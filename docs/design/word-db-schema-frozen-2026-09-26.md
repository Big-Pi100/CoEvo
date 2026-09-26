# 词库表结构（冻结版）—— LLM 全库重跑的落地契约

- 日期：2026-09-26
- 状态：**待白哥确认**
- 目的：**先定表结构，再抽样，再全量** —— 表结构是 LLM 输出的落点，不先定就没法评质量（不知道怎么算对错）
- 依据：v1《最终版》14 表设计（部分原文未落盘，见「来源标注」列）+ 现网 `data/coevo.db` 实测 + DDL 修正
- **表数：18 张**（v1 的 14 + `word_form` + `affix` + `etymon` + `word_etymon`）

> **✅ 已处置（2026-09-26）**：
> - **P0 三项**（词缀表 / 链式 `word_form` / `sort_seq NOT NULL`）→ §1.1 / §1.2 / §1.5
> - **词源结构化 + 两类聚合**（按白哥指出的「词源字段太简单」）→ §1.7
> - **`COLLATE NOCASE` + 即时生成落点**（白哥定）→ §1.11
>
> **🟠 仍待处置**：P1/P2 其余项 → 见 **`word-db-p1p2-recommendations-2026-09-26.md`**
> （其中 **P2-12 搭配解析错位 2,021 行**建议优先修，属数据正确性 bug）

---

## 〇、来源标注规则（避免混淆原文与补全）

| 标记 | 含义 |
|---|---|
| `[v1]` | v1 原文明确出现过的表/字段 |
| `[补]` | v1 未给出具体字段，本文档按设计意图补全 —— **这是我的设计，不是 v1 原文** |
| `[修]` | 对 v1 原文的修正（有实测依据） |
| `[现]` | 现网已有，可直接迁移 |

---

## 一、预制库 `word.db`（只读，随 App 发布）

### 1.1 `word` — 词条主表

| 字段 | 类型 | 来源 | 说明 |
|---|---|---|---|
| `id` | TEXT PK | `[修]` | UUID（评审阻塞 3 选项 B；现网 `prebuilt_cards.id` 已是 TEXT） |
| `sort_seq` | INTEGER UNIQUE | `[补]` | 音频命名 `{sort_seq:05d}_w.opus` + 分片排序。**只增不改** |
| `spelling` | TEXT NOT NULL | `[v1]` | 显示拼写 ← 现网 `prebuilt_cards.front` 100%（**加 `COLLATE NOCASE`**，见 §1.11） |
| `cefr_level` | TEXT | `[v1]` | A1/A2/B1/B2/C1 ← 现网 `level` **100%** |
| `etymology_text` | TEXT | `[v1]` | 词源**叙事文本**（可读，供卡片展示）← LLM 生成。<br>🔴 **结构化另存** `word_etymon`（可聚合）→ 见 §1.7；**这不是双存，是「叙事」与「结构化引用」分工**（P1-9 由此解决） |
| `created_at` | TEXT | `[补]` | |

**🔴 `frequency_rank` 不建** —— v1 有该字段，但现网 `difficulty` 全是 0.5 不可用；白哥已定「用 CEFR 等级近似排序」，而 CEFR 已在 `cefr_level` → 该字段冗余。

#### 🔴 v1 的 `lemma` 字段应当去掉（2026-09-26 白哥提问引出的修正）

**白哥问**：「`"lemma": "prompt"` 和 `"base_form": "prompt"`，在字段含义上有什么不同？」

**核实结论：概念确实不同，且合并到同一字段是错的。**

| | `lemma`（`word_form.json`） | `base_form`（LLM 契约 `entry.base_form`） |
|---|---|---|
| 概念归属 | **词典学** —— 词位的约定引用形式（词典标题） | **构词学** —— 某词形的直接基础形式 |
| 谁生成 | `build_word_form.py`，**字符串规则** | LLM，**语义判定** |
| 生成方向 | 从词表词**正向展开**变形再反查 | 从遇到的词形**反向判**归属 |
| 范围 | 只在**屈折**内 | 可含**派生**（`promptly→prompt`）、**可多级** |
| 唯一性 | 一个 lexeme 一个 lemma | **受 `is_own_entry` 影响** |
| 回答的问题 | 「这个词形**去哪张卡查**」（查词路由） | 「这个词形**该不该有自己的卡**」（建卡决策） |

**「可多级」是本质差别**：`nationalization ← nationalize ← national ← nation` —— `base_form` 可指任意一级**直接**基础，`lemma` 只能有一个。

**实测分叉（抽样 160 词的 `word_form` 对照）**：

| 指标 | 结果 |
|---|---|
| 判 `is_own_entry=false` 的词，`base_form` == `word_form.lemma` | **43/44 = 97.7%** |
| 判 `is_own_entry=true` 的词，`word_form` 里**仍有一条指向别处的映射** | 🔴 **22 条**（分叉） |
| 唯一实质不一致 | `analyses`：LLM=`analysis` ✅ / 规则=`analyse`（英式拼写） |

**分叉样例（这里 `base_form` 对、`lemma` 错）**：

| 词形 | `word_form.lemma`（规则） | `entry.base_form`（LLM） | 谁对 |
|---|---|---|---|
| `lyrics` | `lyric`（plural） | `lyrics`（独立词条） | ✅ LLM |
| `sanctions` | `sanction`（plural） | `sanctions`（独立词条） | ✅ LLM |
| `owner` | **`own`（comparative）** | `owner`（独立词条） | ✅ LLM —— **规则完全错**，`owner` 不是 `own` 的比较级 |
| `besides` | **`beside`（plural）** | `besides`（独立词条） | ✅ LLM —— `besides` 是介词/副词 |
| `genetics` | **`genetic`（plural）** | `genetics`（独立词条） | ✅ LLM —— `genetics` 是单数学科名 |
| `used` | `use`（past） | `used`（独立词条，"用过的/习惯于"） | ✅ LLM |

> **→ 这三条硬错误（`owner`/`besides`/`genetics`）再次实证「规则判断不了自己的遗漏」** ——
> 它们都"匹配到了规则"，所以规则认为自己对。**只有语义判定才能发现。**

#### 处置：`word` 表去掉 `lemma`，改 `UNIQUE(spelling)`

**逻辑链**：
1. `is_own_entry=true` 的词 → 建 `word` 记录，且 `base_form` = **自身**
2. → 每条记录的 `lemma` 恒等于 `spelling` → **字段冗余**
3. → `UNIQUE(lemma)` ≡ `UNIQUE(spelling)` → **原「修正 1」的落点从「聚合后去重」变成「根本不进表」**

**🔴 而且这个字段有害**：它暗示「`word` 表里可以有非自身 lemma 的词条」，**会引诱实现时把 1,375 张冲突卡塞进 `word` 表** —— 正好回到需要人工判断组 A/B/C 的老路。

```sql
CREATE TABLE word (
  id             TEXT PRIMARY KEY,
  sort_seq       INTEGER NOT NULL UNIQUE,   -- 🔴 NOT NULL（P0-3）
  spelling       TEXT NOT NULL COLLATE NOCASE,  -- 🔴 NOCASE（§1.11）
  cefr_level     TEXT,
  etymology_text TEXT,                      -- 叙事文本（结构化见 word_etymon）
  created_at     TEXT DEFAULT (datetime('now')),
  UNIQUE (spelling)              -- 🔴 原 UNIQUE(lemma) 去掉
);
CREATE INDEX idx_word_spelling ON word (spelling);
```

**✅ 处置已定（2026-09-26 白哥批准）：去掉 `lemma`。**

备选方案（已否决，记录以免重提）：
- ❌ **B**：保留 `lemma` 但去 UNIQUE，语义改为「形态来源（可空）」→ 与 `word_form` 信息重复
- ❌ **C**：`lemma` 改名 `base_form` 与 LLM 契约统一 → 命名一致但仍是冗余

**「形态来源」信息不丢** —— 由 `word_form`（基础词在词表时）+ `entry.derived_from`（基础词不在词表时）共同承载（见 §1.2）。

#### 🔴 `sort_seq` 必须加 `NOT NULL`（P0-3，2026-09-26 实测）

**SQLite 实测**：
```sql
CREATE TABLE w (id TEXT PRIMARY KEY, sort_seq INTEGER UNIQUE);
INSERT INTO w VALUES ('a', NULL);
INSERT INTO w VALUES ('b', NULL);   -- 🔴 被接受！
```

**`UNIQUE` 不约束 NULL** → 若构建脚本漏填 `sort_seq`，可以有**任意多条 NULL** → 唯一性形同虚设
→ 音频命名 `{sort_seq:05d}_w.opus` 会**多词同名 → 音频互相覆盖**。

**✅ 处置**：`sort_seq INTEGER NOT NULL UNIQUE` + 构库后校验 `count(*) = count(DISTINCT sort_seq)`。

### 1.2 `word_form` — 词形映射 `[补]`（v1 缺口，已实现 36,856 条）

v1 的检索路径是 `word.spelling` 直查 → `received` 查不到 `receive`。**这是真实缺口。**

**必须区分两个用途**（此前混为一谈）：

| 用途 | 覆盖 | 与 `is_own_entry` 的关系 | 处置 |
|---|---|---|---|
| **① 查词路由**（基础设施） | 词表词的变形展开 → 文章里出现的 `received` 路由到 `receive` | **无关** —— `received` 本就不在词表里 | ✅ **全部保留**，不受本次判定影响 |
| **② 词表内部形态归并** | `word_form.in_vocab=1` 的 **1,383 条**（`isolated` 在词表里也有卡片） | 🔴 **由 `morphology.relation` 决定**（不是 `is_own_entry`） | 见下 |

#### 🔴 撤回原「#7 删除映射」决定（2026-09-26 白哥追问引出的修正）

**原决定**：`is_own_entry=true` 时删除 `word_form` 旧映射。
**🔴 这个决定是错的，必须撤回。**

**错在哪**：它把「语义归属」和「**形态归属**」当成了一回事。两者是不同的维度：

| 维度 | 问题 | 落点 |
|---|---|---|
| **语义归属** | 划到 `isolated` 应显示哪张卡？ | ✅ 自己的卡（`isolated`=孤立的） |
| **形态归属** | `isolated` 属于哪个 lexeme？ | → **`isolate`** —— 这层关系**不能丢** |

**丢了会怎样**（`word-database-design` §1.2 描述的正是这个）：
> 复习队列里 `isolate` 和 `isolated` **各占一位** → 用户复习两遍同一个词
> 掌握度统计虚高 · 痕迹自相矛盾（同一篇文章里 `isolate` 已掌握、`isolated` 还陌生）

