# 底部导航「割裂感」+ 侧滑返回缺失（2026-09-28）

> 来源：白哥真机反馈——
> ①「底部 tab 还是不好看，有一种**割裂感**，这是**设计上的问题**」
> ②「每个页面应该加上**左滑退出**，尤其**收藏列表根本没有返回按钮**」
> 状态：**问题①②均已实施**（问题①由白哥在样张中选定**方案 ③**）
> 样张：`docs/design/tabbar-variants-2026-09-28.html`（5 方案 × 三档 × 含内容穿透态）

---

## 一、问题②：侧滑返回 + 返回按钮（**已实施**）

### 1.1 根因：侧滑**不是路由自带的能力，是转场 builder 给的**

源码级证据链：

| # | 事实 | 出处 |
|---|---|---|
| 1 | `CupertinoPageTransitionsBuilder.buildTransitions` **委托**给 `CupertinoRouteTransitionMixin.buildPageTransitions` | `material/page_transitions_theme.dart:748` |
| 2 | 该方法内部包了 `_CupertinoBackGestureDetector`（**手势检测器就在这里**） | `cupertino/route.dart:253` |
| 3 | Flutter **按平台分派**转场：`android → PredictiveBackPageTransitionsBuilder` · `iOS/macOS → CupertinoPageTransitionsBuilder` | `material/page_transitions_theme.dart:806` |

→ 于是有**两种静默关掉侧滑的方式，编译器都不报错**：

| 方式 | 后果 | 本项目实际 |
|---|---|---|
| **不配 `pageTransitionsTheme`** | Android 走 `PredictiveBack` → **无 iOS 风格侧滑** | 🔴 确实没配 |
| **用 `CustomTransitionPage` 自定义转场** | **绕过 theme** → `_CupertinoBackGestureDetector` 不参与 → **手势消失** | 🔴 `/article/:id` 与 `/chat` 正是如此 |

🔑 **最关键的一条认知**：
> **自定义转场 ≠ 自定义动画。**
> `transitionsBuilder` 只能改**动画**，而「返回手势」是**转场 builder** 提供的。
> 自己写转场 = 自己放弃了手势 —— 而两者在代码里长得**几乎一样**
> （手写的 `SlideTransition` 也是「从右滑入」，肉眼分不出差别）。

### 1.2 已做的三处改动

| # | 文件 | 改动 |
|---|---|---|
| 1 | `lib/theme/theme_builder.dart` | 新增 `pageTransitionsTheme`：**android / iOS / macOS 统一用 `CupertinoPageTransitionsBuilder`** |
| 2 | `lib/app.dart` | `/article/:id`、`/chat` 由 `pageBuilder: CustomTransitionPage + SlideTransition` → **`builder:`**（走 theme 转场） |
| 3 | `lib/screens/bookmark_list_screen.dart` | 标题栏由「单个标题 Text」→ **`Row` + 右上「返回」**（启用设计稿 `.bm-hd .back`） |

**为什么 Android 也要统一成 Cupertino**：
产品只做 iOS，但**Android 是当前唯一能跑起来的验证载体**（无 Mac）。
Android 默认是 `PredictiveBack` → **不统一就根本验不了这个功能**。
⚠️ 代价：Android 用户失去系统预测性返回动画 —— Android 非出货平台，可接受。
若将来真出 Android 版，应改回 `PredictiveBack` 并单独验一遍。

**改后的收益（净增，不是替换）**：视觉上仍是「右滑入场」，但**多拿到**：边缘右滑返回 + 阴影 + 下层视差
（比手写 `SlideTransition` 更接近 iOS 原生）。

### 1.3 返回路径现状（全部页面）

| 页面 | 路由形态 | 侧滑 | 可见返回按钮 |
|---|---|---|---|
| 阅读 / 复习 / 我的 | tab root | —（无上级） | — |
| **收藏清单** | `/home/bookmarks`（子路由） | ✅ **新增** | ✅ **新增「返回」** |
| 阅读器 | `/article/:id`（顶层） | ✅ **新增** | ✅ 原有（`.rd-bar .back`） |
| chat（v1 预留） | `/chat`（顶层） | ✅ **新增** | ⚠️ 无页面级返回（该功能未启用，暂不处理） |

### 1.4 🔴 一处判断错误（如实记录）

