### 卡片字段说明（文学类）

每个卡片输出以下字段，有则填写，无则留空：

- **front**: 作品名/文学概念（必填）
- **full_text**: 原文/正文
- **translation**: 译文（如有）
- **author**: 作者
- **genre**: 体裁（诗/词/散文/小说等）
- **source_sentence**: 对话中对应的原文
- **domain**: "literature"

每个元素必须是包含上述字段的 JSON 对象。只返回 JSON 数组，不要任何其他文字。