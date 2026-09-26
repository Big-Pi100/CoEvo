# 词库字段设计审计（2026-09-26）

> **触发（白哥）**：「看看字段设计还有没有问题」
> **方法**：对 `word-db-schema-frozen-2026-09-26.md` 的 15 张表逐字段核验 —— **用真实数据验证约束是否成立**，不凭直觉
> **数据源**：`data/coevo.db`（11,917 词）+ `word_form.json`（36,856 条）+ `llm_rerun_sample.json`（契约 v3，160 词 × 2 轮）+ SQLite 约束行为实测
>
> **🔴 结论：发现 19 个问题 —— 3 个 P0（会建表失败 / 数据丢失）、8 个 P1（逻辑不一致 / 语义未定义）、8 个 P2（范围与可行性风险）**
>
> ---
>
> ## ⚠️ 更新（2026-09-26 白哥批复 + 深化核实）：P0 三项**已处置**
>
> | P0 | 白哥的方案 | 处置结果 | 核实补充 |
> |---|---|---|---|
> | **P0-1** 词根/词缀唯一键 | 「**词缀要有词缀表**，分解后的词缀优先在词缀表中选择释义，没有也不强行匹配、**允许增加**」；并问「**词根是否也有同样问题**？」 | ✅ **新建 `affix` 表** + `word_root` 改唯一键；**匹配策略**见下 | 🔴 **词根问题性质不同**：词缀 27% 是**同形多义**；词根 0.9% 是**同形异源**（`rod`: Latin 咬 vs Old English 汽车）→ **`origin` 必须进唯一键**（**推翻本文档 P2-19 的原建议**）<br>🔑 附**连带收益**：词缀义表述极不一致（`-ed` 8 种/`-er` 6 种/`re-` 5 种），归一化压缩 **24%** |
> | **P0-2** `word_form` 二义 | 「**是否应该是链式的，从而推导到根本**？」 | ✅ **改链式**：加 `base`/`anchor`/`anchor_id`/`depth`/`kind`，`anchor` 预计算 | 🔴 **实证链式必需**：`derived_from` 有 **12.3%（13/106）** 指向词表外，其中 **3 条 `is_own_entry=false` 会划词无卡**（`slaying→slay`·`eroded→erode`·`freeholders→freeholder`）→ 全量预估 **≈330 词受影响**<br>📌 另：`word_form.lemma` 实测 **100% 在词表**（正向展开保证）→ 原设计「一跳可达」对新词形不成立 |
> | **P0-3** `sort_seq` NULL | 「**写 NOT NULL**」 | ✅ 已改 | — |
>
> **⚠️ 本文档 P2-19 的原建议「`origin` 不参与唯一约束」已被推翻** —— 当时只看到 `-ant`/`-e` 的 French/Latin 分歧，**没意识到 `rod` 是「同形异源」而非「多义」**。
>
> **详见**：`word-db-schema-frozen-2026-09-26.md` §1.1（P0-3）/ §1.2（P0-2 链式）/ §1.5（P0-1 词缀表）


---

## 〇、速查表

