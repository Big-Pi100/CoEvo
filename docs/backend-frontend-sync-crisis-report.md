# 前后端同步危机报告

> 2026-06-03 01:42 | 基于 `learning_plans` 废弃后的系统性断裂

## 根因

`learning_plans` 表被彻底移除后，其承载的两个职责没有完全承接：

| 职责 | 旧表 learning_plans | 新表 conversation_plans | 现状 |
|------|--------------------|------------------------|------|
| CP2 自由对话计划 | 写入 + 读取 | ✅ 部分写入（`upsert_learning_plan` 只写对话计划，无 K12） | ⚠️ 对话计划可写，但 K12 完全不写 |
| K12 预制计划 | 写入 + 读取 | ❌ **完全不写** | 🔴 断裂 |
| Reading 计划 | 写入 + 读取 | ❌ **完全不写** | 🔴 断裂 |
| `task_status` 进度 | JSON 列直接存储 | ❌ `conversation_plans` 无此列 | 🔴 3 个 API handler 500 错误 |

## 断裂清单

### 1. K12 预制计划 → 无 plan 记录（P0）

**`routes.rs` k12_init_handler 和 reading_init_handler`**
删除了 `INSERT INTO learning_plans` 后，没有加对应的 `INSERT INTO conversation_plans`。K12 会话没有 `conversation_plans` 行。

**后果**:
- `/api/plans` 返回空列表 → 复习页面看不到任何 plan tab
- `plans_progress_handler` 查不到进度 → 成就页无跟踪
- 前端 `review_screen` 中 `_planTabs` 为空 → "全部卡片"以外无其他 tab

### 2. 3 个 API handler SELECT 不存在的 `task_status` 列（P0）

| Handler | 文件:行 | SQL |
|---------|---------|-----|
| `plans_list_handler` | `routes.rs:1291` | `SELECT ..., task_status, ... FROM conversation_plans` |
| `plans_progress_handler` | `routes.rs:1341` | `SELECT task_status, ... FROM conversation_plans` |
| `reading_milestone_handler` | `routes.rs:2092` | `SELECT plan_content, task_status FROM conversation_plans` |

`conversation_plans` 表**没有** `task_status` 列。这三个 API 在生产调用时会直接 500 错误。

`plans_list_handler` ✅ 已修（去掉了 `task_status` 引用，加了 `conversation_id`）。
其余两个 ❌ 未修。

### 3. `user_plan_progress` 数据有但无 plan 承载

K12 init 虽然写了 `plan_type='plan_templates', plan_id='{subject}_plan'` 到 cards，但 `conversation_plans` 里没有对应记录。`build_plan_context` 查不到 → 教师角色退化为 free.md。复习页面按 plan 筛选失效。

## 修复方案

### Phase A: 补 `conversation_plans` 记录（2 处）

**k12_init_handler** (`routes.rs`): 创建会话后 INSERT 一条 `conversation_plans`，`plan_content` 从 `plan_templates` 读取。

**reading_init_handler** (`routes.rs`): 同上。

### Phase B: 修 3 个 API handler（3 处）

**plans_list_handler** ✅ 已修。

**plans_progress_handler** (`routes.rs:1341`): `task_status` 改为从 `plan_content` 提取 status（已在 plan JSON 中 embedded）。

**reading_milestone_handler** (`routes.rs:2092`): `task_status` 改为从 `user_plan_progress` 读取或 `plan_content` 提取。

### Phase C: `upsert_learning_plan` 补 K12 路径

`plan_handler.rs:356`: `is_conversation_plan` 判断后，对 K12 也应 INSERT 到 `conversation_plans`（当前只写了 `user_plan_progress`）。
