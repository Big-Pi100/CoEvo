# 电子书导入（EPUB + TXT）—— 设计与实施

> **日期**：2026-10-04
> **触发**：白哥定「电子书导入还没有实现，要出设计并实现功能」
> **白哥同轮决策**：
> · ✅ **电子书本地导入 = 免费**
> · 🔴 「从我们的服务中下载在线电子书」= **不做**（NPPA + ICP 双证，个人主体不可得）
>   → 依据 `docs/review/online-ebook-subscription-compliance-2026-10-04.md`
> · ✅ 订阅权益**改卖「云端同步」**
> **上游**：`docs/design/ebook-import-assessment-2026-09-25.md`（可行性评估 · 合规实证 · 已实施 iOS「用 CoEvo 打开」）

---

## 〇、范围

| 做 | 不做 |
|---|---|
| EPUB（无 DRM）导入 + 解析 | 🔴 **在线书库 / 内容分发**（触发 NPPA）|
| TXT 导入（UTF-8 + GBK 兜底）| PDF（白哥定 EPUB+TXT）|
| 本地书库（列表 / 删除 / 进度）| 保留原书排版、图片、CSS（只要**纯文本**）|
| 阅读 + **划词查词 + 生词本 + 朗读**（复用现有能力）| 书内搜索、笔记、书签（一期不做）|
| 两个入口：App 内选文件 + iOS「用 CoEvo 打开」| Android（本次仅 iOS）|

🔑 **合规定位（必须贯彻到文案）**：**「本地文档阅读工具」**，不是「电子书平台」。
> 永远不说「我们有书」，只说「**你可以导入你自己的文件**」。
> App 描述、页内文案、截图都遵守这条（依据：既有评估 §1.4 的商店实证提炼）。

---

## 一、数据模型：新建 `book.db`（**第三个端侧库**）

### 1.1 为什么不复用 `user.db` / 规格里说的 `content_cache`

| 候选 | 问题 |
|---|---|
| 规格说的 `content_cache` | 🔴 **端侧根本没有这张表** —— 它是**后端**的 RSS 内容表（实测 `grep content_cache app/lib` = 0 命中） |
| 塞进 `user.db` | 🟠 语义混：`user.db` 是「**学习状态**」，导入的书是「**用户内容**」。且一本书正文可达 MB 级，会让学习状态库无谓膨胀 |
| 独立 `book.db` ⭐ | ✅ 语义清晰 · 删书 = 删本库的行，**碰不到任何学习数据**（安全边界好）· 与 `user_db` / `word_db` 两套既有模式一致 |

### 1.2 表结构

```sql
-- 一本书
CREATE TABLE IF NOT EXISTS book (
  id            TEXT PRIMARY KEY,   -- uuid v4（与 `external_word_cache` 的合成 id 同一族思路）
  title         TEXT NOT NULL,
  author        TEXT,
  language      TEXT,               -- EPUB 的 dc:language；TXT 按编码推测
  source_format TEXT NOT NULL,      -- 'epub' | 'txt'
  source_name   TEXT,               -- 原始文件名（展示「从哪来的」）
  chapter_count INTEGER NOT NULL DEFAULT 0,
  char_count    INTEGER NOT NULL DEFAULT 0,
  added_at      TEXT NOT NULL
);

-- 一章 = 一条（**导入时切好，阅读时按章取**）
CREATE TABLE IF NOT EXISTS book_chapter (
  id         TEXT PRIMARY KEY,
  book_id    TEXT NOT NULL,
  idx        INTEGER NOT NULL,      -- 章序，0-based（**顺序以 spine/解析结果为准**）
  title      TEXT,
  text       TEXT NOT NULL,
  char_count INTEGER NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE,
  UNIQUE (book_id, idx)
);
CREATE INDEX IF NOT EXISTS idx_book_chapter ON book_chapter(book_id, idx);

-- 阅读进度（**每本书一条**）
CREATE TABLE IF NOT EXISTS book_progress (
  book_id        TEXT PRIMARY KEY,
  chapter_idx    INTEGER NOT NULL DEFAULT 0,
  scroll_ratio   REAL    NOT NULL DEFAULT 0,   -- 章内位置（0~1），避免存绝对像素
  updated_at     TEXT NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
);
```

