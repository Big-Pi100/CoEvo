// CoEvo · **划线标记探针**（诊断脚本 · 恒退出 0 · 2026-10-07）
//
// # 它回答的唯一问题
//
// 划线用的是「**在源文本里插控制字符标记**」这条路（与痕迹同一机制）。
// 但划线可能是**任意区间** —— 它会跨越 Markdown 的行内语法（`**粗体**`、`` `代码` ``…）。
//
// 🔴 关键风险：`gpt_markdown` 的 `InlinePattern` 文档原话是
//    「matches over the **text a parse produced**」⇒ 它作用在**解析后的节点文本**上。
//    ⇒ 若一对标记被语法**拆到不同节点**，正则 `\u0003…\u0003` 就**匹配不上**。
//
// 两种可能的后果，性质完全不同：
// | 后果 | 严重性 |
// |---|---|
// | 匹配不上 ⇒ **划线不显示** | 轻（少画一条线，不污染正文）|
// | 标记被当字面文本渲染出来 ⇒ 用户看到乱码 | 🔴 重（正文被破坏）|
//
// ⇒ 本探针用**真实解析器**（`plusparse`，纯 Dart）跑完整链路
//    （`injectHighlightMarkers` → 解析 → 按 `kHighlightMarkerPattern` 匹配），
//    量出到底是哪一种 —— 而不是凭「也许危险」猜。
//
// # 🔑 本探针还验证了 `_noMarkRanges` 里那条「行内语法单元要排除」的修法
//
// 首版**没有**排除行内语法单元，探针实测：**跨粗体 / 链接 / 行内代码的划线整条消失**
// （标记被拆到不同节点）。→ 修法是把这些语法单元整段排除，让标记在两侧断开。
// 本脚本的 ③④⑤⑥ 就是那几条的**回归**。
//
// ⚠️ **本探针查不出的**（如实标注）：
//    · `InlinePattern` 在 `GptMarkdown` 层的**真实匹配行为**（那需要 Flutter 环境）
//    · 真机上的视觉效果（下划线粗细、与粗体叠加好不好看）
//    ⇒ 本探针只回答「**标记在解析后是否仍成对**」—— 这是「能不能匹配上」的**必要**条件。
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/highlight_marker_probe.dart

import 'package:gpt_markdown/plusparse/ast.dart';
import 'package:gpt_markdown/plusparse/plusparse.dart';

import '../lib/services/trace_markdown_source.dart';

/// 把控制字符显示成可见符号（否则终端里看不见，等于没测）。
String vis(String s) => s
    .replaceAll(kHighlightOpen, '⟦')
    .replaceAll(kTraceFreshOpen, '‹')
    .replaceAll(kTraceReviewingOpen, '›');

String dump(MdNode n) => switch (n) {
      MdParagraph(:final children) => 'P(${children.map(dump).join(', ')})',
      MdHeading(:final level, :final children) =>
        'H$level(${children.map(dump).join(', ')})',
      MdText(:final text) => 'T「${vis(text)}」',
      MdBold(:final children) => 'B(${children.map(dump).join(', ')})',
      MdItalic(:final children) => 'I(${children.map(dump).join(', ')})',
      MdStrike(:final children) => 'S(${children.map(dump).join(', ')})',
      MdUnderline(:final children) => 'U(${children.map(dump).join(', ')})',
      MdLink(:final children) => 'Link(${children.map(dump).join(', ')})',
      MdInlineCode() => 'Code',
      MdInlineLatex() => 'ITex',
      MdBlockLatex() => 'BlockTex',
      MdCodeBlock() => 'CodeBlock',
      MdHorizontalRule() => 'HR',
      _ => '?(${n.runtimeType})',
    };

/// 收集所有 `MdText` 文本（`InlinePattern` 的匹配对象就是它们）。
List<String> textsOf(MdDocument doc) {
  final out = <String>[];
  void walk(MdNode x) {
    switch (x) {
      case MdText(:final text):
        out.add(text);
      case MdParagraph(:final children):
        children.forEach(walk);
      case MdBold(:final children):
        children.forEach(walk);
      case MdItalic(:final children):
        children.forEach(walk);
      case MdStrike(:final children):
        children.forEach(walk);
      case MdUnderline(:final children):
        children.forEach(walk);
      case MdLink(:final children):
        children.forEach(walk);
      case MdHeading(:final children):
        children.forEach(walk);
      default:
        break;
    }
  }

  doc.children.forEach(walk);
  return out;
}

/// 按**渲染层同一条正则**数出「能匹配上的划线段数」。
int matchedCount(String injected) {
  var n = 0;
  for (final t in textsOf(Plusparse.parse(injected))) {
    n += kHighlightMarkerPattern.allMatches(t).length;
  }
  return n;
}

int pass = 0;
int fail = 0;

void ctrl(String desc, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $desc   [$detail]');
  } else {
    fail++;
    print('  🔴 $desc   [$detail]');
  }
}

