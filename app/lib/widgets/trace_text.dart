import 'package:flutter/material.dart';

import '../theme/coevo_tokens.dart';
import 'trace_segmenter.dart';

/// 痕迹渲染 —— 把 [TraceMark] 覆盖到正文上，输出带痕迹的富文本。
///
/// 切分逻辑在 [splitTraceSpans]（纯 Dart、可独立验证）；
/// **本文件只负责「把样式套上去」** —— 这两件事的验证方式完全不同
/// （切分错 = 逻辑 bug，能自动抓；样子不对 = 视觉问题，只能肉眼），所以分开放。
///
/// 依据：`design-system-spec-2026-09-25.md` §一 · `visual-feed-bookmark-2026-09-25.html`
///
/// # 三档语法共用同一段代码
/// spec §一：「实现上**仍是同一段代码**，只是 token 不同」——
/// 墨（底色浸染）/ 格（下划线）/ 夜（光）的差异**全部来自 token**，
/// 本文件里**没有任何 `if 主题 == …` 分支**（有分支就说明 token 层没抽象干净）。
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
/// # 用法
/// ```dart
/// final t = CoEvoTokensExt.of(context);
/// TraceText(
///   text: article.body,
///   marks: [
///     TraceMark(start: 12, end: 20, style: t.trace.forReps(reps: 0)),
///   ],
///   style: TextStyle(
///     fontFamily: CoFonts.latinSerif,
///     fontSize: 16.5,
///     height: t.readLineHeight,
///   ),
/// )
/// ```
///
/// # 性能说明（**未做缓存，是有意的**）
/// 每次 build 重算切分 + 重新 `substring`。一篇文章（数千字符、数百标记）的开销
/// 在毫秒级，对首屏和滚动都无感。
/// ⚠️ 若将来正文长到掉帧，再上「`text` + `marks` 不变的缓存」——
/// 但现在做会让代码复杂一倍，而问题**还没有被观察到**（不做没依据的优化）。
class TraceText extends StatelessWidget {
  const TraceText({
    super.key,
    required this.text,
    required this.marks,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.logDiagnostics = true,
  });

  final String text;

  /// 痕迹标记。**不要求有序、不要求不重叠** —— [splitTraceSpans] 会归一化，
  /// 并把畸形输入计入诊断（不静默）。
  final List<TraceMark> marks;

  /// 基础正文样式（字体 / 字号 / 行高由调用方按档给出）。
  ///
  /// ⚠️ 两点要求：
  /// 1. **`fontSize` 必传** —— 它参与「下划线粗细」的换算（见 [_kFontStrokeRatio]）
  /// 2. **不要带 `background`** —— 痕迹的 `bg` 会**覆盖**它；
  ///    带了也不会报错，只是那个背景永远不会显示（容易误判成「痕迹没生效」）
  final TextStyle style;

  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  /// 切分出现畸形输入时打一行日志（默认开）。
  ///
  /// 🔑 畸形输入意味着**上游（分词 / 词表命中）有 bug**，
  /// 表现为「某些词莫名没痕迹」。静默吞掉会让这类问题**完全不可观测**
  /// （本项目已反复踩过静默失败的坑，见 `auth_provider` 的 `_friendlyError` 那段）。
  /// 只在**确实有**诊断时打，不会刷屏。
  final bool logDiagnostics;

  @override
  Widget build(BuildContext context) {
    final split = splitTraceSpans(text.length, marks);

    if (logDiagnostics && split.hasDiagnostics) {
      debugPrint('[TraceText] 畸形痕迹区间：${split.diagnostics} '
          '(textLength=${text.length}, marks=${marks.length})');
    }

    return Text.rich(
      TextSpan(
        children: [
          for (final span in split.spans)
            TextSpan(
              text: text.substring(span.start, span.end),
              // 普通文字：`null` = 不设样式，完全继承外层 `style`
              // （**不去 copyWith** —— 少建一个有样式对象，且语义更准）
              style: span.style == null ? null : applyTraceStyle(style, span.style!),
            ),
        ],
      ),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign ?? TextAlign.start,
    );
  }
}

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
/// 公开是为了让**非 [TraceText] 场景**（如词卡里的单个单词）复用同一套映射 ——
/// 避免「痕迹的渲染规则」在两处各写一遍后漂移。
///
/// # 映射规则（逐项 · 与类文档的能力边界表对应）
/// | token | 映射到 | 备注 |
/// |---|---|---|
/// | `fg` | `TextStyle.color` | 为 `null` = **inherit**（不动颜色） |
/// | `bg` | `TextStyle.background`（[traceBackgroundPaint]） | 只能矩形，**无圆角** |
/// | `border` | `decoration: underline` + 宽度/虚实 | 宽度按倍数近似 |
/// | `padding` / `radius` | **无法表达** | 见类文档 |
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