**→ 而 `in_vocab` 字段本来就是为这个设计的**：它的含义是「该 form 另有独立卡片」——
**恰恰是为了让运行时同时知道两件事**：查词优先用自己的卡，统计时知道属于哪个 lexeme。

#### ✅ 修正后的处置：按 `morphology.relation` 分流（不是按 `is_own_entry`）

| LLM `morphology` 判定 | 建 `word` 记录 | `word_form` 映射 | 理由 |
|---|---|---|---|
| **`relation=inflection`**（含 `-ed`/`-ing`/`-s` 屈折后缀） | ✅ 建卡 | ✅ **保留 + `in_vocab=1`** | 同一词的不同形态，复习统计必须能聚合 |
| **`relation=derivation`/`compound`**（施事 `-er`、`-ly`、`-able`…） | ✅ 建卡 | 🔴 **删除** | 旧 `rule` 本就标错（`owner→own` 说成 comparative） |
| **`is_own_entry=false`** | ❌ 不建 | ✅ 保留为主路由 | `politically` 不建卡，路由到 `political` |

**抽样实测这条分流的落点**（22 条会丢映射中）：**10 条屈折型 → 保留** ｜ **12 条派生型 → 删除**

**→ 规则错误（`owner`「施事 -er」被标成 comparative）落在「派生型」里，自动被删 ✅**
**→ 而 `isolated→isolate`（真屈折）被保留 ✅** —— 原决定会把它一起删掉。

#### 🔴 基础词不在词表时，`word_form` 也记不了 → 这正是要**改链式**的理由

**实测**：`attuned`（B2，独立词条，形容词「对…敏感的」）的屈折基础是 **`attune`，而 `attune` 不在词表里**。

`build_word_form.py` 只从**词表词**正向展开变形 → 基础词不在词表时**根本不会生成映射**：

| 词 | 屈折基础 | 基础词在词表？ | `word_form` 能关联？ |
|---|---|---|---|
| `used` | `use` | ✅ 在 | ✅ 能（`used→use`, `in_vocab=1`） |
| `isolated` | `isolate` | ✅ 在 | ✅ 能 |
| **`attuned`** | **`attune`** | 🔴 **不在** | ❌ **不能（无映射）** |
| **`obligated`** | **`obligate`** | 🔴 **不在** | ❌ **不能** |

**→ 这类词的「形态归属」两层都记不住 → 需要 LLM 直接给出 `derived_from`（见 §二）。**

#### 🔴 改链式：`word_form` 必须能「推导到根本」（P0-2，2026-09-26 白哥指出）

**白哥问**：「`word_form` 是否应该是链式的，从而推导到根本？」

**实测：现状是「扁平一跳」且 lemma 恒在词表，但 LLM 的 `derived_from` 会指向词表外 → 两处链断。**

| 事实 | 实测 | 含义 |
|---|---|---|
| `word_form.lemma` 是否恒在词表 | ✅ **36,856 / 36,856 = 100%** | 正向展开保证 → 一跳必然可达 |
| LLM `derived_from` 指向**不在词表**的词 | 🔴 **13 / 106 = 12.3%** | 这些 base **没有 word_form 记录** → **无法继续推** |

**13 条按 `is_own_entry` 分流 —— 后果完全不同**：

| 情形 | 数量 | 后果 |
|---|---:|---|
| `is_own_entry=true`（自己有卡） | **10** | 🟢 查词不受影响；但**形态聚合拿不到锚点**（`attuned` 与 `attune` 的 FSRS 状态无法归并） |
| `is_own_entry=false`（不建卡） | **3** | 🔴 **真链断 —— 划词查不到任何卡** |

**3 条真失败案例**：`slaying→slay` · `eroded→erode` · `freeholders→freeholder`（三个 base 全不在词表）

**→ 实证链式必需**：损失 3/106 ≈ 2.8% → 全量预估约 **330 个词会划词无卡**。

#### ✅ 链式设计

```sql
CREATE TABLE word_form (
  form      TEXT NOT NULL COLLATE NOCASE,   -- 🔴 NOCASE
  base      TEXT NOT NULL COLLATE NOCASE,   -- 🔴 NOCASE
  rule      TEXT,               -- plural / past / adverb / derivation / ...
  kind      TEXT,               -- 🆕 inflection | derivation | variant
  anchor    TEXT COLLATE NOCASE, -- 🔑 链终点（上溯，第一个在词表的词）
  anchor_id TEXT,               -- anchor 的 word.id（NULL = 链断，需补跑）
  depth     INTEGER DEFAULT 1,  -- 跳数（诊断用）
  in_vocab  INTEGER DEFAULT 0,  -- form 自己是否有独立卡（语义优先自己）
  PRIMARY KEY (form, base)
);
CREATE INDEX idx_form ON word_form (form);
CREATE INDEX idx_anchor ON word_form (anchor);
```

**`anchor` 计算（构建期一次性，运行时零成本）**：

```
anchor(x):
  ① x 在词表               → 返回 x                （命中即停）
  ② word_form 有 x 的 base → 递归 anchor(base(x))   （上溯，最多 3 跳，防环）
  ③ 否则                   → NULL                   （链断，记入待补清单）
```

**查词路由（运行时）**：

```
划词 form
  ↓
① form 在词表？            → 是：直达自己的卡
  ↓ 否
② 查 word_form(form).anchor_id   ← 🔑 预计算，一次索引查询即得，无需运行时递归
  ├── 非空    → 路由到 anchor 的卡 ✅
  └── 为空    → ③
  ↓
③ 共享词根兜底（morphology.parts[type=root]）→ 词根在词表则路由
  ↓ 仍失败
④ L2「可用信息卡」（三层降级策略，已有设计）
```

#### 🔴 中间节点需补跑 LLM（补链）

`attuned → attune`，但 `attune` **不在词表** → 它本身没有 `word_form` 记录 → 递归在 `attune` 处断掉。

**→ 需为「中间节点」补一次 LLM，问出它的 base。**

| 项 | 估算 |
|---|---|
| 抽样中间节点 | 13 / 160 词 |
| **全量预估** | **≈ 970 个** |
| 补跑成本 | 970 × ¥0.0026 ≈ **¥2.5** |
| 补跑后预期 | 链断从 12.3% 降至 ~2%（真正无可上溯的） |

**⚠️ 仍有不可解的残留**：`schizophrenia`/`schizophrenic` 这类**互为派生方向不明**的，或 `attune` 也无可靠基的 → `anchor=NULL` → 走 ③④ 降级。**这是可接受的**（降级已有设计）。

#### `word_form` 两个用途的边界（保持）

| 用途 | 覆盖 | 与 `is_own_entry` 关系 |
|---|---|---|
| **① 查词路由** | 词表词变形展开 + LLM `derived_from` + 中间节点 | 无关（`received` 本不在词表） |
| **② 词表内部形态归并** | `in_vocab=1` 的 1,383 条 | 按 `morphology.relation` 分流（§1.2 前文） |

### 1.3 `card` — 卡片表（**一词一卡**）`[v1]`

| 字段 | 来源 | 说明 |
|---|---|---|
| `word_id` | `[修]` | 加 **UNIQUE** —— 解决评审阻塞 2a（`ON CONFLICT (word_id)` 无对应约束）**兼** 一词一卡 |
| `content` | `[v1]` | JSON：`{front, ipa, sections[], extra[]}` |
| `content_hash` | `[修]` | **去掉 TEXT UNIQUE** —— 否则降级卡/同义短卡插入失败（评审阻塞 2b） |
| `template_code` | `[v1]` | 卡片模板 |

```sql
CREATE TABLE card (
  word_id       TEXT PRIMARY KEY,          -- 一词一卡
  content       TEXT NOT NULL,             -- JSON
  content_hash  TEXT,                      -- 🔴 无 UNIQUE
  template_code TEXT,
  updated_at    TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (word_id) REFERENCES word(id)
);
CREATE INDEX idx_card_hash ON card (content_hash);
```

### 1.4 `card_extra` — 降级义项 `[v1]`

超出一页容量上限的义项转可展开区域（§5.2 配套）。现网 `definitions[1..]` 直接迁入。

```sql
CREATE TABLE card_extra (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id TEXT NOT NULL,
  section TEXT NOT NULL,      -- JSON（与 card.content.sections[] 同构）
  ord     INTEGER,
  FOREIGN KEY (word_id) REFERENCES word(id)
);
```

### 1.5 词素层：`affix` + `word_root` + `word_morpheme`（P0-1 重设计）

> **白哥的判断（2026-09-26）**：「词缀要有词缀表，分解后的词缀应该优先在词缀表中**选择释义**，如果没有**也不强行匹配，允许增加**。另外**词根是否也存在这样的问题**？」

#### 🔴 先答「词根是否也有同样问题」：有，但**性质不同**

| | 词缀 | 词根 |
|---|---|---|
| 集合性质 | **封闭集**（英语常用前缀 ~100 + 后缀 ~200 ≈ **300 个**，可穷举） | **开放集**（数万个，不可穷举） |
| 分歧率（抽样） | 🔴 **27%**（18/67 多义） | ✅ **0.9%**（1/109） |
| **分歧的性质** | **同形多义** —— `-er` 真是 6 种义（施事/工具/反复…），**同一词缀的多义** | 🔴 **同形异源** —— 不是多义，是**两个不同的词根** |
| 判据 | 靠 `sense` 维度区分 | **靠 `origin` 区分** |

**`rod` 的实证（同形异源，不是多义）**：

| 词 | `meaning` | `origin` | 真相 |
|---|---|---|---|
| `eroded`（侵蚀） | 咬 | **Latin** | 拉丁 `rodere`（咬） |
| `rodder`（汽车迷） | 汽车（俚语） | **Old English** | 英语 `rod`（棒/汽车） |

**→ 两者是同形异源，不是同一个词根的多义 → 若合并会「造出假词源」。**
**⚠️ 这推翻我审计时的建议**（原建议「`origin` 不参与唯一约束」是错的）—— **`origin` 必须进唯一键**。

#### 三张表的分工

| 表 | 集合 | 生成者 | 唯一键 | 用途 |
|---|---|---|---|---|
| **`affix`**（新） | **封闭** | **人工审校** | `(form, type, sense)` | 规范词缀义，供全库复用 |
| **`word_root`** | **开放** | LLM | `(form, type, origin)` | 词根（含词源，区分同形异源） |
| **`word_morpheme`**（原 `word_root_link`） | — | LLM | `(word_id, position)` | 词 ↔ 词素 的关联 + 每词细义 |

