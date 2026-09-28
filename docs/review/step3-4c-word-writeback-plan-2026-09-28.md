# Step 3.4c 实施方案：查词写入（`user_word` + `lookup_event`）

> 日期：2026-09-28｜来源：白哥批准「先把 3.4c 的实施方案核清楚」
> 状态：**✅ 已定案**（2026-09-28）· **尚未开始实施**
> 权威依据：`docs/design/v1-final-design-authoritative-2026-09-25.md` **§3.2 / §八 / §九**（L0）

---

## 〇、定案汇总（2026-09-28 · 白哥）

| # | 决策点 | 定案 |
|---|---|---|
| **迁移** | 已有设备如何拿到新表 | ✅ **方案 A**：`user_version` 1→2 + `onUpgrade` **重跑全量幂等 schema** |
| **Q1** | 超 200 词后查新词 | ✅ **A**：**仍弹浮层**，只是不入生词本（不打断阅读） |
| **Q2** | 未命中的词是否记 `lookup_event` | ✅ **都记** |
| **Q3** | 软删后重查同一词 | ✅ **A**：**复活**（`deleted` 1→0） |
| **LLM 制卡** | 未命中词走 LLM | ✅ **留 Phase 3** —— 3.4c 只记 `lookup_event`，**暂不制卡** |
| **Q4** | 是否记录「用户实际点的词形」 | ⏸ **按 v1 不加列**（保守默认；需要时再加） |
| **Q5** | `source_sentence` 落地方式 | ⏸ **按 C**：照 v1 存 + **加断言**锁「与 `lookup_event` 最早一条一致」 |

### 🔴 一条留给 Phase 3 的**待澄清需求**（白哥原话）
> 「未命中的词应该走 **LLM 生词 → 进入词库**」

**必须在 Phase 3 开工前澄清「进入词库」的确切含义** —— 因为字面理解会撞上两堵墙（见 §六）：

| 解读 | 后果 |
|---|---|
| **A. 进「端侧缓存」（v1 原设计）** | ✅ 可行。写 `external_word_cache`，不走词库 |
| **B. 真的写回 `word.db`（主词库）** | 🔴 破坏「只读预制库」前提 · 与 `verify_worddb_sync` 的两份一致性断言冲突 · 词库升级时被覆盖 |
| **C. 只是「能进生词本」（体验上像在词库）** | ⚠️ 需先解决 §六 的**结构性断链**（`user_word.word_id NOT NULL` vs 词库外词无 id） |

> 我自己**倾向 A**（v1 原设计 + 风险最低），但这需要白哥在 Phase 3 确认 ——
> 🔑 **不在 3.4c 里预先替 Phase 3 决定架构。**

---

## 一、结论先行：**范围比「建两张表」小**

我原以为 3.4c 是「从零建两张表 + 写仓储 + 接链路」。核实后发现**写入侧大半已就绪**：

| 件 | 状态 | 位置 |
|---|---|---|
| `ReviewListQuery.upsertState(...)` | ✅ **已实现，无调用方** | `services/review_list_query.dart:133` |
| `ReviewListQuery.stateOf(wordId)` | ✅ 已实现 | 同上 `:167` |
| `BookmarkRepository` | ✅ **完整模式可复用**（纯 Dart · 幂等 · UTC 解析 · pending 模式） | `services/bookmark_repository.dart` |
| 查词浮层 | ✅ 已建，且**确认无任何写入意图**（只读） | `widgets/lookup_sheet.dart` |

🔑 **`stateOf` 的注释直接写着**：
> 「取某一词的复习状态（**查词后**决定「已在生词本」还是「新增」）」

→ 说明 `review_list_query` 是**为 3.4c 预建的数据层**（与 `word_query_service` 同理）。
**3.4c 真正缺的只有四件**：

