/// 间距常量（**与主题无关** → 不进 `CoEvoTokens`）。
///
/// 📌 这 8 个值原本和 4 套手写 `ThemeData` 混在同一个文件里（旧主题实现，
/// 已于 2026-09-27 整体删除）。拆出来单独成文件，是因为间距是**布局尺度**：
/// 既不随三档底色变，也不属于任何主题。
///
/// ⚠️ 命名去掉 `spacing` 前缀：类名已经说明了单位，
/// `CoSpacing.sm` 比 `CoSpacing.spacingSm` 少一半噪音（调用点多达 325 处）。
abstract final class CoSpacing {
  /// 4 —— 图标与紧邻文字、行内小间隙
  static const double xs = 4;

  /// 8 —— 最常用：列表项内左距、标签与内容之间
  static const double sm = 8;

  /// 12 —— 同组元素之间
  static const double md = 12;

  /// 16 —— 组与组之间（卡片内边距基准）
  static const double lg = 16;

  /// 20 —— 卡片外间距
  static const double xl = 20;

  /// 24 —— 区块之间
  static const double xxl = 24;

  /// 32 —— 大段落之间
  static const double xxxl = 32;

  /// 48 —— 页面级留白
  static const double xxxxl = 48;

  /// 底部导航（`app.dart` 的 `_ClayTabBar`）的**高度估算 + 呼吸位** = 100。
  ///
  /// 🔑 用途：各 tab 页滚动容器的**底部 padding**。
  ///
  /// 为什么需要它：`_ShellScaffold` 开了 `extendBody: true` → 正文会延伸到 tabbar
  /// **之后**（这就是「底部栏透明」的实质）。若不预留这段距离，最后一项会被按钮压住。
  ///
  /// 估算依据（见 `_ClayTabBar` 的常量）：
  ///   `12`（上留白）+ `~47`（tab 内容：8 + 图标 15 + 4 + 文字 ~13 + 7）
  ///   + `max(24, 系统安全区)` ≈ **83**（iPhone home indicator 时 ≈ **93**）
  ///   → 取 **100**：覆盖安全区，并在最后一项下方留 ~7–17px 呼吸位。
  ///
  /// ⚠️ **与 `_ClayTabBar` 是耦合的**：那边改了内边距 / 字号 / 图标尺寸，这里要跟着改。
  ///    （目前无自动校验 —— 若将来出现「最后一项被按钮压住」，先查这两个数。）
  static const double tabBarClearance = 100;
}
