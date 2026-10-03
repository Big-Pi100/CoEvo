// CoEvo · 用**生产真实正文**探 `unescapeRedundantMarkdown` 的残留（诊断脚本，非断言）
//
// # 为什么需要它
//
// 白哥 2026-10-03 报：「`\` 转义符出现在正文中，几乎每句句末都有，与句号同时出现」。
// 但 `reader_screen.dart` 走的是 `TraceMarkdown`，而它**已经**调用了
// `unescapeRedundantMarkdown` ⇒ 说明**不是「没调」，而是「没消化干净」**。
//
// 要回答的是：**哪些 `\X` 残留？为什么？** 
//   —— 只能拿生产真实正文喂进**真实实现**（不重写一份逻辑，那会引入第二套判据）。
//
// # 跑法
//
//   cd scripts/trace_verify
//   /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_prod_bodies.dart
//
// ⚠️ 本脚本**只诊断、不断言**（退出码恒 0）—— 它输出的是「现象」，不是「对错」。
//    数据来源：`fixtures/prod_bodies.json`（从生产库 `content_pool.body` 导出）。

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

void main() {
  final f = File('fixtures/prod_bodies.json');
  if (!f.existsSync()) {
    stdout.writeln('🔴 缺少 fixtures/prod_bodies.json（先用 SSH 从生产导出）');
    exit(1);
  }
  final List<dynamic> rows = jsonDecode(f.readAsStringSync(encoding: utf8));

  stdout.writeln('=' * 78);
  stdout.writeln('生产真实正文 · unescape 残留探针');
  stdout.writeln('=' * 78);

  for (final r in rows) {
    final id = r['id'];
    final src = r['src'];
    final title = (r['title'] ?? '') as String;
    final body = (r['body'] ?? '') as String;

    final out = unescapeRedundantMarkdown(markdown: body);

    final inBs = body.split('').where((c) => c == r'\').length;
    final outBs = out.split('').where((c) => c == r'\').length;

    stdout.writeln('');
    stdout.writeln('── id=$id (src=$src) ${title.length > 52 ? '${title.substring(0, 52)}…' : title}');
    stdout.writeln('   反斜杠: 输入 $inBs → 输出 $outBs   消掉 ${inBs - outBs}');

    // 残留的 `\X` 形态统计
    final residual = <String, int>{};
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == r'\') {
        final k = r'\' + out[i + 1];
        residual[k] = (residual[k] ?? 0) + 1;
      }
    }
    if (residual.isEmpty) {
      stdout.writeln('   ✅ 无反斜杠残留');
    } else {
      final sorted = residual.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      stdout.writeln('   残留形态: ${sorted.take(10).map((e) => '${_esc(e.key)}×${e.value}').join('  ')}');
    }

    // 只看「点号」这一族（白哥报的形态）—— 给出上下文
    final dotIdx = <int>[];
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] == r'\' && out[i + 1] == '.') dotIdx.add(i);
    }
    if (dotIdx.isNotEmpty) {
      stdout.writeln('   🔴 残留 \\. 共 ${dotIdx.length} 处，样例:');
      for (final i in dotIdx.take(3)) {
        final a = i - 45 < 0 ? 0 : i - 45;
        final b = i + 45 > out.length ? out.length : i + 45;
        stdout.writeln('      …${_esc(out.substring(a, b))}…');
      }
    }
  }

  stdout.writeln('');
  stdout.writeln('=' * 78);
}

String _esc(String s) => s
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');
