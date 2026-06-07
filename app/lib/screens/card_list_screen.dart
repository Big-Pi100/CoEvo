import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../api/chat_client.dart';
import '../widgets/empty_state.dart';
import '../providers/auth_provider.dart';
import '../models/coevo_models.dart';
import '../widgets/markdown_span_nodes.dart';
import '../theme/app_theme.dart';

class CardListScreen extends ConsumerStatefulWidget {
  final bool embedded;
  const CardListScreen({super.key, this.embedded = false});

  @override
  ConsumerState<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends ConsumerState<CardListScreen> {
  // ── Theme access ──
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  // 按 plan 分组的数据
  List<_PlanGroup> _planGroups = [];
  bool _isLoading = true;
  bool _hasLoadedOnce = false;

  // 搜索
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  bool _searchHasMore = false;
  int _searchOffset = 0;
  int _searchTotal = 0;

  // 卡片点击详情弹窗标识
  final Set<String> _expandedCardIds = {};

  @override
  void initState() {
    super.initState();
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
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPlanMeta() async {
    debugPrint('========== [_loadPlanMeta] START ==========');
    final auth = ref.read(authProvider);
    if (auth.userId == null) {
      debugPrint('[_loadPlanMeta] no auth, skip');
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getCardsByPlan();
      final plansRaw = (resp['plans'] as List<dynamic>?) ?? [];
      debugPrint('[_loadPlanMeta] plansRaw count=${plansRaw.length}');

      final planGroups = <_PlanGroup>[];

      for (int i = 0; i < plansRaw.length; i++) {
        final pMap = plansRaw[i] as Map<String, dynamic>;
        final cardCount = (pMap['card_count'] as num?)?.toInt() ?? 0;
        final gid = pMap['id'] as String? ?? '';
        final gConvId = pMap['conversation_id'] as String? ?? '';
        final gGoal = pMap['goal'] as String? ?? '';
        final gGb = pMap['grade_band'] as String? ?? '';
        debugPrint('[_loadPlanMeta]   plan[$i]: id=${gid.substring(0,8)} convId=${gConvId.substring(0,8)} goal=$gGoal grade_band=$gGb cardCount=$cardCount');
        planGroups.add(_PlanGroup(
          id: gid,
          goal: gGoal,
          gradeBand: gGb,
          conversationId: gConvId,
          cardCount: cardCount,
        ));
      }

      setState(() {
        _planGroups = planGroups;
        _isLoading = false;
        _hasLoadedOnce = true;
      });
      debugPrint('========== [_loadPlanMeta] DONE ==========');
    } catch (e) {
      debugPrint('_loadPlanMeta error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 切换展开/收起指定 plan（展开时惰性加载 20 张）
  Future<void> _togglePlan(String conversationId) async {
    final group = _planGroups.where((g) => g.conversationId == conversationId).firstOrNull;
    if (group == null || group.isLoading) return;

    // 已展开 → 收起
    if (group.expanded) {
      group.expanded = false;
      group.cards = [];
      group.displayCards = [];
      group.loadOffset = 0;
      group.hasMore = false;
      setState(() {});
      return;
    }

    // 未展开 → 展开加载
    group.isLoading = true;
    group.expanded = true;
    setState(() {});

    final auth = ref.read(authProvider);
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getCardsByPlan(convId: conversationId, limit: 20, offset: 0, sort: 'front');
      if (!mounted) return;
      final plansRaw = (resp['plans'] as List<dynamic>?) ?? [];
      final matchedPlan = plansRaw.cast<Map<String, dynamic>>().firstWhere(
        (p) => (p['conversation_id'] as String? ?? '') == conversationId,
        orElse: () => <String, dynamic>{},
      );
      final cardsRaw = (matchedPlan['cards'] as List<dynamic>?) ?? [];
      final loadedCards = cardsRaw
          .map((e) => DueCard.fromJson(e as Map<String, dynamic>))
          .toList();
      group.cards = loadedCards;
      group.displayCards = List.from(loadedCards);
      group.loadOffset = loadedCards.length;
      group.hasMore = loadedCards.length >= 20;
    } catch (e) {
      group.expanded = false;
    }
    group.isLoading = false;
    setState(() {});
  }

  /// 加载更多（当前 plan 追加 20 张）
  Future<void> _loadMorePlanCards(String conversationId) async {
    final group = _planGroups.where((g) => g.conversationId == conversationId).firstOrNull;
    if (group == null || !group.hasMore || group.isLoading) return;

    group.isLoading = true;
    setState(() {});

    final auth = ref.read(authProvider);
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getCardsByPlan(convId: conversationId, limit: 20, offset: group.loadOffset, sort: 'front');
      if (!mounted) return;
      final plansRaw = (resp['plans'] as List<dynamic>?) ?? [];
      final matchedPlan = plansRaw.cast<Map<String, dynamic>>().firstWhere(
        (p) => (p['conversation_id'] as String? ?? '') == conversationId,
        orElse: () => <String, dynamic>{},
      );
      final cardsRaw = (matchedPlan['cards'] as List<dynamic>?) ?? [];
      final moreCards = cardsRaw
          .map((e) => DueCard.fromJson(e as Map<String, dynamic>))
          .toList();
      group.cards.addAll(moreCards);
      group.displayCards = List.from(group.cards);
      group.loadOffset += moreCards.length;
      group.hasMore = moreCards.length >= 20;
    } catch (e, st) {
      debugPrint('加载更多卡片失败: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载失败: $e')),
        );
      }
    }
    group.isLoading = false;
    setState(() {});
  }

