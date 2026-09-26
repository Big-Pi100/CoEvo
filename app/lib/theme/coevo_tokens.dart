// CoEvo · 视觉 token 层（三档主题：墨 / 格 / 夜）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（与 `fsrs_service.dart` 同一条约束）。
//   理由：本地 Flutter 是鸿蒙定制版、`flutter analyze` 会因 Windows 管道耗尽崩溃，
//   纯 Dart 才能本地独立跑验证（见 `scripts/tokens_verify/`）。
//   → 所以颜色用自有的 `CoRgba` 值类型，**不用 `dart:ui` 的 `Color`**。
//   → Flutter 层的转换（`CoRgba` → `Color`）在 `theme_builder.dart` 做。
//
// 依据：`docs/design/design-system-spec-2026-09-25.md`（视觉系统定稿规格 = 单一事实源）
//   · §1.1 痕迹 token（三态 × 5 项）
//   · §2.1 主题底色 token（13 项 × 3 档）
//   · §3.3 粘土 token（5 项 × 3 档）
//   · §3.5 尺寸阶梯（sm / md / lg × 5 项）
//   · §5.2 卡片排版层级（9 项）
//   · §7.3 token 结构（单一类型 + 三实例 + 一个 buildTheme，**不写 3 个手写 ThemeData**）
//
// 🔑 本文件承载 spec 的**全部数值**，验收脚本逐项断言 → 「文档改了但代码没改」会被抓住。
//
// ⚠️ 一个已知规格缺口（见文件末 `clayFill` 注释）：spec §7.2/§7.3 引用了 `clayFill`
//    但 §2.1/§3.3 的 token 表**没有给它值**。当前取 `card`（推断），待白哥确认。

import 'dart:math' as math;

// ─────────────────────────────────────────────────────────────
// ① 颜色值类型（纯 Dart，零依赖）
// ─────────────────────────────────────────────────────────────

/// sRGB 颜色 + alpha（0–255 分量，alpha 为 0.0–1.0）。
///
/// 不用 `dart:ui` 的 `Color` —— 那是 Flutter 类型，会让本文件无法在纯 Dart 下验证。
class CoRgba {
  final int r;
  final int g;
  final int b;
  final double a;

  const CoRgba(this.r, this.g, this.b, [this.a = 1.0])
      : assert(r >= 0 && r <= 255, 'r 取值范围 0–255'),
        assert(g >= 0 && g <= 255, 'g 取值范围 0–255'),
        assert(b >= 0 && b <= 255, 'b 取值范围 0–255'),
        assert(a >= 0.0 && a <= 1.0, 'a 取值范围 0.0–1.0');

  /// `CoRgba.hex(0xB4432C)` —— 六位十六进制（不透明）。
  const CoRgba.hex(int rgb, [double alpha = 1.0])
      : r = (rgb >> 16) & 0xFF,
        g = (rgb >> 8) & 0xFF,
        b = rgb & 0xFF,
        a = alpha;

  /// 完全透明（痕迹「格」档的背景用的就是它）。
  static const CoRgba transparent = CoRgba(0, 0, 0, 0.0);

  bool get isTransparent => a == 0.0;

  /// `#B4432C` —— 便于与 spec 逐字对照。
  String get cssHex =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
              '${g.toRadixString(16).padLeft(2, '0')}'
              '${b.toRadixString(16).padLeft(2, '0')}'
              .toUpperCase();

  /// `rgba(180,67,44,.15)` —— 便于与 spec 逐字对照。
  String get cssRgba {
    if (a == 1.0) return 'rgba($r,$g,$b,1)';
    // 去掉前导 0（spec 写 `.15` 而非 `0.15`）与尾随 0
    var t = a.toStringAsFixed(3).substring(1);
    t = t.replaceFirst(RegExp(r'0+$'), '');
    if (t == '.') t = '';
    return 'rgba($r,$g,$b,$t)';
  }

  /// Flutter `Color.value` 口径的 32 位 ARGB（供 `theme_builder` 转换用）。
  int get argb32 {
    final ai = (a * 255).round().clamp(0, 255);
    return (ai << 24) | (r << 16) | (g << 8) | b;
  }

