# `cefr_catalog.json`（41,574）vs `word.db`（11,523）差异核查

> 2026-09-26 ｜ 触发：白哥问「差异是什么？少了的那些是什么」
> 可复跑：`python3 scripts/audit_wordlist_diff.py`
> 口径：所有数字均为对 `backend/cefr_catalog.json` 与 `data/word.db` 的**实测**

---

## 一、一句话结论

**这不是「同一份词表的一大一小两版」，而是两个不同抽象层级的东西** ——
「少了 3 万」里绝大部分是**词形归一**与**未达收录标准**，**不是丢失**。

**但核查过程查出一个真问题**：`word.db` 的**高频词可达率**在 5,000 名以后明显下滑，
**前 2000 高频词里有 80 个查不到** —— 这些词用户划词会失败。

---

## 二、两份表是不同抽象层级

| | `cefr_catalog.json` | `data/word.db` |
|---|---|---|
| 条目数 | **41,574** | **11,523**（+ `word_form` 22,829） |
| 单位 | **表面词形**（surface form） | **词元**（lemma） |
| 来源 | CEFR-J 词表 + **Brown 语料抽词** | 清洗 + 归一 + **LLM 全量补内容** |
| 变形处理 | **各算一条**（`is` / `was` / `been` 分开） | **归一到原形**，存 `word_form` |
| 字段 | `pos` / `domain` / `cefr_level` / `brown_freq` / `ipa` / `definition` | 释义 / 词根 / 词源 / 搭配（JSON） |
| 用途 | 后端 `lookup_cefr()` —— 判断一个词属哪个 CEFR 等级 | **端侧学习词库**（划词 + 复习） |

**关键**：旧表带 `brown_freq`（语料频次）与 `source`，这使它成为**唯一可用的「这个词真实吗」判据**
（见 §四 —— 本次核查的核心方法）。

---

## 三、「少了的 30,464」的构成

```
41,574（旧表）
 ├─ 11,110  两边都有（交集）
 └─ 30,464  只在旧表
      ├─  7,858（25.8%）变形 → ✅ **已归一到原形**（在 word_form 里有映射）
      │      例：is→be · was→be · had→have · said→say · men→man · years→year
      └─ 22,606（74.2%）无映射 → 见下
```

### 3.1 两类「无映射」的性质

| 类 | 数量 | 来源 | 性质 |
|---|---:|---|---|
| **Brown 未评级词** | 17,883 (79.1%) | `brown_unrated` | **CEFR 等级为 `None`** —— 语料里出现过但从未被评级 |
| **Brown 低等级推断词** | 4,525 (20.0%) | `brown_inferred_low` | 推断为低等级，未进入词表 |
| cefr_j 派生/变体 | 198 (0.9%) | `cefr_j` | 派生副词 / 英美变体 |

**语料频次对照（关键证据）**：

| 集合 | 中位 `brown_freq` |
|---|---:|
| 交集（11,110） | **7.0** |
| 真缺（22,606） | **1.0** |

→ **被排除的主体是语料里的长尾**（freq = 1 占 59.5%）。抽样：`jeffersonian` · `bartok` · `stengel` · `frothingham`（专名）、`cantaloupe` · `oilcloth` · `smallpox` · `trestles`（生僻实物）、`reipublicae` · `stockynges` · `mooncursers`（古语/生造）。

### 3.2 「只在新库」的 413 个

旧表没有、新库有 —— 是**学术/生僻动词**（`abash` · `abet` · `abort` · `accredit` · `admonish` · `agglutinate` · `aggrieve`…），
应来自补录批次。**说明新库不是旧表的子集，而是重新选过的词表。**

---

## 四、🔴 核查方法：用 `brown_freq` 当「真实性」判据

旧 `word_form.json`（**36,856 条**）是**规则穷举**生成的 —— 对每个词元机械套 `plural` / `past` / `ing`：

| rule | 旧映射表 | 新 `word_form` |
|---|---:|---:|
| plural | 11,449 | 6,901 |
| ing | 11,459 | 6,856 |
| past | 11,446 | 6,846 |

**规则穷举必然产生假形式**：`abolitioned` · `absolutelying` · `abilitying` · `abdominaled`（给名词加 -ed、给副词加 -ing）。

**判据**：`cefr_catalog.json` 只收录**语料中真实出现过**的拼写 →
「在旧映射表里、但不在 `cefr_catalog` 里」= **从未有人用过** = 规则误加。

