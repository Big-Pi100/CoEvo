// CoEvo · **划线标记注入**验收（信息流页正文下划线 · 2026-10-07）
//
// # 为什么需要本脚本
//
// 信息流页的正文是 **Markdown 渲染**，所以划线**不能**像书架页那样按区间切 `TextSpan`
// ——它必须走「在源文本里插控制字符标记」这条路（与痕迹同一机制）。
//
// 这条路上每一步的错法都**静默**：
//   · 插进了**代码块 / 链接 URL** → 污染代码内容 / 🔴 链接失效（点不开，不报错）
//   · 顺序写反（先 unescape 再插）→ 偏移错位 → **下划线画到别处**
//   · 标记跨过 `**粗体**` 的定界符 → 被解析器拆到不同节点 → **整条划线不显示**
//   · 改坏了原文 → 正文掉字
//
// 🔑 本组最强的一条是【1】：**剥掉控制字符后必须与原文逐字相同** ——
//    它一句就覆盖了「只加不清、不改内容」这整类风险。
//
// 🔴 【2】是**顺序保护**：它是本功能唯一「设计上就对、但改一下也不报错」的地方。
//
// ⚠️ 本脚本**查不出**的（如实列出）：
//   · `gpt_markdown` 是否真的把标记渲染成带下划线的 span（需 Flutter 环境）
//   · 下划线的**视觉**（粗细 / 与字形距离）—— 文本断言验不到「好看」
//   · 真机上「划线 + 粗体」叠加后的观感
//   ⇒ 探针（`app/tool/highlight_marker_probe.dart`）回答「标记在解析后是否仍成对」，
//     那是「能匹配上」的**必要**条件；**充分**条件须真机确认。
//
// 跑法：`cd scripts/trace_verify && dart run bin/verify_highlight_markers.dart`
// 退出码：有失败 → 1

import 'dart:io';

import '../../../app/lib/services/highlight_span.dart'
    show HighlightRange, buildTextSegments;
import '../../../app/lib/services/markdown_unescape.dart';
import '../../../app/lib/services/trace_markdown_source.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = [];

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

void eq(String desc, Object? actual, Object? expected) =>
    check(desc, actual == expected, '实际=$actual 期望=$expected');

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

/// 把控制字符显示成可见符号（否则失败时看不出发生了什么）。
String vis(String s) => s
    .replaceAll(kHighlightOpen, '⟦')
    .replaceAll(kTraceFreshOpen, '‹')
    .replaceAll(kTraceReviewingOpen, '›');

/// 在 [src] 里找 [picked] 的第 [nth] 次出现并构造区间注入。
String injectAt(String src, String picked, {int nth = 0}) {
  var at = -1;
  for (var k = 0; k <= nth; k++) {
    at = src.indexOf(picked, at + 1);
    if (at < 0) break;
  }
  if (at < 0) throw StateError('用例写错了：源里找不到「$picked」');
  return injectHighlightMarkers(
    markdown: src,
    ranges: [(start: at, end: at + picked.length)],
  );
}

/// 剥掉两种标记（用于「不改内容」这条断言）。
String stripAll(String s) => s
    .replaceAll(kHighlightOpen, '')
    .replaceAll(kTraceFreshOpen, '')
    .replaceAll(kTraceReviewingOpen, '');

