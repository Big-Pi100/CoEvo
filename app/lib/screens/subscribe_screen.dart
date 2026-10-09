// ════════════════════════════════════════════════════════════════════════
// CoEvo · 订阅页（独立页 · 路由 `/subscribe`）
// ════════════════════════════════════════════════════════════════════════
//
// # 依据（两条线，缺一不可）
//
// | 线 | 文档 | 管什么 |
// |---|---|---|
// | **内容/合规** | `ui-ux-refactor-assessment-2026-09-25.md` §4.4 | 必须有哪些要素 |
// | **排版** | `design-system-spec-2026-09-25.md` §5.2 + §2/§3 | 该怎么摆 |
//
// ## 🔑 排版的核心依据：§5.2 的两条原则（原用于复习卡片，可直接迁移）
//
// > **「权重该由 色彩 + 底色 + 结构 承担；字号只承担层级」**
// > ⚠️ 易犯的错：① 把解释性段落做成大字号 ② **用字号当权重**
//
// 这页的「**答案**」是**价格** —— 所以全页最大字号必须给它。
// （同 §5.2「内容层最大的字号必须落在『释义』」的逻辑：答案要最显眼。）
//
// ## 🔴 2026-10-04 重排：修掉五个问题（白哥指出「排版有问题」）
//
// | # | 问题 | 依据 |
// |---|---|---|
// | 1 | **「答案」不是主角** —— 价格埋在 15px 里，与权益正文（14px）几乎同级 | §5.2 |
// | 2 | **月/年纵向堆叠** ⇒ 对比丢失（要上下扫视 + 心算）| §4.4.1 判据 4 要求「**并列**展示」<br>⇒ 这是**规格 vs 实现的偏差**，不是审美偏好 |
// | 3 | 法律条文 3 段**文字墙**夹在按钮与恢复购买之间 | §4.4.2 要「显著」+ 判例「要看得见、找得到、关得掉」<br>⇒ 文字墙反而**降低**显著性 |
// | 4 | 购买按钮与价格**分离**（选中后要往下滚）| 移动端可用性 |
// | 5 | 权益卡是**最重的一块**，但内容不成立 | §4.4.1 判据 3 要「主张具体」—— **没说要大卡片** |
//
// ⇒ 新结构（自上而下）：价值主张(一句话) → **价格并排(28px)** → 按钮紧邻
//    → **法定要点(贴按钮·不可折叠)** → **订阅权益(对照表·常驻)** → **订阅到期后(常驻)**
//    → 恢复购买 → 法律链接
//
// ## 🔴 2026-10-09 二稿（白哥定）：**整页去掉折叠**
//
// 白哥原话：「标题直接写『订阅权益』，同时这个区域不需要折叠」+
// 「订阅到期后当然也要常驻 —— 这就是为了让人知道订阅有什么好处」。
//
// | 一稿 | 二稿 | 为什么 |
// |---|---|---|
// | 折叠区「订阅详情与免费版说明」 | **常驻**「订阅权益」+「订阅到期后」两块 | **看不见 = 白做** —— 对照表正是这页的**说服材料**（10-07 §4.3 要解决的正是「用户读完不知道我有没有」）|
// | 折叠里放「免费版包含」列表 | 三列**对照表**（共同享有 / 订阅版专享）| 10-07 §四已定对比形态 = `功能\|免费\|订阅`；§4.2：**合并共同项、突出专享项** |
// | 一稿首屏的「订阅专享」胶囊 | 删掉 | 它**不自解释**（白哥问「这是什么」）⇒ 下方常驻的「订阅权益」已承担该职责 |
//
// ## 🔑 这两块的**受众**是未订阅 / 已到期的人（白哥 2026-10-09）
//
// 原话：「**这就是为了让人知道订阅有什么好处，没订阅、订阅到期的人看到才是关键，
// 已经订阅了的人有什么好看的**」⇒ 已订阅态（[_activeChildren]）**不渲染**这两块。
// 📌 判据：**先问「这块内容给谁看」，再决定它出现在哪个状态里** ——
//    对已订阅的人重复推销权益，既占地方又不产生任何决策价值。
//
// ## 🔑 法定要点与折叠的关系（口径已变）
//
// 法定要求的是「**显著提示**自动续期与取消路径」（§4.4.2）⇒ 那几句在本页
// **始终可见且紧贴购买按钮**（见 [_keynote]，含续费扣款时机）。
// 一稿曾把「续费与扣款」放进折叠区并论证「补充可折叠」；
// 二稿整页无折叠 ⇒ 它回到按钮正下方，**更符合「显著」**。
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
// ⚠️ 同理：**「省 34%」角标是价格事实陈述**（§4.4.1 判据 4 要求展示），
//    但**不得**演变成「推荐 / 默认选中」那种视觉诱导 —— 那是变相预选。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/iap_provider.dart';
import '../providers/subscription_provider.dart';
import '../services/iap_plan.dart';
import '../services/iap_service.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/clay_button.dart';
import '../widgets/legal_link_row.dart';
import '../widgets/sync_cloud_badge.dart';