1. `user_word` + `lookup_event` **两张表的 DDL**（schema 未建）
2. `UserWordRepository`（纯 Dart 仓储）
3. **查词链路接写入**（`reader_screen._lookupWord`）
4. 200 词上限判定 + 超限引导

---

## 二、🔴 首要风险：**迁移**（不解决则新表根本不生效）

### 2.1 事实链（每步可查）

| # | 事实 | 出处 |
|---|---|---|
| 1 | `const int kUserDbVersion = 1;` | `user_db.dart:37` |
| 2 | `onCreate: (db, version) => executeSqlScript(db, schemaSql)` —— **只在新建库时跑** | `user_db.dart:93` |
| 3 | `onUpgrade` **直接抛 `StateError`**（「没有迁移脚本」） | `user_db.dart:94-102` |
| 4 | 注释断言「**本库从未在任何端创建**」 | `user_db.dart:33` · `user_db_schema.sql` 末尾 |
| 5 | 🔴 **但白哥已真机验证「收藏好了」** → 收藏走 `bookmark` 表 → **`user.db` 必然已存在且 `user_version = 1`** | 本轮对话历史 |

### 2.2 后果

把两张表加进 `user_db_schema.sql` 后，在**已有 `user.db` 的设备上**：
- `onCreate` **不重跑**（不是新库）
- `onUpgrade` **不触发**（version 没变，仍是 1）
- → **新表不会被创建** → 运行时 `no such table: user_word`

🔴 **且验收脚本验不出来**：脚本用**临时新库** → `onCreate` 会跑 → 全过。
**又一个「在错平台/错条件下验证」的变体** —— 这次差异不是平台，而是**「新库 vs 已有库」**。

### 2.3 两个解法（**请白哥裁决**）

| | 方案 A：version 递增 + `onUpgrade` | 方案 B：`onOpen` 补跑幂等 DDL |
|---|---|---|
| 做法 | `kUserDbVersion` 1→2；`onUpgrade` 里执行 DDL | `onOpen` 里跑 `CREATE TABLE IF NOT EXISTS` |
| 规范度 | ✅ 标准做法，版本历史清晰 | ⚠️ 绕过了版本机制 |
| 代码量 | 中（要维护迁移分支） | 小 |
| 风险 | 迁移写错 → 老库状态不明 | 每次启动都跑一遍脚本（开销小但存在） |
| 适合 | 长期（会有 v3、v4…） | 短期/尚未发版 |

> 🔑 **一个折中点（我倾向）**：**方案 A，但 `onUpgrade` 直接执行「全量 schema 脚本」** ——
> 因为本库 DDL **全部是 `CREATE TABLE IF NOT EXISTS`**（幂等），
> 所以 `onUpgrade` 里跑全量脚本 = 自动补齐缺失的表，**不需要维护「增量 vs 全量」两套 DDL**。
> 这同时消除了「迁移脚本与实际 DDL 不一致」这类经典漂移。

⚠️ **但有个前提必须确认**：若将来出现「改列」类迁移（`ALTER TABLE`），
幂等全量脚本**不能**替代它（`IF NOT EXISTS` 对已有表是空操作）→ 那时才需要真正的增量分支。

---

## 三、两张表的 DDL（v1 原文 + 三处必须适配）

### 3.0 v1 原文（L0 权威 · 逐字引用）

```sql
-- 生词本（v1 §3.2）
CREATE TABLE user_word (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id           INTEGER NOT NULL,
  source_article_id INTEGER,
  source_sentence   TEXT,
  added_at          TEXT DEFAULT (datetime('now')),
  updated_at        TEXT DEFAULT (datetime('now')),
  deleted           INTEGER DEFAULT 0,
  pending_push      INTEGER DEFAULT 1,
  UNIQUE (word_id)
);

-- 查词记录（v1 §3.2）
CREATE TABLE lookup_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id      INTEGER,
  article_id   INTEGER,
  sentence     TEXT,
  position     INTEGER,
  looked_up_at TEXT DEFAULT (datetime('now'))
);
```

