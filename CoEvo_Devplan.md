# 刻意进化学习 · coevo — 开发计划 V2.1

> **如果不想被 AI 取代，你需要刻意进化。**
>
> AI 对话中自动提取概念、用户确认制卡、FSRS 调度复习、客观验证内化。
> Rust + Flutter · TDD 先行 · 2026-05 MVP · 持续迭代

---

## 〇、品牌

| 层级 | 内容 |
|------|------|
| **品牌** | 刻意进化 |
| **产品** | 刻意进化学习 |
| **英文** | coevo |
| **Slogan** | 如果不想被AI取代，你需要刻意进化。 |
| **品牌故事** | 每一次AI对话，每一次刻意复习练习，都是你的进化。 |

---

## 一、产品定位

### 一句话

> AI 对话中自动发现值得记住的概念，用户确认即制卡，按记忆曲线复习，通过客观验证完成内化。

### 核心理念

```
用户和 AI 对话学习任何东西
    → 每轮对话后，系统自动提取候选概念
    → 用户勾选确认，或对话中直接说"把XX制成卡片"
    → 按 FSRS 记忆曲线在最佳时间弹出复习
    → 翻牌回忆 + 客观验证（LLM 三联问）
    → 日积月累，刻意记住 → 真正进化
```

### 对标差异化

| | Anki | ChatGPT | 刻意进化 |
|------|------|---------|---------|
| AI 对话 | ❌ | ✅ | ✅ |
| 自动提取概念 | ❌ | ❌ | **✅** |
| 用户确认制卡 | ❌ | ❌ | **✅** |
| 记忆曲线 | ✅ | ❌ | **✅ FSRS** |
| 客观验证 | ❌ | ❌ | **✅ LLM 三联问** |
| K12 课标驱动 | ❌ | ❌ | **✅ V2.1** |
| 结构化词典 | ❌ | ❌ | **✅ 牛津/新华字典级** |

---

## 二、制卡流程

```
┌─────────────────────────────────────────┐
│ CP1: 每轮对话后自动提取                   │
│  语言类(english/chinese) → 跳过          │
│  (已有预制词典: 英语12,791/语文2,714)    │
│                                         │
│  含"制卡/记住"意图 → LLM 直接制卡        │
│  常规对话 → LLM 提取候选(≤5) → 去重      │
│  → 弹窗 → 用户勾选/跳过                  │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ CP2: 学习计划内自动挂载                   │
│  K12 Init 激活首阶段卡片                  │
│  Task推进时自动 copy_prebuilt_card        │
│  对话结束 → plan_updated 检查             │
└─────────────────────────────────────────┘
```

---

## 三、复习流程

```
N5 调度到期卡片 (task 级过滤)
    │
    ▼
N6a 翻牌 (支持结构化 JSON 渲染)
  看到正面 → 尝试回忆 → 点击翻转
  词典卡: 牛津/新华字典级展示
  课文卡: full_text + translation + 语法
    │
    ▼
N6b 验证 (统一 LLM 三联问, 后台异步)
  Step 1: LLM 出 3 题 (注入近10轮历史)
  Step 2: 用户依次作答
  Step 3: LLM 批量判断
  3/3 → pass (从列表移除, 计入复习)
  <3 → fail (留在列表, 不计, 可重试)
    │
    ▼
N6c 评分 → FSRS 更新 → cardRefreshProvider++
```

---

## 四、学习计划流程 (K12 + CP2 双路径)

```
Path A: K12 课标计划 (预制)
  Flutter k12_init(grade_band=g1-2, subject=english)
    → 读 v3/plans/{subject}.json
    → 按 grade_band 过滤 stage
    → INSERT conversation_plan
    → copy_prebuilt_card (仅首个 stage)
    → LLM prompt 三级提示词驱动教学
    → CP2 检测 ✅ 已完成 → 推进 task
    → 激活下一 task 卡片

Path B: CP2 自由计划 (LLM 生成)
  用户表达目标 → LLM 输出 <plan_update> JSON
    → handle_plan_update → 解析 + 写入
    → render_plan → 对话文本
    → 后续对话注入学习上下文
```

