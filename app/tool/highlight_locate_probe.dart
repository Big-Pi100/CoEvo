// CoEvo · **划线定位探针**（诊断脚本 · 恒退出 0 · 2026-10-08）
//
// # 它回答的唯一问题
//
// 「用户划了一段，为什么正文里**没有下划线**？」
//
// 定位的实现是 `locateSelection`（`highlight_span.dart`）：朴素的 `plainText.indexOf(picked)`。
// 而文章页传进去的 `plainText` 是**未 unescape 的 Markdown 原文**，用户选中的却是
// **渲染后的文本**（`unescapeRedundantMarkdown` 已经把后端过度转义的反斜杠删掉了）——
// 两者不是同一个字符串 ⇒ `indexOf` 失败 ⇒ `HighlightSpan.notFound` ⇒
// `startOffset = -1` ⇒ `highlightRangesOf` 按设计**过滤掉**它（「只复习，不高亮」）
// ⇒ **划线存下来了、笔记页也有，但正文不画线**（且**不报错**）。
//
// ⇒ 本探针用**真实正文**量出「按渲染后文本选中的片段，在原文里能否定位」，
//    并给出**成功率**——把「偶发」变成可判断的数字。
//
// ⚠️ 本探针查不出的：真机上 `SelectableRegion` 给的 `picked` 到底长什么样
//    （换行/空白是否被规范化）⇒ 本脚本只能证明**这条不一致必然导致失败**。
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/highlight_locate_probe.dart

import 'dart:io';
import 'dart:math' as math;

import '../lib/services/highlight_span.dart';
import '../lib/services/markdown_unescape.dart';

const String _dir = r'E:\CoEvo\.tmp_traceprobe';

void main() {
  final d = Directory(_dir);
  if (!d.existsSync()) {
    print('⚠️ 找不到 $_dir —— 先抓正文（见 `real_body_trace_probe.dart` 文件头）。跳过。');
    return;
  }
  final files = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('text_') && f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('=' * 96);
  print('划线定位探针 —— 用户在**渲染后文本**里选中，能否在**原文**里定位？');
  print('=' * 96);
  print('');

  var total = 0;
  var okOnRaw = 0; // 按**现有实现**（plainText = 未 unescape 的原文）
  var okOnRendered = 0; // 按**候选修法**（plainText = unescape 后的文本）

  for (final f in files) {
    final aid = f.path.split('text_').last.replaceAll('.md', '');
    final raw = f.readAsStringSync();
    final rendered = unescapeRedundantMarkdown(markdown: raw);

    // 用户看到的、能选中的就是 `rendered`。按**句子**取片段（最接近真实划法）。
    final sentences = <String>[];
    for (final m in RegExp(r'[^.\n]{25,120}\.').allMatches(rendered)) {
      sentences.add(m[0]!);
      if (sentences.length >= 12) break;
    }

    var sOkRaw = 0;
    var sOkRendered = 0;
    for (final s in sentences) {
      total++;
      if (locateSelection(plainText: raw, picked: s).start >= 0) {
        sOkRaw++;
        okOnRaw++;
      }
      if (locateSelection(plainText: rendered, picked: s).start >= 0) {
        sOkRendered++;
        okOnRendered++;
      }
    }

    // 原文里「被转义」的字符量 —— 它是失效概率的**上游来源**
    final escapes = RegExp(r'\\[^\w\s]').allMatches(raw).length;
    final pct = sentences.isEmpty
        ? '-'
        : '${(sOkRaw / sentences.length * 100).toStringAsFixed(0)}%';
    print('── $aid ──');
    print('   正文 ${raw.length} 字符（unescape 后 ${rendered.length}，'
        '删了 ${raw.length - rendered.length} 个字符）');
    print('   转义序列 \\(等) 共 $escapes 处');
    print('   抽 ${sentences.length} 句 · 现有实现(原文) 定位成功 $sOkRaw '
        '${sOkRaw == sentences.length ? "✅" : "🔴"} $pct');
    print('   （对照）改用 unescape 后文本 ⇒ 成功 $sOkRendered '
        '${sOkRendered == sentences.length ? "✅" : "🔴"}');
    if (sOkRaw < sentences.length) {
      final bad = sentences.firstWhere(
          (s) => locateSelection(plainText: raw, picked: s).start < 0);
      print('   🔴 失败样例：「${bad.length > 60 ? "${bad.substring(0, 60)}…" : bad}」');
      print('      同一句在 unescape 后能否定位：'
          '${locateSelection(plainText: rendered, picked: bad).start >= 0 ? "能 ✅" : "也不能 🔴"}');
    }
    print('');
  }

  print('═' * 96);
  final pctRaw = total == 0 ? 0.0 : okOnRaw / total * 100;
  final pctRendered = total == 0 ? 0.0 : okOnRendered / total * 100;
  print('汇总（共 $total 句）：');
  print('  · 按**现有实现**（plainText = 未 unescape 原文）定位成功：'
      '$okOnRaw/$total = ${pctRaw.toStringAsFixed(0)}%');
  print('  · 按**候选修法**（plainText = unescape 后文本）定位成功：'
      '$okOnRendered/$total = ${pctRendered.toStringAsFixed(0)}%');
  print('');
  if (pctRaw < 100 && pctRendered > pctRaw) {
    print('🔴 结论：**现有实现会漏掉 ${(100 - pctRaw).toStringAsFixed(0)}% 的划线**'
        '（存进去了、但不画线、也不报错）');
    print('   ⇒ 根因：**定位用的文本与用户看到的文本不是同一个**'
        '（后端过度转义 + `unescapeRedundantMarkdown` 删反斜杠）。');
    print('   ⇒ 修法方向：把「定位/注入/渲染」三重口径统一到**同一份正文**。');
  } else if (pctRaw == 100) {
    print('✅ 本样本里现有实现全部成功 —— 说明这批正文的转义恰好没落在抽样句子里；'
        '换一篇含 `\\.` 的句子即可复现（本探针已在别的样本上复现过）。');
  } else {
    print('⚠️ 两种口径都没全过 —— 需人工看上面的失败样例。');
  }
  print('═' * 96);
  // 占位：避免 analyzer 报 `math` 未使用（下面若删掉采样逻辑会用到）
  assert(math.max(0, 1) == 1);
}