结果（旧有新无、且原形在 `word.db` 的 10,910 条）：

| 判定 | 数量 | 结论 |
|---|---:|---|
| 语料**从未**出现 → 规则误加 | **9,401 (86.2%)** | ✅ **新表正确排除** |
| 语料**出现过** → 真·遗漏 | **1,509 (13.8%)** | 🟠 见 §五 |

> **→ 新 `word_form` 比旧表「更准」**（排除了 9,401 条噪音），**但也「更漏」**（丢了 1,509 条真变形）。

---

## 五、🔴 真·查不到：1,233 个词（用户划词会失败）

> ✅ **已修复（2026-09-28）** —— 按本文 §七 的**方案 A** 补齐：
> `scripts/fill_word_form_gap.py` 向 `word_form` 补入 **1,233 行**（22,829 → 24,062）。
> 补后「真·查不到」**1,233 → 4**（剩下 4 条是**故意排除**的假映射：
> `herring→her` · `hissed/hissing→his` · `theses→these` —— 见
> `docs/design/word-form-gap-and-place-names-2026-09-28.md` §5.1）。
> 前 2,000 高频可达率 96.0% → **97.2%**。
> ⚠️ **本节余下数字为 09-26 时点，保留作为「修复前」基线。**
> 🔴 **并且：§七 的方案 D（英美变体）与地名词表已决定「不补库」** —— 改由 LLM 兜底路径处理。

1,509 条真·遗漏再按「本身是否已独立成条」区分：

| | 数量 | 说明 |
|---|---:|---|
| ✅ 本身已独立收录（直查可命中） | 276 (18.3%) | 如 `actually` / `beginning` / `absolutely` |
| 🔴 **真·查不到**（词元无 + 映射无） | **1,233 (81.7%)** | 见下 |

### 5.1 按类型

| rule | 数量 |
|---|---:|
| **plural** | **823** |
| adverb | 243 |
| past | 82 |
| ing | 63 |
| superlative | 12 |
| comparative | 10 |

### 5.2 语料频次最高的 30 个

| form | → base | rule | freq |
|---|---|---|---:|
| `things` | thing | plural | **368** |
| `activities` | activity | plural | 115 |
| `products` | product | plural | 110 |
| `leaders` | leader | plural | 107 |
| `relations` | relation | plural | 102 |
| `workers` | worker | plural | 88 |
| `carefully` | careful | adverb | 87 |
| `relatively` | relative | adverb | 85 |
| `operations` | operation | plural | 84 |
| `requirements` | requirement | plural | 83 |
| `officers` | officer | plural | 83 |
| `offered` | offer | past | 83 |
| `differences` | difference | plural | 79 |
| `laid` | lay | past | 77 |
| `buildings` | building | plural | 76 |
| `writers` / `teachers` / `statements` / `employees` / `organizations` / `governments` | … | plural | 68–74 |
| `entitled` / `artists` / `measurements` / `decisions` / `characteristics` / `payments` / `elections` | … | 56–54 |

### 5.3 可达率（按语料频次排序，最决策相关）

**可达 = 直查命中 `word` 或 经 `word_form` 归一**

| 排名范围 | 可达 | 查不到 | **可达率** |
|---|---:|---:|---:|
| 前 500 | 497 | 3 | **99.4%** |
| 前 1,000 | 979 | 21 | **97.9%** |
| 前 2,000 | 1,920 | **80** | **96.0%** |
| 前 5,000 | 4,495 | 505 | 89.9% |
| 前 10,000 | 8,379 | 1,621 | 83.8% |
| 全表 41,574 | 18,968 | 22,606 | 45.6% |

### 5.4 前 2000 高频词中查不到的 80 个，分四类