### 3.1 🔴 三处必须适配（与 `bookmark` 的偏离处理**同源**）

| # | v1 原文 | 现库规范 | 理由 |
|---|---|---|---|
| 1 | `datetime('now')` | **`strftime('%Y-%m-%dT%H:%M:%SZ','now')`** | 现库**硬约束 1**：所有时间列 UTC ISO8601 带 `Z`。`datetime('now')` 是空格分隔无 `Z` → Dart 侧 `DateTime.parse` 会**按本地时区解释**（静默错位）。`bookmark` 已踩过这条并写明 |
| 2 | `word_id INTEGER NOT NULL` | **`TEXT NOT NULL`** | 现网词库主键是 **TEXT**（如 `w008732`），不是 INTEGER。`user_db_schema.sql` 顶部已就此说明（`card_review_state` 同处理） |
| 3 | `pending_push INTEGER DEFAULT 1` | **补 `NOT NULL` + `CHECK (IN (0,1))`** | 与 `card_review_state` / `bookmark` 同规格。v1 是**草图级 DDL**，本库是**权威定义** |

> 🔑 **这三处都不是「擅自改设计」**，而是「v1 是草图、现库有更严的事实约束」。
> `bookmark` 落库时已用完全相同的方式处理过（见 `user_db_schema.sql` 的 bookmark 注释）。

### 3.2 需要索引

```sql
-- 生词本列表：按加入时间倒序（同 bookmark 的 idx_bm_time）
CREATE INDEX idx_uw_time ON user_word (added_at DESC);
-- 200 上限计数：WHERE deleted = 0
CREATE INDEX idx_uw_alive ON user_word (deleted) WHERE deleted = 0;
-- 查词记录：按词取首/末次语境 → 记忆里明确「取首次 MIN(looked_up_at)」
CREATE INDEX idx_le_word ON lookup_event (word_id, looked_up_at);
-- pending_push 的 partial index（同 bookmark / card_review_state 模式）
CREATE INDEX idx_uw_pending ON user_word (pending_push) WHERE pending_push = 1;
```

---

## 四、与 `bookmark` 的复用点（**逐条**）

| # | 复用什么 | 说明 | 可直接用？ |
|---|---|---|---|
| 1 | **`parseUserDbUtc()`** | 强制要求尾随 `Z`，缺了就抛错 | ✅ **必须复用**（新仓储同样读时间列） |
| 2 | **纯 Dart 零 Flutter 依赖** | 本层无 `rootBundle`，DDL 由调用方注入 | ✅ 同样约束（本地可验） |
| 3 | **幂等 `add`**（不刷新时间戳） | 收藏重复点击不改 `bookmarked_at` | ✅ **但语义要改**：生词重复查词时，`added_at` 保持首查（v1 一致），而 `updated_at` **要更新**（v1 有该字段） |
| 4 | **`pending_push` + `markSynced` + `pending()`** | 完整数据层（表+索引+查询齐备） | ✅ 照搬模式（同步属 Phase 3，但「表有了查询也有了」才算完整） |
| 5 | **`_fromRow` + 值类型 `==`/`hashCode`/`toString`** | 便于断言比较 | ✅ 照搬 |
| 6 | **硬删 vs 软删的区分** | `bookmark` **硬删**（注明「收藏是可再生意图」）；`user_word` **必须软删**（v1 有 `deleted` 字段） | ⚠️ **反向** —— 这条不能照搬，要按 v1 用软删 |
| 7 | **「按访问形态选数据结构」的判据** | `bookmark` 用内存 `Set`（读多写极少 + 单条判定） | ⚠️ **不适用** —— 生词本要 **COUNT + 列表 + 排序**，内存集合不合适。**不要照搬** |

> 🔑 第 6、7 条是**反向价值**：`bookmark_repository` 的价值不只是「照抄什么」，还有「**哪些不适用**」。

