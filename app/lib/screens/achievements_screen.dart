// ignore_for_file: unnecessary_cast
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../api/chat_client.dart';
import '../shared/achievement_icons.dart';
import '../providers/achievement_notifier.dart';

class AchievementsScreen extends ConsumerStatefulWidget {
  const AchievementsScreen({super.key});

  @override
  ConsumerState<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends ConsumerState<AchievementsScreen> {
  Map<String, dynamic>? _data;            // profile data: stats, cefr, achievements
  Map<String, dynamic>? _activityData;    // heatmap data
  Map<String, dynamic>? _report;          // learning report (plans + tiers)
  List<Map<String, dynamic>> _k12Progress = [];
  Map<String, dynamic>? _achievementsAll; // Phase 3: achievements-all API response
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final results = await Future.wait([
        client.getProfile(),
        client.getActivity(days: 365),
        client.getLearningReport(),
        client.getK12Progress(),
      ]);
      // Phase 3: 加载成就详情（独立请求，失败不影响主流程）
      final achievementsAll = await client.getAchievementsAll();
      if (mounted) {
        setState(() {
          _data = results[0] as Map<String, dynamic>?;
          _activityData = results[1] as Map<String, dynamic>?;
          _report = results[2] as Map<String, dynamic>?;
          _k12Progress = ((results[3] as Map<String, dynamic>)['progress'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
          _achievementsAll = achievementsAll;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('成就')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_data != null) _buildHeader(theme),
                  const SizedBox(height: 16),
                  if (_data != null) _buildStatsGrid(theme),
                  const SizedBox(height: 16),
                  if (_activityData != null) _buildHeatmap(theme),
                  const SizedBox(height: 16),
                  if (_k12Progress.isNotEmpty) _buildK12Progress(theme),
                  const SizedBox(height: 16),
                  if (_data != null) _buildCefrSection(theme),
                  const SizedBox(height: 16),
                  if (_report != null) _buildLearningPlans(theme),
                  const SizedBox(height: 16),
                  if (_data != null) _buildAchievements(theme),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final stats = _data!['stats'] as Map<String, dynamic>? ?? {};
    final streakDays = stats['streak_days'] ?? 0;
    final totalReviews = stats['total_reviews'] ?? 0;
    final todayReviews = stats['today_reviews'] ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
        child: Row(
          children: [
            Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                color: streakDays > 0 ? Colors.orange.withAlpha(25) : Colors.grey.withAlpha(20),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.local_fire_department,
                    color: streakDays > 0 ? Colors.orange : Colors.grey, size: 26),
                  Text('$streakDays',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                      color: streakDays > 0 ? Colors.orange.shade700 : Colors.grey)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(streakDays > 0 ? '连续学习 $streakDays 天' : '开始你的学习之旅',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('今日复习 $todayReviews 次 · 累计 $totalReviews 次',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              ],
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(ThemeData theme) {
    final stats = _data!['stats'] as Map<String, dynamic>? ?? {};
    final items = [
      _SItem(Icons.auto_stories, '卡片总数', '${stats['total_cards'] ?? 0}'),
      _SItem(Icons.replay, '累计复习', '${stats['total_reviews'] ?? 0}'),
      _SItem(Icons.today, '今日复习', '${stats['today_reviews'] ?? 0}'),
      _SItem(Icons.category, '覆盖领域', '${stats['domains_covered'] ?? 0}'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学习统计', style: theme.textTheme.titleMedium),
            const Divider(height: 20),
            Row(children: [
              Expanded(child: _statCol(items[0])),
              Expanded(child: _statCol(items[1])),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _statCol(items[2])),
              Expanded(child: _statCol(items[3])),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _statCol(_SItem item) {
    return Row(children: [
      Icon(item.icon, size: 18, color: Colors.grey.shade600),
      const SizedBox(width: 8),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item.value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Text(item.label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ]),
    ]);
  }

  // ── 月度学习日历热力图 ──
  Widget _buildHeatmap(ThemeData theme) {
    final days = _activityData!['days'] as List<dynamic>? ?? [];
    final scoreByDate = <String, int>{};
    final reviewsByDate = <String, int>{};
    final convsByDate = <String, int>{};
    final cardsByDate = <String, int>{};
    for (final d in days) {
      final day = d as Map<String, dynamic>;
      final date = day['date'] as String? ?? '';
      scoreByDate[date] = day['score'] as int? ?? 0;
      reviewsByDate[date] = day['reviews'] as int? ?? 0;
      convsByDate[date] = day['conversations'] as int? ?? 0;
      cardsByDate[date] = day['cards'] as int? ?? 0;
    }

    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);
    final daysInMonth = lastDay.day;
    final startWeekday = firstDay.weekday; // 1=Mon … 7=Sun
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    const monthNames = ['', '1月', '2月', '3月', '4月', '5月', '6月',
                        '7月', '8月', '9月', '10月', '11月', '12月'];
    final headerLabel = '$year年${monthNames[month]}';

    final maxScore = scoreByDate.values.fold<int>(0, (m, s) => s > m ? s : m);

    Color cellColor(int score) {
      if (score == 0) return Colors.grey.shade100;
      final t = maxScore > 0 ? score / maxScore : 0.0;
      if (t < 0.25) return Colors.green.shade100;
      if (t < 0.5) return Colors.green.shade300;
      if (t < 0.75) return Colors.green.shade500;
      return Colors.green.shade700;
    }

    final leadingBlanks = startWeekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final totalRows = (totalCells + 6) ~/ 7;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, constraints) {
          final cellSize = constraints.maxWidth / 7;
          final fontSize = (cellSize * 0.32).clamp(10.0, 15.0);

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── 月份导航 ──
            Row(children: [
              const Icon(Icons.calendar_month, size: 20),
              const SizedBox(width: 8),
              Text(headerLabel, style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: () => setState(() {
                  _calendarMonth = DateTime(year, month - 1);
                }),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                onPressed: () => setState(() {
                  _calendarMonth = DateTime(year, month + 1);
                }),
              ),
            ]),
            const SizedBox(height: 8),
            // ── 星期标题（与下方格子严格对齐） ──
            Row(children: ['一', '二', '三', '四', '五', '六', '日'].map((d) =>
              SizedBox(
                width: cellSize,
                child: Text(d,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ),
            ).toList()),
            const SizedBox(height: 4),
            // ── 日历格子（严格 7 列 × N 行） ──
            for (int row = 0; row < totalRows; row++) ...[
              Row(children: List.generate(7, (col) {
                final index = row * 7 + col;
                if (index < leadingBlanks || index >= totalCells) {
                  return SizedBox(width: cellSize, height: cellSize);
                }
                final day = index - leadingBlanks + 1;
                final dateStr = '$year-'
                    '${month.toString().padLeft(2, '0')}-'
                    '${day.toString().padLeft(2, '0')}';
                final score = scoreByDate[dateStr] ?? 0;
                final isToday = dateStr == todayStr;
                final reviews = reviewsByDate[dateStr] ?? 0;
                final convs = convsByDate[dateStr] ?? 0;
                final cardCount = cardsByDate[dateStr] ?? 0;

                return Tooltip(
                  message: '$dateStr'
                      '${reviews > 0 ? '\n复习 $reviews 次' : ''}'
                      '${convs > 0 ? '\n$convs 轮对话' : ''}'
                      '${cardCount > 0 ? '\n$cardCount 张卡' : ''}',
                  child: Container(
                    width: cellSize,
                    height: cellSize,
                    alignment: Alignment.center,
                    margin: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: cellColor(score),
                      borderRadius: BorderRadius.circular(4),
                      border: isToday
                          ? Border.all(color: theme.colorScheme.primary, width: 2)
                          : null,
                    ),
                    child: Text('$day',
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                          color: score == 0 ? Colors.grey.shade600 : Colors.black87,
                        )),
                  ),
                );
              })),
            ],
          ]);
        }),
      ),
    );
  }

  // ── K12 学习进度（卡片掌握度） ──
  Widget _buildK12Progress(ThemeData theme) {
    if (_k12Progress.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.school, size: 20),
            const SizedBox(width: 8),
            Text('学习计划进度', style: theme.textTheme.titleMedium),
          ]),
          const Divider(height: 16),
          ..._k12Progress.map((p) {
            final goal = p['goal'] as String? ?? '';
            final totalTasks = (p['total_tasks'] as num?)?.toInt() ?? 0;
            final doneTasks = (p['done_tasks'] as num?)?.toInt() ?? 0;
            final totalCards = (p['total_cards'] as num?)?.toInt() ?? 0;
            final masteredCards = (p['mastered_cards'] as num?)?.toInt() ?? 0;
            final pct = totalTasks > 0 ? doneTasks / totalTasks : 0.0;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(goal.isNotEmpty ? goal : '学习计划',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 6),
                // 任务进度
                Row(children: [
                  Text('任务', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(width: 8),
                  Expanded(child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: pct, minHeight: 6,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary)),
                  )),
                  const SizedBox(width: 8),
                  Text('$doneTasks/$totalTasks',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ]),
                const SizedBox(height: 4),
                // 卡片进度
                if (totalCards > 0)
                  Row(children: [
                    Text('卡片', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    const SizedBox(width: 8),
                    Expanded(child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                          value: totalCards > 0 ? masteredCards / totalCards : 0, minHeight: 6,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation(Colors.green)),
                    )),
                    const SizedBox(width: 8),
                    Text('$masteredCards/$totalCards',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  ]),
              ]),
            );
          }),
        ]),
      ),
    );
  }

  // ── CEFR 词汇 ──
  Widget _buildCefrSection(ThemeData theme) {
    final cefrStats = (_data!['cefr_stats'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
    if (cefrStats.isEmpty) return const SizedBox.shrink();

    final total = cefrStats.fold<int>(0, (s, e) => s + (e['count'] as int? ?? 0));
    final colors = {
      'A1': Colors.green, 'A2': Colors.lightGreen,
      'B1': Colors.blue, 'B2': Colors.indigo,
      'C1': Colors.purple, 'C2': Colors.deepPurple,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.language, size: 20),
            const SizedBox(width: 8),
            Text('词汇掌握度', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text('$total 词', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ]),
          const Divider(height: 16),
          ...cefrStats.map((s) {
            final level = s['level'] ?? '';
            final count = s['count'] ?? 0;
            final maxCount = s['max_count'] ?? 100;
            final ratio = maxCount > 0 ? (count as int) / (maxCount as int) : 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(width: 32, child: Text('$level',
                  style: TextStyle(fontWeight: FontWeight.w600,
                    color: colors[level] ?? Colors.grey, fontSize: 13))),
                const SizedBox(width: 8),
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: ratio, minHeight: 10,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(colors[level] ?? Colors.grey)),
                )),
                const SizedBox(width: 8),
                SizedBox(width: 36, child: Text('$count',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700))),
              ]),
            );
          }),
        ]),
      ),
    );
  }

  // ── 学习计划进度（来源于学习报告） ──
  Widget _buildLearningPlans(ThemeData theme) {
    final plans = _report!['plans'] as List<dynamic>? ?? [];
    if (plans.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.assignment, size: 20),
            const SizedBox(width: 8),
            Text('学习计划 (${plans.length})', style: theme.textTheme.titleMedium),
          ]),
          const Divider(height: 16),
          ...plans.asMap().entries.map((entry) {
            final i = entry.key;
            final plan = entry.value as Map<String, dynamic>;
            return Padding(
              padding: i < plans.length - 1 ? const EdgeInsets.only(bottom: 16) : EdgeInsets.zero,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(
                    plan['mode'] == 'completed' || plan['current_stage'] == '完成'
                        ? Icons.check_circle : Icons.play_circle,
                    size: 16,
                    color: plan['mode'] == 'completed' ? Colors.green : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(plan['goal'] as String? ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
                  if (plan['mode'] == 'completed')
                    Text('已完成', style: TextStyle(fontSize: 11, color: Colors.green.shade600)),
                ]),
                if (plan['current_stage'] is String && (plan['current_stage'] as String).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 24, top: 4),
                    child: Text('当前阶段：${plan['current_stage']}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ),
                if (((plan['total_tasks'] as int?) ?? 0) > 0) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ((plan['done_tasks'] as int?) ?? 0) / ((plan['total_tasks'] as int?) ?? 1),
                      minHeight: 6,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(
                        plan['mode'] == 'completed' ? Colors.green : theme.colorScheme.primary),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 24, top: 4),
                    child: Text('${plan['done_tasks']}/${plan['total_tasks']} 任务 (${plan['progress_pct']})',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ),
                ],
              ]),
            );
          }),
        ]),
      ),
    );
  }

  // ── 成就徽章（Phase 3 改版：Tab 分组 + 进度条） ──
  Widget _buildAchievements(ThemeData theme) {
    final categories = (_achievementsAll?['categories'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

    // 回退：如果新 API 无数据，用旧 profile 成就
    if (categories.isEmpty) {
      final achievements = (_data!['achievements'] as List<dynamic>?)
          ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
      if (achievements.isEmpty) return const SizedBox.shrink();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.emoji_events, size: 20),
              const SizedBox(width: 8),
              Text('成就 (${achievements.length})', style: theme.textTheme.titleMedium),
            ]),
            const Divider(height: 16),
            Wrap(
              spacing: 8, runSpacing: 12,
              children: achievements.map((a) => _AchievementTile(
                achievementKey: a['key'] as String? ?? '',
                name: a['name'] as String? ?? '',
                tier: a['tier'] as String? ?? 'bronze',
                unlockedAt: a['unlocked_at'] as String? ?? '',
                onTap: () {
                  ref.read(achievementNotifierProvider.notifier).push(
                    AchievementNotification(
                      key: a['key'] as String? ?? '',
                      name: a['name'] as String? ?? '',
                      tier: (a['tier'] as String?) ?? 'bronze',
                      unlockedAt: a['unlocked_at'] as String?,
                    ),
                  );
                },
              )).toList(),
            ),
          ]),
        ),
      );
    }

    // Phase 3: Tab 布局
    return Card(
      child: DefaultTabController(
        length: categories.length,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(children: [
              const Icon(Icons.emoji_events, size: 20),
              const SizedBox(width: 8),
              Text('成就徽章', style: theme.textTheme.titleMedium),
            ]),
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: Colors.grey,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: categories.map((cat) {
              final catKey = cat['category'] as String? ?? '';
              final count = (cat['achievements'] as List<dynamic>?)?.length ?? 0;
              final unlocked = (cat['achievements'] as List<dynamic>?)
                  ?.where((a) => (a as Map<String, dynamic>)['unlocked'] == true).length ?? 0;
              return Tab(
                height: 52,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(categoryIcon(catKey),
                      size: 16, color: tierColor('bronze')),
                  const SizedBox(width: 4),
                  Text('${cat['label'] ?? catKey}'),
                  const SizedBox(width: 2),
                  Text('$unlocked/$count',
                      style: const TextStyle(fontSize: 10)),
                ]),
              );
            }).toList(),
          ),
          SizedBox(
            height: 12 + categories.fold<int>(0, (h, cat) {
              final list = (cat['achievements'] as List<dynamic>?) ?? [];
              final cardsH = list.length * 108;
              return h > cardsH ? h : cardsH;
            }).toDouble(),
            child: TabBarView(
              children: categories.map((cat) {
                final items = (cat['achievements'] as List<dynamic>?)
                    ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      children: items.map((a) {
                        final catKey = cat['category'] as String? ?? '';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _AchievementCard(
                            item: a,
                            theme: theme,
                            onTap: (a['unlocked'] == true)
                                ? () {
                                    ref.read(achievementNotifierProvider.notifier).push(
                                      AchievementNotification(
                                        key: (a['id'] as String?) ?? '',
                                        name: (a['name'] as String?) ?? '',
                                        description: a['description'] as String?,
                                        icon: a['icon'] as String?,
                                        color: a['color'] as String?,
                                        tier: (a['tier'] as String?) ?? 'bronze',
                                        category: catKey,
                                        unlockedAt: a['unlocked_at'] as String?,
                                      ),
                                    );
                                  }
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SItem {
  final IconData icon;
  final String label;
  final String value;
  _SItem(this.icon, this.label, this.value);
}

class _AchievementTile extends StatelessWidget {
  final String achievementKey;
  final String name;
  final String tier;
  final String unlockedAt;
  final VoidCallback? onTap;
  const _AchievementTile({
    required this.achievementKey,
    required this.name,
    this.tier = 'bronze',
    required this.unlockedAt,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconData = achievementIcon(achievementKey);
    final iconColor = achievementColor(achievementKey);
    final tile = Tooltip(
      message: unlockedAt.isNotEmpty ? '获得于 $unlockedAt' : '',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(iconData, color: iconColor, size: 28),
        const SizedBox(height: 4),
        SizedBox(width: 64, child: Text(name, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: tile);
    }
    return tile;
  }
}

class _AchievementCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final ThemeData theme;
  final VoidCallback? onTap;
  const _AchievementCard({required this.item, required this.theme, this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = item['name'] as String? ?? '';
    final description = item['description'] as String? ?? '';
    final iconName = item['icon'] as String? ?? 'emoji_events';
    final colorHex = item['color'] as String? ?? '#CD7F32';
    final tier = item['tier'] as String? ?? 'bronze';
    final unlocked = item['unlocked'] as bool? ?? false;
    final unlockedAt = item['unlocked_at'] as String?;
    final progressPct = (item['progress_pct'] as num?)?.toDouble() ?? 0.0;
    final progressLabel = item['progress_label'] as String? ?? '';
    final hidden = item['hidden'] as bool? ?? false;

    // 隐藏且未解锁：加密显示（+ Q2 决议）
    final isHidden = hidden && !unlocked;
    final displayIcon = isHidden ? Icons.lock_outline : _mapIcon(iconName);
    final displayBgColor = isHidden ? Colors.grey : _hexToColor(colorHex);
    final displayName = isHidden ? '???' : name;
    final displayDesc = isHidden ? '隐藏成就' : description;

    final tierLabel = {'bronze': '铜', 'silver': '银', 'gold': '金', 'platinum': '铂', 'diamond': '钻'}[tier] ?? tier;
    final tierColorVal = tierColor(tier);

    final card = Container(
      decoration: BoxDecoration(
        color: (isHidden || !unlocked)
            ? Colors.grey.withValues(alpha: 0.04)
            : displayBgColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: (!isHidden && unlocked)
            ? Border.all(color: displayBgColor.withValues(alpha: 0.3))
            : null,
      ),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: (isHidden || !unlocked)
                ? Colors.grey.withValues(alpha: 0.1)
                : displayBgColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(displayIcon,
            color: (isHidden || !unlocked) ? Colors.grey.shade400 : displayBgColor, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(displayName, style: TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14,
                color: unlocked ? null : Colors.grey.shade600,
              )),
              if (!isHidden) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: tierColorVal.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(tierLabel,
                    style: TextStyle(fontSize: 10, color: tierColorVal, fontWeight: FontWeight.w600)),
                ),
              ],
              if (hidden && unlocked) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('隐藏', style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.w600)),
                ),
              ],
              if (unlocked) ...[
                const Spacer(),
                Icon(Icons.check_circle, size: 16, color: Colors.green.shade400),
              ],
            ]),
            const SizedBox(height: 4),
            Text(displayDesc,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            if (unlocked && unlockedAt != null)
              Text('获得于 $unlockedAt',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade400))
            else if (!isHidden) ...[
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progressPct, minHeight: 4,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(displayBgColor),
                  ),
                )),
                if (progressLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(progressLabel,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                ],
              ]),
            ],
          ],
        )),
      ]),
    );

    // 已解锁的成就才可以点击查看弹窗
    if (unlocked && onTap != null) {
      return GestureDetector(onTap: onTap, child: card);
    }
    return card;
  }

  IconData _mapIcon(String name) {
    return achievementIcon(name);
  }

  Color _hexToColor(String hex) {
    final h = hex.replaceFirst('#', '');
    if (h.length == 6) {
      return Color(int.parse('FF$h', radix: 16));
    }
    return Colors.grey;
  }
}