  // ── WCAG 相对亮度 / 对比度（验证要用，Flutter 层将来也能用）──

  /// 单个分量：sRGB → 线性光。
  static double _linearize(int c) {
    final v = c / 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  /// WCAG 相对亮度（0.0–1.0）。**先合成到不透明底上**再算 —— 见 [over]。
  double get relativeLuminance {
    assert(a == 1.0, '计算亮度前必须先合成到不透明底（用 over()）');
    return 0.2126 * _linearize(r) + 0.7152 * _linearize(g) + 0.0722 * _linearize(b);
  }

  /// 把本颜色（可能半透明）合成到不透明背景 [bg] 上。
  ///
  /// 🔴 半透明色不能直接算对比度 —— 必须先合成，否则算的是「不存在的颜色」。
  CoRgba over(CoRgba bg) {
    assert(bg.a == 1.0, '背景必须不透明');
    if (a == 1.0) return this;
    final na = a + bg.a * (1 - a);
    double mix(int fg, int b) => (fg * a + b * bg.a * (1 - a)) / na;
    return CoRgba(mix(r, bg.r).round(), mix(g, bg.g).round(), mix(b, bg.b).round(), na);
  }

  /// WCAG 对比度（1.0–21.0）。两者都会先合成到 [onTopOf]（默认纯白底）。
  double contrastWith(CoRgba other, {CoRgba? onTopOf}) {
    final base = onTopOf ?? const CoRgba.hex(0xFFFFFF);
    final l1 = over(base).relativeLuminance;
    final l2 = other.over(base).relativeLuminance;
    final hi = math.max(l1, l2);
    final lo = math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }

  @override
  bool operator ==(Object other) =>
      other is CoRgba && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => a == 1.0 ? cssHex : cssRgba;
}

// ─────────────────────────────────────────────────────────────
// ② 痕迹（§1.1）—— 视觉签名，三态 × 5 项
// ─────────────────────────────────────────────────────────────

/// 痕迹语法：三档主题的**关键差异**（不是配色）。
enum TraceSyntax {
  /// 墨 · 底色浸染（暖底 + 淡朱砂，最接近铅笔印）
  wash,

  /// 格 · 下划线（纯白底上浸染看不见，线才对）
  underline,

  /// 夜 · 光（深底上「加亮」比「加色」自然）
  glow,
}

/// 痕迹边框。`none` 用 [TraceStyle.border] 为 `null` 表示。
class TraceBorder {
  final double width;
  final CoRgba color;
  final bool dashed;

  const TraceBorder({required this.width, required this.color, this.dashed = false});

  @override
  bool operator ==(Object other) =>
      other is TraceBorder &&
      other.width == width &&
      other.color == color &&
      other.dashed == dashed;

  @override
  int get hashCode => Object.hash(width, color, dashed);
}

/// 痕迹内边距（`1px 3px` / `0 0 1px 0`）。
///
/// 🔴 spec §1.1 明确：**别只给 `bg` 就开工** —— 三态各自需要「背景/边框/前景/内边距/圆角」，
/// 少了 `p` 和 `r`，痕迹块的留白会随字号漂移。
class TracePadding {
  final double top;
  final double right;
  final double bottom;
  final double left;

  const TracePadding(this.top, this.right, this.bottom, this.left);

  /// `TracePadding.sym(1, 3)` → 上下 1、左右 3。
  const TracePadding.sym(double vertical, double horizontal)
      : top = vertical,
        bottom = vertical,
        right = horizontal,
        left = horizontal;

  double get horizontalTotal => left + right;
  double get verticalTotal => top + bottom;

  @override
  bool operator ==(Object other) =>
      other is TracePadding &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.left == left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);
}

/// 单态痕迹（5 项）。
class TraceStyle {
  final CoRgba bg;
  final TraceBorder? border;

  /// 前景色。`null` = `inherit`（跟随所在文本，**不改颜色**）。
  final CoRgba? fg;
  final TracePadding padding;
  final double radius;

  const TraceStyle({
    required this.bg,
    this.border,
    this.fg,
    required this.padding,
    required this.radius,
  });

  /// 是否完全不改变文本外观（三档「已掌握」态在浅色下就接近这个）。
  bool get isInvisible =>
      bg.isTransparent && border == null && fg == null && padding.verticalTotal == 0;

