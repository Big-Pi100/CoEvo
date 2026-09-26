# 第三轮抽样：新问题报告（契约 v5）

- 日期：2026-09-26
- 触发（白哥）：「**再抽样跑一次，看看还有什么问题**」
- 样本：**210 条 × 2 轮**（S1 100 · S2 60 · 🆕 S3a 短语 25 · 🆕 S3b 短词 25），成本 **¥2.21**
- 依据：`data/curriculum/prebuilt/llm_rerun_sample.json` + `data/coevo.db` 全表核查

---

## 〇、速查

> ## 🔴🔴 最高优先级（本轮最重要的发现，独立于噪声问题）
>
> **词表含涉中国主权与领土完整的错误表述，须在任何上线前修正：**
>
> | 词条 | 现行释义 | 问题 |
> |---|---|---|
> | **`taiwan`** | `An island in East Asia that is a **self-governing democracy**.` | 🔴 **暗示台湾是独立政治实体** —— 严重错误 |
> | **`tibet`** | `... **historically an independent kingdom**, now an autonomous region of China` | 🔴 **「曾是独立王国」是错误历史表述** |
>
> **→ 违反《网络安全法》涉主权内容规定 + App Store 中国区审核红线 + 中国用户强烈反感**
> **→ 必修正为官方表述。详见 §二：「内容合规问题」**
>
> **同时：白哥指出我上一轮「147 条专名全隔离」的建议是错的** —— 混进了国家名/州名/城市名。
> **国家名（`India`/`China`/`Russia`）、大洲、美国州名、主要城市是英语学习的基础词汇，必须保留。详见 §三（已重写）。**

### ✅ 契约 v5 成功（3 项，本次新增的设计都生效了）

| 项 | 结果 |
|---|---|
| `entry_type` 分类 | ✅ 210 条全部正确分类（word 161 · phrase 26 · proper 12 · abbreviation 11） |
| `phrase` 不拆词素（硬约束） | ✅ **违反 0 条** |
| `etyma.parent` 词源链式 | ✅ **49/281 条需要上溯**（232 条已是根本），样例质量好 |

**自洽性反而提高了**（prompt 更长的同时）：`is_own_entry` **100%** · `analyzable` 99.0% · `parts` 96.7% · 三项任一不一致 **3.3%**（上轮 6.2%）
> ⚠️ **但要交代偏差**：新增的 50 条短语/短词判断确定性高，**拉高了整体数字**。不可与上轮直接比较。

### ✅ 白哥已决策（2026-09-26）

| 决策 | 内容 |
|---|---|
| **专有名词 + 姓名** | ✅ **全部保留**（含地名/人名/名人）—— 理由：「**用户也有可能查，删了还要再生成**」<br>**实测支持**：卡片 **0 条空壳** · 音频边际成本 **≈0** · 比删后 LLM 兜底**更省** |
| **外语片段** | ✅ 删 22 条（**但本轮新逻辑与之一致性待确认** —— 见 §3.6，我建议分两类） |
| **拟声词** | ✅ 删 ~14 条 |

### 🔴 待处理（按优先级）

| 优 | 问题 | 规模 | 影响 |
|---:|---|---|---|
| **1** | 🔴🔴 **涉中国主权错误表述**（`taiwan`「self-governing democracy」/ `tibet`「independent kingdom」） | 2 条 + **须全表扫描** | **法律 + 审核红线 + 用户反感** |
| **2** | 🔴 **多词短语设计完全空白** | **142 条** | **划词命中路径缺失** + 卡片结构未定义 |
| **3** | 🔴 **专名 CEFR 等级标错**（`chen`/`jones`/`mary` 标 A1） | **125 条** | 影响难度排序与内容推荐 |
| **4** | 🔴 **`a` 的释义是 `happy` 的**（数据错误） | ≥1 条 | 直接教错 |
| **5** | 🟠 **IPA 多音标装不下** | **583 条 = 4.9%** | 卡片单 `ipa` 字段 |
| **6** | 🟠 **缩写带句点未设计** | 6 条 | `word.spelling` 含 `.` |
| **7** | 🟠 **新的幻觉模式** | 2 条单字母后缀 + 5 条前缀误判 | 词根表污染 |
| **8** | 🗑️ **须删的非专名项**（德/纳粹/撇号剥落） | `kulturbund` · `krystallographie` · `chemische` · `ll` · `ve` | 见 §3.5 |

