import 'package:flutter/material.dart';

import 'coevo_tokens.dart';
import 'tokens_ext.dart';

/// token → `ThemeData` 的**唯一入口**（spec §7.3）。
///
/// 🔴 **不要写 3 个手写的 `ThemeData`** —— 三档主题的全部差异只能来自
/// [CoEvoTokens]。任何「某一档要特殊一点」的需求，都必须先回到 token 层
/// （`coevo_tokens.dart`）加字段，**不许在调用处 if 分支**。
///
/// 用法：
/// ```dart
/// buildTheme(allTokens[ReadingTheme.ink]!)
/// ```
///
/// 📌 **本文件负责的是「Material 组件语义 ← token 语义」的映射**，
/// 不承担视觉决策 —— 颜色/圆角/字号全部来自 token。
/// 卡片内部的排版（单词 32 / 释义 16.5 / …）由 `CoTypography` 直接给组件用，
/// **不进 `textTheme`**（那是界面层级，两套体系别混）。
ThemeData buildTheme(CoEvoTokens t) {
  final isNight = t.theme == ReadingTheme.night;
  final brightness = isNight ? Brightness.dark : Brightness.light;
  final scheme = _colorScheme(t, brightness);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    // 🔑 把 token 挂进主题 —— 组件侧用 `CoEvoTokensExt.of(context)` 取当前档，
    //    不必把 tokens 一层层传下去（粘土组件、卡片都要用）。
    extensions: <ThemeExtension<dynamic>>[CoEvoTokensExt(t)],
    scaffoldBackgroundColor: _c(t.page),
    canvasColor: _c(t.page),
    dividerColor: _c(t.line),
    textTheme: _textTheme(scheme),
    iconTheme: IconThemeData(color: _c(t.ink2)),

    // ── 顶栏 ──
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: _c(t.page),
      foregroundColor: _c(t.ink),
      iconTheme: IconThemeData(color: _c(t.ink2)),
    ),

    // ── 卡面 ──
    // 🔑 填充色用 `card`（= `clayFill`），圆角用主题级 `clay.radius`
    cardTheme: CardThemeData(
      elevation: 0,
      color: _c(t.card),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.clay.radius),
      ),
    ),

    // ── 输入 ──
    // 🔑 凹陷底 `sunken` —— 输入框在语义上就是「凹进去的一块」，
    //    与粘土的内暗用同一个 token，视觉体系一致
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: _c(t.sunken),
      hintStyle: TextStyle(color: _c(t.ink3), fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      border: _inputBorder(t, t.line),
      enabledBorder: _inputBorder(t, t.line),
      focusedBorder: _inputBorder(t, t.accent, width: 1.6),
      errorBorder: _inputBorder(t, t.accent),
      focusedErrorBorder: _inputBorder(t, t.accent, width: 1.6),
    ),

    // ── 按钮 ──
    // 🔴 主按钮 = 实心 `accent` + 压 `accentInk`（spec §2.1：accent 是「实心填充」用）
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _c(t.accent),
        foregroundColor: _c(t.accentInk),
        disabledBackgroundColor: _c(t.sunken),
        disabledForegroundColor: _c(t.ink3),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.clay.radius),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: _c(t.accent),
        foregroundColor: _c(t.accentInk),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.clay.radius),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: _c(t.accent),
        side: BorderSide(color: _c(t.accentBright), width: 1.4),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.clay.radius),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _c(t.accent),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: _c(t.accent),
      foregroundColor: _c(t.accentInk),
      elevation: 0,
      highlightElevation: 0,
    ),

    // ── 底部导航（3 tab）──
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: _c(t.card),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorColor: _c(_tint(t.accent, 0.16)),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: _c(t.accent));
        }
        return IconThemeData(color: _c(t.ink3));
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            color: _c(t.accent),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          );
        }
        return TextStyle(
          color: _c(t.ink3),
          fontWeight: FontWeight.w500,
          fontSize: 12,
        );
      }),
    ),

    // ── 弹层 ──
    dialogTheme: DialogThemeData(
      backgroundColor: _c(t.card),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.clay.radius * 0.6),
      ),
      titleTextStyle: TextStyle(
        color: _c(t.ink),
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: TextStyle(color: _c(t.ink2), fontSize: 15, height: 1.5),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: _c(t.card),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(t.clay.radius * 0.6),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: _c(t.ink),
      contentTextStyle: TextStyle(color: _c(t.page), fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: _c(t.card),
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? _c(t.accentInk) : _c(t.card)),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? _c(t.accent) : _c(t.sunken)),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? null : _c(t.line)),
    ),
    dividerTheme: DividerThemeData(color: _c(t.line), thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: _c(t.ink2),
      textColor: _c(t.ink),
      subtitleTextStyle: TextStyle(color: _c(t.ink2), fontSize: 13),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: _c(t.accent),
      linearTrackColor: _c(t.sunken),
      circularTrackColor: _c(t.sunken),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: _c(t.sunken),
      selectedColor: _c(_tint(t.accent, 0.16)),
      labelStyle: TextStyle(color: _c(t.ink2), fontSize: 13),
      side: BorderSide(color: _c(t.line)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  );
}

