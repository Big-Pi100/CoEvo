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
  /// 非 200 抛异常（与 `chat_client` 原实现一致 —— 调用方在 `try/catch` 里兜）。
  Future<Map<String, dynamic>> getProfile() async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/user/$userId/profile'),
      headers: _authHeaders,
    ).timeout(ApiConfig.requestTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Profile API: ${resp.statusCode}');
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