```sql
-- ① 词缀表（封闭集，人工审校；新）
CREATE TABLE affix (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  form         TEXT NOT NULL COLLATE NOCASE,   -- "-ed" / "-er" / "re-"
  type         TEXT NOT NULL,     -- prefix | suffix
  sense        TEXT NOT NULL,     -- 规范义（canonical）
  meaning_zh   TEXT NOT NULL,     -- 中文规范表述
  aliases      TEXT,              -- 🆕 同义表述（JSON 数组），供落库归一化匹配
  productivity INTEGER DEFAULT 0, -- 能产性（出现频次，用于定 prompt 优先级）
  needs_review INTEGER DEFAULT 0, -- 🆕 1 = LLM 新增、待人工确认
  UNIQUE (form, type, sense)
);

-- ② 词根表（开放集，LLM 生成）
CREATE TABLE word_root (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  form    TEXT NOT NULL COLLATE NOCASE,   -- cred / ceive / rod
  type    TEXT NOT NULL,      -- 固定 root（词根表只放词根，词缀已独立）
  meaning TEXT,               -- 中文义
  origin  TEXT,               -- Latin | Greek | Germanic | Old English | ...
  UNIQUE (form, type, origin)   -- 🔴 origin 必须进唯一键（区分同形异源）
);

-- ③ 词 ↔ 词素 关联（原 v1 的 word_root_link，扩展）
CREATE TABLE word_morpheme (
  word_id  TEXT NOT NULL,
  position INTEGER NOT NULL,     -- 拆分顺序
  type     TEXT NOT NULL,        -- prefix | root | suffix
  affix_id INTEGER,              -- → affix.id     （type ≠ root 时）
  root_id  INTEGER,              -- → word_root.id （type = root 时）
  surface  TEXT,                 -- 该词中的表面形式（at- / tune / -ed）
  gloss    TEXT,                 -- 🆕 该词中的具体义（词缀义因词而异的落点）
  relation TEXT,                 -- ⚠️ 词级属性存在行级（P1-6 待处置）
  PRIMARY KEY (word_id, position),
  CHECK (
    (type =  'root' AND root_id IS NOT NULL AND affix_id IS NULL) OR
    (type <> 'root' AND affix_id IS NOT NULL AND root_id IS NULL)
  )
);
CREATE INDEX idx_morpheme_affix ON word_morpheme (affix_id);
CREATE INDEX idx_morpheme_root  ON word_morpheme (root_id);
```

#### ✅ 匹配策略（白哥的方案：优先选、匹配不上则新增）

**落库时对每个词缀执行**：

```
LLM 给出的词缀 (form, type, 自由义)
  ↓
① 查 affix (form, type) 是否有该义？
    匹配依据：meaning_zh 或 aliases 命中
  ├── 命中          → 复用该行 affix_id          （不新增，释义统一 ✅）
  ├── 该词缀有该行但义不同 → 属于「其他 sense」→ 引用对应 sense
  └── 词缀表完全没有或义确实新 → 🔴 新增一行，needs_review=1
  ↓
写入 word_morpheme.affix_id + gloss（保留 LLM 原文表述）
```

**这正好落实白哥说的「不强行匹配，允许增加」** —— 不为了复用而扭曲语义，但**同义表述必须归并**。

#### 🔑 词缀表的真正价值：不只是避免冲突，而是**释义统一**

抽样实证 —— 同一词缀在不同词下的表述**极度不一致**：

| 词缀 | LLM 给出的表述数 | 各表述 |
|---|---:|---|
| **`-ed`** | **8** | `具有…的` · `被…的` · `过去/被动` · `过去分词` · `过去分词/形容词后缀` · `过去分词后缀` · `过去式` · `过去式/过去分词` |
| **`-er`** | **6** | `…的人` · `…的物/程序` · `从事…的人` · `反复动作` · `者` · `表工具或施动者` |
| **`re-`** | **5** | `再/加强` · `再、回` · `再，加强` · `再；回` · `回，向后` |
| `-ing` | 4 | `…业/活动` · `…的` · `名词化` · `正在…` |

**归一化后**（人工判断同义合并）：**103 行 → 78 行，压缩 24%**

**→ 若不建词缀表**：`-ed` 在不同词下显示 **8 种不同说法** → 用户在 50 张卡里看到 8 种 `-ed` 的解释。
**→ 建表后**：统一为 2 种（`过去式/过去分词`、`被…的`）。

#### ⚠️ 实现方式：不要整表塞进 prompt

| 方案 | 做法 | prompt 成本 | 风险 |
|---|---|---|---|
| ~~B~~ | 词缀表**全量**进 prompt（300 行） | 🔴 **+5,040 token（+336%）** | 🔴 v3 已实证：prompt 变长 → 自洽性 99.4%→94.4% |
| **A**（推荐） | **本地落库归一化**（LLM 输出自由义，落库时按 `aliases` 匹配） | **0** | 需维护 `aliases` 同义表 |
| A+B | 只放**最高频 Top 30**（覆盖 ~70%）进 prompt，其余走 A | +~200 token（+13%） | 可控 |

**→ 建议 A 为主**，把归一化逻辑放在脚本里（`aliases` 可先由 LLM 批量生成，一次性 ¥0.5 级成本）。

### 1.6 `collocation` + `word_collocation` `[v1]`

现网 `related_phrases` 98.1%，格式 `a, b, c（中文1，中文2，中文3）` → 需解析（中英条目数校验）。

```sql
CREATE TABLE collocation (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  phrase    TEXT NOT NULL UNIQUE COLLATE NOCASE,   -- 🔴 NOCASE
  chinese   TEXT,
  frequency INTEGER
);
CREATE TABLE word_collocation (
  word_id        TEXT NOT NULL,
  collocation_id INTEGER NOT NULL,
  ord            INTEGER,
  PRIMARY KEY (word_id, collocation_id)
);
```

### 1.7 聚合层（两类）：`cognate_group`（词根族）+ `etymon`（词源族）

> **白哥的判断（2026-09-26）**：「**词源的字段是否太简单了，现在是单一字段，这样没办法按词源聚合**。聚合页肯定有用，**按词源和词根两类，可以建构记忆联系**。」
>
> **✅ 这个判断纠正了我的结构性遗漏** —— 我把词源做成死的 `etymology_text`（一坨文本），**等于堵死了词源聚合**。

#### 🔑 两类聚合的定位与差别

| | **① 词根族**（`cognate_group`） | **② 词源族**（`etymon_group`） |
|---|---|---|
| 聚合键 | 英语内**可分析词根**（`-ceive`） | **历史源词**（拉丁 `capere`） |
| 视角 | **记忆法**（能拆成什么、串记） | **词源学**（从哪来、同源串记） |
| 来源 | `word_root`（LLM 拆词） | `etymon`（LLM 给词源） |
| 精度 | 🟠 有误合并风险 | ✅ **更准确** |

**🔴 词源族比词根族更准确 —— 用 `rod` 实证**：

| | 词根族（按 `rod` 聚合） | 词源族（按 etymon 聚合） |
|---|---|---|
| `eroded`（侵蚀） | 🟠 落进 `rod` 族 | ✅ `rodere`（拉丁·咬）族 |
| `rodder`（汽车迷） | 🟠 **混进同一族**（错） | ✅ `rod`（古英语·棒）族 |

**→ 词根 `rod` 会误把两个不同来源的词合并；词源 `rodere`/`rod` 能正确分开。**
**→ 这就是白哥说的「词源聚合」的独有价值：它能纠正词根聚合的误伤。**

#### ① 词根族 `cognate_group`（原设计，定位收窄为「词根」）

**从 `word_root` 自动派生**（词根相同即成族）→ 零额外 LLM 成本。

**🔴 派生时必须排除 `relation=inflection` 的词**：
`isolate` 与 `isolated` 共享词根 `isolat`，但它们是**同一词的不同形态**，归 `word_form` 管。
**同源族 = 互不派生的不同词**（`receive`/`perceive`/`conceive`/`deceive`）→ 必须 `relation IN ('derivation','compound')` 才入族。

```sql
CREATE TABLE cognate_group (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  group_key TEXT NOT NULL,          -- 词根 form，如 "ceive"（**显示用**）
  root_id   INTEGER,                -- 🔴 成组依据 → word_root.id
  label     TEXT,                   -- "ceive 词根族（Latin）"
  origin    TEXT,
  size      INTEGER DEFAULT 0,      -- 族规模（按「唯一词数」口径）
  UNIQUE (root_id),                 -- 🔴 不用 UNIQUE(group_key)！见下
  FOREIGN KEY (root_id) REFERENCES word_root(id)
);
CREATE TABLE cognate_group_member (
  group_id INTEGER NOT NULL,
  word_id  TEXT NOT NULL,
  gloss    TEXT,                    -- "拿回来 → 接收"
  PRIMARY KEY (group_id, word_id)
);
```

> **🔴 修正（2026-09-26 全量复核发现）**：原设计 `group_key TEXT NOT NULL UNIQUE`
> —— **必须改为按 `root_id` 成组**，因为**同形异源词根会被错误合并**。
>
> **实证**：全量落库后按 form 字符串成组，**110 个族被污染**。最严重的 `man`：
> ```sql
> word_root:  id=388  man  root  人    Old English
>             id=531  man  root  停留  Latin        ← 同形异源，已由 UNIQUE(form,type,origin) 分开
> cognate_group: 合并成 1 族 32 词 → policeman(警察)/mankind(人类) 与 permanence(永久)/remain(留下)
>                ← 这四类根本不同源！(man=人 vs manere=停留)
> ```
> **修后**：拆成「`man 词根族（Old English）` 28 词」+「`man 词根族（Latin）` 4 词」✅
> 同类受影响的族：`miss`(14) · `it`(12) · `lect`(12) · `line`(11) · `fin`(11) · `pet`(10) …
> **教训**：聚合键必须是**代理键（id）**，不能是**可能重名的自然键（form）** ——
> 这与 P0-1「词根同形异源」是同一个问题的两个面（那里修了存储，这里才补上聚合）。

#### ② 词源族 `etymon` + `word_etymon`（🆕 白哥指出后新增）

**`etymon` = 历史上的源词**（拉丁 `capere`、希腊 `graphein`、古英语 `cwide`）—— 与「英语内词根」是**两个不同层的东西**。