  @override
  bool operator ==(Object other) =>
      other is TraceStyle &&
      other.bg == bg &&
      other.border == border &&
      other.fg == fg &&
      other.padding == padding &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(bg, border, fg, padding, radius);
}

/// 痕迹三态（刚查过 / 复习中 / 已掌握）。
class TraceTokens {
  final TraceSyntax syntax;
  final TraceStyle fresh; // reps = 0
  final TraceStyle reviewing; // reps 1–2
  final TraceStyle mastered; // reps ≥ 3 且 lapses = 0

  const TraceTokens({
    required this.syntax,
    required this.fresh,
    required this.reviewing,
    required this.mastered,
  });

  /// 按熟练度取样式。
  TraceStyle forReps(int reps, {int lapses = 0}) {
    if (reps <= 0) return fresh;
    if (reps >= 3 && lapses == 0) return mastered;
    return reviewing;
  }
}

// ─────────────────────────────────────────────────────────────
// ③ 粘土（§3.2 公式 / §3.3 token / §3.5 尺寸阶梯）
// ─────────────────────────────────────────────────────────────

/// 一道阴影的几何参数（颜色由 [ClayTokens] 决定）。
class CoShadow {
  final double dx;
  final double dy;
  final double blur;
  final bool inset;

  const CoShadow(this.dx, this.dy, this.blur, {this.inset = false});

  @override
  bool operator ==(Object other) =>
      other is CoShadow &&
      other.dx == dx &&
      other.dy == dy &&
      other.blur == blur &&
      other.inset == inset;

  @override
  int get hashCode => Object.hash(dx, dy, blur, inset);

  @override
  String toString() => '${inset ? 'inset ' : ''}${dx}px ${dy}px ${blur}px';
}

/// 尺寸阶梯档位标识。
enum ClaySize { sm, md, lg }

/// 高度 < 24px：**完全去掉 inset**，只留外阴影（没空间表现高光）。
const double clayNoInsetBelow = 24.0;

/// 尺寸阶梯中的一档（§3.5）。
///
/// 🔴 为什么必须有：26px 圆角 + 8px 偏移放在 180px 卡片上成立，
/// 放在 26px 高的药丸上会糊成一团 → **阴影参数必须随元素尺寸缩放**。
class ClayScale {
  final ClaySize size;

  /// 该档适用的高度下界（px）。低于 [minHeight] 一律用更小档。
  final double minHeight;
  final CoShadow outer; // 外阴影 · 浮起
  final CoShadow shade; // 内暗 · 体积（inset，负向）
  final CoShadow light; // 内亮 · 充气（inset，正向）
  final double radiusFactor; // 圆角 = 主题 clRadius × 本系数

  const ClayScale({
    required this.size,
    required this.minHeight,
    required this.outer,
    required this.shade,
    required this.light,
    required this.radiusFactor,
  });
}

/// sm · 24–40px（药丸、小徽章）
const ClayScale clayScaleSm = ClayScale(
  size: ClaySize.sm,
  minHeight: 24,
  outer: CoShadow(2, 3, 5),
  shade: CoShadow(-2, -2, 5, inset: true),
  light: CoShadow(2, 2, 4, inset: true),
  radiusFactor: 0.50,
);

/// md · 40–72px（按钮、图标按钮、统计徽章）
const ClayScale clayScaleMd = ClayScale(
  size: ClaySize.md,
  minHeight: 40,
  outer: CoShadow(4, 5, 10),
  shade: CoShadow(-3, -3, 8, inset: true),
  light: CoShadow(3, 3, 7, inset: true),
  radiusFactor: 0.55,
);

/// lg · 100px+（信息流卡片、复习卡）
const ClayScale clayScaleLg = ClayScale(
  size: ClaySize.lg,
  minHeight: 100,
  outer: CoShadow(6, 8, 16),
  shade: CoShadow(-5, -5, 12, inset: true),
  light: CoShadow(4, 4, 10, inset: true),
  radiusFactor: 1.0,
);

/// 三档尺寸阶梯（按大小升序）。
const List<ClayScale> clayScales = [clayScaleSm, clayScaleMd, clayScaleLg];

