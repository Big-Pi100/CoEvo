import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'coevo_tokens.dart';
import 'tokens_ext.dart';

/// 粘土元素的交互态（spec §3.7）。
///
/// 🔑 粘土的物理直觉让状态表达**不需要换颜色、也不需要加边框** ——
/// 只靠「阴影的层数与方向」就够读懂：
enum ClayState {
  /// 默认 —— 三层齐全，读作「浮起」。
  raised,

  /// 按下 —— 换成**凹陷**公式（外阴影消失），读作「真的被压下去了」。
  pressed,

  /// 选中 —— **保持凸起** + 强调色填充 + 外阴影染强调色，读作「激活」。
  ///
  /// ⚠️ **选中 ≠ 按下**：前者是「它是活的」，后者是「它被按了」（spec §3.7 原文：
  /// 「选中＝激活，不是按下」）。
  selected,

  /// 禁用 —— **抽掉内亮** + 外阴影减半，读作「瘪了」。
  disabled,
}

/// 粘土绘制器 —— 把 `ClayTokens` + `ClayScale` 还原成 spec §3.2 的**三层阴影**。
///
/// # 为什么必须自绘（spec §7.1）
/// Flutter 的 `BoxShadow` **不支持 `inset`**，而粘土的核心恰恰是两个 inset。
/// 第三方包 `flutter_inset_box_shadow` 最新版停在 2022-04（已 4 年未更新），
/// 且要求 `hide BoxDecoration, BoxShadow` 替换整个类型（侵入性高）→ **不引入**。
///
/// # 做法（spec §7.2 第二步 · 与 Chromium 相同）
/// 1. 画一个**足够大的矩形**；
/// 2. 用圆角矩形在它上面做 `Path` 差集（`evenOdd`）→ 得到一个**环形**；
/// 3. 对环形 `MaskFilter.blur` —— 模糊是**双向**渗透的，会渗进圆角矩形**内部**；
/// 4. 渲染前 `clipRRect` 裁掉溢出部分 → 留在内部的半个模糊就是 **inset 阴影**。
///
/// 整体平移环形 = 阴影偏移；换颜色 = 内暗 / 内亮。
class ClayPainter extends CustomPainter {
  ClayPainter({
    required this.tokens,
    required this.state,
    this.fill,
    this.borderRadius,
    this.scaleOverride,
  });

  /// 当前档主题的**完整** token（粘土三参数 + 强调色 + 卡面色都在里面）。
  final CoEvoTokens tokens;

  final ClayState state;

  /// 元素填充色。
  ///
  /// 不传时：选中态取 `accent`，其余取 `clayFill`（getter → `card`，见 §3.3.2）。
  final CoRgba? fill;

  /// 显式圆角。不传则按 `clay.radiusFor(height)` 算（尺寸阶梯，§3.5）。
  final BorderRadius? borderRadius;

  /// 显式指定尺寸档。不传则按元素**真实高度**自动选（§3.5：
  /// 「阴影参数必须随元素尺寸缩放」）。
  final ClayScale? scaleOverride;

  static Color _color(CoRgba c) => Color(c.argb32);

  @override
  void paint(Canvas canvas, Size size) {
    final clay = tokens.clay;
    final rect = Offset.zero & size;

    final scale = scaleOverride ?? clay.scaleFor(size.height);
    final rrect = (borderRadius ?? BorderRadius.circular(clay.radiusFor(size.height)))
        .toRRect(rect);

    final isSelected = state == ClayState.selected;
    final body = fill ?? (isSelected ? tokens.accent : tokens.clayFill);

    // ① 填充先画 —— claymorphism 的填充色**与背景无关**（这是它与 Neumorphism
    //    的关键区别，§3.1）
    canvas.drawRRect(rrect, Paint()..color = _color(body));

    // 🔴 高度 < 24px 的元素**完全去掉 inset** —— 没空间表现高光（§3.5 硬规则）
    final withInset = size.height >= clayNoInsetBelow;

    switch (state) {
      case ClayState.raised:
      case ClayState.selected:
        // ② 外阴影**染元素自身的色相**（§3.2 规则 1）：
        //    彩色元素 → `accentOut`；中性色元素 → `out`
        //    （若彩色元素沿用 `out`，「格」档会出现冷灰阴影配暖朱砂 → 发脏，§3.3.1）
        _outer(canvas, rrect, isSelected ? clay.accentOut : clay.out, scale.outer);
        // ③ 内暗（体积）
        // ④ 内亮（充气）
        if (withInset) {
          _inset(canvas, rrect, clay.shade, scale.shade);
          _inset(canvas, rrect, clay.light, scale.light);
        }

      case ClayState.pressed:
        // 按下 = 凸起转**凹陷**：外阴影消失 + 两个 inset **方向互换**（§3.6）
        if (withInset) {
          _inset(canvas, rrect, clay.shade, scale.shade.flipped);
          _inset(canvas, rrect, clay.light, scale.light.flipped);
        }

      case ClayState.disabled:
        // 禁用 = **抽掉内亮**（只剩内暗）+ 外阴影减半（§3.7）
        _outer(canvas, rrect, clay.out.scaleAlpha(0.55), scale.outer);
        if (withInset) {
          _inset(canvas, rrect, clay.shade, scale.shade);
        }
    }
  }

