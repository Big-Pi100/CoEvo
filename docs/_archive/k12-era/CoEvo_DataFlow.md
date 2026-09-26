# 刻意进化学习 · CoEvo — 数据流节点驱动分析

> **组织原则：每个数据流节点 = 一个独立的可测试单元。节点之间仅通过类型化结构体通信。**
> **分析日期：2026-05-07 | 最后同步：2026-06-08**

---

## 一、管线总图

```
════════════════════════════════════════════════════════════════════
                      CoEvo 数据流全景

 Flow A: AI 对话 (Hot Path, 流式实时)
 Flow B: 制卡 (Cold Path, 对话后异步) — 语言类已关闭 (CP1 skip)
 Flow C: 复习循环 (User-Triggered, 交互流程)
 Flow D: 成就检测 (附属于 B 和 C)
 Flow F: 学习计划 (N8/K12, 对话内结构化学习 + K12 课标驱动)
 Flow G: 对话生命周期 (软删除/恢复/物理删除)
 Flow H: 学习报告/成就页 (Phase 3 看板)
════════════════════════════════════════════════════════════════════

 ┌─────────────────────────────────────────────────────────────────┐
 │  Flow A: 对话 Hot Path                                          │
 │                                                                 │
 │  用户输入 ──→ N1 LLM Caller ──→ 流式回复 ──→ Flutter UI         │
 │      │              │                          │                │
 │      └── 存储到conversation_turns ←────────────┘                │
 │                                                                 │
 │  ⚡ 性能目标: 首 token < 1s, 完整 < 5s                          │
 └─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ 每轮对话结束，触发 Cold Path
 ┌─────────────────────────────────────────────────────────────────┐
 │  Flow B: 制卡 Cold Path (语言类 english/chinese 已跳过)          │
 │                                                                 │
 │  用户消息 + AI回复                                               │
 │      │                                                          │
 │      ▼                                                          │
 │  ┌─────────────────────────────────────────────┐                │
 │  │ N2 概念提取                                  │                │
 │  │                                             │                │
 │  │ 已预制词典的科目(english/chinese) → 跳过      │                │
 │  │ 含"制卡/记住"? → Path B2 (直接制卡)          │                │
 │  │ 否 → LLM提取候选(≤5) → 去重 → 候选列表      │                │
 │  └──────────────────┬──────────────────────────┘                │
 │                     │                                           │
 │              ┌──────┴──────┐                                    │
 │              ▼              ▼                                   │
 │         候选为空        候选有值                                 │
 │              │              │                                   │
 │         不弹窗          Flutter 弹窗                             │
 │         (零打扰)       ┌────┴────┐                              │
 │                       ▼         ▼                               │
 │                   用户勾选    用户跳过                           │
 │                       │         │                               │
 │                       ▼         ▼                               │
 │              ┌────────────┐  skipped_                           │
 │              │ N4 卡片入库  │  concepts                          │
 │              └─────┬──────┘  (表已废弃，改用                   │
 │                    │         卡片 skip 字段)                     │
 │                    ▼ 触发                                        │
 │              ┌────────────┐                                     │
 │              │ N7 成就检测 │                                     │
 │              └────────────┘                                     │
 └─────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────┐
 │  Flow C: 复习循环 (用户主动触发，task 级过滤)                   │
 │                                                                 │
 │  Flutter GET /api/k12/due-cards?conv_id=xxx                      │
 │      │                                                          │
 │      ▼                                                          │
 │  ┌────────────────────────────────────────────────────────┐     │
 │  │ N5 FSRS 待复习队列 (按 task 级过滤)                     │     │
 │  │ SELECT cards JOIN card_memory                          │     │
 │  │ LEFT JOIN user_plan_progress ON plan_id+task_key        │     │
 │  │ WHERE status IN ('in_progress','done')                  │     │
 │  │ AND due <= now()                                       │     │
 │  │ ORDER BY due ASC LIMIT 20                              │     │
 │  └────────────────┬───────────────────────────────────────┘     │
 │                   │ cards[]                                     │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────────────────┐     │
 │  │ N6a 翻牌 (Flutter)                                      │     │
 │  │ Show front → Tap flip → Show back (支持结构化 JSON)     │     │
 │  │ - 英语词典卡 → 牛津级渲染（音标+多义项+例句+搭配）      │     │
 │  │ - 语文词典卡 → 新华字典级（拼音+部首+笔画+释义）        │     │
 │  │ - 概念卡 → 普通文本渲染                                 │     │
 │  └────────────────┬───────────────────────────────────────┘     │
 │                   │                                             │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────────────────┐     │
 │  │ N6b 验证 (Flutter + 后端)                               │     │
 │  │                                                         │     │
 │  │ 统一路径: LLM 三联问 → 3/3 pass, <3 fail               │     │
 │  │ 注入近10轮考题历史供 LLM 参考（避免重复出题）            │     │
 │  │ 验证失败 → 卡片留在队列，不计为复习                      │     │
 │  └────────────────┬───────────────────────────────────────┘     │
 │                   │ rating + result                              │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────────────────┐     │
 │  │ N6c 评分 + FSRS 更新                                    │     │
 │  │ POST /api/review/submit                                │     │
 │  │ {card_id, rating, result} → FSRS.repeat()              │     │
 │  │ → UPDATE card_memory + INSERT review_log               │     │
 │  │ → cardRefreshProvider++ (通知成就页刷新)                 │     │
 │  └────────────────┬───────────────────────────────────────┘     │
 │                   │ 触发                                        │
 │              ┌────────────┐                                     │
 │              │ N7 成就检测 │                                     │
 │              └────────────┘                                     │
 │                                                                 │
 │  循环直到队列为空 → "今日复习完成"                               │
 └─────────────────────────────────────────────────────────────────┘
```

