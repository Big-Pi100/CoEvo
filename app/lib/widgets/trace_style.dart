import 'package:flutter/material.dart';

import '../theme/coevo_tokens.dart';

/// 痕迹的**样式映射层** —— 把 `TraceStyle`（token 层）套到 `TextStyle` 上。
///
/// # 🔴 为什么单独一个文件（2026-10-02 · S4 清理）
///
/// 它原本住在 `trace_text.dart` 里，与「纯文本逐 span 渲染」的 `TraceText`
/// 放在一起。S4 把正文渲染换成 **Markdown**（`trace_markdown.dart`）后：
/// · `TraceText` 失去了**全部消费者** → 已删
/// · 但**这个映射函数还活着** —— `trace_markdown.dart` 的 `InlinePattern`
///   builder 要靠它把痕迹样式套到解析出来的 span 上
///
/// ⇒ 「删掉死代码」时最容易误伤的就是这种情况：**同一个文件里有的死了、有的还活着**。
///   所以先按「谁在用」逐项过一遍，再把活的移出来，最后才删文件。
///   📌 判据：**删文件之前，先确认文件里每一项的去向**（不是看文件名判断）。
///
/// # 分层位置
/// ```
/// trace_locator.dart        ── 判定：哪些词该标、哪一档（唯一权威）
///   ↓ 档位
/// trace_markdown_source.dart ── 编码：把词包成控制字符标记（纯字符串，零 import）
///   ↓ 带标记的 Markdown
/// trace_markdown.dart       ── 渲染：交给 gpt_markdown（InlinePattern）
///   ↓ 需要「痕迹 → TextStyle」
/// trace_style.dart（本文件） ── 映射：`TraceStyle` → `TextStyle`
/// ```
/// 🔑 「档位 → 样式」的映射**只有 token 层一处权威**（`TraceTokens.forReps`），
///    本文件只负责**把已经定好的 `TraceStyle` 翻译成 Flutter 能画的属性**。
///
/// # 🔴 四处「设计稿能做、Flutter 文本做不到」的能力边界
///
/// 设计稿的痕迹是 HTML **内联元素**（`<span>` 带 `border-radius` + `padding`）。
/// Flutter 的 `TextStyle` 没有对应能力 —— 这不是「没实现」，是 **API 不存在**
/// （已逐一核实 SDK 源码）：
///
/// | 设计稿（spec §1.1） | Flutter `TextStyle` | 本实现的处理 |
/// |---|---|---|
/// | `border-radius: 3px` | ❌ **无圆角** —— `background` 是 `Paint`，只能画矩形 | 画矩形。**偏差：直角 vs 圆角** |
/// | `padding: 1px 3px` | ❌ **无 padding**（`TextStyle` 无此字段） | 不加。**偏差：背景紧贴字形** |
/// | `border-bottom: 2.5px` | ⚠️ `decorationThickness` 是**笔画宽度的倍数**，不是像素 | 按系数近似（[_kFontStrokeRatio]）。**偏差：线宽不精确** |
/// | border 贴盒底 | ⚠️ `underline` 贴在**基线下方**，**无偏移可调** | 用 `underline`。**偏差：线离文字更近** |
///
/// ## 按档看影响
/// - **格（下划线）** ✅ 语义完全对（本来就是线）—— 只是线宽/位置需**真机目视标定**
/// - **夜（前景色）** ✅ **完美还原** —— `color` 一一对应，零偏差
/// - **墨（底色浸染）** ⚠️ 语义对（就是背景色），但**无圆角、无 padding**
///
/// 🔑 若要**完全还原墨档**，唯一路径是**自绘**：
/// `TextPainter.getBoxesForSelection()` 拿到每个 span 的矩形 → 自己画 `RRect`。
/// 代价：断行 / 对齐 / 选区都要自己处理。
/// **建议先按本实现跑起来看真实差异**（3px 圆角在 16.5px 正文里差异可能很小），
/// 再决定是否值得上自绘 —— 决策记录见
/// `docs/review/step3-core-ui-plan-2026-09-27.md` §十四。
///
/// ⚠️ **这里只做映射，不做渲染** —— 所以它是**纯函数、零 widget 依赖**，
///    可以在纯 Dart 脚本里独立断言（本机 Flutter 跑不了 `flutter analyze`
///    与 widget 测试，见 `scripts/static_check/README.md`）。