  /// 通过 API 搜索卡片
  Future<void> _doSearch(String query) async {
    if (query.trim().isEmpty) return;
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    setState(() { _isSearching = true; _searchOffset = 0; });
    try {
      final resp = await client.searchCards(query.trim(), limit: 20, offset: 0);
      if (!mounted) return;
      setState(() {
        _searchResults = (resp['cards'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
        _searchTotal = (resp['total'] as num?)?.toInt() ?? 0;
        _searchHasMore = resp['has_more'] as bool? ?? false;
        _searchOffset = _searchResults.length;
        _isSearching = false;
      });
    } catch (_) { setState(() => _isSearching = false); }
  }

  /// 搜索加载更多
  Future<void> _loadMoreSearch() async {
    if (_isSearching || !_searchHasMore) return;
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    setState(() => _isSearching = true);
    try {
      final resp = await client.searchCards(_searchController.text.trim(), limit: 20, offset: _searchOffset);
      if (!mounted) return;
      final more = (resp['cards'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      setState(() {
        _searchResults.addAll(more);
        _searchHasMore = resp['has_more'] as bool? ?? false;
        _searchOffset = _searchResults.length;
        _isSearching = false;
      });
    } catch (_) { setState(() => _isSearching = false); }
  }

  Widget _buildSearchResults() {
    if (_isSearching && _searchResults.isEmpty) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingLg, AppTheme.spacingMd, AppTheme.spacingLg, 0),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: '搜索卡片...',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIcon: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () { _searchController.clear(); setState(() => _searchResults = []); }),
          ),
          onSubmitted: _doSearch,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingSm),
        child: Text('搜索结果：共 $_searchTotal 条', style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
      ),
      Expanded(
        child: _searchResults.isEmpty
            ? Center(child: Text('未找到匹配卡片', style: TextStyle(color: _cs.onSurfaceVariant)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(AppTheme.spacingLg, 0, AppTheme.spacingLg, AppTheme.spacingXxl),
                itemCount: _searchResults.length + (_searchHasMore ? 1 : 0),
                itemBuilder: (ctx, i) {
                  if (i >= _searchResults.length) {
                    return Center(
                      child: TextButton(
                        onPressed: _loadMoreSearch,
                        child: _isSearching
                            ? const SizedBox(width: AppTheme.spacingLg, height: AppTheme.spacingLg, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('加载更多'),
                      ),
                    );
                  }
                  final card = DueCard.fromJson(_searchResults[i]);
                  return _buildCardTile(card);
                },
              ),
      ),
    ]);
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
          padding: const EdgeInsets.all(AppTheme.spacingXxl),
          child: ListView(
            controller: scrollController,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: _cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: AppTheme.spacingXxl),
              Row(children: [const Icon(Icons.history, size: 20), const SizedBox(width: AppTheme.spacingSm), Text('上次考试结果', style: Theme.of(context).textTheme.titleMedium)]),
              const SizedBox(height: AppTheme.spacingLg),
              if (questionDetails != null && questionDetails.isNotEmpty)
                ...questionDetails.map((d) {
                  final q = d as Map<String, dynamic>;
                  final correct = q['correct'] == true;
                  return Card(
                    color: correct ? _cs.primaryContainer : _cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.spacingMd),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [Icon(correct ? Icons.check_circle : Icons.cancel, color: correct ? _cs.primary : _cs.error, size: 18), const SizedBox(width: AppTheme.spacingSm), Expanded(child: Text(q['question'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600)))]),
                        const SizedBox(height: 6),
                        Text(q['feedback'] as String? ?? '', style: TextStyle(fontSize: 13, color: _cs.outline)),
                      ]),
                    ),
                  );
                }),
              if (questionDetails == null || questionDetails.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingXxl), child: Center(child: Text(review['verification_result'] as String? ?? '完成', style: TextStyle(color: _cs.onSurfaceVariant)))),
              const SizedBox(height: AppTheme.spacingMd),
              Center(child: Chip(avatar: Icon(review['verification_result'] == 'pass' ? Icons.check_circle : Icons.cancel, size: 16, color: review['verification_result'] == 'pass' ? _cs.primary : _cs.error), label: Text(review['verification_result'] == 'pass' ? '已通过' : '未通过', style: TextStyle(color: review['verification_result'] == 'pass' ? _cs.primary : _cs.error)))),
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

    // 搜索状态：显示搜索结果
    final isSearching = _searchController.text.trim().isNotEmpty;
    if (isSearching) return _buildSearchResults();

    return Column(children: [
      // 搜索栏
      Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.spacingLg, AppTheme.spacingSm, AppTheme.spacingLg, 0),
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: '搜索卡片...',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchController.clear(); setState(() => _searchResults = []); })
                : null,
          ),
          onSubmitted: _doSearch,
          onChanged: (v) {
            if (v.isEmpty) setState(() => _searchResults = []);
          },
        ),
      ),
      // 分组卡片列表
      Expanded(
        child: _planGroups.where((g) => g.cardCount > 0).isEmpty
            ? Center(child: Text('没有匹配的卡片', style: TextStyle(color: _cs.onSurfaceVariant)))
            : RefreshIndicator(
                onRefresh: _loadPlanMeta,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(AppTheme.spacingLg, 0, AppTheme.spacingLg, AppTheme.spacingXxl),
                  children: [
                    // 总卡片数
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                      child: Text('${_planGroups.fold<int>(0, (s, g) => s + g.cardCount)} 张卡片 · ${_planGroups.length} 个计划',
                          style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
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
          onTap: group.isLoading ? null : () => _togglePlan(group.conversationId),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withAlpha(12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(group.expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: AppTheme.spacingSm),
              Expanded(
                child: Text(() {
                  String label = group.goal.isEmpty ? '无标题计划' : group.goal;
                  if (group.gradeBand.isNotEmpty) {
                    final gb = group.gradeBand.replaceAll('g', '').replaceAll('-', '～');
                    label = '$label（$gb）';
                  }
                  return label;
                }(),
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Theme.of(context).colorScheme.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (group.isLoading)
                const SizedBox(width: AppTheme.spacingMd, height: AppTheme.spacingMd, child: CircularProgressIndicator(strokeWidth: 2)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSm, vertical: 2),
                decoration: BoxDecoration(
                  color: _cs.outline.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${group.cardCount}', style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
        // 展开后显示卡片
        if (group.expanded) ...[
          const SizedBox(height: AppTheme.spacingXs),
          if (group.cards.isEmpty && !group.isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSm),
              child: Center(child: Text('暂无卡片', style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13))),
            )
          else ...[
            ...group.displayCards.map((card) => _buildCardTile(card)),
            // 加载更多按钮
            if (group.hasMore)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingXs),
                  child: TextButton(
                    onPressed: group.isLoading ? null : () => _loadMorePlanCards(group.conversationId),
                    child: group.isLoading
                        ? const SizedBox(width: AppTheme.spacingLg, height: AppTheme.spacingLg, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('加载更多'),
                  ),
                ),
              ),
          ],
        ],
        const SizedBox(height: AppTheme.spacingSm),
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
    final colors = [_cs.secondary, _cs.tertiary, _cs.primary, _cs.tertiaryFixed];
    final color = colors[card.state.clamp(0, 3)];
    return Card(
      color: color,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(top: AppTheme.spacingXs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _cs.outlineVariant),
      ),
      child: Stack(children: [
        Positioned.fill(
          child: FractionallySizedBox(
            widthFactor: _progressOverlay(card.state, card.reps),
            alignment: Alignment.centerLeft,
            child: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withAlpha(60), color.withAlpha(20)], stops: const [0.0, 0.8]))),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(50),
            child: Icon(Icons.auto_stories, color: _cs.onPrimary, size: 18),
          ),
          title: Text(card.front, style: TextStyle(fontWeight: FontWeight.w600, color: _cs.onPrimary)),
          subtitle: Text('${_cardBackPreview(card.back)}\n复习 ${card.reps} 次', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _cs.onPrimary.withAlpha(200))),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (card.lastReviewedAt != null)
              GestureDetector(
                onTap: () => _showReviewDetails(card.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: (card.lastReviewQuality ?? 0) >= 3 ? _cs.primaryContainer : _cs.errorContainer, borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon((card.lastReviewQuality ?? 0) >= 3 ? Icons.check_circle : Icons.cancel, size: 14, color: (card.lastReviewQuality ?? 0) >= 3 ? _cs.primary : _cs.error),
                    const SizedBox(width: 3),
                    Text((card.lastReviewQuality ?? 0) >= 3 ? '正确' : '错误', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: (card.lastReviewQuality ?? 0) >= 3 ? _cs.primary : _cs.error)),
                  ]),
                ),
              ),
            if (card.lastReviewedAt != null) const SizedBox(width: 6),
            Chip(
              label: Text(switch (card.state) { 0 => '新卡片', 1 => '学习中', 2 => '复习中', _ => '重学中' }, style: TextStyle(fontSize: 10, color: _cs.onPrimary)),
              backgroundColor: color.withAlpha(100),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: AppTheme.spacingXs),
            IconButton(
              icon: const Icon(Icons.block, size: 16),
              color: _cs.onPrimary.withAlpha(180),
              tooltip: '跳过',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => _doSkipCard(card),
            ),
            const SizedBox(width: 2),
            Icon(_expandedCardIds.contains(card.id) ? Icons.expand_less : Icons.expand_more,
                 size: 20, color: _cs.onPrimary.withAlpha(180)),
          ]),
          onTap: () {
            setState(() {
              if (_expandedCardIds.contains(card.id)) {
                _expandedCardIds.remove(card.id);
              } else {
                _expandedCardIds.add(card.id);
              }
            });
          },
        ),
        if (_expandedCardIds.contains(card.id)) ...[
          _buildCardDetailInline(card),
        ],
      ]),
    ]),
    );
  }

  static String _formatTimestamp(int? ts) {
    if (ts == null || ts == 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  static String _relativeTime(int? ts) {
    if (ts == null || ts == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final now = DateTime.now();
    final diff = dt.difference(now);
    final days = diff.inDays;
    if (days < 0) return '${-days} 天前';
    if (days == 0) return '今天';
    if (days == 1) return '明天';
    return '$days 天后';
  }

  static String _intervalText(int? from, int? to) {
    if (from == null || to == null || from == 0 || to == 0) return '';
    final days = ((to - from) / 86400).round();
    if (days <= 0) return '';
    return '间隔 $days 天';
  }

  Widget _buildCardDetailInline(DueCard card) {
    final hasTimeline = card.createdAt != null || card.lastReviewedAt != null || card.due != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: _cs.onPrimary.withAlpha(96)),
        Padding(
          padding: const EdgeInsets.all(AppTheme.spacingLg),
          child: DefaultTextStyle(
            style: TextStyle(color: _cs.onPrimary),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('正面', style: _tt.bodySmall?.copyWith(color: _cs.onPrimary.withAlpha(150))),
              const SizedBox(height: AppTheme.spacingXs),
              RichContentBuilder(textColor: _cs.onPrimary).build(card.front),
              Divider(height: 32, color: _cs.onPrimary.withAlpha(96)),
              Text('释义', style: _tt.bodySmall?.copyWith(color: _cs.onPrimary.withAlpha(150))),
              const SizedBox(height: AppTheme.spacingXs),
              RichContentBuilder(textColor: _cs.onPrimary).build(card.back),
              if (card.sourceSentence != null) ...[
                Divider(height: 32, color: _cs.onPrimary.withAlpha(96)),
                Text('来源', style: _tt.bodySmall?.copyWith(color: _cs.onPrimary.withAlpha(150))),
                const SizedBox(height: AppTheme.spacingXs),
                RichContentBuilder(textColor: _cs.onPrimary).build(card.sourceSentence!),
              ],
              if (hasTimeline) ...[
                Divider(height: 32, color: _cs.onPrimary.withAlpha(96)),
                Row(children: [
                  Icon(Icons.timeline, size: 16, color: _cs.onPrimary.withAlpha(96)),
                  const SizedBox(width: 6),
                  Text('复习时间线', style: _tt.bodySmall?.copyWith(color: _cs.onPrimary.withAlpha(150))),
                ]),
                const SizedBox(height: AppTheme.spacingMd),
                _TimelineRow(
                  label: '创建时间',
                  time: _formatTimestamp(card.createdAt),
                ),
                if (card.lastReviewedAt != null) ...[
                  const SizedBox(height: AppTheme.spacingSm),
                  _TimelineRow(
                    label: '上次复习',
                    time: _formatTimestamp(card.lastReviewedAt),
                    hint: _relativeTime(card.lastReviewedAt),
                  ),
                ],
                if (card.due != null) ...[
                  const SizedBox(height: AppTheme.spacingSm),
                  _TimelineRow(
                    label: '下次复习',
                    time: _formatTimestamp(card.due),
                    hint: _relativeTime(card.due),
                    extra: _intervalText(card.lastReviewedAt, card.due),
                  ),
                ],
              ],
              Divider(height: 32, color: _cs.onPrimary.withAlpha(96)),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  _InfoChip(label: '状态', value: switch (card.state) { 0 => '新卡片', 1 => '学习中', 2 => '复习中', _ => '重学中' }),
                  if (card.domain != null) _InfoChip(label: '领域', value: card.domain!),
                  _InfoChip(label: '复习', value: '${card.reps} 次'),
                  _InfoChip(label: '遗忘', value: '${card.lapses} 次'),
                  _InfoChip(label: '难度', value: card.difficulty.toStringAsFixed(1)),
                ],
              ),
            ]),
          ),
        ),
      ],
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
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('跳过', style: TextStyle(color: _cs.error))),
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

  String _cardBackPreview(String back) {
    final t = back.trim();
    if (t.startsWith('{') && t.endsWith('}')) {
      try {
        final parsed = jsonDecode(t) as Map<String, dynamic>;
        return (parsed['full_text'] as String?)?.replaceAll('\n', ' ') ?? back;
      } catch (_) {}
    }
    return back;
  }
}

