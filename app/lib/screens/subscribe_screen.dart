// ════════════════════════════════════════════════════════════════════════
// CoEvo · 订阅页（独立页 · 路由 `/subscribe`）
// ════════════════════════════════════════════════════════════════════════
//
// 依据：`docs/design/ui-ux-refactor-assessment-2026-09-25.md` §4.4
//   （订阅界面的**唯一权威规格**）
//
// | 规格 | 本页对应 |
// |---|---|
// | §4.4.1 付费墙（免费层如实展示 / 价值主张具体 / 价格并列）| 权益卡 + 免费版说明 + 两档并列 |
// | §4.4.2 🔴 自动续费披露（**法定**）| [_disclosure] —— 名称/时长/价格/续期/取消路径 |
// | §4.4.3 🔴 恢复购买（Apple 强制项）| [_restoreButton]（另一处在「我的」页）|
// | §4.4.4 订阅状态与降级展示 | [_activeCard] + [_downgradeNote] |
//
// # 🔴 为什么是独立页，不是弹层（2026-10-04 白哥定）
//
// 原来是「`CoDialog` + `SubscribePanel`」的 380px 弹层。改独立页的理由：
//   ① **法定要件放不下** —— 自动续费披露 + 两个法律链接 + 权益 + 两档 + 恢复购买，
//      塞进弹层要滚动，而 §4.4.2 判例明确「**不是发了就行，要看得见、找得到**」
//   ② **Apple 审核要能看清** —— 订阅页是审核员必看的页面
//   ③ 规格一直写「订阅**页**」
//
// # 🔴 三条不可省的法定义务（删任一条都会被拒审）
//
// ① **自动续费说明**必须在购买按钮**附近**（§4.4.2：接受服务前就要显著提示）
// ② **隐私政策 + 用户协议**链接（Apple 对订阅类 App 的强制要求）
// ③ **恢复购买**入口（审核指南 3.1.1；且**两处**：本页 + 「我的」页）
//
// # 🔴 不预选任何档位
//
// §4.4.2「**不得默认勾选**」⇒ [_selectedProductId] 初值为 null，
// 未选时购买按钮**禁用**并提示「请先选择订阅方式」。
// 宁可让用户多点一次，也不做「默认选中 + 一键付款」——后者是 30 万元罚款的量级
// （判例：某视频公司因提醒路径不明确被判「难谓显著」）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/iap_provider.dart';
import '../services/iap_plan.dart';
import '../services/iap_service.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/clay_button.dart';
import '../widgets/legal_link_row.dart';

/// 正文（说明文字）字号 —— 与「关于」页同值（`about_screen._kBodyFontSize`）。
///
/// 🔑 跨页同字号：「关于」页与订阅页都是「从『我的』页进去的信息页」，
///    来回切换时正文字号必须一致，否则会有「跳一下」的观感。
const double _kBody = 14;

/// 弱说明（角标 / 附注）字号。
const double _kCaption = 12.5;

class SubscribeScreen extends ConsumerStatefulWidget {
  const SubscribeScreen({super.key});

  @override
  ConsumerState<SubscribeScreen> createState() => _SubscribeScreenState();
}

class _SubscribeScreenState extends ConsumerState<SubscribeScreen> {
  /// 🔴 **不预选**（§4.4.2「不得默认勾选」）—— 见文件头说明。
  String? _selectedProductId;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final snap = iapSnapshotOf(ref);

    // 商品还没查回来时用兜底档（价格会标「以 App Store 为准」）
    final plans = snap.plans.isEmpty ? defaultPlans() : snap.plans;
    final selected = _selectedOf(plans);