---

## 二、节点详细定义

### N1: AI 对话

```
┌─────────────────────────────────────────────────────────┐
│ Node N1: AI 对话 (Hot Path)                              │
│                                                         │
│ 位置: 后端 Rust (chat_engine/llm_caller.rs)             │
│       前端 Dart (app/lib/screens/chat_screen.dart)       │
│                                                         │
│ Input:                                                  │
│   ChatRequest { user_id, conversation_id, message }     │
│   + 最近 10 轮 conversation_turns (FROM DB)             │
│   + 学习计划上下文 (如有 K12 plan)                       │
│                                                         │
│ 上下文注入 (2026-06-08 扩展):                            │
│   - 当前任务课文全量注入 (full_text + translation)       │
│   - 重点句型 (key_sentence_patterns)                     │
│   - 语法要点 (key_grammar)                               │
│   - 滑动窗口 10 轮 / 5000 字                             │
│                                                         │
│ Output:                                                 │
│   流式 SSE: Thinking → Token* → Done(reply)             │
│   + 存入 conversation_turns                             │
│                                                         │
│ 前端渲染管道 (chat_screen.dart _buildRichContent):      │
│   ws.rs SSE → serde_json → WebSocket                    │
│     → Dart jsonDecode → _buffer += token               │
│     → isStreaming? 纯文本 : 正则解析公式 + Markdown     │
│     → Math.tex (flutter_math_fork) 渲染                 │
│     → markdown_widget 渲染 (支持表格/引用/代码块)        │
│                                                         │
│ 前缀事件:                                               │
│   thinking → 流式 token → done → plan_updated           │
│ 错误事件:                                               │
│   subscription_required / subscription_expired          │
│   / invalid_token / missing_token + 自定义错误           │
└─────────────────────────────────────────────────────────┘
```

### N2: 概念提取 (Cold Path)