---

## 五、节点定义

### N1: AI 对话 (2026-06-08)

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust (ws.rs + llm_caller.rs) |
| **技术** | DeepSeek V4 Flash，OpenAI 兼容 API |
| **输入** | 用户消息 + 最近 10 轮/5000 字 + 学习上下文 |
| **上下文注入** | 课文 full_text + translation + 句型 + 语法 |
| **输出** | 流式 SSE (thinking→token*→done) |

### N2: 概念提取

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust (concept_extractor.rs) |
| **语言类跳过** | ✅ english/chinese 跳过 |
| **输出** | 候选概念列表 或 空 |

### N3: 卡片格式化 — 纯函数 (已固化)
### N4: 卡片入库 — 去重 + 事务写入 (已固化)

### N5: 待复习队列 (2026-06-08)

| 属性 | 值 |
|------|-----|
| **位置** | 后端 Rust (fsrs_scheduler.rs) |
| **算法** | 自实现 FSRS-5 (fsrs5.rs, 16/16 测试通过) |
| **过滤** | task 级: LEFT JOIN user_plan_progress |
| **mastered** | state=2 + reps>=3 |

### N6: 复习交互 (2026-06-08)

| 属性 | 值 |
|------|-----|
| **验证方式** | 统一 LLM 三联问 (3/3→pass, <3→fail) |
| **考题历史** | 注入近10轮 review_log.details_json |
| **异步评判** | 后台不阻塞 UI, 结果按 card.id 缓存 |
| **失败处理** | 卡片留在队列, 不计为复习 |

### N7: 成就检测

| 属性 | 值 |
|------|-----|
| **位置** | achievement_engine.rs |
| **触发** | 制卡 + 复习 + 每日定时 (24h 冷却) |
| **成就数** | 23+ 个 (固定 + 动态 tier) |

### N8: 学习计划 (K12)

| 属性 | 值 |
|------|-----|
| **位置** | plan_handler.rs + ws.rs |
| **数据表** | conversation_plans / user_plan_progress |
| **Prompt 三级** | nursery (A1) / primary (A2-B1) / secondary (B2) |
| **考核机制** | 2-3 题递进, CP2 自动分析 |

---

## 六、节点汇总

| 节点 | 位置 | 负责 |
|------|------|------|
| N1 | 后端 | AI 对话 (10轮/5000字上下文) |
| N2 | 后端 | 概念提取 (语言类跳过) |
| N3 | 后端 | 卡片格式化 (纯函数) |
| N4 | 后端 | 卡片入库 (去重+事务) |
| N5 | 后端 | FSRS 待复习队列 (task级过滤) |
| N6 | 客户端+后端 | 翻牌 + LLM三联问 + 评分 |
| N7 | 后端 | 成就检测 (23+ 成就) |
| N8 | 后端 | K12 + CP2 学习计划 |

---

## 七、数据库设计 (20 张表)

### 核心表

```sql
-- 卡片 + K12 关联
cards (
    id TEXT PK, user_id TEXT, domain TEXT, subject TEXT,
    card_type TEXT, front TEXT, back TEXT, source_sentence TEXT,
    conversation_id TEXT, plan_id TEXT, task_key TEXT, created_at INTEGER
)

-- FSRS 记忆状态
card_memory (
    card_id TEXT PK, state INTEGER, status TEXT,
    difficulty REAL, stability REAL, due INTEGER,
    last_review INTEGER, reps INTEGER, lapses INTEGER
)

-- K12 学习计划 (V2.0 更名)
conversation_plans (
    id TEXT PK, user_id TEXT, conversation_id TEXT,
    goal TEXT, subject TEXT, grade_band TEXT,
    plan_content TEXT, created_at INTEGER, updated_at INTEGER
)

-- 任务进度 (按 task_key 分列)
user_plan_progress (
    id TEXT PK, user_id TEXT, plan_id TEXT,
    task_key TEXT, status TEXT, updated_at INTEGER
)
```

