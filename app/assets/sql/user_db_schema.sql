-- CoEvo 端侧用户库 `user.db` · schema v1
--
-- 依据：docs/design/v1-final-design-authoritative-2026-09-25.md §3.2（复习状态 / 复习日志）
--       + docs/design/fsrs-client-side-migration-plan-2026-09-26.md §四（数据模型）
-- 配套：app/lib/services/fsrs_service.dart（`ReviewState.toRow()` / `ReviewEvent.toRow()` 的字段名与此一致）
--
-- 🔴 两条硬约束
--   1. **所有时间列都是 UTC ISO8601**（带 `Z`）—— fsrs 包只支持 UTC，
--      存本地时间会让重放时抛 ArgumentError。fsrs_service 已强制校验。
--   2. **`word_id` 是 TEXT**（词库 `word.id`，如 `w008732`）——
--      v1 原文写的是 `card_id INTEGER`，但现网词库主键已是 TEXT UUID 风格，故此处用 TEXT。
--
-- 说明：本文件是**权威定义**。Dart 侧 `onCreate` 使用同一份 DDL 字符串
--      （避免「文档一套、代码一套」）。表结构已用 sqlite3 实测建表通过。

-- 🔴🔴 **本文件不得包含任何 `PRAGMA` 语句**（2026-09-27 修正）
--
-- 这里**曾经**有两行：
--     PRAGMA foreign_keys = ON;
--     PRAGMA journal_mode = WAL;
-- 它们都是错的，理由各不同：
--
--   ① `PRAGMA foreign_keys = ON`
--      schema 由 `executeSqlScript` 逐条 `db.execute()` 执行，而 `onCreate` **在事务内** →
--      **空转**（事务内不生效）。已由 `user_db.dart` 的 `onConfigure` 承担。
--
--   ② `PRAGMA journal_mode = WAL` 🔴 **在 Android 上会失败**
--      `db.execute()` → `sqflite_android` → `SQLiteDatabase.execSQL()`
--                → `SQLiteStatement.executeUpdateDelete()`
--      而该方法**只接受不返回数据的语句**（INSERT / UPDATE / DELETE）。
--      但 `PRAGMA journal_mode = WAL` 按 SQLite 语义**返回新的日志模式**（有结果行）
--      → 违反前提。Android 官方 javadoc（`SQLiteDatabase.java`）明文：
--      「per-connection 的 PRAGMA 不该用 execSQL，应用 `execPerConnectionSQL`」。
--      → 现由 `user_db.dart` 的 `onConfigure` 承担，且**必须用 `db.rawQuery`**（非 `execute`）。
--
-- ⚠️ 这两行**用 `sqflite_common_ffi` 验收时看不出问题**：FFI 直调 sqlite3 C API，
--    **没有** Android `execSQL` 那层限制 → 49 项全过。
--    典型「**在错平台验证 → 错平台不报错，掩盖真平台的问题**」。
--    守护断言见 `scripts/query_verify/bin/verify_bookmark.dart`【2】。
--
-- 🔑 原则：**连接级设置不写在 DDL 里**。DDL 描述「库长什么样」，连接设置描述
--    「这次连接怎么工作」—— 前者是持久化的，后者是每次连接都要重做的。

