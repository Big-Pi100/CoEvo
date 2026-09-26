import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../providers/dialog_queue_provider.dart';
import '../providers/plan_provider.dart' hide cardRefreshProvider;
import '../theme/co_spacing.dart';
import 'review_card_widget.dart';
import 'twemoji.dart';

/// 复习失败的卡片记录
class _FailedCardInfo {
  final String front;
  final String back;
  final List<Map<String, dynamic>> details; // question, expected, actual, correct, feedback
  const _FailedCardInfo({required this.front, required this.back, this.details = const []});
}

/// 复习弹窗 — 接收 DueCard 队列，逐张展示，全部完成后显示统计摘要。
///
/// 流程：
///   1. 接收 List<DueCard> → 逐张调用 ReviewCardWidget
///   2. 每张答完自动跳下一张
///   3. 全部完成 → 统计摘要
///   4. "推迟30分钟" 底部按钮 → 调 POST /api/review/defer → dequeue
class ReviewDialog extends ConsumerStatefulWidget {
  final List<DueCard> cards;
  final String? conversationId;

  const ReviewDialog({
    super.key,
    required this.cards,
    this.conversationId,
  });

  @override
  ConsumerState<ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<ReviewDialog> {
  ChatClient? _client;

  int _passedCount = 0;
  int _totalCount = 0;
  int _failedCount = 0;
  bool _isComplete = false;
  bool _isDeferring = false;

  // 已提交/通过的卡片 ID 集合
  final Set<String> _completedCardIds = {};
  // 失败的卡片详情（用于报告）
  final List<_FailedCardInfo> _failedCards = [];

  @override
  void initState() {
    super.initState();
    _totalCount = widget.cards.length;
    final auth = ref.read(authProvider);
    _client = auth.userId != null
        ? ChatClient(userId: auth.userId!, token: auth.token)
        : null;
  }

  DueCard? get _currentCard {
    for (final card in widget.cards) {
      if (!_completedCardIds.contains(card.id)) {
        return card;
      }
    }
    return null;
  }

  Future<void> _onReviewComplete(String cardId, String result, List<JudgeResult> judgeResults) async {
    if (!mounted) return;
    setState(() {
      _completedCardIds.add(cardId);
      if (result == 'pass') {
        _passedCount++;
      } else {
        _failedCount++;
        // 找对应卡片信息
        final card = widget.cards.where((c) => c.id == cardId).firstOrNull;
        if (card != null) {
          _failedCards.add(_FailedCardInfo(
            front: card.front,
            back: card.back,
            details: judgeResults.map((jr) => {
              'correct': jr.correct,
              'feedback': jr.feedback,
            }).toList(),
          ));
        }
      }
    });

    // 检查所有卡片是否已完成
    if (_completedCardIds.length >= widget.cards.length) {
      setState(() => _isComplete = true);
    }
  }

  Future<void> _deferAndClose() async {
    final client = _client;
    if (client == null) return;

    setState(() => _isDeferring = true);

    try {
      // 收集所有卡片 ID
      final cardIds = widget.cards.map((c) => c.id).toList();
      final resp = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/api/review/defer'),
            headers: {
              'Content-Type': 'application/json',
              if (client.token != null && client.token!.isNotEmpty)
                'Authorization': 'Bearer ${client.token}',
            },
            body: jsonEncode({
              'user_id': client.userId,
              'conversation_id': widget.conversationId ?? '',
              'defer_seconds': 1800,
              'card_ids': cardIds,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final result = jsonDecode(resp.body) as Map<String, dynamic>;
        if (result['status'] == 'ok') {
          if (mounted) {
            // 推迟成功 → 显示评审报告
            setState(() {
              _isComplete = true;
              _isDeferring = false;
            });
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('ReviewDialog defer error: $e');
    }

    if (mounted) {
      setState(() => _isDeferring = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('推迟失败，请稍后重试'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    Widget _statTile(String label, String value, Color color, IconData icon) {
      return Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      );
    }

    String _formatBackForReview(String back) {
      if (!back.startsWith('{')) return back;
      try {
        final d = jsonDecode(back) as Map<String, dynamic>;
        final pinyin = d['pinyin'] as String? ?? d['phonetic'] as String?;
        final definitions = d['definitions'];
        final collocations = d['common_words'] as String? ?? d['collocations'] as String?;
        final parts = <String>[];
        if (pinyin != null) parts.add('拼音: $pinyin');
        if (definitions is List) {
          for (final def in definitions) {
            if (def is Map) {
              final pos = def['pos'] as String? ?? '';
              final meaning = def['meaning'] as String? ?? '';
              final example = def['example'] as String? ?? '';
              String line = '';
              if (pos.isNotEmpty) line = '$pos ';
              line += meaning;
              if (example.isNotEmpty) line += '（例: $example）';
              parts.add(line);
            }
          }
        }
        if (collocations != null && collocations.isNotEmpty) parts.add('常用搭配: $collocations');
        return parts.join('\n');
      } catch (_) {
        return back;
      }
    }

    // 已完成 → 显示统计摘要 + 错误报告
    if (_isComplete) {
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 60),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(CoSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _failedCount == 0 ? Icons.check_circle : Icons.assignment,
                    color: _failedCount == 0 ? cs.primary : Colors.orange,
                    size: 40,
                  ),
                ],
              ),
              const SizedBox(height: CoSpacing.sm),
              Text('本次复习', style: tt.titleLarge),
              const SizedBox(height: 2),
              Text(
                _completedCardIds.length < _totalCount
                    ? '已完成 ${_completedCardIds.length}/$_totalCount 张'
                    : '全部完成',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: CoSpacing.sm),

              // 统计数字
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _statTile('总卡片', '$_totalCount', cs.primary, Icons.credit_card),
                  _statTile('通过', '$_passedCount', Colors.green, Icons.check_circle),
                  _statTile('未通过', '$_failedCount', _failedCount > 0 ? Colors.red : Colors.grey, Icons.cancel),
                ],
              ),

              // 失败卡片列表（含 LLM 评审详情）
              if (_failedCards.isNotEmpty) ...[
                const SizedBox(height: CoSpacing.md),
                const Divider(),
                const SizedBox(height: CoSpacing.sm),
                Text('评审详情 — 未通过的卡片', style: tt.titleSmall?.copyWith(color: Colors.red.shade700)),
                const SizedBox(height: CoSpacing.sm),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.3),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _failedCards.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final f = _failedCards[i];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 卡片名
                          Row(
                            children: [
                              Icon(Icons.cancel, color: Colors.red.shade300, size: 16),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(f.front, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: Colors.red.shade700)),
                              ),
                            ],
                          ),
                          if (f.back.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 20, top: 2),
                              child: Text(_formatBackForReview(f.back), style: tt.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            ),
                          // LLM 评审详情
                          if (f.details.isNotEmpty)
                            ...f.details.map((d) {
                              final isCorrect = d['correct'] as bool? ?? false;
                              final feedback = d['feedback'] as String? ?? '';
                              return Padding(
                                padding: const EdgeInsets.only(left: 20, top: 4),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      isCorrect ? Icons.check_circle : Icons.error,
                                      size: 14,
                                      color: isCorrect ? Colors.green : Colors.orange,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        feedback,
                                        style: tt.bodySmall?.copyWith(
                                          color: isCorrect ? Colors.green.shade700 : Colors.orange.shade800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      );
                    },
                  ),
                ),
              ],

              const SizedBox(height: CoSpacing.lg),
              // 底部按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: _isDeferring ? null : _deferAndClose,
                    icon: _isDeferring
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.schedule, size: 18),
                    label: Text(_isDeferring
                        ? '推迟中...'
                        : _completedCardIds.length < _totalCount
                            ? '推迟剩余 30 分钟'
                            : '推迟 30 分钟'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // 当前卡片
    final card = _currentCard;
    if (card == null) {
      // 卡片为空或全部完成
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(CoSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('没有待复习的卡片'),
              const SizedBox(height: CoSpacing.lg),
              FilledButton(
                onPressed: () {
                  Navigator.of(context, rootNavigator: true).pop();
                },
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 80),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(CoSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题行
            Row(
              children: [
                Icon(Icons.replay, color: cs.primary),
                const SizedBox(width: CoSpacing.sm),
                Text(
                  '复习',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${_passedCount}/${_totalCount}',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: CoSpacing.md),

            // 卡片内容
            Flexible(
              child: SingleChildScrollView(
                child: ReviewCardWidget(
                  card: card,
                  client: _client,
                  reviewIndex: _completedCardIds.length,
                  totalCount: widget.cards.length,
                  onReviewComplete: _onReviewComplete,
                ),
              ),
            ),

            // 推迟按钮
            const SizedBox(height: CoSpacing.md),
            if (!_isComplete)
              TextButton.icon(
                onPressed: _isDeferring ? null : _deferAndClose,
                icon: _isDeferring
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.schedule, size: 18),
                label: Text(_isDeferring ? '推迟中...' : '推迟 30 分钟'),
                style: TextButton.styleFrom(
                  foregroundColor: cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