### 完整表清单 (18 张)

```
users | tokens | conversations | conversation_turns
cards | card_memory | review_log | achievements
conversation_plans | user_plan_progress
knowledge_graph | k12_quiz_bank | k12_quiz_attempts
user_preferences | guardian_assignments
admin_users | admin_audit_log | subscription_requests
```

> cards 表含 `plan_id`, `task_key`, `subject` 列用于 K12 关联
> user_plan_progress 含 `score`, `attempt_count`, `started_at`, `completed_at`

---

## 八、技术栈

| 层 | 技术 |
|----|------|
| 后端 | Rust (axum + tokio + rusqlite) |
| 客户端 | Flutter 3.x (Riverpod + GoRouter + Material3) |
| 数据库 | SQLite (rusqlite, 后端独有) |
| 记忆算法 | FSRS-5 (自实现 fsrs5.rs) |
| LLM | DeepSeek V4 Flash (OpenAI 兼容) |
| 通信 | REST + WebSocket |

---

## 九、实施状态 (2026-06-08)

### ✅ MVP 完成 (2026-05)
```
N1 对话 → N2 提取 → N3-N4 制卡 → N5 FSRS → N6 复习 → N7 成就
用户认证 / 对话持久化 / WS 流式 / TTS / STT
```

### ✅ V2.0 完成 (2026-05-31)
```
Phase 0-4: K12 课标集成 + 知识图谱 + 评估管线
conversation_plans + user_plan_progress
Plan_templates (15行共享)
质量评估: e2e-quality-eval (5维评分)
```

### ✅ V2.1 完成 (2026-06)
```
重构:
  CP1 语言类跳过 (english/chinese)  ← 2026-06-08
  复习页竞态修复 (card.id 提交)      ← 2026-06-08
  成就页事件驱动刷新 (cardRefreshProvider)
  复习验证注入10轮考题历史
  auth 限流 (reg 5/min, login 10/min)
  头像 404 降级
  review_screen tab 首项显示修复
  卡文件合并 21→14  (每科一个)
  数据目录清理 (~73MB)

数据:
  英语重建 Phase 1-5:
    20,688 词卡 → 12,791 词根 (CEFR A1-C1)
    80 篇分级课文 (A1=15, A2=20, B1=25, B2=20)
    名篇为主: Aesop/安徒生/Twain/Dickens/Poe/Frost/Lincoln
  English.json plan 重写 (4 stages × 80 tasks)
  Prompt 三级: nursery/primary/secondary + 考核机制
  词典富集:
    语文: 2,714 (新华字典级, 结构化 JSON)
    英语: 12,791 (牛津级, 结构化 JSON)
  非语言10科卡片重分配: 移除 784 条跨 topic 引用

前端:
  ChatReadingPassage (课文阅读面板 + 朗读)
  Dict card renderer (牛津/新华字典渲染)
  TTS 音色持久化修复
  复习页: 评判中/通过/未通过标签, 后台异步评判
```

### ⏳ V2.2 规划
```
- N9 图像识别 (DeepSeek V4 Vision)
- 学习日志 (AI 生成每日总结)
- 难点跟踪 (挂起-召回-再攻克)
- japanese/russian 卡片文件修复 (22+93 缺卡)
```

---

## 十、设计原则

```
1. 系统不替用户决定什么值得学，系统建议，用户确认
2. 跳过的概念不再骚扰，主动制卡覆盖跳过记录
3. 复习不依赖自我判断，客观验证才能通过
4. 语言类走轻量路径（词库+文本匹配），通用类走 LLM
5. 每个节点独立可测
6. 用户状态用 DB 列，非 JSON (2026-06-01 定稿)
```

---

*文档版本: V2.1 (实施后)*
*日期: 2026-06-08*
*最后同步: 2026-06-08 — 覆盖 V2.0+V2.1 全部变更*
