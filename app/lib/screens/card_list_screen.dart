import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api/chat_client.dart';
import '../widgets/empty_state.dart';
import '../providers/auth_provider.dart';
import '../models/coevo_models.dart';

class CardListScreen extends ConsumerStatefulWidget {
  final bool embedded;
  const CardListScreen({super.key, this.embedded = false});

  @override
  ConsumerState<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends ConsumerState<CardListScreen> {
  // 按 plan 分组的数据
  List<_PlanGroup> _planGroups = [];
  // 拍平后全部卡片（供搜索/状态过滤）
  List<DueCard> _allCards = [];
  List<DueCard> _filteredCards = [];
  bool _isLoading = true;
  bool _hasLoadedOnce = false;

  // 搜索与状态过滤
  final _searchController = TextEditingController();
  int? _stateFilter;       // null = all
  Map<String, int> _stateCounts = {};

  static const _stateLabels = ['新卡片', '学习中', '复习中', '重学中'];
  static const _stateColors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_applyFilters);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlanMeta());
    ref.listenManual(cardRefreshProvider, (prev, next) {
      if (prev != next) _loadPlanMeta();
    });
    ref.listenManual(authProvider, (prev, next) {
      if (!_hasLoadedOnce && next.userId != null) _loadPlanMeta();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_applyFilters);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPlanMeta() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getCardsByPlan();
      final plansRaw = (resp['plans'] as List<dynamic>?) ?? [];

      final planGroups = <_PlanGroup>[];
      final allCards = <DueCard>[];
      final stateCounts = <String, int>{};

      for (final p in plansRaw) {
        final pMap = p as Map<String, dynamic>;
        final cardCount = (pMap['card_count'] as num?)?.toInt() ?? 0;
        planGroups.add(_PlanGroup(
          id: pMap['id'] as String? ?? '',
          goal: pMap['goal'] as String? ?? '',
          conversationId: pMap['conversation_id'] as String? ?? '',
          cardCount: cardCount,
        ));
      }

      setState(() {
        _planGroups = planGroups;
        _allCards = allCards;
        _stateCounts = stateCounts;
        _isLoading = false;
        _hasLoadedOnce = true;
      });
      _applyFilters();
    } catch (e) {
      debugPrint('_loadPlanMeta error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 惰性加载指定 plan 的卡片
  Future<void> _expandPlan(String conversationId) async {
    final group = _planGroups.where((g) => g.conversationId == conversationId).firstOrNull;
    if (group == null || group.expanded) return; // 已展开则跳过

    group.isLoading = true;
    group.expanded = true;
    setState(() {});

    final auth = ref.read(authProvider);
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getCardsByPlan(convId: conversationId);
      final plansRaw = (resp['plans'] as List<dynamic>?) ?? [];
      if (plansRaw.isNotEmpty) {
        final pMap = plansRaw[0] as Map<String, dynamic>;
        final cardsRaw = (pMap['cards'] as List<dynamic>?) ?? [];
        final loadedCards = cardsRaw
            .map((e) => DueCard.fromJson(e as Map<String, dynamic>))
            .toList();
        debugPrint('[_expandPlan] loading conv=$conversationId');
        group.cards = loadedCards;
        group.displayCards = List.from(loadedCards);
        debugPrint('[_expandPlan] loaded ${loadedCards.length} cards, displayCards=${group.displayCards.length}, group.cards=${group.cards.length}');
        // 同步加到 _allCards 中（供搜索/状态过滤）
        _allCards.addAll(loadedCards);
        // 统计状态
        for (final c in loadedCards) {
          final key = switch (c.state) { 0 => 'new', 1 => 'learning', 2 => 'review', _ => 'relearning' };
          _stateCounts[key] = (_stateCounts[key] ?? 0) + 1;
        }
      }
    } catch (e) {
      debugPrint('_expandPlan error: $e');
      // 加载失败：允许重新展开重试
      group.expanded = false;
    }
    group.isLoading = false;
    setState(() {});
  }

  void _applyFilters() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      // 按 state + 搜索 过滤拍平列表
      _filteredCards = _allCards.where((c) {
        if (query.isNotEmpty) {
          if (!c.front.toLowerCase().contains(query) &&
              !c.back.toLowerCase().contains(query)) {
            return false;
          }
        }
        if (_stateFilter != null && c.state != _stateFilter) return false;
        return true;
      }).toList();

      // 同步更新 planGroups 中的 cards 子集
      final filteredIds = _filteredCards.map((c) => c.id).toSet();
      for (final g in _planGroups) {
        g.displayCards = g.cards.where((c) => filteredIds.contains(c.id)).toList();
      }
    });
  }

  void _showCardDetail(DueCard card) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, scrollController) => Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text('正面', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Text(card.front, style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              )),
              const Divider(height: 32),
              Text('释义', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Text(card.back, style: Theme.of(context).textTheme.bodyLarge),
              if (card.sourceSentence != null) ...[
                const Divider(height: 32),
                Text('来源', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(height: 4),
                Text(card.sourceSentence!, style: TextStyle(
                  fontStyle: FontStyle.italic, color: Colors.grey.shade700,
                )),
              ],
              const Divider(height: 32),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  _InfoChip(label: '状态', value: _stateLabels[card.state.clamp(0, 3)]),
                  if (card.domain != null) _InfoChip(label: '领域', value: card.domain!),
                  _InfoChip(label: '复习', value: '${card.reps} 次'),
                  _InfoChip(label: '遗忘', value: '${card.lapses} 次'),
                  _InfoChip(label: '难度', value: card.difficulty.toStringAsFixed(1)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReviewDetails(String cardId) async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    final review = await client.getLastReview(cardId);
    if (!mounted || review == null) return;

    final details = review['details'];
    List<dynamic>? questionDetails;
    if (details is List) questionDetails = details;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: questionDetails != null ? 0.5 : 0.3,
        minChildSize: 0.3,
        maxChildSize: 0.7,
        expand: false,
        builder: (_, scrollController) => Padding(
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 24),
              Row(children: [const Icon(Icons.history, size: 20), const SizedBox(width: 8), Text('上次考试结果', style: Theme.of(context).textTheme.titleMedium)]),
              const SizedBox(height: 16),
              if (questionDetails != null && questionDetails.isNotEmpty)
                ...questionDetails.map((d) {
                  final q = d as Map<String, dynamic>;
                  final correct = q['correct'] == true;
                  return Card(
                    color: correct ? Colors.green.shade50 : Colors.red.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [Icon(correct ? Icons.check_circle : Icons.cancel, color: correct ? Colors.green : Colors.red, size: 18), const SizedBox(width: 8), Expanded(child: Text(q['question'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)))]),
                        const SizedBox(height: 6),
                        Text(q['feedback'] as String? ?? '', style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                      ]),
                    ),
                  );
                }),
              if (questionDetails == null || questionDetails.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text(review['verification_result'] as String? ?? '完成', style: TextStyle(color: Colors.grey.shade600)))),
              const SizedBox(height: 12),
              Center(child: Chip(avatar: Icon(review['verification_result'] == 'pass' ? Icons.check_circle : Icons.cancel, size: 16, color: review['verification_result'] == 'pass' ? Colors.green : Colors.red), label: Text(review['verification_result'] == 'pass' ? '已通过' : '未通过', style: TextStyle(color: review['verification_result'] == 'pass' ? Colors.green : Colors.red)))),
            ],
          ),
        ),
      ),
    );
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _buildBody();
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的卡片'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadPlanMeta)],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_planGroups.isEmpty) return _buildEmptyState();
    return Column(children: [
      // 搜索栏
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: '搜索卡片...',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchController.clear(); _applyFilters(); })
                : null,
          ),
        ),
      ),
      // 状态过滤
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          _StateBadge(label: '全部', count: _allCards.length, isActive: _stateFilter == null, onTap: () => setState(() { _stateFilter = null; _applyFilters(); })),
          const SizedBox(width: 6),
          _StateBadge(label: '新', count: _stateCounts['new'] ?? 0, color: Colors.blue, isActive: _stateFilter == 0, onTap: () => setState(() { _stateFilter = _stateFilter == 0 ? null : 0; _applyFilters(); })),
          const SizedBox(width: 6),
          _StateBadge(label: '学习中', count: _stateCounts['learning'] ?? 0, color: Colors.orange, isActive: _stateFilter == 1, onTap: () => setState(() { _stateFilter = _stateFilter == 1 ? null : 1; _applyFilters(); })),
          const SizedBox(width: 6),
          _StateBadge(label: '复习中', count: _stateCounts['review'] ?? 0, color: Colors.green, isActive: _stateFilter == 2, onTap: () => setState(() { _stateFilter = _stateFilter == 2 ? null : 2; _applyFilters(); })),
          const SizedBox(width: 6),
          _StateBadge(label: '重学', count: _stateCounts['relearning'] ?? 0, color: Colors.red, isActive: _stateFilter == 3, onTap: () => setState(() { _stateFilter = _stateFilter == 3 ? null : 3; _applyFilters(); })),
        ]),
      ),
      // 分组卡片列表
      Expanded(
        child: _planGroups.where((g) => g.cardCount > 0).isEmpty
            ? Center(child: Text('没有匹配的卡片', style: TextStyle(color: Colors.grey.shade500)))
            : RefreshIndicator(
                onRefresh: _loadPlanMeta,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    // 总卡片数
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('${_planGroups.fold<int>(0, (s, g) => s + g.cardCount)} 张卡片 · ${_planGroups.length} 个计划',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                    ),
                    // 每个 plan 一个折叠组
                    ..._planGroups.where((g) => g.cardCount > 0).map((g) => _buildPlanSection(g)),
                  ],
                ),
              ),
      ),
    ]);
  }

  Widget _buildPlanSection(_PlanGroup group) {
    debugPrint('[_buildPlanSection] goal=${group.goal}, expanded=${group.expanded}, cards=${group.cards.length}, display=${group.displayCards.length}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Plan 标题（可点击展开）
        GestureDetector(
          onTap: group.isLoading ? null : () => _expandPlan(group.conversationId),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(group.expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  group.goal.isEmpty ? '无标题计划' : group.goal,
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Theme.of(context).colorScheme.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (group.isLoading)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${group.cardCount}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ),
            ]),
          ),
        ),
        // 展开后显示卡片
        if (group.expanded) ...[
          const SizedBox(height: 4),
          if (group.cards.isEmpty && !group.isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(child: Text('暂无卡片', style: TextStyle(color: Colors.grey.shade500, fontSize: 13))),
            )
          else
            ...group.displayCards.map((card) => _buildCardTile(card)),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  double _progressOverlay(int state, int reps) {
    switch (state) {
      case 0: return 0.0;
      case 1: return reps >= 1 ? 0.5 : 1.0;
      case 2: if (reps >= 6) return 0.0; if (reps >= 3) return 0.5; return 1.0;
      case 3: if (reps >= 6) return 0.0; if (reps >= 3) return 0.5; return 1.0;
      default: return 0.0;
    }
  }

  Widget _buildCardTile(DueCard card) {
    final color = _stateColors[card.state.clamp(0, 3)];
    return Card(
      color: color,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(top: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Stack(children: [
        Positioned.fill(
          child: FractionallySizedBox(
            widthFactor: _progressOverlay(card.state, card.reps),
            alignment: Alignment.centerLeft,
            child: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withAlpha(60), color.withAlpha(20)], stops: const [0.0, 0.8]))),
          ),
        ),
        ListTile(
          dense: true,
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(50),
            child: const Icon(Icons.auto_stories, color: Colors.white, size: 18),
          ),
          title: Text(card.front, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14)),
          subtitle: Text(card.back, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withAlpha(200), fontSize: 12)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (card.lastReviewedAt != null)
              GestureDetector(
                onTap: () => _showReviewDetails(card.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: (card.lastReviewQuality ?? 0) >= 3 ? Colors.green.shade100 : Colors.red.shade100, borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon((card.lastReviewQuality ?? 0) >= 3 ? Icons.check_circle : Icons.cancel, size: 14, color: (card.lastReviewQuality ?? 0) >= 3 ? Colors.green : Colors.red),
                    const SizedBox(width: 3),
                    Text((card.lastReviewQuality ?? 0) >= 3 ? '正确' : '错误', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: (card.lastReviewQuality ?? 0) >= 3 ? Colors.green.shade700 : Colors.red.shade700)),
                  ]),
                ),
              ),
            if (card.lastReviewedAt != null) const SizedBox(width: 6),
            Chip(
              label: Text(_stateLabels[card.state.clamp(0, 3)], style: const TextStyle(fontSize: 10, color: Colors.white)),
              backgroundColor: color.withAlpha(100),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.block, size: 16),
              color: Colors.white.withAlpha(180),
              tooltip: '跳过',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => _doSkipCard(card),
            ),
          ]),
          onTap: () => _showCardDetail(card),
        ),
      ]),
    );
  }

  Future<void> _doSkipCard(DueCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳过这张卡片？'),
        content: Text('跳过「${card.front}」后将不再作为候选概念推荐。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('跳过', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      await client.updateCardStatus(card.id, 'skipped');
      setState(() {
        _allCards.removeWhere((c) => c.id == card.id);
        _filteredCards.removeWhere((c) => c.id == card.id);
        for (final g in _planGroups) {
          g.cards.removeWhere((c) => c.id == card.id);
          g.displayCards.removeWhere((c) => c.id == card.id);
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已跳过「${card.front}」')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('跳过失败: $e')));
      }
    }
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.inbox,
      title: '还没有卡片',
      subtitle: '和 AI 对话后，系统会自动提取知识点',
      actionLabel: '去对话',
      onAction: () => context.go('/chat'),
    );
  }
}

