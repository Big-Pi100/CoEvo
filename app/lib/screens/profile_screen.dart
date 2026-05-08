import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Map<String, dynamic>? _data;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final data = await client.getProfile();
      if (mounted) setState(() { _data = data; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () { setState(() => _isLoading = true); _load(); },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              ref.read(authProvider.notifier).logout();
              context.go('/auth');
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, auth),
    );
  }

  Widget _buildContent(BuildContext context, AuthState auth) {
    final stats = _data?['stats'] as Map<String, dynamic>? ?? {};
    final achievements = (_data?['achievements'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

    final totalCards = stats['total_cards'] ?? 0;
    final totalReviews = stats['total_reviews'] ?? 0;
    final streakDays = stats['streak_days'] ?? 0;
    final domainsCovered = stats['domains_covered'] ?? 0;
    final todayReviews = stats['today_reviews'] ?? 0;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // 用户头像 + 名字
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                child: Icon(Icons.person, size: 40, color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 12),
              Text(auth.username ?? '用户', style: Theme.of(context).textTheme.titleLarge),
              if (streakDays > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department, color: Colors.orange, size: 18),
                      const SizedBox(width: 4),
                      Text('连续学习 $streakDays 天',
                          style: TextStyle(color: Colors.orange.shade700)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // 统计卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('学习统计', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 24),
                _StatRow(icon: Icons.auto_stories, label: '卡片总数', value: '$totalCards'),
                _StatRow(icon: Icons.replay, label: '累计复习', value: '$totalReviews'),
                _StatRow(icon: Icons.today, label: '今日复习', value: '$todayReviews'),
                _StatRow(icon: Icons.category, label: '覆盖领域', value: '$domainsCovered'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 跳过的概念
        Card(
          child: ListTile(
            leading: const Icon(Icons.skip_next, color: Colors.orange),
            title: const Text('跳过的概念'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/skipped'),
          ),
        ),
        const SizedBox(height: 16),

        // 成就卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('成就', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    Text('${achievements.length}/11',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                  ],
                ),
                const Divider(height: 24),
                if (achievements.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.emoji_events, size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 8),
                          Text('还没有成就', style: TextStyle(color: Colors.grey.shade500)),
                          const SizedBox(height: 4),
                          Text('去对话学习，解锁第一个成就',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
                        ],
                      ),
                    ),
                  )
                else
                  Wrap(
                    spacing: 8, runSpacing: 12,
                    children: achievements.map((a) => _AchievementTile(
                      icon: a['icon'] as String? ?? '🌟',
                      name: a['name'] as String? ?? '',
                      unlockedAt: a['unlocked_at'] as String? ?? '',
                    )).toList(),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          )),
        ],
      ),
    );
  }
}

class _AchievementTile extends StatelessWidget {
  final String icon;
  final String name;
  final String unlockedAt;

  const _AchievementTile({
    required this.icon, required this.name, required this.unlockedAt,
  });

  @override
  Widget build(BuildContext context) {
    final date = unlockedAt.length >= 10 ? unlockedAt.substring(0, 10) : '';
    return Tooltip(
      message: date,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Theme.of(context).colorScheme.primary.withAlpha(40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
