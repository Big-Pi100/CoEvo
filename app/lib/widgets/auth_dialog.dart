/// **登录 / 注册弹窗** —— 全应用**唯一**一处账号入口。
///
/// # 🔴 它为什么曾是「两个职责」，以及 2026-10-09 之后只剩一个
///
/// | 职责 | 2026-10-09 之前 | 现在 |
/// |---|---|---|
/// | **登录已有账号** | 「我的」页账号区 | ✅ 保留 |
/// | **注册新账号** | 「我的」页账号区（未登录时）| ✅ 保留 |
/// | **认领匿名试用账号** | `home_screen._showAuthDialog()`（启动弹窗）| 🔴 **已删**（试用账号机制整体退役）|
///
/// ⚠️ 2026-09-29 有过一次事故：那时它**同时**承担「登录」（「我的」页用）与
///    「trial 认领」（启动弹窗用）两个职责。重排时把启动弹窗当作
///    「trial 认领弹窗」删掉，**连带删掉了「登录」的唯一入口** ——
///    因为同一个控件承担了两个职责，按其中一个职责处置就会消灭另一个。
/// 📄 判据：**删一个元素前，先查「它还承担什么职责」**。
///    🔑 2026-10-09 这次是**反过来**做的：先确认「认领」是**唯一的**被删对象，
///    再动它 —— 而且把类名/文件名从 `ClaimDialog` 改为 `AuthDialog`，
///    让那个已消失的概念**不会从名字里渗回来**（同族判据：删功能要清语义残留）。
///
/// # 🔴 形态说明：本批是**弹窗**，不是原型里的「登录页」
///
/// `profile-redesign-2026-09-29.html` 第 ⑤ 屏画的是一个**独立页面**
/// （自绘顶栏「‹ 登录」+ **Apple 登录** + **邮箱/密码** + 并列的登录/注册按钮）。
/// 但那一屏依赖**尚未就绪的后端**，原型里自己标着「本批不做」：
/// · 全库无 `sign_in_with_apple` 依赖
/// · `users` 表**无 `email` 列**（后端 0 命中）→ 是新增，不是复用
/// · 现有 `auth_client` 只有 **username + password**（5 个方法）
///
/// → 本批先用**弹窗**把「已有的账号体系」接通（能登录、能注册、能试出登录态），
///   **视觉照原型第 ⑤ 屏的版式**（标题 / 价值说明 / 输入 / 按钮），
///   只是：① 底子是弹窗不是整页；② 字段是「用户名」不是「邮箱」；
///     ③ 没有 Apple 按钮与「或」分隔线；④ 按钮从「并列两个」改为「主按钮 + 文字切换」
///     （弹窗里没有整页的横向空间，且切换式才能容纳注册所需的额外字段）。
/// 📄 原型第 ⑤ 屏（含上表依据）→ `docs/design/profile-redesign-2026-09-29.html` §D
/// 📄 落地依赖清单 → `docs/design/profile-redesign-plan-2026-09-29.md` §6.4
///
/// # 外壳：走公共 [CoDialog]（平面卡）
///
/// 不在这里自己画 `Dialog` + `Container` —— 「弹窗长什么样」全库只有一处定义。
/// 依据 spec §〇 规则 1「有体积的只可能是**可点**的东西」：弹窗不可点 → 是**平面**；
/// 里面的**输入框是凹陷**（`ClayField`）、**按钮是粘土**（`ClayButton`）。
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

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

/// 登录 / 注册弹窗（**全库唯一的账号入口**）。
class AuthDialog extends ConsumerStatefulWidget {
  const AuthDialog({super.key});

  /// 弹出本弹窗（「我的」页账号区）。
  ///
  /// 🔑 弹出方式统一走 [CoDialog.show] —— 遮罩浓度 / `insetPadding` 只该有一处定义。
  ///
  /// 🔴 2026-10-06：原 `pendingRefCode` / `pendingCampaignId` 两个参数已删 ——
  /// 分销/营销链整体退役（后端 `/api/referral/*` 与 `/api/campaign*` 路由已不存在）。
  /// 🔴 2026-10-09：原 `home_screen` 那个**自动弹窗**调用点已删 ——
  /// 启动不再弹任何东西（「未登录」是一等状态）；本弹窗现在只由
  /// 「我的」页的常驻入口打开。
  static Future<bool?> show(BuildContext context) {
    return CoDialog.show<bool>(
      context,
      builder: (_) => const AuthDialog(),
    );
  }

