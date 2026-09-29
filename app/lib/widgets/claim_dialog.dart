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
/// # 🔴 外壳是**平面**，不是粘土（spec §〇 规则 1）
///
/// 「有体积的只可能是**可点**的东西」—— 弹窗本身不可点，
/// 所以它是「浮起来的平面」（`card` 底 + 外阴影），
/// 而不是一块凸起的粘土。里面的**输入框是凹陷**、**按钮是粘土**，
/// 三类元素各就各位。
/// 🔑 这与已有的两个浮层先例一致：`_UnlockCard`（成就解锁）、`LookupSheet`（划词浮层）。
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
import 'twemoji.dart';

class ClaimDialog extends ConsumerStatefulWidget {
  const ClaimDialog({super.key, this.pendingRefCode, this.pendingCampaignId});

  final String? pendingRefCode;
  final String? pendingCampaignId;

  /// 弹出本弹窗（「我的」页账号区与 `home_screen` 都走这里）。
  static Future<bool?> show(
    BuildContext context, {
    String? pendingRefCode,
    String? pendingCampaignId,
  }) {
    return showDialog<bool>(
      context: context,
      // 遮罩保持 Material 默认（54% 黑）：本弹窗是**抢焦点**的
      // （用户主动点了「登录 / 注册」），不该像 `LookupSheet` 那样把遮罩压到 12%。
      builder: (_) => ClaimDialog(
        pendingRefCode: pendingRefCode,
        pendingCampaignId: pendingCampaignId,
      ),
    );
  }

  @override
  ConsumerState<ClaimDialog> createState() => _ClaimDialogState();
}

class _ClaimDialogState extends ConsumerState<ClaimDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  /// `true` = 登录态（默认）· `false` = 注册态（多两个字段）。
  bool _isLogin = true;
  bool _isSubmitting = false;
  String? _validationError;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String? _validateInputs() {
    final u = _usernameController.text.trim();
    final p = _passwordController.text.trim();
    final err = Validators.username(u) ?? Validators.password(p);
    if (err != null) return err;
    if (!_isLogin) {
      final ne = Validators.realName(_nameController.text.trim());
      if (ne != null) return ne;
      final pe = Validators.phone(_phoneController.text.trim());
      if (pe != null) return pe;
    }
    return null;
  }

  Future<void> _submit() async {
    setState(() => _validationError = null);

    // 客户端校验
    final validationError = _validateInputs();
    if (validationError != null) {
      setState(() => _validationError = validationError);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      if (_isLogin) {
        await ref.read(authProvider.notifier).login(
              _usernameController.text.trim(),
              _passwordController.text,
            );
      } else {
        await ref.read(authProvider.notifier).trialClaim(
              _usernameController.text.trim(),
              _passwordController.text,
              realName: _nameController.text.trim(),
              phone: _phoneController.text.trim(),
              referralCode: widget.pendingRefCode,
              campaignId: widget.pendingCampaignId,
            );
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

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final authState = ref.watch(authProvider);
    final busy = _isSubmitting || authState.isLoading;

    return Dialog(
      // 🔴 外壳自己画（见类文档）：Material 的 `Dialog` 默认自带
      //    `surfaceTint` 底色 + elevation 阴影，那套观感与粘土/平面不同源
      //    → 背景透明 + elevation 0，只留它免费的**路由能力**
      //    （遮罩、返回键关闭、键盘避让、居中 + insetPadding）。
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: ConstrainedBox(
        // 平板 / 横屏下不让弹窗拉得过宽（手机上 insetPadding 已经先限住了）
        constraints: const BoxConstraints(maxWidth: 360),
        child: Container(
          decoration: BoxDecoration(
            color: Color(t.card.argb32),
            borderRadius: BorderRadius.circular(20),
            // 外阴影写法同 `_UnlockCard`（项目里浮层的既有做法）
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── ① 标题 ──
                // 原型第 ⑤ 屏是固定文案「登录 / 注册」（那页两个按钮并列可见）。
                // 本弹窗是**切换式**（同一时刻只有一种动作）→ 标题必须跟着变，
                // 否则点了「注册」还显示「登录」会让人以为没生效。
                Tw(
                  _isLogin ? '登录' : '注册',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.02 * 20,
                    color: Color(t.ink.argb32),
                  ),
                ),
                const SizedBox(height: 8),

                // ── ② 价值说明 ──
                // 照原型第 ⑤ 屏原文。第二句是有意保留的：它是产品原则的体现 ——
                // 「除生词表上限外不验证登录态」，用户需要先知道「不登录也能用」，
                // 才不会被这个弹窗吓退（否则登录会被读成「门槛」而不是「选项」）。
                Tw(
                  '登录后可跨设备同步生词本与学习记录，并找回已购订阅。'
                  '不登录也能用 —— 只有「生词本超过 200 词」等少数能力需要账号。',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12.5,
                    height: 1.7,
                    color: Color(t.ink3.argb32),
                  ),
                ),
                const SizedBox(height: CoSpacing.lg),

                // ── ③ 输入区（凹陷）──
                ClayField(
                  controller: _usernameController,
                  hintText: '用户名',
                  enabled: !busy,
                  autofocus: true,
                ),
                const SizedBox(height: 10),
                ClayField(
                  controller: _passwordController,
                  hintText: '密码（6位以上英文+数字）',
                  obscureText: true,
                  enabled: !busy,
                  textInputAction:
                      _isLogin ? TextInputAction.done : TextInputAction.next,
                  onSubmitted: _isLogin ? (_) => _submit() : null,
                ),

                // 注册态才有的两个字段
                if (!_isLogin) ...[
                  const SizedBox(height: 10),
                  ClayField(
                    controller: _nameController,
                    hintText: '真实姓名（中文，4字以内）',
                    enabled: !busy,
                  ),
                  const SizedBox(height: 10),
                  ClayField(
                    controller: _phoneController,
                    hintText: '手机号',
                    keyboardType: TextInputType.phone,
                    enabled: !busy,
                  ),
                ],

                // ── ④ 错误提示 ──
                // 🔑 两类错误**同一个位置、同一种样式**：
                //    客户端校验（`_validationError`）与服务端返回（`authState.error`）。
                //    分两处显示时，用户会以为是两个不同的问题。
                //    ⚠️ `authState.error` 会**一直留着**直到下次请求 ——
                //       所以只要它非空就显示（`copyWith` 里 `error` 是显式覆盖的）。
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

                // ── ⑤ 主按钮（粘土）──
                const SizedBox(height: CoSpacing.lg),
                ClayButton(
                  label: busy
                      ? (_isLogin ? '登录中…' : '注册中…')
                      : (_isLogin ? '登录' : '注册'),
                  expanded: true,
                  enabled: !busy,
                  onTap: _submit,
                ),

                // ── ⑥ 模式切换 ──
                const SizedBox(height: CoSpacing.sm),
                // 用裸 `GestureDetector` + `Text` 而不是 Material 的 `TextButton`：
                // 后者的水波纹 + 最小点击区（48px）会在一张「平面 + 凹陷」的弹窗里
                // 混进第三套交互观感。
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
          ),
        ),
      ),
    );
  }
}
