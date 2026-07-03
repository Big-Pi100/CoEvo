// ignore_for_file: unnecessary_cast
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../widgets/twemoji.dart';
import '../providers/plan_provider.dart' hide cardRefreshProvider;
import '../api/chat_client.dart';
import '../shared/achievement_icons.dart';
import '../providers/achievement_notifier.dart';
import '../theme/app_theme.dart';

class AchievementsScreen extends ConsumerStatefulWidget {
  const AchievementsScreen({super.key});

  @override
  ConsumerState<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends ConsumerState<AchievementsScreen> {
  // ── Theme access ──
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  Map<String, dynamic>? _data;
  Map<String, dynamic>? _activityData;
  List<Map<String, dynamic>> _k12Progress = [];
  Map<String, dynamic>? _achievementsAll;
  Map<String, dynamic>? _planAchievements;
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  bool _isLoading = true;
  String? _error;
  bool _initialLoadDone = false;

  @override
  void initState() {
    super.initState();
    // 等 auth 就绪后加载数据
    WidgetsBinding.instance.addPostFrameCallback((_) => _waitForAuthThenLoad());
    // 监听卡片状态变化信号 → 刷新数据
    ref.listenManual(cardRefreshProvider, (prev, next) {
      if (prev != next && _initialLoadDone && !_isLoading) {
        _loadWithAuth(ref.read(authProvider));
      }
    });
  }

  Future<void> _waitForAuthThenLoad() async {
    for (int i = 0; i < 50; i++) {
      final auth = ref.read(authProvider);
      if (auth.isRestored && auth.userId != null && auth.token != null) {
        _loadWithAuth(auth);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    try { if (mounted) setState(() { _isLoading = false; _error = '登录状态异常，请重新登录'; }); } catch (_) {}
  }

  Future<void> _loadWithAuth(AuthState auth) async {
    debugPrint('AchievementsScreen._loadWithAuth: userId=${auth.userId}');
    final client = ChatClient(userId: auth.userId!, token: auth.token!);

    Map<String, dynamic>? achievementsAll;
    Map<String, dynamic>? planAchievements;
    try {
      achievementsAll = await client.getAchievementsAll();
      planAchievements = await client.getPlanAchievements();
    } catch (e) {
      debugPrint('AchievementsScreen: getAchievementsAll failed: $e');
    }

    try {
      final results = await Future.wait([
        client.getProfile(),
        client.getActivity(days: 365),
        client.getK12Progress(),
      ]);
      if (mounted) {
        setState(() {
          _data = results[0] as Map<String, dynamic>? ?? <String, dynamic>{};
          _activityData = results[1] as Map<String, dynamic>?;
          _k12Progress = ((results[2] as Map<String, dynamic>)['progress'] as List<dynamic>?)
              ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
          _achievementsAll = achievementsAll;
          _planAchievements = planAchievements;
          _isLoading = false;
          _error = null;
          _initialLoadDone = true;
        });
      }
    } catch (e) {
      debugPrint('AchievementsScreen._load: Future.wait failed: $e');
      if (mounted) setState(() { _isLoading = false; _data = <String, dynamic>{}; _error = '加载失败，请检查网络连接'; });
    }
  }

  Widget _buildEmptyOrErrorState() {
    final isError = _error != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.cloud_off_rounded : Icons.emoji_events_outlined,
              size: 64,
              color: isError ? _cs.outline : _cs.outlineVariant,
            ),
            const SizedBox(height: AppTheme.spacingLg),
            Text(
              isError ? '加载失败' : '暂无成就数据',
              style: _tt.titleLarge?.copyWith(color: _cs.onSurface),
            ),
            const SizedBox(height: AppTheme.spacingSm),
            Text(
              isError ? _error! : '完成学习任务后，你的成就将在这里展示',
              style: _tt.bodyMedium?.copyWith(color: _cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppTheme.spacingXl),
            if (isError)
              FilledButton.icon(
                onPressed: () {
                  setState(() { _isLoading = true; _error = null; });
                  _waitForAuthThenLoad();
                },
                icon: const Icon(Icons.refresh),
                label: Tw('重新加载'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Tw('成就'),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            tooltip: '通知',
            onPressed: () => context.push('/notifications'),
          ),
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _data == null
              ? _buildEmptyOrErrorState()
              : RefreshIndicator(
                  onRefresh: () async {
                    setState(() { _isLoading = true; _error = null; });
                    _loadWithAuth(ref.read(authProvider));
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(AppTheme.spacingLg),
                    children: [
                      _buildHeader(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      _buildStatsGrid(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      if (_activityData != null) _buildHeatmap(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      if (_k12Progress.isNotEmpty) _buildK12Progress(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      _buildCefrSection(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      _buildLearningPlans(theme),
                      const SizedBox(height: AppTheme.spacingLg),
                      _buildAchievements(theme),
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
        padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingXl, horizontal: AppTheme.spacingXl),
        child: Row(
          children: [
            Container(
              width: 60, height: 60,
              decoration: BoxDecoration(
                color: streakDays > 0 ? _cs.tertiary.withAlpha(25) : _cs.outline.withAlpha(20),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.local_fire_department,
                    color: streakDays > 0 ? _cs.tertiary : _cs.outline, size: 26),
                  Text('$streakDays',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                      color: streakDays > 0 ? _cs.tertiaryFixedDim : _cs.outline)),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.spacingLg),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(streakDays > 0 ? '连续学习 $streakDays 天' : '开始你的学习之旅',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('今日复习 $todayReviews 次 · 累计 $totalReviews 次',
                  style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant)),
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
        padding: const EdgeInsets.all(AppTheme.spacingXl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学习统计', style: theme.textTheme.titleMedium),
            const Divider(height: 20),
            Row(children: [
              Expanded(child: _statCol(items[0])),
              Expanded(child: _statCol(items[1])),
            ]),
            const SizedBox(height: AppTheme.spacingMd),
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
      Icon(item.icon, size: 18, color: _cs.onSurfaceVariant),
      const SizedBox(width: AppTheme.spacingSm),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item.value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Text(item.label, style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
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
      if (score == 0) return _cs.surfaceContainerLowest;
      final t = maxScore > 0 ? score / maxScore : 0.0;
      if (t < 0.25) return _cs.primaryContainer;
      if (t < 0.5) return _cs.primaryFixed;
      if (t < 0.75) return _cs.primaryFixedDim;
      return _cs.primary;
    }

    final leadingBlanks = startWeekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final totalRows = (totalCells + 6) ~/ 7;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingLg),
        child: LayoutBuilder(builder: (context, constraints) {
          final cellSize = constraints.maxWidth / 7;
          final fontSize = (cellSize * 0.32).clamp(10.0, 15.0);

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // ── 月份导航 ──
            Row(children: [
              const Icon(Icons.calendar_month, size: 20),
              const SizedBox(width: AppTheme.spacingSm),
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
            const SizedBox(height: AppTheme.spacingSm),
            // ── 星期标题（与下方格子严格对齐） ──
            Row(children: ['一', '二', '三', '四', '五', '六', '日'].map((d) =>
              SizedBox(
                width: cellSize,
                child: Tw(d,
                    textAlign: TextAlign.center,
                    style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
              ),
            ).toList()),
            const SizedBox(height: AppTheme.spacingXs),
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
                  child: SizedBox(
                    width: cellSize,
                    height: cellSize,
                    child: Container(
                      alignment: Alignment.center,
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: cellColor(score),
                        borderRadius: BorderRadius.circular(4),
                        border: isToday
                            ? Border.all(color: theme.colorScheme.primary, width: 2)
                            : null,
                      ),
                      child: Tw('$day',
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                          color: score == 0 ? _cs.onSurfaceVariant : _cs.onSurface,
                        )),
                  ),
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
        padding: const EdgeInsets.all(AppTheme.spacingXl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.school, size: 20),
            const SizedBox(width: AppTheme.spacingSm),
            Text('学习计划进度', style: theme.textTheme.titleMedium),
          ]),
          const Divider(height: 16),
          ..._k12Progress.map((p) {
            final goal = p['goal'] as String? ?? '';
            final gb = (p['grade_band'] as String? ?? '').replaceAll('g', '').replaceAll('-', '～');
            String label = goal.isNotEmpty ? goal : '学习计划';
            if (gb.isNotEmpty) label = '$label（$gb）';
            final totalTasks = (p['total_tasks'] as num?)?.toInt() ?? 0;
            final doneTasks = (p['done_tasks'] as num?)?.toInt() ?? 0;
            final totalCards = (p['total_cards'] as num?)?.toInt() ?? 0;
            final masteredCards = (p['mastered_cards'] as num?)?.toInt() ?? 0;
            final pct = totalTasks > 0 ? doneTasks / totalTasks : 0.0;

            return Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.spacingMd),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.isNotEmpty ? label : '学习计划',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 6),
                // 任务进度
                Row(children: [
                  Text('任务', style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
                  const SizedBox(width: AppTheme.spacingSm),
                  Expanded(child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: pct, minHeight: 6,
                        backgroundColor: _cs.surfaceContainerLow,
                        valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary)),
                  )),
                  const SizedBox(width: AppTheme.spacingSm),
                  Text('$doneTasks/$totalTasks',
                      style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
                ]),
                const SizedBox(height: AppTheme.spacingXs),
                // 卡片进度
                if (totalCards > 0)
                  Row(children: [
                    Text('卡片', style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
                    const SizedBox(width: AppTheme.spacingSm),
                    Expanded(child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                          value: totalCards > 0 ? masteredCards / totalCards : 0, minHeight: 6,
                          backgroundColor: _cs.surfaceContainerLow,
                          valueColor: AlwaysStoppedAnimation(_cs.primary)),
                    )),
                    const SizedBox(width: AppTheme.spacingSm),
                    Text('$masteredCards/$totalCards',
                        style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
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
      'A1': _cs.primary, 'A2': _cs.primaryFixed,
      'B1': _cs.secondary, 'B2': _cs.secondaryFixed,
      'C1': _cs.tertiaryFixed, 'C2': _cs.tertiaryFixedDim,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.language, size: 20),
            const SizedBox(width: AppTheme.spacingSm),
            Text('词汇掌握度', style: theme.textTheme.titleMedium),
            const Spacer(),
            Text('$total 词', style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant)),
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
                SizedBox(width: AppTheme.spacingXxxl, child: Tw('$level',
                  style: TextStyle(fontWeight: FontWeight.w600,
                    color: colors[level] ?? _cs.outline, fontSize: 13))),
                const SizedBox(width: AppTheme.spacingSm),
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: ratio, minHeight: 10,
                    backgroundColor: _cs.surfaceContainerLow,
                    valueColor: AlwaysStoppedAnimation(colors[level] ?? _cs.outline)),
                )),
                const SizedBox(width: AppTheme.spacingSm),
                SizedBox(width: 36, child: Tw('$count',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13, color: _cs.onSurface))),
              ]),
            );
          }),
        ]),
      ),
    );
  }