```
┌─────────────────────────────────────────────────────────┐
│ Node N2: 概念提取 (Cold Path)                            │
│                                                         │
│ 位置: 后端 Rust (chat_engine/concept_extractor.rs)      │
│                                                         │
│ Input:                                                  │
│   { user_id, user_message, ai_reply, conversation_id }  │
│                                                         │
│ 语言类跳过 (2026-06-08):                                 │
│   English/Chinese 已预制完整词典卡片                      │
│   ed == "english" || ed == "chinese" → 跳过 CP1         │
│   这些科目的卡片由阅读优先(CP2) + 复习循环管理             │
│                                                         │
│ Step 1 — 意图检测 (本地，无 LLM):                        │
│   IF user_message 包含 ["制卡","记住","做成卡片",...]    │
│   → Path B2: 调用 LLM 直接生成卡片                      │
│                                                         │
│ Step 2 — 概念提取 (LLM 调用):                           │
│   ELSE: 调用 LLM 提取候选概念 ≤ 5 个                    │
│                                                         │
│ Step 3 — 去重 (本地):                                   │
│   vs cards 表: SELECT front FROM cards                   │
│   skipped_concepts 表已废弃 → 前端维护 skip 状态         │
│                                                         │
│ Output:                                                 │
│   { candidates: [{concept, source_text}...] }           │
│   或 { empty: true }                                     │
└─────────────────────────────────────────────────────────┘
```

### N5: 待复习队列 (FSRS + Task 级过滤)

```
┌─────────────────────────────────────────────────────────┐
│ Node N5: FSRS 待复习队列 (task 级过滤)                   │
│                                                         │
│ 位置: 后端 Rust (card_engine/fsrs_scheduler.rs)         │
│                                                         │
│ Input:                                                  │
│   GET /api/k12/due-cards?user_id=xxx&conv_id=xxx        │
│                                                         │
│ Logic (2026-06-08 升级: 按 task 过滤):                   │
│   SELECT c.id, c.front, c.back, ...                    │
│   FROM cards c                                          │
│   JOIN card_memory cm ON c.id = cm.card_id             │
│   LEFT JOIN user_plan_progress upp                       │
│     ON c.plan_id = upp.plan_id AND c.task_key = upp.task_key
│   WHERE c.user_id = ?                                   │
│     AND cm.status = 'active'                            │
│     AND cm.due <= ?                                     │
│     AND upp.status IN ('in_progress', 'done')            │
│   ORDER BY CASE WHEN cm.state = 0 THEN 1 ELSE 0 END,    │
│            cm.due ASC                                   │
│   LIMIT 20                                              │
│                                                         │
│ Output:                                                 │
│   { cards: [{id, front, back, card_type, ...}],         │
│     has_more: bool }                                   │
│                                                         │
│ FSRS 状态机 (自实现 fsrs5.rs, 16/16 测试通过):           │
│   New ──(复习)→ Learning ──(Good)→ Review              │
│   Review ──(Again)→ Relearning ──(Good)→ Review        │
│                                                         │
│ mastered = state=2 + reps>=3                            │
└─────────────────────────────────────────────────────────┘
```

### N6: 复习交互 + 验证 (统一 LLM 路径)

```
┌─────────────────────────────────────────────────────────┐
│ Node N6: 复习交互 (统一 LLM 验证路径)                     │
│                                                         │
│ 位置: Flutter (review_screen.dart) + 后端 (routes.rs)    │
│                                                         │
│ N6a 翻牌 (Flutter):                                     │
│   显示 front → 用户回忆 → 点击翻转 → 显示 back          │
│   支持结构化 JSON 渲染:                                   │
│   - 英语词典: word + 音标 + 多义项 + 例句 + 搭配        │
│   - 语文词典: 字 + 拼音 + 部首 + 笔画 + 释义            │
│   - 课文卡: full_text + translation + 语法              │
│                                                         │
│ N6b 验证 (统一路径):                                    │
│   Step 1: POST /api/review/verify (LLM 出3题)           │
│     { card_id, front, back, history(近10轮) }           │
│     → [{question, expected_answer}]                     │
│                                                         │
│   Step 2: Flutter 依次展示问题，收集答案                 │
│                                                         │
│   Step 3: POST /api/review/judge (LLM 批量判断)          │
│     → [{correct, feedback}], total_correct              │
│     → 3/3 → pass, <3 → fail                             │
│                                                         │
│   ⚡ 后台异步: 评判不阻塞 UI，卡片可随时关闭              │
│   评判结果缓存 (按 card.id), 关闭后再展开仍显示           │
│                                                         │
│ N6c 评分:                                               │
│   POST /api/review/submit                              │
│   通过 → 从列表移除 + cardRefreshProvider++              │
│   失败 → 留在列表 + 不计为复习                           │
│                                                         │
│ 近期考题历史注入 (2026-06-08):                           │
│   review_log.details_json 存储每轮详细问答               │
│   verify 时查询近10轮注入 prompt                         │
│   LLM 避免重复出题，聚焦薄弱点                           │
└─────────────────────────────────────────────────────────┘
```

