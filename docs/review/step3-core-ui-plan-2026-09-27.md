# Step 3 核心界面重写 · 实施规划

> 日期：2026-09-27 11:20（**§九/§十 为后续执行记录**）
> 触发：白哥选「进 Step 3 核心界面」→ 按铁律**先出规划报告，不上代码**
> 状态：✅ **规划已批准并执行中** —— §一~§七 是**当时的规划原文**（保留不删，便于回溯决策依据）；
> 执行结果见 **§九（3.0 清退）** 与 **§十（3.1 导航 + 首页 + tabbar）**
> 依据：`docs/design/visual-feed-bookmark-2026-09-25.html`（信息流目标态 · 本轮新读）
> · `docs/design/visual-word-card-target-2026-09-26.html`（词卡目标态 · L1 锚点）
> · `docs/design/design-system-spec-2026-09-25.md`（视觉单一事实源）
> · `docs/plan-and-progress-2026-09-26.md` §四（Step 3 定义）

---

## 一、目标态（从设计稿逐字提取，非我推测）

### 1.1 信息流卡片 = **只有 4 个元素**

设计稿原文：「去掉「N 个生词」和「已读/未读」之后，卡片上只剩四个元素：
**分类·时长 / 标题 / 摘要 / 收藏**」

| 元素 | 示例（设计稿原文） |
|---|---|
| 分类 · 时长 | `Science · 4 min` |
| 标题 | `A New Way to Grow Food in Cities` |
| 摘要 | `In the middle of Singapore, a tall glass building produces more than 800 tons...` |
| 收藏书签 | 右上角；**未收藏 = 凹陷的空书签**，点击 → **实心 + 强调色底** |

### 1.2 🔴 导航是「**阅读 / 复习 / 我的**」——不是当前的「学习 / 复习 / 成就」

设计稿每屏的 tabbar 都是：`阅读` · `复习` · `我的`

**当前代码**（`app/lib/app.dart:134-147`）：`学习`（`Icons.school`）· `复习` · `成就`（`Icons.emoji_events`）

→ **三个 tab 的名字与图标全要改**。「成就」页（999 行 `_k12Progress`）在新导航里**没有位置**。

### 1.3 信息流标题栏

`今日精选` + 右侧 `收藏 12`（**入口 + 计数**）

> 设计稿原文：「收藏是**信息流的一个视图**，不是独立的一级入口。所以导航维持 3 tab 不变，
> 信息流本身也还是一整条流 —— 只是标题栏右侧多了个「收藏 N」的入口」

### 1.4 收藏清单（**不新建界面**）

> 原文：「不做新的列表样式。**同一套卡片组件，只是数据源筛选过**」「**没有新界面要设计**」
> 空状态：**粘土凹陷圆环 + 用真实图标做引导**（教用户「书签在哪」，而不是只说「没有内容」）

### 1.5 阅读界面

| 元素 | 规格 |
|---|---|
| 顶部栏 | **只有三个**：返回 / 分类 / 书签（原文：「书签是**动作**不是显示元素」） |
| 来源行 | `Science · VOA Learning English` |
| 标题 | 同卡片标题 |
| 正文 | **带痕迹**（`tk-n` / `tk-m` / `tk-d` 三态） |

### 1.6 收藏反馈

轻提示 toast：「已收藏 · 可在「收藏」里重读」，**1.5 秒消失**（原文：「不做常驻标签」）

### 1.7 数据层（设计稿已给 DDL）

```sql
-- 端侧 user.db
CREATE TABLE bookmark (
  content_id   INTEGER PRIMARY KEY,      -- 一篇文章只收藏一次
  bookmarked_at TEXT DEFAULT (datetime('now')),
  pending_push INTEGER DEFAULT 1
);
CREATE INDEX idx_bm_time ON bookmark (bookmarked_at DESC);
```

设计稿 5 条要点：① `content_id` 直接当主键 ② 时间戳 DESC（「我刚存了什么」的直觉）
③ 跟着已有同步机制（`pending_push` + 增量 pull/push），**不需要新接口**
④ 取消收藏 = `DELETE`（收藏是可再生意图，与「生词本不能硬删」不同）
⑤ 收藏数不单独存，`SELECT COUNT(*)` 即可

### 1.8 明确「不做」的两项（设计稿已定）

| 项 | 设计稿原文 |
|---|---|
| 「N 个生词」统计 | 连同 `cefr_band_counts` / `user_article_stats` 两张表设计**一并作废** |
| 「该重读了」提示 | **建议先不做** —— 「再加一层系统催prompt会让收藏变成一个待办清单，压力就来了」 |

### 1.9 🔑 一条设计理由（解释了为什么痕迹必须做）

> 「数字会和「**痕迹**」抢角色。去掉数字之后，**痕迹成了唯一的进度表达**：你在文章里看到的淡色词，
> 就是你和这篇文章的关系。**一个概念，一个表达**」

→ **痕迹（`TraceTokens`）从「可选装饰」升级为「阅读界面的核心信息载体」**。
目前 **tokens 层已就绪、渲染层零实现** —— 这是 Step 3 里优先级最高的一块。

---

## 二、现状差距（逐层实测）

| 层 | 现状 | 差距 |
|---|---|---|
| **导航** | 学习 / 复习 / 成就 | 🔴 需改「阅读 / 复习 / 我的」 |
| **信息流** | 🔴 **不存在**（前端 `grep rss/feed/article` 命中全是 `feedback`/`Particle`，**零真实代码**） | 从零建 |
| **阅读器** | 🔴 **不存在** | 从零建 |
| **划词** | 🔴 **无能力**（记忆：0 命中） | 从零建 |
| **痕迹渲染** | 🔴 **零实现** | 从零建 |
| **词卡** | `review_card_widget` 846 行（K12 时代） | 整体重写 |
| **收藏** | 🔴 `user.db` 只有 2 表（`card_review_state` / `review_log`）→ **无 `bookmark`** | 新建表 |
| **后端 feed** | 🔴 无任何 RSS/feed 路由（`routes.rs` 里 `feed` 命中全是 `feedback`） | 从零建 |
| **服务层** | ✅ `word_query_service` 491 · `review_list_query` 239 · `fsrs_service` 474 · `tts_service` 299 · `open_with_handler` 184 | **已就绪** |

### 2.1 ✅ 已就绪的底子（**不要重复建**）

| 服务 | 行数 | 对应 Step 3 的哪块 |
|---|---:|---|
| `word_query_service.dart` | 491 | **划词查词**（`query_verify` 79 项验收已过 · p50 43µs Py / 228µs FFI 稳态） |
| `review_list_query.dart` | 239 | **复习页列表** |
| `fsrs_service.dart` | 474 | **复习调度**（`fsrs_verify` 19+39 项已过 · 零 Flutter 依赖） |
| `tts_service.dart` | 299 | **朗读**（词卡 + 文章，全端侧） |
| `open_with_handler.dart` | 184 | **电子书导入**（iOS「用 CoEvo 打开」已实施） |
| `theme/coevo_tokens.dart` | 977 | **三档主题 + 痕迹 + 粘土 + 排版**（验收 307 项） |
| `theme/clay.dart` | ~290 | **粘土组件**（四态 + 真 inset） |

> 🔑 **结论**：Step 3 缺的是**界面层与内容层**，服务/算法/视觉 token **全部就位**。

---

## 三、🔴 本轮发现的三个真问题（非 Step 3 本身，但需一并处置）

### 3.1 🔴 痕迹色「spec 与设计稿冲突」——**冲突已进代码**

| 来源 | 「格」档 `--tk-m-bd`（复习中） |
|---|---|
| `design-system-spec` §1.1 | `1.5px solid rgba(0,192,139,.42)` ← 🔴 **绿** |
| `visual-feed-bookmark` L53（设计稿） | `1.5px solid rgba(196,83,58,.42)` ← **朱砂** |
| **`coevo_tokens.dart`（实测）** | `CoRgba(0, 192, 139, 0.42)` ← 🔴 **照 spec 写的绿** |

**判断**：绿色是**旧「翠绿进化」时代的残留** —— 而现行方案甲已明确「统一色相 = 朱砂」。
朱砂版（设计稿）才符合现行决策。

⚠️ **但这是「文档冲突」，不是「实现错」** —— 按既定分类（skill 铁律五）：
须**先请示改 spec**，再改代码；且**有断言锁住这个值**（【4】痕迹断言），改两处要同步。

**待白哥定**：① 按设计稿改朱砂 ② 保持 spec 的绿（说明理由）。

