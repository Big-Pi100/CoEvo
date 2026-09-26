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

  // 墨：背景透明度递减 .15 → .075 → .026，无边框，无前景覆盖
  final ink = inkTokens.trace;
  color('墨.n.bg', ink.fresh.bg, const CoRgba(180, 67, 44, 0.15));
  color('墨.m.bg', ink.reviewing.bg, const CoRgba(180, 67, 44, 0.075));
  color('墨.d.bg', ink.mastered.bg, const CoRgba(180, 67, 44, 0.026));
  for (final (tag, s) in [('n', ink.fresh), ('m', ink.reviewing), ('d', ink.mastered)]) {
    check('墨.$tag.bd = none', s.border == null);
    check('墨.$tag.fg = inherit', s.fg == null);
    near('墨.$tag.p.top', s.padding.top, 1, tol: 0.001);
    near('墨.$tag.p.right', s.padding.right, 3, tol: 0.001);
    near('墨.$tag.r', s.radius, 3, tol: 0.001);
  }

  // 格：线宽递减 2.5px 实线 → 1.5px 半透明 → 1px 虚线，背景始终透明
  final grid = gridTokens.trace;
  for (final (tag, s) in [('n', grid.fresh), ('m', grid.reviewing), ('d', grid.mastered)]) {
    check('格.$tag.bg = transparent', s.bg.isTransparent);
    near('格.$tag.p.top', s.padding.top, 0, tol: 0.001);
    near('格.$tag.p.bottom', s.padding.bottom, 1, tol: 0.001);
    near('格.$tag.r', s.radius, 0, tol: 0.001);
  }
  near('格.n.bd.width', grid.fresh.border!.width, 2.5, tol: 0.001);
  color('格.n.bd.color', grid.fresh.border!.color, const CoRgba.hex(0xC4533A));
  check('格.n.bd 实线', !grid.fresh.border!.dashed);
  near('格.m.bd.width', grid.reviewing.border!.width, 1.5, tol: 0.001);
  color('格.m.bd.color', grid.reviewing.border!.color, const CoRgba(0, 192, 139, 0.42));
  near('格.d.bd.width', grid.mastered.border!.width, 1.0, tol: 0.001);
  color('格.d.bd.color', grid.mastered.border!.color, const CoRgba(10, 10, 10, 0.16));
  check('格.d.bd 虚线', grid.mastered.border!.dashed);

  // 夜：亮度递减，用**不同灰阶**（暖 → 冷）而非单降亮度
  final night = nightTokens.trace;
  color('夜.n.fg', night.fresh.fg!, const CoRgba.hex(0xFFD9B8));
  color('夜.m.fg', night.reviewing.fg!, const CoRgba.hex(0xDEDCD7));
  color('夜.d.fg', night.mastered.fg!, const CoRgba.hex(0x8E939F));
  for (final (tag, s) in [('n', night.fresh), ('m', night.reviewing), ('d', night.mastered)]) {
    check('夜.$tag.bg = transparent', s.bg.isTransparent);
    check('夜.$tag.bd = none', s.border == null);
  }

  // 三态取用逻辑
  check('forReps(0) → fresh', ink.forReps(0) == ink.fresh);
  check('forReps(1) → reviewing', ink.forReps(1) == ink.reviewing);
  check('forReps(2) → reviewing', ink.forReps(2) == ink.reviewing);
  check('forReps(3) → mastered', ink.forReps(3) == ink.mastered);
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
  eq('中文 family', CoFonts.cjk, 'AlibabaPuHuiTi');
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
    if (f == CoFonts.cjk) continue; // 阿里普惠体不按此命名，单独跳
    final hit = RegExp('assets/fonts/$f[-\\w]*\\.ttf').allMatches(yaml);
    check('`$f` 的 asset 路径已声明', hit.isNotEmpty);
    for (final m in hit) {
      final p = File('${_repoRoot()}/app/${m.group(0)}');
      check('  文件存在: ${m.group(0)!.split('/').last}', p.existsSync(),
          p.existsSync() ? '${p.lengthSync()} B' : '缺文件');
    }
  }
}

/// 仓库根目录（从 cwd 向上找到含 app/ 的目录）。
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
  String src(String p) => File('$root/app/lib/$p').readAsStringSync();
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
    final s = f.readAsStringSync();
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
  String src(String p) => File('$root/app/lib/$p').readAsStringSync();
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
}
