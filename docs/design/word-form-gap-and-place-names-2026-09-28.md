# 待办 1 & 2 修复方案：`word_form` 补漏 1,233 + 补地名

> 2026-09-28 ｜ 触发：白哥从待办中选「1（word_form 补漏 1,233）」与「2（补地名 hong kong）」
> **本文为调查产出，未改动 `word.db`。** 待审批后实施。
> 可复跑：`python3 scripts/audit_wordlist_diff.py`（原差异核查）
> 口径：所有数字均为对 `backend/cefr_catalog.json` · `data/word.db` · `data/curriculum/prebuilt/word_form.json` 的**本机实测**

---

## 〇、一句话结论

| 项 | 结论 |
|---|---|
| **1. `word_form` 补漏 1,233** | ✅ **精确复现，且旧表 100% 覆盖** —— 纯数据补行，**零 LLM 成本**，判据是语料实证。**可立即开工。** |
| **2. 补地名** | 🔴 **根因比「漏了几个词」深一层**：语料**分词把多词专名拆散**（库里从未有过 `hong kong` 这种形态）＋ 现有 `proper` 552 条是**布朗语料产物**而非场景化地名表。**修法有 3 个范围档，需白哥定。** |

**附带发现两项原报告未写的问题**（见 §三）：英美变体缺口 11 对 · **真·词元缺失含 `cannot`/`forward`/`corps` 等常用词**。

---

## 一、第 1 项：`word_form` 补漏 1,233

### 1.1 复现与覆盖验证（关键：证明「能补」）

| 检查 | 结果 |
|---|---|
| 「真·查不到」复现 | ✅ **1,233**（`plural 823 / adverb 243 / past 82 / ing 63 / superlative 12 / comparative 10`）—— 与 09-26 报告**逐项一致，未漂移** |
| 全量「真·查不到」总数 | 22,606（含 09-26 判定为「**不该补**」的语料长尾 21,362） |
| 🔑 **旧表能否覆盖这 1,233** | ✅ **1,233 / 1,233 = 100%** —— 且每个 `lemma` **都已在库**（`word` 表） |
| 旧表有映射但 lemma 不在库 | 11（`surprisingly→surprising` 等，边缘案例） |
| 旧表无该 form | 21,362（= 语料长尾，中位频次 1，**报告已明确不建议补**） |

> 🔑 **「1,233」这个数字的含义**：它**不是**「所有查不到的」，而是「**旧表能救回来的那一批**」。
> 剩余 21,362 条是布朗语料的生僻词/专名/古语 —— 补进来只会**稀释词库质量**（09-26 报告 §七结论）。

### 1.2 为什么「不补」21,362 仍然成立

反例验证（本次实测的残余，见 §2.5）：那批的样例是 `acknowledgement` · `agonise` · `airplane` · `backward`
—— 看着像常用词，但**中位语料频次 1**，且大量是 `barnumville` · `jarrodsville` 这类 1961 年美国小镇名。
**判据：语料频次是「真实使用」的唯一实证**；无该证据的一律不收。

### 1.3 修法（方案 A，推荐）

在 `word_form` 追加 1,233 行，**只补「`cefr_catalog` 里出现过 且 旧表有映射 且 lemma 在库」三条同时成立的**。

字段口径（对齐现有 22,829 行的主流约定）：

| 列 | 取值 | 依据 |
|---|---|---|
| `form` | 目标词形（如 `things`） | |
| `base` | 词元（如 `thing`） | |
| `rule` | `plural`/`past`/`ing`/`adverb`/`superlative`/`comparative` | 沿用旧表 |
| `kind` | 曲折 → `inflection`；`adverb` → `derivation` | ⚠️ 见 1.4 |
| `anchor` | = `base` | 现有行全部如此 |
| `anchor_id` | `word.id`（查库取） | |
| `depth` | `1` | 22,214 / 22,829 为 1 |
| `in_vocab` | `0` | 21,545 / 22,829 为 0 |
| `action` | `'keep'` | **全表 22,829 行统一是 `keep`** |

### 1.4 ⚠️ 顺带发现：`kind` 字段口径**不一致**（现存问题，非本次引入）

同一个 `rule='adverb'`，两套标法并存：

| `rule` | `kind` | 行数 |
|---|---|---:|
| adverb | `inflection` | **464** |
| adverb | `derivation` | **135** |

