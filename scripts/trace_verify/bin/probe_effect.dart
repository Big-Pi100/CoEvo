// CoEvo · 扩白名单的**效果**验证（诊断脚本 · 恒退出 0）
//
// 问题：`probe_all.dart` 要处理那 2 篇 PDF（正文 4.3M / 3.5M 字符）⇒ 跑十几分钟。
// 那 2 篇是**乱码**（已定：不在正常内容范围内），跳过它们能快两个数量级。
//
// 本脚本统计「**正常文章**里消化后还剩多少反斜杠、什么形态」，
// 用来量化扩白名单的效果（对比扩之前的 27273 → 2377）。
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_effect.dart

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

/// 已确认的乱码/非英语条目（跳过 —— 它们不是正常内容，且体积极大）
const kJunkIds = <int>{2041, 2692, 2658, 744};

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  final forms = <String, int>{};
  var articles = 0, withResidual = 0, totalIn = 0, totalOut = 0;
  final perArticle = <int>[];

  for (final r in rows) {
    final id = r['id'] as int;
    if (kJunkIds.contains(id)) continue;
    final b = (r['body'] ?? '') as String;
    if (b.isEmpty) continue;
    articles++;

    var inN = 0;
    for (var i = 0; i < b.length; i++) {
      if (b[i] == r'\') inN++;
    }
    totalIn += inN;

    final out = unescapeRedundantMarkdown(markdown: b);
    var outN = 0;
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == r'\') {
        outN++;
        forms[r'\' + out[i + 1]] = (forms[r'\' + out[i + 1]] ?? 0) + 1;
      }
    }
    totalOut += outN;
    if (outN > 0) {
      withResidual++;
      perArticle.add(outN);
    }
  }

  final pct = totalIn == 0 ? '—' : (100 * (totalIn - totalOut) / totalIn).toStringAsFixed(1);
  print('=' * 74);
  print('正常文章 $articles 篇（跳过乱码/非英语 ${kJunkIds.length} 篇）');
  print('=' * 74);
  print('  反斜杠: $totalIn → 残留 $totalOut   消掉 $pct%');
  print('  仍有残留: $withResidual 篇 '
      '(${(100 * withResidual / articles).toStringAsFixed(1)}%)');
  if (perArticle.isNotEmpty) {
    perArticle.sort();
    print('  单篇残留: 中位 ${perArticle[perArticle.length ~/ 2]} · '
        '最大 ${perArticle.last} · 均值 ${(totalOut / perArticle.length).toStringAsFixed(1)}');
  }
  print('');
  final f = forms.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  print('残留形态 TOP 14:');
  for (final e in f.take(14)) {
    print('   ${e.key}\t${e.value}');
  }
}
