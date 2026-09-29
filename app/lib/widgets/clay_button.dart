import 'package:flutter/material.dart';

import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'twemoji.dart';

/// 粘土强调按钮 —— 页面里的**动作 CTA**（「续费」·「支付」…）。
///
/// # 为什么要有这个组件（而不是直接用 Material `FilledButton`）
///
/// 规格 §6.1 的组件清单把「**主/次按钮**」明确列为**粘土**元素：
///
/// > | 交互 | 粘土 | 卡片、**按钮**、标签、排序药丸、徽章、进度环 |
///
/// 而 Material 的 `FilledButton` 自带一整套**另一套体系**的观感 ——
/// 它的圆角、阴影、按下反馈（水波纹 + 底色变暗）都与粘土语言不同源：
/// 粘土按下是 **`scale(.97)` 压下去 + 松手弹回**（§3.8），
/// 而它既没有 `accentOut` 那层「染了自身色相」的外阴影，
/// 也没有内暗/内亮那对体积感。放在一堆粘土卡片中间会读作
/// 「**这不是这个体系里的东西**」。
///
/// # 🔴 为什么用 `ClayState.selected`，而不是 `raised` + 显式 `fill: accent`
///
/// 两者看起来等价（都是「accent 填充 + 保持凸起」），**其实不等价**：
/// §3.2 规则 1 要求「外阴影**染元素自身的色相**」——
///
/// | 写法 | 填充 | 外阴影 | 结果 |
/// |---|---|---|---|
/// | `selected` | `accent` ✅ | `clay.accentOut` ✅ | 正确 |
/// | `raised` + `fill` | `accent` ✅ | `clay.out`（**中性灰**）❌ | 「格」档**冷灰阴影配暖朱砂 → 发脏**（§3.3.1） |
///
/// → `ClayPainter` 里 `isSelected` 同时决定这两件事，绕过它就必然写错其中一件。
///   **所以这里借用的是它的「视觉定义」，与「选中/激活」的业务含义无关** ——
///   本按钮是**无状态**的，它不表达「已选中什么」。
///
/// # 尺寸
///
/// **不传** `borderRadius` 也不传 `scaleSize` → 让 `Clay` 按元素**真实高度**
/// 自动选档（§3.5「阴影参数必须随元素尺寸缩放」）。
/// 视觉高度 ≈ `12.5 × 1.4 + 7 × 2 ≈ 31.5px` → **sm 档**（24–40px）。
///
/// ⚠️ 也**不要**硬写 `borderRadius`：那会**跳过尺寸阶梯**，
/// 让「格」档拿不到它那个「不参与缩放」的例外（§3.5.1）。
///
/// # ⚠️ 已知缺口：点击区 < 44px
///
/// 规格 §6.1 对「图标按钮」注明「最小点击区 44×44」，
/// 本组件（与复习页的排序药丸、底部 tab 一样）**点击区 = 视觉区 ≈ 31.5px**。
/// 这是**现状的共性缺口**，不是本组件特有；若要补，应三处一起补（否则又不一致）。
class ClayButton extends StatelessWidget {
  const ClayButton({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.expanded = false,
  });

  /// 按钮文案。
  ///
  /// 用 `String`（内部经 `Tw` 渲染）而非 `Widget` —— 字号/字重/字色是
  /// **本组件的视觉契约**，不该由调用方各自覆盖（那正是「不一致」的来源）。
  final String label;

  /// 点击回调。**必填** —— 没有「不可点」的态；
  /// 若将来要 disabled/loading，应显式加参数并用 `ClayState.disabled`，
  /// 而不是传 `null` 让它静默变成一块不能点的粘土。
  final VoidCallback onTap;

  /// **可用性**（2026-09-29 新增）。`false` = 提交中 / 条件未满足。
  ///
  /// 走 `ClayState.disabled`（§3.7：**抽掉内亮** + 外阴影减半 + `opacity .5`）
  /// 而**不是**把 `onTap` 置空 —— `Clay` 内部 `_interactive` 已经是
  /// `onTap != null && !_disabled`，所以传 `disabled` 时点击**自动无效**。
  ///
  /// ⚠️ 这与上一条注释里说的「将来要 disabled 时显式加参数」是同一次动作：
  ///    因为「条件未满足」已经出现（登录弹窗里提交中要防重复提交），
  ///    所以现在补，而不是等到有调用方去 hack。
  final bool enabled;

  /// **撑满可用宽度**（2026-09-29 新增）。弹窗里的主 CTA 需要通栏。
  ///
  /// 实现上包一层 `SizedBox(width: double.infinity)` + 内部 `Row(max)` 居中 ——
  /// 🔑 只给 `Clay` 一个 `width: infinity` 的外层约束**不够**：
  ///    `Clay` 的 `CustomPaint` 尺寸取自 **child**，
  ///    而 child（`Tw`）是自然宽 → 整块按钮仍然只有文字那么宽。
  ///    必须让**最内层**也撑开（`Row(mainAxisSize: max)`），居中由它负责。
  ///
  /// ⚠️ 只能在**有确定宽度**的父里用（`Column` / `ListView` ✅）；
  ///    放进 `Row` 这类**宽度无界**的父会因 `double.infinity` 布局报错。
  final bool expanded;

  /// 横向 14 给文字留出呼吸，纵向 7 使高度落在 sm 档中段。
  static const EdgeInsets _padding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 7);

  @override
  Widget build(BuildContext context) {
    // 从当前主题档取 token：字色必须与 `Clay` 用的填充**同档**，
    // 否则「格」档下会拿「墨」的 accentInk 去压「格」的 accent。
    final t = CoEvoTokensExt.of(context);

    final text = Tw(
      label,
      style: TextStyle(
        fontFamily: CoFonts.uiSans,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        // `accentInk` = 「压在 accent 上的字色」（token 表原文），
        // 不是把 accent 调亮 —— 对比度由 token 保证。
        color: Color(t.accentInk.argb32),
      ),
    );

    final button = Clay(
      // 🔴 先判 `enabled`：禁用与选中**互斥**（`ClayPainter` 里 `disabled`
      //    是独立分支）。写反了按钮会「看着能点、点不动」—— 正是 §🆕 那条
      //    「视觉元素的形态须与语义一致」要避免的。
      state: enabled ? ClayState.selected : ClayState.disabled,
      // ⚠️ 禁用时**照样把 onTap 传下去**（不是置 null）：
      //    `Clay` 内部 `_interactive = onTap != null && !_disabled` 已经挡掉了，
      //    而置 null 会让「为什么点不动」变得需要读两层代码才能解释。
      onTap: onTap,
      padding: _padding,
      // 撑宽时居中的责任在**最内层**（见 [expanded] 的说明）
      child: expanded
          ? Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [text],
            )
          : text,
    );

    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}