> **✅ 不是问题**：**地理实体 ~220 + 人名 178 + 名人 36 = 433 条专名** —— 白哥已定**全部保留**（我前两轮误列为噪声，已改，§三）。

---

## 一、✅ 契约 v5 验证结果

### 1.1 `entry_type` 分类准确（新增字段）

| entry_type | 数量 | 抽样判定 |
|---|---:|---|
| `word` | 161 | 单词 |
| `phrase` | **26** | 多词短语 |
| `proper` | **12** | 专名（`rousseau`/`greek`/`jenkins`/`italian`…） |
| `abbreviation` | 11 | 缩写（`ph`/`ms`/`ns`/`ll`/`sr`/`ve`…） |

**`phrase` 硬约束（`morphology` 必须全空）违反 0 条** ✅ —— 设计生效。
**LLM 对短语的处理完全正确**（`out of`/`good night`/`navy blue`/`ice cream` 全部 `entry_type=phrase` + `is_own_entry=true`）。

> 🔑 **`entry_type=proper` 12 条本身就是信号** —— LLM 主动识别出这些是专名，**等于替我们指出了词表噪声**（见 §三）。

### 1.2 `etyma.parent` 词源链式（新增字段）

| 指标 | 结果 |
|---|---|
| 需上溯（`parent` 非空） | **49 / 281 = 17%** |
| 已是根本（`parent` 为空） | 232 / 281 |

**上溯样例（质量好）**：

| 词 | 直接源词 | 上溯到 |
|---|---|---|
| `science` | `scientia` | **`scire`**（知道）✅ |
| `paint` | `peint` | **`pingere`**（画）✅ |
| `greek` | `Graecus` | **`Graikos`** ✅ |
| `news` | `newes` | **`new`** ✅ |
| `musician` | `musica` | **`mousike`** ✅ |
| `rousseau` | `Rousseau` | **`Rubeus`**（红色）✅ |

**→ 上溯链可用。** 全量约 **2,000 条**需上溯（11,917 × 17%），补跑成本 ¥5 级。

### 1.3 「信任自身知识」规则生效

**白哥之前注意到的 `a` 释义错误，LLM 自己纠正了**：

| | 值 |
|---|---|
| 提供给它看的 `form_def` | `feeling or showing pleasure or contentment.`（**`happy` 的释义**） |
| LLM 判定 | `entry_type=word` · `is_own_entry=true` · reason = **「不定冠词，需单独学习」** ✅ |

**→ 契约里加的「若给定释义与词形无关，以自己的词汇知识为准」这条规则起作用了。**

---

## 二、🔴🔴 最高优先级 · 内容合规问题（涉中国主权与领土完整）

### 2.1 事实（原样引自 `data/coevo.db`）

| 词条 | `pos` | 现行 EN 释义 | 现行 ZH |
|---|---|---|---|
| **`taiwan`** | `n` | `An island in East Asia that is a self-governing democracy.` | 台湾 |
| **`tibet`** | `[n]` | `a region in central Asia, on the Tibetan Plateau; historically an independent kingdom, now an autonomous region of China.` | 西藏 |
| `mekong` | — | `a major river in Southeast Asia, flowing from the Tibetan Plateau through China, ...` | — |

**`taiwan` 的例句**：`She was born in Taiwan and moved abroad later.`

### 2.2 问题性质

| # | 问题 | 定性 |
|---|---|---|
| **1** | `taiwan` 被描述为 **`a self-governing democracy`** | 🔴 **暗示台湾是独立政治实体 —— 与一个中国原则不符** |
| **2** | `tibet` 被描述为 **`historically an independent kingdom`** | 🔴 **错误历史表述 —— 西藏自古以来是中国的一部分** |
| **3** | 两条均以**英文原文**呈现，会被逐字朗读、进入复习卡 | 🔴 **错误表述会被反复强化记忆** |

### 2.3 影响（三层风险）

| 层 | 风险 |
|---|---|
| **法律** | 违反涉国家主权内容的监管要求；App 面向中国区发行 |
| **平台** | **App Store 中国区审核红线** —— 此类内容属高概率拒审项 |
| **用户** | 中国用户看到会强烈反感，可能举报；且 app 定位是**中文母语者学英语**，用户全部是中国用户 |

