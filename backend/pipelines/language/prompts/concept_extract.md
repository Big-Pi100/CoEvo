从以下对话中提取英语词汇/语法概念，生成复习卡片。

### 已经提取过的概念（严禁重复提取同名概念）
{existing_concepts_list}

### 对话上下文
{conversation_history}

### 当前 AI 回复
{text}

规则：
- 每个单词/概念一条卡片
- front 为英语单词或短句
- back 为中文释义 + 词性标注 + 英文例句
- domain 固定为 "language"
- 如有 IPA 音标，在 back 中标注 `/音标/`
- 只返回 JSON 数组，不要其他文字

JSON 格式示例：
[
  {"front": "apple", "back": "/ˈæp.əl/ 苹果; n. I eat an apple every day.", "source_sentence": "Apple is a sweet fruit.", "domain": "language"},
  {"front": "run", "back": "/rʌn/ 跑; v. She runs every morning.", "source_sentence": "He can run fast.", "domain": "language"}
]