```sql
CREATE TABLE etymon (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  form         TEXT NOT NULL,       -- capere / credere / γράφειν / café
  form_ascii   TEXT NOT NULL COLLATE NOCASE,  -- ASCII 转写（聚合键）
  language     TEXT NOT NULL,       -- Latin | Greek | Old English | French | Proto-Germanic | ...
  meaning_zh   TEXT,                -- 拿取 / 相信
  note         TEXT,                -- 说明（如「经法语 receivre 进入英语」）
  parent_id    INTEGER,             -- 🔑 自引用：上一层源词（见「链式」）
  anchor_id    INTEGER,             -- 🔑 根本源词（传递闭包终点，预计算）
  depth        INTEGER DEFAULT 0,   -- 到根本的层数（0 = 已是根本）
  size         INTEGER DEFAULT 0,   -- 族规模（可按 anchor 聚合，派生时回填）
  UNIQUE (form_ascii, language),
  FOREIGN KEY (parent_id) REFERENCES etymon(id),
  FOREIGN KEY (anchor_id) REFERENCES etymon(id)
);
CREATE INDEX idx_etymon_ascii  ON etymon (form_ascii);
CREATE INDEX idx_etymon_anchor ON etymon (anchor_id);

-- 词 → 词源 的关联
CREATE TABLE word_etymon (
  word_id   TEXT NOT NULL,
  etymon_id INTEGER NOT NULL,       -- 指向「根本」还是「直接源」？→ 见下（两者都存）
  role      TEXT,                   -- root | prefix | derived | whole
  is_direct INTEGER DEFAULT 1,      -- 🆕 1 = 直接源词；0 = 根本（传递闭包）
  ord       INTEGER,
  PRIMARY KEY (word_id, etymon_id),
  FOREIGN KEY (etymon_id) REFERENCES etymon(id)
);
CREATE INDEX idx_word_etymon_etymon ON word_etymon (etymon_id);
```

#### 🔴 `etymon` 也必须链式 —— 实测 8/8 验证

**问题**：LLM 给出的源词**粒度不一** —— `perceive` 给 `percipere`，而 `receive` 给 `capere`；两者其实同族。

| 词 | LLM 直接给出的 etymon | 真正的根本 |
|---|---|---|
| `receive` | **`capere`**（一步到位） | `capere` |
| `perceive` | **`percipere`**（中间源词） | `capere` |
| `conceive` | `capere` | `capere` |
| `deceive` | **`decipere`**（中间源词） | `capere` |

**→ 若不链式，族只会聚到 2 个（`receive`+`conceive`），漏掉 `perceive`/`deceive`。**

**✅ 实测：让 LLM 对中间源词再上溯一层，准确率 8/8 = 100%**

| 中间源词 | LLM 给出的上一级 | 应为 |
|---|---|---|
| `percipere` | `capere` ✅ | `capere` |
| `decipere` | `capere` ✅ | `capere` |
| `respicere` | `specere` ✅ | `specere` |
| `suspicere` | `specere` ✅ | `specere` |
| `prospicere` | `specere` ✅ | `specere` |
| `importare` | `portare` ✅ | `portare` |
| `contrahere` | `trahere` ✅ | `trahere` |
| `dictare` | `dicere` ✅ | `dicere` |

**→ 传递闭包后，族规模 `capere` 从 2 → 4。**（中间源词补跑：预估几百个，成本 ¥1 级）

**`rank` 语义**：
- `is_direct=1` → 该词的**直接源词**（词典学正确）
- `is_direct=0` → **根本源词**（聚合用）

**两类成员**（`role`）：
- `whole`：**整体借词**（`café` ← 法语 `café`、`papa` ← 法语 `papa`）→ 单成员族，仍有词源价值（v1「词源故事」的适用对象）
- `root`/`prefix`/`derived`：**同源派生**（`receive`/`perceive`/`conceive` ← `capere`）→ 多成员族，**聚合页有价值**

#### 🔴 实证：**词源族完胜词根族**（推翻我原先的猜想）

**针对性验证**（不受抽样偏差影响 —— 直接跑 7 个已知同源族）：

| 已知族 | 词源聚合（按 `anchor`） | **词根聚合** | 差异 |
|---|---|---|---|
| `capere` 拿取 | ✅ **4/4** | 🟠 **2/4**（漏 `perceive`/`deceive`） | **词源多 2** |
| `credere` 相信 | ✅ 4/4 | ✅ 4/4 | 平 |
| `specere` 看 | ✅ 4/4 | ✅ 4/4 | 平 |
| `portare` 携带 | ✅ **5/5** | 🟠 4/5（漏 `report`） | **词源多 1** |
| `dicere` 说 | ✅ 4/4 | ✅ 4/4 | 平 |
| `trahere` 拉 | ✅ 4/4 | ✅ 4/4 | 平 |
| 复合词（`earthquake` 类） | ❌ 无共享（**正确**） | ❌ 无共享（正确） | — |
| **合计** | **✅ 6/7 成族** | 🟠 **2/7 成族** | **词源多覆盖 14%** |

**根本原因**：
| | 度量对象 | 判据瓶颈 |
|---|---|---|
| **词根族** | 词在**现代英语**里是否可拆出透明词根 | 🟠 `perceive`/`deceive` 的 `-ceive` **现代已不透明** → 判为不可拆 → **漏掉** |
| **词源族** | 词在**历史上**源自哪个词 | ✅ **不依赖可拆性** → 覆盖更全 |

**→ 结论：v1 §4.3 把聚合页定为「cognate 词源族」是**对的** —— 词源视角比词根视角召回更高。**
**→ 🔴 我此前「词源族可能比词根族更常见」是不确定的猜想，现已实证为事实。**

> ⚠️ **复合词（`subway`/`earthquake`）两类都不适用** —— 它们没有共享源词，只有自身构词。
> **这是正确行为**：复合词的价值在「可拆」（词根/构词法 section），不在「聚合」。

### 1.8 `aggregate_page` + `aggregate_page_word` — 聚合页 `[v1]`

**只读查询，不进复习队列**（评审 §十 第 4 条「不要动」）。

**🆕 加 `page_type` 区分两类聚合**（白哥：按词源和词根两类）：

```sql
CREATE TABLE aggregate_page (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  page_type TEXT NOT NULL CHECK(page_type IN ('root','etymon')),  -- 🆕 两类
  group_id  INTEGER,               -- → cognate_group.id（page_type=root）
  etymon_id INTEGER,               -- → etymon.id        （page_type=etymon，存 **anchor** 的 id）
  front     TEXT NOT NULL,         -- "ceive 词根族（Latin）" / "capere（Latin·拿取）词源族"
  content   TEXT NOT NULL,         -- JSON {front, sections:[{type:"cognate_list", source:{…}, items:[{word,word_id,gloss}]}]}
  member_count INTEGER DEFAULT 0,
  CHECK ((page_type='root'   AND group_id  IS NOT NULL AND etymon_id IS NULL) OR
         (page_type='etymon' AND etymon_id IS NOT NULL AND group_id  IS NULL))
);
CREATE TABLE aggregate_page_word (
  page_id  INTEGER NOT NULL,
  word_id  TEXT NOT NULL,
  ord      INTEGER,                -- 🔑 页内顺序（原 sort_seq → 更名，见 P2-17）
  PRIMARY KEY (page_id, word_id)
);
```

#### ✅ 两类均已实现并验证（2026-09-26 全量）

| page_type | 门槛 | 产出页数 | 成员 min/max/avg | 最大族 |
|---|---|---:|---|---|
| **`etymon`**（词源族） | 同 `anchor` 根本源词，**≥3 词** | **1,014** | 3 / **65** / 6.1 | `facere`(做) 65 · `capere`(拿) 52 · `ferre`(带) 41 · `specere`(看) 41 |
| **`root`**（词根族） | 同 `root_id`，≥3 词 | **522** | 3 / 28 / 5.2 | `man`(OE,人) 28 · `graph`(Greek,写) 23 · `fer`(Latin) 21 |

**覆盖与互补**：root 覆盖 2,556 词 · etymon 覆盖 5,416 词 · 两者都覆盖 2,344 → **并集 5,628 词（53%）**

**🔑 `content` 结构（两类统一）**：
```json
{"front": "capere（Latin·拿取）词源族",
 "sections": [{"type": "cognate_list",
   "source": {"form": "capere", "language": "Latin", "meaning": "拿取"},   // etymon 型
   //        {"form": "graph", "type":"root", "origin": "Greek", "meaning": "写"},  // root 型
   "items": [{"word": "capture", "word_id": "w001234", "gloss": "俘获，捕获"}]}]}
```

> 🔴 **两处实现修正（2026-09-26）**：
> 1. **`items[].gloss` 改为「该词自身的中文释义」** —— 原 root 型存的是**词根义**（`graph` 族每个词都显示"写"，重复 10 遍对学习者无用）。
>    词根/源词的信息移到 `section.source`，两类格式统一。
> 2. **`items[].word` 加拼写文本** —— 原只存 `word_id`，客户端需 join 才能显示。
>    现同时存 `word`（直接显示）+ `word_id`（可跳卡）。
>
> 🔴 **口径必须是「唯一词数」，不是「etymon 节点数」** —— 页面列的是**词**：
> 按节点数 ≥3 → 389 族；按**词数** ≥3 → **1,014 族**（**差 2.6 倍**）。
> 另：一个词可有 2 个 etymon 都锚到同一根本（`facere` 锚下 107 行 → **65 个唯一词**），故必须 `count(DISTINCT word_id)`。
>
> 🟠 **一个未修的数据质量问题（待定）**：**`form_ascii` 转写不一致会把族拆开**（实测 **108 组**受影响，其中 **18 组因此完全没有页**）。例：
> `grafein`(12词) vs `graphein`(24词) —— 同一个希腊词 γράφειν 两种转写；`up`/`upp`、`well`/`wel`、`iustus`/`justus`、`tekhne`/`techne`、`cognoscere`/`gnoscere`。
> **性质**：与「词缀同义归一化」同一类问题（自由文本需 canonical 化）。
> ⚠️ **不能用简单规则修** —— 实测「去 h 后同形」会把 `hand`(手)/`and`(和) 这类**不同的词误合**；
> 需「同语言 + 同释义 + 相似度」联合判据，或交给 LLM 聚类（同词缀归一化的做法）。

**两类聚合页的取舍（P2-14，✅ 已有针对性实证）**：
| page_type | 门槛 | 实测（7 个已知族） |
|---|---|---|
| `root`（词根族） | 词根族 ≥3 成员 | 🟠 **仅 2/7 成族** —— `perceive`/`deceive` 因 `-ceive` 现代不透明而漏 |
| `etymon`（词源族） | 词源族 ≥3 成员（按 `anchor`） | ✅ **6/7 成族** —— 不依赖可拆性，覆盖更全 |

