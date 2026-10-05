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
  added_at      TEXT NOT NULL,             -- ISO8601 UTC
  -- ─────────────────────────────────────────────────────────────────────
  -- 🆕 v2（2026-10-05 · 跨设备同步）：**内容指纹** —— 解决「同一本书在两台
  --    设备上是两本书」的问题
  -- ─────────────────────────────────────────────────────────────────────
  -- `book.id` 是**端侧生成的 uuid** ⇒ 同一本《Pride and Prejudice》在两台设备
  -- 上导入会得到**两个不同 id** ⇒ 进度对不上。
  -- ⇒ 用 **`sha256(原始文件字节)`** 作为跨设备的「同一本书」判据 +
  --    一张「待认领」表（见下方 `book_progress_pending`）承接「本地还没导入时」的进度。
  --
  -- 📄 设计依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §3.4
  --
  -- # 🔴 可空是刻意的（不是漏写 NOT NULL）
  --  · 本库**尚未上线** ⇒ 正常情况下没有「旧书」；但若将来出现「算不出哈希」的情况
  --    （如导入流程异常中断），该行为 NULL ⇒ **不参与同步**（而不是拿错误哈希去匹配）
  --  · ⚠️ SQLite 也**不允许** `ADD COLUMN ... NOT NULL` 不带默认值 ⇒ 迁移侧必须可空
  --    （或给一个哨兵默认值 —— 那更糟，会让「算不出」伪装成「有一个哈希」）
  --
  -- # 🔴 这个指纹的边界（**不假装更强**）
  --
  -- | 情形 | 哈希 | 结果 |
  -- |---|---|---|
  -- | 同一文件拷到两台设备 | 相同 | ✅ 进度共享 |
  -- | **同一本公版书、从不同来源下载** | 🔴 **不同**（元数据/排版有差异）| ❌ 进度不共享 |
  --
  -- 🔑 后者是**刻意接受**的：不同来源的同一本书**章节划分可能完全不同** ⇒
  --    硬把进度「共享」过去会**把用户带到错误的位置** —— **比不同步更糟**。
  --    ⇒ 将来若要做跨来源识别，需要「书名+作者+章节数」等**弱指纹**，
  --      但那会引入**错配风险**，必须配套「用户确认」交互 ⇒ **一期不做**。
  --    ⚠️ 实施时**不要**顺手把它加强成「模糊匹配」。
  --
  -- ⚠️ **算哈希必须放 Isolate**（50 MB 约 100–200 ms）—— 导入流程本就在 Isolate 里。
  -- ⚠️ 同样写在**末尾**：`ALTER TABLE ADD COLUMN` 只能追加到末尾，保持一致。
  content_hash  TEXT
);

-- 按指纹找书（跨设备认领进度时用：`WHERE content_hash = ?`）
CREATE INDEX IF NOT EXISTS idx_book_hash ON book(content_hash);

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

-- ── 🆕 v2（2026-10-05 · 跨设备同步）：**待认领**的远端进度 ────────────────
--
-- # 🔴 为什么必须有这张表（不是过度设计）
--
-- `book_progress` 有 `FK → book(id) ON DELETE CASCADE`。
-- 同步拉取时，远端的 `book_id` 是**另一台设备的 uuid** —— 本地**没导入这本书**
-- ⇒ 直接写 `book_progress` 会 **FK 失败**（插不进去）。
--
-- **若因此丢弃远端进度**（更简单的做法）⇒ 用户的真实流程是
-- 「新设备 → **导入书** → 打开」，而同步往往**早于**导入
-- ⇒ 进度**永久丢失** ⇒ 这个功能等于没做。
--
-- ⇒ 用本表按**指纹**（`book.content_hash`，不是 `book_id`）先接住，
--    等用户在新设备导入同一本书后「**认领**」。
--
-- # 认领流程
--
-- ```
-- ① 同步拉取 → 写进本表（**不需要**本地已有这本书）
-- ② 用户导入同一本书 → 算出 content_hash → 命中本表
--    ⇒ 写入 book_progress（此时 FK 满足）→ 删掉本表的行
-- ③ 本地读书 → 更新 book_progress + 一并更新本表（便于上传）
-- ```
CREATE TABLE IF NOT EXISTS book_progress_pending (
  content_hash TEXT PRIMARY KEY,           -- 按**指纹**存，而不是 book_id（见上）
  chapter_idx  INTEGER NOT NULL,
  scroll_ratio REAL    NOT NULL,
  updated_at   TEXT    NOT NULL
);