/// 弱说明（角标 / 附注 / 补充段落）字号。
///
/// 🔑 本页**刻意没有**「正文字号」常量（原有一个 `_kBody = 14`，已删）——
///    重排后本页不再有「正文段落」这类元素：所有文字都归入
///    **价值主张（[_kLead]）/ 价格（[_kPrice]）/ 要点与说明（本常量）** 三类。
///    ⇒ 留一个用不到的常量会触发 `unused_element`（**CI 的 warning 是致命档**），
///      也会让后人以为「这里该有正文」。
///    📌 与「关于」页的字号一致性仍然成立 —— 那说的是**它的**正文；
///      本页没有对应元素，故无需同值。
const double _kCaption = 12.5;

/// 🔴 价格字号 —— **全页最大**。
///
/// 依据 `design-system-spec §5.2`：内容层最大字号必须落在「要记住的答案」。
/// 用户来订阅页要的答案是「多少钱」，所以它必须压过其它一切文字。
/// ⚠️ 反例（本次修掉）：原实现给价格 20px、给权益正文 14px —— 层级几乎不分。
const double _kPrice = 28;

/// 价值主张（一句话）字号。
///
/// 🔑 16px/600 足够 —— 它只承担「为什么值得看」，不承担「答案」。
///    权重靠**位置（顶部）+ 色彩（主文字色）**表达，不靠字号（§5.2）。
const double _kLead = 16;

