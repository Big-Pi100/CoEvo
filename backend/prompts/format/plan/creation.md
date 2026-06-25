请输出 JSON 格式的学习计划，包含：
- goal: 简洁的学习目标（**15字以内**，概括即可，如"一元二次方程求解"、"Python入门"）
- stages: 阶段数组，每个阶段包含 name、tasks 数组
- 每项 task 包含 name、description。name 必须体现该 task 的**核心学习内容**，回答"学什么"——如"勾股定理"、"配方法"、"现在完成时"、"道可道非常道"、"光合作用"。**禁止**在 name 中出现任何序号、章节编号、书目名称、页码范围——这些不是"学了什么"，只是"在哪里"。如果你只有章节编号，用自己的知识为该章节提炼一个核心主题作为名称
- completed_concepts: []
- current_task_complete: false
- next_stage_suggestion: null

根据对话内容生成覆盖完整学习路径的计划，按合理粒度拆分阶段和任务。

只返回 JSON，不要加其他文字：
{{"is_new_plan": true, "goal": "...", "domain": "...", "stages": [...], "completed_concepts": [], "current_task_complete": false, "next_stage_suggestion": null}}

关于 domain 字段：
- "science": 物理、化学、生物、数学、地理、信息技术等自然科学
- "language": 语言类（英文、中文、日文等）的词汇、语法、发音学习
- "literature": 文学类（诗歌、散文、小说、寓言等）的赏析与理解
- "humanities": 历史、政治等社会科学
- 根据对话内容选择最合适的 domain，不要自造 domain 值