本页原先**没有任何返回入口**，是我在 Step 3.5 的决定：
> 「设计稿 mockup **没有返回按钮** → 本实现按 mockup 走子视图、不设返回，
>    返回靠点『阅读』tab 或右滑」

**这个判断错在两处**：

1. **「设计稿没画」≠「设计稿没定义」** —— 设计稿 CSS **里就写着**：
   ```css
   .bm-hd .back{font-size:12px;color:var(--accent);font-weight:600}
   ```
   我当时把它判为「全屏方案的残留」而忽略。它更像是**留给实现补全的接口**。
   → 🔑 **看到「定义存在但未被使用」时，应按「待补全」处理，而不是当残留删掉。**
2. **「右滑可用」当时并不成立** —— 我在注释里写了「iOS 右滑返回可用」，
   但那条路径从未被验证过（子路由的转场也受 `pageTransitionsTheme` 影响）。
   → 🔑 **注释里的能力声明，未经验证就是假设。**

---

## 二、问题①：底部导航的「割裂感」（**待选方案**）

### 2.1 根因：**栏的底被平分到了每个 item 上**

对照设计稿（`visual-feed-bookmark-2026-09-25.html:164-168`）：

```css
.tabbar     { /* 无背景 */ }
.tb         { color:var(--ink3); }        /* 未选中：无底、无影 —— 完全平坦 */
.tb.on      { background:var(--accent); box-shadow: 3px 4px 10px var(--accent-out), … }
```

**设计稿的意图是「一条栏 + 只有选中项是实体」**：
未选中项**融入**页面，视觉重心只落在选中项。

**现状是「没有栏 + 三个各自有实体的 item」**：
为了修「正文穿过导致看不清」，我给**每个**未选中项都加了
`Clay(raised)` + `card` 白填充 + 外阴影 → 底部变成**三个独立悬浮物件**，
「一条栏」的整体感随之消失。

> 🔑 **一句话**：加底色这个动作没错（穿透确实需要解决），
> **但落点错了** —— 底应该加在「**栏**」这一层，而不是「每个 item」上。

### 2.2 五个方案（见样张）

| # | 栏底 | item 表达 | 评价 |
|---|---|---|---|
| ① | 透明 | 平坦 | **设计稿原意**。但正文与「复习/我的」重叠 → 就是当初说「看不清」的样子 |
| ② | 透明 | **三个凸起** | **现状**。可读但割裂（三个独立物件） |
| ③ | **毛玻璃** | **平坦** | 🟢 **推荐**：栏是一条、内容被模糊而非截断；item 回设计稿平坦，重心只在选中项。**与设计稿最一致，且是 iOS 原生观感** |
| ④ | 实心 `card` | 平坦 | 同③结构但不透明 → 内容在栏口被硬截断（即当初「底部栏破坏视觉」的感觉） |
| ⑤ | 毛玻璃 | 三个凸起 | 只补栏底、药丸不动 → 「栏 + 三个物件」叠了两层 |

**为什么推荐③而不是回到①**：
①「看不清」的根因是**内容直接压在文字上**，而③的毛玻璃**把内容模糊掉**—— 
既保留「栏与内容连续」的观感，又保证文字清晰。**这不是妥协，是 iOS 的标准解法**
（系统相机、音乐、App Store 的底部栏都是这个）。

### 2.3 若选③，技术要点

- `BackdropFilter(blur)` —— Flutter 原生支持，但**会强制该区域每帧重绘**，
  需实测滚动帧率（release 包 + 真机）
- 栏底不要用「透明黑」，用 **`page` 半透明**（如 82%）+ `blur(20) saturate(1.4)` ——
  否则夜档会偏灰
- ③ 会让**未选中项回到 `ink2`**（沿用现在的字色，因为 `ink3` 在三种底色上对比度都 < 4.5；
  已有 9 条断言锁着）

---

## 三、验证

| 验收 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4（与基线一致） |
| `verify_tokens` | ✅ **376 项**（+8，新增 §15） |
| `query_verify` 全套 | ✅ 52 / 42 / 31 / 37 / 6 / 22（全不变） |
| `trace_verify` | ✅ |
| **证伪测试** | ✅ 三处篡改**全部准确报红**：删 android 转场 · 改回 `CustomTransitionPage`（并指出 `app.dart`）· 换返回实现 |

