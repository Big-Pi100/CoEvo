// 翻译 API 客户端 —— `POST /api/translate`
//
// # 🔴 本客户端**必须带 token**（与 `generate_card_client` 相反）
//
// 理由是**成本归属**，不是产品原则变了：
// · 划词查词不带 token —— 它是**内容渲染的一部分**，不能被登录态阻塞
//   （「登录服务一抖 → 划词就查不了」是不可接受的）。
// · 翻译**每次真的调模型**，必须记在某个账号头上（免费 10 次/月）
//   ⇒ 它是**能力记账**，属于「能力限制开关」那一类（同 `/api/sync/*`）。
// ⇒ 未登录时**明确提示去登录**，而不是"静默失败"。
//
// # 分层：本文件只做 **HTTP**，解析在别处
//
// 类型与解析都在 [`services/translate_parse.dart`] —— 那里**零 Flutter / 零 http 依赖**，
// 于是 401/403/畸形 JSON 这些分支能用**一行字符串**全部断言（本文件做不到）。
// 本文件通过 `export` 把它们带出去 ⇒ 调用方 import 一处即可。
//
// # 为什么结果是 sealed 而不是 `Map?` + 异常
// 四种结局对用户**完全不同**：
//
// | 结局 | 用户看到 | 该做什么 |
// |---|---|---|
// | 成功 | 译文浮层 | — |
// | **未登录**（401）| 「登录后可翻译」| 去登录 |
// | **额度用尽**（403）| 服务端给的具体文案 | 订或不订 |
// | 失败（4xx/5xx/网络）| 具体错误 | 重试 / 放弃 |
//
// 🔴 尤其**不能把 401 混进「失败」** —— 401 的标准处理是「清凭据 → 跳登录」，
//    提示成「翻译失败」会让用户反复重试一个**永远不会成功**的动作。

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../services/translate_parse.dart';
import 'api_config.dart';

// 把类型与解析带出去（调用方只 import 本文件即可）
export '../services/translate_parse.dart';

/// 翻译客户端。
class TranslateClient {
  TranslateClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? ApiConfig.baseUrl,
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// 翻译是「等一次模型调用」，与在线制卡同一量级 ⇒ 用 `longTimeout`（60s）。
  ///
  /// ⚠️ 不要把超时设短：那会让"正在翻译"被客户端**主动截断**，
  ///    用户看到的是「网络错误」而不是「在翻译」—— **把一个可等待的状态伪装成了故障**。
  static const Duration _timeout = ApiConfig.longTimeout;

  /// 翻译一段文本。[token] 为空 ⇒ **不发请求**，直接回 [`TranslateNeedLogin`]。
  ///
  /// 🆕 [ticket]：端侧翻译**预扣**时拿到的一次性凭据 ——
  /// 🔑 带上它 ⇒ 服务端**跳过扣额**（那次已在预扣时扣掉）。
  /// 只在「端侧翻失败后的回落」这一条路径上带；其余情况不传。
  Future<TranslateResult> translate(
    String text, {
    required String token,
    String? ticket,
  }) async {
    if (token.isEmpty) return const TranslateNeedLogin();

    final uri = Uri.parse('$baseUrl/api/translate');
    try {
      final resp = await _http
          .post(
            uri,
            headers: ApiConfig.headers(token: token),
            body: jsonEncode({
              'text': text,
              if (ticket != null) 'ticket': ticket,
            }),
          )
          .timeout(_timeout);
      return parseTranslateBody(resp.body, resp.statusCode);
    } catch (e) {
      // 网络层失败（连不上 / 超时 / DNS）→ statusCode == null
      debugPrint('[translate] 请求失败 err=$e');
      return const TranslateFailed(message: '连不上服务，请检查网络后重试');
    }
  }

  /// 🆕 端侧翻译的**额度预扣**（`POST /api/translate/quota`）。
  ///
  /// # 为什么端侧翻译还要问服务端
  /// 「翻译」是**订阅权益**（免费 10 次/月 · 订阅无限）—— 端侧虽然零成本，
  /// 但不能因此让免费用户变成无限 ⇒ **闸门仍由服务端握着**。
  ///
  /// ⚠️ 本接口**不调模型**（所以它很快、也不花任何模型钱）。
  Future<PrepayResult> prepayQuota(String text, {required String token}) async {
    if (token.isEmpty) return const PrepayNeedLogin();

    final uri = Uri.parse('$baseUrl/api/translate/quota');
    try {
      final resp = await _http
          .post(
            uri,
            headers: ApiConfig.headers(token: token),
            // `runes.length` = **字符数**（与 Rust 侧 `clean.chars().count()` 同口径）；
            // 它是统计值（`chars_sum`），**不参与上限判断**。
            body: jsonEncode({'chars': text.runes.length}),
          )
          .timeout(_timeout);
      return parsePrepayBody(resp.body, resp.statusCode);
    } catch (e) {
      debugPrint('[translate] 预扣请求失败 err=$e');
      return const PrepayFailed(message: '连不上服务，请检查网络后重试');
    }
  }

  void dispose() => _http.close();
}
