import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../pipelines/verification_strategy.dart';
import '../providers/plan_provider.dart';
import '../services/tts_service.dart';
import '../theme/co_spacing.dart';
import 'markdown_span_nodes.dart';

/// 复习卡片组件 — 支持翻转、验证、AI 问答、评判展示
///
/// 使用方式：
/// ```dart
/// ReviewCardWidget(
///   card: dueCard,
///   client: chatClient,
///   reviewIndex: 0,
///   totalCount: 10,
///   onReviewComplete: (cardId, result) {},
/// )
/// ```
class ReviewCardWidget extends ConsumerStatefulWidget {
  final DueCard card;
  final ChatClient? client;
  final int reviewIndex;
  final int totalCount;
  final bool autoFlipAfterVerify;
  final ValueChanged<String>? onVerificationStart;
  final ValueChanged<String>? onVerificationComplete;
  final Future<void> Function(String cardId, String result, List<JudgeResult> judgeResults)? onReviewComplete;

  const ReviewCardWidget({
    super.key,
    required this.card,
    this.client,
    this.reviewIndex = 0,
    this.totalCount = 1,
    this.autoFlipAfterVerify = false,
    this.onVerificationStart,
    this.onVerificationComplete,
    this.onReviewComplete,
  });

  @override
  ConsumerState<ReviewCardWidget> createState() => _ReviewCardWidgetState();
}

