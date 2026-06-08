# Cargo Warnings 分析报告

**日期**: 2026-06-08  
**分析范围**: `api_server` crate  
**总警告数**: 9  

---

## 1. routes.rs:14 — 未使用的导入

```rust
use crate::curriculum_loader;
```

| 字段 | 值 |
|:--|:--|
| 位置 | `routes.rs:14` |
| 详情 | 该 import 声明了但未使用。代码中实际引用处 `routes.rs:2148` 使用的是 `crate::curriculum_loader::k12_data_dir()` 完整路径，绕过了 import。 |
| 根因 | import 路径与引用路径不一致 |
| 修复 | **建议选一**：A) 删除第 14 行 import；B) 将 2148 行改为 `curriculum_loader::k12_data_dir()` |
| 优先级 | P1（代码整洁） |

---

## 2. plan_handler.rs:232 — 未使用变量 `now`

```rust
let now = chrono::Utc::now().timestamp();
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:232`，函数 `apply_plan_update` |
| 详情 | 计算了当前时间戳但后续从未使用此变量。该函数的剩余代码只操作 JSON 的 `plan` 对象，不涉及时间戳。 |
| 根因 | 大概率是早期版本需要时间戳，重构后不再需要但遗留了声明。 |
| 修复 | 前缀 `_now` 或删除。 |
| 优先级 | P1（代码整洁） |

---

## 3. plan_handler.rs:247 — 未使用变量 `domain`

```rust
let domain = String::new();
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:247`，函数 `apply_plan_update` |
| 详情 | 分配了一个空字符串，上方注释明确说明："domain 不再等于 conversation_id，改为 ""（通用）"，以及 "真正的学科路由信息从 pipeline_domain 字段读取"。这是有意为之的遗留代码，但变量 `domain` 从未被引用。 |
| 根因 | 重构遗留。`domain` 原来是用于构建 plan_content JSON 的，后来 domain 逻辑移到了 `pipeline_router.rs`。 |
| 修复 | 删除第 247 行。 |
| 优先级 | P1（代码整洁） |

---

## 4. plan_handler.rs:269 — 未使用变量 `task_status_str`

```rust
let task_status_str = serde_json::json!({"task_status": task_status_val}).to_string();
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:269`，函数 `apply_plan_update` |
| 详情 | 用 `task_status_val` 构建了一个 JSON 字符串，但只有 `task_status_val` 本身在后续被引用（作为 `plan["task_status"]`），`task_status_str` 从未使用。 |
| 根因 | 重构遗留。可能早期需要序列化的字符串，后来改为直接使用 `task_status_val` 的 Value 对象。 |
| 修复 | 删除第 269 行。 |
| 优先级 | P1（代码整洁） |

---

## 5. plan_handler.rs:1234 — 未使用变量 `goal`

```rust
let (goal, plan_content_str) = match conn.query_row(...) { ... };
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:1234`，`'task_name` 代码块 |
| 详情 | 从 `conversation_plans` 表查询返回 `(goal, plan_content_str)`，但 `goal` 变量后续从未被引用。只用了 `plan_content_str`。 |
| 根因 | SQL 的 SELECT 中包含了 `goal` 列，解构时顺便取了但不用。 |
| 修复 | 改为 `let (_goal, plan_content_str)` 或 `let (_, plan_content_str)`，甚至可考虑从 SELECT 中删除 `goal` 列（需要确认其他调用场景）。 |
| 优先级 | P1（代码整洁） |

---

## 6. plan_handler.rs:1346 — 未使用变量 `now_ts`

```rust
let now_ts = chrono::Utc::now().timestamp();
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:1346`，函数末尾 |
| 详情 | 在当前函数的剩余代码中（~100 行）从未引用 `now_ts`。函数主要在操作 card_ids 和 stage 卡片激活。 |
| 根因 | 与 #2 类似，`now_ts` 在 `apply_plan_update` 中也有同名变量（也是未使用），在 `activate_next_task` 里又是同样模式。可能是模板式复制遗留。 |
| 修复 | 前缀 `_now_ts` 或删除。 |
| 优先级 | P1（代码整洁） |

