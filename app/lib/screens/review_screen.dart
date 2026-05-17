import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../services/tts_service.dart';
import 'card_list_screen.dart';

/// 复习: 内联复习队列
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final _answerController = TextEditingController();
  ChatClient? _client;
  List<DueCard> _cards = [];

  int _activeCardIndex = -1;
  bool _isFlipped = false;
  bool _isLoading = true;
  bool _hasLoadedOnce = false;
  String _verificationResult = '';
  bool _isVerified = false;
  bool _isVerifying = false;  // 闭卷考试模式（翻回正面，不可再翻看）
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCards());
    ref.listenManual(cardRefreshProvider, (prev, next) {
      if (prev != next && mounted) _loadCards();
    });
    // 监听 auth 恢复：当 auth 从不可用变为可用时自动重新加载
    ref.listenManual(authProvider, (prev, next) {
      if (!_hasLoadedOnce && next.userId != null) {
        _loadCards();
      }
    });
  }

  @override
  void dispose() {
    _answerController.dispose();
    _scrollController.dispose();
    super.dispose();
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
      final resp = await _client!.getDueCards();
      setState(() {
        _cards = (resp['cards'] as List<dynamic>?)
            ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
            .toList() ?? [];
        _isLoading = false;
        _hasLoadedOnce = true;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<int> _loadMoreCards() async {
    try {
      final resp = await _client!.getDueCards();
      final newCards = (resp['cards'] as List<dynamic>?)
          ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      setState(() {
        _cards = newCards;
        _activeCardIndex = -1;
      });
      return newCards.length;
    } catch (_) {
      return 0;
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

  void _showAchievementDialog(List<Map<String, dynamic>> achievements) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.emoji_events, color: Colors.amber, size: 28),
            SizedBox(width: 8),
            Text('成就解锁！'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: achievements.map((a) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Text(a['icon'] as String? ?? '🌟', style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(a['name'] as String? ?? '',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          )).toList(),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('太棒了！'),
          ),
        ],
      ),
    );
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
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 48),
              ],
            ),
            const SizedBox(height: 16),
            Text('本次复习了 $_reviewedCount 张卡片',
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('保持节奏，每天进步一点点！',
                style: TextStyle(color: Colors.grey.shade600)),
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
      await _client!.skipConcept(card.front, card.sourceSentence ?? '');
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
    if (_client == null || index >= _cards.length) return;
    final card = _cards[index];
    final vtype = card.cardType == 'vocabulary' ? 'spelling' : 'ai_dialogue';
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
        _cards.removeAt(index);
        _activeCardIndex = -1;
      });
      final achievements = resp['achievements'] as List<dynamic>?;
      if (achievements != null && achievements.isNotEmpty) {
        _showAchievementDialog(achievements.cast<Map<String, dynamic>>());
      }
      if (_cards.isEmpty) {
        final more = await _loadMoreCards();
        if (more == 0 && mounted) _showCompletionStats();
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('复习'),
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.onSurface,
            tabs: [
              Tab(text: _isLoading ? '待复习' : '待复习 (${_cards.length})'),
              const Tab(text: '全部卡片'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildReviewTab(),
            const CardListScreen(embedded: true),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewTab() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_cards.isEmpty) {
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
                    Icon(Icons.check_circle_outline, size: 64, color: Colors.green.shade300),
                    const SizedBox(height: 16),
                    Text('今日复习完成！', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text('共复习 $_reviewedCount 张卡片',
                        style: TextStyle(color: Colors.grey.shade600)),
                    const SizedBox(height: 24),
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
    final stateColors = [Colors.blue, Colors.orange, Colors.green, Colors.purple];

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: _cards.length,
      itemBuilder: (_, i) {
        final card = _cards[i];
        final state = card.state.clamp(0, 3);
        final isActive = _activeCardIndex == i;

        return Dismissible(
          key: ValueKey('review_${card.id}'),
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
              side: BorderSide(color: Colors.grey.shade200),
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
                      child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                    title: Text(card.front, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                    subtitle: isActive ? null : Text('${card.back}\n复习 ${card.reps} 次', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withAlpha(200))),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(
                      label: Text(stateLabels[state], style: const TextStyle(fontSize: 11)),
                      backgroundColor: stateColors[state].withAlpha(20),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    if (!isActive) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 20, color: Colors.grey.shade400),
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
                    // 预生成 AI 问题（概念类卡片）
                    if (card.cardType != 'vocabulary') {
                      _preloadAiQuestions(card);
                    }
                  }
                },
              ),

              // 展开内联复习
              if (isActive) ...[
                const Divider(height: 1, color: Colors.white38),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.white),
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
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _isVerifying ? const Color(0xFFF5F5FF) :
                     _isFlipped ? const Color(0xFFEEF2FF) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                // 卡片内容（考试模式降低不透明度）
                Padding(
                  padding: const EdgeInsets.all(8),
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
                      child: Text(
                        key: ValueKey('${_isVerifying}_$_isFlipped'),
                        _isVerifying || !_isFlipped ? card.front : card.back,
                        style: TextStyle(
                          fontSize: _isVerifying || !_isFlipped ? 18 : 16,
                          fontWeight: FontWeight.w600,
                          color: _isVerifying
                              ? const Color(0x051A1A2E) // 2% 可见度 + 模糊
                              : const Color(0xFF1A1A2E),
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    ),
                  ),
                if (!_isVerifying && _isFlipped && card.sourceSentence != null) ...[
                  const SizedBox(height: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text('来源: ${card.sourceSentence}',
                        key: ValueKey(card.sourceSentence),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontStyle: FontStyle.italic)),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  _isVerifying ? '闭卷考试中' :
                  _isFlipped ? '点击收回' : '点击翻转查看释义',
                  style: TextStyle(fontSize: 12, color: _isVerifying ? Colors.indigo.shade400 : Colors.grey.shade500)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

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
                  language: 'zh-CN',
                ),
              ),
            );
          },
        ),

        // 记忆验证（正面背面均显示）
        if (!_isVerified && !_isVerifying) ...[
          const SizedBox(height: 8),
          if (card.cardType == 'vocabulary')
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => setState(() { _isFlipped = false; _isVerifying = true; }),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('默写验证'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() { _isFlipped = false; _isVerifying = true; });
                  // 使用预加载的问题（已在后台生成），即时启动
                  _startInlineAiQuiz(card);
                },
                icon: _preloadingQuiz
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.quiz, size: 18),
                label: Text(_preloadedQuestions.isNotEmpty ? '记忆验证 (已就绪)' :
                           _preloadingQuiz ? '正在准备考题...' : '记忆验证'),
              ),
            ),
        ],

        // 默写输入（vocabulary 专用，验证中显示）
        if (_isVerifying && card.cardType == 'vocabulary' && !_isVerified) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _answerController,
            decoration: const InputDecoration(
              hintText: '输入答案...',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) {
              final minLen = (card.back.length * 0.3).ceil().clamp(3, card.back.length);
              final sub = card.back.toLowerCase().substring(0, minLen);
              final correct = _answerController.text.trim().toLowerCase().contains(sub);
              _verificationResult = correct ? 'pass' : 'fail';
              _isVerified = true;
              _isVerifying = false;
              setState(() {});
              Future.delayed(const Duration(milliseconds: 5000), () {
                if (mounted) _submitInlineReview(_cards.indexOf(card));
              });
            },
          ),
          const SizedBox(height: 8),
        ],

        // AI 问答（闭卷中）
        if (_isVerifying && !_isJudging && _isAiQuiz && _aiQuestions.isNotEmpty && _aiResults.isEmpty && _aiQuestionIndex < _aiQuestions.length) ...[
          const SizedBox(height: 8),
          Text('问题 ${_aiQuestionIndex + 1}/${_aiQuestions.length}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(_aiQuestions[_aiQuestionIndex].question,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
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
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _submitInlineAiAnswer,
                icon: const Icon(Icons.arrow_forward, size: 18),
              ),
            ],
          ),
        ],

        // 判断中...
        if (_isJudging) ...[
          const SizedBox(height: 12),
          const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('正在判断答案...', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ],

        // AI 结果（自动提交前显示 1.5s）
        if (_aiResults.isNotEmpty && !_isJudging) ...[
          const SizedBox(height: 8),
          ..._aiResults.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(r.correct ? Icons.check_circle : Icons.cancel,
                    color: r.correct ? Colors.green : Colors.red, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(r.feedback, style: const TextStyle(fontSize: 12))),
              ],
            ),
          )),
        ],

        // 验证结果（5 秒提示）
        if (_isVerified)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _verificationResult == 'pass'
                    ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _verificationResult == 'pass'
                      ? Colors.green.shade300 : Colors.red.shade300,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _verificationResult == 'pass'
                        ? Icons.check_circle : Icons.cancel,
                    color: _verificationResult == 'pass'
                        ? Colors.green : Colors.red,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _verificationResult == 'pass' ? '验证通过 ✅' : '未通过 ❌',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _verificationResult == 'pass'
                          ? Colors.green.shade700 : Colors.red.shade700,
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
