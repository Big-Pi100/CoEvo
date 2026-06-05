# Phase C 后修复计划

> 2026-06-05 凌晨，基于 Phase B/C 重构后的全面审查。

---

## 已完成（Phase B + C + CP1/CP2 审查修复）

| # | 内容 | 状态 |
|:--|:------|:----:|
| B1 | schema.sql 重写（UUID PK、11 列 cards、无 plan_templates） | ✅ |
| B2 | auth.rs UUID + phone 校验 + phone_hash | ✅ |
| B3 | routes.rs 4 个 handler 重写 + HTTP chat_handler 删除 | ✅ |
| B4 | plan_handler.rs build_plan_context + normalize + 删管道 + 删 sub_steps 回写 | ✅ |
| B5 | ws.rs prompt 选择（prompt_mode 驱动） | ✅ |
| C1 | schema：cards 删 status + 加 task_key，card_memory 加 status | ✅ |
| C2 | 15+ 处 SQL `cards.status` → `card_memory.status` | ✅ |
| C3 | ws.rs CP1 写入（full UUID、删 status、补 task_key、status='pending'） | ✅ |
| C4 | copy_prebuilt_card + insert_card + update_card_status 同步新 schema | ✅ |
| C5 | API `cards/all` 补 user_id + 删死字段 | ✅ |
| — | HTTP `/api/chat` handler 删除 + 4 个旧 e2e 测试删除 | ✅ |
| — | `check_revert_signals` 删除，`auto_revert` 重写为 `/back` 精确匹配 | ✅ |

---

## 待修复

### P0 — 运行时错误或数据一致性问题

| # | 问题 | 文件 | 说明 |
|:--|:-----|:-----|:------|
| D1 | **`/plan` 命令** | `plan_handler.rs` + `ws.rs` | 新增 `/plan` 精确匹配，直接调用 CP2 创建计划（用户无计划时的兜底入口） |
| D2 | **`creation.md` 删 status 尾巴** | `prompts/plan/general/creation.md` | prompt 要求 LLM 输出 stage/task 的 status，V3 不需要（plan_content 不存状态，user_plan_progress 是权威） |
| D3 | **`creation.md` 删 `domain` 字段** | `prompts/plan/general/creation.md` | domain 不再在 schema 中使用，prompt 里不应再要求 LLM 输出 |
| D4 | **`signal.md` 格式优化** | `prompts/plan/general/signal.md` | 确认 `{final_reply}` 替换正确；考虑是否需按 subject 定制 |

### P1 — 架构优化

| # | 问题 | 文件 | 说明 |
|:--|:-----|:-----|:------|
| P1-1 | **旧管道 fallback 代码删除** | `plan_handler.rs:1618-1695` | 管道 A/B/C（vocab_/reading_/k12_ 前缀）全是死代码，V3 数据无旧字段，触发了也 SQL 报错 |
| P1-2 | **`reading_loader.rs` 删除** | `reading_loader.rs` | 仅被旧管道引用，删除旧管道后可删 |
| P1-3 | **`curriculum_loader.rs` 部分函数清理** | `curriculum_loader.rs` | `get_cards()`, `get_card_by_id()` 等功能仅被旧管道引用 |
| P1-4 | **`analyze_plan_progress()` 死代码** | `plan_handler.rs:~1069-1370` | 完整 LLM 分析路径 + 客观通过率覆盖，无调用方 |
| P1-5 | **`auto_advance_check()` 死代码** | `plan_handler.rs:785-855` | 无调用方 |

### P2 — 清理/维护

| # | 问题 | 文件 | 说明 |
|:--|:-----|:-----|:------|
| P2-1 | **`load_chat_context()` 死代码** | `routes.rs:251` | 仅被已删除的 HTTP chat_handler 使用 |
| P2-2 | **`save_assistant_turn()` 死代码** | `routes.rs:364` | 同上 |
| P2-3 | **`ChatInput` struct 死代码** | `routes.rs:213` | 同上 |
| P2-4 | **`build_user_content()` 死代码** | `routes.rs:293` | 同上（ws.rs 有独立的 user_content 构建逻辑） |
| P2-5 | **`schedule_based_auto_advance` 相关代码** | `main.rs:852` | StageBinding 相关死代码 |
| P2-6 | **旧数据文件清理** | `data/curriculum/prebuilt/` | Phase D 遗留：`plans/`、`reading_plans/`、`cards/` 旧目录 |
| P2-7 | **`all_cards_query` 的 `subject` 分支** | `routes.rs:814` | `AllCardsQuery.subject` 作为请求参数仍然存在（已不用于查询），可选移除 |

---

## 执行顺序

| 步骤 | 内容 | 预估 |
|:-----|:------|:----:|
| 1 | **`/plan` 命令**：ws.rs 入口 + `plan_handler.rs` 函数（直接调 `analyze_turn_progress` 无 plan 分支） | 20min |
| 2 | **Prompt 清理**：`creation.md` 删 status/domain | 5min |
| 3 | **删旧管道 + reading_loader**：删 `unlock_next_cards` 管道 A/B/C + 删 `reading_loader.rs` 模块 + 删 `curriculum_loader` 未用函数 | 20min |
| 4 | **删死代码**：`analyze_plan_progress` / `auto_advance_check` / `load_chat_context` / `save_assistant_turn` / `ChatInput` / `build_user_content` | 15min |
| 5 | **Phase D 清理**：旧数据文件 + main.rs StageBinding + 旧 JSON | 10min |
| 6 | **测试**：全部单元 + e2e 三场景 | 40min |
| **总计** | | ~1.5h |
