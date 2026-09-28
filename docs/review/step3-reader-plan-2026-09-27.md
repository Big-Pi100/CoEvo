# Step 3.4 规划：阅读器 + 划词（**最大未知**）

> 日期：2026-09-27 13:20
> 触发：白哥「继续」→ 按铁律**先调查出报告，不上代码**
> 状态：🔴 **待批准**（未动任何一行代码）
> 上游：`step3-core-ui-plan-2026-09-27.md` §十六（3.3 已完成）

---

## 一、结论摘要

**真实范围显著大于原规划。** 原规划只有一行：「3.4 阅读器 + 划词（最大未知）」。
实测后缺口大头在**数据层**，不在 UI：

| 层 | 原规划以为 | 实测 |
|---|---|---|
| 数据层 | （未提） | 🔴 **4 张表不存在 + 1 个 32.9 MB 预制库从未落盘** |
| UI | 阅读器 + 划词 | 阅读器页 + 划词触发 + 查词浮层 + 查词写入 —— 4 块 |
| 依据文档 | 「设计稿」 | 实际要读 **3 份**（v1 §九 划词流程 / L1 §07 浮层形态 / spec §5.1 排版），**且三处正文字号互不相同** |

**建议分期**（见 §五）：`3.4a 阅读器骨架`（mock 正文，不依赖任何新表）→ `3.4b word.db 落盘 + 划词查词` → `3.4c 生词本落库`。

---

## 二、已核实现状（每条带判据 · 可直接复核）

| # | 事实 | 判据 |
|---|---|---|
| 1 | **前端无任何阅读器文件** —— 只有 `screens/chat/chat_reading_passage.dart`（K12 遗留，调已随 3.0 删除的 `/api/k12/reading/…`） | `find app/lib -iname '*read*' -o -iname '*passage*'` → 1 命中且是 K12 |
| 2 | **`word.db` 不在 app 内** —— 在 `data/word.db`，**32.9 MB**（32,960,512 B） | `find app/assets -name '*.db'` → **0**；`ls -la data/word.db` |
| 3 | **`assets/` 只声明了 `assets/sql/`** —— 落盘机制不存在 | `pubspec.yaml` `assets:` 段 |
| 4 | **端侧 schema 只有 3 张表**：`card_review_state` / `review_log` / `bookmark` | `grep '^CREATE TABLE' app/assets/sql/user_db_schema.sql` |
| 5 | v1 §3.2（**L0 权威**）另有 4 张表**未实现**：`user_word`（生词本）· `lookup_event`（查词记录）· `article`（文章）· `external_word_cache`（词库外缓存） | v1 L275–360；端侧 schema L123 注释自认「待后续迁移一并落库」 |
| 6 | **`FeedItem` 刻意无正文**（只有 `excerpt` 摘要）· `mock_feed` 只有 3 条 excerpt | `app/lib/models/feed_item.dart` / `data/mock_feed.dart` |
| 7 | **卡片点击未接通** —— `FeedCard.onTap` 存在但 `home_screen` 未传 → 卡片不可点 | `home_screen.dart:286` 只传了 `bookmarkReady` |
| 8 | **无阅读器路由** | `grep "path: '" app/lib/app.dart` → 无 reader/article |
| 9 | **后端无文章接口**（RSS 抓取属 Phase 3） | `grep articles backend/.../routes.rs` → 只有注释 |

### 划词/阅读器的依据文档（三份，各管一段）

| 文档 | 层 | 管什么 |
|---|---|---|
| v1 §九「用户查词流程」 | **L0** | 流程：**画线 → 查 word 表 → 命中取 card → 写 `user_word` + `card_review_state` → `pending_push`**；未命中 → `external_word_cache` → LLM 制卡 |
| `visual-word-card-target` §07（划词浮层） | **L1** | 浮层形态：**与卡片同一套四段结构**（记忆法在释义前）· 不可拆词不摆空段 · 正文里已查词用极淡痕迹 |
| `design-system-spec` §5.1（阅读器正文） | L2 | 排版：行高随主题 / 行宽≤680 / 段距 16 / 阅读区无边框无阴影 / 顶部栏极简 / **点中央唤出设置面板** |
| `visual-feed-bookmark`（阅读界面） | 设计稿 | 顶部栏三元素（返回 / 分类 / 书签）+ 标题区 + 正文 |

---

## 三、3.4 真实范围

### 3.1 数据层（🔴 大头 · 5 个缺口）

| # | 缺口 | 说明 | 依赖 |
|---|---|---|---|
| D1 | **`word.db` 落盘** | 32.9 MB 预制库需 ① 进 `assets/` + 声明 ② 首次启动复制到可写目录（iOS：Documents）③ 只读打开 | 无（可独立做） |
| D2 | **文章内容来源** | `FeedItem` 无正文；v1 的 `article` 表（title/content/source_url）不存在 | ⚠️ 真数据属 Phase 3 → 3.4 用 **mock 正文**（同 3.1 的做法） |
| D3 | **`user_word`**（生词本） | 查词命中要写入（v1 §九）。这是**「200 词上限」的物理载体** | D1（需 `word_id`） |
| D4 | **`lookup_event`**（查词记录） | 语境记录（一词可多条）—— 记忆已定「例句取首次 `MIN(looked_up_at)`」 | D1 |
| D5 | **`external_word_cache`** | 词库外词路径。⚠️ 记忆已定「**划词不走后端**」→ 词库外是否走 LLM **需重新确认** | 待定 |

### 3.2 UI 层（4 块）

| # | 块 | 说明 |
|---|---|---|
| U1 | **阅读器页** | 顶部栏 + 标题区 + 正文（Literata / 行高随主题）+ **痕迹由 3.2 的 `TraceText` 渲染**（3.2 第一次有正文可标） |
| U2 | **划词触发** | v1 说「用户画线」—— 移动端具体手势**未定义**（见 §四 冲突 4） |
| U3 | **查词浮层** | 形态由 L1 §07 定；字号 = 卡片 ×0.9（spec §5.2） |
| U4 | **查词写入** | 命中 → 写 `user_word` + `card_review_state` + `pending_push`（v1 §九） |

---

## 四、冲突与空白（**4 项 · 需白哥裁决**）

### 冲突 1：正文字号 —— 三处文档互不相同

| 来源 | 层 | 值 |
|---|---|---|
| `design-system-spec` §5.1 | L2 | **18px**（默认，可调 15–24） |
| `visual-word-card-target` §07 | **L1**（界面锚点） | **17px** |
| `visual-feed-bookmark`（阅读界面 CSS `.rd .body`） | 设计稿 | **16.5px** |

跨度 16.5–18（差 1.5px）。按记忆的裁决规则「**设计稿与 spec 冲突时按 spec**」应取 18；
但 **L1 是界面锚点、优先级高于 L2**（向 L1 对齐）→ 取 17。**两条规则指向不同答案**，故请示。

> 📌 我的建议：**取 L1 的 17px**。理由：L1 是「界面锚点」层（记忆的分层表明确 L1 > L2），
> 且 spec 的 18px 是「**默认值且可调 15–24**」——本质是滑块初值，不是版面定值。
> 但三处都合理，**以你看到的实际观感为准**。

### 冲突 2：顶部栏 —— 元素不同

| 来源 | 元素 |
|---|---|
| spec §5.1 | 返回 + 标题（**下滑隐藏**） |
| 设计稿 · 阅读界面 | 返回 + **分类** + 书签 |
| L1 §07 | 返回 + **标题** + 书签 |

设计稿与 L1 都含**书签**（且 3.3 已实现书签）→ 建议 **返回 + 分类 + 书签**（对齐设计稿），
下滑隐藏属动效细节、可后补。

### 冲突 3：文章表 —— v1（L0）与 v2 用了不同表名

| 来源 | 表 | 位置 |
|---|---|---|
| **v1 §3.2**（L0 权威） | `article`（title / content / source_url） | **user.db**（用户库） |
| v2 / 电子书方案 | `content_cache`（+ `source_type` / `parent_id` / `is_local`） | 端侧 |

🔑 这是**「上游先偏」的又一例**：v2 引入了 `content_cache` 并沿用到电子书方案，
但 L0 用的是 `article`。**按分层应遵 v1** → 但电子书已定「复用 `content_cache`」→ 两者会打架。

### 空白 4：划词手势 —— 三份文档都没定义

v1 只说「**用户画线**」。移动端要落到具体交互，至少三种可能：