| 类 | 样例 | 性质 |
|---|---|---|
| **A. 变形遗漏**（原形在库，映射缺） | `things` `shown` `opened` `programs` `persons` `activities` `products` `leaders` `relations` `workers` `operations` `requirements` `officers` `offered` `differences` `buildings` `writers` `laid` `occurred` `realized` | 🔴 **`word_form` 覆盖不完整** |
| **B. 派生词未收录** | `carefully` `relatively` `older` `fourth` `connection` | 🟠 原形在库（`careful`/`relative`/`old`/`four`/`connect`），但派生词无条目也无映射 |
| **C. 英美变体不对称** | `behavior`🔴 `behaviour`🔴 · `labor`🔴 `labour`🔴 · `centre`🔴(美式`center`✅) · `theater`🔴(英式`theatre`✅) | 🔴 **`behavior`/`labour` 两边都没有** —— 高频词 |
| **D. 词元真缺** | `cannot` `forward` `corps` `communism` `aj` | 🟠 词元完全不在库 |
| （另）专名 | `washington` `england` `william` `george` `europe` `british` `french` `german` `james` `robert` `france` `november` `berlin` `rome` `paris` `california` … | ✅ **符合「专名保留」决策，只是这 24 个未收录**（Brown 高频专名） |

### 5.5 🔴 这是**回归**，不是原生缺陷

| | 旧系统（`word_form.json` 36,856） | 新 `word_form`（22,829） |
|---|---|---|
| `things` | ✅ plural → thing | 🔴 无 |
| `activities` | ✅ plural → activity | 🔴 无 |
| `products` | ✅ plural → product | 🔴 无 |
| `offered` / `laid` | ✅ | 🔴 无 |
| `abolitioning`（垃圾） | 🔴 有 | ✅ **正确排除** |

→ 换生成方式（规则穷举 → LLM 判定）**同时**带来了「去噪」和「漏收」。
**去噪是收益，漏收是成本 —— 但漏的是高频词，成本更痛。**

---

## 六、影响面

`WordQueryService.lookup()` 的链路（`app/lib/services/word_query_service.dart:70`）：

```
① 直查 word.spelling  → 命中返回
② word_form 归一      → 命中返回
③ 都没有 → 返回 null → 调用方走「词库外」流程（LLM 兜底制卡）
```

**没有形态兜底**（如「去 s / 去 ed」），所以命不中就是**真的命不中**。
后果：用户划 `things` → 走 LLM 兜底 → **慢 + 花钱 + 卡片质量低于预制卡**。

---

## 七、修复建议（待白哥定）

| # | 方案 | 覆盖 | 成本 | 风险 |
|---|---|---|---|---|
| **A** | **用旧规则表补 `word_form`**，但**只补「`cefr_catalog` 里出现过」的 1,509 条** | 一次补齐真遗漏；**天然排除 9,401 条噪音** | 小（纯脚本，零 LLM） | 低 —— 判据是语料实证 |
| **B** | 重跑 `build_word_form.py`，改成「规则穷举 + 语料过滤」 | 同上，但重跑全量 | 中 | 中 —— 需重验 |
| **C** | 在 `WordQueryService` 加**形态兜底**（去 s/es/ed/ing/ly 重试） | 覆盖**未预见**的变形（比 A 广） | 小（~40 行） | 🟠 可能误判（`bus`→`bu`）→ 需长度/白名单保护 |
| **D** | 补英美变体对（≥200 对） | 覆盖 C 类 + 大量未测变体 | 中 | 低 |

**我的建议**：**A + C + D**（互补，不重叠）
- **A** 修已知的 1,233 条（数据层）
- **C** 兜住 A 之后的残余 + 未来新词（服务层）
- **D** 单独一批变体对（`behavior`/`labour` 这类高频词不能靠 C 兜）

**不建议**：把 `cefr_catalog.json` 的 22,606 条语料长尾**直接补录** ——
中位频次 1、无 CEFR 等级、大量专名与古语，补进来只会稀释词库质量。
**但其中「前 5000 高频词里查不到的 505 个」值得单独过一遍**（含专名与变体）。

---

## 八、附带结论

1. **`cefr_catalog.json` 的 `brown_freq` 是宝贵的语料证据** —— 本次核查全靠它区分
   「真变形」与「规则误加」。**将来做词库质量核查时应保留这个字段**（哪怕后端迁移到端侧）。
2. **不能简单说「新库比旧表小」** —— 新库**多**了 413 个旧表没有的词，**少**了 9,401 条噪音，
   **同时又漏**了 1,233 条真变形。三个方向同时发生。
3. **旧前端时代的 `word_form.json`（36,856）不应直接删除** —— 它是本次补漏的**数据来源**。
   现存于 `data/curriculum/prebuilt/word_form.json`（4.3 MB）。

---

*本报告为调查产出。核查脚本 `scripts/audit_wordlist_diff.py` 可复跑。未修改词库数据。*
