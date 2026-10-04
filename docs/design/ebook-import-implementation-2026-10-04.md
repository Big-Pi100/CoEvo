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
| 3 | **书库入口位置** | 🔄 **已改（2026-10-04 · 白哥定）**：<br>原建议 = 「我的」页加一行「我的书库」<br>**现定 = 信息流页「今日精选」标题栏下方一行「我的书库 ›」**，点击进书库页；**导入按钮在书库页右上角** → 见 §9.7 |

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

---

## 十、第二批实施记录（2026-10-04 · 落库 + 书库/阅读页 + 入口）

> 触发：白哥真机试完后问「**我没看到导入入口？还没设计吗？**」
> ⇒ 澄清：设计早已完成（本文档 + `ebook-import-assessment`），**解析层也做完了**，
>   缺的是 **UI 那批** —— 当时按我建议的顺序（C 看订阅页 → A 云端同步）排在后面。
> 白哥随即定：**先做电子书 UI**。

### 10.1 🔄 一处**设计变更**：入口位置（必须记录，不能只改不记）

| | 原设计（§六 #3） | **现定**（白哥 2026-10-04） |
|---|---|---|
| 位置 | 「我的」页加一行 | **信息流页「今日精选」标题栏下方一行** |
| 理由 | 「书库属内容管理，与『我的资产』同族」 | —— |
| 导入按钮 | 未指定 | **书库页右上角** |

🔑 **变更后的理由（白哥的判断，也更有道理）**：
信息流页是**主界面**，入口在那里**曝光高**；而「我的」页是**设置/资产**语境，
用户不会去那里找「看书的地方」。

⚠️ **实现时必须回答一个反对意见**（否则会撞上自己定的判据）：
`home_screen.dart` 里留着一句
「🔴 2026-10-03：兴趣筛选栏曾放这里，白哥真机反馈『阅读界面太拥挤』⇒ 已移回『我的』页
　🔑 判据：**信息流页的垂直空间是稀缺资源，留给内容** ⚠️ 别再放回来」。

✅ **它不适用于本入口** —— 两者的**性质不同**：

| | 兴趣筛选（已移走） | 我的书库（新入口） |
|---|---|---|
| 性质 | **前置控制**（筛选信息流本身） | **内容导航**（去读另一类内容） |
| 频率 | 低频（设一次长期不动） | 中频（想读书时就用） |
| 判定 | ❌ 为「设置」占行，不划算 | ✅ **它本身就是内容入口** |

🔑 并且：白哥的真问题是「**没看到导入入口**」⇒ 入口的首要指标是**被发现**
⇒ 做成**淡色底的条**（不是纯文字行，也不是卡片），占一行是**有意的代价**。

### 10.2 本批新增/改动

| 文件 | 内容 |
|---|---|
| `services/ebook/book_import_plan.dart` 🆕 | **零 import 纯 Dart**：`fileExtension` / `pickFormat`（**魔数 > 扩展名**）/ `buildImportPlan`（id 与时间戳**注入** ⇒ 可确定性断言）|
| `services/ebook/book_import_messages.dart` 🆕 | 失败文案映射（穷尽 `switch` + **每类文案不同**）|
| `services/book_importer.dart` 🆕 | 解析（**走 Isolate**）→ 事务落库；**不 import Flutter**（id 由调用方注入）|
| `providers/book_provider.dart` 🆕 | `book.db` 共享连接（**唯一所有者**）+ 书库列表（LEFT JOIN 进度）+ 修订号 |
| `screens/book_library_screen.dart` 🆕 | 书库页：空态 / 列表 / 滑动删除（二次确认）/ **右上角导入** |
| `screens/book_reader_screen.dart` 🆕 | 阅读页：按章取、上下章、进度、整章朗读（**免费**）|
| `widgets/book_library_entry.dart` 🆕 | 信息流页入口（**纯 UI，不查库** ⇒ 不阻塞信息流渲染）|
| `home_screen.dart` | 插入入口（含上面那段「与兴趣筛选不同」的论证）|
| `app.dart` | 注册 `/books` · `/books/:id` |
| `pubspec.yaml` | `uuid: ^3.0.7`（lock 里已有，**零下载**）· `file_selector: ^1.0.0` |
| `ci.yml` | `ebook-verify` job 加 2 个 step（落库计划 34 项 · SQL 一致性 9 项）|

### 10.3 🔴 三条**关键设计决策**（都有代价，都记下来）

**① 落库拆成「计划 + 执行」两层** —— 让**大头可验证**

| 层 | 内容 | 可本机验证 |
|---|---|---|
| `book_import_plan.dart` | `BookDraft` → 各表行数据（**纯函数**）| ✅ 34 项断言 · 进 CI |
| `book_importer.dart` | 真正写库 | ❌ 靠源级断言 + 真机 |