| 方案 | 交互 | 代价 |
|---|---|---|
| **A** 点词查（推荐） | 单击任一单词 → 直接查 → 浮层 | 与「痕迹是词级」一致；不需长按；但点词与「唤出设置面板（点中央）」有冲突（见下） |
| **B** 长按选择 | 长按 → 系统选择器 → 选中词/短语 → 查 | 更接近「画线」字面；可查短语；但打断阅读感更强 |
| **C** 混合 | 单击查词 + 长按选短语 | 覆盖最全，实现最重 |

⚠️ **与 spec §5.1 的直接冲突**：spec 说「**单击屏幕中央唤出设置面板**（Kindle 模式）」——
若再让「单击单词查词」，则同一个「点击」有两种含义。**这个冲突必须一并定**（见请示 Q3）。

---

## 五、分期建议（按依赖排序）

| 批 | 内容 | 依赖 | 可否独立验证 |
|---|---|---|---|
| **3.4a 阅读器骨架** | 扩 `FeedItem` 加正文（mock，取自设计稿原文）· 阅读器页（顶部栏 + 标题区 + 正文 + `TraceText` 痕迹）· 卡片点击接通 + 路由 | **无**（不需要 word.db / 不建新表） | ✅ 能读一篇文章，痕迹在真实正文里生效 |
| **3.4b 划词查词** | `word.db` 进 assets + 首次复制落盘（D1）· 划词触发（U2）· 查词浮层（U3） | `WordQueryService`（已建 ✅） | ✅ 真库断言 + 真机目视 |
| **3.4c 生词本落库** | `user_word` + `lookup_event` 表（D3/D4）· 查词命中写入链路（U4） | 3.4b | ✅ 真库断言（收藏脚本同模式） |

> **为什么 3.4a 可先行**：它**不碰任何新表**、不需要 32.9 MB 库，
> 却能立刻让 3.2 的痕迹**第一次有正文可标**（3.2 交付时痕迹没有落脚处，这是当时明确的留白）。
> 且它复用 3.1 已验证的 mock 模式，风险最低。
>
> **为什么 D5（`external_word_cache`）暂不做**：记忆已定「**划词不走后端**」，
> 而 v1 §九 的「未命中 → LLM 制卡」是联网路径 —— 两者需先对齐（属 Phase 3 的取舍）。

---

## 六、待白哥拍板（3 项）

| # | 事项 | 选项 |
|---|---|---|
| **Q1 分期** | 本轮做多少 | (a) 只做 **3.4a 阅读器骨架**（推荐 · 风险最低）(b) **3.4a + 3.4b**（含 word.db 落盘与划词）(c) 先做数据层（D1–D3）再做 UI |
| **Q2 正文字号** | §四 冲突 1 | (a) **17px**（L1 界面锚点 · 推荐）(b) 16.5px（设计稿）(c) 18px（spec 默认值） |
| **Q3 划词手势 + 设置面板冲突** | §四 空白 4 | (a) **单击词查词**，设置面板移到「顶部栏按钮」或「长按中央」（推荐）(b) 长按选择（贴近 v1「画线」字面）(c) 单击中央唤出设置面板，查词走长按选择 |

> 冲突 2（顶部栏）与冲突 3（文章表名）**不必单列**：
> 顶部栏我按「返回 + 分类 + 书签」实现（设计稿与 L1 一致处）；文章表 3.4a 用 mock、不建表，
> 建表时再定（届时按分层遵 v1 `article`，除非电子书方案已把 `content_cache` 定为事实标准）。

---

## 七、✅ 白哥决策（2026-09-27 13:25）

| # | 事项 | 决策 |
|---|---|---|
| **Q1 分期** | | **只做 3.4a 阅读器骨架**（零新表 · 不需 word.db · 风险最低） |
| **Q2 正文字号** | | **17px**（L1 界面锚点 `visual-word-card-target` §07） |
| **Q3 划词手势** | | **长按选择**（贴近 v1「用户画线」字面；可查短语） |

🔑 **Q3 顺带消解了一处冲突**：原 spec §5.1 说「**单击屏幕中央唤出设置面板**」，
若再让单击查词就一个字两种含义。选**长按选择**后两者正交 ——
**单击 = 唤出设置面板 · 长按 = 选词查词**，不需再改 spec。

📌 **Q2 的连带影响**：字号值集中为常量，三档主题**共用 17px**（L1 未按主题分档）；
行高仍随主题（spec §5.1 的 `--read-lh`：墨 1.82 / 格 1.74 / 夜 1.84）→ **需核实该值是否已在 token 层**。

---

## 八、规划总结

**3.4 的难点不在「画一个阅读器」，而在「一张文章表、一本生词本、一个 32.9 MB 的库」都还没有。**
本轮按 **3.4a 阅读器骨架** 实施（零新表、低风险、立刻让痕迹有正文可标），
数据层留到 3.4b/c。

---

## 九、✅ 3.4a 执行记录（2026-09-27 13:40）

### 9.1 交付物

| 文件 | 动作 | 行数 | 说明 |
|---|---|---|---|
| `models/article.dart` | 🆕 | 73 | `Article` + `ArticleLookup` —— **数据层存事实（reps/lapses），样式由渲染层算** |
| `data/mock_articles.dart` | 🆕 | 83 | 第一篇正文逐字取自设计稿；后两篇 `paragraphs: []`（设计稿没有它们的全文） |
| `widgets/trace_locator.dart` | 🆕 | 68 | **词级痕迹定位**（零 Flutter 依赖）—— 核心是**词边界** |
| `widgets/bookmark_button.dart` | 🆕 | 100 | 从 `feed_card.dart` **抽出**（设计稿 `.bm` 本就是卡片与阅读界面共用的同一个类） |
| `screens/reader_screen.dart` | 🆕 | 346 | 阅读器（顶部栏 / 标题区 / 正文 / 痕迹 / 两种「读不了」状态） |
| `widgets/feed_card.dart` | 改 | 208→118 | 移出 `BookmarkButton` + 加 import |
| `app.dart` | 改 | +22 | `/article/:id` 路由（`pageBuilder` + 右滑转场，与 `/chat` 同级） |
| `home_screen.dart` | 改 | +6 | 卡片 `onTap` → 阅读器 |

### 9.2 三项决策落地

| 决策 | 落地方式 |
|---|---|
| **只做 3.4a** | ✅ 未建任何新表、未碰 `word.db`；划词/浮层/生词本留给 3.4b/c |
| **正文 17px** | `ReaderScreen._bodyFontSize = 17`；🔑 **不进主题 token**（见 §9.3） |
| **长按选择** | 3.4a 未涉及（属 3.4b）；但已在阅读器类文档写明**为何单击留给设置面板** |

### 9.3 🔑 四处设计判断（都写进了代码注释）

**① 「阅读界面零粘土」的裁决 —— 顶部栏书签是有意保留的粘土**

| 文档 | 说法 |
|---|---|
| spec §〇 规则 2 | 「**阅读界面零粘土**」（宽） |
| spec §八 **验收项** | 「**阅读区容器内**不得出现粘土类」（窄 · 且有明确检查范围） |
| 设计稿 | `.bm`（书签）**同时用于 `.fc`（卡片）与 `.rd-bar`（阅读栏）** → 本来就是粘土 |

→ 取 **§八 的口径**（验收项比原则表达精确）：**正文区零粘土**（严格），
顶部栏那一个动作按钮保留粘土（与卡片同一套语汇）。
若把它改成平面，同一个动作在两个界面会长得不一样 —— 破坏「一套语汇」。
**已加自动检查**（`tokens_verify` §12，5 项）。

**② 正文字号不进主题 token**

行高是**主题相关**的（`readLineHeight` 三档 1.82/1.74/1.84 —— 不同底色下人眼舒适度不同），
而字号是**用户偏好**（spec：可调 15–24）。
一个是「主题」、一个是「设置」—— 混进同一层，将来做设置面板时会分不清谁覆盖谁。

**③ `BookmarkButton` 抽成独立组件**

3.3 时它与 `FeedCard` 同文件。3.4 阅读器也要用它 —— 若不抽，
阅读器得 `import 'feed_card.dart'` 只为拿一个按钮，**依赖方向变得莫名**。
抽出的依据是设计稿本身：`.bm` 就是**一个类**。

**④ 「正文未就绪」与「找不到文章」是两种状态，各有文案**

🔴 **不共用白屏** —— 白屏用户只会以为 App 坏了（与「静默失败」同类）。
另外：正文未就绪的文章**照样可点**（进阅读器看解释），
而**不是**把卡片做成不可点 —— 后者要用户猜原因。

### 9.4 与设计稿的逐项对照

