# 全量生成完成报告

- 日期：2026-09-26
- 范围：11,917 词表词 LLM 全量重跑 + 后处理全链路（词缀归一化 → 链式 → 中间节点补跑 → 落库）
- 状态：**全链路已跑通，18 表落库完成**；发现 **1 个设计缺口**（etymon 聚合页未实现）待请示

---

## 〇、速查

| 环节 | 结果 | 成本 |
|---|---|---|
| 全量生成 | **11,917 / 11,917 = 100%** · 0 遗漏 · **42 秒** | ¥63.89 |
| 🆕 **词表补录** | **+980 词**（LLM 判值得独立成卡的中间节点）· 链断 **396 → 0** | ¥1.03 |
| 🆕 **词表补录** | **+980 词**（LLM 判值得独立成卡的中间节点）· 链断 **396 → 0** | ¥1.03 |
| 词缀归一化 | 1,731 条表述 → **744 canonical**（压缩 57%） | ¥0.26 |
| 链式计算 | `word_form` 25,690 · `etymon` 8,532 | — |
| 中间节点补跑 | 多轮共 983 个 · **pending → 0** | ¥4.39 |
| 🆕 **词源拼写归一化** | 149 组（/ 等）· 族 **389 → 1,059** | ¥0.40 |
| 落库 | 18 表 · **外键 0 违规** · 21 MB | — |
| **合计** | | **≈¥69**（+ 压测 ¥107 见 §六） |

### 🎉 最重要结论：**聚合页确实可行**（P2-14 有答案了）

| 抽样规模 | ≥3 词共享的族 |
|---|---|
| 160 词 | **0** 🔴（当时怀疑不可行） |
| 1,000 词 | 17 |
| **11,917 词（全量）** | ✅ **389** |

→ 抽样**天然低估族规模**（同族词极难同时抽中）这个判断被证实。**聚合页不是猜测，是实证可行的。**

---

## 一、全量生成质量

### 1.1 覆盖与契约合规

| 项 | 结果 |
|---|---|
| 覆盖 | **11,917 / 11,917 = 100%**（交叉验证 JSONL 唯一词 = 11,917） |
| 契约版本 | 全部 v5（无混版） |
| 失败 | **0**（`esthetics` 曾有 1 次握手超时，重试后成功） |

### 1.2 硬约束违反（全部检测项）

| 约束 | 违反 |
|---|---:|
| `is_own_entry=false` 但 `derived_from` 空 | **0** ✅ |
| `entry_type=phrase` 却拆了词素 | **0** ✅ |
| `etymology` 非对象 | **0** ✅ |
| `abbreviation` 但 `is_own_entry≠true` | **0** ✅ |
| `relation=inflection` 无 `derived_from` | **0** ✅ |
| 词素缺 `form` | **0** ✅ |
| `mnemonic=root` 但 `analyzable=false` | 🟠 **21（0.18%）** |

> 那 21 条是 v5 契约里唯一未完全遵守的硬约束，占 0.18%，可在落库时纠正（改 `primary` 为 `etymology`/`context`）。

### 1.3 关键分布

| 维度 | 分布 |
|---|---|
| `entry_type` | word **11,162** · proper **523** · phrase **152** · abbreviation **80** |
| `is_own_entry=true` | **10,543（88.5%）** → word 表规模（⚠️ **后经补录增至 11,523，见 §九**） |
| `analyzable` | **6,290（52.8%）** |
| `relation` | derivation **4,405** · inflection **1,298** · compound **587** · null 5,627 |
| `mnemonic.primary` | root **6,079** · etymology **3,222** · context **1,433** · image 902 · cognate 184 · collocation 97 |

### 1.4 幻觉词素过滤（规则校验）

落库时拦下 **49 条**（占词素总数 12,266 的 0.4%）：

| 类 | 例 |
|---|---|
| 连接元音当词根 | `anthropologist`→`-o-` · `technology`→`-o-` · `monument`→`-u-` |
| 无意义单字母 | `counselling`→`-l-` |
| 非英语拼写 | `krystallographie`→`-o-`（该词本身是德语残留） |

**→ 印证「规则不能做语义判断，但可以做合法性校验」**（规则只需单调可靠，不需完备性）。

---

