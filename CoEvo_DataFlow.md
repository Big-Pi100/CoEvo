# 刻意进化学习 · CoEvo — 数据流节点驱动分析

> **组织原则：每个数据流节点 = 一个独立的可测试单元。节点之间仅通过类型化结构体通信。**
> **分析日期：2026-05-07**

---

## 一、管线总图

```
════════════════════════════════════════════════════════════════════
                      CoEvo 数据流全景

 Flow A: AI 对话 (Hot Path, 流式实时)
 Flow B: 制卡 (Cold Path, 对话后异步)
 Flow C: 复习循环 (User-Triggered, 交互流程)
 Flow D: 成就检测 (附属于 B 和 C)
 Flow E: 跳过管理
 Flow F: 学习计划 (N8, 对话内结构化学习)
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
 │  Flow B: 制卡 Cold Path                                         │
 │                                                                 │
 │  用户消息 + AI回复                                               │
 │      │                                                          │
 │      ▼                                                          │
 │  ┌─────────────────────────────────────────────┐                │
 │  │ N2 意图识别 + 概念提取                       │                │
 │  │                                             │                │
 │  │ 含"制卡/记住"? ──→ Path B2 (直接制卡)       │                │
 │  │ 否 ──→ LLM提取候选(≤5) → 去重 → 候选列表    │                │
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
 │              │ N3 卡片格式化│  concepts                          │
 │              │ (纯函数)    │  表写入                            │
 │              └─────┬──────┘                                     │
 │                    ▼                                            │
 │              ┌────────────┐                                     │
 │              │ N4 卡片入库 │                                     │
 │              │ (去重+写入) │                                     │
 │              └─────┬──────┘                                     │
 │                    │                                            │
 │                    ▼ 触发                                        │
 │              ┌────────────┐                                     │
 │              │ N7 成就检测 │                                     │
 │              └────────────┘                                     │
 └─────────────────────────────────────────────────────────────────┘

 ┌─────────────────────────────────────────────────────────────────┐
 │  Flow C: 复习循环 (用户主动触发)                                │
 │                                                                 │
 │  Flutter GET /api/review/due                                     │
 │      │                                                          │
 │      ▼                                                          │
 │  ┌────────────────────────────────────────────┐                 │
 │  │ N5 FSRS 待复习队列                          │                 │
 │  │ SELECT cards JOIN card_memory              │                 │
 │  │ WHERE state IN (New,Learning,Review,       │                 │
 │  │       Relearning) AND due <= now()         │                 │
 │  │ ORDER BY due ASC LIMIT 20                  │                 │
 │  └────────────────┬───────────────────────────┘                 │
 │                   │ cards[]                                     │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────┐                 │
 │  │ N6a 翻牌 (Flutter)                          │                 │
 │  │ Show front → Tap flip → Show back+source   │                 │
 │  └────────────────┬───────────────────────────┘                 │
 │                   │                                             │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────┐                 │
 │  │ N6b 验证 (Flutter + 后端)                   │                 │
 │  │                                             │                 │
 │  │ 语言类: 打字，本地文本匹配 → pass/fail      │                 │
 │  │ 通用类: LLM 三联问 → pass(≥2/3)/fail       │                 │
 │  └────────────────┬───────────────────────────┘                 │
 │                   │ rating + result                            │
 │                   ▼                                             │
 │  ┌────────────────────────────────────────────┐                 │
 │  │ N6c 评分 + FSRS 更新                        │                 │
 │  │ POST /api/review/submit                    │                 │
 │  │ {card_id, rating, result} → FSRS.repeat()  │                 │
 │  │ → UPDATE card_memory + INSERT review_log   │                 │
 │  └────────────────┬───────────────────────────┘                 │
 │                   │                                             │
 │                   ▼ 触发                                        │
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
│ 复用: LinguaFlow llm_caller.rs (直接复制)               │
│                                                         │
│ Input:                                                  │
│   ChatRequest { user_id, conversation_id, message }     │
│   + 最近 10 轮 conversation_turns (FROM DB)             │
│                                                         │
│ Output:                                                 │
│   流式 SSE: Thinking → Token* → Done(reply)             │
│   + 存入 conversation_turns                             │
│                                                         │
│ DB 写入:                                                │
│   INSERT INTO conversation_turns                        │
│   (id, conversation_id, role, content, created_at)       │
│                                                         │
│ 关键性能决策:                                           │
│   - 双请求竞速 (tokio::select!) 保证最低延迟             │
│   - 1s 超时 → 模板回复 (不丢用户输入)                   │
│   - warmup() 启动预热                                   │
│                                                         │
│ 依赖:                                                   │
│   - reqwest HTTP client (全局单例)                      │
│   - OpenAI 兼容 API (DeepSeek V4/Qwen3)                 │
└─────────────────────────────────────────────────────────┘
```