### 3.2 🔴 前端 2,652 行「零引用死代码」（提前清理可显著降低 Step 3 干扰）

| 文件 | 行数 | 被引用 |
|---|---:|---|
| `screens/curriculum_plans_page.dart` | 836 | **0 处** |
| `screens/debug_logs_page.dart` | 611 | **0 处** |
| `screens/curriculum_cards_page.dart` | 583 | **0 处** |
| `screens/config_page.dart` | 433 | **0 处** |
| `screens/user_detail_screen.dart` | 189 | **0 处** |
| **合计** | **2,652** | — |

✅ **已核实**：`card_list_screen.dart`（904 行）**不是死代码** —— 它被
`review_screen.dart:18` `import` → 属复习流程，会随 3.6 一起重写。

### 3.3 🔴 后端 24,233 行中，有一块可能整体超出产品定位（**仅报告事实，不擅自判死**）

后端 `crates/api_server/src/` 共 **24,233 行**，其中这些模块与既定决策的关系需白哥确认：

| 模块 | 行数 | 与既定决策的关系 |
|---|---:|---|
| `plan_handler.rs` | **1,987** | ⚠️ 记忆：「**不做 plan**」 |
| `curriculum_admin.rs` | **1,726** | ⚠️ 记忆：「**不做 admin**」（app 与 `app_admin` 项目已删） |
| `admin_handlers.rs` | **1,365** | ⚠️ 同上 |
| `distribution_handler.rs` | **2,264** | ❓ 分销体系 —— 定位未明确 |
| `referral_handler.rs` | 1,236 | ✅ **保留**（前端 `home_screen` 有推广码逻辑） |
| `campaign_handler.rs` + `campaign_executor.rs` | **2,089** | ❓ 与 referral 配套？ |

**实测**：`routes.rs` 里有 **99 条 `/api/admin/**` 路由** · `curriculum_admin::` 被引用 **27 处**。

**两条核实到的事实**：
1. `plan_handler.rs` 仍被 `e2e_runner.rs:310`（`build_plan_context`）与 `lib.rs:22`（模块声明）引用
   → **不是孤儿**，删要先处理这两处
2. `curriculum_admin.rs` 提供 **admin 后台的 27 个 handler**，而**后台前端已删**
   → 路由仍在注册（后端不会因此报错），但**没有调用方**

> ⚠️ **我不判它们是死代码** —— admin/plan/分销 的「是否保留」是产品决策，不是技术判断。
> 仅报告规模，供白哥在同一次清退里一并处置（若确认不做，则这是 **≈7,400 行**的清理空间，
> 远大于 K12 的 ≈1,700 行）。

---

## 四、K12 清退的完整牵连图（实测）

### 4.1 后端（Rust）

| 位置 | 内容 | 规模 |
|---|---|---|
| `lib.rs:41-43` | 三行模块声明 | 3 行 |
| `k12_quiz.rs` + `k12_quiz_api.rs` + `k12_quiz_loader.rs` | 模块本体 | **297 行** |
| `routes.rs:154-158` | **5 条路由**注册 | 5 行 |
| `routes.rs:2538-3162` | 5 个 handler 实现（含 1 个测试） | **≈625 行** |
| `curriculum_loader.rs` | `k12_data_dir()` + 加载逻辑（注释：「供 /k12/init 路由直接使用」） | **767 行** |
| `plan_handler.rs:1540` | 调 `k12_quiz::should_mark_task_complete` | 1 处 |
| `curriculum_admin.rs` | `/api/admin/curriculum/**` 一批路由（**27 个 handler**） | **1,726 行** |

### 4.2 前端（Dart）· 7 个文件

| 文件 | k12 命中 | 处置 |
|---|---:|---|
| `config/k12_subjects.dart` | 35 | 🔴 **整文件废弃** |
| `api/chat_client.dart` | 14 | 摘除 K12 方法 |
| `screens/achievements_screen.dart` | 8 | 🔴 **整体废弃**（新导航无「成就」） |
| `screens/home_screen.dart` | 7 | 🔴 **整体重写**（信息流首页） |
| `screens/review_screen.dart` | 1 | 摘除 |
| `widgets/markdown_span_nodes.dart` | 1 | 注释（已核实） |

### 4.3 删除顺序（**顺序错会编不过**）

```
① 前端：删 k12_subjects.dart → 摘 home/achievements/review 的引用
   （这三页本就要重写，所以随重写一起做，不单独删）
② 后端：先删 routes.rs 的 5 条路由 + handler（625 行）
③ 后端：再删 lib.rs 模块声明
④ 后端：删 k12_quiz*.rs（297 行）
⑤ 后端：清 plan_handler.rs:1540 的调用
⑥ 后端：删 curriculum_loader.rs（767 行）—— ⚠️ 需先确认无其它调用方
```

> 🔑 **铁律**：每步后 `cargo check` + 前端 `analyze_inproc`（错误集中在同一文件且表现为
> `undefined_identifier` → 多半是引用没改；若表现为 `expected_executable` → 查括号结构）

---

## 五、分批实施建议（含依赖与可验证点）

> **核心依赖问题**：信息流**要有内容**才有东西显示，而内容来自后端 RSS 抓取（Phase 3）。
> 两条路：**(A) 先做界面 + mock 数据**（能快速看到设计稿的样子）
> 或 **(B) 先做 Phase 3**（界面做完立刻有真数据，但看到界面更晚）。

| 批 | 内容 | 依赖 | 可验证点 | 规模估计 |
|---|---|---|---|---|
| **3.0** | **清退**：2,652 行死代码 + K12 前后端 | — | `cargo check` EXIT=0 · `analyze_inproc` 基线不变 | 删 ≈3,500 行 |
| **3.1** | **导航骨架**：tab 改「阅读/复习/我的」+ 路由调整 | 3.0 | 跑起来点三个 tab 都有页面 | 小 |
| **3.2** | **痕迹渲染层**（`TraceText`）：三态 × 三档 | tokens 已就绪 | 三档主题下三态可辨（spec §八 有验收项） | 中 |
| **3.3** | **信息流卡片 + 书签 + `bookmark` 表** | 3.1 | 卡片四元素齐全 · 点击书签变实心 + toast | 中 |
| **3.4** | **阅读器 + 划词浮层** | 3.2 · 3.3 · `word_query_service` | 划词能查词（**当前 0 能力 → 1**） | **大** |
| **3.5** | **收藏清单 + 空状态** | 3.3 | 复用卡片 · 空状态用粘土环 + 图标引导 | 小 |
| **3.6** | **复习页重写**：去「汉语 tab」· 接 FSRS | 3.1 · `fsrs_service` | 四档按钮显示「下次 X 天」 | **大** |
| **3.7** | **词卡重写**（对齐 L1 界面稿） | 3.6 | 字号层级不反转 · IPA 元素级字体 | **大** |

### 5.1 内容来源的三种做法（**待白哥选**）

| 方案 | 做法 | 优点 | 代价 |
|---|---|---|---|
| **A** | 3.3/3.4 先用**本地 mock JSON**（贴设计稿的三篇示例文） | 最快看到界面 · 与后端解耦 | 之后要接真数据 |
| **B** | 先做 **Phase 3 后端 RSS 抓取** 再做界面 | 界面做完立即有真内容 | 看到界面更晚 |
| **C** | 并行：界面用 mock，同时起后端抓取 | 兼顾 | 需同时管两条线 |

> 🔑 **我的建议：A** —— 理由：① 设计稿已给出**三篇示例文**（Singapore 垂直农场 / Why We Sing Together /
> Why Small Shops Are Coming Back），直接可用 ② 界面验收标准是「长得对不对」，与数据来源无关
> ③ 后端 RSS 有它自己的不确定性（源站结构、频次、版权），**不该阻塞界面**。

---

## 六、风险与未知

| # | 风险 | 说明 |
|---|---|---|
| 1 | **划词是最大未知** | 当前 0 能力。要解决「正文分词 + 命中词表 + 浮层定位 + 长按手势」—— 其中**命中词表**可用 `word_query_service`（已验证），但**正文渲染成可划词的 span** 是新的 |
| 2 | **后端 RSS 抓取的不确定性** | 源站结构、抓取频次、VOA/BBC 条款 —— 属 Phase 3 范围，但**是 Step 3 的内容前提** |
| 3 | **`review_screen` 1,533 行** | 含「英语 tab + 汉语 tab」+ AI 判题 + 对话。要判清哪些能留（判题/对话可能是 v1 的「AI 考核」保留项） |
| 4 | `plan_handler` 与「plan」 | 记忆：「不做 plan」。但 `plan_handler.rs` 存在且被 K12 调用 —— 需判清它是否整体废弃 |
| 5 | `curriculum_admin.rs` | 未核实规模，可能是第二批 K12 清退对象 |

