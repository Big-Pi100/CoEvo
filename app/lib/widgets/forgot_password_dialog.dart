// CoEvo · 「忘记密码」弹层（找回密码 —— 自助重置）
//
// # 它和「修改密码」是并列的两项，**不是**同一个功能的两种入口
//
// | | 修改密码 | 忘记密码（本文件） |
// |---|---|---|
// | 谁用 | **已登录**、记得原密码 | **登不进来**、忘了密码 |
// | 凭据 | 原密码 | 邮箱收到的 **6 位码** |
// | 旧会话 | **保留当前**、踢其他设备 | **全部删除** |
// ⇒ 两者的后端函数与前端入口都**刻意不共用**（判据：复用要看语义是否同一件事）。
//
// # 🔴 两处入口（白哥 2026-10-05 定案 A + B）
//
// | 入口 | 位置 | 谁走到 |
// |---|---|---|
// | **A** | `claim_dialog`（登录弹层）密码框下方「忘记密码？」 | **卡在门外**的人 |
// | **B** | `change_password_dialog` 尾部「忘了原密码？找回密码 ›」 | 已进来、但**想不起原密码**的人 |
//
// 🔑 入口 B 的位子在「修改密码」弹层里**早已留好**（`change_password_dialog.dart` §④ 原文：
//    「不能现在加 —— 指向一个不存在的功能比没有更糟」）⇒ 本次一并接上。
//
// # 三屏在同一弹层内分步（不套新弹层）
//
// 与 `ClaimDialog` 的「登录 ⇄ 注册」切换同构 ⇒ 用户不会迷路。
// 顶部三条进度指示展示「走到第几步了」。
//
// # 流程与后端的对应（**关键**：屏②不单独调接口）
//
// 后端 `POST /api/auth/reset-password` **一次**接收 `email + code + new_password`
// （见 `auth::reset_password`）⇒ 屏② 只做**本地格式校验**（6 位数字），
// 真正提交发生在屏③（两者一起发）。这样后端无需为「先验码」再开一个端点。
//
// # ⚠️ 屏③ 必须留「上一步」出口
//
// 若码错/过期，错误会显示在屏③ —— 用户需要有路**回屏②改码**。
// 📌 判据：**「有提示、无出口」比没有提示更糟**（本项目已因这条改过两处）。
//
// ⚠️ 本文件 import Flutter ⇒ **本机不可验证**（渲染），以 CI 的 `frontend` 为准。
//    可验部分：`services/code_box_logic.dart`（纯逻辑，本机可断言）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../services/code_box_logic.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../utils/validators.dart';
import 'clay_button.dart';
import 'clay_field.dart';
import 'co_dialog.dart';
import 'code_input.dart';
import 'twemoji.dart';

/// 「重新发送」的冷却秒数 —— 与后端 `auth::RESET_CODE_COOLDOWN_SECS` **同值**。
///
/// 🔴 两侧必须同值：后端硬性拒绝 60 秒内的重复申请。
///    若前端倒计时比后端短（如前端的 30 秒），用户会在**自以为可以**的时候
///    被后端拒绝，看到「发送太频繁」—— 那是把一个正常的等待变成一次报错。
const int kResendCooldownSecs = 60;

class ForgotPasswordDialog extends ConsumerStatefulWidget {
  const ForgotPasswordDialog({super.key});

  /// 打开弹层。**返回值**：`true` = 重置成功（且已自动登录）。
  ///
  /// 🔑 与 `ChangePasswordDialog.show` 同一约定：不在弹层里弹 toast，
  ///    由调用方统一负责（避免弹层关闭瞬间 toast 跟着消失）。
  static Future<bool?> show(BuildContext context) {
    return CoDialog.show<bool>(
      context,
      builder: (_) => const ForgotPasswordDialog(),
    );
  }

