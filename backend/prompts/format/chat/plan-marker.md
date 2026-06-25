如果需要输出计划 JSON，使用 `<plan_update>` 标签包裹：

```
<plan_update>
{"is_new_plan": true, "goal": "学习目标（15字以内）", "domain": "science|language|literature|humanities", "stages": [{"name": "阶段名称", "tasks": [{"name": "任务名称", "description": "任务描述", "status": "pending"}]}], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}
</plan_update>
```