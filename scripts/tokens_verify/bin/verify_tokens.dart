// CoEvo · 视觉 token 验收
//
// 为什么存在：`design-system-spec-2026-09-25.md` 是**视觉的单一事实源**，
//   但文档与代码会各自漂移 —— 改了文档忘了改代码，或反之，都不会报错。
//   本脚本把 spec 的**全部数值**写成断言 → 「文档改了但代码没改」当场暴露。
//
// 🔑 三类断言（分工不同）：
//   ① `eq` / `near`  —— 逐项对照 spec 的数值（值错 = 实现错）
//   ② `contrast`     —— 用 spec **自己声称的实测值**反验我们的对比度实现
//                       （这一条同时验了「token 值」和「算法实现」两件事）
//   ③ 不变量         —— spec 的**设计规则**（层级不反转 / 色相同源 / 几何成立）
//
// ⚠️ 两类「spec 内部不自洽」用 `conflict()` 单独报告，**不计为实现失败**：
//   冲突是文档要改，不是代码要改。见脚本末尾输出。
//
// 跑法：`cd scripts/tokens_verify && dart run bin/verify_tokens.dart`
// 退出码：**有实现类失败 → 1**；仅有规格冲突 → 0（冲突另行列示）

import 'dart:io';

import '../../../app/lib/theme/coevo_tokens.dart';
int _pass = 0;
int _fail = 0;
final List<String> _failures = [];
final List<String> _conflicts = [];