**→ ✅ 结论：聚合页以 `etymon` 为主，`root` 为辅。**
**→ 抽样里「族规模 0」是抽样偏差**（跨 CEFR 随机 → 同族词极难同时抽中），**针对性验证才是可信依据**。

> ⚠️ **全量后仍需复核族规模分布**（抽样偏差只能靠全量消除），但方向已明确。

### 1.9 `mnemonic_type` + `word_mnemonic_profile` — 记忆法 `[v1]`

```sql
CREATE TABLE mnemonic_type (
  code            TEXT PRIMARY KEY,   -- root|cognate|etymology|collocation|image|context
  priority        INTEGER NOT NULL,   -- 1..6
  name            TEXT NOT NULL,
  applicable_when TEXT                -- 🔴 判据必须写清（P2-15）
);
-- 静态 6 行（priority 按 v1 §4.1）：
--   1 root        词根词缀 —— 「词可拆成**现代英语仍透明**的词根/词缀」（incredible = in+cred+ible）
--   2 cognate     同源串记 —— 「**与另一个英语词共享同一词根或词源**」（receive/perceive/conceive）
--                              🔴 谐音相似（papa ↔ 爸爸）**不属于 cognate**，归 image
--   3 collocation 搭配整记 —— 「有 ≥1 条高频固定搭配」
--   4 etymology   词源故事 —— 「整体借词、不可拆」（café ← French café）
--   5 image       联想图像 —— 「抽象词，靠意象联想」（含谐音联想）
--   6 context     语境原句 —— 默认附加
--
-- ⚠️ 两类"同源"的分工（§1.7）：
--   cognate(词根视角)  → cognate_group   —— 现代英语可分析词根
--   etymology(词源视角) → etymon_group    —— 历史源词（更准确，能纠正词根误合并）
--   两者可**同时**作为 primary/secondary（如 receive：primary=root, secondary=cognate）

CREATE TABLE word_mnemonic_profile (
  word_id         TEXT PRIMARY KEY,
  primary_code    TEXT NOT NULL,
  secondary_codes TEXT,               -- JSON array（🟠 P2-16：不可索引，全表扫可接受）
  confidence      REAL,
  rationale       TEXT,
  FOREIGN KEY (primary_code) REFERENCES mnemonic_type(code)
);
```

### 1.10 `card_audio` — 语音元数据 `[v1]`

> ## 🟠 暂不写入 · **预留后续收费扩展**（白哥 2026-09-26 定案）
>
> | 项 | 说明 |
> |---|---|
> | **表是否保留** | ✅ **保留 DDL**（18 表冻结结构不变）—— 白哥：「**留 DDL + 标注后续收费扩展**」 |
> | **当前状态** | 🟠 **暂不写入**（TTS 全量端侧 `flutter_tts` → 无预生成音频 → 无数据来源） |
> | **预留用途** | 🔮 **后续收费扩展**（如付费高品质语音包 / 离线音频包等增值形态） |
>
> 🔴 **与「语音包取消」不矛盾**：取消的是**免费预生成**这条路线，表结构作为**未来的能力位**保留。
>
> ⛔ 同期仍作废的两张表（**不建**）：
> - `external_word_audio`（v1 第 354 行）—— 端侧音频缓存，无预生成音频则无意义
> - `audio_package_version`（v1 第 482 行）—— 语音包版本管理，无语音包则无意义
>
> ✅ **P1-7 `section_index` 指代消歧**：问题**暂缓**（表暂不写入；若未来启用收费扩展，沿用已加的 `scope` 列即可）。
>
> 音色一致性由**渲染层**保证：**同一张卡内锁定同一个 `voice` 实例**（端侧 TTS）。
> 📄 决策依据：`tts-unified-client-side-2026-09-26.md` §7.1

*（DDL 保留，暂不写入）*

```sql
CREATE TABLE card_audio (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id       TEXT NOT NULL,
  audio_type    TEXT NOT NULL,       -- word | section
  scope         TEXT,                -- 🆕 section | extra（P1-7：指代消歧）
  section_index INTEGER,
  text          TEXT NOT NULL,
  file_name     TEXT NOT NULL,
  duration_ms   INTEGER,
  content_hash  TEXT,
  UNIQUE (word_id, audio_type, scope, section_index)
);
```

### 1.11 🔴 `COLLATE NOCASE` 与「即时生成」的落点（白哥定）

> **白哥原话**：「**还是加 COLLATE NOCASE 吧，查询的时候也要大小写不敏感，而且还有即时生成**。」

#### 实测：NOCASE 做什么、不做什么

| 行为 | 实测结果 |
|---|---|
| `UNIQUE` 是否折叠大小写 | ✅ `India` 插入后 `india` **被拒绝** |
| `WHERE s = ?` 是否折叠 | ✅ `= 'india'` / `= 'INDIA'` 都能命中 `India` |
| 🔴 **非 ASCII 是否折叠** | ❌ **不折叠** —— `café` 存在时 `= 'CAFÉ'`、`= 'CAFE'` **都不命中**；`Ärger` 对 `= 'ärger'` 也不命中 |

**→ `NOCASE` 只处理 ASCII 的 A–Z。** 这是必须交代的硬限制。

#### 对词库的影响：够用

| 对象 | 实测 | NOCASE 够用？ |
|---|---|---|
| 英语词表 `spelling` | 11,917 条，**0 条含大写**；仅 **2 条**非 ASCII（`café`/`cybercafé`） | ✅ **够用**（那 2 条按原样精确匹配即可） |
| `word_form.form` | 同源，全小写 | ✅ 够用 |
| **`etymon.form`** | 🟠 **会有非 ASCII**（希腊 `γράφειν`、德语 `Ärger`、古英语 `ǣ`） | 🟠 **需额外处理** → 见下 |

#### 加 NOCASE 的列（全清单）

| 表 | 列 | 为什么 |
|---|---|---|
| `word` | `spelling` | 划词查词（句首大写 `India` / 全大写 `INDIA`） |
| `word_form` | `form` · `base` · `anchor` | 划词查词主路径 |
| `affix` | `form` | 词缀查表复用 |
| `word_root` | `form` | 词根聚合 |
| `etymon` | `form_ascii` | 词源聚合（**用 ASCII 转写列做键**，绕开非 ASCII 问题） |
| `collocation` | `phrase` | 搭配查找 |

**写法**：`col TEXT NOT NULL COLLATE NOCASE`

#### 🟠 `etymon` 的非 ASCII 处理：双列

`etymon` **不能只靠 NOCASE**（希腊/德语源词不折叠）→ **拆两列**：

| 列 | 用途 | 例 |
|---|---|---|
| `form` | **显示**（保留原拼写，含非 ASCII） | `γράφειν` · `Ärger` |
| `form_ascii` | **聚合键**（ASCII 转写，`COLLATE NOCASE`） | `grafein` · `aerger` |

- 转写规则：希腊/西里尔 → 拉丁转写；变音符 → 去音或展开（`ä`→`ae`）
- **`UNIQUE(form_ascii, language)`** 做聚合键 → 稳定、可折叠大小写
- ⚠️ **两个不同的源词可能转写成同一 `form_ascii`** → 靠 `language` 区分；仍冲突则加 `form_ascii` 后缀消歧

#### 「而且还有即时生成」→ 即时生成的词也要走同一套

**理解**：即时生成（LLM 兜底制卡）产出的词卡，最终要**合并回主词库**，因此
**必须与主库同一套约束与结构**，否则合并时会冲突或丢失聚合能力。

**落点（`generated_card_cache`，端侧 + 服务端）**：

| 要求 | 具体 |
|---|---|
| 查词大小写不敏感 | `generated_card_cache.spelling` **加 `COLLATE NOCASE`** |
| 词形归一 | 即时生成时**也查 `word_form`**（可能命中已有 lemma → 根本不用生成） |
| 词源可聚合 | 即时生成**也产出结构化 `etyma`** → 合并进 `etymon`/`word_etymon` |
| 词缀可复用 | 即时生成**也走 `affix` 查表** → 不新增同义行 |
| 与主库对齐 | 合并时用 `derived_from` + `relation` 走同一分流逻辑 |

**→ 顶层原则：即时生成不是「另一套流程」，而是「同一套流程 + 词表未命中分支」。**
（这正好复用已有的三层降级设计：L1 重试 → L2 可用信息卡 → L3 后台重试队列；成功者入缓存并最终合并。）

---

**合计 18 张表**（v1 的 14 张 + `word_form` + `affix` + `etymon` + `word_etymon`；
其中 v1 的 `word_root_link` 扩展为 `word_morpheme`）。

---

## 二、LLM 输出契约（**这是本次抽样的核心**）

抽样跑要验证的，就是「LLM 能不能按这个契约、高质量地逐词产出」。**一次调用产出完整内容包**（不拆多次，避免重复传上下文）：

> 🔴 **v3 契约（2026-09-26，白哥两轮追问引出）**：删 `entry.base_form`、`inflection_of`→`derived_from`、扁平化 `entry`。见 §2.1。

### 2.1 🔴 契约演进 v1 → v2 → v3（三轮追问，逐个消除冗余）

**白哥第一问**：「`entry: {is_own_entry: true, base_form: "attuned"}` 和 `morphology: {analyzable: true, relation: "derivation"}` 不冲突吗？」

**答**：`entry` 与 `morphology` **是不同维度，不冲突**。
`farmer` 是正面例子：`is_own_entry=true`（独立建卡）+ `analyzable=true`（farm + -er 拆来记）—— **独立与可拆完全可以并存**。
**但 `attuned` 暴露两个真缺陷**：

| # | 缺陷 |
|---|---|
| **1** | `relation="derivation"` 但 parts 含 `-ed` —— **`-ed` 是屈折后缀**，是 `relation` 缺 `inflection` 枚举导致的 |
| **2** | `base_form="attuned"` 重复自身 → **「它是 `attune` 的过去分词」无处记录**（`attune` 不在词表 → `word_form` 也记不了） |

**根因**：契约只回答「要不要自己的卡」，**没回答「它属于哪个词」** → 契约 v2 增补 `inflection_of` + `relation` 扩 `inflection`。

**白哥第二问**：「如果按你的解释，`is_own_entry` 和 `entry` 不就又重复了？」

**🔴 答：两处冗余，都成立于这次追问。**

