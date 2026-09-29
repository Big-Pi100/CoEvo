// CoEvo · 关于页
//
// 从「我的」页进入（`/about`）—— 依据 `ui-ux-refactor-assessment-2026-09-25` §6.1
// 定稿的「我的」子树最后一项：「关于」。
//
// # 🔴 本页**只有真实存在的内容**（不放假链接）
//
// | 想放的 | 为什么现在没放 |
// |---|---|
// | **隐私政策** | 🔴 URL 尚未确定。它是 **Apple 上架的硬要求**（App Store Connect 必填 + App 内应有入口）→ **待白哥提供正式 URL 后补**。**不编造链接**（判据同 `stats_card` 的分享注释：「若不编造 URL」）。 |
// | **用户协议** | 同上 |
// | **ICP 备案号** | ✅ 已备案（粤ICP备2026061557号-1）→ **可以放**，中国区 App 常规要求 |
// | 开源许可 | Flutter / 字体的许可都是真实的 → 可放；本版先不铺开（一张长列表会把「关于」变成一堵墙） |
// → 🔑 判据：**页面上的每个链接都必须能打开**。放一个死链比不放进糟糕 ——
//    用户点了没反应，会以为是 App 坏了（同「静默失败 + 无出口」）。
//
// # 🆕 「联系工作人员」2026-09-29 由「我的」页**移入本页**（白哥定）
//
// 🔑 为什么移到这里（不是冗余搬运）：它属**「关于本 App」这一族** ——
//    与「隐私政策 / 用户协议 / 版本 / 备案号」同类（都是「产品层面的信息」），
//    而不是「高频操作」（主题 / 朗读设置 / 成就）。
//    放在「我的」页的「其他」分组中段，会把「偶尔点」和「经常点」混在一起。
//
// # 🔴 视觉：本页**全平面**，所以新入口**不用**「我的」页那种粘土行
//
// 「我的」页的 `_navTile` 是 `bare: true` —— 它的设计前提是
// **外层已有 `Clay` 分组容器**（一整块凸起的卡，行与行之间用分隔线切）。
// 本页没有那个容器（内容直接铺在页面上）→ 直接搬过来会出现
// **一个孤立的凸起小块**，与周围全平面的文字不同源（判据：spec §〇 规则 1
// 「有体积的只可能是**可点**的东西」—— 可点 ≠ 必须有体积，形状要与所在页面成套）。
// ✅ 改用与 `_InfoRow` 同族的 [_LinkRow]：同一条基线、同样的行距，
//    只是右侧换成**强调色 + 箭头**来表达「这里能点进去」。
//
// # 🔴 排版规则（2026-09-29 白哥：「字号不统一、缩进不一致，大大小小前前后后，乱七八糟」后定）
//
// | 规则 | 值 | 为什么 |
// |---|---|---|
// | **正文字号** | **只有一档** [_kBodyFontSize]（=14，与「我的」页列表行同号） | 层级别靠字号差表达（12.5 vs 12 那种 0.5px 差**看不出层级、只显得不齐**） |
// | **左列颜色** | `ink`（深）—— 信息行与入口行**同色** | 同位置只该有一种颜色，否则相邻两组「一浅一深」 |
// | **右列颜色** | `ink3`（浅）· 入口处是 `accent` 箭头 | iOS 设置惯例「左黑右灰」 |
// | **行距** | 全部 `vertical: 9` | 三条信息行 + 入口行**同节奏** |
// | **分隔线留白** | 统一「上 20 / 下 16」（[_divider]） | 原两条线一个 `xl+lg` 一个 `xl+sm` |
//
// 🔴 **不重复呈现同一信息**：原先顶部有一个「App 名 22px + 版本 12.5px」的居中大块，
//    与下面的「应用名称 / 版本」两行**完全重复** —— 那是「前前后后」的真因，已删。
//    现在 App 名只在「应用名称」这一行出现**一次**。
//
// 🔴 **不放产品简介**（白哥 2026-09-29：「在关于里不用产品简介」）：
//    用户**已经在用**这个 App，再告诉他「这是英语学习应用…」是把营销文案放进产品内部 ——
//    那是 App Store 描述该干的事。「关于」页只回答「我装的是什么版本、谁做的、去哪找人」。
//
// 🔑 **判据（泛化）**：一个「关于/信息」页的乱，通常不是「某个字号不对」，
//    而是**①同一信息重复出现 ②层级用 0.5px 的字号差表达 ③同一位置混了两种颜色**。
//    修法是**减少变量**（少一档字号、少一处重复），不是逐处微调。
//
// # 🔴 第三轮：三行**必须共用同一个 label 列宽**（白哥第二次指出）
//
// 白哥：「应用名、版本号、备案号还是字号不统一、缩进不统一，**你只是取消了顶部的信息，
// 但是没有统一三行内容**」。
//
// 实测（用 Chrome 量原型的渲染几何，不是读代码猜）：
//
// | 行 | label | label 宽 | **值左边界** | 值右边界 |
// |---|---|---|---|---|
// | 应用名称 | 4 字 | 56 | **2025** | 2235 |
// | 版本 | 2 字 | 28 | **1997** | 2235 |
// | 备案号 | 3 字 | 42 | **2011** | 2235 |
//
// 🔴 **值的左边界差 28px** —— label 宽度由内容决定（4/2/3 字各不同），
//    而 `Spacer()` 把值推到右边 ⇒ **右边界齐、起点不齐** ⇒ 看着「参差」。
//
// ✅ 修法：label 列**定宽** + 值改**左对齐** ⇒ 两条竖直对齐线。
//    这是「信息表」的标准做法（同 macOS「关于本机」）。
//
// 🔑 **列宽由 `TextPainter` 实测**（[_measureLabelColumn]），**不是**「字号 × 字数」估算 ——
//    中文字形的 advance 不是恰好 1em，估算在系统「文字大小」缩放后会不够
//    （`header_chip.dart` 的教训：估算 36px 让「已到期」在真机折成两行）。
// ⚠️ **量宽度与渲染必须共用同一个 style**（[_labelStyle]）——
//    各写一份的话，改字体/字重后列宽会**悄悄**不准（不报错）。
//
// ⚠️ 关于白哥说的「字号不统一」：实测三行的 `font-size` **都是 14px，一致**。
//    「大小不一」的观感来自 ① 参差的起点（本轮修掉）② **中英字形差异** ——
//    中文是满格字面，`CoEvo` / `1.0.0` 是拉丁字母，同样 14px 下视觉高度明显更矮。
//    后者是字体固有的，**不该靠调字号去补**（补了会让中文行真的偏大）。

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_config.dart';
import '../constants/app_info.dart';
import '../theme/co_spacing.dart';
import '../theme/tokens_ext.dart';
import '../theme/coevo_tokens.dart';
import '../widgets/clay_button.dart';
import '../widgets/co_dialog.dart';
import '../widgets/twemoji.dart';

