## 输出格式

仅返回以下 JSON 格式，不要任何其他文字：

```json
{
    "word": "要验证的单词",
    "correct": true/false,
    "reason": "判断理由",
    "correction_hint": "如果 correct=false，提供纠正提示。如果 correct=true，留空字符串"
}
```