| 层 | 冗余 | 实测证据 |
|---|---|---|
| **命名** | `entry.is_own_entry` —— 「entry」出现两次 | 该对象只有 4 个字段，`entry` 前缀无信息量 |
| **字段** | **`base_form` 完全可推导** | 见下 |

#### 🔴 实测：`base_form` 100% 可推导（应删除）

| 情形 | 实测 | `base_form` 的信息量 |
|---|---|---|
| `is_own_entry=true` | `base_form ≡ word` **115/115 = 100%** | **0** |
| `is_own_entry=false` | `base_form ≡ derived_from` **37/37** | **0** |
| 例外 8 条 | 全为 `-ly` **派生**副词（`politically→political`…），`relation=derivation` | 🟠 因字段名过窄而空 |

**→ 推导公式：`base_form = is_own_entry ? word : derived_from`**
**→ 那 8 条例外正是「字段名过窄」的后果**：LLM 按字面理解「`inflection_of` = 屈折形式」，见 `-ly` 是派生就不填 → 只能把基础词塞给 `base_form`。
**→ 改名 `derived_from` 并放宽语义后，这 8 条也会填 → `base_form` 完全冗余。**

#### ✅ 契约 v3（三处变更）

```json
{
  "word": "attuned",
  "is_own_entry": true,          // ① 扁平化：去掉 entry 包裹
  "derived_from": "attune",      // ② inflection_of 改名 + 放宽语义（屈折或派生；无则 null）
  "reason": "对…敏感，需单独记忆",
  "morphology": {
    "analyzable": true,
    "relation": "inflection",    // ③ 值域 4 值
    "parts": [ {"form":"at-","type":"prefix","meaning":"朝向","origin":"Latin"},
               {"form":"tune","type":"root","meaning":"调音","origin":"Old English"},
               {"form":"-ed","type":"suffix","meaning":"已…的","origin":"Old English"} ]
  },
  "etymology": "…", "collocations": [ … ], "mnemonic": { … }, "confidence": 0.9
}
```

**变更清单**：

| # | 变更 | 理由 |
|---|---|---|
| ① | **删 `entry.base_form`** | 100% 可推导：`is_own_entry ? word : derived_from` |
| ② | **`inflection_of` → `derived_from`** | 字段名过窄导致 8 条派生词漏填；放宽为「源自哪个基础词」 |
| ③ | **扁平化 `entry`** | 该对象仅剩 3 个字段，`entry.` 前缀冗余（白哥指出 `entry.is_own_entry` 重名） |

**→ 附带收益**：JSON 更短 → prompt token 更省 → **全量成本下降**。

**硬约束（必须加）**：`is_own_entry=false` ⟹ `derived_from` 非空（否则查词路由不到任何卡）

**`relation` 值域（3 值 + null）**：

| 值 | 判据 | 后缀例 | 用途 |
|---|---|---|---|
| **`inflection`** | 屈折变化 —— **不改变词类、不产生新词位** | `-ed` · `-ing` · `-s` · `-er`(**比较级**) · `-est` | → `word_form` **保留映射** + `in_vocab=1` |
| **`derivation`** | 派生构词 —— 改变词类或产生新义 | `-er`(**施事**) · `-ly` · `-able` · `-ment` · `-ness` | → `word_form` **删除**旧映射 |
| **`compound`** | 复合词 | `subway`=sub+way · `earthquake`=earth+quake | 同上 |
| `null` | 不可拆 | — | — |

**🔴 `-er` 的两副面孔**（最易混的一处）：
- `farmer` = farm + `-er`**（施事，派生）** → `relation=derivation` ✅
- `cheaper` = cheap + `-er`**（比较级，屈折）** → `relation=inflection` ✅
- **旧规则把 `owner`(`own`+-er 施事) 标成 `comparative`** → 这正是它错的原因

**`derived_from` vs 已删的 `base_form`**：

| 情形 | `is_own_entry` | `derived_from` | 推导出的 `base_form` |
|---|---|---|---|
| `used` | true（自己的卡） | `use` | `used` |
| `politically` | false（不建卡） | `political` | `political` |
| `happy` | true | `null` | `happy` |

#### ✅ 契约 v2 重跑结果（¥1.068 / 160 词 × 2 轮）

| 指标 | 结果 |
|---|---|
| `relation` 值越界 | **0 ✅** |
| `inflection_of` 键缺失 | **0/160 ✅** |
| 自洽性：`relation` | **99.4%** |
| 自洽性：`inflection_of` | **96.9%** |
| `attuned` 两轮复现 | `own=True` + `base_form=attuned` + `inflection_of=attune` + `relation=inflection` ✅ **两轮一致** |
| **`-er` 两副面孔** | `farmer`/`owner`/`folder`/`autocoder`/`rodder` → **全部 `derivation` ✅**（规则把它们标成 `comparative`，全错） |

**`relation` 分布**：`derivation` 70 · `inflection` 28 · `compound` 4
**可拆率升至 63.7%**（v1 契约 52.5%）—— 因为 `inflection` 类别被正确识别了。

#### 🔴 第三层发现：`inflection_of` 与 `base_form` 在 `is_own_entry=false` 时**完全重复**

**实测**：`is_own_entry=false` 的样本中，`base_form == inflection_of` **37/37 = 100% 一致**（0 条不一致）。

| 情形 | `base_form` | `derived_from` | 谁有信息 |
|---|---|---|---|
| `is_own_entry=false`（`politically`） | `political` | `political` | 🔴 **完全重复** |
| `is_own_entry=true`（`attuned`） | `attuned`（自身） | **`attune`** | `derived_from` 独有 |

**→ 加上第一层发现（true 时 `base_form ≡ word`）→ `base_form` 在两个分支上都 0 信息量 → 删（§2.1 契约 v3）。**

#### 🔴 第四层发现：字段名 `inflection_of` 过窄 —— LLM 把派生词也填了

`inflection_of` 非空的 17 条中，**6 条是 `-ly` 派生副词**（不是屈折形式）：

| 词 | 填的 `inflection_of` | 严格说是 |
|---|---|---|
| `recently` | `recent` | **派生**（recent + -ly） |
| `anxiously` | `anxious` | **派生** |
| `justifiably` | `justifiable` | **派生** |
| `suspiciously` | `suspicious` | **派生** |
| `respectably` | `respectable` | **派生** |
| `delicately` | `delicate` | **派生** |

**这不是错，是「字段语义被 LLM 放宽」** —— 它填的是「**它源自哪个基础词**」（词族归属），而非严格的「屈折形式归属」。

**🟠 这层信息其实有价值**：
- `recently→recent`：`word_form` **也有**这条映射 → 两者可**交叉校验**（能发现 `word_form` 的错）
- `attuned→attune`：`word_form` **没有**（`attune` 不在词表）→ **补位**

**✅ 处置（白哥已同意）**：字段改名 **`inflection_of` → `derived_from`**，语义放宽为「源自哪个基础词（屈折或派生）」。
**→ 改名后那 8 条漏填的派生副词也会填上，`base_form` 才真正 100% 可推导。**

#### ✅ 附带证实：`derived_from` 与 `analyzable` **正交**

**11 条不规则变形**：`feet→foot` · `taught→teach` · `sworn→swear` · `torn→tear` · `sat→sit` · `awoke→awake` · `bred→breed` · `analyses→analysis` · `las→la` · `pistols→pistol` · `forbidden→forbid`

这些 `analyzable=false`（**不可拆**，因为是不规则变形）但 **`derived_from` 有值** ✅
**→ 证明两个字段回答不同问题**：可拆性（记忆法）与形态归属（统计）**互不依赖**。

**🔴 硬约束（白哥已同意）**：`is_own_entry=false` ⟹ `derived_from` 非空（否则查词路由落空）。
**实测当前违反**：`relation=inflection` 但 `derived_from` 空 —— **2/28 = 7%**（`studded`·`involved`，应为 `stud`/`involve`）。

#### ✅ 契约 v3 重跑结果（¥1.075 / 160 词 × 2 轮）

| 指标 | 结果 | 判断 |
|---|---|---|
| **`base_form` 可推导（已删）** | **160/160** | ✅ 删除决策验证成立 |
| **违反硬约束**（`own=false` 但 `derived_from` 空） | **0** | ✅ 硬约束生效 |
| `derived_from` 非空率 | **66.2%**（v2 的 `inflection_of` 仅 **26.9%**） | ✅ **改名放宽语义后覆盖率翻倍** |
| `relation` 值越界 | 0 | ✅ |
| `derived_from` 键缺失 | 0 | ✅ |
| 自洽性：`is_own_entry` / `derived_from` | **98.8% / 98.8%** | ✅ 稳定 |
| 自洽性：`analyzable` / `parts` / `relation` | 🟠 **94.4% / 91.9% / 92.5%**（v2 为 99.4% / 95.0% / 99.4%） | 🟠 **下降，见下** |
| 必查清单（三项任一不一致） | 8.8% | 🟠 |
| 可拆率 | **66.9%** | ✅ |

**`relation` 分布**：`derivation` 69 · `inflection` 35 · `compound` 3
**`studded`/`involved` 的 `derived_from` 已被硬约束补上**（`stud`/`involve`）—— v2 时为空。

#### 🔴 自洽性下降的根因：prompt 变长 → 注意力稀释

**不是随机抖动，是单向的**：

| 方向 | 数量 | 例 |
|---|---:|---|
| 第 1 轮 `analyzable=true` → 第 2 轮 `false` | **8** | `convenient` · `pressure` · `stable` · `resolute` · `retrieve` · `lyrics` · `sanctions` · `awoke` |
| 第 1 轮 `false` → 第 2 轮 `true` | **1** | `feet` |

**→ 第 2 轮更保守，且更对**。第 1 轮的「可拆」判断里有系统性幻觉。

#### 🔴 幻觉模式：**单字母/无意义词素**

第 1 轮拆出的可疑词素（第 2 轮自己放弃了）：

| 词 | 第 1 轮拆分 | 问题 |
|---|---|---|
| `stable` | **`st`** + `-able` | `st` 不是词根（真词源 Latin `stabilis`，词根 `sta`） |
| `resolute` | `re-` + `solut` + **`-e`** | `-e` 不是后缀 |
| `retrieve` | `re-` + `triev` + **`-e`** | `-e` 不是后缀 |
| `resemble` | `re-` + `sembl` + **`-e`** | `-e` 不是后缀 |
| `awoke` | **`a-`** + `woke` | `awoke` 是 `awake` 的不规则过去式 |
| `eroded` | **`e-`** + `rod` + `-ed` | `e-` 是 `ex-` 的变体，不应独立 |
| `width` | **`wid`** + `-th` | 真基础是 `wide`（LLM 第 2 轮自己改对了） |
| `convenient` | `con-` + **`veni`** + `-ent` | `veni` 是 `venire` 词干，临界 |