### N7: 成就检测

```
┌─────────────────────────────────────────────────────────┐
│ Node N7: 成就检测                                        │
│                                                         │
│ 位置: 后端 Rust (achievement_engine.rs)                 │
│                                                         │
│ 触发点:                                                 │
│   - N4 卡片入库成功后                                    │
│   - N6c 复习评分后                                      │
│   - 每日定时检测 (24h 冷却)                               │
│                                                         │
│ Input (单次聚合查询):                                   │
│   AchievementAggregate {                                 │
│     total_cards, total_reviews,                         │
│     domains_covered, plans_completed,                   │
│     conversations_completed                             │
│   }                                                    │
│                                                         │
│ 成就列表 (2026-06-08): 23+ 个成就                       │
│   - 固定成就: 卡片数/连续天数/领域数/复习数/计划完成数   │
│   - 动态成就 (学习计划绑定): task→bronze, stage→silver, │
│     domain→gold, cross→platinum                         │
│   - 分类展示: 学习/坚持/领域/特殊/cosmos                │
│                                                         │
│ 成就详情 API: GET /api/user/{uid}/achievements-all       │
│   返回分组成就 + 进度 + 隐藏成就                         │
└─────────────────────────────────────────────────────────┘
```

### N8: 学习计划 (K12 双路径)

```
┌─────────────────────────────────────────────────────────┐
│ Node N8: 学习计划 (K12 课标驱动 + CP2 自由路径)          │
│                                                         │
│ 位置: 后端 Rust (plan_handler.rs + ws.rs)                │
│                                                         │
│ 双路径 (2026-06-01 定稿):                                │
│                                                         │
│ Path A — K12 课标计划 (预制):                           │
│   Flutter k12_init → 读取 v3/plans/{subject}.json       │
│   → 按 grade_band 过滤 stage → 创建 conversation_plan    │
│   → 激活首 stage 卡片 (copy_prebuilt_card)              │
│   → 后续 task 推进时自动激活下一批卡片                    │
│   卡片源: v3/cards/{subject}.json (每科合并为一个文件)   │
│                                                         │
│ Path B — CP2 自由计划 (LLM 生成):                       │
│   用户表达学习目标 → LLM 输出 <plan_update> JSON        │
│   → handle_plan_update() 解析                           │
│   → upsert_learning_plan() / apply_plan_mutations()     │
│   → render_plan() → 对话文本                            │
│                                                         │
│ 数据表:                                                 │
│   conversation_plans (原 learning_plans, V2.0 更名)     │
│   user_plan_progress (按 task_key 分列存储进度)          │
│   user_plan_progress (按 task_key 分列存储进度)          │
│                                                         │
│ 卡片激活机制:                                           │
│   首次 init → 仅激活第1个 stage                          │
│   task 推进 → copy_prebuilt_card 逐个激活               │
│   activate_stage_cards (V3 简化: no-op)                  │
│                                                         │
│ Prompt 注入 (2026-06-08 升级):                          │
│   - 当前 task 课文 full_text                            │
│   - 重点句型 + 语法要点                                  │
│   - 任务完成信号 (✅ 已完成)                             │
│   - LLM prompt 三级: nursery/primary/secondary           │
│   - 考核机制 (grill): 2-3 题递进                         │
└─────────────────────────────────────────────────────────┘
```

---

## 三、用户会话流转 (完整时序)