---

## 五、产品决策点（**✅ 已定案 · 见 §〇**；本节保留选项与理由作决策依据）

### Q1 · 超过 200 词时怎么办？

记忆里的产品原则：
> 「**只有「生词本新增超 200 词上限」→ ✅ 需要**（登录）」
> 「免费层：生词本 **200 词**上限」

| 选项 | 行为 | 代价 |
|---|---|---|
| **A** | 查词**仍弹浮层**，但**不入生词本** + 提示「已达 200 词上限」+ 订阅引导 | 用户能继续查词（不打断阅读），只是不积累 |
| **B** | 查词**拦截**（弹订阅页） | ❌ 严重打断阅读 —— 与「内容渲染不得被登录态阻塞」原则冲突 |
| **C** | 允许无限加入，只在**生词本页**提示超出 | 与「200 上限」的商业设计冲突 |

→ 我倾向 **A**（B 违反已定的产品原则）。

### Q2 · 未命中的词（词库外）要不要记 `lookup_event`？

v1 §九 的流程：命中 → 写 `user_word` + `card_review_state`；**未命中 → 走 `external_word_cache`（Phase 3）**。
但 `lookup_event` 是**查词记录** —— 查了就该记（否则「你查过哪些词」不完整）。

| 选项 | 说明 |
|---|---|
| **A** | 命中记 · **未命中不记**（严格照 v1 §九） |
| **B** | **两者都记**（`lookup_event` 是纯日志，与卡片是否命中无关） |
| C | 只记命中（同 A），但 `word_id` 可空正是为未命中预留 → 暗示应记 |

> 🔑 `lookup_event.word_id` 在 v1 里是**可空**的（无 `NOT NULL`）——
> 这个设计本身暗示「查了但没查到词」也要留痕。故我倾向 **B**，但**由白哥定**。

### Q3 · 软删 `deleted` 的语义

| 子问题 | 选项 |
|---|---|
| 删除后又查同一个词 | A. **复活**（`deleted=1→0`）· B. 保持删除状态（用户明确不要了） |
| 200 上限是否算已删的 | A. 不算（`WHERE deleted = 0`）· B. 算 |

> 记忆里写「**200 词上限 = 唯一 lemma 数**」→ 倾向「不算已删」。
> 但「复活 vs 保持」我**没有依据**，需要白哥定。

### Q4 · 要不要记录「用户实际点的词形」？

**这是一个独立的产品问题**（不依赖任何转述文档）：

场景：用户点的是 `running`，但生词本按 lemma 唯一 → 记的是 `run`。
那么「用户当时点的形态」要不要存？

| 选项 | 说明 |
|---|---|
| **A** | 不存（照 v1）—— `lookup_event.word_id` 记的是**词库里的词**，形态信息丢失 |
| **B** | `lookup_event` 加一列 `form TEXT`（用户实际点的串） |

> ⚠️ **为什么我不引用「v2 的 `content_lookup` 有 lemma/form 更优」**：
> 那条来自 `v1-final-vs-v2-authoritative-mapping` 的**转述**，
> 而我去**后端源码里核实**时 —— 🔴 **`content_lookup` 表在后端已不存在**（搜 `backend/**/*.rs` 与 `migrations/*.sql` 均 0 命中）。
> 按文档分层铁律：**转述不能作实现依据**，且「找不到原文 ≠ 原文不存在 ≠ 可以按转述做」。
> → 所以我把 Q4 提为一个**独立产品问题**，请白哥判断，而不是「照 v2 抄」。

### Q5 · `user_word.source_sentence` 的写入时机

记忆里明确：
> 「❌ 不用「最后一次查词语境」覆盖例句 → ✅ **取首次**（`MIN(looked_up_at)`）」

落地方式三选一：