class _ReviewCardWidgetState extends ConsumerState<ReviewCardWidget>
    with TickerProviderStateMixin {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  final _answerController = TextEditingController();

  bool _isFlipped = false;
  bool _isVerifying = false;
  bool _isVerified = false;

  // 语音输入（与 chat_input 一致）
  bool _voiceMode = false;
  bool _isRecording = false;
  bool _isTranscribing = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  static const int _maxRecordSeconds = 60;

  String _verificationResult = '';

  // AI 问答
  bool _isAiQuiz = false;
  List<VerifyQuestion> _aiQuestions = [];
  int _aiQuestionIndex = 0;
  List<String> _aiAnswers = [];
  List<JudgeResult> _aiResults = [];
  bool _isJudging = false;
  List<VerifyQuestion> _preloadedQuestions = [];
  bool _preloadingQuiz = false;

  // 订阅豁免
  bool _subscriptionRequired = false;
  bool _subscriptionExpired = false;
  bool _subscriptionChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadAiQuestions();
    });
  }

  @override
  void didUpdateWidget(ReviewCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id) {
      _resetState();
      _preloadAiQuestions();
    }
  }

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  void _resetState() {
    setState(() {
      _isFlipped = false;
      _isVerifying = false;
      _isVerified = false;
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
      _voiceMode = false;
      _isRecording = false;
      _isTranscribing = false;
    });
  }

  // ── 语音输入（复用 chat_input 的 JS 引擎） ──

  void _enterVoiceMode() => setState(() => _voiceMode = true);

  void _exitVoiceMode() {
    _recordTimer?.cancel();
    try { js.context.callMethod('__coeStop', [_nullFunc]); } catch (_) {}
    setState(() {
      _voiceMode = false;
      _isRecording = false;
      _isTranscribing = false;
      _recordSeconds = 0;
    });
  }

  void _nullFunc() {}

  Future<void> _startRecording() async {
    try {
      js.context.callMethod('__coeStart');
      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) { _recordTimer?.cancel(); return; }
        final next = _recordSeconds + 1;
        if (next >= _maxRecordSeconds) {
          _recordTimer?.cancel();
          _stopRecording();
        } else {
          setState(() => _recordSeconds = next);
        }
      });
    } catch (e) {
      debugPrint('ReviewCard voice start error: $e');
      _exitVoiceMode();
    }
  }

  void _stopRecording() {
    _recordTimer?.cancel();
    setState(() => _isRecording = false);
    setState(() => _isTranscribing = true);
    final callback = js.JsFunction.withThis((self, b64) {
      if (mounted) _sendVoiceBase64(b64 as String);
    });
    try { js.context.callMethod('__coeStop', [callback]); } catch (e) {
      debugPrint('ReviewCard voice stop error: $e');
      _exitVoiceMode();
    }
  }

  Future<void> _sendVoiceBase64(String b64) async {
    if (b64.isEmpty) { _exitVoiceMode(); return; }
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/stt/transcribe'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'audio': b64, 'format': 'wav', 'engine': '16k_zh'}),
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200 && mounted) {
        final d = jsonDecode(resp.body) as Map<String, dynamic>;
        final text = d['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _answerController.text = text;
          _answerController.selection = TextSelection.fromPosition(
            TextPosition(offset: text.length),
          );
        }
      }
    } catch (_) {}
    setState(() => _isTranscribing = false);
    _exitVoiceMode();
  }

  Future<void> _preloadAiQuestions() async {
    final client = widget.client;
    if (client == null) return;
    if (_subscriptionRequired || _subscriptionExpired) return;
    setState(() => _preloadingQuiz = true);
    try {
      final resp = await client.verifyQuestions(
        widget.card.id,
        widget.card.front,
        widget.card.back,
      );
      final questions = (resp['questions'] as List<dynamic>?)
              ?.map((e) => VerifyQuestion.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      if (mounted) {
        setState(() {
          _preloadedQuestions = questions;
          _preloadingQuiz = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _preloadingQuiz = false);
    }
  }

  Future<void> _startAiQuiz() async {
    // 优先用预加载的问题
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
    final client = widget.client;
    if (client == null) return;
    if (_subscriptionRequired || _subscriptionExpired) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('需要有效订阅才能使用 AI 问答功能')),
        );
      }
      return;
    }
    try {
      final resp = await client.verifyQuestions(
        widget.card.id,
        widget.card.front,
        widget.card.back,
      );
      final questions = (resp['questions'] as List<dynamic>?)
              ?.map((e) => VerifyQuestion.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      setState(() {
        _isAiQuiz = true;
        _aiQuestions = questions;
        _aiQuestionIndex = 0;
        _aiAnswers = List.filled(questions.length, '');
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isVerifying = false;
          _isFlipped = true;
        });
      }
    }
  }

  void _submitAiAnswer() {
    if (_aiQuestionIndex >= _aiQuestions.length) return;
    _aiAnswers[_aiQuestionIndex] = _answerController.text.trim();
    _answerController.clear();
    setState(() => _aiQuestionIndex++);
    if (_aiQuestionIndex >= _aiQuestions.length) {
      _judgeAnswers();
    }
  }

  Future<void> _judgeAnswers() async {
    final client = widget.client;
    if (client == null || widget.card.id.isEmpty) return;
    if (_subscriptionRequired || _subscriptionExpired) return;

    final snapshotQuestions = List<Map<String, String>>.generate(
      _aiQuestions.length,
      (i) => {
        'question': _aiQuestions[i].question,
        'expected_answer': _aiQuestions[i].expectedAnswer,
        'user_answer': i < _aiAnswers.length ? _aiAnswers[i] : '',
      },
    );
    setState(() => _isJudging = true);

    try {
      final resp = await client.judgeAnswers(
        cardId: widget.card.id,
        questions: snapshotQuestions,
      );
      final results = (resp['results'] as List<dynamic>?)
              ?.map((e) => JudgeResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [];
      final correct = resp['total_correct'] as int? ?? 0;
      final result = correct >= 3 ? 'pass' : 'fail';

      if (!mounted) return;
      setState(() {
        _aiResults = results;
        _verificationResult = result;
        _isVerified = true;
        _isVerifying = false;
        _isJudging = false;
      });

      widget.onVerificationComplete?.call(result);

      // 自动提交
      _submitReview(result, results);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isJudging = false;
          _isVerifying = false;
        });
      }
    }
  }

  Future<void> _submitReview(String result, List<JudgeResult> judgeResults) async {
    final client = widget.client;
    if (client == null) return;

    final rating = result == 'pass' ? 3 : 1;
    String? detailsJson;
    if (judgeResults.isNotEmpty) {
      detailsJson = jsonEncode(
        List.generate(judgeResults.length, (i) {
          return {
            'question': i < _aiQuestions.length ? _aiQuestions[i].question : '',
            'expected': i < _aiQuestions.length ? _aiQuestions[i].expectedAnswer : '',
            'actual': i < _aiAnswers.length ? _aiAnswers[i] : '',
            'correct': judgeResults[i].correct,
            'feedback': judgeResults[i].feedback,
          };
        }),
      );
    }

    try {
      await client.submitReview(
        cardId: widget.card.id,
        rating: rating,
        verificationType: 'ai_dialogue',
        verificationResult: result,
        detailsJson: detailsJson,
      );
      if (mounted) {
        ref.read(cardRefreshProvider.notifier).state++;
        widget.onReviewComplete?.call(widget.card.id, result, _aiResults);
      }
    } catch (e) {
      debugPrint('ReviewCardWidget submitReview error: $e');
    }
  }

  /// 拼写验证提交
  Future<void> _submitSpellingVerification() async {
    final client = widget.client;
    if (client == null) return;

    final strategy = resolveStrategy(widget.card);
    final result = await strategy.submitVerification(
      card: widget.card,
      client: client,
      userInput: _answerController.text,
    );
    if (!mounted) return;
    setState(() {
      _verificationResult = result;
      _isVerified = true;
      _isVerifying = false;
    });
    widget.onVerificationComplete?.call(result);

    // 延迟后自动提交
    Future.delayed(const Duration(milliseconds: 5000), () {
      if (mounted) {
        final vtype = strategy.isSpellingBased ? 'spelling' : 'ai_dialogue';
        final rating = result == 'pass' ? 3 : 1;
        client.submitReview(
          cardId: widget.card.id,
          rating: rating,
          verificationType: vtype,
          verificationResult: result,
        ).then((_) {
          if (mounted) {
            ref.read(cardRefreshProvider.notifier).state++;
            widget.onReviewComplete?.call(widget.card.id, result, []);
          }
        });
      }
    });
  }

  /// 卡片背面预览（截取前几个字）
  String _cardBackPreview(String back) {
    final t = back.trim();
    if (t.startsWith('{') && t.endsWith('}')) {
      try {
        final parsed = jsonDecode(t) as Map<String, dynamic>;
        if (parsed.containsKey('character') && parsed.containsKey('pinyin')) {
          final defs = parsed['definitions'] as List<dynamic>? ?? [];
          if (defs.isNotEmpty) {
            final first = defs[0] as Map<String, dynamic>;
            return first['meaning'] as String? ?? parsed['character'] as String;
          }
          return parsed['character'] as String? ?? back;
        }
        if (parsed.containsKey('word') && parsed.containsKey('definitions')) {
          final ch = parsed['chinese'] as String? ?? '';
          if (ch.isNotEmpty) return ch;
          final defs = parsed['definitions'] as List<dynamic>? ?? [];
          if (defs.isNotEmpty) {
            final first = defs[0] as Map<String, dynamic>;
            final meaning = first['meaning'] as String? ?? '';
            final dChinese = first['chinese'] as String? ?? '';
            return dChinese.isNotEmpty ? dChinese : meaning;
          }
          return parsed['word'] as String? ?? back;
        }
        return (parsed['full_text'] as String?)?.replaceAll('\n', ' ') ?? back;
      } catch (_) {}
    }
    return back;
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final strategy = resolveStrategy(card);
    final isSpelling = strategy.isSpellingBased;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 牌号提示 ──
        if (widget.totalCount > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: CoSpacing.sm),
            child: Text(
              '卡片 ${widget.reviewIndex + 1}/${widget.totalCount}',
              style: _tt.labelMedium?.copyWith(color: _cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),

        // ── 翻牌区域 ──
        GestureDetector(
          onTap: _isVerifying ? null : () => setState(() => _isFlipped = !_isFlipped),
          child: Container(
            padding: const EdgeInsets.all(CoSpacing.xl),
            decoration: BoxDecoration(
              color: _isVerifying
                  ? const Color(0xFFF5F5FF)
                  : (_isFlipped ? _cs.surface : _cs.primary),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _cs.surfaceContainerLow),
            ),
            child: Column(
              children: [
                // 卡片内容
                Padding(
                  padding: const EdgeInsets.all(CoSpacing.sm),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
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
                                      color: _isVerifying
                                          ? const Color(0x051A1A2E)
                                          : const Color(0xFF1A1A2E),
                                      height: 1.4,
                                    ),
                                    textAlign: TextAlign.center,
                                  )
                                : Container(
                                    key: const ValueKey('back'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: CoSpacing.lg,
                                    ),
                                    child: RichContentBuilder(textColor: _cs.onSurface)
                                        .build(card.back),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!_isVerifying && _isFlipped && card.sourceSentence != null) ...[
                  const SizedBox(height: CoSpacing.sm),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      '来源: ${card.sourceSentence}',
                      key: ValueKey(card.sourceSentence),
                      style: _tt.bodySmall?.copyWith(
                        color: _cs.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: CoSpacing.sm),
                Text(
                  _isVerifying
                      ? '闭卷考试中'
                      : (_isFlipped ? '点击收回' : '点击翻转查看释义'),
                  style: _tt.bodySmall?.copyWith(
                    color: _isVerifying ? _cs.secondaryFixed : _cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: CoSpacing.md),

        // ── TTS ──
        Consumer(
          builder: (_, ref, __) {
            final tts = ref.watch(ttsServiceProvider);
            final enabled = ref.watch(ttsEnabledProvider);
            if (!enabled) return const SizedBox.shrink();
            final isPlaying = tts.isPlaying;
            final isLoading = tts.state == TtsState.loading;
            return Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        isPlaying ? Icons.stop_circle_outlined : Icons.volume_up,
                        size: 18,
                      ),
                label: Text(
                  isPlaying
                      ? '停止'
                      : (_isFlipped ? '朗读释义' : '朗读概念'),
                ),
                onPressed: isLoading
                    ? null
                    : () {
                        String ttsText;
                        if (_isFlipped) {
                          final back = card.back;
                          final trimmed = back.trim();
                          if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
                            try {
                              final parsed = jsonDecode(trimmed) as Map<String, dynamic>;
                              if (parsed.containsKey('word')) {
                                final w = parsed['word'] as String? ?? '';
                                final c = parsed['chinese'] as String? ?? '';
                                ttsText = '$w. $c';
                              } else if (parsed.containsKey('character')) {
                                final ch = parsed['character'] as String? ?? '';
                                final py = parsed['pinyin'] as String? ?? '';
                                ttsText = '$ch $py';
                              } else {
                                ttsText = back.replaceAll('**', '');
                              }
                            } catch (_) {
                              ttsText = back.replaceAll('**', '');
                            }
                          } else {
                            ttsText = back.replaceAll('**', '');
                          }
                        } else {
                          ttsText = card.front;
                        }
                        tts.togglePlay(ttsText);
                      },
              ),
            );
          },
        ),

        // ── 验证按钮 ──
        if (!_isVerified && !_isVerifying) ...[
          const SizedBox(height: CoSpacing.sm),
          strategy.buildButton(
            context,
            () {
              widget.onVerificationStart?.call(card.id);
              setState(() {
                _isFlipped = false;
                _isVerifying = true;
              });
              if (!isSpelling) {
                _startAiQuiz();
              }
            },
            isReady: _preloadedQuestions.isNotEmpty,
            isLoading: _preloadingQuiz,
          ),
        ],

        // ── 拼写验证输入 ──
        if (_isVerifying && !_isVerified && isSpelling)
          strategy.buildInput(
            context: context,
            card: card,
            controller: _answerController,
            isVerifying: _isVerifying,
            isVerified: _isVerified,
            verificationResult: _verificationResult,
            onSubmit: (_) => _submitSpellingVerification(),
          ),

        // ── AI 问答 ──
        if (_isVerifying && !_isJudging && _isAiQuiz &&
            _aiQuestions.isNotEmpty && _aiResults.isEmpty &&
            _aiQuestionIndex < _aiQuestions.length) ...[
          const SizedBox(height: CoSpacing.sm),
          Text(
            '问题 ${_aiQuestionIndex + 1}/${_aiQuestions.length}',
            style: _tt.titleSmall,
          ),
          const SizedBox(height: CoSpacing.xs),
          Text(
            _aiQuestions[_aiQuestionIndex].question,
            style: _tt.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: CoSpacing.sm),
          // ── AI 问答输入（语音模式切换） ──
          if (_voiceMode)
            // 语音模式：按住说话（与 chat_input 一致）
            Row(
              children: [
                IconButton(
                  icon: _isTranscribing
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.keyboard, size: 22),
                  onPressed: _isRecording ? null : _exitVoiceMode,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onLongPressStart: _isTranscribing ? null : (_) => _startRecording(),
                    onLongPressEnd: _isTranscribing ? null : (_) => _stopRecording(),
                    onLongPressCancel: _stopRecording,
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.red.withAlpha(20) : _cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _isRecording ? Colors.red.withAlpha(100) : _cs.outline.withAlpha(60),
                        ),
                      ),
                      child: Center(
                        child: _isTranscribing
                            ? const Row(mainAxisSize: MainAxisSize.min, children: [
                                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.grey)),
                                SizedBox(width: 8), Text('识别中...', style: TextStyle(fontSize: 15)),
                              ])
                            : _isRecording
                                ? Row(mainAxisSize: MainAxisSize.min, children: [
                                    SizedBox(
                                      width: 20, height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3, color: Colors.red,
                                        value: _recordSeconds / _maxRecordSeconds,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text('${_maxRecordSeconds - _recordSeconds}s 松手结束',
                                        style: const TextStyle(color: Colors.red, fontSize: 15)),
                                  ])
                                : const Text('按住 说话', style: TextStyle(fontSize: 15)),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            // 文字输入模式（与 chat_input 一致：mic 在左）
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.mic, size: 22),
                  onPressed: _enterVoiceMode,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                const SizedBox(width: CoSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _answerController,
                    decoration: const InputDecoration(
                      hintText: '你的回答...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submitAiAnswer(),
                  ),
                ),
                const SizedBox(width: CoSpacing.xs),
                IconButton.filled(
                  onPressed: _submitAiAnswer,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                ),
              ],
            ),
        ],

        // ── 评判中 ──
        if (_isJudging) ...[
          const SizedBox(height: CoSpacing.md),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: CoSpacing.lg,
                  height: CoSpacing.lg,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: CoSpacing.sm),
                Text('正在判断答案...', style: TextStyle(color: _cs.outline)),
              ],
            ),
          ),
        ],

        // ── AI 评判结果 ──
        if (!_isJudging && _aiResults.isNotEmpty) ...[
          const SizedBox(height: CoSpacing.sm),
          ..._aiResults.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: CoSpacing.xs),
              child: Row(
                children: [
                  Icon(
                    r.correct ? Icons.check_circle : Icons.cancel,
                    color: r.correct ? _cs.primary : _cs.error,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Text(r.feedback, style: _tt.bodySmall!)),
                ],
              ),
            ),
          ),
        ],

        // ── 验证结果 ──
        if (!_isJudging && _isVerified)
          Padding(
            padding: const EdgeInsets.only(top: CoSpacing.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: _verificationResult == 'pass'
                    ? _cs.primaryContainer
                    : _cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _verificationResult == 'pass'
                      ? _cs.primaryFixed
                      : _cs.errorContainer,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _verificationResult == 'pass' ? Icons.check_circle : Icons.cancel,
                    color: _verificationResult == 'pass' ? _cs.primary : _cs.error,
                    size: 22,
                  ),
                  const SizedBox(width: CoSpacing.sm),
                  Text(
                    _verificationResult == 'pass' ? '验证通过' : '未通过',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _verificationResult == 'pass' ? _cs.primary : _cs.error,
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