```
用户启动App
    │
    ▼
┌──────────┐     ┌──────────┐     ┌───────────┐
│ 登录/注册 │ ──→ │ 对话主页  │ ──→ │ AI 对话   │
│ 限流:     │     └──────────┘     │ + 课文面板 │
│ reg 5/min │                      └─────┬─────┘
│ login 10/m│                            │
└──────────┘         每轮对话结束后 ├─→ CP2 检查 plan_update
                      (后台ColdPath) │    → cardRefreshProvider++
                         ┌──────────────┘
                         ▼
                  ┌──────────────┐
                  │ N2 概念提取   │ (语言类已跳过)
                  │ (后台静默)    │
                  └──────┬───────┘
                         │ CP1
                    ┌────┴────┐
                    ▼         ▼
               候选为空    候选有值
                    │         │
                 不弹窗    Flutter弹窗
                 (静默)      │
                       ┌─────┴─────┐
                       ▼           ▼
                   用户勾选     用户跳过
                       │           │
                  ┌────▼────┐
                  │ N4 入库  │
                  └─────────┘

         复习循环 (用户主动点击"复习")
                       │
                       ▼
                ┌──────────────┐
                │ N5 到期队列   │
                │ task 级过滤   │
                └──────┬───────┘
                       │ cards[]
                       ▼
                ┌──────────────┐
                │ N6a 翻牌     │
                │ 列表+展开式   │
                └──────┬───────┘
                       │
                       ▼
                ┌──────────────┐
                │ N6b LLM 三联问│
                │ 3/3→pass <3→fail│
                │ 后台异步不阻塞 │
                └──────┬───────┘
                       ▼
                ┌──────────────┐
                │ N6c 评分     │
                │ cardRefresh++ │
                └──────┬───────┘
                       │
                  ┌────▼────┐
                  │ N7 成就  │
                  │ + 成就页 │
                  └─────────┘
                       │
                 还有到期卡片?
                    │    │
                   是   否
                    │    │
                    ▼    ▼
              继续循环  "今日完成"

         成就页面 (tab 4)
               │
               ▼
        ┌──────────────┐
        │ 4 API 聚合    │
        │ profile+     │
        │ activity+    │
        │ learning-    │
        │ report+      │
        │ k12-progress │
        └──────┬───────┘
               │
          cardRefreshProvider 监听
          复习/CP2 更新 → 自动刷新
```

---

## 四、Seat-map: 数据存储位置 (V2.1+)

