import 'package:flutter/material.dart';
import 'dart:async';
// `ImageFilter` 由 `dart:ui` 提供，**不经** material/painting/rendering 导出
// → 必须显式引入（`show` 限定，避免与 material 的符号重名）。
// ⚠️ `dart:ui` 不是 web-only 库（`dart:html`/`dart:js` 才是）→ 无需平台守卫。
import 'dart:ui' show ImageFilter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'theme/coevo_tokens.dart';
import 'theme/clay.dart';
import 'theme/tokens_ext.dart';
import 'theme/theme_builder.dart';
import 'screens/home_screen.dart';
import 'screens/achievements_screen.dart';
import 'screens/about_screen.dart';
import 'screens/aggregate_page_screen.dart';
import 'screens/bookmark_list_screen.dart';
import 'screens/review_screen.dart';
import 'screens/review_session_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/subscribe_screen.dart';
import 'pages/user/distribution/notification_panel.dart';
import 'providers/auth_provider.dart';
import 'providers/iap_provider.dart';
import 'providers/subscription_provider.dart';
import 'providers/theme_provider.dart';
import 'services/iap_plan.dart';
import 'services/iap_service.dart';
import 'widgets/achievement_unlock_overlay.dart';
import 'widgets/dialog_overlay.dart';

final goRouter = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    return null;
  },
  routes: [
    GoRoute(
      path: '/share/:refCode',
      redirect: (context, state) {
        final refCode = state.pathParameters['refCode'] ?? '';
        final campaignId = state.uri.queryParameters['campaign_id'] ?? '';
        var dest = '/home?ref=$refCode';
        if (campaignId.isNotEmpty) dest += '&campaign_id=$campaignId';
        return dest;
      },
    ),
    GoRoute(
      path: '/',
      redirect: (context, state) => '/home',
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _ShellScaffold(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) => const HomeScreen(),
              routes: [
                // 🔴 收藏清单（3.5）= **「阅读」tab 内的子视图**
                //
                // 挂成 `/home` 的**子路由** → go_router 把它渲染在**该分支的 Navigator** 里
                // → **底部 tabbar 保留**，且 iOS 右滑返回可用。
                //
                // 🔑 依据：设计稿 mockup **画了 tabbar 且没有返回按钮**；
                //    产品原则「**收藏是视图非 tab**」。
                //
                // ⚠️ **与阅读器 `/article/:id` 的形态不同，这不是疏漏**：
                //    · 「清单」是「阅读」这个 tab 的**内容** → 留在 shell 内
                //    · 「阅读器」是**覆盖全屏的沉浸态**（spec §5.1「底部：无」）→ 顶层路由
                //    判断依据：**它是不是 tab 的内容**。
                //
                // 🔑 返回方式：点「阅读」tab（`_ShellScaffold` 的
                //    `goBranch(i, initialLocation: i == currentIndex)` 会回到分支初始页）
                //    或右滑手势。设计稿 CSS 里那个未使用的 `.bm-hd .back` 是「全屏+返回」
                //    方案的残留 —— 本实现按 mockup 走子视图，故不用它。
                GoRoute(
                  path: 'bookmarks',
                  builder: (context, state) => const BookmarkListScreen(),
                ),
                // 🔴 这里**曾经**有 `/home/words`（3.4d 的独立生词本页）—— 已删除。
                //
                // 原因（2026-09-28 白哥澄清）：**生词本就是复习页本身**，不是另一个页面。
                // 依据 `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §6.2
                // （白哥原话：「生词本就是复习管理，其实复习页面只要一个就行了……
                //   就不要移入移出了」）。
                //
                // 🔑 我原先把它做成了「阅读 tab 下的子页」，方向错了 —— 于是存在
                //    **两个入口指向同一份数据**（这个子页 + 复习 tab），
                //    而两者形态不同（一个只有列表、一个当时还是 K12 遗留）。
                //    → 现在统一到**复习 tab**（`/review`，见上面的 StatefulShellBranch）。
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/review',
              builder: (context, state) => const ReviewScreen(),
            ),
          ],
        ),
        // 🔴 第三 tab = **「我的」**（设计稿定案：导航是「阅读 / 复习 / 我的」）。
        //    原「成就」页（K12 时代 `_k12Progress`，999 行）在新导航里**没有位置**
        //    → 已随 3.1 删除。
        //    个人页原本是 push 页（`/profile`）→ 现提升为一级 tab，路径改 `/mine`；
        //    顶层 `/profile` 路由同步移除（同一页面留两个入口会让栈行为分叉）。
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/mine',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
    // 🔴 阅读器（3.4a）—— 从信息流卡片进入，**全屏**（spec §5.1「底部：无」）。
    //    ⚠️ 必须排在兜底路由 `/:unknown` 之前，且它本身是**两段**路径
    //    （`/:unknown` 是单段）→ 不会被兜底吞掉。
    //    🔑 **2026-09-28 改为 `builder:`** —— 原先这里 (与 `/chat`) 用
    //    `CustomTransitionPage` + 手写 `SlideTransition`。那个写法**看起来**是
    //    「从右滑入」，与 Cupertino 转场几乎一样，**但它绕过了
    //    `ThemeData.pageTransitionsTheme`** → 也就绕过了
    //    `CupertinoRouteTransitionMixin.buildPageTransitions` 内部包的
    //    `_CupertinoBackGestureDetector` → **边缘右滑返回被静默关掉**。
    //
    //    🔑 教训：**自定义转场 ≠ 自定义动画** —— `transitionsBuilder` 只能改动画，
    //       而「返回手势」是**转场 builder** 提供的。自己写转场 = 自己放弃手势。
    //    → 用 `builder:` 让路由走 theme 的统一转场：视觉上仍是「右滑入场」，
    //      **额外获得**手势 + 阴影 + 下层视差（比手写 SlideTransition 更接近原生）。
    GoRoute(
      path: '/article/:id',
      builder: (context, state) => ReaderScreen(
        // 解析失败 → -1 → 阅读器走「找不到这篇文章」分支（不抛异常、不白屏）
        articleId: int.tryParse(state.pathParameters['id'] ?? '') ?? -1,
      ),
    ),
    // 🔴 复习翻卡会话（3.6 第二步）—— **全屏**，与阅读器同理（顶层路由）。
    //
    // 🔑 为什么必须是顶层路由（2026-09-28 白哥真机报「四键被底部栏遮住，
    //    拉动也出不来」）：
    //    翻卡原先做成 `review_screen` 内的一个状态（`bool _inCard`）→
    //    它继承了「复习 tab 那一屏」的布局约束，其中包含 `_ShellScaffold` 的
    //    `extendBody: true` + 底部 tabbar ≈100px → 四键（固定在页面最底部、
    //    不参与滚动）**被盖住且拉不出来**。
    //    🔴 而设计稿的翻卡 mockup **根本没有 tabbar**
    //    （`visual-word-card-target` 的 `.phone`：`pbar` + `pbody` + `card`，
    //     `tabbar`/`nav`/`bottom` 0 命中）→ 它是**全屏沉浸态**。
    //
    //    🔑 判据（项目已定）：**它是不是 tab 的内容** ——
    //      是 → 页内/子路由（保留 tabbar）；否（覆盖全屏的沉浸态）→ 顶层路由。
    //    阅读器 `/article/:id` 就是这么处理的。
    GoRoute(
      path: '/review/session',
      builder: (context, state) => const ReviewSessionScreen(),
    ),
    // ── 聚合页（词根族 / 词源族）──────────────────────────────
    //
    // 从复习卡片的 ① / ② 点进来（白哥 2026-09-28：「之前说词根词缀、
    // 词源故事点击应该进入聚合页，也没有实现」）。
    //
    // 🔑 同样按**顶层路由**处理（判据同上：覆盖全屏的沉浸态，不是 tab 的内容）。
    //    阅读器 `/article/:id` 与翻卡 `/review/session` 都是这么放的。
    //
    // 参数：
    // · `:pageId` —— `aggregate_page.id`（1,777 页，数据已就绪）
    // · `?from=` / `?slot=` —— 来处（「来自 intercept 的 ① 词根词缀」）。
    //   用 **query 参数**而不是 `extra`：这类纯字符串上下文可序列化、
    //   刷新/深链也还在；`extra` 在走系统返回后容易丢。
    // ⚠️ `pageId` 解析失败 → 传 -1（查不到 → 页面显示「这一页暂时打不开」），
    //    而不是让路由抛错把用户卡在空白页。
    GoRoute(
      path: '/aggregate/:pageId',
      builder: (context, state) => AggregatePageScreen(
        pageId: int.tryParse(state.pathParameters['pageId'] ?? '') ?? -1,
        fromWord: state.uri.queryParameters['from'],
        fromSlotLabel: state.uri.queryParameters['slot'],
      ),
    ),
    // 成就墙（二级页 · 顶层路由）—— 从「我的」页「其他」组进入
    GoRoute(
      path: '/achievements',
      builder: (context, state) => const AchievementsScreen(),
    ),
    // 关于（二级页）—— 从「我的」页「其他」组进入
    // 🔑 与 `/achievements` 同级：两者都是「我的」页的**二级信息页**，
    //    不是 tab 的内容（所以走顶层路由，不带 tabbar）。
    GoRoute(
      path: '/about',
      builder: (context, state) => const AboutScreen(),
    ),
    // 🗑 2026-09-29 已删除：`/chat` 路由（+ `screens/chat_screen.dart` import）
    //    —— 产品已定**不做 chat/UGC**；且该路由**全库无任何 push/go/named 跳转**
    //       （即「有路由、无入口」的孤儿页）→ 用户根本到不了。
    //    同时删除其整条依赖链（均为闭包，已用 import 反向图验证）：
    //      chat_screen · screens/chat/{5} · review_dialog · review_card_widget
    //      · pipelines/{4 子策略 + 主策略 + registry} · providers/plan_provider
    //    ⚠️ 注意：`widgets/review_dialog.dart` / `review_card_widget.dart` **不是复习页组件** ——
    //       名字像，但属**旧架构（走后端）**的 chat 专用件；现役 `review_screen.dart`
    //       已自建复习页（数据源全走端侧 `user.db`），**不复用它们**。
    // 🗑 2026-10-04：`/pay`（`PayScreen` 微信扫码支付页）已删除 ——
    //    Apple IAP 下**没有「下单 + 二维码 + 轮询」这一环**
    //    （购买由 StoreKit 在客户端完成），整页 552 行无对应物。
    //    订阅入口统一为独立页 `/subscribe`（见 `screens/subscribe_screen.dart`）。
    GoRoute(
      path: '/subscribe',
      builder: (context, state) => const SubscribeScreen(),
    ),
    GoRoute(
      path: '/notifications',
      builder: (context, state) => const NotificationPanel(),
    ),
    // 兜底路由：未知路径->首页
    GoRoute(
      path: '/:unknown',
      redirect: (context, state) => '/home',
    ),
  ],
  errorBuilder: (context, state) {
    // 路由错误时回到首页，不白屏
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GoRouter.of(context).go('/home');
    });
    return const SizedBox.shrink();
  },
);

