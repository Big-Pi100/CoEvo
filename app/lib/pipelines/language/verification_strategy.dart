import 'package:flutter/material.dart';
import '../verification_strategy.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';

/// 语言学习验证策略
///
/// Phase 1：保持现有拼写验证逻辑不变（从 review_screen 提取出来）
/// Phase 2：增加听写、反向验证等功能
class LanguageVerificationStrategy extends VerificationStrategy {
  @override
  String get name => 'language';

  @override
  bool get isSpellingBased => true;

  @override
  String get buttonLabel => '默写验证';

  @override
  Widget buildButton(BuildContext context, VoidCallback onPressed,
      {bool isReady = false, bool isLoading = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.edit, size: 18),
        label: const Text('默写验证'),
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
      children: [
        const SizedBox(height: 8),
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
    // 拼写验证不需要异步准备
  }

  @override
  Future<String> submitVerification({
    required DueCard card,
    required ChatClient client,
    required String userInput,
  }) async {
    final answer = userInput.trim().toLowerCase();
    if (answer.isEmpty) return 'fail';

    // 拼写验证：用户看到释义，拼出英语单词
    // card.front = "apple"（待拼的英语单词）
    // card.back = "苹果"（中文释义，仅作提示）
    // 答案必须逐字符完全匹配 card.front
    final expected = card.front.trim().toLowerCase();
    final correct = answer == expected;
    return correct ? 'pass' : 'fail';
  }
}