### §15 新增断言的 8 条

1. `theme_builder` 配置了 `pageTransitionsTheme`
2. android 用 `CupertinoPageTransitionsBuilder`
3. iOS 用 `CupertinoPageTransitionsBuilder`
4. macOS 用 `CupertinoPageTransitionsBuilder`
5. **全库**无 `CustomTransitionPage` / `pageBuilder:`（两者都绕过 theme 转场）
6. 收藏清单有返回按钮（`context.pop()`）
7. 返回按钮文案为「返回」
8. 返回按钮用 `accent` 色（设计稿 `.back`）

🔑 第 5 条**必须全库扫描**而非只看 `app.dart` —— 将来在别的文件里加一个自定义转场，
同样会静默关掉那一页的手势，而编译器不报错。
⚠️ 且必须经 `_codeOnly()` 过滤：`app.dart` 的注释里**故意**解释了「为什么不用它」，
不过滤会造成**假红**。

---

## 四、方案 ③ 实施记录（2026-09-28 · 已落地）

白哥在样张中选定 **③ 毛玻璃栏底 + 平坦 item**。改动三处：

| # | 文件 | 改动 |
|---|---|---|
| 1 | `lib/theme/coevo_tokens.dart` | 新增派生 `tabBarSurface`（`page` 82% 不透明）+ 常量 `_tabBarSurfaceAlpha` |
| 2 | `lib/app.dart` | `_ClayTabBar.build`：`SafeArea` → **`ClipRect` + `BackdropFilter(blur 20)` + `DecoratedBox`（`tabBarSurface` 底 + `line` hairline）** |
| 3 | `lib/app.dart` | `_tab`：未选中项由 `Clay(raised)` → **裸 `GestureDetector` + `Padding`（平坦）** |

### 关键决策与依据

**① 为什么用派生 getter 而不是新增 token 字段**
栏底必须是**当前档的页面色**，否则三档出现色相断层。派生 → **只此一处定义，三档自动适配**（同 `clayFill => card` 的先例）。

**② 不透明度取 0.82 的实测依据**（按**最坏情形**验，因为栏后内容不同合成色也不同）

| 档 | 栏后有卡片 | 栏后是空白 |
|---|---|---|
| 墨 | 4.99 | 4.85 |
| 格 | 6.11 | 5.94 |
| 夜 | 7.25 | 7.42 |

（`ink2` vs 合成底 · 11px 小字要求 4.5 → 三档全部达标，最低 4.85）

**③ `ClipRect` 不可省** —— `BackdropFilter` 模糊的是**其身后的一切**（整个屏幕），不裁剪会把全屏拖进滤镜。Flutter 官方文档明确要求。

**④ 平坦项不提供按下反馈**（有意）—— `Clay` 的 `scale(.97)` 回弹语义是「有物理形态的物件被按下去」；平坦项无物理形态 → 加回弹是**语义错位**。照设计稿，靠选中态切换作反馈。

### 🔴 与「渐变」的关键区别（为什么这次能成）

| | 机制 | 结果 |
|---|---|---|
| 第 ② 轮「渐隐」 | **在栏上叠一层色带** | 🔴 色带本身可见（=「雾带」） |
| 现在「毛玻璃」 | **把栏后的内容模糊掉** | ✅ 不新增可见元素 |

**同是「让内容淡出」，机制不同** —— 渐变会留下它自己，毛玻璃不会。

### 验证

| 验收 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=0** / warning=13 / info=4 |
| `verify_tokens` | ✅ **378 项**（§13 重写：**极性反转**，从「禁背景层」→「必须有毛玻璃」） |
| `query_verify` 全套 | ✅ 52 / 42 / 31 / 37 / 6 / 22（全不变） |
| `trace_verify` | ✅ 97 项 |
| **证伪测试** | ✅ 四处篡改**全部报红**：去 `ClipRect` · 栏底色写裸值 · 未选中改回 `Clay(raised)` · 去掉 `GestureDetector` |

🔑 证伪时有个**正确行为**值得记：篡改成 `Clay(raised)` 但**没传 `fill`** →
「未选中项不显式给 fill」这条**保持绿**（因为 `raised` 本就不需要 fill）→ 
说明三条断言**互相独立、各司其职**，不是重复。