-- ─────────────────────────────────────────────────────────────
-- 复习状态（每词一行）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS card_review_state (
  word_id         TEXT    PRIMARY KEY,              -- 词库 word.id
  -- ── 冗余字段（跨库方案 A · 2026-09-26 白哥已定）────────────────
  -- 为什么冗余：复习列表要显示「单词」并支持**按单词搜索**，而本库只有 word_id。
  --   若靠 word.db，就必须 ATTACH 跨库 JOIN（双库常开、路径管理复杂）。
  --   冗余后：列表渲染与搜索**完全不碰 word.db**。
  -- 🔑 只冗余 `spelling`，**不冗余释义** —— 释义在 `word.card.content`（~1.2 KB/词），
  --   复制 11,523 条 = ~14 MB；而 spelling 平均 ~8 字节。释义按需单个查 word.db（43 µs）。
  -- ⚠️ 一致性：`word_id` 一旦分配永久不变（v1 §3.1.1 关键约束），拼写本身也不会变
  --   → 词库升级只需**新增**词，不修改已有词的 spelling → 冗余风险极低。
  --   若将来真出现拼写订正，需一并 UPDATE 本表（见文件末「变更记录」）。
  spelling        TEXT    NOT NULL COLLATE NOCASE,
  state           INTEGER NOT NULL DEFAULT 0        -- 0 未学 / 1 learning / 2 review / 3 relearning
                  CHECK (state BETWEEN 0 AND 3),
  step            INTEGER,                          -- learning/relearning 的步；review 为 NULL
  stability       REAL,                             -- FSRS S（天）；未学为 NULL
  difficulty      REAL,                             -- FSRS D（1–10）；未学为 NULL
  reps            INTEGER NOT NULL DEFAULT 0,
  lapses          INTEGER NOT NULL DEFAULT 0,
  last_review_at  TEXT,                             -- UTC ISO8601，未学为 NULL
  next_review_at  TEXT    NOT NULL,                 -- UTC ISO8601，未学 = 创建时刻（立即到期）
  pending_push    INTEGER NOT NULL DEFAULT 1        -- 1 = 待同步
                  CHECK (pending_push IN (0, 1)),
  updated_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 默认排序（记忆曲线）就是按到期时间升序 —— 这是最热的查询
CREATE INDEX IF NOT EXISTS idx_crs_due     ON card_review_state (next_review_at);
CREATE INDEX IF NOT EXISTS idx_crs_pending ON card_review_state (pending_push)
  WHERE pending_push = 1;
-- 排序档 3「A–Z」与**搜索**都走这里
-- ⚠️ `COLLATE NOCASE` 只折叠 ASCII —— 对英文拼写足够；若将来含非 ASCII 需改 `NOCASE_unicode`
CREATE INDEX IF NOT EXISTS idx_crs_spelling ON card_review_state (spelling COLLATE NOCASE);

-- ─────────────────────────────────────────────────────────────
-- 复习日志（每复习一次一行）—— 也是**多端同步的最小单位**
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS review_log (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id      TEXT    NOT NULL,
  rating       INTEGER NOT NULL                     -- 1 忘了 / 2 困难 / 3 记得 / 4 熟练
               CHECK (rating BETWEEN 1 AND 4),
  duration_ms  INTEGER,                             -- 停留时长（可选）
  reviewed_at  TEXT    NOT NULL,                    -- UTC ISO8601
  utc_day      TEXT    NOT NULL,                    -- 'YYYY-MM-DD'（UTC 日历日）
  device_id    TEXT    NOT NULL DEFAULT '',         -- ⚠️ NOT NULL DEFAULT '' 而非 NULL：
                                                    --    NULL 在 UNIQUE 里互不相等 → 破坏下面的幂等约束
  synced       INTEGER NOT NULL DEFAULT 0
               CHECK (synced IN (0, 1)),
  -- 🔑 幂等键：同一设备在同一时刻不可能对同一词评两次
  --    多端拉取重复事件时用 `INSERT OR IGNORE`，天然幂等
  UNIQUE (word_id, reviewed_at, device_id)
);

-- 重放：按词取时间序
CREATE INDEX IF NOT EXISTS idx_log_word_replay ON review_log (word_id, reviewed_at);
-- 待上传
CREATE INDEX IF NOT EXISTS idx_log_sync        ON review_log (synced) WHERE synced = 0;
-- 「今天该复习」计数走 card_review_state，但按日统计复习量走这里
CREATE INDEX IF NOT EXISTS idx_log_day         ON review_log (utc_day);

-- ─────────────────────────────────────────────────────────────
-- 收藏（每收藏一篇文章一行）
-- ─────────────────────────────────────────────────────────────
-- 依据：`docs/design/visual-feed-bookmark-2026-09-25.html`（设计稿已给出 DDL）
--
-- 🔑 设计稿的 5 条要点（**采纳**）：
--   ① `content_id` 直接当主键 —— 收藏没有数量/顺序/分类需求，不需要额外 id 与排序字段
--   ② 时间戳 DESC 排序（「我刚存了什么」的直觉）
--   ③ 跟着已有同步机制（`pending_push` + 增量 pull/push），**不需要新接口**
--   ④ 取消收藏 = `DELETE` —— 收藏是**可再生的用户意图**，与「生词本不能硬删」不同
--   ⑤ 收藏数不单独存，`COUNT(*)` 即可（单用户量级极小）
--
-- ⚠️ **与设计稿的两处偏离**（设计稿写 `DEFAULT (datetime('now'))`）：
--   ① `datetime('now')` 返回 `YYYY-MM-DD HH:MM:SS`（**空格分隔、无 `Z`**），
--      与本库**硬约束 1**（所有时间列 UTC ISO8601 带 `Z`）不符 ——
--      也同 `card_review_state.updated_at` 的 `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` 不一致。
--      → 统一为后者。理由不只是「风格一致」：**空格分隔的时间串在 Dart 侧 `DateTime.parse`
--      会被当本地时间**（无时区标记时按本地解释），跨时区会静默错位。
--   ② 设计稿的 `pending_push INTEGER DEFAULT 1` 未声明 NOT NULL / CHECK ——
--      → 补 `NOT NULL` + `CHECK (IN (0,1))`，与 `card_review_state` 同规格。
--      （设计稿是**草图**级 DDL，本文件是**权威定义**，按本文件的规格补齐。）
CREATE TABLE IF NOT EXISTS bookmark (
  content_id    INTEGER PRIMARY KEY,                -- 一篇文章只收藏一次
  bookmarked_at TEXT    NOT NULL
                DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push  INTEGER NOT NULL DEFAULT 1
                CHECK (pending_push IN (0, 1))
);

-- 「我刚存了什么」= 按时间倒序 —— 收藏清单的唯一排序
CREATE INDEX IF NOT EXISTS idx_bm_time ON bookmark (bookmarked_at DESC);
-- 待上传（与 card_review_state 同模式，供增量 push 用）
-- ⚠️ 设计稿**没有**这个索引 —— 但它点明「跟着已有的同步机制走」，
--    而增量 push 的查询就是 `WHERE pending_push = 1`；表小也不该全表扫。
CREATE INDEX IF NOT EXISTS idx_bm_pending ON bookmark (pending_push)
  WHERE pending_push = 1;

-- ─────────────────────────────────────────────────────────────
-- 生词本（v1 §3.2 `user_word`）—— 每词一行
-- ─────────────────────────────────────────────────────────────
-- 🔴 **v1 原文 vs 本文件的差异（三处，均为「现库事实约束」，非擅自改设计）**
--   v1 §3.2 的 DDL 是**草图级**，本文件是**权威定义**，按现库规格补齐（同 `bookmark` 的处理）：
--   ① `datetime('now')` → **`strftime('%Y-%m-%dT%H:%M:%SZ','now')`**
--      现库**硬约束 1**：所有时间列 UTC ISO8601 带 `Z`。`datetime('now')` 是
--      「空格分隔、无 Z」→ Dart 侧 `DateTime.parse` **静默按本地时区解释** → 跨时区错位。
--   ② `word_id INTEGER NOT NULL` → **`TEXT NOT NULL`**
--      现网词库主键是 TEXT（如 `w008732`）。同 `card_review_state.word_id`。
--   ③ `pending_push INTEGER DEFAULT 1` → **补 `NOT NULL` + `CHECK (IN (0,1))`**
--      与 `card_review_state` / `bookmark` 同规格。
--
-- 🔑 **`user_word` 用「软删除」（`deleted`），与 `bookmark` 的「硬删除」相反**
--   理由：**生词携带学习数据**（复习状态、查词语境）→ 误删的代价不可逆；
--   而收藏是「可再生」的用户意图（`VISUAL-FEED-BOOKMARK` §四 ④ 已定硬删）。
--   → `deleted = 1` 表示「用户先不学这个词了」，**数据仍在**，再次查词时**复活**（1→0）
--     （白哥 2026-09-28 定：Q3-A「复活」）。
--
-- 🔑 **200 词上限 = `COUNT(*) WHERE deleted = 0`** —— 已软删的**不占额度**
--   （与「200 词上限 = 唯一 lemma 数」一致：删掉的词不再是生词）。
--
-- 🔴 **`deleted = 1` 对各统计的影响**不一致** —— 这是**有意的（白哥 2026-09-29 定）
--   | 统计项 | 过滤暂停？ | 理由 |
--   |---|---|---|
--   | 生词本词数 / 200 上限 | ✅ 过滤 | 暂停 = 它不在生词本里了 |
--   | 复习页列表 / 「今天该看」 | ✅ 过滤 | 暂停的词不该催着复习 |
--   | **「已掌握」**（`stability >= 21`） | ❌ **不过滤** | **掌握是「历史成就」—— 暂停 ≠ 忘记** |
--   同族先例：「连续学习天数」也不会因为今天没学就清零（它记的同样是**曾经达成**）。
--
--   ⚠️ 后果（**已知且接受**）：暂停一个已掌握的词后，生词本 −1 而「已掌握」不变
--     → 两个数字**可以对不上**（极端情况：「已掌握 50」而复习页只剩 5 个词可见）。
--   🔴 **别顺手给「已掌握」补 `AND deleted = 0`** —— 那会**静默改变**用户看到的语义
--     （数字随暂停掉、且不报错）。守护断言见
--     `scripts/query_verify/bin/verify_achievement_service.dart`【3】。
--     📄 判据展开：`app/lib/services/achievement_rules.dart` 文件头 ④
CREATE TABLE IF NOT EXISTS user_word (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  -- 🔴 指向词库的 `word.id`（TEXT），——**或**词库外词的**合成 id** `ext:<拼写>`。
  --
  -- 🆕 **2026-10-01（A2）：词库外的词现在能进本表了**。此前这里是
  --    「词库外的词没有 word_id → 写不进来」，那是**路径 A 落地前**的状态。
  --    现在写法见 `app/lib/services/external_word_id.dart`：
  --      · 词库内的词 → `w0xxxxx`（真 id）
  --      · **词库外的词** → **`ext:brainstorm`**（合成 —— 前缀自带语义、一眼可辨）
  --    🔑 `ext:` 的价值：让「词库外的词」先**占住一个唯一 key**，
  --      于是 200 上限口径、复习队列、JOIN 全部照常工作，**无需改任何表结构**。
  --    🔑 且它**天然是回流的钩子**：词被回流进 `word.db` 后，发版时把
  --      `ext:brainstorm` 收敛成 `w011524` 即可（见清单 §二）。
  --    ⚠️ 它**不再**是「永远是 `w…` 形状」——任何**按 id 形态做判断**的代码
  --      都必须先看前缀（`kExternalWordIdPrefix`），不要假设 `startsWith('w')`。
  word_id           TEXT    NOT NULL,
  -- ── 冗余字段（跨库方案 A · 与 `card_review_state.spelling` 同一理由）──
  -- 生词本列表要显示单词并支持**按词搜索**，而本库只有 word_id。
  -- 🔑 只冗余 `spelling`（~8 字节），**不冗余释义**（~1.2 KB/词 · 11,523 条 = ~14 MB）
  -- ⚠️ `word_id` 一旦分配永久不变，拼写本身也不会变 → 冗余风险极低
  spelling          TEXT    NOT NULL COLLATE NOCASE,
  source_article_id INTEGER,                        -- 首次查出它的文章（可空）
  -- 🔑 **取首次语境，不用最后一次覆盖**（记忆里的明确决策）
  --    `lookup_event` 是完整记录；本列是**首次**那条的快照
  --    → 断言锁「与 `lookup_event` 里该词最早一条的 sentence 一致」（防两处漂移）
  source_sentence   TEXT,
  added_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  -- 🔑 **软删**（见上）：1 = 用户已移出生词本，但学习数据保留
  deleted           INTEGER NOT NULL DEFAULT 0
                    CHECK (deleted IN (0, 1)),
  pending_push      INTEGER NOT NULL DEFAULT 1
                    CHECK (pending_push IN (0, 1)),
  -- 🔑 **按 lemma 唯一** → 同一词无论从哪篇文章、被查几次，都只有一行
  --    「落地列名是 `spelling`」—— 概念上叫 lemma，`word.db` 里没有 `lemma` 列
  UNIQUE (word_id)
);

-- 生词本列表：按加入时间倒序（同 `idx_bm_time`）
CREATE INDEX IF NOT EXISTS idx_uw_time ON user_word (added_at DESC);
-- 200 上限的计数与列表都只关心未删的
CREATE INDEX IF NOT EXISTS idx_uw_alive ON user_word (deleted) WHERE deleted = 0;
-- 待上传（同 `card_review_state` / `bookmark` 模式）
CREATE INDEX IF NOT EXISTS idx_uw_pending ON user_word (pending_push)
  WHERE pending_push = 1;

-- ─────────────────────────────────────────────────────────────
-- 查词记录（v1 §3.2 `lookup_event`）—— 每查一次一行
-- ─────────────────────────────────────────────────────────────
-- 🔑 **这是「语境记录」，不是「生词」** —— 一个词可有多条（在不同句子被查）
--    · 生词本按 `word_id` 唯一（一词一行）；本表**有意不去重**
--    · 用途：① 「你读到的那句」② 回填 `user_word.source_sentence`（取首次）
--
-- 🔴 **`word_id` 可空**（v1 原文即无 `NOT NULL`）→ **这个设计本身有含义**：
--    「**查了但词库里没有**」也要留痕 → 白哥 2026-09-28 定：**未命中也要记**
--    （Q2：「都记」）→ 所以命中写 word_id、未命中留 NULL。
--
-- 🔴 **无 `pending_push`**（照 v1）—— 它是**纯日志**，不是用户意图，
--    不参与同步（与 `review_log` 有 `synced` 列不同：那个要重放，这个只用于展示）。
CREATE TABLE IF NOT EXISTS lookup_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id      TEXT,                                -- 🔴 可空：未命中时留 NULL
  spelling     TEXT    NOT NULL COLLATE NOCASE,     -- 用户实际查的词（未命中时也有）
  article_id   INTEGER,                             -- 哪篇文章（可空）
  sentence     TEXT,                                -- 当时那句（可空）
  position     INTEGER,                             -- 句内位置（可空）
  looked_up_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 取某词的**首次语境**（`MIN(looked_up_at)`）→ 回填 `user_word.source_sentence`
CREATE INDEX IF NOT EXISTS idx_le_word ON lookup_event (word_id, looked_up_at);
-- 按时间倒查「最近查了什么」（将来的「查词历史」用）
CREATE INDEX IF NOT EXISTS idx_le_time ON lookup_event (looked_up_at DESC);

-- ─────────────────────────────────────────────────────────────
-- 成就解锁记录（v1.4 · Step 3.8 成就体系端侧化）
-- ─────────────────────────────────────────────────────────────
-- 依据：`docs/design/achievement-redesign-2026-09-29.md`（成就改为**端侧计算**）
--       + `achievement_rules.dart`（成就清单与判定纯函数 · 唯一真理源）
--
-- # 🔴 为什么必须有这张表（不能「纯计算」）
-- 「当前满足哪些成就」可以纯算出来，但**算不出**这两件事：
--   ① **解锁时间** —— 成就的意义之一就是「我什么时候拿到的」
--   ② **「新解锁」** —— 「上次检查时还没有、现在有了」需要**历史状态**做差
--      → 没有它**无法弹解锁通知**，成就就退化成「统计数字」，失去激励作用
--
-- 🔑 表极小（一行 ≈ 40 字节 · 20 个成就全解锁 ≈ 1 KB）——
--    这不是「为未知需求建表」，是**已定需求的最小持久化**。
--
-- # ⚠️ 本表**不参与多端同步**（有意如此 · 第一版）
-- 若加 `pending_push` 走既有同步机制，就要处理「两台设备各自解锁」的**合并语义**
-- （unlocked_at 取谁的？A 端解锁 B 端没解锁怎么办？）
-- → 第一版**只本地记录**：换设备后成就会重算（**靠指标能重新算出来**，
--   只是 `unlocked_at` 会变成新设备的首次检查时刻）。
-- 🔑 这是**有意的取舍**：成就内容不丢（指标在端侧库里），丢的只是「首次解锁时间」。
--    将来若要同步，加 `pending_push` 列 + 合并规则即可（同 `bookmark` 的模式）。
--
-- # 🔑 与 `achievement_rules.dart` 的关系
-- 本表的 `key` **必须**是 `kAchievements` 里的 `key`（它也是**主键**）。
-- 🔴 因此成就 key **一旦发布不可改** —— 改了 = 用户既有解锁记录对不上
--    （旧 key 永远留在表里，新 key 永远算不解锁）。
CREATE TABLE IF NOT EXISTS achievement_unlock (
  key         TEXT PRIMARY KEY,                     -- 成就 key（见 achievement_rules.dart）
  unlocked_at TEXT NOT NULL                         -- UTC ISO8601（本库硬约束 1）
              DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  -- ⚠️ 无索引、无 `pending_push`：本表只有「全表读」与「按 key 插入」两种查询，
  --    主键即索引；不参与同步（见上）。
);

-- ─────────────────────────────────────────────────────────────
-- 读过的文章（v1.5 · 「我的」页统计「阅读篇数」）
-- ─────────────────────────────────────────────────────────────
-- 依据：`docs/design/profile-redesign-plan-2026-09-29.md` §七（白哥 2026-09-29 定口径**乙**）
--
-- # 🔑 为什么需要这张表（此前**完全没有数据源**）
-- 「阅读篇数」是白哥要加的统计，但实测：**6 张表里没有任何一张记录「读过哪篇文章」**
-- —— `reader_screen.dart` 只在**划词查词**时写 `lookup_event`，
--    **打开/读完文章不产生任何记录**。
-- → 这不是「加个数字」，而是**新建数据源**。
--
-- # 🔴 口径（白哥选定「乙」）：**读完的文章数**
-- | 项 | 规则 |
-- |---|---|
-- | 判定 | **滚到底**（`extentAfter <= 阈值`）**且**停留 >= 3s（见下「双条件」） |
-- | 去重 | 🔴 `article_id` **去重**（同一篇读两次算 1 篇）→ 主键天然去重 |
-- | 不选「打开过」（甲） | 点进去看一眼也算 → **数字易注水**，激励性弱 |
-- | 不选「有查词记录」（丙） | 读完不划词的不算 → **会低估** |
--
-- ## 🔑 双重条件（滚到底 + 最短停留）是**必须的**，不是保险
-- 只判「滚到底」会**误判**：**短文章一屏就到底** → 打开即「读完」。
-- → 所以再加「停留 >= 3s」，把「点开就退」排除掉。
-- ⚠️ 这条理由写在表注释里，是因为**它决定了写入时机**（见 `reader_screen` 的判据）。
--
-- # 🔑 与 `bookmark` **完全同构**（有意为之，不是巧合）
-- 两者都是「**用户对某个内容对象的意图状态**」+ 单列主键去重：
-- | | `bookmark` | `article_read` |
-- |---|---|---|
-- | 主键 | `content_id` | `article_id` |
-- | 时间 | `bookmarked_at` | `read_at` |
-- | 同步 | `pending_push` | `pending_push` |
-- → 沿用同一模式，**消费端（repository / 同步）可以照抄**。
--
-- # ⚠️ 与 `lookup_event` 的区别（为什么那个**不带** `pending_push`，这个带）
-- `lookup_event` 是**纯日志**（可丢，只用于展示「当时那句」）；
-- `article_read` 是**状态**（丢了就**无法重算** —— 换设备后篇数会归零）。
-- 🔑 对照 `achievement_unlock`：它也同步不了，但**指标能重算**（所以第一版有意不参与同步）；
--    本表**不能重算** → 保留 `pending_push` 是为将来同步留的正确形态。
--
-- # ⚠️ 当前无消费者（只加列与方法，暂无人调用）—— 如实标注
-- 后端**没有任何 sync/push/pull 接口**（2026-09-29 实测 grep 0 命中）→
-- 同步机制**尚未实现**，故 `pending_push` 现在与 `bookmark` 一样，
-- **只有 repository 的读写方法、没有调用方**。这是该库的既有形态（不是本表引入的问题）。
--
-- # ⚠️ 有意**不加**的列（记下「为什么没有」，防后人以为是遗漏）
-- · **`read_count`（读了几遍）** —— 现在没有消费者，属 YAGNI。
--   将来若要（如「重读」成就），`ALTER TABLE ADD COLUMN` 成本低
--   （⚠️ 前提是**该列有 DEFAULT** —— SQLite 的 `NOT NULL` 加列必须能给默认值/回填，
--    见 `user_db.dart` 的 `onUpgrade` 能力边界说明）。
-- · **「按时间排序」索引** —— 现在没有「阅读历史」列表这个功能，加了没有查询会用到。
CREATE TABLE IF NOT EXISTS article_read (
  article_id   INTEGER PRIMARY KEY,                 -- 一篇文章只算一次（去重即主键）
  -- 🔑 语义 = **首次读完的时刻**：幂等写入（第二次读完不覆盖，`INSERT OR IGNORE`）
  -- ⚠️ `strftime(...'Z')` 而非 `datetime('now')` ——
  --    后者是「空格分隔、无 Z」→ Dart 侧 `DateTime.parse` 会**静默按本地时区**解释
  --    （本库硬约束 1，同 `bookmark` / `user_word`）
  read_at      TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0, 1))
);