| 级 | # | 问题 | 后果 |
|---|---|---|---|
| **P0** | 1 | `word_root.UNIQUE(form,type)` **与实测冲突** | 🔴 词缀义因词而异 → 强行唯一会**丢义** |
| **P0** | 2 | `word_form` **129 条 form→多 lemma 二义** | 🔴 运行时**无法决定跳哪张卡** |
| **P0** | 3 | `sort_seq UNIQUE` 无 `NOT NULL` | 🔴 多个 NULL 被接受 → **唯一性失效** |
| **P1** | 4 | `word_form.word_id` 语义未写清 | 🟠 实测指向 **lemma**，文档写「→ word.id」有歧义 |
| **P1** | 5 | `spelling` 大小写敏感 | 🟠 `India`/`india` 可并存（潜在） |
| **P1** | 6 | `word_root_link.relation` 词级属性存在行级 | 🟠 每词素重复一次 |
| **P1** | 7 | `card_audio.section_index` 指代未定义 | 🟠 无法确定指向 `sections[]` 还是 `card_extra` |
| **P1** | 8 | `card_extra` 是否计入 `content_hash` 未定义 | 🟠 变更后**音频不重生成** |
| **P1** | 9 | `etymology` 双重存储 | 🟠 两处必然分叉 |
| **P1** | 10 | 契约缺跨字段约束 | 🟠 实测 6 条 `primary=root` 但 `analyzable=false` |
| **P1** | 11 | `related_phrases` 含 **275 条垃圾搭配** | 🟠 占位符被当搭配导入 |
| **P2** | 12 | `collocation.phrase UNIQUE` + 单 `chinese` 列 | 🟡 同短语异义会丢 |
| **P2** | 13 | `etymology` 生成率 **91.9%** 远超设计意图 | 🟡 范围失控，成本与卡片膨胀 |
| **P2** | 14 | **`cognate_group` 可能大片为空** | 🔴 **聚合页面临「无内容」** |
| **P2** | 15 | `mnemonic_type` 的 `cognate` 被滥用 | 🟡 谐音联想被当成同源 |
| **P2** | 16 | `secondary_codes` 存 JSON 数组 | 🟡 违反 1NF，不能 FK/索引 |
| **P2** | 17 | `aggregate_page_word.sort_seq` 重复 | 🟡 与 `word.sort_seq` 冗余 |
| **P2** | 18 | `word_root` 会收录幻觉词素 | 🟡 `-e`/`st`/`a-` 入库 |
| **P2** | 19 | `word_root.origin` 不稳定 | 🟡 3 例同词素多 origin |

---

## 一、P0-1 🔴 `word_root.UNIQUE(form, type)` 与实测冲突　→ ✅ **已处置（新建 `affix` 表 + `origin` 进唯一键）**

### 证据

抽样 160 词中，出现 **176 个 (form, type) 组合**，其中 **19 个有多个不同 `meaning`**：

| 词素 | type | 义项数 | 各义（来自不同词） |
|---|---|:--:|---|
| **`-er`** | suffix | **6** | `…的人`(rodder) · `从事…的人`(farmer) · `…的物/程序`(autocoder) · `表工具或施动者`(folder) · `反复动作` |
| **`re-`** | prefix | **5** | `再/加强`(resolute) · `再、回`(retrieve) · `再，加强`(resemble) · `再；回`(respectably) |
| **`-ing`** | suffix | **4** | `正在…`(emphasizing) · `…的`(surprising) · `…业/活动`(slaying) · `名词化` |
| **`in-`** | prefix | **3** | `不`(involuntarily) · `内`(insect) · `向内`(involved) |
| **`-ly`** | suffix | **3** | `…地` · `以…方式` · `副词后缀` |
| `-y` | suffix | 3 | `充满…的` · `像…的` · `如…的` |
| `-ation` `-s` `-ent` `-ant` `-e` `com-` | — | 2 | 略 |

### 分维度统计（关键）

| 词素类型 | 有歧义的 | 总数 | 歧义率 |
|---|---:|---:|---:|
| **前缀 / 后缀** | **18** | 67 | 🔴 **27%** |
| **词根** | **1** | 109 | ✅ **0.9%** |

**→ 规律：词根义稳定（可共享），词缀义随词而变（不可共享）。**

### 后果

`UNIQUE(form, type)` 强制 `-er` 只能有一行 → **5 种义只剩 1 种** → 其余词查不到自己的词缀义 → 卡片显示错误的词根说明。

### 建议（3 选项）

| 选项 | 做法 | 评价 |
|---|---|---|
| **A**（推荐） | `word_root` 改 **`UNIQUE(form, type, sense)`** —— 允许同一词素多义，各义一行 | 保留共享（同义词复用），不丢义 |
| **B** | 去 `UNIQUE`，`word_root` 退化为**每词一行** | 失去共享表意义，`word_root_link` 变多余 |
| **C** | `word_root.meaning` 存**规范义**（如「名词后缀」），**每词细义移到 `word_root_link.gloss`** | 结构性最干净，但需新增字段并改契约落点 |

> **A + C 可组合**：`word_root(form,type,sense)` 存规范义 + `word_root_link.gloss` 存该词中的具体义。