/// 「字体自带笔画宽度」相对 `fontSize` 的**估算系数**。
///
/// 🔴 **这是估算值，必须真机标定**：
/// 真实值藏在字体元数据里（`OS/2` 表的 `underlineThickness`），Flutter **未暴露**。
/// 于是「设计稿要 2.5px 的线」只能反推倍数：
/// ```
/// decorationThickness = 目标像素 / (fontSize × 本系数)
/// ```
/// 常见字体的 underlineThickness 约为 `fontSize` 的 5%–8%，故取中值 0.07。
///
/// ⚠️ **真机目视后回来调这一个数**即可同时修正三态线宽 ——
/// 所以「目标像素」保留在 token 的 `border.width` 里（语义），
/// 而不是把倍数硬编码进 token（那样就丢了「设计稿要几像素」这个判据）。
const double _kFontStrokeRatio = 0.07;

/// 把痕迹 token 套到基础文字样式上。
///
/// # 映射规则（逐项 · 与文件头的能力边界表对应）
/// | token | 映射到 | 备注 |
/// |---|---|---|
/// | `fg` | `TextStyle.color` | 为 `null` = **inherit**（不动颜色） |
/// | `bg` | `TextStyle.background`（[traceBackgroundPaint]） | 只能矩形，**无圆角** |
/// | `border` | `decoration: underline` + 宽度/虚实 | 宽度按倍数近似 |
/// | `padding` / `radius` | **无法表达** | 见文件头 |
///
/// ⚠️ **调用方不要传「不可见样式」来取消标识** ——
/// 「不标识」= **不传这个 mark**（`TraceTokens.forReps` 返回 `null` 就跳过）。
/// 因为即使把颜色调到全透明，`padding` 仍会改变字距 → 被标记过的字与普通字**间距不同**，
/// 那仍然是标识，只是更难解释。
TextStyle applyTraceStyle(TextStyle base, TraceStyle trace) {
  var s = base;

  // ── 前景色 ──
  // spec：`fg == null` 表示 `inherit` = **不该改颜色**（跟随正文字色）。
  // 必须用 null 判断 —— 不能因为「null 就当默认色」而写死一个颜色。
  if (trace.fg != null) {
    s = s.copyWith(color: Color(trace.fg!.argb32));
  }

  // ── 背景 ──
  if (!trace.bg.isTransparent) {
    s = s.copyWith(background: traceBackgroundPaint(trace));
  }

  // ── 边框 → 下划线 ──
  final bd = trace.border;
  if (bd != null) {
    final fs = base.fontSize ?? 16.5;
    final baseStroke = fs * _kFontStrokeRatio;
    s = s.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: Color(bd.color.argb32),
      // 目标像素 → 倍数（见 [_kFontStrokeRatio]；真机标定后回来调那一个系数）
      decorationThickness: baseStroke > 0 ? bd.width / baseStroke : 1.0,
      decorationStyle:
          bd.dashed ? TextDecorationStyle.dashed : TextDecorationStyle.solid,
    );
  }

  return s;
}

/// 痕迹的矩形背景 —— 单独给它一个名字。
///
/// 🔑 命名是为了**让「这里是矩形」这件事有个明确的落脚点**：
/// 将来若改自绘（圆角矩形 `RRect`），改动点就在这一个函数，
/// 不会散落在各处 `Paint()..color = …` 里。
Paint traceBackgroundPaint(TraceStyle trace) =>
    Paint()..color = Color(trace.bg.argb32);
