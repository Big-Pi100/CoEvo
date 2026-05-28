import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/guardian_screen.dart';
import 'screens/review_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'screens/skipped_list_screen.dart';
import 'screens/home_screen.dart';
import 'providers/auth_provider.dart';

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
      builder: (context, state, navigationShell) => _ShellScaffold(navigationShell: navigationShell),
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
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/chat',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: ChatScreen(conversationId: state.extra as String?),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
              position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
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
              position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
              child: child,
            ),
      ),
    ),
    GoRoute(
      path: '/skipped',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const SkippedListScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
              position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(animation),
              child: child,
            ),
      ),
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
          navigationShell.goBranch(i, initialLocation: i == navigationShell.currentIndex);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.school_outlined), selectedIcon: Icon(Icons.school), label: '学习'),
          NavigationDestination(icon: Icon(Icons.replay_outlined), selectedIcon: Icon(Icons.replay), label: '复习'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '个人'),
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authProvider.notifier).tryRestore();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep admin/guardian from tree-shaking
    _allScreens;
    return MaterialApp.router(
      title: '刻意进化学习',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: goRouter,
    );
  }
}