  @override
  ConsumerState<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends ConsumerState<AuthDialog> {
  /// 🔴 2026-09-29：字段由「用户名 + 密码 + 真实姓名 + 手机号」收敛为**邮箱 + 密码**。
  ///    白哥：「注册不要真实姓名和手机号，用邮箱注册+密码注册」。
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  /// `true` = 登录态（默认）· `false` = 注册态。
  bool _isLogin = true;
  bool _isSubmitting = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    // 🔴 2026-10-07 真机修复（白哥反馈 #7B）：**打开弹窗时清掉上一次的错误**。
    //
    // 现象：网络正常，但弹窗里一直写着「连不上服务器，请检查网络后重试」。
    // 根因：`authState.error` 只在下次操作时被覆盖，而「打开弹窗」不碰它
    // ⇒ 用户看到的是启动阶段那次失败留下的**陈旧错误**。
    //
    // ⚠️ 用 `microtask` 而不是直接调用：`initState` 期间改 provider 会触发
    //    「setState during build」告警。
    Future.microtask(() => ref.read(authProvider.notifier).clearError());
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateInputs() =>
      Validators.email(_emailController.text) ??
      Validators.password(_passwordController.text);

  Future<void> _submit() async {
    setState(() => _validationError = null);

    final validationError = _validateInputs();
    if (validationError != null) {
      setState(() => _validationError = validationError);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final email = _emailController.text.trim();
      final notifier = ref.read(authProvider.notifier);

      if (_isLogin) {
        await notifier.login(email, _passwordController.text);
      } else {
        // ── 注册：**直接建号** ──
        //
        // 🔴 2026-10-09：原「已登录（匿名试用账号）⇒ 认领 `trialClaim`」这条分支
        //    已随试用账号机制一起删除 —— 不再有匿名账号可认领。
        //    ⚠️ 它历史上还害过一次：**未登录时**误走认领，而 `trialClaim` 内部用
        //    `state.userId!` ⇒ 抛 `Null check operator used on a null value`
        //    ⇒ 用户看到一句英文机器话。现在那条路不存在了。
        //
        // 🔑 语义差异（值得留在注释里）：**认领** = 「升级**这个**匿名账号」，
        //    **注册** = 「新建一个账号」。两者本就不同，混用是接口选错了。
        await notifier.register(email, _passwordController.text);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // 错误文案**由 `authProvider` 统一成「人话」**（`_friendlyError`）后
      // 已经在 `authState.error` 里了 —— 这里不再拼一遍原始异常，
      // 否则会出现「网络超时」和「Exception: TimeoutException…」同时显示两行。
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Apple 登录只在 **iOS** 上可用（本项目唯一的目标平台）。
  ///
  /// 🔑 用 `defaultTargetPlatform` 而**不是** `Platform.isIOS`：
  ///    后者要 `import 'dart:io'`，在本项目（有 web 目标）会让 web 构建直接失败。
  bool get _supportsApple => defaultTargetPlatform == TargetPlatform.iOS;

  /// Sign in with Apple —— **建号 / 登录 / 绑定 三合一**（2026-10-07）。
  ///
  /// 🔑 身份完全由**设备上取得的 `identityToken`** 决定；provider 把它连同
  ///    「当前是否已登录」一起交给后端，由后端决定「绑定」还是「建号/登录」。
  ///
  /// 🆕 2026-10-13：**同时**把 `authorizationCode` 交给后端。
  ///    它是一次性的（约 5 分钟过期），后端立刻用它换 `refresh_token` 存库 ——
  ///    供「**注销时向 Apple 撤销授权**」用（Apple 审核 5.1.1(v)）。
  ///    🔴 只在登录**这一刻**才有 ⇒ 这里不取，那个用户就**永久**撤不了授权。
  ///    ⚠️ 它不影响登录本身：后端拿不到也只是记日志，登录照常成功。
  Future<void> _submitApple() async {
    setState(() {
      _isSubmitting = true;
      _validationError = null;
    });
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final identityToken = credential.identityToken;
      if (identityToken == null || identityToken.isEmpty) {
        // 拿不到 token **不是用户取消**（取消走下面的 exception 分支），
        // 通常是 entitlement / 后台 capability 没配齐 ⇒ 留日志便于排查。
        debugPrint('auth_dialog: Apple 未返回 identityToken（检查 App ID 的 '
            'Sign in with Apple capability 与 Runner.entitlements）');
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
      await ref.read(authProvider.notifier).appleLogin(
            identityToken,
            authorizationCode: credential.authorizationCode,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on SignInWithAppleAuthorizationException catch (e) {
      // 🔑 用户**主动取消**不是错误 —— 静默收场，不弹「登录失败」
      //    （弹了会让用户以为系统出问题，而他只是改了主意）。
      if (e.code == AuthorizationErrorCode.canceled) {
        debugPrint('auth_dialog: 用户取消了 Apple 登录');
        if (mounted) setState(() => _isSubmitting = false);
        return;
      }
      debugPrint('auth_dialog: Apple 授权失败 code=${e.code} msg=${e.message}');
      if (mounted) setState(() => _isSubmitting = false);
    } catch (e) {
      // 服务端/网络错误：文案已由 `authProvider` 归一化并写进 `authState.error`
      // ⇒ 这里只 `setState` 触发重绘，**不重复拼一遍原始异常**
      //   （否则界面上会同时出现「网络异常」和「Exception: …」两行）。
      debugPrint('auth_dialog: Apple 登录失败: $e');
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// 切换登录 / 注册。
  ///
  /// 🔑 必须清掉上一态留下的**已提交错误**：否则从「登录」切到「注册」时，
  ///    上一态那句「用户名或密码错误」会挂在注册表单下面 —— 用户会以为
  ///    是这次注册失败。
  void _toggleMode() {
    setState(() {
      _isLogin = !_isLogin;
      _validationError = null;
    });
  }

  /// 打开「忘记密码」流程（**入口 A** · 白哥 2026-10-05 定案）。
  ///
  /// 🔑 重置成功后后端**直接建了新会话**（自动登录）⇒ 本弹层也要一起关掉，
  ///    并让调用方知道「现在已登录」。
  ///    若只关子弹层，用户会看到「已登录的 App 上仍压着一个登录弹窗」——
  ///    而那个弹窗里的「登录」按钮再点会报「已登录」，非常费解。
  Future<void> _openForgotPassword() async {
    // 🔑 把用户**刚在登录框里打的**邮箱带过去预填 ——
    //    他点「忘记密码」的时机，往往就是刚打完邮箱、登录失败之后
    //    ⇒ 别让他再把同一串再打一遍。
    // ⚠️ 这里**不锁定**（`lockedEmail` 留空）：未登录时系统并不知道他是谁
    //    ⇒ 他可能记错了邮箱，必须允许改（见 `ForgotPasswordDialog.lockedEmail`）。
    final ok = await ForgotPasswordDialog.show(
      context,
      initialEmail: _emailController.text,
    );
    if (!mounted) return;
    if (ok == true) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final authState = ref.watch(authProvider);
    final busy = _isSubmitting || authState.isLoading;

    return CoDialog(
      // 原型第 ⑤ 屏是固定文案「登录 / 注册」（那页两个按钮并列可见）。
      // 本弹窗是**切换式**（同一时刻只有一种动作）→ 标题必须跟着变，
      // 否则点了「注册」还显示「登录」会让人以为没生效。
      title: _isLogin ? '登录' : '注册',
      actions: [
        ClayButton(
          label: busy
              ? (_isLogin ? '登录中…' : '注册中…')
              : (_isLogin ? '登录' : '注册'),
          expanded: true,
          enabled: !busy,
          onTap: _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── ① 价值说明 ──
          // 第一句照原型第 ⑤ 屏原文（`profile-redesign-plan` §六「未登录」态副标题：
          // 「登录后可跨设备同步 · 找回订阅」）—— **仍然成立**，保留。
          //
          // 🔴 第二句改过两次：
          //    2026-10-01 原文是「只有『生词本超过 200 词』等少数能力需要账号」，
          //       而 200 上限**已取消** ⇒ 那句成了**假陈述** ⇒ 改成
          //       「不登录也能用 —— 全部功能都可以直接使用，无需账号」。
          //    2026-10-09 那句**也不准了**：实测后端 —— **整段翻译**走
          //       `authorize_login_only`（额度按 `user_id` 记），未登录用不了
          //       ⇒ 「全部功能」是错的。改为**如实列举**：常用功能不需要账号，
          //       翻译因为要记免费额度才需要（那是它自己的提示会说明的事）。
          //    📌 判据：**「不登录也能用」这种全称断言，必须逐项核对** ——
          //       它会随任何一个功能加门而失效，而且失效时**没有任何东西会报错**。
          Tw(
            '登录后可跨设备同步生词本与学习记录，并找回已购订阅。'
            '阅读、划词、生词本与复习都不需要账号。',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12.5,
              height: 1.7,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.lg),

          // ── ①-b Sign in with Apple（2026-10-07 · 原型第 ⑤ 屏的上半部分）──
          //
          // 🔴 **只在 iOS 显示** —— `SignInWithApple` 在非 Apple 平台会直接抛异常，
          //    留一个「点了必失败」的按钮比没有按钮更糟。
          // 🔑 位置照原型：Apple 按钮在上、「或」分隔线在中、邮箱/密码在下。
          if (_supportsApple) ...[
            ClayButton(
              label: '通过 Apple 继续',
              // 与主按钮（登录/注册）**区分开**：它是一条**并列**的路，
              // 不是「更重要的那一个」。用 secondary 表达「同级的另一种选择」。
              variant: ClayButtonVariant.secondary,
              expanded: true,
              enabled: !busy,
              onTap: _submitApple,
            ),
            const SizedBox(height: CoSpacing.md),
            // 「或」分隔线 —— 明确「上面一条路、下面一条路」是二选一，
            // 而不是「先点 Apple 再填表单」这类顺序关系。
            Row(
              children: [
                Expanded(
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(t.line.argb32),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Tw(
                    '或',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ),
                Expanded(
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(t.line.argb32),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CoSpacing.md),
          ],

          // ── ② 输入区（凹陷）──
          //
          // 🔴 只剩两个字段（2026-09-29）：注册与登录**共用同一套** ——
          //    标识是邮箱，没有「只有注册才填」的额外字段了
          //    （原先是真实姓名 + 手机号，属微信时代的实名制遗留）。
          ClayField(
            controller: _emailController,
            hintText: '邮箱',
            keyboardType: TextInputType.emailAddress,
            enabled: !busy,
            autofocus: true,
          ),
          const SizedBox(height: 10),
          ClayField(
            controller: _passwordController,
            hintText: '密码（6位以上英文+数字）',
            obscureText: true,
            enabled: !busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),

          // ── ②-b 忘记密码出口（**入口 A** · 白哥 2026-10-05 定案）──
          //
          // 🔑 只放在**登录态**：注册态的用户还没账号，「忘记密码」不成立。
          //
          // 🔑 **右对齐小字**，而不是与底部「没有账号？注册」并列居中 ——
          //    两条次要链接若都居中，用户会以为是同一组二选一。
          //    视觉分层（右对齐 + 紧贴密码框 vs 居中 + 弹层底部）表达的是
          //    「这条属于**密码**这个字段，那条属于**整个弹层**」。
          //
          // 📌 位置刻意就在**密码框正下方** —— 用户「想不起来」的那一刻，
          //    视线与手指都在这个框上。
          if (_isLogin) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: busy ? null : _openForgotPassword,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  child: Tw(
                    '忘记密码？',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: Color(t.accent.argb32),
                    ),
                  ),
                ),
              ),
            ),
          ],

          // ── ③ 错误提示 ──
          // 🔑 两类错误**同一个位置、同一种样式**：
          //    客户端校验（`_validationError`）与服务端返回（`authState.error`）。
          //    分两处显示时，用户会以为是两个不同的问题。
          if (_validationError != null || authState.error != null) ...[
            const SizedBox(height: CoSpacing.md),
            Tw(
              _validationError ?? authState.error!,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                height: 1.6,
                color: Color(t.accent.argb32),
              ),
            ),
          ],

          // ── ④ 模式切换 ──
          // 用裸 `GestureDetector` + `Text` 而不是 Material 的 `TextButton`：
          // 后者的水波纹 + 最小点击区（48px）会在一张「平面 + 凹陷」的弹窗里
          // 混进第三套交互观感。
          const SizedBox(height: CoSpacing.sm),
          GestureDetector(
            onTap: busy ? null : _toggleMode,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Tw(
                _isLogin ? '没有账号？注册' : '已有账号？登录',
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
}
