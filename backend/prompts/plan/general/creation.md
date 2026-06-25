根据以下师生对话，为学生制定一个详细的学习计划。

对话：
{dialogue_text}

请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可，如"一元二次方程求解"、"Python入门"）
- stages: 阶段数组，每个阶段包含 name、tasks 数组
- 每项 task 包含 name、description，name必须是有完整语义的概念而非序号或编号
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

以金字塔原则为准，保证知识点不重不漏。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}

关于 domain 字段：
- "science": 物理、化学、生物、数学、地理、信息技术等自然科学
- "language": 语言类（英文、中文、日文等）的词汇、语法、发音学习
- "literature": 文学类（诗歌、散文、小说、寓言等）的赏析与理解
- "humanities": 历史、政治等社会科学
- 根据对话内容选择最合适的 domain，不要自造 domain 值
