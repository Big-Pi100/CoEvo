import 'package:flutter/material.dart';
import '../verification_strategy.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';

/// 通用概念验证策略
///
/// 保持原有 AI 快问快答逻辑不变。
class GeneralVerificationStrategy extends VerificationStrategy {
  @override
  String get name => 'general';

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
    return const SizedBox.shrink(); // AI 快问快答用自定义对话流程，不需要通用输入框
  }

  @override
  Future<void> startVerification({
    required DueCard card,
    required ChatClient client,
  }) async {
    // AI 快问快答由 review_screen 的 _startInlineAiQuiz 处理，此处无需额外准备
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
