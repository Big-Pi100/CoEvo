# 正文排版「权威值」对照表（2026-10-23）

> 白哥：「这个代码就在那摆着，**权威在哪**，你一点都不知道怎么做吗？」
>
> **权威 = 代码 + token 文件**，不是我的印象，也不是截图的像素。
> 下表每一行都标了**出处**，改 spike 时逐行抄，不再重新「设计」一遍。

---

## 一、正文排版（`book_reader_screen.dart` 正文渲染）

| 项 | 权威值 | 出处 |
|---|---|---|
| 正文字号 | **17**（范围 15–24，可被用户改）| `reading_settings.dart:30` `kReadingFontSizeDefault = 17` |
| 行高 | **1.75**（硬编码，不随字号）| `book_reader_screen.dart:509` `height: 1.75` |
| 正文水平边距 | **24** | `co_spacing.dart:26` `xxl = 24` |
| 正文垂直边距（上）| **0** | `book_reader_screen.dart:456` `fromLTRB(xxl, 0, xxl, xxl)` |
| 正文底部留白 | **24** | 同上 |
| 段落间距 | **无 margin** —— 靠 `\n\n`（一个空行 ≈ 一行高）| `_bodySpans`（539–575）只切划线，**不给段落加样式** |
| 对齐方式 | **左对齐**（`Text` 默认，不设 `textAlign`）| `book_reader_screen.dart:503` `Text.rich(...)` |
| 自动断词 | **无**（Flutter 不做 hyphenation）| 同上 |
| 章节标题字号 | **正文 + 2** | `book_reader_screen.dart:465` `fontSize: _bodyFontSize + 2` |
| 章节标题字重 | **w600** | 同上 `fontWeight: FontWeight.w600` |
| 章节标题行高 | **1.4** | 同上 `height: 1.4` |
| 章节标题下间距 | **一行高**（`SizedBox(height: CoSpacing.lg)`）| `book_reader_screen.dart:473` |
| 划线（下划线）色 | **`accentBright`**（亮调，不是 `accent`）| `_bodySpans` 注释：「细线与描边用亮调」 |
| 划线粗细 | **1.2** | `_bodySpans` `decorationThickness: 1.2` |

## 二、三档主题色（`coevo_tokens.dart`）

| 档 | `read`（正文底）| `ink`（文字）| `accent` | `accentBright` |
|---|---|---|---|---|
| 墨 | `#FAF8F4` | `#24211C` | `#B4432C` | `#C4533A` |
| 格 | `#FFFFFF` | `#0A0A0A` | `#B4432C` | `#C4533A` |
| 夜 | `#14161C` | `#EDEBE6` | `#DB7E6B` | `#E89B8C` |

⚠️ 注意用 **`read`** 而不是 `page`：
- `page`（墨 `#F1EDE4`）是**页面底**（卡片外面的底）
- `read`（墨 `#FAF8F4`）是**阅读区底** —— 正文画在它上面

## 三、我错在哪（逐条）

| # | 我写的 | 权威值 | 为什么错 |
|---|---|---|---|
| 1 | 墨底 `#F5F0E8` | `#FAF8F4` | **编的**，没查 token |
| 2 | 墨字 `#3A332C` | `#24211C` | 同上 |
| 3 | 格/夜 各两色 | 见上表 | 同上（三档六个色全是编的）|
| 4 | `text-align: justify` | 左对齐 | 正式页没有 justify |
| 5 | `-webkit-hyphens: auto` | 无断词 | Flutter 不做 |
| 6 | 段落 `margin: fs*0.8`（13.6px）| 一个行高（29.75px）| 正式页靠 `\n\n`，约两倍行高 |
| 7 | 边距 20 | 24 | 没查 `CoSpacing` |
| 8 | 链接色没设（浏览器蓝）| 朱砂 + 下划线 | 漏了 `<a>` 样式 |
| 9 | 划线色用 `accent` | `accentBright` | 漏了「细线用亮调」这条规定 |

📌 **教训**：**排版参数天然有唯一权威（代码），却去凭印象写** —— 这是最容易避免、也最伤观感的一类错。
「先读代码再动手」在新写一个渲染层时**尤其**适用：不是复用它，而是**复现它的数值**。