## 二、链式计算与中间节点补跑

### 2.1 迭代收敛过程

| 轮次 | 待补跑 pending | 链断（anchor 空） |
|---|---:|---:|
| 初始（全量刚落完） | 846 | 1,257 |
| 第 1 轮补跑后 | 31 | 430 |
| 第 2 轮补跑后 | **0** ✅ | **396** |

**补跑成本**：¥4.37（932 个节点，3 轮）

### 2.2 多跳链生效（补跑才可能出现）

```
unhesitatingly      → unhesitating      → hesitate         (depth=2)
congregationalists  → congregationalist → congregational   (depth=2)
iodinating          → iodinate          → iodine           (depth=2)
calving             → calve             → calf             (depth=2)
```
跳数分布：`{0: 3678, 1: 21943, 2: 67, 3: 2}`

### 2.3 🔴 链断 396 条 —— **全部会导致「划词查不到卡」**

| 项 | 值 |
|---|---:|
| 链断映射 | **396** |
| 其中自己在 `word` 表（划词仍能查到，仅缺形态锚点） | **0** |
| 🔴 **自己也不建卡 → 划词无卡可查** | **396** |

**性质**：这 396 个词形（如 `belched`←`belch`、`accrued`←`accrue`、`glibly`←`glib`）
被 LLM 判为「不必独立建卡」，但它们的 **base 也不在词表** → 两边都落空。

**实测准度**：抽样时外推「≈390 条」，全量实测 **396 条** ✅（外推很准）

**根因**：现网 11,917 词表**不是完整基础词表** —— 补跑出的 932 个「中间节点」**100% 被 LLM 判值得独立成卡**，
代表词：`belch` · `accrue` · `alienate` · `adjourn` · `impede` · `prudent` · `scrutinize` …
→ **推算词表漏 ≈1,000 个基础词**

**两个处置方案（待请示）**：
| 方案 | 做法 | 代价 | 效果 |
|---|---|---|---|
| **A 补录**（我建议） | 把判 `is_own_entry=true` 的中间节点补进词表 | 全量 +932 词（+¥5 / +10 秒） | **链断归零**，词表更完整 |
| B 不补录 | 走「L2 降级卡」兜底 | 零 | 396 条走降级路径 |

---

## 三、落库结果（18 表）

| 表 | 行数 |
|---|---:|
| `word` / `card` / `word_mnemonic_profile` | **11,523**（含补录 980） |
| `word_collocation` | 28,870 |
| `word_form` | 23,004 |
| `word_etymon` | 14,523 |
| `word_morpheme` | 12,266 |
| `etymon` | 8,532 |
| `cognate_group` | 2,556 |
| `card_extra` | 844 |
| `affix` | 744 |
| **`aggregate_page`** | **1,777**（root 596 + etymon 1,181） |
| `mnemonic_type` | 6 |

**完整性核查**（全部 ✅）：
- `PRAGMA foreign_key_check` → **0 违规**
- `card` 数 = `word` 数 = 10,543
- 每词都有 `card` / `word_mnemonic_profile`（缺失 0）
- `card_extra` / `word_morpheme` 无孤儿（0）
- `word_form.anchor_id` 有 anchor 却没 id 的 → 0

---

## 四、聚合页实证（本轮最重要的产出）

### 4.1 口径先说清：**「词数」不是「节点数」**

| 口径 | 词根族 ≥3 | 词源族 ≥3 |
|---|---:|---:|
| `count(*)` 行数 / etymon 节点数 | 544 | 389 |
| ✅ **`count(DISTINCT word_id)` 唯一词数**（页面列的是**词**） | **522** | **1,014** |

**血源族差 2.6 倍** —— 一个词可有 2 个 etymon 同锚一根本（`facere` 锚下 107 行 → **65 唯一词**）。
**→ 聚合页门槛必须按唯一词数算，否则会漏掉大量本该成页的族。**

（图根族从 544 → 522 是因为修了同形异源合并后，部分族被拆小到 <3 词 —— 这是**正确的**减少。）

**→ 详细产出见 §4.2。**

### 4.2 ✅ 两类聚合页均已实现（2026-09-26 补做）

