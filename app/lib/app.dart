import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'theme/app_theme.dart';
import 'api/api_config.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/guardian_screen.dart';
import 'screens/review_screen.dart';
import 'screens/pay_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/achievements_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'screens/home_screen.dart';
import 'screens/k12_subject_screen.dart';
import 'screens/skipped_screen.dart';
import 'providers/auth_provider.dart';
import 'providers/theme_provider.dart';
import 'widgets/achievement_overlay.dart';
import 'widgets/subscribe_panel.dart';

// Prevent dart2js tree-shaking of admin/guardian screens
final _allScreens = <Widget>[
  AdminScreen(),
  GuardianScreen(),
];

final goRouter = GoRouter(
  initialLocation: '/auth',
  redirect: (context, state) {
    final auth = ProviderScope.containerOf(context).read(authProvider);
    if (!auth.isRestored) return null;

    final loc = state.uri.toString();
    final isOnAuth = loc.endsWith('/auth');
    if (loc.contains('/admin') || loc.contains('/guardian')) return null;

    if (auth.isAuthenticated && isOnAuth) return '/home';
    if (!auth.isAuthenticated && !isOnAuth) return '/auth';
    return null;
  },
  routes: [
    GoRoute(
      path: '/auth',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const AuthScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const AdminScreen(),
    ),
    GoRoute(
      path: '/guardian',
      builder: (context, state) => const GuardianScreen(),
    ),
    GoRoute(
      path: '/teacher',
      builder: (context, state) => const GuardianScreen(),
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
      path: '/conversations',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ConversationListScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(animation),
          child: child,
        ),
      ),
    ),
    GoRoute(
      path: '/k12-subject',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const K12SubjectScreen(),
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
      path: '/skipped',
      builder: (context, state) => const SkippedScreen(),
    ),
  ],
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
    // 距上次关闭时间按 dismiss 次数递增
    if (_lastDismissed != null) {
      final idx = _dismissCount.clamp(0, _backoffMinutes.length - 1);
      final minWait = _backoffMinutes[idx];
      if (DateTime.now().difference(_lastDismissed!).inMinutes < minWait)
        return;
    }

    http.get(
      Uri.parse('${ApiConfig.baseUrl}/api/user/${auth.userId}/subscription'),
      headers: {'Content-Type': 'application/json'},
    ).then((resp) {
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['expired'] == true && mounted && !_showSubExpired) {
        setState(() => _showSubExpired = true);
      }
    }).catchError((_) {});
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
    // Keep admin/guardian from tree-shaking
    _allScreens;

    final themeState = ref.watch(themeProvider);

    ThemeData lightTheme;
    ThemeData darkTheme;
    ThemeMode themeMode;

    switch (themeState.mode) {
      case AppThemeMode.duolingo:
        lightTheme = AppTheme.duolingo;
        darkTheme = AppTheme.duolingo; // 强制亮色，无视系统暗色模式
        themeMode = ThemeMode.light;
        break;
      case AppThemeMode.light:
        lightTheme = AppTheme.light;
        darkTheme = AppTheme.light;
        themeMode = ThemeMode.light;
        break;
      case AppThemeMode.dark:
        lightTheme = AppTheme.dark;
        darkTheme = AppTheme.dark;
        themeMode = ThemeMode.dark;
        break;
      case AppThemeMode.system:
        lightTheme = AppTheme.light;
        darkTheme = AppTheme.dark;
        themeMode = ThemeMode.system;
        break;
    }

    return MaterialApp.router(
      title: '刻意进化学习',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      routerConfig: goRouter,
      builder: (context, child) => Stack(
        children: [
          child!,
          const AchievementOverlay(),
          _buildSubExpiredOverlay(),
        ],
      ),
    );
  }
}
