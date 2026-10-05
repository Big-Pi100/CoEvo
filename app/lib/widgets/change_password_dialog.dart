// CoEvo · 「修改密码」弹层
//
// # 为什么会有这个功能
//
// 它和「忘记密码」在**账号维护功能**里是**并列的两项**：
// · 只有「忘记密码」⇒ 记得密码的人**改不了**（想换个更强的密码都做不到）
// · 只有「修改密码」⇒ 忘了密码的人**进不去**（没有出口）
//
// # 🔴 三条设计约束（都来自「后端已定案的行为」，不是自选）
//
// | # | 约束 | 依据 |
// |---|---|---|
// | ① | **3 个字段**（原/新/确认） | 白哥 2026-10-05 定案（设计稿 §五 选 B） |
// | ② | **每个框右侧一个显隐切换** | 同上选 A —— 密码看不见，眼睛是**核对手段** |
// | ③ | **必须说「其他设备需要重新登录」** | 后端成功后会**失效其他会话**（保留当前）<br>这是**真实副作用**，用户**事先**就该知道 |
//
// ## ③ 为什么放在**字段上方**而不是成功提示里
//
// 若改完才告知，用户会以为「App 出故障把我踢了」——
// 📌 判据：**副作用要在动作发生前告知**（事先是「知情」，事后是「甩锅」）。
//
// # 为什么用 `CoDialog` 而不是另写一个弹层
//
// 登录/注册（`ClaimDialog`）、导入失败提示都用它 ⇒ **同一套弹窗观感**。
// 若各写一份，标题字号、按钮形态、圆角会静默漂移（本项目已有此类教训）。
//
// # 与 `ClaimDialog` 的两处**有意差异**（不是不一致）
//
// | | ClaimDialog（登录/注册） | 本弹层 |
// |---|---|---|
// | 密码字段 | 1 个 | **3 个** —— 改密码是「设一个看不见且不能弄错的值」，需二次确认 |
// | 错误文案 | 客户端校验 + 服务端错误**同一位置** | 同样同一位置 ✅（这条**保持一致**） |
//
// ⚠️ 本文件 import Flutter ⇒ **本机不可验证**（渲染），以 CI 的 `frontend` 为准。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../utils/validators.dart';
import 'clay_button.dart';
import 'clay_field.dart';
import 'co_dialog.dart';
import 'forgot_password_dialog.dart';
import 'twemoji.dart';

class ChangePasswordDialog extends ConsumerStatefulWidget {
  const ChangePasswordDialog({super.key});

  /// 打开弹层。**返回值**：`true` = 改成功了（调用方据此提示）。
  ///
  /// 🔑 刻意不在本弹层里弹 toast —— 那是**页面级**反馈，
  ///    由调用方（「我的」页）统一负责，避免弹层关闭瞬间 toast 跟着一起消失。
  static Future<bool?> show(BuildContext context) {
    return CoDialog.show<bool>(
      context,
      builder: (_) => const ChangePasswordDialog(),
    );
  }

