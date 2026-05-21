import 'package:flutter/material.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import 'language/verification_strategy.dart';
import 'general/verification_strategy.dart';

/// 验证策略接口
///
/// 每条管线实现自己的验证策略：
/// - general: AI 快问快答（通用概念）
/// - language: 拼写验证 + 听写（Phase 2 完善）
///
/// 调用方 (review_screen) 通过 resolveStrategy(card) 获取对应实例。
abstract class VerificationStrategy {
  /// 策略名称标识
  String get name;

  /// 是否为拼写型验证（语言类卡片）
  /// review_screen 据此决定是否展示输入框
  bool get isSpellingBased => false;

  /// 验证按钮的标签
  String get buttonLabel;

  /// 构建验证按钮
  Widget buildButton(BuildContext context, VoidCallback onPressed, {bool isReady = false, bool isLoading = false});

  /// 构建验证输入区域
  Widget buildInput({
    required BuildContext context,
    required DueCard card,
    required TextEditingController controller,
    required bool isVerifying,
    required bool isVerified,
    required String verificationResult,
    required void Function(String) onSubmit,
  });

  /// 开始验证（生成题目等异步准备）
  Future<void> startVerification({
    required DueCard card,
    required ChatClient client,
  });

  /// 提交验证（返回 pass/fail）
  Future<String> submitVerification({
    required DueCard card,
    required ChatClient client,
    required String userInput,
  });
}

/// 策略路由：按 card.domain 匹配
VerificationStrategy resolveStrategy(DueCard card) {
  switch (card.domain) {
    case 'vocabulary':
    case 'grammar':
    case 'language':
      return LanguageVerificationStrategy();
    default:
      return GeneralVerificationStrategy();
  }
}