实例：`ably→able` 标 `inflection`，而 `abnormally→abnormal` 标 `derivation` —— **同是 -ly 派生，两种标法**。

**✅ 已核实其影响面（原先是「待核」，现已有结论）：**

实测 `app/lib` 全库，`word_form` 读出的字段里：
| 字段 | 消费者 | 结论 |
|---|---|---|
| `form` · `base` | `lookup()` 的命中判定 + `LemmaResult.base` | ✅ **真正生效** |
| `rule` · `kind` · `anchor` · `anchor_id` · `depth` · `in_vocab` · `action` | **0 处** | 🟢 **存了但从未被消费** |

> 🔑 **即：对 app 而言，`word_form` 的语义只有「`form` → `base`」这一条映射。**
> 其余字段目前是**惰性数据**。

**这带来两个推论**：
1. **`kind` 口径不一致是「观感/未来隐患」而非当前 Bug** → **优先级下调**，本次不必统一。
2. ✅ **同时说明第 1 项的风险比预想更低** —— 补的 1,233 行只要 `form`/`base` 对，**app 行为就一定正确**；
   其余字段即使口径有分歧，**当前不影响任何功能**。

⚠️ 但仍**按主流口径填**（`inflection` / `derivation` 区分），因为：
- 将来若做「变形提示 UI」会用到（见 §3.3）
- 与存量 22,829 行保持一致，避免制造第二批不一致

### 1.4b 🔴 附带发现：`LemmaResult` 的「变形提示」链路**只写不读**

代码注释写着（`word_query_service.dart:68`）：
> 返回的卡片带 `isLemmatized == true` 时，说明是**变形查到的词元**——
> 界面据此决定是否提示「received 是 receive 的变形」。

**实测**：`grep` 全 `app/lib` —— `isLemmatized` 与 `result.lemma` **在各界面里 0 处引用**
（`lookup_sheet.dart` 收了 `WordLookupResult result` 但从不读 `lemma`）。
→ 🔴 **这个「变形提示」UI 从未实现**，属「规格写了、未落地」。

🔑 与 MEMORY 既有判据同族：**「写了 A 端」≠「B 端会显示」**。
**影响**：用户划 `received` → 浮层显示的是 `receive` 的卡片，**但没有任何提示说明「这是变形」**
→ 用户可能以为「我明明划的是 received，怎么出来 receive？」（**易被读成「查错了」**）。
→ 记为**独立待办**（不属第 1、2 项范围）。

### 1.5 成本与风险

| | |
|---|---|
| LLM 成本 | **0**（纯数据，无内容生成） |
| 改动面 | `word.db` 的 `word_form` 表 **+1,233 行**（22,829 → 24,062，+5.4%） |
| 风险 | 🟢 **低** —— 判据是「语料出现过」的实证，不是启发式猜测 |
| 反向风险 | 若某条映射本身错（如旧表把 `X` 判成 `X` 的变形），会把**错的映射**固化。**缓解**：只取「旧表有 + catalog 有 + lemma 在库」三条交集，并**抽样人工过一遍** |
| 可回滚 | ✅ 补行前备份 `word.db`（`scripts/backup-db.sh`） |

### 1.6 验收方法（可复跑、可判红）

1. **补前跑** `scripts/audit_wordlist_diff.py` → 记下 1,233
2. 补行
3. **补后重跑** → 「真·查不到」应从 1,233 → **0**（指这 1,233 条全部命中）
4. 抽查 SQL：`SELECT COUNT(*) FROM word_form WHERE form='things'` → `1`，且离 `thing`
5. 覆盖排名表复核：前 2,000 高频可达率应 **96.0% → ~100%**

---

## 二、第 2 项：补地名

### 2.1 🔴 根因（三层，逐层加深）

#### ① 语料**分词把多词专名拆散** —— 库里从未存在过 `hong kong` 这种形态

实测 `cefr_catalog.json`：

| 键 | 语料频次 | 说明 |
|---|---:|---|
| `hong` | 11 | ← 「Hong Kong」被切成两半 |
| `kong` | 11 | ← 同上 |
| `rhode` | **105** | ← Rhode Island |
| `angeles` | 47 | ← Los Angeles |
| `francisco` | 41 | ← San Francisco |
| `orleans` | 40 | ← New Orleans |