/// 关于页**正文的唯一字号**（信息行 / 说明 / 入口行 全用它）。
///
/// # 🔴 为什么把它提成常量（而不是各处写 14）
///
/// 2026-09-29 白哥：「字号不统一…大大小小…乱七八糟」。
/// 原实现一页里混了 **4 档**：22（App 名）/ 13（信息行）/ 12.5（版本·简介）/ 12（待补项）——
/// 其中 **12.5 与 12 只差 0.5px**，那种差**看不出层级、只显得不齐**。
///
/// 🔑 提到常量是为了让「**这一页只有一档正文字号**」成为**可断言的事实**（不是约定）：
///    将来有人想加一行文字，写 `fontSize: _kBodyFontSize` 时就会看到这段说明；
///    若他要写别的数，得先解释「为什么这一行该与其它行不同」。
///
/// 🔑 数值取 14 的依据：与 `profile_screen._navTile.title` 的「我的」页列表行
///    **同字号** —— 两个列表页的字号必须一致，否则来回切换会「跳」。
///
/// ⚠️ **不受它管**的只有两处：顶栏标题（23px，属页面级）与
///    「联系工作人员」弹窗（`CoDialog` 内部，属另一个视觉上下文）。
const double _kBodyFontSize = 14;

/// 信息行**左列（字段名）的唯一样式** —— [AboutScreen] 量列宽与 [_InfoRow] 渲染**共用**它。
///
/// 🔑 存在的唯一理由：**防止「量宽度」与「渲染」两处 style 漂移**。
///    拆成两份写法看起来无害，但改了 `fontSize` / `fontWeight` 之后，
///    量出来的列宽就不再是实际渲染宽度 —— 而**这不报错**，
///    只是三行悄悄又错开几像素（正是白哥这次指出的那类问题）。
///    判据：「同一件事的『口径』只能有一处权威」。
TextStyle _labelStyle(CoEvoTokens t) => TextStyle(
      fontFamily: CoFonts.uiSans,
      fontSize: _kBodyFontSize,
      // w500 与 `profile_screen._navTile.title` 一致（列表行左列都是这个字重）
      fontWeight: FontWeight.w500,
      color: Color(t.ink.argb32),
    );

