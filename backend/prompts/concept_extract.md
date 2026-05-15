从以下对话中，提取值得记住的新知识点作为卡片。

### 已经提取过的概念（严禁重复提取同名概念）
{existing_concepts_list}

### 对话上下文
{conversation_history}

### 当前 AI 回复
{text}

要求：
- 提取值得记住的**新**知识点，不设数量限制，但不要过度碎片化。每个知识点应有独立学习价值。
- 如果当前内容与"已提取概念"高度相关但角度不同，可用相同 front 扩展 back 内容；如果确实是新概念，创建新的 front
- 如果没有值得提取的新知识点，必须返回空数组 []
- front 必须简洁明确，不要用问句形式（如不要"什么是XX？"、"XX是什么？"），直接用名词或短语
- 英文术语优先用中文+英文的形式：如"量子叠加态 (Quantum superposition)"而非仅英文或仅中文
- 每个元素必须是包含 front/back/source_sentence/domain 的 JSON 对象
- 严禁返回没有意义的占位内容，不要编造概念
- 只返回 JSON 数组，不要任何其他文字

示例:
好: {"front": "工业革命", "back": "18世纪中叶英国开始的以蒸汽机为标志的生产方式变革", "source_sentence": "工业革命始于18世纪中叶的英国", "domain": "history"}
好: {"front": "Binary search (二分查找)", "back": "一种在有序数组中查找目标值的高效算法，时间复杂度O(log n)", "source_sentence": "Binary search works by repeatedly dividing the search interval in half", "domain": "tech"}
不好: {"front": "什么是工业革命？", "back": "...", ...}
不好: {"front": "工业革命带来了什么影响", "back": "...", ...}

JSON:
