# 六种记忆法 · 数据实现状态审计

- 日期：2026-09-26
- 触发：白哥问「这些记忆法数据中哪些实现了，哪些没实现」
- 依据：`data/word.db` 全库实测 + v1 §3.1.7 `applicable_when` + §4.1 优先级表

---

## 一、速查表

| # | code | 记忆法 | primary 词数 | 素材覆盖率 | 状态 |
|---|---|---|---:|---:|---|
| 1 | `root` | 词根词缀 | 5,334 | **99.8%** | ✅ **已实现** |
| 2 | `cognate` | 同源串记 | 195 | **2.1%** | 🟠 **表在，但无适用对象** |
| 3 | `collocation` | 搭配整记 | 102 | **100%** | ✅ **已实现** |
| 4 | `etymology` | 词源故事 | 3,525 | **100%**（98% 不可拆 ✓） | ✅ **已实现** |
| 5 | `image` | 联想图像 | 957 | **0%** | 🔴 **完全未实现** |
| 6 | `context` | 语境原句 | 1,410 | **99.8%** | ✅ **已实现** |

> **「素材覆盖率」定义**：**被判为该 `primary` 的词里，该记忆法的数据真的存在的比例。**
> 这才是有效指标 —— 只看「素材表总覆盖率」会漏掉判定错误。

---

## 二、逐项核实

### 1 `root` 词根词缀 —— ✅ 已实现

| 项 | 实测 |
|---|---|
| 素材表 | `word_morpheme` + `word_root` + `affix` |
| primary 词数 | 5,334 |
| 其中**真可拆** | **5,322 / 5,334 = 99.8%** ✅ |
| 卡片里是否用上 | ✅ 有渲染（5,322 张有 `root` section） |

**12 条偏差**都是**多词短语**（`modal verb` · `web page` · `question mark` · `department store` · `sitting room` · `steering wheel` · `well-dressed`）——
短语不该有词根拆解。**量小，可接受。**

### 2 `cognate` 同源串记 —— 🟠 表在，但 primary 判定与数据不匹配

| 项 | 实测 |
|---|---|
| 素材表 | `cognate_group` + `cognate_group_member`（1,777 族已生成） |
| primary 词数 | 195 |
| 其中**真有同族词** | **4 / 195 = 2.1%** 🔴 |
| 族素材总覆盖率 | 2,988 词（25.9%，size≥3） |

**v1 的 `applicable_when` 原文**：
> 「与**另一个英语词**共享同一词根或词源（`receive`/`perceive`/`conceive`）；谐音不算」

**实测这 195 词的同源对象都不在词表里**：

| 词 | 词源（实测） | 同源对象 |
|---|---|---|
| `father` | 古英语 fæder，与拉丁 **pater** 同源 | 拉丁词，不在词表 |
| `where` | 古英语 hwær，与 **here/there** 同源 | ⚠️ `here`/`there` 在词表，但无族记录 |
| `nine` | 古英语 nigon，与拉丁 **novem** 同源 | 拉丁词，不在词表 |
| `advise` | 拉丁 ad + **videre**（看） | 拉丁词，不在词表 |
| `glimpse` | 与 **gleam**（闪光）同源 | ⚠️ `gleam` 在词表，但无族记录 |

**→ 问题性质**：LLM 把「**词源上有亲缘**」当成了 `cognate`，但 v1 要求的是「**与另一个英语词构成可串记的词群**」。
`father` 与拉丁 `pater` 同源 —— **这层关系对英语学习者没有串记价值**（用户不会同时学 `pater`）。

**→ 这是判定标准错误，不是数据缺失**（族表本身没问题）。

### 3 `collocation` 搭配整记 —— ✅ 已实现

| 项 | 实测 |
|---|---|
| 素材表 | `collocation` + `word_collocation`（99.3% 词有搭配） |
| primary 词数 | 102 |
| 其中**有搭配** | **102 / 102 = 100%** ✅ |

**搭配质量确实高**（都是习语/固定搭配，符合 v1 的「固定搭配强的词」）：
```
killing      → make a killing / killing field / mercy killing
bulk         → the bulk of / in bulk / bulk up
guise        → under the guise of / in the guise of
expense      → at the expense of / living expenses
span         → attention span / life span / span the globe
```

### 4 `etymology` 词源故事 —— ✅ 已实现

| 项 | 实测 |
|---|---|
| 素材表 | `word.etymology_text`（99.0%）+ `etymon`/`word_etymon`（68.5% 真词源） |
| primary 词数 | 3,525 |
| 其中**不可拆**（符合 v1「整体借词、不可拆」） | **3,441 / 3,525 = 97.6%** ✅ |
| 有 `etymology_text` | **3,525 / 3,525 = 100%** ✅ |

**抽样（判得对）**：
```
absurd    → 拉丁 absurdus（不协调的）→ 荒谬的
burglar   → 拉丁 burgus（城堡）→ 古法语 burgier（洗劫）→ 入室盗窃者
caution   → 拉丁 cavere（当心）→ cautio（小心）→ 英语 caution
brooklyn  → 荷兰语 Breukelen（沼泽地）→ 布鲁克林
bel       → 源自电话发明者贝尔的姓氏
```
**84 条可拆却判 `etymology`** 的（`bankrupt` = bank + -rupt）—— 2.4%，主要是 LLM 认为拆解不透明。**可接受。**

### 5 `image` 联想图像 —— 🔴 完全未实现

| 项 | 实测 |
|---|---|
| 素材表 | **不存在** —— 搜遍全库表名/列名，无 `imag`/`img`/`pic`/`photo`/`illustration` |
| primary 词数 | 957 |
| 其中**有素材** | **0 / 957 = 0%** 🔴 |
| `secondary_codes` 含 `image` | **另 1,539 词**（同样无数据源） |
| 卡片里是否用上 | ❌ 无（无数据可渲染） |

**v1 的 `applicable_when`**：「**抽象词**，靠意象或谐音联想」
**v1 §8.2 伪代码有 `build_imagery_section(word)`，但全文未说明数据来源** —— 所以严格说 v1 也没定义怎么生成。

#### 更严重：**957 词全部判错**

实测这 957 词是**最具体的实物名词**，与「抽象词」完全相反：
```
belly · cocky · fork · mat · pizza · pop · rose · rope · ax · ball
babe · balloon · bee · beads · berry · big · bin · boa · breeze · bucket
cat · cheese · clock · cold · ditch · dog · door · flock · garlic · glass
glove · golf · hat · hen · horse · ice cream · traffic light · chocolate
```
（长度 ≥9 的只占 **4%**）

#### 反证：**真抽象词一个都没判给 `image`**

实测 28 个典型抽象词：

| 词 | primary | 词 | primary |
|---|---|---|---|
| `justice` | `root` | `subtle` | `etymology` |
| `freedom` | `root` | `notion` | `etymology` |
| `concept` | `root` | `irony` | `etymology` |
| `ideology` | `root` | `courage` | `etymology` |
| `wisdom` | `root` | `patience` | `etymology` |
| `ambiguous` | `root` | `virtue` | `etymology` |
| `temptation` | `root` | `humility` | `etymology` |

**分布：`root` 18 · `etymology` 10 · `image` 0** 🔴
（只有 `nuance` 和 `melancholy` 的 `secondary` 里有 `image`）

**→ `image` 这一类在现网数据里没有任何适用对象。** 957 词 + 1,539 词 `secondary` 都是被错判进去的。

### 6 `context` 语境原句 —— ✅ 已实现

| 项 | 实测 |
|---|---|
| 素材表 | `card.sections[].example`（99.7% 词有例句） |
| primary 词数 | 1,410 |
| 其中**有例句** | **1,407 / 1,410 = 99.8%** ✅ |

⚠️ 但注意：v1 说 `context` 是「**默认附加**」—— 意思是它**不该当 primary**，而是无条件附加在每张卡上。
现在 1,410 词把它当 primary（见 §三.2）。

---

## 三、🔴 两个结构性问题

### 3.0 `primary`/`secondary` 是怎么生成的（白哥问）

#### 3.0.1 表结构 —— ⚠️ 与 v1 有偏差

| | v1 §3.1.7 | 我的实现 |
|---|---|---|
| primary | `primary_type_id`（**外键**） | `primary_code`（TEXT） |
| secondary | `secondary_type_id`（**外键 · 单个**） | `secondary_codes`（**JSON 数组，可多个**） |
| 理由字段 | `analysis` | `rationale` ✅（有用） |

**实测** `secondary` 个数分布：`0 个 86 · 1 个 10,675 · 2 个 762` —— **v1 只允许 1 个 secondary，我做成数组**。

#### 3.0.2 生成方式：LLM 在契约里一次给出

契约 v5（`coevo_wordlib_contract.py` 第 105 / 173–177 行）：
```json
"mnemonic": {"primary": "root", "secondary": ["cognate"], "rationale": "in(不)+cred(相信)+ible(可…的)"}
```
```
8) mnemonic.primary ∈ root|cognate|etymology|collocation|image|context
   — the single method most likely to help a learner recall THIS word.     ← 🔴 关键
   * "cognate" means the word SHARES A ROOT OR ETYMON with another English word (receive/perceive/conceive).
     A mere sound-alike (e.g. "papa" ~ Chinese "爸爸") is NOT cognate -> use "image".
   * HARD RULE: if primary="root", then morphology.analyzable MUST be true.
     Otherwise choose "etymology" or "context".
```

#### 3.0.3 🔴 根因找到了：**偏离在契约措辞，不在 LLM**

| | 原文 | 含义 |
|---|---|---|
| **v1 §4.1** | 「制卡时**按 `mnemonic_type.priority` 选**主记忆法和次记忆法」 | **按 1→6 顺序试，第一个满足的当 primary** |
| **我的契约 v5** | 「the single method **most likely to help a learner recall** THIS word」 | **取「最有效的」** —— 主观最优 |

**→ LLM 完全按契约执行了，是契约本身偏离了 v1。**
这解释了 §3.1 的全部实测结果（`image` 组 99.5% 满足 collocation，本应先命中 3）。

**另外两点**：
- 契约里**没有给 `secondary` 的选取规则**（只给了示例）→ LLM 自由发挥
- 契约的 HARD RULE 只有一条（`primary=root ⟹ analyzable=true`）→ 其余组合无约束

**→ 修法：改契约措辞**（把「most likely」改成「按 priority 顺序第一个满足的」）+ 补 secondary 规则。

### 3.0.4 🔑 词根词缀 × 词源故事 的重叠率（白哥问）

**素材层面：`root` 与 `etymology` 几乎完全重叠。**

| 指标 | 数值 |
|---|---|
| 可拆词（有 `word_morpheme` **任意记录**） | 5,484 / 11,523 |
| 其中**有 `etymology_text`** | **5,483 / 5,484 = 100.0%** 🔴 |
| 其中**有「真词源」**（`role≠whole`） | **5,115 / 5,484 = 93.3%** 🔴 |
| 有词源但**不可拆** | 2,784 |

> ⚠️ **可拆不能用 `word_morpheme.type='root'` 判** —— 那个口径只有 5,448，会漏 36 个
> （`biology`/`oxygen`/`psychology`… LLM 把希腊语词素标成了 `prefix`）。详见
> `mnemonic-layer-separation-2026-09-26.md` §2.1。

**内容层面：对可拆词，② 的义项与 ① 的义项重复度极高。**

| 判定 | 词数 | 占比 |
|---|---:|---:|
| ② 标注的义项**全部**与 ① 重复 | **3,565** | **65.0%** 🔴 纯冗余 |
| ② 义项**部分**重复 | 728 | 13.3% |
| ② 义项**无**重复（有增量） | 1,123 | 20.5% |
| ② 无可解析义项标注 | 67 | 1.2% |

**纯冗余样例（② 一个字都没多）**：
```
disappear   ① dis-（不，相反）+ appear（出现）
            ② dis-（不）+ appear（出现）→ 不出现，即消失        ← 逐字重复

anatomy     ① ana-（向上；分开）+ tom（切）+ -y（名词后缀）
            ② 希腊 ana（向上）+ temnein（切）→ 切开研究         ← 义项重复

grown       ① grow（生长）
            ② 古英语 growan（生长）→ 过去分词 grown → 成年的    ← 重复
```

**有增量样例（② 提供了历史路径）**：
```
instruct    ① in-（进入；在内）+ struct（建造；堆叠）
            ② 拉丁 instruere（建造、安排）→ 在头脑中构建知识 → 教导    ← 增量=语义演变

shocked     ① shock（震惊）+ -ed（…的）
            ② 法语 choquer（撞击）→ 受到冲击的                    ← 增量=来源语

cooker      ① cook（烹饪）+ -er（工具）
            ② 古英语 coc（厨师）→ 烹饪者 → 炊具                  ← 增量=演变链
```

### 3.0.5 🔴 由此推出一条与 v1 示例吻合的结论：① 与 ② 应该**互斥**

**可用性矩阵**（实测）：

| 组合 | 词数 | 占比 |
|---|---:|---:|
| ① 可拆 + ② 有词源 | **5,115** | 44.4% |
| ① 可拆 + ② 无词源 | 369 | 3.2% |
| ① **不可拆** + ② 有词源 | **2,784** | 24.2% |
| ① 不可拆 + ② 无词源 | 3,255 | 28.2% |

> 🔑 **5,115 + 2,784 = 7,899 = 「有真词源」总数** ——
> **每个有词源的词，要么可拆（用 ① `root`），要么不可拆（用 ② `etymology`），正好二选一。**

**v1 §4.2 的示例也指向互斥**：
```json
{ "front": "incredible",
  "sections": [
    { "type": "root", "text": "in-（不）+ cred（相信）+ -ible（能…的）", ... },
    { "type": "definition", "text": "难以置信的" },
    { "type": "context", "text": "The story is incredible." } ] }
```
→ **只有 3 段 `[root, definition, context]`，没有 `etymology` 段**。而 `incredible` 正是可拆词。

**→ 所以 v1 的意图很可能是：记忆法段是 `root` **或** `etymology`（互斥），不是两段并存。**

**但白哥 2026-09-26 明确说的是四样**：「卡片显示的是**当前单词的词根词缀、词源故事、释义、语境原句**」。

**→ 两者需要调和，见 §3.0.6。**

### 3.0.6 调和方案（待白哥定）

| 方案 | 可拆词（5,115） | 不可拆词（2,784） | 代价 |
|---|---|---|---|
| **A** 严格互斥 | ① `root` 一段（**丢 20.5% 的增量**） | ① `etymology` 一段 | 3 段卡；符合 v1 示例 |
| **B** 记忆法段 + 词源补充一行 | ① `root` 拆解<br>② **仅一行出处**：`← 拉丁 instruere（建造、安排）`（**只取增量，不重复义项**） | ① `etymology` 完整故事 | 4 段卡；**零冗余**；符合白哥四段要求 |
| **C** 两段都完整（我界面稿现状） | ① `root` + ② 完整词源故事 | ① `etymology` | 🔴 **65% 纯冗余**，且占容量 |

**→ 我建议 B**：既满足白哥的「词根词缀 + 词源故事 + 释义 + 语境原句」四样，
又避免把 ① 说过的义项在 ② 再说一遍（实测 65% 是逐字重复）。

**实现要点**：② 需要**自动判定有无增量** ——
规则可先筛（比对 ② 的义项标注与 ① 的 `gloss`），**重合的就不放进 ②**，只保留历史路径部分。

---

### 3.1 `primary` 判定**没有按 v1 的 priority 1→6 顺序筛选**

**v1 §4.1 原文**：「制卡时**按 `mnemonic_type.priority` 选**主记忆法和次记忆法」

→ 「按 priority 选」= 按 1→6 顺序试，**第一个满足的当 primary**。

**检验方法**：若按顺序试，则 `primary=image`(5) 的词**必须不满足** 1/2/3/4。

**实测结果**：

| primary | 词数 | 满足 3·collocation 有搭配 | 满足 4·etymology 真词源 |
|---|---:|---:|---:|
| **`image`** | 957 | **952（99.5%）** 🔴 | 231（24.1%）🔴 |
| **`context`** | 1,410 | **1,380（97.9%）** 🔴 | 373（26.5%）🔴 |
| **`cognate`** | 195 | **194（99.5%）** 🔴 | 114（58.5%）🔴 |

**→ 这三组共 2,562 词里，绝大多数「本不该轮到它们」** —— 按优先级顺序应先命中 `collocation`。

> ⚠️ **保留说明**：我的检验用「有 ≥1 条搭配」当作满足 `collocation`，而 v1 判据是「有 ≥1 条**高频固定**搭配」——
> 边界模糊，需人工判断。**但 `image` 组确实含习语**（`learn the ropes` · `get the ax` · `have a ball` · `fork in the road`），
> 与 `collocation` 组（`make a killing` · `in bulk` · `under the guise of`）**同质**。
> 所以「判定未按顺序」这个结论方向是可靠的，但**具体重判结果需 LLM 按语义重做**。

### 3.2 判定是「逐项独立打标」，不是「按顺序筛选」

从上述数据反推，实际判定逻辑更可能是：
```
对每个词，LLM 独立判断 6 个记忆法各自「适不适用」→ 取信心最高的当 primary
```
而不是 v1 要求的：
```
按 1→6 顺序试 → 第一个满足的当 primary
```

**差别很大**：`pizza` 有搭配（`pizza slice`），按顺序试应命中 `collocation`(3)；
但 LLM 独立判断时可能觉得「`pizza` 是具体事物 → 应该用图像记忆」→ 判了 `image`(5)。

**→ 这解释了 `image` 的全部 957 词**：LLM 把「**具体名词**」误当成「**适合图像记忆**」了。

---

## 四、修复建议

### 4.1 立即要定的：`image` 怎么办

| 方案 | 做法 | 代价 | 评价 |
|---|---|---|---|
| **A** | **不实现 `image`** —— 从 `mnemonic_type` 标记为「不可用」，1,152 词（957 primary + 1,539 secondary）重判 | 零 | ✅ **我建议 A**：现网无适用对象，且 v1 未定义数据源 |
| B | 用 LLM 生成**谐音/意象联想文字**（v1 说「靠意象或**谐音**联想」—— 谐音是纯文字，可生成） | LLM 成本 + 质量未知 | 🟠 可作后续增强，但要先解决「哪些词真适用」 |
| C | 生成真实图像（图片文件） | 图像生成成本高 + 体积 + 语音包之外还要图片包 | 🔴 不建议（与「一页容量」和包体政策冲突） |

⚠️ **注意**：方案 B 的前提是**先修判定** —— 现在 957 词全是具体名词，那些本不该用联想。
**真抽象词（`justice`/`subtle`/`courage`）现在都被判给了 `root`/`etymology`**，它们是否更适合联想，需要单独判断。

### 4.2 然后是：重做 `primary`/`secondary` 判定

**必须按 v1 §4.1 的顺序 + §3.1.7 的 `applicable_when` 重判**，涉及约 **3,700 词**（image 957 + context 1,410 + cognate 195 + 部分偏差）。

**判据（v1 原文，直接用）**：
| 优先级 | 判据（`applicable_when`） |
|---|---|
| 1 `root` | 可拆成现代英语仍透明的词根/词缀（`incredible = in+cred+ible`） |
| 2 `cognate` | 与**另一个英语词**共享同一词根或词源（`receive`/`perceive`/`conceive`）；**谐音不算** |
| 3 `collocation` | 有 ≥1 条**高频固定**搭配 |
| 4 `etymology` | **整体借词、不可拆**（`café ← French café`） |
| 5 `image` | **抽象词**，靠意象或谐音联想 |
| 6 `context` | **默认附加**（不作 primary） |

**成本估计**：LLM 重跑全量判定（prompt 只需词 + 现有素材摘要，短），约 **¥8–15 / 10 分钟**。

**产出**：新的 `word_mnemonic_profile` + 一个「判定依据」字段（记录为什么选它 —— 便于人工抽检）。

### 4.3 顺带修正的一处口径

| 项 | 现状 | 建议 |
|---|---|---|
| `context` 当 primary | 1,410 词 | 按 v1「**默认附加**」→ 它不该占 primary 位，应改为「每张卡无条件附加」 |

---

## 五、给白哥的结论

**直接回答你的问题**：

| 记忆法 | 实现了吗 |
|---|---|
| **1 词根词缀** | ✅ **已实现**（5,322/5,334 可拆 · 已渲染到卡片） |
| **2 同源串记** | 🟠 **表已建、族已生成，但 195 个 primary 词只有 4 个真有族** —— 判定标准错了 |
| **3 搭配整记** | ✅ **已实现**（102/102 有搭配 · 质量高） |
| **4 词源故事** | ✅ **已实现**（3,525 词全有词源 · 97.6% 确实不可拆） |
| **5 联想图像** | 🔴 **完全没实现** —— 无表、无字段、无数据；且 957 词全判错 |
| **6 语境原句** | ✅ **素材已实现**（99.8% 有例句），但被当 primary 用了 1,410 次，与 v1「默认附加」不符 |

**→ 6 种里 4 种已实现，1 种（cognate）判定错，1 种（image）完全没做。**

---

### 五之二、追加：`primary`/`secondary` 怎么分的 + 重叠率（白哥第二轮问）

#### A. `primary`/`secondary` 怎么分的

1. **表结构**：`primary_code` + `secondary_codes`（JSON 数组）
   ⚠️ **v1 §3.1.7 是 `primary_type_id` + `secondary_type_id`（各自单个 + 外键）** —— 我把 secondary 做成了数组（实测 10,675 词有 1 个 · 762 词有 2 个）
2. **生成方式**：LLM 在契约 v5 里一次给出（`mnemonic.primary` / `secondary` / `rationale`）
3. 🔴 **根因在契约措辞**：

| | 原文 | 含义 |
|---|---|---|
| **v1 §4.1** | 「制卡时**按 priority 选**主记忆法和次记忆法」 | **按 1→6 顺序试，第一个满足的当 primary** |
| **我的契约 v5** | 「the single method **most likely to help a learner recall** THIS word」 | **取最有效的**（主观最优） |

**→ LLM 完全按契约执行了，是契约本身偏离了 v1。**
4. 契约**没有给 `secondary` 的选取规则**（只给了示例）→ LLM 自由发挥
5. ✅ 有 `rationale` 字段记录理由（如「ag(做,行动)+ent(人/物) → 做事的人 → 代理人；同根词 act, action, agenda」）—— **可支撑人工抽检**
6. ✅ `primary` 不会出现在自己的 `secondary` 里（实测 0 条自我重复）

#### B. 词根词缀 × 词源故事 的重叠率