/// 尺寸阶梯工具（纯函数，无实例状态 → 可在 const 上下文中引用）。
abstract final class ClayScales {
  /// 按元素高度选档（不考虑主题强度上限）。
  static ClayScale forHeight(double height) {
    if (height >= clayScaleLg.minHeight) return clayScaleLg;
    if (height >= clayScaleMd.minHeight) return clayScaleMd;
    return clayScaleSm;
  }

  /// 取两档中较小的一档（用于落实「强度上限」）。
  static ClayScale smaller(ClayScale a, ClayScale b) =>
      a.size.index <= b.size.index ? a : b;

  static ClayScale bySize(ClaySize size) => switch (size) {
        ClaySize.sm => clayScaleSm,
        ClaySize.md => clayScaleMd,
        ClaySize.lg => clayScaleLg,
      };
}

/// 粘土 token（§3.3）。
///
/// 🔑 **粘土参数是主题 token 的一部分，不是全局常量** ——
/// 这正是「三档主题 × 粘土」不冲突的原因：它们本来就是同一张表里的不同字段。
class ClayTokens {
  /// 外阴影 —— **中性色元素**用（卡片、白底按钮）。
  final CoRgba out;

  /// 内暗（体积）。
  final CoRgba shade;

  /// 内亮（充气）。深色档必须压到 .05–.07 → 体积感减弱约一半（§3.9 如实接受的代价）。
  final CoRgba light;

  /// 外阴影 —— **彩色元素**用（朱砂按钮、选中态）。取强调色的染色版本（同色相、.40）。
  ///
  /// 🔴 为什么必须分开（§3.3.1）：§3.2 规则要求「外阴影要染元素自身的色相」，
  /// 而 [out] 是**主题级**（暖褐 / 冷灰 / 无彩）。强调色元素若强行用 [out]，
  /// 在「格」档会出现**冷灰阴影配暖朱砂填充**（色相冲突 155°）→ 正是规则要避免的「发脏」。
  final CoRgba accentOut;

  /// 圆角（主题级）。
  ///
  /// 🔴 与 inset 偏移是**几何硬约束**：圆角 ≥ 偏移 × 3（§3.4）。
  /// 圆角不够时内阴影会绕过圆角形成**「月牙状」伪影**，比不做粘土更难看。
  final double radius;

  /// **强度上限** —— 该主题最高只用到这一档参数。
  ///
  /// 依据 §3.3「粘土强度」行：墨 = 完整（lg）、**格 = 中等（参数降 md 档）**、夜 = 完整。
  /// 「格」档降档的理由是它的圆角只有 14px，承载不了 lg 的 5px 偏移。
  final ClaySize maxSize;

  /// **圆角是否参与尺寸缩放**（§3.5.1）。
  ///
  /// - `true`（墨 26 / 夜 24）：基准圆角明显大于目标值 → 按 `radiusFactor` 缩放
  /// - 🔴 `false`（**格** 14）：**基准圆角本身就是目标值** → 缩放会重复缩一次
  ///
  /// 依据：`0.50/0.55` 系数是为「墨 26 / 夜 24」整定的（`26×0.55≈14.3`、`24×0.55≈13.2`，
  /// **都落在 14px 附近**）—— 而「格」的 14px 正是那个目标值（§3.4 的 B 方案）。
  /// 再乘系数得 `7.7px < 9`（偏移 3 × 3）→ **违反 §3.4 的几何约束**。
  ///
  /// ⚠️ **只有圆角例外；阴影参数（外/内暗/内亮）三档仍按尺寸阶梯缩放。**
  final bool scaleRadius;

  const ClayTokens({
    required this.out,
    required this.shade,
    required this.light,
    required this.accentOut,
    required this.radius,
    this.maxSize = ClaySize.lg,
    this.scaleRadius = true,
    required this.syntaxLabel,
  });

  /// spec 里对「粘土强度」的描述（便于逐字核对）。
  final String syntaxLabel;

  /// 按元素高度取档，**并施加主题强度上限**。
  ClayScale scaleFor(double height) =>
      ClayScales.smaller(ClayScales.forHeight(height), ClayScales.bySize(maxSize));

