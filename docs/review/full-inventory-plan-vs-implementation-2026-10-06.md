# 全面清查：计划 vs 实现（2026-10-06）

> 白哥：「全面清查计划，更新文档，将计划了但没有做的按计划执行」
>
> ## 清查方法（口径）
> 读 **4 份规格源**，逐项提取「计划项」，再去**代码里核对**（不采信文档的状态描述）：
> | 文档 | 体量 | 权威层 |
> |---|---|---|
> | `v1-final-design-authoritative-2026-09-25.md` | 37 KB | **L0 白哥原文** |
> | `ui-ux-refactor-assessment-2026-09-25.md` | 92 KB | L1/L2 |
> | `design-system-spec-2026-09-25.md` | 62 KB | L2 |
> | `english-app-implementation-plan-v2-2026-09-25.md` | 182 KB | L3 |
>
> 🔴 **为什么不能只信文档**：这 4 份都是 **09-25 写的**，之后代码演进 11 天。
> 实测里已有大量「文档写 ⏳ 未开始、代码早做完」的条目 ⇒ 全部以**代码 grep** 为准。
>
> ⚠️ **不列入清查的范围**（历史归档，与当前产品无关）：
> `docs/redbook/`(78) · `docs/research/`(127) · `docs/marketing/`(46) ·
> `docs/_archive/`(64) · `docs/features/`(17，**全是 K12 时代 5–6 月**)。

---

## 一、真正「计划了但没做」的（按优先级）

### P1 —— 用户可直接感知 / 有连带阻塞

| # | 项 | 证据 | 为什么是 P1 |
|---|---|---|---|
| **1** | 🔴🔴 **阅读设置面板** | `design-system-spec §5.1` 要求：字号**可调 15–24px**·行高·主题·**痕迹开关**·语速。实测 `grep 阅读设置\|readingSettings` → 只命中注释「面板本身是独立一批，不在骨架内」 | **连带阻塞 3 处**：① spec 第 86 行明说「**痕迹开关在阅读设置面板内**」⇒ 面板不存在 ⇒ **该开关无任何入口** ②「单击屏幕中央唤出面板」⇒ **手势目前是空的** ③ `profile_screen:963` 注释「搬去阅读面板的前提是面板先存在」⇒ 有项设置搬不走 |
| **2** | 🔴 **单击屏幕中央唤出面板**（Kindle 模式） | 同 `ui-ux §6.3/§6.6` | 与 #1 **同一个根因**（面板不存在，手势无目的）。🔑 也是当初划词选**长按**的原因 —— 一个手势不能有两种含义 |
| **3** | 🔴 **私密笔记** | 两个独立来源都计划：`implementation-plan-v2 §5.7.2 / Phase 4 #9` + `ui-ux §4.3/§6.5`。实测 `grep user_note\|笔记\|addNote` → 端侧 **0 命中**（`user.db` 也无笔记表） | 计划里把它定位为「**低合规风险的记忆增益功能**」—— 用户自己的笔记不涉版权 |
| **4** | 🟠 **学习成果分享图**（**半成品**） | `utils/image_export.dart:30` 的 `exportPngBytes` **已写好但全仓 0 个调用方**；实际分享只有 `stats_card.dart:211` 的**纯文字** `Share.share` | 代码写完了没接线 ⇒ 典型的「**写了没人跑**」 |
| **5** | 🟠 **Apple 登录** | `pubspec.yaml` 无 `sign_in_with_apple`；`app/lib` 全库无 `SignInWithApple`；`widgets/claim_dialog.dart:24` 注释自记「全库无该依赖」 | 上架前常见配置；且记忆里「登录页批次」列过它 |

### P2 —— 增强（有价值但不紧急）

