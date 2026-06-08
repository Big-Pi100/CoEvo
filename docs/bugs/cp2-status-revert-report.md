# 计划状态回退与 CP2 机制调查报告

> 2026-06-03 10:33

## 问题 1：计划状态回退

### 根因

`apply_plan_mutations()`（`plan_handler.rs:431`）的 SQL 从：

```sql
SELECT task_status, plan_content FROM learning_plans
```

改为了：

```sql
SELECT id, plan_content, plan_content FROM conversation_plans
```

因为 `conversation_plans` 没有 `task_status` 列。但后续代码（L442）仍以旧格式解析：

```
plan_row → (plan_id, task_status_str, plan_content_raw)
                               ↓
                    status_val = serde_json::from_str(task_status_str)
                    status_val.get("task_status")  ← 期望 { task_status: {...} }
```

现在 `task_status_str` 拿到的是 `plan_content`（完整计划 JSON，含 stages 但不含 `"task_status"` 顶层键），所以 `status_val.get("task_status")` 返回 `None` → 任务状态覆盖不执行 → `apply_plan_mutations` 返回了但未更新任何 task status。

**影响**：CP2 检测到通关信号（`badge_found = true`），调用 `handle_plan_update` → `apply_plan_mutations` 返回 `Some(plan)`（未修改的原始 plan），`plan_updated = true`，但 **user_plan_progress 同步代码读到的 task status 是过期的** → 状态不变。

### 修法

`apply_plan_mutations` 不再需要 `task_status_str`，直接用 `plan_content` 即可（`plan_content` 中 stages 已含 status）。

### 其他可能影响

同一函数内 L444-454 的 "注入 task_status 到每个 task" 逻辑也是旧的——`plan_content` 的 tasks 已有 status，不需要再注入。

## 问题 2：API 测试报告不完整

`e2e_api_lifecycle.rs` 当前只报告了 plans 数量和对话轮次，缺少：
- CP2 计划状态（task_key 维度的进度）
- CP1 卡片数据（候选概念列表）
- 计划事件的详细日志

需要新增 API 调用：
- `GET /api/plans?user_id=xxx` 读全部计划
- `GET /api/user/{uid}/learning-report` 读学习报告
- `GET /api/cards/all?user_id=xxx` 读卡片数据
- 报告末尾写入卡片数、计划进度、CP2 事件摘要

## 问题 3：plan_context 注入时机

`structured.md` 本身不包含计划信息和任务完成信号模板。这些内容在 `build_context_text()`（`plan_handler.rs:1047`）中动态生成，通过 `build_plan_context()` 返回，在 `ws.rs:277-278` 注入到 `user_content`（LLM 的用户输入，不是 system prompt）：

```
ws.rs 流程:
  1. build_plan_context() → (domain, mode, ctx)
  2. ctx = build_context_text(merged, goal, mode)
     → 生成 "### 学习计划" + "### 任务完成信号" 文本
  3. user_content = 对话历史 + plan_context + 当前消息
  4. LLM(system_prompt, user_content)
```

system prompt（`structured.md`）只定义教师角色和行为规范。计划进度和完成信号指示是作为 user_content 注入的。