---

## 七、待白哥拍板（4 项）

| # | 事项 | 选项 |
|---|---|---|
| **1** | **痕迹「格」档颜色** | (a) 按设计稿改朱砂 `rgba(196,83,58,.42)` （b) 保持 spec 的绿 |
| **2** | **内容来源** | (A) 界面先用 mock（**建议**）· (B) 先做 Phase 3 · (C) 并行 |
| **3** | **开工范围** | (a) 先做 **3.0 清退**（让代码库干净再重写）· (b) 直接进 3.1 导航 · (c) 先只做 3.2 痕迹渲染层 |
| **4** | **后端 admin / plan / 分销 的去留**（§3.3，≈7,400 行） | (a) 确认不做 → 一并清退 · (b) 保留现状 · (c) 逐模块判 |

---

## 八、一句话总结

**Step 3 缺的是界面层与内容层** —— 服务（查词/复习/FSRS/朗读/电子书）· 视觉 token（三档主题/痕迹/粘土/排版，
验收 307 项）**全部就位**；而**信息流、阅读器、划词、痕迹渲染在前端是零代码，后端也无 feed 接口**。

设计稿把目标态定得很具体（卡片 4 元素 · 导航改「阅读/复习/我的」· 收藏是视图不是 tab ·
数据层一张表 · 「N 个生词」作废），**实现路径清晰**。

两件顺带发现：① **痕迹「格」档颜色 spec（绿）与设计稿（朱砂）冲突，且已进代码** —— 需先定规格；
② **前端 2,652 行零引用死代码** + **后端有一块（≈7,400 行）可能整体超出定位**（admin 99 条路由 ·
plan 1,987 行）—— 清掉能让后续重写少受干扰，**但后者是产品决策不是技术判断，需白哥确认**。

**下一步等你拍板 4 项，我再动手。**

---

## 九、✅ 执行记录（2026-09-27 11:50 · 3.0 清退已完成）

### 白哥 4 项决策

| # | 事项 | 选择 |
|---|---|---|
| 1 | 痕迹「格」档颜色 | ✅ **改朱砂** `rgba(196,83,58,.42)` |
| 2 | 内容来源 | ✅ **先用 mock** |
| 3 | 开工范围 | ✅ **先做 3.0 清退** |
| 4 | 后端 admin·plan | ✅ 确认不做，一并清 → 🔴 **但核实后两处是活代码，未删**（见下） |

### 执行结果

| 批次 | 内容 | 规模 |
|---|---|---|
| ① | 痕迹「格」档颜色（spec + 代码 + 2 断言） | 3 处 |
| ② | 前端 5 个零引用死代码 | **2,652 行** |
| ③ | 后端 K12（routes/main/schema/lib + 4 文件 + 1 测试摘除） | **≈1,293 行** |
| **合计** | | **≈3,940 行** |

**验证**：后端 `cargo check --all-targets` ✅ 零 error/warning（含测试编译）·
前端 `analyze_inproc` ✅ 与基线一致 · `tokens_verify` ✅ **309 项全过**

### 🔴 范围修正：§七 第 4 项批准的范围**实际不能执行**

原估计「plan_handler 1,987 + admin 3,091 ≈ 5,100 行」，核实后：

| 目标 | 核实结论 |
|---|---|
| `plan_handler.rs` 1,987 | 🔴 **活代码** —— `ws.rs:352-353`（chat 流程）用它选 system prompt |
| `admin_handlers.rs` 1,365 | 🔴 **共享工具** —— `verify_admin`/`ok`/`err` 被 4 个保留模块引用 |
| `config_admin` · `plans_handlers` | ⚠️ **混装**（含非 admin 路由） |
| `distribution_handler` 2,264 | ✅ **必须保留**（8 处非 admin 路由，含 `/api/pay/calculate`） |

→ **要清 admin 路由需逐条剥离，属独立一轮**（本报告 §3.3 的规模估算需按此修正）。

### 两个过程教训

1. 🔑 **搜引用图必须覆盖整个 workspace** —— 我漏搜 `backend/src/`（`main.rs:99` 引用
   `k12_quiz_loader`）与 `tests/`，是 **`cargo check` 抓出来的**（「真编译是终判」再次验证）。
2. 🔑 **「按名字定范围」会算错量级** —— `plan`/`admin` 听起来都属于「已定不做」，
   但代码里它们**同时服务着保留中的 chat 流程**。

### 顺带发现（既有问题，非本次引入）

本机 clippy（Rust 1.95）对 `api_server` 报 **48 个 lint 错误**，分布于 **15+ 个未改动文件** ——
改动文件里报错行号与本次改动**不重叠**，均为既有 lint。
⚠️ CI 用默认 stable → **若同为 1.95+，clippy job 会红**（待白哥在 Actions 页面确认）。

### 下一步

`3.1 导航骨架`（tab 改「阅读/复习/我的」+ 路由）→ `3.2 痕迹渲染层` → `3.3 卡片+书签`
（内容先用设计稿的三篇示例文 mock）

---

## 十、✅ 执行记录（2026-09-27 12:00 · 3.1 导航骨架 + 首页信息流骨架）

### 10.1 改动清单

| 文件 | 动作 | 规模 |
|---|---|---|
| `app/lib/app.dart` | 改：3 tab → 「阅读 / 复习 / 我的」（名字 + 图标）· 第 3 分支 `/achievements` → `/mine`（挂 `ProfileScreen`）· **删顶层 `/profile` 路由** | ±30 行 |
| `app/lib/screens/home_screen.dart` | **重写**（K12 科目直选 → 信息流） | 475 → 302 行 |
| `app/lib/widgets/feed_card.dart` | 新增（卡片组件，信息流 + 收藏清单共用） | **84 行** |
| `app/lib/models/feed_item.dart` | 新增（`FeedItem` 领域模型） | **62 行** |
| `app/lib/data/mock_feed.dart` | 新增（设计稿原文三篇 · **临时**） | **43 行** |
| `app/lib/screens/achievements_screen.dart` | **删除**（新导航无「成就」位置） | **−999 行** |
| `app/lib/api/chat_client.dart` | 删 5 个失联方法（`getK12Subjects` / `k12Init` / `getK12Progress` / `getAchievementsAll` / `getPlanAchievements`） | ≈−95 行 |
| `app/lib/screens/review_screen.dart` | 删 2 处 `context.push('/profile')`（个人页已是 tab，入口重复且路由已删） | −6 行 |
| `app/lib/frontend-api-alignment-review.md` | 归档 → `docs/_archive/k12-era/frontend-api-alignment-review-2025-06-05.md` | 移动 |

**净变化**：≈ −1,020 行。

### 10.2 🔴 三个「不是风格问题，是功能已断」的发现

本轮重写首页时核实出的**既有断裂**（**均非本次引入**，是 3.0 清退的后遗症）：

| # | 位置 | 事实 | 本次处置 |
|---|---|---|---|
| 1 | 旧首页「科目直选」 | 调 `/api/k12/subjects` + `/api/k12/init` —— **两个端点已随 3.0 删除**（`routes.rs` 里 `grep k12` = **0 命中**）→ **点击即报错** | ✅ 随首页重写一并移除 |
| 2 | 旧首页「历史对话」入口 | `context.push('/conversations')`，而 `app.dart` **从未注册**该路由 → 命中兜底 `/:unknown` → **静默跳回首页** | ✅ 随首页重写一并移除 |
| 3 | `screens/chat/chat_reading_passage.dart` | 调 `/api/k12/reading/{conv}/current-card` —— **该路由也已删除** → chat 阅读链路**当前必失败** | ⚠️ **只标注、不改**：属 chat 流程，去留待定（见 §10.4） |

> 🔑 **教训复用**：「主题层已生效，但页面层是 K12 遗留」这个判断**还不够** ——
> 更准确的描述是：**页面层调用的后端接口已经不存在了**。
> 所以「界面还是旧的」不是审美问题，是**功能已断**。
> 这也解释了为什么 3.0 清退必须在 Step 3 之前做：**先断接口，才能让残留页面自己暴露出来**。

### 10.3 ⚠️ 3.1 有意留白的项（不是遗漏）

