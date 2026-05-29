import 'package:flutter/material.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import 'language/verification_strategy.dart' as lang;
import 'math/verification_strategy.dart';
import 'general/verification_strategy.dart';
import 'language/grammar_strategy.dart';

/// 验证模式枚举
///
/// - forward: 正向语义验证（LLM 判断中文翻译是否等价）
/// - reverse: 反向拼写验证（精确匹配英语单词）
/// - dictation: 听写验证（TTS 朗读后精确匹配）
enum VerificationMode { forward, reverse, dictation }

/// 验证策略接口
///
/// 每条管线实现自己的验证策略：
/// - general: AI 快问快答（通用概念）
/// - language: 多模式验证（正向/反向/听写）
/// - math: AI 快问快答（数学/物理）
abstract class VerificationStrategy {
  String get name;
  bool get isSpellingBased => false;
  String get buttonLabel;

  /// 当前验证模式（语言管线使用 forward/reverse/dictation）
  VerificationMode get mode => VerificationMode.forward;

  Widget buildButton(BuildContext context, VoidCallback onPressed, {bool isReady = false, bool isLoading = false});

  Widget buildInput({
    required BuildContext context,
    required DueCard card,
    required TextEditingController controller,
    required bool isVerifying,
    required bool isVerified,
    required String verificationResult,
    required void Function(String) onSubmit,
  });

  Future<void> startVerification({required DueCard card, required ChatClient client});

  Future<String> submitVerification({required DueCard card, required ChatClient client, required String userInput});
}

/// 策略路由：按 card.domain 匹配 + 按 reps 选择验证模式
VerificationStrategy resolveStrategy(DueCard card) {
  switch (card.domain) {
    case 'vocabulary':
    case 'language':
      final mode = lang.resolveMode(card);
      return lang.LanguageVerificationStrategy(mode: mode);
    case 'grammar':
      return GrammarVerificationStrategy();
    case 'math':
    case 'physics':
      return MathVerificationStrategy();
    case '数学':
    case '物理':
      return MathVerificationStrategy();
    default:
      return GeneralVerificationStrategy();
  }
}
