import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../providers/achievement_notifier.dart';
import '../services/tts_service.dart';
import '../pipelines/verification_strategy.dart';
import '../widgets/markdown_span_nodes.dart';
import 'card_list_screen.dart';
import '../theme/app_theme.dart';

/// 复习: 内联复习队列
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> with SingleTickerProviderStateMixin {
  // ── Theme access ──
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  final _answerController = TextEditingController();
  ChatClient? _client;
  List<DueCard> _cards = [];

  int _activeCardIndex = -1;
  bool _isFlipped = false;
  bool _isLoading = true;
  bool _hasLoadedOnce = false;
  String? _loadError;
  String _verificationResult = '';
  bool _isVerified = false;
  bool _isVerifying = false;
  bool _isAiQuiz = false;
  List<VerifyQuestion> _aiQuestions = [];
  int _aiQuestionIndex = 0;
  List<String> _aiAnswers = [];
  List<JudgeResult> _aiResults = [];
  int _reviewedCount = 0;
  final _scrollController = ScrollController();
  final Map<int, GlobalKey> _cardKeys = {};
  List<VerifyQuestion> _preloadedQuestions = [];
  bool _preloadingQuiz = false;
  bool _isJudging = false;
  bool _hasMore = false;

  // 订阅状态
  bool _subscriptionRequired = false;
  bool _subscriptionExpired = false;
  bool _subscriptionChecked = false;

  // Riverpod 订阅（必须在 dispose 中关闭）
  ProviderSubscription? _cardRefreshSub;
  ProviderSubscription? _authListenerSub;

  // 计划标签 & domain 过滤
  late TabController _tabController;
  List<Map<String, dynamic>> _planTabs = [];
  String? _selectedConvId;  // 当前选中的 plan tab 的 conversation_id（null=全部卡片）

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCards();
      _loadPlans();
      _checkSubscription();
    });
    // 监听卡片刷新
    _cardRefreshSub = ref.listenManual(cardRefreshProvider, (prev, next) {
      if (prev != next && mounted) {
        _loadCards();
        _loadPlans();
      }
    });
    // 监听 auth 恢复：当 auth 从不可用变为可用时自动重新加载
    _authListenerSub = ref.listenManual(authProvider, (prev, next) {
      if (!_hasLoadedOnce && next.userId != null) {
        _loadCards();
        _loadPlans();
      }
    });
  }

  @override
  void dispose() {
    _cardRefreshSub?.close();
    _authListenerSub?.close();
    _tabController.dispose();
    _answerController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPlans() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final planList = await client.getPlans();
      // 并行获取卡片统计（用于 tab badge 显示，不受 _cards LIMIT 500 限制）
      Map<String, int> cardCountByConv = {};
      try {
        final cardCountResp = await client.getCardsByPlan();
        final plansRaw = (cardCountResp['plans'] as List<dynamic>?) ?? [];
        for (final p in plansRaw) {
          final pMap = p as Map<String, dynamic>;
          final convId = pMap['conversation_id'] as String? ?? '';
          final count = (pMap['card_count'] as num?)?.toInt() ?? 0;
          if (convId.isNotEmpty) cardCountByConv[convId] = count;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        // 合并 cardCount 到 planTabs
        _planTabs = planList.map((p) {
          final convId = p['conversation_id'] as String? ?? '';
          final count = cardCountByConv[convId];
          if (count != null) p['card_count'] = count;
          return p;
        }).where((p) {
          // 隐藏没有待复习卡片的 tab（所有卡片 due 都在未来）
          final dueCount = (p['due_card_count'] as num?)?.toInt() ?? 1;
          return dueCount > 0;
        }).toList();
        final totalTabs = 1 + _planTabs.length;
        final oldIndex = _tabController.index;
        _tabController.dispose();
        _tabController = TabController(length: totalTabs, vsync: this,
          initialIndex: oldIndex.clamp(0, totalTabs - 1));
      });
    } catch (_) {}
  }

  Future<void> _checkSubscription() async {
    if (_client == null) return;
    try {
      final prefs = await _client!.getPreferences();
      final expiresStr = prefs['subscription_expires'];
      if (expiresStr == null || expiresStr.isEmpty) {
        if (mounted) setState(() {
          _subscriptionRequired = true;
          _subscriptionExpired = false;
          _subscriptionChecked = true;
        });
        return;
      }
      final expires = DateTime.tryParse(expiresStr);
      if (expires == null) {
        if (mounted) setState(() {
          _subscriptionRequired = true;
          _subscriptionExpired = false;
          _subscriptionChecked = true;
        });
        return;
      }
      final now = DateTime.now();
      if (mounted) setState(() {
        _subscriptionExpired = now.isAfter(expires);
        _subscriptionRequired = false;
        _subscriptionChecked = true;
      });
    } catch (e) {
      debugPrint('ReviewScreen._checkSubscription: $e');
      if (mounted) setState(() => _subscriptionChecked = true);
    }
  }

  void _initClient() {
    final auth = ref.read(authProvider);
    _client = ChatClient(
      userId: auth.userId ?? 'default_user',
      token: auth.token,
    );
  }

  Future<void> _loadCards() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    _initClient();
    if (_client == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    try {
      final convId = _selectedConvId;
      final resp = await _client!.getDueCards(conversationId: convId, limit: 20, offset: 0);
      setState(() {
        _cards = (resp['cards'] as List<dynamic>?)
            ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
            .toList() ?? [];
        _hasMore = resp['has_more'] as bool? ?? false;
        _isLoading = false;
        _hasLoadedOnce = true;
        _activeCardIndex = _cards.isNotEmpty ? 0 : -1;
      });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _loadError = '加载失败，请检查网络连接'; });
    }
  }

  /// 补货：队列 ≤ 10 时加载下 10 张
  Future<void> _replenishQueue() async {
    if (_client == null || _cards.isEmpty) return;
    try {
      final convId = _selectedConvId;
      final offset = _cards.length;
      final resp = await _client!.getDueCards(conversationId: convId, limit: 10, offset: offset);
      final newCards = (resp['cards'] as List<dynamic>?)
          ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      setState(() {
        _cards.addAll(newCards);
        _hasMore = resp['has_more'] as bool? ?? false;
      });
    } catch (e) {
      debugPrint('ReviewScreen._replenishQueue: $e');
    }
  }

  void _resetInlineReview() {
    setState(() {
      _isFlipped = false;
      _isVerified = false;
      _isVerifying = false;
      _verificationResult = '';
      _isAiQuiz = false;
      _aiQuestions = [];
      _preloadedQuestions = [];
      _preloadingQuiz = false;
      _isJudging = false;
      _aiQuestionIndex = 0;
      _aiAnswers = [];
      _aiResults = [];
      _answerController.clear();
    });
  }