  // ── 学习计划进度（来源于 PlanProvider） ──
  Widget _buildLearningPlans(ThemeData theme) {
    final planState = ref.watch(planProvider);
    final plans = planState.plans;
    if (plans.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.assignment, size: 20),
            const SizedBox(width: AppTheme.spacingSm),
            Text('学习计划 (${plans.length})', style: theme.textTheme.titleMedium),
          ]),
          const Divider(height: 16),
          ...plans.asMap().entries.map((entry) {
            final i = entry.key;
            final plan = entry.value;
            final gn = plan.goal.isNotEmpty ? plan.goal : '学习计划';
            final gb = plan.gradeBand?.replaceAll('g', '').replaceAll('-', '～') ?? '';
            final title = gb.isNotEmpty ? '$gn（$gb）' : gn;

            return Padding(
              padding: i < plans.length - 1 ? const EdgeInsets.only(bottom: AppTheme.spacingLg) : EdgeInsets.zero,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.play_circle, size: 16),
                  const SizedBox(width: AppTheme.spacingSm),
                  Expanded(
                    child: Tw(title,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _cs.primary.withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Tw('${plan.totalCards} 卡片',
                        style: _tt.labelSmall?.copyWith(color: _cs.primary)),
                  ),
                ]),
                if (plan.stages != null && plan.stages!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: AppTheme.spacingXxl),
                    child: Tw('${plan.stages!.length} 个阶段',
                        style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant)),
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

    // 合并 plan 成就 tab
    final plans = (_planAchievements?['plans'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

    // 回退：如果新 API 无数据，用旧 profile 成就
    if (categories.isEmpty && plans.isEmpty) {
      final achievements = (_data!['achievements'] as List<dynamic>?)
          ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
      if (achievements.isEmpty) return const SizedBox.shrink();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingXl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.emoji_events, size: 20),
              const SizedBox(width: AppTheme.spacingSm),
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

    // Phase 3: Tab 布局（含 plan 成就 tab）
    final allTabs = [...categories, ...plans.map((p) => {
      'category': 'plan_${p['plan_id']}',
      'label': p['plan_name'],
      'achievements': p['achievements'],
      '_isPlan': true,
    })];

    return Card(
      child: DefaultTabController(
        length: allTabs.length,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.spacingXl, AppTheme.spacingXl, AppTheme.spacingXl, 0),
            child: Row(children: [
              const Icon(Icons.emoji_events, size: 20),
              const SizedBox(width: AppTheme.spacingSm),
              Text('成就徽章', style: theme.textTheme.titleMedium),
            ]),
          ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: _cs.outline,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: allTabs.map((tab) {
              final isPlan = tab['_isPlan'] == true;
              final catKey = tab['category'] as String? ?? '';
              if (isPlan) {
                return Tab(
                  height: 52,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.flag, size: 16, color: _cs.primary),
                    const SizedBox(width: AppTheme.spacingXs),
                    Text(tab['label'] as String? ?? ''),
                  ]),
                );
              }
              final count = (tab['achievements'] as List<dynamic>?)?.length ?? 0;
              final unlocked = (tab['achievements'] as List<dynamic>?)
                  ?.where((a) => (a as Map<String, dynamic>)['unlocked'] == true).length ?? 0;
              return Tab(
                height: 52,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(categoryIcon(catKey),
                      size: 16, color: tierColor('bronze')),
                  const SizedBox(width: AppTheme.spacingXs),
                  Text('${tab['label'] ?? catKey}'),
                  const SizedBox(width: 2),
                  Text('$unlocked/$count',
                      style: const TextStyle(fontSize: 10)),
                ]),
              );
            }).toList(),
          ),
          SizedBox(
            height: 12 + allTabs.fold<int>(0, (h, tab) {
              final list = (tab['achievements'] as List<dynamic>?) ?? [];
              final cardsH = list.length * 108;
              return h > cardsH ? h : cardsH;
            }).toDouble(),
            child: TabBarView(
              children: allTabs.map((tab) {
                final items = (tab['achievements'] as List<dynamic>?)
                    ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
                final isPlan = tab['_isPlan'] == true;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingSm),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      children: items.map((a) {
                        final name = a['name'] as String? ?? '';
                        final tier = a['tier'] as String? ?? 'bronze';
                        if (isPlan) {
                          // plan 成就：显示名 + tier 图标
                          final icon = a['icon'] as String? ?? 'emoji_events';
                          final key = a['achievement_key'] as String? ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                            child: _PlanAchievementCard(
                              name: name, tier: tier, icon: icon,
                              onTap: () {
                                ref.read(achievementNotifierProvider.notifier).push(
                                  AchievementNotification(
                                    key: key,
                                    name: name,
                                    tier: tier,
                                  ),
                                );
                              },
                            ),
                          );
                        }
                        final catKey = tab['category'] as String? ?? '';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
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

/// plan 成就卡片
class _PlanAchievementCard extends StatelessWidget {
  final String name;
  final String tier;
  final String icon;
  final VoidCallback? onTap;
  const _PlanAchievementCard({required this.name, required this.tier, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (IconData iconData, Color color) = switch (tier) {
      'bronze' => (Icons.emoji_events, const Color(0xFFCD7F32)),
      'silver' => (Icons.emoji_events, const Color(0xFFC0C0C0)),
      'gold' => (Icons.emoji_events, const Color(0xFFFFD700)),
      'platinum' => (Icons.diamond, const Color(0xFFE5E4E2)),
      'diamond' => (Icons.diamond, const Color(0xFFB9F2FF)),
      'special' => (Icons.stars, const Color(0xFFFF69B4)),
      _ => (Icons.emoji_events, const Color(0xFFCD7F32)),
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(children: [
          Icon(iconData, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(name, style: TextStyle(fontSize: 14, color: cs.onSurface))),
          Icon(Icons.check_circle, size: 16, color: color.withAlpha(150)),
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
        const SizedBox(height: AppTheme.spacingXs),
        SizedBox(width: 64, child: Tw(name, textAlign: TextAlign.center,
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

  // ── Theme access (redirects to widget's own theme) ──
  ColorScheme get _cs => theme.colorScheme;
  TextTheme get _tt => theme.textTheme;

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
    final displayBgColor = isHidden ? _cs.outline : _hexToColor(colorHex);
    final displayName = isHidden ? '???' : name;
    final displayDesc = isHidden ? '隐藏成就' : description;

    final tierLabel = {'bronze': '铜', 'silver': '银', 'gold': '金', 'platinum': '铂', 'diamond': '钻'}[tier] ?? tier;
    final tierColorVal = tierColor(tier);

    final card = Container(
      decoration: BoxDecoration(
        color: (isHidden || !unlocked)
            ? _cs.outline.withValues(alpha: 0.04)
            : displayBgColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: (!isHidden && unlocked)
            ? Border.all(color: displayBgColor.withValues(alpha: 0.3))
            : null,
      ),
      padding: const EdgeInsets.all(AppTheme.spacingMd),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: (isHidden || !unlocked)
                ? _cs.outline.withValues(alpha: 0.1)
                : displayBgColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(displayIcon,
            color: (isHidden || !unlocked) ? _cs.outlineVariant : displayBgColor, size: 24),
        ),
        const SizedBox(width: AppTheme.spacingMd),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(displayName, style: TextStyle(
                fontWeight: FontWeight.w600, fontSize: 14,
                color: unlocked ? null : _cs.onSurfaceVariant,
              )),
              if (!isHidden) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: tierColorVal.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Tw(tierLabel,
                    style: TextStyle(fontSize: 10, color: tierColorVal, fontWeight: FontWeight.w600)),
                ),
              ],
              if (hidden && unlocked) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _cs.tertiaryFixedDim.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Tw('隐藏', style: TextStyle(fontSize: 10, color: _cs.tertiary, fontWeight: FontWeight.w600)),
                ),
              ],
              if (unlocked) ...[
                const Spacer(),
                Icon(Icons.check_circle, size: 16, color: _cs.primaryFixedDim),
              ],
            ]),
            const SizedBox(height: AppTheme.spacingXs),
            Text(displayDesc,
              style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant),
              maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            if (unlocked && unlockedAt != null)
              Text('获得于 $unlockedAt',
                style: TextStyle(fontSize: 10, color: _cs.outlineVariant))
            else if (!isHidden) ...[
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progressPct, minHeight: 4,
                    backgroundColor: _cs.surfaceContainerLow,
                    valueColor: AlwaysStoppedAnimation(displayBgColor),
                  ),
                )),
                if (progressLabel.isNotEmpty) ...[
                  const SizedBox(width: AppTheme.spacingSm),
                  Text(progressLabel,
                    style: TextStyle(fontSize: 10, color: _cs.onSurfaceVariant)),
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
    return _cs.outline;
  }
}

