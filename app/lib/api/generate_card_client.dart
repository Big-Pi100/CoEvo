// 在线制卡 API 客户端 —— `POST /api/generate-card`
//
// # 🔴 本客户端**不带 token**（不是遗漏）
//
// 与 `content_client.dart` 同一条产品原则的理由：
// 「登录态是**能力限制开关**，不是**内容可见性开关**」。
// 划词查词是**内容渲染的一部分** —— 若它需要登录，
// 则「登录服务一抖 → 划词到生词就查不了」（**用易失败的外部依赖卡住核心动作**）。
// 服务端也如此设计（`routes.rs` 的 handler 注释明写「**不需要登录**」）。
//
// # 分层
// 本层只做「HTTP + JSON → 结果类型」。**不含业务判断**
// （「要不要写缓存」「卡片长什么样」都是调用方的事）。
//
// # 结果为什么是 sealed class 而不是 `Map?` + 异常
// 三种结局对用户**完全不同**，必须让类型强制区分（同 `WordDbLoad` 的理由）：
//
// | 结局 | 用户看到 | 能重试吗 |
// |---|---|---|
// | 成功 | 词卡浮层 | — |
// | **正在生成中**（503）| 「正在生成，请稍后重试」| ✅ **能**（白哥裁决：报错 + 稍后重试）|
// | 失败（400/422/502/500/网络）| 具体错误文案 | ⚠️ 看情形 |
//
// 🔑 尤其**不能把 503 混进「失败」** —— 它不是错误，是「同一时刻别人正在生成这个词」
//    （服务端 in-flight 去重的正常结果）。若提示成「生成失败」，用户会以为功能坏了。

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'api_config.dart';

/// 制卡请求的结局。
sealed class GenerateCardResult {
  const GenerateCardResult();
}

/// ✅ 拿到词卡（可能来自服务端缓存 —— `fromCache` 为 `true` 时**没有**调 LLM）。
final class GenerateCardReady extends GenerateCardResult {
  const GenerateCardReady({
    required this.card,
    required this.fromCache,
    required this.hitCount,
    required this.contractVersion,
  });

  /// 🔴 **服务端返回的原始 card JSON** —— 注意它**不是** `word.db.card.content` 的形状！
  ///
  /// 它是 LLM 的输出 schema（`{word, entry_type, morphology, etymology, ipa,
  /// definition, context, collocations, mnemonic, confidence}` 平铺字段），
  /// 而端侧渲染要的是 `{front, ipa, entry_type, sections:[…]}`。
  /// → 转换是 `services/generated_card_adapter.dart` 的职责（**纯函数、可断言**）。
  /// ⚠️ **别在本层转换** —— 那会让转换逻辑无法脱离 HTTP 单独验证。
  final Map<String, Object?> card;

  /// `true` = 服务端已有这个词的卡（本次没花钱）。
  final bool fromCache;

  /// 该词被查过的次数（服务端统计，含本次）。
  final int hitCount;

  /// 契约版本（如 `v6`）—— 🔴 **改契约时端侧要据此判断**
  /// （服务端升级后若端侧适配器还是旧的，字段可能对不上 → 应显式失败而不是静默出空卡）。
  final String contractVersion;
}

/// ⏳ 同词正在生成中（HTTP 503）—— **不是错误**，重试即可。
final class GenerateCardInProgress extends GenerateCardResult {
  const GenerateCardInProgress();
}

/// ❌ 失败。`message` 已由服务端转成**面向用户的中文**（可直接提示）。
///
/// ⚠️ 曾经有个 `isRetryable` getter，**已删除** —— 端侧没有用它做出任何分支
///    （服务端的文案本身已体现差异：「正在生成中，请稍后重试」vs「该词暂不支持生成」）。
///    📌 判据：**零消费者的 getter = 死代码**，即便它「看起来以后有用」。
///    将来若真要在界面上放「重试」按钮，按 [`statusCode`] 判即可（503 可重试、422 合规不可）。
final class GenerateCardFailed extends GenerateCardResult {
  const GenerateCardFailed({required this.message, this.statusCode});

  final String message;

  /// HTTP 状态码；网络层失败（连不上/超时）时为 `null`。
  final int? statusCode;
}

/// 在线制卡客户端。
class GenerateCardClient {
  final String baseUrl;
  final http.Client _http;

  GenerateCardClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? ApiConfig.baseUrl,
        _http = httpClient ?? http.Client();