**背景**：首次落库时 `page_type` 分布 = `{'root': 544}` —— **`etymon` 型 0 个**（落库脚本只实现了 root 型）。
白哥批复「**etymon 型和 root 型都要实现**」→ 已补齐，并在实现过程中**发现并修掉 root 型一个真 bug**。

#### 🔴 修掉的 bug：root 型把「同形异源词根」错误合并

原实现按**词根 form 字符串**成组（不是 `root_id`）→ **110 个族被污染**。

| `man` 族的实际内容（修前） | 问题 |
|---|---|
| `policeman`(警察) · `mankind`(人类) · `craftsman`(工匠) | 来自 OE `man`（人） |
| `permanence`(永久) · `permanent`(永久的) · `remain`(留下) | 来自 Latin `manere`（停留） |

**两类根本不同源却混成一族（32 词）。** `word_root` 表已用 `UNIQUE(form,type,origin)` 把同形异源分开存储 —— 但聚合时又按 form 合并了。

**修后**：
```
「man 词根族（Old English）」28 词 → policeman / mankind / craftsman / anchorman …
「man 词根族（Latin）」       4 词 → permanence / permanent / immanent / impermanent
```

**受影响族（TOP）**：`man` 32 · `miss` 14 · `it` 12 · `lect` 12 · `line` 11 · `fin` 11 · `pet` 10（**共 110 个**）

**教训**：**聚合键必须是代理键（id），不能是可能重名的自然键（form）** —— 这与 P0-1「词根同形异源」是同一问题的两个面（那里修了存储，这里才补上聚合）。

#### ✅ 两类产出（最终）

| page_type | 页数 | 成员 min/max/avg | 最大族 |
|---|---:|---|---|
| **`etymon`**（词源族） | **1,014** | 3 / **65** / 6.1 | `facere`(做) 65 · `capere`(拿) 52 · `ferre`(带) 41 · `specere`(看) 41 |
| **`root`**（词根族） | **522** | 3 / 28 / 5.2 | `man`(OE,人) 28 · `graph`(Greek,写) 23 · `fer`(Latin) 21 |

**覆盖与互补**：root 覆盖 2,556 词 · etymon 覆盖 5,416 词 · 两者都覆盖 2,344 → **并集 5,628 词（53%）**
→ **两类不是重复，是互补**（词源族覆盖面大得多，印证「以 etymon 为主」）

#### 🔑 同时修正的两处实现

| # | 原实现 | 修正 |
|---|---|---|
| **1** | root 型 `items[].gloss` = **词根义**（`graph` 族每个词都显示"写"，重复 10 遍） | 改为**该词自身的中文释义**（`biography`→传记、`demography`→人口统计学）；词根义移到 `section.source` |
| **2** | `items[]` 只存 `word_id`，客户端需 join 才能显示 | 加 `word` 拼写文本（直接显示）+ 保留 `word_id`（可跳卡） |

**两类 `content` 格式现已统一**：
```
{front, sections:[{type:"cognate_list", source:{…族的信息…}, items:[{word, word_id, gloss}]}]}
```

#### 🔴 口径修正：「唯一词数」而非「etymon 节点数」

| 口径 | ≥3 的族数 |
|---|---:|
| 按 **etymon 节点数** | 389 |
| 按 **唯一词数**（✅ 页面列的是词） | **1,014** |

**差 2.6 倍** —— 且一个词可有 2 个 etymon 同锚一根本（`facere` 锚下 **107 行 → 65 唯一词**）→ 必须 `count(DISTINCT word_id)`。

#### 质量核查（全部 0 违规）

| 检查 | 结果 |
|---|---|
| 外键违规 | **0** |
| 页内重复词 | **0** |
| 成员不在 `word` 表 | **0** |
| `member_count` 与明细不符 | **0** |
| 两类 `gloss` 为空 | **0 / 1,536** |
| CHECK 约束违反（root↔group_id / etymon↔etymon_id） | **0** |

**抽样人工核对**（内容确实同源）：
```
capere（Latin·拿取）52 词: accept, acceptable, acceptance, anticipate, anticipation,
                          capability, capable, capacity, caption, captive, capture, conceit …
specere（Latin·看）41 词: aspect, circumspect, conspicuous, despise, despite,
                          especially, inspect, inspection, inspector …
logia（Greek·学科）28 词: anthropological, anthropology, archaeological,
                          biological, biology, chronology, cosmology …
```