**⚠️ 与「词表噪声」的区别**：噪声是「这条数据没价值」，**这是「这条数据有害」** —— 性质不同，优先级最高。

### 2.4 建议修正（按官方立场）

| 词条 | 建议改为 | 说明 |
|---|---|---|
| **`taiwan`** | 英文：`Taiwan, a province of China (Taiwan Province of China)`；中文：**中国台湾省** | 明确其为中国的一部分；例句改为中性地理表述 |
| **`tibet`** | 英文：`Xizang (Tibet), an autonomous region in southwest China`；中文：**西藏自治区，中国西南部** | **删除「historically an independent kingdom」**；建议统一用 `Xizang` |
| `tibetan` | `relating to Xizang (Tibet), its people, or their language` | 地理/语言形容词，去掉独立政治含义 |
| `mekong` | 可保留（`Tibetan Plateau` 是地理专名） | 但建议统一为 `the Qinghai-Xizang Plateau` |

**另外建议**：
- **补入** `hong kong`（中国香港）、`macao`（中国澳门）—— 当前**词表里没有**（对学习者是缺漏）
- 若补入，须用**「中国香港特别行政区」/「中国澳门特别行政区」**表述

### 2.5 🔴 必须做全表扫描（我不能只修这 2 条）

**理由**：本轮已两次证明「规则判据只覆盖想到的情形」（专名漏判、噪声漏判）。**同类问题可能不止这 2 条。**

**建议**：用 LLM 对全表 11,917 条做一次**专项合规扫描**（独立于词库重跑），判据：
```
对每个词条的释义，判断是否包含：
① 涉中国主权/领土的错误定性（台湾/西藏/新疆/南海/钓鱼岛…）
② 把中国地区表述为独立政治实体
③ 其他政治敏感的不当表述
→ 输出：命中词条 + 问题句 + 建议修正
```

**成本估算**：11,917 条 × 短 prompt（只传释义）≈ **¥8–12**（比全字段重跑便宜，因 prompt 极短）

**→ 这件事优先级高于全量词库重跑** —— 因为它决定「能不能上架」。

---

## 三、✅ 专有名词与姓名：**全部保留**（白哥决策）

> **白哥原话**：「**专有名词还是不删了，包括姓名，也都别删了，用户也有可能查，删了还要再生成。**」
>
> **→ 我上一轮「147 条全隔离」的建议作废；本轮的「人名 178 + 名人 36 删除」也作废。**

### 3.1 ✅ 实测支持该决策（三条，都是好消息）

| # | 核实项 | 结果 |
|---|---|---|
| **1** | **卡片内容是否空壳** | ✅ **178 条人名中 0 条空壳** —— 139 条有 **2 义项 + 例句 + IPA**，17 条有 3 义项 |
| **2** | **音频资产边际成本** | ✅ **≈ 0** —— 语音包本就是**全量覆盖**（≈290MB），多这 433 条不增加成本 |
| **3** | **vs 删除后的再生成成本** | ✅ **保留更省** —— 删了用户查到就要走 LLM 兜底（每词 ¥0.0026 + 缓存链路复杂度） |

**→ 白哥的判断在成本上是对的，而且卡片质量没问题。**

### 3.2 保留后**新暴露**的问题：CEFR 等级标错（125 条）

| 类 | 等级分布 |
|---|---|
| **人名/姓氏** 178 | 🔴 **A1: 80** · A2: 36 · B1: 5 · B2: 15 · C1: 42 |
| **名人** 36 | A1: 4 · A2: 5 · B1: 4 · B2: 7 · C1: 16 |
| 地理实体 ~220 | A1: 32 · A2: 45 · B1: 54 · B2: 78 · C1: 10 |

**🔴 125 条人名/名人被标为 A1/A2** —— 初学者不需要学 `chen`（中国姓氏）、`jones`、`wilson`、`mary`、`thomas`。

**样例**：
```
chen       CEFR=A1   a Chinese surname.
jones      CEFR=A1   a surname.
wilson     CEFR=A1   an English surname.
mary       CEFR=A1   a female first name, from Hebrew Miryam.
```

