// CoEvo · **真实正文上的痕迹/划线注入探针**（诊断脚本 · 恒退出 0 · 2026-10-08）
//
// # 它回答的唯一问题
//
// `TraceMarkdown` 在**真实文章正文**上，到底有没有把标记注进去？
//
// `highlight_marker_probe.dart` 用的是**短测试文本**；而真实正文有它的特征：
//   · 9000–14000 字符 · 含 Markdown 语法（标题 / 列表 / 代码块 / 链接）
//   · 后端**过度转义**（`\.` `\"` `\(`）—— `unescapeRedundantMarkdown` 会删反斜杠
//   · 代码围栏数不定
// ⇒ 任何一条都可能让注入**在真实文本上**被跳过（而短文本上正常）。
//
// # 输入从哪来（⚠️ 本脚本依赖一份临时抓取的正文）
//
// `E:/CoEvo/.tmp_traceprobe/text_<id>.md`（由 `curl /api/feed/<id>` 提取 `item.body`）。
// 取不到就跳过 —— 它是诊断工具，不是门禁。
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/real_body_trace_probe.dart

import 'dart:io';
import 'dart:math' as math;

import '../lib/services/markdown_unescape.dart';
import '../lib/services/trace_markdown_source.dart';

const String _dir = r'E:\CoEvo\.tmp_traceprobe';

/// 可见化控制字符。
String vis(String s) => s
    .replaceAll('<HL>', '⟦') // 占位，见下
    .replaceAll(kHighlightOpen, '⟦')
    .replaceAll(kTraceFreshOpen, '‹')
    .replaceAll(kTraceReviewingOpen, '›');

/// 数一对标记（同字符开闭 ⇒ 总数 / 2）。
int pairsOf(String s, String marker) {
  final n = marker.allMatches(s).length;
  return n ~/ 2;
}

void main() {
  final d = Directory(_dir);
  if (!d.existsSync()) {
    print('⚠️ 找不到 $_dir —— 先跑抓取（见文件头）。跳过。');
    return;
  }
  final files = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('text_') && f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('=' * 96);
  print('真实正文注入探针 —— 6 篇（${files.length}）· 模拟 TraceMarkdown 的三步链');
  print('=' * 96);
  print('');
  print('三步链（与 `trace_markdown.dart` 的 build **逐字同序**）：');
  print('  ① injectHighlightMarkers(原文, 区间) → ② unescapeRedundantMarkdown → ③ injectTraceMarkers');
  print('');

  var allHlOk = 0;
  var allTrOk = 0;
  var n = 0;

  for (final f in files) {
    final aid = f.path.split('text_').last.replaceAll('.md', '');
    final raw = f.readAsStringSync();
    n++;

    // ── 构造输入（模拟真实场景）──
    // ① 划线：取正文 1/4 处的一段（避开开头，更接近真实）
    final at = (raw.length * 0.25).round();
    final hlEnd = math.min(at + 60, raw.length);
    // ② 痕迹：从正文里抽 6 个「长度 4–10 的纯字母词」（模拟查过的词）
    final words = <String>{};
    for (final m in RegExp(r'\b[a-z]{4,10}\b').allMatches(raw)) {
      final w = m[0]!;
      if (words.length >= 6) break;
      words.add(w);
    }
    final tiers = {for (final w in words) w: 0};

    // ── 三步链（逐字同序）──
    final step1 = injectHighlightMarkers(
      markdown: raw,
      ranges: [(start: at, end: hlEnd)],
    );
    final step2 = unescapeRedundantMarkdown(markdown: step1);
    final step3 = injectTraceMarkers(markdown: step2, tiers: tiers);

    // ── 统计 ──
    // ⚠️ 划线标记在 step1 就注入了；step2/step3 不该删掉它
    final hlPairs = pairsOf(step3, kHighlightOpen);
    final trPairs =
        pairsOf(step3, kTraceFreshOpen) + pairsOf(step3, kTraceReviewingOpen);

    // 还原性检查：剥掉两种标记后应等于 step2（即：标记没吃掉正文）
    final stripped = step3
        .replaceAll(kHighlightOpen, '')
        .replaceAll(kTraceFreshOpen, '')
        .replaceAll(kTraceReviewingOpen, '');
    final lossless = stripped.length == step2.length;

    final hlOk = hlPairs >= 1;
    final trOk = trPairs >= 1;
    if (hlOk) allHlOk++;
    if (trOk) allTrOk++;

    print('── $aid  (${raw.length} 字符 · 抽词 ${words.length}) ──');
    print('   ① 划线注入后标记数: ${pairsOf(step1, kHighlightOpen)}');
    print('   ② unescape 后标记数: ${pairsOf(step2, kHighlightOpen)}'
        '   （长度 ${step1.length} → ${step2.length}，删了 ${step1.length - step2.length} 个字符）');
    print('   ③ 三步后：划线 $hlPairs 对 · 痕迹 $trPairs 对'
        '   ${hlOk ? "✅" : "🔴"}${trOk ? "✅" : "🔴"}');
    print('   还原性（剥标记后 == step2）: ${lossless ? "✅" : "🔴 不一致"}');
    if (trPairs == 0) {
      print('   ⚠️ 痕迹为 0 —— 抽到的词：${words.take(6).join(", ")}');
      // 抽查第一个词是否真在正文里
      final w0 = words.first;
      final hit = step2.contains(w0);
      print('      正文里含「$w0」：$hit（若不在这里，说明该词落在被跳过的区间）');
    }
    print('');
  }

  print('═' * 96);
  print('汇总：划线注入成功 $allHlOk/$n · 痕迹注入成功 $allTrOk/$n');
  print('（本脚本**恒退出 0** —— 诊断工具）');
  print('');
  if (allHlOk == n && allTrOk == n) {
    print('🔑 结论：**注入层在真实正文上完全正常** ⇒ 痕迹/划线的缺失不在这一层。');
  } else {
    print('🔴 结论：**注入层在真实正文上有失败** ⇒ 这就是真机症状的根因（继续看上面哪一篇哪一步）。');
  }
  print('═' * 96);
}