void check(String desc, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $desc${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _fail++;
    _failures.add(desc);
    print('  🔴 $desc${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

void eq(String desc, Object? actual, Object? expected) => check(
      desc,
      actual == expected,
      actual == expected ? '$actual' : '实得 $actual / 期望 $expected',
    );

/// 列表**按内容**比较。
///
/// 🔴 **Dart 的 `List == List` 是引用比较** —— 用它断言会让「值相同」的两个列表
/// 报失败，且打印出的实得/期望**看起来一模一样**（极难排查）。
/// 这个坑在本脚本首轮就踩到过：`latinFallback == [ipaSerif]` 实得与期望显示均为
/// `[CharisSIL]` 却判失败 —— **属「断言写错」而非「实现错」**。
void listEq(String desc, List<String> actual, List<String> expected) {
  final ok = actual.length == expected.length &&
      List.generate(actual.length, (i) => actual[i] == expected[i]).every((x) => x);
  check(desc, ok, ok ? '${actual.length} 项一致' : '实得 $actual / 期望 $expected');
}

void near(String desc, double actual, double expected, {double tol = 0.015}) {
  final ok = (actual - expected).abs() <= tol;
  check(
    desc,
    ok,
    ok ? actual.toStringAsFixed(2) : '实得 ${actual.toStringAsFixed(3)} / 期望 $expected',
  );
}

/// spec 内部不自洽的项 —— **文档要改，不是代码要改**。
void conflict(String desc, String detail) {
  _conflicts.add('$desc —— $detail');
  print('  ⚠️  $desc');
  print('        $detail');
}

/// 断言；失败时**归因为规格问题**（而非实现错）—— 用于「spec 自己没定清」的项。
///
/// 🔑 与 [check] 的区别：`check` 失败 = 我们写错了；`checkSpec` 失败 = 文档有歧义/矛盾。
/// 分开才能避免「把文档问题当成代码 bug 去改代码」。
///
/// ⚠️ **当前无调用点**（2026-09-26 三处规格冲突已全部由白哥定案并修入 spec）。
/// **有意保留** —— spec 会继续演进，下次出现同类矛盾时直接用它归因，
/// 不必重新设计这套分类。删除它等于把这个教训丢掉。
// ignore: unused_element
void checkSpec(String desc, bool ok, String conflictDetail) {
  if (ok) {
    _pass++;
    print('  ✅ $desc');
  } else {
    conflict(desc, conflictDetail);
  }
}

/// 颜色断言：直接用 `CoRgba` 值比较，不依赖字符串格式化。
void color(String desc, CoRgba actual, CoRgba expected) =>
    check(desc, actual == expected, actual == expected ? '$actual' : '实得 $actual / 期望 $expected');

const _themes = <(String, CoEvoTokens)>[
  ('墨', inkTokens),
  ('格', gridTokens),
  ('夜', nightTokens),
];

void main() {
  print('═' * 72);
  print('CoEvo 视觉 token 验收 · 对照 design-system-spec-2026-09-25.md');
  print('═' * 72);

  _s1ThemeColors();
  _s2Contrast();
  _s3Clay();
  _s4Trace();
  _s5Scale();
  _s6Typography();
  _s7Fonts();
  _s8Invariants();
  _s9Wiring();
  _s10ClayRender();
  _s11Lerp();
  _s12Reader();
  _s13TabBarShell();
  _s14BookmarkList();
  _s15Navigation();
  _s16WordWriteback();
  _s17ReviewList();
  _s18DbRevision();
  _s19ExternalCard();
  _s20DeviceId();

  print('\n' + '═' * 72);
  print('通过 $_pass 项，实现类失败 $_fail 项，规格内部冲突 ${_conflicts.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
  }
  if (_conflicts.isNotEmpty) {
    print('\n⚠️ 规格内部冲突（改文档即可，非实现问题）：');
    for (final c in _conflicts) {
      print('  · $c');
    }
  }
  if (_fail == 0 && _conflicts.isEmpty) {
    print('\n✅ token 层与 spec 逐项一致，且 spec 无内部矛盾');
  } else if (_fail == 0) {
    print('\n✅ token 层与 spec 逐项一致（规格冲突见上，待定夺）');
  }
  // 冲突不导致失败退出 —— 它是文档问题
  if (_fail > 0) {
    print('\n🔴 有实现类失败，需修正');
    exit(1);
  }
}

// ── ① 主题底色 · §2.1（13 项 × 3 档）────────────────────────
void _s1ThemeColors() {
  print('\n【1】主题底色 token（spec §2.1 · 13 项 × 3 档）');

  const expected = <String, Map<String, int>>{
    'page': {'墨': 0xF1EDE4, '格': 0xEDEEF0, '夜': 0x0B0D12},
    'read': {'墨': 0xFAF8F4, '格': 0xFFFFFF, '夜': 0x14161C},
    'card': {'墨': 0xFFFFFF, '格': 0xFFFFFF, '夜': 0x1C1F27},
    'ink': {'墨': 0x24211C, '格': 0x0A0A0A, '夜': 0xEDEBE6},
    'ink2': {'墨': 0x6E6659, '格': 0x5A5A5A, '夜': 0x9AA0AE},
    'ink3': {'墨': 0x988F7C, '格': 0x8A8A8A, '夜': 0x6E7484},
    'accent': {'墨': 0xB4432C, '格': 0xB4432C, '夜': 0xDB7E6B},
    'accentBright': {'墨': 0xC4533A, '格': 0xC4533A, '夜': 0xE89B8C},
    'accentInk': {'墨': 0xFFFFFF, '格': 0xFFFFFF, '夜': 0x2A1405},
    'line': {'墨': 0xEFE9DE, '格': 0xE8E8E8, '夜': 0x262A34},
    'sunken': {'墨': 0xEDE6DA, '格': 0xF0F0F0, '夜': 0x0B0D12},
  };

  for (final (label, t) in _themes) {
    for (final e in expected.entries) {
      final want = e.value[label]!;
      final got = switch (e.key) {
        'page' => t.page,
        'read' => t.read,
        'card' => t.card,
        'ink' => t.ink,
        'ink2' => t.ink2,
        'ink3' => t.ink3,
        'accent' => t.accent,
        'accentBright' => t.accentBright,
        'accentInk' => t.accentInk,
        'line' => t.line,
        'sunken' => t.sunken,
        _ => throw StateError('未知 token ${e.key}'),
      };
      eq('$label.${e.key}', got, CoRgba.hex(want));
    }
    // 阅读行高 —— spec 强调「不是全局 1.5」（对英文偏紧）
    final wantLh = {'墨': 1.82, '格': 1.74, '夜': 1.84}[label]!;
    near('$label.readLineHeight', t.readLineHeight, wantLh);
    // accentOut（§2.1 标为 🆕 独立 token）
    final wantOut = switch (label) {
      '夜' => const CoRgba(219, 126, 107, 0.40),
      _ => const CoRgba(180, 67, 44, 0.40),
    };
    color('$label.accentOut', t.accentOut, wantOut);
  }
}

// ── ② 对比度 · §2.1（用 spec 声称的实测值反验实现）───────────
void _s2Contrast() {
  print('\n【2】对比度（spec §2.1 声称的实测值 → 反验我们的算法实现）');

  // spec 原表：| 档 | 底 ↔ accent（≥3） | accent ↔ ink（≥4.5） | 底 ↔ bright（≥3） |
  const expected = <String, (double, double, double)>{
    '墨': (4.76, 5.56, 3.87),
    '格': (4.79, 5.56, 3.89),
    '夜': (6.67, 6.00, 8.79),
  };

  for (final (label, t) in _themes) {
    final (wantBaseAccent, wantAccentInk, wantBaseBright) = expected[label]!;

    // 「底」= page（已用 spec 数值反推确认：墨档 page↔accent 手算 4.751 ≈ 4.76）
    final baseAccent = t.page.contrastWith(t.accent);
    final accentInk = t.accent.contrastWith(t.accentInk);
    final baseBright = t.page.contrastWith(t.accentBright);

    near('$label · page ↔ accent', baseAccent, wantBaseAccent);
    near('$label · accent ↔ accentInk', accentInk, wantAccentInk);
    near('$label · page ↔ accentBright', baseBright, wantBaseBright);

    // 达标线（spec 给的阈值）
    check('$label · page↔accent ≥ 3', baseAccent >= 3.0, baseAccent.toStringAsFixed(2));
    check('$label · accent↔accentInk ≥ 4.5', accentInk >= 4.5, accentInk.toStringAsFixed(2));
    check('$label · page↔accentBright ≥ 3', baseBright >= 3.0, baseBright.toStringAsFixed(2));
  }

  // §八 验收清单第 1 条：「三档主题的文字对比度全部达标（含 --ink3 弱文字）」
  print('\n  ── 文字对比度（§八 验收清单第 1 条）──');
  for (final (label, t) in _themes) {
    final ink = t.read.contrastWith(t.ink);
    final ink2 = t.read.contrastWith(t.ink2);
    final ink3 = t.read.contrastWith(t.ink3);
    check('$label · ink ↔ read ≥ 4.5', ink >= 4.5, ink.toStringAsFixed(2));
    check('$label · ink2 ↔ read ≥ 4.5', ink2 >= 4.5, ink2.toStringAsFixed(2));
    // ink3 = 辅助/弱文字 → 按 WCAG 辅助文字阈值 3.0（口径已在 spec §2.1.0 写明）
    // 墨档曾为 2.94 ❌ → 2026-09-26 白哥定「降 1% 明度」→ #988F7C = 3.02 ✅
    check('$label · ink3 ↔ read ≥ 3（辅助文字阈值）', ink3 >= 3.0, ink3.toStringAsFixed(2));
  }
}

// ── ③ 粘土 · §3.3 + §3.4 ────────────────────────────────────
void _s3Clay() {
  print('\n【3】粘土 token（spec §3.3 · 5 项 × 3 档）');

  const expected = <String, (int, double, int, double, int, double, double)>{
    // outRgb, outA, shadeRgb, shadeA, lightRgb, lightA, radius
    '墨': (0x967D5F, 0.24, 0xBAA68A, 0.55, 0xFFFFFF, 1.0, 26),
    '格': (0x6E737D, 0.22, 0x9E9E9E, 0.46, 0xFFFFFF, 1.0, 14),
    '夜': (0x000000, 0.55, 0x000000, 0.42, 0xFFFFFF, 0.062, 24),
  };

  for (final (label, t) in _themes) {
    final (outRgb, outA, shadeRgb, shadeA, lightRgb, lightA, radius) = expected[label]!;
    color('$label.clay.out', t.clay.out, CoRgba.hex(outRgb, outA));
    color('$label.clay.shade', t.clay.shade, CoRgba.hex(shadeRgb, shadeA));
    color('$label.clay.light', t.clay.light, CoRgba.hex(lightRgb, lightA));
    near('$label.clay.radius', t.clay.radius, radius, tol: 0.001);

    // §3.3.1 核心要求：**彩色元素的外阴影要染元素自身的色相**
    // → accentOut 的 RGB 必须与 accent 完全一致（只差 alpha）
    check(
      '$label · accentOut 与 accent 同色相（§3.3.1）',
      t.clay.accentOut.r == t.accent.r &&
          t.clay.accentOut.g == t.accent.g &&
          t.clay.accentOut.b == t.accent.b,
      'accentOut=${t.clay.accentOut} / accent=${t.accent}',
    );
    check('$label · accentOut alpha = .40', t.clay.accentOut.a == 0.40);

    // §3.3「粘土强度」行
    final wantStrength = {'墨': '完整', '格': '中等（参数降 md 档）', '夜': '完整但内亮受限'}[label]!;
    eq('$label.clay.强度描述', t.clay.syntaxLabel, wantStrength);
  }

  // §3.9 深色取舍：内亮必须压到 .05–.07
  final lightA = nightTokens.clay.light.a;
  check(
    '夜 · 内亮压到 .05–.07（§3.9）',
    lightA >= 0.05 && lightA <= 0.07,
    lightA.toString(),
  );

  // §3.4 几何约束：圆角 ≥ inset 偏移 × 3
  // 🔴 首轮三档里有「格」档两项不成立（14 × 0.55 = 7.7 < 9）
  //    → 2026-09-26 白哥定「格档 radiusFactor 全取 1.0」→ 已修，现应全部成立
  print('\n  ── 圆角几何约束（§3.4：圆角 ≥ 偏移 × 3）──');
  for (final (label, t) in _themes) {
    for (final h in [180.0, 48.0]) {
      final tag = h >= 100 ? 'lg' : 'md';
      final ok = t.clay.geometryOkFor(h);
      final r = t.clay.radiusFor(h);
      final off = t.clay.scaleFor(h).shade.dx.abs();
      check('$label · $tag(${h.toInt()}px) 几何成立', ok,
          'r=${r.toStringAsFixed(1)} / 偏移=${off.toStringAsFixed(0)}'
          '${t.clay.scaleRadius ? '' : ' · 不缩放'}');
    }
  }

  // §3.5.1：只有「格」档 scaleRadius = false
  check('墨档 圆角参与缩放', inkTokens.clay.scaleRadius);
  check('夜档 圆角参与缩放', nightTokens.clay.scaleRadius);
  check('🔴 格档 圆角**不**参与缩放（§3.5.1）', !gridTokens.clay.scaleRadius);
  near('格档 radiusFor(48) == 14（不缩放）', gridTokens.clay.radiusFor(48), 14, tol: 0.001);
  near('格档 radiusFor(180) == 14（不缩放）', gridTokens.clay.radiusFor(180), 14, tol: 0.001);
  near('墨档 radiusFor(48) == 26×0.55', inkTokens.clay.radiusFor(48), 26 * 0.55, tol: 0.001);

  // §3.3.2：clayFill = card（getter，不可能不一致）
  for (final (label, t) in _themes) {
    check('$label · clayFill == card（§3.3.2）', t.clayFill == t.card);
  }

  // 高度 < 24px：完全去掉 inset（只留外阴影）
  for (final (label, t) in _themes) {
    check('$label · <24px 无 inset 约束', t.clay.geometryOkFor(20));
  }
}

// ── ④ 痕迹 · §1.1（三态 × 5 项 × 3 档）──────────────────────
void _s4Trace() {
  print('\n【4】痕迹 token（spec §1.1 · 三态 × 5 项 × 3 档）');

  // 语法（三档最重要的差异，不是配色）
  const syntaxExpected = {
    '墨': TraceSyntax.wash,
    '格': TraceSyntax.underline,
    '夜': TraceSyntax.glow,
  };
  for (final (label, t) in _themes) {
    eq('$label.trace.syntax', t.trace.syntax, syntaxExpected[label]);
  }

  // 墨：背景透明度递减 .15 → .075，无边框，无前景覆盖
  // 🔴 2026-09-27 白哥定「已掌握 = 不标识」→ **只有两态**（trace 里已无 mastered 字段）
  final ink = inkTokens.trace;
  color('墨.n.bg', ink.fresh.bg, const CoRgba(180, 67, 44, 0.15));
  color('墨.m.bg', ink.reviewing.bg, const CoRgba(180, 67, 44, 0.075));
  for (final (tag, s) in [('n', ink.fresh), ('m', ink.reviewing)]) {
    check('墨.$tag.bd = none', s.border == null);
    check('墨.$tag.fg = inherit', s.fg == null);
    near('墨.$tag.p.top', s.padding.top, 1, tol: 0.001);
    near('墨.$tag.p.right', s.padding.right, 3, tol: 0.001);
    near('墨.$tag.r', s.radius, 3, tol: 0.001);
  }

  // 格：线宽递减 2.5px 实线 → 1.5px 半透明，背景始终透明
  final grid = gridTokens.trace;
  for (final (tag, s) in [('n', grid.fresh), ('m', grid.reviewing)]) {
    check('格.$tag.bg = transparent', s.bg.isTransparent);
    near('格.$tag.p.top', s.padding.top, 0, tol: 0.001);
    near('格.$tag.p.bottom', s.padding.bottom, 1, tol: 0.001);
    near('格.$tag.r', s.radius, 0, tol: 0.001);
  }
  near('格.n.bd.width', grid.fresh.border!.width, 2.5, tol: 0.001);
  color('格.n.bd.color', grid.fresh.border!.color, const CoRgba.hex(0xC4533A));
  check('格.n.bd 实线', !grid.fresh.border!.dashed);
  near('格.m.bd.width', grid.reviewing.border!.width, 1.5, tol: 0.001);
  //    🔴 2026-09-27 白哥定：由绿 `rgba(0,192,139,.42)` 改朱砂 —— 原值是旧「翠绿进化」
  //       时代残留，与方案甲「统一色相 = 朱砂」冲突（色相 155°）。取值 = `accentBright`
  //       (`0xC4533A`) 的 42% 透明版，与 fresh 的实色同源（对齐 `visual-feed-bookmark` L53）。
  color('格.m.bd.color', grid.reviewing.border!.color, const CoRgba(196, 83, 58, 0.42));

  //    🔑 不变量：格档两态的边框必须**同色相**（都来自 accentBright 的染色版）——
  //       否则又回到「一条痕迹两种色系」。fresh 是实色、reviewing 是 42% 透明，只差 alpha。
  {
    final n = grid.fresh.border!.color;
    final m = grid.reviewing.border!.color;
    final nDiff = (n.r - 196).abs() + (n.g - 83).abs() + (n.b - 58).abs();
    final mDiff = (m.r - 196).abs() + (m.g - 83).abs() + (m.b - 58).abs();
    check('格档两态边框同色相（均源自 accentBright #C4533A）',
        nDiff == 0 && mDiff == 0, 'fresh=$n / reviewing=$m');
    check('两态只差 alpha（实色 1.0 vs .42）',
        n.a == 1.0 && m.a == 0.42, 'a=${n.a} / ${m.a}');
  }

  // 夜：两态用**不同灰阶**（暖奶油 → 中性），而非同一色降透明度
  //   ⚠️ 原表述「亮度递减」在三态下成立（靠已掌握把亮度拉到 .291）；
  //      两态下亮度仅 .743 → .716，**实际区分靠暖度/彩度** → 断言改为验「暖度递减」。
  final night = nightTokens.trace;
  color('夜.n.fg', night.fresh.fg!, const CoRgba.hex(0xFFD9B8));
  color('夜.m.fg', night.reviewing.fg!, const CoRgba.hex(0xDEDCD7));
  for (final (tag, s) in [('n', night.fresh), ('m', night.reviewing)]) {
    check('夜.$tag.bg = transparent', s.bg.isTransparent);
    check('夜.$tag.bd = none', s.border == null);
  }
  //    「暖度」用 (r − b) 表达：fresh 暖奶油 r−b = 71，reviewing 中性 r−b = 7
  {
    final nWarm = night.fresh.fg!.r - night.fresh.fg!.b;
    final mWarm = night.reviewing.fg!.r - night.reviewing.fg!.b;
    check('夜档暖度递减（fresh 更暖 → reviewing 近中性）', nWarm > mWarm,
        'fresh r−b=$nWarm / reviewing r−b=$mWarm');
  }

  // 两态取用逻辑 + 🔴 **已掌握必须返回 null**（不标识）
  check('forReps(0) → fresh', ink.forReps(0) == ink.fresh);
  check('forReps(1) → reviewing', ink.forReps(1) == ink.reviewing);
  check('forReps(2) → reviewing', ink.forReps(2) == ink.reviewing);
  check('forReps(3) → null（已掌握 = 不标识）', ink.forReps(3) == null);
  check('forReps(9) → null（已掌握 = 不标识）', ink.forReps(9) == null);
  check('forReps(3, lapses:1) → reviewing（有遗忘则不算掌握）',
      ink.forReps(3, lapses: 1) == ink.reviewing);
}

// ── ⑤ 尺寸阶梯 · §3.5（3 档 × 5 项）─────────────────────────
void _s5Scale() {
  print('\n【5】尺寸阶梯（spec §3.5 · sm / md / lg）');

  // 档位边界
  check('forHeight(20) → sm', ClayScales.forHeight(20).size == ClaySize.sm);
  check('forHeight(30) → sm', ClayScales.forHeight(30).size == ClaySize.sm);
  check('forHeight(48) → md', ClayScales.forHeight(48).size == ClaySize.md);
  check('forHeight(72) → md', ClayScales.forHeight(72).size == ClaySize.md);
  check('forHeight(180) → lg', ClayScales.forHeight(180).size == ClaySize.lg);

  // sm：2px 3px 5px / inset -2 -2 5 / inset 2 2 4 / ×50%
  eq('sm.outer', clayScaleSm.outer, const CoShadow(2, 3, 5));
  eq('sm.shade', clayScaleSm.shade, const CoShadow(-2, -2, 5, inset: true));
  eq('sm.light', clayScaleSm.light, const CoShadow(2, 2, 4, inset: true));
  near('sm.radiusFactor', clayScaleSm.radiusFactor, 0.50, tol: 0.001);

  // md：4px 5px 10px / inset -3 -3 8 / inset 3 3 7 / ×55%
  eq('md.outer', clayScaleMd.outer, const CoShadow(4, 5, 10));
  eq('md.shade', clayScaleMd.shade, const CoShadow(-3, -3, 8, inset: true));
  eq('md.light', clayScaleMd.light, const CoShadow(3, 3, 7, inset: true));
  near('md.radiusFactor', clayScaleMd.radiusFactor, 0.55, tol: 0.001);

  // lg：6px 8px 16px / inset -5 -5 12 / inset 4 4 10 / ×100%
  eq('lg.outer', clayScaleLg.outer, const CoShadow(6, 8, 16));
  eq('lg.shade', clayScaleLg.shade, const CoShadow(-5, -5, 12, inset: true));
  eq('lg.light', clayScaleLg.light, const CoShadow(4, 4, 10, inset: true));
  near('lg.radiusFactor', clayScaleLg.radiusFactor, 1.0, tol: 0.001);

  // 两个 inset 必须反向（§3.2 细节 2：与全站「统一左上光」一致）
  for (final s in clayScales) {
    check('${s.size.name} · 两 inset 反向',
        s.shade.dx < 0 && s.shade.dy < 0 && s.light.dx > 0 && s.light.dy > 0);
    check('${s.size.name} · 内亮比内暗更小偏移（更透明）',
        s.light.dx.abs() <= s.shade.dx.abs() && s.light.blur < s.shade.blur);
  }

  // 强度上限：格档最高只用 md 参数（§3.3「参数降 md 档」）
  eq('格档 lg 高度实际用 md 参数', gridTokens.clay.scaleFor(180).size, ClaySize.md);
  eq('墨档 lg 高度用 lg 参数', inkTokens.clay.scaleFor(180).size, ClaySize.lg);
  eq('夜档 lg 高度用 lg 参数', nightTokens.clay.scaleFor(180).size, ClaySize.lg);
}

// ── ⑥ 排版 · §5.2 ───────────────────────────────────────────
void _s6Typography() {
  print('\n【6】排版层级（spec §5.2 · 9 项）');

  final t = inkTokens.type;
  near('word', t.word, 32, tol: 0.001);
  near('defText（答案 · 内容层最大）', t.defText, 16.5, tol: 0.001);
  near('mnemMain（线索 · 必须 ≤ 释义）', t.mnemMain, 15.5, tol: 0.001);
  near('ctxText', t.ctxText, 14.5, tol: 0.001);
  near('gloss', t.gloss, 13.5, tol: 0.001);
  near('defEn', t.defEn, 13, tol: 0.001);
  near('mnemNote', t.mnemNote, 12.5, tol: 0.001);
  near('ipa', t.ipa, 15, tol: 0.001);
  near('label', t.label, 11, tol: 0.001);

  // 🔑 设计原则：线索不压过答案
  check('§5.2 不变量 · 释义 ≥ 记忆法', t.defText >= t.mnemMain,
      '${t.defText} ≥ ${t.mnemMain}');
  check('§5.2 不变量 · 记忆法 > 语境', t.mnemMain > t.ctxText);
  check('§5.2 不变量 · 层级链完整（word > defText > mnemMain > ctxText > label）',
      t.word > t.defText && t.defText >= t.mnemMain && t.mnemMain > t.ctxText && t.ctxText > t.label);

  // 紧凑档（划词浮层）：整体 ×0.9，**关系不能反转**
  near('compactScale', t.compactScale, 0.9, tol: 0.001);
  final c = t.compact;
  near('紧凑 · word', c.word, 28.8, tol: 0.01);
  near('紧凑 · defText', c.defText, 14.85, tol: 0.01);
  near('紧凑 · mnemMain', c.mnemMain, 13.95, tol: 0.01);
  check('紧凑档不变量 · 释义 ≥ 记忆法（关系不能反转）', c.defText >= c.mnemMain,
      '${c.defText.toStringAsFixed(2)} ≥ ${c.mnemMain.toStringAsFixed(2)}');
  check('hierarchyHolds（含紧凑档）', t.hierarchyHolds);

  // 整句类行高（词源故事）
  near('sentenceLineHeight', t.sentenceLineHeight, 1.75, tol: 0.001);
}

// ── ⑦ 字体 · spec §四（A′ 方案）─────────────────────────────
void _s7Fonts() {
  print('\n【7】字体（spec §4.1 · A′ 方案）');

  eq('正文 family', CoFonts.latinSerif, 'Literata');
  eq('IPA family', CoFonts.ipaSerif, 'CharisSIL');
  // 2026-09-27 由 AlibabaPuHuiTi 更换（条款禁止子集化 → 换 OFL 的 Noto Sans SC）
  eq('中文 family', CoFonts.cjk, 'NotoSansSC');
  listEq('latinFallback == [ipaSerif]', CoFonts.latinFallback, [CoFonts.ipaSerif]);

  // 🔴 A′ 的核心不变量：音标字体**不得**出现在正文的「主 family」位置
  check('音标 family ≠ 正文 family', CoFonts.ipaSerif != CoFonts.latinSerif);
  check(
    '🔴 A′ 不变量 · fallback 链不等于「整段共用」（已显式分离两个 family）',
    CoFonts.latinFallback.isNotEmpty && CoFonts.latinSerif != CoFonts.ipaSerif,
  );

  // 🔑 交叉验证：代码里引用的 family **必须**在 pubspec.yaml 里声明
  //    —— 否则运行时会**静默回退**系统字体（不报错，只是字变了）
  final pubspec = File('${_repoRoot()}/app/pubspec.yaml');
  if (!pubspec.existsSync()) {
    check('找到 app/pubspec.yaml', false, pubspec.path);
    return;
  }
  final yaml = pubspec.readAsStringSync();
  final declared = RegExp(r'^\s*-\s*family:\s*(\S+)\s*$', multiLine: true)
      .allMatches(yaml)
      .map((m) => m.group(1)!)
      .toList();

  check('pubspec 读到字体声明', declared.isNotEmpty, declared.join(', '));
  for (final f in CoFonts.shippedFamilies) {
    check('pubspec 声明了 `$f`（否则会静默回退系统字体）', declared.contains(f),
        declared.contains(f) ? '已声明' : '缺！pubspec 有: $declared');
  }

  // 字体文件真的存在（声明了但文件不在 → 打包时才报错）
  for (final f in CoFonts.shippedFamilies) {
    final hit = RegExp('assets/fonts/$f[-\\w]*\\.ttf').allMatches(yaml);
    check('`$f` 的 asset 路径已声明', hit.isNotEmpty);
    for (final m in hit) {
      final p = File('${_repoRoot()}/app/${m.group(0)}');
      check('  文件存在: ${m.group(0)!.split('/').last}', p.existsSync(),
          p.existsSync() ? '${p.lengthSync()} B' : '缺文件');
    }
  }
  // 🔑 上面那个「`CoFonts.cjk` 单独跳过」的特例已删除（2026-09-27）——
  //    原先跳是因为**阿里普惠体的文件名与 family 名不同**（`AlibabaPuHuiTi-3-55-Regular`）。
  //    换成 `NotoSansSC-*` 后命名一致，`shippedFamilies` 的通用检查**已能覆盖它**
  //    → 特例没有存在理由了。（「**功能取消，其子功能一并失去理由**」的又一处应用。）

  // ── 🆕 中文字体（2026-09-27 更换为 Noto Sans SC · OFL）──────────
  //
  // 本节只做**接线性**断言（名字 / 声明 / 字重 / 许可文本是否随包）。
  // 🔴 **真正的「cmap 覆盖」不在这里** —— 那需要解析 TTF 的 cmap 表，
  //    而 Dart 侧无此能力；放在 `scripts/build_fonts.py --verify-coverage`
  //    （Python 有 `fontTools`，且它本来就是**字体构建的单一出处**）。
  //    ⚠️ 两者是**互补**的，缺一不可：这里防「写了但没接上」，那边防「字体被换/词库增长后缺字」。
  final nsc = 'assets/fonts/NotoSansSC-';
  for (final w in [400, 500, 600, 700]) {
    final hit = RegExp('$nsc\\w+\\.ttf[\\s\\S]{0,40}?weight:\\s*$w')
        .hasMatch(yaml) ||
        RegExp('weight:\\s*$w[\\s\\S]{0,80}?$nsc\\w+\\.ttf').hasMatch(yaml);
    check('中文字体声明了字重 $w', hit);
  }
  // 🔑 600 是本次刻意补的：代码里 `w600` 用 69 处（最多），
  //    而旧字体只声明 400/500/700 → 那 69 处一直在「就近取」。
  check('中文字体**没有**多声明不需要的字重（4 个字重即可）',
      RegExp('$nsc\\w+\\.ttf').allMatches(yaml).length == 4,
      '实得 ${RegExp('$nsc\\w+\\.ttf').allMatches(yaml).length} 个');
  // 🔴 OFL 条件 2：许可文本必须**随包分发**。
  //    ⚠️ 只把文件放进 `assets/fonts/` 不够 —— **未在 `assets:` 声明的文件不会被打包**
  //    （本项目已踩过：`user_db_schema.sql` 曾因此不进包，编译不报错、运行时才炸）
  check('OFL 许可文本已声明为 asset（否则不进包 = 等于没附）',
      RegExp(r'^\s*-\s*assets/fonts/NotoSansSC-OFL\.txt\s*$', multiLine: true)
          .hasMatch(yaml));
  check('OFL 许可文本文件存在',
      File('${_repoRoot()}/app/assets/fonts/NotoSansSC-OFL.txt').existsSync());
  // 🔴 OFL 条件 3：Modified Version 不得用 Reserved Font Name。
  //    本字体的保留名是 `Source`（查官方 OFL.txt 原文）→ 断言我们的 family 名不含它。
  check('family 名未使用保留名 `Source`', !CoFonts.cjk.contains('Source'));
}

/// 仓库根目录（从 cwd 向上找到含 app/ 的目录）。
/// 🔴 **「检查代码里有没有某个东西」必须先滤掉注释行** —— 两个方向都会出错：
///
/// | 方向 | 误判 | 后果 |
/// |---|---|---|
/// | 「**无残留**」检查 | 注释里解释「为什么**不用** X」被当成「还在**用** X」 | 🔴 **假红** —— 断言失败但代码没错 |
/// | 「**已接线**」检查 | 注释里提到 API 名，被当成「代码里调了」 | 🔴🔴 **假绿，更危险** —— 明明没接却显示通过 |
///
/// 本轮就是被第一种咬到：【11】检查「已无阶跃实现」时，
/// 命中的是注释里那句「为什么不能是阶跃（`t < 0.5 ? this : other`）」。
///
/// ⚠️ **只滤「整行注释」**（行首 `//`）—— 不敢去行尾 `//`，
/// 因为源码里有大量 URL（`https://…`），正则去尾注释会误伤字符串。
/// 这是刻意的折中：行尾注释的误判概率远低于整行注释。
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 取出某个**方法/函数**的 `{ ... }` 体（按花括号配对，含嵌套）。
///
/// # 🔑 为什么需要它（2026-09-28 实测踩到的假绿）
/// 「全文件 `contains`」在很多场景**范围大于被测对象**——
/// 只要同一行代码在**别处**也出现，断言就永远为绿，改坏被测处也不会报红。
///
/// 实例：`_collapseSearch` 里应有 `copyWith(search: '')`（收起时清空筛选），
/// 但输入框的 ✕ 按钮**也有**同一行（只清空输入、不退出搜索）→
/// 全文件 `contains` 在「`_collapseSearch` 已经不清空」时**照样通过**。
/// 证伪①实测确认：改成 `_args = _args` 后 428 项**全绿**（本该报红）。
///
/// 🔑 做法：先**切片**，再对切片断言 ——
/// 即「文本断言的范围必须等于被测对象」（同 `verifiable-core-logic` 的范围纪律）。
///
/// ⚠️ 调用方**必须**同时断言返回非空：方法改名/删除会让切片变空串 →
/// **空串通关** = 另一种假绿。
///
/// ⚠️ 已知边界：按**花括号**配对，不理解字符串字面量 —— 若方法体里有含 `{`/`}`
/// 的字符串（如 `'${a ? "}" : "{"}'`）会数错。本项目的方法体无此写法；
/// 真需要时再补「带引号状态的扫描器」（同 `splitSqlStatements` 的处理原则）。
/// 从 [start]（指向 `{`）起按**配对**取出区间（天然含嵌套）。
String _braces(String src, int start) {
  var depth = 0;
  for (var j = start; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, j + 1);
    }
  }
  return '';
}

/// 取「**类体**」或「**方法体**」的切片 —— 文本断言的「范围纪律」的基础工具。
///
/// # 🔴🔴 这个函数踩过**四个坑**，每个都让「反向断言」静默假绿
/// | # | 坑 | 后果 |
/// |---|---|---|
/// | 1 | 切出**空串**（`indexOf` 返回 -1 → 兜底 `''`） | 空串不含任何东西 →「不得含 X」全绿 |
/// | 2 | 找**类体**时命中**构造函数**（`const Foo({`） | 切到构造函数体（几乎不含东西）→ 反向断言全绿 |
/// | 3 | 找**方法体**时命中**调用处**（调用在前、定义在后） | 切成一段无关代码（**非空**，更隐蔽） |
/// | 4 | 方法体 `{` 命中**命名参数的 `{}`**（`f(a, {required X})`） | 切成**参数列表**（实测可短到 24 字符） |
///
/// 🔑 **四坑的共同点：切错后区间往往仍「非空」** → 「切片非空」这条自检
/// **挡不住 2/3/4**。所以调用方**必须**另加「**特征哨兵**」断言
/// （切片里应含该结构独有的字符串），否则守护是假的。
///
/// 🔑 **危害方向始终不对称**：正向断言（「应含 X」）会报红、能被发现 ✅；
/// **反向断言（「不得含 X」）全部假绿** ❌ —— 已多次靠正向断言救回。
String _braceBody(String src, String name) {
  // ── 路径 A：**类**（`class Foo extends Bar {`）──
  //   类**没有参数列表** → 声明后的第一个 `{` 就是类体。
  //   ⚠️ 不能让类走下面 `) {` 的路径 —— 那会命中**构造函数**或别处（坑 2 的变体）。
  final classAt = src.indexOf('class ' + name);
  if (classAt >= 0) {
    final b = src.indexOf('{', classAt);
    return b < 0 ? '' : _braces(src, b);
  }

  // ── 路径 B：**方法** ──
  //   🔴 坑 3：必须匹配「**定义式**」（前面带返回类型），不能只找 `name(` ——
  //      调用处可能先于定义处出现（本项目的 `build()` 在文件前段调
  //      `_header(t, dueCount)` / `_sortBar(t)`，而它们的定义在文件后段）
  //      → 从调用处配对会切出一段**与该方法无关**的区间。
  final def = RegExp(
    r'(?:Widget|void|Future<[^>]*>|List<Widget>|bool|String|int|double|'
    r'Iterable<[^>]*>|Map<[^>]*>)\s+'
    + RegExp.escape(name) + r'\(',
  ).firstMatch(src);
  final i = def?.start ?? src.indexOf(name + '(');
  if (i < 0) return '';

  //   🔴 坑 4：方法体的 `{` 必须在「**参数列表结束**」之后 ——
  //      签名里的命名参数也用花括号：`Widget f(a, {required X x}) {`
  //      → `indexOf('{', i)` 会命中**参数列表**（实测 `_mnemonicBlock` 只切到 24 字符）。
  //   ✅ 找「`)` + 可选 `async` + 可选空白 + `{`」—— 那才是方法体开始。
  //
  //   🔴 坑 5（2026-09-28 撞到，本坑真实漏判过一次）：
  //      **`async` 关键字**！`Future<void> _openMember(...) async {`
  //      → 只认 `\)\s*\{` 会**跳过真正的函数体**，继续往后匹配到方法体**内部**的
  //        `if (...) {` → 切出一个**与该方法无关的区间**（既不空、也不对 → 危险）。
  //      症状：`_openMember` 里明明有 `LookupSheet.show(`，断言却报红。
  //      ⚠️ 更坏的情形是**反向断言** —— 切错区间后 `contains` 为 false → 假绿。
  //      🔑 教训：**切片函数本身也会漏**；切片错时先怀疑切片，别急着怀疑实现。
  final bodyOpen = RegExp(r'\)\s*(?:async\s*)?\{').firstMatch(src.substring(i));
  final start = bodyOpen != null ? i + bodyOpen.end - 1 : src.indexOf('{', i);
  return start < 0 ? '' : _braces(src, start);
}

String _repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${d.path}/app').existsSync() &&
        File('${d.path}/app/pubspec.yaml').existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

// ── ⑧ 结构不变量 ─────────────────────────────────────────────
void _s8Invariants() {
  print('\n【8】结构不变量');

  eq('三档全表齐备', allTokens.length, 3);
  check('allTokens 覆盖 ink/grid/night',
      allTokens.containsKey(ReadingTheme.ink) &&
          allTokens.containsKey(ReadingTheme.grid) &&
          allTokens.containsKey(ReadingTheme.night));
  eq('浅色档 = [ink, grid]', lightThemes.length, 2);
  check('浅色档不含 night', !lightThemes.contains(ReadingTheme.night));

  // 方案甲：墨/格 accent 必须完全相同（统一色相 → token 从 3 值降为 2 值）
  eq('方案甲 · 墨/格 accent 共用', gridTokens.accent, inkTokens.accent);
  eq('方案甲 · 墨/格 accentBright 共用', gridTokens.accentBright, inkTokens.accentBright);
  check('夜档 accent 为深底版（≠ 浅底版）', nightTokens.accent != inkTokens.accent);

  // 每档自己的 label / character 要对上
  eq('ink.label', inkTokens.label, '墨');
  eq('grid.label', gridTokens.label, '格');
  eq('night.label', nightTokens.label, '夜');
  eq('ink.character', inkTokens.character, '暖沙 · 纸感');

  // §3.8 动效常数
  eq('主题切换 280ms', CoEvoTokens.transitionDuration.inMilliseconds, 280);
  eq('按下 90ms', CoEvoTokens.pressDuration.inMilliseconds, 90);
  eq('按下 scale(.97)', CoEvoTokens.pressScale, 0.97);
  eq('松手回弹 320ms', CoEvoTokens.releaseDuration.inMilliseconds, 320);

  // 三档 themes 枚举与实例一致
  for (final (label, t) in _themes) {
    eq('$label.theme 与实例对应', t.theme, allTokens.entries.firstWhere((e) => e.value == t).key);
  }
}

// ── ⑨ 接线（防「写了但没接通」）───────────────────────────────
//
// 🔑 为什么需要这一节：设计系统最典型的失效方式**不是数值写错，而是没接上** ——
// 新 token 写好了、`app.dart` 还在用旧主题，编译器不会报错，界面照旧。
// 所以这节全是**结构级**断言（文件在不在、谁引用谁、有没有第二份实现），
// 与【1】–【8】的数值验收互补。
//
// 🔴 2026-09-27 的教训来源：本地无法 `flutter run`，改完主题**看不出来接没接上** ——
// 必须靠断言兜住。
void _s9Wiring() {
  print('\n【9】设计系统接线（防「写了但没接通」）');

  final root = _repoRoot();
  // 🔑 统一经 `_codeOnly` —— 否则「注释里提到」会冒充「代码里写了」
  String src(String p) => _codeOnly(File('$root/app/lib/$p').readAsStringSync());
  bool has(String p) => File('$root/app/lib/$p').existsSync();

  // ① 文件到位 / 旧文件已删（语义残留清理）
  check('theme_builder.dart 存在', has('theme/theme_builder.dart'));
  check('co_spacing.dart 存在', has('theme/co_spacing.dart'));
  check('旧 app_theme.dart 已删除', !has('theme/app_theme.dart'));

  // ② 全库扫描：旧概念不许复活
  final dartFiles = Directory('$root/app/lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  final legacyHits = <String>[];
  final themeDataProducers = <String>[];
  for (final f in dartFiles) {
    final s = _codeOnly(f.readAsStringSync());
    if (RegExp(r'\bAppTheme\b|\bAppThemeMode\b').hasMatch(s)) {
      legacyHits.add(f.path.split(RegExp(r'[/\\]')).last);
    }
    if (s.contains('return ThemeData(')) {
      themeDataProducers.add(f.path.split(RegExp(r'[/\\]')).last);
    }
  }
  check('全库无 AppTheme / AppThemeMode 残留', legacyHits.isEmpty,
      legacyHits.join(' · '));
  // §7.3：'不要写 3 个手写的 ThemeData' → 全库只允许一个产出点
  listEq('ThemeData 只有一个产出点', themeDataProducers, ['theme_builder.dart']);

  // ③ theme_builder：颜色必须全部来自 token
  final builder = src('theme/theme_builder.dart');
  check('导出 buildTheme(CoEvoTokens)', RegExp(r'ThemeData buildTheme\(CoEvoTokens \w+\)').hasMatch(builder));
  check('字体取 CoFonts（不另起一套）', builder.contains('CoFonts.'));
  final hard = RegExp(r'Color\(0x').allMatches(builder).length;
  check('无硬编码颜色（全部来自 token）', hard == 0, '发现 $hard 处');
  final named = RegExp(r'Colors\.(?!transparent)').allMatches(builder).length;
  check('无具名色常量（Colors.xxx）', named == 0, '发现 $named 处');

  // ④ app.dart 三件套接线
  final app = src('app.dart');
  check('app.dart 用 buildTheme()', app.contains('buildTheme('));
  check('app.dart 从 allTokens 取档', app.contains('allTokens['));
  check('app.dart 深色槽接 nightTokens', app.contains('nightTokens'));
  check('app.dart 无 duolingo 残留', !app.toLowerCase().contains('duolingo'));

  // ⑤ provider：两个字段持久化
  final prov = src('providers/theme_provider.dart');
  check('provider 用 ReadingTheme', prov.contains('ReadingTheme'));
  check('provider 有 followSystem', prov.contains('followSystem'));
  check('持久化 = 档位 + 开关 两个字段',
      prov.contains("'reading_theme'") && prov.contains("'follow_system'"));

  // ⑥ 设置页：入口跟着换
  final prof = src('screens/profile_screen.dart');
  check('设置页遍历 ReadingTheme.values', prof.contains('ReadingTheme.values'));
  check('设置页有跟随系统开关', prof.contains('setFollowSystem'));

  // ⑦ spacing 值不许漂移（325 处引用全靠它）
  final spacing = src('theme/co_spacing.dart');
  const expected = <String, double>{
    'xs': 4, 'sm': 8, 'md': 12, 'lg': 16,
    'xl': 20, 'xxl': 24, 'xxxl': 32, 'xxxxl': 48,
  };
  for (final e in expected.entries) {
    final m = RegExp('double ${e.key} = ([0-9.]+);').firstMatch(spacing);
    check('CoSpacing.${e.key} = ${e.value.toInt()}',
        m != null && double.parse(m.group(1)!) == e.value,
        m == null ? '未找到声明' : '实得 ${m.group(1)}');
  }
}

// ── ⑩ 粘土渲染层（防「参数对但没画出来」）─────────────────────
//
// 🔑 为什么需要这一节：【3】【5】验的是**参数值**，验不到「有没有真的画出来」。
// 设计系统最典型的失效方式**不是数值写错，而是写了但没接上** ——
// 参数全对、界面照旧，编译器不会报错。所以这里全是**结构级**断言：
// 用哪个 API 画的、四态齐不齐、有没有硬编码色、token 挂没挂进主题。
void _s10ClayRender() {
  print('\n【10】粘土渲染层（防「参数对但没画出来」）');

  final root = _repoRoot();
  // 🔑 统一经 `_codeOnly` —— 否则「注释里提到」会冒充「代码里写了」
  String src(String p) => _codeOnly(File('$root/app/lib/$p').readAsStringSync());
  bool has(String p) => File('$root/app/lib/$p').existsSync();

  check('clay.dart 存在', has('theme/clay.dart'));
  check('tokens_ext.dart 存在', has('theme/tokens_ext.dart'));
  if (!has('theme/clay.dart')) return;

  final clay = src('theme/clay.dart');
  final ext = src('theme/tokens_ext.dart');
  final builder = src('theme/theme_builder.dart');
  final tokens = src('theme/coevo_tokens.dart');

  // ① 必须走**真 inset**（自绘），不能停在 gradient 兜底
  //    spec §7.2：gradient 方案只有「约 80%」（圆角处会出现色带）→ 最终须 CustomPainter
  check('用 MaskFilter 实现 inset（不是 gradient 兜底）',
      clay.contains('MaskFilter.blur'));
  check('用 evenOdd 差集把圆角矩形挖空成环', clay.contains('PathFillType.evenOdd'));
  check('渲染前 clipRRect 裁剪（只留渗入内部的那半）', clay.contains('clipRRect'));

  // ② 零硬编码色 —— 视觉全部来自 token
  final hard = RegExp(r'Color\(0x').allMatches(clay).length;
  check('clay.dart 无硬编码颜色', hard == 0, '发现 $hard 处');
  final named = RegExp(r'Colors\.(?!transparent)').allMatches(clay).length;
  check('clay.dart 无具名色常量（Colors.xxx）', named == 0, '发现 $named 处');

  // ③ 四态齐全，且**都真的被 switch 覆盖**（不是只声明了枚举）
  final cases = RegExp(r'case ClayState\.(\w+):')
      .allMatches(clay)
      .map((m) => m.group(1)!)
      .toSet();
  check(
    'painter 的 switch 覆盖全部四态',
    cases.length == 4 &&
        const ['raised', 'pressed', 'selected', 'disabled']
            .every(cases.contains),
    '实得 ${(cases.toList()..sort()).join(" / ")}',
  );

  // ④ 关键语义（每条都对应 spec 明文）
  check('选中态外阴影用 accentOut（外阴影染自身色相 §3.2）',
      clay.contains('clay.accentOut'));
  check('按下态 inset 方向互换（§3.6「最容易写错的一处」）',
      clay.contains('.flipped'));
  check('禁用态外阴影减半 ×0.55（§3.7）', clay.contains('scaleAlpha(0.55)'));
  check('高度 <24px 去掉 inset（§3.5 硬规则）', clay.contains('clayNoInsetBelow'));
  check('选中填充 accent / 默认填充 clayFill（§3.3.2）',
      clay.contains('tokens.accent') && clay.contains('tokens.clayFill'));

  // ⑤ 接线：token 必须挂进主题，否则 CoEvoTokensExt.of(context) 取不到
  check('buildTheme 挂 extensions', builder.contains('extensions:'));
  check('buildTheme 挂的是 CoEvoTokensExt', builder.contains('CoEvoTokensExt(t)'));
  check('CoEvoTokensExt.of(context) 存在',
      ext.contains('static CoEvoTokens of(BuildContext'));
  check('取不到时**抛错**而非静默回退（防掩盖接线错误）', ext.contains('assert('));

  // ⑥ 为渲染层补的两个 token 能力（spec §3.6 / §3.7 需要）
  check('CoShadow.flipped 方向取反', tokens.contains('CoShadow(-dx, -dy'));
  check('CoRgba.scaleAlpha 存在', tokens.contains('CoRgba scaleAlpha'));

  // ⑦ shadow 参数到 MaskFilter 的换算必须与原生 BoxShadow 同口径
  //    （否则自绘阴影与 Material 组件会是「两种模糊味」）
  check('blur→sigma 换算与原生同口径（×0.57735+0.5）',
      clay.contains('0.57735'));

  // ⑧ 🆕 真的有人用 —— 防「组件写好了但没人接」
  //    🔑 这是接线验收的**最后一环**：组件存在 ≠ 界面用上了。
  final prof = src('screens/profile_screen.dart');
  check('设置页已接入 Clay（档位预览）', prof.contains('Clay('));
  check('设置页用**目标档**的 token 画预览（`tokens: t`）',
      RegExp(r'tokens:\s*t\b').hasMatch(prof));
  check('设置页用到 selected 态（选中＝激活，不是按下）',
      prof.contains('ClayState.selected'));
  check('Clay 支持显式 tokens（预览其它档的前提）',
      clay.contains('CoEvoTokens? tokens'));

  // ⑨ 🆕 动效（spec §3.8）—— 两条：**参数对** + **不重复定义**
  //
  // 🔑 为什么单列：动效常数在 `CoEvoTokens` 上已有单一出处，
  // 但**很容易在调用处顺手再写一遍裸值**（本轮就犯过：`clay.dart` 里
  // 另写了 `Duration(milliseconds: 90)` 和 `0.97`）→ 改 spec 时要改两处。
  final app = src('app.dart');
  check('主题切换时长取 token 常量（不写魔数）',
      app.contains('CoEvoTokens.transitionDuration'));
  check('主题切换曲线 = Curves.fastOutSlowIn',
      app.contains('Curves.fastOutSlowIn'));
  //     📌 `Curves.fastOutSlowIn` 定义为 `Cubic(0.4, 0.0, 0.2, 1.0)`
  //        （Flutter `animation/curves.dart`）—— 与 spec §3.8 写的
  //        `cubic-bezier(.4,0,.2,1)` **逐位相同**，不是近似值。
  check('按下/回弹取 token 常量（不写魔数）',
      clay.contains('CoEvoTokens.pressDuration') &&
          clay.contains('CoEvoTokens.releaseDuration') &&
          clay.contains('CoEvoTokens.pressScale'));

  // 「动效常数只有一处定义」：调用处不得出现这四个裸值
  final bareRe = RegExp(r'Duration\(milliseconds:\s*(280|90|320)\b');
  final bareHits = <String>[];
  for (final e in {'app.dart': app, 'theme/clay.dart': clay}.entries) {
    if (bareRe.hasMatch(e.value) || e.value.contains('? 0.97')) {
      bareHits.add(e.key);
    }
  }
  check('动效常数只在 CoEvoTokens 定义一处（调用处零裸值）',
      bareHits.isEmpty, bareHits.join(' · '));
}

// ── ⑪ token 插值（主题切换过渡 · spec §3.8）─────────────────
//
// 🔑 为什么需要这一节：主题切换时 `ThemeData.lerp` 会把 `colorScheme` 等平滑插值，
// 而 token 走 `ThemeExtension.lerp` —— 若它**阶跃**（t<0.5 保持原档），
// 用 token 取色的组件（粘土）会在过渡中途「啪」地跳变，与周围不协调。
//
// 但插值**不能无脑做**：几何量是某些派生值的输入，插值会造成更难看的不连续。
// 所以本节的核心是 —— **验「颜色确实插值」+「几何确实整组阶跃」**。
void _s11Lerp() {
  print('\n【11】token 插值（主题切换过渡 · spec §3.8）');

  // ① 端点短路：t=0 / t=1 必须返回**原实例**（identical）
  //    🔑 不只是省分配 —— `ClayPainter.shouldRepaint` 用 identical 判断，
  //    若稳态也返回新对象 → 每帧无谓重绘。
  var allBegin = true, allEnd = true;
  for (final (_, ta) in _themes) {
    for (final (_, tb) in _themes) {
      if (!identical(CoEvoTokens.lerp(ta, tb, 0), ta)) allBegin = false;
      if (!identical(CoEvoTokens.lerp(ta, tb, 1), tb)) allEnd = false;
    }
  }
  check('t=0 / t=1 返回原实例（三档两两共 6 组）', allBegin && allEnd);

  final ink = _themes[0].$2, grid = _themes[1].$2, night = _themes[2].$2;
  final a = ink, b = grid;

  // ② 颜色**确实插值**（不是阶跃）
  final midPage = CoRgba.lerp(a.page, b.page, 0.5);
  final expR = (a.page.r + b.page.r) / 2;
  check('颜色在中点取均值（±1 取整误差）',
      (midPage.r - expR).abs() <= 1,
      '实得 ${midPage.r} / 期望 ≈${expR.toStringAsFixed(1)}');
  check('中点色 ≠ 任一端点（确认真的插了，没阶跃）',
      midPage != a.page && midPage != b.page);
  // alpha 不取整（半透明过渡对精度敏感）
  final alphaMid = CoRgba.lerp(
      const CoRgba(0, 0, 0, 0.0), const CoRgba(0, 0, 0, 0.55), 0.5);
  near('alpha 插值不取整（0 → .55 中点为 .275）', alphaMid.a, 0.275, tol: 0.001);

  // ③ 🔴 几何**整组阶跃**（本轮最关键的判断）
  final midClay = ClayTokens.lerp(a.clay, b.clay, 0.5);
  check('radius 只取端点值（不插值）',
      midClay.radius == a.clay.radius || midClay.radius == b.clay.radius,
      '实得 ${midClay.radius}');
  check('maxSize 只取端点值', midClay.maxSize == a.clay.maxSize || midClay.maxSize == b.clay.maxSize);
  //    🔑 核心不变量：radius 与 scaleRadius **必须同侧** ——
  //    否则 radiusFor() 会在 t=0.5 跳变（见 coevo_tokens.dart 文件头 ⓪）
  check('radius 与 scaleRadius 同侧（派生量自洽）',
      (midClay.radius == a.clay.radius) == (midClay.scaleRadius == a.clay.scaleRadius));

  // ④ 🔴 端到端：`radiusFor()` 在整个过渡期间**不得跳变**
  //    这是 ③ 的可观测后果 —— 三档两两组合全扫。
  var maxJump = 0.0;
  String worst = '';
  for (final (la, ta) in _themes) {
    for (final (lb, tb) in _themes) {
      if (identical(ta, tb)) continue;
      double prev = double.nan;
      for (var i = 0; i <= 100; i++) {
        final r = CoEvoTokens.lerp(ta, tb, i / 100).clay.radiusFor(60);
        if (i > 0) {
          final jump = (r - prev).abs();
          if (jump > maxJump) {
            maxJump = jump;
            worst = '$la→$lb @t=${(i / 100).toStringAsFixed(2)}';
          }
        }
        prev = r;
      }
    }
  }
  //    阈值 2px —— **不是拍的**，依据如下：
  //    · 各档 md（高度 60）的实际圆角：墨 `26×0.55=14.3` · 格 `14×1.0=14.0` · 夜 `24×0.55=13.2`
  //      → 任意两档最大差 **1.1px**，这就是「整组阶跃」的**固有代价**
  //    · 对照：若错误地只插 `radius` 而 `scaleRadius` 仍阶跃（墨→格），
  //      跳变会是 `|11.1 − 19.9| = 8.8px`（见 coevo_tokens.dart 文件头 ⓪）
  //    → 阈值 2px 与 8.8px 相差 4 倍，**有足够区分度**：能把「固有代价」和「真写错」分开
  //
  //    🔑 为什么这个代价可以接受：1.1px 的圆角变化，在一帧内完成，肉眼基本不可察；
  //       而要消除它需把 token 结构从「基准 radius + 缩放开关」改成「三档最终半径」——
  //       会连带改 spec §3.4/§3.5 与既有【3】【5】断言，**代价远大于收益**。
  //       → 记为**已知取舍**（如实在 spec §3.8 说明），不当成 bug。
  check('radiusFor 全程无跳变（相邻步进 ≤ 2px）', maxJump <= 2.0,
      '最大跳变 ${maxJump.toStringAsFixed(2)}px${worst.isEmpty ? '' : " @ $worst"}');

  // ⑤ 字号**可以放心插值** —— 线性插值保序 → 层级不变量在过渡期间仍成立
  var hierOk = true;
  for (final (_, ta) in _themes) {
    for (final (_, tb) in _themes) {
      for (var i = 0; i <= 20; i++) {
        if (!CoEvoTokens.lerp(ta, tb, i / 20).type.hierarchyHolds) hierOk = false;
      }
    }
  }
  check('过渡期间「线索不压过答案」始终成立（字号保序）', hierOk);

  // ⑥ 两态痕迹都参与插值（不能只插 fresh）
  final midTrace = TraceTokens.lerp(a.trace, b.trace, 0.5);
  final changed = <String>[];
  if (midTrace.fresh.bg != a.trace.fresh.bg &&
      midTrace.fresh.bg != b.trace.fresh.bg) changed.add('fresh');
  if (midTrace.reviewing.bg != a.trace.reviewing.bg &&
      midTrace.reviewing.bg != b.trace.reviewing.bg) changed.add('reviewing');
  check('两态痕迹的 bg 都被插值', changed.length == 2, '实得 ${changed.join(" / ")}');

  // ⑦ 接线：`ThemeExtension.lerp` 必须真的调 `CoEvoTokens.lerp`
  final ext = _codeOnly(
      File('${_repoRoot()}/app/lib/theme/tokens_ext.dart').readAsStringSync());
  check('CoEvoTokensExt.lerp 调用 CoEvoTokens.lerp', ext.contains('CoEvoTokens.lerp('));
  check('tokens_ext 里已无阶跃实现（t<0.5 ? this : other）',
      !RegExp(r't\s*<\s*0\.5\s*\?\s*this').hasMatch(ext));
}

// ─────────────────────────────────────────────────────────────
// 【12】阅读界面零粘土（spec §八 的自动检查）
// ─────────────────────────────────────────────────────────────
void _s12Reader() {
  print('\n【12】阅读界面零粘土（spec §八）');
  final f = File('${_repoRoot()}/app/lib/screens/reader_screen.dart');
  if (!f.existsSync()) {
    check('reader_screen.dart 存在', false, '3.4a 的阅读器未见');
    return;
  }
  // 🔑 统一经 `_codeOnly` —— 否则注释里写的「零粘土」会冒充「代码里做到了」
  final code = _codeOnly(f.readAsStringSync());

  // spec §八：「阅读界面零粘土 · 可用自动检查：**阅读区容器内**不得出现粘土类」
  // 🔑 判据取「**不直接**出现 `Clay(`」：
  //    顶部栏的书签按钮是**唯一**的粘土，但它封装在 `BookmarkButton` 里 ——
  //    设计稿的 `.bm` 本就是粘土类、且卡片与阅读界面**共用同一个类**，
  //    所以那个粘土属于「书签组件」，不属于「阅读区」。
  check('正文区零粘土：阅读器不**直接**使用 Clay', !code.contains('Clay('));
  check('顶部栏书签走 BookmarkButton（粘土的单一出口）',
      code.contains('BookmarkButton('));
  check('阅读器不自绘阴影（无 BoxShadow）', !code.contains('BoxShadow('));
  check('正文痕迹走 TraceText + locateTraceMarks（不手写背景色）',
      code.contains('TraceText(') && code.contains('locateTraceMarks('));
  // 正文底色必须取主题 token，不能写死
  check('阅读底色取 token（t.read）', code.contains('t.read'));

  // ── 3.4b 追加：查词浮层与选词工具栏也必须零粘土 ──
  // 🔑 理由：浮层是**阅读场景的一部分**（spec §八「阅读区容器内不得出现粘土类」）。
  //    粘土是「交互」语汇（卡片 / 按钮 / tabbar），浮层是「内容」→ 用层级色表达。
  final sheet = File('${_repoRoot()}/app/lib/widgets/lookup_sheet.dart');
  if (sheet.existsSync()) {
    final sc = _codeOnly(sheet.readAsStringSync());
    check('查词浮层零粘土（不直接用 Clay）', !sc.contains('Clay('));
    check('浮层底色取 token（t.card）', sc.contains('t.card'));
    // 🔴 音标必须**元素级**指定 CharisSIL —— 挂 fallback 链会让 93.9% 的音标
    //    「一条音标两种字体」（spec §4.1.1）。浮层是新加的第三个音标落点（卡片、聚合页之外）。
    check('浮层音标元素级指定 CoFonts.ipaSerif',
        sc.contains('CoFonts.ipaSerif'));
    // 词性必须走归一化（47 种写法 → 词典惯例缩写），不得直接显示原始值
    check('浮层词性走 normalizePos 归一化', sc.contains('normalizePos('));
  } else {
    check('lookup_sheet.dart 存在', false, '3.4b 的浮层未见');
  }

  // ── 3.4b 修（2026-09-27）：词库预热必须是 watch ──
  //
  // 🔑 为什么这条值得用断言锁住：它**极易回归**。
  //    只 `ref.read` 的话，31.4 MB 的落盘要等到「用户第一次长按查词」
  //    那一刻才开始 → 那一刻 future 刚启动、`valueOrNull` 必然是 null
  //    → **第一次查词 100% 失败**，而文案是「正在准备，请稍候」，
  //    用户只会以为是自己点太快。
  //    ⚠️ 有人可能为了「省一次 rebuild」把它改回 `read` —— 这条断言拦的就是那个。
  check('阅读器 watch 了 wordQueryProvider（预热，不能只 read）',
      code.contains('ref.watch(wordQueryProvider)'));

  final wp = File('${_repoRoot()}/app/lib/providers/word_db_provider.dart');
  if (wp.existsSync()) {
    final wc = _codeOnly(wp.readAsStringSync());
    // 🔑 「不可用」必须是**带原因**的类型，不能是裸 `null` ——
    //    否则「平台不支持（永久）」与「还在加载（可等）」会共用一句
    //    「请稍候」，让 web 用户重试一个永远不会成功的操作。
    check('词库「不可用」带原因（sealed class，非裸 null）',
        wc.contains('sealed class WordDbLoad'));
    check('web 上提前返回「不支持」（不做注定失败的尝试）',
        wc.contains('kIsWeb') && wc.contains('WordDbUnsupported'));
    check('失败转成结果类型（不产生 AsyncError，防 when(error:) 把整页变报错）',
        wc.contains('WordDbFailed'));
  } else {
    check('word_db_provider.dart 存在', false, '3.4b 的词库 provider 未见');
  }
}

// ── ⑬ 底部栏「透明」的两处配套（防「只改一半」）─────────────────
//
// 🔑 为什么需要这一节（2026-09-27）：
//   用户反馈「底部栏很破坏视觉」。核实后发现**根因不是颜色** ——
//   `scaffoldBackgroundColor` / tabbar 背景 / 设计稿 `.phone` 三处**本来就是同一个 `page` 色**
//   （所以「把背景改成透明」不会有任何视觉变化）。真正的来源是**结构**：
//   `Scaffold(bottomNavigationBar:)` 让 tabbar 占一条**独立地带**，`body` 不含它 →
//   滚动到底时正文与按钮之间有一道**静止空白**，观感是「内容被切掉一块、下面飘着三个按钮」。
//
//   修法是**三处配套**：
//     ① `_ShellScaffold` 开 `extendBody: true`（正文延伸到底栏之后）
//     ② `_ClayTabBar` 的**毛玻璃栏底**（让正文在栏下**模糊淡出**而非硬截断）
//     ③ 各 tab 页滚动容器的底部 padding 留出 tabbar 高度（否则最后一项被按钮压住）
//
//   🔴 演进史（**四轮** · 详见 `_ClayTabBar` 类文档）：
//     ① `ColoredBox(page)` → ②「透明→page」渐隐（白哥「**渐变不好看**」）
//     → ③ 全透明 + **未选中项加凸起药丸**（白哥「**还是有割裂感**」—— 底加错了层）
//     → ④ **毛玻璃栏底 + item 回平坦** ✅
//
//   🔴 **只改一处会有问题**，而**编译器不会报错**：
//      · 只开 `extendBody` 忘了 padding → 最后一张卡片被永久遮住半截
//      · 只加 padding 不开 `extendBody` → 底部永远空一截，白改
//      · 删掉栏底却留着 `extendBody` → 正文直接压在未选中 tab 文字上（「看不清」回来了）
//   → 所以把「三处必须同时存在」写成断言。
void _s13TabBarShell() {
  print('\n【13】底部栏「毛玻璃」的三处配套（防只改一半）');

  final root = _repoRoot();
  // 🔑 统一经 `_codeOnly` —— 否则「注释里提到」会冒充「代码里写了」
  //    （本次尤其关键：`app.dart` 的文档注释里**故意**提到了 `ColoredBox` /
  //     `LinearGradient` / `Color(t.page…)`，用来记录演进史与备选方案。
  //     若不滤注释，下面「不得有背景层」这条会**假红**。）
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  const tabs = ['screens/home_screen.dart', 'screens/review_screen.dart',
      'screens/profile_screen.dart'];
  final app = src('app.dart');

  // ① body 必须延伸到 tabbar 之后
  check('_ShellScaffold 开了 extendBody: true',
      RegExp(r'extendBody:\s*true').hasMatch(app));

  // ② tabbar **必须是毛玻璃栏底** —— 这是白哥选定方案 ③ 的代码判据。
  //
  //    🔴 **必须先切出 `_ClayTabBar` 类体**再断言，不能拿全文件当范围。
  //       首版就是拿全文件跑的 → 被 `app.dart` 的**订阅弹窗遮罩**
  //       `Container(color: Colors.black54)` 撞红 —— 那处**完全合法**（modal barrier），
  //       与 tabbar 毫无关系。**断言的范围必须等于被测对象的范围**，
  //       否则「真红」与「假红」混在一起，久了就没人信断言了。
  //
  //    🔑 **本轮断言的「极性」反转了**（重要）：
  //       上一轮锁「**不得有任何背景层**」（全透明）；本轮锁「**必须有毛玻璃**」。
  //       这是设计决策变更的结果 —— 🔑 **这正是断言该有的摩擦**：
  //       改设计必须留下痕迹（改这段时会被迫重读演进史）。
  //
  //    🔴 四条各自对应一个**曾验证过的失败**：
  //      · 无 `ClipRect` → **会把整个屏幕拖进滤镜**（`BackdropFilter` 的已知陷阱）
  //      · 无 `BackdropFilter` → 退化成「实心色带」（= 第 ① 轮被否的观感）
  //      · 用渐变 → 第 ② 轮被否（卡片被雾化成**雾带**）
  //      · 背景色写裸值 → 三档色相断层（必须走 `t.tabBarSurface`）
  final clsStart = app.indexOf('class _ClayTabBar');
  final clsEnd = clsStart < 0 ? -1 : app.indexOf('\nclass ', clsStart + 1);
  final tabBar = clsStart < 0
      ? ''
      : app.substring(clsStart, clsEnd < 0 ? app.length : clsEnd);
  check('能切出 _ClayTabBar 类体（断言范围正确的前提）', tabBar.isNotEmpty);
  check('栏底用 BackdropFilter 毛玻璃（方案 ③）',
      tabBar.contains('BackdropFilter'));
  check('毛玻璃被 ClipRect 包住（否则模糊会溢出到整个屏幕）',
      tabBar.contains('ClipRect'));

  // ②-b 🔴 **性能两条**（2026-09-28 白哥实测「掉帧有点严重」后补 · 两处都是真根因）
  //
  //  ① **缺 `RepaintBoundary` → 模糊区导致「全屏重绘」**
  //     公开实测数据（Pixel 4a · 100×100 模糊区）：
  //       不加 → **全屏重绘 → 45fps**；加上 → 只重绘模糊区 → **稳定 60fps**
  //     🔑 且必须在 `ClipRect` **外面** —— 让「裁剪 + 模糊」整体成为一个独立图层。
  //  ② **`sigma` 有性能阈值** —— 资料共识：「超过 **15** 时性能消耗显著增加」，
  //     且旗舰机推荐 5–10。首版取了 **20**（超标）→ 已降到 10。
  //
  //  🔑 这两条**必须都锁**：一条管「重绘的**范围**」，一条管「单次的**成本**」——
  //     只修一个都不够（这正是本次掉帧的同时存在两个原因）。
  check('毛玻璃被 RepaintBoundary 包住（否则模糊区导致全屏重绘 · 实测 45fps）',
      tabBar.contains('RepaintBoundary'));
  check('RepaintBoundary 在 ClipRect 外层（裁剪+模糊整体成一个图层）',
      RegExp(r'RepaintBoundary\(\s*child:\s*ClipRect\(').hasMatch(tabBar));
  final sigmaM = RegExp(r'_blurSigma\s*=\s*([\d.]+)').firstMatch(tabBar);
  check('能读到 _blurSigma 常量（下面那条断言的前提）', sigmaM != null);
  if (sigmaM != null) {
    final v = double.parse(sigmaM.group(1)!);
    check('_blurSigma ≤ 15（超过 15 性能消耗显著增加；推荐区间 5–10）', v <= 15);
  }
  check('栏底色走 token 派生 t.tabBarSurface（不写裸色值 → 三档自动适配）',
      RegExp(r't\.tabBarSurface').hasMatch(tabBar));
  check('栏底不是纯色带 ColoredBox（那是第 ① 轮被否的观感）',
      !tabBar.contains('ColoredBox'));
  check('未用渐变（第 ② 轮被否：卡片被雾化成雾带）',
      !tabBar.contains('LinearGradient'));

  // ④ 🆕 未选中项 = **平坦**（2026-09-28 · 方案 ③ · 四轮演进后的定案）
  //
  //    演进：① 无底平坦（照设计稿）→ 白哥「看不清」（`extendBody` 后正文穿过）
  //          ② `pressed` + `sunken`（凹陷）→ 白哥「**凹陷的，不好看**」
  //          ③ `raised`（凸起药丸）→ 白哥「**还是有割裂感**」（**底加错了层**）
  //          ④ **平坦** ← 定案：穿透问题改由「**栏底毛玻璃**」在**栏**这一层解决
  //
  //    🔑 断言锁住「**平坦**」：不能再是 `Clay` 的**任何**形态 ——
  //       它们都会给单个 item 加实体 → 底部变三个独立物件 → 割裂感回来。
  check('未选中项**不是** Clay（平坦 = 照设计稿 `.tb`，无底无影）',
      !RegExp(r'state:\s*ClayState\.(raised|pressed)').hasMatch(tabBar));
  check('未选中项走裸 GestureDetector + Padding（平坦的实现形态）',
      tabBar.contains('GestureDetector') &&
          tabBar.contains('Padding(padding: _tabPadding'));
  check('未选中项不显式给 fill（平坦项无填充）',
      !RegExp(r'fill:\s*t\.').hasMatch(tabBar));
  //    🔴 字色必须 `ink2`：`ink3` 在**任何**候选底色上都不足 WCAG 小字 4.5
  //       （page 2.74 / sunken 2.58 / card 3.20）→ 换底色救不了，必须换字色。
  check('未选中项字色用 ink2（ink3 任何底色上都不达标）',
      tabBar.contains('t.accentInk : t.ink2'));
  //    ⚠️ 不加 detail 参数 —— `check` 的第三个参数是**无条件打印**的，
  //       通过时也显示会让报告误导（首版写了「tabBar 里仍有 t.ink3」，
  //       明明是 ✅ 却像在陈述问题）。
  check('未选中项不再用 ink3', !tabBar.contains('t.ink3'));

  // ⑤ 对比度硬校验 —— 用**实测值**验「未选中 tab 文字真的看得清」
  //
  //    ⚠️ 上面那条只验了「源码里写的是 ink2」，验不到「ink2 够不够」。
  //       若将来有人改了 `ink2` 或 `card` 的值，源码断言照样绿 ——
  //       所以必须**算一遍真实对比度**。（同 §2 用 spec 数值反验实现的思路。）
  //    🔑 底色 = **栏底基线 `page`**（`tabBarSurface` = `page` 82%）。
  //       ⚠️ 实际合成色取决于「栏后是什么内容」→ 这里取 82% 的**主导色** `page` 为基线；
  //          最坏情形（栏后是该档卡面色）已在 `CoEvoTokens.tabBarSurface` 的
  //          文档注释里**逐档算过**：墨 4.85 / 格 5.94 / 夜 7.25（均 ≥4.5）。
  print('\n  ── 未选中 tab 的文字对比度（11px 小字 → 要求 4.5）──');
  for (final (label, t) in _themes) {
    final cr = t.ink2.contrastWith(t.page);
    check('$label · 未选中 tab 文字 ink2 ↔ 栏底基线 page ≥ 4.5',
        cr >= 4.5, cr.toStringAsFixed(2));
  }
  // 🔑 反向断言：记录「为什么不能用 ink3」—— 它在**三种**候选底色上都必须不达标。
  //    若哪天 ink3 达标了，说明 token 被改过，这些断言会一起提示复核。
  for (final (label, t) in _themes) {
    for (final (name, bg) in [
      ('page', t.page),
      ('sunken', t.sunken),
      ('clayFill(card)', t.clayFill),
    ]) {
      final cr = t.ink3.contrastWith(bg);
      check('$label · （对照）ink3 ↔ $name 确实 < 4.5，故不能用',
          cr < 4.5, cr.toStringAsFixed(2));
    }
  }

  // ③ 三个 tab 页的滚动容器都要留出 tabbar 高度
  for (final p in tabs) {
    final s = src(p);
    check('$p 底部留白用 CoSpacing.tabBarClearance',
        s.contains('CoSpacing.tabBarClearance'));
    // ⚠️ **反向检查**：常量已定义 ≠ 调用处不会重写裸值。
    //    （本项目已踩过：token 层有定义，调用处又写 `90/320/0.97`。）
    check('$p 未用裸值当底部留白（不许绕过常量）',
        !RegExp(r'fromLTRB\([^)]*\b100\b').hasMatch(s));
  }

  // ④ 常量本身：值必须与 `_ClayTabBar` 的实际高度匹配
  final spacing = src('theme/co_spacing.dart');
  check('CoSpacing.tabBarClearance = 100（与 _ClayTabBar 内边距耦合，改一边要改两边）',
      RegExp(r'tabBarClearance\s*=\s*100;').hasMatch(spacing));
}

// ── ⑭ 收藏清单（3.5）────────────────────────────────────────
//
// 🔑 为什么需要这一节：收藏清单是最容易「做歪」的一屏 ——
//   它看起来像「新页面」，但设计稿明说**没有新界面**：
//   > 「同一套卡片组件，只是筛选过 —— **没有新界面要设计**。」
//
//   所以三类断言，每类对应一个**已定义的具体失效方式**：
//     ① **路由形态** —— 挂成子路由（保留 tabbar）。挂成顶层路由就变成全屏，
//        与设计稿 mockup 不符，且「收藏是视图非 tab」的产品原则被破坏。
//     ② **复用 `FeedCard`** —— 重写一套卡片会让「同一套组件」退化成两份实现
//        （本项目已确立：「设计稿里是同一个类 → 实现里就该是一个东西」）。
//     ③ **空状态的教学性** —— 设计稿要求「**教会用户书签在哪**」，
//        而不是只说「没有内容」→ 断言那行引导**真的在**。
void _s14BookmarkList() {
  print('\n【14】收藏清单（3.5 — 设计稿：「没有新界面要设计」）');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  bool has(String p) => File('$root/app/lib/$p').existsSync();

  // ① 文件到位
  check('bookmark_list_screen.dart 存在', has('screens/bookmark_list_screen.dart'));
  check('bookmark_toggle.dart 存在（信息流与清单**共用**同一交互）',
      has('widgets/bookmark_toggle.dart'));
  if (!has('screens/bookmark_list_screen.dart')) return;

  final screen = src('screens/bookmark_list_screen.dart');
  final app = src('app.dart');
  final home = src('screens/home_screen.dart');

  // ② **路由形态**：必须是 `/home` 的**子路由**（相对路径 = 无前导 `/`）
  //
  //    🔑 判据用「相对路径」而不是去解析嵌套结构：
  //       go_router 里**带前导 `/` 是绝对路径（顶层，脱离 shell）**，
  //       不带则是子路由（留在 shell 分支的 Navigator 内 → **tabbar 保留**）。
  //       所以「有相对路径」+「没有同名绝对路径」= 形态正确，且不依赖文件结构。
  check('收藏清单编在 shell 分支内（`path: \'bookmarks\'` 无前导斜杠）',
      RegExp(r"path:\s*'bookmarks'").hasMatch(app));
  check('未把它做成顶层路由（`/bookmarks` 会脱离 shell → 失去 tabbar）',
      !RegExp(r"path:\s*'/bookmarks'").hasMatch(app));

  // ③ **复用 `FeedCard`**，不许自造卡片
  check('清单复用 FeedCard（设计稿：「同一套卡片组件，只是筛选过」）',
      screen.contains('FeedCard('));
  //    ⚠️ 反向检查：不许自己拼一个「看起来像卡片」的容器
  //    （判据：清单页里**不应**出现卡片专属的元信息行拼装 ——
  //      `FeedItem.meta` 注释已声明「卡片和收藏清单共用……格式必须只定义一次」）
  check('清单未自行拼卡片元信息（不许绕过 FeedItem.meta）',
      !screen.contains('item.category') && !screen.contains('\' · \''));

  // ④ **空状态的教学性**（设计稿：「教会用户书签在哪」）
  check('空状态存在', screen.contains('_EmptyState'));
  check('空状态用粘土凹陷圆环（ClayState.pressed）',
      screen.contains('ClayState.pressed'));
  check('空状态有「书签在哪」的引导行（不是只说「没有内容」）',
      screen.contains('在卡片上找这个'));
  check('空状态引导用真实书签图标（设计稿：「用真实图标做引导」）',
      screen.contains('Icons.bookmark_border'));

  // ⑤ **共用交互**：两处都调同一个函数，不许各写一份 toast
  check('信息流用共用 toggleBookmarkWithToast',
      home.contains('toggleBookmarkWithToast('));
  check('收藏清单也用同一个 toggleBookmarkWithToast',
      screen.contains('toggleBookmarkWithToast('));
  //    🔴 反向：不许再有「自己写 SnackBar + 设计稿文案」的第二份实现
  //    （判据：设计稿规定的那句 toast 文案只应出现在**共用函数**里）
  final toggleFile = src('widgets/bookmark_toggle.dart');
  check('toast 文案只在共用函数里定义一次（不许第二份）',
      toggleFile.contains('可在「收藏」里重读') &&
          !home.contains('可在「收藏」里重读') &&
          !screen.contains('可在「收藏」里重读'));

  // ⑥ **入口**：首页标题栏右侧必须有「收藏 N」（否则清单页根本进不去）
  //
  //    ⚠️ 2026-09-28（3.4d）**断言对象改了**：`_BookmarkEntry` → `_HeaderChip`
  //       （生词入口与它共用同一个组件）。判据从「类名」改为**文案** ——
  //       类名是实现细节，**文案才是设计稿规定的东西**。
  //       🔑 断言越贴近「被保护的对象」越不易碎（改实现不该报红，改语义才该报红）。
  check('首页标题栏有收藏入口（文案为「收藏」）', home.contains("label: '收藏'"));
  check('入口指向 /home/bookmarks（与 ② 的路由一致）',
      home.contains('/home/bookmarks'));
  //    🔑 计数按设计稿呈现（`.bm-entry .n{font-size:10.5px;opacity:.7}`）
  //
  //    ⚠️ 2026-09-28：计数渲染已移入**公共组件** `widgets/header_chip.dart`
  //       → 断言对象**必须跟着搬**。继续查 `home` 会**假绿**：
  //         那里已无任何渲染代码（只剩一次调用）。
  //       🔑 又一次「断言范围必须等于被测对象」。
  final chip = src('widgets/header_chip.dart');
  check('药丸渲染在公共组件里（首页与复习页**共用一处定义**）',
      has('widgets/header_chip.dart') && chip.isNotEmpty);
  check('入口计数按设计稿呈现（`.bm-entry .n` 的 opacity:.7）',
      chip.contains('opacity: 0.7'));
  //    🆕 入口走**统一实现** —— 防「再有一个入口时另写一份」
  //
  //    ⚠️ 2026-09-28 修正：原断言是 `RegExp(r'_HeaderChip\(')` **计数 ≥ 2**，
  //       名义上「两个入口共用」，实际**把构造函数定义也数进去了**
  //       （`const _HeaderChip({` 同样匹配 `_HeaderChip(`）→ 即使只剩一个调用
  //       也照样 ≥2 → **假绿**。
  //       🔑 这是「文本断言的范围纪律」问题：**计数类断言必须排除定义处**。
  //    生词入口已于当天下线 → `_HeaderChip` 只有收藏一个消费者，不再计数。
  check('首页标题栏入口用公共组件 HeaderChip（统一实现，不另写一份）',
      home.contains('HeaderChip('));

  // ⑦ **extendBody 配套**：清单页也要留出 tabbar 高度，否则最后一张卡被压住
  //    （同三个 tab 页的处理 —— 少一处就出现「最后一条看不到」）
  check('清单页底部留白用 CoSpacing.tabBarClearance',
      screen.contains('CoSpacing.tabBarClearance'));

  // ⑧ **不许用 `when(error:)` 之外的方式撒谎**：
  //    库不可用时要给**准确**提示，不能显示成「还没有收藏」
  //    （用户明明收藏过 → 谎报是比报错更糟的失效）
  check('库不可用态有独立处理（不冒充「没有收藏」）',
      screen.contains('_Unavailable'));
}

// ── ⑮ 导航：侧滑返回 + 返回入口 ─────────────────────────────────────
//
// 🔑 为什么需要这一节（2026-09-28 白哥：「每个页面应该加上左滑退出，
//    尤其收藏列表根本没有返回按钮」）：
//
// **侧滑返回不是「路由」自带的能力，它由「转场 builder」提供。**
//   `CupertinoPageTransitionsBuilder.buildTransitions` 委托
//   `CupertinoRouteTransitionMixin.buildPageTransitions`，后者内部包了
//   `_CupertinoBackGestureDetector`（`flutter/lib/src/cupertino/route.dart:253`）。
//
// → 于是有两种**静默**关掉侧滑的方式，**编译器都不会报错**：
//   ① 不配 `pageTransitionsTheme` → Android 默认走 `PredictiveBack`（无 iOS 风格侧滑）
//      ⚠️ 本项目「产品只做 iOS、Android 是开发期验证载体」→ 不统一就**根本验不了**
//   ② 用 `CustomTransitionPage` 自定义转场 → **绕过 theme** → 手势消失
//      （`/article/:id` 与 `/chat` 原先就是这样，实测无侧滑）
//   → 两条都写成断言。
void _s15Navigation() {
  print('\n【15】导航：侧滑返回 + 返回入口');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final theme = src('theme/theme_builder.dart');
  final bm = src('screens/bookmark_list_screen.dart');

  // ① 转场统一 —— 侧滑手势的唯一来源
  check('theme_builder 配置了 pageTransitionsTheme',
      theme.contains('pageTransitionsTheme'));
  for (final p in ['android', 'iOS', 'macOS']) {
    check('$p 用 CupertinoPageTransitionsBuilder（内置边缘手势检测器）',
        RegExp('TargetPlatform\\.$p:\\s*CupertinoPageTransitionsBuilder')
            .hasMatch(theme));
  }

  // ② **全库**不得出现自定义转场 —— 任何一处都会静默关掉那一页的侧滑
  //
  //    🔑 必须全库扫描而不是只看 `app.dart`：将来在别的文件里加一个
  //       `CustomTransitionPage`，同样会关掉那一页的手势，而编译器不报错。
  //    ⚠️ 经 `_codeOnly` 过滤 —— 否则「注释里解释为什么不用它」会造成**假红**
  //       （`app.dart` 的注释里**故意**提到了它）。
  final offenders = <String>[];
  for (final e in Directory('$root/app/lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final code = _codeOnly(e.readAsStringSync());
    if (code.contains('CustomTransitionPage') || code.contains('pageBuilder:')) {
      offenders.add(e.path.split(RegExp(r'[\\/]')).last);
    }
  }
  check('全库无 CustomTransitionPage / pageBuilder（两者都绕过 theme 转场）',
      offenders.isEmpty, offenders.join(', '));

  // ③ 收藏清单的**可见**返回入口（设计稿 `.bm-hd .back`）
  check('收藏清单有返回按钮（context.pop）', bm.contains('context.pop()'));
  check('返回按钮文案为「返回」', bm.contains("'返回'"));
  check('返回按钮用 accent 色（设计稿 .back{color:var(--accent)}）',
      bm.contains('t.accent'));
}

// ── ⑯ 查词写入（Step 3.4c）的接线 ────────────────────────────────
//
// 🔑 为什么需要这一节：本节锁的全是「**写了但没接通**」型的风险 ——
//    它们在**编译期完全看不出来**，而症状要真机操作才暴露：
//      · 查词写了 `lookup_event` 但**忘了** `user_word` → 生词本永远是空的
//      · 写入**没被调用**（只定义了函数）→ 同上
//      · 写入**阻塞了浮层** → 用户要等落库才看到释义
//      · 连接被**打开两次** → `singleInstance` 下互相 close（`database_closed`）
//    → 逐条写成断言。
void _s16WordWriteback() {
  print('\n【16】查词写入（3.4c）的接线');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final reader = src('screens/reader_screen.dart');
  final dbProv = src('providers/user_db_provider.dart');
  final bmProv = src('providers/bookmark_provider.dart');
  final uwRepo = src('services/user_word_repository.dart');

  // ① 写入**被真的调用**（不是「只定义了函数」）
  check('阅读器调用了查词写入（_writeBackLookup）',
      RegExp(r'_writeBackLookup\(').allMatches(reader).length >= 2,
      '应至少 1 处定义 + 2 处调用');

  // ② 🔴 **不阻塞渲染** —— 写入必须 `unawaited`（浮层先弹、写入随后）
  //    若写成 `await _writeBackLookup(...)`，用户要等落库完才看到释义。
  final unawaitedCalls =
      RegExp(r'unawaited\(_writeBackLookup').allMatches(reader).length;
  check('查词写入用 unawaited（不阻塞浮层展示）', unawaitedCalls == 2,
      '实得 $unawaitedCalls 处（应 2：命中 1 + 未命中 1）');

  // ③ 命中与未**都**要写入（白哥定 Q2：未命中也要记 lookup_event）
  check('未命中分支也写入（记 lookup_event）',
      reader.contains('spelling: text'));

  // ④ 三张表都写：lookup_event + user_word + 复习状态
  check('写 lookup_event', uwRepo.contains('recordLookup'));
  check('写 user_word', uwRepo.contains("'user_word'"));
  check('新词同时进复习队列（ReviewListQuery.upsertState）',
      reader.contains('upsertState'));

  // ⑤ 🔴 2026-10-01：**200 上限已取消** → 旧断言**反转**（防被加回来）
  //
  //    历史：这里原本断言「上限判定存在（`kUserWordLimitFree`）」等三条
  //    （含「上限时用 debugPrint 记日志」）。取消上限后那些断言若留着，
  //    **后人会照着它们把上限加回去** —— 断言即规格。
  //    🔑 判据：**删掉一个功能后，把守它的断言改成「反向断言」**，别只删。
  //    📄 `docs/review/free-tier-limit-removal-assessment-2026-10-01.md`
  //
  //    ⚠️ `src()` 会走 `_codeOnly`（只滤**整行** `//` 注释）→
  //       源码里解释「为什么删掉」的那些注释**不会**让本组断言误报。
  check('🔴 `add()` 里已无 200 上限判定（`kUserWordLimitFree` 不在了）',
      !uwRepo.contains('kUserWordLimitFree'));
  check('🔴 `AddWordResult` 里已无 `limitReached`',
      !uwRepo.contains('limitReached'));
  check('🔴 划词处已无 `limitReached` 分支（不再静默拦截）',
      !reader.contains('limitReached'));

  // ⑥ 🔴🔴 **连接只有一处打开**（防 `singleInstance` 下互相 close）
  //
  //    `sqflite` 默认 `singleInstance: true` → 第二次 open 拿到**同一个对象**，
  //    两个 provider 各自 `onDispose(close)` 会互相踩（`database_closed`）。
  //    ⚠️ **扫描时必须排除 `services/user_db.dart`** —— 它是 `openUserDb` 的
  //       **定义处**（函数签名里就有 `openUserDb(`），不排除会把它算成「打开者」。
  //       🔑 这是「扫源码文本的断言语境」问题：**定义**与**调用**同名，
  //          必须靠「文件是不是定义处」来区分，而不是只看字符串。
  //    ⚠️ 且**不能写 `path.endsWith('services/user_db.dart')`** ——
  //       Windows 的分隔符是 `\`，那个判断恒为 false（排除不掉）。
  //       → 用**文件名**判断（跨平台安全）。
  const defFile = 'user_db.dart';
  final allLib = Directory('$root/app/lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => (
            f.path.split(RegExp(r'[\\/]')).last,
            _codeOnly(f.readAsStringSync())
          ))
      .where((e) => e.$1 != defFile) // ← `openUserDb` 的定义处，排除
      .toList();
  final openers = allLib
      .where((e) => e.$2.contains('openUserDb('))
      .map((e) => e.$1)
      .toList();
  check('🔴 全库只有 user_db_provider 打开 user.db（连接所有权唯一）',
      openers.length == 1 && openers.first == 'user_db_provider.dart',
      openers.join(', '));
  check('user_db_provider 是唯一 close 点（ref.onDispose）',
      dbProv.contains('ref.onDispose'));
  check('🔴 bookmark_provider **不再**自己 open / close（改用共享连接）',
      !bmProv.contains('openUserDb(') && !bmProv.contains('ref.onDispose'));
  check('bookmark_provider 依赖 userDbProvider',
      bmProv.contains('userDbProvider'));

  // ⑦ DDL 只从 asset 读一次（不是各处硬编码）
  check('DDL 走 kUserDbSchemaAsset（单一出处）',
      dbProv.contains('kUserDbSchemaAsset'));

  // ⑧ 写入失败**只记日志**（不得因写库失败让用户看不到释义）
  check('写入失败被 catch 且只 debugPrint',
      RegExp(r'catch \(e, st\)').hasMatch(reader) &&
          reader.contains('[lookup] 写入失败'));
}

// ── ⑰ 复习页（单一列表）的接线 ──────────────────────────────────
//
// 🔴 本节的历史（**两次都由白哥实测暴露**，两次都是「编译器看不出来」的失效）
//
// ① 2026-09-28 上午 · 白哥：「查词没有进入复习 tab」
//    → 查清 3.4c 只做了**写入端**，**没有任何界面读 `user_word`**
//    → 当时补了 `/home/words`（§17 的最初版本）
//
// ② 2026-09-28 中午 · 白哥：「**生词本不是一个单独的页面，
//    生词本和复习 tab 是一个东西**」
//    → 独立页**方向错了** → 改为**重写复习页**（本节的当前版本）
//    → 依据 `ui-ux-refactor-assessment-2026-09-25.md` §6.2
//      （🔑 这条规格 **2026-09-25 就已定稿**，白哥原话：
//       「生词本就是复习管理，其实复习页面只要一个就行了……就不要移入移出了」）
//
// 🔑 教训：**「写了页面」≠「接对了数据源」**。本节锁的都是这类风险：
//   · 复习页读错源（读 `bookmark` 或**后端 `plans`**）→ 列表永远空 / 显示别的东西
//   · K12 残留没清干净（`DueCard` / `ChatClient`）→ 页面**偷偷依赖登录态**
//   · 暂停过滤漏了 → 暂停过的词还在列表里
//   · 三条查询（list / count / dueCount）筛选不一致 →「顶部说 5 个该看，列表只数出 3 个」
void _s17ReviewList() {
  print('\n【17】复习页（单一列表）的接线');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final page = src('screens/review_screen.dart');
  final prov = src('providers/review_list_provider.dart');
  final q = src('services/review_list_query.dart');
  final home = src('screens/home_screen.dart');
  final app = src('app.dart');

  // ① 数据源正确：**端侧** `card_review_state`（经 `reviewListProvider`）
  check('复习页用 reviewListProvider', page.contains('reviewListProvider'));
  check('provider 走 ReviewListQuery', prov.contains('ReviewListQuery'));
  check('查询主表是 card_review_state', q.contains('FROM card_review_state'));

  // ② 🔴 K12 残留必须清干净 —— 这些都是「编译能过、运行才发现」的
  check('复习页不再读后端 plans（K12 遗留）', !page.contains('planProvider'));
  check('复习页不再用 DueCard / ChatClient（K12 遗留）',
      !page.contains('DueCard') && !page.contains('ChatClient'));
  check('复习页不再含 AI 出题测验（_isAiQuiz / VerifyQuestion）',
      !page.contains('_isAiQuiz') && !page.contains('VerifyQuestion'));
  //    产品原则：除生词表上限外不验证登录态
  check('复习页不依赖登录态（无 authProvider）', !page.contains('authProvider'));

  // ③ 🔴 暂停过滤：**三条查询都必须** JOIN + 过滤
  //    这是「单一列表」的数据基础（§6.2.1：「一个词离开视野，是它的状态变了」）
  //    🔑 少一条就会出现「列表与计数对不上」
  final joins = RegExp(r'LEFT JOIN user_word uw').allMatches(q).length;
  check('list / count / dueCount 三条都 LEFT JOIN user_word（应 ≥3）',
      joins >= 3, '实得 $joins');
  final paused = RegExp(r'COALESCE\(uw\.deleted, 0\) = 0').allMatches(q).length;
  check('三条都过滤「已暂停」（应 ≥3）', paused >= 3, '实得 $paused');

  // ④ 三档排序齐全，且**都带 `crs.` 前缀**
  //    🔴 不加限定：JOIN 后 `spelling` / `updated_at` 两表同名 →
  //       SQLite 直接报 `ambiguous column name`（运行期炸，编译期无声）
  for (final k in ['orderMemoryCurve', 'orderRecent', 'orderAlphabetical']) {
    check('排序档 $k 存在', q.contains(k));
  }
  check('🔴 排序串都带 crs. 前缀（JOIN 后避免 ambiguous column）',
      q.contains('crs.next_review_at ASC') &&
          q.contains('crs.updated_at DESC') &&
          q.contains('crs.spelling COLLATE NOCASE ASC'));

  // ⑤ 筛选（白哥 2026-09-28 新增「显示全部 / 显示已到期」）
  check('数据层支持 dueOnly 筛选', q.contains('dueOnly'));
  check('界面有筛选切换', page.contains('dueOnly'));
  //    🔴 筛选按钮与首页「收藏」入口**外观一致**（白哥 2026-09-28）
  //
  //    🔑 做法**不是**「把两处参数抄成一样」，而是**共用同一个组件** ——
  //       抄参数会在下次只改一处时**静默走偏**（编译器看不出来，
  //       往往到真机才被发现）。同 `toggleBookmarkWithToast` 的判据。
  //    ⚠️ 反向：复习页**不许**再自写一份筛选药丸。
  check('🔴 筛选用公共组件 HeaderChip（与收藏入口同一处定义）',
      page.contains('HeaderChip('));
  check('🔴 复习页不再自写筛选药丸（`_FilterChip` 已删）',
      !page.contains('_FilterChip'));

  // ⑥ 分组走**数据层**静态方法（不在 UI 里重算「是否到期」）
  check('分组走 ReviewListQuery.group（不在 UI 重算到期）',
      page.contains('ReviewListQuery.group'));

  // ⑦ 暂停 = 软删（`pause` → `deleted = 1`）+ 刷新，**不是 DELETE**
  check('暂停走仓储的 pause（软删）', page.contains('repo.pause('));
  //    🔴 **2026-09-28 机制反转**：刷新不再靠「写端点名 invalidate 每个读端」，
  //       改为「**写端 bump 修订号，读端自己 watch**」——
  //       见「【18】库修订号」一节（那里锁全貌）。
  //
  //       ⚠️ 本两条断言**必须跟着反转**，否则它会一直报红；
  //          更糟的是：有人为了让它变绿，会把 `invalidate` 加回来
  //          → **断言反向驱动实现**，两套机制并存（本项目明令禁止）。
  //       🔑 「反转型断言」：决策反转时，断言方向必须同步反转。
  check('🔴 暂停后 bump 修订号（写端不必点名读端）',
      page.contains('revision.bump()'));
  check('🔴 暂停处不再点名 invalidate（防两套机制并存）',
      !page.contains('invalidate(reviewListProvider)') &&
          !page.contains('invalidate(reviewDueCountProvider)'));

  // ⑧ 入口：**底部 tab 就是入口**，标题栏不再放按钮
  //
  // 🔴 2026-09-28 白哥：「阅读页面的『生词』按钮要取消」。
  //    🔑 顺着规格读就通了：**生词本 ≡ 复习页**（`ui-ux` §6.2），
  //       而复习**本身就是底部的一个 tab** —— 标题栏那个按钮
  //       只是「再切一次 tab」，等于把导航按钮做了第二遍。
  //
  //    ⚠️ 原断言写的是「首页标题栏**有**生词入口」→ 现已**反转为「不应有」**。
  //       断言跟着决策反转时，**必须同步改方向**，否则它会一直报红
  //       （或更糟：有人为了让它变绿而把入口加回来）。
  check('🔴 首页标题栏**不再有**生词入口（白哥 2026-09-28 取消）',
      !home.contains("label: '生词'") && !home.contains('/review'));
  check('🔴 已无 /home/words 独立页（路由与页面都已删）',
      !home.contains('/home/words') && !app.contains("path: 'words'"));
  //    🔴 K12 旧生词本页（904 行，`plan`/概念卡/时间线）—— 2026-09-28 删除
  check('🔴 K12 旧生词本 card_list_screen 已删',
      !File('$root/app/lib/screens/card_list_screen.dart').existsSync());

  // ⑨ 搜索：**默认收起为左上角图标，点击才展开**（白哥 2026-09-28）
  //
  // 🔑 理由：搜索是**低频**动作，常驻一行会把「今天该复习什么」挤下去。
  // 🔴 关键约束：**收起时必须一并清空搜索词** ——
  //    否则界面收起后看不出「列表正被筛着」→ 用户会以为**词丢了**。
  //    （「界面状态必须与数据状态一致」的实例。）
  //
  //    ⚠️🔴 这条**必须取方法体切片再断言**，不能用全文件 `contains`：
  //       输入框里的 ✕ 按钮**也有** `copyWith(search: '')`（只清空输入、不退出搜索）→
  //       全文件 contains 在「_collapseSearch 已不清空」时**仍然为绿** = 假绿。
  //       （实测：证伪时把 _collapseSearch 改成 `_args = _args` 后，全文件断言照样通过。）
  //       🔑 「文本断言的**范围**必须等于被测对象」—— 先切片，再断言。
  check('搜索默认收起（_searchExpanded 状态）', page.contains('_searchExpanded'));
  check('展开时请求焦点（不必再点一次输入框）',
      page.contains('requestFocus()'));

  //    🔴 **位置**（白哥 2026-09-28）：搜索入口在「记忆曲线 / 最近 / A–Z」
  //       **排序行的最右侧**（此前在标题栏最左侧）。
  //
  //       ⚠️ 这里**必须切片**：全文件 `contains('_SearchIconButton')` 在
  //          「入口被放回标题行」时**照样为绿** → 位置改动**完全抓不到**。
  //       🔑 「断言范围必须等于被测对象」：被测的是**位置**，
  //          就必须断言它**在哪个方法体里**、以及**不在哪个**里。
  final sortBar = _braceBody(page, '_sortBar');
  final headerBar = _braceBody(page, '_header');
  check('能切出 _sortBar / _header 方法体（位置断言的前提）',
      sortBar.isNotEmpty && headerBar.isNotEmpty,
      sortBar.isEmpty || headerBar.isEmpty ? '切不出：确认方法是否改名' : '');
  //    🔑 切片「非空」还不够 —— 调用处先于定义处出现时，slice 会**非空但错位**
  //       （`_braceBody` 已修为优先匹配定义处；这里再加一道特征校验）
  check('切片确实是 _header（含标题文案「复习」）', headerBar.contains('复习'));
  check('🔴 搜索入口在**排序行**内（白哥定的位置）',
      sortBar.contains('_SearchIconButton'));
  check('🔴 搜索入口**不在标题行**（否则等于没搬）',
      !headerBar.contains('_SearchIconButton'));
  check('搜索入口被推到该行**最右侧**（用 Spacer，不写死间距）',
      sortBar.contains('Spacer()'));
  check('展开态也留在排序行（排序 chip 让位 → 列表不位移）',
      sortBar.contains('_searchField') && sortBar.contains('_cancelSearch'));

  final collapse = _braceBody(page, '_collapseSearch');
  // 🔑 切片必须非空 —— 否则「方法改名/删除」会让断言**空串通关**（另一种假绿）
  check('能切出 _collapseSearch 方法体（断言范围正确的前提）',
      collapse.isNotEmpty,
      collapse.isEmpty ? '切不出方法体，确认方法是否改名' : '');
  check('🔴 收起搜索时同步清空搜索词（界面与数据不许不一致）',
      collapse.contains("copyWith(search: '')"));
  check('🔴 收起搜索时同时复位展开态',
      collapse.contains('_searchExpanded = false'));

  // ⑩ 两种空状态 + 库不可用态都要分开（不撒谎）
  check('库不可用有独立处理（不冒充「还没有生词」）', page.contains('_Unavailable'));
  check('空状态区分「真的没有」与「被筛掉」', page.contains('_EmptyState'));

  // ⑪ 零硬编码色 + 底部避让（与三个 tab 页 / 收藏清单同一处理）
  check('页面不留裸色值（颜色全部走 token）',
      !RegExp(r'Color\(0x').hasMatch(page) && !page.contains('Colors.'));
  check('底部留白用 CoSpacing.tabBarClearance（extendBody 配套）',
      page.contains('CoSpacing.tabBarClearance'));

  // ⑫ 翻卡（第二步 · 白哥 2026-09-28「做成可点，连带做词卡」）
  //
  // 🔴 本节锁的仍是「编译器看不出来」的接线：
  //   · 行看起来能点但**没有 onTap** → 静默无效（本项上一轮的真实缺陷）
  //   · 评级只写 `card_review_state` 忘了 `review_log` → **历史永久丢失**
  //   · 四键的「下次 X 天」自己算 → 与提交结果**不一致**（用户看到的后果是假的）
  //   · 翻卡队列用活列表 → 每评一张索引就错位
  //
  // ⚠️ 2026-09-28 改：翻卡**已提升为顶层路由**（见 ⑬），实现分散到
  //    `review_session_screen.dart` + `review_session_provider.dart` →
  //    本节断言随之改读那两个文件（否则会一直报红）。
  final cardW = src('widgets/word_card.dart');
  final prov2 = src('providers/review_list_provider.dart');
  final sess = src('screens/review_session_screen.dart');
  final sessProv = src('providers/review_session_provider.dart');

  // ① 列表项：显示释义 + **真的可点**
  check('列表项显示释义（设计稿 §02 的四要素之一）',
      page.contains('row.definition'));
  check('🔴 列表项真的可点（Clay 有 onTap → 不是「看起来能点」）',
      page.contains('onTap: onOpen'));

  // ② 翻卡队列必须是**快照**（在会话 provider 里）
  //    否则提交后该词离开「今天该复习」分组 → 索引错位（评完一张跳过一张）
  check('翻卡队列是冻结快照（不是每帧读 provider）',
      sessProv.contains('List.of(rows)') && sessProv.contains('final List<ReviewRow> queue'));

  // ③ 🔴 评级写**两张表**（缺一不可）
  check('🔴 评级写 card_review_state（排序依据）', sess.contains('upsertState('));
  check('🔴 评级写 review_log（同步 + 统计的唯一来源）',
      sess.contains('logReview('));

  // ④ 🔴 评分来源：**拼写判定**（白哥 2026-09-28 用考核取代了自评四键）
  check('🔴 评分来自拼写判定（gradeSpelling + ratingForSpelling）',
      sess.contains('gradeSpelling(') && sess.contains('ratingForSpelling('));
  check('🔴 已无自评四键（_RatingKey 已删）',
      !sess.contains('_RatingKey') && !cardW.contains('_RatingKey'));
  check('评分与提交共用同一个 FsrsService（fsrsServiceProvider）',
      sess.contains('fsrsServiceProvider'));
  //    ⚠️ 「四键预览走 previewAll」这条已随四键一起删除 ——
  //       考核只需「对/错」两个分支，不需要预先算四个间隔；
  //       结果态显示的是 `apply` 的**真实产出**，不是预测。

  // ④b 🔴 考核**不能泄露答案**（否则整个考核失效，且看不出来 ——
  //     用户会「答对」，但那不代表他记得）
  final promptBody = _braceBody(cardW, 'WordPromptView');
  // 🔴 这条**不只是**防空串 —— 它防「切片切到构造函数体」这种**范围偏小**的失败。
  //    没有它，下面所有「不得含 X」都会假绿（一个空壳切片不含任何东西）。
  check('能切出 WordPromptView **类体**（含 @override，而非构造函数体）',
      promptBody.isNotEmpty && promptBody.contains('@override'));
  check('🔴 题面不含**单词本身**（它就是答案）',
      !promptBody.contains('card.spelling'));
  check('🔴 题面不含**记忆法**（①②是为记这个词服务的，给了等于给答案）',
      !promptBody.contains('_mnemonicSlots') &&
          !promptBody.contains('profile'));
  check('🔴 题面不含**语境原句**（语境句里通常就含这个词）',
      !promptBody.contains("'context'"));
  // 🔄 2026-09-28 21:4x：断言对象从 `onSpeak` 改为 **`SpeakButton`**。
  //    🔑 为什么必须改（而不是留着）：`onSpeak` 参数已**删除** →
  //       继续断言它只会「永远为真」= **假绿**（这正是本项目判据
  //       「反转型断言必须同步翻转对象」的场景）。
  //    🔴 而且这条**现在更重要**：`SpeakButton` 是**自包含**的（不需要外部传参）——
  //       谁在 `WordPromptView` 里放一个，就**真的会把答案念出来**，
  //       而「传参控制」时代那种约束**已经不存在了**。
  check('🔴 题面不含**朗读**（喇叭会把答案念出来）',
      !promptBody.contains('SpeakButton'));
  check('题面含释义（考核的主线索）', promptBody.contains("'definition'"));

  // ④c 🔴 输入框的三个「防作弊」开关都必须是关闭的
  check('🔴 关闭自动纠错（否则拼错会被系统改成对的）',
      sess.contains('autocorrect: false'));
  check('🔴 关闭联想条（否则会提示正确拼写 = 给答案）',
      sess.contains('enableSuggestions: false'));
  check('🔴 不做首字母自动大写（不替用户改输入）',
      sess.contains('textCapitalization: TextCapitalization.none'));

  // ④d 🔴 只有**到期**的词才写 FSRS（白哥定「未到期的不考」）
  //     未到期的词走浏览态 → 不打乱已算好的调度
  check('🔴 未到期的词只浏览、不写 FSRS',
      sess.contains('if (!isDue)') && sess.contains('answered'));
  check('结果态显示**正确拼写**（错了却不给正确答案 = 这个错误毫无价值）',
      sess.contains('expected'));

  // ⑤ 词卡四段 + 段落分派
  check('词卡组件存在', cardW.isNotEmpty);
  for (final seg in ['root', 'etymology', 'cognate', 'collocation']) {
    check('词卡能渲染 $seg 段', cardW.contains("case '$seg'"));
  }
  check('词卡有释义段与语境段',
      cardW.contains("label: '释义'") && cardW.contains("label: '语境原句'"));

  // ⑤-a 🔴 **搭配段：词组与中文分行**（2026-09-28 20:5x 白哥定）
  //     「搭配整记的搭配词组应该**保证显示在一行**，可以**中文一行、搭配词组一行**
  //       这样，现在的排列方式**把词组分成了两行**」。
  //
  //     🔑 根因是**布局容器**不是文案：原用 `Row` + 两个 `Flexible`（词组 ｜ 中文同行），
  //        而 `Flexible` 默认 `fit: loose` 允许子项被压窄 → `Text` 被压窄时**软换行**
  //        → 词组自己折成两行。
  //     🔑 这类「**同一份数据，换个容器就散**」的问题，编译器和 analyzer 都看不见 ——
  //        只能靠断言锁住「树形结构」。
  {
    // 切出 collocation 分支（`case 'collocation':` → 下一个 `default:`）
    // ⚠️ 不能对 `_sectionBody` 全体断言 `!contains('Row(')` ——
    //    root 分支（`_morphPart`）与 ④ 语境也各有一个 `Row`，那样会误红。
    final body = _braceBody(cardW, '_sectionBody');
    final ci0 = body.indexOf("case 'collocation':");
    final ci1 = body.indexOf('default:', ci0);
    final collBody =
        (ci0 >= 0 && ci1 > ci0) ? body.substring(ci0, ci1) : '';
    // 🔑 先断言切片非空 —— 否则下面的**反向断言会因空串假绿**
    check('🔴 搭配段断言切片非空（collocation 分支）', collBody.isNotEmpty);

    check('🔴 搭配的**词组与中文分行**（不用同行 `Row` —— 同行时词组会被挤到折行）',
        !collBody.contains('Row('),
        'Row 在不在: ${collBody.contains('Row(')}');
    check('🔴 搭配不再用 `Flexible` 压窄词组（那是折行的直接原因）',
        !collBody.contains('Flexible('));
    // 🔑 两档间距必须**拉开差距**：词组↔中文 2px ／ 条↔条 10px。
    //    否则每条从 1 行变 2 行后，读者分不清「哪两行是同一条搭配」。
    check('🔴 词组↔中文 2px、条↔条 10px（两档须有差距）',
        collBody.contains('height: 2') && collBody.contains('height: 10'));
  }

  // ⑤-b 🔴 **建立层级的三件套**（2026-09-28 排版整理 · 白哥「排版有点乱」）
  //
  // 🔴 为什么这一组必须存在（本轮教训）：
  //    这些**上轮全漏了**，而它们**编译器、analyzer、任何逻辑断言都看不到** ——
  //    它们不是符号、不是行为，只是「有没有那条边线 / 那个底块 / 那根色条」。
  //    → 只能靠**对照锚点 CSS**逐条写成断言，否则下次改动又会悄悄改回扁平。
  //
  // 🔑 判据（新）：**视觉「乱」先查「容器与分隔」，最后才查字号。**
  //    「排得松一点」≠「有层级」；层级靠 `border` / 凹陷底块 / 色条 / 虚线。
  //
  // 📄 逐项差异（方案 A ↔ 中途的色条版）：`docs/design/word-card-layout-refine-2026-09-28.html` §3.6
  //
  // ⚠️ 全部用**方法体切片**（`_braceBody`）—— 这些符号在卡片里出现多次
  //    （`leftBar` 在 ④、`ClayState.pressed` 在 ①②），全文件 `contains` 会互相顶替。
  final mnemBody = _braceBody(cardW, '_mnemonicBlock');
  final ansBody = _braceBody(cardW, '_answerSlots');
  final headBody2 = _braceBody(cardW, '_head');
  final blockBody = _braceBody(cardW, '_block');
  check('能切出词卡的关键方法体（结构断言的前提）',
      mnemBody.isNotEmpty &&
          ansBody.isNotEmpty &&
          headBody2.isNotEmpty &&
          blockBody.isNotEmpty,
      'mnem=${mnemBody.isNotEmpty} ans=${ansBody.isNotEmpty} '
          'head=${headBody2.isNotEmpty} block=${blockBody.isNotEmpty}');

  // ① 词头**下分隔线** —— 让「词头」成为头，不与内容黏一起
  check('🔴 词头有下分隔线（`border` + `bottom:`）',
      headBody2.contains('border:') && headBody2.contains('bottom:'));

  // ② 词头**居中**（2026-09-28 16:5x 白哥「还是方案 A 比较好」→ 回到锚点 `text-align:center`）
  //    🔄 **反转型断言**：中途断言的是「左对齐」→ 必须反转。
  //       🔑 不反转的代价是双向的：它会一直报红；更糟的是有人为了让绿
  //          **把居中删掉** —— 那是「断言反向驱动实现」。
  check('🔴 词头**居中**（锚点 `text-align:center` —— 词头是这张卡的主题）',
      headBody2.contains('CrossAxisAlignment.center') &&
          headBody2.contains('MainAxisAlignment.center'));
  check('🔴 词头不再左对齐（左对齐是中途 Q1 的选择，已撤回）',
      !headBody2.contains('CrossAxisAlignment.start'));

  // ③ ①② = **凹陷底块**（锚点 `.mnem{background:var(--sunken)}`）
  //    🔄 **反转型断言**：中途断言的是「色条 3px accent」→ 必须反转。
  //    🔑 为什么回到凹陷块而不是色条：**形状**区分（有底 / 留白）不需要比参数，
  //       而两者同为竖线时只能靠 5 个参数硬分（设计稿 §3.5）。
  check('🔴 ①② 有**凹陷底块**（Clay pressed + `sunken` 底 + radius 16）',
      mnemBody.contains('sunken: true') &&
          blockBody.contains('ClayState.pressed') &&
          blockBody.contains('fill: t.sunken') &&
          blockBody.contains('_mnemRadius'),
      'mnem.sunken=${mnemBody.contains('sunken: true')} '
          'block.clay=${blockBody.contains('ClayState.pressed')}');
  check('🔴 ①② **不再**用左侧色条（与 ④ 同形 → 会被读成同类）',
      !mnemBody.contains('leftBar'));

  // ④ ④ 语境的左侧色条 = **2px `accentBright`**（原用 `line`，浅到看不见）
  check('🔴 ④ 语境色条用 accentBright（2px，不是 line）',
      ansBody.contains('leftBar: Color(t.accentBright.argb32)') &&
          ansBody.contains('leftBarWidth: 2'));
  check('🔴 语境不再用 `line` 做边框（浅到几乎看不见 = 白设）',
      !ansBody.contains('t.line.argb32'));

  // ⑤ 🔑 ①② 与 ④ **形态不同**（凹陷底块 vs 左侧竖线）
  //    ⚠️ 中途那条「粗细不同 3 vs 2」现在**没有意义了** ——
  //       它是「同形时靠参数硬分」的补丁；形态分开后，这条改成断言**形态**本身。
  check('🔑 ①② 与 ④ 的**形态**不同（①② 凹陷底块 / ④ 竖线）',
      mnemBody.contains('sunken: true') && ansBody.contains('leftBar:'));

  // ⑥ 段标签下距：③④ = **4px**（锚点 `.lab`）；①② = **8px**（锚点 `.mnem-head`）
  //    🔑 锚点里这两处**本来就不同** —— 中途统一成 4 是错的（我当时按 `.lab` 一刀切）。
  check('🔴 标签下距走 `labelGap`（不是硬编码 4），且默认值是 4',
      // ⚠️ 默认值在**签名**里，而 `_braceBody` 切的是**方法体** ——
      //    参数列表不在切片内（这正是 `_braceBody` 的边界）→ 必须分开断言，
      //    否则会像本条第一版那样：实现是对的，断言却报红。
      cardW.contains('double labelGap = 4') &&
          blockBody.contains('SizedBox(height: labelGap)'),
      'labelGap 在不在: ${blockBody.contains('labelGap')}');
  check('🔴 ①② 的标签下距是 **8px**（锚点 `.mnem-head`，与 ③④ 的 4px 不同）',
      mnemBody.contains('labelGap: 8'));

  // ⑦ 记忆法组与答案区之间 **20px**（类别切换，比段间 14/15 更大）
  //    ⚠️ 锚点的 14 是「记忆法在上」时的段间值；顺序换过 → 这个值要重定
  final mnemSlotsBody = _braceBody(cardW, '_mnemonicSlots');
  check('🔴 记忆法组上距 20px（类别切换 > 段间 14/15）',
      mnemSlotsBody.contains('SizedBox(height: 20)'));

  // ⑧ 卡片内边距 = 锚点 `.card{padding:20px 19px}`（上下**对称**）
  //    ⚠️ 中途是 `22, 4, 22, 18`，再叠一个末尾留白 18 → 实际「上 4 / 下 36」
  check('🔴 卡片内边距 19/20（锚点，上下对称）',
      cardW.contains('EdgeInsets.fromLTRB(19, 20, 19, 20)'));
  check('🔴 末尾**不再**垫额外留白（会与内边距叠加成「下 38 vs 上 20」）',
      !mnemSlotsBody.contains('SizedBox(height: 18)'));

  // ⑨ 段内间距回到锚点：标签下 4 / 音标行上 6 · gap 9 / 英文释义上 3
  //    🔄 21:4x：喇叭改用 `SpeakButton` 后，音标↔喇叭的 **gap 由组件自带**
  //       （`gapBefore: 9`）而不是外层 `SizedBox(width: 9)`。
  //       🔑 这不只是换写法：`gapBefore` 在「设置里关了朗读、喇叭不渲染」时
  //          **连间距一起消失** → 音标仍精确居中，行内不留空洞。
  //          外层 `SizedBox` 做不到（它不知道喇叭有没有渲染）。
  final hasMetaTop = headBody2.contains('SizedBox(height: 6)');
  final hasMetaGap = headBody2.contains('gapBefore: 9');
  check('🔴 音标行上距 6、gap 9（锚点 `.w-meta`；原为 7 / 10）',
      hasMetaTop && hasMetaGap,
      '上距=$hasMetaTop gap=$hasMetaGap');
  check('🔴 英文释义上距 3（锚点 `.def-en`；原为 6）',
      cardW.contains('SizedBox(height: 3)'));

  // ⑩ 词头用共用喇叭组件（规格本体在 `speak_button.dart`，见下面「喇叭总组」）
  check('🔴 词头有喇叭（走共用组件 `SpeakButton`，不再自己画）',
      headBody2.contains('SpeakButton(text: card.spelling'),
      'SpeakButton 在不在: ${headBody2.contains("SpeakButton")}');

  // ⑥ 🔴 **顺序**（白哥 2026-09-28）：「释义 + 语境原句在上，记忆法在下」
  //
  //    ⚠️ 与设计稿原稿（①② 记忆法在上）**相反** —— 这是白哥明确要求的调整。
  //    ⚠️ 必须用**位置**断言（`indexOf` 比大小），不能只看「两个都在」——
  //       后者在顺序反转时**照样为绿**。
  final iAnswer = cardW.indexOf('_answerSlots(t)');
  final iMnem = cardW.indexOf('_mnemonicSlots(t)');
  check('能定位两个槽位方法的调用处（顺序断言的前提）',
      iAnswer > 0 && iMnem > 0, 'answer@$iAnswer mnemonic@$iMnem');
  check('🔴 释义/语境在**前**、记忆法在**后**（白哥定的顺序）',
      iAnswer < iMnem, 'answer@$iAnswer mnemonic@$iMnem');

  // ⑦ 🔴 卡片①② 是**聚合页入口**（白哥 2026-09-28：「之前说词根词缀、词源故事
  //    点击应该进入聚合页，也没有实现」）
  //
  //    ⚠️ **本条是反转型断言**：它**原先**是「词卡**不**给未实现的聚合页入口加 `›`」
  //       （那时聚合页属 3.7）。现在聚合页已实现 → **方向必须反转**。
  //       🔑 若不反转：它会一直报红；更糟的是有人为了让绿而**把箭头删掉**
  //          —— 那是「断言反向驱动实现」。
  check('🔴 词卡有聚合页入口箭头（聚合页已实现 → 该给 `›`）',
      cardW.contains('›'));
  //    🔑 箭头必须**由 onTap 推导** —— 两者分开写迟早出现「有箭头没回调」
  //       （= 显示箭头却点不动 = 静默无效）
  check('🔑 箭头由 `onTap` 推导（不单独写一个 bool）',
      RegExp(r'if \(onTap != null\)').hasMatch(cardW) &&
          cardW.contains("'›'"));
  check('词卡有聚合页入口回调（onOpenAggregate）',
      cardW.contains('onOpenAggregate'));
  //    🔴 槽位必须走 `CardSlots.resolve`（排除 context/cognate + 补位），
  //       而不是直接读 `profile.primaryCode` —— 后者正是
  //       「语境原句重复显示」「同源串记铺在卡上」两个 bug 的来源。
  check('🔴 槽位走 CardSlots.resolve（不直接读 primaryCode）',
      cardW.contains('CardSlots.resolve') &&
          !RegExp(r'_sectionOf\(p\.primaryCode\)').hasMatch(cardW));
  //    🔴 这里**必须断言「被调用」而不是「存在这个方法」** ——
  //       实测证伪：删掉 `WordCardView(onOpenAggregate: ...)` 后，
  //       `_openAggregate` 的**方法定义**还在 → `contains('_openAggregate')`
  //       **照样为真** → 断言 0 红（假绿）。
  //       🔑 又一次「同一符号在别处也出现」——**定义处与调用处**是两件事。
  //          判据升级：**断言「接线」就断言调用处的特有形态**（带实参）。
  check('复习页把「打开聚合页」**调用**接上了（不是只留一个方法定义）',
      sess.contains('onOpenAggregate:') &&
          sess.contains('_openAggregate(pageId'));
  //    🔴 **路由必须真的注册** —— 页面写了但路由没接，**编译期不报错**，
  //       表现是「点了没反应」（正是白哥报过的「静默无效」那一类）。
  //       实测证伪：把 `path: '/aggregate/:pageId'` 改名后，
  //       若不写本条**全程 0 红**。
  check('🔴 聚合页路由已注册（/aggregate/:pageId）',
      app.contains("path: '/aggregate/:pageId'"));
  check('聚合页 screen 已接入路由（不是只建了文件）',
      app.contains('AggregatePageScreen'));
  check('聚合页是**顶层路由**（在 shell 之外 —— 全屏沉浸态）',
      app.indexOf("path: '/aggregate/:pageId'") >
          app.indexOf('StatefulShellRoute'));

  // ⑧ 聚合页结构（2026-09-28 19:3x 白哥定：成员行**平坦 + 可点** · 顶栏/页头/词列一起改）
  //
  // 🔑 这一组守的是**编译器看不见的东西** —— 容器形状（平坦 vs 粘土）与
  //    「看起来能不能点」都不出现在类型里，任何 analyzer 规则都抓不到。
  //    而它们正是**已定禁忌**的直接体现：「凸起但不可点」= 静默无效。
  {
    final agg = src('screens/aggregate_page_screen.dart');
    final rowBody = _braceBody(agg, '_MemberRow');
    final topBody = _braceBody(agg, '_TopBar');
    final openBody = _braceBody(agg, '_openMember');
    final bodyBody = _braceBody(agg, '_body');

    // ⚠️ 先断言**切片非空** —— 否则下面所有 `contains` 都不可信：
    //    正项会因空串报红（噪音），**反项会因空串「假绿」**（危险）。
    //    🔑 这是本项目「切片四坑」的固定搭配动作（见 skill `verifiable-core-logic`）。
    check('聚合页断言切片非空（_MemberRow / _TopBar / _openMember / _body）',
        rowBody.isNotEmpty &&
            topBody.isNotEmpty &&
            openBody.isNotEmpty &&
            bodyBody.isNotEmpty,
        'row=${rowBody.length} top=${topBody.length} '
            'open=${openBody.length} body=${bodyBody.length}');

    // ── 成员行：平坦 ──
    check('🔴 成员行**平坦**（不用 Clay —— 20+ 行粘土卡又重又噪）',
        !rowBody.contains('Clay('));

    // ── 成员行：可点 ──
    check('🔴 成员行**可点**（InkWell + onTap，与「平坦」配套）',
        rowBody.contains('InkWell(') && rowBody.contains('onTap'));
    check('  有可点指示 `›`（与实际可点性**一致**）', rowBody.contains('›'));

    // ── 两列对齐 ──
    check('🔴 词列最小宽 96（锚点 .agg-w{min-width:96px}）—— 让 20+ 行能竖着扫',
        rowBody.contains('_wordMinWidth = 96'),
        'wordMinWidth 在不在: ${rowBody.contains('_wordMinWidth')}');
    check('  释义**右对齐**（锚点 .agg-z）', rowBody.contains('TextAlign.right'));

    // ── 左竖线（2026-09-28 20:1x 白哥定；20:2x 改「分段式」）──
    //    🔑 一个词条占两行（词+释义 / 分拆法），只靠底边线会串行；
    //       左竖线把两行**括成一个视觉单元**（底边线只能分隔、不能归组）。
    //    🔴 **必须用 `accentBright` 而不是 `line`** —— 项目已定判据：
    //       「左侧色条用 `line`（#EFE9DE）在浅纸上几乎看不见 = 白设了这条竖线」。
    check('🔴 成员行有**左竖线**（把「词+释义+分拆法」括成一个视觉单元）',
        rowBody.contains('Positioned(') && rowBody.contains('_barWidth'));
    check('🔴 竖线用 accentBright（不是 line —— 浅到看不见 = 白设）',
        rowBody.contains('t.accentBright.argb32'));

    // 🔴 竖线必须**分段**（白哥 2026-09-28 20:2x：「左侧的竖线是用来**分割**
    //    聚合页中的词条的，我看你在草稿中都连起来了」）。
    //    `Border(left: …)` 时竖线**必然**从行顶贯穿到行底，而行与行紧挨 →
    //    上一行的尾接下一行的头 = **一条贯穿全列表的长线** ——
    //    看着像「列表的左边框」，而不是「词条之间的分隔」。
    check('🔴 竖线**分段**（上下缩进 `_barGap` → 相邻两行之间留 12px 间隙）',
        rowBody.contains('top: _barGap') && rowBody.contains('bottom: _barGap'),
        '_barGap 在不在: ${rowBody.contains('_barGap')}');
    // 🔴 反向断言：不许回到贯穿式 `Border(left:)`。
    //    ⚠️ 不设这条的代价是双向的 —— 有人「为了让某条断言变绿」把它改回去时，
    //       正/反向断言若不同步，改坏的那一版照样全绿（本项目已踩过）。
    check('🔴 竖线**不再用 `Border(left:)`**（贯穿式 —— 行紧挨会连成一条长线）',
        !rowBody.contains('left: BorderSide'));

    // ── 🔴 跨文件一致：竖线「分段」这件事在 实现 + 三份文档 里必须是同一套 ──
    //    🔑 把判据「**改动一个已定案的决定 = 一组动作**」（实现 · 锚点 · spec ·
    //       断言 · 设计稿，漏一处就漂移回去）**变成断言**，而不是靠人记。
    {
      final docs = <String, String>{
        '锚点(L1)': 'docs/design/visual-word-card-target-2026-09-26.html',
        '方案页': 'docs/design/card-aggregate-plan-2026-09-28.html',
        '设计稿': 'docs/design/word-card-note-and-aggregate-refine-2026-09-28.html',
      };
      for (final e in docs.entries) {
        final file = File('${_repoRoot()}/${e.value}');
        check('  ${e.key} 文档存在', file.existsSync(), e.value);
        if (!file.existsSync()) continue;
        final css = file.readAsStringSync();
        check('🔴 ${e.key}：成员行竖线用 `::before` + 上下缩进（与实现同口径）',
            css.contains('.agg-item::before') &&
                css.contains('top:6px;bottom:6px'));
        check('🔴 ${e.key}：成员行**不再有**贯穿式 `border-left`',
            !css.contains('border-left:2px solid var(--accentBright);border-bottom'));
      }
    }

    // ── 顶栏：**不带族名**（2026-09-28 20:1x 白哥取消）──
    //    🔴 反向断言：它与页头的 `cept` 大字 + meta 重复显示同一信息。
    //    ⚠️ 这条**曾经是正向断言**（「顶栏有族名」），同一天内被推翻 →
    //       正是「反转型断言必须同步翻转方向」的场景（不翻会反向驱动实现）。
    check('🔴 顶栏**不带族名**（与页头重复 = 视觉噪音）',
        !topBody.contains('front') && !topBody.contains('Spacer'));

    // ── 页头：居中 + 下边线 + 词根不再抢主角 ──
    check('🔴 页头**居中**（锚点 .agg-src{text-align:center}）',
        bodyBody.contains('TextAlign.center'));
    check('🔴 页头有**下边线**（让「头」成为头，不与列表黏在一起）',
        bodyBody.contains('bottom: BorderSide'));
    check('🔴 词根本体回到 **23px**（原 30px 朱砂与族名抢主角）',
        bodyBody.contains('fontSize: 23') && !bodyBody.contains('fontSize: 30'));
    check('🔴 页头**不再渲染族名**（修掉「cept / Latin 各出现两次」）',
        !bodyBody.contains('p.front'));

    // ── 点成员 → 查词浮层 ──
    check('🔴 点成员打开**查词浮层**（`LookupSheet.show(`）',
        openBody.contains('LookupSheet.show('));

    // ── 🔴🔴 语义：**不写生词本** ──
    //    判据：`lookup()` 是纯查询；写库是阅读器**显式调用**的。
    //    聚合页点成员 = 「看看这个词」≠「我要学它」。
    //    🔑 断言**调用处的特有形态**（带括号）—— 注释里写符号名（不带括号）
    //       不会命中，所以「靠注释说明」与「靠断言守住」不冲突。
    //    ⚠️ 反向断言的假绿风险由上面「切片非空」那条兜住。
    check('🔴 点成员**不写生词本**（不出现 `_writeBackLookup(` 调用）',
        !openBody.contains('_writeBackLookup('));
    check('  词库未就绪时给**准确的话**（不留静默失败）', openBody.contains('_hint'));
  }

  // ⑨ `HeaderChip` 两态与固定宽（2026-09-28 20:1x 白哥定）
  //
  // 🔑 这三条守的是**同一天内被推翻又重定的东西**，最容易被改回去：
  //    ① 两态**一凹一凸**（原先恒 `pressed` → 两个状态看起来一样）
  //    ② 宽度**固定**（否则「全部」↔「已到期」切换时药丸跳变 ~11.5px）
  //    ③ 只改**凸凹**、**不改填充色**（否则与 `_SortChip` 的选中态撞脸 —— 已定禁忌）
  {
    final chip = src('widgets/header_chip.dart');
    final chipBody = _braceBody(chip, 'HeaderChip');
    final review = src('screens/review_screen.dart');

    check('HeaderChip 断言切片非空', chipBody.isNotEmpty && review.isNotEmpty,
        'chip=${chipBody.length} review=${review.length}');

    check('🔴 HeaderChip 有 `active` 两态（`raised` 浮起 / `pressed` 凹陷）',
        chipBody.contains('ClayState.raised') && chipBody.contains('ClayState.pressed'),
        'raised=${chipBody.contains("ClayState.raised")} '
            'pressed=${chipBody.contains("ClayState.pressed")}');

    // ⑤ 排他：不能让 `active` 用 `selected`（那是「凸起 + 强调色填充」→ 与 _SortChip 撞脸）
    check('🔴 `active` **不用 `selected`**（强调填充会与 _SortChip 的选中态撞脸）',
        !chipBody.contains('ClayState.selected'));

    check('  浮起时**不显式给 sunken**（让 Clay 用默认 clayFill —— 亮底 vs 暗底也区分）',
        chipBody.contains('active ? null : t.sunken'));

    // 🔄 2026-09-28 21:0x：`minWidth`（整块内容区最小宽）**已删**，改为 `labelMinWidth`
    //    （文字区定宽）。原因（白哥真机：「药丸太宽」「内容看起来不居中」）：
    //    · 上一版把「整宽 84」传进了作用在 padding **内部**的 `minWidth`
    //      → 药丸实际 84+24 = **108**（比目标宽 24，内容只占 39% → 看着空）
    //    · 且「图标+文字整块居中」时**文字必然偏右** (13+6)/2 = 9.5px
    // 🔄 2026-09-28 21:3x：上面那条「反推右内边距让文字居中」的修法**也被推翻**
    //    （白哥看完实际观感：「**右上角按钮更不对了，还不如原来的**」）→ **去掉图标**。
    //    🔑 一条**数学结论**决定了可选范围：内容 = `[图标 13][间距 6][文字]`，
    //       图标只占左边 → 整块居中时文字**必然**偏右 (13+6)/2 = 9.5px（无法通过调参消除）。
    //       要消掉它只有两条路：① 右侧留等量空白（＝21:0x 的做法 → 右侧 27px 全空，观感更差）
    //       ② **不要图标**（→ 文字天然居中 + 左右对称）。
    //
    // 🔄🆕 2026-09-28 22:2x **第四次修正**：定宽**不再用像素**。
    //    白哥：「**宽度应该按「已到期」三字，现在显示「已到期」时变成两行了**」。
    //    🔴 根因：上面 21:0x 那版取的 `labelMinWidth = 36` 是「3 字 × 11.5px」的
    //       **估算**，而中文字形的 advance **并非恰好 1em**（字体 fallback、
    //       `w600` 的合成加粗、系统「文字大小」缩放都会让它更宽）
    //       → 真机上「已到期」被 36 挤成**两行**。
    //    🔑 修法：改传**参照文案** `labelReserve`（复习页传 `'已到期'`），
    //       组件用**隐形占位**把它量出来 → 宽度由**引擎实测**，
    //       与字体 / 系统缩放无关地**永不折行**，且两态同宽、文字仍居中。
    //    🔑🔑 通用判据：**凡由「字号 × 字数」反推出来的可用宽度，
    //       迟早会在真机上不够。能用「让引擎实测另一个字符串」解决的，不要写死像素。**
    final hasLabelReserve = chipBody.contains('labelReserve');
    check('🔴 有 `labelReserve`（宽度参照**文案** → 两态同宽 + 文字位置不横移）',
        hasLabelReserve, 'labelReserve 在不在: $hasLabelReserve');
    check('🔴 参照是**文案**而不是像素（`final String? labelReserve`）',
        chipBody.contains('final String? labelReserve'));

    // 🔴 **「文字真居中」的代码级保证**：右内边距 = 左内边距 + **图标块宽**。
    //    推导：药丸宽 = L + labelW + R；文字区中心 = L + labelW/2；
    //          药丸中心 = (L+labelW+R)/2；令相等 → **L == R**。
    //    ⚠️ 这条一改，「文字居中」就静默失效（且**看不出** —— 仍然是个好看的药丸）。
    final hasCenterFormula = chipBody.contains('leftPad + iconBlock');
    check('🔴 右内边距 = 左内边距 + 图标块宽（「文字居中」的推导结论 L == R）',
        hasCenterFormula, '公式在不在: $hasCenterFormula');

    // 🔴 **无图标 → 公式自动退化为对称内边距**（不需要特判 —— 这正是选它的好处）。
    final hasSymmetricBranch =
        chipBody.contains('hasIcon ? _iconLead : _padH');
    check('🔴 无图标时左内边距用 `_padH`（→ 右也 = `_padH` → 对称）',
        hasSymmetricBranch, '分支在不在: $hasSymmetricBranch');
    check('  图标块宽：有图标 19（13+6）／ 无图标 0',
        chipBody.contains('hasIcon ? (_iconSize + _iconGap) : 0.0'));
    // 🔑 新的实现形态：**隐形占位 + `Stack`**（宽度实测 —— 不再有 `SizedBox(width: lw)`）
    check('🔴 宽度由**隐形占位**实测（`Stack` + 占位 + 居中叠放）',
        chipBody.contains('Stack(') &&
            chipBody.contains('opacity: 0') &&
            chipBody.contains('alignment: Alignment.center'));
    check('🔴 占位**不进语义树**（`ExcludeSemantics` → 读屏不重复念参照文案）',
        chipBody.contains('ExcludeSemantics'));
    check('🔴 `maxLines: 1` + `softWrap: false`（「永不折行」的兜底）',
        chipBody.contains('maxLines: 1') && chipBody.contains('softWrap: false'));
    // 🔴 反向：不得回到「写死像素的定宽」—— 那正是「已到期」折行的根因
    check('🔴 不再出现写死的定宽（`width: lw`）', !chipBody.contains('width: lw'));

    // 🔴 反向：不得再回到「把最小宽加在整块内容区」（那就是上一版的口径错误）
    check('🔴 不再用 `BoxConstraints(minWidth:` 撑整块内容（口径错 → 药丸宽出 padding）',
        !chipBody.contains('BoxConstraints(minWidth:'));

    // 🔑 `labelReserve` 与 `count` 互斥（居中的推导假设文字区右侧没有其它元素）
    check('🔴 `labelReserve` 与 `count` 互斥（构造函数有 assert）',
        chipBody.contains('assert(') &&
            chipBody.contains('labelReserve == null || count == null'));

    // 🆕 **图标改为可选**（`IconData?`）—— 这使「纯文字药丸」成为合法形态。
    check('🔴 `icon` 可空（`IconData?`）—— 纯文字药丸是允许的',
        chipBody.contains('final IconData? icon'));
    check('  渲染处用 `if (icon != null)`（**不要** `if (hasIcon)`：那样 `icon` 不类型提升）',
        chipBody.contains('if (icon != null)') && !chipBody.contains('Icon(icon!'));

    // 调用处：复习页必须**真的传了**这两项（只加参数不接线 = 白加）
    // 🔑 断调用处的**特有形态**（带实参），不是方法名 —— 否则「删掉传参」照样为绿
    check('🔴 复习页传了 `active:`（筛选生效时浮起）',
        review.contains('active: _args.dueOnly'));
    check('🔴 复习页传了 `labelReserve: _filterChipReserveLabel`',
        review.contains('labelReserve: _filterChipReserveLabel'));
    check('🔴 参照文案 = `已到期`（**必须是「最长的那个」** —— 传短了会溢出）',
        review.contains("_filterChipReserveLabel = '已到期'"));
    check('🔴 复习页不再传像素口径的 `labelMinWidth`',
        !review.contains('labelMinWidth:'));
    check('🔴 像素常量 `_filterChipLabelWidth` 已彻底移除（口径没回退）',
        !review.contains('_filterChipLabelWidth'));
    check('🔴 复习页不再用旧的 `_filterChipWidth`（整宽口径 —— 已废弃）',
        !review.contains('minWidth: _filterChipWidth'));

    // 🆕 🔴 **复习页不传 `icon`** —— 这是「文字居中」的唯一解（见上面的数学结论）。
    //    ⚠️ 反向断言：有人「顺手把图标加回来」时会报红。
    check('🔴 复习页**不传 icon**（去掉图标 = 文字既不偏、又左右对称的唯一解）',
        !review.contains('Icons.filter_alt'),
        'filter_alt 残留: ${review.contains("Icons.filter_alt")}');
    check('  信息流「收藏」**仍传 icon**（那边是入口 + 计数，图标有意义）',
        src('screens/home_screen.dart').contains('icon: Icons.bookmark_border'));
    check('  信息流「收藏」入口**不传** active（它是入口，不是开关 → 保持凹陷）',
        !src('screens/home_screen.dart').contains('active:'));
  }

  // ⑩ 🔴🔴 **Clay 凹陷容器里的输入框必须「完全无边框」**（2026-09-28 22:2x 真机 Bug）
  //
  // 白哥：「**搜索栏有个红色的线框，这个线框取消掉**」。
  // 🔴 根因：`theme_builder.dart` 的 `inputDecorationTheme` 给**全局**输入框定了
  //    `focusedBorder = accent(#B4432C) 1.6px`；而 `InputDecoration` 的 border 类字段
  //    是**各自独立**从 theme 继承的 ——
  //    ```dart
  //    InputDecoration(border: InputBorder.none)   // ❌ 只覆盖了 border
  //    ```
  //    聚焦时 `InputDecorator` 取的是主题的 `focusedBorder` → 冒出朱砂色线框。
  //    两处输入框（复习页搜索框「展开即自动聚焦」· 测验框 `autofocus: true`）
  //    都**一下就到聚焦态** → **必现**，不是偶发。
  //
  // 🔑 判据：**要「完全无边框」，必须把 border 类字段*全部*设为 `none`。**
  //    留一个为 `null`，那个状态就会把主题的边框放回来。
  //    （同 `HeaderChip` 那条教训：「**主题里有**」≠「**调用处已覆盖**」。）
  //
  // 🔑 为什么这两个输入框「不该有框」：它们都嵌在 `Clay(state: pressed)` 里 ——
  //    凹陷本身就是「这里可以输入」的视觉语言，再叠一圈描边是**两套语汇打架**。
  {
    final tb = src('theme/theme_builder.dart');
    check('🔴 有全库唯一的 `borderlessInputDecoration`（无框输入的唯一定义处）',
        tb.contains('InputDecoration borderlessInputDecoration('));
    check('🔴 六个 border 类字段**全部** none（少一个，那个状态就会漏出主题边框）',
        tb.contains('border: InputBorder.none') &&
            tb.contains('enabledBorder: InputBorder.none') &&
            tb.contains('disabledBorder: InputBorder.none') &&
            tb.contains('focusedBorder: InputBorder.none') &&
            tb.contains('errorBorder: InputBorder.none') &&
            tb.contains('focusedErrorBorder: InputBorder.none'));

    for (final f in [
      'screens/review_screen.dart',
      'screens/review_session_screen.dart',
    ]) {
      final code = src(f);
      check('🔴 $f 的输入框走 `borderlessInputDecoration(`',
          code.contains('borderlessInputDecoration('));
      // 🔴 反向：**不得**再裸写 `border: InputBorder.none`
      //    —— 那正是「只覆盖 border、漏掉 focusedBorder」的原始写法。
      check('🔴 $f 不再裸写 `border: InputBorder.none`（会漏掉 focusedBorder）',
          !code.contains('border: InputBorder.none'));
    }
  }

  // ⑦ 🔴 卡片**有发音入口**（设计稿 mockup 的 `spk`）
  //    ⚠️ 我上一轮曾误判「设计稿卡片上无喇叭」并据此没做 → 这条防它再被删掉。
  //
  //    🔑 取 `_head` 的**方法体切片**再断言（而不是全文件 contains）：
  //       发音块被挪出词头、或整个删掉，都应报红。
  //
  //    🔄 21:4x：`onSpeak` 已删（改为自包含的 `SpeakButton`）→ 断言对象同步改。
  //    🔑 **本断言的已知边界（如实标注）**：`if (ipa.isNotEmpty)` 改成恒假
  //       **抓不到**（文本没变）。但本轮之后这一行的「有无」已由
  //       `SpeakButton(text: card.spelling` 这个**带实参的调用形态**代表 ——
  //       删掉调用就会报红。真正抓不到的是「外层 if 恒假」这类逻辑改动。
  final headBody = _braceBody(cardW, '_head');
  check('能切出词头方法体（断言范围正确的前提）', headBody.isNotEmpty);
  check('🔴 卡片词头有喇叭（设计稿 `spk`，紧跟音标）',
      headBody.contains('SpeakButton(text: card.spelling'),
      'SpeakButton 在不在: ${headBody.contains("SpeakButton")}');

  // ⑦b 🔴🔴 **朗读喇叭总组**（2026-09-28 21:4x 接通 · 5 处）
  //
  // 依据 **v1 §6.2（L0）**：`front`（单词）· `context`（英文例句）·
  // `collocation`（英文搭配）✅ 朗读；`definition`/`root`/`etymology` ❌（**含中文**）。
  // > 🔑 **原则：只朗读纯英文文本。**
  //
  // 🔴 这一组守的是「**一处定义 + 按段判断播放态**」——
  //    5 处各写一份，改一处就会静默走偏（用户看到两个喇叭同时亮），
  //    而这类不一致**编译器和 analyzer 都抓不到**。
  {
    final spk = src('widgets/speak_button.dart');
    final spkBody = _braceBody(spk, 'SpeakButton');
    check('喇叭断言切片非空（speak_button.dart）', spkBody.isNotEmpty);

    // ── ① 规格：26 / 22 两档（都是锚点给定值，不是自定）──
    check('🔴 两个尺寸档 = 锚点值（main 26 · inline 22）',
        spk.contains('static const double main = 26') &&
            spk.contains('static const double inline = 22'));
    check('  inline 前间距 = 锚点 `.ctx .spk{margin-left:6px}`（不走 CoSpacing）',
        spk.contains('static const double inlineGap = 6'));
    check('🔴 `Clay` 凸起 + 显式给 `card` 底（锚点 `background:var(--card)`）',
        spkBody.contains('ClayState.raised') && spkBody.contains('fill: t.card'));
    check('🔴 正圆半径**显式**给 `size / 2`（走 token 档位会在「格」档 ≠ 正圆）',
        spkBody.contains('BorderRadius.circular(size / 2)'));

    // ── ② 播放态必须按「**哪一段**」判断 ──
    //    🔑 用全局 `isPlaying` 会让 5 个喇叭一起亮 → 看不出在读哪段。
    check('🔴 播放态按**文本**判断（`isSpeaking(text)`，不是全局 `isPlaying`）',
        spkBody.contains('tts.isSpeaking(text)'));
    check('  三态图标：loading 转圈 / playing 变 stop / 其它喇叭',
        spkBody.contains('CircularProgressIndicator') &&
            spkBody.contains('Icons.stop_rounded') &&
            spkBody.contains('Icons.volume_up_rounded'));
    check('🔴 `TtsService.isSpeaking` 存在（含 loading 态）',
        src('services/tts_service.dart').contains('bool isSpeaking(String text)'));

    // ── ③ 行为：白哥定的「播放/停止切换」──
    check('🔴 点按走 `togglePlay`（白哥 21:4x：播放/停止切换）',
        spkBody.contains('tts.togglePlay(text)'));
    check('  `loading` 时**不给 onTap**（防重复触发 —— 转圈本身就是反馈）',
        spkBody.contains('loading ? null :()') ||
            spkBody.contains('loading ? null : ()'));

    // ── ④ 关朗读 → 不渲染（不留「点了没反应」的喇叭）──
    //    判据：「静默失败 + 无出口」比「报错」更糟。
    check('🔴 设置里关了朗读 → 返回 `SizedBox.shrink()`（不留静默失效的喇叭）',
        spkBody.contains('ttsEnabledProvider') &&
            spkBody.contains('SizedBox.shrink()'));

    // ── ⑤ **5 处接线**（只加组件不接线 = 白加）──
    //
    // 🔴🔴 **期望值必须带 `SpeakButton(` 前缀 —— 这是证伪测试逼出来的修正**：
    //    我最初的写法是 `contains('text: example')` 这类**只取实参**的形态，
    //    结果**假绿**：删掉例句的 `SpeakButton` 后，`TextSpan(text: example)`
    //    里**仍有** `text: example` → 断言照样通过。
    //    实测确认：注入「删掉例句喇叭」→ **该项不报红**（继续全绿）。
    //    🔑 判据复用：「**期望值的形态必须等于被测对象**」——
    //       被测对象是「SpeakButton 这个调用」，所以期望值必须**从 `SpeakButton(` 起算**。
    //    这里用正则（参数跨行，`contains` 不够）：
    //    新增一个喇叭 = `SpeakButton(` + 任意实参（不含 `)`）。
    bool hasSpeak(String file, String argPattern) => RegExp(
            'SpeakButton\\([^)]*?' + argPattern)
        .hasMatch(src(file));

    final wire = <String, List<String>>{
      '词头（单词）': ['widgets/word_card.dart', r'card\.spelling'],
      '④ 语境原句':   ['widgets/word_card.dart', 'ctxText'],
      '搭配每条':     ['widgets/word_card.dart', r'items\[i\]\.phrase'],
      '浮层·单词行': ['widgets/lookup_sheet.dart', r'card\.spelling'],
      '浮层·例句':   ['widgets/lookup_sheet.dart', 'example'],
    };
    for (final e in wire.entries) {
      check('🔴 ${e.key} 有喇叭（`SpeakButton(` + 该实参）',
          hasSpeak(e.value[0], e.value[1]), '在 ${e.value[0]}');
    }

    // 反向哨兵：上面 5 条若因「切片/形态」写错而集体假绿，用**计数**兜底。
    // 🔑 两处调用点各自应有几个 `SpeakButton(`：
    //    词卡 = 词头 + ④ 语境 + 搭配 = **3**；浮层 = 单词行 + 例句 = **2**。
    final cardCnt = 'SpeakButton('.allMatches(cardW).length;
    final sheetCnt = 'SpeakButton('.allMatches(src('widgets/lookup_sheet.dart')).length;
    check('🔴 词卡有 3 处喇叭调用（词头 / 语境 / 搭配）', cardCnt == 3, '实得 $cardCnt');
    check('🔴 浮层有 2 处喇叭调用（单词行 / 例句）', sheetCnt == 2, '实得 $sheetCnt');

    // ── ⑥ 🔴 **只给英文段**（v1 §6.2 原则）──
    //    词卡的 `_sectionBody` 里：只有 `collocation` 分支可含 SpeakButton；
    //    `root` / `etymology` / `definition` / `cognate` 分支**都不得有**。
    //    ⚠️ 断言要**切片到各分支**（不能对整个 `_sectionBody` 查 —— 那里确实有一个）。
    final secBody = _braceBody(cardW, '_sectionBody');
    final ci0 = secBody.indexOf("case 'collocation':");
    final ci1 = secBody.indexOf('default:', ci0);
    final collBody = (ci0 >= 0 && ci1 > ci0) ? secBody.substring(ci0, ci1) : '';
    check('  搭配分支切片非空', collBody.isNotEmpty);
    check('🔴 搭配段有喇叭（v1 §6.2：collocation ✅ 朗读）',
        collBody.contains('SpeakButton('));
    for (final seg in ['root', 'etymology', 'cognate']) {
      final i0 = secBody.indexOf("case '$seg':");
      if (i0 < 0) continue;
      var i1 = secBody.indexOf('case ', i0 + 1);
      if (i1 < 0) i1 = secBody.length;
      final body = secBody.substring(i0, i1);
      check('🔴 `$seg` 段**不得**有喇叭（v1 §6.2：含中文 → 只朗读纯英文文本）',
          !body.contains('SpeakButton'), '段长 ${body.length}');
    }
    // 释义段（③）在 build 里而不在 `_sectionBody` —— 单独查它的切片
    final defBody = _braceBody(cardW, '_definition');
    if (defBody.isNotEmpty) {
      check('🔴 释义段不得有喇叭（中文释义）', !defBody.contains('SpeakButton'));
    }

    // ── ⑦ 唯一实现：业务代码不得自己画喇叭图标 ──
    //    ⚠️ 排除 `chat/*`（K12 遗留，整体待清退，见 MEMORY「主线」段）。
    const ownDrawAllowed = {'widgets/speak_button.dart'};
    final scanned = <String>[
      'screens/review_screen.dart', 'screens/review_session_screen.dart',
      'screens/reader_screen.dart', 'screens/home_screen.dart',
      'screens/aggregate_page_screen.dart',
      'widgets/word_card.dart', 'widgets/lookup_sheet.dart',
      'widgets/header_chip.dart', 'widgets/bookmark_button.dart',
    ];
    final offenders = <String>[];
    for (final f in scanned) {
      if (ownDrawAllowed.contains(f)) continue;
      if (src(f).contains('Icons.volume_up')) offenders.add(f);
    }
    check('🔴 业务代码**不自己画喇叭图标**（应走 `SpeakButton` —— 全库唯一实现）',
        offenders.isEmpty, '违规: ${offenders.join(", ")}');
  }

  // ⑧ 提交中**要看得出来**（本项目教训：不显眼的禁用被读成「坏了」）
  //    ⚠️ 原先这条是「四键禁用用 Opacity」—— 四键已删；
  //       现在考核态的忙碌反馈是「确认按钮换成转圈」（同样要看得出来）。
  check('提交中有可见反馈（确认按钮转圈）',
      sess.contains('CircularProgressIndicator'));

  // ⑨ 释义缺失**不阻塞列表**（跨库依赖不得成为渲染前置条件）
  check('🔑 释义取不到只记日志、不影响列表渲染',
      prov2.contains('firstDefinitionsOf') && prov2.contains('debugPrint'));

  // ═══ ⑬ 翻卡 = 顶层路由（全屏）—— 四键不再被 tabbar 遮挡 ═══
  //
  // 🔴 白哥 2026-09-28 真机：「四键被底部栏遮住，**拉动也出不来**」。
  //
  // 根因不是「忘了留白」，而是**结构**：翻卡原先做成 `review_screen` 内的
  // 一个状态（`_inCard`）→ 继承「复习 tab 那一屏」的布局约束，其中包含
  // `_ShellScaffold` 的 `extendBody: true` + tabbar ≈100px →
  // 四键（固定在底部、不参与滚动）被盖住。
  //
  // 🔴 而设计稿的翻卡 mockup **根本没有 tabbar**
  //    （`.phone` 里只有 `pbar` + `pbody` + `card`）→ 它是**全屏沉浸态**。
  //
  // 🔑 判据（项目已定）：**它是不是 tab 的内容**（是 → 页内；否 → 顶层路由）。
  print('\n【17b】翻卡 = 顶层路由（全屏）');
  check('翻卡路由已注册（/review/session）',
      app.contains("path: '/review/session'"));
  //    🔴 关键：必须在 `StatefulShellRoute` **之外** ——
  //       在 shell 内 → tabbar 仍在 → 遮挡回来
  final shellStart = app.indexOf('StatefulShellRoute');
  final routePos = app.indexOf("path: '/review/session'");
  check(
      '🔴 翻卡路由在 shell **之外**（在 shell 内 → tabbar 仍在 → 遮挡复现）',
      shellStart >= 0 && routePos > shellStart);
  check('🔴 翻卡不再是复习页的页内状态（无 _inCard 残留）',
      !page.contains('_inCard'));
  check('🔴 全屏页避让底部安全区（SafeArea 不再传 bottom: false）',
      !sess.contains('bottom: false'));
  check('列表项点击 → push 翻卡路由（不是切状态）',
      page.contains("context.push('/review/session')"));
  check('🔴 翻卡退出路径不再依赖 `dispose` 刷新（改由提交后 bump）',
      !sess.contains('ref.invalidate(reviewListProvider)') &&
          sess.contains('revision.bump()'));
}

// ── ⑱ 库修订号：**写端 bump · 读端 watch** ─────────────────────────
//
// 🔴 为什么需要这一节（2026-09-28 白哥真机报的**两个**现象）：
//
// > 「划词后进入复习页面第一时间看不到新单词，要切换一下内部 tab 才能看到；
// >   考试后单词状态也不能第一时间改变，同样也要切换一下」
//
// 根因**不是写入失败**（库是对的，所以「切一下」就能看到），而是：
// 读端是**带缓存的** `FutureProvider`，只有 `invalidate` 或失去监听者才重算；
// 而写端有三处，**「通知」这一步靠人记** ——
//   · 划词写回 —— 🔴 **一处都没有**
//   · 评级提交 —— ⚠️ 只在 `dispose()` 里（把「数据变了」押在「页面被销毁」上）
//   · 暂停     —— ✅ 有（唯一一处正确范例）
//
// 🔑 本节的守护目标**不是**「某个 provider 被 invalidate 了」，
//    而是**结构本身**：写端只 bump、读端自己 watch ——
//    这样「新增读端」不必改写端、「新增写端」不必知道有哪些读端。
//
// ⚠️ 这类失效**编译器完全看不出来**：数据写对了，只是没人告诉界面。
//    用户看到的是「查词没生效」/「评了没用」。
void _s20DeviceId() {
  print('\n【20】匿名设备标识（device_id）的接线与边界');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final devId = src('services/device_id.dart');
  final devProv = src('providers/device_id_provider.dart');
  final client = src('api/generate_card_client.dart');
  final reader = src('screens/reader_screen.dart');
  final sess = src('screens/review_session_screen.dart');
  final auth = src('providers/auth_provider.dart');

  // ① 🔴 分层：纯逻辑层**不许** import Flutter（否则断言脚本 import 不了它）
  check('🔴 `device_id.dart` 零 Flutter 依赖（IO 走回调注入 → 可纯 Dart 断言）',
      devId.isNotEmpty && !devId.contains('package:flutter'));
  check('`device_id.dart` 不依赖 shared_preferences（那是接线层的事）',
      !devId.contains('shared_preferences'));
  check('🔑 `device_id.dart` 与登录态**无关**（不出现 token / login / auth）',
      !RegExp(r'token|login|auth', caseSensitive: false).hasMatch(devId));

  // ② 🔑 格式常量只有**一处**出处 + 前缀带 `dev_`
  final devIdPrefsKey = RegExp(r"kDeviceIdPrefsKey\s*=\s*'([^']+)'")
      .firstMatch(devId)?.group(1);
  check('`kDeviceIdPrefsKey` 有唯一定义（可 grep 的单一出处）',
      devIdPrefsKey != null && devIdPrefsKey.isNotEmpty, '$devIdPrefsKey');
  check('🔑 存储键带 `coevo.` 命名空间（与其它键同类）',
      devIdPrefsKey != null && devIdPrefsKey.startsWith('coevo.'),
      '$devIdPrefsKey');

  // ③ 制卡：device_id **真的进了请求体**，且空串被剔除
  check('制卡客户端 `generate` 接受 `deviceId`',
      RegExp(r'generate\([^)]*deviceId').hasMatch(client));
  check('🔴 请求体含 `device_id`（**接线**，不是只声明参数）',
      client.contains("'device_id':"));
  check('🔑 空串被显式剔除（否则服务端会把空串当一个「用户」计入去重）',
      client.contains("deviceId != null && deviceId.isNotEmpty"));
  check('reader 调用制卡时传了 deviceId', reader.contains('deviceId: deviceId'));

  // ④ 复习日志：device_id 真的写进去了（多端同步的冲突判定键）
  check('🔴 提交评级时把 deviceId 传给 `svc.review`',
      sess.contains('deviceId: deviceId'));
  check('🔑 两个调用方都用 `deviceIdOrNull`（**拿不到就降级**的单一实现）',
      reader.contains('deviceIdOrNull(') && sess.contains('deviceIdOrNull('));
  check('provider 侧同时暴露 Ref 版本（WidgetRef 与 Ref 无公共父类）',
      devProv.contains('deviceIdOrNullFrom'));

  // ⑤ 🔴🔴 退出登录**不许** `prefs.clear()` —— 那会把 device_id 一起抹掉，
  //    表现为「每次退出登录都换一个新身份」（服务端去重被稀释、且用户无感知）
  check('🔴 `logout` 用精确删键（`remove`），**不是** `clear()`',
      auth.contains("remove('display_name')") && !auth.contains('prefs.clear()'));

  // ⑥ 🔴 pubspec 必须声明 `assets/word_db.version`
  //    ⚠️ 漏声明**不报错** —— `word_db_provider` 对该资产做了容错（缺失即退回比大小），
  //       于是表现为「静默退化成旧行为」，比崩溃更难发现。
  final pubspecFile = File('$root/app/pubspec.yaml');
  final pubspec = pubspecFile.existsSync() ? pubspecFile.readAsStringSync() : '';
  check('🔴 `pubspec.yaml` 声明了 `assets/word_db.version`（漏声明不报错，只静默退化）',
      RegExp(r'^\s*-\s*assets/word_db\.version\s*$', multiLine: true)
          .hasMatch(pubspec));
  check('`assets/word.db` 仍逐文件声明（它是单文件，不会连带同目录其它文件）',
      RegExp(r'^\s*-\s*assets/word\.db\s*$', multiLine: true)
          .hasMatch(pubspec));

  // ⑦ 资产文件真的在（声明了但文件缺失 = 运行期才炸）
  final vAsset = File('$root/app/assets/word_db.version');
  check('版本号资产文件存在', vAsset.existsSync());
  if (vAsset.existsSync()) {
    final v = vAsset.readAsStringSync().trim();
    check('版本号非空且形如 `<词数>+<8位hex>`',
        RegExp(r'^\d+\+[0-9a-f]{8}$').hasMatch(v), v);
  }
}

void _s18DbRevision() {
  print('\n【18】库修订号（写端 bump · 读端 watch）');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final dbProv = src('providers/user_db_provider.dart');
  final listProv = src('providers/review_list_provider.dart');
  final page = src('screens/review_screen.dart');
  final sess = src('screens/review_session_screen.dart');
  final reader = src('screens/reader_screen.dart');
  final sessProv = src('providers/review_session_provider.dart');

  // ① 信号源存在，且**与库同一处定义**（「库有变化」只有一个出处）
  check('userDbRevisionProvider 定义在 user_db_provider.dart（与库同一处）',
      dbProv.contains('userDbRevisionProvider') &&
          dbProv.contains('class UserDbRevision'));
  check('它是 Notifier（写端能 bump），不是只读的 Provider',
      dbProv.contains('extends Notifier<int>'));

  // ② 读端**自己** watch 它（而不是等写端来点名）
  //    🔴 两条都要有：少一条就出现「列表刷新了但顶部计数没变」
  // ② 读端**自己** watch 它（而不是等写端来点名）
  //
  //    🔴 **必须按 provider 的定义处切段**，不能查全文件 ——
  //       本文件里 `ref.watch(userDbRevisionProvider)` 会出现**两次**
  //       （两个 provider 各一次），全文件 `contains` 会让「删掉其中一个」
  //       **照样为绿**（实测：证伪时删掉 `reviewListProvider` 的那行，断言 0 红）。
  //       🔑 「同一行在别处也出现」的又一次实例 —— 而且这次是**同一个文件内**。
  //          同类定义越多，`contains` 越不可信：**默认就应该切段**。
  final listAt = listProv.indexOf('final reviewListProvider');
  final dueAt = listProv.indexOf('final reviewDueCountProvider');
  final listSeg = (listAt < 0)
      ? ''
      : listProv.substring(listAt, dueAt > listAt ? dueAt : listProv.length);
  final dueSeg = dueAt < 0 ? '' : listProv.substring(dueAt);
  check('能切出两个 provider 各自的段（读端断言的前提）',
      listSeg.isNotEmpty && dueSeg.isNotEmpty,
      'listAt=$listAt dueAt=$dueAt');
  check('🔴 reviewListProvider 的段内 watch 了修订号',
      listSeg.contains('ref.watch(userDbRevisionProvider)'));
  check('🔴 reviewDueCountProvider 的段内也 watch 了（列表与计数同源刷新）',
      dueSeg.contains('ref.watch(userDbRevisionProvider)'));

  // ③ 三个写端**都**要 bump（少一个就是一次「界面不更新」）
  //
  //    🔑 **函数体切片在这里定义**（③④⑤⑥ 共用）——
  //       ③ 划词那处若用全文件 `contains` 是**假绿**：`reader_screen.dart`
  //       里 L231 另有一处 `revision.bump()`（读完文章写 `article_read` 后的）
  //       → 把 `_writeBackLookup` 里的 bump **删掉也照样为绿**。
  //       ⚠️ 切函数体**不能取「第一个 `{`」** —— 签名里有命名参数花括号
  //          （`(WidgetRef ref, { String? wordId, required String spelling, })`）。
  //          复用 `_braceBody`（已处理「命名参数 `{}`」与「`async` 关键字」两坑）。
  final writeBody = _braceBody(reader, '_writeBackLookup');
  // 🔑 **特征哨兵** —— 「切片非空」挡不住切错（`_braceBody` 注释里的坑 2/3/4
  //    切出来的区间**往往仍非空**）→ 必须断言切片含该结构**独有**的东西，
  //    否则 ③④⑤⑥ 的守护全是假的。
  check('能切出 `_writeBackLookup` 的函数体（③④⑤⑥ 位置断言的前提）',
      writeBody.contains('await repo.add('), 'len=${writeBody.length}');
  check('🔴 划词写回写库后 bump 修订号（`_writeBackLookup` 内）',
      writeBody.contains('revision.bump()'));
  for (final e in [
    ('评级提交', sess),
    ('暂停', page),
  ]) {
    check('🔴 ${e.$1}写库后 bump 修订号', e.$2.contains('revision.bump()'));
  }

  // ④ 🔴 **bump 必须在写库之后**（顺序类断言 —— 位置可验，不必肉眼）
  //
  //    反了会怎样：读端在写入完成前重查一次（拿到旧值），
  //    而修订号**已经变过**、不会再有第二次通知 → 表现为「这一次没刷新」。
  //    🔑 这是「刷新信号必须晚于写入」的一般要求。
  //
  //    🔴🔴 **位置断言必须在「被测函数内」比**（2026-10-01 修 · 此前**恒假红**）
  //    `revision.bump()` 在 `reader_screen.dart` 里有 **2 处**真实代码：
  //      · L231 —— 「读完文章 → 写 `article_read` → bump」（**与本条无关**）
  //      · L579 —— `_writeBackLookup` 内（**本条要验的就是这处**）
  //    而 `indexOf` **只返回首次出现的位置** → 拿到 L231 →
  //    `bump@231 > add@552` **恒为 false** ⇒ 本组 3 条断言**长期假红**。
  //    🔑 根因与本节 ② 同源（那里是「同一行在本文件出现两次」），解法也相同：
  //       **先切段，再断言**。② 的注释已写明「默认就应该切段」，④ 当时漏了。
  //    ⚠️ 切片不能取「第一个 `{`」——签名有命名参数花括号，会切成参数列表。
  //       `writeBody` 已在 ③ 切好并加了哨兵断言，这里直接复用。
  final readerAdd = writeBody.indexOf('await repo.add(');
  final readerBump = writeBody.indexOf('revision.bump()');
  check('🔑 划词：bump 在 `repo.add` 之后（先写库、后通知）',
      readerAdd >= 0 && readerBump > readerAdd,
      'add@$readerAdd bump@$readerBump');
  // ⚠️ 下面两处（评级 / 暂停）保持**全文件**定位：实测这两个文件里
  //    `revision.bump()` 各只 **1 处**（`review_screen` 里 `await repo.pause(`
  //    看似 2 处，但其中 1 处在注释行、已被 `_codeOnly` 滤掉）→ 无此洞。
  //    🔑 但**若将来这两处新增第二个 bump，必须同步改成 `_braceBody`**。
  final sessWrite = sess.indexOf('await q.logReview(');
  final sessBump = sess.indexOf('revision.bump()');
  check('🔑 评级：bump 在写两张表之后',
      sessWrite >= 0 && sessBump > sessWrite,
      'logReview@$sessWrite bump@$sessBump');
  final pauseWrite = page.indexOf('await repo.pause(');
  final pauseBump = page.indexOf('revision.bump()');
  check('🔑 暂停：bump 在 `repo.pause` 之后',
      pauseWrite >= 0 && pauseBump > pauseWrite,
      'pause@$pauseWrite bump@$pauseBump');

  // ⑤ 🔴 **只在真的写库后**才刷（白哥 2026-09-28 定）
  //
  //    `add()` 里**不写库**的分支都必须提前 return：
  //      · `alreadyExists` → 直接 return（连 `user_word` 都没动）
  //    未命中（`wordId == null`）只写 `lookup_event`，而复习页**不读**该表 → 也不必刷。
  //    ⚠️ 2026-10-01：原第 3 条 `limitReached`（200 上限 · 不入库）**已随上限取消删除**，
  //       守着它的那条断言也一并移走（该上限另有一组「反向断言」，见本文件 §⑤）。
  //    🔑 「刷新」的判据是**数据变了**，不是「用户做了个操作」。
  //
  //    ⚠️ 这里用**位置**证明「不写库的路径都提前 return 了」，
  //       而不是去匹配注释文本 —— 注释可以改，而「return 在 bump 之前」
  //       是结构事实。（用注释当断言 = 断言跟着注释漂移。）
  //    🔑 2026-10-01：三处锚点统一改用 ④ 切出的 `writeBody` ——
  //       与 `readerBump` **同一坐标系**才能比较（此前 `readerBump` 取的是
  //       另一个函数的 bump，位置比较毫无意义，见 ④ 的长注释）。
  final missReturn = writeBody.indexOf('if (wordId == null) return;');
  final alreadyReturn = writeBody.indexOf('AddWordResult.alreadyExists) return');
  check('🔴 划词：未命中（只写 lookup_event）时提前 return，走不到 bump',
      missReturn >= 0 && missReturn < readerBump,
      'return@$missReturn bump@$readerBump');
  check('🔴 划词：`alreadyExists`（库没动）时提前 return，走不到 bump',
      alreadyReturn >= 0 && alreadyReturn < readerBump,
      'return@$alreadyReturn bump@$readerBump');

  // ⑥ 🔑 **提前取 notifier 引用** —— 避开「`await` 期间 ref 失效」
  //
  //    三处写端都有 `await`：期间用户可能退出页面 → `ref` 失效 →
  //    `await` 之后再 `ref.read` 会抛错（写库已成功，只是通知失败）。
  //    拿 `Notifier` **实例**引用则不受 widget 生命周期影响。
  //    🔑 划词那处**必须用切片**：`ref.read(userDbRevisionProvider.notifier)`
  //       在 `reader_screen.dart` 有 **2 处**（L221 与 L540）→ 全文件 `contains`
  //       在「`_writeBackLookup` 内那处被删掉」时**照样为绿**（同 §18 ② 的洞）。
  check('🔴 划词：在 `await` 之前取 notifier 引用（`_writeBackLookup` 内）',
      writeBody.contains('ref.read(userDbRevisionProvider.notifier)'));
  for (final e in [('评级', sess), ('暂停', page)]) {
    check('${e.$1}：在 `await` 之前取 notifier 引用',
        e.$2.contains('ref.read(userDbRevisionProvider.notifier)'));
  }

  // ⑦ 🔴 **不许两套机制并存**（本项目明令：同一个目的只能有一处定义）
  //    针对复习数据的 `invalidate` 必须全部消失 ——
  //    否则改了一处、另一处仍按老路子走，下次排查无从下手。
  final stale = RegExp(r'invalidate\(review(List|DueCount)Provider\)');
  for (final e in [('复习页', page), ('翻卡页', sess), ('列表 provider', listProv)]) {
    check('🔴 ${e.$1}不再点名 invalidate 复习数据（防两套机制）',
        !stale.hasMatch(e.$2));
  }

  // ⑧ 🔑 翻卡**快照不受修订号影响**（否则每评一张队列就会重算 → 索引错乱）
  //    判据：`cardBundleProvider` 依赖的是**会话状态**与词库，**不是**列表 provider。
  check('🔑 翻卡数据源不依赖 reviewListProvider（快照不会被刷新打乱）',
      !sessProv.contains('reviewListProvider'));
}

// ═══════════════════════════════════════════════════════════════════
// 【19】🆕 在线制卡（A2 · 2026-10-01）
// ═══════════════════════════════════════════════════════════════════
//
// 🔴 本组防的是「**功能静默消失**」这类失效：
//    · 适配器写好了但**没人调用** → 编译通过、功能不存在
//    · `cardById` 少了 `ext:` 回落 → 词库外的词在复习页**看得见、点不开**
//    · 客户端不小心带上了 token → 违反产品原则（登录服务抖一下，划词就查不了）
// 这些**都不会报错**，只能靠断言行。

void _s19ExternalCard() {
  print('\n【19】在线制卡（A2）的接线');

  final root = _repoRoot();
  String src(String p) {
    final f = File('$root/app/lib/$p');
    return f.existsSync() ? _codeOnly(f.readAsStringSync()) : '';
  }

  final reader = src('screens/reader_screen.dart');
  final wqs = src('services/word_query_service.dart');
  final client = src('api/generate_card_client.dart');
  final adapter = src('services/generated_card_adapter.dart');
  final extId = src('services/external_word_id.dart');
  final genProv = src('providers/generate_card_provider.dart');
  final wordProv = src('providers/word_db_provider.dart');

  // ① 未命中分支必须**真的**走制卡（不是只提示一句就结束）
  check('🔴 未命中分支调用了 `_lookupExternalWord`（**接线**，不只是定义）',
      RegExp(r'_lookupExternalWord\(').allMatches(reader).length >= 2,
      '应 1 处定义 + 1 处调用');

  // ② 🔴 「只说一句话就结束」那套**必须消失** —— 留着就是「静默失败 + 无出口」
  //    ⚠️ `_codeOnly` 只滤**整行** `//` 注释 → 解释性注释不会误伤这两条（已实测）
  check('🔴 不再有「词库里没有」的用户可见提示（旧行为已废除）',
      !reader.contains("'词库里没有"));
  check('🔴 未命中不再直接写 `spelling: text`（那条路径已改为带合成 id）',
      !reader.contains('unawaited(_writeBackLookup(ref, spelling: text))'));

  // ③ 🔑 合成 id 的构造只有**一处出处**（防两处漂移）
  check('ext: 合成 id 由 `externalWordId()` 产出（不在调用处手拼字符串）',
      reader.contains('externalWordId(') &&
          !RegExp(r"'ext:[\s]*\$").hasMatch(reader));
  check('🔑 前缀常量定义在 `external_word_id.dart`（单一出处）',
      extId.contains("kExternalWordIdPrefix = 'ext:'"));

  // ④ 🔴 客户端**不带 token**（产品原则 · 不是遗漏）
  check('🔴 制卡客户端不带 token（产品原则：划词是内容渲染，不该被登录态阻塞）',
      client.contains('ApiConfig.headers()') &&
          !client.contains('headers(token:') &&
          !client.contains('userToken'));

  // ⑤ 三块协作组件都**被引用**（否则是死代码）
  check('适配器被 reader 调用（契约 v6 → card.content）',
      reader.contains('toCardContent('));
  check('解析器被 reader 调用（card.content → 渲染形状）',
      reader.contains('parseCardContent('));
  check('生成客户端 provider 被 reader 引用（走 provider 复用 http.Client）',
      reader.contains('generateCardClientProvider'));
  check('provider 在 dispose 时关闭客户端（不泄漏连接）',
      genProv.contains('onDispose') && genProv.contains('dispose'));

  // ⑥ 🔴 `cardById` 的 `ext:` 回落（**复习页能显示词库外的词**全靠它）
  //
  //    🔴🔴 **这里踩过一次「假绿」，记下来**（2026-10-01）：
  //    第一版只断言「切片里含 `externalSpellingOf` / `_externalCardLoader`」——
  //    证伪时我在它们**前面**插了一句 `return null;`（把回落变成死代码），
  //    断言**照样全绿**。原因：**文本断言只能证明「写了」，不能证明「会执行到」**。
  //
  //    ✅ 修法分两层（**缺一不可**）：
  //      ① **位置断言**（本文件）—— 「无条件的提前 return 不得出现在回落逻辑之前」
  //      ② **行为断言**（`verify_generated_card_adapter.dart` §5）——
  //         真开 word.db、真调 `cardById('ext:xxx')`、断言**真的取到了卡**。
  //         那一条能抓到「路径被短路」，因为它**真跑**。
  //    📌 一般化：**「接线」类断言若只扫源码，必须配一条真跑的行为断言** ——
  //       否则它守护的是「文本还在」，不是「功能还在」。
  final biAt = wqs.indexOf('Future<WordCard?> cardById(');
  final biSeg = biAt < 0 ? '' : wqs.substring(biAt, (biAt + 2600).clamp(0, wqs.length));
  check('能切出 `cardById` 的源码段（下面断言的前提）',
      biSeg.contains('externalSpellingOf'), 'len=${biSeg.length}');
  check('🔴 `cardById` 在词库查不到时回落到端侧缓存',
      biSeg.contains('externalSpellingOf') && biSeg.contains('_externalCardLoader'));
  check('🔑 回落是**惰性注入**（回调而非直接依赖 user.db → 本层仍可纯 Dart 断言）',
      wqs.contains('typedef ExternalCardLoader'));
  // 🔴 位置断言 —— 见上面「假绿」说明
  final segFallbackAt = biSeg.indexOf('externalSpellingOf');
  final segNullReturnAt = biSeg.indexOf('return null;');
  check('🔴 回落逻辑之前**没有**无条件的 `return null;`（否则整段是死代码）',
      segFallbackAt >= 0 && (segNullReturnAt < 0 || segNullReturnAt > segFallbackAt),
      'fallback@$segFallbackAt 首个 return null;@$segNullReturnAt');

  // ⑦ 🔴 `user.db` 打不开**不能**让词库不可用（增强不该阻断主体）
  check('🔴 词库外卡片的读取器**吞异常**（返回 null，不冒泡）',
      wordProv.contains('_externalCardLoader') &&
          wordProv.contains('return null;'));

  // ⑧ 表与迁移都在（结构性前提）
  final schemaFile = File('$root/app/assets/sql/user_db_schema.sql');
  final schema = schemaFile.existsSync() ? _codeOnly(schemaFile.readAsStringSync()) : '';
  check('schema 里有 `external_word_cache` 表',
      schema.contains('CREATE TABLE IF NOT EXISTS external_word_cache'));
  check('🔑 表注释写明「存的是转换后的形状，与服务端不同」'
      '（防后人「顺手统一」）',
      schemaFile.existsSync() &&
          schemaFile.readAsStringSync().contains('转换后'));
}
