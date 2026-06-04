# 卡片状态管理修复计划

> 2026-06-04 晚，基于 Phase B 重构后的全面审查发现。
> 目标：整理剩余问题，分 Phase 逐步修复。

---

## 问题总览

| # | 问题 | 严重度 | 涉及文件 |
|:-:|:-----|:------|:---------|
| C1 | `status` 列在 `cards` 表 → 应移至 `card_memory` | P0 | 两个 schema.sql + 6 处 SQL 查询 |
| C2 | `cards` 缺 `task_key` 列 → 卡片→任务关联断裂 | P0 | 两个 schema.sql + ws.rs CP1 写入 + init handler |
| C3 | CP1 写入 `status='active'` → 绕过用户确认 | P0 | ws.rs CP1 INSERT |
| C4 | `GET /api/cards/all` 缺 `user_id` 字段 | P1 | routes.rs cards_all_handler |
| C5 | `AllCardsQuery.subject` 死参数字段 | P2 | routes.rs AllCardsQuery |
| C6 | `cards_all_handler` 的 SQL 仍 INNER JOIN card_memory | P2 | routes.rs cards_all_handler |
| — | Phase D: 清理旧 loader + 旧 JSON | P1 | 多个文件 |

---

## 详细分析与修复方案

### C1: `status` 列迁移（cards → card_memory）

**原则：** `cards` 只存不可变结构数据，状态由 `card_memory` 管理。与 `plan_content` / `user_plan_progress` 的分工一致。

**当前 schema：**
```sql
-- cards
status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','pending','skipped','archived'))

-- card_memory
state INTEGER DEFAULT 0,  -- FSRS: New/Learning/Review/Relearning
```

**目标 schema：**
```sql
-- cards: 删 status 列
id, user_id, domain, card_type, front, back, source_sentence, created_at, conversation_id, plan_id, task_key

-- card_memory: 加 status 列
card_id, state, status, difficulty, stability, due, last_review, reps, lapses
status CHECK(status IN ('active','pending','skipped','archived'))
```

**受影响的所有 SQL 查询（6处）：**

| 位置 | 当前 | 改后 |
|:-----|:-----|:------|
| `routes.rs:849` `cards/all` | `WHERE c.status = 'active'` | `WHERE cm.status = 'active'` |
| `card_engine/fsrs_scheduler.rs:50` due cards | `AND c.status = 'active'` | `AND cm.status = 'active'` |
| `card_engine/fsrs_scheduler.rs:82` due | `AND c.status = 'active'` | `AND cm.status = 'active'` |
| `routes.rs:1241` vocab mastery | `AND c.status = 'active'` | `AND cm.status = 'active'` |
| `routes.rs:2132` k12_progress | `c.status = 'archived'` | `cm.status = 'archived'` |
| `card_repository.rs:139` batch_update | `UPDATE cards SET status` | `UPDATE card_memory SET status` |

**影响范围：**
- ws.rs CP1 INSERT（写 `status` 到 card_memory 而不是 cards）
- plan_handler.rs copy_prebuilt_card INSERT（同上）
- 所有测试中的 cards INSERT（删 status 参数）

---

### C2: 新增 `task_key` 列

**目的：** 每张卡片知道它属于哪个 task（计划阶段的子任务），与 `user_plan_progress` 直接关联。

```sql
ALTER TABLE cards ADD COLUMN task_key TEXT;
```

**写入时机：**
- K12 init：从 v3 JSON 的 stage→task 结构读取 `task_key`，写入预置卡
- Reading init：同上
- CP1：从当前 `build_plan_context()` 找到 in_progress task 的 `task_key`
  - 当前 WS 已有 `build_plan_context()` 返回的 domain/mode/ctx
  - 需额外从 plan_content 中提取当前 in_progress 的 `task_key`

---

### C3: CP1 status 流修复

**当前问题：**
```
ws.rs: INSERT INTO cards (..., status, ...) VALUES (..., 'active', ...)
         ↓
前端: 用户确认→batchUpdateStatus('active')   ← 空操作，已经是 active
前端: 用户跳过→updateCardStatus('skipped')    ← 有效
```

**目标流程（原则：卡片不入库则不进入复习队列）：**
```
ws.rs: INSERT INTO cards + card_memory (status='pending')
         ↓
WS 发送 candidates 事件（含 card_id）
         ↓
前端 ConceptDialog 展示，用户选择
  ├─ 确认 → PATCH /api/cards/batch-status {ids, 'active'}
  └─ 跳过 → PATCH /api/cards/status {id, 'skipped'}
         ↓
所有未处理的 pending 卡片：下次复习请求时过滤掉
```

**配套改动：**
- `ws.rs` CP1 INSERT: `status` 列改到 `card_memory`，默认 `'pending'`
- `fsrs_scheduler.rs`: 筛选 due cards 时加 `AND cm.status = 'active'`（已索引）
- 前端 Dialog: 逻辑不变，后端适配即可

---

### C4: API 补 `user_id`

```diff
-- routes.rs cards_all_handler SELECT
+ c.user_id
-- response JSON
+ "user_id": row.get::<_, String>(14)?
```

---

### C5: 清理死字段

```diff
- pub subject: Option<String>,
```

---

## 执行顺序

| 阶段 | 内容 | 预估 |
|:-----|:------|:----:|
| **C-Phase 1** | 两个 schema.sql 改 DDL（cards 删 status + 加 task_key，card_memory 加 status） | 15min |
| **C-Phase 2** | 修复所有 SQL 查询（6处 status 迁移 + task_key 补齐） | 20min |
| **C-Phase 3** | 修复 CP1 ws.rs 写入流（status → pending + plan_id/task_key） | 15min |
| **C-Phase 4** | 修复 copy_prebuilt_card 写入（同步 schema） | 10min |
| **C-Phase 5** | API 补 user_id + 删死字段 | 5min |
| **C-Phase 6** | 修复计划期未使用的测试（e2e_main 等） | 10min |
| **C-Phase 7** | 跑 full test suite + 3 场景 e2e | 30min |
| **总计** | | ~1.5h |

---

## 未解决的架构问题（待讨论）

| 问题 | 描述 |
|:-----|:------|
| `plan_id` 是否冗余 | 已有 `conversation_id`，可 JOIN `conversation_plans` 找到 plan。但 `plan_id` 作反规范化可避免 JOIN，保留。 |
| `card_memory` INNER JOIN 性能 | `cards/all` 用 INNER JOIN card_memory，如果 card_memory 缺失则卡片不返回。这是设计意图（无状态则无卡片）。 |
| `cards_all_handler` 无分页 | 大用户场景可能需要分页，当前无 pagination。 |
