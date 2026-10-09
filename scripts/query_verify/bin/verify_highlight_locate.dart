// CoEvo · 划线定位口径验收 —— 🔴 守一类「存下来了但画不出来」的静默失效
//
// 跑法：cd scripts/query_verify && dart run bin/verify_highlight_locate.dart
// 🔴 退出码：0 = 全过，1 = 有失败。
//
// # 为什么需要它（2026-10-08 真机踩到的）
//
// 用户在**渲染后**的正文上划一段，端侧要把这段文字**反查**回正文的字符偏移
// （`locateSelection` = 朴素 `indexOf`），再拿这个偏移去画下划线。
//
// 而后端按 CommonMark **过度转义**正文（`\\.` `\\"` `\\(` …），渲染前
// `unescapeRedundantMarkdown` 会把那些反斜杠**删掉** ⇒ 文本**变短**。
//
// 🔴 于是产生**两套坐标系**：用户选中的是「已 unescape 的文本」，
//    而过去 `plainText` 传的是「未 unescape 的原文」⇒ `indexOf` 找不到
//    ⇒ `start = -1` ⇒ `highlightRangesOf` 按设计过滤掉它（「只复习，不高亮」）
//    ⇒ **划线存下来了、笔记页也有，但正文不画线，且不报错**。
//
// 📊 探针实测（`app/tool/highlight_locate_probe.dart` · 6 篇真实正文 · 72 句）：
//    未 unescape ⇒ **3/72 = 4%** 成功；已 unescape ⇒ **72/72 = 100%**。
//
// # 本脚本的两条腿
//   ① **行为级**：用内联样本证明「两套坐标系必然失败」且「统一后必然成功」
//      （不依赖网络抓取的数据 —— 否则 CI 跑不了）
//   ② **结构级**：守住两处的口径与顺序（那是修复的**形状**，改回去就静默复发）
//
// 🔴 证伪方式（改完必须试一次，见文件末）：
//   把 `reader_screen` 的 `plainText:` 改回 `body` ⇒ ② 组变红。

import 'dart:io';

import '../../../app/lib/services/highlight_span.dart';
import '../../../app/lib/services/markdown_unescape.dart';

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

/// 仓库根（含 `app/pubspec.yaml` 的那一层，向上找特征文件而不是数层数）。
String repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

String read(String rel) =>
    File([repoRoot(), ...rel.split('/')].join(Platform.pathSeparator))
        .readAsStringSync();

/// 只去整行注释（`///` / `//` 开头的行）—— 避免注释里的示例代码被当成实现。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 后端过度转义的**真实形态**（取自生产正文：`\\.` `\\"` `\\(` `\\)` `\\-`）。
/// 🔑 它必须含 `.`（英文正文里最密集的字符）—— 那正是 96% 失效率的来源。
const String _rawBody = r'''
Q3 revenue was \(66\.4%\) up, per the CTO\. The report says \"growth\" is real\.
The Dutch NCSC documented them in advisory NCSC-2026-0392 on 23 September 2026\.
Three Langflow OSS vulnerabilities fixed by IBM carry CVSS v3 scores of 9\.8\.
No escapes live in this particular sentence so it matches either way.
''';