### 🔴 掉帧修复（2026-09-28 · 白哥实测「掉帧有点严重」后）

方案 ③ 落地后掉帧。查证后确认是**两个并存的真根因**（不是猜测，有实测数据支撑）：

| # | 根因 | 证据 | 修法 |
|---|---|---|---|
| **1** | **缺 `RepaintBoundary`** → 模糊区导致**全屏重绘** | 公开实测（Pixel 4a · 100×100 模糊区）：**不加 → 45fps；加上 → 60fps** | `RepaintBoundary` 包在 **`ClipRect` 外面** |
| **2** | **`_blurSigma = 20` 超出性能阈值** | 资料共识：**「sigma 超过 15 时性能消耗显著增加」**；旗舰推荐 5–10 | 20 → **10** |

🔑 **两条必须都修**：一条管**重绘的范围**，一条管**单次成本**。

**面积对比说明第 1 条为什么关键**：
本栏约 `390 × 90 ≈ 3.5 万 px²`，而全屏约 `390 × 844 ≈ 33 万 px²` → **约 9.4 倍**的无谓开销。

**为什么 sigma 取 10 不损失观感**：`sigma ≈ CSS blur-radius / 2` → 10 相当于 CSS `blur(20px)`，仍是明显的毛玻璃。

#### ⚠️ 关于 debug / release（重要）

白哥当时测的是 **`app-debug.apk`**（`app-release.apk` 仍是旧包）。
- **debug（JIT）会显著放大** `BackdropFilter` 的开销 → 「掉帧严重」有一部分是**模式假象**
- 但**第 1 条是结构问题**，与编译模式无关 → **release 下同样存在** → 所以这两处该修

#### ✅ 顺带排查：全库另有 2 处模糊，但**不是隐患**

| 位置 | 类型 | 判定 |
|---|---|---|
| `review_screen.dart:1263` | **`ImageFiltered`** | ✅ 安全 |
| `review_card_widget.dart:410` | **`ImageFiltered`** | ✅ 安全 |

🔑 **关键区别**：
- **`BackdropFilter`** = 模糊**其下层（backdrop）** → **需要读屏幕像素** → 贵
- **`ImageFiltered`** = 对**自己的 child** 应用滤镜 → **不读 backdrop** → 便宜得多

且这两处的 `sigma` 是 `_isVerifying ? 5.0 : 0.0` —— **只在「验证中」短暂生效**，
5.0 也在低端推荐区间内。（`sigma = 0` 时等于无模糊。）

#### 验证

| 验收 | 结果 |
|---|---|
| `analyze_inproc` | ✅ **error=0** |
| `verify_tokens` | ✅ **382 项**（§13 新增 4 条性能断言） |
| `query_verify` 全套 / `trace_verify` | ✅ 全不变 |
| **证伪测试** | ✅ 三条准确报红：去 `RepaintBoundary` · `RepaintBoundary` 位置颠倒 · `sigma` 改回 20 |

#### 🔻 若仍掉帧的兜底阶梯（成本从低到高）

1. `_blurSigma` 继续降（10 → 6~8）—— 一行
2. **缩小模糊面积**：不模糊 `SafeArea` 的 bottom 区（栏高约 90px 中占 24–34px，省 ~30%）
3. **去掉 `BackdropFilter`，改纯半透明**（成本 ≈ 0）
   — 资料明确支持：「**用户通常无法区分微妙的透明效果和真正的模糊效果**」
4. 退回**实心 `card`** 栏底（方案 ④，零成本但白哥当时不喜）

---

## 五、后续待办

- [ ] 真机验侧滑：**收藏清单 / 阅读器 / chat / 屏幕边缘起手**（四个方向都试）
- [ ] 真机验毛玻璃：**release 包**滚动帧率（debug 会误导）+ 三档观感（重点夜档）
- [ ] 设计稿 `.tb` 的 `transition: color .28s, background .28s` **未实现**
      —— 未选中（无底）→ 选中（药丸）是**形状**变化，`Clay` 与裸 `Padding` 无法直接插值，
      需重写为 `AnimatedContainer`。**收益待评估，未默默加**。
- [ ] chat 页的**页面级**返回（v1 预留功能启用时补）
