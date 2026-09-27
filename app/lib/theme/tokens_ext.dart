import 'package:flutter/material.dart';

import 'coevo_tokens.dart';

/// 把 [CoEvoTokens] 挂进 `ThemeData.extensions` ——
/// 让组件树里任何地方都能用 `CoEvoTokensExt.of(context)` 取到**当前档**的 token。
///
/// # 为什么需要这个桥接
/// `coevo_tokens.dart` 刻意**零 Flutter 依赖**（可用纯 Dart 跑 `tokens_verify`），
/// 所以 `CoEvoTokens` **不能**直接 `extends ThemeExtension`（那要 `package:flutter`）。
/// 本文件只做一件事：把 token 塞进主题，让组件侧按 `context` 取 ——
/// **不必让每个调用点都把 tokens 一路传下去**（那样容易传错档）。
///
/// 用法：
/// ```dart
/// final t = CoEvoTokensExt.of(context);
/// color: Color(t.accent.argb32),
/// ```
class CoEvoTokensExt extends ThemeExtension<CoEvoTokensExt> {
  const CoEvoTokensExt(this.tokens);

  final CoEvoTokens tokens;

  /// 取当前主题档的 token。
  ///
  /// 🔴 取不到时**抛错而不是回退** —— 静默回退到某一档会掩盖接线错误
  /// （「写了但没接上」正是本项目反复踩的坑）。
  static CoEvoTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<CoEvoTokensExt>();
    assert(
      ext != null,
      '当前主题缺少 CoEvoTokensExt —— 检查 buildTheme() 是否把它放进了 extensions',
    );
    return ext!.tokens;
  }

  @override
  CoEvoTokensExt copyWith({CoEvoTokens? tokens}) =>
      CoEvoTokensExt(tokens ?? this.tokens);

  /// 主题切换过渡 —— 把两档 token 真正**插值**（spec §3.8：280ms「背景/文字/阴影/圆角同过渡」）。
  ///
  /// 🔑 **为什么不能是阶跃**（`t < 0.5 ? this : other`）：
  /// `ThemeData.lerp` 会把 `colorScheme` / `scaffoldBackgroundColor` 等**平滑插值**，
  /// 而 `ThemeExtension` 若在 t=0.5 一次性切换 → 用 token 取色的组件（如粘土）
  /// 会在过渡中途**「啪」地跳变**，与周围平滑渐变的背景不协调。
  ///
  /// 插值策略见 [CoEvoTokens.lerp]：**颜色与字号插值，几何与枚举整组阶跃**
  /// （几何是派生量的输入，插值会造成更难看的不连续 —— 依据见 `coevo_tokens.dart` 文件头 ⓪）。
  @override
  CoEvoTokensExt lerp(ThemeExtension<CoEvoTokensExt>? other, double t) {
    if (other is! CoEvoTokensExt) return this;
    return CoEvoTokensExt(CoEvoTokens.lerp(tokens, other.tokens, t));
  }
}
