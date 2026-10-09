// 翻译响应的**解析** —— 纯 Dart（**零 Flutter / 零 http 依赖**）
//
// # 🔑 为什么单独一个文件
//
// 「服务返回什么形状」是这个功能**最容易错**、又**最难在真机上复现**的部分：
// 要覆盖 `401` / `403` / 缺字段 / 非 JSON / 空数组，得各造一次真实响应。
//
// ⇒ 把解析做成**纯函数**、放进**零依赖**的文件，
//    这些分支就能用**一行字符串**全部覆盖（见 `verify_translate_client.dart`）。
//    📌 判据（本项目反复出现）：**能脱离外部依赖验证的逻辑，就别让它依赖**。
//
// HTTP 那一层留在 `api/translate_client.dart`（它 import Flutter 与 http），
// 并通过 `export` 把本文件的类型带出去 ⇒ 调用方 import 一处即可。

import 'dart:convert';

/// 一句对照。
class TransSegment {
  const TransSegment({required this.src, required this.dst});

  final String src;
  final String dst;

  @override
  bool operator ==(Object other) =>
      other is TransSegment && other.src == src && other.dst == dst;

  @override
  int get hashCode => Object.hash(src, dst);
}

/// 翻译请求的结局。
sealed class TranslateResult {
  const TranslateResult();
}

/// ✅ 拿到译文。
final class TranslateReady extends TranslateResult {
  const TranslateReady({
    required this.segments,
    required this.used,
    required this.limit,
    required this.subscribed,
  });

  /// 🔑 **永远非空**（服务端保证至少一段）—— 单句时长度为 1。
  ///    于是渲染层只需**一条**路径（判据：能少一个分支就少一个）。
  final List<TransSegment> segments;

  /// 本月已用次数。
  ///
  /// ⚠️ **`-1` 是哨兵值 = 未知**（缓存命中时没调接口 ⇒ 服务端没回 quota）。
  ///    见 `providers/translate_provider.dart::kTranslateUsedUnknown`。
  final int used;

  /// 免费层上限；订阅用户为 `null`（不限）。
  final int? limit;

  final bool subscribed;
}

/// 🔑 **未登录**（HTTP 401）。
///
/// ⚠️ 它与 [`TranslateFailed`] **必须分开**：401 的正确反应是「去登录」，
///    而"失败"的正确反应是「重试」。混在一起 ⇒ 用户会反复重试一个**永远不会成功**的动作。
final class TranslateNeedLogin extends TranslateResult {
  const TranslateNeedLogin();
}

/// 🚫 免费额度用尽（HTTP 403）。`message` 是**服务端给的**（含"下月 1 日重置"）。
final class TranslateQuotaExceeded extends TranslateResult {
  const TranslateQuotaExceeded({required this.message});

  final String message;
}

/// ❌ 失败。
final class TranslateFailed extends TranslateResult {
  const TranslateFailed({required this.message, this.statusCode});

  final String message;

  /// 网络层失败（连不上 / 超时）时为 `null`。
  final int? statusCode;
}

/// **解析响应体 → 结果类型**（纯函数）。
///
/// [statusCode] 决定分支；[body] 只在 200 与「带错误文案」时被读。
TranslateResult parseTranslateBody(String body, int statusCode) {
  if (statusCode == 401) return const TranslateNeedLogin();

  // 非 200：尽量取服务端的可读文案
  if (statusCode != 200) {
    final msg = errorMessageOf(body);
    if (statusCode == 403) {
      return TranslateQuotaExceeded(message: msg);
    }
    return TranslateFailed(message: msg, statusCode: statusCode);
  }

  Map<String, Object?> m;
  try {
    final d = jsonDecode(body);
    if (d is! Map) {
      return const TranslateFailed(message: '服务返回格式异常', statusCode: 200);
    }
    m = d.cast<String, Object?>();
  } catch (_) {
    return const TranslateFailed(message: '服务返回格式异常', statusCode: 200);
  }

  final raw = m['segments'];
  if (raw is! List || raw.isEmpty) {
    return TranslateFailed(
      message: (m['error'] as String?) ?? '服务未返回译文',
      statusCode: 200,
    );
  }

  final segments = <TransSegment>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final src = item['src'];
    final dst = item['dst'];
    if (src is! String || dst is! String) continue;
    // 空译文是**坏条目**（不是"这句没翻出来"）⇒ 丢掉
    if (dst.trim().isEmpty) continue;
    segments.add(TransSegment(src: src, dst: dst));
  }
  // 🔴 全都不成形 ⇒ 当失败（**不返回空浮层** —— 那看着像"翻出来是空的"）
  if (segments.isEmpty) {
    return const TranslateFailed(message: '服务返回的译文不完整', statusCode: 200);
  }

  final quota = m['quota'];
  final q = quota is Map ? quota.cast<String, Object?>() : const <String, Object?>{};
  return TranslateReady(
    segments: segments,
    used: (q['used'] as num?)?.toInt() ?? 0,
    // ⚠️ `limit` **允许为 `null`**（订阅不限）—— 别用 `?? 0` 把它压成 0：
    //    那会让「订阅用户」看起来像「额度为 0」
    limit: (q['limit'] as num?)?.toInt(),
    subscribed: q['subscribed'] == true,
  );
}