// ── 数据模型 ──

class _PlanGroup {
  final String id;
  final String goal;
  final String gradeBand;
  final String conversationId;
  final int cardCount;
  List<DueCard> cards;
  List<DueCard> displayCards;
  bool isLoading = false;
  bool expanded = false;
  int loadOffset = 0;    // 已加载卡片数（用于下一页 offset）
  bool hasMore = false;  // 是否有更多卡片

  _PlanGroup({
    required this.id,
    required this.goal,
    required this.conversationId,
    required this.cardCount,
    this.gradeBand = '',
    List<DueCard>? cards,
  }) : cards = cards ?? [],
       displayCards = [];
}

// ── 小组件 ──
// _StateBadge removed (state filter feature removed)

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Chip(
      avatar: Text(label, style: TextStyle(fontSize: 10, color: cs.outline)),
      label: Text(value, style: const TextStyle(fontSize: 13)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final String label;
  final String time;
  final String? hint;
  final String? extra;
  const _TimelineRow({required this.label, required this.time, this.hint, this.extra});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Row(children: [
      SizedBox(width: 56, child: Text(label, style: tt.bodySmall?.copyWith(color: cs.onPrimary.withAlpha(120)))),
      Expanded(child: Text(time, style: const TextStyle(fontSize: 13))),
      if (hint != null && hint!.isNotEmpty)
        Text(hint!, style: tt.bodySmall?.copyWith(color: cs.onPrimary.withAlpha(150))),
      if (extra != null && extra!.isNotEmpty) ...[
        const SizedBox(width: AppTheme.spacingSm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: cs.onPrimary.withAlpha(25),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(extra!, style: tt.labelSmall?.copyWith(color: cs.onPrimary.withAlpha(180))),
        ),
      ],
    ]);
  }
}