| 元素 | 设计稿 | 实现 | 偏差 |
|---|---|---|---|
| 顶部栏内边距 / 间距 | `0 20 14` / 12 | 同 | — |
| 返回符 | 19 / `ink3` | 同（热区撑到 44） | 热区是我加的（设计稿未定义） |
| 分类 | 12.5 / w600 / `ink2` | 同 | — |
| 正文区左右 | 26 | 同 | — |
| 标题区 | `6 0 20` | 同 | — |
| 来源行 | 10.5 / w600 / .07em / 大写 / `accent` | 同 | — |
| 标题 | Literata 21 / w500 / 1.3 / -.012em | 同 | — |
| **正文** | Literata **16.5** | Literata **17** | 🔴 **白哥定 17**（对齐 L1 界面锚点） |
| 行高 | `--read-lh` | `t.readLineHeight`（三档） | — |
| 段间距 | 16 | 同 | — |
| 顶部栏书签 | `.bm`（粘土凹/凸） | `BookmarkButton` | — |

### 9.5 ✅ 验证

| 项 | 结果 |
|---|---|
| `trace_verify` | ✅ **97 项**（76 → 97 · 新增 **21 项**定位断言，含 **6 条词边界**：`art` 不匹配 `start`/`part`/`artist`、`vertical` 不匹配 `vertically`、`_` 算单词字符、连字符边界） |
| `tokens_verify` | ✅ **300 项**（295 → 300 · 新增 §12「阅读界面零粘土」5 项） |
| `verify_bookmark` / `verify_review_list` / `verify_word_query` | ✅ **49 / 37 / 42 项**（抽出 `BookmarkButton` 后**无回归**） |
| `analyze_inproc`（`app/lib`，72 文件 / 21,517 行） | ✅ **error=3 / warning=13 / info=7** 与基线一致（过程中曾多出 1 个 `unused_import`，已修） |

### 9.6 ⏳ 只能真机看的（如实列出）

| 项 | 为什么脚本查不出 |
|---|---|
| 三档主题下正文的**对比度舒适度** | `ink` 对 `read` 的对比度已达标（token 验收），但「读起来累不累」是人的判断 |
| 17px + 行高 1.82/1.74/1.84 的**实际观感** | 数字对不代表版面舒服 |
| 痕迹在 17px 正文里**是否可辨** | spec §八 明确要求肉眼（3.2 已列出） |
| 顶部栏书签与卡片的**粘土观感是否一致** | 两处共用组件，但上下文底色不同 |
| **点书签不应同时触发卡片点击** | 卡片外层的 `Clay(onTap:)` 包着书签按钮；Flutter 手势竞技场里内层优先（标准行为），但**这是第一次两者都启用**（3.3 时卡片 `onTap` 是 `null`）→ 值得实机点一下确认 |

**请白哥 `flutter run` 后**：点首页第一张卡（有正文）→ 看顶部栏 / 标题区 / 三段正文 / 三处痕迹
（`vertical` 刚查过 · `Instead`+`liquid` 复习中 · `produces`/`traditional`/`kilometres` **应无任何标记**）；
再点第二张卡 → 应看到「正文还没准备好」。

### 9.7 下一步

`3.4b`：`word.db` 进 assets + 首次落盘 · **长按选择**触发 · 查词浮层（L1 §07）
→ `3.4c`：`user_word` + `lookup_event` 落库 + 查词写入链路
→ 之后 `3.5 收藏清单`（「收藏 N」入口届时才有意义）。

---

## 十、3.4b 规划：`word.db` 落盘 + 划词查词（2026-09-27 13:50）

> 状态：🔴 **待批准**（未动任何一行代码，除下列**只读实测**）
> 上游：§九（3.4a 已完成）

### 10.1 已实测的 8 个事实（每条可直接复核）

| # | 事实 | 判据 |
|---|---|---|
| 1 | `word.db` = **32,960,512 B**（32.9 MB）· **19 表 / 27 索引** | `ls -la data/word.db`；`SELECT count(*) FROM sqlite_master` |
| 2 | 规模：`word` 11,523 · `card` 11,523 · `word_form` 22,829 · `aggregate_page` 1,777 · `aggregate_page_word` 10,398 · `word_morpheme` 13,489 | 逐表 `COUNT(*)` |
| 3 | 🔑 **`git add` 第二份相同文件 → 零新增**：松散对象 **113 → 113**，`.git` 仍 **87 MB** | 复制到 `app/assets/` → `git add` → `count-objects` 对比 → `reset` 撤销 |
| 4 | `path_provider: ^2.1.0` **已在依赖**（落盘不需要新依赖） | `app/pubspec.yaml:19` |
| 5 | `TraceText` 用 **`Text.rich`** → **可参与 `SelectionArea`**（`Text`/`RichText` 均支持 `selectionRegistrar`） | `text.dart:977` |
| 6 | **`SelectedContent { final String plainText; }`** —— 长按选中后可直接取文本 | `rendering/selection.dart:200` |
| 7 | 🔴 **`card.sections` 没有 `priority` 字段** —— 段顺序就是存储顺序 | `intercept` 段序 = `root, cognate, collocation, etymology, definition, context` |
| 8 | **优先级在 `mnemonic_type.priority`**：`root`1 · `cognate`2 · `collocation`3 · `etymology`4 · `image`5 · `context`6 | `SELECT * FROM mnemonic_type` |

### 10.2 🔴 事实 3 推翻了「两份会让仓库翻倍」的推测

**我原本的推测**：把 33 MB 复制进 `app/assets/` → git 存两份 → **+66 MB**（且每次更新 +66）。
**实测**：`git` 按**内容哈希**存 blob → 两份内容相同时**复用同一个 blob** → **零新增**。

| 方案 | git 成本（实测） | 工作区磁盘 | 失败模式 |
|---|---|---|---|
| **两份都进 git**（推荐） | **首次 0** · 每次词库更新 +33 MB | 多 33 MB | ⚠️ 两份**可能漂移**（只更新一份就分叉） |
| 单一权威 + 构建时复制 | 同 +33 MB | 一份 | 🔴 **忘记跑复制**（CI/本地都要额外一步） |

→ **取「两份都进 git」**：git 成本与另一方案相同，却省掉整个构建步骤（clone 即完整、CI 不需要前置步骤）。
⚠️ 代价是**漂移风险** → 必须加一条「两份 md5 一致」的断言（**这是本批的必做项，不是可选**）。

> 📌 与 `fonts` 先例的差别：fonts 是「源 → 中间产物 → 交付物」三级，源必须不进 git；
> 而 `word.db` **源与交付物是同一个文件**（不是构建产物），所以两份都进是合理的。
> ✅ **本项不改动任何既有 `.gitignore` 决策**（`data/word.db` 原样保持进 git）。

### 10.3 技术方案

#### （1）落盘：三件事

```
assets/word.db  ──rootBundle.load──►  ByteData(32.9 MB)
                                          │ 写盘（仅首次 / 词库变更时）
                                          ▼
              getApplicationDocumentsDirectory()/word.db   ← SQLite 只读打开
```

| 点 | 做法 | 理由 |
|---|---|---|
| **为什么必须复制** | assets 是**打包资源**（`rootBundle` 拿 ByteData），不是可直接 `open` 的文件路径 | iOS bundle 只读；SQLite 打开会尝试建 WAL |
| **何时复制** | **后台预加载**：进阅读器时异步启动；划词时 `await` 同一个 `Future` | 🔴 不能在启动时阻塞首屏（33 MB 复制约 0.5–2 s） |
| **怎么判断要不要复制** | 比较**目标文件 size** 与 assets size：不存在 → 复制；size 不等 → 重复制；相等 → 跳过 | 🔑 **没有这一步，App 升级后用户会一直用旧词库**（且不报错） |

> ⚠️ **size 比较是启发式**：「size 相同但内容不同」在理论上可能（概率极低 —— 33 MB 的库重写后极少等长）。
> 若将来真出现，改用「随词库生成的版本文件」。**现在不预先加**（避免为假设的复杂度付费）——
> 但这条限制写进代码注释，别让后人以为是完备的。

**分层**（沿用 3.3 的做法 —— 可验证性驱动）：

| 文件 | 性质 | 内容 |
|---|---|---|
| `services/word_db_bootstrap.dart` | **纯 Dart** | 决策逻辑：`needsCopy(targetSize, assetSize)`（纯函数）+ `ensure()`（**字节来源与写盘由调用方注入**） |
| 调用层（provider） | Flutter | 注入 `rootBundle.load` 与 `path_provider` |

