从以下对话中提取化学概念，生成复习卡片。

### 已经提取过的概念（严禁重复提取同名概念）
{existing_concepts_list}

### 对话上下文
{conversation_history}

### 当前 AI 回复
{text}

规则：
- 每个化学概念/反应/元素一条卡片
- front 为概念名称（中文 + 英文名）
- back 按以下结构组织：
  - 定义: 一句话说清楚
  - 化学式/反应: \(LaTeX\) 格式
  - 现象/特征: 实际表现
  - 应用: 实际用途
- domain 固定为 "chemistry"
- 只返回 JSON 数组，不要其他文字

示例：
[
  {"front": "氧化还原反应 (Redox reaction)", "back": "定义: 有电子转移的化学反应\n\n特征: 氧化反应(失电子)和还原反应(得电子)同时发生\n\n例子: \(2Na + Cl_2 \\rightarrow 2NaCl\)，Na失电子被氧化，Cl₂得电子被还原", "source_sentence": "氧化还原反应是化学中最基本的反应类型之一", "domain": "chemistry"},
  {"front": "元素周期表 (Periodic table)", "back": "定义: 按原子序数排列的元素表格\n\n结构: 7个周期(横行)和18个族(纵列)\n\n规律: 同一族元素化学性质相似,同一周期元素原子半径从左到右减小", "source_sentence": "元素周期表是化学的重要工具", "domain": "chemistry"}
]
