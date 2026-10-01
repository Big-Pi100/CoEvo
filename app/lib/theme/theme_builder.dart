// 🔴 **这一行是必需的**（理由见下方 `pageTransitionsTheme` 处的长注释）——
//    `CupertinoPageTransitionsBuilder` 这个类**换过家**：
//      · Flutter **3.41**：定义在 **material** 库（`src/material/page_transitions_theme.dart`）
//      · Flutter **3.47**：已迁到 **cupertino** 库（`src/cupertino/route.dart`）
//        （**迁移发生在哪一版未核实**，只确认了这两个端点的归属）
//    ⇒ 当时（CI 还是 3.47.5、本机 3.41.1）：
//        只 import material → CI 报 `isn't defined`（那次 CI 红的原因）
//        只 import cupertino → 本机报同样的错
//      ⚠️ 这是**历史成因**；CI 已于 2026-10-01 钉到 3.41.1（两边一致），
//        但**双 import 保留** —— 让代码对两个版本都成立。
//      **两个都 import → 两个版本都能解析** ✅（本机实测 0 error / 0 warning）
import 'package:flutter/cupertino.dart';
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

    // ── 页面转场：**全部平台统一用 iOS 的 Cupertino 转场** ─────────────────
    //
    // # 为什么（2026-09-28 白哥：「每个页面应该加上左滑退出」）
    //
    // 🔑 关键机制：**侧滑返回手势是「转场 builder」自带的，不是路由本身带的**。
    //    `CupertinoPageTransitionsBuilder.buildTransitions` 委托给
    //    `CupertinoRouteTransitionMixin.buildPageTransitions`，该方法内部包了
    //    `_CupertinoBackGestureDetector`（`flutter/lib/src/cupertino/route.dart:253`）
    //    → 换成这个 builder，页面**同时**获得「右滑入场 + 边缘右滑返回」。
    //
    // 🔴 而 Flutter 默认是**按平台分派**的（`material/page_transitions_theme.dart`
    //    的 `PageTransitionsTheme._defaultBuilders`；具体行号随版本变，别记死）：
    //      android → `PredictiveBackPageTransitionsBuilder`（**无 iOS 风格侧滑**）
    //      iOS/macOS → `CupertinoPageTransitionsBuilder`
    //    → 所以在 Android 上**天然测不到**这个手势。本产品只做 iOS，
    //      Android 是开发期的验证载体 → **必须统一**，否则「在 Android 上验 iOS 行为」
    //      这件事根本做不到（本项目已多次栽在「在错平台上验证」）。
    //
    // ⚠️ 代价（如实记录）：Android 用户会失去系统的预测性返回动画。
    //    Android 不是出货平台 → 可接受。若将来真出 Android 版，应改回
    //    `PredictiveBackPageTransitionsBuilder` 并单独验一遍手势。
    //
    // 🔴 **配套约束**：任何页面**不许**用 `CustomTransitionPage` 自定义转场 ——
    //    它不走本表，等于**把侧滑手势关掉**（`/article/:id` 与 `/chat` 原先就是
    //    这么写的，已改回 `builder:`）。这条有断言守着（`tokens_verify` §15）。
    //
    // 🔴 **为什么文件顶部要额外 import cupertino（2026-10-01 踩的坑）**
    //
    //    下表的 `CupertinoPageTransitionsBuilder` **换过家**：
    //      · Flutter 3.41（本机 SDK）：属 **material** 库
    //      · Flutter 3.47（CI 的 SDK）：已迁到 **cupertino** 库
    //    ⇒ 只 import material 时，CI 报
    //        `The function 'CupertinoPageTransitionsBuilder' isn't defined`
    //      + 连带 2 条（`Invalid constant value` / `non_constant_map_value`）——
    //      共 7 条 error，整条 frontend job 就卡在 analyze 这一步。
    //      （本机 3.41.1 **看不到**这个错：同一个名字本机由 material 提供 → 本地永远绿灯。）
    //    ✅ 修法：**两个库都 import** → 3.41 由 material 解析、3.47 由 cupertino 解析，
    //       两边都编译。已核实不会产生同名冲突（该文件用到的 36 个 material 名字，
    //       逐个查过 cupertino 文档，**零同名**）。
    //    ⚠️ 这是「**本机 SDK ≠ CI SDK**」的典型症状：本地绿、CI 红。
    //    ✅ **已根治（2026-10-01）**：CI 钉死到 **3.41.1**（= 项目 SDK 的版本），
    //       见 `.github/workflows/ci.yml` 的 `Setup Flutter`。此后两边同版本，
    //       上面那个「本地永远绿灯」的盲区不再存在。
    //       （本行的双 import 仍**保留** —— 它让代码对两个版本都成立，
    //        将来升级 SDK 时不会因为这个类再次编译不过。）
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),

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
      // 🔴 这一行让**每个**输入框在聚焦时都描一圈朱砂。
      //    若某处输入框不想要它（Clay 凹陷容器里的输入框），
      //    必须在**调用处**把 border 类字段**全部**设为 none ——
      //    只写 `border: InputBorder.none` 是**不够**的（focusedBorder 会继承下来）。
      //    ✅ 用 `borderlessInputDecoration()`（本文件下方，全库唯一一处）。
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

    // ── 底部导航 ──
    // ⚠️ 主 tabbar（`app.dart` 的 `_ClayTabBar`）已于 2026-09-27 **改为自绘粘土药丸** ——
    //    设计稿要求选中态是「强调色填充 + 实体投影」，M3 `NavigationBar` 表达不出来
    //    （`indicatorColor` 只能换颜色，改不了形状与材质）→ 当前**没有组件在用这份主题**。
    // 🔑 **仍然保留**：任何页面若引入 M3 `NavigationBar`（如二级 tab），
    //    颜色不会静默回落成 Material 默认紫 ——「写了但没接上」与「静默降级」
    //    都是本项目反复踩的坑，留一份正确的兜底比删掉更安全。
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

