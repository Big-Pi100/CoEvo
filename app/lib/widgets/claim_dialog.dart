/// **登录 / 注册弹窗** —— 全应用**唯一**一处账号入口。
///
/// # 🔴 它承担两个职责（这正是它一度被误删的原因）
///
/// | 职责 | 谁在用 | 场景 |
/// |---|---|---|
/// | **登录已有账号** | 「我的」页账号区 | 用户已有账号，想同步 / 找回订阅 |
/// | **认领试用账号**（注册） | `home_screen._showAuthDialog()` | 试用期满 / 已登录但没填姓名 |
///
/// ⚠️ 2026-09-29 之前它只在第 2 个场景被调用过（由「我的」页的自动弹窗触发）。
/// 那次重排把自动弹窗当作「trial 认领弹窗」删掉时，**连带删掉了「登录」的唯一入口** ——
/// 因为**同一个控件承担了两个职责**，按其中一个职责处置就会消灭另一个。
/// 📄 判据见 `MEMORY.md` 判据库：「删一个元素前，先查『它还承担什么职责』」。
///
/// ⚠️ **文件名/类名已名不副实**：`Claim` 指的是 trial 认领时代。
/// 现在它的主要消费者是「登录」。改名（→ `AuthDialog`）尚未做，
/// 因为那会牵动 `home_screen` 的引用 —— **留待与「登录页」一并处理**（见下）。
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

class ClaimDialog extends ConsumerStatefulWidget {
  const ClaimDialog({super.key});

  /// 弹出本弹窗（「我的」页账号区与 `home_screen` 都走这里）。
  ///
  /// 🔑 弹出方式统一走 [CoDialog.show] —— 遮罩浓度 / `insetPadding` 只该有一处定义。
  ///
  /// 🔴 2026-10-06：原 `pendingRefCode` / `pendingCampaignId` 两个参数已删 ——
  /// 分销/营销链整体退役（后端 `/api/referral/*` 与 `/api/campaign*` 路由已不存在）。
  static Future<bool?> show(BuildContext context) {
    return CoDialog.show<bool>(
      context,
      builder: (_) => const ClaimDialog(),
    );
  }

  @override
  ConsumerState<ClaimDialog> createState() => _ClaimDialogState();
}

class _ClaimDialogState extends ConsumerState<ClaimDialog> {
  /// 🔴 2026-09-29：字段由「用户名 + 密码 + 真实姓名 + 手机号」收敛为**邮箱 + 密码**。
  ///    白哥：「注册不要真实姓名和手机号，用邮箱注册+密码注册」。
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  /// `true` = 登录态（默认）· `false` = 注册态。
  bool _isLogin = true;
  bool _isSubmitting = false;
  String? _validationError;

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
      } else if (ref.read(authProvider).isAuthenticated) {
        // ── 已登录（匿名试用账号）→ **认领**：保留这个账号已有的学习记录 ──
        await notifier.trialClaim(
          email,
          _passwordController.text,
        );
      } else {
        // ── 未登录 → **直接注册** ──
        //
        // 🔴 这条分支是 2026-09-29 补的，修掉一个真错误：
        //    此前无论是否已登录都调 `trialClaim`，而它内部用 `state.userId!` ——
        //    未登录时是 `null` → 抛 `Null check operator used on a null value`，
        //    而 `_friendlyError` 映射不到这种字符串 → **用户看到一句英文机器话**。
        //
        // 🔑 两者的语义本就不同：认领 = 「升级**这个**匿名账号」，
        //    直接注册 = 「新建一个账号」。混用是接口选错了，不是参数写错了。
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
    final ok = await ForgotPasswordDialog.show(context);
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
          // 🔴 第二句是**本地补充**（原型里没有），2026-10-01 改写：
          //    原文是「只有『生词本超过 200 词』等少数能力需要账号」，
          //    而 200 上限**已取消**（免费可全量使用，见
          //    `docs/review/free-tier-limit-removal-assessment-2026-10-01.md`）
          //    ⇒ 那句成了**假陈述** ⇒ 必须改。
          // 🔑 改法：**只保留「不登录也能用」这一半**，不再列举「哪些能力需要账号」——
          //    因为现在**没有任何能力**需要账号，列举什么都不对。
          Tw(
            '登录后可跨设备同步生词本与学习记录，并找回已购订阅。'
            '不登录也能用 —— 全部功能都可以直接使用，无需账号。',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12.5,
              height: 1.7,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.lg),

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