  @override
  ConsumerState<ChangePasswordDialog> createState() =>
      _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<ChangePasswordDialog> {
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  /// 三个框各自的显隐状态。
  ///
  /// 🔑 **各自独立**（白哥选「每框一个」）：用户常需要「看原密码确认输对了、
  ///    但新密码保持隐藏」⇒ 用一个总开关做不到这件事。
  bool _showOld = false;
  bool _showNew = false;
  bool _showConfirm = false;

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  /// 当前的新旧密码是否**明显**不一致（只用于**即时**提示，不是拦提交）。
  ///
  /// ⚠️ 刻意只在「确认框**非空**且两者不同」时才提示 ——
  ///    若用户刚敲了确认框第一个字符就报错，体验很差（那是「边打边骂」）。
  bool get _mismatch =>
      _confirmController.text.isNotEmpty &&
      _confirmController.text != _newController.text;

  Future<void> _submit() async {
    final oldPw = _oldController.text;
    final newPw = _newController.text;
    final confirm = _confirmController.text;

    // ── 客户端校验（与后端 `validate_password_strength` 同一条规则）──
    // 🔑 复用 `Validators.password` —— 与注册用的是**同一个函数**，
    //    避免「注册允许但改密码不允许」这类跨流程漂移。
    final clientErr = (oldPw.isEmpty ? '请输入原密码' : null) ??
        Validators.password(newPw) ??
        (confirm != newPw ? '两次输入的新密码不一致' : null);

    if (clientErr != null) {
      setState(() => _error = clientErr);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(authProvider.notifier).changePassword(oldPw, newPw);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 后端文案已是中文且可直接展示（「原密码不正确」等）——
        // 但 `Exception: ` 前缀要去掉（那是 `Exception.toString()` 的产物）。
        _error = _friendly(e);
      });
    }
  }

  /// 去掉 `Exception: ` 前缀。
  ///
  /// 🔑 后端的设计是**「error 字段即用户可读文案」**，所以这里**不改写内容**，
  ///    只剥掉 Dart 异常对象的类型前缀 —— 改写反而会把准确文案变模糊。
  String _friendly(Object e) {
    final s = e.toString();
    const p = 'Exception: ';
    final msg = s.startsWith(p) ? s.substring(p.length) : s;
    // 网络类错误仍是英文（`SocketException` 等）⇒ 换成统一中文兜底
    final looksEnglish = RegExp(r'^[A-Za-z]').hasMatch(msg);
    return looksEnglish ? '网络异常，请稍后重试' : msg;
  }

  /// 显隐切换按钮（👁）。
  ///
  /// 🔑 用裸 `GestureDetector` + `Icon` 而非 `IconButton`：
  ///    后者的 48px 最小点击区会把凹陷框**撑高**，且带 Material 水波纹
  ///    （在「平面 + 凹陷」的弹窗里混入第三套交互观感 —— 同 `ClaimDialog` 的取舍）。
  Widget _eye({required bool shown, required VoidCallback onTap}) {
    final t = CoEvoTokensExt.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // 加大触摸面积（图标本身 18px 太小），同时不撑高布局
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

    return CoDialog(
      title: '修改密码',
      actions: [
        ClayButton(
          label: _submitting ? '修改中…' : '确认修改',
          expanded: true,
          // 🔴 禁用时走 `ClayState.disabled`（`ClayButton` 内建），
          //    而不是把 `onTap` 置 null —— 后者会造出「点了没反应的死入口」。
          enabled: !_submitting,
          onTap: _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── ① 副作用说明（**必须在字段上方** —— 见文件头 ③）──
          Tw(
            '改完后，其他设备需要重新登录，这台不用。',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12.5,
              height: 1.7,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.lg),

          // ── ② 三个凹陷输入框 ──
          ClayField(
            controller: _oldController,
            hintText: '原密码',
            obscureText: !_showOld,
            enabled: !_submitting,
            autofocus: true,
            trailing: _eye(
              shown: _showOld,
              onTap: () => setState(() => _showOld = !_showOld),
            ),
          ),
          const SizedBox(height: 10),
          ClayField(
            controller: _newController,
            // 🔑 提示里直接写规则 —— 与注册用的是**同一句**
            //    （`Validators.password` 的分条文案是「至少6位/需包含英文字母/需包含数字」，
            //     这里给个总览，用户一次就能填对）
            hintText: '新密码（6位以上英文+数字）',
            obscureText: !_showNew,
            enabled: !_submitting,
            trailing: _eye(
              shown: _showNew,
              onTap: () => setState(() => _showNew = !_showNew),
            ),
          ),
          const SizedBox(height: 10),
          ClayField(
            controller: _confirmController,
            hintText: '确认新密码',
            obscureText: !_showConfirm,
            enabled: !_submitting,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            trailing: _eye(
              shown: _showConfirm,
              onTap: () => setState(() => _showConfirm = !_showConfirm),
            ),
          ),

          // ── ③ 错误提示（客户端校验与服务端错误**同一位置、同一式样**）──
          // 🔑 与 `ClaimDialog` 保持一致的取舍：分两处显示会让用户
          //    以为是两个不同的问题。
          if (_error != null || _mismatch) ...[
            const SizedBox(height: CoSpacing.md),
            Tw(
              _error ?? '两次输入的新密码不一致',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                height: 1.6,
                color: Color(t.accent.argb32),
              ),
            ),
          ],

          // ── ④ 忘密码的出口（**入口 B** · 白哥 2026-10-05 定案，本次接上）──
          //
          // 🔴 这个是**唯一**把两个功能连起来的地方：
          //    用户点进「修改密码」多半是因为「我想不起来原密码了」
          //    —— 此时最该告诉他「有找回的路」。
          //
          // 🔑 **放在 `child` 末尾而不是 `actions` 里** ——
          //    `CoDialog.actions` 是**横向 Row + Expanded 平分**（见 `co_dialog.dart`），
          //    放进去会变成「确认修改 | 找回密码」两个并排按钮，语义完全不同。
          //
          // ⚠️ 形态照 **`ClaimDialog` 底部的「没有账号？注册」**（同一个弹层家族里
          //    已有的先例），而不是新造一种链接样式。
          //    📌 2026-10-05 更正：原注释写「照 `subscribe_screen` 的次要链接」——
          //      实测那处是 `ClayButton(variant: secondary)`（一个**按钮**，不是文字链接）
          //      ⇒ 那份引用是错的（同族判据：**引用要复制，不要凭印象写**）。
          const SizedBox(height: CoSpacing.sm),
          GestureDetector(
            // 提交中置 `null` ⇒ 不可点（`_secondaryLink` 的既有取舍）。
            onTap: _submitting ? null : _openForgotPassword,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Tw(
                '忘了原密码？找回密码 ›',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: Color(t.accent.argb32),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开「忘记密码」流程（**入口 B** · 白哥 2026-10-05 定案）。
  ///
  /// 🔑 重置成功后用户**已自动登录**，而本弹层是「已登录才会打开」的
  ///    ⇒ 重置成功时把本弹层一起关掉（`pop(false)` 表示「改密码**没**发生」，
  ///    调用方据此不弹「修改成功」——因为用户做的是**另一件事**）。
  Future<void> _openForgotPassword() async {
    final ok = await ForgotPasswordDialog.show(context);
    if (!mounted) return;
    if (ok == true) {
      Navigator.of(context).pop(false);
    }
  }
}