| # | 项 | 证据 |
|---|---|---|
| **6** | 阅读器「**下滑到底自动加载下一篇**」 | `ui-ux §6.4`（保持连续感）。实测 0 命中 |
| **7** | **阅读-复习联动**（文章里遇到的词优先复习） | `v1 §13 Phase4#1` + `plan-v2 §七 Phase7#2`，**两处都计划** ⇒ 0 命中（`fromArticle` 无） |
| **8** | **结构化交互**（文章「有用/有点难」+ 词卡群体统计） | `plan-v2 §5.7.1 / Phase4#10 / Phase5#8`，**前后端均 0 命中** |

### P3 —— 长期 / 可不做

`进度环·趋势图`（ui-ux §4.3）· `错误类型分析 + 复习队列错误权重`（v1 §10.2）·
`难度自适应`（v1 §13 Phase4#2）· `CEFR 难度自动估算`（plan-v2 Phase3#4）·
`年度总结`（plan-v2 Phase7#4）· `服务端 POST /auth/logout`（v1 §7.4）·
`内容离线缓存`（plan-v2 Phase4#7 —— 现正文仅在线拉取）

---

## 二、🔴 清理未完成（不是「没做」，是「做了半边」）

### 2.1 app 里残留 **K12 分销时代**的调用

| 调用点 | 接口 | 性质 |
|---|---|---|
| `home_screen.dart:381` `_checkLoginCampaignPush` | `GET /api/campaigns/check-push-trigger?push_trigger=login` | 🔴 **每次登录自动发**（营销推送触发）|
| `home_screen.dart:393` `_joinCampaign` | `POST /api/campaign/join` | 注释自述「拼团/砍价类」—— **与英语学习无关** |
| `home_screen.dart:295` | `POST /api/referral/click` | 分销推荐点击 |
| `profile_screen.dart:1276` | `GET /api/referral/my-code` | 推荐码 |
| `notification_panel.dart:126` | `POST /api/referral/generate-h5` | 分销 H5 分享页 |

⇒ **英语学习 App 里没有「拼团/砍价/推荐码」的产品位置**。这些是 K12 分销线的残留调用。
⚠️ 后端 `marketing_campaigns` 表 **0 行** ⇒ 接口返回空 ⇒ **无害但白跑**。

### 2.2 后端 61 条 `/api/admin/*` 路由仍在（**风险已缓解，但代码未清**）

- ✅ **缓解**：Nginx `location /api/admin/ { return 404; }`（2026-10-02 加的，实测生产配置里有）
- 🔴 **但代码层三处未清**：
  1. **61 条路由 + `admin_handlers.rs`** 仍在（含 `admin_hard_delete_user` / `admin_users_export`）
  2. `admin_users` 表生产上 **1 行 `super`，且 `password_hash` 长度为 0** ⇒ 那个账号**无法用 token 登录**（空串被 `token.is_empty()` 挡）⇒ 实际**唯一入口是 `x-admin-key`**
  3. `verify_admin` 的 `x-admin-key` 一旦匹配**直接返回 `("super","super")`** ⇒ **单一静态密钥 = 全部权限**；且实测生产该密钥**以 `coev` 开头**（疑似可猜的短词）
  ⚠️ 我**没有打印完整密钥值**（那会造成新的泄漏）。
- 📌 **纵深防御**：Nginx 挡的是「外部」；但①密钥弱 ②代码在 ③`admin_users` 有 active 行 ⇒ 任一环节失守即可直达 `hard-delete-user`

### 2.3 其他残留

- `data/word.db` 的 **`card_audio` 空表**（语音包已取消 · 表还在）
- `docs/features/` **17 个 K12 时代文档**（5–6 月）混在 docs 里，看着像「当前计划的 feature」
- 🔴 **memory 目录 91 个日志（5 月 7 日 ~ 10 月 6 日）** —— `MEMORY.md` 写明「**30 天以上 distill 后删除**」，
  **该规则从未执行**。⚠️ 后果已实测：我把 5 月 13 日的「考试模式透明度」当成**待办**去问白哥，
  而它 5 月 21 日就**结案**了（白哥 10-06 确认「过时，现在的考试模式是正确的」）。
  ⇒ 与「progress 文档过时」**同一个病**：手写快照 vs 持续前进的现实。⚠️ 删除不可逆，需单独批准。