class _ShellScaffold extends StatelessWidget {
  final StatefulNavigationShell navigationShell;
  const _ShellScaffold({required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🔴 `extendBody: true` —— 让 body **延伸到底部导航之后**（2026-09-27）。
      //
      // 不加的话，tabbar 占据一条**独立地带**（`Scaffold` 的 `body` 不含这块高度）→
      // 滚动到底时，最后一张卡片与按钮之间会留一道**静止空白**
      // （`ListView` 底部 padding + tabbar 顶部 padding ≈ 36px，再加按钮自身高度）。
      // 观感是「**内容被切掉一块，下面飘着三个按钮**」——这就是「一条栏」的实体感。
      //
      // 🔑 所以用户感知的「底部栏很破坏视觉」**不是颜色问题**：三处本来就是同一个
      //    `page` 色（`scaffoldBackgroundColor` / tabbar 背景 / 设计稿 `.phone`）——
      //    把背景「改成透明」不会有任何视觉变化。真正的问题是**结构**。
      //
      // ⚠️ 三处必须配套改（只改这里会更难看）：
      //    ① 本处 `extendBody`
      //    ② `_ClayTabBar` 的**毛玻璃栏底** —— 它让「正文在栏下模糊淡出」而非硬截断；
      //       去掉栏底会让正文直接压在未选中 tab 的文字上（2026-09-27 实测「看不清」）
      //    ③ 各 tab 页滚动容器的底部 padding → 留出 tabbar 高度（见 `home_screen`）
      //       —— 否则滚动到底时最后一项被按钮压住
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: _ClayTabBar(
        currentIndex: navigationShell.currentIndex,
        onSelect: (i) {
          navigationShell.goBranch(i,
              initialLocation: i == navigationShell.currentIndex);
        },
      ),
    );
  }
}

