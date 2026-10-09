// 在线制卡客户端的 provider —— `POST /api/generate-card`
//
// # 为什么需要 provider 而不是「用到时 new 一个」
// `GenerateCardClient` 内部持有 `http.Client`（**连接池**）——
// 每次 new 一个会各开一套连接，且**没人 close**。
// → 由 provider 持有**一个**实例，并在销毁时 `close()`（同 `ContentApiClient` 的处理）。
//
// # ⚠️ 它**不需要登录态**（这是设计，不是遗漏）
// 见 `api/generate_card_client.dart` 文件头的产品原则说明。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/generate_card_client.dart';
import '../services/external_word_card.dart';

final generateCardClientProvider = Provider<GenerateCardClient>((ref) {
  final client = GenerateCardClient();
  ref.onDispose(client.dispose);
  return client;
});

/// HTTP 客户端的结局 → [`ExternalCardGenReply`]（**唯一一处**映射）。
///
/// 🔑 为什么要这一层：`services/external_word_card.dart` 必须保持**纯 Dart**
/// （`scripts/query_verify` 要拿真库直接跑它），而 `api/generate_card_client.dart`
/// 依赖 Flutter ⇒ 两者之间需要一个**薄适配**。
///
/// ⚠️ **只做字段搬运，不做判断**（`retryable` 的判据在
/// `external_word_card.dart` 的 `_retryable()` —— 那里能对状态码穷举断言，
/// 放在这里就变成"跟着 UI 走"了）。
ExternalCardGenReply externalCardReplyOf(GenerateCardResult r) => switch (r) {
      GenerateCardReady(
        :final card,
        :final fromCache,
        :final contractVersion,
      ) =>
        ExternalCardGenReady(
          rawCard: card,
          fromCache: fromCache,
          contractVersion: contractVersion,
        ),
      GenerateCardInProgress() => const ExternalCardGenBusy(),
      GenerateCardFailed(:final message, :final statusCode) =>
        ExternalCardGenFailed(message: message, statusCode: statusCode),
    };
