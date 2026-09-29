import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'api_config.dart';

/// Auth API client — /api/auth/register and /api/auth/login
///
/// # 🔴 2026-09-29：注册 / 登录标识由「用户名 + 实名 + 手机号」改为**邮箱**
///
/// 白哥：「注册不要真实姓名和手机号，用邮箱注册+密码注册」。
/// | 方法 | 参数变化 |
/// |---|---|
/// | [register] | `username, realName?, phone?` → **`email`** |
/// | [login] | `username` → **`email`** |
/// | [trialClaim] | `username, realName?, phone?` → **`email`** |
///
/// 📄 后端对应改动：`users` 表删 `real_name`/`phone`/`phone_hash`/`id_number`/`bind_hash`，
///    加 `email` 唯一索引。方案见 `profile-redesign-plan-2026-09-29.md`。
///
/// # 🔴 每个请求都必须 `.timeout()`
///
/// 本文件 2026-09-27 之前只有 [verifyToken] 带超时，其余 4 个请求**没有** ——
/// 于是当目标 IP **可达但不响应**（防火墙 DROP / 网络黑洞 / 服务假死）时，
/// Flutter Web 的 `http` 底层是浏览器 XHR/fetch，**默认超时极长**（Chrome ≈300s）
/// → 用户点了「登录」要干等好几分钟，且**没有任何提示**。
///
/// 🔑 **判定标准**：「连不上」和「连上了但没人应」是两回事 ——
/// - 端口无监听 → `ECONNREFUSED`，**立即**失败（不需要超时兜底）
/// - IP 可达但被丢弃 → **没有超时就会无限等**
/// 所以超时不是「防连不上」，而是「防等不到头」。
///
/// 用 [ApiConfig.requestTimeout]（10s）与 `chat_client` 保持一致，
/// **不各自写数字** —— 超时时长属于配置，不属于调用点。
class AuthClient {
  /// Register a new user（**直接注册**，不需要既有账号）。
  ///
  /// 返回 `{user_id, token, email}` 或抛异常。
  Future<Map<String, dynamic>> register(String email, String password, {String? referralCode}) async {
    final body = <String, dynamic>{'email': email, 'password': password};
    if (referralCode != null && referralCode.isNotEmpty) {
      body['referral'] = {'code': referralCode};
    }
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Registration failed');
    }
    return data;
  }

  /// Login. Returns {user_id, token, email} or throws.
  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Login failed');
    }
    return data;
  }

  /// Verify that a stored token is still valid on the server.
  /// Returns true if the token is valid, false otherwise.
  /// 验证 token 是否仍有效（用于应用重启后的会话恢复）
  /// 返回 `{valid: bool, email: String?}`
  ///
  /// 🔑 `email` 取代了原来的 `real_name` —— 而它的用途从来不是「显示姓名」，
  ///    而是让前端判断「**这个账号是否已完成注册**」（`email == null` = 仍是匿名试用账号）。
  ///
  /// ⚠️ 超时是 **5s，刻意不等于 `ApiConfig.requestTimeout`(10s)** ——
  /// 它在**启动路径**上（会话恢复），用户正等着首屏；
  /// 且超时的后果轻（网络错误按「已认证」继续，不阻塞）→ 宁可早点放行。
  /// **这是全库唯一的有意例外，不是漏改。**
  Future<Map<String, dynamic>> verifyToken(String userId, String token) async {
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/auth/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'user_id': userId, 'token': token}),
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('verifyToken: network error: $e');
    }
    return {'valid': true}; // Be lenient on network errors
  }

  /// Create a trial account. Returns {user_id, token}.
  Future<Map<String, dynamic>> trialStart({String? referralCode, String? campaignId}) async {
    final body = <String, String>{};
    if (referralCode != null && referralCode.isNotEmpty) {
      body['referral_code'] = referralCode;
    }
    if (campaignId != null && campaignId.isNotEmpty) {
      body['campaign_id'] = campaignId;
    }
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/trial/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Trial start failed');
    }
    return data;
  }

  /// 认领试用账号（= 把匿名账号升级为正式账号）。Returns `{token, email}`.
  ///
  /// 🔴 **需要既有账号**（`userId` / `token`）—— 调用方必须先确保已登录
  /// （哪怕是匿名试用账号）。未登录时应走 [register]。
  Future<Map<String, dynamic>> trialClaim(
    String userId,
    String token,
    String email,
    String password, {
    String? referralCode,
    String? campaignId,
  }) async {
    final body = <String, dynamic>{
      'user_id': userId,
      'email': email,
      'password': password,
    };
    if (referralCode != null && referralCode.isNotEmpty) body['referral_code'] = referralCode;
    if (campaignId != null && campaignId.isNotEmpty) body['campaign_id'] = campaignId;
    final resp = await http.put(
      Uri.parse('${ApiConfig.baseUrl}/api/trial/claim'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Trial claim failed');
    }
    return data;
  }
}
