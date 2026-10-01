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

final generateCardClientProvider = Provider<GenerateCardClient>((ref) {
  final client = GenerateCardClient();
  ref.onDispose(client.dispose);
  return client;
});