/// 从错误体里取可读文案（服务端已转成中文）。
///
/// ⚠️ 服务端的错误体**可能不是 JSON**（网关 502 / nginx 错误页）⇒ 必须有兜底。
String errorMessageOf(String body) {
  try {
    final d = jsonDecode(body);
    if (d is Map && d['error'] is String) {
      final msg = (d['error'] as String).trim();
      if (msg.isNotEmpty) return msg;
    }
  } catch (_) {
    // 落到兜底
  }
  return '翻译失败，请稍后重试';
}

// ══════════════════════════════════════════════════════════════════════
// 端侧翻译的**额度预扣**（A1 · 2026-10-09）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么端侧翻译还要先问服务端
//
// 端侧翻译**零成本**，但「翻译」是一项**订阅权益**（免费 10 次/月 · 订阅无限）。
// 若端侧翻译完全绕过服务端，免费用户就变成**事实上无限** ⇒ 权益就不是「不变」了。
// ⇒ 顺序固定为：**先预扣（服务端点头）→ 再端侧翻 → 失败才回落**。
//
// 🔑 与 [`parseTranslateBody`] 一样，这里是**纯函数** —— 401/403/畸形 JSON 这些
//    分支能用一行字符串全部覆盖（见 `verify_translation_service.dart`）。

/// 预扣的结局。
sealed class PrepayResult {
  const PrepayResult();
}

/// ✅ 预扣成功。
final class PrepayOk extends PrepayResult {
  const PrepayOk({
    required this.ticket,
    required this.used,
    required this.limit,
    required this.subscribed,
  });

  /// 🔑 **回落时带回去 ⇒ 服务端不再扣额**（那次已在预扣时扣掉）。
  ///
  /// ⚠️ 订阅用户为 `null` —— 他们不受上限，回落本来就不会扣。
  final String? ticket;

  final int used;
  final int? limit;
  final bool subscribed;
}

/// 🔑 **未登录**（HTTP 401）—— 与 [`TranslateNeedLogin`] 同义，必须与失败分开。
final class PrepayNeedLogin extends PrepayResult {
  const PrepayNeedLogin();
}

/// 🚫 额度用尽（HTTP 403）。`message` 由服务端给（含「下月 1 日重置」）。
final class PrepayQuotaExceeded extends PrepayResult {
  const PrepayQuotaExceeded({required this.message});
  final String message;
}

/// ❌ 失败（网络 / 5xx / 畸形响应）。
final class PrepayFailed extends PrepayResult {
  const PrepayFailed({required this.message});
  final String message;
}

/// **解析预扣响应 → 结果类型**（纯函数）。
PrepayResult parsePrepayBody(String body, int statusCode) {
  if (statusCode == 401) return const PrepayNeedLogin();

  if (statusCode != 200) {
    final msg = errorMessageOf(body);
    if (statusCode == 403) return PrepayQuotaExceeded(message: msg);
    return PrepayFailed(message: msg);
  }

  Map<String, Object?> m;
  try {
    final d = jsonDecode(body);
    if (d is! Map) return const PrepayFailed(message: '服务返回格式异常');
    m = d.cast<String, Object?>();
  } catch (_) {
    return const PrepayFailed(message: '服务返回格式异常');
  }

  final quota = m['quota'];
  final q = quota is Map ? quota.cast<String, Object?>() : const <String, Object?>{};
  final t = m['ticket'];
  return PrepayOk(
    // 空串等同没有 —— 免得把 "ticket": "" 当成有效凭据发下去
    ticket: (t is String && t.isNotEmpty) ? t : null,
    used: (q['used'] as num?)?.toInt() ?? 0,
    // ⚠️ `limit` 允许为 `null`（订阅不限）—— 别用 `?? 0` 压成 0
    limit: (q['limit'] as num?)?.toInt(),
    subscribed: q['subscribed'] == true,
  );
}
