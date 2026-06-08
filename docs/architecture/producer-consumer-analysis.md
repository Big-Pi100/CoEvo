# 数据流生产者→消费者全链路分析

> 2026-06-02
> 方法：从业务入口开始，逐表追踪数据产生（INSERT）→ 消费（SELECT/JOIN）→ 断链识别

---

## 一、业务入口概述

系统有三大业务入口，四条数据流：

```
入口1: K12 (数学/语文/英语...)
  └─ k12_init_handler ─→ conversations + learning_plans + cards + card_memory
       └─ ws.rs ─→ conversation_turns + cards(CP1) + card_memory

入口2: 自由对话
  └─ ws.rs ─→ conversation_turns + conversation_plans + user_plan_progress + cards(CP1) + card_memory

入口3: 阅读模式
  └─ k12_reading_init_handler ─→ conversations + learning_plans + cards + card_memory
       └─ ws.rs ─→ conversation_turns + cards(CP1) + card_memory
```

---

## 二、入口1: K12 全链路追踪

### 2.1 `k12_init_handler` (routes.rs:1831)

**触发条件**: 用户选择科目(如"数学")→ 前端 POST `/api/k12/init`

#### 表1: `conversations`

| 字段 | 生产者 | 值来源 | 消费者 |
|------|--------|--------|--------|
| `id` | `uuid::new_v4()` | `routes.rs:1868` | k12_init 重复检测 (`WHERE subject+grade_band`, :1849) |
| | | | `cards_all_handler` JOIN, 间接 |
| `user_id` | `input.user_id` | `routes.rs:1872` | 同上 |
| `started_at` | `now_str` | `routes.rs:1872` | 历史查询 |
| `subject` | `input.subject` | `routes.rs:1872` | k12_init 重复检测 (WHERE, :1849) |
| | | | `learning_plans` 迁移 (`CASE subject`, main.rs:882) |
| `grade_band` | `input.grade_band` | `routes.rs:1872` | k12_init 重复检测 |

#### 表2: `learning_plans`

| 字段 | 生产者 | 值来源 | 消费者 |
|------|--------|--------|--------|
| `id` | `uuid::new_v4()` | `routes.rs:1889` | **仅 learning_plans 内部使用** |
| `user_id` | `input.user_id` | `routes.rs:1919` | admin统计 |
| `conversation_id` | `conv_id` | `routes.rs:1919` | k12_init 重复检测 (INNER JOIN, :1851) |
| | | | `build_plan_context` 查 plan (plan_handler:1088) |
| | | | `k12_init` DELETE 清理 (1915) |
| `goal` | `plan.goal` | `routes.rs:1919` | history_handler (子查询, :946) |
| `domain` | `domain_val` | `routes.rs:1919` | — |
| `mode` | `'structured'` | hardcoded | plan_handler 查询 (`WHERE mode`, :460) |
| `plan_content` | `serde_json::to_string` | `routes.rs:1921` | `build_plan_context` (plan_handler:1088) |
| `task_status` | `serde_json::to_string` | `routes.rs:1920` | milestone_handler (:1500) |
| | | | `auto_revert` (plan_handler:1712) |
| | | | HTTP API `GET /api/plans` (:1319) |
| `created_at` | `now_ts` | `routes.rs:1921` | — |
| `updated_at` | `now_ts` | `routes.rs:1921` | — |

#### 表3: `cards` (预生成卡片)

| 字段 | 生产者 | 值来源 | 消费者 | 对齐? |
|------|--------|--------|--------|-------|
| `id` | `format!("k12_{}", card_tmpl.id)` | `:1961` | `cards_all_handler` JOIN card_memory | ✅ |
| `user_id` | `input.user_id` | `:1962` | `cards_all_handler` WHERE user_id | ✅ |
| `domain` | `domain_val.to_string()` | `:1962` | cards_all_filter WHERE domain | ✅ |
| `card_type` | `card_tmpl.card_type` | `:1963` | — | ✅ |
| `front` | `card_tmpl.front` | `:1963` | review/display | ✅ |
| `back` | `card_tmpl.back` | `:1963` | review/display | ✅ |
| `source_sentence` | `card_tmpl.source_sentence` | `:1963` | — | ✅ |
| `conversation_id` | `conv_id` | `:1963` | ✅ **有此列** | ✅ |
| `created_at` | `now_ts` | `:1963` | — | ✅ |
| `subject` | `input.subject` | `:1963` | cards_all_filter WHERE subject | ✅ |
| `grade_band` | `input.grade_band` | `:1963` | — | ✅ |
| `k12_card_id` | `card_tmpl.id` | `:1963` | — | ✅ |
| `origin` | `'prebuilt'` | hardcoded | Phase 4 迁移检查 | ✅ |
| **`status`** | **❌ 缺** | — | **cards_all_handler WHERE status='active'** (:733) | **❌ 缺** |
| **`plan_id`** | **❌ 缺** | — | **无此列** | **❌ 缺** |