---

## 五、成本与时间（实际）

| 环节 | 词数 | 成本 | 时间 |
|---|---:|---:|---:|
| 全量生成 | 11,917 | ¥63.89 | **42 秒** |
| 词缀归一化 | — | ¥0.26 | 5.4 min |
| 中间节点补跑（3 轮） | 932 | ¥4.37 | 3.2 min |
| 落库 | — | — | 4 秒 |
| **小计（生产）** | | **≈¥69** | **≈9 min** |

### 🔴 与最初估算的对比

| 项 | 最初估 | 实测 |
|---|---|---|
| **耗时** | 🔴 **3.5 小时** | ✅ **9 分钟**（生成仅 42 秒） |
| **成本** | ≈¥72 | **≈¥69** ✅ 准 |

**耗时差 23 倍的根因**：最初估把「客户端三处问题（代理 / 连接不复用 / fsync）造成的慢」当成了「服务端慢」。
详见 `fullrun-concurrency-test-2026-09-26.md`。

---

## 六、⚠️ 成本如实交代：压测花了 ¥106.7

| 项 | 词数 | 成本 |
|---|---:|---:|
| **压测（纯损耗）** | **22,340** | **¥106.7** 🔴 |
| 生产（全量 + 补跑） | 12,849 | ¥69 |

**压测成本是全量本身的 1.5 倍** —— 因为我把 `--factor` 开到 1.5–3 且连测 7 档，
词量与全量高度重叠，**这些调用对最终数据毫无贡献**。

**教训（已写入 skill）**：**并发压测应在「小样本 + 高并发」上做**（如每档 200–400 词），
测的是「连接管理与吞吐」，不需要大词量。**大词量只在验证「持续跑是否退化」时才必要，且一次就够。**

---

## 七、待请示

> 🔴 **一处更正（2026-09-26）**：「一页容量上限」的数值**是落盘的**，在评审报告 §十 第 3 条：
> **4 sections / 300 字 / 单 section 100 字**。我此前写「文档未落盘」是错的。
> 实测 **191 张卡超限**（4 sense + 1 root = 5）。详见 `db-relationship-and-sections-audit-2026-09-26.md`。

| # | 事项 | 我的建议 | 阻塞 |
|---|---|---|---|
| ~~1~~ | ~~🟠 实现 `etymon` 型聚合页~~ | ✅ **已实现**（2026-09-26）—— 见 §4.2；顺带修掉 root 型 110 族错合并 | — |
| ~~2~~ | ~~🔴 链断 396 条：词表补录~~ | ✅ **已补录 980 词**（§十）→ 链断 **396 → 0** | — |
| **3** | 🔴 **191 张卡超「一页容量上限」** —— 上限**有明确数值**（4 sections / 300 字 / 单 section 100 字，见评审 §十 第 3 条），⚠️ **我此前写「数值未落盘」是错的**；实测 191 张 = 4 sense + 1 root = **5 个** | 需你定修法（A：可拆词最多 3 sense + 1 root；**B：root 不计入 sections**）→ 详见 `db-relationship-and-sections-audit-2026-09-26.md` | 卡片渲染规则 |
| 4 | ~~搭配数据源~~ | ✅ **已定：不合并现网**（白哥 2026-09-26）—— 默认只用 LLM 的 `collocations[]`；现网解析产物仅作对照资产留存 | — |
| 5 | ~~`form_ascii` 转写不一致拆散族（108 组）~~ | ✅ **已修**（§九）→ 族 1,014 → 1,059 | — |

### 也请一并确认

| # | 事项 | 我的建议 |
|---|---|---|
| 4 | 搭配数据源（现网 `related_phrases` 解析 vs LLM `collocations[]`，实测仅 **33% 重合**） | 🟠 建议**合并**（开关已备好 `--merge-legacy-collocations`） |
| 5 | 21 条 `primary=root` 但不可拆 | ✅ 落库时自动纠正为 `etymology`/`context` |
| 6 | `word.db` 是否即为新词库基线 | ✅ **是**（词库完整 18 表）；⚠️ 但**切库要改后端 ~190 处 `prebuilt_*` 引用**，且 `coevo.db` **不废弃**（它是运行时库）→ 详见 `db-relationship-and-sections-audit-2026-09-26.md` |