| 项 | 为什么不做 | 归入 |
|---|---|---|
| 「今日精选」右侧的「收藏 N」入口 | 需要 `bookmark` 表 → 现在做只能是个**点了没反应的死入口** | **3.3 / 3.5** |
| 卡片右上角书签 | 同上 | **3.3** |
| ~~底部 tabbar 的**视觉**~~ | ✅ **已补做（见 §10.6）** —— 白哥 2026-09-27 定「按设计稿」→ 自绘粘土药丸 | ✅ 已完成 |

⚠️ 另一处已知不一致：设计稿「格」档写 `--cl-radius: 8px`，而 token「格」档 = **14px**
（Step 2 已定案，理由见 `word-db-schema…` 之外的 `design-system-spec` §3.5.1）→ **按 token 的 14**，设计稿该值属旧稿。

### 10.4 ✅ 白哥三项决策（2026-09-27 12:00）→ ③ 当场落地

| # | 事项 | 白哥决策 | 本轮动作 |
|---|---|---|---|
| 1 | **AI 对话（chat）去留** | 🔵 **保留 —— 是 v1「AI 考核」的预留** | ✅ **不动**（3.7 词卡页给它重新开入口） |
| 2 | **后端成就系统去留** | 🔵 **保留，但「成就要重新规划」** | ✅ 后端**不动**｜🔴 **新开待办：成就体系重新规划**（见 §10.7） |
| 3 | **底部 tabbar 是否按设计稿自绘** | 🔴 **按设计稿** | ✅ **已完成 —— 见 §10.6** |

### 10.5 ✅ 验证

| 项 | 结果 |
|---|---|
| `scripts/analyze_inproc`（`app/lib`） | **error=3 / warning=13 / info=7** —— 与基线**逐项一致**（3 个 error 均为既有 `dart:html`/`dart:js` web-only 导入，与本轮无关） |
| `scripts/tokens_verify` | **309 项全过** · 实现类失败 0 · 规格内部冲突 0 |
| 残留引用扫查 | `grep achievements_screen\|AchievementsScreen app/lib` → **0 命中**（仅剩一份已归档的 md） |
| 真编译 | ⏳ **未跑**（本机沙箱跑不了 `flutter`）→ 请白哥 `flutter run` 目视三 tab + 首页卡片 |

---

### 10.6 ✅ 3.1 补：底部导航自绘粘土药丸（按设计稿）

**动因**：设计稿的 tabbar 选中态是「**强调色填充药丸 + 实体投影**」，
而 M3 `NavigationBar` 的选中表达只是「药丸背景 + 图标变色」、**且未选中项仍有容器色**
—— 形状与材质都对不上，调参数调不出来（`indicatorColor` 只能改颜色）。

**→ 这是 Step 2 之后第一处真正用上 `Clay` 的界面**（此前 `clay.dart` 只接在设置页的档位预览里）。

| 文件 | 动作 | 规模 |
|---|---|---|
| `app/lib/app.dart` | `_ShellScaffold` 的 `NavigationBar` → 自绘 **`_ClayTabBar`**（含逐项对齐表与理由） | **+128 行**（`app.dart` → **448 行**） |
| `app/lib/theme/theme_builder.dart` | `navigationBarTheme` **保留** + 注释说明「当前无组件在用，是兜底」（见下） | +5 行注释 |
| `app/lib/screens/home_screen.dart` | 注释同步（`NavigationBar` → `_ClayTabBar`） | 1 行 |

**逐项对齐设计稿**（`.tabbar` / `.tb` / `.tb.on` / `.tb .ic`）

| 设计稿 | 值 | 实现 |
|---|---|---|
| `.tabbar` padding | `12px 20px 24px` | 上 12 · 左右 20 · 下 **`SafeArea(minimum:24)`**（有 home indicator 时取更大者） |
| `.tabbar` gap | `9px` | 9 |
| `.tb` padding / 圆角 | `8px 0 7px` / **`17px`** | 同（圆角**显式覆盖** token 档位值） |
| `.tb` 未选中 | **只有 `color:ink3`，无背景无阴影** | 普通 `Padding`（**不用 `Clay`**） |
| `.tb.on` | `background:accent` + `color:accentInk` + 投影 | `Clay(state: selected)` → 自动取 `accent` / `accentInk` / `accentOut` |
| `.tb .ic` | `15×15` · `opacity:.75`（选中 → 1） | 同 |

#### 🔴 三个必须写下来的实现判断

1. **未选中项不能用 `Clay`** —— 粘土的「抬起」态**必然**画填充 + 外阴影，
   而设计稿里未选中项是**完全平的**（`.tb` 只有 `color`）。硬套会凭空多出三个灰底药丸。
2. **圆角显式取 17，不走 token 档位** —— 设计稿 `.tb` 的 `border-radius:17px`
   **写死在组件上、不在主题变量里**（三档共用 17）→ 显式传 `borderRadius` 覆盖
   `clay.radiusFor()`（那会得到「墨 14.3 / 格 14 / 夜 13.2」）。
   🔑 **这是三档里唯一「圆角不随主题变」的元素** —— 照设计稿。
   几何仍成立：md 档内阴影偏移 3 × 3 = 9 ≤ 17 ✅（§3.4 约束）
3. **选中态 inset 取 token，而非设计稿的硬编码值** —— 设计稿 `.tb.on` 把内阴影写死成
   `rgba(0,0,0,.15)` / `rgba(255,255,255,.26)`；spec §3.3.1 明文「两者共用」→ **按 spec**。

#### ⚠️ 一处「有意的保留」，不是遗留

`theme_builder.dart` 的 `navigationBarTheme` 现在**没有组件在用**，但**刻意不删**：
任何页面若引入 M3 `NavigationBar`（如二级 tab），颜色不会**静默回落成 Material 默认紫**。
「写了但没接上」与「静默降级」都是本项目反复踩的坑 —— 留一份正确兜底比删掉更安全。

#### ⚠️ 待实机确认（**不自作主张，如实记录**）

设计稿**没有定义**未选中项的**按下反馈** → 本实现也不自行添加
（保持「无背景 = 无物理形态 = 无回弹」的自洽）。
🔴 实机若觉得点击「没反应」，**再讨论**要不要补一个轻微反馈 —— 不默默加。

### 10.7 🔴 新开待办：**成就体系重新规划**（白哥 2026-09-27 定）

> 白哥原话：「后端成就系统留着吧，**不过成就要重新规划**」

**现状**（§10.1 + 10.4 核实）：

| 层 | 状态 |
|---|---|
| 前端 | 🔴 **入口已全部移除**（`achievements_screen.dart` 999 行删除 + 2 个客户端方法删除） |
| 后端 | 🟢 **完整保留**：`achievements` 表 · `achievements_all_handler` · `plan_achievements_handler` · **chat 流程内嵌的 `engine.check_and_persist`** |

**→ 两边现在是断开的**：后端仍在按 `engine.check_and_persist` 写成就记录，但前端没有任何地方能看见它。

🔴 **重新规划时必须一并决定**：
1. 成就**挂在什么行为上**（旧版挂 K12 进度 —— 那套已不存在）
2. **在 3 tab 里放哪**（设计稿定的是「阅读 / 复习 / 我的」→ 最可能是「我的」页内的一块，**不是一级 tab**）
3. 要不要**沿用后端现有的 `achievements` 表结构**（现存数据量需先查）
4. `plan_achievements` 与记忆里「**不做 plan**」的关系

⚠️ **不阻塞任何后续批次** —— 后端不动、前端无入口，现状是「静默休眠」。

### 10.8 下一步

`3.2 痕迹渲染层`（`TraceText`：三态 × 三档 · tokens 已就绪、渲染零实现）
→ `3.3 卡片书签 + bookmark 表` → `3.4 阅读器 + 划词`（**最大未知**）
→ `3.7 词卡` 时给 chat（**v1「AI 考核」预留**）重新开入口

---

## 十一、🔴🔴 产品原则：**除生词表上限外，不验证登录态**（2026-09-27 白哥定）

> 白哥原话：「**首先我们的功能除了生词表限制以外不验证用户登录状态，所以你的方案不对**」

### 11.1 原则（架构约束，越出本轮范围）

**读文章是免费能力，不需要登录。** 判定用户身份**只发生在「生词本是否超 200 词上限」那一刻**。

| 能力 | 要不要登录 |
|---|---|
| 读信息流 / 打开文章 / 划词查词 / 词卡朗读 / 复习 | ❌ **不需要** |
| 生词本**新增**（超 200 词上限时） | ✅ **只有这里**需要 |

→ 推论：**任何「内容渲染」都不得被登录态阻塞**。
登录态是**能力限制开关**，不是**内容可见性开关**。

