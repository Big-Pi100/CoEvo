### 卡片字段说明（科学类）

每个卡片输出以下字段，有则填写，无则留空：

- **front**: 卡片名称（必填）
- **definition**: 一句话说清楚是什么
- **key_elements**: 核心组成部分/特征（列表形式）
- **applications**: 实际用在什么场景
- **related_concepts**: 与哪些已知概念有关
- **formula**: 公式（如有）
- **source_sentence**: 对话中对应的原文
- **source**: 来源/参考资料
- **domain**: "science"

每个元素必须是包含上述字段的 JSON 对象。只返回 JSON 数组，不要任何其他文字。