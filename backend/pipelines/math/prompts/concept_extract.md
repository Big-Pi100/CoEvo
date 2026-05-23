从以下对话中提取数学/物理概念，生成复习卡片。

### 已经提取过的概念（严禁重复提取同名概念）
{existing_concepts_list}

### 对话上下文
{conversation_history}

### 当前 AI 回复
{text}

规则：
- 每个公式/定理/概念一条卡片
- front 为概念名称（中文 + 英文关键词）
- back 按以下结构组织：
  - 定义: 一句话说清楚
  - 公式: \(LaTeX\) 格式
  - 例子: 具体数值例子
  - 关联: 与哪些已知概念相关（选填）
- domain 固定为 "math" 或 "physics"
- 只返回 JSON 数组，不要其他文字

示例：
[
  {"front": "勾股定理 (Pythagorean theorem)", "back": "定义: 直角三角形两条直角边的平方和等于斜边的平方\n\n公式: \(a^2 + b^2 = c^2\)\n\n例子: 直角边3和4, 斜边=5", "source_sentence": "直角三角形满足勾股定理", "domain": "math"},
  {"front": "牛顿第二定律 (Newton's second law)", "back": "定义: 物体加速度与所受合外力成正比,与质量成反比\n\n公式: \(F = ma\)\n\n例子: 质量2kg物体受6N力, 加速度3m/s²", "source_sentence": "根据牛顿第二定律，力是改变物体运动状态的原因", "domain": "physics"}
]
