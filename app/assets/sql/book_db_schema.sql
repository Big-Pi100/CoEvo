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

-- ── 🆕 v3（2026-10-07）：**书签**（位置标记）──────────────────────────────
--
-- # 🔴 三个「看着都像标记」的东西，语义必须分清（混一个就烂）
--
-- | | 谁产生 | 几条 | 目的 | 进复习吗 |
-- |---|---|---|---|---|
-- | **进度**（`book_progress`）| 系统自动 | 一本**一条**（覆盖式）| 下次回到原处 | ❌ |
-- | **书签**（本表）| 用户点一下 | **任意多条** | **回头找**某处 | ❌ **不进队列** |
-- | **划线**（`user.db` 的 `highlight`）| 用户选一段 | 任意多条 | **记住**这段 | ✅ 进队列（默写）|
--
-- 一句话：进度 = 系统说「你读到这了」· 书签 = 你说「**这里我要回来**」·
-- 划线 = 你说「**这段我要记住**」。
-- ⇒ 前两者差在「谁说的 + 几条」，后两者差在「**要不要复习**」。
-- ⚠️ 这也是**书签不进 `highlight` 表**的原因：那张表带 `text`/`note`/`start_offset`，
--    而书签**没有选中的文字**（它是一个位置）—— 硬塞进去要造一堆空字段，
--    且会让「复习取卡」多一种要排除的行。
--
-- # 🔑 位置为什么用 `chapter_idx + scroll_ratio`（与进度**同一套**）
--
-- 不存绝对像素 —— 换设备、换字号后像素值**无意义**。
-- 同一条判据已在 `book_progress` 上用过 ⇒ 这里是**复用**，不是新发明。
--
-- # ⚠️ 不变量「同一位置不重复」由**代码**保证，不是 DB 唯一索引
--
-- `scroll_ratio` 是 REAL ⇒ 浮点相等比较不可靠（0.5 与 0.5000001 该不该算同一处？）。
-- ⇒ 用**容差**在代码里判（见 `book_marker_repository.dart`）：
--    当前位置在某条已有书签的容差内 ⇒ 视为「已在书签处」⇒ 再点就是**取消**。
--    📌 判据：**浮点比较不要交给 DB** —— `UNIQUE(chapter_idx, scroll_ratio)` 会
--       因为一个字节的差而放过「同一条书签」，用户看到两条几乎重合的记录。
--
-- # ⚠️ 同步：表结构已为它准备好，但**管线未接**（如实标注）
--
-- `deleted`（软删）与 uuid 都是为了同步准备的（并集同步下硬删会复活 ——
-- 文章收藏已踩过一次）。但**同步管线（`sync_handlers.rs` / `sync_service.dart`）
-- 尚未接入本表** —— 那是订阅权益上线时的事。
CREATE TABLE IF NOT EXISTS book_marker (
  id           TEXT PRIMARY KEY,           -- uuid v4（端侧生成 —— 同 `highlight`，多设备同步靠它去重）
  book_id      TEXT NOT NULL,
  chapter_idx  INTEGER NOT NULL,
  scroll_ratio REAL    NOT NULL,           -- 章内相对位置 0~1（**与进度同一套**）
  -- 摘录：列表里让用户「认出这是哪段」。
  -- ⚠️ **它是近似值** —— 由比例估算而来（比例是**像素**关系、文字是**字符**关系，
  --    两者不是线性），可能差几十到一百多字。设计稿已如实标注。
  excerpt      TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  -- 软删（同步用）。⚠️ 读端一律要 `deleted = 0`。
  deleted      INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
);

-- 取某本书的全部书签（按**位置**排序 —— 找地方是按顺序找，不是按「我什么时候标的」）
CREATE INDEX IF NOT EXISTS idx_book_marker ON book_marker(book_id, chapter_idx, scroll_ratio);