---

## 7. plan_handler.rs:1531 — 未使用参数 `conn`

```rust
pub fn activate_stage_cards(
    conn: &rusqlite::Connection,  // ← 未使用
    user_id: &str,
    _plan_type: &str,             // ← 已有正确的前缀下划线
    plan_id: &str,
    stage_name: &str,
)
```

| 字段 | 值 |
|:--|:--|
| 位置 | `plan_handler.rs:1531`，函数 `activate_stage_cards` |
| 详情 | 函数接受了 `conn` 参数但函数体内从未使用。对比同函数的 `_plan_type` 参数正确地加了前缀下划线。 |
| 根因 | 该函数内部通过 `crate::db_pool::get_conn()` 取自己的连接，没有复用传入的 `conn`。需要确认函数签名是否应该去掉该参数（clippy 可能警告公共 API 变更），或函数体改用传入的连接。 |
| 修复 | **选一**：A) 参数名前缀 `_conn`；B) 函数体改用 `conn` 而不是函数内重新获取。保守修复选 A。 |
| 优先级 | P1（代码整洁） |

---

## 8. curriculum_loader.rs:151 — `count_before` 不需要 `mut`

```rust
let mut count_before = plan_index.len();
```

| 字段 | 值 |
|:--|:--|
| 位置 | `curriculum_loader.rs:151` |
| 详情 | `count_before` 只被赋值一次，后续只有读取（用于比较 `plan_index.len() > count_before`），从未重新赋值，不需要 `mut`。 |
| 根因 | 纯粹的 `mut` 冗余。 |
| 修复 | 去掉 `mut`。 |
| 优先级 | P2（轻微） |

---

## 9. ws.rs:453 — 未使用变量 `cold_turn`

```rust
let cold_turn = current_turn;
```

| 字段 | 值 |
|:--|:--|
| 位置 | `ws.rs:453`，ColdPath CP1 处理块 |
| 详情 | 第 453 行声明了 `cold_turn`，但在第 468 行被另一个 `let cold_turn = current_turn;` 遮蔽之前从未使用过。第 468 行的 `cold_turn` 是真正被传入 spawn 的变量。 |
| 根因 | 变量声明冗余。第 453 行可能是在重构过程中提前声明的初版代码，后续增加了第 468 行的新声明导致遮蔽。 |
| 修复 | 删除第 453 行。 |
| 优先级 | P1（代码整洁） |

---

## 汇总

| # | 文件 | 类型 | 严重度 | 修复难度 | 建议操作 |
|:-:|:--|:--|:--:|:--:|:--|
| 1 | routes.rs | 未使用导入 | P1 | 低 | 删除 import 或改用短路径 |
| 2 | plan_handler.rs:232 | 未使用变量 (`now`) | P1 | 低 | 前缀下划线或删除 |
| 3 | plan_handler.rs:247 | 未使用变量 (`domain`) | P1 | 低 | 删除整行 |
| 4 | plan_handler.rs:269 | 未使用变量 (`task_status_str`) | P1 | 低 | 删除整行 |
| 5 | plan_handler.rs:1234 | 未使用变量 (`goal`) | P1 | 低 | 前缀下划线 |
| 6 | plan_handler.rs:1346 | 未使用变量 (`now_ts`) | P1 | 低 | 前缀下划线或删除 |
| 7 | plan_handler.rs:1531 | 未使用参数 (`conn`) | P1 | 低 | `_conn` 或改用传入连接 |
| 8 | curriculum_loader.rs:151 | 冗余 `mut` | P2 | 极低 | 去掉 `mut` |
| 9 | ws.rs:453 | 未使用变量 (`cold_turn`) | P1 | 低 | 删除整行 |

**结论**: 9 个警告全部属于**代码整洁**范畴，无功能性风险。其中 5 个集中在 `plan_handler.rs`（重构遗留变量）。全部修复风险极低，`cargo fix` 可自动处理大部分（建议 `cargo fix --lib -p api_server`）。
