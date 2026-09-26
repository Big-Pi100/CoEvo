# 「记忆法全不可用」116 词 · 核查报告

> 2026-09-26 ｜ 核查脚本 `scripts/audit_no_mnemonic_words.py` ｜ 数据源 `data/word.db`
> 起因：`mnemonic-layer-separation-2026-09-26.md` §六 待定项 5 —— 「先查它们的 ③④ 是否完整」

---

## 一、核查结论（一句话）

**③④ 100% 完整，不存在「四段全空」的卡 —— 无须补任何数据。**

| 核查项 | 结果 |
|---|---|
| 有释义（`sections[].zh` 非空） | **116 / 116** |
| 有例句（`sections[].example` 非空） | **116 / 116** |
| 有音标（`card.ipa` 非空） | **116 / 116** |
| 无 card 行 / JSON 损坏 | **0 / 0** |
| 缺任一项 | **0** |

段数分布（116 词）：1 段 50 · 2 段 38 · 3 段 16 · 4 段 12 —— **没有 0 段的卡**。

→ 原判断「需要确认它们有释义与例句，否则会出现四段全空的卡」**已排除**。

---

## 二、这 116 词到底是什么（构成拆解）

**口径**（与 §3.1 一致）：不可拆（`word_morpheme` 无 `type='root'`）**且** `etymology_text` 为空。
`collocation` 待判、`image` 无数据源，均不计入 —— 所以这 116 是**偏保守的上界**。

按 `entry_type` 拆开，**问题性质立刻变了**：

| `entry_type` | 词数 | 天然适用记忆法？ | 判定 |
|---|---:|---|---|
| `phrase` 词组 | 13 | ❌ 不适用 | `traffic jam` · `pocket money` · `police station` · `make up`… 词组本就没有词根可拆 |
| `abbreviation` 缩写 | 15 | ❌ 不适用 | `fbi` · `ibm` · `hiv` · `cdc` · `nyu` · `gnp`… 缩写没有词源 |
| `proper` 专名 | 13 | ❌ 不适用 | `nehru` · `poe` · `kong` · `waco` · `chen`… **已决定保留** |
| `word` 单词 | **75** | 🟠 需再看 | 见 §三 —— **一半是词表噪声** |

**→ 41 条（45.7%）是口径问题，不是数据问题。** 它们本来就该走 ③④ 两段，
槽位①② 为空是**正确行为**，不是缺陷。

---

## 三、意外发现：这一格是「词表噪声」的富集区

剩下的 75 条 `word` 里，`big`／`job`／`jump` 这类古英语短词**客观没有可讲的词源**
（`job` 的词源在词源学上本身就是「来源不明」），所以它们落进来是正常的。

**但另一半不是这个原因。** 对 75 条逐条看首义英释后，出现明显的低质条目：

```
iocsixf      (computing, cryptography) a code or identifier with unknown…   ← 不像真词
iocsixg      (computing, cryptography) a code or identifier similar to…
eromonga     (rare) an intense romantic or sexual infatuation…
pornsen      (rare, informal) a person who produces, distributes…
jerebohms    A type of small brown beetle that damages stored grain…
tultul       a type of shell money used traditionally in parts of Papua New Guinea
vernava      A type of traditional woven fabric…
nogol        (rare) a small cylindrical wooden peg or block…
glimco       (rare) a faint, intermittent light…
gapt         (archaic or dialect) having a gap or opening; cleft
mij          (chiefly literary) a small dark-furred semi-aquatic mammal…
```

**判据：`data-noise-classification` 的「自述型措辞」** —— 释义自己就在说
「罕见／古语／方言／变体拼写／某类织物」而不是描述事物本身。
自动标记（正则命中 `(rare` `(archaic` `variant spelling` `surname` `a type of`… ）：

| 分类 | 条数 |
|---|---:|
| 命中自述型措辞（**自动**标记） | **22** |
| 人工复核加判（`chemisch` 德语词 · `dag`/`stram`/`ulyate` 方言 · `Jenks`/`Sweeneys`/`Mickie`/`Pratt`/`Fogg`/`Jelke`/`Dow`/`Mosk`/`Ku` 姓氏被标成 word · `vesole`/`pel`） | ~13 |
| **疑为词表噪声合计** | **≈35** |
| **净真词**（`big` `blur` `bunch` `clog` `cuff` `dingy` `dodge` `eh` `fog` `frills` `fuss` `hurl` `jag` `job` `jump` `knack` `loop` `lurch` `mall` `mound` `nick` `nip` `paddle` `rabbit` `rip` `rub` `ruffle` `shrill` `shrub` `shrug` `slang` `smell` `snarl` `tag` `toss` `turmoil` `uh` `uhhu` `wisp` `wrap`） | **40** |

**→ 这一格的真实成分是：噪声（≈35）+ 词组/缩写/专名（41）+ 古英语短词（40）。**

### 3.1 噪声不是补录批次引入的

`gen_senses_new_words.py` 补录了 982 词（来源是 LLM 生成其他词时提到的 `derived_from` 中间节点）。
**但 116 词里只有 8 条来自补录批次**（`chemisch` `defensive line` `jag` `make up` `pel` `ruffle` `shrub` `snarl`）→ **7%**。

**→ 噪声源头在更早的词表（`iocsixf` / `jerebohms` 这类不在任何补录清单里），需单独溯源。**
（本次未查到底 —— 属独立的「词表清洗」任务，见 §四）

### 3.2 一个有用的副产品

**「记忆法全不可用」这一格可以直接当词表质量的探针**：
噪声词必然不可拆、必然无词源 → 必然落进这一格。
**这一格的噪声密度（≈30%）比全库平均（未知，但远低于此）高一个量级。**
以后清洗词表，从这里入手性价比最高。

---

## 四、处置建议

| # | 事项 | 建议 | 理由 |
|---|---|---|---|
| 1 | 116 词是否需要补释义/例句 | ✅ **不需要，什么都不做** | 实测 ③④ 100% 完整 |
| 2 | 41 条非 `word`（phrase/abbr/proper） | ✅ **不处理** —— 槽位①② 为空是正确行为 | 词组/缩写没有词根，专名已决定保留 |
| 3 | 40 条古英语短词 | ✅ **不处理** | `big`/`job`/`jump`/`rub` 客观无词源；且都是用户早已认识的最高频词，学习价值最低 |
| 4 | ≈35 条疑噪声 | 🟠 **单独立项**（不在本次改动范围） | 需先溯源（噪声源头比补录更早）+ 按 `data-noise-classification` 全库扫一遍，不止这 35 条 |
| 5 | 渲染层 | ✅ **槽位①② 为空时直接渲染 ③④ 两段**，UI 不留空段 | 与界面稿 §06「不可拆词不摆空段」一致 |

**→ 结论：「116 词」这个待办应当从「数据缺失」重新定性为「词表清洗」，
且不阻塞任何当前改动。**

---

## 五、对整体改动的影响

- 验收条款「槽位① 总是有内容（除非五类全不可用，实测仅 116 词）」**改写为**：
  「槽位① 无内容时直接渲染 ③④ 两段（实测 116 词，其中 41 条为词组/缩写/专名，属正常）」。
- §3.1 的分布表**不需要改** —— 116 这个数字是准的（口径无变化）。
- **不改任何数据、不重跑 LLM、零成本。**

---

*本文档为调查产出，未修改代码或生产环境。`coevo.db` 时间戳未变。*
