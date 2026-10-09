import 'package:flutter/material.dart';

import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 划词菜单的一项。
class SelectionMenuItem {
  const SelectionMenuItem({
    required this.label,
    required this.icon,
    this.onTap,
    this.disabledHint,
  });

  /// 标签 —— **保持 2 字**。
  ///
  /// 🔑 第一项在「查词」「翻译」之间切换（由 `classifyPicked` 决定），
  /// 两者都是 2 字 ⇒ **菜单宽度不随内容变形**（锚点 §5「形态稳定」）。
  final String label;

  /// 图标 —— 用 Material **outlined** 系列（细线，对应锚点「细线与描边用亮调」）。
  final IconData icon;

  /// 点击行为。`null` ⇒ **置灰**。
  final VoidCallback? onTap;

  /// 置灰时点击要说什么（`null` ⇒ 点了没有反应）。
  ///
  /// 🔴 给了文案就必须弹出来 —— 本项目判据：**「静默失败」比报错更糟**。
  final String? disabledHint;

  bool get enabled => onTap != null;
}

/// 划词菜单 —— 浮在选区旁的横向胶囊（L1 锚点 `visual-selection-menu-2026-10-07.html` §2）。
///
/// # 🔴 本组件**只负责「长什么样」**，而且**必须被包着用**
///
/// 它挂在 `SelectionArea` 的 `contextMenuBuilder` 上。框架只做两件事：
/// **把返回值插进 Overlay** + **给出锚点**（`SelectableRegionState.contextMenuAnchors`）。
/// 它**不做**约束放松、也**不做**定位 —— 那两件必须由**调用方**补上：
/// `CustomSingleChildLayout` + `TextSelectionToolbarLayoutDelegate`
/// （落地处见 `word_lookup_selection.dart` 的 `_buildMenu`）。
///
/// 🔴🔴 **直接 `return SelectionMenu(...)` 会白屏**（2026-10-08 白哥真机踩到）：
///    Overlay 给**非定位 entry** 的约束是 `BoxConstraints.tight(size)`
///    （**全屏紧约束**，SDK 原注释「Equivalent to … `StackFit.expand`」），
///    而 `ConstrainedBox` / `SizedBox` 这类**放松不掉**它（`enforce` 遇更紧的父约束
///    只会**更紧**）⇒ 本组件被撑成**全屏**，它的实心底 `card` 色就盖住整屏
///    （墨/格档的 `card` 是白色 ⇒ 用户看到的就是「白屏」）。
///    ✅ 只有 `TextSelectionToolbarLayoutDelegate.getConstraintsForChild → loosen()`
///       那条路能解除它 —— 那也正是**框架自带菜单**走的路。
///
/// 📌 判据：**「框架负责位置」≠「框架负责约束」** ——
///    这里过去写「位置 / 翻转 / 夹紧**都是**框架行为」，那句是**错的**，已回标。
///
/// （「点外部收起」**确实**是框架行为：`_SelectionToolbarWrapper` 包了
///  `TapRegion(groupId: SelectableRegion)`。）
///
/// # 🔴 零粘土（spec §〇 规则 2：「阅读界面零粘土」）
///
/// 菜单浮在**正文之上** ⇒ 它属于**阅读界面** ⇒ **不加粘土内阴影**。
/// 依据与 `LookupSheet` 完全同一条 —— 那份的实现注释写着
/// 「用 `card` 底 + 轻阴影表达层级，不用粘土（粘土是「交互」语汇）」。
///
/// 🔴⚠️ **本组件修正了锚点 §2 的一处错误**：那份稿子原文写
///    「内阴影 `inset -3 -3 8` / `inset 3 3 7`（md 档 · 体积）」——
///    这与 spec §〇 规则 2 **直接冲突**。先读了 spec 才动手，故此处**按 spec**；
///    锚点的规格表与 CSS 已同步更正为「无内阴影」。
///    📌 判据：**设计稿与 spec 冲突时按 spec**（本项目既有规则）。
///
/// ⇒ 本组件的材质 = **`card` 底 + 圆角 + 一层外阴影**：无内阴影、无「厚度」内边距。
class SelectionMenu extends StatelessWidget {
  const SelectionMenu({super.key, required this.items});

  final List<SelectionMenuItem> items;

  /// 圆角系数 —— 锚点 §2 的值（墨 `26 × 0.55 = 14.3` · 夜 `24 × 0.55 = 13.2`）。
  ///
  /// 🔑 「格」档**不缩放**（`clay.scaleRadius == false`）：它的 14px 本身就是目标值，
  /// 再乘一次会得 7.7px。见 `ClayTokens.scaleRadius` 的说明。
  static const double _radiusFactor = 0.55;

  /// 分隔线高度（锚点 §2：`1px × 18px`）。
  static const double _dividerHeight = 18;

  /// 外阴影 —— **只有一层**（见类文档的「零粘土」）。
  ///
  /// 颜色用 `clay.out`（**中性色元素**的主题级外阴影，与卡面同色系）；
  /// 不用 `accentOut` —— 那是彩色元素（朱砂按钮）用的，菜单是中性色面。
  static const double _shadowBlur = 16;
  static const Offset _shadowOffset = Offset(0, 6);

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final radius =
        t.clay.scaleRadius ? t.clay.radius * _radiusFactor : t.clay.radius;

    final row = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) {
        row.add(Container(
          width: 1,
          height: _dividerHeight,
          color: Color(t.line.argb32),
        ));
      }
      row.add(_MenuButton(item: items[i]));
    }

    return ConstrainedBox(
      // 选区贴屏幕边时不溢出（锚点 §3「夹紧」）。
      // 🔑 框架管菜单的**位置**，但**自身宽度**的兜底必须由我们给 ——
      //    「框架负责 X」不等于「X 的所有方面都不用管」。
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 24,
      ),
      child: Material(
        // `InkWell` 需要 Material 祖先；菜单本身是卡面，故透传（颜色由下面 Container 给）。
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Color(t.card.argb32),
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Color(t.clay.out.argb32),
                blurRadius: _shadowBlur,
                offset: _shadowOffset,
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: row),
        ),
      ),
    );
  }
}

/// 菜单里的一项（图标 + 2 字标签）。
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.item});

  final SelectionMenuItem item;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final enabled = item.enabled;

    // 锚点 §2：图标用 `accentBright`（**细线与描边**用亮调），文字用 `ink`
    // ——「三个项都染红会互相争夺注意力」。
    // 置灰时两者一起降到 `ink3`（弱文字）：**形状不变、只降对比度**。
    final iconColor = Color(enabled ? t.accentBright.argb32 : t.ink3.argb32);
    final textColor = Color(enabled ? t.ink.argb32 : t.ink3.argb32);

    return InkWell(
      onTap: enabled ? item.onTap : _disabledTap(context),
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        // 锚点 §2：项内 `8px 12px`；图标 15px + 间距 6px；文字 12.5 / w500。
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, size: 15, color: iconColor),
            const SizedBox(width: 6),
            Text(
              item.label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 置灰项的点击 —— **不能静默**（本项目判据：「静默失败」比报错更糟）。
  VoidCallback? _disabledTap(BuildContext context) {
    final message = item.disabledHint;
    if (message == null) return null;
    return () {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ));
    };
  }
}