// ─────────────────────────────────────────────────────────────
// 内部映射
// ─────────────────────────────────────────────────────────────

Color _c(CoRgba c) => Color(c.argb32);

/// 取同色相的淡色（选中底、指示器等）。
///
/// 🔑 不用 `Color.withOpacity`（已废弃）也不用 `withValues`（SDK 版本敏感）——
/// 直接在 [CoRgba] 上改 alpha，语义最直白。
CoRgba _tint(CoRgba c, double alpha) => CoRgba(c.r, c.g, c.b, alpha);

OutlineInputBorder _inputBorder(CoEvoTokens t, CoRgba color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: _c(color), width: width),
    );

/// token → M3 `ColorScheme` 的映射表（**集中在一处，便于逐条核对**）。
///
/// 🔑 先用 `fromSeed` 生成**完整** scheme（避免漏字段导致组件取到 Material 默认紫），
/// 再逐条覆盖 —— 覆盖项就是下面这些「有 token 对应」的槽位。
ColorScheme _colorScheme(CoEvoTokens t, Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: _c(t.accent),
    brightness: brightness,
  );

  return base.copyWith(
    // 强调（实心填充）
    primary: _c(t.accent),
    onPrimary: _c(t.accentInk),
    primaryContainer: _c(t.sunken),
    onPrimaryContainer: _c(t.ink),
    // 强调（亮调 / 描边）
    secondary: _c(t.accentBright),
    onSecondary: _c(t.accentInk),
    secondaryContainer: _c(t.sunken),
    onSecondaryContainer: _c(t.ink),
    tertiary: _c(t.accentBright),
    onTertiary: _c(t.accentInk),
    // 纸面层级
    surface: _c(t.card),
    onSurface: _c(t.ink),
    onSurfaceVariant: _c(t.ink2),
    surfaceContainerLowest: _c(t.page),
    surfaceContainerLow: _c(t.page),
    surfaceContainer: _c(t.read),
    surfaceContainerHigh: _c(t.card),
    surfaceContainerHighest: _c(t.sunken),
    // 反向（SnackBar 等）
    inverseSurface: _c(t.ink),
    onInverseSurface: _c(t.page),
    inversePrimary: _c(t.accentBright),
    // 线与阴影
    outline: _c(t.ink3),
    outlineVariant: _c(t.line),
    shadow: _c(t.clay.out),
    // 模态遮罩跟着主题走（浅色档用暖褐遮罩，纯黑会「发脏」）
    scrim: _c(_tint(t.ink, brightness == Brightness.dark ? 0.72 : 0.48)),
  );
}

/// 界面字号层级（**不是卡片层级** —— 卡片层级见 [CoTypography]）。
///
/// 中文字体用 [CoFonts.cjk]（已打进包）；英文正文/音标由组件**元素级**指定，
/// 这里不挂 `latinFallback`（见 `CoFonts` 的警告）。
TextTheme _textTheme(ColorScheme scheme) {
  const family = CoFonts.cjk;

  TextStyle s(double size, FontWeight weight, {double height = 1.4}) =>
      TextStyle(fontFamily: family, fontSize: size, fontWeight: weight, height: height);

  return TextTheme(
    headlineLarge: s(28, FontWeight.w600, height: 1.25),
    headlineMedium: s(24, FontWeight.w600, height: 1.3),
    headlineSmall: s(20, FontWeight.w600),
    titleLarge: s(18, FontWeight.w600),
    titleMedium: s(16, FontWeight.w500),
    titleSmall: s(14, FontWeight.w500),
    bodyLarge: s(16, FontWeight.normal, height: 1.5),
    bodyMedium: s(14, FontWeight.normal),
    bodySmall: s(12, FontWeight.normal, height: 1.35),
    labelLarge: s(14, FontWeight.w500),
    labelMedium: s(12, FontWeight.w500),
    labelSmall: s(11, FontWeight.normal, height: 1.3),
  ).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
}
