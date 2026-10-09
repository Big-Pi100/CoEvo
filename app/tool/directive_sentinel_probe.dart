// CoEvo · **directive sentinel 探针**（诊断脚本 · 恒退出 0 · 2026-10-08）
//
// # 它回答的唯一问题
//
// `gpt_markdown` 的 `inlineDirectives` 会在**解析之前**把标记区间换成一对
// PUA sentinel（`\u{E010}<index>:<base64 payload>\u{E011}`），渲染时
// （`_textSpans` → `expandInlineDirectives`）再换回来。
//
// 🔴 风险：**sentinel 必须完好地活过「解析」与「增量分片」两道关**。
//    · 解析器若把它吞了 / 拆进不同节点 ⇒ `decodeInlineDirectiveMask` 返回 null
//      ⇒ 这个区间被当**普通文本**渲染；而 PUA 字符在真机上是**不可见**的
//      ⇒ 用户看到的是「**干净的正文 + 什么都没有**」——**完全静默**。
//    · 这与白哥报的症状（「文章页没有任何痕迹」）**形状一致**，所以必须先测它。
//
// ⇒ 本探针用**真实解析器**（`plusparse`，纯 Dart）逐项量出 sentinel 是否存活，
//    并给出「若走旧参数 `inlinePatterns`（标记以控制字符留在文本里）会怎样」的对照。
//
// # ⚠️ 本探针**查不出**的（如实标注）
//
//    · `_textSpans` / `expandInlineDirectives` 的**真实执行**（那需要 Flutter 环境）
//    · 真机视觉（下划线粗细 / 底色深浅）
//    ⇒ 本探针只回答「**若展开被调用，它的输入还在不在**」——这是必要条件，不是充分条件。
//
// # 🔑 关于本文件里的 `maskInline`（照抄包源码）
//
// 它是 `gpt_markdown-1.3.0/lib/inline_directive.dart` 的 `maskInlineDirectives`
// 的**逐行移植**（只去掉 `blockRegistry` 分支 —— 本项目没注册扩展块）。
// ⚠️ **包升级后必须回来核对**：两侧一旦漂移，本探针的结论就不再适用于真实渲染。
//    （为了让它可核对，下面保留了 `_maskOpen` / `_maskClose` 的字面值与包一致。）
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/directive_sentinel_probe.dart

import 'dart:convert';

import 'package:gpt_markdown/plusparse/ast.dart';
import 'package:gpt_markdown/plusparse/plusparse.dart';

import '../lib/services/trace_markdown_source.dart';

// ── 与包 `inline_directive.dart` 一致的字面值（改包时必须回来对）──
const String _maskOpen = '\u{E010}';
const String _maskClose = '\u{E011}';

/// `gpt_markdown-1.3.0/lib/inline_directive.dart` 的 `maskInlineDirectives` 移植版。
///
/// 差异只有一处：去掉 `blockRegistry` 分支（本项目没注册扩展块，
/// 所以真实渲染走的就是这里的「主循环」路径）。
String maskInline(String source, List<({String open, String close})> directives) {
  if (directives.isEmpty) return source;
  var out = source;
  for (var index = 0; index < directives.length; index++) {
    final d = directives[index];
    if (!out.contains(d.open)) continue;
    final buffer = StringBuffer();
    var cursor = 0;
    while (cursor < out.length) {
      final start = out.indexOf(d.open, cursor);
      if (start == -1) break;
      final from = start + d.open.length;
      final end = out.indexOf(d.close, from);
      if (end == -1) break; // 未闭合 ⇒ 保持字面
      buffer
        ..write(out.substring(cursor, start))
        ..write(_maskOpen)
        ..write(index)
        ..write(':')
        ..write(base64Encode(utf8.encode(out.substring(from, end))))
        ..write(_maskClose);
      cursor = end + d.close.length;
    }
    if (buffer.isNotEmpty) {
      buffer.write(out.substring(cursor));
      out = buffer.toString();
    }
  }
  return out;
}

/// 把不可见字符显示成可见符号（否则终端里看不见，等于没测）。
String vis(String s) => s
    .replaceAll(_maskOpen, '⟪')
    .replaceAll(_maskClose, '⟫')
    .replaceAll(kHighlightOpen, '⟦')
    .replaceAll(kTraceFreshOpen, '‹')
    .replaceAll(kTraceReviewingOpen, '›');

/// 收集所有 `MdText` 文本（渲染层 `_textSpans` 收到的就是它们）。
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

int pass = 0;
int fail = 0;

void ctrl(String desc, bool ok, [String detail = '']) {
  if (ok) {
    pass++;
    print('  ✅ $desc   [$detail]');
  } else {
    fail++;
    print('  🔴 $desc   [$detail]');
  }
}

/// 一段足够真实的正文（含粗体 / 行内代码 / 链接 —— 即会拆节点的那些语法）。
const String _body = '''
The great migration began in spring. It was a **remarkable** sight.

Researchers used `tracking tags` to follow them ([source](http://x.com/study)).
''';