    // 购买成功 → 提示一次（幂等：只在「未激活 → 激活」的跃迁上触发）
    ref.listen<AsyncValue<IapSnapshot>>(iapSnapshotProvider, (prev, next) {
      final was = prev?.valueOrNull?.isActive ?? false;
      final now = next.valueOrNull?.isActive ?? false;
      if (!was && now && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('订阅已开通，感谢支持')),
        );
      }
    });

    return Scaffold(
      // 🔑 与全站一致：**自绘顶栏**（不用 Material `AppBar`）
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _topBar(t),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  CoSpacing.xxl,
                  0,
                  CoSpacing.xxl,
                  CoSpacing.xxxxl,
                ),
                children: [
                  if (snap.isActive) ...[
                    _activeCard(t, snap),
                    const SizedBox(height: CoSpacing.lg),
                    _downgradeNote(t),
                  ] else ...[
                    _benefitsCard(t),
                    const SizedBox(height: CoSpacing.xl),
                    _sectionTitle(t, '选择订阅方式'),
                    const SizedBox(height: CoSpacing.sm),
                    for (final p in plans)
                      _planCard(t, p, selected?.productId == p.productId),
                    const SizedBox(height: CoSpacing.lg),
                    _buyButton(snap, selected),
                    if ((snap.lastError ?? '').isNotEmpty) ...[
                      const SizedBox(height: CoSpacing.sm),
                      _errorLine(snap.lastError!),
                    ],
                    const SizedBox(height: CoSpacing.lg),
                    _disclosure(t, selected),
                    const SizedBox(height: CoSpacing.xl),
                    _restoreButton(t, snap),
                    const SizedBox(height: CoSpacing.lg),
                    _divider(t),
                    _legalRows(),
                    const SizedBox(height: CoSpacing.lg),
                    _signInHint(t),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 顶栏 ──────────────────────────────────────────────────────────
  //
  // 照 `about_screen` 的范式：「返回」是**右对齐的文字链接**（不是左箭头）。
  Widget _topBar(CoEvoTokens t) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '订阅',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 23 * -0.015,
                  color: Color(t.ink.argb32),
                ),
              ),
            ),
            InkWell(
              onTap: () => context.pop(),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  '返回',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  // ── 已订阅：状态卡（§4.4.4）────────────────────────────────────────
  Widget _activeCard(CoEvoTokens t, IapSnapshot snap) {
    final expires = snap.expiresAtUtc;
    final dateText = expires == null
        ? ''
        : ' · 到期日 ${expires.toLocal().toString().substring(0, 10)}';
    return Clay(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified, size: 19, color: Color(t.accent.argb32)),
              const SizedBox(width: 10),
              Text(
                '订阅中$dateText',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(t.ink.argb32),
                ),
              ),
            ],
          ),
          const SizedBox(height: CoSpacing.sm),
          Text(
            SubscriptionLegalText.howToCancel(),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: _kCaption,
              height: 1.6,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.md),
          // 🔴 §4.4.4：「已订阅 → 提供**管理订阅**（跳 Apple 订阅管理）」
          ClayButton(
            label: '管理订阅',
            onTap: () => _openUrl(kAppleManageSubscriptionsUrl),
          ),
        ],
      ),
    );
  }

  // ── 权益卡（§4.4.1：价值主张要具体）────────────────────────────────
  Widget _benefitsCard(CoEvoTokens t) {
    return Clay(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '订阅后可以',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.md),
          for (final b in SubscriptionLegalText.benefits) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Icon(Icons.check,
                      size: 15, color: Color(t.accent.argb32)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    b,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: _kBody,
                      height: 1.5,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CoSpacing.sm),
          ],
          const SizedBox(height: CoSpacing.xs),
          Divider(height: 1, color: Color(t.line.argb32)),
          const SizedBox(height: CoSpacing.md),
          // 🔴 §4.4.1「免费层如实展示」：明确写「免费可用」，**不用「试用」「限时」话术**
          Text(
            SubscriptionLegalText.freeTierNote(),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: _kCaption,
              height: 1.6,
              color: Color(t.ink3.argb32),
            ),
          ),
        ],
      ),
    );
  }

  // ── 套餐卡（并列展示 · 未选中态是默认）──────────────────────────────
  Widget _planCard(
    CoEvoTokens t,
    IapPlanDisplay plan,
    bool isSelected,
  ) {
    // 「省 X%」角标只在**年付**且折扣可算时显示
    final int? discount =
        plan.productId == kProductYearly ? _yearlyDiscount() : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: CoSpacing.sm),
      child: Clay(
        state: isSelected ? ClayState.selected : ClayState.raised,
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _selectedProductId = plan.productId),
        child: Row(
          children: [
            // 单选圈 —— 🔴 未选中是空心圈（「不预选」在视觉上也要能看出来）
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 19,
              color:
                  isSelected ? Color(t.accentInk.argb32) : Color(t.ink3.argb32),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        plan.durationLabel,
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: isSelected
                              ? Color(t.accentInk.argb32)
                              : Color(t.ink.argb32),
                        ),
                      ),
                      if (discount != null) ...[
                        const SizedBox(width: CoSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Color(t.accentBright.argb32)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '省 $discount%',
                            style: TextStyle(
                              fontFamily: CoFonts.uiSans,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: isSelected
                                  ? Color(t.accentInk.argb32)
                                  : Color(t.accent.argb32),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'CoEvo 专业版',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: _kCaption,
                      color: isSelected
                          ? Color(t.accentInk.argb32)
                          : Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CoSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  plan.priceLabel,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Color(t.accentInk.argb32)
                        : Color(t.ink.argb32),
                  ),
                ),
                if (plan.usingFallbackPrice)
                  Text(
                    // 🔑 兜底价必须**标注来源** —— 否则用户看到的价格与 App Store
                    //    实际扣款不一致时会认为被欺骗（价格权威在 ASC）
                    '以 App Store 为准',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11,
                      color: isSelected
                          ? Color(t.accentInk.argb32)
                          : Color(t.ink3.argb32),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 购买按钮 ──────────────────────────────────────────────────────
  Widget _buyButton(
    IapSnapshot snap,
    IapPlanDisplay? selected,
  ) {
    final busy = snap.purchasing;
    final unavailable = snap.availability == IapAvailability.unavailable;

    final String label;
    final bool enabled;
    if (busy) {
      label = '处理中…';
      enabled = false;
    } else if (unavailable) {
      label = '当前无法连接 App Store';
      enabled = false;
    } else if (selected == null) {
      label = '请先选择订阅方式';
      enabled = false;
    } else {
      label = '立即订阅 · ${selected.priceLabel}';
      enabled = true;
    }

    return ClayButton(
      label: label,
      expanded: true,
      enabled: enabled,
      onTap: enabled ? () => _buy(selected!) : () {},
    );
  }

  // ── 🔴 自动续费披露（§4.4.2 · 法定）────────────────────────────────
  Widget _disclosure(
    CoEvoTokens t,
    IapPlanDisplay? selected,
  ) {
    // 选中了就按该档披露（名称/时长/价格齐）；没选则给通用说明 ——
    // §4.4.2 要求「**接受服务前**」就提示，不能等到选完才告知。
    final notice = selected == null
        ? SubscriptionLegalText.autoRenewNoticeGeneric()
        : SubscriptionLegalText.autoRenewNotice(
            title: 'CoEvo 专业版',
            durationLabel: selected.durationLabel,
            priceLabel: selected.priceLabel,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          notice,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: _kCaption,
            height: 1.6,
            color: Color(t.ink2.argb32),
          ),
        ),
        const SizedBox(height: CoSpacing.sm),
        Text(
          SubscriptionLegalText.renewalCharge(),
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: _kCaption,
            height: 1.6,
            color: Color(t.ink3.argb32),
          ),
        ),
        const SizedBox(height: CoSpacing.sm),
        Text(
          SubscriptionLegalText.howToCancel(),
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: _kCaption,
            height: 1.6,
            color: Color(t.ink3.argb32),
          ),
        ),
      ],
    );
  }

  // ── 恢复购买（§4.4.3）─────────────────────────────────────────────
  Widget _restoreButton(CoEvoTokens t, IapSnapshot snap) => ClayButton(
        label: snap.purchasing ? '处理中…' : '恢复购买',
        variant: ClayButtonVariant.secondary,
        expanded: true,
        enabled: !snap.purchasing,
        onTap: _restore,
      );

  // ── 法律链接（Apple 强制要求）──────────────────────────────────────
  //
  // 🔑 用**共享组件** `LegalLinkRow` —— 与「关于」页是**同一套规则**：
  //    URL 为空 → 显示「即将上线」且不可点；就绪 → 可点。
  //    抽成组件而不是各写一份，理由见该文件（同一条规则写在两处会漂）。
  //
  // 📌 位置：`Column` 里两行，**不可省略** —— Apple 对订阅类 App 强制要求
  //    （审核指南 3.1.2），`iap_verify` 有断言守着。
  Widget _legalRows() => const Column(
        children: [
          LegalLinkRow(label: '隐私政策', url: kPrivacyPolicyUrl),
          LegalLinkRow(label: '用户协议', url: kTermsOfServiceUrl),
        ],
      );

  // ── 降级说明（§4.4.4：不没收用户资产）────────────────────────────────
  Widget _downgradeNote(CoEvoTokens t) => Text(
        downgradeNotice(),
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: _kCaption,
          height: 1.6,
          color: Color(t.ink3.argb32),
        ),
      );

  /// 未登录时的轻提示。
  ///
  /// 🔑 措辞刻意**不写成限制** —— 购买与恢复都**不需要登录**
  ///    （StoreKit 用 Apple ID 完成；本页对未登录用户完全可用）。
  ///    登录只是为了把交易**对账到账号**（便于跨设备查看记录）。
  Widget _signInHint(CoEvoTokens t) => Text(
        '订阅由 App Store 处理，无需登录即可购买与恢复。登录后可将订阅记录同步到账号。',
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 11.5,
          height: 1.6,
          color: Color(t.ink3.argb32),
        ),
      );

  Widget _sectionTitle(CoEvoTokens t, String text) => Text(
        text,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Color(t.ink.argb32),
        ),
      );

  Widget _divider(CoEvoTokens t) => Column(
        children: [
          Divider(height: 1, color: Color(t.line.argb32)),
        ],
      );

  Widget _errorLine(String msg) => Text(
        msg,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: _kCaption,
          color: Theme.of(context).colorScheme.error,
        ),
      );

  // ── 动作 ──────────────────────────────────────────────────────────

  IapPlanDisplay? _selectedOf(List<IapPlanDisplay> plans) {
    final id = _selectedProductId;
    if (id == null) return null;
    for (final p in plans) {
      if (p.productId == id) return p;
    }
    return null;
  }

  /// 年付相对月付的折扣（用**兜底价**算 —— StoreKit 给的是格式化字符串，无法参与运算）。
  int? _yearlyDiscount() {
    final base = defaultPlans();
    return yearlyDiscountPercent(
      monthlyFen: base[0].fallbackFen,
      yearlyFen: base[1].fallbackFen,
    );
  }

  Future<void> _buy(IapPlanDisplay plan) async {
    await ref.read(iapServiceProvider).buy(plan.productId);
    // ⚠️ 结果**不在这里判定** —— 它从 `purchaseStream` 异步回来，
    //    由 `iapSnapshotProvider` 驱动 UI（见 build 里的 `ref.listen`）。
  }

  Future<void> _restore() async {
    final outcome = await ref.read(iapServiceProvider).restore();
    if (!mounted) return;

    final msg = switch (outcome) {
      RestoreOutcome.restored => '已恢复订阅',
      RestoreOutcome.notFound => '未找到订阅记录',
      RestoreOutcome.failed => '恢复购买失败，请稍后重试',
      RestoreOutcome.unavailable => '当前无法连接 App Store',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 打开外部链接 —— 🔴 **失败必须让用户看见**（不能静默）。
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接，请稍后重试')),
    );
  }
}