  @override
  ConsumerState<ForgotPasswordDialog> createState() =>
      _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends ConsumerState<ForgotPasswordDialog> {
  /// 0 = 输邮箱 · 1 = 输验证码 · 2 = 设新密码
  int _step = 0;

  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _newPwController = TextEditingController();
  final _confirmPwController = TextEditingController();

  bool _submitting = false;
  String? _error;

  /// 屏③ 两个密码框**各自独立**的显隐状态（同「修改密码」的取舍：
  /// 用户常要「看新密码、但确认框保持隐藏」，一个总开关做不到）。
  bool _showNewPw = false;
  bool _showConfirmPw = false;

  /// 「重新发送」倒计时（秒）。> 0 时不可点。
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    // 🔴 必须取消：否则弹层关闭后定时器仍在跑，回调里 `setState` 会炸
    //    （「弹层已 dispose 还在 setState」是本项目踩过的形态）。
    _timer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = kResendCooldownSecs);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  /// 去掉 `Exception: ` 前缀（同 `ChangePasswordDialog._friendly`）。
  ///
  /// 🔑 后端的设计是**「error 字段即用户可读文案」**（如「该邮箱尚未注册」），
  ///    所以这里**不改写内容**，只剥类型前缀 —— 改写反而会把准确文案变模糊。
  String _friendly(Object e) {
    final s = e.toString();
    const p = 'Exception: ';
    final msg = s.startsWith(p) ? s.substring(p.length) : s;
    final looksEnglish = RegExp('^[A-Za-z]').hasMatch(msg);
    return looksEnglish ? '网络异常，请稍后重试' : msg;
  }

