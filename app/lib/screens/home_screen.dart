import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';
import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../providers/auth_provider.dart';
import '../providers/bookmark_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/interest_provider.dart';
import '../services/feed_pager.dart';
import '../services/interest_selection.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_toggle.dart';
import '../widgets/claim_dialog.dart';
import '../widgets/feed_card.dart';
import '../widgets/header_chip.dart';

/// 首页 —— **信息流**（导航第一个 tab「阅读」）。
///
/// 目标态见 `docs/design/visual-feed-bookmark-2026-09-25.html`：
/// 标题栏「今日精选」+ 一列信息流卡片。
///
/// # 与旧首页（K12 时代）的关系
/// 旧首页是「科目直选」网格，调 `/api/k12/subjects` 与 `/api/k12/init` ——
/// 两个端点都已随后端 K12 清退（Step 3.0）**不复存在**，所以旧首页不是「风格过时」，
/// 而是**点击即报错**。本次重写同时修掉这一点。
///
/// 🔴🔴 **本页不验证登录态**（产品原则 · 白哥 2026-09-27）
/// > 「**除了生词表限制以外，不验证用户登录状态**」
///
/// 🆕 2026-10-01：**那个例外也取消了** —— 生词本 200 词上限已废除
/// ⇒ 原则简化为「**完全不验证登录态**」。
/// 📄 `docs/review/free-tier-limit-removal-assessment-2026-10-01.md`
///
/// 读文章是**免费能力**，而且**现在没有任何功能需要登录**
/// → 信息流**无条件渲染**，**登录态不是它的前置条件**（这条现在依然成立，
/// 且新客户端 `content_client.dart` 刻意不带 token —— 见那里的说明）。
///
/// # 🆕 2026-09-29：数据改从后端来 → 「后端可达性」**变成了**前提
///
/// ⚠️ 本段**修正了一句已经过时的话**。原文写的是：
/// > 「登录态、**后端可达性**都**不是**它的前置条件」
///
/// 那句话在「信息流是 mock（`mockFeedItems` 硬编码在端侧）」时是对的 ——
/// 数据不出本机，后端挂了照样能显示。
/// 但数据源已改为 `GET /api/feed`（服务端共享内容池）→
/// 🔴 **后端可达性现在是前提**，且**不能假装它不是**：
/// 网络失败时信息流就是空的。
///
/// 🔑 所以「不验证登录态」这条原则要**精确表述**：
///    · ✅ 不因「未登录」而拒绝渲染（登录是**能力**开关，不是**可见性**开关）
///    · ❌ 不等于「渲染与数据源无关」—— 数据源在网络上，失败是**常态**
/// → 于是 [feedProvider] 的**错误态必须存在且有出口**（见 `build` 里的 `_FeedError`）：
///   显示「拿不到」+ 一个重试按钮。
///   这仍然符合原意：原则要防的是「**静默失败 + 无出口**」，
///   而不是「假装数据不需要网络」。
///
/// # 🔑 本页保留的是「启动引导」，不是「首页内容」
/// [_initAuth] 那一整块（试用账户创建 / 推广码与活动 / 注册弹窗）是**产品必需**的
/// 进入路径 —— 换 UI 时**必须原样保留**，否则新用户无法完成注册。
/// 但它现在是 [initState] 里 `addPostFrameCallback` 触发的**后台副作用**：
/// - 成功 → 照旧创建试用 / 弹注册引导
/// - 失败 → **静默**，阅读不受任何影响
///
/// ⚠️ 它**曾经**是一道首屏门（`if (!_authReady) return <转圈>`）——
/// 后果是「任何网络抖动 → 首页永久转圈 + 零提示 + 无重试」。
/// 详见 [build] 里的完整记录。
///
/// # 数据
/// ✅ **已接服务端内容池**（2026-09-29）：`GET /api/feed` → [feedProvider]。
/// 🔑 三态（加载 / 失败可重试 / 空）各有明确表达 —— 见 `build` 里信息流那一段。
/// 📄 端侧不再有 `mock_feed.dart`（已删除）；内容由服务端抓取入库（RSS + HN）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String? _pendingRefCode;
  String? _pendingCampaignId;
  bool _authInitBusy = false;

  /// `_initAuth` 等待 auth 恢复的重试计数。
  ///
  /// 🔑 **必须有上限**：原实现是「没恢复就 300ms 后再调自己」的**无界递归** ——
  /// 一旦 `isRestored` 迟迟不置位，它会每 300ms 无限重试。
  /// （改为后台副作用后它不再阻塞 UI，但仍会一直空转 → 仍要封顶。）
  /// 20 次 ≈ 6 秒，超过则放弃本次启动引导（下次有用户交互时另有机会）。
  int _authRestoreTries = 0;
  static const int _kMaxAuthRestoreTries = 20;

  /// 🆕 2026-10-03：信息流列表的滚动控制器 —— 用于**触底加载更多**。
  ///
  /// 🔑 为什么用「滚动监听」而不是 `NotificationListener`：
  ///    两者都能做，但 `ScrollController` 能让「距底部还有多远」成为一个**显式数字**
  ///    （`maxScrollExtent - pixels`），预警距离是**可调的一个常量**，而不是散在
  ///    回调里的魔法判断。
  final ScrollController _feedScroll = ScrollController();

  /// 距底部还有多少像素时开始预加载下一页。
  ///
  /// 🔑 取 400 而不是 0：等真正滚到底再请求，用户会**看到一次明显的停顿**
  ///    （网络往返期间底部什么都没有）。提前 400px 让下一页在用户滑到之前就绪。
  ///    ⚠️ 不能太大（如整屏 800）：那样首屏刚渲染完就会立刻触发第 2 页请求，
  ///    等于把「首屏只加载 30 条」的省流设计作废。
  static const double _kLoadMoreThreshold = 400;

  /// 信息流当前使用的 category key（`''` = 全部）。
  ///
  /// # 🆕 2026-10-03：由常量改为**每次 build 从兴趣选择刷新**的字段
  ///
  /// 原来它是 `static const ''`（一个**恒为空**的占位）—— 现在接上了兴趣筛选。
  ///
  /// 🔑 为什么是**字段**而不是 getter：
  ///    它要在两类上下文里被读，而这两类**读法不同**：
  ///    | 上下文 | 例子 | 读法 |
  ///    |---|---|---|
  ///    | build 内 | `ref.watch(feedProvider(key))` | 必须 `watch`（兴趣变化要触发重建）|
  ///    | **回调内** | 滚动触发 `loadMore()` | **不能** `watch`（不在 build 上下文）|
  ///    ⇒ 折中：build 里 `watch` 一次并**存进字段**，回调统一读字段 ——
  ///      回调拿到的正是「当前屏幕上那份列表所对应的 key」✅
  String _feedKey = '';

  @override
  void initState() {
    super.initState();
    // 🔑 启动引导跑在 `addPostFrameCallback` 里（**不阻塞 build**）——
    //    这样首屏立刻渲染信息流，引导成功与否都不影响「能不能读」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAuth());
    _feedScroll.addListener(_onFeedScroll);
  }

  @override
  void dispose() {
    // 🔑 必须 dispose：否则监听器会跟着 State 泄漏
    //    （列表被释放后回调仍可能被调用 → `hasClients` 之外还可能有陈旧引用）
    _feedScroll.removeListener(_onFeedScroll);
    _feedScroll.dispose();
    super.dispose();
  }

  /// 滚动到接近底部 ⇒ 触发加载下一页。
  ///
  /// ⚠️ **必须自己去重** —— 滚动回调在滑动过程中**每帧都会触发**，
  ///    不去重会在一次滑动里连发十几个请求。
  ///    但这里**已经**有两道保险，所以本函数不需要再加标志位：
  ///    ① `FeedNotifier.loadMore()` 里 `loadingMore` 守卫（语义层）
  ///    ② `FeedPager.hasMore`（到底了直接 return，连请求都不发）
  ///    📌 判据：**防重入放在「状态的所有者」那里，而不是每个调用点** ——
  ///       否则将来多一个触发源（如下拉超过顶部）就要再写一遍。
  void _onFeedScroll() {
    if (!_feedScroll.hasClients) return;
    final pos = _feedScroll.position;
    if (pos.pixels < pos.maxScrollExtent - _kLoadMoreThreshold) return;

    // ⚠️ 用 `read` 而不是 `watch`：这里只是「通知它去做事」，
    //    不需要本 widget 因 notifier 变化而重建（重建由 build 里的 watch 负责）。
    ref.read(feedProvider(_feedKey).notifier).loadMore();
  }

  /// `RefreshIndicator.onRefresh` —— 返回的 `Future` 决定**转圈何时收起**。
  ///
  /// 🔴 时序要点（本项目反复的教训）：
  ///    **「等一个猜的时长」＜「等一个条件成立」**。
  ///    `FeedNotifier.refresh()` 内部 `await` 到了新数据**写进 state** 才返回
  ///    ⇒ 转圈收起时内容**已经**是新的。
  ///    ⚠️ 若这里写成「`invalidate` 然后立刻返回」，转圈会**立刻收起**、
  ///    内容随后才变 —— 用户看到的是「下拉了一下，什么也没发生」，
  ///    于是**再下拉一次**（而第一次其实成功了）。这类「假失败」极伤体验。
  Future<void> _refreshFeed() {
    return ref.read(feedProvider(_feedKey).notifier).refresh();
  }

  /// 把「不可滚动的居中内容」放进可滚动容器 —— 让**下拉手势**成立。
  ///
  /// # 为什么需要它
  ///
  /// `RefreshIndicator` 要求 child **可滚动**：给它一个 `Center` 就永远拉不动。
  /// 而空态（`_FeedEmpty`）正是一个 `Center` ⇒ 空态下**没有任何刷新出口**。
  ///
  /// 标准做法：`SingleChildScrollView` + `AlwaysScrollableScrollPhysics`
  /// + `ConstrainedBox(minHeight = 视口高)` ——
  /// 后两者合起来的效果是「内容不满屏，但**仍然可以下拉**」。
  Widget _fillViewport(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }

  /// 列表末尾的「加载更多」footer。
  ///
  /// # 为什么必须有 footer（不能只靠滚动监听）
  ///
  /// 滚动监听只在「用户滑到底附近」时触发。若**加载失败**，列表既不增长、
  /// 用户也没有任何提示 —— 就是典型的「**静默失败 + 无出口**」。
  /// ⇒ 错误必须在**用户刚操作的那个位置**（列表底部）说出来，并给出口。
  ///
  /// # 四态处理
  ///
  /// | 状态 | 显示 |
  /// |---|---|
  /// | 加载更多**失败** | 一行说明 + 「重试」 |
  /// | **正在**加载 | 小转圈 |
  /// | 还有更多、未触发 | 空（滚动监听随时会触发）|
  /// | **已经到底** | 空（✅ 2026-10-03 **白哥定：不要文案**）|
  ///
  /// ✅ **「到底」时不出文案已定案**（2026-10-03 白哥：「『到底了』不要」）。
  ///    理由（即使不看决策本身也成立）：列表自然结束**不是缺陷** ——
  ///    用户不会以为卡住，而多一行「没有更多了」反而制造一个**永久的尾注**。
  ///    🔴 **不要再加**：这是**已定案**的取舍，不是「忘了做」。
  Widget _feedFooter(FeedPager<FeedItem> pager) {
    if (pager.loadMoreError != null) {
      final t = CoEvoTokensExt.of(context);
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          children: [
            Text(
              // 🔑 不显示异常原文（用户读不懂 `SocketException…`）——
              //    与 `_FeedError` 同一取舍
              '没能加载更多',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                color: Color(t.ink3.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.sm),
            // 🔑 重试是**唯一的出口**（否则用户只能一直上拉，而每次都失败）
            TextButton(
              onPressed: () =>
                  ref.read(feedProvider(_feedKey).notifier).loadMore(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (pager.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    // 还有更多（等滚动触发）或已到底 —— 都留一点空隙，避免卡片贴住 tabbar
    return const SizedBox(height: 8);
  }

  /// 启动引导 —— **后台副作用，不阻塞首屏**（见类文档「不验证登录态」）。
  ///
  /// 🔒 **失败不是错误**：它只决定「试用账户是否已创建 / 是否弹注册引导」，
  /// 与「能不能读文章」无关 → 因此**不向用户报错，也不无限重试**。
  Future<void> _initAuth() async {
    // 防止并发调用
    if (_authInitBusy) return;
    _authInitBusy = true;
    try {
      // 首次创建试用时读取 URL 推广码（只读一次，防止递归调用时 GoRouter 状态变化丢失）
      if (_pendingRefCode == null) {
        final refCode = _readRefCode();
        final uri = GoRouter.of(context).state.uri;
        final campaignId = uri.queryParameters['campaign_id'] ?? uri.queryParameters['camp'];
        _pendingRefCode = refCode;
        _pendingCampaignId = campaignId;
        debugPrint('_initAuth refCode=$refCode campaignId=$campaignId href=${Uri.base}');
      }

      // ── 点击追踪：来自推广链接或二维码扫码 → 记录一次分享点击 ──
      if (_pendingRefCode != null && _pendingRefCode!.isNotEmpty) {
        try {
          final baseUrl = ApiConfig.baseUrl;
          http.post(
            Uri.parse('$baseUrl/api/referral/click'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'campaign_id': _pendingCampaignId ?? 'share',
              'referrer_code': _pendingRefCode,
              'share_channel': 'direct_link',
              'landed_page': '/home',
            }),
          );
        } catch (_) {}
      }

      final auth = ref.read(authProvider);
      if (!auth.isRestored) {
        if (_authRestoreTries >= _kMaxAuthRestoreTries) {
          debugPrint(
              '_initAuth: auth 恢复超时（已试 $_kMaxAuthRestoreTries 次 ≈6s），放弃本次启动引导');
          return;
        }
        _authRestoreTries++;
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          _authInitBusy = false;
          _initAuth();
        }
        return;
      }
      if (auth.isAuthenticated) {
        // 已登录用户：有 campaign_id 则加入活动（拼团/砍价）
        if (_pendingRefCode != null &&
            _pendingCampaignId != null &&
            _pendingCampaignId!.isNotEmpty &&
            mounted) {
          _joinCampaign(auth.userId!, auth.token!, _pendingCampaignId!);
        }
        // 登录时触发活动推送检查（写 campaign_push 通知）
        _checkLoginCampaignPush(auth.userId!, auth.token!);
        // 已登录但还没完善资料 → 引导注册（**只是弹窗，不挡内容**）
        // 🔴 判据换成 `auth.isRegistered`（= 邮箱非空）—— 它取代了原来的 `realName`。
        //    语义完全相同：「这个账号还没完成注册 → 引导注册」。
        //    匿名试用账号的 `email` 为 null（而 `isAuthenticated` 仍为 true）→ 会走到这里 ✅
        if (!auth.isRegistered) {
          if (mounted) _showAuthDialog();
        }
        return;
      }
      if (await AuthNotifier.hasUsedTrial()) {
        if (mounted) _showAuthDialog();
        return;
      }
      debugPrint('_initAuth trialStart refCode=${_pendingRefCode} campaignId=${_pendingCampaignId}');
      await ref
          .read(authProvider.notifier)
          .trialStart(refCode: _pendingRefCode, campaignId: _pendingCampaignId);
      // trial 完成后重新读取 auth 状态，继续流程
      final auth2 = ref.read(authProvider);
      if (auth2.isAuthenticated && mounted) {
        // 同上：用 `isRegistered`（邮箱）判断是否还需引导注册
        if (!auth2.isRegistered) {
          _showAuthDialog();
        }
      }
    } finally {
      _authInitBusy = false;
    }
  }

  void _showAuthDialog() {
    debugPrint('_showAuthDialog: 开始显示登录 / 注册对话框');
    // 🔑 走 `ClaimDialog.show()` 而不是在这里自己写 `showDialog` ——
    //    弹窗的**弹出方式**（遮罩浓度 · insetPadding…）只该有一处定义；
    //    两个调用方各写一遍，迟早在某个参数上走偏
    //    （同 `HeaderChip` 被抽成公共组件的理由）。
    ClaimDialog.show(
      context,
      pendingRefCode: _pendingRefCode,
      pendingCampaignId: _pendingCampaignId,
    ).then((result) {
      debugPrint('_showAuthDialog: 对话框关闭 result=$result');
    }).catchError((e) {
      debugPrint('_showAuthDialog: 异常 $e');
    });
  }

  /// 登录时触发活动推送检查（写 campaign_push 通知到通知中心）
  void _checkLoginCampaignPush(String userId, String token) {
    http.get(
      Uri.parse('${ApiConfig.baseUrl}/api/campaigns/check-push-trigger?push_trigger=login&user_id=$userId'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
    ); // fire-and-forget
  }

  /// 已登录用户点击活动分享链接 → 加入活动成员（拼团/砍价类）
  void _joinCampaign(String userId, String token, String campaignId) {
    http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/campaign/join'),
      headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: jsonEncode({
        'campaign_id': campaignId,
        'user_id': userId,
        'role': 'member',
      }),
    ); // fire-and-forget
  }

  String? _readRefCode() {
    // 优先从 GoRouter URI 读，兜底从 window.location.href 解析（防止 GoRouter 丢参数）
    try {
      final fromRouter = GoRouter.of(context).state.uri.queryParameters['ref'];
      if (fromRouter != null && fromRouter.isNotEmpty) return fromRouter;
    } catch (_) {}
    try {
      final href = Uri.base.toString();
      final parsed = Uri.parse(href);
      final fromUrl = parsed.queryParameters['ref'];
      if (fromUrl != null && fromUrl.isNotEmpty) return fromUrl;
      // 兜底：从 /share/{refCode} 路径提取
      if (parsed.path.contains('/share/')) {
        final parts = parsed.path.split('/share/');
        if (parts.length > 1) {
          final ref = parts[1].split('?')[0].split('&')[0];
          if (ref.isNotEmpty) return ref;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 🔑 每次 build 刷新「当前分类 key」：
    //    · `ref.watch(interestProvider)` 让**兴趣变化能触发本页重建**（必须 watch）
    //    · `interestKeyOf` 把「prefs 未加载完 / 读失败」都收敛成 `''`（= 全部）
    //      ⇒ 偏好读不出来**不会**挡住信息流（同 `device_id` 的降级判据）
    //    · 存进字段供**回调**使用（滚动/下拉刷新/重试 —— 那些地方不能 watch）
    //    ⚠️ 已知取舍：若用户确实设了筛选，首帧会先用 `''`（全部）发起一次请求，
    //       prefs 就绪后 key 变化 ⇒ 可能**多发一次请求**。
    //       彻底消除需要在 `main()` 预载 prefs 并 override（动启动路径，本轮不做）。
    _feedKey = interestKeyOf(ref.watch(interestProvider).valueOrNull);
    final t = CoEvoTokensExt.of(context);

    // 🔑 只取 `idsOrEmpty` / `isReady`，**不用 `when`**：
    //    数据库没打开好时，信息流照常渲染、书签按钮禁用 ——
    //    绝不把「收藏能不能用」变成「内容能不能看」的前置条件（3.22 的教训）。
    final bookmarkState = ref.watch(bookmarkProvider);
    final bookmarkIds = bookmarkState.idsOrEmpty;
    final bookmarkReady = bookmarkState.isReady;

    // 🔴🔴 信息流**无条件渲染** —— 登录态不是它的前置条件。
    //
    // 产品原则（白哥 2026-09-27）：
    //   「**除了生词表限制以外，不验证用户登录状态**」
    // 🆕 2026-10-01：**那个例外已消失**（生词本 200 上限取消）
    //   → 现在是「**完全不验证登录态**」，没有任何功能需要登录。
    //
    // ⚠️ 这里**曾经**是一道 `if (!_authReady) return <转圈>;` 的门（K12 时代的写法）：
    //   一旦 `_initAuth()` 的 `trialStart` 请求失败（如早前 `flutter run` 默认连
    //   `localhost:8080`，本地没有后端），`isAuthenticated` 就一直是 false
    //   → `_authReady` 永远不置位 → **首页永久转圈，且无提示、无重试入口**。
    //   而 tabbar 在外层 `_ShellScaffold`、loading 在内层 Scaffold → 表现为
    //   「按钮正常，但首页没有卡片」。
    //
    //   → 教训：**把「网络/身份」这类易失败的外部依赖，放在「内容渲染」的前置条件上**
    //     ＝ 让内容可用性绑定在一个与内容无关的开关上。
    //     现在 `_initAuth` 降级为 `addPostFrameCallback` 里的后台副作用：
    //     成功 → 照旧创建试用 / 弹注册引导；失败 → 静默，阅读不受影响。
    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理，这里只避让状态栏
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题栏（设计稿 `.feed-hd`：23 / w600 / 字距 -.015em）──
            //    右侧「收藏 N」入口 = 3.5（设计稿 `.bm-entry`）。
            //    🔑 现在放得下手了 —— 收藏清单页已存在（`/home/bookmarks`），
            //       不会出现「点了没反应的死入口」（这正是之前不放的理由）。
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '今日精选',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 23 * -0.015,
                        color: Color(t.ink.argb32),
                      ),
                    ),
                  ),
                  // 设计稿 `.feed-hd{gap:12px}`
                  const SizedBox(width: 12),
                  // 🔴 这里**曾经**有一个「生词 N」入口（3.4d）—— 已于 2026-09-28 删除。
                  //
                  // 白哥：「**阅读页面的『生词』按钮要取消**」。
                  // 🔑 理由（顺着规格读下来就通了）：**生词本 ≡ 复习页**（`ui-ux` §6.2），
                  //    而复习**本身就是一个 tab** —— 底部导航已经有它了。
                  //    再放一个标题栏按钮，是**同一目的的第二个入口**；
                  //    而且它指过去只是「切 tab」，等于把导航按钮做了第二遍。
                  HeaderChip(
                    icon: Icons.bookmark_border,
                    label: '收藏',
                    count: bookmarkIds.length,
                    onTap: () => context.push('/home/bookmarks'),
                  ),
                ],
              ),
            ),

            // ── 信息流（设计稿 `.feed` padding 0 16px · `.fcards` gap 13px）──
            Expanded(
              child: ref.watch(feedProvider(_feedKey)).when(
                    // ① 加载中：**给一个可见的转圈**（不是一个空白区）。
                    //    🔑 首次进 App 要等一次网络往返 → 没有占位的话
                    //       用户看到的是「今日精选」下面一片空白 = 像坏了。
                    loading: () => const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    // ② 失败：**明确说出「拿不到」+ 可重试**。
                    //    🔴 这是本页最重要的一态：内容源依赖网络，
                    //       而网络失败是**常态**（不是异常）。
                    //       判据：「静默失败 + 无出口」比报错更糟 ——
                    //       一个永远空着的信息流，用户只会以为 App 坏了。
                    //
                    // ⚠️ 走到这里 = **首次加载就失败**（一条都没拿到）。
                    //    若已有数据、只是「加载更多/刷新」失败，**不会**变成这一态 ——
                    //    那两种失败分别由 footer 与轻提示表达（见 FeedPager 的说明）。
                    //    📌 判据：**「有数据时失败」≠「没数据时失败」**。
                    //
                    // 🆕 2026-10-03：错误态**也包进下拉刷新**。
                    //    🔑 理由：`_FeedError` 的说明文案里**本来就写着**
                    //       「服务可能正在忙。稍后再试，**或者下拉重试**」——
                    //       而在此之前**根本没有下拉刷新**（这句文案是空头支票）。
                    //    📌 判据：**「声称的能力」必须真的存在** ——
                    //       文案/注释里的能力声明要 grep 得到实现，否则就是误导。
                    error: (e, _) => RefreshIndicator(
                      onRefresh: _refreshFeed,
                      child: _fillViewport(
                        _FeedError(
                          error: e,
                          onRetry: () =>
                              ref.invalidate(feedProvider(_feedKey)),
                        ),
                      ),
                    ),
                    // ③ 空：**区分「服务通了但没有内容」与「拿不到」**。
                    //    两者的处理完全不同（前者不该劝重试 —— 重试也没用）。
                    //
                    // 🆕 2026-10-03：空态**也包进下拉刷新**。
                    //    原先 `_FeedEmpty` 是个不可滚动的 `Center` ⇒ 空态下
                    //    用户**没有任何刷新出口**（只能杀 App）—— 与「静默失败」同族。
                    //    修法：用可滚动容器撑满高度，让下拉手势成立。
                    data: (pager) {
                      if (pager.isEmpty) {
                        return RefreshIndicator(
                          onRefresh: _refreshFeed,
                          child: _fillViewport(_FeedEmpty(
                            // 🔑 传 key 而不是 bool：空状态要**说清**「哪一类为空」
                            //    并对「筛选后为空」给出回到全部的出口。
                            //    ⚠️ 用 `_feedKey`（本帧已由 build 刷新）而不是再读一遍
                            //       provider —— 两者必须一致，读两处就会漂移。
                            categoryKey: _feedKey,
                            onShowAll: () =>
                                ref.read(interestProvider.notifier).clear(),
                          )),
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: _refreshFeed,
                        child: ListView.separated(
                          controller: _feedScroll,
                          // 🔴 底部 padding 必须**留出 tabbar 的高度**（2026-09-27）。
                          //    `_ShellScaffold` 加了 `extendBody: true` → 正文延伸到 tabbar **之后**，
                          //    若仍用原来的 24，最后一张卡片会被按钮压住。
                          //    数值与依据见 `CoSpacing.tabBarClearance`（≈83–93 取 100）。
                          padding: const EdgeInsets.fromLTRB(
                              16, 0, 16, CoSpacing.tabBarClearance),
                          // 🔑 `+1` = 末尾的「加载更多」footer（见 `_feedFooter`）
                          itemCount: pager.items.length + 1,
                          separatorBuilder: (_, __) => const SizedBox(height: 13),
                          itemBuilder: (_, i) {
                            if (i == pager.items.length) {
                              return _feedFooter(pager);
                            }
                            final item = pager.items[i];
                            return FeedCard(
                              item: item,
                              bookmarked: bookmarkIds.contains(item.id),
                              // 🔴 库未就绪 → 传 `null` → 按钮**禁用**。
                              //    不传一个「点了没反应」的回调 —— 那会让用户以为 App 坏了
                              //    （3.22 的教训：「静默无效的操作」比「禁用」更糟）。
                              onToggleBookmark: bookmarkReady
                                  ? () => _toggleBookmark(item.id)
                                  : null,
                              // 点卡片 → 阅读器（3.4a）。
                              // 🔑 **正文未就绪的卡片照样可点** —— 与书签的「禁用」不同：
                              //    书签禁用是因为「数据库没开」这种**异常状态**；
                              //    而「正文未抓取」是**正常状态**（该源的 feed 只给摘要），
                              //    进阅读器会看到一句明确的解释 —— 比「点了没反应」好，
                              //    也比「卡片不可点」好（后者要用户猜原因）。
                              onTap: () => context.push('/article/${item.id}'),
                            );
                          },
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// 切换收藏并给出轻提示。
  ///
  /// 🔑 实现已抽到 `widgets/bookmark_toggle.dart` —— 收藏清单页要做**同一件事**
  /// （设计稿 §03 ②：「同一套卡片组件，只是筛选过」），而 toast 的**文案与时长**
  /// 由设计稿 §1.6 规定 → **只该定义一次**。
  /// （同 `BookmarkButton` 被抽出来的理由：设计稿里是同一个东西，实现里就该是一处。）
  Future<void> _toggleBookmark(int contentId) =>
      toggleBookmarkWithToast(context, ref, contentId);
}

/// 信息流**拿不到内容**时的表达（错误态）。
///
/// # 🔴 为什么必须有这一态（而不是留空）
/// 数据源在网络另一头（`GET /api/feed`），**失败是常态而非异常**。
/// 若失败时只显示空列表，用户看到的是「今日精选」下面一片空白 ——
/// 与「今天确实没有新内容」**完全无法区分**。
/// 📌 判据（本项目反复出现）：「**静默失败 + 无出口**」比报错更糟。
///    所以这里既**说出发生了什么**，也给**一个出口**（重试）。
///
/// # 🔑 文案分层：标题给「结论」，副标题给「原因」
/// [error] 是 `ContentApiException` —— 它的 `toString` 里有状态码与原因，
/// 但**不把异常原文当标题**（用户读不懂 `Exception: SocketException...`）。
/// 区分两种情况：
/// · 网络层失败（`statusCode == 0`）→ 「检查网络」
/// · 服务返回错误（如 500）→ 「服务暂时不可用」
/// 两者的用户动作不同（前者查自己，后者只能等）—— 分开说才有用。
class _FeedError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _FeedError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final isNetwork = error is ContentApiException &&
        (error as ContentApiException).statusCode == 0;
    final title = isNetwork ? '网络好像不通' : '内容暂时取不到';
    final detail = isNetwork
        ? '检查一下网络连接，然后再试一次。'
        : '服务可能正在忙。稍后再试，或者下拉重试。';

    return _FeedNotice(
      icon: isNetwork ? Icons.wifi_off : Icons.cloud_off,
      title: title,
      detail: detail,
      // 🔑 重试是**唯一的出口** —— 没有它，用户只能杀掉 App 重开
      actionLabel: '重试',
      onAction: onRetry,
      tokens: t,
    );
  }
}

/// 信息流**确实为空**（服务通了，但本次查询没有可展示的条目）。
///
/// # 🔑 与 [_FeedError] 分开是**必须的**，不是啰嗦
/// 「拿不到」与「没有」对用户是**两件事**：
/// · 拿不到 → 会好，**重试有意义**
/// · 没有 → 重试也没用（内容就是空的）
/// → 所以本态**不给重试按钮**，而是说明原因（首次部署时内容池还没抓完）。
/// 若两者共用一个「重试」态，用户会对一个不会变的状态反复点重试。
///
/// # 🆕 2026-10-03：分成**两态**（兴趣筛选上线后必须分）
///
/// | 情形 | 文案 | 按钮 |
/// |---|---|---|
/// | **没筛**（全部）却为空 | 还没有内容（内容池还没抓完）| ❌ **不给**（重试无意义）|
/// | **筛选后**为空 | 这一类还没有内容 | ✅ **「查看全部」** |
///
/// 🔴 第二行是本条存在的理由：筛选后为空时若只显示「还没有内容」，
///    用户会以为**整个 App 都没内容**（而不是「我筛掉了」）——
///    典型的「静默失败 + 无出口」。而且本项目**已知**有些类内容很少
///    （`family` / `business` 近 7 天只有个位数）⇒ 这一态会**真的被用户遇到**。
///    📌 判据：**「空」必须说清是哪种空，并给出口**。
class _FeedEmpty extends StatelessWidget {
  /// 当前分类 key（`''` = 全部）。
  final String categoryKey;

  /// 「查看全部」——清空兴趣筛选。
  final VoidCallback onShowAll;

  const _FeedEmpty({required this.categoryKey, required this.onShowAll});

  @override
  Widget build(BuildContext context) {
    final filtered = categoryKey.isNotEmpty;
    return _FeedNotice(
      icon: filtered ? Icons.filter_alt_off_outlined : Icons.inbox_outlined,
      title: filtered ? '这一类还没有内容' : '还没有内容',
      detail: filtered
          // ⚠️ 不写「试试别的类别」这种空话 —— 直接给按钮更省事
          ? '你筛选的类别下暂时没有文章。'
          : '内容还在准备中。过一会儿回来看，或者稍后重试。',
      // 筛选后为空 ⇒ **必须给出口**（否则用户卡在自己的筛选里出不去）
      actionLabel: filtered ? '查看全部' : null,
      onAction: filtered ? onShowAll : null,
      tokens: CoEvoTokensExt.of(context),
    );
  }
}

/// [_FeedError] / [_FeedEmpty] 共用的版式（**只有一份外观定义**）。
///
/// 🔑 抽出来的理由同 `bookmark_toggle`：两者是**同一位置的同一种东西**
/// （信息流区域的占位），只是文案与有无按钮不同。
/// 各写一遍必然视觉漂移 —— 而它们**永远相邻出现**，漂移一眼可见。
class _FeedNotice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  /// `null` = 不给按钮（见 [_FeedEmpty] 的说明）。
  final String? actionLabel;
  final VoidCallback? onAction;
  final CoEvoTokens tokens;

  const _FeedNotice({
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: Color(t.ink3.argb32)),
            const SizedBox(height: CoSpacing.md),
            // 标题：层级高于说明（字号 15 > 13，字重 w600 > 常规）
            // 🔑 与「线索不压过答案」同一条原则：结论要能一眼看到
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.sm),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                height: 1.6,
                color: Color(t.ink3.argb32),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: CoSpacing.lg),
              // ⚠️ 用 `TextButton` 而**不是**粘土按钮：本页（阅读区）是**零粘土**区
              //    （spec §八「阅读区容器内不得出现粘土类」）。
              //    重试是页面内的一次动作，不是需要「体积」强调的主操作。
              TextButton(
                onPressed: onAction,
                child: Text(
                  actionLabel!,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


