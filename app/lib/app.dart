import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'theme/coevo_tokens.dart';
import 'theme/theme_builder.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/review_screen.dart';
import 'screens/pay_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/achievements_screen.dart';
import 'pages/user/distribution/notification_panel.dart';
import 'providers/auth_provider.dart';
import 'providers/subscription_provider.dart';
import 'providers/theme_provider.dart';
import 'widgets/achievement_overlay.dart';
import 'widgets/dialog_overlay.dart';
import 'widgets/subscribe_panel.dart';

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
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/achievements',
              builder: (context, state) => const AchievementsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/profile',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ProfileScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(animation),
          child: child,
        ),
      ),
    ),
    GoRoute(
      path: '/chat',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: ChatScreen(conversationId: state.extra as String?),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(animation),
          child: child,
        ),
      ),
    ),
    GoRoute(
      path: '/pay',
      builder: (context, state) => const PayScreen(),
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
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (i) {
          navigationShell.goBranch(i,
              initialLocation: i == navigationShell.currentIndex);
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.school_outlined),
              selectedIcon: Icon(Icons.school),
              label: '学习'),
          NavigationDestination(
              icon: Icon(Icons.replay_outlined),
              selectedIcon: Icon(Icons.replay),
              label: '复习'),
          NavigationDestination(
              icon: Icon(Icons.emoji_events_outlined),
              selectedIcon: Icon(Icons.emoji_events),
              label: '成就'),
        ],
      ),
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

  void _checkSubscription() {
    final auth = ref.read(authProvider);
    if (!auth.isAuthenticated || auth.userId == null) return;
    // 距上次关闭时间按 dismiss 次数递增（已显示的覆盖层不在此限，支付后需立即刷新）
    if (_lastDismissed != null && !_showSubExpired) {
      final idx = _dismissCount.clamp(0, _backoffMinutes.length - 1);
      final minWait = _backoffMinutes[idx];
      if (DateTime.now().difference(_lastDismissed!).inMinutes < minWait) {
        return;
      }
    }

    ref.fetchSubscription().then((_) {
      // provider 状态更新后，检查是否需要弹出覆盖层
      final sub = ref.read(subscriptionProvider);
      final auth = ref.read(authProvider);
      final isTrial = (auth.username ?? '').startsWith('trial_');
      // 临时账户不弹订阅覆盖层，引导注册由 ChatScreen 处理
      if (sub.isExpired && mounted && !_showSubExpired && !isTrial) {
        setState(() => _showSubExpired = true);
      }
      // 订阅已激活（刚支付完成）→ 关闭覆盖层
      if (!sub.isExpired && mounted && _showSubExpired) {
        setState(() => _showSubExpired = false);
      }
    });
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
                  const SubscribePanel(),
                  const SizedBox(height: 16),
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
              const AchievementOverlay(),
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