→ 于是「要不要复制」这个判断能被脚本断言（边界：不存在 / size 相同 / size 不同 / 目标为 0 字节）。

#### （2）长按选择：`SelectionArea` + 自定义 toolbar

```dart
String? _picked;                      // 暂存选中文本（toolbar builder 拿不到 state 内容）
SelectionArea(
  onSelectionChanged: (c) => setState(() => _picked = c?.plainText),
  contextMenuBuilder: (ctx, state) => _LookupToolbar(text: _picked, onLookup: ...),
  child: TraceText(...),              // Text.rich → 支持 selectionRegistrar
)
```

- **为什么自定义 toolbar**：默认 toolbar 是「复制 / 全选 / 查找」—— 阅读场景下**复制没用**，
  且用户还要在系统菜单里找路。我们要的是**只有一个「查词」**。
- **为什么用 `onSelectionChanged` 暂存**：`contextMenuBuilder` 只拿到 `SelectableRegionState`，
  而选中文本要从回调里取 → 暂存是标准做法。
- ⚠️ **拖动选择会反复触发 `onSelectionChanged`** → 只在**点「查词」时**查，不在回调里查（否则会连打十几次库）。

#### （3）浮层的数据映射 —— 🔴 **浮层 = 查词（基础信息）· 词卡 = 学词（记忆法）**

> **白哥 2026-09-27 14:36 定**：「浮层应该显示的是**基础信息**而不是**优化记忆**，即**音标、词性、释义、例句**」

##### ⚠️ 这是对 L1 §07 的修正（如实说明）

| 出处 | 说法 |
|---|---|
| **L1 §07**（界面锚点） | 「浮层与卡片**同一套四段结构**（一致的心智模型），**记忆法在释义之前**」 → 浮层含①记忆法 |
| **v1 §九**（**L0 最高权威**） | 「命中 → 取 card → **显示**」 —— **未规定显示什么** |
| **白哥（本项）** | 浮层 = **音标 / 词性 / 释义 / 例句**（**不含记忆法**） |

→ 因 **v1 未规定**，本项**不违反 L0**，只**修正 L1**（L1 把浮层画成了「词卡的紧凑版」）。

##### 🔑 两个场景的分工（这是本项的实质）

| | **划词浮层** | **词卡**（3.7） |
|---|---|---|
| 场景 | **查词** —— 我在读文章，这个词什么意思？ | **学词** —— 我要记住这个词 |
| 内容 | **基础信息**：音标 / 词性 / 释义 / 例句 | **记忆法**：① 词根词缀 / 词源故事 ② 释义 ③ 语境 |
| 诉求 | **快**（不打断阅读） | **记住**（一页记忆方案） |
| 用 `priority`？ | ❌ **不用** | ✅ 用（`root`→`cognate`→`etymology`→…） |

🔑 **这也确定了 `priority` 交换（§十二）的作用域**：它服务的是**词卡**，与浮层无关。
（交换仍然有意义 —— 修掉了 `etymology` 0.5% 的表内部矛盾，且 3.7 词卡会用到。）

##### 四要素的数据来源与覆盖率（实测 11,523 张卡）

| 元素 | 数据源 | 覆盖率 |
|---|---|---|
| 词 | `card.content.front` | **100%** |
| **音标** | `card.content.ipa`（**元素级 CharisSIL**，见 spec §4.1.1） | **100%** |
| **词性** | `sections[definition].pos` | **100%** |
| **释义** | `sections[definition].zh`（主）+ `.en`（次） | **100%**（两者都有） |
| **例句** | `sections[context].text` | **99.7%**（11,491）→ 32 个词无例句，需空态 |

**🔴 词性有 47 种写法，必须归一化**：

| 格式 | 占比 | 例 |
|---|---:|---|
| `[xx]` 方括号 | **84.4%** | `[n]` 5736 · `[adj]` 2270 · `[v]` 1222 |
| `xx` 纯缩写 | **14.7%** | `verb` 541 · `n` 452 · `noun` 337 · `v` 155 |
| 其他/空 | 0.9% | — |

→ **同一个词性有三种写法**（`[n]` / `n` / `noun`）。渲染层需**归一化后统一显示**（否则浮层会时方括号时全称）。
⚠️ **不在渲染层写映射表**（会是第 N 处「同一逻辑多副本」）→ 归一化规则放**一处**，并由断言锁住。

##### 浮层实际形态（用真库数据拼出）

```
intercept                              🔊
/ˌɪntɜˈsɛpt/                           [v]
──────────────────────────────────────────
拦截；截获
to stop, catch, or seize someone or something before it reaches…

「The police intercepted the stolen vehicle on the highway.」
```

##### ⚠️ 「其他义项」与「例句来源」两处留白

