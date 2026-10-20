/// 弹层外壳 —— 全应用**唯一**一处定义「弹窗长什么样」。
///
/// # 为什么要抽（而不是每个弹窗自己写一遍）
///
/// 「我的」页原有 **5 个** Material 弹窗（`AlertDialog` / `SimpleDialog`）。
/// 如果把它们逐个改成「透明 `Dialog` + 平面卡」，会有 **5 份**几乎相同的
/// `Container` + `BoxDecoration` + `boxShadow` + `padding` ——
/// 这正是 `HeaderChip` 注释里说的那种「今天参数完全相同，下次改一处就静默走偏」。
///
/// 🔑 **「外观一致」最可靠的实现方式 = 只有一处定义。**
///
/// # 🔴 外壳是**平面**，不是粘土（spec §〇 规则 1）
///
/// > **内容平面 / 交互粘土 / 输入凹陷** —— 文字永不动；**有体积的只可能是可点的东西**
///
/// 弹窗本身**不可点** → 它是「浮起来的平面」（`card` 底 + 外阴影），
/// 不是一块凸起的粘土。壳里的**输入框是凹陷**（`ClayField`）、
/// **按钮是粘土**（`ClayButton`）—— 三类元素各就各位。
///
/// 🔑 这与已有两个浮层先例一致：`_UnlockCard`（成就解锁）、`LookupSheet`（划词浮层）；
///    外阴影参数也照 `_UnlockCard` 抄，不另发明一套「浮层的模糊味」。
library;

import 'package:flutter/material.dart';

import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import 'twemoji.dart';

class CoDialog extends StatelessWidget {
  const CoDialog({
    super.key,
    required this.child,
    this.title,
    this.actions,
  });

  /// 正文内容。
  final Widget child;

  /// 标题（可选）。样式固定为原型第 ⑤ 屏的 `.lg h2`（20px / w600）。
  ///
  /// 🔑 `String` 而非 `Widget` —— 同 `ClayButton.label`：
  ///    字号 / 字重 / 字色是**本组件的视觉契约**，不该由调用方各自覆盖。
  final String? title;

  /// 底部按钮行（可选）。**每个元素会被 `Expanded` 平分宽度**（原型 `.lgbtn{flex:1}`）。
  ///
  /// 传 `ClayButton` 时请一并传 `expanded: true` ——
  /// `Expanded` 给的是「确定宽度」，而 `ClayButton` 内部还需要 `SizedBox(width: infinity)`
  /// 才能让**文字居中**（原因见 `ClayButton.expanded` 的注释）。
  final List<Widget>? actions;

  /// 手机上弹窗两侧留白。
  static const EdgeInsets _insetPadding =
      EdgeInsets.symmetric(horizontal: 28, vertical: 32);

  /// 弹出弹层。
  ///
  /// 🔑 **弹出方式也只该有一处定义**（遮罩浓度 · `insetPadding` · 是否可点外关闭）——
  ///    两个调用方各写一遍 `showDialog`，迟早在某个参数上走偏。
  static Future<T?> show<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: builder,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 🔴 `Dialog` 默认自带 `surfaceTint` 底色 + elevation 阴影 ——
    //    那套观感与「平面 + 凹陷 + 粘土」不同源。所以背景透明 + elevation 0，
    //    只留它**免费的路由能力**（遮罩 · 返回键关闭 · 键盘避让 · 居中）。
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: _insetPadding,
      child: CoDialogSurface(
        title: title,
        actions: actions,
        child: child,
      ),
    );
  }
}

/// 弹层的**内容外壳**（不含路由能力）。
///
/// # 🔴 为什么把它从 [CoDialog] 拆出来（2026-10-20）
///
/// 「订阅已到期」覆盖层挂在 `MaterialApp.builder` 的**顶层 Stack**（Navigator 之上），
/// **不能用 `showDialog`**（那个上下文查不到 GoRouter/Navigator —— 详见 `app.dart` 里
/// 那段「点击查看订阅没跳转」的根因记录）。
///
/// 但它原先自己手搓了一套 `Container(color: Colors.white) + Icons.lock + FilledButton`
/// ⇒ 深色主题下是**一块白板**，和粘土/朱砂体系完全脱节（白哥 2026-10-20 反馈「丑陋」）。
///
/// ✅ 正解：把**视觉外壳**抽成这个组件，两条路径共用 ——
///    · [CoDialog]（走 `showDialog` 的普通弹窗）
///    · 顶层覆盖层（`Center` 里直接放它）
/// ⇒ 仍然满足本文件开头那条判据：**「外观一致」= 只有一处定义**。
///
/// 📌 判据：**「不能用 Dialog 路由」不等于「可以另写一套外观」** ——
///    该拆的是**外壳**，不是让它分叉。
class CoDialogSurface extends StatelessWidget {
  const CoDialogSurface({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.maxWidth = 360,
  });

  final Widget child;
  final String? title;
  final List<Widget>? actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        decoration: BoxDecoration(
          color: Color(t.card.argb32),
          borderRadius: BorderRadius.circular(20),
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
              if (title != null) ...[
                Tw(
                  title!,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    // 原型 `.lg h2{letter-spacing:-.02em}` → 这里换算成绝对字距
                    letterSpacing: -0.02 * 20,
                    color: Color(t.ink.argb32),
                  ),
                ),
                const SizedBox(height: CoSpacing.lg),
              ],
              child,
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: CoSpacing.xl),
                Row(
                  children: [
                    for (var i = 0; i < actions!.length; i++) ...[
                      // 原型 `.lgbtns{gap:9px}`
                      if (i > 0) const SizedBox(width: 9),
                      Expanded(child: actions![i]),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