### N2: 意图识别 + 概念提取

```
┌─────────────────────────────────────────────────────────┐
│ Node N2: 意图识别 + 概念提取 (Cold Path)                │
│                                                         │
│ 位置: 后端 Rust (chat_engine/concept_extractor.rs)      │
│ 复用: 适配 LinguaFlow concept_extractor.rs              │
│                                                         │
│ Input:                                                  │
│   { user_id, user_message, ai_reply, conversation_id }  │
│                                                         │
│ Step 1 — 意图检测 (本地，无 LLM):                       │
│   IF user_message 包含 ["制卡","记住","做成卡片",       │
│       "make card","add to cards","记住这个"]             │
│   → Path B2: 调用 LLM 直接生成卡片                      │
│                                                         │
│ Step 2 — 概念提取 (LLM 调用):                           │
│   ELSE: 调用 LLM 提取候选概念 ≤ 5 个                    │
│   Prompt: "从以下对话中提取值得记住的概念..."            │
│   Output: JSON ["概念1","概念2",...]                    │
│                                                         │
│ Step 3 — 去重 (本地):                                   │
│   3a. vs cards 表: SELECT front FROM cards               │
│       WHERE user_id = ? AND LOWER(front) IN (...)       │
│   3b. vs skipped_concepts 表:                           │
│       SELECT front FROM skipped_concepts                │
│       WHERE user_id = ? AND LOWER(front) IN (...)       │
│                                                         │
│   candidates = 提取结果 - 已有 - 已跳过                 │
│                                                         │
│ Output:                                                 │
│   { candidates: [{concept, source_text}...] }           │
│   或 { direct_card: {front, back, source, domain} }    │
│   或 { empty: true } — 不弹窗                           │
│                                                         │
│ ❓ 问题:                                                │
│   LLM 提取是否会提取到多词概念/短语?                    │
│   去重是否只精确匹配 front, 还是需要语义去重?           │
│   候选概念要不要带解释(back)?                           │
│   - DevPlan 只说了 front, 但制卡需要 back              │
│   - 推荐: LLM 同时生成 front + back + source_sentence  │
└─────────────────────────────────────────────────────────┘
```

### N3: 卡片格式化

```
┌─────────────────────────────────────────────────────────┐
│ Node N3: 卡片格式化 (纯函数)                             │
│                                                         │
│ 位置: 后端 Rust (card_engine/card_formatter.rs)         │
│ 新开发                                                   │
│                                                         │
│ Input:                                                  │
│   ConceptInput {                                        │
│     user_id: String,                                    │
│     front: String,           // 概念名                  │
│     back: String,            // 释义/答案               │
│     domain: String,          // 领域标签                │
│     card_type: String,       // "vocabulary"|"concept"  │
│     source_sentence: String, // 来源对话句               │
│   }                                                   │
│                                                         │
│ Logic (纯函数):                                          │
│   1. 生成 card_id = UUID v4                             │
│   2. 构建 Card {                                       │
│        id, user_id, domain, card_type,                 │
│        front, back, source_sentence,                   │
│        created_at: now()                              │
│      }                                                │
│   3. 构建初始 CardMemory {                              │
│        card_id,                                        │
│        state: 0 (New),                                 │
│        difficulty: 5.0,    // FSRS 默认                │
│        stability: 0.0,     // FSRS 默认                │
│        due: now(),         // 立即可复习               │
│        last_review: null,                              │
│        reps: 0,                                        │
│        lapses: 0                                       │
│      }                                                │
│                                                         │
│ Output: (Card, CardMemory)                              │
│                                                         │
│ 可测试性: 100% 纯函数，无需 mock，输入→输出确定          │
└─────────────────────────────────────────────────────────┘
```