#### 表4: `card_memory`

| 字段 | 生产者 | 值来源 |
|------|--------|--------|
| `card_id` | `同上 card_id` | `:1971` |
| `state` | `0` (hardcoded) | `:1971` |
| `difficulty` | `0.3` (hardcoded) | `:1971` |
| `stability` | `1.0` (hardcoded) | `:1971` |
| `due` | `now_ts` | `:1971` |
| `last_review` | `0` (hardcoded) | `:1971` |
| `reps/lapses` | `0` (hardcoded) | `:1971` |

**消费者**: `cards_all_handler` 在 `:726` 处 `JOIN card_memory cm ON c.id = cm.card_id`
(第 2 大消费者连接)

---

### 2.2 K12 对话 WS 流程 (ws.rs)

**触发条件**: k12_init 后用户发送消息 → WebSocket

#### 表: `conversation_turns`

| 字段 | 生产者 | 值来源 | 消费者 |
|------|--------|--------|--------|
| `id` | `uuid::new_v4()` | `routes.rs:273` | plan_handler 读历史 |
| `conversation_id` | `input.conversation_id` | `ws.rs:273` | history_handler WHERE |
| `role` | `'user'/'assistant'` | hardcoded | CP1 提取、学生 LLM prompt |
| `content` | 用户消息 / LLM 回复 | | 同上 |

#### 表: `cards` (CP1 提取)

**生产者**: `ws.rs:528-531` (ColdPath tokio::spawn)

| 字段 | 值来源 | 消费者 | 对齐? |
|------|--------|--------|-------|
| `id` | `format!("pend_{}", uuid)` | cards_all_handler | ✅ |
| `user_id` | `chat_req.user_id` | cards_all_handler WHERE | ✅ |
| `domain` | `c.domain` (CP1 输出) | cards_all_filter WHERE | ✅ |
| `card_type` | `'concept'` | — | ✅ |
| `front` | `c.front` (CP1 输出) | review | ✅ |
| `back` | `c.back` (CP1 输出) | review | ✅ |
| `source_sentence` | `c.source_sentence` | review | ✅ |
| `created_at` | `now` | — | ✅ |
| `status` | `'pending'` | cards_all_handler WHERE status='active' (:733) | ⚠️ pending≠active |
| **`conversation_id`** | **❌ 缺** | **无** | **❌ 断链** |
| **`subject`** | **❌ 缺** | **—** | **❌** |
| **`plan_id`** | **❌ 缺** | **—** | **❌** |

---

## 三、入口2: 自由对话全链路追踪

### 3.1 WS 对话 → CP2 创建计划

**触发条件**: 用户发消息 → CP2 检测到学习意图

#### 表: `conversation_plans` (plan_handler.rs:371)

| 字段 | 生产者 | 值来源 | 消费者 |
|------|--------|--------|--------|
| `id` | `uuid::new_v4()` | `:369` | user_plan_progress.plan_id (子查询, :123) |
| | | | plan_handler 读路径 (SELECT id WHERE conversation_id) |
| `user_id` | 函数参数 | `:371` | — |
| `conversation_id` | 函数参数 | `:371` | plan_handler 查对话 (WHERE, :364) |
| `goal` | LLM 生成 | `:268` | — |
| `domain` | `String::new()` | `:282` | — (始终空! 参见问题) |
| `plan_content` | LLM JSON | `:349` | build_plan_context 展开 tasks |
| `created_at` | `now_ts` | `:371` | — |
| `updated_at` | `now_ts` | `:371` | — |