| 选项 | 做法 | 评价 |
|---|---|---|
| **A** | 写 `user_word` 时 `INSERT OR IGNORE` + 仅首次填 `source_sentence` | 简单，但**同一信息存两份**（`user_word.source_sentence` 与 `lookup_event.sentence`）→ 有漂移风险 |
| **B** | `user_word` **不存** sentence；渲染时从 `lookup_event` 取 `MIN(looked_up_at)` 那条 | 单一出处；但**偏离 v1**（v1 该字段存在） |
| **C** | 照 v1 存，且加断言「`user_word.source_sentence` == `lookup_event` 里该词**最早**那条的 `sentence`」 | 保 v1 + 用断言防漂移 |

> 我倾向 **C**（既守 v1，又用断言消除漂移风险）。

---

## 六、写入时机（v1 §八 / §九 是权威）

v1 两处**独立印证**「查词即自动写入，零额外操作」：

```mermaid
U->>C: 画线查词
C->>C: 查 word.db → 命中卡片
C->>L: INSERT user_word + card_review_state   ← 就是这一步
C-->>U: 显示卡片
```
```
1. 用户画线
2. 查本地 word 表
   ├── 命中 → 取 card → 显示
   │          → 写入 user_word + card_review_state
```

🔑 **所以不需要「＋加入生词本」按钮** —— 这与记忆里
「**生词产生路径只有一条：用户查词**」完全一致。

⚠️ **但有一处必须留意**：`reader_screen` 的查词是 `_lookupDebounce`（**300ms 防抖**）后触发。
防抖已保证「手指移动不会连打十几次」→ 但**写入仍应幂等**（`INSERT OR IGNORE`），
因为「同一个词在不同句子被查两次」是正常的（应该是新的 `lookup_event`，但 `user_word` 不重复）。

---

## 七、验收断言方案

| # | 断言 | 为什么 |
|---|---|---|
| 1 | `user_word.word_id` 为 **TEXT** 且 `UNIQUE` | 防有人改回 INTEGER / 去掉唯一约束 |
| 2 | 两表**无 `datetime('now')`**（须为 `strftime(...'Z')`） | 现库硬约束：漏 `Z` 会静默错时区 |
| 3 | `pending_push` 有 `NOT NULL` + `CHECK` | 与同库其它表同规格 |
| 4 | **DDL 里不得出现任何 `PRAGMA`** | 已踩过（Android 上 `journal_mode` 会炸） |
| 5 | 🔴 **`onUpgrade` 不是无条件抛错**（若采方案 A） | 否则已装设备永远拿不到新表 |
| 6 | 🔴 **模拟「已有 v1 库」的迁移测试** | **本次最关键的断言** —— 验收脚本必须覆盖「老库升级」而不只是「新库创建」 |
| 7 | `user_word` 用**软删**（存在 `deleted` 且无 `DELETE FROM user_word`） | v1 明确；与 `bookmark` 的硬删语义相反 |
| 8 | 200 上限的计数条件含 `WHERE deleted = 0` | 防「删了还是占额度」 |
| 9 | `source_sentence` 与 `lookup_event` 最早一条一致（若采 Q5-C） | 防两处漂移 |
| 10 | 查词链路**不阻塞渲染** | 产品原则：内容渲染不得被登录态/写入阻塞 |

> 🔑 **第 6 条是本次的「断言范围」教训的延续**：
> 现有验收全部在**新建的临时库**上跑 → **天然覆盖不到迁移路径**。
> 必须**显式造一个「v1 老库」**（先按旧 schema 建库、写入数据、再跑升级）。

---

## 八、实施计划（定案后 · 尚未开始）

### 步骤 1 · schema 加两张表（无 UI，零风险）
- `user_db_schema.sql` 增 `user_word` + `lookup_event` + 4 个索引（§三）
- 三处适配现库规范（§3.1）：`strftime(...'Z')` · `word_id TEXT` · 补 `NOT NULL`/`CHECK`
- **验收**：`verify_bookmark` 那套（FFI + 临时库）应全过 —— ⚠️ 但这**只证明新库能建**

