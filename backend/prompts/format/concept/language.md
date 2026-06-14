### 卡片字段说明（语言类）

每个卡片输出以下字段，有则填写，无则留空：

- **front**: 单词/短语（必填）
- **pronunciation**: 读音/音标
- **pos**: 词性
- **definitions**: 释义列表（每项包含 meaning、example、chinese 译文）
- **related_phrases**: 常用搭配/短语
- **source_sentence**: 对话中对应的原文
- **domain**: "language"

每个元素必须是包含上述字段的 JSON 对象。只返回 JSON 数组，不要任何其他文字。