🔑 **三个设计要点**：

1. **`book_progress` 独立成表**（不是 `book` 的列）—— 将来做「云端同步」时，**只同步这张表**（进度是学习状态，书正文不是），表边界即同步边界。
2. **`ON DELETE CASCADE` + `PRAGMA foreign_keys=ON`**（`user_db` 的既有做法）⇒ 删书自动清章节与进度，不会留孤儿。
3. **不给生词加 `book_id`** —— 既有规格 §3.3 已定死：**生词按 lemma 唯一，与来源无关**。划词落在哪本书只影响 `lookup_event` 的语境记录。

---

## 二、解析器（纯 Dart · 本机**可验证**）

### 2.1 分层：解析层零 import，落库层碰 DB

```
lib/services/ebook/
  ├── epub_parser.dart     ← 零 import（除 dart:typed_data）+ archive
  ├── txt_parser.dart      ← 零 import（除 dart:convert）
  ├── book_text.dart       ← 共享模型（BookDraft / ChapterDraft / EbookParseError）
  └── book_importer.dart   ← 落库（碰 book.db）
```

🔑 **为什么这么分**：本机 `flutter` 不可用（231），但 **`dart run` 可用**。
⇒ 解析层抽成**零 Flutter import** 就能写**真断言**（同 `iap_plan.dart` 的既定做法）。

### 2.2 EPUB：用 `archive` 解压 + 自研 OPF/spine 解析

```
.epub（本质是 zip）
  ├── archive           ← 解压（成熟的纯 Dart 包）
  ├── xml               ← 解析 META-INF/container.xml → content.opf
  └── 自研：
        ① container.xml 找 OPF 路径
        ② OPF 取 metadata（title/author/language）+ <spine> 章节顺序
        ③ 按 spine 取各 XHTML → 正文纯文本
        ④ DRM 检测
```

🔴 **章节顺序必须以 `<spine>` 为准，不是文件名**（既有评估 §2.2 明确）。
文件名排序在真实 EPUB 里经常是错的（`ch10` 排在 `ch2` 前）。

**DRM 检测（最高频失败原因）**：
```dart
// zip 里存在 META-INF/encryption.xml ⇒ 有 DRM
```
⇒ 必须给**明确提示**：不是「导入失败」，而是「**这本书受 DRM 保护**（多数商业电子书如此），请使用无 DRM 的 EPUB」。
🔑 并且**要给出可用的来源指引**（Project Gutenberg 等公版书站）—— 这是把失败转化为留存的点。
> ✅ **2026-10-04 已核定可行**，但**有精确边界**（不是「随便给链接」）：
> ① 只链 **landing page**（`gutenberg.org/ebooks/{id}`），**不链 `/files/...`** —— ToS 明文要求 + 深链被技术阻挡（打不开）
> ② **不做书库形态**（列书 / 分类 / 搜索 / 精选）—— 否则落入《网络出版服务管理规定》第二条(三)「选择、编排、汇集」
> ③ **不镜像 / 不代理 / 不转存 / 不批量抓取**
> 📄 依据与实测 → `docs/review/public-domain-ebook-link-compliance-2026-10-04.md`

### 2.3 TXT：编码探测 + 章节正则

| 环节 | 做法 |
|---|---|
| **编码** | ① 有 BOM ⇒ 按 BOM ② 无 BOM ⇒ **先试 UTF-8 严格解码**（`utf8.decode(bytes, allowMalformed: false)` 不抛异常就是合法 UTF-8）③ 失败 ⇒ GBK |
| **GBK** | 需新依赖（`charset`）；⚠️ **本期先只做 UTF-8 + 明确提示**，见 §六 待确认 |
| **分章** | 正则识别：`第X章` / `Chapter N` / `CHAPTER N` / `^\s*\d+\s*$`（纯数字行）|
| **无章节标记** | 退化为**按固定字数切分**（如每 8,000 字符一章，尽量在段落边界断）|

### 2.4 失败路径必须先测（不写「不会发生」的兜底）