🔑 **判据：`cefr_catalog` 是「单词形表」（41,574 条，键全小写）** → 它**在结构上不可能**给出多词专名。
→ 而端侧词库的词条来源依赖它 → **`hong kong` 两边都不存在**，这是**必然而非疏漏**。

#### ② 现有 `proper` 552 条是**布朗语料产物**，不是场景化地名表

| 在库（proper） | 不在库 |
|---|---|
| `london` `china` `america` `india` `russia` `africa` `asia` `australia` `belgium` `sweden`… | 🔴 `paris` `berlin` `england` `france` `germany` `canada` `spain` `japan` `moscow` `cuba` `boston` `rome` `california` `philadelphia` |
| `barnumville` `jarrodsville` `fleischmanns` `chattanooga` `charlottesville`（1961 年美国小镇） | |

🔑 **「有 `barnumville` 却没有 `paris`」= 收词口径是「语料撞上什么算什么」，不是按使用场景设计。**
「专名保留」决策**已定**（见 09-26 报告 §5.4），只是**这 552 条不是按该决策筛出来的**。

#### ③ 划词是**多词选择**，直接透传给查询

```
reader_screen._onSelectionChanged(SelectedContent)
  → _cleanPicked(text)          // 只 .trim()
  → WordQueryService.lookup(text)
      → _normalize(text)        // .trim() + 折叠连续空白
      → SELECT … WHERE w.spelling = ?   // ✅ 列本身 COLLATE NOCASE
```
✅ **大小写不是问题**（`word.spelling` 是 `COLLATE NOCASE`，实测 `London`/`LONDON`/`london` 全命中）。
🔴 **问题是「没有那个条目」** → 返回 `null` → 走 **LLM 兜底**（慢 + 花钱 + 卡片质量低于预制卡）。

### 2.2 影响面（为什么这件事对**本项目**格外重要）

**内容源是 VOA/BBC 新闻 RSS**（MEMORY 主线）—— 新闻体裁里**地名出现频率极高**：
「Hong Kong」「New York」「South Korea」「Saudi Arabia」「United Arab Emirates」…
→ 用户每次划到地名都走 LLM 兜底。**这是高频路径上的持续成本 + 体验损耗。**

### 2.3 范围选项（需白哥定）

| # | 范围 | 条数 | 含 | 评价 |
|---|---|---:|---|---|
| **A** | 布朗高频专名（09-26 报告 §5.4 已列） | **24** | `washington` `england` `europe` `paris` `berlin` `france` `germany` `british` `rome` `california`… | 补「已知的洞」，**不含多词形式 → 修不了 `hong kong`** |
| **B** ⭐ | **新闻常用地名表**（国家 + 首都 + 主要城市 + **多词形式**） | **150~250** | A 全部 ＋ `hong kong` `new york` `south korea` `saudi arabia` `united states` `new zealand`… | ✅ 直接对准内容源；✅ A 是它的子集 |
| **C** | 残余 343 中的**全部**专名 | ~170 | B ＋ **人名** `william` `george` `tom` `parker` `richard` `james`… | ❌ 人名是布朗语料噪声（1961 年美国人名），**不建议** |

**我的建议：B。**
理由：A 修不了 `hong kong`（白哥点名的就是这个）；C 把 `tom`/`parker` 收进学习词库会稀释质量。
B 是「**按内容源的实际需要**收词」——与「订阅正当性 = 文章每日更新的持续价值」这条产品逻辑一致。

### 2.4 成本（⚠️ 比第 1 项贵得多，需知情）

地名要作为**完整词条**入库（不能只加 `word_form`，因为没有 base 词元可映射）：

| 表 | 每条 | 是否需 LLM |
|---|---|---:|
| `word` | 1 行 | ❌ |
| `card` | 1 行（`content` JSON：`front`/`ipa`/`entry_type`/`sections`） | ✅ **需要** |
| `word_mnemonic_profile` | 1 行 | ✅ |
| `word_etymon` | 1 行 | ✅ |
| `word_collocation` | 3 行 | ✅ |

实测参照（`london`）：`card.content` 587 字节 · `sections` 4 段 · `word_collocation` 3 条。
→ **B 档 ≈ 200 条 × 1 次 LLM 调用**（可走既有 skill `llm-batch-content-fill` 的批处理 + 断点续跑）。

### 2.5 残余缺口全景（补完第 1 项后，freq ≥ 20 的 343 条）