**→ 可自动化的信号：词素 `form` 去连字符后长度 ≤ 1 的 `prefix`/`suffix`（除 `-s`/`-y`/`-a` 等真后缀）高度可疑。**

#### 🔑 方法论补充：「规则不能做判断，但可以做校验」

前面否定了「规则做语义判断」，但这里有一个**合法的规则用法**：

| 用途 | 合法性 | 例 |
|---|---|---|
| **规则做语义判断** | ❌ 已否定（无法自证遗漏） | 「`-er` 结尾 → 比较级」 |
| **规则做合法性校验** | ✅ **合法** | 「后缀 `-e` 不在合法后缀表 → 标记可疑」 |

**区别**：判断是「给出答案」，校验是「**检查答案是否越界**」—— 后者不需要完备性，只需**单调可靠**（检出即为可疑，不保证全检）。
**→ 落点**：全量跑完后，用词素白名单/长度阈值筛出可疑项 → **只对这些项补跑第 2 轮**，而非全量两轮。

#### 🟠 一处看似矛盾、实则不是

**13 条 `is_own_entry=true` 却拆出屈折后缀**（`attuned`+`-ed` · `used`+`-ed` · `sanctions`+`-s` · `lyrics`+`-s` · `rendering`+`-ing`…）

**这不矛盾** —— 正是「两个维度」的体现：
- `is_own_entry=true`：**语义层面**它值得有自己的卡（`attuned`=对…敏感的）
- `relation=inflection`：**形态层面**它由 `attune` + `-ed` 构成

**与 `farmer`（独立 + 派生）同理，`attuned` 是「独立 + 屈折」** —— 所以 `relation` 必须独立于 `is_own_entry`，这也是 §1.2 分流规则的依据。

---

### 2.2 完整输出示例（契约 v4）

> 🔴 **v4 变更（2026-09-26 白哥指出「词源字段太简单」）**：`etymology` 从**纯字符串**改为**结构化对象**（`text` + `etyma[]`），**否则无法按词源聚合**。见 §1.7 / §1.11。

```json
{
  "word": "receive",
  "is_own_entry": true,
  "derived_from": null,
  "reason": "独立动词，核心义「接收」",
  "morphology": {
    "analyzable": true,
    "relation": "derivation",
    "parts": [
      {"form": "re-", "type": "prefix", "meaning": "回、再", "origin": "Latin"},
      {"form": "ceive", "type": "root", "meaning": "拿、取", "origin": "Latin"}
    ]
  },
  "etymology": {
    "text": "拉丁 capere（拿取）→ 法语 receivre → 中古英语 receiven",
    "etyma": [
      {"form": "capere", "form_ascii": "capere", "language": "Latin",
       "meaning": "拿取", "role": "root"}
    ]
  },
  "collocations": [{"phrase": "receive a letter", "zh": "收到一封信"}],
  "mnemonic": {"primary": "root", "secondary": ["cognate"], "rationale": "re(回)+ceive(拿) = 拿回来 → 接收"},
  "confidence": 0.92
}
```

**`etymology` 结构说明**：

| 字段 | 类型 | 落点 | 用途 |
|---|---|---|---|
| `etymology.text` | 字符串 | `word.etymology_text` | **叙事文本**，供卡片展示（可读） |
| `etymology.etyma[]` | 数组 | `etymon` + `word_etymon` | 🔑 **结构化引用，供词源聚合** |

**`etyma[]` 每项**：

| 键 | 说明 | 例 |
|---|---|---|
| `form` | 源词原拼写（**可含非 ASCII**） | `capere` · `γράφειν` · `Ärger` |
| `form_ascii` | **ASCII 转写（聚合键）** | `capere` · `grafein` · `aerger` |
| `language` | 源语言 | `Latin` \| `Greek` \| `French` \| `Old English` \| `Proto-Germanic` |
| `meaning` | 中文义 | `拿取` |
| `role` | 在词中的角色 | `root` \| `prefix` \| `derived` \| `whole`（整体借词） |

**例：`café`（整体借词）**
```json
"etymology": {
  "text": "法语 café（咖啡）→ 借入英语",
  "etyma": [{"form": "café", "form_ascii": "cafe", "language": "French", "meaning": "咖啡", "role": "whole"}]
}
```
**→ `role=whole` 也会入 `etymon` 表**（单成员族），**但它不单独建聚合页**（门槛 ≥3，§1.8）。

**输出 → 落点映射（契约 v4）**：

| JSON 路径 | 落表 |
|---|---|
| `is_own_entry` | `word`（建不建记录；`true` 才建） |
| `derived_from` | `word_form.base`（链式；`is_own_entry=false` 时的直接基）+ 独立词条的**形态归属** |
| ~~`base_form`~~ | ❌ **已删** —— 恒等于 `is_own_entry ? word : derived_from` |
| `morphology.relation` | `word_morpheme.relation` + **决定 `word_form` 旧映射去留**（§1.2） |
| `morphology.parts[]`（`type=prefix/suffix`） | → **`affix`**（按 `(form,type)` 查表；命中则复用 `affix_id`，未命中的义**新增** `needs_review=1`）+ `word_morpheme`（`surface`/`gloss`） |
| `morphology.parts[]`（`type=root`） | → **`word_root`**（按 `(form,type,origin)` 查表）+ `word_morpheme` + `card.content.sections[type=root].payload.parts` |
| `morphology.parts[type=root]` 相同 **且** `relation≠inflection` | → `cognate_group`（**词根族**，自动派生，须排除 `relation=inflection`） |
| **`etymology.text`** | `word.etymology_text`（叙事，**不占 `sections` 位** —— P1-9） |
| 🔑 **`etymology.etyma[]`** | **`etymon`**（按 `(form_ascii, language)` 查表/新增）+ **`word_etymon`** → **`etymon_group` 聚合页（`page_type='etymon'`）** |
| `collocations[]` | `collocation` + `word_collocation` |
| `mnemonic.*` | `word_mnemonic_profile` |

> ⚠️ **`cognate_group` 派生必须排除 `relation=inflection`** —— 否则 `isolate` 与 `isolated` 会因共享词根 `isolat` 被当成同族。
> **同族**是 `receive`/`perceive`/`conceive`（**互不派生的不同词**）；`isolate`/`isolated` 是**同一词的不同形态**，归 `word_form` 管。
>
> ⚠️ **词源族的优势**：`cognate_group` 靠**词根**（LLM 拆词，有误合并），`etymon_group` 靠**源词**（更准确）。
> `rod` 的实证：词根 `rod` 会把 `eroded`(Latin rodere) 与 `rodder`(Old English rod) 错并；词源能正确分开。

---

## 三、1,375 张冲突卡的处置（LLM 全量跑替代人工分组）

**v1 的 `UNIQUE(lemma)` 会与 1,375 张卡冲突**（涉及 1,130 个 lemma；`be`←are/am · `run`←running/ran · `tooth`←teeth…）。

规则法把它分成组 A（884 纯屈折）/ B（338 有独立义）/ C（161 灰区），然后要我人工判 18 条 —— **这条路已被白哥否定**（规则错判无法自证，见 §四.1）。

**新路径**：`entry.is_own_entry` 由 **LLM 逐词判定**：

| 判定 | 建 `word` 记录 | `word_form` |
|---|---|---|
| `is_own_entry=true` | ✅ 建（`spelling` = 该词形，**无 `lemma` 字段**） | 按 `relation` 分流（屈折保留 / 派生删除）—— 见 §1.2 |
| `is_own_entry=false` | ❌ 不建 | ✅ 保留为查词路由（`lemma` = `base_form`） |

**→ 冲突自然消解**：判定为 `false` 的**根本不进 `word` 表**，所以撞不上；判定为 `true` 的各自独立，也撞不上。**不再需要 `UNIQUE(lemma)`，也不再需要人工判组 A/B/C。**

**抽样实测折算**（S2 60 条样本）：LLM 判独立 **35.0%** → 全 1,375 张约 **481 张保留 / 894 张合并**。
（对照规则法：组 A 884 建议全合并，但抽样显示其中 **17% 应保留** → 约 150 条误合；组 B 20% 应合并 → 约 68 条误留。）

**→ 抽样必须包含这 1,375 张冲突卡**（S2 组），才能验证 LLM 判定的质量。

---

## 四、抽样验证方案（回答「怎么评质量、怎么知道漏了」）

### 4.1 🔴 为什么规则法判断不了自己的遗漏

| | 规则法 | LLM 全量重跑 |
|---|---|---|
| 覆盖面 | **只在你写规则的地方找** → 遗漏 = 规则盲区，**无参照可测** | **每词都跑** → 覆盖面 = 100%，遗漏变成「判错」，**可统计** |
| 判「遗漏」 | 需要另一个规则 → **循环** | 用**人工盲评 + 交叉模型分歧**，不用规则 |
| 可测指标 | 「我想到的都判了」（自我指涉） | 准确率 / 一致率 / 分歧数（**有分母**） |

### 4.2 三条不依赖规则的质量评估

| 方法 | 做法 | 产出指标 |
|---|---|---|
| **① 人工盲评** | 抽 N 条输出，**只看 LLM 结果判对错**（不看规则、不看我的预期） | 准确率（唯一真 ground truth） |
| **② 多轮自洽** | 同词同 prompt 跑 2 轮（温度 0.1），比对 `analyzable`/`parts`/`entry` 是否一致 | 一致率、**分歧清单**（= 必查项） |
| **③ 交叉模型** | 换模型（`deepseek-chat` vs `flash`）跑同一批 | **分歧项 = 疑似错误清单**（比规则找遗漏可靠） |

> **关键**：方法 ②③ 的产物是「**分歧清单**」—— 它**不是靠规则找遗漏**，而是靠「两个独立模型不一致」定位可疑项。规则法的漏检永远发现不了自己漏了，而分歧法**必然暴露**。

### 4.3 抽样设计

| 组 | 抽样对象 | 数量 | 目的 |
|---|---|---:|---|
| **S1** | 分层随机（每 CEFR 等级 20 词） | **100** | 测内容生成整体质量（词根/词源/搭配/画像） |
| **S2** | 1,375 张冲突卡随机 | **60** | 测归一化判定（`is_own_entry` / `base_form`） |
| **合计** | | **160** | ×2 轮 = 320 次调用 |