**素材层：几乎完全重叠。**

| 指标 | 数值 |
|---|---|
| 可拆词（有 `word_morpheme` **任意记录**，⚠️ 不是 `type='root'`） | 5,484 / 11,523 |
| 其中**有 `etymology_text`** | **100.0%**（5,483/5,484）🔴 |
| 其中**有「真词源」** | **93.3%**（5,115/5,484）🔴 |

**内容层：对可拆词，② 的义项与 ① 的义项重复严重。**

| 判定 | 词数 | 占比 |
|---|---:|---:|
| ② 义项**全部**与 ① 重复 | **3,565** | **65.0%** 🔴 逐字重复 |
| ② 义项部分重复 | 728 | 13.3% |
| ② 义项**无**重复（有增量） | 1,123 | 20.5% |

```
【纯冗余】disappear   ① dis-（不，相反）+ appear（出现）
                      ② dis-（不）+ appear（出现）→ 不出现，即消失     ← 一个字都没多
【有增量】instruct    ① in-（进入；在内）+ struct（建造；堆叠）
                      ② 拉丁 instruere（建造、安排）→ 在头脑中构建知识 → 教导
```

#### C. 🔴 由此推出一条与 v1 示例吻合的结论：**① 与 ② 应该互斥**

**可用性矩阵**：

| 组合 | 词数 |
|---|---:|
| ① 可拆 + ② 有词源 | **5,115** |
| ① 可拆 + ② 无词源 | 369 |
| ① **不可拆** + ② 有词源 | **2,784** |
| ① 不可拆 + ② 无词源 | 3,255 |

> **5,115 + 2,784 = 7,899 = 「有真词源」总数** ——
> **每个有词源的词，要么可拆（用 ① `root`），要么不可拆（用 ② `etymology`），正好二选一。**

**v1 §4.2 示例也印证**：`[root, definition, context]` 只有 **3 段，没有 `etymology`** —— 而 `incredible` 正是可拆词。

#### D. 结论与建议

**v1 的意图很可能是「记忆法段是 `root` **或** `etymology`（互斥）」；
但白哥说的是四样并存（词根词缀 + 词源故事 + 释义 + 语境原句）。**

调和方案（**我建议 B**）：

| 方案 | 可拆词（5,115） | 不可拆词（2,784） | 评价 |
|---|---|---|---|
| A 严格互斥 | ① `root` 一段 | ① `etymology` 一段 | 3 段卡；符合 v1 示例；**丢 20.5% 增量** |
| **B 记忆法段 + 词源补充一行** | ① `root` 拆解<br>② **仅一行出处**：`← 拉丁 instruere（建造、安排）`（**只取增量**） | ① `etymology` 完整故事 | ✅ **4 段 · 零冗余 · 符合白哥四段要求** |
| C 两段都完整 | ① `root` + ② 完整故事 | ① `etymology` | 🔴 **65% 纯冗余** + 占容量 |

**实现要点**：② 需**自动判定有无增量** —— 先比对 ② 的义项标注与 ① 的 `gloss`，重合部分**不进 ②**，只保留历史路径。

---

**四个待你定**：
1. ✅ **`image` 不实现**（已同意）
2. 🔴 **是否重做 primary/secondary 判定**（≈3,700 词 · ¥8–15）→ 我建议**做**，且**改契约措辞**（「取最有效」→「按 priority 顺序」）+ 加「判定依据」字段
3. 🔴 **① ② 用哪个方案**（A 互斥 / **B 记忆法段 + 词源补充一行** / C 现状）→ 我建议 **B**
4. 🟠 `secondary` 是**数组**（我的实现）还是**单个**（v1 §3.1.7）→ 我建议**保留数组**（v1 的单数过于受限，且实测 20% 词有 2 个次记忆法）

---

*本文档为审计产出，未修改代码或生产环境。`coevo.db` 时间戳未变。*