### N4: 卡片入库

```
┌─────────────────────────────────────────────────────────┐
│ Node N4: 卡片入库                                        │
│                                                         │
│ 位置: 后端 Rust (card_engine/card_repository.rs)        │
│ 新开发                                                   │
│                                                         │
│ Input: (Card, CardMemory)                               │
│                                                         │
│ Logic:                                                  │
│   1. 去重检查:                                          │
│      SELECT front FROM cards WHERE user_id = ?          │
│      计算 Jaro-Winkler 相似度                            │
│      IF max_similarity > 0.85 → REJECT (返回已存在提示) │
│                                                         │
│   2. 跳过记录移除 (用户主动制卡时):                      │
│      DELETE FROM skipped_concepts                       │
│      WHERE user_id = ? AND LOWER(front) = LOWER(?)      │
│                                                         │
│   3. 事务写入 (BEGIN→INSERT×2→COMMIT):                   │
│      INSERT INTO cards (...)                            │
│      INSERT INTO card_memory (...)                      │
│                                                         │
│ Output: Result<CardId, InsertError>                     │
│                                                         │
│ 错误类型:                                               │
│   - DuplicateFront(front) — 前端提示用户已存在           │
│   - DatabaseError(msg)                                  │
│                                                         │
│ 🔒 事务保证: cards 和 card_memory 要么同时存在          │
└─────────────────────────────────────────────────────────┘
```

### N5: 待复习队列 (FSRS)

```
┌─────────────────────────────────────────────────────────┐
│ Node N5: FSRS 待复习队列                                 │
│                                                         │
│ 位置: 后端 Rust (card_engine/fsrs_scheduler.rs)         │
│ 新开发 (关键模块)                                        │
│                                                         │
│ Input:                                                  │
│   GET /api/review/due?user_id=xxx                       │
│                                                         │
│ Logic:                                                  │
│   SELECT c.id, c.front, c.back, c.domain,               │
│          c.card_type, c.source_sentence,                │
│          cm.state, cm.difficulty, cm.stability,         │
│          cm.due, cm.reps, cm.lapses                     │
│   FROM cards c                                          │
│   JOIN card_memory cm ON c.id = cm.card_id             │
│   WHERE c.user_id = ?                                   │
│     AND cm.state IN (0, 1, 2, 3)  -- New/Learning/     │
│                                    -- Review/Relearning │
│     AND cm.due <= ?              -- now()              │
│   ORDER BY cm.due ASC                                  │
│   LIMIT 20                                              │
│                                                         │
│ Output:                                                 │
│   {                                                     │
│     cards: [{                                           │
│       id, front, back, domain, card_type,              │
│       source_sentence, state, reps                     │
│     }],                                                │
│     total_due: N,                                        │
│     has_more: bool                                       │
│   }                                                   │
│                                                         │
│ FSRS 状态机:                                            │
│   New ──(首次复习)→ Learning ──(Good)→ Review          │
│   Review ──(Again)→ Relearning ──(Good)→ Review        │
│   Relearning ──(Again)→ Relearning (间隔逐渐延长)       │
│                                                         │
│ ❓ 需要确认:                                             │
│   - fsrs crate 的 API 是否匹配这个状态模型?             │
│   - New 状态的卡片何时转为 Learning?                     │
│     → 推荐: 首次复习评分后自动转 Learning               │
│   - 如果 fsrs crate 不支持独立状态管理，需手动维护状态   │
└─────────────────────────────────────────────────────────┘
```

### N6: 复习交互 + 验证