**影响**（保留后才有意义）：
- `word.frequency_rank` 设计上「用 CEFR 等级近似排序」→ **等级错了排序就错**
- 「按等级筛选/推荐内容」会把这些塞给初学者

**✅ 建议**：**专名的 `cefr_level` 置 `NULL`（无等级）**，而非硬塞一个等级。
排序时 `NULL` 排最后（或按 `entry_type` 单列一组）。

### 3.3 ✅ 保留清单（不再删除）

| 类 | 数量 | 例 |
|---|---:|---|
| **地理实体** | **~220** | `india` · `china` · `russia` · `texas` · `virginia` · `london` · `cambridge` · `bengal` · `calcutta` |
| **人名 / 姓氏** | **178** | `chen` · `jones` · `wilson` · `thompson` · `mary` · `thomas` · `elizabeth` |
| **名人** | **36** | `kafka` · `picasso` · `plato` · `sophocles` · `tchaikovsky` · `voltaire` · `rousseau` |
| **合计** | **~433（3.6%）** | 全部保留，走同一套流程 |

**→ 无需特殊机制**：这些词在划词、卡片、音频、生词本上都走**普通词条的同一套流程**。

> ⚠️ **一处精度交代**：地理实体的精确数量我未能给出（规则判据仍混入 `sky`/`war`/`health` 等含 "region of"/"state of" 的普通词）。
> **人名 178 / 名人 36 是严格判据的准确值**；地理实体量级 ~220，**精确分类需 LLM**（见 §3.4）。

### 3.4 🆕 衍生建议：`entry_type` 需细分 `subtype`

**理由**：白哥决策后，`proper` 不再需要「删/留」分流，但**仍需区分用途**：

| subtype | 用途 |
|---|---|
| `geographic` | 地理实体 —— 可入「地名/文化」类内容 |
| `person` | 人名/姓名/名人 —— **`cefr_level` 置 NULL**，不作难度统计 |
| `organization` | `un`/`nato`/`ussr` —— 新闻高频，正常处理 |

**→ 不细分也能上线**（走同一套流程），但**细分后能做「排除人名统计」**（如未来的生词数口径、难度分布）。

### 3.5 ⚠️ 仍需单独处理的（**不属于专名/姓名**，与本次决策无关）

| 词 | 性质 | 处置 |
|---|---|---|
| **`taiwan`** | 🔴 **涉中国主权** —— `a self-governing democracy` | ✅ **须改表述**（§二） |
| **`tibet`** | 🔴 **涉中国主权** —— `historically an independent kingdom` | ✅ **须改表述**（§二） |
| **`kulturbund`** | 🔴 **德语词 + 纳粹组织** —— 既非专名也非姓名 | 🗑️ **须删** |
| **`krystallographie`** | 德语拼写（非英语） | 🗑️ 建议删 |
| **`chemische`** | 德语（非英语） | 🗑️ 建议删 |
| **`ll`** | 撇号剥落（`'ll`）—— 不是姓名 | 🗑️ 建议删 |
| **`ve`** | 撇号剥落（`'ve`）—— 不是姓名 | 🗑️ 建议删 |
| `re` | 音阶名（虽也是 `'re` 剥落） | ✅ **保留**（合法音乐术语） |

### 3.6 ⚠️ 外语片段 21 条：**白哥逻辑适用，但与上轮批复冲突 → 请再定**

**上轮白哥说「外语片段删了」；本轮逻辑「删了还要再生成」同样适用于它们。** 我按能否出现在英文里分两类：

**① 常出现在英文短语中的 11 条** → 🟠 **建议保留**（`de facto` / `et cetera` / `du jour` 英文里真会用）

| 词 | 释义 |
|---|---|
| `de` | (Latin, used in phrases) of; from; concerning |
| `et` | (Latin) and; used in phrases such as "et cetera" |
| `cetera` | (Latin) the rest; other similar things |
| `du` | (French, used in English phrases) of the; from the |
| `hoc` | A Latin word meaning 'this', used in English phrases like 'ad hoc' |
| `rex` | (Latin, formal) a king |
| `vous` | (French) the formal or plural second-person pronoun |
| `mais` | (French) but; however |
| `dolce` | (Italian) Sweetness |
| `grazie` | (Italian) thank you |
| `los` | (Spanish) a definite article |
| `chien` | (French) dog |