| 情况 | 期望行为 |
|---|---|
| 不是 zip（改名的文件） | 明确报「不是有效的 EPUB」 |
| zip 里没有 OPF | 明确报「EPUB 结构不完整」 |
| **有 DRM** | 🔴 专门文案（见 §2.2） |
| 空文件 / 全空白 | 拒绝并提示 |
| 超大文件（>50MB） | 拒绝并提示（见 §3.2） |
| 解析中途异常 | **不留半本书**（先解析完再落库，事务写入）|

---

## 三、性能与存储

### 3.1 解析放 Isolate

`compute()` 跑解析（大文件可能数秒）。⚠️ **入参与返回值必须是可序列化的简单类型**（不能直接传 `Book` 对象 —— isolate 传的是拷贝）。

### 3.2 上限（防 OOM）

| 项 | 阈值 | 理由 |
|---|---|---|
| 单文件大小 | **50 MB** | 超过就是异常输入（正常英文小说 <5MB） |
| 单本章节数 | 2,000 | 中文长篇小说极端情况 |
| 落库前估算 | 若解析出的总字符 > 5,000,000 ⇒ 提示确认 | |

### 3.3 阅读时按章取

**不整本载入内存**。`BookReaderScreen` 只持有当前章 + 相邻章的预取。

---

## 四、阅读界面

### 4.1 🔴 不复用 `ReaderScreen`（架构决策）

| 事实 | 影响 |
|---|---|
| `ReaderScreen({required this.articleId})` | 绑定**后端文章 id** |
| 内容来自 `articleDetailProvider(articleId)` | 走**网络** + 后端 API |
| 内含划词/生词/朗读/赞踩 | 价值高，但入口与数据源都绑死后端 |

**决策：新建 `BookReaderScreen`**，但**划词与朗读走共享组件**：

| 能力 | 复用方式 |
|---|---|
| **划词查词** | 抽 `WordLookupHandler`（或直接用现有的 lookup 层）—— ⚠️ **实施时先读 `reader_screen` 的 `_writeBackLookup` 看它依赖什么**，能抽则抽，不能抽则在 `BookReaderScreen` 里薄封装 |
| **朗读** | `SpeakButton`（既有组件，自包含） |
| **生词本写入** | `UserWordRepository`（既有，**不知道来源** ⇒ 天然可复用） |

> 📌 判据：**「复用同一组件」≠「同一套行为」** —— 抽共享件时要核对默认参数与最终请求是否一致。

### 4.2 界面

```
书库页（「我的」页入口 → /books）
├── 空态：引导导入（「导入你自己的 EPUB / TXT」+ 导入按钮）
├── 列表：封面占位（不解析封面图，一期用标题首字）· 标题 · 作者 · 进度%
└── 滑动删除（二次确认）

阅读页（/books/:id）
├── 自绘顶栏（返回 · 书名 · 章节名）—— 遵循既有的自绘顶栏规范（无 AppBar）
├── 正文（Literata 字体 · 可划词 · 段间距按 design-system-spec）
├── 底部：上一章 / 下一章 + 章节进度
└── 朗读按钮（整章朗读 —— ⚠️ 见 §六 待确认 #2）
```

---

## 五、两个入口

| 入口 | 实现 | 状态 |
|---|---|---|
| **App 内选文件** | `file_selector`（**官方 flutter.dev 包**，与本项目「优先官方包」一致）| 需新增依赖 |
| **iOS「用 CoEvo 打开」** | `open_with_handler.dart`（**185 行已写好**）| ✅ 代码在，**但零引用 ⇒ 必须接进 `app.dart`** |

### 5.1 接入点（`open_with_handler` 的设计已给出）

```dart
// app.dart 的 initState（既有 IAP 预热的同一处）
final openWith = OpenWithHandler();
await openWith.start();
openWith.files.listen((f) => /* 交给导入器 */);
```

⚠️ 该文件的设计文档已处理三个坑（见既有评估 §6.3–6.4）：
- **冷启动 vs 热启动时序**（信号 + pull，`getPendingFiles` 取出即清空 ⇒ 幂等）
- **只清理 `Inbox/` 的文件**（否则会删掉用户的原书 —— 一个真实 bug 隐患，已修）
- **并发拉取串行化**（in-flight Future 复用）

⇒ 接入时**必须保留这三条**，不要简化。

### 5.2 导入后的落点

