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

  /// 🔑 token 是**离散档位**（墨 / 格 / 夜），没有「中间值」可言 ——
  /// 不过半就保持原档，避免插值出第四种配色。
  ///
  /// 主题切换的观感过渡由 `MaterialApp` 自身的 280ms 动画承担。
  @override
  CoEvoTokensExt lerp(ThemeExtension<CoEvoTokensExt>? other, double t) {
    if (other is! CoEvoTokensExt) return this;
    return t < 0.5 ? this : other;
  }
}