  /// 服务端对 llm_card 的超时约定：**in-flight 最多等 8s**，之后返回 503。
  /// 但 LLM 首次生成本身可能更久（尤其冷启动）→ 客户端给它 `longTimeout`（60s）。
  ///
  /// 🔑 为什么不用 `requestTimeout`（10s）：那会让「正在生成」被客户端**主动截断**，
  ///    用户看到的是「网络错误」而不是「正在生成」—— **把一个可等待的状态
  ///    伪装成了故障**。（同「503 不能混进失败」的道理。）
  static const Duration _timeout = ApiConfig.longTimeout;

  /// 请求生成（或取缓存）。
  ///
  /// [spelling] 用户查的词（大小写不敏感 —— 服务端会归一化）。
  /// [deviceId] 🆕 本机匿名标识（`services/device_id.dart`）。
  ///
  /// 🔴 **它是可选参数，且调用方应为「取不到就不传」**（不要在这里兜底生成）：
  ///    服务端用它写 `generated_card_hit(spelling, device_id)` 以算
  ///    `distinct_user_count` —— **A3 回流门槛的真信号**
  ///    （`hit_count` 只管累计，去重不了：「一人刷 100 次」与「100 人各 1 次」同形）。
  ///
  ///    传 `null` 的后果是**统计缺口**（服务端 `distinct_user_count` 不增长），
  ///    而不是功能故障 —— 所以**宁可空着也不瞎传**：
  ///    每次现生成一个随机值会让该指标被灌成「请求次数」，比空值**更具误导性**
  ///    （有空值至少知道「未启用」；灌水值是「有值但全错」）。
  Future<GenerateCardResult> generate(String spelling, {String? deviceId}) async {
    final uri = Uri.parse('$baseUrl/api/generate-card');

    final body = jsonEncode({
      'spelling': spelling,
      // 空串等同未提供 —— 显式剔除，别让服务端把一个空字符串当成一个「用户」
      if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
    });

    try {
      // 🔴 用 `headers()` 且**不传 token** —— 见文件头（产品原则，不是遗漏）
      final resp = await _http
          .post(uri, headers: ApiConfig.headers(), body: body)
          .timeout(_timeout);

      if (resp.statusCode == 200) {
        return _parseOk(resp.body, spelling);
      }
      if (resp.statusCode == 503) {
        // 🔑 **不是失败** —— 别人正在生成同一个词，稍后重试就有
        return const GenerateCardInProgress();
      }
      return GenerateCardFailed(
        message: _errorMessage(resp, spelling),
        statusCode: resp.statusCode,
      );
    } catch (e) {
      // 网络层失败（连不上 / 超时 / DNS）→ `statusCode == null`
      debugPrint('[generate_card] 请求失败 spelling=$spelling err=$e');
      return GenerateCardFailed(
        message: '连不上服务，请检查网络后重试',
        statusCode: null,
      );
    }
  }

  GenerateCardResult _parseOk(String raw, String spelling) {
    try {
      final d = jsonDecode(raw);
      if (d is! Map) {
        return const GenerateCardFailed(message: '服务返回格式异常');
      }
      final m = d.cast<String, Object?>();
      final card = m['card'];
      if (card is! Map) {
        return GenerateCardFailed(
          message: (m['error'] as String?) ?? '服务未返回词卡',
          statusCode: 200,
        );
      }
      return GenerateCardReady(
        card: card.cast<String, Object?>(),
        fromCache: m['from_cache'] == true,
        hitCount: (m['hit_count'] as num?)?.toInt() ?? 0,
        contractVersion: (m['contract_version'] as String?) ?? '',
      );
    } catch (e) {
      debugPrint('[generate_card] 解析失败 spelling=$spelling err=$e');
      return const GenerateCardFailed(message: '服务返回格式异常');
    }
  }

  /// 取服务端的错误文案（服务端已转成面向用户的中文）。
  ///
  /// ⚠️ 服务端返回体**可能不是 JSON**（网关 502 / nginx 错误页）→ 解析失败时有兜底文案。
  String _errorMessage(http.Response resp, String spelling) {
    try {
      final d = jsonDecode(resp.body);
      if (d is Map && d['error'] is String) {
        final msg = (d['error'] as String).trim();
        if (msg.isNotEmpty) return msg;
      }
    } catch (_) {
      // 落到兜底
    }
    debugPrint(
        '[generate_card] 非 JSON 错误体 spelling=$spelling code=${resp.statusCode} '
        'body=${resp.body.length > 200 ? '${resp.body.substring(0, 200)}…' : resp.body}');
    return '生成失败（HTTP ${resp.statusCode}），请稍后重试';
  }

  void dispose() => _http.close();
}