**成本** ≈ **¥0.5**（deepseek-flash，thinking disabled）；**耗时** ≈ 2 分钟（8 并发）。

---

## 五、待白哥确认

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **16 张表**（v1 的 14 张 + `word_form` + `affix`）是否认可为冻结版 | ✅ 认可 |
| 2 | `frequency_rank` 不建（CEFR 已足） | ✅ 不建 |
| 3 | LLM 输出契约（§二 的 JSON 结构） | ✅ 用这个跑抽样 |
| 4 | 「可拆」分三类 → `word_morpheme.relation` = `inflection`/`derivation`/`compound`（v1 的 `word_root.type` 装不下 `subway`=sub+way） | ✅ 加 `relation` 字段（P1-6 待定其落点） |
| 5 | 抽样规模 160 词 × 2 轮（¥0.5） | ✅ 已执行（实际 ¥0.817） |
| 6 | **`word` 表去掉 `lemma` 字段**，改 `UNIQUE(spelling)`（§1.1） | ✅ **已定：去掉** |
| 7 | ~~`is_own_entry=true` 时删除 `word_form` 旧映射~~ | 🔴 **已撤回**（§1.2）—— 改为**按 `relation` 分流**：屈折**保留**、派生**删除** |
| 8 | **契约 v2**：加 `entry.inflection_of` + `relation` 扩值域 `inflection`（§2.1） | ✅ 已采纳并重跑验证 |
| 9 | **`cognate_group` 派生排除 `relation=inflection`**（§二 落点映射） | ✅ **必须排除** —— 否则 `isolate`/`isolated` 会被当同源族 |
| 10 | `attuned→attune` 这类「基础词不在词表」的形态归属，靠 `derived_from` 承载 | ✅ 采纳（`word_form` 无解） |
| 11 | **`inflection_of` 改名 `derived_from`**（语义放宽为「源自哪个基础词」） | ✅ **已同意** |
| 12 | **硬约束**：`is_own_entry=false` ⟹ `derived_from` 非空 | ✅ **已同意**（当前违反 7%） |
| 13 | ~~保留 `base_form` 作交叉校验~~ | 🔴 **已推翻** —— 实测 `base_form` 100% 可推导（**115/115** + **37/37**）→ **契约 v3 删除 `base_form`** |
| 14 | **契约 v3：删 `base_form` + 扁平化 `entry`**（`entry.is_own_entry` 重名） | ✅ **已同意并重跑验证**：`base_form` 可推导 **160/160**、硬约束违反 **0** |
| 15 | **幻觉检测用「规则做校验」**（词素长度阈值 / 白名单）筛可疑项 → 只对可疑项补跑第 2 轮 | 🟠 **建议采纳** —— 规则不做判断、只做校验是合法用法（§2.1） |
| 16 | prompt 变长导致 `analyzable` 自洽性从 99.4% → 94.4%（单向：第 1 轮偏激进） | 🟠 建议：**全量跑 1 轮 + 可疑/分歧子集补跑第 2 轮取交集** |
| 17 | **词源结构化**（`etymology` → `{text, etyma[]}`）+ 新增 `etymon`/`word_etymon`（白哥指出「词源字段太简单，没办法按词源聚合」） | ✅ **已按白哥意见设计并实证**（§1.7 / §2.2 契约 v4） |
| 18 | **聚合页两类**：`page_type='root'`（词根族）+ `'etymon'`（词源族） | ✅ **已设计**；🔴 **实证：词源族 6/7 成族 vs 词根族 2/7** → **以词源族为主** |
| 18b | 🆕 **`etymon` 也要链式**（`parent_id`/`anchor_id`）—— LLM 给出的源词粒度不一（`perceive`→`percipere`） | ✅ **实测上溯 8/8 = 100%**；不链式则 `capere` 族只能聚 2 个（漏 `perceive`/`deceive`） |
| 19 | **`COLLATE NOCASE` 加到 6 处**（`word.spelling`/`word_form.*`/`affix.form`/`word_root.form`/`etymon.form_ascii`/`collocation.phrase`） | ✅ **已按白哥意见加**（§1.11） |
| 20 | **即时生成走同一套**（`generated_card_cache` 加 NOCASE + 同样产出 `etyma` + 同样查 `affix`） | ✅ **已按白哥意见设计**（§1.11） |
| 21 | `etymon` **双列**（`form` 显示 / `form_ascii` 聚合键）—— 因为 NOCASE 不折叠非 ASCII | ✅ **已设计**；契约实测 **`form_ascii` 196/196 全 ASCII** ✅ |
| 22 | **`etymology.text` 不占 `sections` 位**（P1-9 新解法：叙事与结构化分工，非双存） | ✅ 建议采纳 |

---

### 五.2 🔴 P0 三项处置（2026-09-26 白哥定 + 实测支撑）

| # | P0 问题 | ✅ 处置 | 依据 |
|---|---|---|---|
| **P0-1** | `word_root.UNIQUE(form,type)` 与实测冲突 | **新建 `affix` 表**（`UNIQUE(form,type,sense)`）+ `word_root` 改 `UNIQUE(form,type,origin)`；**优先选释义、匹配不上则新增**（白哥方案） | 词缀 **27% 多义**（同形多义）；词根 0.9% 但性质是**同形异源**（`rod`: Latin 咬 / Old English 汽车）→ **`origin` 必须进唯一键**（推翻我原建议） |
| **P0-2** | `word_form` 129 条路由二义 + 链式 | **改链式**：加 `base`/`anchor`/`anchor_id`/`depth`/`kind`；`anchor` **预计算**（构建期上溯，运行时一次索引查询）；**中间节点补跑 LLM ≈970 个 / ¥2.5** | `derived_from` 有 **12.3%（13/106）** 指向词表外；其中 **3 条 `is_own_entry=false` 会划词无卡**（`slaying→slay`·`eroded→erode`·`freeholders→freeholder`）→ 全量预估 **约 330 词受影响** |
| **P0-3** | `sort_seq UNIQUE` 无 `NOT NULL` | ✅ **加 `NOT NULL`** | SQLite 实测：**两条 NULL 都被接受** → 唯一性失效 → 音频命名互相覆盖 |

**P0-1 的连带收益**（实测）：词缀义表述极度不一致 —— `-ed` 有 **8 种**说法、`-er` **6 种**、`re-` **5 种**。
**归一化后 103 行 → 78 行（压缩 24%）** → 若不建词缀表，用户会在 50 张卡里看到 8 种不同的 `-ed` 解释。

**P0-1 的实现建议**：**词缀表不进 prompt**（全量 300 行会 **+5,040 token / +336%**，v3 已实证 prompt 变长会稀释注意力让自洽性从 99.4% 掉到 94.4%）→ 改为**本地落库归一化**（维护 `affix.aliases` 同义表）。

---

### 五.3 白哥已批复（2026-09-26 第三轮）

| 事项 | 批复 |
|---|---|
| **词源字段太简单 → 按词源聚合** | ✅ **已加** `etymon`/`word_etymon` + `aggregate_page.page_type`（§1.7/§1.8） |
| **两类聚合：词源 + 词根** | ✅ **已设计**；🔴 **针对性实证：词源族 6/7 成族，词根族仅 2/7** → **以词源族为主** |
| **加 `COLLATE NOCASE`** | ✅ **已加 6 处**；⚠️ 已交代**只折叠 ASCII** 的硬限制（§1.11） |
| **查询大小写不敏感** | ✅ `=` 比较同样折叠（实测 `= 'INDIA'` 能命中 `India`） |
| **即时生成也要走同一套** | ✅ **已设计**：NOCASE + 结构化 `etyma` + 查 `affix` + 同分流逻辑（§1.11） |
| **其他同意** | ✅ P1-6/7/8/10/11、P2-13/15/16/17 等按建议执行（见 `word-db-p1p2-recommendations`） |

#### 🔴 契约 v4 已重跑验证（¥1.469 / 160 词 × 2 轮）

| 指标 | 结果 |
|---|---|
| `etymology` 是对象（非字符串） | ✅ **160/160** |
| `etyma` 键缺失 | **0** |
| **`etyma` 为空数组** | ✅ **仅 2/160 = 1%**（聚合覆盖面 99%） |
| **`form_ascii` 纯 ASCII** | ✅ **196/196** |
| etyma 条目总数 | **196** |
| 语言分布 | Latin 85 · Old English 53 · Greek 26 · French 18 · English 3 · Hebrew 2 · Old Norse 2 · Spanish 2 |
| `role` 分布 | root 112 · whole 57 · derived 13 · prefix 10 · suffix 4 |
| 自洽性 | `is_own_entry` 99.4% · `analyzable` 97.5% · `parts` 94.4% · `relation` 95.6% · `derived_from` 98.1% |
| 硬约束违反 | **0** ✅ |

**非 ASCII 实测覆盖到了**（验证双列必要性）：`grētan` · `Ἰνδός` · `יִצְחָק` · `wǣt` · `eorþe` → **全部有对应 `form_ascii`** ✅

---

### 五.4 仍待处置（P1/P2 剩余）

| 级 | # | 问题 | 阻塞 |
|---|---|---|---|
| 🔴 P2 | **12** | **搭配解析错位 2,021 行（14.1%）** —— 两种格式并存 | **搭配正确性（建议优先）** |
| P1 | 6 | `relation` 是词级属性存行级 | 无（迁移期用） |
| P1 | 7 | `card_audio.section_index` 指代 | ✅ **已加 `scope`**（§1.10）→ 🟠 **2026-09-26 暂缓**（表**保留 DDL 但暂不写入**，预留后续收费扩展） |
| P1 | 8 | `card_extra` 是否计入 `content_hash` | **Phase 2 语音包** |
| P1 | 10 | 契约缺 `primary=root ⟹ analyzable=true`（实测 6 条矛盾） | 全量重跑前 |
| P2 | 13 | `etymology` 生成率 91.9% | 建议不收紧（前提：text 不占 section 位） |
| P2 | 14 | **`etymon_group` + `cognate_group` 规模都要验证** | **聚合页是否值得做** |
| P2 | 18 | 幻觉词素入库 | 规则校验拦 |

**→ 建议下一步：① 修搭配解析脚本（P2-12，数据正确性）② 契约 v4 重跑抽样（验证 `etyma` 质量 + 幻觉率）③ 全量跑完后验证两类聚合族规模（P2-14）→ 决定聚合页去留。**

---

*本文档为设计产出，未修改任何代码或生产环境。抽样脚本：`scripts/llm_full_rerun_sample.py`*
