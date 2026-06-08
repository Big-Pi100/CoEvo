# 跨用户/跨会话 ID 冲突排查报告

> 生成日期: 2026-06-04
>
> 排查起因: 修复 `k12_plan_id` 跨用户冲突后发现 —— `plan_id` 使用 `format!("{}_plan", subject)` 导致所有用户共享同一 ID，`INSERT OR IGNORE` 静默失败，后续用户的 plan 面板不显示。

---

## 排查范围

扫描 `backend/crates/api_server/src/` 下所有使用了 `format!("..._plan", subject)` 或类似模式的硬编码 ID 构造模式，重点查找：

- 用共享值（subject、grade 等）而非唯一值（UUID、conv_id）构造的 ID
- 不按 user_id 过滤的跨表查询/更新
- `INSERT OR IGNORE` 配合共享 ID 的静默失败风险

---

## 发现总览

| # | 问题 | 位置 | 严重性 | 类型 |
|:-|:-----|:-----|:------|:-----|
| 1 | `k12_plan_id` 跨用户共享 → 已修复 | `routes.rs:1798,1862,2037` | P0 | **已修复** |
| 2 | `build_plan_context` progress 查询缺 user_id 过滤 | `plan_handler.rs:927` | P1 | 预存 |
| 3 | `activate_stage_cards` 更新缺 user_id 过滤 | `plan_handler.rs:1921` | P1 | 预存 |
| 4 | K12 progress plan_id 与 conversation_plans.id 不一致 | `plan_handler.rs:381,927` | P2 | 设计 |

---

## 详细分析

### 问题 1: k12_plan_id 跨用户共享（P0 ✅ 已修复）

**位置**: `routes.rs:1798, 1862, 2037`

**根因**:
```rust
// 改前 — 所有用户共用同一个 plan_id
let k12_plan_id = format!("k12_{}_plan", input.subject);  // "k12_math_plan"
```

**影响**: 使用 `INSERT OR IGNORE` 写 `conversation_plans` 表时，第二个用户调用 `k12/init` 的 INSERT 被静默忽略，该用户的 conversation 没有关联 plan → 前端 `_loadPlan()` 返回空列表 → plan 面板不显示。

**修复**:
```rust
// 改后 — 每个会话唯一
let k12_plan_id = format!("k12_{}_plan_{}", input.subject, conv_id);  // "k12_math_plan_conv-uuid"
```

---

### 问题 2: `build_plan_context` progress 查询缺 user_id 过滤（P1）

**位置**: `plan_handler.rs:925-929`

**代码**:
```rust
// K12 路径：读取 user_plan_progress
let mut stmt = conn.prepare(
    "SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1"
).unwrap();
stmt.query_map(rusqlite::params![format!("{}_plan", subject_key)], |row| {
    ...
```

**问题**: 不按 `user_id` 过滤。用户 A 和用户 B 做同一个科目时，两人的进度行都会被返回。HashMap 用 `task_key` 去重时，取决于数据库返回顺序，可能 A 的进度覆盖 B 的，反之亦然。

**修复**: 加 `AND user_id = ?2`：
```rust
"SELECT task_key, status FROM user_plan_progress WHERE plan_id = ?1 AND user_id = ?2"
```

**注意**: 函数签名需要额外传入 `user_id`。

---

### 问题 3: `activate_stage_cards` 更新缺 user_id 过滤（P1）

**位置**: `plan_handler.rs:1920-1923`

**代码**:
```rust
pub fn activate_stage_cards(conn, plan_type, plan_id, stage_name) {
    conn.execute(
        "UPDATE cards SET status = 'active'
         WHERE plan_type = ?1 AND plan_id = ?2 AND stage_name = ?3 AND status = 'archived'"
    );
}
```

**问题**: 不加 `user_id` 过滤。用户 A 推进到下一 stage 时，会激活所有用户下该 stage 的预置卡片。如果两个用户在同一科目且到达同一 stage，A 的推进会帮 B 也激活卡片。

**修复**: 加 `user_id` 参数 + `AND user_id = ?4`。

---

### 问题 4: K12 progress plan_id 与 conversation_plans.id 不一致（P2）

**位置**: `plan_handler.rs:381, 927`

**现状**: 修复后 `conversation_plans.id` = `"k12_math_plan_conv-uuid"`，但 K12 路径内部写入/读取 `user_plan_progress` 仍使用 `"math_plan"`（不带 `k12_` 前缀和 conv_id 后缀）。

**影响**:
- K12 内部读写一致（都用 `"math_plan"`）→ 功能正常
- 外部代码通过 `conversation_plans.id` 查 `user_plan_progress`（如 e2e 测试的 report 生成）→ 找不到进度

**修复**: `build_plan_context` 的 K12 路径改用 `conversation_plans.id` 作为 `user_plan_progress.plan_id`，与 conversation_plans 条目标对齐。同时确保写入 progress 的 plan_id 也同步更新。

---

## 非问题确认

以下模式排查后确认安全：

| 位置 | 代码 | 原因 |
|:-----|:-----|:-----|
| `curriculum_loader.rs:154` | `format!("{}_plan", subject)` | 仅用于内存中 plan_templates 的 key，不持久化到 DB |
| `plan_handler.rs:1833` | `format!("{}_plan", subject)` | 配合 `activate_stage_cards` 使用，与问题 3 关联自动修复 |
| `reading_loader.rs:196` | `format!("{}_reading_plan", subject_key)` | plan_templates 的内存 key |
| `routes.rs:1986` | `format!("{}_reading_plan", subj_key)` | reading_init 返回给前端的 plan ID，不写入 DB |
| `plan_handler.rs:347` 以下 | `DELETE FROM user_plan_progress WHERE plan_id = ?1` | 只删除当前 conversation 对应的 progress |

---

## 建议修复优先级

| 优先级 | 问题 | 工作量 | 说明 |
|:------|:-----|:------|:------|
| P0 | 问题 1 | ✅ 已完成 | plan 面板不显示，阻塞用户 |
| P1 | 问题 2 + 3 | 0.5 天 | 跨用户数据污染，A 用户看到 B 的进度 |
| P2 | 问题 4 | 0.5 天 | K12 progress plan_id 对齐，修复 e2e 报告兼容性 |
