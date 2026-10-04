-- ══════════════════════════════════════════════════════════════════════════
-- book.db —— 用户导入的电子书（EPUB / TXT）
-- ══════════════════════════════════════════════════════════════════════════
--
-- # 为什么是第三个库（不是塞进 user.db）
--
-- | 候选 | 问题 |
-- |---|---|
-- | `user.db` | 🟠 语义混：它是「**学习状态**」库；导入的书是「**用户内容**」。
-- |          且一本书正文可达 MB 级 ⇒ 会让学习状态库无谓膨胀 |
-- | 独立 `book.db` | ✅ 删书 = 删本库的行，**碰不到任何学习数据**（安全边界好）|
--
-- 🔑 判据：**「谁的数据」决定「放哪个库」** —— 与 `word.db`（词库·只读）
--    和 `user.db`（学习状态）并列的第三类：**用户导入的内容**。
--
-- # 连接级设置不写在这里
--
-- ⚠️ 与 `user_db_schema.sql` 同一条教训：schema 由 `executeSqlScript` 逐条
--    `db.execute()` 执行，而 `onCreate` **在事务内** ⇒ PRAGMA 写在这里要么空转、
--    要么直接失败（per-connection 的 PRAGMA 不能用 execSQL）。
--    ⇒ `PRAGMA foreign_keys = ON` / `journal_mode = WAL` 一律在代码的
--      `onConfigure` 里做（见 `book_db.dart`）。
--
-- # 能力的边界（如实标注）
--
-- · 本库**不存**「生词与书的关联」—— 生词按 lemma 唯一，与内容来源无关
--   （依据：`ebook-import-assessment` §3.3，白哥 2026-09-25 已定）
-- · 本库**不做全文搜索索引** —— 一期只按章取正文
-- ══════════════════════════════════════════════════════════════════════════

-- ── 一本书 ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS book (
  id            TEXT PRIMARY KEY,          -- uuid v4（端侧生成）
  title         TEXT NOT NULL,
  author        TEXT,
  language      TEXT,                      -- EPUB 的 dc:language；TXT 按编码推测
  source_format TEXT NOT NULL              -- 'epub' | 'txt'
                CHECK (source_format IN ('epub', 'txt')),
  source_name   TEXT,                      -- 原始文件名（让用户认出「哪来的」）
  chapter_count INTEGER NOT NULL DEFAULT 0,
  char_count    INTEGER NOT NULL DEFAULT 0,
  added_at      TEXT NOT NULL              -- ISO8601 UTC
);

CREATE INDEX IF NOT EXISTS idx_book_added ON book(added_at DESC);

-- ── 一章 = 一条（导入时切好，阅读时按章取）────────────────────────────────
--
-- 🔑 **不整本载入内存** —— 阅读时只取当前章（大书可达数十万字符）。
-- 🔑 顺序**以 idx 为准**，而不是解析出的文件名/标题 —— 章节顺序在导入时就定死。
CREATE TABLE IF NOT EXISTS book_chapter (
  id         TEXT PRIMARY KEY,
  book_id    TEXT NOT NULL,
  idx        INTEGER NOT NULL,             -- 章序，0-based
  title      TEXT,
  text       TEXT NOT NULL,
  char_count INTEGER NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE,
  UNIQUE (book_id, idx)
);

CREATE INDEX IF NOT EXISTS idx_book_chapter ON book_chapter(book_id, idx);

-- ── 阅读进度（每本书一条）──────────────────────────────────────────────────
--
-- 🔑 **独立成表，不是 `book` 的列** —— 理由有两条：
--   ① 将来做「云端同步」时**只同步这张表**（进度是学习状态，书正文不是）
--      ⇒ 表边界即同步边界，不必再挑字段
--   ② `book` 是「内容」，本表是「状态」—— 两者的写频次差几个量级
CREATE TABLE IF NOT EXISTS book_progress (
  book_id      TEXT PRIMARY KEY,
  chapter_idx  INTEGER NOT NULL DEFAULT 0,
  scroll_ratio REAL    NOT NULL DEFAULT 0, -- 章内相对位置 0~1（**不存绝对像素** —— 换设备/换字号后像素值无意义）
  updated_at   TEXT NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
);
