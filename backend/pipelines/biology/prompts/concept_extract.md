从以下对话中提取生物概念，生成复习卡片。

### 已经提取过的概念（严禁重复提取同名概念）
{existing_concepts_list}

### 对话上下文
{conversation_history}

### 当前 AI 回复
{text}

规则：
- 每个生物概念/结构/过程一条卡片
- front 为概念名称（中文 + 英文）
- back 按以下结构组织：
  - 定义: 一句话说清楚
  - 结构/组成: 由什么构成
  - 功能/作用: 有什么作用
  - 关联: 与哪些生物概念相关
- domain 固定为 "biology"
- 只返回 JSON 数组，不要其他文字

示例：
[
  {"front": "细胞膜 (Cell membrane)", "back": "定义: 包围在细胞表面的一层薄膜\n\n结构: 磷脂双分子层为骨架,镶嵌蛋白质\n\n功能: 控制物质进出,保持细胞内部环境稳定\n\n关联: 与细胞壁、细胞质共同构成细胞基本结构", "source_sentence": "细胞膜是细胞的重要组成部分", "domain": "biology"},
  {"front": "光合作用 (Photosynthesis)", "back": "定义: 植物利用光能将CO₂和H₂O转化为有机物和O₂的过程\n\n公式: \(6CO_2 + 6H_2O \\xrightarrow{光} C_6H_{12}O_6 + 6O_2\)\n\n场所: 叶绿体\n\n条件: 光照、叶绿素、水", "source_sentence": "光合作用是植物最重要的生理过程", "domain": "biology"}
]
