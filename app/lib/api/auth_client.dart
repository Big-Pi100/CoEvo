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
/// | ~~`trialClaim`~~ | 该端点连带整个试用账号机制于 **2026-10-09 删除** |
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
  Future<Map<String, dynamic>> register(String email, String password) async {
    final body = <String, dynamic>{'email': email, 'password': password};
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

  // 🔴 2026-10-09 已删 `trialStart()` / `trialClaim()` —— 试用账号机制整体退役
  //    （后端 `/api/trial/start` 与 `/api/trial/claim` 两个路由一并删除）。
  //    见 `docs/review/trial-account-removal-2026-10-09.md`。

  /// 修改密码（需登录）。
  ///
  /// # 后端约定（`POST /api/auth/change-password`）
  /// · 鉴权**只认 `Authorization: Bearer <token>`** —— body 里**没有** `user_id`
  ///   （有的话就成了「改别人密码」的口子）
  /// · 成功 → `{"ok": true}`；失败 → `{"error": "<可直接展示给用户的文案>"}`
  ///
  /// 🔑 后端的 error 文案**已经写得可直接展示**（「原密码不正确」/「新密码不能与原密码相同」/
  ///    「该账号尚未设置密码，请先完成注册」）⇒ 这里**原样抛出**，不要再包一层英文前缀。
  ///    ⚠️ 上层（弹层）负责展示；**不要**把它和网络错误的英文混在一起。
  ///
  /// ⚠️ 超时用 `requestTimeout`（默认档）：它跑 bcrypt 两次（验旧 + 算新），
  ///    比登录稍慢，但仍在秒级 —— 不需要像 `verifyToken` 那样开例外。
  Future<void> changePassword({
    required String token,
    required String oldPassword,
    required String newPassword,
  }) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/change-password'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'old_password': oldPassword,
        'new_password': newPassword,
      }),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? '修改失败，请重试');
    }
  }

  /// 「忘记密码」第 1 步 —— 申请验证码（**无需 token**）。
  ///
  /// 🔑 用户此刻**登不进来**（忘了密码），所以这个接口不能带 `Authorization`。
  ///
  /// ⚠️ 后端的错误文案**可直接展示**：邮箱未注册时是「该邮箱尚未注册」
  ///    （白哥 2026-10-05 定「明说」）；60 秒内重复申请是「发送太频繁，请稍后再试」。
  ///    这里**不改写**这些文案（改写会把准确信息变模糊）。
  Future<void> forgotPassword(String email) async {
    // 🔴 2026-10-07 真机修复（白哥反馈 #7C）：**用长超时，不用默认 10s**。
    //
    // 现象：客户端显示「网络异常，请稍后重试」，但**服务器日志里这条是 200**。
    // 根因：服务端 `auth_forgot_password`（`routes.rs:499`）**同步 `await`**
    //      腾讯云 SES 发信 —— 发信慢于 10s 时：
    //        · 客户端先超时 ⇒ `TimeoutException`（**英文**）
    //        · `_friendly()` 见消息以英文开头 ⇒ 笼统显示「网络异常」（**误导**：
    //          用户以为没网，实际是服务端在等第三方）
    //        · 而服务器最终仍返回 200（日志可证）⇒ 邮件可能**已经发出去了**
    //
    // ⇒ 用 `longTimeout`（60s）：发信依赖**外部服务**，耗时不由我们控制。
    // ⚠️ 更根本的解法在**服务端**（把发信改成后台任务、接口立即返回）——
    //    否则用户只是不再被误导，等待时长并未改善。已记入报告待评估。
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/forgot-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    ).timeout(ApiConfig.longTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? '验证码发送失败，请稍后再试');
    }
  }

  /// 「忘记密码」第 2 步 —— 用验证码重置密码（**无需 token**）。
  ///
  /// 返回体与 [login] **同形**（`user_id` / `token` / `email`）——
  /// 后端在重置成功时直接建了新会话 ⇒ 前端可**自动登录**，不必再登一次。
  ///
  /// 🔑 与 [changePassword] 的关键差异：那个是「已登录时改密码」，
  ///    这个是「登不进来时重置」⇒ 两个接口的入参、鉴权、旧会话处理**都不同**，
  ///    参数名也刻意不同（`new_password` 相同，但这里多 `email` + `code`）。
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/reset-password'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'code': code,
        'new_password': newPassword,
      }),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? '重置失败，请重试');
    }
    return data;
  }

  // ══════════════════════════════════════════════════════════════════════
  // 修改邮箱（两步）—— 2026-10-07
  // ══════════════════════════════════════════════════════════════════════

  /// 「修改邮箱」第 1 步 —— 发验证码到**新邮箱**（**需登录**）。
  ///
  /// 🔴 除了 token 还**必须**传当前密码：
  ///    只验「新邮箱的码」等于让**拿到已解锁设备的人**把邮箱改成他自己的，
  ///    随后走一次「忘记密码」就**彻底接管账号**
  ///    —— 与「改密码必须验原密码」是同一条理由（后端的对应注释在
  ///    `auth::issue_email_change_code`）。
  ///
  /// ⚠️ 超时用 `longTimeout`（60s）：这一步**会真发一封邮件**（腾讯云 SES），
  ///    与 [forgotPassword] 完全同理 —— 发信耗时不归我们控制。
  ///    （默认 10s 会让用户看到误导性的「网络异常」，而服务端其实成功了。）
  Future<void> changeEmailCode({
    required String token,
    required String password,
    required String newEmail,
  }) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/change-email/code'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'password': password, 'new_email': newEmail}),
    ).timeout(ApiConfig.longTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? '验证码发送失败，请稍后再试');
    }
  }

  /// 「修改邮箱」第 2 步 —— 用验证码完成换绑（**需登录**）。返回**新邮箱**。
  ///
  /// 🔑 后端返回 `{"ok": true, "email": "<新邮箱>"}` ——
  ///    返回新邮箱是为了让调用方**立刻刷新界面上的账号邮箱**，
  ///    而不是等下一次 `verifyToken` 才知道改成了什么。
  Future<String> changeEmail({
    required String token,
    required String newEmail,
    required String code,
  }) async {
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/change-email'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'new_email': newEmail, 'code': code}),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? '修改失败，请重试');
    }
    return (data['email'] as String?) ?? newEmail;
  }

  // ══════════════════════════════════════════════════════════════════════
  // Sign in with Apple —— 2026-10-07
  // ══════════════════════════════════════════════════════════════════════

  /// Sign in with Apple（`POST /api/auth/apple`）。
  ///
  /// · [identityToken] 由 `sign_in_with_apple` 插件在**设备上**取得（JWS）
  /// · [token] 传当前会话 token ⇒ 把 Apple 身份**绑到该账号**（认领语义：
  ///   保留已有学习记录）；传 `null` ⇒ 建号 / 登录
  ///
  /// 返回体与 [login] **同形**（`user_id` / `token` / `email`）——
  /// 所以 `AuthProvider` 可以走与登录取值完全相同的落库路径。
  ///
  /// ⚠️ 后端**不接收** `authorizationCode`（它只为「注销时撤销 Apple 授权」服务，
  ///    本批不做；详见 `backend/crates/api_server/src/apple_auth.rs` 文件头）。
  Future<Map<String, dynamic>> appleLogin({
    required String identityToken,
    String? token,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final resp = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/auth/apple'),
      headers: headers,
      body: jsonEncode({'identity_token': identityToken}),
    ).timeout(ApiConfig.requestTimeout);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200 || data.containsKey('error')) {
      throw Exception(data['error'] ?? 'Apple 登录失败，请重试');
    }
    return data;
  }
}