/// 「订阅权益」对照表里，右侧两个值列（免费版 / 订阅版）的宽度。
///
/// 🔑 定宽是让它**两段对齐**：`共同享有` 段与 `订阅版专享` 段的行上下对得齐，
///    否则「— vs ✓」的对比会因为列宽漂移而看不出来。
///    62 是按最长的值文案「每月 10 次」（11px）定的。
const double _kCmpValueCol = 62;

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

    // 🔴 2026-10-09：改用**全库唯一判据** `subscriptionActiveNow`（端侧 OR 服务端）。
    //    此前这里直接读 `snap.isActive`（纯端侧）⇒ 在**没有 StoreKit 的载体**上
    //    （安卓验证机 / 后台授予的订阅）永远显示「未订阅」—— 而服务端明明有效。
    //    ⚠️ 下面的「购买成功提示」仍以**端侧跃迁**为准（那是 StoreKit 的事实，
    //       与「这个账号有没有权益」是两回事）。
    final isActive = subscriptionActiveNow(ref);

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
                // ── 顺序即优先级（自上而下）────────────────────────────
                children: isActive
                    ? _activeChildren(t, snap)
                    : _purchaseChildren(t, snap, plans, selected),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 已订阅态（§4.4.4）：状态 → 恢复购买 → 法律链接。
  ///
  /// 🔴 2026-10-09（白哥定）：**不渲染「订阅权益」「订阅到期后」** ——
  ///    这两块是给**未订阅 / 已到期**的人看的（见文件头「受众」那节）。
  ///    已订阅的人看到自己的权益清单没有决策价值，白白占掉一屏。
  List<Widget> _activeChildren(CoEvoTokens t, IapSnapshot snap) => [
        _activeCard(t, snap),
        const SizedBox(height: CoSpacing.xl),
        _restoreButton(t, snap),
        const SizedBox(height: CoSpacing.lg),
        _legalRows(),
        const SizedBox(height: CoSpacing.lg),
        _signInHint(t),
      ];

  /// 未订阅态：**价格与按钮在首屏**，法定要点紧贴按钮，
  /// 「订阅权益」与「订阅到期后」**常驻**（不折叠 —— 见文件头）。
  List<Widget> _purchaseChildren(
    CoEvoTokens t,
    IapSnapshot snap,
    List<IapPlanDisplay> plans,
    IapPlanDisplay? selected,
  ) =>
      [
        // ① 价值主张 —— 一句话（不是卡片）
        _valueProp(t),
        const SizedBox(height: CoSpacing.xl),

        // ② 价格 —— 月/年**并排**（§4.4.1 判据 4「并列展示」）
        _planRow(t, plans, selected),

        // ③ 购买按钮 —— **紧邻价格**（原实现隔了「选择订阅方式」标题 + 卡片 + 间距，
        //    选中后要往下滚才按得到，白哥指出的问题 4）
        const SizedBox(height: CoSpacing.lg),
        _buyButton(snap, selected),
        if ((snap.lastError ?? '').isNotEmpty) ...[
          const SizedBox(height: CoSpacing.sm),
          _errorLine(snap.lastError!),
        ],

        // ④ 法定要点 —— 🔴 **不可折叠**，紧贴按钮（§4.4.2）
        const SizedBox(height: CoSpacing.md),
        _keynote(t, selected),

        // ⑤ 🆕 「订阅权益」对照表 —— **常驻**
        _benefitsSection(t),

        // ⑥ 🆕 「订阅到期后」—— **常驻**（回答「退了会怎样」）
        _expirySection(t, lapsed: subscriptionLapsedNow(ref, snap)),

        // ⑦ 恢复购买（§4.4.3 Apple 强制项）
        const SizedBox(height: CoSpacing.lg),
        _restoreButton(t, snap),

        // ⑧ 法律链接（Apple 强制）
        const SizedBox(height: CoSpacing.md),
        _legalRows(),

        const SizedBox(height: CoSpacing.lg),
        _signInHint(t),
      ];

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

  // ── ① 价值主张（§4.4.1 判据 3：主张要具体）────────────────────────
  //
  // 🔑 为什么是**一句话 + 一行补充**，而不是原来的「权益卡」：
  //    ① §4.4.1 判据 3 只要求「主张**具体**」（不写「解锁全部功能」），
  //       **没有**要求做成卡片 —— 卡片是我们自己加的、还用满了视觉权重
  //    ② 权益清单已经由下方**常驻的「订阅权益」对照表**逐条承担
  //       ⇒ 标题只该说**一句话**（三条权益拼起来是一段话，做标题就是文字墙）
  //    ③ §5.2 判据：权重靠位置与色彩表达即可，不必靠体积
  Widget _valueProp(CoEvoTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            SubscriptionLegalText.headline(),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: _kLead,
              fontWeight: FontWeight.w600,
              height: 1.55,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: 6),
          // 🔴 §4.4.1 判据 2「免费层如实展示」：明确写「免费可用」，
          //    **不用「试用」「限时」话术**。
          Text(
            SubscriptionLegalText.freeTierNote(),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              height: 1.6,
              color: Color(t.ink3.argb32),
            ),
          ),
        ],
      );

  // ── ② 价格：月/年【并排】──────────────────────────────────────────
  //
  // 🔑 为什么并排（而不是原来的纵向两卡）：
  //    §4.4.1 判据 4 明确要求「月付 ¥9.9 / 年付 ¥78（省 34%）**并列**展示」。
  //    纵向堆叠时用户要**上下扫视 + 心算**才知道差多少 ⇒ 对比关系丢失。
  //    ⇒ 这一条是**规格 vs 实现的偏差**，不是我的审美偏好。
  Widget _planRow(
    CoEvoTokens t,
    List<IapPlanDisplay> plans,
    IapPlanDisplay? selected,
  ) =>
      IntrinsicHeight(
        // 🔑 需要 IntrinsicHeight：`CrossAxisAlignment.stretch` 要求父级高度有界，
        //    而 ListView 的纵向是无界的 ⇒ 没有它两卡会被拉成不同高（或报错）。
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < plans.length; i++) ...[
              if (i > 0) const SizedBox(width: CoSpacing.md),
              Expanded(
                child: _planCard(
                  t,
                  plans[i],
                  selected?.productId == plans[i].productId,
                ),
              ),
            ],
          ],
        ),
      );

  /// 单个档位卡（纵向：名称 → 价格 → 周期）。
  Widget _planCard(
    CoEvoTokens t,
    IapPlanDisplay plan,
    bool isSelected,
  ) {
    // 「省 X%」角标只在**年付**且折扣可算时显示
    final int? discount =
        plan.productId == kProductYearly ? _yearlyDiscount() : null;

    // 🔴 2026-10-07 真机修复：选中态的**文字**必须用 `accentInk`，不是 `accent`。
    //
    // `Clay(state: ClayState.selected)` 的填充色是 `tokens.accent`（朱砂红，
    // 见 `theme/clay.dart:81`：`fill ?? (isSelected ? tokens.accent : tokens.clayFill)`）
    // ⇒ 若文字也用 `accent`，就是**红底红字** —— 真机上表现为
    //   「选中以后文字看不见了」（白哥反馈 #8）。
    //
    // 🔑 `accentInk` 正是为这个场景定义的 token：它是「**强调色底上的文字色**」
    //    （墨/格档 `#FFFFFF`，夜档 `#2A1405`），两档都保证对比度。
    //    📌 判据：**凡是「某色当背景」，前景就用配套的 `*Ink`** ——
    //       配对 token 的存在本身就是为了防这种撞色。
    final inkOn = isSelected ? Color(t.accentInk.argb32) : Color(t.ink.argb32);
    final subOn = isSelected ? Color(t.accentInk.argb32) : Color(t.ink3.argb32);

    return Stack(
      // 角标要溢出卡片顶部
      clipBehavior: Clip.none,
      children: [
        Clay(
          state: isSelected ? ClayState.selected : ClayState.raised,
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _selectedProductId = plan.productId),
          padding: const EdgeInsets.fromLTRB(14, 15, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    plan.durationLabel,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: isSelected
                          ? Color(t.accent.argb32)
                          : Color(t.ink2.argb32),
                    ),
                  ),
                  const Spacer(),
                  // 🔴 未选中 = 空心圈 ⇒「不预选」在视觉上也要能看出来
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: isSelected
                        ? Color(t.accent.argb32)
                        : Color(t.ink3.argb32),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 🔴 价格 —— **全页最大字号**（§5.2：最大字号给「答案」）
              //    FittedBox 兜底：价格串来自 StoreKit（可能较长，如「¥1,280.00」），
              //    缩不下会溢出两列布局 ⇒ 让它**缩字**而不是撑破。
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  plan.priceLabel,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: _kPrice,
                    fontWeight: FontWeight.w700,
                    height: 1.05,
                    letterSpacing: _kPrice * -0.018,
                    color: inkOn,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                plan.periodLabel,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: _kCaption,
                  color: subOn,
                ),
              ),
              if (plan.usingFallbackPrice) ...[
                const SizedBox(height: 2),
                Text(
                  // 🔑 兜底价必须**标注来源** —— 否则用户看到的价格与 App Store
                  //    实际扣款不一致时会认为被欺骗（价格权威在 ASC）
                  '以 App Store 为准',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 10.5,
                    color: subOn,
                  ),
                ),
              ],
            ],
          ),
        ),

        // 「省 34%」角标 —— §4.4.1 判据 4 要求展示。
        // ⚠️ 它是**价格事实陈述**，不是「推荐」标签 —— 不得演变成变相预选。
        if (discount != null)
          Positioned(
            top: -8,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Color(t.accent.argb32),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                '省 $discount%',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(t.accentInk.argb32),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── ③ 购买按钮 ────────────────────────────────────────────────────
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

  // ── ④ 🔴 法定要点（§4.4.2 · **不可折叠**）────────────────────────────
  //
  // 🔑 它**必须**满足三件事（少一件就可能是 30 万元罚款的量级）：
  //    ① 在购买按钮**附近**（这里：正下方，零间隔元素）
  //    ② 说明**自动续期**（含 24 小时取消窗口）
  //    ③ 说明**在哪里取消**（可找到的路径）
  //
  // 📌 为什么用**纯文本**而不是做成「链接/按钮」：
  //    判例的核心是「**路径不明确 ⇒ 难谓显著**」。
  //    把取消路径写进**可见的句子**里（而不是藏在可点文字后面），
  //    比任何交互都更「显著」。
  //
  // ⚠️ 未选档位时也必须显示（`autoRenewNoticeGeneric`）——
  //    §4.4.2 要求「**接受服务前**」就提示，不能等用户选完才告知。
  //
  // 🔴 2026-10-09：「续费与扣款」(`renewalCharge`) 从折叠区**并到这里** ——
  //    整页去掉折叠后，它回到按钮正下方；它本身就是**法定披露**
  //    （与「自动续期 / 取消路径」同族）⇒ 放这里**更符合「显著」**。
  Widget _keynote(CoEvoTokens t, IapPlanDisplay? selected) {
    final notice = selected == null
        ? SubscriptionLegalText.autoRenewNoticeGeneric()
        : SubscriptionLegalText.autoRenewNotice(
            title: 'CoEvo 专业版',
            durationLabel: selected.durationLabel,
            priceLabel: selected.priceLabel,
          );

    final style = TextStyle(
      fontFamily: CoFonts.uiSans,
      fontSize: _kCaption,
      height: 1.62,
      color: Color(t.ink2.argb32),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(notice, style: style),
        const SizedBox(height: CoSpacing.sm),
        Text(SubscriptionLegalText.renewalCharge(), style: style),
        const SizedBox(height: CoSpacing.sm),
        Text(SubscriptionLegalText.howToCancel(), style: style),
      ],
    );
  }

  // ── ⑤ 订阅权益（三列对照表 · **常驻 · 不折叠**）──────────────────
  //
  // 🔴 受众是**未订阅 / 已到期**的人（见文件头「受众」）—— 已订阅态不渲染。
  //
  // 🔑 行数据**全部来自** `SubscriptionLegalText.comparison`（唯一事实清单）；
  //    这一层只负责**画**，不参与「哪条算权益」的判断 ——
  //    否则行数据与文案会各有一套（同一件事两个来源）。
  Widget _benefitsSection(CoEvoTokens t) {
    final rows = SubscriptionLegalText.comparison;
    // 第一条专享行之前 = 「共同享有」段；之后 = 「订阅版专享」段。
    final firstExclusive = rows.indexWhere((r) => r.exclusive);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(t, '订阅权益'),
        Clay(
          borderRadius: BorderRadius.circular(16),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            children: [
              _cmpHeaderRow(
                t,
                firstExclusive > 0 ? '共同享有' : '订阅版专享',
              ),
              for (var i = 0; i < rows.length; i++) ...[
                if (i == firstExclusive && firstExclusive > 0)
                  _cmpGroupRow(t, '订阅版专享'),
                _cmpRow(t, rows[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 小标题 —— 与「我的」页的分组标签**同款**（11px/600/ink3/字距 0.06）。
  ///
  /// 🔑 复用同一套语汇：订阅页与「我的」页的分组看起来必须是**同一种东西**
  ///    （判据：**统一的是外壳与层级**，不是「每页各发明一种小标题」）。
  Widget _sectionTitle(CoEvoTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(2, CoSpacing.xl, 2, CoSpacing.sm),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 11 * 0.06,
            color: Color(t.ink3.argb32),
          ),
        ),
      );

  /// 对照表的表头行：`共同享有 | 免费版 | 订阅版`。
  Widget _cmpHeaderRow(CoEvoTokens t, String left) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                left,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 11 * 0.05,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
            _cmpHeaderCell(t, '免费版'),
            _cmpHeaderCell(t, '订阅版'),
          ],
        ),
      );

  Widget _cmpHeaderCell(CoEvoTokens t, String text) => SizedBox(
        width: _kCmpValueCol,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 11 * 0.05,
            color: Color(t.ink3.argb32),
          ),
        ),
      );

  /// 段落标题行（「订阅版专享」）—— 无右侧两列，靠**上间距 + 字重**分段。
  Widget _cmpGroupRow(CoEvoTokens t, String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 11 * 0.05,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
          ],
        ),
      );

  /// 对照表的一行。
  ///
  /// 🔑 专享行的区分**不靠底色块**，靠**字重 + 强调色对勾**
  ///    （判据：**形状区分优于参数** —— 换底色会让表变「花」）。
  Widget _cmpRow(CoEvoTokens t, BenefitRow r) {
    final ex = r.exclusive;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(t.line.argb32))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              r.label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12.5,
                height: 1.35,
                fontWeight: ex ? FontWeight.w600 : FontWeight.w400,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
          SizedBox(
            width: _kCmpValueCol,
            child: Center(child: _cmpCell(t, r.free, emphasize: false)),
          ),
          SizedBox(
            width: _kCmpValueCol,
            child: Center(
              child: _cmpCell(t, r.sub, emphasize: ex && r.sub != '—'),
            ),
          ),
        ],
      ),
    );
  }

  /// 对照表的值单元格（`✓` / `—` / 额度文案）。
  Widget _cmpCell(CoEvoTokens t, String text, {required bool emphasize}) {
    // 额度类文案（「每月 10 次」）比 `✓/—` 长 ⇒ 小一号字，避免撑破列宽。
    final bool longText = text.length > 2;
    final Color color = text == '—'
        ? Color(t.ink3.argb32)
        : (emphasize ? Color(t.accent.argb32) : Color(t.ink2.argb32));
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: CoFonts.uiSans,
        fontSize: longText ? 11 : 12.5,
        fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
        color: color,
      ),
    );
  }

  // ── ⑥ 订阅到期后会怎样（**常驻 · 不折叠**）────────────────────────
  //
  // 🔑 它回答「我订了再退会怎样」—— 对**未订阅 / 已到期**的人是关键
  //    （白哥 2026-10-09：「没订阅、订阅到期的人看到才是关键」）⇒ 与权益一样常驻。
  //
  // 🔴 [lapsed]（**曾订阅、现已失效**）时先说一句降级说明
  //    —— 此前那句写在折叠区里、**对所有人都显示**，包括从未订阅的人
  //    （对他们说「会员已到期」是错的）。现在只在真·已到期时出现。
  Widget _expirySection(CoEvoTokens t, {required bool lapsed}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(t, '订阅到期后'),
          Clay(
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lapsed) ...[
                  _downgradeNote(t),
                  const SizedBox(height: CoSpacing.md),
                ],
                for (final s in SubscriptionLegalText.afterExpiry) _bullet(t, s),
              ],
            ),
          ),
        ],
      );

  /// 清单项（圆点 + 文字）。
  Widget _bullet(CoEvoTokens t, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(
                  color: Color(t.ink3.argb32),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: _kCaption,
                  height: 1.62,
                  color: Color(t.ink2.argb32),
                ),
              ),
            ),
          ],
        ),
      );

  // ── 已订阅：状态卡（§4.4.4）────────────────────────────────────────
  Widget _activeCard(CoEvoTokens t, IapSnapshot snap) {
    // 🔑 到期日走**全库唯一换算点**（端侧精确时刻优先 → 退回服务端对账值）
    //    —— 安卓上没有 StoreKit，端侧给不出日期，退回服务端才不会一片空白。
    final expiry = subscriptionExpiryLabel(
      iapExpiresAtUtc: snap.expiresAtUtc,
      backendExpiresAt: ref.watch(subscriptionProvider).expiresAt,
    );
    final dateText = expiry == null ? '' : ' · 到期日 $expiry';
    return Clay(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified, size: 19, color: Color(t.accent.argb32)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '订阅中$dateText',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Color(t.ink.argb32),
                  ),
                ),
              ),
              // 🆕 2026-10-09：云端同步的**云朵状态标**（白哥定：「加云朵图标就行」）。
              //    🔑 它自包含（自己判订阅 + 自己 watch 同步状态）⇒ 调用方一行。
              //    未订阅时不渲染（见 `SyncCloudBadge` 的文件头）。
              const SyncCloudBadge(),
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
  // 📌 位置：`Column` 里两行，**不可省略** —— Apple 对订阅类 App 强制要求
  //    （审核指南 3.1.2），`iap_verify` 有断言守着。
  // 🔑 用**共享组件** `LegalLinkRow`：「url 空则显示『即将上线』不可点」的规则单点。
  Widget _legalRows() => const Column(
        children: [
          LegalLinkRow(label: '隐私政策', url: kPrivacyPolicyUrl),
          LegalLinkRow(label: '用户协议', url: kTermsOfServiceUrl),
        ],
      );

  // ── 降级说明（§4.4.4：不没收用户资产）────────────────────────────────
  //
  // 🔴 只在**曾订阅且已失效**时显示（[lapsed]）—— 对从未订阅的人说
  //    「会员已到期」是错的（用户没订过，哪来的「到期」）。
  //    ⚠️ 一稿把它放在折叠区里、对所有状态显示 —— 那是个**错误陈述**，
  //       这次随重排一起修掉。
  Widget _downgradeNote(CoEvoTokens t) => Text(
        downgradeNotice(),
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: _kCaption,
          height: 1.6,
          color: Color(t.ink2.argb32),
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