### 步骤 2 · 🔴 迁移机制（本次的技术核心）
- `kUserDbVersion` **1 → 2**
- `onUpgrade`：从「无条件抛 `StateError`」→ **重跑全量幂等 schema**
  ```dart
  onUpgrade: (db, old, now) async {
    // 本库 DDL 全为 `CREATE TABLE IF NOT EXISTS` → 重跑 = 补齐缺的表，已有的不动。
    // ⚠️ 这只覆盖「新增表/新增索引」。将来若需「改已有表的列」
    //    （ALTER TABLE / NOT NULL 加列），必须在下面按版本号写专门分支 ——
    //    `IF NOT EXISTS` 对已存在的表是空操作，替代不了列变更。
    await executeSqlScript(db, schemaSql);
  },
  ```
- 🔑 **同时修正那两条已过时的注释**（`user_db.dart:33` 与 schema 末尾的「本库尚无用户」）——
  它们的前提**已不成立**（真机验过收藏 → 库已存在），留着会误导下一个读的人

### 步骤 3 · ★★ 补「老库升级」验收（**本次最关键**）
- 新增验证：**先按「v1 schema（无两新表）」建库 + 写入模拟数据（几条 bookmark）**
  → 然后用**当前 schema + version 2** 打开 → 断言：
  1. `user_word` / `lookup_event` **已存在**
  2. **旧数据完好**（bookmark 条数不变）
  3. `user_version == 2`
- 🔑 **为什么必须有**：现有全部验收都跑在**新建临时库**上 → **天然覆盖不到升级路径**（§2.2）
- **证伪**：把 `kUserDbVersion` 改回 1 → 该验收**必须变红**

### 步骤 4 · `UserWordRepository`（纯 Dart）
- 复用 `bookmark_repository` 的：`parseUserDbUtc` · 幂等 add · `pending_push` 模式 · 值类型
- **不复用**的（§四 第 6/7 条）：
  · **软删**（v1 `deleted` 字段），而 bookmark 是硬删
  · **不用内存 Set**（生词本要 COUNT + 列表 + 排序）
- 关键方法：`add(wordId, {sentence, articleId})` · `remove(wordId)`（**软删**）· `count()`（`WHERE deleted = 0`）· `list()` · 幂等 + **复活**语义（Q3-A）
- 断言按 §七（10 条）

### 步骤 5 · 接查词链路
- `reader_screen._lookupWord`（300ms 防抖后）→ 命中则：
  `userWordRepo.add(...)` + `ReviewListQuery.upsertState(...)`（**已有方法，首次调用**）
- 未命中 → 只写 `lookup_event`（Q2 定案）
- ⚠️ **写入不得阻塞渲染** —— 浮层先弹，写入异步；失败只记日志（不能因写库失败而看不到释义）

### 步骤 6 · 200 上限判定
- `count() >= 200` 且是新词 → **仍弹浮层**，跳过写入 + 轻提示（Q1-A）
- 与「**除生词表上限外不验证登录态**」的产品原则一致

### 步骤 7 · 真机验证（**重点验脚本验不到的**）
- 🔑 **老库能否升级出两张新表** —— 这正是步骤 3 用脚本模拟、但真机要再确认一次的那条
- 查词 → 杀进程重开 → 生词还在（验落盘）
- 第 201 个词的提示
- 删除后再查 → 复活

---

## 九、⚠️ 一处顺手发现的文档问题（未改）

`user_db.dart:6` 与 `:126` 引用的验证脚本路径是 **`scripts/bookmark_verify/`**，
但该脚本**实际在 `scripts/query_verify/bin/verify_bookmark.dart`**（目录已合并）。
→ 注释里的路径**已过时**（2 处）。属「注释与实现不符」，一处小修，等白哥一并批准。
