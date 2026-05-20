/// 统一表单验证规则
class Validators {
  static String? username(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (v.trim().length < 5) return '至少5位';
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(v.trim())) return '仅限英文和数字';
    return null;
  }

  static String? password(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (v.trim().length < 6) return '至少6位';
    if (!RegExp(r'[a-zA-Z]').hasMatch(v.trim())) return '需包含英文字母';
    if (!RegExp(r'\d').hasMatch(v.trim())) return '需包含数字';
    return null;
  }

  static String? realName(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (v.trim().length > 4) return '不超过4个字';
    if (!RegExp(r'^[\u4e00-\u9fff·]+$').hasMatch(v.trim())) return '仅限中文';
    return null;
  }

  static String? phone(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (!RegExp(r'^1\d{10}$').hasMatch(v.trim())) return '手机号格式不正确';
    return null;
  }

  static String? idNumber(String? v) {
    if (v == null || v.trim().isEmpty) return '必填';
    if (v.trim().length != 18) return '应为18位';
    if (!RegExp(r'^\d{17}[\dXx]$').hasMatch(v.trim())) return '格式不正确';
    return null;
  }
}