```
┌─────────────────────────────────────────────────────────┐
│ Node N6: 复习交互 (客户端驱动 + 后端验证)              │
│                                                         │
│ 位置: Flutter (N6a翻牌 + N6b打字UI) + 后端 (AI问答)     │
│ 新开发 (CoEvo 独有核心功能)                              │
│                                                         │
│ N6a 翻牌 (Flutter):                                     │
│   显示 front → 用户回忆 → 点击翻转 → 显示 back + source │
│   UI 状态: { card, isFlipped, startTime }              │
│                                                         │
│ N6b 验证 (两路径):                                      │
│                                                         │
│ 路径 1 — 语言类 (本地):                                 │
│   card_type == "vocabulary"                            │
│   Flutter 本地:                                        │
│     - 看词写释义: 显示 front, 输入 back                │
│     - 看释义写词: 显示 back, 输入 front                │
│     - 文本匹配: trim + lowercase + 标点归一化           │
│   → 匹配 → pass, 不匹配 → fail (显示正确答案)           │
│   ❌ 不需要后端/LLM                                    │
│                                                         │
│ 路径 2 — 通用类 (后端 LLM, 优化: 仅2次API):           │
│   card_type == "concept"                               │
│   Step 1: POST /api/review/verify                       │
│     { card_id, card_front, card_back }                 │
│     → LLM 批量生成 3 个问题 + 答案                      │
│     → 返回 [{question, expected_answer},...]           │
│                                                        │
│   Step 2: Flutter 依次展示问题，收集所有用户答案         │
│     (本地 UI，无 LLM)                                  │
│                                                        │
│   Step 3: POST /api/review/judge (仅1次调用)            │
│     { card_id, questions: [                             │
│        {q, expected, user_answer},...] }               │
│     → LLM 一次性批量判断全部 3 题                       │
│     → 返回 [{correct: bool, feedback: str},...]        │
│     → 计分: ≥2 correct → pass; <2 → fail               │
│                                                         │
│ N6c 评分:                                               │
│   POST /api/review/submit                              │
│   { card_id, rating: 1|2|3|4,                         │
│     verification_type, verification_result }           │
│                                                         │
│   后端:                                                 │
│     1. FSRS.repeat(card_memory, rating) → new_state     │
│     2. UPDATE card_memory SET ...                      │
│     3. INSERT INTO review_log (...)                    │
│     4. 触发 N7 成就检测                                │
│                                                         │
│ ❓ 需要确认:                                             │
│   - AI 问答是逐个提问还是一次性全部提问?                 │
│     → 推荐: 批量生成3问 + 逐个展示 + 逐个判断            │
│     优点: 只需2次LLM调用 (生成+判断×3=4次总计)            │
│     备选: 一次生成+一次批量判断 = 2次LLM调用            │
│   - 打字验证的模糊度? 大小写不敏感 + 标点忽略足够?       │
│   - rating 映射: pass→Good(3), fail→Again(1)            │
│     那什么时候用 Hard(2) 和 Easy(4)?                     │
│     → 对CoEvo, 暂时简化: 只用 Good(3) 和 Again(1)      │
└─────────────────────────────────────────────────────────┘
```

### N7: 成就检测