---

## 二、P0-2 🔴 `word_form` 的 129 条路由二义性　→ ✅ **已处置（改链式，加 `anchor` 预计算）**

### 证据

`word_form` 36,856 条中，**一个 form 指向多个 lemma 的有 129 条** —— **且这 129 条的两个 lemma 全部都在词表里**（即真的会在运行时撞车）：

| form | → lemma A | → lemma B |
|---|---|---|
| `aided` / `aiding` | `aid` | `aide` |
| `bathed` / `bathing` | `bath` | `bathe` |
| `blonded` / `blonding` | `blond` | `blonde` |
| `anted` / `anting` | `ant` | `ante` |
| `arted` / `arting` | `art` | `arte` |
| `bobbies` / `bobbied` | `bobbie` | `bobby` |

### 后果

用户划到 `aided` → 查 `word_form` → **返回 2 条映射（aid、aide）** → 跳哪张卡？**无规则**。
`PRIMARY KEY (form, lemma)` 允许这种多行，但没有「选哪个」的定义。

### 建议

**加 `preferred INTEGER`（或 `rank`）标记唯一首选**，并在构建时用规则定序：
1. 优先 lemma 在词表中 `cefr_level` 更低者（更基础 = 更可能是用户要找的）
2. 同级则取**更短的 lemma**（`aid` < `aide`）
3. 仍平则取 `MIN(sort_seq)`

**约束**：`UNIQUE(form) WHERE preferred=1`（部分唯一索引）保证每 form 恰有一个首选。

---

## 三、P0-3 🔴 `sort_seq UNIQUE` 的 NULL 漏洞　→ ✅ **已处置（加 NOT NULL）**

### 证据（SQLite 实测）

```sql
CREATE TABLE w (id TEXT PRIMARY KEY, sort_seq INTEGER UNIQUE);
INSERT INTO w VALUES ('a', NULL);
INSERT INTO w VALUES ('b', NULL);   -- 🔴 被接受
```

**SQLite 的 `UNIQUE` 不约束 NULL** —— 多条 NULL 合法 → **唯一性形同虚设**。

### 后果

若构建脚本漏填 `sort_seq`，音频命名 `{sort_seq:05d}_w.opus` 会**多词同名 → 音频互相覆盖**。

### 建议

```sql
sort_seq INTEGER NOT NULL UNIQUE
```

---

## 四、P1 级（8 项）

### P1-4 🟠 `word_form.word_id` 语义未写清

**实测：36,856 / 36,856 = 全部指向 `lemma` 的卡片 id**，不是 form 自己的。
文档写「`word_id TEXT -- → word.id`」，**未说明是哪个词的 id**。
**建议**：改注释为 `-- → lemma 的 word.id（不是 form 自己的）`。

**🟢 附带澄清一个此前的担心**：`word_form` **不会**出现「lemma 不在词表」的情况 ——
因为它是**从词表词正向展开**生成的（`build_word_form.py`），lemma 必然在词表。
所以 `attuned → attune`（`attune` 不在词表）**根本没有映射** ✅ —— 这正是 `derived_from` 必须存在的原因。

### P1-5 🟠 `spelling` 大小写敏感

SQLite 默认 `TEXT` 比较**大小写敏感** → `UNIQUE(spelling)` 允许 `India` 与 `india` 并存。
**当前词表 0 条大小写重复**（已实测）→ 是**潜在**风险而非现行问题。
但词表含 `Isaac`/`Jan`/`India`/`Sunday` 等专名 → 未来补词时易撞。
**建议**：`spelling TEXT NOT NULL COLLATE NOCASE`（或统一小写存储 + 显示层还原）。

### P1-6 🟠 `word_root_link.relation` 是词级属性，却存在行级

`relation ∈ {inflection, derivation, compound}` 描述**整个词的构词方式**，
却放在 `word_root_link`（**每个词素一行**）→ 一个 3 词素的词会把同一个值存 3 遍。

**更关键**：它的两个用途**都是迁移期一次性**的 ——
① 决定 `word_form` 旧映射去留（§1.2）② 排除 `inflection` 出 `cognate_group`（§1.7）。
**运行时不查它。**

