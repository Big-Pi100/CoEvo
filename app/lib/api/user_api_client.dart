// 用户 API 客户端 —— 个人页（`profile_screen`）用到的两个接口
//
// # 🔴 为什么单独一个文件（2026-09-29）
//
// 原 `api/chat_client.dart`（719 行 / 33 个公开方法）是**旧架构**的通用客户端 ——
// 它同时服务「chat 链」与「个人页」，因此 chat 链删除后它**无法整体删除**。
//
// 用 import 反向图实测（`scripts` 之外的临时脚本）：**chat 链之外只有
// `profile_screen` 在用，且只用 2 个方法**：
//   · `getProfile()`        —— 个人页读 display_name / real_name / phone
//   · `updateDisplayName()` —— 改昵称后同步到后端
//
// → 把这两个方法（+ 必要的 HTTP / 认证样板）抽成本文件，
//   其余 31 个方法随 chat 链一并删除（719 行 → 本文件）。
//
// ⚠️ 方法体与 `chat_client.dart` **逐字一致**（未顺手「改进」）——
//   抽取是**搬迁**而不是重写；顺手改行为会让「删除」变成「改功能」，
//   而本次改动**无法本地编译验证**（本机 flutter 必崩）→ 必须让改动**可预测**。
//
// # 与 `chat_client.dart` 的差异（仅这些）
//   · 去掉 `conversationId` 字段（仅 chat 用）
//   · 去掉 WebSocket（`streamChat` / `WsChatSession` / `web_socket_channel` 依赖）
//   · 去掉 `getPreferences` / `savePreferences` 等其余 31 个方法
//   · 类名 `ChatClient` → `UserApiClient`（避免名字暗示它会做 chat）

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'api_config.dart';

/// 带 **HTTP 状态码** 的 API 异常（2026-10-10 新增）。
///
/// # 为什么必须有（而不是沿用 `Exception('Profile API: 401')`）
///
/// 调用方需要**区分**「网络不通」与「**登录态已失效（401）**」——
/// 前者重试有意义，后者**重试永远失败**，必须给「重新登录」的出口。
///
/// 🔴 而旧实现把状态码**拼进字符串**（`'Profile API: $statusCode'`）⇒ 调用方只能
///    `e.toString().contains('401')` —— 这属于「**用字符串当类型**」：
///    任何一个改文案的人都能让它**静默失效**（不再识别 401 ⇒ 出口消失且不报错）。
///    判据：**能用类型表达的判别，不要用字符串**。
class ApiStatusException implements Exception {
  final int statusCode;

  /// 触发它的接口路径（便于日志定位，不参与判定）。
  final String path;

  const ApiStatusException(this.statusCode, this.path);

  /// 🔑 401 = **凭证无效**（本项目里最常见的原因：**同一账号在别的设备上登录**，
  ///    旧 token 被 `enforce_token_limit` / 改密 / 重置密码清掉）。
  ///    ⚠️ 这是**终态**，不是瞬时错误 ⇒ 界面必须给出口，不能只给「重试」。
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiStatusException($statusCode @ $path)';
}

/// 个人页所需的用户接口客户端（**只含 2 个方法**，见文件头注释）。
class UserApiClient {
  final String baseUrl;
  final String userId;
  final String? token;

  UserApiClient({
    String? baseUrl,
    required this.userId,
    this.token,
  }) : baseUrl = baseUrl ?? ApiConfig.baseUrl;

  Map<String, String> get _authHeaders {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// 读当前用户资料（**调用方用到的字段**：`display_name` / `real_name` / `phone`）。
  ///
  /// 非 200 抛 [ApiStatusException]（带状态码，供调用方区分 401 与其他错误）。
  Future<Map<String, dynamic>> getProfile() async {
    final path = '/api/user/$userId/profile';
    final resp = await http.get(
      Uri.parse('$baseUrl$path'),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw ApiStatusException(resp.statusCode, path);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// 改昵称并同步到后端。**失败返回 `false`，不抛**（与 `chat_client` 原实现一致）。
  Future<bool> updateDisplayName(String name) async {
    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/user/$userId/display-name'),
        headers: _authHeaders,
        body: jsonEncode({'display_name': name}),
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('updateDisplayName error: $e');
      return false;
    }
  }
}