### 11.2 违反该原则的实例（已修）

白哥报「**首页没有卡片，按钮正常**」→ 我第一版方案把它当成「未登录阻塞首屏」去修（加三态 + 重试）→ **方向错**。
白哥纠正后重新核实，**全库只有一处**违反：

| 位置 | 性质 |
|---|---|
| `app.dart:302` 订阅检查 | ✅ 订阅确实需要登录 |
| `profile_screen.dart:65` 「我的」页刷新 | ✅ 个人页确实需要登录 |
| `chat_screen.dart:96` chat 等 auth | ✅ chat 需要用户身份 |
| 🔴 `home_screen.dart` 首屏 `if (!_authReady) return <转圈>` | ❌ **唯一把登录态当「内容前置条件」的地方** |

**完整缺陷链**：

```
干净浏览器状态（新 profile / 换端口 → localStorage 不共享）
  → hasUsedTrial() = false
  → POST http://localhost:8080/api/trial/start     ← flutter run 默认连 localhost（后端在 VPS）
  → 本地无后端 → 请求失败
  → auth_client 抛异常 → AuthNotifier 内部 catch（只写 state.error，**不打日志**）
  → state.isAuthenticated 仍 false
  → home_screen `if (auth2.isAuthenticated && mounted)` 整块被跳过
  → _authReady 永远 false → **首页永久转圈**：无提示、无重试入口
```

**为什么表现为「按钮正常，首页没卡片」**：
loading 在**内层 Scaffold**，tabbar 在**外层 `_ShellScaffold`** → 两者独立渲染。

### 11.3 修复（`home_screen.dart` · 只删不加）

| 动作 | 说明 |
|---|---|
| 删 `bool _authReady` + 整个 loading 分支（~34 行） | 信息流**无条件渲染** |
| `_initAuth` 里 3 处 `setState(_authReady = true)` + `.then` 里 1 处 | 一并删除 |
| `_initAuth` **保留原逻辑**，但降级为 `addPostFrameCallback` 的**后台副作用** | 成功照旧创建试用 / 弹注册引导；**失败静默** |
| 🔒 补 `_authRestoreTries` 上限（20 次 ≈ 6s） | 原「等 auth 恢复」是**无界递归**（每 300ms 调自己一次），改为后台副作用后虽不阻塞 UI，但仍会一直空转 → 必须封顶 |

### 11.4 🔑 教训（可复用）

1. **不要把「易失败的外部依赖」（网络 / 身份）放在「内容渲染」的前置条件上** ——
   那等于让内容可用性绑定在一个与内容无关的开关上；开关失败 → 内容整体消失。
2. **「静默失败 + 无出口」比「报错」更糟** ——
   `trialStart` 的 catch 只写 `state.error` 却**不打日志**，`_initAuth` 的失败路径**无任何提示或重试**。
   两处叠加 → 用户只能看到「没有卡片」，连一个可以报告的线索都没有。
3. **反过来也成立**：白哥的产品原则先于技术方案 ——
   我第一版方案（「加三态 + 重试」）在技术上没错，但它**默认了「未登录」是合法状态**，
   而正确前提是「**未登录根本不该影响读**」。**方案要建立在产品原则上，不是技术自洽上。**

### 11.5 ✅ 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc`（`app/lib`） | ✅ **error=3 / warning=13 / info=7** —— 与基线**逐项一致** |
| `_authReady` 残留 | ✅ 代码中 **0 处**（仅注释里记录历史） |
| `home_screen.dart` | 302 → **265 行** |
| 真编译 | ⏳ 本机沙箱跑不了 → 请白哥 `flutter run` 确认首页直接出卡片 |

### 11.6 🔴 遗留隐患（**未改，仅标注**）

`AuthNotifier.trialStart` 的 catch **只设 `state.error`，不打印日志、不上报** ——
这使「试用创建失败」在生产上**完全不可观测**。
建议后续补一行 `debugPrint`（属 `auth_provider.dart`，不在本轮范围）。

### 11.7 下一步

`3.2 痕迹渲染层` → `3.3 卡片书签 + bookmark 表` → `3.4 阅读器 + 划词`（**最大未知**）

---

## 十二、✅ 补静默失败日志（白哥批准）+ 🔴 新发现待批

### 12.1 ✅ 已实施：认证模块 5 处「静默失败」补日志

白哥批准「补一行 `debugPrint`」→ 实际扫查后发现**同性质的静默失败共 5 处**，
按同一原则一并补齐（`app/lib/providers/auth_provider.dart`）：

| 方法 | 原状态 | 现状态 |
|---|---|---|
| `trialStart` | 🔴 **完全静默** —— 且这是「首页转圈」的源头 | ✅ 带端点 + refCode |
| `register` | 🔴 只写 `state.error`（UI 可见，但控制台无线索） | ✅ 带端点 + username |
| `login` | 🔴 同上 | ✅ 同上 |
| `trialClaim` | 🔴 同上 | ✅ 带端点 + userId + username |
| `logout`（清 display_name） | 🔴 `catch (_) {}` **空吞** | ✅ 补一行（不影响登出结果） |

**已具备日志的**（无需改）：`tryRestore` · `_saveCredentials` · `_clearCredentials` ·
`_clearTrialStorageFlags` · `_setTrialUsedFlag` · `hasUsedTrial`。

#### 🔑 日志**必须带端点**（`endpoint=${ApiConfig.baseUrl}`）

这是本次最有价值的一处设计 —— **本次故障的根因就是「连错地址」**
（`flutter run` 默认 `localhost:8080`，后端在 VPS）。
日志若只有 `SocketException: Connection refused`，**必须靠猜**；
带上端点后一眼可见：

```
trialStart 失败 endpoint=http://localhost:8080 refCode=null campaignId=null error=...
                                  ^^^^^^^^^^^^^^^^^^^^^ ← 立刻定位
```

### 12.2 🔴 新发现（**未改，待白哥批**）：`auth_client` 4 个方法缺 `.timeout()`

#### 调查

| 文件 | 请求处 | 带 `timeout` |
|---|---:|---:|
| `chat_client.dart` | ≈30 | **24** → ✅ **「加 timeout」是本项目惯例** |
| `auth_client.dart` | 5 | **1**（仅 `verifyToken`） |

缺失的 4 个：`register` · `login` · `trialStart` · `trialClaim`。
`ApiConfig.requestTimeout`（10s）早已定义，它们只是**没用**。

#### 影响范围与后果（**准确表述，不夸大**）

- ⚠️ **本次「转圈」不是它造成的** —— 连 `localhost:8080` 无监听 → **立即** `ECONNREFUSED`。
- 🔴 它影响的是**另一种场景**：目标 IP **可达但无响应**（防火墙 DROP / 网络黑洞 / 服务假死）。
  此时 Flutter Web 的 `http` 用浏览器 XHR/fetch，**浏览器默认超时极长**（Chrome 约 300s）
  → 用户点「登录」后**最长可等数分钟无反馈**（无 spinner 之外的任何提示）。
- 对 `trialStart`：改造成后台副作用后**不再阻塞首页**，但仍会长时间占用 `_authInitBusy`。

#### 修复方案

| 方案 | 做法 | 代价 |
|---|---|---|
| **A（建议）** | 4 处统一加 `.timeout(ApiConfig.requestTimeout)`（10s）—— **与 `chat_client` 惯例一致** | 4 行 |
| **B** | A + 区分错误类型（超时 / 拒连 / 4xx / 5xx），给用户不同提示文案 | ~20 行，需定文案 |

> 🔑 **建议 A** —— 理由：① 与既有惯例对齐，无新概念 ② 超时本身已是巨大改善（300s → 10s）
> ③ 分文案属「体验优化」，可另开一轮，不必与健壮性修复捆绑。

### 12.3 ⚠️ 顺带记录（**有意的设计，非缺陷**）

`auth_client.verifyToken` 网络错误时 `return {'valid': true}`（注释：`Be lenient on network errors`）
—— **断网时会把无效 token 当有效**。
这是**有意的宽容**（避免「一断网就被登出」），但副作用是：
若服务端已吊销 token，客户端在离线期间仍会认为自己已登录。
🔵 记录备查，**不建议改**（改动会引入「断网即登出」这一更差体验）。

### 12.4 ✅ 验证