**② 纯外语/生僻 10 条** → 🗑️ **建议删**

| 词 | 释义 | 理由 |
|---|---|---|
| 🔴 `kulturbund` | (German) ... a Nazi-era organization | **政治敏感** |
| `krystallographie` | (German) the science of crystal structure | 德语拼写 |
| `chemische` | (German) chemical | 德语 |
| `ciudad` | (Spanish) city | 西语 |
| `crus` | (French) a named vineyard | 法语 |
| `garson` | (French) a waiter | 法语 |
| `von` | (German origin) used in surnames | 德语 |
| `jason` / `evadna` / `titan` | Greek mythology | 神话人物（**非"专名"要件**，但属古籍角色） |

> **→ 我的建议：① 保留、② 删除。请白哥确认。**
> **理由**：①类在英文文本里会实际出现（用户会划到 `et`），②类不会 —— **与「删了要再生成」的判据一致**（①删了要重新生成，②删了没有场景）。


## 四、🔴 多词短语 142 条：设计完全空白

### 4.1 事实

| 指标 | 实测 |
|---|---|
| 词表含空格条目 | **142 条**（139 双词 + 3 三词） |
| 在 `word_form` 里的映射 | 🔴 **0 条** |
| 组成词也在词表中的 | **203 / 228**（如 `ice`+`cream` 都是独立词条） |
| `entry_type=phrase` | 26/26 抽样判定正确 |

### 4.2 🔴 四个未设计的问题

| # | 问题 | 现状 |
|---|---|---|
| **1** | **划词命中路径** | `word_form` 里 0 条 → 用户划到 `ice cream` **查不到** |
| **2** | **卡片结构** | 多个词的 IPA？例句？`sections` 怎么组织？**未定义** |
| **3** | **音频命名** | 音频要读**整个短语**（不是逐词）→ `{sort_seq:05d}_w.opus` 语义是否变？ |
| **4** | **组成词的重复计卡** | `ice`/`cream` 已是独立词条 → 短语与单词**会不会重复占复习位**？ |

### 4.3 附带发现：美英拼写重复 5 组

| 美式 | 英式 | 处理 |
|---|---|---|
| `sports center` | `sports centre` | 🔴 应合并（已有 `spelling_variant` 机制） |
| `driver's license` | `driving licence` | 🔴 应合并 |
| `disc jockey` | `disk jockey` | 🔴 应合并 |
| `check-in counter` | `check-in desk` | 🟠 可能同义 |
| `id card` | `identity card` | 🟠 可能同义 |

> 词表里还有 `cd player`（`cd` 应大写 CD）、`mp3 player`、`web page` 等小写缩写 —— 与 v1「**只朗读纯英文**」的 `is_english_only` 判据相关（`mp3` 怎么念？）。

### 4.4 建议（3 选项）

| 选项 | 做法 | 评价 |
|---|---|---|
| **A**（推荐） | **短语独立成卡**（`entry_type=phrase`）+ 组成词的 `word_form` 加**短语级映射**（`ice cream → ice cream` 自身） | 与 `entry_type` 设计一致 |
| **B** | 短语不建卡，只作为**组成词的搭配**（`ice cream` 挂到 `ice` 的 `collocation` 下） | 省卡，但**用户划短语查不到** |
| **C** | 从词表**删除短语**（只保留单词） | 🔴 **不建议** —— 这些是真实学习内容（`have to`/`used to`/`each other`） |

**需白哥定**：短语的**划词交互**（用户怎么划一个短语？长按选中两个词？）

---

---

## 五、🟠 IPA 多音标：卡片单字段装不下（583 条 = 4.9%）

### 4.1 事实

| 类型 | 数量 | 样例 |
|---|---:|---|
| 含 US/UK 双音标 | ~290 | `hello` = `/həˈloʊ/ (US) /həˈləʊ/ (UK)` |
| 含强/弱读变体 | 8 | `and` = `/ænd/ (stressed) /ənd/ (unstressed)` |
| 含多义音标 | 其余 | `the` = `/ðə/ (before consonant) /ðiː/ (before vowel)` |
| **合计非「单 `[...]`」** | **583 = 4.9%** | |

### 4.2 🔴 我之前的判断错了