  /// 按高度取该档的圆角（「格」档不缩放，见 [scaleRadius]）。
  double radiusFor(double height) =>
      scaleRadius ? radius * scaleFor(height).radiusFactor : radius;

  /// 🔴 圆角承载不了内阴影 → 会绕过圆角形成「月牙状」伪影（§3.4）。
  ///
  /// 返回该档在当前圆角下是否几何成立。
  /// 三档现已全部成立（「格」档靠 [scaleRadius] = `false` 修好，见 §3.5.1）。
  bool geometryOkFor(double height) {
    if (height < clayNoInsetBelow) return true; // 无 inset，无约束
    final s = scaleFor(height);
    final offset = s.shade.dx.abs();
    return radiusFor(height) >= offset * 3;
  }
}

// ─────────────────────────────────────────────────────────────
// ④ 排版层级（§5.2）
// ─────────────────────────────────────────────────────────────

/// 卡片字号层级。
///
/// 🔑 **设计原则：线索不压过答案** ——
/// 内容层最大字号必须落在**释义**（要记住的答案），不是**记忆法**（帮助记住的线索）。
/// 记忆法的权重靠**色彩 + 凹陷底 + 拆分结构**，**与字号无关**。
///
/// ⚠️ 两个易犯的错：
///   1. 把解释性段落做成大字号 —— 长句放大字只增加阅读负担，不增加权重
///   2. 用字号当权重 —— 权重该由色彩/底色/结构承担；字号只承担**层级**
class CoTypography {
  final double word; // 单词（Literata）
  final double defText; // 释义 —— 内容层最大（Inter 500）
  final double mnemMain; // 记忆法主体 —— 必须 ≤ defText
  final double ctxText; // 语境
  final double gloss; // 记忆法括号注释
  final double defEn; // 英文释义
  final double mnemNote; // 词源说明（Inter）
  final double ipa; // 音标（Charis SIL）
  final double label; // 段标签（Inter，字距 .05em）

  /// 划词浮层 / 紧凑卡的**整体缩放**（spec：×0.9）。
  final double compactScale;

  /// 整句类（词源故事）专用行高 —— 句子长，行高要松。
  final double sentenceLineHeight;

  const CoTypography({
    this.word = 32,
    this.defText = 16.5,
    this.mnemMain = 15.5,
    this.ctxText = 14.5,
    this.gloss = 13.5,
    this.defEn = 13,
    this.mnemNote = 12.5,
    this.ipa = 15,
    this.label = 11,
    this.compactScale = 0.9,
    this.sentenceLineHeight = 1.75,
  });

  /// 紧凑卡的字号集合。
  CoTypography get compact => CoTypography(
        word: word * compactScale,
        defText: defText * compactScale,
        mnemMain: mnemMain * compactScale,
        ctxText: ctxText * compactScale,
        gloss: gloss * compactScale,
        defEn: defEn * compactScale,
        mnemNote: mnemNote * compactScale,
        ipa: ipa * compactScale,
        label: label,
        compactScale: 1.0,
        sentenceLineHeight: sentenceLineHeight,
      );

  /// 🔑 不变量：记忆法不得压过释义（含紧凑档）。
  bool get hierarchyHolds =>
      defText >= mnemMain && mnemMain > ctxText && compact.defText >= compact.mnemMain;
}

// ─────────────────────────────────────────────────────────────
// ⑤ 字体（**全局，不随主题变**）
// ─────────────────────────────────────────────────────────────

/// 字体族名。
///
/// 🔑 **为什么是独立常量类而不是 `CoEvoTokens` 的字段**：
/// spec §2.2 把「字体组合」列在「**跨主题稳定**（品牌在这）」那一栏 ——
/// 字体不跟着三档主题变，所以不该是 per-theme token。
///
/// 🔴 **A′ 方案的核心约束**（spec §4.1.1）：**音标必须元素级指定字体**。
///
/// ```dart
/// // ❌ 错：把 IPA 字体当整段文字的 fallback → 逐字符回退 → 一条音标两种字体
/// TextStyle(fontFamily: 'Literata', fontFamilyFallback: ['CharisSIL'])
/// //   → 实测 10,823 / 11,523 = 93.9% 的音标会混排两种字体
///
/// // ✅ 对（A′）：
/// // ① 正文类文字
/// TextStyle(fontFamily: CoFonts.latinSerif, fontFamilyFallback: CoFonts.latinFallback)
/// // ② 音标元素 —— 直接指定，不挂 fallback 链
/// TextStyle(fontFamily: CoFonts.ipaSerif)
/// ```
///
/// ⚠️ `latinFallback` 存在的**唯一目的**是兜住「词源说明里偶尔内嵌的音标」
/// （实测 232 张卡 = 2.0%，无法避免）—— **不要拿它当通配回退用**。
abstract final class CoFonts {
  /// 英文阅读正文。**缺 18 个 IPA 码位**（所以音标不能靠它）。
  static const String latinSerif = 'Literata';