| 项 | 结果 |
|---|---|
| `analyze_inproc`（`app/lib`） | ✅ **error=3 / warning=13 / info=7** —— 与基线**逐项一致** |
| 结构完整性 | ✅ 逐方法核对：5 处新日志到位，`_setTrialUsedFlag` 文档注释完好（编辑时一度误删，已复原文并复核） |
| 真编译 | ⏳ 本机沙箱跑不了 → 请白哥 `flutter run` 观察控制台 |

### 12.5 下一步

**待白哥定 §12.2**（A / B / 暂不改）→ 然后进 `3.2 痕迹渲染层`

---

## 十三、✅ 方案 A 实施：`auth_client` 全部请求补 `.timeout()`（白哥批准）

### 13.1 ✅ A 本体：4 处补 `.timeout(ApiConfig.requestTimeout)`

`app/lib/api/auth_client.dart` —— **5/5 请求全部带超时**：

| 方法 | 行 | 超时 |
|---|---:|---|
| `register` | 33 | ✅ 新增 `ApiConfig.requestTimeout`(10s) |
| `login` | 47 | ✅ 新增 |
| `verifyToken` | 65 | ⚠️ **原 5s，有意保留**（说明见 §13.3） |
| `trialStart` | 88 | ✅ 新增 |
| `trialClaim` | 123 | ✅ 新增 |

并加**类文档**说明「每个请求都必须 `.timeout()`」，含一句判定标准：

> 🔑 **「连不上」和「连上了但没人应」是两回事** ——
> 端口无监听 → `ECONNREFUSED` **立即**失败（不需要超时兜底）；
> IP 可达但被丢弃 → **没有超时就会无限等**。
> 所以超时不是「防连不上」，而是「**防等不到头**」。

### 13.2 🔴 A 的必要配套：`_friendlyError` 补两个映射

**为什么必须一起做**：加了 `.timeout()` 之后，`Future.timeout()` 抛的是 `TimeoutException`，
而 `_friendlyError` 是**错误文案的唯一出口** —— 映射不到就**原样透传**，
用户会直接看到：

```
TimeoutException after 0:00:10.000000: Future not completed
```

**→ 加了超时反而让用户看到更糟的文案。** 故一并补：

| 异常文本 | 显示 |
|---|---|
| `TimeoutException …` | 「**网络超时，请检查网络后重试**」 |
| `SocketException` / `Connection refused` / `Failed host lookup` | 「**连不上服务器，请检查网络后重试**」 |

⚠️ 明确区分：**超时映射是 A 引入的新暴露（必须做）**；
**Socket 映射是既有问题**（同函数、同类问题、改一行即收口）—— 一并处理但如实标注来源。

### 13.3 🔴🔴 顺带挖出一个真 bug：`replaceFirst` 会把 `SocketException:` 啃掉

原调用处是 `_friendlyError(e.toString().replaceFirst('Exception: ', ''))`。
但 `SocketException: Connection refused` 里**中间也含 `Exception: `** → `replaceFirst` 命中它：

```
'SocketException: Connection refused'.replaceFirst('Exception: ', '')
  → 'SocketConnection refused'          ← 前缀被损坏
  → contains('SocketException') == false  ← 此后任何 Socket 匹配永远失效
```

**这是「埋雷」型缺陷**：字符串已损坏 + 后续匹配静默失效 ——
若以后有人（包括下一个我）在这里加 `contains('SocketException')`，会**永远不生效且查不出原因**。

**修法**：只在「**恰好**以 `Exception: ` 开头」时才剥前缀：

```dart
final msg = raw.startsWith('Exception: ')
    ? raw.substring('Exception: '.length)
    : raw;
```

→ **入参改为传 `e.toString()` 原文**（4 处调用同步改），函数文档里加了 ⚠️ 提醒。

### 13.4 ⚠️ `verifyToken` 的 5s 是**有意例外**（非漏改）

它的超时从原实现就存在，且刻意不等于 `requestTimeout`：
它在**启动路径**（会话恢复）上，用户正等着首屏；超时后果也轻（catch 后按「已认证」继续）。
→ 已在文档注释里写明「**这是全库唯一的有意例外，不是漏改**」，防后人「顺手统一」。

### 13.5 ✅ 验证

| 项 | 结果 |
|---|---|
| 超时覆盖 | ✅ **5/5**（`grep "timeout("` 逐行确认） |
| `analyze_inproc`（`app/lib`） | ✅ **error=3 / warning=13 / info=7** —— 与基线**逐项一致** |
| **错误映射逻辑** | ✅ **8/8** —— 用**真实异常文本**复刻逻辑验证（含 `TimeoutException` / `SocketException` / `Failed host lookup` / `rate_limited` / 后端业务错误 / 未知错误原样透传） |
| **旧实现对照** | ✅ 实证 `contains('SocketException')` 在旧实现下为 **false**（bug 复现） |
| 真编译 | ⏳ 本机沙箱跑不了 → 请白哥 `flutter run` |

⚠️ **验证局限（如实说明）**：§13.5 的映射验证是**复刻逻辑**跑的
（`_friendlyError` 嵌在 import Flutter 的文件里，无法独立 import）——
它证明**逻辑正确**，不证明**源码可编译**。后者仍需真编译。

---

## 十四、✅ Step 3.2：痕迹渲染层（2026-09-27 12:40）

> 依据：`design-system-spec-2026-09-25.md` **§一（视觉签名）/ §1.1（三态 token）/ §八（验收清单）**

### 14.1 产出（3 个文件 + 1 个对照页）

| 文件 | 性质 | 规模 |
|---|---|---|
| `app/lib/widgets/trace_segmenter.dart` | 🆕 **区间切分 · 零 Flutter 依赖** | ~250 行 |
| `app/lib/widgets/trace_text.dart` | 🆕 渲染层（`TraceText` + `applyTraceStyle`） | ~200 行 |
| `scripts/trace_verify/`（3 文件） | 🆕 验收脚本（**82 项断言**） | ~330 行 |
| `docs/design/trace-render-compare-2026-09-27.html` | 🆕 三档 × 三态 × 三字号对照页 | — |

### 14.2 🔑 核心设计：把「切分」与「渲染」拆开

痕迹有两类问题，**性质完全不同**：

| 类 | 例子 | 能否自动抓 |
|---|---|---|
| ① **切分错** | 丢字 / 重叠 / 越界 / 同起点结果不稳定 | ✅ **能**（纯逻辑） |
| ② **样子不对** | 三态不可辨、已掌握态干扰阅读 | ❌ **不能**（只能肉眼） |

→ 把①抽成 `trace_segmenter.dart`（**不 import Flutter**，仿 `fsrs_service` 做法），
②留在 `trace_text.dart`。

🔑 **可验证性反过来促成了更好的分层** —— 为了让切分能被脚本断言，
它必须不碰 Flutter；于是「计算」与「呈现」被强制分开，
**出了错时能立刻知道该往哪查**。

### 14.3 🔴🔴 三处「设计稿能做、Flutter 文本做不到」（已核实 SDK 源码）

设计稿的痕迹是 HTML **内联元素**（`<span>` + `border-radius` + `padding`）。
Flutter 的 `TextStyle` **没有对应能力 —— 不是没实现，是 API 不存在**：

| 设计稿（spec §1.1） | Flutter `TextStyle` | 偏差 |
|---|---|---|
| `border-radius: 3px` | ❌ **无圆角** —— `background` 是 `Paint`，只能画矩形 | 直角 vs 圆角 |
| `padding: 1px 3px` | ❌ **无 padding 字段**（已 grep SDK 确认） | 背景紧贴字形 |
| `border-bottom: 2.5px` | ⚠️ `decorationThickness` 是**笔画宽度的倍数**，**不是像素** | 线宽不精确 |
| border 贴盒底 | ⚠️ `underline` 贴在**基线下方**，**无偏移可调** | 线离文字更近 |

**按档看影响**：

| 档 | 结论 |
|---|---|
| **夜（前景色）** | ✅ **完美还原** —— `color` 一一对应，零偏差 |
| **格（下划线）** | ✅ 语义完全对（本来就是线）—— 仅线宽/位置需**真机目视标定** |
| **墨（底色浸染）** | ⚠️ 语义对，但**无圆角、无 padding** |

📄 **对照页**（用真实 token 值、同一 CSS 引擎并排画）：
`docs/design/trace-render-compare-2026-09-27.html` **第 ② 节**

> 🔑 **要判断的就一件事**：墨档那个差异，是「可以接受」还是「一眼就觉得糙」？
> - 可接受 → 保持现实现，偏差按已知问题记录
> - 不可接受 → 墨档单独上**自绘**（`TextPainter.getBoxesForSelection()` 拿矩形 → 画 `RRect`），
>   代价是断行/对齐/选区都要自己处理
>
> ⚠️ **不擅自决定** —— 3px 圆角在 16.5px 正文里的实际差异，**只有看的人能判断**。

