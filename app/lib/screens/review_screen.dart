import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../services/tts_service.dart';

/// 学习计划: 展示待复习队列 + 复习模式
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final _answerController = TextEditingController();
  ChatClient? _client;
  List<DueCard> _cards = [];

  // 复习状态
  int _activeCardIndex = -1; // -1 = 队列视图
  bool _isFlipped = false;
  bool _isLoading = true;
  String _verificationResult = '';
  bool _isVerified = false;
  bool _isAiQuiz = false;
  List<VerifyQuestion> _aiQuestions = [];
  int _aiQuestionIndex = 0;
  List<String> _aiAnswers = [];
  List<JudgeResult> _aiResults = [];
  int _reviewedCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCards());
  }

  @override
  void dispose() {
    _answerController.dispose();
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
    _initClient();
    if (_client == null) return;
    try {
      final resp = await _client!.getDueCards();
      setState(() {
        _cards = (resp['cards'] as List<dynamic>?)
            ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
            .toList() ?? [];
        _isLoading = false;
        _activeCardIndex = _cards.isEmpty ? -1 : -1; // 先展示队列
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _enterReview(int index) {
    setState(() {
      _activeCardIndex = index;
      _isFlipped = false;
      _isVerified = false;
      _verificationResult = '';
      _isAiQuiz = false;
      _aiQuestions = [];
      _aiQuestionIndex = 0;
      _aiAnswers = [];
      _aiResults = [];
      _answerController.clear();
    });
  }

  void _exitReview() {
    setState(() {
      _activeCardIndex = -1;
      _isFlipped = false;
      _isVerified = false;
      _verificationResult = '';
    });
    _loadCards(); // 刷新队列
  }

  Future<void> _submitAndNext(String vtype) async {
    if (_client == null || _activeCardIndex < 0) return;
    final card = _cards[_activeCardIndex];
    final passed = _verificationResult == 'pass';
    try {
      await _client!.submitReview(
        cardId: card.id,
        rating: passed ? 3 : 1,
        verificationType: vtype,
        verificationResult: _verificationResult,
      );
      setState(() => _reviewedCount++);

      // 下一张
      if (_activeCardIndex + 1 < _cards.length) {
        _enterReview(_activeCardIndex + 1);
      } else {
        setState(() {
          _cards.removeAt(_activeCardIndex);
          _activeCardIndex = -1;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交失败: $e')),
      );
    }
  }

  // AI 问答
  Future<void> _startAiQuiz() async {
    if (_client == null || _activeCardIndex < 0) return;
    final card = _cards[_activeCardIndex];
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI 问答启动失败: $e')),
      );
    }
  }

  void _submitAiAnswer() {
    setState(() {
      _aiAnswers[_aiQuestionIndex] = _answerController.text.trim();
      _answerController.clear();
      if (_aiQuestionIndex + 1 < _aiQuestions.length) {
        _aiQuestionIndex++;
      } else {
        _judgeAiAnswers();
      }
    });
  }

  Future<void> _judgeAiAnswers() async {
    if (_client == null || _activeCardIndex < 0) return;
    final card = _cards[_activeCardIndex];
    final qlist = List.generate(_aiQuestions.length, (i) => {
      'question': _aiQuestions[i].question,
      'expected_answer': _aiQuestions[i].expectedAnswer,
      'user_answer': _aiAnswers[i],
    });
    try {
      final resp = await _client!.judgeAnswers(cardId: card.id, questions: qlist);
      final results = (resp['results'] as List<dynamic>?)
          ?.map((e) => JudgeResult.fromJson(e as Map<String, dynamic>))
          .toList() ?? [];
      final correct = resp['total_correct'] as int? ?? 0;
      setState(() {
        _aiResults = results;
        if (correct >= 2) {
          _verificationResult = 'pass';
        } else {
          _verificationResult = 'fail';
        }
        _isVerified = true;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI 判断失败: $e')),
      );
    }
  }

  void _skipCard() {
    if (_activeCardIndex + 1 < _cards.length) {
      _enterReview(_activeCardIndex + 1);
    } else {
      _exitReview();
    }
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('学习计划')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // ── 复习模式 ──
    if (_activeCardIndex >= 0 && _activeCardIndex < _cards.length) {
      return _buildReviewMode();
    }

    // ── 队列视图（没有待复习卡片） ──
    if (_cards.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('学习计划')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, size: 80, color: Colors.green.shade400),
              const SizedBox(height: 24),
              Text(
                _reviewedCount > 0 ? '今日复习完成！' : '暂无待复习卡片',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              if (_reviewedCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('今日已复习 $_reviewedCount 张卡片',
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
              if (_reviewedCount == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('去对话学习新知识，卡片会自动出现在这里',
                      style: TextStyle(color: Colors.grey.shade600)),
                ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }

    // ── 队列视图（有待复习卡片） ──
    return Scaffold(
      appBar: AppBar(
        title: const Text('学习计划'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: const Icon(Icons.schedule, size: 18),
              label: Text('${_cards.length} 张待复习'),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      body: _buildQueueView(),
    );
  }

  Widget _buildQueueView() {
    // 从卡片列表提取领域信息用于过滤
    final domains = <String>{};
    for (final c in _cards) {
      if (c.domain != null) domains.add(c.domain!);
    }

    return _CardsQueueView(
      cards: _cards,
      domains: domains.toList()..sort(),
      onEnterReview: _enterReview,
    );
  }

  Widget _buildReviewMode() {
    final card = _cards[_activeCardIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text('复习 (${_activeCardIndex + 1}/${_cards.length})'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _exitReview,
        ),
        actions: [
          // 跳过当前卡片
          if (!_isVerified)
            TextButton(
              onPressed: _skipCard,
              child: const Text('跳过'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // 进度条
            if (_isFlipped) ...[
              LinearProgressIndicator(
                value: (_activeCardIndex + 1) / _cards.length,
              ),
              const SizedBox(height: 8),
            ],

              // 卡片 (带 TTS 朗读)
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      onTap: () => setState(() => _isFlipped = !_isFlipped),
                      child: Card(
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: _isFlipped
                                ? Padding(
                                    key: const ValueKey('back'),
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(card.back,
                                          style: Theme.of(context).textTheme.titleLarge,
                                          textAlign: TextAlign.center,
                                        ),
                                        if (card.sourceSentence != null) ...[
                                          const SizedBox(height: 16),
                                          Text('来源: ${card.sourceSentence}',
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: Colors.grey,
                                              fontStyle: FontStyle.italic,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                        if (card.domain != null)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 12),
                                            child: Chip(
                                              label: Text(card.domain!, style: const TextStyle(fontSize: 12)),
                                              visualDensity: VisualDensity.compact,
                                            ),
                                          ),
                                      ],
                                    ),
                                  )
                                : Padding(
                                    key: const ValueKey('front'),
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Text(card.front,
                                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 24),
                                        const Text('点击翻转查看释义',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    // TTS 朗读按钮
                    Positioned(
                      right: 8, bottom: 8,
                      child: Consumer(
                        builder: (_, ref, __) {
                          final tts = ref.watch(ttsServiceProvider);
                          final enabled = ref.watch(ttsEnabledProvider);
                          if (!enabled) return const SizedBox.shrink();
                          return IconButton(
                            icon: const Icon(Icons.volume_up, size: 22),
                            onPressed: () => tts.speak(
                              _isFlipped ? card.back : card.front,
                              language: card.front.contains(RegExp(r'[\u4e00-\u9fff]')) ? 'zh-CN' : 'en-US',
                            ),
                            tooltip: '朗读',
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

            // 验证区
            if (_isFlipped && !_isVerified) ...[
              const SizedBox(height: 16),
              // 验证方式选择
              if (card.cardType == 'vocabulary') ...[
                TextField(
                  controller: _answerController,
                  decoration: const InputDecoration(hintText: '输入答案...'),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (value) {
                    final minLen = (card.back.length * 0.3).ceil().clamp(3, card.back.length);
                    final sub = card.back.toLowerCase().substring(0, minLen);
                    final correct = value.trim().toLowerCase().contains(sub);
                    setState(() {
                      _verificationResult = correct ? 'pass' : 'fail';
                      _isVerified = true;
                    });
                  },
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: _startAiQuiz,
                  icon: const Icon(Icons.quiz),
                  label: const Text('开始验证 (AI 问答)'),
                ),
              ],
            ],

            // AI 问答
            if (_isAiQuiz && _aiQuestions.isNotEmpty && _aiResults.isEmpty && !_isVerified) ...[
              const SizedBox(height: 16),
              Text('问题 ${_aiQuestionIndex + 1}/${_aiQuestions.length}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_aiQuestions[_aiQuestionIndex].question,
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _answerController,
                      decoration: const InputDecoration(hintText: '你的回答...'),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitAiAnswer(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _submitAiAnswer,
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ],
              ),
            ],

            // AI 结果
            if (_aiResults.isNotEmpty) ...[
              const SizedBox(height: 16),
              ..._aiResults.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(r.correct ? Icons.check_circle : Icons.cancel,
                        color: r.correct ? Colors.green : Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.feedback, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              )),
            ],

            // 验证结果 + 提交
            if (_isFlipped && _isVerified) ...[
              const SizedBox(height: 16),
              Text(
                _verificationResult == 'pass' ? '✅ 正确！' : '❌ 未掌握',
                style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold,
                  color: _verificationResult == 'pass' ? Colors.green : Colors.red,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _submitAndNext(
                    card.cardType == 'vocabulary' ? 'spelling' : 'ai_dialogue',
                  ),
                  child: Text(
                    _activeCardIndex + 1 < _cards.length
                        ? '提交并继续 (${_cards.length - _activeCardIndex - 1} 张剩余)'
                        : '提交并完成',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 可搜索/过滤的复习队列 ──
class _CardsQueueView extends StatefulWidget {
  final List<DueCard> cards;
  final List<String> domains;
  final Function(int) onEnterReview;

  const _CardsQueueView({
    required this.cards, required this.domains, required this.onEnterReview,
  });

  @override
  State<_CardsQueueView> createState() => _CardsQueueViewState();
}

class _CardsQueueViewState extends State<_CardsQueueView> {
  final _searchController = TextEditingController();
  int? _stateFilter;
  String? _domainFilter;

  List<DueCard> get _filtered {
    final query = _searchController.text.trim().toLowerCase();
    return widget.cards.where((c) {
      if (query.isNotEmpty) {
        if (!c.front.toLowerCase().contains(query) &&
            !c.back.toLowerCase().contains(query)) return false;
      }
      if (_stateFilter != null && c.state != _stateFilter) return false;
      if (_domainFilter != null && c.domain != _domainFilter) return false;
      return true;
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static const _labels = ['新卡片', '学习中', '复习中', '重学中'];
  static const _colors = [Colors.blue, Colors.orange, Colors.green, Colors.red];

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;

    return Column(
      children: [
        // 搜索栏
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索待复习卡片...',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () { _searchController.clear(); setState(() {}); },
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),

        // 状态过滤标签
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _Badge(label: '全部', count: widget.cards.length, isActive: _stateFilter == null, onTap: () => setState(() => _stateFilter = null)),
              const SizedBox(width: 6),
              _Badge(label: '新', color: Colors.blue, count: widget.cards.where((c) => c.state == 0).length, isActive: _stateFilter == 0, onTap: () => setState(() => _stateFilter = _stateFilter == 0 ? null : 0)),
              const SizedBox(width: 6),
              _Badge(label: '学习中', color: Colors.orange, count: widget.cards.where((c) => c.state == 1).length, isActive: _stateFilter == 1, onTap: () => setState(() => _stateFilter = _stateFilter == 1 ? null : 1)),
              const SizedBox(width: 6),
              _Badge(label: '复习中', color: Colors.green, count: widget.cards.where((c) => c.state == 2).length, isActive: _stateFilter == 2, onTap: () => setState(() => _stateFilter = _stateFilter == 2 ? null : 2)),
              const SizedBox(width: 6),
              _Badge(label: '重学', color: Colors.red, count: widget.cards.where((c) => c.state == 3).length, isActive: _stateFilter == 3, onTap: () => setState(() => _stateFilter = _stateFilter == 3 ? null : 3)),
            ]),
          ),
        ),

        // 领域过滤标签
        if (widget.domains.isNotEmpty)
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _DomainChip2(label: '全部领域', isActive: _domainFilter == null, onTap: () => setState(() => _domainFilter = null)),
                ...widget.domains.map((d) => Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _DomainChip2(label: d, isActive: _domainFilter == d, onTap: () => setState(() => _domainFilter = _domainFilter == d ? null : d)),
                )),
              ],
            ),
          ),

        // 计数
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text('${filtered.length} 张待复习',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ],
          ),
        ),

        // 列表
        Expanded(
          child: filtered.isEmpty
              ? Center(child: Text('没有匹配的待复习卡片', style: TextStyle(color: Colors.grey.shade500)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final card = filtered[i];
                    final stateLabel = _labels[card.state.clamp(0, 3)];
                    final stateColor = _colors[card.state.clamp(0, 3)];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: stateColor.withAlpha(30),
                          child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        title: Text(card.front, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(card.back, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Chip(
                          label: Text(stateLabel, style: const TextStyle(fontSize: 11)),
                          backgroundColor: stateColor.withAlpha(20),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onTap: () => widget.onEnterReview(widget.cards.indexOf(card)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final int count;
  final Color? color;
  final bool isActive;
  final VoidCallback onTap;
  const _Badge({required this.label, required this.count, this.color, required this.isActive, required this.onTap});

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
          fontSize: 12, fontWeight: isActive ? FontWeight.w600 : FontWeight.normal, color: txtColor,
        )),
      ),
    );
  }
}

class _DomainChip2 extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _DomainChip2({required this.label, required this.isActive, required this.onTap});

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
