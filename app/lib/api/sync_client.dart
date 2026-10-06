import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';

/// 云端同步 API 客户端 —— `/api/sync/push` 与 `/api/sync/pull`。
///
/// # 与 `AuthClient` 的分工
///
/// 本文件只做**传输**（拼 URL / header / 解 JSON / 归类错误）；
/// 「拉回来怎么合并、推什么上去」全在 `services/sync_service.dart`（纯逻辑，可离线验证）。
/// 🔑 这条边界是**刻意的**：把 IO 推到边界，逻辑留在中间
///    （见 `sync_service.dart` 头部与 skill `verifiable-core-logic`）。
///
/// # 🔴 403 是**语义信号**，不是错误
///
/// 后端对「已登录但**没有有效订阅**」回 **403 Forbidden**
/// （服务端 `AppError::Forbidden` —— 刻意不用 401，因为端侧对 401 的标准反应是
/// 「清凭据 → 跳登录」，那会让用户**被莫名登出**）。
/// ⇒ 这里把它翻译成 [SyncNotSubscribed]，让上层能说人话：
///   「跨设备同步是订阅权益」而不是「同步失败」。
///
/// # 🔴 每个请求都必须 `.timeout()`
///
/// 理由同 `AuthClient`（那里记了完整推导）：超时不是「防连不上」
/// （端口无监听会立即 `ECONNREFUSED`），而是「**防连上了但没人应**」
/// （防火墙 DROP / 网络黑洞 / 服务假死 ⇒ 没有超时会无限等）。
/// 用 [ApiConfig.requestTimeout]（10s），**不在这里写数字**（超时属配置）。
class SyncClient {
  SyncClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 推送本地变更。
  ///
  /// ⚠️ **幂等**：同一批重复推送，服务端结果一致（各表主键 + 条件 UPSERT）
  /// ⇒ 网络超时后**重试是安全的**（本方法不自己重试，由下一次同步自然重试）。
  Future<Map<String, dynamic>> push(
    Map<String, dynamic> body, {
    required String token,
  }) async {
    final resp = await _client
        .post(
          Uri.parse('${ApiConfig.baseUrl}/api/sync/push'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(ApiConfig.requestTimeout);
    return _decode(resp, 'push');
  }

  /// 拉取服务端变更。
  ///
  /// [since] 为 `null` = 首次同步（服务端拉全部）。
  /// [deviceId] 让服务端**排除本设备**推上去的数据（那些本地已经有了）。
  Future<Map<String, dynamic>> pull({
    required String token,
    String? since,
    String? deviceId,
  }) async {
    final q = <String, String>{};
    if (since != null && since.isNotEmpty) q['since'] = since;
    if (deviceId != null && deviceId.isNotEmpty) q['device_id'] = deviceId;
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/sync/pull')
        .replace(queryParameters: q.isEmpty ? null : q);
    final resp = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(ApiConfig.requestTimeout);
    return _decode(resp, 'pull');
  }

  /// 统一解码 + 错误归因。
  ///
  /// 🔑 错误信息**分流成三种**（而不是一律 `Exception('同步失败')`）：
  /// · [SyncNotSubscribed] —— 403，上层应说「订阅后可用」（**不是**「失败」）
  /// · [SyncUnauthorized]  —— 401，token 失效（上层应考虑登出）
  /// · 其他                —— 真失败（网络 / 5xx / 协议错）
  Map<String, dynamic> _decode(http.Response resp, String op) {
    if (resp.statusCode == 403) {
      throw SyncNotSubscribed(_serverMessage(resp) ?? '跨设备同步是订阅权益');
    }
    if (resp.statusCode == 401) {
      throw SyncUnauthorized(_serverMessage(resp) ?? '登录状态已失效');
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (e) {
      // 非 JSON 响应（网关错误页 / 代理拦截）—— 归到下面统一报
      debugPrint('sync.$op: 响应不是 JSON（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode != 200) {
      throw Exception(
          'sync.$op HTTP ${resp.statusCode}: ${data?['error'] ?? resp.body}');
    }
    if (data == null) {
      throw Exception('sync.$op: 响应不是 JSON 对象');
    }
    if (data.containsKey('error')) {
      throw Exception('sync.$op: ${data['error']}');
    }
    return data;
  }

  String? _serverMessage(http.Response resp) {
    try {
      final d = jsonDecode(resp.body);
      if (d is Map && d['error'] is String) return d['error'] as String;
    } catch (_) {
      // 忽略：拿不到服务端文案时用调用方给的默认值
    }
    return null;
  }
}

/// 「已登录，但**没有有效订阅**」—— 这是**预期内的状态**，不是故障。
///
/// 上层应据此显示「订阅后可用」而不是「同步失败，请重试」。
class SyncNotSubscribed implements Exception {
  SyncNotSubscribed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `token` 失效（401）—— 与 [SyncNotSubscribed] 分开，因为**处理方式不同**
/// （这个要清凭据 / 引导重新登录）。
class SyncUnauthorized implements Exception {
  SyncUnauthorized(this.message);
  final String message;
  @override
  String toString() => message;
}