```
┌─────────────────────────────────────────────────────────────────┐
│                        SQLITE                                   │
│                                                                 │
│  18 张有效表 (V2.1 定稿: 用户状态用 DB 列非 JSON)               │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ users                  (Auth + PII 加密)             │       │
│  │ id | username | password_hash | streak_days          │       │
│  │   | display_name | real_name(加密) | phone(加密)     │       │
│  │   | created_at                                       │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ cards                  (Data + K12 关联)             │       │
│  │ id | user_id | domain | subject | card_type         │       │
│  │   | front | back | source_sentence | conversation_id │       │
│  │   | plan_id | task_key | created_at                 │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ card_memory            (FSRS State, 1:1)            │       │
│  │ card_id | state | status | difficulty | stability   │       │
│  │   | due | last_review | reps | lapses               │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ conversation_plans      (K12 + CP2 计划)             │       │
│  │ id | user_id | conversation_id | goal | subject     │       │
│  │   | grade_band | plan_content | created_at          │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ user_plan_progress      (状态列存储, 非 JSON)        │       │
│  │ id | user_id | plan_id | task_key | status          │       │
│  │   | updated_at                                      │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  更多表: tokens | conversations | conversation_turns           │
│  review_log | achievements | knowledge_graph                   │
│  k12_quiz_bank | k12_quiz_attempts | user_preferences          │
│  guardian_assignments | admin_users | admin_audit_log          │
│  subscription_requests                                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、API 契约 (V2.1+)

### 新增 K12 端点

| Method | Path | 说明 |
|:--|:--|:--|
| POST | `/api/k12/init` | 初始化 K12 学习计划 |
| GET | `/api/k12/progress` | 学习计划卡片进度 |
| GET | `/api/k12/due-cards` | 到期卡片 (conv_id 过滤) |
| GET | `/api/k12/reading/{conv_id}/current-card` | 当前课文卡片 |
| GET | `/api/user/{uid}/profile` | 用户画像 (stats+cefr+成就) |
| GET | `/api/user/{uid}/learning-report` | 学习报告 (家长看板) |
| GET | `/api/user/{uid}/activity` | 活动热力图 |
| GET | `/api/user/{uid}/achievements-all` | 全部成就详情 |
| GET | `/api/user/{uid}/avatar` | 头像 (GET/POST 上传) |

### 限流

| 端点 | 限流 | 生效 |
|:--|:--|:--|
| `/api/auth/register` | 5/min/IP | 2026-06-08 |
| `/api/auth/login` | 10/min/IP | 2026-06-08 |

### 事件驱动

```
复习通过 → submitReview → cardRefreshProvider++
CP2 plan_updated → chat_screen → cardRefreshProvider++
成就页监听 cardRefreshProvider → 自动刷新数据
```

---

## 六、数据流分析发现的问题与建议（实施后状态 V2.1）

### 🔴 P0 问题 (已全部解决)

| # | 问题 | 状态 | 解决方案 |
|:--|:--|:--:|:--|
| 1 | N2 LLM 提取只输出 front | ✅ | LLM prompt 返回完整结构 |
| 2 | conversation_turns 未在计划中出现 | ✅ | 增加表 |
| 3 | users 缺少 streak_days | ✅ | 增加字段 |
| 4 | 安全: batch-create/skip-delete 缺鉴权 | ✅ | 已修复 |
| 5 | 安全: cards_all_handler 缺鉴权 | ✅ | 已修复 |
| 6 | PII 加密: real_name/phone AES-256-GCM | ✅ | encryption.rs |
| 7 | 限流: 注册/登录无防护 | ✅ | rate_limiter 5/10 per min |

### 🟡 P1 改进 (已实施)

| # | 改进 | 状态 |
|:--|:--|:--:|
| 1 | 复习验证无记忆 → 注入10轮历史 | ✅ 2026-06-08 |
| 2 | 卡片状态更新竞态 → card.id 提交 | ✅ 2026-06-08 |
| 3 | 成就页数据不刷新 → cardRefreshProvider | ✅ 2026-06-08 |
| 4 | 复习页 tab 首项不显示 → 自动加载修复 | ✅ 2026-06-08 |
| 5 | CP1 语言类不必要 → english/chinese 跳过 | ✅ 2026-06-08 |

---

## 七、开发计划修正记录 (V2.1)

### 修正 1: 表结构 (V2.0 动态扩展至 18 张)
```
新增: conversation_plans, user_plan_progress
      knowledge_graph, k12_quiz_bank, k12_quiz_attempts
      guardian_assignments, admin_users, admin_audit_log
      subscription_requests
废弃: learning_plans → 备份为 learning_plans_legacy
      skipped_concepts → 状态由前端管理
```

### 修正 2: 用户状态存储
```
原: user_plan_progress.plan_progress (JSON)
改: user_plan_progress.task_key + status (列存储, 可查询)
```

### 修正 3: 卡片卡片知识图谱
```
新增: 4 层架构 — 入口路由 → 课标约束 → 知识图谱 → 评估反馈
知识图谱: 177 节点, 275 边 (高中 10 科)
```

### 修正 4: Prompt 体系
```
新增三级阅读提示词: nursery/primary/secondary
英语: 按 A1/A2/B1/B2 分级
语文: 对标英语结构重写 (禁例清单+教学要点+文体差异)
考核机制: 2-3 题递进, CP2 自动分析
```

---

*文档版本: V2.2 (实施后)*
*日期: 2026-06-08*
*最后同步: 2026-06-08 — 覆盖成就页刷新/复习页竞态/CP1跳过/限流/提示词优化*