-- 待上传（与 `idx_bm_pending` 同模式，供将来的增量 push 用）
CREATE INDEX IF NOT EXISTS idx_ar_pending ON article_read (pending_push)
  WHERE pending_push = 1;

-- ─────────────────────────────────────────────────────────────
-- 词库外生词的词卡缓存（`external_word_cache`）—— 每词一行
-- ─────────────────────────────────────────────────────────────
-- 依据：L0 `v1-final-design-authoritative-2026-09-25.md` §3.2（该表原文定义）
--       + `docs/design/llm-card-online-path-2026-09-29.md` §21.3（五条已定裁决）
--       + `docs/review/a2-and-worddb-convergence-checklist-2026-10-01.md` §4.1（三处适配）
--
-- # 🔑 它解决什么
-- 用户划到**词库里没有的词**时，服务端 LLM 实时制卡 → 本表存一份本机副本。
-- 作用①：**本机重复查同一词不再走网络**（离线也能看）。
-- 作用②：**让「词库外的词」能进生词本与复习队列** ——
--   `user_word.word_id` 写合成 id `ext:<拼写>`（见 `services/external_word_id.dart`），
--   复习页取卡时 `WordQueryService.cardById` 发现 `ext:` 前缀 → 回落到本表。
--   🔴 **没有这张表，「词库外的词」就无法被复习**（在 `word.db` 里查不到）。
--
-- # 🔴🔴 本表存的是**转换后**的形状，与服务端不同（有意，别「顺手统一」）
-- | | 存什么 | 为什么 |
-- |---|---|---|
-- | 服务端 `generated_card_cache` | LLM 的**原始输出** | 那是**回流原料** —— `load_llm_results.py` 吃的就是这个形状 |
-- | **本表** | **转换后的 `card.content` 形状**（`{front, ipa, entry_type, sections:[…]}`）| 端侧渲染要的是 `sections`（`WordSection` 的访问器按它取值）|
-- 🔑 **而且形状与 `word.db.card.content` 一致** —— 这正是不该「统一」的理由：
--   词被回流后（`ext:` → `w…`），端侧只是**换了取卡来源**，**内容形状不变** ⇒
--   收敛能做到**真正无缝**（见清单 §二）。若本表存 LLM 原始形状，收敛就必须
--   在切换时重新转换一次，多一个能出错的环节。
--
-- # ⚠️ 三处对 L0 原文的适配（同 `bookmark` / `user_word` 的处理，理由各不同）
--   ① `spelling` 补 `NOT NULL` + `COLLATE NOCASE`
--      大写折叠是必须的：用户查 `Brainstorm` 与 `brainstorm` 必须命中同一行
--      （L0 原文只写 `UNIQUE`，未声明 NOT NULL / COLLATE）
--   ② `fetched_at` 用 `strftime('%Y-%m-%dT%H:%M:%SZ','now')`
--      现库**硬约束 1**：所有时间列 UTC ISO8601 带 `Z`
--      （`datetime('now')` 是「空格分隔、无 Z」→ Dart 侧会**静默按本地时区解释**）
--   ③ `pending_push` 补 `NOT NULL` + `CHECK (IN (0,1))`
--      与 `card_review_state` / `bookmark` / `user_word` 同规格
--
-- # ⚠️ `pending_push` 目前**没有消费者**（如实标注，同 `bookmark` 的既有形态）
--   服务端有它自己的**全局**缓存（跨用户复用），端侧推上去没有意义 ——
--   所以本列是「为将来的同步留的正确形态」，**不是**当前功能所需
--   （与本库 `article_read` 的处理一致）。
CREATE TABLE IF NOT EXISTS external_word_cache (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  -- 🔑 用户实际查的词（**小写归一后**；与 `ext:<spelling>` 里的拼写同源）
  spelling     TEXT    NOT NULL COLLATE NOCASE,
  -- 🔴 **转换后的 `card.content` 形状** —— 理由见上（与服务端存的**不同**，别统一）
  card_content TEXT    NOT NULL,
  fetched_at   TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0, 1)),
  -- 🔑 一词一行：同一个词被查多次只有一份缓存（`ON CONFLICT REPLACE` 覆盖）
  UNIQUE (spelling)
);

