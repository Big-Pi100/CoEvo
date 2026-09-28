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
CREATE TABLE IF NOT EXISTS user_word (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  -- 🔴 指向**词库**的 `word.id`（TEXT）。⚠️ 词库外的词没有 word_id
  --    → 现阶段**不会**写入本表（见文件末「不在本次范围」）
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
-- 说明（不在本次范围）
-- ─────────────────────────────────────────────────────────────
-- · **词库外生词**（`external_word_cache` + LLM 制卡）—— 属 **Phase 3**。
--   v1 §3.2 有定义，但**本次不建**：它需要联网 + 后端接口（当前无实现）。
--   🔴 **且有一条结构性障碍待解**（2026-09-25 评审已记录）：
--     `user_word.word_id` 是 `NOT NULL` 且指向词库，而**词库外的词没有 word_id**
--     → 「词库外生词」进不了生词本、也进不了复习队列。
--     评审建议：复用现网 `user_cards` 模式（有 `prebuilt_card_id` FK + 域子表）。
--   📄 方案见 `docs/review/step3-4c-word-writeback-plan-2026-09-28.md` §六
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

