/// **修改邮箱弹窗** —— 两步：① 验当前密码 + 填新邮箱 → 发码；② 填码 → 换绑。
///
/// # 为什么是**两步**（而不是一张表单一次提交）
///
/// 换邮箱要证明的是「**新**邮箱属于你」—— 而那个证明只能在
/// 「**收到发往新邮箱的验证码**」之后成立 ⇒ 必须先发、后验。
///
/// # 🔴 为什么第 1 步要**当前密码**
///
/// 只验「新邮箱的码」等于让**拿到已解锁设备的人**把邮箱改成他自己的，
/// 随后走一次「忘记密码」就**彻底接管账号**（邮箱正是找回密码的收信地址）。
/// 与「改密码必须验原密码」是同一条理由 ——
/// 后端 `auth::issue_email_change_code` 的文档里有完整取舍。
///
/// # 版式
///
/// 与 `ForgotPasswordDialog` 同一套：`CoDialog` 外壳 + 顶部进度条 +
/// **同一位置同一式样**的错误提示 + 底部次要出口。
/// **刻意不新画一套** —— 「弹窗长什么样」全库只该有一处定义。
///
/// ⚠️ 本文件 import Flutter ⇒ **本机不可验证渲染**（本机 `flutter` 命令跑不了，
///    `CreateFile failed 231`）⇒ 以 CI 的 `frontend` job 为准
///    （与 `forgot_password_dialog.dart` 的声明同）。
library;

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
// 🔑 只为**一个常量**而 import：冷却秒数必须与「忘记密码」同值，
//    而后端两处的 cooldown 也都是 60s ⇒ 复制一个数字就是埋一处迟早漂移的重复。
//    ⚠️ 别把它「顺手」搬出来：`verify_forgot_password.dart` 的断言
//       明确检查它定义在 `forgot_password_dialog.dart` 里。
import 'forgot_password_dialog.dart' show kResendCooldownSecs;
import 'twemoji.dart';

class ChangeEmailDialog extends ConsumerStatefulWidget {
  const ChangeEmailDialog({super.key});

  /// 弹出本弹窗。
  ///
  /// 返回值：**新邮箱字符串**（成功）· `null`（取消 / 中途关闭）。
  static Future<String?> show(BuildContext context) {
    return CoDialog.show<String>(
      context,
      builder: (_) => const ChangeEmailDialog(),
    );
  }

  @override
  ConsumerState<ChangeEmailDialog> createState() => _ChangeEmailDialogState();
}

class _ChangeEmailDialogState extends ConsumerState<ChangeEmailDialog> {
  /// 0 = 输当前密码 + 新邮箱 · 1 = 输验证码
  int _step = 0;

  final _newEmailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();

  bool _submitting = false;
  String? _error;

  /// 「重新发送」倒计时（秒）。> 0 时不可点。
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    // 🔴 必须取消：否则弹层关闭后定时器仍在跑，回调里的 `setState` 会炸
    //    （「弹层已 dispose 还在 setState」—— 本项目踩过的形态）。
    _timer?.cancel();
    _newEmailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
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

  /// 去掉 `Exception: ` 前缀；消息以英文字母开头 ⇒ 判为「网络异常」。
  ///
  /// 🔑 后端的 `error` 字段**本身就是用户可读文案**（「当前密码不正确」/
  ///    「该邮箱已被其他账号使用」…）⇒ 这里**不改写内容**，只剥类型前缀。
  ///    改写会把准确文案变模糊。
  /// ⚠️ 与 `forgot_password_dialog` / `change_password_dialog` 的同名私有方法
  ///    **逐字一致** —— 三处各有一份是既有现状（它们分属不同弹层），
  ///    本次不为「改邮箱」引入第四种写法。
  String _friendly(Object e) {
    final s = e.toString();
    const p = 'Exception: ';
    final msg = s.startsWith(p) ? s.substring(p.length) : s;
    final looksEnglish = RegExp('^[A-Za-z]').hasMatch(msg);
    return looksEnglish ? '网络异常，请稍后重试' : msg;
  }

  /// 邮箱打码（首尾各留 1 字，`zhangsan@qq.com` → `z…n@qq.com`）。
  ///
  /// 🔑 让用户**确认没输错**，又不把完整地址留在屏幕/截图上。
  /// ⚠️ 这里打的是**用户刚输入的新邮箱** —— 他本人已知内容，打码纯粹是防旁人。
  String _maskEmail(String email) {
    final at = email.indexOf('@');
    if (at <= 1) return email;
    final name = email.substring(0, at);
    final domain = email.substring(at);
    if (name.length <= 2) return '${name[0]}…$domain';
    return '${name[0]}…${name[name.length - 1]}$domain';
  }