**建议（2 选项）**：
- **A**：上移到 `card.content` JSON（不建列）—— 它是分析元数据，不是查询维度
- **B**：若要在库中审计，加 `word.morphology_relation`（**词表一行**，不重复）

### P1-7 🟠 `card_audio.section_index` 指代未定义

`card_audio` 有 `audio_type ∈ {word, section}` + `section_index`。
但「section」有**两个来源**：`card.content.sections[]` 与 `card_extra`。
**`section_index` 指向哪一组？未定义** → 音频与卡片可能错配。

**建议**：加 `scope TEXT CHECK(scope IN ('section','extra'))`，或统一编号空间（extra 接在 sections 之后）。

### P1-8 🟠 `card_extra` 是否计入 `content_hash` 未定义

v1 的 `content_hash` 用途是「判断是否重新生成音频」（评审 §十 第 8 条）。
但 `card_extra` 独立成表 —— **若 `content_hash` 只算 `card.content` 列，则 `card_extra` 变更不会触发音频重生成**。

**建议**：明确定义 `content_hash = hash(card.content + 该词全部 card_extra.section)`，或对 extra 单独记 hash。

### P1-9 🟠 `etymology` 双重存储

落点映射写：`etymology` → **同时**写入 `word.etymology_text` **和** `card.content.sections[type=etymology]`。
**同一字符串两处存储** → 一旦任一处可编辑就会分叉。
（我们刚删掉 `base_form` / `lemma` 两处同类冗余，这里又有一处。）

**建议**：**只存 `card.content.sections[type=etymology]`**，删 `word.etymology_text`
（或反之 —— 若词源要独立检索，则只留 `word.etymology_text` 并在卡片渲染时读取）。

### P1-10 🟠 契约缺跨字段约束 → 实测 6 条逻辑矛盾

| 矛盾 | 实测 | 性质 |
|---|---|---|
| `primary=root` 但 `analyzable=false` | **6**（`feet`·`native`·`moderate`·`notion`·`unite`·`analyses`） | 🔴 **不可分析却选了「词根法」** |

其余交叉检查**均通过** ✅：`own=false` 但 `derived_from` 空 = 0 · `relation` 非空但 `analyzable=false` = 0 · `relation=inflection` 但 `derived_from` 空 = 0 · `primary=collocation` 但无搭配 = 0 · `primary=etymology` 但无词源 = 0。

**建议**：契约加硬约束 **`primary=root` ⟹ `analyzable=true`**。

### P1-11 🟠 `related_phrases` 含 275 条垃圾搭配

从现网 `related_phrases` 解析出 **24,624 条搭配**，其中 **275 条（1.1%）是占位符**：

| 出现次数 | 内容 |
|---:|---|
| 43 | `(none common)` |
| 21 | `(none)` |
| 18 | `none` |
| 11 | `(none specific)` |
| 5 | `(rare` |
| 4 | `none common` |
| 3+3+2+2+2+2+2+2 | `(none common enough to list separately)` · `(none additional)` · `(none common; used as manner adverb)` · `(none specific; used as a phrase)` · `(no common collocations)` · `(in) di` · `(see evoke)` · `(same as grok)` |

**根因**：现网 `related_phrases` 生成时，对「无搭配」的词写了 `(none)` 之类的占位说明，
**解析脚本会把括号内容当搭配**。
**建议**：导入前加过滤 —— 命中 `^\(` 或 `^none$` / `^rare$` 的丢弃，并记录被丢弃清单。

---

## 五、P2 级（8 项）

### P2-13 🟡 `etymology` 生成率失控

| 项 | 值 |
|---|---|
| LLM 产出 `etymology` 非空 | **147/160 = 91.9%** |
| v1 §4.1 设计意图 | 只对「**外来整体词**」→ 原估 ≤2,000 / 11,917 = **16.8%** |
| **其中可拆词也带了词源** | **102 个**（本应「可拆词用词根、不可拆词用词源」） |