void _showCompletionStats() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('今日复习完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: _cs.primary, size: 48),
              ],
            ),
            const SizedBox(height: AppTheme.spacingLg),
            Text('本次复习了 $_reviewedCount 张卡片',
                style: _tt.bodyLarge!),
            const SizedBox(height: AppTheme.spacingSm),
            Text('保持节奏，每天进步一点点！',
                style: TextStyle(color: _cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<void> _skipCard(DueCard card) async {
    if (_client == null) return;
    try {
      await _client!.updateCardStatus(card.id, 'skipped');
      if (mounted) {
        setState(() {
          _cards.removeWhere((c) => c.id == card.id);
          _activeCardIndex = -1;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已跳过「${card.front}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('跳过失败: $e')),
        );
      }
    }
  }

  Future<void> _preloadAiQuestions(DueCard card) async {
    if (_client == null) return;
    if (_subscriptionRequired || _subscriptionExpired) return;
    setState(() => _preloadingQuiz = true);
    try {
      final resp = await _client!.verifyQuestions(card.id, card.front, card.back);
      final questions = (resp['questions'] as List<dynamic>?)
          ?.map((e) => VerifyQuestion.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      if (mounted && _activeCardIndex >= 0 && _cards[_activeCardIndex].id == card.id) {
        setState(() {
          _preloadedQuestions = questions;
          _preloadingQuiz = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _preloadingQuiz = false);
    }
  }

  // ── 内联复习方法 ──

  Future<void> _startInlineAiQuiz(DueCard card) async {
    // 优先用预加载的问题（零延迟）
    if (_preloadedQuestions.isNotEmpty) {
      setState(() {
        _isAiQuiz = true;
        _aiQuestions = List.from(_preloadedQuestions);
        _aiQuestionIndex = 0;
        _aiAnswers = List.filled(_preloadedQuestions.length, '');
      });
      return;
    }
    // 降级: 实时生成
    if (_client == null) return;
    if (_subscriptionRequired || _subscriptionExpired) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要有效订阅才能使用 AI 问答功能')),
        );
      }
      return;
    }
    try {
      final resp = await _client!.verifyQuestions(card.id, card.front, card.back);
      final questions = (resp['questions'] as List<dynamic>?)
          ?.map((e) => VerifyQuestion.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      setState(() {
        _isAiQuiz = true;
        _aiQuestions = questions;
        _aiQuestionIndex = 0;
        _aiAnswers = List.filled(questions.length, '');
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AI 问答启动失败: $e')),
        );
      }
    }
  }

  void _submitInlineAiAnswer() {
    if (_aiQuestionIndex >= _aiQuestions.length) return;
    _aiAnswers[_aiQuestionIndex] = _answerController.text.trim();
    _answerController.clear();
    setState(() => _aiQuestionIndex++);
    if (_aiQuestionIndex >= _aiQuestions.length) {
      _judgeInlineAnswers();
    }
  }

  Future<void> _judgeInlineAnswers() async {
    if (_client == null || _cards.isEmpty || _activeCardIndex < 0) return;
    if (_subscriptionRequired || _subscriptionExpired) return;
    setState(() => _isJudging = true);
    final card = _cards[_activeCardIndex];
    try {
      final questions = List.generate(_aiQuestions.length, (i) => {
        'question': _aiQuestions[i].question,
        'expected_answer': _aiQuestions[i].expectedAnswer,
        'user_answer': i < _aiAnswers.length ? _aiAnswers[i] : '',
      });
      final resp = await _client!.judgeAnswers(cardId: card.id, questions: questions);
      final results = (resp['results'] as List<dynamic>?)
          ?.map((e) => JudgeResult.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      final correct = resp['total_correct'] as int? ?? 0;
      _aiResults = results;
      _verificationResult = correct >= 2 ? 'pass' : 'fail';
      setState(() {
        _isVerified = true;
        _isVerifying = false;
        _isJudging = false;
      });
      // 展示 5 秒后自动提交（让用户看清结果）
      Future.delayed(const Duration(milliseconds: 5000), () {
        if (mounted) _submitInlineReview(_activeCardIndex);
      });
    } catch (e) {
      if (mounted) setState(() => _isJudging = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('判断失败: $e')),
        );
      }
    }
  }

  Future<void> _submitInlineReview(int index) async {
    if (_client == null) return;
    final displayCards = _filteredCards;
    if (index >= displayCards.length) return;
    final card = displayCards[index];
    final strategy = resolveStrategy(card);
    final vtype = strategy.isSpellingBased ? 'spelling' : 'ai_dialogue';
    // 序列化每道题细节
    String? detailsJson;
    if (_aiResults.isNotEmpty) {
      detailsJson = jsonEncode(List.generate(_aiResults.length, (i) {
        final aiQ = i < _aiQuestions.length ? _aiQuestions[i] : null;
        return {
          'question': aiQ?.question ?? '',
          'correct': _aiResults[i].correct,
          'feedback': _aiResults[i].feedback,
        };
      }));
    }
    try {
      final resp = await _client!.submitReview(
        cardId: card.id,
        rating: _verificationResult == 'pass' ? 3 : 1,
        verificationType: vtype,
        verificationResult: _verificationResult,
        detailsJson: detailsJson,
      );
      setState(() {
        _reviewedCount++;
        _cards.removeWhere((c) => c.id == card.id);
        _activeCardIndex = -1;
      });
      final achievements = resp['achievements'] as List<dynamic>?;
      if (achievements != null && achievements.isNotEmpty) {
        final notifier = ref.read(achievementNotifierProvider.notifier);
        for (final a in achievements.cast<Map<String, dynamic>>()) {
          notifier.push(AchievementNotification.fromJson(a));
        }
      }
      if (_cards.isEmpty) {
        final convId = _selectedConvId;
        try {
          final resp = await _client!.getDueCards(conversationId: convId, limit: 10, offset: 0);
          final more = (resp['cards'] as List<dynamic>?)?.length ?? 0;
          if (more == 0 && mounted) _showCompletionStats();
        } catch (_) { if (mounted) _showCompletionStats(); }
      }
      // 队列 ≤ 10 且有更多卡片时自动补货
      if (_cards.length <= 10 && _hasMore && mounted) {
        _replenishQueue();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提交失败: $e')),
        );
      }
    }
  }

  // ── Build ──

  /// 按 conversation_id 匹配的待复习卡片数
  /// 优先从 planTabs 中缓存的 cardCount 取值，兜底降级到 _cards 过滤
  int _planDueCount(String convId) {
    if (convId.isEmpty) return 0;
    // 从 planTabs 找 cardCount（精准，不受 _cards 500 条限制影响）
    for (final p in _planTabs) {
      if ((p['conversation_id'] as String? ?? '') == convId) {
        final cached = p['card_count'] as int?;
        if (cached != null) return cached;
        break;
      }
    }
    // 兜底：从已加载的 _cards 过滤（可能因 LIMIT 500 截断而不准）
    return _cards.where((c) => c.conversationId == convId).length;
  }

  /// 从 plan goal + grade_band 提取简短标签
  String _planLabel(Map<String, dynamic> plan) {
    final goal = plan['goal'] as String? ?? '';
    final gb = plan['grade_band'] as String? ?? '';
    final label = goal.replaceAll(RegExp(r'^K12:\s*'), '');
    if (gb.isNotEmpty) {
      return '$label（$gb）';
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    // TabBar 切换时更新 conversation_id 过滤
    void onTabChanged() {
      final i = _tabController.index;
      if (i < _planTabs.length) {
        final convId = _planTabs[i]['conversation_id'] as String? ?? '';
        if (convId != _selectedConvId) {
          setState(() {
            _selectedConvId = convId;
            _activeCardIndex = -1;
            _resetInlineReview();
            _cards = [];
          });
          _loadCards();
        }
      } else {
        setState(() {
          _selectedConvId = null;
          _activeCardIndex = -1;
          _resetInlineReview();
        });
      }
    }
    _tabController.removeListener(onTabChanged);
    _tabController.addListener(onTabChanged);
    // 初始化时应用首 tab 的 conversation_id
    if (_selectedConvId == null && _planTabs.isNotEmpty) {
      _selectedConvId = _planTabs[0]['conversation_id'] as String? ?? '';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('复习'),
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          controller: _tabController,
          labelColor: Theme.of(context).colorScheme.onSurface,
          tabs: [
            ..._planTabs.map((p) {
              final convId = p['conversation_id'] as String? ?? '';
              final count = _planDueCount(convId);
              final label = _planLabel(p);
              // 截取前5个字符（中文字符每个占1个UTF-16单元）
              final shortLabel = label.length > 5 ? label.substring(0, 5) : label;
              return Tab(
                child: SizedBox(
                  width: 90,  // ≈ 5 个中文字符宽度
                  child: Text('$shortLabel（$count）',
                      overflow: TextOverflow.ellipsis, maxLines: 1),
                ),
              );
            }),
            const Tab(child: SizedBox(width: 90, child: Text('全部卡片', overflow: TextOverflow.ellipsis, maxLines: 1))),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          ..._planTabs.map((_) => _buildReviewTab()),
          const CardListScreen(embedded: true),  // 全部卡片永远放最后
        ],
      ),
    );
  }

  /// 按 conversation_id 过滤的待复习列表
  /// - 选中 plan tab: 匹配卡片 conversationId == 该 plan 的 conversation_id
  /// - 选中"全部卡片": 不过滤
  /// domain 仅用于内部分类标签，不用于 tab 匹配
  List<DueCard> get _filteredCards {
    if (_selectedConvId == null) return _cards;
    return _cards.where((c) => c.conversationId == _selectedConvId).toList();
  }

  Widget _buildReviewTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // 加载失败状态
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingXxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 48, color: _cs.outline),
              const SizedBox(height: AppTheme.spacingLg),
              Text('加载失败', style: _tt.titleLarge?.copyWith(color: _cs.onSurface)),
              const SizedBox(height: AppTheme.spacingSm),
              Text(_loadError!, style: _tt.bodyMedium?.copyWith(color: _cs.onSurfaceVariant), textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.spacingXl),
              FilledButton.icon(
                onPressed: () {
                  setState(() { _isLoading = true; _loadError = null; });
                  _loadCards();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    final displayCards = _filteredCards;

    // 订阅检查横幅
    if (_subscriptionChecked && (_subscriptionRequired || _subscriptionExpired)) {
      final isExpired = _subscriptionExpired;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingXxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isExpired ? Icons.subscriptions_outlined : Icons.info_outline,
                  size: 48, color: isExpired ? _cs.errorContainer : _cs.tertiaryFixedDim),
              const SizedBox(height: AppTheme.spacingLg),
              Text(
                isExpired ? '订阅已过期' : '需要订阅',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppTheme.spacingSm),
              Text(
                isExpired
                    ? '你的订阅已过期，续费后可继续使用 AI 复习功能'
                    : '请先购买订阅，解锁 AI 辅助复习功能',
                textAlign: TextAlign.center,
                style: TextStyle(color: _cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (displayCards.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadCards,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline, size: 64, color: _cs.primaryFixed),
                    const SizedBox(height: AppTheme.spacingLg),
                    Text('今日复习完成！', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: AppTheme.spacingSm),
                    Text('共复习 $_reviewedCount 张卡片',
                        style: TextStyle(color: _cs.onSurfaceVariant)),
                    const SizedBox(height: AppTheme.spacingXxl),
                    FilledButton(
                      onPressed: () => context.go('/chat'),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCards,
      child: _buildQueue(),
    );
  }

  /// 蒙版宽度因子：0.0 = 无蒙版（全进度），1.0 = 全蒙版（无进度）
  double _progressOverlay(int state, int reps) {
    switch (state) {
      case 0: // 新卡片 — 无蒙版，全彩色
        return 0.0;
      case 1: // 学习中 — 0 或 50%
        return reps >= 1 ? 0.5 : 1.0;
      case 2: // 复习中 — 0 / 50 / 100%
        if (reps >= 6) return 0.0;
        if (reps >= 3) return 0.5;
        return 1.0;
      case 3: // 重学中 — 0 / 50 / 100%
        if (reps >= 6) return 0.0;
        if (reps >= 3) return 0.5;
        return 1.0;
      default:
        return 0.0;
    }
  }

  Widget _buildQueue() {
    final stateLabels = ['新卡片', '学习中', '复习中', '重学中'];
    final stateColors = [_cs.secondary, _cs.tertiary, _cs.primary, _cs.tertiaryFixed];
    final displayCards = _filteredCards;

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      itemCount: displayCards.length,
      itemBuilder: (_, i) {
        final card = displayCards[i];
        final state = card.state.clamp(0, 3);
        final isActive = _activeCardIndex == i;

        return Dismissible(
          key: ValueKey('review_${card.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: AppTheme.spacingXxl),
            decoration: BoxDecoration(
              color: _cs.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.skip_next, color: _cs.onPrimary),
                SizedBox(width: AppTheme.spacingSm),
                Text('跳过', style: TextStyle(color: _cs.onPrimary, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          confirmDismiss: (_) async {
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
            if (confirmed != true) return false;
            await _skipCard(card);
            return true;
          },
          child: Card(
            color: stateColors[state],
            elevation: 0,
            key: _cardKeys.putIfAbsent(i, () => GlobalKey()),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: _cs.surfaceContainerLow),
            ),
            child: Stack(
              children: [
                // 进度蒙版：用渐变替代白色 alpha
                Positioned.fill(
                  child: FractionallySizedBox(
                    widthFactor: _progressOverlay(card.state, card.reps),
                    alignment: Alignment.centerLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            stateColors[state].withAlpha(60),
                            stateColors[state].withAlpha(20),
                          ],
                          stops: const [0.0, 0.8],
                        ),
                      ),
                    ),
                  ),
                ),
                // 卡片内容
                Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: stateColors[state].withAlpha(50),
                      child: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.bold, color: _cs.onPrimary)),
                    ),
                    title: Text(card.front, style: TextStyle(fontWeight: FontWeight.w600, color: _cs.onPrimary)),
                    subtitle: isActive ? null : Text('${card.back}\n复习 ${card.reps} 次', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _cs.onPrimary.withAlpha(200))),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(
                      label: Text(stateLabels[state], style: _tt.labelSmall!),
                      backgroundColor: stateColors[state].withAlpha(20),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    if (!isActive) ...[
                      const SizedBox(width: AppTheme.spacingXs),
                      Icon(Icons.expand_more, size: 20, color: _cs.outlineVariant),
                    ],
                  ],
                ),
                onTap: () {
                  if (isActive) {
                    setState(() => _activeCardIndex = -1);
                  } else {
                    setState(() => _activeCardIndex = i);
                    _resetInlineReview();
                    // 展开后只滚动到刚好可视
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final key = _cardKeys[i];
                      if (key?.currentContext != null) {
                        Scrollable.ensureVisible(
                          key!.currentContext!,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          alignment: 0.1, // 顶部留 10% 边距
                        );
                      }
                    });
                    // 预生成 AI 问题（非拼写验证类卡片）
                    final strategy = resolveStrategy(card);
                    if (!strategy.isSpellingBased) {
                      _preloadAiQuestions(card);
                    }
                  }
                },
              ),

              // 展开内联复习
              if (isActive) ...[
                Divider(height: 1, color: _cs.onPrimary.withAlpha(38)),
                Padding(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  child: DefaultTextStyle(
                    style: TextStyle(color: _cs.onPrimary),
                    child: _buildInlineReview(card),
                  ),
                ),
              ],
            ],
          ),
          ],
        ),
      ),
    );
  },
    );
  }

  Widget _buildInlineReview(DueCard card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 翻牌区域（验证中锁定为正面，闭卷）
        GestureDetector(
          onTap: _isVerifying ? null : () => setState(() => _isFlipped = !_isFlipped),
          child: Container(
            padding: const EdgeInsets.all(AppTheme.spacingXl),
            decoration: BoxDecoration(
              color: _isVerifying ? const Color(0xFFF5F5FF) :
                     _isFlipped ? _cs.surface : _cs.primary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _cs.surfaceContainerLow),
            ),
            child: Column(
              children: [
                // 卡片内容（考试模式降低不透明度）
                Padding(
                  padding: const EdgeInsets.all(AppTheme.spacingSm),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(scale: animation, child: child),
                        );
                      },
                      child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: _isVerifying ? 5.0 : 0.0,
                        sigmaY: _isVerifying ? 5.0 : 0.0,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _isVerifying || !_isFlipped
                          ? Text(
                              card.front,
                              key: const ValueKey('front'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: _isVerifying ? const Color(0x051A1A2E) : const Color(0xFF1A1A2E),
                                height: 1.4,
                              ),
                              textAlign: TextAlign.center,
                            )
                          : Container(
                              key: const ValueKey('back'),
                              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg),
                              child: RichContentBuilder(textColor: _cs.onSurface).build(card.back),
                            ),
                      ),
                    ),
                    ),
                  ),
                if (!_isVerifying && _isFlipped && card.sourceSentence != null) ...[
                  const SizedBox(height: AppTheme.spacingSm),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text('来源: ${card.sourceSentence}',
                        key: ValueKey(card.sourceSentence),
                        style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant, fontStyle: FontStyle.italic)),
                  ),
                ],
                const SizedBox(height: AppTheme.spacingSm),
                Text(
                  _isVerifying ? '闭卷考试中' :
                  _isFlipped ? '点击收回' : '点击翻转查看释义',
                  style: _tt.bodySmall?.copyWith(color: _isVerifying ? _cs.secondaryFixed : _cs.onSurfaceVariant)),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingMd),

        // TTS
        Consumer(
          builder: (_, ref, __) {
            final tts = ref.watch(ttsServiceProvider);
            final enabled = ref.watch(ttsEnabledProvider);
            if (!enabled) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.volume_up, size: 18),
                label: Text(_isFlipped ? '朗读释义' : '朗读概念'),
                onPressed: () => tts.speak(
                  (_isFlipped ? card.back : card.front).replaceAll('**', ''),
                ),
              ),
            );
          },
        ),

        // 记忆验证（正面背面均显示）
        if (!_isVerified && !_isVerifying) ...[
          const SizedBox(height: AppTheme.spacingSm),
          resolveStrategy(card).buildButton(
            context,
            () {
              setState(() { _isFlipped = false; _isVerifying = true; });
              if (!resolveStrategy(card).isSpellingBased) {
                _startInlineAiQuiz(card);
              }
            },
            isReady: _preloadedQuestions.isNotEmpty,
            isLoading: _preloadingQuiz,
          ),
        ],

        // 验证输入（管线策略路由，仅在验证中显示）
        if (_isVerifying && !_isVerified && resolveStrategy(card).isSpellingBased)
          resolveStrategy(card).buildInput(
            context: context,
            card: card,
            controller: _answerController,
            isVerifying: _isVerifying,
            isVerified: _isVerified,
            verificationResult: _verificationResult,
            onSubmit: (_) async {
              if (resolveStrategy(card).isSpellingBased) {
                final strategy = resolveStrategy(card);
                _verificationResult = await strategy.submitVerification(
                  card: card,
                  client: _client!,
                  userInput: _answerController.text,
                );
                _isVerified = true;
                _isVerifying = false;
                setState(() {});
                Future.delayed(const Duration(milliseconds: 5000), () {
                  if (mounted) _submitInlineReview(_cards.indexOf(card));
                });
              }
            },
          ),

        // AI 问答（闭卷中）
        if (_isVerifying && !_isJudging && _isAiQuiz && _aiQuestions.isNotEmpty && _aiResults.isEmpty && _aiQuestionIndex < _aiQuestions.length) ...[
          const SizedBox(height: AppTheme.spacingSm),
          Text('问题 ${_aiQuestionIndex + 1}/${_aiQuestions.length}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppTheme.spacingXs),
          Text(_aiQuestions[_aiQuestionIndex].question,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: AppTheme.spacingSm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _answerController,
                  decoration: const InputDecoration(hintText: '你的回答...', isDense: true, border: OutlineInputBorder()),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitInlineAiAnswer(),
                ),
              ),
              const SizedBox(width: AppTheme.spacingSm),
              IconButton.filled(
                onPressed: _submitInlineAiAnswer,
                icon: const Icon(Icons.arrow_forward, size: 18),
              ),
            ],
          ),
        ],

        // 判断中...
        if (_isJudging) ...[
          const SizedBox(height: AppTheme.spacingMd),
Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: AppTheme.spacingLg, height: AppTheme.spacingLg, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: AppTheme.spacingSm),
                Text('正在判断答案...', style: TextStyle(color: _cs.outline)),
              ],
            ),
          ),
        ],

        // AI 结果（自动提交前显示 1.5s）
        if (_aiResults.isNotEmpty && !_isJudging) ...[
          const SizedBox(height: AppTheme.spacingSm),
          ..._aiResults.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.spacingXs),
            child: Row(
              children: [
                Icon(r.correct ? Icons.check_circle : Icons.cancel,
                    color: r.correct ? _cs.primary : _cs.error, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(r.feedback, style: _tt.bodySmall!)),
              ],
            ),
          )),
        ],

        // 验证结果（5 秒提示）
        if (_isVerified)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.spacingMd),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _verificationResult == 'pass'
                    ? _cs.primaryContainer : _cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _verificationResult == 'pass'
                      ? _cs.primaryFixed : _cs.errorContainer,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _verificationResult == 'pass'
                        ? Icons.check_circle : Icons.cancel,
                    color: _verificationResult == 'pass'
                        ? _cs.primary : _cs.error,
                    size: 22,
                  ),
                  const SizedBox(width: AppTheme.spacingSm),
                  Text(
                    _verificationResult == 'pass' ? '验证通过 ✅' : '未通过 ❌',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _verificationResult == 'pass'
                          ? _cs.primary : _cs.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