  /// 外阴影 —— 用「偏移 + 模糊过的圆角矩形」表达（原生 `BoxShadow` 的做法）。
  void _outer(Canvas canvas, RRect rrect, CoRgba color, CoShadow s) {
    final paint = Paint()..color = _color(color);
    final sigma = _sigma(s.blur);
    if (sigma > 0) {
      paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma);
    }
    canvas.drawRRect(rrect.shift(Offset(s.dx, s.dy)), paint);
  }

  /// inset 阴影 —— 环形 + 模糊 + 裁剪（原理见类文档）。
  void _inset(Canvas canvas, RRect rrect, CoRgba color, CoShadow s) {
    final delta = Offset(s.dx, s.dy);
    final sigma = _sigma(s.blur);
    final paint = Paint()..color = _color(color);
    if (sigma > 0) {
      paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma);
    }

    canvas.save();
    // ① 只保留圆角矩形**内部** —— 于是模糊渗进来的那半个才成为 inset 阴影
    canvas.clipRRect(rrect);
    // ② 「大矩形 − 平移后的圆角矩形」= 环形（evenOdd 让中间成为空洞）
    final ring = Path()
      ..fillType = ui.PathFillType.evenOdd
      ..addRect(rrect.outerRect.shift(delta).inflate(s.blur + 40))
      ..addRRect(rrect.shift(delta));
    canvas.drawPath(ring, paint);
    canvas.restore();
  }

  /// `blurRadius` → `MaskFilter` 的 sigma。
  ///
  /// 用与 Flutter 原生 `BoxShadow` 相同的换算（`blur × 0.57735 + 0.5`），
  /// 保证自绘阴影与 Material 组件的阴影**视觉一致**，不会两种「模糊味」。
  static double _sigma(double blur) => blur <= 0 ? 0 : blur * 0.57735 + 0.5;

  @override
  bool shouldRepaint(ClayPainter old) =>
      !identical(old.tokens, tokens) ||
      old.state != state ||
      old.fill != fill ||
      old.borderRadius != borderRadius ||
      !identical(old.scaleOverride, scaleOverride);
}

/// 粘土容器 —— 把 [ClayPainter] 接成可直接使用的 widget。
///
/// - **尺寸档**默认按自身高度自动选（§3.5），高度 < 24px 自动去掉 inset
/// - 传 [onTap] 即成为可点元素，并自动带上按下动效（spec §3.8：
///   「**缺了动效，粘土只是个圆角卡片**」）
/// - 高度 / 宽度请由调用方用 `SizedBox` 等约束 —— 本组件不自带尺寸，
///   这样「按真实高度选档」才准确
///
/// ```dart
/// Clay(
///   onTap: () {},
///   padding: const EdgeInsets.all(CoSpacing.lg),
///   child: const Text('开始复习'),
/// )
/// ```
class Clay extends StatefulWidget {
  const Clay({
    super.key,
    required this.child,
    this.state = ClayState.raised,
    this.onTap,
    this.tokens,
    this.fill,
    this.borderRadius,
    this.scaleSize,
    this.padding,
  });

  final Widget child;

  /// 显式指定 token 档。
  ///
  /// 不传时从 [CoEvoTokensExt.of] 取**当前主题档**；
  /// 传了就用它 —— 用途是「**预览其它档**」：比如设置页要用「墨」的粘土参数
  /// 画一块「夜」的预览，就必须把那一档的 token 递进来，
  /// 否则预览块会跟着当前主题变，失去比较意义。
  final CoEvoTokens? tokens;

  /// 当前态。配合 `setState` 切换（或由父层控制）。
  final ClayState state;

  /// 若不为空 → 成为可点元素（自动处理按下态 + `scale(.97)` 回弹）。
  final VoidCallback? onTap;

  final CoRgba? fill;
  final BorderRadius? borderRadius;

  /// 强制尺寸档；不传则按元素真实高度自动选（§3.5）。
  final ClaySize? scaleSize;

  final EdgeInsetsGeometry? padding;

  @override
  State<Clay> createState() => _ClayState();
}

class _ClayState extends State<Clay> {
  bool _pointerDown = false;

  /// 按下动效参数（spec §3.8）：按下 90ms `ease-out`；松手 320ms **elasticOut** 回弹。
  static const Duration _pressMs = Duration(milliseconds: 90);
  static const Duration _releaseMs = Duration(milliseconds: 320);

  bool get _disabled => widget.state == ClayState.disabled;
  bool get _interactive => widget.onTap != null && !_disabled;

  ClayState get _effective {
    if (_disabled) return ClayState.disabled;
    if (_pointerDown && _interactive) return ClayState.pressed;
    return widget.state;
  }

  @override
  Widget build(BuildContext context) {
    // 🔑 默认取**当前主题档**；显式传入时用它（见 [Clay.tokens] 的预览场景）
    final active = widget.tokens ?? CoEvoTokensExt.of(context);

    Widget surface = CustomPaint(
      painter: ClayPainter(
        tokens: active,
        state: _effective,
        fill: widget.fill,
        borderRadius: widget.borderRadius,
        scaleOverride: widget.scaleSize == null
            ? null
            : ClayScales.bySize(widget.scaleSize!),
      ),
      child: Padding(
        padding: widget.padding ?? EdgeInsets.zero,
        child: widget.child,
      ),
    );

    if (_disabled) {
      // §3.7：禁用 = opacity .5（整元素变淡，含子内容）
      surface = Opacity(opacity: 0.5, child: surface);
    } else if (_interactive) {
      surface = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pointerDown = true),
        onTapUp: (_) => setState(() => _pointerDown = false),
        onTapCancel: () => setState(() => _pointerDown = false),
        onTap: widget.onTap,
        child: surface,
      );
    }

    return AnimatedScale(
      scale: (_pointerDown && _interactive) ? 0.97 : 1.0,
      duration: _pointerDown ? _pressMs : _releaseMs,
      curve: _pointerDown ? Curves.easeOut : Curves.elasticOut,
      child: surface,
    );
  }
}
