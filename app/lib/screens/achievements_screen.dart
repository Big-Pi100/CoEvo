// ignore_for_file: unnecessary_cast
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../api/chat_client.dart';

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
      if (mounted) {
        setState(() {
          _data = results[0] as Map<String, dynamic>?;
          _activityData = results[1] as Map<String, dynamic>?;
          _report = results[2] as Map<String, dynamic>?;
          _k12Progress = ((results[3] as Map<String, dynamic>)['progress'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
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

  // ── 学习日历（真实月历） ──
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
    final startWeekday = firstDay.weekday;
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    const monthNames = ['', '1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
    final headerLabel = '$year年${monthNames[month]}';
    final maxScore = scoreByDate.values.fold<int>(0, (m, s) => s > m ? s : m);

    Color cellColor(int score) {
      if (score == 0) return Colors.grey.shade100;
      final intensity = maxScore > 0 ? score / maxScore : 0.0;
      if (intensity < 0.25) return Colors.green.shade100;
      if (intensity < 0.5) return Colors.green.shade300;
      if (intensity < 0.75) return Colors.green.shade500;
      return Colors.green.shade700;
    }

    final cells = <Widget>[];
    final leadingBlanks = startWeekday - 1;
    for (int i = 0; i < leadingBlanks; i++) {
      cells.add(const SizedBox(width: 40, height: 40));
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr = '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      final score = scoreByDate[dateStr] ?? 0;
      final isToday = dateStr == todayStr;
      final bgColor = cellColor(score);
      final textColor = score == 0 ? Colors.black54 : Colors.black;
      final reviews = reviewsByDate[dateStr] ?? 0;
      final convs = convsByDate[dateStr] ?? 0;
      final cardCount = cardsByDate[dateStr] ?? 0;

      cells.add(
        Tooltip(
          message: '$dateStr\n复习$reviews次 · $convs轮对话 · $cardCount张卡',
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: isToday ? Border.all(color: theme.colorScheme.primary, width: 2) : null,
            ),
            alignment: Alignment.center,
            child: Text('$day',
              style: TextStyle(fontSize: 14,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                color: textColor)),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.calendar_month, size: 20),
            const SizedBox(width: 8),
            Text(headerLabel, style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 20),
              onPressed: () => setState(() {
                _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month - 1);
              }),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 20),
              onPressed: () => setState(() {
                _calendarMonth = DateTime(_calendarMonth.year, _calendarMonth.month + 1);
              }),
            ),
          ]),
          const SizedBox(height: 8),
          // Weekday header
          Row(children:
            ['一', '二', '三', '四', '五', '六', '日'].map((d) =>
              SizedBox(width: 40, child: Text(d, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)))
            ).toList(),
          ),
          const SizedBox(height: 4),
          // Calendar cells in 7-column wrap
          Wrap(children: cells),
        ]),
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

  // ── 成就徽章 ──
  Widget _buildAchievements(ThemeData theme) {
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
              icon: a['icon'] as String? ?? '🌟',
              name: a['name'] as String? ?? '',
              unlockedAt: a['unlocked_at'] as String? ?? '',
            )).toList(),
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
  final String icon;
  final String name;
  final String unlockedAt;
  const _AchievementTile({required this.icon, required this.name, required this.unlockedAt});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: unlockedAt.isNotEmpty ? '获得于 $unlockedAt' : '',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(icon, style: const TextStyle(fontSize: 28)),
        const SizedBox(height: 4),
        SizedBox(width: 64, child: Text(name, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
