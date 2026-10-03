// CoEvo · 全量正文跑 `unescapeRedundantMarkdown`，看**残留分布**（诊断脚本 · 恒退出 0）
//
// 白哥 2026-10-03 报「`\` 转义符几乎每句句末都有」。
// 但单篇探针显示 `\.` **全被消化**（0 残留），残留的是 `\(` `\)`（LaTeX 定界符）。
// ⇒ 本脚本量化「全量到底还剩什么、集中在哪些源」，让判断基于事实而非印象。
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_all.dart

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  final forms = <String, int>{};
  final bySrc = <String, List<int>>{};
  final tot = <String, int>{};
  var withResidual = 0;
  var totalResidual = 0;
  var totalIn = 0;
  final worst = <List<Object?>>[];

  for (final r in rows) {
    final b = (r['body'] ?? '') as String;
    final s = r['src'].toString();
    tot[s] = (tot[s] ?? 0) + 1;
    if (b.isEmpty) {
      continue;
    }
    final out = unescapeRedundantMarkdown(markdown: b);

    var n = 0;
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == r'\') {
        n++;
        final k = r'\' + out[i + 1];
        forms[k] = (forms[k] ?? 0) + 1;
      }
    }
    var inN = 0;
    for (var i = 0; i < b.length; i++) {
      if (b[i] == r'\') inN++;
    }
    totalIn += inN;

    if (n > 0) {
      withResidual++;
      totalResidual += n;
      bySrc.putIfAbsent(s, () => <int>[]).add(n);
      worst.add(<Object?>[r['id'], s, n, (r['title'] ?? '').toString()]);
    }
  }

  final line = '=' * 74;
  print(line);
  print('全量 ${rows.length} 篇 · unescape 后仍有反斜杠的: $withResidual 篇');
  final cut = totalIn == 0
      ? '0'
      : (100 * (totalIn - totalResidual) / totalIn).toStringAsFixed(1);
  print('  反斜杠: $totalIn 个 → 残留 $totalResidual 个（消掉 $cut%）');
  print(line);

  final f = forms.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  print('');
  print('残留形态 TOP 18（`\\X` 计数）:');
  for (final e in f.take(18)) {
    print('   ${e.key.replaceAll('\n', r'\n')}\t${e.value}');
  }

  print('');
  print('按来源（残留篇数 / 总篇数 · 平均残留）:');
  final keys = bySrc.keys.toList()..sort();
  for (final s in keys) {
    final l = bySrc[s]!..sort();
    final sum = l.fold<int>(0, (a, b) => a + b);
    print('   src=$s: ${l.length}/${tot[s]} 篇 · 计 $sum · 中位 ${l[l.length ~/ 2]}');
  }

  worst.sort((a, b) => (b[2] as int).compareTo(a[2] as int));
  print('');
  print('残留最多的 8 篇:');
  for (final w in worst.take(8)) {
    final t = w[3] as String;
    print('   id=${w[0]} src=${w[1]} 残留=${w[2]} | '
        '${t.length > 50 ? t.substring(0, 50) : t}');
  }
}