**→ 实测 91.9% 是设计意图的 5.5 倍。**
**后果**：① token 成本上升 ② 卡片内容膨胀（违背「一页容量上限 4 sections / 300 字」）③ 与词根 section 功能重叠。
**建议**：契约收紧 —— `etymology` 仅在 `analyzable=false` 且属外来整体词时填写。

### P2-14 🔴 `cognate_group` 可能大片为空（聚合页最大风险）

**实测**：抽样 107 个可拆词 → 展开出 **109 个不同词根**（几乎 1:1）

| 门槛 | 词根数 |
|---|---:|
| ≥2 词共享 | **3** |
| ≥3 词共享（聚合页有意义的门槛） | **0** |

**→ 107 个可拆词只能凑出 3 个族、覆盖 6 个词。**

**⚠️ 但必须诚实交代偏差**：抽样是**跨 CEFR 分层随机**，`receive`/`perceive`/`conceive` 这类同族词**极难同时被抽中** → **样本天然低估族的形成率**。
**→ 此事抽样无法定论，必须全量跑完后验证。**

**建议**：全量跑完后立即统计 ——
```
SELECT group_key, count(*) FROM cognate_group_member GROUP BY group_id HAVING count(*)>=3;
```
若 ≥3 词的族占比 < 10%，则**聚合页（v1 §4.3）实际不可用**，需重新评估是否值得做。

### P2-15 🟡 `mnemonic_type` 的 `cognate` 被滥用

抽样中 `primary=cognate` 的 5 条：`papa` · `lard` · `path` · `sound` · `ptolemaic`

**其中 `papa` 的理由是「与中文『爸爸』发音相似」** —— 这是**谐音联想**，不是**同源**（cognate 严格指 PIE 同源词族）。
**→ 说明 `mnemonic_type.applicable_when` 的判据没写清，LLM 自行放宽了 `cognate` 的语义。**
**建议**：给 `mnemonic_type` 补严格定义 —— `cognate` = 「**与另一个英语词共享同一词根/词源**」，谐音归 `image`。

### P2-16 🟡 `secondary_codes` 存 JSON 数组

`word_mnemonic_profile.secondary_codes TEXT -- JSON array`
→ 违反 1NF，**不能 FK 到 `mnemonic_type`、不能索引**。
**影响**：无法查询「哪些词把 cognate 作为次记忆法」。
**建议**：若需查询 → 拆 `word_mnemonic_secondary(word_id, code)`；若不需要 → **明示它是只读展示字段**（可接受）。

### P2-17 🟡 `aggregate_page_word.sort_seq` 与 `word.sort_seq` 冗余

两张表都有 `sort_seq` —— 若含义相同则重复；若含义不同则应改名区分。
**建议**：改为 `ord`（**页内**排序），与 `word.sort_seq`（**全局**音频命名序号）明确区分。

### P2-18 🟡 `word_root` 会收录幻觉词素

抽样第 1 轮的幻觉词素（第 2 轮自行放弃）：

| 词 | 幻觉词素 | 问题 |
|---|---|---|
| `stable` | **`st`** | 不是词根 |
| `resolute` / `retrieve` / `resemble` | **`-e`** | 不是后缀 |
| `awoke` | **`a-`** | 不应独立 |
| `eroded` | **`e-`** | `ex-` 变体，不应独立 |

**这些会成为 `word_root` 表的正式行**（且因 `UNIQUE(form,type)` 可能污染共享表）。
**建议**：入库前用**规则做校验**（§2.1 已确立的合法用法）——
词素 `form` 去连字符后长度 ≤1 的 `prefix`/`suffix`（除 `-s`/`-y`/`-a` 等真后缀白名单）标记可疑。

### P2-19 🟡 `word_root.origin` 不稳定　→ 🔴 **原建议已被推翻**

同一 `(form,type)` 有多个 `origin` 的：**3 例** —— `-ant`(French/Latin) · `-e`(French/Latin) · `rod`(Latin/Old English)

**~~建议：`origin` 不参与唯一约束~~ → 🔴 推翻。** 深化核实后发现 **`rod` 不是「多义」而是「同形异源」**：