补完 `word_form` 后，`freq ≥ 20` 仍查不到 **343 条**，构成：

| 类 | 数量 | 样例 |
|---|---:|---|
| **专名/地名** | ~170 | `washington` `england` `french` `george` `europe` `british` `rhode`(Island) `james` `german` `germany` `france` `berlin` `rome` `paris` `california` `boston` `cuba` `moscow` `canada` `poland`… |
| 🔴 **真·词元缺失**（**常用词！**） | ~80 | `cannot`(258) `forward`(115) `corps`(110) `older`(93) `fourth`(83) `connection`(69) `machinery`(60) `intensity`(59) `grounds`(58) `wagon`(57) `permitted`(57) `mantle`(48) `integration`(48) `interference`(46) `doctrine`(46) `precision`(46) `removal`(43) `warfare`(43) `comparable`(42)… |
| **英美变体** | 11 对 | 见 §三① |
| **多词专名碎片** | 4 | `rhode` `angeles` `francisco` `orleans` |

> ⚠️ **343 是「freq ≥ 20」的口径** —— 放宽到 freq ≥ 1 还有更多，但那批按 09-26 判据属长尾，不收。

---

## 三、🔴 附带发现（原 09-26 报告未写）

### ① 英美变体缺口：24 对抽测里 **11 对有洞**

| 类型 | 数量 | 实例 |
|---|---:|---|
| **两个变体都不在库**（划词**必失败**） | **3** | `labor` / `labour` · `behavior` / `behaviour` · `dialog` / `dialogue` |
| 只有一个变体在库（另一边失败） | **8** | `honor`❌/`honour`✅ · `center`✅/`centre`❌ · `theater`❌/`theatre`✅ · `traveled`✅/`travelled`❌ · `canceled`✅/`cancelled`❌ · `modeling`✅/`modelling`❌ · `program`✅/`programme`❌ · `catalog`❌/`catalogue`✅ |

⚠️ **`behavior`/`labour` 是高频词**（freq 96 / 149）—— 用户划到就是失败。
→ 建议作为**独立一批**（09-26 报告方案 D），可与第 2 项**合并实施**（都要生成卡片，可复用同一批 LLM 调用）。

### ② 真·词元缺失里含**常用词**（优先级可能高于地名）

`cannot`(258) · `forward`(115) · `corps`(110) · `older`(93) · `fourth`(83) ·
`connection`(69) · `machinery`(60) · `intensity`(59) · `wagon`(57) ·
`integration`(48) · `doctrine`(46) · `precision`(46) · `removal`(43) · `warfare`(43)

🔑 **这是一条与地名独立的问题线** —— 不是「变形漏了」，也不是「专名没收」，而是**词元本身就缺**。
其中 `older`/`fourth`/`sixth`/`seventh` 属「序数/比较级未独立成条」，`cannot`/`forward`/`corps` 则是**实打实的常用词遗漏**。

> **建议**：`cannot` / `forward` / `corps` 这类**比地名更该先补**（用户划到的概率更高、且不是专名）。
> 是否开一条独立待办，请白哥定。

---

## 四、待白哥决策

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | **第 1 项（1,233 补行）是否开工？** | ✅ 建议开工（零 LLM、判据实证、可回滚） |
| 2 | **第 2 项地名取哪个范围档**（A 24 / **B 150~250** / C ~170） | ⭐ **B**（对准新闻内容源；A 修不了 `hong kong`） |
| 3 | **英美变体（§三①）是否合并进第 2 项一起做？** | ✅ 建议合并（同批 LLM 调用，边际成本低） |
| 4 | **§三②真·词元缺失是否新开待办？** | ⭐ 建议新开（`cannot`/`forward` 优先级可能高于地名） |
| 5 | **`kind` 字段口径不一致（§1.4）是否本次一并统一？** | ❌ 建议本次只保证**新增行**正确，存量 464 行另立待办（已核实：**无消费者**，不是当前 Bug） |
| 6 | **§1.4b 的「变形提示」UI 缺失是否开待办？** | ⭐ 建议开（规格已写、未落地；用户可能误读成「查错了」） |

**实施顺序建议**：**第 1 项（零成本、当天可完成）→ 验收 → 再定第 2 项范围 → 实施**

---

*本文为调查产出，**未改动 `word.db`**。原差异核查脚本 `scripts/audit_wordlist_diff.py` 可复跑。*