/// 底部导航 —— 自绘**粘土药丸**（设计稿 `visual-feed-bookmark` 的 `.tabbar` / `.tb`）。
///
/// # 为什么不用 M3 `NavigationBar`
/// 设计稿的选中态是「**强调色填充药丸 + 实体投影**」（粘土语汇里的「激活」），
/// 而 M3 `NavigationBar` 的选中表达是**药丸背景 + 图标变色**、且**未选中项仍有容器色**
/// —— 形状与材质都对不上，调参数也调不出来（`indicatorColor` 只能改颜色）。
/// 这是 Step 2「粘土组件已建但未接入页面」之后**第一处真正用上 `Clay` 的界面**。
///
/// # 逐项对齐设计稿
/// | 设计稿 | 值 | 本实现 |
/// |---|---|---|
/// | `.tabbar` padding | `12px 20px 24px` | 上 12 / 左右 20 / 下 **`SafeArea(minimum:24)`** |
/// | `.tabbar` gap | `9px` | 9 |
/// | `.tb` padding | `8px 0 7px` | 同 |
/// | `.tb` 圆角 | **`17px`** | **显式覆盖 token 档位圆角**（见下） |
/// | `.tb` 文字 | 11 / w600 | 同（字体见下） |
/// | `.tb` 未选中 | 只有 `color:ink3`，无背景无阴影 | ✅ **平坦**（照设计稿）；字色改 `ink2`（对比度，见下） |
/// | `.tb.on` | `background:accent` + `color:accentInk` + 投影 | `Clay(state: selected)` → 自动取 `accent` / `accentInk` / `accentOut` |
/// | `.tb .ic` | `15×15` · `opacity:.75`（选中 → 1） | 同 |
/// | `.tb .ic` 与文字间距 | `4px` | 4 |
///
/// ## 🔴 未选中项：**四轮演进 → 最终「平坦」**（2026-09-28）
///
/// ### 演进表（**别再来回改**）
/// | 轮 | 未选中 | 栏底 | 白哥反馈 |
/// |---|---|---|---|
/// | ① | **平坦**（照设计稿 `.tb`） | 透明 | 「看不清」—— `extendBody` 后正文从下方穿过 |
/// | ② | `pressed` + `sunken`（**凹陷**） | 透明 | 🔴「**凹陷的，不好看**，还是用凸起的视觉效果吧」 |
/// | ③ | **`raised`（凸起药丸）** | 透明 | 🔴「**还是有割裂感**，这是设计上的问题」 |
/// | ④ **现在** | **平坦** | **毛玻璃** | ✅ |
///
/// ### 🔑 关键转折：底该加在「**栏**」，不是「**每个 item**」
/// ①~③ 三轮都在**item 这一层**加东西（底色 / 阴影）来解决「正文穿过」——
/// 但 ③ 的割裂感暴露了方向错了：
/// **给每个 item 加实体 → 底部变成三个独立物件 → 「一条栏」的整体感消失。**
/// ④ 把遮罩上移到**栏底**（`BackdropFilter` + `page` 82%）→ item 得以回平坦。
///
/// ### 🔑 字色必须是 `ink2`（`ink3` 在任何候选底色上都不达标）
/// | 档 | `ink3` on `page`（设计稿） | 栏后有卡片 | 栏后是空白 | **`ink2` 实测** |
/// |---|---|---|---|---|
/// | 墨 | 🔴 2.74 | 4.99 | 4.85 | ✅ |
/// | 格 | 🔴 2.97 | 6.11 | 5.94 | ✅ |
/// | 夜 | 🔴 4.16 | 7.25 | 7.42 | ✅ |
///
/// → `ink3` **换任何底色都救不回来**（`page` 2.74 / `sunken` 2.58 / `card` 3.20），
///   **必须换字色**。⚠️ 代价：未选中项**比设计稿重一点**（设计稿用 `ink3` 表「次要」）——
///   🔑 **可读性优先于层级微差**。
///
/// ### ⚠️ 平坦项**不提供按下反馈**（有意）
/// `Clay` 的按下回弹（`scale(.97)`）语义是「有物理形态的物件被按下去」；
/// 平坦项没有物理形态 → 加回弹是**语义错位**。照设计稿，靠**选中态切换**作反馈
/// （设计稿 `.tb` 的 `transition: color .28s, background .28s` 也是此意）。
/// 🔴 那个 `.28s` 过渡**本实现未做** —— 未选中（无底）→ 选中（药丸）是**形状**变化，
/// `Clay` 与裸 `Padding` 之间无法直接插值（需重写为 `AnimatedContainer`），收益待评估。
///
/// ## ⚠️ 与设计稿的已知偏差（均为有意，非疏漏）
/// 0. 🆕 **栏底由「无背景」改为「毛玻璃 + `page` 82%」**（2026-09-28 · 白哥在样张中选定方案 ③）——
///    设计稿是**静态稿**，未定义「正文从按钮下方穿过」时的表现 → 本层是**补空**。
///    演进见 `build()` 的四轮表。
///    ⚠️ **未选中项的「平坦」已回归设计稿**（`ink2` 字色是唯一保留的偏离，为对比度）。
/// 1. **圆角取 `17` 而非 token 档位值**：设计稿 `.tb` 的 `border-radius:17px` **写死在
///    组件上、不在主题变量里**（三档共用 17）→ 显式传 `borderRadius` 覆盖
///    token 的 `clay.radiusFor()`（那会得到「墨 14.3 / 格 14 / 夜 13.2」）。
///    🔑 这也是三档里唯一「圆角不随主题变」的元素 —— 照设计稿。
///    几何仍然成立：md 档内阴影偏移 3 × 3 = 9 ≤ 17 ✅（§3.4 约束）
/// 2. **字体用 `CoFonts.uiSans` 而非设计稿的 `--round`**：`--round` 是 Quicksand，
///    项目**未打包**该字体（为一处 11px 标签引字体文件不划算）→ 与 `FeedCard` 同一取舍。
/// 3. 🆕 **顶部 hairline**（`t.line` 1px）—— 设计稿 `.tabbar` 没有；毛玻璃栏底若无边界，
///    小屏上易与内容糊在一起（见 `build()`）。
///
/// ## ✅ 背景：**毛玻璃**（2026-09-28 定案 · 四轮演进）
///
/// | 阶段 | 背景 | 结果 |
/// |---|---|---|
/// | 原状 | `ColoredBox(page)` | 视觉等价（那时未开 `extendBody`） |
/// | 加 `extendBody` 后 | 「透明 → page」**渐隐** | 🔴 白哥：「**渐变不好看**」 |
/// | 第二轮 | **完全透明** | 🔴 白哥：「**还是有割裂感**」（item 层背了锅，见「未选中项」） |
/// | **现在** | **毛玻璃**（`BackdropFilter` + `page` 82% + hairline） | ✅ |
///
/// **渐变为什么不好看**（原文保留）：渐变区（`stops: [0, 0.55]`）覆盖 tabbar 上半段 →
/// **白色卡片**滚进这块区域时下边缘被逐层**雾化淡出**，形成一条**看得见的雾带**。
/// 🔑 端点色与底色相同也消不掉它 —— 因为被雾化的是**穿过的卡片**，不是背景。
///
/// ⚠️ **与「渐变」的关键区别**（为什么这次能成）：
/// 渐变是**在栏上叠一层色带**（色带本身可见）；毛玻璃是**把栏后的内容模糊掉**
/// （不新增可见元素）→ 所以不会形成「带」。**同是"让内容淡出"，机制不同。**
///
/// ⚠️ **`ClipRect` 不可省**：`BackdropFilter` 模糊的是**其身后的一切**（整个屏幕），
/// 不裁剪会把全屏拖进滤镜。Flutter 官方文档明确要求。
///
/// ⚠️ **性能**：本组件**每帧重绘**（`BackdropFilter` 固有代价）→ 需 release 真机测帧率；
/// 若掉帧，第一个该降的是 `_blurSigma`。
///
/// ## 选中态的 inset 取 token 而非设计稿硬编码值
/// 设计稿 `.tb.on` 把内阴影写死成 `rgba(0,0,0,.15)` / `rgba(255,255,255,.26)`；
/// 而 spec §3.3.1 明文「**选中态与默认态共用同一套内阴影**」→ **按 spec**
/// 用 `clay.shade` / `clay.light`（`Clay` 的默认行为，无需额外处理）。
class _ClayTabBar extends StatelessWidget {
  const _ClayTabBar({required this.currentIndex, required this.onSelect});