-- 待上传（与 `idx_bm_pending` / `idx_uw_pending` 同模式）
CREATE INDEX IF NOT EXISTS idx_ewc_pending ON external_word_cache (pending_push)
  WHERE pending_push = 1;

-- ─────────────────────────────────────────────────────────────
-- 说明（不在本次范围）
-- ─────────────────────────────────────────────────────────────
-- · **`article`** —— v2 已改名为 `content_cache` 并修正语义，属 Phase 3
-- · 词条内容（拼写/释义/词根等）来自只读预制库 `word.db`，**不在本库**
--   （唯一例外：`user_word.spelling` / `card_review_state.spelling` 冗余，见各自注释）
-- · 本库不含 FSRS 参数（21 个权重）—— 端侧用包内默认值
--
-- ─────────────────────────────────────────────────────────────
-- 变更记录
-- ─────────────────────────────────────────────────────────────
-- v1   (2026-09-26) 初版
-- v1.1 (2026-09-26) 白哥定「跨库方案 = 冗余 spelling」：
--   · `card_review_state` 新增 `spelling TEXT NOT NULL COLLATE NOCASE` + `idx_crs_spelling`
--   · `review_log` **不加** —— 重放只需 word_id
-- v1.2 (2026-09-27) Step 3.3：新增 `bookmark`（收藏）
--   · 表 + `idx_bm_time` + `idx_bm_pending`
--   · ⚠️ 两处偏离设计稿：时间列改 UTC ISO8601 带 `Z` · 补 NOT NULL/CHECK
-- v1.3 (2026-09-28) Step 3.4c：新增 `user_word`（生词本）+ `lookup_event`（查词记录）
--   · 4 个索引 · 🔴 `user_word` 用**软删**（与 `bookmark` 硬删相反）
--   · ⚠️ 三处偏离 v1 原文（均为现库事实约束，见该表注释）
--   · 📄 决策依据：`docs/review/step3-4c-word-writeback-plan-2026-09-28.md` §〇
-- v1.4 (2026-09-29) Step 3.8：新增 `achievement_unlock`（成就解锁记录）
--   · 成就改为**端侧计算**（后端成就引擎已退役，见 `backend-legacy-chain-retirement-2026-09-29.md`）
--   · 只加**一张表**（不参与同步）· 清单与判定见 `app/lib/services/achievement_rules.dart`
--   · 📄 决策依据：`docs/design/achievement-redesign-2026-09-29.md`
-- v1.5 (2026-09-29) 「我的」页统计：新增 `article_read`（读过的文章）
--   · 🔑 **新建数据源** —— 此前 6 张表**都没有**「读过哪篇文章」的记录
--   · 口径（白哥定「乙」）：**读完**（滚到底 **且** 停留 ≥3s）· `article_id` 去重
--   · 与 `bookmark` **完全同构**（PK 去重 + 时间列 + `pending_push`）→ 消费端可照抄
--   · ⚠️ `pending_push` 现无调用方（后端无 sync 接口）—— 与 `bookmark` 同样的既有形态
--   · 📄 决策依据：`docs/design/profile-redesign-plan-2026-09-29.md` §七
--
-- v1.6 (2026-10-01) A2：新增 `external_word_cache`（词库外生词的词卡缓存）
--   · 🔑 让「词库外的词」能进生词本 / 复习队列：`user_word.word_id` 写合成 id `ext:<拼写>`
--   · 🔴 **本表存「转换后的 `card.content` 形状」**（与服务端存的 LLM 原始格式**不同**，
--     理由见该表注释：收敛切换时要形状不变 → 真正无缝）
--   · ⚠️ `pending_push` 现无消费者（同 `bookmark` 的既有形态，如实标注）
--   · 📄 依据：`docs/review/a2-and-worddb-convergence-checklist-2026-10-01.md` §四 阶段 2
--
-- 🔴🔴 **升级注意（本次起「已有用户库」必须走迁移）**
--    v1.2 时本库尚无任何端创建，故 version 停在 1。
--    **现已不成立** —— 白哥真机验证过收藏功能 → `user.db` 已存在且 `user_version = 1`。
--    → 加了两张表后：
--      · `onCreate` **不会重跑**（不是新库）· `onUpgrade` 会触发（version 1→2）
--      · ✅ `user_db.dart` 的 `onUpgrade` 已改为**重跑全量幂等脚本**（本文件全是
--        `CREATE TABLE IF NOT EXISTS` → 已有的表不动，缺的自动补上）
--    ⚠️ **但这只覆盖「新增表/索引」**。将来若需**改已有表的列**（`ALTER TABLE` /
--      `NOT NULL` 加列），`IF NOT EXISTS` 是**空操作**，必须在 `onUpgrade` 里
--      按版本号写专门分支，且 `NOT NULL` 加列**必须给默认值或回填**（SQLite 已知限制）。
--    🆕 v1.4 同理：真机上现存的库是 **v2**（或 v1）→ 必须靠 `onUpgrade` 建出
--      `achievement_unlock`。**守护断言见 `scripts/query_verify/bin/verify_userdb_migration.dart`**

