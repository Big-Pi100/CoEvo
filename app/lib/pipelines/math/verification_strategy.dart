import 'package:flutter/material.dart';
import '../verification_strategy.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';

/// 数学/物理概念验证策略
///
/// 使用 AI 快问快答进行验证（数学不适用拼写验证）。
class MathVerificationStrategy extends VerificationStrategy {
  @override
  String get name => 'math';

  @override
  bool get isSpellingBased => false;

  @override
  String get buttonLabel => '记忆验证';

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
            : const Icon(Icons.quiz, size: 18),
        label: Text(isLoading
            ? '正在准备考题...'
            : isReady
                ? '记忆验证 (已就绪)'
                : buttonLabel),
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
    return const SizedBox.shrink(); // AI 快问快答，不需要输入框
  }

  @override
  Future<void> startVerification({
    required DueCard card,
    required ChatClient client,
  }) async {
    // AI 快问快答由 review_screen 处理
  }

  @override
  Future<String> submitVerification({
    required DueCard card,
    required ChatClient client,
    required String userInput,
  }) async {
    return 'pass';
  }
}