---

## 八、产出文件

| 文件 | 内容 |
|---|---|
| `data/curriculum/prebuilt/fullrun/results.jsonl` | 11,917 条 LLM 原始产出 |
| `data/curriculum/prebuilt/intermediate/results.jsonl` | 932 条中间节点 |
| `data/curriculum/prebuilt/affix_normalized.json` | 744 canonical 词缀 |
| `data/curriculum/prebuilt/word_form_chained.json` | 25,690 条形态链 |
| `data/curriculum/prebuilt/etymon_chained.json` | 8,532 条词源链 |
| `data/curriculum/prebuilt/chain_broken.json` | 🔴 396 条链断清单 |
| **`data/word.db`** | **新词库（18 表 · 21 MB）** |
| `scripts/run_intermediate.py` | ✏️ 补加自动选路 + 300 并发 |

**生产库 `data/coevo.db` 未改动**（时间戳仍为 Sep 25 22:48）。

---

*本文档为全量执行产出，未修改生产环境。*

---

## 九、🆕 词源拼写归一化（`normalize_etymon.py`）

### 背景

LLM 给**同一历史源词**输出**不同转写** → `UNIQUE(form_ascii, language)` 视为不同条目
→ **词源族被拆开**。实测 **108 组**影响聚合页，其中 **18 组因此完全没有页**。

```
同一个希腊词 γράφειν：  grafein (12 词)  vs  graphein (24 词)   → 两页
其他：iustus/justus · tekhne/techne · up/upp · jungere/iungere · weorc/work · diarrhoia/diarroia
```

### 🔑 为什么必须用 LLM（不能用规则）

简单规则会**误合并不同的词**。实测「去掉 h 后同形」会命中：

| 假阳性 | 为什么不能合 |
|---|---|
| `hand`(手) vs `and`(和) | OE 的 `h` 是**词义的一部分**，不是转写差异 |
| `haer`(头发) vs `aer`(空气) | 同上 |
| `man`(人) vs `manere`(停留) | 两个不同的拉丁词 |

→ 规则无法区分「转写差异」与「真的不同词」→ **必须语义判断**。

### 做法（两层候选 + LLM 判定）

**① 骨架归一化**（`skeleton()`）折叠常见转写等价：
```
i↔j · u↔v · k↔c · ph↔f · ae/oe→e · y→i · 叠字母归一
```
实测：真变体全部折叠为一（`iustus/justus` → 同骨架 ✅），而 `hand`/`and` 骨架仍**不同** ✅

**② 候选生成用领导者聚类，不用连通分量**
🔴 连通分量会**链式传递** —— 实测一个 Latin 簇膨胀到 **400+ 词**，完全失真。
领导者聚类（按词数多的当锚点）→ 簇规模可控。

**③ LLM 只判两件事**：这簇里哪些是同一源词 + 规范形取哪个。

### 结果

| 项 | 数值 |
|---|---:|
| 候选簇 | 390（骨架相同 135 · 骨架相近 255） |
| 合并组 | **149** |
| 归并 etymon | 299 → 149 canonical |
| 成本 | **¥0.40**（15 秒） |

**质量验证**：

| 检查 | 结果 |
|---|---|
| 🔴 9 个「陷阱对」（`hand`/`and`·`man`/`manere`·`in`/`inn`…） | ✅ **全部正确保持分开** |
| 已知真变体 8 组 | ✅ **7/8 正确合并**（漏 `sceoppa`/`scoppa`，生僻 OE 词） |

**族规模提升**：`graphein` 24 → **35 词** · `man`/`mann` 合并 · `up`/`upp` → 21 词 · 词源族 **1,014 → 1,059**

**顺带修的两处显示/数据问题**：
1. **标题带别名** —— 归一化后 canonical 可能是**不好认的古拼法**
   （`weorc` 才是 OE 正确的源词，但用户不认识）→ 标题显示成 `weorc / work（Old English·工作）词源族`（62 页有别名）
2. **`word_etymon.is_direct` 终于有区分** —— 设计里就是用来「区分直接源/根本」的，
   此前**全被写成 1**；现补 `is_direct=0` 的 anchor 链接（780 条）