🔑 判据（`verifiable-core-logic`）：**把可验证的核心抽成零依赖**。
落库正确性的**大头是映射逻辑**（字段对错 / 章节断号 / 计数不一致），
而「sqflite 的事务能不能提交」是**库的行为**、不是我们的 ⇒ 不该拖累前者可验证。
📌 代价：多一个文件、`id`/时间戳要走**依赖注入**（换来「结果可逐字段比对」）。

**② 补了一条编译期抓不到的守卫：SQL 列名 vs schema 源级比对**

`book_importer.dart` 的 INSERT 列名是**字符串字面量** ⇒ 拼错一个字母，
**Dart 编译器一声不吭**，只有那本书真被导入时才炸（`no such column`）。
⚠️ 符号解析（`codestatic`）也救不了字符串键 ⇒ **只有源级比对能守**。
✅ 用**集合相等**（不是包含）—— 多列 / 少列都当场红（判据：「集合相等」>「包含 + 下限」）。
✅ 已证伪：注入「列名拼错 + 少一列」⇒ 恰好 1 项变红，
   报告精确到「缺 `{source_format, chapter_count}` / 多 `{source_fromat}`」。

**③ 一期不做「重复导入」拦截**（刻意，判据见 `book_import_plan.dart` 末尾）

| 方案 | 代价 |
|---|---|
| 按内容 hash 去重 | 需引 `crypto`；且**不同来源的同一本书 hash 必然不同** ⇒ 拦不住真实情况 |
| 按「书名 + 作者」去重 | 🔴 **会误判**（同名不同译本是合法的两本书）⇒ 用户困惑「为什么导不进去」 |
| **不拦（本方案）** | 列表里可能出现两本一样的书 ⇒ 用户**滑删**即可 |

🔑 判据：**「误判」比「重复」更糟** —— 重复**可见且可自行修复**；
误判**不可见且无出口**（用户不知道被拦了、也不知道怎么绕过）。

### 10.4 🔴 本轮**没有**做划词查词（如实交代）

`reader_screen.dart`（1284 行）的划词逻辑（`SelectionArea` + 防抖 + 自绘菜单）
**内联在页面里、没有抽成组件**。要在书内也支持查词只有两条路：

| | 做法 | 问题 |
|---|---|---|
| ❌ | 复制一份 | 违反「同一件事只能有一处权威」（将来改查词要改两处）|
| ✅ | 抽成公共组件 | **那是一次重构**（涉 1284 行里最精细的一段：防抖 / 菜单自绘 / 手势与滚动的相互影响）⇒ **应单独做 + 单独验证** |

⇒ 本轮取后者但**不在这一轮做**。本页先给「阅读 + 翻章 + 进度 + 朗读」。
⏳ **下一轮**：抽 `WordLookupSelection`，两页共用（顺手统一两处菜单行为）。
⚠️ 在补上之前，阅读页**不宣称**支持查词 —— 实现里用**普通 `Text`**（不是 `SelectionArea`），
   因为「能选但选了没有查词菜单」= **有出口的假象**，比没有出口更让人困惑。

### 10.5 一轮验证结果

```
verify_txt_parser            ✅ 35 项
verify_epub_parser           ✅ 30 项
verify_book_import_plan      ✅ 34 项   ← 新增
verify_book_importer_sql     ✅  9 项   ← 新增（已证伪）
codestatic 符号解析           ✅ error 0 · warning 0（除 file_selector 本机缺包的假红）
```

🔴 **codestatic 抓到 3 类真 bug**（都是「凭印象写」的）：
① **switch 模式写成了本文件自己的类**（`BookImportFailure` 而非 `EbookParseFailure`）
  ⇒ **解析失败会掉进成功分支被静默吞掉** —— 抓到它的是 **Dart 的穷尽性检查**；
② `ConflictAlgorithm` 未 import；③ `CoFonts.serif` 不存在（真名是 `latinSerif`）。
📌 ②③ 是「凭印象写 API 名」的老毛病（同 `codestatic/README` 事故③「API 名不能靠猜」）。

### 10.6 ⏳ 仍待做

| 项 | 说明 |
|---|---|
| 🔴 **真机验证** | 导入真 EPUB/TXT、翻章、朗读、删书（**需白哥**）|
| 划词查词（§10.4） | 需先抽公共组件 |
| `open_with_handler` 接入 | 185 行代码已在但**零引用**（「用 CoEvo 打开」入口）|
| 章内滚动位置 | 一期固定 `scroll_ratio = 0`（只记「读到第几章」）|
| iCloud 备份排除 | `book.db` 在 Application Support 默认会进备份（见 `book_provider.dart` 注释）|