---

## 三、❌ 已取消（**不要重启**）

语音包整条轨道 · 微信支付 · 词表分级 / `plan` 学习计划 · 跟读评测 · UGC 自由文本评论 ·
免费层「生词本 200 词上限」· 课文课程（80 篇）· 服务端 PostgreSQL（用 SQLite）·
`user_session` 单端会话（**已改多端登录**，白哥 2026-10-05 批准）· `<image>` 联想图像段（**无数据源**）

---

## 四、⚠️ 有意留白（**不是遗漏**，别当待办）

- **阅读器顶栏「下滑隐藏」**：spec 只给四个字，**没给触发阈值/回弹规则** ⇒
  `reader_screen.dart:53-55` 已显式注明「自行定一个数等于替设计做决定 → 留到有明确规格时再做」
- **成就解锁「粒子撒花」**：`achievement_unlock_overlay.dart:11-15` 注明「第一版不做」（装饰性）
- **消息推送**：`plan-v2 Phase7#1` 自己标「**第一期不做**」
- **日落自动切换主题**：spec 写「建议顺带做」，属建议项

---

## 五、执行计划（建议批次）

| 批次 | 内容 | 为什么这个顺序 | 状态 |
|---|---|---|---|
| **①** | **阅读设置面板**（含痕迹开关 + 字号 + 语速）+ 顶栏入口 | 一条根因解 3 处阻塞；规格最明确；不依赖外部 | ✅ **2026-10-06 已实现**（见 §七）|
| **②** | **分享图接线**（`exportPngBytes` 已有，只需接 UI）+ **K12 分销调用清理** | 前者是「写完没接线」，成本低收益直观；后者是纯减法 | ⏳ |
| **③** | **私密笔记**（schema + UI） | 需先定「笔记放哪」—— 属产品决策 | ⏳ 待定 |
| **④** | 后端死路由清理（61 条 admin + referral/campaign 残留）+ memory 归档 | ⚠️ 涉及删除，单独批准 | ⏳ 待批 |
| **⑤** | P2 增强（自动加载下一篇 / 阅读-复习联动 / 结构化交互） | 需求更弱，等前面稳定 | ⏳ |

---

## 七、✅ 批次① 实施记录（2026-10-06）

### 交付物

| 文件 | 作用 |
|---|---|
| 🆕 `app/lib/services/reading_settings.dart` | **规则层**（零 import）：字号区间 15–24 · 默认 **17** · `clampReadingFontSize` · `ReadingPrefKeys`（键名收敛）· `kTraceEnabledDefault` |
| 🆕 `app/lib/providers/reading_settings_provider.dart` | 状态（`StateNotifier` + SharedPreferences，形态与 `themeProvider` 一致）|
| 🆕 `app/lib/widgets/reading_settings_panel.dart` | **面板 UI**：字号 −/+ · 底色三档 · 痕迹开关 · 语速 |
| ✏️ `app/lib/screens/reader_screen.dart` | 字号改从 provider 读（删掉硬编码 `_bodyFontSize`）· 传 `traceEnabled` · 顶栏加设置键 |
| ✏️ `app/lib/widgets/trace_markdown.dart` | 加 `traceEnabled`（默认 `true` ⇒ 旧调用方行为逐字不变）|
| 🆕 `scripts/query_verify/bin/verify_reading_settings.dart` | **42 项** · 已接 CI · **证伪 6/6** |

### 🔴 两处必须说清的取舍 → ✅ **白哥 2026-10-06 已全部定案**

1. **行高不放面板** —— ✅ **白哥定：「行高不放阅读面板」**（与 spec §839「行高随主题」一致）。
   spec §847 把「行高」列进面板那句，视为**与 §839 冲突后的旧措辞**，不采。