  /// IPA 音标。**逐字符 30/30 全覆盖**（含 4 个组合符号）。
  static const String ipaSerif = 'CharisSIL';

  /// 中文 UI。全量 24.2 MB，**不做子集化**（阿里普惠体条款禁止拆分/转换）。
  static const String cjk = 'AlibabaPuHuiTi';

  /// 界面 / 数字（未接入，可随 Flutter 默认）。
  static const String uiSans = 'Inter';

  /// 正文的 fallback 链 —— **只兜「词源正文里内嵌的音标」**（2.0%）。
  static const List<String> latinFallback = [ipaSerif];

  /// 字体族名清单（供验收脚本与 pubspec 交叉核对）。
  static const List<String> allFamilies = [latinSerif, ipaSerif, cjk, uiSans];

  /// 实际打进 App 的字体族（`uiSans` 尚未接入）。
  ///
  /// 🔑 这些名字**必须**在 `app/pubspec.yaml` 的 `flutter.fonts` 里声明，
  /// 否则运行时会**静默回退**到系统字体（不报错，只是字变了）——
  /// 验收脚本会做这条交叉检查。
  static const List<String> shippedFamilies = [latinSerif, ipaSerif, cjk];
}

// ─────────────────────────────────────────────────────────────
// ⑥ 主题汇总
// ─────────────────────────────────────────────────────────────

/// 三档底色对应**三种使用场景**，不是三种审美 → 三档全做、用户可切换。
enum ReadingTheme { ink, grid, night }

/// 一档主题的全部 token。
///
/// 🗂 **不写 3 个手写的 ThemeData**（§7.3）—— 单一类型 + 三实例 + 一个 `buildTheme`。
class CoEvoTokens {
  final ReadingTheme theme;
  final String label; // 中文名（墨 / 格 / 夜）
  final String character; // 独有气质（一句话）

  // ── 主题底色（§2.1）──
  final CoRgba page; // 页面底
  final CoRgba read; // 阅读底
  final CoRgba card; // 卡面
  final CoRgba ink; // 主文字
  final CoRgba ink2; // 次文字
  final CoRgba ink3; // 弱文字
  final CoRgba accent; // 强调色 · **实心填充**用（上面压 accentInk）
  final CoRgba accentBright; // 亮调 · **细线与描边**用（不作背景）
  final CoRgba accentInk; // 压字色
  final CoRgba accentOut; // 彩色元素外阴影
  final CoRgba line; // 分隔线
  final CoRgba sunken; // 凹陷底
  final double readLineHeight; // 阅读行高 —— **不是全局 1.5**（对英文偏紧）

  // ── 质感 ──
  final ClayTokens clay;
  final TraceTokens trace;

  // ── 排版 ──
  final CoTypography type;

  /// 粘土元素的填充色。
  ///
  /// 🔑 **= `card`（卡面色），不另设值** —— 2026-09-26 白哥定，见 spec §3.3.2。
  ///
  /// 依据：
  /// - §3.1 已定 claymorphism 的填充色「**任意色，与背景无关**」→ 用卡面色完全成立
  /// - §7.2 示例里粘土元素的例子就是「卡片、白底按钮」—— 它们本就该是卡面色
  /// - 同值却分设字段会制造「改了 `card` 忘了改 `clayFill`」的漂移风险
  ///
  /// 🔑 **定义为 getter 而非字段** → 它**不可能**与 `card` 不一致。
  CoRgba get clayFill => card;