```
┌─────────────────────────────────────────────────────────┐
│ Node N7: 成就检测                                        │
│                                                         │
│ 位置: 后端 Rust (growth_engine/achievements.rs)        │
│ 复用: 适配 LinguaFlow achievements.rs                   │
│                                                         │
│ 触发点:                                                 │
│   - N4 卡片入库成功后                                    │
│   - N6c 复习评分后                                      │
│                                                         │
│ Input (从 DB 聚合):                                     │
│   AchievementContext {                                   │
│     user_id,                                            │
│     total_cards: u32,         // COUNT(*) FROM cards     │
│     total_reviews: u32,       // COUNT(*) FROM review_log│
│     streak_days: u32,         // FROM users              │
│     domains_covered: u32,     // COUNT(DISTINCT domain)  │
│   }                                                    │
│                                                         │
│ Logic:                                                  │
│   1. 读取 achievement_defs (硬编码或配置文件)             │
│   2. 读取 already_unlocked (FROM achievements)          │
│   3. 逐个检查条件:                                       │
│      - total_cards >= 1/50/200/500                     │
│      - streak_days >= 3/7/30                           │
│      - domains_covered >= 3/5                           │
│      - total_reviews >= 100/1000                       │
│   4. 过滤已解锁的                                       │
│   5. 写入新成就 INSERT INTO achievements               │
│                                                         │
│ Output:                                                 │
│   new_achievements: [{key, name, icon, unlocked_at}]    │
│   (返回给客户端做动画提示)                               │
│                                                         │
│ ⚠️ 注意:                                                │
│   LinguaFlow 的成就系统基于对话/概念/错误               │
│   CoEvo 需要改为基于卡片数/复习数/领域数                 │
│   条件解析器(parse_numeric_condition) 可直接复用         │
│   AchievementContext 字段需要调整                        │
└─────────────────────────────────────────────────────────┘
```

### N8: 学习计划 (结构化学习)

```
┌─────────────────────────────────────────────────────────┐
│ Node N8: 学习计划 (对话内结构化学习)                      │
│                                                         │
│ 位置: 后端 Rust (ws.rs 对话内处理)                       │
│                                                         │
│ 触发: LLM 检测学习意图 → 用户确认                         │
│                                                         │
│ 刚体流程:                                                │
│                                                         │
│ 用户:"我想学XX"                                          │
│   → LLM 确认 + 输出 <plan_update> JSON                   │
│   → 后端解析 JSON（含 is_new_plan + stages/tasks）       │
│   → INSERT INTO learning_plans (绑定 conversation_id)    │
│   → render_plan() 渲染为对话文本                         │
│   → 发 done + plan_updated WS 事件                       │
│                                                         │
│ 后续对话:                                                │
│   → prompt 注入学习上下文 (长期目标/当前阶段/任务状态)    │
│   → LLM 教学 + 输出 <plan_update> 更新进度               │
│   → 后端解析 → UPDATE plan_json + achievements           │
│   → plan_updated WS 事件 → Flutter 刷新面板              │
│                                                         │
│ 流式拦截:                                                │
│   检测到 <plan_update 标签 → 停止转发 token              │
│   发 planning 事件 → Flutter 显示"计划制定中……"           │
│                                                         │
│ 截断保护:                                                │
│   找到 <plan_update 但找不到 > 或 </plan_update>         │
│   → truncate(start) 删掉垃圾，不写数据库                  │
│                                                         │
│ DB 表:                                                   │
│   learning_plans (id, user_id, conversation_id,          │
│     goal, domain, mode, plan_json, created_at, updated)  │
│                                                         │
│ 成就绑定:                                                │
│   task done → bronze/"任务名入门"                        │
│   stage done → silver/"阶段名精英"                       │
│   domain done → gold/"领域大师"                          │
│   cross-domain → platinum/"目标宗师"                     │
└─────────────────────────────────────────────────────────┘
```

### Flow E: 跳过管理

```
┌─────────────────────────────────────────────────────────┐
│ Flow E: 跳过管理 (附属于 Flow B)                         │
│                                                         │
│ 写入:                                                   │
│   POST /api/cards/skip                                  │
│   { user_id, front, domain, source_text }              │
│   → INSERT INTO skipped_concepts                        │
│                                                         │
│ 自动移除 (用户主动制卡时):                               │
│   N4 入库前检查:                                        │
│   IF front 匹配 skipped_concepts                        │
│   → DELETE FROM skipped_concepts                        │
│   → 继续正常入库流程                                     │
│                                                         │
│ 读取 (管理页面):                                        │
│   GET /api/cards/skipped?user_id=xxx                    │
│   → SELECT * FROM skipped_concepts                      │
│                                                         │
│ 取消跳过:                                               │
│   DELETE /api/cards/skipped/{skip_id}                    │
│   → 移除跳过记录 → 同时重新创建卡片并加入复习队列         │
│   → 概念立即出现，不等后续对话                           │
│                                                         │
│ ⚠️ 数据一致性问题:                                       │
│   front 是用户写的自由文本，可能和LLM提取的front不同     │
│   例如: 用户跳过 "machine learning"                     │
│   LLM 提取 "machine learning" → 应该能匹配              │
│   解决: 去重时用 LOWER(front) 做精确匹配                 │
│   ❓ 是否需要更模糊的匹配?                               │
└─────────────────────────────────────────────────────────┘
```