  // ── 屏① 发送验证码（到**新邮箱**）──
  Future<void> _sendCode() async {
    final newEmail = _newEmailController.text.trim();
    final clientErr = Validators.email(newEmail) ??
        (newEmail.toLowerCase() ==
                (ref.read(authProvider).email ?? '').toLowerCase()
            ? '新邮箱与当前邮箱相同'
            : null);
    if (clientErr != null) {
      setState(() => _error = clientErr);
      return;
    }
    if (_passwordController.text.isEmpty) {
      // ⚠️ 不在这里判「密码强度」—— 那是**设置**新密码时的规则，
      //    而当前密码只需「填了」。强度校验留给后端（它验的是正确性）。
      setState(() => _error = '请输入当前密码');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).changeEmailCode(
            password: _passwordController.text,
            newEmail: newEmail,
          );
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
        // 如「当前密码不正确」/「该邮箱已被其他账号使用」（后端均已明说）
        _error = _friendly(e);
      });
    }
  }

  /// 屏② 重新发送（倒计时结束后可点）。
  Future<void> _resend() async {
    if (_cooldown > 0 || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).changeEmailCode(
            password: _passwordController.text,
            newEmail: _newEmailController.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 重发后清掉旧码 —— 新码与旧码不同，留着会让用户困惑
        //（「我收到两个码，填哪个？」）。
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

  /// 屏② 提交 —— 真正换绑。
  Future<void> _submit() async {
    final code = _codeController.text;
    if (!isCodeComplete(code)) {
      final missing = emptyBoxIndexes(code.split(''));
      setState(() => _error = '请填完 6 位验证码（还差 ${missing.length} 位）');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await ref.read(authProvider.notifier).changeEmail(
            newEmail: _newEmailController.text.trim(),
            code: code,
          );
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendly(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    const titles = ['修改邮箱', '输入验证码'];
    const labels = ['发送验证码', '确认修改'];

    return CoDialog(
      title: titles[_step],
      actions: [
        ClayButton(
          label: _submitting ? '请稍候…' : labels[_step],
          expanded: true,
          enabled: !_submitting,
          onTap: _step == 0 ? _sendCode : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 进度指示（两条）──
          ..._steps(t),
          const SizedBox(height: CoSpacing.md),

          // ── 各屏正文 ──
          if (_step == 0) ..._bodyNewEmail(t),
          if (_step == 1) ..._bodyCode(t),

          // ── 错误提示（**两屏同一位置、同一式样**）──
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
          ],

          // ── 次要出口（放在末尾，与 `ClaimDialog` / `ForgotPasswordDialog` 同一形态）──
          // 🔑 屏② 必须有：码错了用户得有条路**回去改邮箱/密码**，
          //    否则只能关掉弹窗重来（「有提示、无出口」比没有提示更糟）。
          if (_step == 1) ...[
            const SizedBox(height: CoSpacing.sm),
            GestureDetector(
              onTap: _submitting
                  ? null
                  : () => setState(() {
                        _step = 0;
                        _error = null;
                        _codeController.clear();
                      }),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Tw(
                  '‹ 上一步（改邮箱或密码）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Color(
                      _submitting ? t.ink3.argb32 : t.accent.argb32,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 顶部两条进度指示。
  List<Widget> _steps(CoEvoTokens t) {
    return [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 2; i++)
            Container(
              width: 22,
              height: 3,
              margin: EdgeInsets.only(right: i == 1 ? 0 : 5),
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

  List<Widget> _bodyNewEmail(CoEvoTokens t) {
    return [
      Tw(
        '验证码会发送到**新邮箱**。为确认是本人操作，请同时输入当前密码。',
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 12.5,
          height: 1.7,
          color: Color(t.ink3.argb32),
        ),
      ),
      const SizedBox(height: CoSpacing.lg),
      ClayField(
        controller: _newEmailController,
        hintText: '新邮箱',
        keyboardType: TextInputType.emailAddress,
        enabled: !_submitting,
        autofocus: true,
      ),
      const SizedBox(height: 10),
      ClayField(
        controller: _passwordController,
        hintText: '当前密码',
        obscureText: true,
        enabled: !_submitting,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _sendCode(),
      ),
    ];
  }

  List<Widget> _bodyCode(CoEvoTokens t) {
    return [
      Tw(
        '验证码已发送至 ${_maskEmail(_newEmailController.text.trim())}，'
        '10 分钟内有效。',
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 12.5,
          height: 1.7,
          color: Color(t.ink3.argb32),
        ),
      ),
      const SizedBox(height: CoSpacing.lg),
      CodeInput(
        controller: _codeController,
        enabled: !_submitting,
        autofocus: true,
      ),
      const SizedBox(height: CoSpacing.sm),
      // ── 重新发送 / 倒计时 ──
      Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onTap: (_cooldown > 0 || _submitting) ? null : _resend,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Tw(
              _cooldown > 0 ? '重新发送（$_cooldown s）' : '重新发送',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: Color(
                  (_cooldown > 0 || _submitting)
                      ? t.ink3.argb32
                      : t.accent.argb32,
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}
