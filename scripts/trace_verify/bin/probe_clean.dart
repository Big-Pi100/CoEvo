// CoEvo · **排除 2 篇 PDF 乱码**后重新统计（诊断脚本 · 恒退出 0）
//
// 全量统计里 id=2041 / 2692 两篇 PDF 占 99.4% 的残留 —— 它们把真实分布完全掩盖。
// 按已知 id 精确排除（比猜「非 ASCII 比例」可靠），看**正常文章**还剩多少。
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_clean.dart

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

/// 已确认的乱码/非英语条目（会单独过滤，不参与「正常文章」统计）
const kJunkIds = <int>{
  2041, // The Legend of von Neumann [pdf] —— 西里尔+中文+阿拉伯混杂
  2692, // Electrification Special Report 2026 [pdf] —— 同上
  2658, // Telegram-бот… —— 真俄语（白哥报的那篇）
  744,  // 疑似误报（标题英语，body 少量西里尔）
};

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  final forms = <String, int>{};
  var ok = 0, junk = 0, withResidual = 0, totalResidual = 0, totalIn = 0;
  final perArticle = <int>[];

  for (final r in rows) {
    final b = (r['body'] ?? '') as String;
    if (b.isEmpty) continue;
    if (kJunkIds.contains(r['id'])) {
      junk++;
      continue;
    }
    ok++;

    final out = unescapeRedundantMarkdown(markdown: b);
    var n = 0;
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == r'\') {
        n++;
        forms[r'\' + out[i + 1]] = (forms[r'\' + out[i + 1]] ?? 0) + 1;
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
      perArticle.add(n);
    }
  }

  final pct = (100 * withResidual / ok).toStringAsFixed(1);
  final cutIn = totalIn == 0
      ? '—'
      : '${(100 * (totalIn - totalResidual) / totalIn).toStringAsFixed(1)}%';
  print('=' * 74);
  print('剔除乱码/非英语 $junk 篇后 · 正常文章 $ok 篇');
  print('=' * 74);
  print('  仍有反斜杠: $withResidual 篇 ($pct%)');
  print('  反斜杠: $totalIn → 残留 $totalResidual （消掉 $cutIn）');
  if (perArticle.isNotEmpty) {
    perArticle.sort();
    print('  单篇残留: 中位 ${perArticle[perArticle.length ~/ 2]} · '
        '最大 ${perArticle.last} · 均值 ${(totalResidual / perArticle.length).toStringAsFixed(1)}');
  }
  print('');
  final f = forms.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  print('残留形态 TOP 16:');
  for (final e in f.take(16)) {
    print('   ${e.key}\t${e.value}');
  }
}