  /// 邮箱打码（首尾各留 1 字，如 `zhangsan@qq.com` → `z…n@qq.com`）。
  ///
  /// 🔑 目的：让用户**确认没输错**，又不把完整邮箱显示在屏幕上
  ///    （弹层可能被旁人看到，以及在截图里留痕）。
  String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 1) return email;
    final name = email.substring(0, at);
    final domain = email.substring(at);
    if (name.length <= 2) return '${name[0]}…$domain';
    return '${name[0]}…${name[name.length - 1]}$domain';
  }

  // ── 屏① 发送验证码 ──
  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    final clientErr = Validators.email(email);
    if (clientErr != null) {
      setState(() => _error = clientErr);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).forgotPassword(email);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _step = 1;
      });
      _startCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendly(e); // 如「该邮箱尚未注册」（白哥定「明说」）
      });
    }
  }

  /// 重新发送（屏②倒计时结束后可点）。
  Future<void> _resend() async {
    if (_cooldown > 0 || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).forgotPassword(
            _emailController.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 重新发送后清掉旧码 —— 新码与旧码不同，留着会让用户困惑
        // （「我明明收到两个码，填哪个？」）。
        _codeController.clear();
      });
      _startCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendly(e);
      });
    }
  }

  /// 屏② → 屏③（**只做本地校验，不调接口**，见文件头）。
  void _toNewPassword() {
    final code = _codeController.text;
    if (!isCodeComplete(code)) {
      final missing = emptyBoxIndexes(code.split(''));
      setState(() => _error = '请填完 6 位验证码（还差 ${missing.length} 位）');
      return;
    }
    setState(() {
      _error = null;
      _step = 2;
    });
  }

  /// 屏③ 提交（**这才是真正调后端的地方**：email + code + 新密码一起发）。
  Future<void> _submitReset() async {
    final newPw = _newPwController.text;
    final confirm = _confirmPwController.text;
    final clientErr =
        Validators.password(newPw) ?? (confirm != newPw ? '两次输入的新密码不一致' : null);
    if (clientErr != null) {
      setState(() => _error = clientErr);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).resetPassword(
            email: _emailController.text.trim(),
            code: _codeController.text,
            newPassword: newPw,
          );
      if (!mounted) return;
      // 后端在重置成功时**直接返回新 token**（已自动登录）⇒ 无需再登一次。
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendly(e);
      });
    }
  }

  /// 错误是否来自「验证码」—— 决定要不要提示用户回上一步。
  ///
  /// 🔑 只在**屏③**用：码错/过期/次数用尽都要用户回去重新输码或重发。
  ///    ⚠️ 这是**字符串判断**（脆弱）⇒ **只用来追加一条提示**，
  ///    不用它做任何分支控制（后端才是权威）。
  bool get _errorLooksLikeCode {
    final e = _error ?? '';
    return e.contains('验证码') || e.contains('次数');
  }

  Widget _eye({required bool shown, required VoidCallback onTap}) {
    final t = CoEvoTokensExt.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Icon(
          shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 18,
          color: Color(t.ink3.argb32),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    final titles = ['找回密码', '输入验证码', '设置新密码'];
    final labels = ['发送验证码', '下一步', '重置密码'];

    return CoDialog(
      title: titles[_step],
      actions: [
        ClayButton(
          label: _submitting ? '请稍候…' : labels[_step],
          expanded: true,
          enabled: !_submitting,
          onTap: _step == 0
              ? _sendCode
              : _step == 1
                  ? _toNewPassword
                  : _submitReset,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 进度指示（三条）──
          ..._steps(t),
          const SizedBox(height: CoSpacing.md),

          // ── 各屏正文 ──
          if (_step == 0) ..._bodyEmail(t),
          if (_step == 1) ..._bodyCode(t),
          if (_step == 2) ..._bodyNewPassword(t),

          // ── 错误提示（**所有屏同一个位置、同一式样**）──
          if (_error != null) ...[
            const SizedBox(height: CoSpacing.md),
            Tw(
              _error!,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                height: 1.6,
                color: Color(t.accent.argb32),
              ),
            ),
            // 屏③ 且错误与「验证码」有关 ⇒ 明确告诉用户出口在哪
            // （判据：「有提示、无出口」比没有提示更糟）。
            if (_step == 2 && _errorLooksLikeCode) ...[
              const SizedBox(height: 4),
              Tw(
                '请点下方「‹ 上一步」重新输入验证码，或返回重发。',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11.5,
                  height: 1.6,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ],
          ],

          // ── 次要出口（放在末尾，与 `ClaimDialog` 的「没有账号？注册」**同一形态**）──
          // 🔑 屏②③ 必须有：屏③ 若码错，用户得有路**回去改码**
          //    （判据：「有提示、无出口」比没有提示更糟 —— 本项目已因这条改过两处）。
          if (_step > 0) ...[
            const SizedBox(height: CoSpacing.sm),
            _secondaryLink(
              label: _step == 2 ? '‹ 上一步（改验证码）' : '返回登录',
              onTap: _submitting
                  ? null
                  : () {
                      if (_step == 2) {
                        setState(() {
                          _step = 1;
                          _error = null;
                        });
                      } else {
                        Navigator.of(context).pop(false);
                      }
                    },
            ),
          ],
        ],
      ),
    );
  }

  /// 顶部三条进度指示。
  List<Widget> _steps(CoEvoTokens t) {
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 22,
              height: 3,
              margin: EdgeInsets.only(right: i == 2 ? 0 : 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: i <= _step
                    ? Color(t.accent.argb32)
                    : Color(t.sunken.argb32),
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _bodyEmail(CoEvoTokens t) {
    return [
      Tw(
        '输入你的注册邮箱，我们会发送 6 位验证码。',
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 12.5,
          height: 1.7,
          color: Color(t.ink3.argb32),
        ),
      ),
      const SizedBox(height: CoSpacing.lg),
      ClayField(
        controller: _emailController,
        hintText: '邮箱',
        keyboardType: TextInputType.emailAddress,
        enabled: !_submitting,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _sendCode(),
      ),
    ];
  }

  List<Widget> _bodyCode(CoEvoTokens t) {
    return [
      Tw(
        '已发送至 ${_maskEmail(_emailController.text.trim())}\n验证码 10 分钟内有效。',
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 12.5,
          height: 1.7,
          color: Color(t.ink3.argb32),
        ),
      ),
      const SizedBox(height: CoSpacing.lg),
      // 🔑 6 格（白哥定案）。实现是「1 个隐藏输入框 + 6 个展示格」——
      //    见 `widgets/code_input.dart` 头部为什么这样做。
      CodeInput(
        controller: _codeController,
        enabled: !_submitting,
        hasError: _error != null,
        autofocus: true,
      ),
      const SizedBox(height: CoSpacing.md),
      // 倒计时 / 重新发送
      _cooldown > 0
          ? Tw(
              '没收到？$_cooldown 秒后可重新发送',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 11.5,
                height: 1.6,
                color: Color(t.ink3.argb32),
              ),
            )
          : _secondaryLink(
              label: '重新发送验证码',
              onTap: _submitting ? null : _resend,
            ),
    ];
  }

  List<Widget> _bodyNewPassword(CoEvoTokens t) {
    return [
      ClayField(
        controller: _newPwController,
        hintText: '新密码（6位以上英文+数字）',
        obscureText: !_showNewPw,
        enabled: !_submitting,
        autofocus: true,
        trailing: _eye(
          shown: _showNewPw,
          onTap: () => setState(() => _showNewPw = !_showNewPw),
        ),
      ),
      const SizedBox(height: 10),
      ClayField(
        controller: _confirmPwController,
        hintText: '确认新密码',
        obscureText: !_showConfirmPw,
        enabled: !_submitting,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submitReset(),
        trailing: _eye(
          shown: _showConfirmPw,
          onTap: () => setState(() => _showConfirmPw = !_showConfirmPw),
        ),
      ),
    ];
  }

  /// 次要文字链接（与 `ClaimDialog` 的「没有账号？注册」同一形态）。
  Widget _secondaryLink({required String label, VoidCallback? onTap}) {
    final t = CoEvoTokensExt.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Tw(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: Color(onTap == null ? t.ink3.argb32 : t.accent.argb32),
          ),
        ),
      ),
    );
  }
}