| 词 | `meaning` | `origin` | 真相 |
|---|---|---|---|
| `eroded`（侵蚀） | 咬 | **Latin** | 拉丁 `rodere`（咬） |
| `rodder`（汽车迷） | 汽车（俚语） | **Old English** | 英语 `rod`（棒/汽车） |

**→ 若按 `(form,type)` 合并，会把两个不同词源「造出假词源」。**
**→ ✅ `origin` 必须进唯一键：`UNIQUE(form, type, origin)`。**
（我原建议的错误：只看到 `-ant`/`-e` 的 French/Latin 分歧，误判为「origin 不稳定」，
**实际那是词缀传承路径的正常分歧，而 `rod` 是完全不同的两个词根**。）

---

## 六、建议的处置顺序（P0 已处置，见顶部更新）

| 序 | 事项 | 性质 | 阻塞什么 | 状态 |
|---|---|---|---|---|
| **1** | **P0-1** 新建 `affix` 表（`UNIQUE(form,type,sense)`）+ `word_root` 改 `UNIQUE(form,type,origin)` + `word_morpheme.gloss` | 结构 | **建表即错** | ✅ **已处置** |
| **2** | **P0-3** `sort_seq NOT NULL` | 一行 DDL | **音频命名** | ✅ **已处置** |
| **3** | **P0-2** `word_form` 改链式（`base`/`anchor`/`anchor_id`）+ 中间节点补跑 LLM | 结构 + 构建逻辑 | **划词跳转** | ✅ **已处置** |
| **4** | **P1-11** 过滤 275 条垃圾搭配 | 清洗脚本 | 搭配导入 | ⏳ |
| **5** | **P1-9** 解决 `etymology` 双存 | 结构（删一列） | 卡片渲染 | ⏳ |
| **6** | **P1-7 / P1-8** 定义 `section_index` 与 `content_hash` 覆盖范围 | 定义 | **Phase 2 语音包** | ⏳ |
| **7** | **P1-10** 契约加 `primary=root ⟹ analyzable` | 契约 | 重跑前 | ⏳ |
| **8** | **P2-13** 收紧 `etymology` 生成条件 | 契约 | 成本 | ⏳ |
| **9** | **P2-14** 全量后验证 `cognate_group` 规模 | **验证** | **聚合页是否值得做** | ⏳ |

---

## 七、待白哥拍板

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | `word_root` 唯一键 → `(form,type,sense)`；每词细义移 `word_root_link.gloss` | ✅ **P0，必须改**（A+C 组合） |
| 2 | `sort_seq` 加 `NOT NULL` | ✅ **P0，必须改** |
| 3 | `word_form` 加 `preferred` + 三级定序规则（CEFR → 长度 → sort_seq） | ✅ **P0，必须改** |
| 4 | 过滤 275 条垃圾搭配 + 记录清单 | ✅ 建议 |
| 5 | `etymology` 只存一处（删 `word.etymology_text`） | ✅ 建议（否则必分叉） |
| 6 | `relation` 上移到 `card.content` JSON（不建列） | 🟠 建议 —— 它运行时不需要 |
| 7 | `card_audio` 加 `scope` 列（section/extra） | 🟠 建议 |
| 8 | 契约加 `primary=root ⟹ analyzable=true` | ✅ 建议 |
| 9 | `etymology` 收紧为「仅不可拆的外来词」 | 🟠 建议 —— 但也可接受现状（词源本身有帮助） |
| 10 | `cognate` 判据收紧（同源 ≠ 谐音） | ✅ 建议 |
| 11 | 全量跑完后先验证 `cognate_group` 规模，再决定聚合页是否做 | ✅ **建议前置** |

---

## 附：本次核验用到的数据与脚本

| 项 | 说明 |
|---|---|
| `data/coevo.db` | 11,917 词表 + `related_phrases` 24,624 条解析 |
| `data/curriculum/prebuilt/word_form.json` | 36,856 条映射（129 条二义） |
| `data/curriculum/prebuilt/llm_rerun_sample.json` | 契约 v3 抽样 160 词 × 2 轮 |
| SQLite 约束实测 | `UNIQUE` 的 NULL 漏洞、大小写敏感性 |

*本文档为审计产出，未修改任何代码或生产环境。*