---

## 十、🆕 词表补录（+980 词，链断归零）

### 背景

补跑中间节点时发现：**983 个「别的词的 `derived_from` 指向的词」不在现网词表**，
而 LLM **100% 判它们「值得独立成卡」** → **现网 11,917 词表漏了基础词**。

后果：**396 个词形的 anchor 落空 → 划词查不到任何卡**
```
belched → belch（不在词表）· accrued → accrue · glibly → glib · loathed → loathe
```
性质：用户划词后**什么都看不到** —— 不是「体验差」，是**功能缺失**。

### 做法

1. **补录判定**：LLM 判 `is_own_entry=true` 且不在现网词表 → 补为正式词条
2. **生成缺失的卡片内容**（`gen_senses_new_words.py` 🆕）：
   这些词的 `morphology`/`etymology`/`collocations`/`mnemonic` **已有**（补跑时同契约产出），
   但**没有 IPA / CEFR 等级 / 释义**（现网词是迁自存量的）→ 缺了就是空壳卡。
   故新增一次轻量生成（IPA + 等级 + 1–3 义项中英对照 + 例句）。

### 结果

| 项 | 数值 |
|---|---:|
| 补录词 | **980** |
| 生成卡片内容 | ¥1.01（972 + 3 + 2 条） |
| CEFR 分布 | A1 4 · A2 25 · B1 169 · B2 433 · C1 351 |
| 无 IPA | **0** |
| **`word` 表规模** | **10,543 → 11,523** |
| **链断映射** | **396 → 0** ✅ |
| `word_form` anchor 覆盖率 | 98.3% → **100.0%** ✅ |

**划词链路验证**（原本全部无卡）：
```
loathed    → loathe      (C1)  belched → belch     (B2)   accrued  → accrue (C1)
sudsing    → sud         (B1)  glibly  → glib      (C1)   distilled → distill (B2)
correlated → correlate   (B2)  frowned → frown     (B1)   …全部 ✅
```

**补录词卡片质量**（`belch`）：
```
[verb] to release gas noisily from the stomach through the mouth / 打嗝，嗳气
[noun] a noisy release of gas from the stomach through the mouth / 打嗝，嗳气
[verb] to emit smoke, fire, or steam in large amounts / 喷出，冒出（烟、火等）
```

### 🔴 同时修掉一个**代码不一致 bug**

`build_chains.py` 里 `base` 与 `anchor_of` 用了**两张不同的图**：

| | 来源 | 值（`loathed`） |
|---|---|---|
| 行的 `base` 字段 | 旧 `word_form` 规则 | `loath`（在词表） |
| `anchor_of` 实际走的 | LLM 的 `derived_from`（覆盖了 `direct`） | `loathe`（不在词表） |

→ **后果**：该行显示 `base=loath` 看起来正常，实际 anchor 按 `loathe` 算 → **链断**
→ 且 `pending` 是从行的 `base` 收集的 → **`loathe` 这个真正缺的词从没进过补跑清单**

**修法两处**：① 行 `base` 改用 `direct` 里的值（与 `anchor_of` 同图）
② `pending` 改为从 `direct` 收集（不再只看行 `base`）

---

## 十一、最终规模与成本（含 §九 §十）

| 项 | 数值 |
|---|---:|
| **`word` / `card`** | **11,523** |
| `word_form` | 22,829（anchor 覆盖 **100%**） |
| `etymon` | 8,534 |
| `word_etymon` | 15,918（含 780 条 anchor 链接） |
| `cognate_group` | 2,650（≥3 词 **596**） |
| **`aggregate_page`** | **1,777**（**etymon 1,181** · **root 596**） |
| `affix` | 744 |
| `word.db` | 24 MB（词库 18 表，**不含运行时表**） |

**数据完整性（全部 0 违规）**：外键 · 链断映射 · 页面 leader · 页内重复词 · `member_count` 不符 · 重复 front · `parent` 自指
**卡片完整**：**11,523 / 11,523 有 sense section** ✅

**本轮（§九+§十）新增成本：¥1.44**（归一化 ¥0.40 + 补录释义 ¥1.03）

---

*本节为后续补充实施产出，未修改生产环境。*

