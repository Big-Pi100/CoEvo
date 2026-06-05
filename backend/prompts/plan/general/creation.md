根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{dialogue_text}

请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可，如"一元二次方程求解"、"Python入门"）
- stages: 阶段数组，每个阶段包含 name、tasks 数组
- 每项 task 包含 name、description
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

确保计划包含 3-5 个阶段，每个阶段不少于 2-3 个任务，覆盖完整的学习路径。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}