---

## 三、用户会话流转 (完整时序)

```
用户启动App
    │
    ▼
┌──────────┐     ┌──────────┐     ┌──────────┐
│ 登录/注册 │ ──→ │ 对话主页  │ ──→ │ AI 对话  │
└──────────┘     └──────────┘     └────┬─────┘
                                       │
                    每轮对话结束后        │
                    (后台ColdPath)       │
                         ┌──────────────┘
                         ▼
                  ┌──────────────┐
                  │ N2 概念提取   │
                  │ (后台静默)    │
                  └──────┬───────┘
                         │
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
                  ┌────▼────┐  skipped_
                  │ N4 入库  │  concepts
                  └─────────┘
                       │
                  ┌────▼────┐
                  │ N7 成就  │
                  │ (可能触发)│
                  └─────────┘


         复习循环 (用户主动点击"复习")
                       │
                       ▼
                ┌──────────────┐
                │ N5 到期队列   │
                │ GET /review  │
                └──────┬───────┘
                       │ cards[]
                       ▼
                ┌──────────────┐
                │ N6a 翻牌     │
                │ 单张全屏展示  │
                └──────┬───────┘
                       │
                 ┌─────┴─────┐
                 ▼           ▼
           vocabulary     concept
                 │           │
            N6b 打字    N6b AI问答
            (本地匹配)   (LLM 三联问)
                 │           │
                 └─────┬─────┘
                       ▼
                ┌──────────────┐
                │ N6c 评分     │
                │ POST /submit │
                └──────┬───────┘
                       │
                  ┌────▼────┐
                  │ N7 成就  │
                  │ (可能触发)│
                  └─────────┘
                       │
                 还有到期卡片?
                    │    │
                   是   否
                    │    │
                    ▼    ▼
              继续循环  "今日完成"
```

---

## 四、Seat-map: 数据存储位置

