# 语言类 cards definitions 缺失审查报告

## 范围
4 种语言 × `prebuilt_language_cards.definitions` 字段

---

## 1. 总览

| 语言 | 总卡 | 空 definitions | 占比 | V3 源数据本身缺失 |
|:----|:----|:-------------:|:----:|:----------------:|
| 中文 | 2,714 | **31** | 1.1% | 31/31 ✅ 确认 |
| 英文 | 12,839 | **786** | 6.1% | 786/786 ✅ 确认 |
| 日文 | 1,787 | **0** | 0% | — |
| 俄文 | 98 | **0** | 0% | — |

所有空 definitions 在 V3 源数据中就是空的，V4 迁移没有丢失数据。

---

## 2. 中文空 definitions 分析（31 张）

全部是 `vocabulary` 类型，V3 的 `back` JSON 中 `definitions` 就是 `[]`。

典型代表：

| 字 | 拼音 | related_phrases | 问题 |
|:---|:----|:---------------|:-----|
| 爱 | ài | 爱情、爱护、热爱 | 有常用词但无释义 |
| 功 | (空) | (空) | 无拼音、无释义、无词组 |
| 泳 | yǒng | (空) | 有拼音无释义无词组 |
| 打 | dǎ, dá | 打击、打扫、打篮球 | 多音字，有词组无释义 |

**结论：** V3 数据集对这些字的定义录入不完整，不是迁移问题。

---

## 3. 英文空 definitions 分析（786 张）

| 卡类型 | 数量 | 特征 |
|:------|:----|:-----|
| `vocabulary` | 748 | 普通词汇，V3 源数据无 definitions |
| `dialogue` | 8 | 对话类（A Phone Call, At the Restaurant 等） |
| `informational` | 8 | 信息类（A Brief History of the Olympics 等） |
| `letter` | 6 | 书信类 |
| `opinion` | 8 | 观点类 |
| `biography` | 5 | 传记类 |
| `report` | 4 | 报告类 |
| `speech` | 3 | 演讲类 |
| `instruction` | 2 | 说明类 |
| `play` | 2 | 剧本类 |
| `review` | 2 | 评论类 |

非 vocabulary 类型的卡片（共 48 张）没有 definitions 是正常的——它们是整篇课文/对话/书信，不是可定义的词汇。

**重点：748 张 vocabulary** 卡 definitions 为空——但与中文一样，V3 源数据就没有。

---

## 4. 连带影响：英文非词汇卡的 `back` 显示问题

英文非 vocabulary 卡（48 张）的 `pronunciation` 也是空字符串。COALESCE 取到 `''` 作为 `back`，导致这些卡在复习时背面是空的。

**这些卡片的 V3 back JSON 实际包含 `full_text` 等内容，但 V4 `prebuilt_language_cards` 表没有对应字段来承载这些数据。**

---

## 5. 结论

| 问题 | 涉及范围 | 严重程度 |
|:-----|:---------|:---------|
| definitions 为空（V3 源数据缺失） | 中文 31 + 英文 748 = **779 张** | 🟡 源数据问题，非迁移 bug |
| 非词汇卡 back 为空（渲染空白） | 英文 48 张（dialogue/letter/report 等） | 🟡 COALESCE 缺少 `c.front` 兜底 |
| 中文 pos 顶层字段为空（已填） | 2,714 张 | ✅ 已修复 |