/// 量出**一组 label 里最宽的那个**的实际渲染宽度（供 [_InfoRow.labelWidth] 用）。
///
/// # 🔑 为什么用 `TextPainter` 实测，而不是「字号 × 字数」
///
/// 中文字形的 advance **并非恰好 1em** —— 字体 fallback、`w500` 的合成加粗、
/// 系统「文字大小」缩放，都会让它更宽。估算值迟早不够（`header_chip.dart` 的教训：
/// 那里用 `labelMinWidth = 36` 估算「3 字 × 11.5」，真机上「已到期」折成了两行）。
///
/// ✅ 让**引擎**量：同一套 `TextStyle` 喂进去，谁宽用谁。
/// ⚠️ 调用方应传 [_labelStyle] 的产物 —— **与实际渲染完全同一个 style**，否则白量。
double _measureLabelColumn(List<String> labels, TextStyle style) {
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    maxLines: 1,
  );
  var widest = 0.0;
  for (final label in labels) {
    painter.text = TextSpan(text: label, style: style);
    painter.layout();
    if (painter.width > widest) widest = painter.width;
  }
  return widest;
}

/// 段间分隔线 —— **上下留白统一**（上 `xl`=20 / 下 `lg`=16）。
///
/// 🔑 为什么做成 helper：原实现两条线分别写了 `xl+lg` 与 `xl+sm` ——
///    **同样的线、不同的留白**，这也是「不齐」的一部分。
///    抽成一处后，「两条线长得一样」就不再依赖我每次记得写对。
Widget _divider(CoEvoTokens t) => Column(
      children: [
        const SizedBox(height: CoSpacing.xl),
        Divider(height: 1, color: Color(t.line.argb32)),
        const SizedBox(height: CoSpacing.lg),
      ],
    );

