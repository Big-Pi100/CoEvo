import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';
import '../data/mock_feed.dart';
import '../providers/auth_provider.dart';
import '../providers/bookmark_provider.dart';
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
/// 读文章是**免费能力**，判定用户身份只发生在「生词本是否超 200 词上限」那一刻。
/// 所以信息流**无条件渲染**，登录态、后端可达性都**不是**它的前置条件。
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
/// 🔴 当前用 [mockFeedItems]（**临时**，设计稿原文三篇）。
/// 后端 RSS 抓取属 Phase 3，落地后改为从 feed 接口取数并删除 mock 文件。
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

  @override
  void initState() {
    super.initState();
    // 🔑 启动引导跑在 `addPostFrameCallback` 里（**不阻塞 build**）——
    //    这样首屏立刻渲染信息流，引导成功与否都不影响「能不能读」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAuth());
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
        if (auth.realName == null || auth.realName!.trim().isEmpty) {
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
        if (auth2.realName == null || auth2.realName!.trim().isEmpty) {
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
    // 读文章是免费能力，判定用户身份只发生在「生词本是否超 200 词上限」那一刻。
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
              child: ListView.separated(
                // 🔴 底部 padding 必须**留出 tabbar 的高度**（2026-09-27）。
                //    `_ShellScaffold` 加了 `extendBody: true` → 正文延伸到 tabbar **之后**，
                //    若仍用原来的 24，最后一张卡片会被按钮压住。
                //    数值与依据见 `CoSpacing.tabBarClearance`（≈83–93 取 100）。
                padding: const EdgeInsets.fromLTRB(
                    16, 0, 16, CoSpacing.tabBarClearance),
                itemCount: mockFeedItems.length,
                separatorBuilder: (_, __) => const SizedBox(height: 13),
                itemBuilder: (_, i) {
                  final item = mockFeedItems[i];
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
                    // 🔑 正文未就绪的文章**照样可点** —— 与书签的「禁用」不同：
                    //    书签禁用是因为「数据库没开」这种**异常状态**；
                    //    而「正文未抓取」是**正常状态**（Phase 3 未做），
                    //    进阅读器会看到一句明确的解释 —— 比「点了没反应」好，
                    //    也比「卡片不可点」好（后者要用户猜原因）。
                    onTap: () => context.push('/article/${item.id}'),
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