两个入口汇到**同一个 `book_importer`**：

```
选择文件 / 系统打开  →  bytes  →  [Isolate 解析]  →  BookDraft  →  事务落库
                                                                      ↓
                                                            跳转书库 / 提示成功
```

---

## 六、待白哥确认

| # | 事项 | 我的建议 |
|---|---|---|
| 1 | **GBK（中文 TXT）本期做不做** | 需要新增 `charset` 依赖。**建议本期做**（否则中文 TXT 全失败，而中国区用户会试）。若想省依赖，可本期只支持 UTF-8 + 明确提示「请转成 UTF-8」 |
| 2 | **整章朗读**（与「云端同步」订阅权益无关，属免费能力边界） | 词卡朗读已免费；**整章朗读建议免费**（它是同一个 `flutter_tts` 能力，收费会显得抠）。⚠️ 但这与「订阅卖朗读」的旧规划冲突 —— 现在订阅已改卖**云端同步**，所以朗读可以老实免费 |
| 3 | **书库入口位置** | 「我的」页加一行「我的书库」（与「注销账号」同组，账号无关的功能单列组）。⚠️ 也可考虑放信息流页 —— 但按「语义归属」判据，书库属**内容管理**，与「我的」页的「我的资产」同族 |

---

## 七、实施计划

| # | 任务 | 可本机验证 |
|---|---|---|
| 1 | `book.db` + schema（第三套库） | ✅ `dart run` + `sqflite_common_ffi` |
| 2 | `epub_parser` / `txt_parser`（零 import） | ✅ 纯 Dart 断言 |
| 3 | `book_importer`（事务落库） | ✅ 同上 |
| 4 | 断言集 + 接 CI | ✅ |
| 5 | `file_selector` + `open_with` 接线 | ❌ 靠 CI + 真机 |
| 6 | 书库页 + 阅读页 UI | ❌ 靠 CI + 真机 |
| 7 | 划词/朗读复用接线 | ❌ 同上 |

### 7.1 依赖新增（3 个 · 均需 CI 验证）

| 包 | 用途 | 备注 |
|---|---|---|
| `archive` | EPUB 解压 | 纯 Dart · 无原生依赖 · 极成熟 |
| `file_selector` | App 内选文件 | **官方 flutter.dev**（与 `in_app_purchase` 同类）|
| `charset` | GBK 解码 | 若 §六 #1 决定做中文 TXT |

🔑 `html` / `xml` **已在 `pubspec.lock`**（传递依赖）⇒ **显式声明即可**，不触发新解析
（同 `sqflite_common` / `path` 的既定做法）。

⚠️ **本机 `flutter pub get` 不可用** ⇒ 这 3 个依赖能否解析**只能靠 CI 验证**。
若 CI 报冲突，改 pubspec 对应行重推。

---

## 八、诚实边界

- ⚠️ 本文为设计，**代码尚未实施**
- ⚠️ 解析器的**真实 EPUB/TXT 覆盖率无法本机验证**（需真机 + 真实电子书样本）
  ⇒ 实施时必须准备**样本集**（含：正常 EPUB · DRM EPUB · 无 OPF 的损坏包 · GBK TXT · 无章节标记 TXT）
- ⚠️ 「划词能力能否干净复用」**未核实** —— 实施第 7 步时先读 `reader_screen._writeBackLookup` 的依赖
- ⚠️ iOS「用 CoEvo 打开」的 Swift 侧（`AppDelegate.swift`）**本次未核实现状**，实施时先确认它还在

---

## 九、实施记录（2026-10-04 · 第一批：解析层）

### 9.1 已完成

| # | 交付物 | 验证 |
|---|---|---|
| 1 | `app/assets/sql/book_db_schema.sql` | — |
| 2 | `app/lib/services/book_db.dart`（第三套库的连接层，复用 `user_db` 的 SQL 拆分器） | — |
| 3 | `app/lib/services/ebook/book_text.dart`（模型 + 失败分类） | — |
| 4 | `app/lib/services/ebook/txt_parser.dart` | ✅ **35 项** |
| 5 | `app/lib/services/ebook/epub_parser.dart` | ✅ **30 项** |
| 6 | `scripts/ebook_verify/`（纯 Dart 验收，**本机可跑**） | ✅ 65 项全过 |
| 7 | CI job `ebook-verify` | ✅ YAML 已校验 |
| 8 | `app/pubspec.yaml` 依赖：`archive ^4.3.0` · `xml ^6.5.0` | ⏳ 靠 CI |