### 14.4 线的粗细：一个必须真机标定的估算

`decorationThickness` 是「字体自带笔画宽度的倍数」（默认 1.0），
而真实笔画宽度藏在字体元数据（`OS/2.underlineThickness`）里，**Flutter 未暴露**。

→ 实现里用估算系数 `_kFontStrokeRatio = 0.07`（常见字体约 5%–8%）换算：

```
decorationThickness = 目标像素 / (fontSize × 系数)
```

🔑 **「目标像素」保留在 token 的 `border.width` 里（2.5 / 1.5 / 1.0）** ——
真机标定时判据是「屏幕上是不是 2.5px 那么粗」；若把倍数硬编码进 token，
就丢了这个判据。**改一个系数即可同时修正三态线宽。**

⚠️ 这是**估算**，真机目视后需回来调 —— 已在代码注释里写明。

### 14.5 ✅ 验证

| 项 | 结果 |
|---|---|
| **`trace_verify`** | ✅ **82 项全过** —— 含 **2,000 组随机输入**（越界/空/反向）的「覆盖全文 + 首尾相接」不变量（其中 1,292 组确实落了痕迹，不是靠空输出蒙过） |
| `tokens_verify` | ✅ **309 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** —— 与基线逐项一致（分析文件 62 → **64**） |
| 真机视觉 | ⏳ **未做**（需 `flutter run`）—— 三态的**可辨性**只有肉眼能验（spec §八） |

#### 过程中一次「断言错 vs 实现错」的判别

首跑 **8 项失败**，实际输出 `[_0-10]`、我写的期望是 `[_-0-10]`。
按判据「**先看数据是否自相矛盾**」：实际输出 `[_0-2, T2-6, T6-8, _8-10]`
区间连续、样式分布正确 → **实现是对的**，是我的期望字符串多打了一个 `-`。
→ 🔑 **见红不要先改实现**；这次的 8 项全部是断言错。

### 14.6 下一步

| # | 待办 | 说明 |
|---|---|---|
| 1 | **看对照页定墨档** | 上不上自绘（§14.3）—— **不阻塞后续** |
| 2 | 真机 `flutter run` 目视 | 两态在 15/18/24px 下是否可辨（spec §八） |
| 3 | 进 `3.3 卡片书签 + bookmark 表` | 痕迹暂时没有「落脚处」—— 它要等 **3.4 阅读器**才有正文可标 |

---

## 十五、🔴🔴 白哥定「已掌握 = 不标识」→ 痕迹从三态改两态（2026-09-27 12:52）

> 白哥：「**已掌握就应该不标识了吧**」

### 15.1 这条修掉了 spec 的**一处内部矛盾**

| 位置 | 原文 |
|---|---|
| spec 第 21 行（**原则**） | 「**学习的终点是痕迹的消失**」 |
| spec 原 §1.1（**值表**） | 已掌握 = 「几乎不可见（**比周围文字暖一点点**）」 |

一个说「消失」、一个说「还留一点点」→ **按原则改值表**。
已掌握的字**回到普通文字**，与「从没查过」在视觉上**完全一致**。

### 15.2 🔑 关键判断：「不标识」**不能**用「透明样式」表达

**因为 `padding`。**

透明确实看不见**颜色**，但 `padding: 1px 3px` **仍然生效** → 撑开字距 →
被标记过的字与普通字**间距不同**，用户看得出来「这里有东西」。
**那仍然是标识，只是更难解释 —— 一种更糟的「标识」。**

→ 所以用 **`null`**（**没有痕迹**）表达，而不是「一个看不见的痕迹」：

```dart
TraceStyle? forReps(int reps, {int lapses = 0}) {
  if (reps <= 0) return fresh;
  if (reps >= 3 && lapses == 0) return null;   // 已掌握 → 痕迹消失
  return reviewing;
}
```

返回值可空 → 调用方**在编译期就被告知要处理这个分支**（不能忘）。

### 15.3 顺带的收益：痕迹不再退化成「掌握度仪表盘」

若已掌握还留一点暖色，痕迹就同时背了**两个表达**
（「这里我查过」+「这个我掌握了」）—— 违反设计稿的「**一个概念，一个表达**」
（原文：「去掉数字之后，痕迹成了唯一的进度表达」）。

→ 掌握度要看就**去复习页看**；**痕迹只表达「我和这篇文章的关系」**。

### 15.4 改动清单

| 文件 | 动作 |
|---|---|
| `coevo_tokens.dart` | 删 `TraceTokens.mastered` 字段（**三态 → 两态**）· `forReps` 改返回 **`TraceStyle?`** · 删 `TraceStyle.isInvisible`（不再需要 —— 不标识用 `null` 表达）· 三档实例各删 `mastered` |
| `coevo_tokens.dart` | `TraceBorder.dashed` **保留** + 标注「当前无实测值使用者」（唯一使用者曾是格档 mastered；保留因为它是边框的通用属性、映射已接通） |
| `trace_segmenter.dart` · `trace_text.dart` | 注释更新 —— 说明「不标识用 `null`，**不要传透明样式**」 |
| `design-system-spec` | §一 表格 · §1.1 token 表（删「已掌握」三行）· §八 验收项 |
| `design-system-spec` | 🔑 **顺带修正一处失效表述**（见 §15.5） |
| **设计稿**（L1 锚点） | 🔴 **不擅自改样式** → 加注释标注 `--tk-d-*` 已作废，**原样保留** |
| `scripts/trace_verify` | 断言改（**82 → 76 项**） |
| `scripts/tokens_verify` | 断言改（**309 → 295 项**） |
| `trace-render-compare-*.html` | 三态 → **两态** + 🆕「已掌握 vs 无标记」并排对照（两行应完全一致） |

### 15.5 🔑 顺带发现：spec 的夜档表述「亮度递减」已失效

spec 原写「夜用**亮度递减**」。这在**三态**下成立 —— 靠「已掌握」把亮度拉到 `.291` 才拉开差距。

只剩两态后实测：

| 态 | fg | 相对亮度 |
|---|---|---|
| 刚查过 | `#FFD9B8` | **0.743** |
| 复习中 | `#DEDCD7` | **0.716** |

**差 0.027 —— 几乎无差。** 两态**实际靠「暖度」（r−b：71 vs 7）区分**，不是亮度。

→ 已改为「**暖度递减**」，并在 spec 里标注：

> 若真机目视发现两态**难以区分**，这是**首要怀疑点**。

⚠️ 这个变化是白哥的决策**顺带揭示**的 —— 若不做两态简化，这个「表述与实测不符」会一直藏着。

### 15.6 ✅ 验证

| 项 | 结果 |
|---|---|
| `trace_verify` | ✅ **76 项全过**（含「三档 `forReps(3)` 都必须返回 `null`」） |
| `tokens_verify` | ✅ **295 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致 |

⚠️ **过程中又踩「`old_string` 漏含子行」**（第 5 次）→ **立刻读文件核实**实际内容正确、未造成损坏。
→ 这条教训已写进 `MEMORY.md` 的维护规则：**改前先 `Read` 精确上下文，改后 `grep` 复核**。

### 15.7 下一步（不变）

| # | 待办 |
|---|---|
| 1 | **看对照页定两件事**：两态分得清吗（尤其夜档）· 墨档要不要上自绘 |
| 2 | 真机 `flutter run` 目视 |
| 3 | `3.3 书签 + bookmark 表` → `3.4 阅读器 + 划词`（痕迹到这时才有正文可标） |

---

## 十六、✅ Step 3.3：卡片书签 + `bookmark` 表（2026-09-27 13:10）

### 16.1 🔴 调查结果：真实缺口比规划里写的更多

规划 §五 把 3.3 写成「卡片 + 书签 + `bookmark` 表」，暗示「表结构已定义、查询层已建，只差接口 + UI」。
**核实后发现：连「打开 user.db」这一步都不存在。**

| 环节 | 核实前以为 | 实际 |
|---|---|---|
| `sqflite` 依赖 | ✅ 已有 | ✅ 已有 |
| `user_db_schema.sql` | ✅ 已定义 | ✅ 已定义且已声明进 `assets:` |
| `ReviewListQuery` / `WordQueryService` | ✅ 已建 | ✅ 已建 —— 但**只接受注入的 `Database`** |
| 🔴 **谁来打开 `user.db`** | ❌ **不存在** | ❌ **确实不存在** —— 从无代码创建过它 |

