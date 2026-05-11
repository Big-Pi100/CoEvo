import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api/chat_client.dart';
import '../widgets/empty_state.dart';
import '../providers/auth_provider.dart';
import '../models/coevo_models.dart';

class CardListScreen extends ConsumerStatefulWidget {
  const CardListScreen({super.key});

  @override
  ConsumerState<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends ConsumerState<CardListScreen> {
  List<DueCard> _allCards = [];
  List<DueCard> _filteredCards = [];
  bool _isLoading = true;

  // 搜索与过滤
  final _searchController = TextEditingController();
  int? _stateFilter;       // null = all
  String? _domainFilter;   // null = all
  List<String> _domains = [];
  Map<String, int> _stateCounts = {};
  String _sortBy = 'state';
  String get _sortLabel {
    switch (_sortBy) {
      case 'front': return '名称';
      case 'created': return '创建时间';
      case 'due': return '到期';
      default: return '状态';
    }
  }

  static const _stateLabels = ['新卡片', '学习中', '复习中', '重学中'];
  static const _stateColors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_applyFilters);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCards());
  }

  @override
  void dispose() {
    _searchController.removeListener(_applyFilters);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCards() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getAllCards(sort: _sortBy);
      final cards = (resp['cards'] as List<dynamic>?)
          ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      final stateCounts = resp['state_counts'] as Map<String, dynamic>? ?? {};
      final domains = (resp['domains'] as List<dynamic>?)
          ?.map((e) => e as String).toList() ?? [];

      setState(() {
        _allCards = cards;
        _domains = domains;
        _stateCounts = stateCounts.map((k, v) => MapEntry(k, (v as num).toInt()));
        _isLoading = false;
      });
      _applyFilters();
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _applyFilters() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredCards = _allCards.where((c) {
        // 搜索
        if (query.isNotEmpty) {
          if (!c.front.toLowerCase().contains(query) &&
              !c.back.toLowerCase().contains(query)) {
            return false;
          }
        }
        // 状态过滤
        if (_stateFilter != null && c.state != _stateFilter) return false;
        // 领域过滤
        if (_domainFilter != null && c.domain != _domainFilter) return false;
        return true;
      }).toList();
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

    // 解析考试细节
    final details = review['details'];
    List<dynamic>? questionDetails;
    if (details is List) {
      questionDetails = details;
    }

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
              Row(
                children: [
                  const Icon(Icons.history, size: 20),
                  const SizedBox(width: 8),
                  Text('上次考试结果', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 16),
              if (questionDetails != null && questionDetails.isNotEmpty)
                ...questionDetails.map((d) {
                  final q = d as Map<String, dynamic>;
                  final correct = q['correct'] == true;
                  return Card(
                    color: correct ? Colors.green.shade50 : Colors.red.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                correct ? Icons.check_circle : Icons.cancel,
                                color: correct ? Colors.green : Colors.red,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(
                                q['question'] as String? ?? '',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              )),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(q['feedback'] as String? ?? '',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                        ],
                      ),
                    ),
                  );
                }),
              if (questionDetails == null || questionDetails.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      review['verification_result'] as String? ?? '完成',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Center(
                child: Chip(
                  avatar: Icon(
                    review['verification_result'] == 'pass' ? Icons.check_circle : Icons.cancel,
                    size: 16,
                    color: review['verification_result'] == 'pass' ? Colors.green : Colors.red,
                  ),
                  label: Text(
                    review['verification_result'] == 'pass' ? '已通过' : '未通过',
                    style: TextStyle(
                      color: review['verification_result'] == 'pass' ? Colors.green : Colors.red,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的卡片')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _allCards.isEmpty
              ? _buildEmptyState()
              : Column(
                  children: [
                    // 搜索栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: '搜索卡片...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    _applyFilters();
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),

                    // 统计栏
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          _StateBadge(
                            label: '全部',
                            count: _allCards.length,
                            isActive: _stateFilter == null,
                            onTap: () => setState(() { _stateFilter = null; _applyFilters(); }),
                          ),
                          const SizedBox(width: 6),
                          _StateBadge(
                            label: '新', count: _stateCounts['new'] ?? 0,
                            color: Colors.blue,
                            isActive: _stateFilter == 0,
                            onTap: () => setState(() { _stateFilter = _stateFilter == 0 ? null : 0; _applyFilters(); }),
                          ),
                          const SizedBox(width: 6),
                          _StateBadge(
                            label: '学习中', count: _stateCounts['learning'] ?? 0,
                            color: Colors.orange,
                            isActive: _stateFilter == 1,
                            onTap: () => setState(() { _stateFilter = _stateFilter == 1 ? null : 1; _applyFilters(); }),
                          ),
                          const SizedBox(width: 6),
                          _StateBadge(
                            label: '复习中', count: _stateCounts['review'] ?? 0,
                            color: Colors.green,
                            isActive: _stateFilter == 2,
                            onTap: () => setState(() { _stateFilter = _stateFilter == 2 ? null : 2; _applyFilters(); }),
                          ),
                          const SizedBox(width: 6),
                          _StateBadge(
                            label: '重学', count: _stateCounts['relearning'] ?? 0,
                            color: Colors.red,
                            isActive: _stateFilter == 3,
                            onTap: () => setState(() { _stateFilter = _stateFilter == 3 ? null : 3; _applyFilters(); }),
                          ),
                        ],
                      ),
                    ),

                    // 领域标签
                    if (_domains.isNotEmpty)
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            _DomainChip(
                              label: '全部领域',
                              isActive: _domainFilter == null,
                              onTap: () => setState(() { _domainFilter = null; _applyFilters(); }),
                            ),
                            ..._domains.map((d) => Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _DomainChip(
                                label: d,
                                isActive: _domainFilter == d,
                                onTap: () => setState(() { _domainFilter = _domainFilter == d ? null : d; _applyFilters(); }),
                              ),
                            )),
                          ],
                        ),
                      ),

                    // 结果计数
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('${_filteredCards.length} 张卡片',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_sortLabel, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
                                onSelected: (sort) {
                                  if (sort != _sortBy) {
                                    setState(() => _sortBy = sort);
                                    _loadCards();
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'state', child: Text('按状态排序')),
                                  const PopupMenuItem(value: 'front', child: Text('按名称排序')),
                                  const PopupMenuItem(value: 'created', child: Text('按创建时间')),
                                  const PopupMenuItem(value: 'due', child: Text('按到期时间')),
                                ],
                                icon: const Icon(Icons.sort, size: 20),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // 卡片列表
                    Expanded(
                      child: _filteredCards.isEmpty
                          ? Center(
                              child: Text('没有匹配的卡片',
                                  style: TextStyle(color: Colors.grey.shade500)))
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: _filteredCards.length,
                              itemBuilder: (_, i) {
                                final card = _filteredCards[i];
                                return Dismissible(
                                  key: ValueKey('skip_${card.id}'),
                                  direction: DismissDirection.endToStart,
                                  background: Container(
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 24),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade400,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Icon(Icons.skip_next, color: Colors.white),
                                        SizedBox(width: 8),
                                        Text('跳过', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                  confirmDismiss: (_) async {
                                    final auth = ref.read(authProvider);
                                    if (auth.userId == null) return false;
                                    final client = ChatClient(userId: auth.userId!, token: auth.token);
                                    try {
                                      await client.skipConcept(card.front, card.sourceSentence ?? '');
                                      setState(() {
                                        _allCards.removeWhere((c) => c.id == card.id);
                                        _filteredCards.removeWhere((c) => c.id == card.id);
                                      });
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('已跳过「${card.front}」')),
                                        );
                                      }
                                      return true;
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('跳过失败: $e')),
                                        );
                                      }
                                      return false;
                                    }
                                  },
                                  child: Card(
                                    color: _stateColors[card.state.clamp(0, 3)],
                                    elevation: 0,
                                    clipBehavior: Clip.antiAlias,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      side: BorderSide(color: Colors.grey.shade200),
                                    ),
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: FractionallySizedBox(
                                            widthFactor: _progressOverlay(card.state, card.reps),
                                            alignment: Alignment.centerLeft,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  colors: [
                                                    _stateColors[card.state.clamp(0, 3)].withAlpha(60),
                                                    _stateColors[card.state.clamp(0, 3)].withAlpha(20),
                                                  ],
                                                  stops: const [0.0, 0.8],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: CircleAvatar(
                                                backgroundColor: _stateColors[card.state.clamp(0, 3)].withAlpha(50),
                                                child: Icon(Icons.auto_stories,
                                                  color: Colors.white, size: 20),
                                              ),
                                              title: Text(card.front, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                                              subtitle: Text(card.back, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withAlpha(200))),
                                              trailing: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (card.lastReviewedAt != null)
                                                    GestureDetector(
                                                      onTap: () => _showReviewDetails(card.id),
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                        decoration: BoxDecoration(
                                                        color: (card.lastReviewQuality ?? 0) >= 3
                                                            ? Colors.green.shade100
                                                            : Colors.red.shade100,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                            (card.lastReviewQuality ?? 0) >= 3
                                                                ? Icons.check_circle : Icons.cancel,
                                                            size: 16,
                                                            color: (card.lastReviewQuality ?? 0) >= 3
                                                                ? Colors.green : Colors.red,
                                                          ),
                                                          const SizedBox(width: 4),
                                                          Text(
                                                            (card.lastReviewQuality ?? 0) >= 3 ? '正确' : '错误',
                                                            style: TextStyle(
                                                              fontSize: 12,
                                                              fontWeight: FontWeight.w600,
                                                              color: (card.lastReviewQuality ?? 0) >= 3
                                                                  ? Colors.green.shade700 : Colors.red.shade700,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    ),
                                                  if (card.lastReviewedAt != null) const SizedBox(width: 8),
                                                  Chip(
                                                    label: Text(_stateLabels[card.state.clamp(0, 3)], style: const TextStyle(fontSize: 11, color: Colors.white)),
                                                    backgroundColor: _stateColors[card.state.clamp(0, 3)].withAlpha(100),
                                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                    visualDensity: VisualDensity.compact,
                                                  ),
                                                ],
                                              ),
                                              onTap: () => _showCardDetail(card),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ],
                ),
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
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: isActive ? Border.all(color: (color ?? Colors.grey).withAlpha(80)) : null,
        ),
        child: Text('$label $count', style: TextStyle(
          fontSize: 12, fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          color: txtColor,
        )),
      ),
    );
  }
}

class _DomainChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _DomainChip({required this.label, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? Theme.of(context).colorScheme.primary.withAlpha(30) : Colors.grey.withAlpha(15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 12,
          color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey.shade600,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        )),
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