### 9.2 🔴 实施时发现的**两个真 bug**（都是断言抓到的）

| # | 问题 | 后果 | 修法 |
|---|---|---|---|
| 1 | `ZipDecoder` 对**非 zip 数据不抛异常**，而是返回空 `Archive` ⇒ 代码走到「缺 container.xml」⇒ 报 `brokenEpub` | 用户**选错文件**（拖了个 .txt）时被告知「EPUB 结构不完整」⇒ 以为书坏了，而不是「我选错了」 | 加 **zip magic number（`PK`）** 前置判定 ⇒ 报 `notEpub` |
| 2 | 断言样本用 `xhtml('X', '')` 造「空章」—— 但该辅助函数**总会插入 `<h1>X</h1>`**，h1 的文字就是内容 ⇒ **测不到「空章跳过」** | 断言**假绿**（看起来覆盖了空章，实际没测） | 改用真正空的 xhtml（连 `<h1>` 都没有） |

> 📌 第 1 条的教训与项目既有判据同族：**「不同失败原因必须给不同提示」** ——
> 把「用户选错文件」和「文件本身损坏」混成一句话，用户就无法自救。
> 📌 第 2 条：**样本也是实现，要与被测逻辑对齐** —— 辅助函数的「顺手加个 h1」会让样本失真。

### 9.3 依赖版本决策（一个刻意的保守选择）

`xml` 钉 **`^6.5.0`** 而不是最新的 7.x：

| 事实 | 影响 |
|---|---|
| `app/pubspec.lock` 里 `xml` 已是 **6.5.0**（`gpt_markdown` 依赖链的传递依赖） | 声明 `^7.x` 会**升级**它 |
| `xml` 7.x 依赖 `petitparser` 7.x（现为 6.0.2） | ⇒ **连带升级 petitparser** |
| `gpt_markdown`（正文 Markdown 渲染核心）依赖 petitparser | 🔴 大版本升级**可能破坏正文渲染** |

⇒ 判据：**不为「解析两个小 XML」去动渲染链的依赖树**。
本文件只用到 `descendants` / `name.local` / `getAttribute` / `innerText` —— 6.x 全都有。
✅ 已实测：钉 6.5.0（实解 **6.6.1**）下 65 项断言**全过**。

### 9.4 证伪记录（判据：门禁必须证伪过）

| 注入的回归 | 结果 |
|---|---|
| DRM 检测的返回类别改错（`drmProtected` → `unknown`） | ✅ 变红 |
| 把 `&amp;` 解码**提前**到 `&lt;` 之前（制造二次解码） | ✅ 变红 |
| | 两次均**非零退出码** |

### 9.5 ⏳ 未完成（下一批）

| # | 项 | 本机可验证 |
|---|---|---|
| 1 | `book_importer.dart`（事务落库：先解析完再写，不留半本书） | ✅ 可用 `sqflite_common_ffi` |
| 2 | 书库页 `/books` + `BookReaderScreen` | ❌ 靠 CI + 真机 |
| 3 | `file_selector` 接入（App 内选文件） | ❌ |
| 4 | `open_with_handler` 接进 `app.dart`（185 行代码已在，**零引用**） | ❌ |
| 5 | 划词/朗读在书内的复用接线 | ❌ |
| 6 | 🔴 **真机验证**（需 3~5 本真书：无 DRM 公版书） | ❌ 需白哥 |

### 9.6 ⚠️ 依赖风险提示（如实说）

`archive 4.3.0` 引入了 `posix` / `ffi` 等传递依赖。
- ✅ 我们只调 `ZipDecoder`（纯内存解压），**不碰** posix 的文件权限 API
- ⚠️ 若 CI 的 `frontend` / `ios-build` 报依赖冲突或编译失败 ⇒ 回退方案：
  **改用 `archive 3.x`**（无 posix 依赖；API 差异仅在 `encodeBytes`，见 `scripts/ebook_verify`）