  final int currentIndex;
  final ValueChanged<int> onSelect;

  static const List<({IconData icon, String label})> _items = [
    (icon: Icons.article_outlined, label: '阅读'),
    (icon: Icons.replay_outlined, label: '复习'),
    (icon: Icons.person_outline, label: '我的'),
  ];

  /// 设计稿 `.tb` padding: `8px 0 7px`。
  static const EdgeInsets _tabPadding = EdgeInsets.fromLTRB(0, 8, 0, 7);

  /// 设计稿 `.tb` `border-radius:17px`（**不随主题变**，见类文档 ⚠️1）。
  static final BorderRadius _tabRadius = BorderRadius.circular(17);

  /// 栏底毛玻璃的模糊半径（px）—— 20 接近 iOS 系统栏的观感。
  ///
  /// ⚠️ **这是性能旋钮**：`BackdropFilter` 会让本组件**每帧重绘**，
  /// 栏底毛玻璃的模糊半径（px）。
  ///
  /// ## 🔴 为什么是 10 而不是更大（性能阈值 · 2026-09-28 实测掉帧后调）
  /// 参考多份 Flutter 模糊性能资料的**共识区间**：
  ///
  /// | 设备档 | 推荐 sigma | 最大 sigma |
  /// |---|---|---|
  /// | 旗舰 | 5–10 | 15 |
  /// | 中端 | 3–7 | 10 |
  /// | 低端 | 1–5 | 7 |
  ///
  /// 🔑 且有一条明确阈值：**「sigma 超过 15 时性能消耗显著增加」**。
  ///    首版取 **20 → 直接落在阈值之外**（白哥实测「掉帧有点严重」）。
  ///    → 现取 **10**：在旗舰推荐区间内、且远低于 15 阈值。
  ///
  /// 🔑 视觉代价很小：`sigma ≈ CSS blur-radius / 2` → 10 相当于 CSS `blur(20px)`，
  ///    仍是**明显**的毛玻璃（不是「看不出模糊」）。
  ///
  /// ⚠️ 仍是性能旋钮 —— 若还掉帧，下一个该动的是它（继续降到 6~8），
  ///    或直接改用 `CoEvoTokens.tabBarSurface` 的**半透明无模糊**写法（成本≈0）。
  static const double _blurSigma = 10;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🔴🔴 **毛玻璃栏底**（2026-09-28 · 白哥在样张中选定方案 ③）
    // 样张：`docs/design/tabbar-variants-2026-09-28.html`（5 方案 × 三档 × 含穿透态）
    //
    // ## 演进（**四轮 · 别再来回改**）
    // | 轮 | 栏底 | item | 白哥反馈 |
    // |---|---|---|---|
    // | ① | 透明（照设计稿 `.tabbar`） | 平坦 | 「看不清」—— `extendBody` 后正文穿过 |
    // | ② | 渐变遮罩（透明→`page`） | 平坦 | 「**渐变不好看**」—— 卡片被雾化成**雾带** |
    // | ③ | 透明 | **三个凸起药丸** | 「**还是有割裂感**，这是设计上的问题」 |
    // | ④ **现在** | **毛玻璃** | **平坦** | ✅ |
    //
    // ## 🔑 第 ③ 轮「割裂感」的根因：**底加错了层**
    // 设计稿（`visual-feed-bookmark:164-168`）的意图是「**一条栏 + 只有选中项是实体**」：
    //   · `.tb     { color:var(--ink3); }`  ← 未选中**无底、无影**（这才是「栏」）
    //   · `.tb.on  { background:accent; box-shadow:…; }` ← 唯一实体
    // 而第 ③ 轮为了修「穿透看不清」，给**每个**未选中项都加了填充 + 外阴影 →
    // 底部变成**三个各自独立的白色物件** → 「一条栏」的整体感消失。
    //
    // 🔑 **加底色这个动作没错，落点错了** —— 底该加在「**栏**」这一层，不是「每个 item」。
    //
    // ## 现在的结构
    //   · **栏底**（本层）：`ClipRect` + `BackdropFilter(blur)` + `page` 82% 半透明
    //     → 内容在栏下**被模糊淡出**，而非被硬截断；「内容仍在继续」的观感保留
    //   · **item**：回设计稿的**平坦**（见 `_tab()`）→ 视觉重心只落在选中项
    //
    // ## ⚠️ `ClipRect` **不可省**
    // `BackdropFilter` 模糊的是**其身后的一切**（整个屏幕）→ 不裁剪会把全屏拖进滤镜。
    // Flutter 官方文档明确要求用 `ClipRect` 包住。
    //
    // ## ⚠️🔴 `RepaintBoundary` **不可省**（2026-09-28 掉帧后补 · 本次修复的关键）
    //
    // `BackdropFilter` 会让**其所在的整棵绘制子树**参与重绘判定 ——
    // 不加隔离层时，**body 每滚动一帧都会把「模糊 + 全屏」一起重做**。
    //
    // 🔬 有公开实测数据（Pixel 4a · 100×100 模糊区）：
    //   · **不加** `RepaintBoundary` → **全屏重绘** → **降到 45fps**
    //   · **加上** → 只重绘模糊区 → **稳定 60fps**
    //   （本栏面积约 390×90 ≈ 3.5 万 px²，而全屏 ≈ 33 万 px² → **约 9.4 倍**的浪费）
    //
    // 🔑 加在 `ClipRect` **外面**（`RepaintBoundary(child: ClipRect(child: BackdropFilter))`）
    //    —— 让「裁剪 + 模糊」整体成为一个独立图层。
    //
    // ## 🔑 与 sigma 的配合（本次同时改的两处）
    // 另一个根因是 `_blurSigma` 原本取 **20**，超出「**超过 15 性能显著增加**」的阈值
    // → 已降到 **10**（见该常量的文档）。
    // **两处一起改**才够：`RepaintBoundary` 解决「重绘范围」，sigma 解决「单次成本」。
    //
    // ## 为什么可以偏离设计稿的「`.tabbar` 无背景」
    // 设计稿是**静态稿**，它没有定义「正文从按钮下方穿过」时的表现。
    // 这一层与 `pageTransitionsTheme` 同类：**补空**，不是改稿。
    //
    // ## 🔑 顶部 hairline 的作用
    // `t.line` 色的 1px 上边线 —— 让「这是一条栏」的边界可辨。
    // 设计稿 `.tabbar` 没有它；但毛玻璃栏底若无边界，小屏上易与内容糊在一起。
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 🔑 走 token 派生（`page` 82%）—— **不写裸色值**，三档自动适配。
              //    不透明度 0.82 的实测依据见 `CoEvoTokens.tabBarSurface`。
              color: Color(t.tabBarSurface.argb32),
              border: Border(top: BorderSide(color: Color(t.line.argb32))),
            ),
            child: SafeArea(
              top: false,
              // 设计稿的 `24px` 底距 = iPhone 安全区；有 home indicator 时取更大者
              minimum: const EdgeInsets.only(bottom: 24),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < _items.length; i++) ...[
                      if (i > 0) const SizedBox(width: 9),
                      Expanded(child: _tab(i, t)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(int i, CoEvoTokens t) {
    final item = _items[i];
    final on = i == currentIndex;
    // 🔴 未选中用 `ink2` 而非设计稿的 `ink3`（2026-09-27 实测「看不清」后定）
    //
    // 实测对比度（11px 小字 · WCAG 要求 **4.5**）—— 底色现在是**栏底**（`tabBarSurface`，
    // 即 `page` 82% 叠在栏后内容上；栏后不同内容合成出的底色不同，故按最坏情形取两列）：
    // | 档 | `ink3` on `page`（设计稿） | 栏后有卡片 | 栏后是空白 | **`ink2` 实测** |
    // |---|---|---|---|---|
    // | 墨 | 🔴 2.74 | 4.99 | 4.85 | ✅ |
    // | 格 | 🔴 2.97 | 6.11 | 5.94 | ✅ |
    // | 夜 | 🔴 4.16 | 7.25 | 7.42 | ✅ |
    //
    // 🔑 **死结是 `ink3` 本身**：它在**任何**候选底色上都不足 4.5
    //    （`page` 2.74 / `sunken` 2.58 / `card` 3.20）→ **换底色救不了**，必须换字色。
    // ⚠️ 代价（如实记录）：`ink2` 让**未选中项比设计稿重一点** —— 设计稿用 `ink3`
    //    表达「次要」，但那个色值在 11px 下不可读。
    // 🔑 **可读性优先于层级微差**（同「线索不压过答案」的原则）。
    final fg = on ? t.accentInk : t.ink2;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 设计稿图标是 `15×15` 的**圆角空方块占位**（`.ic` 是 border 画的），
        // 用真图标代替时沿用同样的 15px 与 `.75` 透明度。
        Opacity(
          opacity: on ? 1 : 0.75,
          child: Icon(item.icon, size: 15, color: Color(fg.argb32)),
        ),
        const SizedBox(height: 4),
        Text(
          item.label,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(fg.argb32),
          ),
        ),
      ],
    );

    if (!on) {
      // 🔴 **未选中 = 平坦**（2026-09-28 回归设计稿 `.tb{color:…}`：无底、无影、无圆角）
      //
      // ## 四轮演进（**别再来回改**）
      // | 轮 | 未选中 | 白哥反馈 |
      // |---|---|---|
      // | ① | 平坦（照设计稿） | 「看不清」—— 根因是 **`extendBody` 后正文穿过** |
      // | ② | `pressed` + `sunken`（凹陷） | 🔴「**凹陷的，不好看**」 |
      // | ③ | `raised`（凸起药丸） | 🔴「**还是有割裂感**，这是设计上的问题」 |
      // | ④ **现在** | **平坦** | ✅（穿透问题已由「**栏底毛玻璃**」在**栏**这一层解决） |
      //
      // ## 🔑 为什么能回平坦了
      // ① 轮看不清的**真因是「内容压在文字上」**，而本轮把遮罩加在了**栏底**
      //    （`BackdropFilter` + `page` 82%）→ 内容在**栏下被模糊**，不再压字。
      //    → 于是**不需要**给每个 item 加实体来挡内容。
      //
      // ## 🔑 平坦项**不提供按下反馈**（如实记录）
      // `Clay` 的按下回弹（`scale(.97)`）表达的是「有物理形态的物件被按下去」——
      // 平坦项**没有物理形态**，加回弹是**语义错位**。
      // → 照设计稿：靠**选中态切换**本身作反馈（设计稿 `.tb` 的
      //   `transition: color .28s, background .28s` 也是这个意思）。
      // ⚠️ 设计稿那个 `.28s` 过渡**本实现未做** —— 未选中（无底）→ 选中（药丸）
      //    是**形状**变化，`Clay` 与裸 `Padding` 之间无法直接插值，
      //    需要重写成 `AnimatedContainer`，收益待评估。**不默默加**。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(i),
        child: Padding(padding: _tabPadding, child: content),
      );
    }

    // 选中 = 粘土「激活」：填充 `accent` + 外阴影染 `accentOut`（Clay 内部自动选）
    return Clay(
      state: ClayState.selected,
      onTap: () => onSelect(i),
      padding: _tabPadding,
      borderRadius: _tabRadius,
      child: content,
    );
  }
}