#### 表: `user_plan_progress` (plan_handler.rs:417)

| 字段 | 生产者 | 值来源 | 消费者 |
|------|--------|--------|--------|
| `id` | `uuid::new_v4()` | `:415` | — |
| `user_id` | 函数参数 | `:417` | — |
| `plan_type` | `'conversation'` 或 `'k12'` | `:419` | — |
| `plan_id` | conversation_plans.id | `:378-393` | handle_plan_update 子查询 (:123) |
| `task_key` | `task_key` / `name` / 自动 | `:412-414` | handle_plan_update WHERE (:123) |
| `status` | `task["status"]` → default `'pending'` | `:409` | **所有读路径!** (plan_handler:1001, 1056) |
| `updated_at` | `now_ts` | `:417` | — |

---

## 四、关键消费者：`cards_all_handler` (routes.rs:711)

这是**前端复习页面的核心查询**，决定了卡片如何被筛选。

**当前 SQL**:
```sql
SELECT c.id, c.front, c.back, c.domain, c.card_type, c.source_sentence,
       c.created_at, cm.state, cm.difficulty, cm.due, cm.reps, cm.lapses,
       lrev.reviewed_at, lrev.rating, c.subject, c.grade_band,
       c.conversation_id
FROM cards c
JOIN card_memory cm ON c.id = cm.card_id
LEFT JOIN review_log lr ON ...
WHERE c.user_id = ?1 AND c.status = 'active'
  [AND c.domain = ?]  [AND c.subject = ?]  [AND cm.state = ?]
ORDER BY cm.state ASC, cm.due ASC
```

**需要的**:前端需要按计划筛选卡片 `WHERE plan_id = ?`。当前只能通过 `domain` 或 `subject` 粗略分组。

---

## 五、发现问题汇总

### 问题 1: CP1 卡片 (`ws.rs:528`) 无 conversation_id → 找不到来源会话
- 生产者有 `user_id`, `domain`, 无 `conversation_id`
- 消费者 `cards_all_handler` 返回 `conversation_id` 列为空
- 影响: K12 对话中的 CP1 卡片无法关联到科目

### 问题 2: K12 预生成卡片 (`:1963`) 无 `status` 列
- 消费者 `cards_all_handler` WHERE `status='active'`
- 生产环境 Phase N 迁移已加 `status` 设 `'active'`
- 但测试 schema 无此列 → test INSERT 失败

### 问题 3: 所有卡片均无 `plan_id`
- 前端需要按计划筛选卡片，当前只能按 `subject` 粗略分组
- 三个入口均有各自 plan(learning_plans.id / conversation_plans.id)
- 卡片与计划的关联要通过 `conversation_id → learning_plans/conversation_plans` 两步查询

### 问题 4: `user_plan_progress.plan_id` 无 FK，引用方式不一致
- CP2: `plan_id = conversation_plans.id` (UUID)
- K12: `plan_id = "{subject_key}_plan"` (派生字符串)
- 两种格式无法统一查询

### 问题 5: 双写覆盖仅 13%
- 15 处 learning_plans 写入，仅 2 处有新表对应

---

## 六、正向设计：正确的数据模型

基于业务需求 (K12 / 自由对话 / 阅读 → 计划 → 卡片 → 复习)，正确的关联应是：

```
conversations (id, user_id, subject?, grade_band?)
    │ conversation_id
    ├──────────────────────────────┐
    │                              │
learning_plans (K12)        conversation_plans (CP2)
    │ plan_id                      │ plan_id
    └──────────┬───────────────────┘
               │
        user_plan_progress
        (plan_id, task_key, status)
               │
        cards (user_id, conversation_id, plan_type, plan_id,
               subject, status, origin)
               │ card_id
          card_memory
          (FSRS state, due)
               │
          review_log
```

**要加的字段**:

| 表 | 加 | 原因 |
|----|----|------|
| `conversations` | 已有 | `subject`, `grade_band` 已有 |
| `cards` | `plan_type TEXT, plan_id TEXT` | 统一按计划筛选 |
| `cards` | (CP1) `conversation_id` | 补全断链 |
| `cards` | (K12预生成) `status` | 补全对齐 |