```
┌─────────────────────────────────────────────────────────────────┐
│                        SQLite                                   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ users                  (Auth)                        │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | username | password_hash | created_at           │       │
│  │                                  + streak_days?     │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ cards                  (Data)                        │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | user_id | domain | card_type | front | back    │       │
│  │     | source_sentence | created_at                  │       │
│  │ 🔗 N2 去重查询     🔗 N3 格式化输出                  │       │
│  │ 🔗 N5 复习队列     🔗 N6a UI展示                    │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ card_memory            (FSRS State, 1:1 cards)      │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ card_id | state | difficulty | stability | due      │       │
│  │         | last_review | reps | lapses               │       │
│  │ 🔗 N4 初始创建     🔗 N5 队列筛选                    │       │
│  │ 🔗 N6c 每次更新    🔗 FSRS.repeat()                 │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ review_log             (Audit Trail)                 │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | card_id | rating | verification_type           │       │
│  │    | verification_result | reviewed_at              │       │
│  │ 🔗 N6c 每次写入     🔗 N7 计数                       │       │
│  │ 🔗 N7 累计复习次数  (百炼/千锤)                      │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ achievements           (Progress)                    │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | user_id | achievement_key | unlocked_at         │       │
│  │ 🔗 N7 写入          🔗 客户端展示                    │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ skipped_concepts       (User Preferences)            │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | user_id | front | domain | source_text         │       │
│  │    | skipped_at                                     │       │
│  │ 🔗 N2 去重查询     🔗 用户跳过 UI                   │       │
│  │ 🔗 N4 自动移除 (用户主动制卡时)                      │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ conversation_turns     (Dialogue History)            │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | conversation_id | role | content               │       │
│  │    | created_at                                     │       │
│  │ 🔗 N1 每轮写入     🔗 N2 概念提取输入               │       │
│  │ 🔗 N1 最近10轮上下文                                │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ conversations          (Session)                     │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | user_id | turn_count | started_at              │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ learning_plans         (Learning Progress)           │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ id | user_id | conversation_id | goal | domain      │       │
│  │     | mode | plan_json | created_at | updated_at    │       │
│  │ 🔗 N8 创建/更新   🔗 对话 prompt 注入               │       │
│  │ 🔗 Flutter 面板   🔗 成就 (bronze~platinum)         │       │
│  └─────────────────────────────────────────────────────┘       │
│                                                                 │
│  ┌─────────────────────────────────────────────────────┐       │
│  │ user_preferences       (User Settings)               │       │
│  │ ─────────────────────────────────────────────────── │       │
│  │ user_id | key | value | updated_at                   │       │
│  │ 🔗 偏好同步 (TTS语速、朗读开关等)                     │       │
│  └─────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、API 契约

### REST Endpoints

| Method | Path | Node | Request | Response |
|:--|:--|:--|:--|:--|
| POST | `/api/auth/register` | - | `{username, password}` | `{user_id, token}` |
| POST | `/api/auth/login` | - | `{username, password}` | `{user_id, token}` |
| WS | `/ws` | N1 | `ChatRequest` (JSON) | `WsEvent` 流 |
| POST | `/api/cards/skip` | N2 | `{user_id, front, source_text}` | `{skipped_id}` |
| GET | `/api/cards/skipped` | - | `?user_id=xxx` | `{skipped: [...]}` |
| DELETE | `/api/cards/skipped/{skip_id}` | - | - | `{status: "restored", card_id: "..."}` (同时恢复为卡片) |
| GET | `/api/review/due` | N5 | `?user_id=xxx` | `{cards: [...], total_due, has_more}` |
| POST | `/api/review/verify` | N6b | `{card_id, front, back}` | `{questions: [{q, expected}]...}` |
| POST | `/api/review/judge` | N6b | `{card_id, questions: [{q,expected,user_answer}]}` | `{results: [{correct,feedback}], total_correct}` |
| POST | `/api/review/submit` | N6c | `{card_id, rating, vtype, vresult}` | `{new_state, next_due, achievements}` |
| POST | `/api/cards/batch-create` | N3+N4 | `{user_id, candidates: [{front,back,source_sentence,domain}]}` | `{created, duplicates, achievements}` |
| GET | `/api/cards/all` | - | `?user_id=xxx&q=&state=&domain=&sort=` | `{cards, total, state_counts, domains}` |
| GET | `/api/history` | N1 | `?user_id=xxx&conversation_id=xxx` | `{turns: [{role,content,...}]}` |
| GET | `/api/plans` | N8 | `?conversation_id=xxx` 或 `?user_id=xxx` | `{plans: [{id, goal, plan, mode}]}` |
| POST | `/api/plans` | N8 | `{user_id, goal, domain, plan_json}` | `{id, status}` |
| DELETE | `/api/plans/{plan_id}` | N8 | `?user_id=xxx` | `{status: "ok"}` (软删除) |

### WebSocket 协议 (HotPath / ColdPath 分离)

```
客户端 → 服务器:
{
  "user_id": "...",
  "conversation_id": "...",
  "message": "用户输入"
}

服务器 → 客户端 (HotPath，按顺序):
{"type":"thinking"}                       // 开始思考
{"type":"token","content":"..."}          // 流式token (计划生成时被 planning 替代)
{"type":"planning"}                       // 计划生成中，显示占位
{"type":"done","reply":"..."}             // 完成 —— 立即返回，不等概念提取
{"type":"plan_updated"}                   // 计划已更新，前端刷新面板

服务器 → 客户端 (ColdPath，异步推送):
{"type":"candidates",                     // 概念提取完成（1-3s 后）
  "candidates": [{"front":..., "back":..., "source_sentence":..., "domain":...}]}