void main() {
  print('═' * 88);
  print('划线定位口径验收 —— 「用户选中的文本」必须在「定位用的文本」里找得到');
  print('═' * 88);

  // ══════════════════════════════════════════════════════════════
  print('');
  print('① 行为级：两套坐标系 vs 统一口径（内联样本，不依赖网络）');
  // ══════════════════════════════════════════════════════════════
  final canonical = unescapeRedundantMarkdown(markdown: _rawBody);

  check('①-0 样本确实含转义（否则本条测试空过）',
      _rawBody.contains(r'\.') && _rawBody.contains(r'\('),
      '转义点数 ${RegExp(r"\\[^\w\s]").allMatches(_rawBody).length}');
  check('①-1 unescape 真的让文本变短（坐标系确实会漂）',
      canonical.length < _rawBody.length,
      '${_rawBody.length} → ${canonical.length}');

  // 用户**看到并选中**的句子 —— 从 canonical 里取（模拟真实：他在渲染后的文本上划）
  final picked = canonical.split('\n').first.trim();
  check('①-2 取到一句渲染后的文本（含被转义过的 `.`）',
      picked.contains('.') && !picked.contains('\\'),
      picked.length > 40 ? '${picked.substring(0, 40)}…' : picked);

  final onRaw = locateSelection(plainText: _rawBody, picked: picked);
  final onCanonical = locateSelection(plainText: canonical, picked: picked);
  check('🔴 ①-3 用**未 unescape 的原文**定位 ⇒ 失败（这正是那个 bug）',
      onRaw.start < 0,
      '若这里绿了，说明样本不够像真实正文（本 bug 就不成立）');
  check('🔴 ①-4 用**已 unescape 的正文**定位 ⇒ 成功（这是修复后的口径）',
      onCanonical.start >= 0 && onCanonical.end > onCanonical.start,
      'got [${onCanonical.start},${onCanonical.end})');

  // 反过来：**不含转义**的句子在两种口径下都成功 ⇒ 说明 bug 是**转义**引起的，不是别的。
  // ⚠️ 取句要显式挑那一行（`split('\n').last` 会取到空行 ⇒ `picked` 为空 ⇒ 必然失败，
  //    我第一版就这么写错了 —— 样本自身缺陷会伪装成实现缺陷）。
  // 🔴 必须从**原文**里挑（不是从 canonical）：
  //    canonical 的每一行都不含反斜杠（那正是 unescape 的效果），若从它挑，
  //    会挑到「原文里含转义」的第一行 ⇒ 在原文里当然找不到 ⇒ 把**已证的 bug**
  //    当成「对照组失败」。我第一版就踩了这个（且 `plain` 的来源是判据的一部分）。
  final plain = _rawBody
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty && !l.contains('\\'));
  check('①-5-0 对照组句子确实不含转义（否则本条空过）', !plain.contains('\\'),
      plain.length > 40 ? '${plain.substring(0, 40)}…' : plain);
  check('①-5 对照：不含转义的句子在**原文**里也能定位（⇒ 差异确实来自转义）',
      locateSelection(plainText: _rawBody, picked: plain).start >= 0,
      '按原文定位 = ${locateSelection(plainText: _rawBody, picked: plain).start}');
  check('①-5b 同一句在 canonical 里同样能定位（两边都在 ⇒ 唯一变量是转义）',
      locateSelection(plainText: canonical, picked: plain).start >= 0);

  // ══════════════════════════════════════════════════════════════
  print('');
  print('② 结构级：两处的口径与顺序（修复的**形状**）');
  // ══════════════════════════════════════════════════════════════
  final trace = stripComments(read('app/lib/widgets/trace_markdown.dart'));
  final reader = stripComments(read('app/lib/screens/reader_screen.dart'));

  final iCanonical = trace.indexOf('unescapeRedundantMarkdown(markdown: markdown)');
  final iInject = trace.indexOf('injectHighlightMarkers(');
  check('②-1 找得到两处关键调用', iCanonical >= 0 && iInject >= 0,
      'canonical=$iCanonical inject=$iInject');
  check('🔴 ②-2 `unescape` 必须在**划线注入之前**（否则 offset 落在旧坐标系）',
      iCanonical >= 0 && iInject > iCanonical,
      '若红 ⇒ 划线 offset 与用户定位不同坐标系 ⇒ **96% 静默失画**');
  check('②-3 划线注入用的是 `canonical`（不是原始 `markdown`）',
      trace.contains('markdown: canonical'));

  check('🔴 ②-4 `reader_screen` 的 `plainText` 是 **unescape 后**的正文',
      reader.contains('plainText: unescapeRedundantMarkdown(markdown: body)'),
      '若红 ⇒ 用户选中渲染后文本、却拿原文去 indexOf ⇒ 找不到');
  check('②-5 两处用的是**同一个函数**（口径一处权威）',
      trace.contains('unescapeRedundantMarkdown(') &&
          reader.contains('unescapeRedundantMarkdown('));

  // ── 📌 有意差异：书页**不该** unescape（防「顺手修」）──
  final book = stripComments(read('app/lib/screens/book_reader_screen.dart'));
  check('②-6 🔑 书页的 `plainText` **不用** unescape（有意差异，别顺手改）',
      !book.contains('unescapeRedundantMarkdown'),
      '书页渲染纯文本、不经过 unescape ⇒ 那里 unescape 反而会让两边不一致');

  print('');
  print('═' * 88);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 症状对照：**划了线，正文里不出现下划线**，但「笔记」页里能看到那条；');
    print('    重开文章仍然没有 —— 因为 `startOffset = -1` 被 `highlightRangesOf` 过滤了。');
  }
  print('═' * 88);

  // 🔴 退出码（必须有）—— 少了它 CI 会假绿：「打印了失败」≠「退出码非 0」。
  if (_failures.isNotEmpty) exit(1);
}
