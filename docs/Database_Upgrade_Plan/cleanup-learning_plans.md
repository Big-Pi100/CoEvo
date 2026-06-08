# learning_plans 清理完成报告

> 2026-06-03 | 全部清理完成

## 清理结果

### Phase 1 (P0 — 修复功能) ✅
| 函数 | 修改内容 | 状态 |
|------|---------|------|
| `auto_revert` | 改为读写 `conversation_plans.plan_content` | ✅ |
| `analyze_plan_progress` (ColdPath 2) | 改为读 `conversation_plans.plan_content` | ✅ |
| `handle_plan_update` reading_update 路径 | 改为读写 `conversation_plans.plan_content` | ✅ |

### Phase 2 (P1 — 清理死代码) ✅
| 代码段 | 操作 | 状态 |
|--------|------|------|
| `upsert_learning_plan` `existing_plan` 查询 | 删除 | ✅ |
| `upsert_learning_plan` legacy 双写块 | 删除 | ✅ |

### Phase 3 (P3 — 注释更新) ✅
| 位置 | 旧内容 | 新内容 |
|------|--------|--------|
| `plan_handler.rs:5` | "创建/更新 learning_plans 表" | "创建/更新 conversation_plans + user_plan_progress" |
| `plan_handler.rs:110` | "apply_plan_mutations 只写 learning_plans" | "apply_plan_mutations 已写 conversation_plans" |
| `pipeline_router.rs:130` | "与 learning_plans.domain 对齐" | "与 conversation_plans.domain 对齐" |

### Phase 4 (P2 — 遗留兜底) ⏸ 保留
`build_plan_context` legacy `learning_plans` 回退路径保留（兼容旧数据，无功能影响）。

### Phase 5 (测试) ✅
| 测试 | 修改内容 | 状态 |
|------|---------|------|
| `test_auto_revert` | 从 `learning_plans` 迁移到 `conversation_plans` | ✅ |

### 废弃测试删除 ✅
| 文件 | 原因 |
|------|------|
| `e2e_live_llm_plan_lifecycle.rs` (~3200 行) | 30+ 处 learning_plans 引用 + 编译错误 |
| `e2e_learning_plan_lifecycle.rs` (~250 行) | 基于旧 learning_plans |
| `e2e_card_pipeline.rs` (~200 行) | 基于旧 learning_plans |

## 最终状态

- `cargo build` ✅ 0 errors
- `cargo test -p api_server --lib` ✅ **26/26 passed**
- 生产代码中 `learning_plans` 引用数: **15 → 1**（仅 `build_plan_context` 遗留兜底路径，P2 保留）