/// 关于页（版本 · 备案号 · 待补项）。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🔑 产品信息三行的 **label 列宽** —— 引擎实测，三行共用（见文件头「第三轮」）。
    //    🔴 必须「一处产出、两处消费」：量的 style 与 `_InfoRow` 渲染的 style
    //       都由 [_labelStyle] 产生；各写一份的话，改了字体/字重后列宽会悄悄不准。
    final labelColumnWidth = _measureLabelColumn(
      const ['应用名称', '版本', '备案号'],
      _labelStyle(t),
    );

    return Scaffold(
      // 🔑 与全站一致：**自绘顶栏**（不用 Material `AppBar`）
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 顶栏：「返回」在右（照 `bookmark_list_screen` 的范式：
            //    设计稿 `.bm-hd .back` 是**右对齐的文字链接**，不是左箭头）──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '关于',
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
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
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    CoSpacing.xxl, 0, CoSpacing.xxl, CoSpacing.tabBarClearance),
                children: [
                  const SizedBox(height: CoSpacing.xl),

                  // ── ① 产品信息（三行，**完全同格式**）──
                  //
                  // 🔴 2026-09-29 白哥：「应用名、版本号、备案号字号不统一、缩进不一致，
                  //    大大小小前前后后，乱七八糟」。诊断出**两个真因**：
                  //
                  // ① **同一信息出现两次**（「前前后后」）：这里原本上面还有一个
                  //    「App 名 22px + 版本 12.5px」的居中大块，与下面这两行**完全重复**
                  //    → 已删。App 名只在「应用名称」这一行出现一次。
                  // ② **一页 4 档字号**（「大大小小」）：22 / 13 / 12.5 / 12。
                  //    其中 12.5 与 12 只差 0.5px —— **看不出层级，只显得不齐**。
                  //    → 全页正文统一 **14px**（= `profile_screen._navTile.title` 的
                  //      「我的」页列表行字号，**跨页也一致**）。
                  //
                  // 🔑 层级改由**颜色**承担（而不是 0.5px 的字号差）：
                  //    · 左列（字段名）`ink` 深色 + w500 —— 与 `_LinkRow` 的左列**同色**，
                  //      于是「字段行」与「动作行」的左列在视觉上**是一条线**
                  //      （原实现这里是 `ink3` 浅色，与下面的 `ink` 深色对不齐）
                  //    · 右列（值）`ink3` 浅色 —— 与 iOS 设置「左黑右灰」的惯例一致
                  //
                  // ⚠️ 之前 `_InfoRow` 是「标签浅 / 值深」，而原型 `.row` 是「标签深 / 值浅」
                  //    —— 两处相反。现统一到后者（设置列表的通行做法）。
                  // 🔴 三行**共用同一个 label 列宽**（`labelColumnWidth`）——
                  //    不传它的话，label 又回到「内容宽」，三行的值起点就会再次错开。
                  //    📄 实测数据与推导见文件头「第三轮」。
                  _InfoRow(
                      labelWidth: labelColumnWidth,
                      label: '应用名称',
                      value: kCoEvoName),
                  _InfoRow(
                      labelWidth: labelColumnWidth,
                      label: '版本',
                      value: kCoEvoVersion),
                  // 🔑 备案号是**中国区上架的常规要求**，且已真实持有 → 直接放（不是占位）
                  _InfoRow(
                      labelWidth: labelColumnWidth,
                      label: '备案号',
                      value: '粤ICP备2026061557号-1'),

                  // ── ② 分隔线（留白统一：上 20 / 下 16）──
                  //    ⚠️ 原实现两条线分别是 `xl+lg` 与 `xl+sm` —— 同样的线、不同的留白，
                  //       也是「不齐」的一部分。现在两条**完全一致**。
                  _divider(t),

                  // ── ③ 🔴 待补项（**可见地标注，而不是留死链**）──
                  //    Apple 上架需要「隐私政策」入口；URL 未定 → 先如实说明，
                  //    而不是放一个点了没反应的链接。
                  //
                  // 🔴 2026-09-29：**产品简介已删**（白哥：「在关于里不用产品简介」）。
                  //    原文案是「CoEvo 是一款英语学习应用：读英文新闻、划词查词…」。
                  //    🔑 删它的道理：用户**已经在用**这个 App 了，再告诉他「这是英语学习应用」
                  //       是把营销文案放进了产品内部 —— 那是 App Store 描述该干的事。
                  //       「关于」页只该回答「我装的是什么版本、谁做的、去哪找人」。
                  Text(
                    '隐私政策与用户协议即将上线。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: _kBodyFontSize,
                      color: Color(t.ink3.argb32),
                    ),
                  ),

                  _divider(t),

                  // ── ④ 🆕 联系工作人员（2026-09-29 由「我的」页移入）──
                  _LinkRow(
                    label: '联系工作人员',
                    onTap: () => _showContactDialog(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  /// 「联系工作人员」弹窗（二维码）。
  ///
  /// 🔴 2026-09-29 由 `profile_screen` 整体移入 —— 逻辑与原实现一致，
  ///    只是**弹窗外壳换成公共 `CoDialog`**（本页此前无弹窗，现在起有了一处）。
  ///
  /// 🔑 二维码是**联网图片**（`/api/public/qrcode`）→ 必须有 `errorBuilder`：
  ///    没网/接口挂了时显示一个「图片不可用」图标，而不是留一块空白
  ///    （判据同本页文件头：「静默失败 + 无出口」比报错更糟）。
  void _showContactDialog(BuildContext context) {
    CoDialog.show<void>(
      context,
      builder: (ctx) {
        // ⚠️ 用 builder 的 `ctx` 取 token（而不是外层 context）——
        //    弹窗是**路由级 overlay**，它的 context 才是它真正所在的树。
        final t = CoEvoTokensExt.of(ctx);
        return CoDialog(
          title: '联系工作人员',
          actions: [
            ClayButton(
              label: '关闭',
              variant: ClayButtonVariant.secondary,
              expanded: true,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tw(
                '扫码添加工作人员微信',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 13,
                  color: Color(t.ink2.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.lg),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: NetworkImage('${ApiConfig.baseUrl}/api/public/qrcode'),
                  width: 200,
                  height: 200,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.image_not_supported,
                    size: 64,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// **可点**一行（左标签 + 右箭头）—— [_InfoRow] 的「入口」版本。
///
/// # 与 [_InfoRow] 的关系
///
/// 两者**同族**：同一字号（[_kBodyFontSize]）、同一条左右基线、同样的 `vertical: 9` 行距，
/// **左列文字用同一个颜色**（`ink`）。差别只有右侧：
///
/// | | 读法 | 右侧 |
/// |---|---|---|
/// | `_InfoRow` | 「这个字段的**值**是…」（只读信息） | `ink3` 文字（如「0.1.0」） |
/// | `_LinkRow` | 「点这里**进去**」（入口） | 强调色 + **箭头** |
///
/// 🔑 **左列必须同色**，否则相邻两组会「一浅一深、对不齐」——
///    原实现正是这样（`_InfoRow` 的标签是 `ink3`，本类是 `ink`），
///    白哥 2026-09-29 的「乱七八糟」里就有这一条。
///    判据：**同一个位置（左列）只该有一种颜色**；层级差异放在**右侧**表达。
///
/// 🔑 为什么用一个新类而不是给 `_InfoRow` 加 `onTap` 参数：
///    两者的**视觉契约不同**（值 vs 入口），混在一个类里要靠
///    `onTap == null` 分支去切两套观感 —— 那正是「同一组件两副面孔」的开始。
///    分成两个小类，各自的意图是**单一**的。
///
/// 🔑 右侧用**箭头图标**而不是文字「查看」：箭头是「可进入」的通用符号，
///    且不占横向空间（本页信息行的右侧已经可能出现长值，如备案号）。
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final accent = Color(t.accent.argb32);

    return InkWell(
      // 顶栏「返回」用的也是 `InkWell` —— 本页既有的可点元素就这一种做法
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: _kBodyFontSize,
                color: Color(t.ink.argb32),
              ),
            ),
            const Spacer(),
            // 箭头也用强调色 —— 「能点」这件事由**颜色 + 符号**同时表达
            Icon(Icons.chevron_right, size: 20, color: accent),
          ],
        ),
      ),
    );
  }
}

/// 「字段名 — 值」一行（只读信息）。
///
/// # 颜色分工：左 `ink`（深）/ 右 `ink3`（浅）
///
/// 即 iOS 设置的通行做法（左黑右灰）。
///
/// 🔴 2026-09-29 **反过来过**：原实现是「左 `ink3` 浅 / 右 `ink` 深」（表单回显的写法）。
///    改过来的理由不是审美偏好，而是**与 [_LinkRow] 对齐** ——
///    两类的**左列在视觉上必须是同一条线**，否则相邻两组一浅一深地看着乱。
///
/// # 🔴 [labelWidth] **必填** —— 三行必须共用同一个列宽
///
/// 不传它（或各行传不同的值）→ label 回到「内容宽」→ 三行的值起点再次错开。
/// 📄 实测数据（值左边界 2025 / 1997 / 2011）与推导见**文件头「第三轮」**。
///
/// ⚠️ 与 [_LinkRow] 是**两个类**，别合并 —— 理由见 [_LinkRow] 的文档。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.labelWidth,
    required this.label,
    required this.value,
  });

  /// label 列的**共用宽度**（调用方用 [_measureLabelColumn] 实测传入；同组各行必须相同）。
  final double labelWidth;

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              // 🔑 与量列宽用的是**同一个** style（[_labelStyle]）——
              //    两处各写一份的话，改了字体/字重后列宽会悄悄不准（不报错）。
              style: _labelStyle(t),
            ),
          ),
          // label 与值之间的**固定**间距。
          // 🔴 原来这里是 `Spacer()`（弹性空白）—— 正是它让三行的值起点
          //    跟着各自 label 的宽度漂。改成固定值才能得到「一条竖线」。
          const SizedBox(width: 12),
          // 🔑 值**左对齐**并占满剩余宽度 ⇒ 三行的值从**同一条竖线**开始。
          //    ⚠️ 不再用 `Flexible` + `TextAlign.right`（那是右对齐：右边界齐、起点不齐）。
          Expanded(
            child: Tw(
              value,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: _kBodyFontSize,
                color: Color(t.ink3.argb32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