/// **「Clay 凹陷容器里的无框输入框」专用的 `InputDecoration`** —— 全库唯一一处。
///
/// # 🔴 为什么必须有它（2026-09-28 真机 Bug）
/// 上面的 `inputDecorationTheme` 给**全局**输入框定了
/// `focusedBorder = accent(#B4432C) 1.6px`（聚焦时描一圈朱砂）。
/// 而 `InputDecoration` 的 border 类字段是**各自独立**从 theme 继承的 ——
/// ```dart
/// InputDecoration(border: InputBorder.none)   // ❌ 只覆盖了 border
/// ```
/// 聚焦时 `InputDecorator` 取的是主题的 `focusedBorder` → **冒出朱砂色线框**。
/// 复习页搜索框（展开即自动聚焦）与复习测验输入框（`autofocus: true`）
/// 都**一下就到聚焦态** → 这个 Bug 是**必现**的，不是偶发。
///
/// 🔑 **判据：要「完全无边框」，必须把 border 类字段*全部*设为 `none`。**
///    留一个为 `null`，那个状态就会把主题的边框放回来。
///    （同 `HeaderChip` 那条教训：「**主题里有**」≠「**调用处已覆盖**」——
///      凡是主题级默认值，调用处都必须显式覆盖掉不想继承的那几项。）
///
/// # 为什么这两个输入框「不该有框」
/// 它们都嵌在 `Clay(state: pressed)` 里 —— 凹陷本身就是「这里可以输入」
/// 的视觉语言（粘土语汇：`pressed` = 可交互的容器）。
/// 再叠一圈描边 = **两套语汇打架**，也就是白哥报的「红色的线框」。
///
/// # 用法
/// ```dart
/// decoration: borderlessInputDecoration(
///   hintText: '搜索单词',
///   hintStyle: TextStyle(
///     fontFamily: CoFonts.uiSans, fontSize: 14, color: Color(t.ink3.argb32)),
/// )
/// ```
InputDecoration borderlessInputDecoration({
  required String hintText,
  TextStyle? hintStyle,
}) =>
    InputDecoration(
      isDense: true,
      // 🔴 六个都要写 —— 少任何一个，那个状态下就会继承主题的边框
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      hintText: hintText,
      hintStyle: hintStyle,
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