`word-db-migration` 文档写：「`pronunciation` 100%（**95.1% 标准 `/.../`**）→ **5% 需规范化为 `/.../`**」

**→ 实测：这 5% 不是「格式不规范」，而是「有价值的多音标信息」** —— 强行规范化会**丢掉英美差异**。

### 4.3 建议

| 选项 | 做法 | 评价 |
|---|---|---|
| **A**（推荐） | 卡片 `ipa` **保留原文字符串**（不解析），展示层按需截取 | 零成本，不丢信息 |
| **B** | 拆 `ipa_us` / `ipa_uk` / `ipa_weak` 三列 | 需解析 583 条，规则不可靠 |
| **C** | 拆 `ipa_primary`（第一个）+ `ipa_note`（其余） | 与 A 类似但结构更清晰 |

**建议 A**：`card.content.ipa` 存原文，**不做结构化**（避免规则解析引入错误）。

---

## 六、🟠 缩写带句点未设计（6 条）

```
a.m.    before noon (from Latin 'ante meridiem').
p.m.    after noon, used in time expressions
dr.     same as dr, but with a period to indicate an abbreviation
mr.     a title used before a man's surname
mrs.    variant spelling of Mrs
ms.     variant spelling of Ms
```

**问题**：
1. 词表里**同时有** `dr` 和 `dr.`、`mr` 和 `mr.`、`ms` 和 `ms.` → **重复词条**
2. `word.spelling` 含 `.` → 划词时句点通常是**句末标点**，会被剥离 → 命中不到
3. `a.m.` 的 `word_form` 映射 0 条

**建议**：
- **保留无句点形式**（`mr`/`dr`/`ms`），删带句点重复项（4 条）
- `a.m.`/`p.m.` **保留带句点**（这是标准写法），但**同时建 `am`/`pm` 映射**（用户可能不带句点输入）
- ⚠️ 与 `am`（be 动词）/`pm`（Prime Minister）**冲突** → 需 `preferred` 优先级（P0-2 的机制可复用）

---

## 七、🟠 新的幻觉模式（7 条）

### 6.1 单字母后缀（2 条）

| 词 | 幻觉 | 应为 |
|---|---|---|
| `bidding` | `bid` + **`-d`** + `-ing` | `bid` + `-ing` |
| `given` | `give` + **`-n`** | `give` + `-en` |

**→ 与之前 `stable` 的 `st`、`resolute` 的 `-e` 是同一类（单字母词素）。规则校验可拦（已有方法论）。**

### 6.2 前缀误判（5 条）

| 词 | LLM 拆的 | 问题 |
|---|---|---|
| `fulfillment` | **`ful-`** + fill + -ment | 🔴 **`ful` 不是前缀**（应为 `fulfill` + `-ment`） |
| `deformity` | `de-` + form + -ity | 🟠 `de-` 语义已不透明 |
| `decorate` | `de-` + cor + -ate | 🟠 争议（`decor` 是词根） |
| `denounced` | `de-` + nounce + -ed | 🟠 可接受 |
| `endangered` | `en-` + danger + -ed | ✅ 可接受 |

**→ `ful-` 这条是硬错**（`fulfill` 来自 `full` + `fill`，不是 `ful-` 前缀）。

---

## 八、待白哥拍板

> ✅ **已批复（2026-09-26）**：
> - 「**india/china——这种国家名都删了？**」→ **地理实体保留**（我上轮建议错了）
> - 「**专有名词还是不删了，包括姓名，也都别删了，用户也有可能查，删了还要再生成**」→ ✅ **专名+姓名全部保留**（§三）；连带作废本轮「人名 178 + 名人 36 删除」的建议
> - 「**外语片段删了，拟声词删了**」→ ✅ 删