| 项 | 实测 | 本轮处理 |
|---|---|---|
| **其他义项**（`card_extra`） | **13,812 行 / 8,255 张卡**（含 `pos`/`zh`/`en`/**`example`**） | 只显示**首义**（`definition`）—— 白哥的四要素是单数；多义项留给**词卡** |
| **例句来源** | `context.text` 是**通用语料例句**（非用户正在读的那句） | 本轮用 `context`；🔑 **3.4c 接 `lookup_event` 后**可显示「**你读到的那句**」（更贴合划词场景） |

**🔴 渲染层不得读 `word_mnemonic_profile.primary_code`** —— 白哥 2026-09-26 已定
「**制卡时不分主要次要，只问是否可以。优先级是渲染层面的事**」。
⚠️ 但实测发现：**该表的 `primary_code` / `secondary_codes` 数据仍在**（如 `intercept` → `root` + `["cognate"]`）。
→ **「设计上废弃」≠「数据已清」** —— 后人看到这列有数据，很可能顺手读它。
**做法**：本轮不读它，并在此处**明确标注**（避免有人「发现有数据就用」）。

### 10.4 🔴 两个决策点

#### 决策点 1：槽位① 按 `priority` 取，`collocation` 会占掉 52%

| 词 | 按 `priority` 顺序取 | 设计稿 L1 §07 显示 |
|---|---|---|
| `intercept` | `root`(1) → **词根词缀** | **词根词缀** ✅ 一致 |
| `vertical` | `collocation`(3) → **搭配整记** | 🔴 **词源故事**（`etymology`(4)） |

🔴 **`vertical` 不一致** —— 这正是记忆里那条待办的根源：
「⚠️ `collocation` 占槽位① 52% → **须先补「固定搭配强」判定**（未做）」。

##### 🔑 但实测推翻了「搭配不够强」这个诊断 —— 根因是 `priority` 表自相矛盾

**白哥定「本轮就补搭配强度判定」（2026-09-27）后，我先去查数据 —— 结论与预期不同。**

| 实测 | 值 |
|---|---|
| **不可拆词**（`sections` 无 `root`） | **6,039 / 11,523 = 52.4%** |
| 其中**有 `etymology` 段**的 | **5,924（98.1%）** |
| 同时有 `collocation` + `etymology` 的 | 11,350（98.5%） |

**槽位① 分布对比**：

| 槽位① | 现状 priority | collocation 移到 etymology 之后 |
|---|---:|---:|
| `collocation` | **5,957（51.7%）** | 86（0.7%） |
| `root` | 5,484（47.6%） | 5,484（47.6%） |
| `etymology` | **53（0.5%）** | **5,924（51.4%）** |

🔑 **`collocation` 的 51.7% 与「不可拆词」的 52.4% 几乎完全重合** ——
也就是说，它抢走的是**本属于 `etymology` 的位置**，与「搭配质量」无关。

**为什么说这是 `priority` 表自相矛盾** —— 看 `mnemonic_type.applicable_when` 的语义：

| 类型 | priority | `applicable_when` |
|---|---:|---|
| `root` | 1 | **可拆**成现代英语仍透明的词根/词缀 |
| `cognate` | 2 | 与另一英语词共享词根/词源 |
| `collocation` | **3** | **有 ≥1 条高频固定搭配** ← 实测 **99.3%** 都满足 |
| `etymology` | **4** | **整体借词、不可拆** |
| `image` | 5 | 抽象词，靠意象/谐音 |
| `context` | 6 | 默认附加 |

- `root`（**可拆**）与 `etymology`（**不可拆**）是**互补**的两条路，合计覆盖 99%+ —— 这是表自己的设计意图。
- 而 `collocation` 的条件「有 ≥1 条固定搭配」**几乎人人满足**（99.3%）→ 把它放在第 3 位，
  **必然吃掉所有「不可拆词」的槽位①**（`etymology` 只剩 0.5%，形同虚设）。

> 🔑 **这不是「搭配不够强」，是「顺序让一个几乎恒真的条件盖住了一个具体条件」。**
> 修根因 = 调顺序（1 行数据），不是加判据。

##### ⚠️ 我试过的「搭配强度」判据：无效

试的判据是「搭配的中文是否只是词义的字面组合」（如 `vertical line`=垂直线 ⊃ 垂直）。
实测：**只筛掉 8.8%**（1,002 / 11,437）—— 远不足以改变 51.7% 的分布。
（且首个版本有 bug：把「第一个义项」整体当核心词，`荒谬的，荒唐的` 与 `荒谬的想法` 判为不含 → 误判。
修正后可提升，但**离 51.7% 的规模差太远**。）

**结论**：靠「搭配质量」判据去把 51.7% 降下来，是**用错了工具**。

##### 三个选项（请白哥定）→ ✅ **已定 (a) 并执行（2026-09-27 14:08）**

| | 做法 | 效果 | 改动面 | 状态 |
|---|---|---|---|---|
| **(a) 改 `mnemonic_type.priority`**：**交换 `etymology` 3 ↔ `collocation` 4** | 与 `applicable_when` 语义自洽；结果 = `etymology` **51.4%** / `collocation` **0.7%** | ✅ **与设计稿 L1 一致** | 🔴 改 **2 个值**（3 处出处：DB + 脚本源 + 验收副本）+ 同步 assets | ✅ **已执行 · 验证全过** |
| (b) 按原计划补「搭配强度」判定 | 需重新设计判据；而实测「字面组合」无效 → 大概率要 **LLM 判定**（~6,000 词） | ⚠️ 若判据不够强，collocation 仍占多数 | 渲染层规则 + 可能重跑 | ❌ 未采用（判据已证无效） |
| (c) 两者都做 | (a) 修顺序 + (b) 让 `collocation` 在兜底位仍有质量门槛（0.7% 那部分） | 最完整 | 最大 | ❌ 未采用 |

> 📄 **执行记录（含 3 处出处、未重排段顺序的理由、全部实测数据）→ `mnemonic-slot-priority-conflict-2026-09-27.md` §十二**
>
> 🔑 **执行后的最终分布**：`etymology` **5,924（51.4%）** · `root` 5,484（47.6%）· `collocation` **86（0.7%）**
> ✅ `vertical` 的槽位① 现为「**词源故事 · vertere（Latin·转）词源族**」= **与设计稿 L1 一致**（这就是本次改动的目标）
> ⚠️ **仍未定**：`verify_card_structure.py` 里那条「段存储顺序」断言**是否保留**（见 §12.3）

#### 决策点 2：聚合页入口 —— ✅ 白哥定了（2026-09-27 14:40）

> **白哥原话**：「浮层**不放**，但**点击浮层应该能进入到复习卡片**，聚合页进入入口**暂时只有复习卡片**」

##### 🔑 三层递进（这是本项确定的架构）

```
划词 → 浮层（基础信息：音标 / 词性 / 释义 / 例句）
         │  点击整个浮层
         ▼
      复习卡片（① 记忆法 ② 释义 ③ 语境）        ← 3.7
         │  点击 ① 里的「词源族 33 词 ›」
         ▼
      聚合页（词族成员 + 分拆法）                 ← 入口只在复习卡片
```

**聚合页入口的落点是唯一的：复习卡片。** 浮层不放。

| 层 | 内容 | 聚合页入口 | 批次 |
|---|---|---|---|
| **浮层** | 基础信息四要素 | ❌ 不放 | **3.4b（本轮）** |
| **复习卡片** | 记忆法 + 释义 + 语境 | ✅ **唯一入口** | 3.7 |
| **聚合页** | 词族成员列表 | — | 跟随入口 |

##### 🔴 由此产生的时序问题（必须说清）

| 事实 | 后果 |
|---|---|
| **复习卡片 = 3.7**（本轮不做） | ① 浮层的「点击进入复习卡片」**本轮没有落点**<br>② 聚合页入口也**没有落点** → **聚合页本轮做不了** |

🔑 **所以「聚合页本轮做」这个决定被本次调整自动顺延**（不是被否掉，是**入口还不存在**）。

**我按项目一贯原则处理**（3.1/3.3 的教训：**不做死入口**）：

| 项 | 本轮做法 |
|---|---|
| 浮层的「进入复习卡片」入口 | ❌ **本轮不放** —— 词卡页不存在，放了就是死入口 |
| 聚合页 | ❌ **本轮不做** → 顺延到 **3.7**（与复习卡片一起，那时入口自然存在） |
| 浮层内容 | ✅ 只做四要素（§10.3(3)） |

⚠️ **如果你希望本轮就把「点击浮层 → 复习卡片」接通**，那等于**本轮同时做复习卡片（3.7）**
—— 那是个大工程（L1 §07 四段结构 + spec §5.2 字号层级 + 痕迹 + 聚合页入口）。
**需要你明确**：本轮是否扩到含复习卡片？

### 10.5 本批范围（✅ 已按白哥 14:36 / 14:40 两项决定调整）

| 项 | 内容 |
|---|---|
| **D1** `word.db` 落盘 | 复制进 `app/assets/`（✅ 已就位）· **pubspec 声明** · `word_db_bootstrap.dart`（纯 Dart 决策层）+ provider（后台预加载）· **两份一致性断言**（✅ 已建） |
| **U2** 长按选择 | `SelectionArea` + 自定义 `_LookupToolbar`（只有一个「查词」）+ 选中文本暂存 |
| **U3** 查词浮层 | 🔴 **基础信息四要素：音标 / 词性 / 释义 / 例句**（白哥 14:36 定 · **不含记忆法**）<br>➕ **`pos` 归一化**（47 种写法 → 统一格式，规则放**一处**） |
| **U3b** 聚合页 | ❌ **顺延到 3.7** —— 入口只在复习卡片，本轮无落点（白哥 14:40 定） |
| **不做**（各附理由） | ① **浮层的「进入复习卡片」入口** → 词卡是 3.7，**放了就是死入口**（3.1/3.3 教训）<br>② 「＋ 加入生词本」→ 需 `user_word` 表，属 **3.4c**<br>③ 词库外路径（`external_word_cache`）→ 需先与「划词不走后端」对齐<br>④ **记忆法槽位①** → **浮层用不到**（它属复习卡片）；`priority` 交换已做（服务 3.7） |

> 🔑 **本批的范围因此比原计划小**：原以为要带聚合页；现在浮层只做四要素 + 落盘 + 长按选择。
> 但**多了一项**：`pos` 归一化（47 种写法的数据不一致，是实测才发现的）。

### 10.6 验收计划

| 脚本 | 新增断言 |
|---|---|
| `trace_verify`（或新建 `worddb_verify`） | `needsCopy` 的 4 个边界 · **两份 md5 一致**（防漂移） |
| `tokens_verify` | 🔴 **渲染层不得读 `primary_code`**（防「数据还在就用它」）+ 浮层零粘土（同 spec §八 口径） |
| `query_verify` | 已有 42 项（真库）—— 确认落盘后路径仍可用 |
| `analyze_inproc` | 对齐基线 error=3 / warning=13 / info=7 |

⏳ **只能真机看**：首次落盘耗时（33 MB）· 长按选择的手感 · 浮层与正文的遮挡关系 · 三档主题下浮层可读性。

---

## 十一、✅ 3.4b 执行记录（白哥选定方案 A · 2026-09-27 14:46）

> 本轮范围：**浮层四要素 + `word.db` 落盘 + 长按选择 + `pos` 归一化**
> （**不含**聚合页与复习卡片 —— 见 §10.4 决策点 2 的时序说明）

### 11.1 交付物

| 文件 | 动作 | 行数 | 说明 |
|---|---|---|---|
| `services/word_db_bootstrap.dart` | 🆕 | 172 | **落盘决策 · 纯 Dart**（判断与 IO 分离） |
| `services/pos_display.dart` | 🆕 | 174 | **词性归一化 · 纯 Dart**（47 种写法 → 19 类） |
| `providers/word_db_provider.dart` | 🆕 | 98 | Flutter 侧注入 `rootBundle` + `path_provider` |
| `widgets/lookup_sheet.dart` | 🆕 | 192 | **查词浮层（四要素）** |
| `screens/reader_screen.dart` | 改 | 346 → **478** | `SelectionArea` + 自定义工具栏 + `_lookup` |
| `pubspec.yaml` | 改 | +6 | 🔴 **声明 `assets/word.db`**（此前它从未被打包） |
| `scripts/query_verify/bin/verify_worddb_bootstrap.dart` | 🆕 | 149 | 落盘决策 **22 项** |
| `scripts/query_verify/bin/verify_pos_display.dart` | 🆕 | 185 | 词性归一化 **31 项**（**读真库全量**） |
| `scripts/tokens_verify/bin/verify_tokens.dart` | 改 | +18 | §12 追加 **5 条浮层零粘土断言** |

### 11.2 🔑 五处关键设计

**① 落盘决策与 IO 分离 → 判断可独立断言**

`needsCopy` / `planBootstrap` 是**纯函数**，IO 全部注入（`AssetReader` / `TargetProbe` / `TargetWriter`）。
于是「要不要复制」这个**出错时没有任何运行时症状**的判断，能被脚本锁住 —— 22 项里最有价值的是：

> 🔴 **资产异常（0 字节）+ 目标存在 → 不复制**
>
> 这条防的是「**用空文件盖掉好库**」——最糟的一类（不可逆，且用户下次启动才发现）。
> 直觉上会写成「不同就复制」，但那样一旦 assets 打包事故，用户的库就被毁了。

**② `pos` 归一化：47 种写法 → 19 类**

| 类别 | 例 | 归一化 |
|---|---|---|
| 同义写法 | `[n]` / `n` / `noun` | 都 → `n.` |
| **可数性标记**（**不是词性**） | `[c, u]` / `[u, c]` / `[n pl]` | 都 → `n.`（去重后只剩一个） |
| 复合词性 | `[adj/adv]` | `adj. / adv.` |
| 括号注释 | `[adj（phrase）]` | `adj.`（全角括号被剥） |
| 多词键（**整串优先**） | `[modal verb]` | `modal v.`（不被拆成两段） |
| 未知 | `zzz` | **原样保留**（🔑 **不猜** —— 猜错比不猜糟） |

**③ 🔴 而「原样保留」这条兜底规则，差点骗过我自己**

首跑 `verify_pos_display` 报：**`[det./pron.]` 未识别**（2 张卡）。

但我在**手写样例**里断言过 `[det./pron.] → 'det. / pron.'` 并且**它通过了**。
判据（数据是否自相矛盾）：`normalizePos` 输出确实是 `det. / pron.`，看起来对 —— 为什么说未识别？

查根因：清洗只剥了**整串**的尾句点，没剥**每段**的 → 拆开后得到 `det.`（带点），
表里没有这个键 → 走「原样保留」兜底 → **输出恰好等于期望** → **假通过**。

> 🔑 **教训：凡有「兜底原样返回」的地方，就必须另有一条断言独立判「是否命中」** ——
> 否则「漏映射」会伪装成「正确」。本条已写进代码注释与验收脚本。

修法：抽出**唯一的** `_tokenKey()`（剥尾点 + 小写），`normalizePos` 与 `isPosRecognized` 共用。

**④ 长按选择：`SelectionArea` 只改一行，但有三处必须处理**

| 处理 | 理由 |
|---|---|
| `onSelectionChanged` **只暂存**、查库在点「查词」时 | 拖动选择会**反复触发**回调 → 若在回调里查库，一次拖动会打十几次 SQLite、弹十几次浮层 |
| 自定义 `contextMenuBuilder`（**只有一个「查词」**） | 系统默认是「复制/全选/查找」——「复制」在阅读场景**没用**，且用户要在系统菜单里找路。为改成 StatefulWidget 铺路的正是「暂存选中文本」这一条 |
| `barrierColor` 用**轻遮罩 12%** | 默认 54% 会把正文压暗得像「跳到了另一个界面」，而意图是**不打断阅读** |

**⑤ 「查不到」分三种，各有明确表达**（🔴 不能静默无效）

| 情况 | 表达 | 为什么 |
|---|---|---|
| 词库未就绪（落盘/打开中） | 「词库正在准备，请稍候再试」 | **可重试**，不是永久失败 |
| 词库外（未命中 + 词形还原也没中） | 「词库里没有「X」」 | 属 Phase 3 的 `external_word_cache` |
| 命中 | 弹浮层（四要素） | — |

**⑥ 一处实现细节：`ByteData` 的 offset 陷阱**

`rootBundle.load` 返回的 `ByteData` **不保证从 buffer 第 0 字节开始**。
必须写 `data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)` ——
写成 `data.buffer.asUint8List()` 会多带头部字节 → 写出的文件头不对 →
SQLite 报 `file is not a database`，而**这个错误只在真机/真打包下暴露**（本地脚本测不出）。

### 11.3 浮层的字号依据（含一处 1.5px 偏差，如实说明）

| 元素 | 值 | 依据 |
|---|---|---|
| 单词 | **21** | 🔑 **L1 §07 浮层的 inline 值**（`font-size:21px`）—— 比 `compact.word`（28.8）小得多。与 `_ClayTabBar` 圆角 17 同做法：**照设计稿、硬编码、注释说明** |
| 释义 | `compact.defText` = **14.85** | spec §5.2「浮层整体 ×0.9」（L1 的 inline 是 15 → 几乎相同 ✅） |
| 英文释义 | `compact.defEn` = 11.7 | 同上 |
| 例句 | `compact.ctxText` = 13.05 | 同上 |
| 词性 | `label` = 11（**不缩**） | spec §5.2 的 `compact` 只缩字号、label 保持 |
| 音标 | `compact.ipa` = **13.5** | ⚠️ spec 说「×0.9」，而 **L1 浮层未缩**（用 15）→ **1.5px 偏差**，真机目视后可调 |

**音标 → 释义 反比**：音标 13.5 < 释义 14.85 ✅（同 `hierarchyHolds` 的「线索不压过答案」）

### 11.4 ✅ 验证

| 脚本 | 结果 |
|---|---|
| 🆕 `verify_worddb_bootstrap` | ✅ **22 项**（含「资产异常不覆盖」的编排验证：真不写盘） |
| 🆕 `verify_pos_display` | ✅ **31 项** —— **真库全量**：47 种写法**全部被识别** → 归一为 **19 类**，且全部以「.」结尾 |
| `verify_worddb_sync` | ✅ **6 项**（两份一致） |
| `verify_word_query` / `review_list` / `bookmark` | ✅ **42 / 37 / 49 项** |
| `tokens_verify` | ✅ **304 项**（300 → 304 · §12 追加 5 条浮层断言） |
| `trace_verify` | ✅ **97 项** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（76 文件 / 22,285 行） |

⚠️ **过程中修了 2 个我引入的 error**（一度 error=5）：
`library_directive_not_first`（`library;` 必须在 import 前）· `undefined_getter`（token 字段名是 `type` 不是 `typography`）。

### 11.5 ⏳ 只能真机看（脚本查不出）

| 项 | 为什么 |
|---|---|
| **首次落盘耗时**（31.4 MB） | 依赖设备 IO；进阅读器后台进行，但**「用户等不等得到」要实测** |
| **`assets/word.db` 是否真被 `rootBundle` 找到** | 本地脚本不经过打包链路 —— 🔴 这正是项目踩过的坑（未声明 → 不打包 → **编译不报错**） |
| 长按选择的手感 · 工具栏位置是否挡字 | 交互体感 |
| 浮层与正文的遮挡关系 · 三档主题下浮层可读性 | 视觉 |
| **`ByteData` 的 offset 假设** | 只有真机真打包能验（见 §11.2⑥） |

**请白哥 `flutter run`**（iOS 模拟器/真机）：
1. 点第一张卡进阅读器 → 读一会 → **长按一个词**（如 `vertical`）→ 应弹「查词」工具栏
2. 点「查词」→ 应弹底部浮层，含 **音标 / 词性（`n.` 这种缩写，不是 `[n]`）/ 释义 / 例句**
3. 长按一个**词库里没有的词** → 应提示「词库里没有「X」」（而不是无声无息）

### 11.6 仍未做（各自有明确归属）

| 项 | 归属 |
|---|---|
| 浮层的「进入复习卡片」入口 | **3.7**（词卡页还不存在 → 放了就是死入口） |
| 聚合页（入口只在复习卡片） | **3.7** |
| 「＋ 加入生词本」 | **3.4c**（需 `user_word` 表） |
| 浮层的 🔊 朗读 | 设计稿有，但白哥的四要素**未提**；且朗读属「`flutter_tts` 接通」另一端 → **未放**（免得是死按钮） |
| 词库外路径（`external_word_cache`） | Phase 3（需先与「划词不走后端」对齐） |
| 阅读设置面板（单击中央唤出） | 独立批次（spec §5.1 的面板含字号/行高/主题/痕迹开关） |
| `word.db` 标记「不参与 iCloud 备份」 | 它是**可重建**的交付物，31.4 MB 进备份不划算 —— 需平台通道（`NSURLIsExcludedFromBackupKey`），本轮未做 |
| `AggregateLink.pageType` 恒空 | 既有缺陷（`entry` 无 `page_type` 字段），UI 用 `label` 可绕过 |

---

## 十二、🔴 白哥反馈「长按一个词没有任何弹出」→ 查清是 **web 与真机的双重差异**（2026-09-27 15:06）

> 白哥原话：「长按一个词没有任何弹出，是 web 与 app 的差异吗」→ **是的，而且是两层。**

### 12.1 🔴 两层原因（都来自 Flutter SDK 源码，不是猜测）

| # | 层 | 证据（SDK 原文） | 后果 |
|---|---|---|---|
| **①** | **长按手势不认鼠标** | `_kLongPressSelectionDevices = {touch, stylus, invertedStylus}`（**不含 `mouse`**）· `selectable_region.dart:43` | Chrome / Windows 桌面用**鼠标长按不产生任何选择** → 没有选择就没有工具栏 |
| **②** | **web 上不显示 Flutter 工具栏** | `if (_webContextMenuEnabled) { return false; }`（`selectable_region.dart:1362`）· 注释原文：「Web is using native dom elements to enable clipboard functionality…」 | 即使选中了，web 上也**改用浏览器原生右键菜单**，`contextMenuBuilder` 根本不被调用 |

`_webContextMenuEnabled = kIsWeb && BrowserContextMenu.enabled && platform ∉ {android, iOS}`

→ **在 Chrome 上，这两层任一层都足以让功能"看起来没实现"。**

### 12.2 🔴 更关键的约束：**Windows 上无法构建 iOS**

所以白哥**没有**「iOS 模拟器」这个选项（iOS 构建需要 Xcode/macOS）。

| 验证路径 | 可行性 | 说明 |
|---|---|---|
| **Chrome + 设备模拟模式** | ✅ **最快** | DevTools **Ctrl+Shift+M** 切到手机型号 → 发**触摸事件** → 绕过第 ① 层。**需要第 ② 层的开关**（见 §12.3，已加） |
| **Android 模拟器** | ⚠️ 需先建 AVD | SDK 在（`android-34/35/36` + system-image），但 **`emulator -list-avds` 输出为空** → 从未创建过虚拟设备 |
| **iPhone 真机** | ✅ **最终以此为准** | 产品只做 iOS；⚠️ Windows 上连真机调试也要装 iTunes 驱动链 |
| Windows 桌面 | ❌ | 桌面平台**双击不显示 overlay**（SDK：`case macOS/linux/windows: // not shown on desktop on a double click`）→ 拖动选择才有戏，且无触摸长按 |
| web + 改代码关浏览器菜单 | ✅ 已做成 debug-only | 见 §12.3 |

### 12.3 ✅ 已加：仅 debug · 仅 web 的验证开关

`app/lib/main.dart`：

```dart
if (kDebugMode && kIsWeb) {
  await BrowserContextMenu.disableContextMenu();
}
```

- **解掉第 ② 层** → web 上 `_webContextMenuEnabled` 变假 → Flutter 会显示自己的工具栏
- **严格限定 `kDebugMode`** → release 不受影响（产品只做 iOS，web 仅开发预览）
- ⚠️ 代价：debug 时 web 上失去「复制到剪贴板」等原生能力 —— 开发期可接受
- ⚠️ **第 ① 层无法用代码解**（mouse 不在长按设备白名单里）→ **必须配合 Chrome 设备模拟模式**

**验证步骤**：
```bash
flutter run -d chrome
# → 按 Ctrl+Shift+M 打开设备模拟（切任一手机型号）
# → 长按正文里的词 → 应弹「查词」工具栏
# ⚠️ 不切设备模拟模式，鼠标长按依然无反应（第 ① 层）
```

### 12.4 顺带修正的实现问题（我自己的，如实记录）

排查过程中我一度把「读选中文本」改成 `state.getSelectedContent()` —— **那是错的**：
`getSelectedContent()` 属于 **`StaticSelectionContainerDelegate`**，不是 `SelectableRegionState`
（analyzer 直接报 `undefined_method`）。**已改回 `onSelectionChanged` 暂存**。

同时**核实了时序**（这次是查源码，不是猜）：

```dart
void _handleTouchLongPressEnd(LongPressStartDetails details) {   // 长按路径
  _finalizeSelection();
  _updateSelectedContentIfNeeded();   // ← 触发 onSelectionChanged → _picked 赋值
  _finalizeSelectableRegionStatus();
  _showToolbar();                     // ← 工具栏最后才显示（下一帧才 build）
}
```

→ **回调先于工具栏构建**，所以 `_picked` 在 toolbar 读取时一定有值 ✅
（鼠标路径顺序相反，但那条路不用于触摸长按选词。）

⚠️ 过程中还犯了两个操作错误（已修）：
1. **Python 脚本 assert 失败 → 整个文件未写入**（脚本是「先全改、最后 write」）→ 导致我误判「第一处已生效」，实际文件保持原状 → **当文件处于"半改"状态时，必须先 `Read` 核实再继续**
2. 改动把 `static const` 留在了 widget 类里，而 State **访问不到** widget 类的私有 static 成员 → 移到 State 类

### 12.5 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（回到基线；过程中一度 error=8） |
| `query_verify` 六脚本 | ✅ **6 / 22 / 31 / 42 / 37 / 49** |
| `tokens_verify` / `trace_verify` | ✅ **304 / 97** |

### 12.6 ⚠️ 结论

**这次不是 bug，是「在错误的平台上验证触摸交互」。**
白哥在 Chrome 上看到的现象（鼠标长按无反应）是 SDK 的**预期行为**，
但**掩盖了代码是否正确的疑问** —— 所以在 chrome 上验证前必须先满足两个条件
（设备模拟模式 + 关浏览器菜单），或直接用 Android 模拟器 / iPhone 真机。

---

## 十三、🔴 补充：`Ctrl+Shift+M` 弹出的是 Chrome 账号登录 → 那是**浏览器快捷键抢走了**（2026-09-27 15:24）

> 白哥反馈：「ctrl+shift+M弹出的是chrome账号登录」

### 13.1 原因

`Ctrl+Shift+M` 是 **Chrome 浏览器级的「切换用户资料」快捷键**。
DevTools **没打开**（或打开但没获得焦点）时，浏览器先把它吃掉 → 弹出账号登录，
**根本到不了 DevTools**。

→ **不是我们的代码问题，也不是设备模拟不可用，是打开方式被抢了快捷键。**

### 13.2 ✅ 两条不冲突的打开路径（任选）

| # | 操作 | 说明 |
|---|---|---|
| **①** | `F12` 打开 DevTools → **点左上角的手机/平板图标**（Toggle device toolbar） | 🔑 **最稳**，不依赖任何快捷键 |
| **②** | `F12` → **`Ctrl+Shift+P`**（命令面板，不与浏览器冲突）→ 输入 `device` → 选「Show Device Toolbar」 | 键盘流，`Ctrl+Shift+P` 是 DevTools 自己的 |

（截图位置：图标在 DevTools 顶栏左侧，「Select an element」箭头按钮的**右边**。）

### 13.3 ✅ 技术前提已核实：设备模拟**确实能绕过第一层**

web 引擎源码（`bin/cache/flutter_web_sdk/lib/_engine/engine/pointer_binding.dart`）：

```dart
ui.PointerDeviceKind _pointerTypeToDeviceKind(String pointerType) {
  return switch (pointerType) {
    'mouse' => ui.PointerDeviceKind.mouse,
    'pen'   => ui.PointerDeviceKind.stylus,
    'touch' => ui.PointerDeviceKind.touch,   // ← 设备模拟模式下浏览器派发的就是 'touch'
    _       => ui.PointerDeviceKind.unknown,
  };
}
```

设备模拟模式（CDP `Emulation.setTouchEmulationEnabled`）下达的 `PointerEvent.pointerType` 是 `'touch'`
→ Flutter 认成 `PointerDeviceKind.touch` → 落入长按白名单 ✅

→ **两层都能解**：`main.dart` 里那行 debug-only 开关解第 ② 层，设备模拟解第 ① 层。

### 13.4 🆕 已备好更可靠的路径：**Android 模拟器**（环境实测齐备）

排查中发现这台机器的 Android 环境**其实只差建 AVD**：

| 项 | 实测 |
|---|---|
| 加速器 | ✅ `WHPX(10.0.26200) is installed and usable` |
| system-image | ✅ `system-images;android-36.1;google_apis_playstore;x86_64` |
| licenses | ✅ 已接受（`android-sdk-license` 等 6 个） |
| JDK | ✅ Android Studio JBR 21（`D:/Android Studio\jbr`）· `java` 21 在 PATH |
| `local.properties` | ✅ SDK 路径正确 |
| **AVD** | ✅ **本轮已创建**：`coeo_phone`（medium_phone · android-36.1）<br>位置 `D:/Users/Lenovo/AppDataLinks/Android/.android/avd/` |

**命令**（在 `app/` 下）：

```bash
# 1) 启动模拟器（首次启动约 1-2 分钟）
D:/Users/Lenovo/AppDataLinks/Android/... # 直接用 Android Studio 的 Device Manager 更简单
# 或用命令行：
C:/Users/Lenovo/AppData/Local/Android/Sdk/emulator/emulator.exe -avd coeo_phone

# 2) 运行（首次会走 Gradle 构建，可能 10-30 分钟）
D:/flutter/bin/flutter.bat run -d android
```

⚠️ **成本提示**：`flutter run -d android` 首次会下载 Gradle 与依赖，耗时较长；
但这是 **Windows 上唯一能产生真触摸事件的路径**（iOS 构建需要 macOS）。
一旦建好，以后验证触摸交互都是秒级。

**推荐用法**：日常用 **Chrome + 设备模拟**（快），
涉及**触摸手势/长按/选择器**的验证用 **Android 模拟器**（真事件）。

### 13.5 🔑 顺带修掉一个我埋的隐患：`_picked` 的时序依赖

`contextMenuBuilder` 返回的组件活在 **overlay** 里 —— 它的重建**不由本 State 的 `setState` 驱动**。
原先用普通字段 `String? _picked`，就变成「正确性押在 SDK 的调用顺序上」：

| 路径 | SDK 内部顺序 | 结论 |
|---|---|---|
| 长按 `_handleTouchLongPressEnd` | `_updateSelectedContentIfNeeded()`（触发回调）→ **再** `_showToolbar()` | ✅ 顺序有利 |
| 鼠标拖动 `_startNewMouseSelectionGesture` | 顺序**相反** | ❌ 顺序不利 → 工具栏可能永远空白 |

→ 改为 **`ValueNotifier<String?> _picked` + `ValueListenableBuilder`** 包住工具栏：
工具栏**订阅**文本变化，**两条路径都不依赖顺序**。代价只有一行 `dispose()`。

> 🔑 **通用教训：「我验证了当前时序是安全的」不等于「这里没有时序耦合」。**
> 前者把正确性押在**别人可以改的实现顺序**上；解除耦合（改成订阅/回调用）才是一劳永逸。
> 「验证过」只能证明**此刻成立**，不能证明**设计上无依赖**。

⚠️ 顺带修了一处 Dart 语法风险：`builder: (_, text, _)` 里的**重复 `_` 在 Dart 3.7 之前是重名参数**
（`The name '_' is already defined`）→ 改为 `(_, text, __)`。

### 13.6 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（回到基线） |

---

## 十四、✅ 去掉「查词」中间步骤：长按即弹浮层（白哥 2026-09-27 15:37）

> 白哥原话：「正确弹出了，但是中间那个点『查词』是多余的，直接弹出底部浮窗就可以了」

### 14.1 改动

| 项 | 改前 | 改后 |
|---|---|---|
| 交互 | 长按 → 弹「查词」按钮 → **点它** → 弹浮层（3 步） | 长按 → **直接**弹浮层（1 步） |
| `_LookupToolbar` 类 | 45 行（含 `Material`/`InkWell`/图标/文字） | 🔴 **整个删除** |
| 选中文本载体 | `ValueNotifier<String?>` + `ValueListenableBuilder`（供 toolbar 订阅） | `Timer?`（防抖）+ 局部变量 |
| `contextMenuBuilder` | 返回自定义工具栏 | **`SizedBox.shrink()`**（抑制系统默认工具栏） |
| `reader_screen.dart` | 521 行 | **501 行**（净 −20） |

### 14.2 🔴 核实过的关键前提：**拖动时会反复触发**（这决定防抖是否必需）

我原先只在注释里「断言」过这一点 —— 本轮去 SDK 源码**验证**了：

```dart
// selectable_region.dart:1014
void _handleTouchLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
  ...
  _updateSelectedContentIfNeeded();   // ← 手指每移动一次都调 → 触发 onSelectionChanged
}
void _handleTouchLongPressEnd(LongPressEndDetails details) {
  ...
  _updateSelectedContentIfNeeded();   // ← 抬起时也调
}
// 而 → _updateSelectedContentIfNeeded() 内部：
//   widget.onSelectionChanged!.call(_lastSelectedContent);
```

→ **直接查库的后果**：一次「长按 + 拖动微调」会打**十几次 SQLite 查询**、
并弹出**十几个浮层**（一个叠一个）。

→ ∴ 加了 **300ms 防抖**。取值理由：人手拖动是**连续移动**（间隔 <100ms），
而「停下来看结果」的停顿远超 300ms —— 能合并成一次，又不会让用户等得可感。

> 🔑 **这不是性能优化，是正确性** —— 少了它功能是错的，不是慢的。

### 14.3 🔴 我第一版写错了，被实测否掉：**「剥首尾标点」会破坏真实词条**

第一版我写了个「输入清洗」正则剥离首尾非字母数字（想解决 `vertical,` 查不到）。**然后去查了词库**：

| 词库真实词条 | 剥首尾标点后 | 后果 |
|---|---|---|
| **`a.m.`** · **`dr.`** | `a.m` · `dr` | 🔴 **反而查不到**（原词条**就带句点**） |
| **`café`** · `cybercafé` · `français` | ~~`caf`~~（若用 `[^A-Za-z0-9]`） | 🔴 **把词毁掉**（非 ASCII 字母被当标点） |

实测数据：词库 11,523 词中 —— 含**内部**标点的 **64 个**（`e-mail` · `brother-in-law` ·
`driver's license` …）· 含**非 ASCII 字母**的 **3 个** · 首尾已有标点的 **0 个**。

→ **「剥标点」这个动作需要知道词库里有什么** —— 那是**查询层**的信息，UI 层没有。

🔑 **结论（分层）**：**UI 层只做「去空白」**这一件无争议的事；
标点/大小写等**宽松匹配属查询层**（它才知道精确命中是否失败、该不该再试一次）。

### 14.4 ⚠️ 已知边界（**未修，已记录**）

长按后**拖动手柄**会把相邻标点带进来（`vertical,`）→ 当前会提示
「词库里没有『vertical,』」。

**修法**：查询层加**「精确 → 剥标点」两段查**（属 `WordQueryService.lookup` 的改动，
要同步 `verify_word_query`）→ **不在本轮**。

📌 **主路径不受影响**：长按**默认选中的就是一个词**（Flutter 的 word boundary 不含标点）。

### 14.5 一处「上下文来源」的细节

`SelectedContent`（`onSelectionChanged` 的参数类型）由 **`package:flutter/rendering.dart`** 导出，
**不在** `material.dart` / `widgets.dart` 的导出链里（首跑报 `undefined_class`）。
→ 用 `import 'package:flutter/rendering.dart' show SelectedContent;`
（`show` 只引入这一个符号，不拖整个 rendering 命名空间进来）。

⚠️ 与 `main.dart` 里 web 的 `BrowserContextMenu.disableContextMenu()` 是**两个不同层**，
不能相互替代：
| 层 | 谁负责 | 关掉什么 |
|---|---|---|
| **浏览器原生菜单** | `main.dart`（debug + web） | 右键/长按时的 **Chrome 自带**菜单 |
| **Flutter 工具栏** | `contextMenuBuilder: (_, __) => SizedBox.shrink()` | Flutter 自己的「复制/全选/查找」 |

### 14.6 ✅ 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7**（回到基线） |
| `query_verify` 六脚本 | ✅ **6 / 22 / 31 / 42 / 37 / 49** |
| `tokens_verify` / `trace_verify` | ✅ **304 / 97** |
| 残留引用 | ✅ `_LookupToolbar` · `ValueNotifier` · `_picked` **均 0 命中** |

⏳ **请白哥目视**：长按正文里的词 → **应立即弹浮层**（不再有中间按钮）；
且**不应**出现「复制/全选/查找」的系统工具栏。