// ── 数据模型 ──

class _PlanGroup {
  final String id;
  final String goal;
  final String conversationId;
  final int cardCount;
  List<DueCard> cards;       // 展开后加载
  List<DueCard> displayCards;
  bool isLoading = false;    // 正在加载中
  bool expanded = false;     // 当前是否展开

  _PlanGroup({
    required this.id,
    required this.goal,
    required this.conversationId,
    required this.cardCount,
    List<DueCard>? cards,
  }) : cards = cards ?? [],
       displayCards = [];
}

// ── 小组件 ──

class _StateBadge extends StatelessWidget {
  final String label;
  final int count;
  final Color? color;
  final bool isActive;
  final VoidCallback onTap;

  const _StateBadge({
    required this.label, required this.count,
    this.color, required this.isActive, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = (color ?? Colors.grey).withAlpha(isActive ? 30 : 10);
    final txtColor = isActive ? (color ?? Colors.grey) : Colors.grey;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16), border: isActive ? Border.all(color: (color ?? Colors.grey).withAlpha(80)) : null),
        child: Text('$label $count', style: TextStyle(fontSize: 12, fontWeight: isActive ? FontWeight.w600 : FontWeight.normal, color: txtColor)),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      label: Text(value, style: const TextStyle(fontSize: 13)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