-- ── 🆕 v5（2026-10-10）：**待认领的远端书签** ──────────────────────────────
--
-- # 🔴 为什么需要它（与 `book_progress_pending` 同一条理由）
--
-- `book_marker` 有 `FK → book(id) ON DELETE CASCADE`。而同步拉回来的书签，
-- 其 `content_hash` 指向的书**本地可能还没导入** ⇒ 直接写 `book_marker` 会 **FK 失败**。
-- 若因此丢弃远端书签 ⇒ 用户的真实流程是「新设备 → **同步** → **导入书** → 打开」，
-- 而同步往往**早于**导入 ⇒ 书签**永久丢失**。
-- ⇒ 先按 `content_hash` 接住，等导入同一本书时**认领**（与进度同一套流程）。
--
-- # 🔑 与 `book_progress_pending` 的关键差别：**主键不同**
--
-- | | 进度 | 书签（本表）|
-- |---|---|---|
-- | 一本几条 | **一条**（覆盖式）| **多条**（用户可标多处）|
-- | 主键 | `content_hash` | 🔴 **书签 uuid（`id`）** |
-- ⇒ ⚠️ **不能照抄「content_hash 作主键」** —— 那会把同一本书的多个书签**互相覆盖**，
--    只留最后一条（且**不报错**，用户以为书签丢了）。
--
-- # 认领流程（同 `book_progress_pending`）
-- ```
-- ① pull → 写本表（**不需要**本地已有这本书）
-- ② 用户导入同一本书 → 算出 content_hash → 命中本表多行
--    ⇒ 逐行写入 book_marker（此时 FK 满足，用**远端的 id** 作主键）→ 删掉本表的行
-- ```
CREATE TABLE IF NOT EXISTS book_marker_pending (
  id           TEXT PRIMARY KEY,   -- 书签 uuid（**远端**的 id —— 认领后原样写进 `book_marker`）
  content_hash TEXT NOT NULL,      -- 书的跨设备身份（用来找「本地有没有这本书」）
  chapter_idx  INTEGER NOT NULL,
  scroll_ratio REAL NOT NULL,
  excerpt      TEXT NOT NULL,
  created_at   TEXT NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0
);

-- 认领时按指纹找（`WHERE content_hash = ?`）
CREATE INDEX IF NOT EXISTS idx_bmp_hash ON book_marker_pending(content_hash);

-- ─────────────────────────────────────────────────────────────
-- v4 (2026-10-08) 书架上云：**云端书单的本地镜像**
-- ─────────────────────────────────────────────────────────────
-- 🔑 为什么**单独一张表**，而不是给 `book` 加一列（「这本书在不在云端」）：
--    `book` 的语义是「**本地已导入**的书」（正文在 `book_chapter`）。
--    「只有云端」的书**本地没有正文** ⇒ 塞进 `book` 会污染这个语义
--    （书架点开它时正文为空 ⇒ 白屏或崩）。
--    ⇒ 本表只回答「**云端有什么**」；「本地有什么」仍由 `book` 回答；
--      书架视图 = 两者按 `content_hash` 合并。
--
-- 🔴 **它不是用户资产，是服务端书单的只读副本**（可随时重建）：
--    · **不参与 push** —— 权威在服务端 `sync_book`（含服务端算出的 `blob_size`）。
--      ⚠️ 绝不能被同步管线当成「可推送的表」，否则会把「本端看到的清单」推回服务端。
--    · 应用侧只在**成功拉取后整体替换**（见 `CloudBookRepository`）——
--      所以本表**不需要** `deleted` 软删列：消失的行直接没了。
CREATE TABLE IF NOT EXISTS cloud_book (
  content_hash  TEXT PRIMARY KEY,   -- 跨设备身份（与服务端 `sync_book` 同一个键）
  title         TEXT NOT NULL,
  author        TEXT,
  language      TEXT,
  chapter_count INTEGER NOT NULL DEFAULT 0,
  -- 云端**实际存储**的字节数。⚠️ `0` = 服务端**没有这个文件**（只有元数据），
  --   与「文件正在传」是两件事。本值由服务端算，端侧**只读**。
  blob_size     INTEGER NOT NULL DEFAULT 0,
  -- 原始文件大小（配额展示用）。与服务端 `sync_book.size_bytes` 对应。
  size_bytes    INTEGER NOT NULL DEFAULT 0,
  -- 首次上云的时间（服务端口径）—— **原样保留**，不要用本地 now 覆盖它，
  -- 否则「云端书架」的排序会随每台设备同步的时刻漂移。
  added_at      TEXT NOT NULL,
  -- 本端最后一次从服务端看到这条的记录时刻（本地时钟；仅供诊断/LRU 清理用）
  seen_at       TEXT NOT NULL
                DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 书架「云端」段按最近上云排序（与本地书架用 `added_at` 同一口径）
CREATE INDEX IF NOT EXISTS idx_cloud_book_added ON cloud_book(added_at DESC);