void main() {
  print('=' * 88);
  print('划线标记探针 —— 注入 → **真实解析** → 按渲染层正则匹配');
  print('=' * 88);

  /// 在 [src] 里按 [picked] 的位置构造区间并注入（模拟「用户选中 picked」）。
  String inject(String src, String picked, {int nth = 0}) {
    var at = -1;
    for (var k = 0; k <= nth; k++) {
      at = src.indexOf(picked, at + 1);
      if (at < 0) break;
    }
    if (at < 0) return src;
    return injectHighlightMarkers(
      markdown: src,
      ranges: [(start: at, end: at + picked.length)],
    );
  }

  print('');
  print('① 纯文本（对照 —— 不注入时不该有任何标记）');
  const p1 = 'A great achievement today.';
  ctrl('未注入 ⇒ 0 段', matchedCount(p1) == 0, '$p1');
  ctrl('注入后 ⇒ 1 段', matchedCount(inject(p1, 'great')) == 1,
      vis(inject(p1, 'great')));

  print('');
  print('② 🔴 最重要的一条：**剥掉控制字符后必须与原文逐字相同**');
  print('   （一句覆盖「只加不清、不改内容」整类风险）');
  for (final e in <String, String>{
    '纯文本': 'A great achievement today.',
    '含粗体': 'A **great** achievement and **more** text.',
    '含行内代码': 'Run `dart pub get` then **read** the log.',
    '含链接': 'See [the docs](https://x.com/a_b) for **more**.',
    '含代码块': 'Text.\n\n```dart\nfinal x = 1;\n```\n\nAfter.',
    '含转义': r'DELETE\. and \"QUERY\" here.',
  }.entries) {
    final picked = e.value.replaceAll(RegExp(r'[`\[\]()*\\]'), '').trim();
    final scope = picked.length > 12 ? picked.substring(0, 12) : picked;
    final injected = inject(e.value, scope);
    final stripped = injected.replaceAll(kHighlightOpen, '');
    ctrl('剥标记 == 原文 · ${e.key}', stripped == e.value,
        '注入：${vis(injected)}');
  }

  print('');
  print('③ 划线落在各种位置（探针实测的**能力边界**）');
  // 每条：源 / 划什么 / 预期能匹配到几段
  final cases = <(String label, String src, String picked, int want)>[
    ('纯文本里', 'A great achievement today.', 'great', 1),
    // 🔑 划线**落在**语法单元内部 ⇒ 标记包在定界符之内 ⇒ **正常匹配**
    ('整个落在粗体内', 'A **great** achievement today.', 'great', 1),
    // ⚠️ 跨粗体：定界符 `**` 被排除 ⇒ 标记断成 3 段 ——
    //    三段**都在自己的节点里成对** ⇒ 全都能显示（比「整条不画」好得多）
    ('跨越粗体', 'A great **best** moment today.', 'great **best** moment', 3),
    ('跨越行内代码', 'A great `code` moment today.', 'great `code` moment', 2),
    ('跨越链接', 'A great [link](http://x.com) moment.', 'great [link](http://x.com) moment',
        3),
    // 🔴 不可修复的两条：整段落在代码里 ⇒ 一个标记都不插（**有意**）
    ('整段落在代码块里', 'Before.\n\n```\ncode here\n```\n\nAfter.', 'code here', 0),
    ('整段落在行内代码里', 'A `code` here.', 'code', 0),
  ];
  for (final (label, src, picked, want) in cases) {
    final injected = inject(src, picked);
    final got = matchedCount(injected);
    ctrl('$label ⇒ $want 段', got == want, '实际 $got 段 · ${vis(injected)}');
  }

  print('');
  print('④ 幂等 / 边界');
  ctrl('空 ranges ⇒ 原样返回',
      injectHighlightMarkers(markdown: p1, ranges: const []) == p1, '');
  ctrl('start=-1 ⇒ 原样返回',
      injectHighlightMarkers(markdown: p1, ranges: const [(start: -1, end: -1)]) ==
          p1,
      '');
  ctrl('已含划线标记 ⇒ 原样返回（偏移已失配，不二次注入）',
      injectHighlightMarkers(
              markdown: 'A \u0003great\u0003 b', ranges: const [(start: 0, end: 1)]) ==
          'A \u0003great\u0003 b',
      '');
  ctrl('越界区间 ⇒ 钳到末尾，不抛',
      matchedCount(injectHighlightMarkers(
              markdown: p1, ranges: const [(start: 2, end: 9999)])) ==
          1,
      vis(injectHighlightMarkers(
          markdown: p1, ranges: const [(start: 2, end: 9999)])));

  print('');
  print('⑤ 划线与痕迹共存（划定优先 —— 痕迹跳过划线标记）');
  const p5 = 'A great achievement today.';
  final hi = inject(p5, 'great');
  final both = injectTraceMarkers(markdown: hi, tiers: const {'great': 0});
  ctrl('划线区内的词**不再有痕迹标记**', !both.contains(kTraceFreshOpen),
      vis(both));
  ctrl('但划线本身仍在', matchedCount(both) == 1, vis(both));
  final traceOnly = injectTraceMarkers(markdown: p5, tiers: const {'achievement': 0});
  ctrl('划线区外的词**正常有**痕迹标记', traceOnly.contains(kTraceFreshOpen),
      vis(traceOnly));

  print('');
  print('⑥ 全链顺序（划线 → 痕迹）：剥掉**两种**控制字符后仍等于原文');
  final chain = injectTraceMarkers(markdown: hi, tiers: const {'achievement': 0});
  ctrl('剥两种标记 == 原文',
      chain
              .replaceAll(kHighlightOpen, '')
              .replaceAll(kTraceFreshOpen, '')
              .replaceAll(kTraceReviewingOpen, '') ==
          p5,
      vis(chain));

  print('');
  print('=' * 88);
  print('探针自检：通过 $pass 项 · 失败 $fail 项');
  print('（本脚本**恒退出 0** —— 它是诊断工具，不是门禁；门禁在 `scripts/trace_verify`）');
  print('');
  print('⚠️ 本探针**查不出**的：`InlinePattern` 在 GptMarkdown 层的真实匹配 + 视觉');
  print('   —— 只回答了必要条件（标记在解析后仍成对）。须真机确认。');
  print('=' * 88);
}
