import 'package:flutter/material.dart';
import '../verification_strategy.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';

/// 语法练习验证策略
///
/// 语法卡片在复习流程内完成：
/// front: "请将以下句子改为否定句：She is a teacher."
/// back: "She is not a teacher."（标准答案，仅作 LLM 参考）
/// 用户输入 → LLM 判断语法正确性
class GrammarVerificationStrategy extends VerificationStrategy {
  @override
  String get name => 'grammar';

  @override
  bool get isSpellingBased => false;

  @override
  String get buttonLabel => '语法验证';

  @override
  Widget buildButton(BuildContext context, VoidCallback onPressed,
      {bool isReady = false, bool isLoading = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.abc, size: 18),
        label: Text(isLoading ? '判断中...' : buttonLabel),
      ),
    );
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.purple.shade100,
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            '语法练习',
            style: TextStyle(fontSize: 11, color: Colors.black87),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入答案...',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.send,
          onSubmitted: onSubmit,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Future<void> startVerification({
    required DueCard card,
    required ChatClient client,
  }) async {
    // 语法验证不需要异步准备
  }

  @override
  Future<String> submitVerification({
    required DueCard card,
    required ChatClient client,
    required String userInput,
  }) async {
    final answer = userInput.trim();
    if (answer.isEmpty) return 'fail';

    try {
      final result = await client.verifyGrammar(
        front: card.front,
        back: card.back,
        userInput: answer,
      );
      return result;
    } catch (_) {
      // LLM 不可用时的简单降级
      // 检查用户输入是否包含 back 的关键内容（基础检测）
      final input = answer.toLowerCase();
      final back = card.back.toLowerCase();
      // 如果用户答案包含标准答案的主要关键词，算通过
      if (back.split(' ').any((w) => w.length > 3 && input.contains(w))) {
        return 'pass';
      }
      return 'fail';
    }
  }
}