void main() {
  print('=' * 92);
  print('directive sentinel 探针 —— mask → **真实解析** → sentinel 是否存活');
  print('=' * 92);

  // 三个 directive 与 `trace_markdown.dart` 注册的**逐字对应**：
  //   index 0 = 痕迹 fresh（\u0001）· 1 = 痕迹 reviewing（\u0002）· 2 = 划线（\u0003）
  final directives = <({String open, String close})>[
    (open: kTraceFreshOpen, close: kTraceFreshOpen),
    (open: kTraceReviewingOpen, close: kTraceReviewingOpen),
    (open: kHighlightOpen, close: kHighlightOpen),
  ];

  // ── 构造注入后的正文（痕迹一个词 + 划线跨粗体一句）──
  //
  // 划线用 `injectHighlightMarkers`（**真实实现**），痕迹手工套上 fresh 标记 ——
  // 这样「注入」这一侧是真的，我们只替换掉不可能在本机跑的部分（Flutter 渲染）。
  final at = _body.indexOf('great migration');
  final withHl = injectHighlightMarkers(
    markdown: _body,
    ranges: [(start: at, end: at + 'great migration'.length)],
  );
  final injected = withHl.replaceFirst('remarkable', '$kTraceFreshOpen'
      'remarkable$kTraceFreshOpen');

  print('');
  print('① 注入产物（可见化）');
  print('    ${vis(injected)}');
  ctrl('①-1 划线标记成对', kHighlightMarkerPattern.hasMatch(injected));
  ctrl('①-2 痕迹标记在', injected.contains(kTraceFreshOpen));

  print('');
  print('② mask 之后（解析器实际看到的东西）');
  final masked = maskInline(injected, directives);
  print('    ${vis(masked)}');
  ctrl('②-1 源里**不再有**任何控制字符标记（已被 sentinel 取代）',
      !masked.contains(kHighlightOpen) && !masked.contains(kTraceFreshOpen));
  ctrl('②-2 sentinel 出现了', masked.contains(_maskOpen) && masked.contains(_maskClose));
  final sentinelCount = RegExp(RegExp.escape(_maskOpen)).allMatches(masked).length;
  ctrl('②-3 sentinel 对数 = 2（一个划线 + 一个痕迹）', sentinelCount == 2,
      '实际 $sentinelCount 对');

  print('');
  print('③ 🔴 关键：sentinel 能否存活过 `Plusparse.parse`');
  final texts = textsOf(Plusparse.parse(masked));
  print('    解析出 ${texts.length} 个 MdText：');
  for (final t in texts) {
    print('      · 「${vis(t)}」');
  }
  final alive = texts.where((t) => t.contains(_maskOpen)).toList();
  ctrl('③-1 sentinel 仍在解析后的文本里', alive.isNotEmpty,
      '若红 ⇒ 掩码丢失 ⇒ 渲染层换不回 span ⇒ **静默无痕迹**');
  final paired = texts.where(
      (t) => t.contains(_maskOpen) && t.contains(_maskClose)).length;
  ctrl('③-2 每对 sentinel **完整落在同一个 MdText 内**（没被拆到两个节点）',
      paired == alive.length && paired > 0,
      '完整 $paired / 含 open 的 ${alive.length}');

  print('');
  print('④ 对照：**旧参数 `inlinePatterns`** 的路径（标记以控制字符留在文本里）');
  // `inlinePatterns` 不 mask，标记直接留在源里 ⇒ 它要求「解析后仍成对」。
  final crossing = textsOf(Plusparse.parse(injected));
  var matched = 0;
  for (final t in crossing) {
    matched += kHighlightMarkerPattern.allMatches(t).length;
  }
  ctrl('④-1 旧路径：解析后划线标记仍成对（跨粗体那句）', matched >= 1,
      '匹配 $matched 段');
  final traceAlive = crossing.where((t) => t.contains(kTraceFreshOpen)).length;
  ctrl('④-2 旧路径：解析后痕迹标记仍在', traceAlive > 0, '$traceAlive 个节点含标记');

  print('');
  print('⑤ 增量分片：按空行切片后，sentinel 会不会被切开');
  // 增量视图把源按空行分段、每段单独 parse ⇒ 只要 sentinel 内部不含空行就不会被切开。
  final segments = masked.split('\n\n');
  ctrl('⑤-1 无分片含**半个** sentinel（有 open 无 close，或反之）',
      segments.every((s) =>
          s.contains(_maskOpen) == s.contains(_maskClose)),
      '分片数 ${segments.length}');
  final segTexts = <String>[
    for (final s in segments) ...textsOf(Plusparse.parse(s)),
  ];
  final segPaired = segTexts.where(
      (t) => t.contains(_maskOpen) && t.contains(_maskClose)).length;
  ctrl('⑤-2 分片解析后 sentinel 仍完整', segPaired > 0, '完整 $segPaired 个');

  print('');
  print('=' * 92);
  print('探针自检：通过 $pass 项 · 失败 $fail 项');
  print('（本脚本**恒退出 0** —— 它是诊断工具，不是门禁；门禁在 `scripts/trace_verify`）');
  print('');
  print('⚠️ 本探针**查不出**的：`_textSpans` / `expandInlineDirectives` 的真实执行 + 视觉');
  print('   —— 只回答了「展开时**输入是否还在**」这个必要条件。须真机确认。');
  print('=' * 92);
}
