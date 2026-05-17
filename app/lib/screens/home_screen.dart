import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('刻意进化学习'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Header
            Text(
              '今天想学什么？',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '和 AI 对话，自动提取概念，按记忆曲线复习',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 48),

            // Action cards
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ActionCard(
                    icon: Icons.chat,
                    title: '开始对话',
                    subtitle: '和 AI 对话学习新知识',
                    onTap: () => context.push('/chat'),
                  ),
                  const SizedBox(height: 16),
                  _ActionCard(
                    icon: Icons.replay,
                    title: '学习计划',
                    subtitle: '按记忆曲线回顾知识点',
                    color: Colors.green,
                    onTap: () => context.push('/review'),
                  ),
                  const SizedBox(height: 16),
                  _ActionCard(
                    icon: Icons.library_books,
                    title: '我的卡片',
                    subtitle: '查看已创建的知识卡片',
                    color: Colors.indigo,
                    onTap: () => context.go('/review'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color? color;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(20),
        leading: CircleAvatar(
          backgroundColor: accentColor.withAlpha(30),
          child: Icon(icon, color: accentColor),
        ),
        title: Text(title, style: Theme.of(context).textTheme.titleLarge),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }
}