{"type":"error","content":"..."}          // 错误
```

⚡ HotPath 和 ❄️ ColdPath 通过 `select!` 并发处理:

```
主循环:
  select! {
    ws.recv()   → 流式回复 → done → spawn(ColdPath)
    cold_rx     → candidates → 推送给客户端
  }
```

ColdPath 运行在 `tokio::spawn` 后台 task 中，不阻塞消息接收。
用户连续发消息时，每条消息立即被处理（不等前一条的 ColdPath 完成）。

### 词汇匹配 (新增，2026-05-08)

```
ColdPath 内:
  1. LLM 提取概念 (已有流程)
  2. 词库文本匹配:
     AI回复 → 分词 → 查 cefr_catalog.json (10万词)
     → 按难度降序排序 → 取前10个
     → 去重: 已有卡片/跳过记录/LLM已提取 → 跳过
     → domain: "general"|"grammar" → 改为 "vocabulary"
     → 与 LLM 结果合并 → 返回 candidates
```

词库文件: `backend/cefr_catalog.json` (从 LinguaFlow 复制)
词库加载: `chat_engine/src/word_bank.rs`
加载时机: 启动时一次性读入 `OnceLock<HashMap<String, CefrEntry>>`
匹配算法: O(n) 全量扫描 + HashSet 去重 + 多词复合匹配

---

## 六、数据流分析发现的问题与建议（实施后状态）

### 🔴 P0 问题 (已全部解决)

| # | 问题 | 状态 | 解决方案 |
|:--|:--|:--:|:--|
| 1 | **N2 的 LLM 提取只输出 front** — N3 需要 front+back+source+doman | ✅ | LLM prompt 返回完整结构 `[{front, back, source, domain}]` |
| 2 | **conversation_turns 表未在计划中出现** — N1 需要会话历史 | ✅ | 增加 `conversation_turns` + `conversations` 表 (6→8) |
| 3 | **users 表缺少 streak_days 字段** — N7 需要 | ✅ | 增加 `streak_days` + `last_active_date` |

### 🟡 P1 重要问题 (已全部解决)

| # | 问题 | 状态 | 解决方案 |
|:--|:--|:--:|:--|
| 4 | **FSRS 评分只用 Good/Again** | ✅ | MVP 简化策略，仅用 Good(3)/Again(1) |
| 5 | **New 状态卡片何时转 Learning** | ✅ | 首次复习评分后自动转 Learning |
| 6 | **AI 问答 LLM 调用次数** | ✅ | 批量生成(1次) → 收集答案(本地) → 批量判断(1次) = 2 次 |
| 7 | **N2 去重匹配策略** | ✅ | LOWER(front) 精确匹配 + 过滤占位文本 |

### 🟢 P2 采纳情况

| # | 建议 | 状态 |
|:--|:--|:--:|
| 8 | **N1 上下文: 5000 字滑动窗口** | ✅ 已实现 |
| 9 | **achievements 表加 name + icon** | ✅ 已实现 |
| 10 | **增加 daily_review_count 限制** | ⏭️ 已确认不需要 |

---

## 七、开发计划修正记录 (已全部实施)

### 修正 1: 表结构 (9 → 10 张表)
```
原计划 9 张表 → 增加 user_preferences
最终 10 张表: users, conversations, conversation_turns,
  cards, card_memory, review_log, achievements, skipped_concepts,
  learning_plans, user_preferences
```

### 修正 2: N2 节点输出结构
```
原: 输出"候选概念列表" (只说了 front)
改为: 输出 [{front, back, source_sentence, domain}]
```

### 修正 3: streak_days 持久化
```
users 表增加: streak_days, last_active_date
每次复习时更新签到逻辑
```

### 修正 4: 跳过记录匹配策略
```
LOWER(front) 精确匹配 + Jaro-Winkler > 0.85 模糊匹配
```

---

*文档版本: V2.1 (实施后)*
*日期: 2026-05-13*
*说明: 所有数据流分析发现的问题已在实施中解决*