  const CoEvoTokens({
    required this.theme,
    required this.label,
    required this.character,
    required this.page,
    required this.read,
    required this.card,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentBright,
    required this.accentInk,
    required this.accentOut,
    required this.line,
    required this.sunken,
    required this.readLineHeight,
    required this.clay,
    required this.trace,
    this.type = const CoTypography(),
  });

  /// 主题切换 280ms 过渡（§3.8）。
  static const Duration transitionDuration = Duration(milliseconds: 280);

  /// 按下 `scale(.97)`，90ms ease-out（§3.8）。
  static const Duration pressDuration = Duration(milliseconds: 90);
  static const double pressScale = 0.97;

  /// 松手回弹 320ms `Curves.elasticOut`（§3.8）。
  static const Duration releaseDuration = Duration(milliseconds: 320);
}

// ─────────────────────────────────────────────────────────────
// ⑦ 三档实例（数值全部逐项对齐 spec）
// ─────────────────────────────────────────────────────────────

const CoRgba _accentInkLight = CoRgba.hex(0xFFFFFF);
const CoRgba _accentOutLight = CoRgba(180, 67, 44, 0.40);

/// 墨 · 暖纸（默认档）
const CoEvoTokens inkTokens = CoEvoTokens(
  theme: ReadingTheme.ink,
  label: '墨',
  character: '暖沙 · 纸感',
  page: CoRgba.hex(0xF1EDE4),
  read: CoRgba.hex(0xFAF8F4),
  card: CoRgba.hex(0xFFFFFF),
  ink: CoRgba.hex(0x24211C),
  ink2: CoRgba.hex(0x6E6659),
  // 🔴 原 #9A917F 与 read 底对比度仅 2.94 < 3.0（§八 声称达标但从未实测）
  //    → 2026-09-26 白哥定：保持色相 40°/饱和 11.8% 不变，**只降 1% 明度** → 3.02 ✅
  ink3: CoRgba.hex(0x988F7C),
  accent: CoRgba.hex(0xB4432C),
  accentBright: CoRgba.hex(0xC4533A),
  accentInk: _accentInkLight,
  accentOut: _accentOutLight,
  line: CoRgba.hex(0xEFE9DE),
  sunken: CoRgba.hex(0xEDE6DA),
  readLineHeight: 1.82,
  clay: ClayTokens(
    out: CoRgba(150, 125, 95, 0.24),
    shade: CoRgba(186, 166, 138, 0.55),
    light: CoRgba(255, 255, 255, 1.0),
    accentOut: _accentOutLight,
    radius: 26,
    syntaxLabel: '完整',
  ),
  trace: TraceTokens(
    syntax: TraceSyntax.wash,
    fresh: TraceStyle(
      bg: CoRgba(180, 67, 44, 0.15),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
    reviewing: TraceStyle(
      bg: CoRgba(180, 67, 44, 0.075),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
    mastered: TraceStyle(
      bg: CoRgba(180, 67, 44, 0.026),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
  ),
);

/// 格 · 纯白（精密 / 网格 / 等宽音标）
const CoEvoTokens gridTokens = CoEvoTokens(
  theme: ReadingTheme.grid,
  label: '格',
  character: '精密 · 网格 · 等宽音标',
  page: CoRgba.hex(0xEDEEF0), // ⚠️ 从 #F2F2F2 压深 —— 卡面纯白，页面底太近白则粘土层次太弱
  read: CoRgba.hex(0xFFFFFF),
  card: CoRgba.hex(0xFFFFFF),
  ink: CoRgba.hex(0x0A0A0A),
  ink2: CoRgba.hex(0x5A5A5A),
  ink3: CoRgba.hex(0x8A8A8A),
  accent: CoRgba.hex(0xB4432C), // 与墨共用（方案甲：统一色相）
  accentBright: CoRgba.hex(0xC4533A), // 与墨共用
  accentInk: _accentInkLight,
  accentOut: _accentOutLight,
  line: CoRgba.hex(0xE8E8E8),
  sunken: CoRgba.hex(0xF0F0F0),
  readLineHeight: 1.74,
  clay: ClayTokens(
    out: CoRgba(110, 115, 125, 0.22),
    shade: CoRgba(158, 158, 158, 0.46),
    light: CoRgba(255, 255, 255, 1.0),
    accentOut: _accentOutLight,
    // ⚠️ 14px（不是原设计的 8px）—— 8px 承载不了 inset（圆角 ≥ 偏移 × 3），
    //    强行用会出现「月牙状」伪影。选 B 方案：圆角提到 14px + 参数降 md 档。
    radius: 14,
    // §3.3：格档粘土强度 = 中等 → 最高只用 md 档参数（lg 的 5px 偏移它承载不了）
    maxSize: ClaySize.md,
    // 🔴 §3.5.1：14px 本身就是目标值，**再乘 0.55 会得 7.7px < 9 → 违反 §3.4 几何约束**
    scaleRadius: false,
    syntaxLabel: '中等（参数降 md 档）',
  ),
  trace: TraceTokens(
    syntax: TraceSyntax.underline,
    fresh: TraceStyle(
      bg: CoRgba.transparent,
      border: TraceBorder(
        width: 2.5,
        color: CoRgba.hex(0xC4533A), // var(--accent-bright)
      ),
      padding: TracePadding(0, 0, 1, 0),
      radius: 0,
    ),
    reviewing: TraceStyle(
      bg: CoRgba.transparent,
      border: TraceBorder(width: 1.5, color: CoRgba(0, 192, 139, 0.42)),
      padding: TracePadding(0, 0, 1, 0),
      radius: 0,
    ),
    mastered: TraceStyle(
      bg: CoRgba.transparent,
      border: TraceBorder(width: 1.0, color: CoRgba(10, 10, 10, 0.16), dashed: true),
      padding: TracePadding(0, 0, 1, 0),
      radius: 0,
    ),
  ),
);

/// 夜 · 深墨（沉浸 / 暗房）
const CoEvoTokens nightTokens = CoEvoTokens(
  theme: ReadingTheme.night,
  label: '夜',
  character: '沉浸 · 暗房',
  page: CoRgba.hex(0x0B0D12),
  read: CoRgba.hex(0x14161C),
  card: CoRgba.hex(0x1C1F27),
  ink: CoRgba.hex(0xEDEBE6),
  ink2: CoRgba.hex(0x9AA0AE),
  ink3: CoRgba.hex(0x6E7484),
  accent: CoRgba.hex(0xDB7E6B), // 深底版亮朱砂（同色相，只变明度）
  accentBright: CoRgba.hex(0xE89B8C),
  accentInk: CoRgba.hex(0x2A1405),
  accentOut: CoRgba(219, 126, 107, 0.40),
  line: CoRgba.hex(0x262A34),
  sunken: CoRgba.hex(0x0B0D12),
  readLineHeight: 1.84,
  clay: ClayTokens(
    out: CoRgba(0, 0, 0, 0.55),
    shade: CoRgba(0, 0, 0, 0.42),
    // 🔴 白高光在深底上会读成「发光」而非「膨胀」→ 必须压到 .05–.07（取 .062）
    light: CoRgba(255, 255, 255, 0.062),
    accentOut: CoRgba(219, 126, 107, 0.40),
    radius: 24,
    syntaxLabel: '完整但内亮受限',
  ),
  trace: TraceTokens(
    syntax: TraceSyntax.glow,
    // 🔑 两态用**不同灰阶**而不是不同亮度（暖 → 冷）—— 单降亮度在深底上会读成「脏」
    fresh: TraceStyle(
      bg: CoRgba.transparent,
      fg: CoRgba.hex(0xFFD9B8),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
    reviewing: TraceStyle(
      bg: CoRgba.transparent,
      fg: CoRgba.hex(0xDEDCD7),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
    mastered: TraceStyle(
      bg: CoRgba.transparent,
      fg: CoRgba.hex(0x8E939F),
      padding: TracePadding.sym(1, 3),
      radius: 3,
    ),
  ),
);

/// 三档全表。
const Map<ReadingTheme, CoEvoTokens> allTokens = {
  ReadingTheme.ink: inkTokens,
  ReadingTheme.grid: gridTokens,
  ReadingTheme.night: nightTokens,
};

/// 浅色档（供「跟随系统」的浅色分支用）。
const List<ReadingTheme> lightThemes = [ReadingTheme.ink, ReadingTheme.grid];