→ 所以 3.3 的真实范围是：**连接层 + 表 + 仓储 + 状态 + UI**，
其中**连接层是从来没做过的一环**（此前所有端侧数据层验证都靠脚本自建临时库）。

### 16.2 产出

| 文件 | 性质 | 说明 |
|---|---|---|
| `app/lib/services/user_db.dart` | 🆕 **连接层**（纯 Dart） | 打开/建表/迁移 + **SQL 脚本拆分器** |
| `app/lib/services/bookmark_repository.dart` | 🆕 仓储（纯 Dart） | 增/删/切换/列表/待同步 + `parseUserDbUtc` |
| `app/lib/providers/bookmark_provider.dart` | 🆕 Riverpod 状态 | `AsyncNotifier<Set<int>>` + 两个派生 getter |
| `app/assets/sql/user_db_schema.sql` | 改 | +`bookmark` 表 + `idx_bm_time` + `idx_bm_pending`（v1.2） |
| `app/lib/widgets/feed_card.dart` | 改 | +`BookmarkButton`（凹→凸）+ 元信息行改 `Row` |
| `app/lib/screens/home_screen.dart` | 改 | 接 provider + `_toggleBookmark`（1.5s toast） |
| `app/pubspec.yaml` | 改 | 显式声明 `path`（原为 Flutter 传递依赖） |
| `scripts/query_verify/bin/verify_bookmark.dart` | 🆕 **49 项断言**（真库） | — |
| `scripts/query_verify/bin/verify_review_list.dart` | 改 | 复用连接层的拆分器（**消除重复实现**） |

### 16.3 🔑 三处关键设计

#### ① DDL 由调用方注入 → 连接层保持纯 Dart

Flutter 读 assets 要用 `rootBundle`（那是 Flutter API）→ 一旦在连接层调用就**无法在脚本里验证**。
→ **调用方把 DDL 字符串读进来传进去**：

```dart
// Flutter 侧
final schema = await rootBundle.loadString(kUserDbSchemaAsset);
final db = await openUserDb(factory: databaseFactory, path: ..., schemaSql: schema);

// 验证脚本侧（同一个函数、同一个 DDL 文件）
final schema = File('app/assets/sql/user_db_schema.sql').readAsStringSync();
final db = await openUserDb(factory: databaseFactoryFfi, path: ..., schemaSql: schema);
```

🔑 附带好处：**只有一份 DDL 文件** → 「文档一套、代码一套」不可能发生。

#### ② 「不标识」的第二例：收藏不用「透明样式」表达禁用

书签未收藏 = **凹陷**（`ClayState.pressed`）+ `sunken` 填充；
已收藏 = **凸起 + 朱砂**（`ClayState.selected`）。
库未就绪时**不用 `ClayState.disabled`** —— 那个态的定义是「从凸起变瘪」，
而书签未收藏本来就是凹陷 → **套上去会变成凸起，语义直接反转**。
→ 只用一层 `Opacity(0.45)` 表达「当前不可用」，不触碰粘土的物理语义。

⚠️ 这个状态**极短暂**（打开数据库 <100ms），只有打开失败时才长期停留 ——
那时它就是「该功能不可用」的诚实表达。设计稿**没有定义**禁用态，所以这层透明度是最小表达。

#### ③ UI 怎么消费 provider —— 把「未就绪」处理成**一次**

`bookmark_provider.dart` 的类文档写了一条**硬约定**：

> **只能用 `idsOrEmpty` / `isReady`，不要用 `when` / `maybeWhen`。**

原因：`when(error:)` 会把「数据库打不开」渲染成一个**错误界面** ——
而收藏只是信息流的一个附属动作，它坏了**不该把内容页变成报错页**（3.22 的教训）。
两个 getter 已经把这件事处理好：未就绪/失败 → 空集合 + 按钮禁用。

### 16.4 与设计稿的偏离（2 处，均已记录在 schema 注释里）

| # | 设计稿 | 本实现 | 理由 |
|---|---|---|---|
| 1 | `bookmarked_at TEXT DEFAULT (datetime('now'))` | `DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))` | 🔴 `datetime('now')` 返回**空格分隔、无 `Z`** → Dart 的 `DateTime.parse` 会**静默按本地时区解释** → 跨时区静默错位（不报错）。且与本库硬约束 1（UTC ISO8601 带 `Z`）冲突 |
| 2 | `pending_push INTEGER DEFAULT 1` | + `NOT NULL` + `CHECK (IN (0,1))` | 与 `card_review_state` 同规格。设计稿是**草图级** DDL，本文件是**权威定义** |

🔑 另一处**补充**（非偏离）：设计稿只要求 `idx_bm_time`；
本实现另加 `idx_bm_pending` —— 因为设计稿自己说「跟着已有的同步机制走」，
而增量 push 的查询就是 `WHERE pending_push = 1`。

### 16.5 ✅ 验证

| 项 | 结果 |
|---|---|
| **`verify_bookmark`** | ✅ **49 项全过** —— **真库**（`sqflite_common_ffi`）：SQL 拆分器 9 项边界 · schema 执行 · 表/索引齐备 · **重开模拟应用重启** · CRUD · **幂等** · **重复点击不刷新时间戳** · 取消后可再收藏 · `toggle` · 待同步 · 倒序 · limit/offset · 时间列带 `Z` |
| `verify_review_list` | ✅ **37 项全过**（改用连接层拆分器后**无回归**） |
| `verify_word_query` | ✅ **42 项全过** |
| `analyze_inproc` | ✅ **error=3 / warning=13 / info=7** 与基线一致（文件 64 → **67**） |
| 真机 | ⏳ 未跑 → 请白哥 `flutter run` 看：卡片右上角书签**凹陷** → 点击变**朱砂凸起** + 1.5s toast |

#### 又一次「断言错 vs 实现错」的判别

首跑 **8 项失败**，而**「实得」与「期望」的文本完全相同**（如 `实得 [11, 12, 10] · 期望 [11, 12, 10]`）。
→ 判据「数据是否自相矛盾」：文本一样而判不等 → **不是实现问题**。
真因：`eq` 用了 `==`，而 **Dart 的 `List` / `Set` 没有值等价语义**（`==` 是引用比较）。

修 `eq` 加 `deepEquals`（逐元素比较）后 **49 项全过**。
→ 已在 `scripts/query_verify/README.md` 写了提醒，避免后人重踩。

#### 🔴 顺带消除一处**重复实现**

`verify_review_list.dart` 原本自己写了一套**较弱的** SQL 拆分
（`split(';')` + 过滤以 `--` 开头的行）—— 它不处理**行内注释**，也不处理**块注释**。
而同一份 `user_db_schema.sql` 在新脚本里走的是强拆分器。
→ **同一份文件、两套解析**迟早分叉（一个通一个不通，症状诡异）。
→ 改为复用 `user_db.dart` 的 `executeSqlScript`，跑通 37 项无回归。

⚠️ 编辑过程中「`old_string` 截断在语句块中间」导致留下残骸 —— **立刻读文件核实并修复**。
这是该坑的**第 6 次**（前 5 次是「漏含子行」，这次是「漏含后半段」）。

### 16.6 ⚠️ 有意留白

| 项 | 为什么不做 | 归入 |
|---|---|---|
| 标题栏「收藏 N」入口 | 它要打开**收藏清单**，而清单是 3.5 → 现在做只能是**死入口**（3.1 的判断一致） | **3.5** |
| 收藏清单页（复用同一套卡片 + 空状态粘土环） | 同上 | **3.5** |
| 多端同步（`pending_push` 的 pull/push） | 属 Phase 3；表/索引/`pending()`/`markSynced()` 已就位，**不是从零写** | Phase 3 |
| `word.db` 的落盘与打开 | 它是 32.9 MB 的预制库，需要「首次启动从 assets 复制到可写目录」——属**划词**链路 | **3.4** |

### 16.7 下一步

`3.4 阅读器 + 划词`（**最大未知**）—— 到那时痕迹才有正文可标、`word.db` 才需要落盘。

🔴 **已出专项规划** → 📄 `docs/review/step3-reader-plan-2026-09-27.md`
**关键结论**：真实范围远超原规划 —— 缺口大头在**数据层**（4 张表 + 32.9 MB 预制库落盘），UI 只是一部分。
建议分期 **3.4a 阅读器骨架**（零新表）→ 3.4b 划词查词 → 3.4c 生词本落库。⏳ 待白哥定 Q1/Q2/Q3。