class CoEvoApp extends ConsumerStatefulWidget {
  const CoEvoApp({super.key});

  @override
  ConsumerState<CoEvoApp> createState() => _CoEvoAppState();
}

class _CoEvoAppState extends ConsumerState<CoEvoApp> {
  Timer? _subTimer;
  DateTime? _lastDismissed;
  int _dismissCount = 0;
  bool _showSubExpired = false;

  static const List<int> _backoffMinutes = [10, 30, 60, 120, 360];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 🔴 IAP **预热**（必须在启动时 read 一次）——
      //    `iapServiceProvider` 是懒加载的：不预热的话，用户若从不打开
      //    订阅页 /「我的」页，商店在**启动瞬间**投递「上次未完成的事务」时就漏了
      //    （事务滞留 → 每次启动重复投递、再次购买报「重复事务待处理」）。
      //    ⚠️ 只 read（创建服务 + 订阅事件流），无 UI 副作用。
      ref.read(iapServiceProvider);
      ref.read(authProvider.notifier).tryRestore();
      // 等 auth 恢复完成后首次检查
      Future.delayed(const Duration(seconds: 3), _checkSubscription);
      // 每 5 分钟轮询
      _subTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => _checkSubscription());
    });
  }

  @override
  void dispose() {
    _subTimer?.cancel();
    super.dispose();
  }

  /// 检查订阅状态并按需驱动「已到期」覆盖层。
  ///
  /// 🔴 2026-10-04（支付批次）：判定源改为**端侧 IAP 优先**。
  ///    原实现只看后端 `subscriptionProvider` ⇒ 用户**刚买完**、
  ///    后端还没收到 `/api/iap/verify` 对账的那段时间里会**误弹「已到期」**
  ///    （端侧已解锁、后端尚未记账）—— 这正是「端侧权威」要解决的问题。
  ///    回退分支保留：IAP 不可用时（如非 iOS 平台）仍用后端记录。
  void _checkSubscription() {
    final auth = ref.read(authProvider);
    final iap = ref.read(iapServiceProvider).snapshot;
    final isTrial = (auth.username ?? '').startsWith('trial_');

    if (iap.availability == IapAvailability.available) {
      _applyExpired(
        expired: iap.entitlement == IapEntitlementStatus.expired,
        isTrial: isTrial,
      );
      return;
    }

    // 回退：IAP 不可用 → 沿用后端记录
    if (!auth.isAuthenticated || auth.userId == null) return;
    ref.fetchSubscription().then((_) {
      _applyExpired(
        expired: ref.read(subscriptionProvider).isExpired,
        isTrial: isTrial,
      );
    });
  }

  /// 按「是否已到期」驱动覆盖层显隐（含 backoff）。
  void _applyExpired({required bool expired, required bool isTrial}) {
    // 距上次关闭时间按 dismiss 次数递增（已显示的覆盖层不在此限，支付后需立即刷新）
    if (_lastDismissed != null && !_showSubExpired) {
      final idx = _dismissCount.clamp(0, _backoffMinutes.length - 1);
      final minWait = _backoffMinutes[idx];
      if (DateTime.now().difference(_lastDismissed!).inMinutes < minWait) {
        return;
      }
    }

    // 临时账户不弹订阅覆盖层，引导注册由 ChatScreen 处理
    if (expired && mounted && !_showSubExpired && !isTrial) {
      setState(() => _showSubExpired = true);
    }
    // 订阅已激活（刚买完）→ 关闭覆盖层
    if (!expired && mounted && _showSubExpired) {
      setState(() => _showSubExpired = false);
    }
  }

  Widget _buildSubExpiredOverlay() {
    if (!_showSubExpired) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () {},
            child: Container(color: Colors.black54),
          ),
        ),
        Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 20),
                      SizedBox(width: 8),
                      Text('订阅已到期',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 🔴 2026-10-04：原为内嵌的 `SubscribePanel`（380px 弹层）。
                  //    订阅界面已改为**独立页** ⇒ 这里改为跳转按钮（覆盖层本身保留：
                  //    它承担的是「到期提示」的职责，与订阅页是两件事）。
                  FilledButton(
                    onPressed: () {
                      _lastDismissed = DateTime.now();
                      _dismissCount++;
                      setState(() => _showSubExpired = false);
                      context.push('/subscribe');
                    },
                    child: const Text('查看订阅'),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () {
                      _lastDismissed = DateTime.now();
                      _dismissCount++;
                      setState(() => _showSubExpired = false);
                    },
                    child: const Text('稍后再说'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每次 build 时检查订阅状态（支付后路由变化触发刷新，有 backoff 保护不会频繁请求）
    Future.microtask(_checkSubscription);

    // 监听 auth 切换：用户 ID 变化时重新获取订阅状态
    ref.listen<String?>(authProvider.select((a) => a.userId), (prev, next) {
      if (next != null && next != prev) {
        ref.fetchSubscription();
      }
    });

    final settings = ref.watch(themeProvider);

    // 🔑 三档主题共用一个 buildTheme（spec §7.3：不写手写 ThemeData）：
    //   浅色槽 = 用户选的档（选「夜」时白天回落「墨」，见 ThemeSettings.lightTheme）
    //   深色槽 = 固定「夜」
    // 这样「跟随系统」交给 Flutter 自己按 platformBrightness 二选一，
    // 不需要在这里读 MediaQuery（MaterialApp 之上拿不到）。
    final lightTheme = buildTheme(allTokens[settings.lightTheme]!);
    final darkTheme = buildTheme(nightTokens);

    return MaterialApp.router(
      title: '刻意进化',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: settings.followSystem
          ? ThemeMode.system
          : (settings.theme == ReadingTheme.night
              ? ThemeMode.dark
              : ThemeMode.light),
      // 🔑 主题切换动效（spec §3.8）：280ms + `cubic-bezier(.4,0,.2,1)`。
      //    Flutter 默认是 200ms `Curves.linear` —— 比 spec 又短又生硬。
      //    `Curves.fastOutSlowIn` 的定义**正是** `Cubic(0.4, 0.0, 0.2, 1.0)`，
      //    与 spec 写的那条 cubic-bezier 逐位相同。
      //    背景 / 文字 / 阴影 / 圆角**同过渡** —— 因为 Flutter 的 `AnimatedTheme`
      //    走 `ThemeData.lerp`，会把上述全部字段一起插值，无需逐项声明。
      themeAnimationDuration: CoEvoTokens.transitionDuration,
      themeAnimationCurve: Curves.fastOutSlowIn,
      routerConfig: goRouter,
      builder: (context, child) {
        final isWide = MediaQuery.of(context).size.width > 768;
        // 限制系统字体缩放最大 1.3 倍，防止卡片内容溢出撑爆布局
        final scale = MediaQuery.of(context).textScaleFactor.clamp(1.0, 1.3);
        final content = MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaleFactor: scale),
          child: DialogOverlay(
            child: Stack(
              children: [
                child!,
                // 全局成就解锁弹窗（**任何页面**解锁都会弹）—— 顶层 Stack 最上层
                // 数据源：端侧（见 providers/achievement_notifier.dart）
                const AchievementUnlockOverlay(),
                _buildSubExpiredOverlay(),
              ],
            ),
          ),
        );
        if (!isWide) return content;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: content,
          ),
        );
      },
    );
  }
}