| # | 事项 | 我的建议 |
|---|---|---|
| **1** | 🔴🔴 **`taiwan`/`tibet` 主权错误表述** | ✅ **按官方立场修正**（§二.4）；**且必须全表扫描同类**（¥8–12） |
| **2** | 🔴🔴 是否**先做合规扫描再谈词库** —— 它决定「能不能上架」 | 🟠 **建议优先** —— 优先级高于全量重跑 |
| **3** | 🔴 **多词短语 142 条**：独立成卡 / 挂组成词 / 删除 | ✅ **独立成卡**（+ 需定**划词交互**） |
| **4** | 🔴 **专名 CEFR 等级标错 125 条**（`chen`/`jones` 标 A1） | ✅ **`cefr_level` 置 NULL**（不作难度统计），而非硬塞等级 |
| **5** | 🔴 **`a` 的释义错误** | ✅ 修（并**全表复查同类串位**） |
| **6** | ⚠️ **外语片段 21 条**：本轮逻辑适用，但上轮批复是「删」 | 🟠 **建议分两类**：①常现于英文短语的 11 条**保留**（`de`/`et`/`du`…）②纯外语 10 条**删**（含 `kulturbund`）§3.6 |
| **7** | 🗑️ **须删的非专名项** | ✅ `kulturbund` · `krystallographie` · `chemische` · `ll` · `ve`（§3.5） |
| **8** | ⚠️ **`nazi`/`nazis`/`ussr`/`un`/`nato`** 保留还是删 | 🟠 **建议保留**（新闻高频，且**不是"姓名"**） |
| **9** | ⚠️ **是否补入 `hong kong`/`macao`** | 🟠 建议补（当前词表缺；须用「中国香港/中国澳门」表述） |
| **10** | 🆕 **`entry_type` 是否细分 `subtype`**（geographic/person/organization） | 🟠 建议细分 —— 不做也能上线，但细分后能做「排除人名统计」 |
| **11** | 🟠 美英拼写重复 5 组 | ✅ 合并 |
| **12** | 🟠 **IPA 多音标 583 条** | ✅ **保留原文**，不结构化 |
| **13** | 🟠 缩写带句点 6 条 | ✅ 去重 + 建 `am`/`pm` 映射（用 `preferred` 消歧） |
| **14** | 🟠 单字母后缀 + `ful-` 前缀误判 | ✅ 用规则校验拦（已有方法论） |
| **15** | 🆕 **契约 v5 是否定稿**（`entry_type` + `etyma.parent`） | ✅ 定稿（本轮验证通过） |

---

## 九、方法论收获（本轮最重要）

| # | 收获 |
|---|---|
| **1** | 🔴 **判据要跟「功能」走，不是跟「数据形态」走** —— 我两轮都把专名当噪声（先「全隔离」、再「删人名」），**白哥一句「用户也有可能查，删了还要再生成」点破：判据应该是「这个词会不会被用到」，不是「它是不是专名」**。**这个判据下，专名和姓名都该留** |
| **2** | 🔴 **词表问题里混着「内容合规问题」，后者优先级高一个量级** —— `taiwan`/`tibet` 的错误表述是**法律 + 审核红线**，不是「数据不够干净」。我前几轮只盯数据质量，**漏了合规维度** |
| **3** | **LLM 的 `entry_type=proper` 是噪声检测器** —— 专名**全部**被识别（抽样 12/210）。**规则漏掉的小写专名，LLM 一次全标出**（但需细分 geographic/person 才能自动分流） |
| **4** | **「契约里加一条反制规则」比「修数据」快** —— `a` 的坏释义**没改数据**，只加「信任自身词汇知识」一条规则，LLM 自动纠正 |
| **5** | **「有争议的多音标」不是「脏数据」** —— 我此前判「需规范化」，实测是**英/美差异的价值信息** |
| **6** | **抽样偏差要说清** —— 新增 S3 组（短语/短词）拉高了整体自洽性，不可与上轮数字直接比 |
| **7** | **同一个错我犯了两轮** —— 先用宽泛正则把 `sister`/`father` 匹配成「人名」，又把国家名／人名匹配成「噪声」。**加规则前先看命中样例**；而且**两次都错在「用形态判价值」** |
| **8** | **我的成本视角不全** —— 只算了「建卡有没有教学价值」，**没算「删了之后用户查到要 LLM 再生成」**。白哥的成本视角是**全链路**的（含删除后的补救成本） |

**🔴 最重要的反思**：本轮的 `taiwan`/`tibet` 问题说明 —— **我的核查维度一直局限在「数据结构 + 数据质量」，没有覆盖「内容合规」**。
词表是**要交付给用户的内容**，不只是数据结构。**后续每轮核查都应加合规维度**（涉主权 / 涉政 / 涉黄暴 / 涉歧视）。

---

*本文档为审计产出，未修改任何代码或生产环境。*
