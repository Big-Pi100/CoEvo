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

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

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
-- 说明（不在本次范围）
-- ─────────────────────────────────────────────────────────────
-- · 生词本（user_word）与查词记录（lookup_event）—— v1 §3.2 另有定义，待后续迁移一并落库
-- · 词条内容（拼写/释义/词根等）来自只读预制库 `word.db`，**不在本库**
--   （唯一例外：`card_review_state.spelling` 冗余，见该表注释）
-- · 本库不含 FSRS 参数（21 个权重）—— 端侧用包内默认值；将来做个性化优化时再加 params 表
--
-- ─────────────────────────────────────────────────────────────
-- 变更记录
-- ─────────────────────────────────────────────────────────────
-- v1 (2026-09-26)  初版
-- v1.1 (2026-09-26) 白哥定「跨库方案 = 冗余 spelling」：
--   · `card_review_state` 新增 `spelling TEXT NOT NULL COLLATE NOCASE`
--   · 新增索引 `idx_crs_spelling`
--   · `review_log` **不加** —— 重放只需 word_id（状态由重放产出），
--     事件历史不作为列表展示来源 → 避免无谓反范式
--
-- ⚠️ **升级注意**：本库尚无用户（`user.db` 未在任何端创建），故无需迁移脚本。
--    若将来 schema 变更且已有数据，`NOT NULL` 加列**必须给默认值或做回填**，
--    否则 `ALTER TABLE ADD COLUMN` 会失败（SQLite 的已知限制）。
