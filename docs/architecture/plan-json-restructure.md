# Plan JSON 重构：内容与状态分离

## 现状

`learning_plans.plan_json` 同时存储**不可变的内容**和**可变的运行时状态**。

以课文阅读为例，每次 init 写入 170KB JSON，包含 127 个 stage、596 个 task 的全部内容（name, focus, lesson_script 等）加上 status 字段。多租户部署下每个用户独立存储一份，重复 170KB×N。

## 目标

分拆成两层：

| 层 | 内容 | 存储 | 共享性 |
|:---|:-----|:-----|:-------|
| **内容层** | stage/task 结构、focus、lesson_script | JSON 文件（内存索引）或 `plan_content` 列 | 所有用户共享（或每人一份锁定时不可变） |
| **状态层** | task 的 status（done/in_progress/pending） | SQLite `plan_json` 列 | 每人独立 |

新增 `learning_plans.plan_content` 列，存储完整计划结构（写入一次，只读不改）。

各管线的内容来源：

| 管线 | plan_content 来源 | plan_json 内容 |
|:----|:-----------------|:--------------|
| 课文阅读 | NULL（从 `reading_loader` 取） | `{"task_status":{"春":"done","济南的冬天":"in_progress"}}` |
| K12 结构化 | NULL（从 `curriculum_loader` 取） | 同上 |
| 自由探索 | LLM 首次 `<plan_update>` 生成的全量结构 | 同上 |

`plan_json` 新格式（所有管线统一）：
```json
{"task_status": {"任务A": "done", "任务B": "in_progress", "任务C": "pending"}}
```

## 最终决策

- ✅ **通用管线也改**——三条管线统一架构，`plan_content` 列存 LLM 首次生成的结构
- ✅ **后端 API 层做映射**——`/api/plans` 返回时合并内容+状态，前端格式不变
- ✅ **一次性全量转换**——所有线上用户 `plan_json` 通过迁移脚本批量转换

## 影响范围

### 后端：直接读取 `plan_json["stages"]` 的代码

| 文件 | 函数/位置 | 作用 | 影响 |
|:----|:---------|:-----|:----|
| `plan_handler.rs` | `get_current_task_name()` | 从 plan_json.stages 找当前 in_progress task | 改为查 plan_json.task_status |
| `plan_handler.rs` | `apply_plan_mutations()` | 更新 plan_json.stages[].tasks[].status | 改为更新 plan_json.task_status |
| `plan_handler.rs` | `handle_plan_update()` (reading_update) | 标记 task done | 改为更新 plan_json.task_status |
| `plan_handler.rs` | `build_plan_context()` | 拼接 stage/task 状态文本 | 从内容索引+状态合并 |
| `plan_handler.rs` | `render_plan()` | 渲染 plan 文本 | 从内容索引+状态合并 |
| `plan_handler.rs` | `check_revert_signals()` | 检测回退 | 读 status → 改 status |
| `plan_handler.rs` | 单元测试 | 验证 status | mock 格式更新 |

| 文件 | 函数/位置 | 作用 | 影响 |
|:----|:---------|:-----|:----|
| `admin_handlers.rs` | `parse_plan_progress()` | 管理后台进度 | 查 task_status + 内容索引 |
| `routes.rs` | 成就检测 | 遍历 stages 找 done | 查 task_status |
| `ws.rs` | 成就检测 | 同上 | 同上 |
| `reading_loader.rs` | `build_reading_context()` | 注入 reading 卡内容 | 状态改为从 SQLite 取 |
| `routes.rs` | `plans_list_handler` | 返回 plan 给前端 | 内部合并内容+状态 |

### 数据库迁移

```sql
ALTER TABLE learning_plans ADD COLUMN plan_content TEXT DEFAULT NULL;
-- 迁移：将旧格式 plan_json 拆分为 plan_content + plan_json(task_status)
```

### 前端

**不改。** `plans_list_handler` 返回格式不变（依然有 `stages` 和 `tasks`），前端无感知。

### 测试

- `e2e_live_llm_plan_lifecycle.rs`：断言中 mock 的 JSON 格式需更新
- `plan_handler.rs` 内嵌测试：mock 数据结构需更新

## 实施顺序

### Step 1: 数据库迁移 + `plan_content` 列
- `main.rs` 加 ALTER TABLE 迁移
- `routes.rs` k12_reading_init_handler/k12_init_handler 首次创建 plan 时写入 plan_content

### Step 2: 后端只读函数改造
- `plan_handler.rs` 新增 `fn get_plan_content(conn, conversation_id)` 统一获取内容
- `plans_list_handler` 改为返回合并后的 plan

### Step 3: 状态写入函数改造
- `apply_plan_mutations()` → 改为读写 `plan_json.task_status`
- `handle_plan_update()` (reading_update) → 改为读写 `plan_json.task_status`
- `build_plan_context()` / `render_plan()` → 从内容+状态合并

### Step 4: 迁移脚本
- 一次性全量转换：遍历 `learning_plans`，将旧格式 `plan_json` 拆分为 `plan_content` + `plan_json(task_status)`

### Step 5: 清理
- 删除旧格式兼容代码
- 单元测试适配新格式
