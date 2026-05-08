import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/review_screen.dart';
import 'screens/card_list_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'screens/skipped_list_screen.dart';

final goRouter = GoRouter(
  initialLocation: '/auth',
  routes: [
    GoRoute(
      path: '/auth',
      builder: (context, state) => const AuthScreen(),
    ),
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/chat',
      builder: (context, state) {
        final conversationId = state.extra as String?;
        return ChatScreen(conversationId: conversationId);
      },
    ),
    GoRoute(
      path: '/review',
      builder: (context, state) => const ReviewScreen(),
    ),
    GoRoute(
      path: '/cards',
      builder: (context, state) => const CardListScreen(),
    ),
    GoRoute(
      path: '/profile',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(
      path: '/conversations',
      builder: (context, state) => const ConversationListScreen(),
    ),
    GoRoute(
      path: '/skipped',
      builder: (context, state) => const SkippedListScreen(),
    ),
  ],
);

class CoEvoApp extends StatelessWidget {
  const CoEvoApp({super.key});

  @override
  Widget build(BuildContext context) {
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