void main() {
  print('═' * 74);
  print('划线标记注入验收（信息流页 · Markdown 路径）');
  print('═' * 74);

  // ══════════════════════════════════════════════════════════════════════
  section('【1】🔴🔴 剥掉标记后必须与原文逐字相同（核心不变量）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 这一条覆盖「只加不清、不改内容」整类风险。**任何**输入都不许例外 ——
  // 一旦改了正文，用户看到的文章就与后端给的不是同一篇。
  final sources = <String, String>{
    '纯文本': 'A great achievement today. Someone said so.',
    '含粗体': 'A **great** achievement and **more** text here.',
    '含斜体': 'A *great* achievement and *more* here.',
    '含行内代码': 'Run `dart pub get` then **read** the log file.',
    '含链接': 'See [the docs](https://x.com/a_b) for **more** info.',
    '含代码块': 'Text before.\n\n```dart\nfinal x = 1;\n```\n\nText after.',
    '含转义': r'DELETE\. and \"QUERY\" \(66\.4%\) here.',
    '含删除线': 'A ~~great~~ achievement with ~~more~~ text.',
    '含列表': '- first item here\n- second item here\n',
    '含标题': '# Title of the piece\n\nBody text follows here.',
    '含方括号': 'JSON: \["IN", "US"\] and more text.',
    '空正文': '',
  };
  for (final e in sources.entries) {
    if (e.value.isEmpty) {
      eq('${e.key} ⇒ 原样返回',
          injectHighlightMarkers(markdown: '', ranges: const [(start: 0, end: 3)]),
          '');
      continue;
    }
    // 用**整篇**做区间（最激进的情形：一条线覆盖全文）
    final full = injectHighlightMarkers(
      markdown: e.value,
      ranges: [(start: 0, end: e.value.length)],
    );
    check('${e.key} · 全覆盖后剥标记 == 原文', stripAll(full) == e.value,
        vis(full));
    // 再取中间一段
    final lo = e.value.length ~/ 3;
    final hi = (e.value.length * 2) ~/ 3;
    final part = injectHighlightMarkers(
      markdown: e.value,
      ranges: [(start: lo, end: hi)],
    );
    check('${e.key} · 中段后剥标记 == 原文', stripAll(part) == e.value,
        vis(part));
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【2】🔴 顺序保护：划线必须在 unescape **之前**注入');
  // ══════════════════════════════════════════════════════════════════════
  //
  // `unescapeRedundantMarkdown` 会**删反斜杠**（`\.` → `.`）⇒ 它之后偏移全错位。
  // 顺序写反**不报错**，只是下划线**画到别处**（且差几个字符，肉眼极难发现）。
  //
  // 本组直接把两种顺序的结果**对比**：正确顺序标记包住的是期望文本，
  // 错误顺序会偏 —— 于是「改顺序」立刻红。
  const tricky = r'A DELETE\. and \"QUERY\" tail.';
  const wantWord = 'and';
  final at = tricky.indexOf(wantWord);
  // ✅ 正确：先注入（用原始偏移），再 unescape
  final correct = unescapeRedundantMarkdown(
    markdown: injectHighlightMarkers(
      markdown: tricky,
      ranges: [(start: at, end: at + wantWord.length)],
    ),
  );
  // ❌ 错误：先 unescape，再用**未调整的**偏移注入
  final wrong = injectHighlightMarkers(
    markdown: unescapeRedundantMarkdown(markdown: tricky),
    ranges: [(start: at, end: at + wantWord.length)],
  );

  /// 取出第一对标记里的内容。
  String firstMarked(String s) {
    final m = kHighlightMarkerPattern.firstMatch(s);
    return m == null ? '（无标记）' : (m.group(1) ?? '');
  }

  eq('✅ 正确顺序 ⇒ 标记恰好包住「$wantWord」', firstMarked(correct), wantWord);
  check('🔴 错误顺序 ⇒ 标记**不**包住「$wantWord」（所以这条能抓住改顺序）',
      firstMarked(wrong) != wantWord,
      '错误顺序实际包住：「${firstMarked(wrong)}」· ${vis(wrong)}');
  check('两种顺序的结果确实不同（否则本组无区分力）', correct != wrong,
      '正确=${vis(correct)}');

  // ══════════════════════════════════════════════════════════════════════
  section('【3】禁插区：代码块 / 行内代码 / 链接 URL / 行内语法定界符');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 不排除的后果各不相同：
  //   · 代码块 / 行内代码 → 控制字符被当代码内容 / 污染原文
  //   · 链接 URL → **链接失效**（点不开，不报错）
  //   · 行内语法定界符（`**` `~~` `[` `]`）→ 标记被解析器拆到不同节点 ⇒ **整条不显示**
  const codeSrc = 'Before text.\n\n```dart\nfinal x = 1;\n```\n\nAfter text.';
  final inCode = injectAt(codeSrc, 'final x = 1;');
  eq('🔴 代码块内**不插**标记', inCode, codeSrc);

  const inlineSrc = 'A `code snip` here and more.';
  final inInline = injectAt(inlineSrc, 'code snip');
  eq('🔴 行内代码内**不插**标记', inInline, inlineSrc);

  const urlSrc = 'See [docs here](https://x.com/a_b_c) now.';
  final inUrl = injectAt(urlSrc, 'https://x.com/a_b_c');
  eq('🔴 URL 内**不插**标记（插了链接会坏）', inUrl, urlSrc);

  // 划**链接文字**（不是 URL）⇒ 允许（标记在 `[` `]` 之内）
  final linkText = injectAt(urlSrc, 'docs here');
  check('链接**文字**可以标（定界符之外）',
      linkText.contains('$kHighlightOpen'), vis(linkText));
  check('且没有破坏链接语法（`](` 仍在）', linkText.contains('](https://x.com/a_b_c)'),
      vis(linkText));

  // `**` 定界符处必须断开（否则标记跨节点 ⇒ 整条不显示）
  const boldSrc = 'A great **best** moment today.';
  final acrossBold = injectAt(boldSrc, 'great **best** moment');
  // 🔑 判据是「**标记内部**不含 `*`」—— 不是「标记之间不出现 `**`」。
  //    ⚠️ 首版写成 `RegExp('\u0003[^\u0003]*\*\*[^\u0003]*\u0003')` 是**错的**：
  //    它匹配的是 `⟦**⟦`（标记**紧邻** `**`）—— 而那恰恰是**正确**的结果。
  //    📌 教训：正向描述要写成「期望的形状」，不要写成「某个正则不匹配」。
  check('🔴 跨粗体时标记内部**不含** `*`（含则跨节点 ⇒ 整条不显示）',
      kHighlightMarkerPattern
          .allMatches(acrossBold)
          .every((m) => !(m.group(1) ?? '').contains('*')),
      vis(acrossBold));
  check('断开后**两侧都有**标记（不是整条丢弃）',
      kHighlightMarkerPattern.allMatches(acrossBold).length >= 2,
      '${kHighlightMarkerPattern.allMatches(acrossBold).length} 段 · ${vis(acrossBold)}');
  check('跨粗体后剥标记 == 原文', stripAll(acrossBold) == boldSrc,
      vis(acrossBold));

  // 划线**整个落在**粗体内 ⇒ 应正常标（首版把 `**bold**` 整段排除，这里就该红）
  final insideBold = injectAt(boldSrc, 'best');
  check('🔴 划线整个落在粗体内 ⇒ **能**标（首版误排整段 ⇒ 这里会红）',
      kHighlightMarkerPattern.hasMatch(insideBold), vis(insideBold));
  check('落在粗体内剥标记 == 原文', stripAll(insideBold) == boldSrc, vis(insideBold));

  // ══════════════════════════════════════════════════════════════════════
  section('【4】区间处理：排序 / 重叠 / 越界 / 非法 / 幂等');
  // ══════════════════════════════════════════════════════════════════════
  const p = 'The habit of reading closely is replaced.';

  eq('空 ranges ⇒ 原样返回',
      injectHighlightMarkers(markdown: p, ranges: const []), p);
  eq('start = -1 ⇒ 原样返回（定位失败是正常状态）',
      injectHighlightMarkers(markdown: p, ranges: const [(start: -1, end: -1)]), p);
  eq('零宽 ⇒ 原样返回',
      injectHighlightMarkers(markdown: p, ranges: const [(start: 4, end: 4)]), p);
  eq('反向 ⇒ 原样返回',
      injectHighlightMarkers(markdown: p, ranges: const [(start: 9, end: 4)]), p);
  eq('start 超出长度 ⇒ 原样返回',
      injectHighlightMarkers(markdown: p, ranges: const [(start: 999, end: 1000)]), p);
  check('end 超出长度 ⇒ **钳到末尾**（不抛、不丢前半段）',
      injectHighlightMarkers(markdown: p, ranges: const [(start: 4, end: 9999)])
          .contains(kHighlightOpen),
      vis(injectHighlightMarkers(
          markdown: p, ranges: const [(start: 4, end: 9999)])));
  eq('钳制后剥标记 == 原文',
      stripAll(injectHighlightMarkers(markdown: p, ranges: const [(start: 4, end: 9999)])),
      p);

  // 乱序输入 ⇒ 输出按位置
  // ⚠️ 偏移要**算准**：`the habit of reading closely is replaced.` 小写化后
  //    `reading` 在 **[13, 20)** —— 首版写成 [15,22) ⇒ 断言红而实现是对的。
  final unordered = injectHighlightMarkers(markdown: p, ranges: const [
    (start: 13, end: 20),
    (start: 4, end: 9),
  ]);
  final marks = kHighlightMarkerPattern
      .allMatches(unordered)
      .map((m) => m.group(1) ?? '')
      .toList();
  eq('乱序输入 ⇒ 输出按位置（先 `habit`）', marks.first, 'habit');
  eq('乱序输入 ⇒ 第二段是 `reading`', marks[1], 'reading');
  eq('乱序剥标记 == 原文', stripAll(unordered), p);

  // 重叠 ⇒ 合并
  final overlap = injectHighlightMarkers(markdown: p, ranges: const [
    (start: 4, end: 15),
    (start: 10, end: 22),
  ]);
  eq('重叠 ⇒ 合并成 1 段',
      kHighlightMarkerPattern.allMatches(overlap).length, 1);
  eq('重叠合并取并集 [4,22)',
      kHighlightMarkerPattern.firstMatch(overlap)!.group(1),
      p.substring(4, 22));
  eq('重叠剥标记 == 原文', stripAll(overlap), p);

  // 端点相接 ⇒ **不**合并（与 `buildTextSegments` 同一口径）
  final adjacent = injectHighlightMarkers(markdown: p, ranges: const [
    (start: 4, end: 9),
    (start: 9, end: 15),
  ]);
  eq('端点相接 ⇒ 仍是 2 段（口径与书架页切分一致）',
      kHighlightMarkerPattern.allMatches(adjacent).length, 2);

  // 🔑 与 `buildTextSegments`（书架页）的**口径交叉核对**
  final crossRanges = [
    (id: 'A', start: 4, end: 15),
    (id: 'B', start: 10, end: 22),
    (id: 'C', start: 30, end: 999),
    (id: 'D', start: -1, end: -1),
    (id: 'E', start: 25, end: 25),
  ];
  final segs = buildTextSegments(
    text: p,
    ranges: crossRanges
        .map((r) => HighlightRange(id: r.id, start: r.start, end: r.end))
        .toList(),
  );
  final segHighlighted =
      segs.where((s) => s.isHighlighted).map((s) => s.text).toList();
  final injected = injectHighlightMarkers(
    markdown: p,
    ranges: crossRanges.map((r) => (start: r.start, end: r.end)).toList(),
  );
  final injMarked = kHighlightMarkerPattern
      .allMatches(injected)
      .map((m) => m.group(1) ?? '')
      .toList();
  // 🔴 必须比 `join` 后的字符串 —— **Dart 的 `List` 不重写 `==`**，
  //    两个内容完全相同的 list 用 `==` 比较也是 `false`（首版就栽在这里：
  //    报红的输出里两边**长得一模一样**）。📌 判据：断言里的比较对象要选
  //    **有值语义**的类型（String / num / 自定义 `==`），别直接比集合。
  eq('🔴 与书架页切分**产出同一批高亮片段**（两页口径一致）',
      injMarked.join('␟'), segHighlighted.join('␟'));

  // 幂等
  final once = injectAt(p, 'reading');
  eq('已含划线标记 ⇒ 原样返回（偏移已失配，不二次注入）',
      injectHighlightMarkers(markdown: once, ranges: const [(start: 0, end: 3)]), once);
  eq('二次注入后仍只有 1 段',
      kHighlightMarkerPattern.allMatches(injectHighlightMarkers(
              markdown: once, ranges: const [(start: 0, end: 3)]))
          .length,
      1);

  // ══════════════════════════════════════════════════════════════════════
  section('【5】与痕迹共存：划线优先，痕迹跳过划线标记');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 这是**有意的互斥**（不是遗漏）：两者都是高亮，叠加会互相干扰。
  //    顺序上也是必然的：划线先注入（按 offset），痕迹后注入（按词）⇒
  //    后者必然遇到前者的标记。
  const both = 'A great achievement today.';
  final hi = injectAt(both, 'great');
  final withTrace = injectTraceMarkers(markdown: hi, tiers: const {'great': 0});
  check('🔴 划线区内的词**不再有**痕迹标记（互斥）',
      !withTrace.contains(kTraceFreshOpen), vis(withTrace));
  eq('划线本身仍在', kHighlightMarkerPattern.allMatches(withTrace).length, 1);
  eq('全链剥两种标记 == 原文', stripAll(withTrace), both);

  final traceOutside =
      injectTraceMarkers(markdown: hi, tiers: const {'achievement': 0});
  check('划线区**外**的词正常有痕迹标记',
      traceOutside.contains(kTraceFreshOpen), vis(traceOutside));
  eq('划线区外的痕迹不破坏划线',
      kHighlightMarkerPattern.allMatches(traceOutside).length, 1);

  // ══════════════════════════════════════════════════════════════════════
  section('【6】全链顺序（划线 → unescape → 痕迹）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // ⚠️ 期望值**不是**原始 markdown —— unescape 会**有意**改文本（`\.` → `.`）。
  //    首版期望写成原始文本，于是「剥标记 == 原文」**必然红**（而实现是对的）。
  //    📌 这条断言的正确形式：剥标记 == **unescape 之后**的文本
  //       （即「划线注入 + 痕迹注入都没改内容」，unescape 的改动另算）。
  const fullSrc = r'A **great** achievement\. and [more](https://x.com) here.';
  final afterUnescape = unescapeRedundantMarkdown(markdown: fullSrc);
  final lo2 = fullSrc.indexOf('achievement');
  final chain = injectTraceMarkers(
    markdown: unescapeRedundantMarkdown(
      markdown: injectHighlightMarkers(
        markdown: fullSrc,
        ranges: [(start: lo2, end: lo2 + 'achievement'.length)],
      ),
    ),
    tiers: const {'here': 0},
  );
  eq('全链后剥两种标记 == **unescape 后**的文本', stripAll(chain), afterUnescape);
  check('全链确实消化了 `\\.`（说明 unescape 真的跑了）',
      !afterUnescape.contains(r'\.'), afterUnescape);
  check('全链后划线仍在', kHighlightMarkerPattern.hasMatch(chain), vis(chain));
  check('全链后痕迹仍在', chain.contains(kTraceFreshOpen), vis(chain));

  // ══════════════════════════════════════════════════════════════════════
  print('\n${'═' * 74}');
  if (_fail > 0) {
    print('🔴 失败 $_fail 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「剥标记 == 原文」类失败 → 检查 `injectHighlightMarkers` 的切分是否漏字；');
    print('  若「禁插区」类失败 → 检查 `_noMarkRanges` 的顺序扫描与 `_kInlineDelimiters`；');
    print('  若【2】顺序保护失败 → 检查 `TraceMarkdown.build` 里三步的**先后**。');
    exit(1);
  }
  print('✅ 全部通过：$_pass 项');
  print('═' * 74);
  print('');
  print('⚠️ 本脚本**查不出**的：');
  print('   · gpt_markdown 是否真的把标记渲染成带下划线的 span（需 Flutter 环境）');
  print('   · 下划线的视觉（粗细 / 与字形距离）与「划线 + 粗体」叠加的观感（真机）');
  print('   · 探针（app/tool/highlight_marker_probe.dart）回答「标记解析后是否仍成对」；');
  print('     那是**必要**条件，充分条件须真机确认。');
}