2. **入口 = 单击正文 + 顶栏键（双入口）** —— ✅ 白哥指出：「**划词不是长按吗？面板弹出应该是点击，与划词应该不冲突才对**」。
   **读 Flutter SDK 源码核实（不是猜）** ⇒ **白哥判断正确**：

   | 手势 | 注册者 | 源码位置 |
   |---|---|---|
   | **长按（划词）** | `LongPressGestureRecognizer` | `selectable_region.dart:717` |
   | **单击** | `TapAndHorizontalDragGestureRecognizer`（`onTapUp`）| `:683` |
   | 右键 | `TapGestureRecognizer`（**只绑 `onSecondaryTapDown`**）| `:458` |

   ⇒ **语义上确实不冲突**（两个不同的 recognizer）。
   ⚠️ 但**竞技场层面**有个坑：外层包 `GestureDetector` **拿不到**单击 ——
   竞技场按「加入顺序」裁决，而加入顺序 = hit test 顺序 = **内层先**
   ⇒ 外层的 recognizer **总是后加入** ⇒ 被内层吃掉。
   ✅ **正解**：把 `onTap` 放在 **`SelectionArea` 的 child 位置**（比内层 `SelectableRegion` 更深）
   ⇒ 先加入竞技场 ⇒ 单击归我们；长按仍由 `LongPressGestureRecognizer` 在 500ms 后先 accept
   ⇒ **划词不受影响**。

   🔑 **与「单击取消选区」共存的方式**（关键）：靠「**注册与否**」分流，不是 handler 里判断 ——
   · **有选区** ⇒ `onTap` 传 `null` ⇒ `GestureDetector` **不创建**该识别器
     ⇒ 单击落到 `SelectableRegion` ⇒ **清空选区**（原行为一字不差）
   · **无选区** ⇒ 注册 ⇒ 单击 ⇒ **弹面板**
   📌 为什么必须这样：handler 里 `if (有选区) return;` 仍会**吃掉**这次点击
   ⇒ 选区**永远取消不掉**（且零报错）。**要让出事件，只能不注册识别器。**

   ⏳ **仍需真机确认**（推理自洽但本机验不了）；顶栏键**保留作兜底**。

3. **朗读卡搬进面板** —— ✅ **白哥定：「搬」**。已搬 **语速 + 音色 + 试听**，
   `profile_screen` 的卡已删（含孤儿符号 `_previewNativeTts` / `_nativePreviewText` / `import tts_service`）。
   ⚠️ 代价如实记录：那张卡原也服务**词卡朗读** ⇒ 词卡里调音色需先进入文章。

### 验证
- 语法：`dart format --output=none` 通过（5 文件）
- 断言：**42 项全过** · **证伪 6/6**
- 回归：`tokens_verify` **692** · `verify_reader_tts` **43** · `verify_feed_wiring` **71** ·
  `verify_reading_completion` **13** · trace 三脚本 —— 全绿
- ⏳ **未做**：真机（本项目工具边界）—— 要验三件：字号 −/+ 生效 · 痕迹开关真的不标 · 面板能打开

---

## 六、请白哥定的两件

| # | 问题 | 我的建议 |
|---|---|---|
| **①** | **私密笔记**要不要做？做成什么样？ | 建议做（计划里定位为低合规风险的记忆增益）。**但要先定位置** —— 我倾向「词卡内一个可折叠的笔记区」而不是独立页（避免又是一个低频独立页） |
| **②** | `COEVO_ADMIN_KEY` 现在是**弱值**（`coev` 开头），且 admin 路由只是 Nginx 挡着。要不要**轮换密钥 + 删死路由**？ | 建议**都做**：轮换零风险（无消费者）；删路由是纯减法。⚠️ 但两者都属「改生产」，按铁律等你批准 |
