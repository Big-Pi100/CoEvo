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
}
