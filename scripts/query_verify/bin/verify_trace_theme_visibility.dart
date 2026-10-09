// CoEvo · 痕迹样式「三档可见性」验收 —— 🔴 守一类**只在某一档才暴露**的失效
//
// 跑法：cd scripts/query_verify && dart run bin/verify_trace_theme_visibility.dart
// 🔴 退出码：0 = 全过，1 = 有失败。
//
// # 为什么需要它（2026-10-08 真机踩到的）
//
// 痕迹（「查过的词」的标识）在**三档阅读主题下的表达手段完全不同**：
//
// | 档 | `syntax` | 可见手段 | `fresh.bg` |
// |---|---|---|---|
// | 墨 | `wash`      | **底色**（`background: Paint`）| 朱砂 15%（有颜色）|
// | 格 | `underline` | **下划线**（`decoration`）    | `transparent` ← **设计如此** |
// | 夜 | `glow`      | **前景色**（`color`）         | `transparent` ← **设计如此** |
//
// 排查「文章页没有痕迹」时，我在诊断条里**只打印了 `bg`**，看到 `trans=true` 就当成
// 「痕迹不可见」—— 而那是**格档的正确值**。整条渲染链被反复怀疑、包源码被逐行读完，
// 真凶却是「**我只看了一种表达手段**」。
//
// 📌 判据（两条）：
//   ① **「同一份语义在多个变体下的表达手段可以不同」** —— 只查一种手段（或只看一档）
//      会把**正常**读成**故障**；
//   ② **「声明」与「配置」必须一致** —— `syntax` 声明了哪种手段，就必须真的配上那种
//      手段（声明 `wash` 却把 bg 设成透明 ⇒ 那一档的痕迹**永远不可见**，且不报错）。
//
// 🔴 本脚本的证伪方式（改完必须试一次）：
//   把某一档的 `bg` 改成 `CoRgba.transparent` 而 `syntax` 仍写 `wash` ⇒ ① 与 ② 都应变红。
//
// # ⚠️ 本脚本查不出的
//   · 真机的实际观感（下划线粗细是否够、底色是否太淡）—— 须真机
//   · 「格档痕迹」与「用户划线」**同形**这件事（两者都是下划线）——
//     它写在文末的【4】，只能验「至少粗细不同」，不能验「用户是否分得清」

import 'dart:io';

import '../../../app/lib/theme/coevo_tokens.dart';

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(label + (detail.isEmpty ? '' : '  ($detail)'));
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String _hex(int v) => v.toRadixString(16).padLeft(8, '0');

/// 一种痕迹样式**可见手段**的清单（与 `applyTraceStyle` 的三个分支逐条对应）。
({bool bg, bool border, bool fg}) _means(TraceStyle s) => (
      bg: !s.bg.isTransparent,
      border: s.border != null,
      fg: s.fg != null,
    );

/// `syntax` 声明的**主手段**。
TraceSyntax _declaredMain(TraceStyle s) {
  // `TraceTokens.syntax` 是**整档**的声明；这里按「配了什么」反推单条的主手段。
  // ⚠️ 之所以不直接用 `syntax`：`fresh` 与 `reviewing` 在同档下必须**同一种**手段，
  //    否则两态之间的切换会是一次「换了表达方式」而不是「同一种表达强弱变化」。
  if (!s.bg.isTransparent) return TraceSyntax.wash;
  if (s.border != null) return TraceSyntax.underline;
  if (s.fg != null) return TraceSyntax.glow;
  return TraceSyntax.wash; // 三种都没有 ⇒ 调用方会先被判失败
}

void main() {
  print('═' * 88);
  print('痕迹三档可见性验收 —— 每一档都必须**真的能看见**，且与声明一致');
  print('═' * 88);
  print('');
  print('档位表：${allTokens.entries.map((e) => "${e.value.label}(${e.key.name})").join(" · ")}');
  print('');

  var n = 0;
  for (final entry in allTokens.entries) {
    final theme = entry.key;
    final tokens = entry.value;
    final syntax = tokens.trace.syntax;
    n++;

    print('── ${tokens.label}（${theme.name}）· 声明 syntax = ${syntax.name} ──');

    for (final pair in [('fresh', tokens.trace.fresh), ('reviewing', tokens.trace.reviewing)]) {
      final name = pair.$1;
      final s = pair.$2;
      final m = _means(s);

      // ① **至少有一种**可见手段 —— 全空 ⇒ 这一态的痕迹**永远不可见**（静默）
      check('${tokens.label}·$name 至少有一种可见手段（bg/border/fg 不能全空）',
          m.bg || m.border || m.fg,
          'bg=${_hex(s.bg.argb32)}${s.bg.isTransparent ? "(透明)" : ""} '
              'border=${s.border?.width ?? "-"} fg=${s.fg == null ? "-" : _hex(s.fg!.argb32)}');

      // ② **与整档声明的 syntax 一致** —— 声明与配置漂移会让「这一档」看不出痕迹
      final main = _declaredMain(s);
      final wantGlow = syntax == TraceSyntax.glow;
      final ok = switch (syntax) {
        // 墨：靠底色 ⇒ bg 必须**非**透明
        TraceSyntax.wash => m.bg,
        // 格：靠下划线 ⇒ border 必须存在
        TraceSyntax.underline => m.border,
        // 夜：靠光 ⇒ 必须给了 fg（前景色）
        TraceSyntax.glow => !wantGlow || m.fg,
      };
      check('${tokens.label}·$name 与声明的手段一致（${syntax.name}）', ok,
          '实际主手段 = ${main.name}');
    }
    print('');
  }

  // ── ③ 三档的**表达方式必须互不相同**（否则「换档」等于没换表达）──
  print('── 三档的表达方式是否互不相同 ──');
  final mains = {
    for (final e in allTokens.entries)
      e.value.label: _declaredMain(e.value.trace.fresh)
  };
  check('三档的痕迹主手段互不相同（墨=底色 · 格=线 · 夜=光）',
      mains.values.toSet().length == mains.length,
      mains.entries.map((e) => "${e.key}=${e.value.name}").join(' · '));

  // ── ④ 已知冲突（**记录而非断言通过**）：格档痕迹 = 下划线，而用户划线也是下划线 ──
  print('');
  print('── 🔴 已知冲突：格档的「痕迹」与用户的「划线」同形 ──');
  final gridTrace = gridTokens.trace.fresh;
  final traceW = gridTrace.border?.width ?? 0;
  check('格档的痕迹确实是下划线（border 存在）', gridTrace.border != null,
      '宽度 $traceW');
  // 划线的样式在 `trace_markdown.dart` 的 `_highlightDirective` 里硬编码 `1.2`
  check('两者**至少**粗细不同（痕迹 $traceW vs 划线 1.2）', traceW != 1.2,
      '颜色同为 accentBright ⇒ **只能靠粗细区分**');
  print('  ⚠️ 这与既定的「**形状区分优于参数**」冲突 —— 需产品定（见当日交付说明）。');

  print('');
  print('═' * 88);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项（三档 · 两态）');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 症状对照：**某一档的痕迹完全看不见**（而其它档正常）——');
    print('    因为那档的「可见手段」没配上（如声明 wash 却把 bg 设成透明）。');
  }
  print('═' * 88);

  // 🔴 退出码（**必须有**）—— 少了它 CI 会**假绿**：脚本红了、退出码仍是 0。
  //    📌 判据：「`main` 正常返回」≠「退出码非 0」。
  if (_failures.isNotEmpty) exit(1);
}
