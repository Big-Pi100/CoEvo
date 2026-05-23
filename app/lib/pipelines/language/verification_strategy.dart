import 'package:flutter/material.dart';
import '../verification_strategy.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';

/// 语言学习验证策略（多模式）
///
/// 三种验证模式，按 reps 自动升级：
/// - forward:  正向语义验证 — LLM 判断用户中文翻译是否等价于 back
/// - reverse:  反向拼写验证 — 精确匹配用户输入是否等于 front（已有）
/// - dictation: 听写验证 — TTS 朗读后精确匹配（待 TTS 就绪）
class LanguageVerificationStrategy extends VerificationStrategy {
  VerificationMode _mode;

  LanguageVerificationStrategy({VerificationMode mode = VerificationMode.reverse})
    : _mode = mode;

  @override
  String get name => 'language';

  @override
  VerificationMode get mode => _mode;

  set mode(VerificationMode newMode) => _mode = newMode;

  @override
  bool get isSpellingBased => _mode != VerificationMode.forward;

  @override
  String get buttonLabel {
    switch (_mode) {
      case VerificationMode.forward:
        return '正向理解验证';
      case VerificationMode.reverse:
        return '默写验证';
      case VerificationMode.dictation:
        return '听写验证';
    }
  }

  @override
  Widget buildButton(BuildContext context, VoidCallback onPressed,
      {bool isReady = false, bool isLoading = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(_buttonIcon, size: 18),
        label: Text(isLoading ? '验证中...' : buttonLabel),
      ),
    );
  }

  IconData get _buttonIcon {
    switch (_mode) {
      case VerificationMode.forward:
        return Icons.translate;
      case VerificationMode.reverse:
        return Icons.edit;
      case VerificationMode.dictation:
        return Icons.hearing;
    }
  }

  @override
  Widget buildInput({
    required BuildContext context,
    required DueCard card,
    required TextEditingController controller,
    required bool isVerifying,
    required bool isVerified,
    required String verificationResult,
    required void Function(String) onSubmit,
  }) {
    if (!isVerifying || isVerified) return const SizedBox.shrink();

    final hint = _mode == VerificationMode.forward
        ? '输入中文释义...'
        : '输入英文单词...';

    return Column(
      children: [
        const SizedBox(height: 8),
        // 模式标签
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _modeColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _modeLabel,
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.send,
          onSubmitted: onSubmit,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  String get _modeLabel {
    switch (_mode) {
      case VerificationMode.forward:
        return '正向理解';
      case VerificationMode.reverse:
        return '反向默写';
      case VerificationMode.dictation:
        return '听写';
    }
  }

  Color get _modeColor {
    switch (_mode) {
      case VerificationMode.forward:
        return Colors.green;
      case VerificationMode.reverse:
        return Colors.orange;
      case VerificationMode.dictation:
        return Colors.purple;
    }
  }

  @override
  Future<void> startVerification({
    required DueCard card,
    required ChatClient client,
  }) async {
    // forward/reverse 不需要异步准备
  }

  @override
  Future<String> submitVerification({
    required DueCard card,
    required ChatClient client,
    required String userInput,
  }) async {
    final answer = userInput.trim();
    if (answer.isEmpty) return 'fail';

    switch (_mode) {
      case VerificationMode.forward:
        return _judgeForward(card, client, answer);
      case VerificationMode.reverse:
        return _judgeReverse(card, answer);
      case VerificationMode.dictation:
        return _judgeReverse(card, answer); // 听写也用精确匹配
    }
  }

  /// 正向验证：LLM 语义判断
  Future<String> _judgeForward(
    DueCard card,
    ChatClient client,
    String userInput,
  ) async {
    try {
      final result = await client.verifyTranslation(
        front: card.front,
        back: card.back,
        userInput: userInput,
      );
      return result;
    } catch (_) {
      // 降级：若 API 不可用，用简单包含检测（不如 LLM 准但比 fail 好）
      final input = userInput.toLowerCase();
      final back = card.back.toLowerCase();
      // 检查用户输入是否包含 back 的关键词或 back 是否包含用户输入
      if (back.contains(input) || input.contains(back)) return 'pass';
      return 'fail';
    }
  }

  /// 反向验证：精确匹配（对 reverse/dictation）
  String _judgeReverse(DueCard card, String userInput) {
    final answer = userInput.trim().toLowerCase();
    final expected = card.front.trim().toLowerCase();
    return answer == expected ? 'pass' : 'fail';
  }
}

/// 根据卡片复习次数自动选择验证模式
VerificationMode resolveMode(DueCard card) {
  if (card.cardType != 'vocabulary') return VerificationMode.forward;
  final reps = card.reps;
  if (reps == 0) return VerificationMode.forward;       // 首次：正向理解
  if (reps <= 3) return VerificationMode.reverse;        // 2-3次：反向拼写
  return VerificationMode.dictation;                      // 4次+：听写综合
}
