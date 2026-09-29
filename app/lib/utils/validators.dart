/// 统一表单验证规则
///
/// # 🔴 2026-09-29：注册标识由「用户名 + 实名 + 手机号」改为**邮箱**
///
/// 白哥：「注册不要真实姓名和手机号，用邮箱注册+密码注册」。
/// 于是删掉了 `realName` / `phone` / `idNumber` 三个校验器
/// （它们只在 `ClaimDialog` 用过），新增 [email]。
///
/// 🔑 **判据必须与后端一致** —— 后端 `auth::is_valid_email` 用的是同一套宽松规则。
///    两边不一致的后果是「前端说没问题、后端拒了」或反之，
///    而用户只看到一个说不清原因的错误。
class Validators {
  /// 邮箱格式校验。
  ///
  /// # ⚠️ 刻意宽松（与后端 `auth::is_valid_email` 逐条对应）
  ///
  /// 只要求：有且只有一个 `@` · `@` 两侧非空 · 域名含 `.` · 无空白 · 总长 ≤254。
  ///
  /// 🔑 **为什么不写「严格」的正则**：过严会拒掉**合法**邮箱 ——
  ///    `a+tag@x.co.uk`（子地址）、国际化域名（`用户@例子.中国`，punycode 前形态）……
  ///    而被拒的用户**没有任何办法绕过**，只能放弃注册。
  ///
  /// 🔑 **真正的邮箱验证手段是「发验证邮件」，不是正则** —— 属登录页批次。
  static String? email(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '必填';
    if (s.length > 254) return '邮箱过长';
    if (RegExp(r'\s').hasMatch(s)) return '不能包含空格';

    final parts = s.split('@');
    if (parts.length != 2) return '邮箱格式不正确';
    final local = parts[0];
    final domain = parts[1];
    if (local.isEmpty) return '邮箱格式不正确';
    if (domain.isEmpty || !domain.contains('.') ||
        domain.startsWith('.') || domain.endsWith('.')) {
      return '邮箱格式不正确';
    }
    return null;
  }

  static String? password(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (v.trim().length < 6) return '至少6位';
    if (!RegExp(r'[a-zA-Z]').hasMatch(v.trim())) return '需包含英文字母';
    if (!RegExp(r'\d').hasMatch(v.trim())) return '需包含数字';
    return null;
  }
}
