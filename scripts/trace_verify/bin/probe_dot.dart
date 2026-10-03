// CoEvo · 定位「残留 `\.`」到底在正文的什么位置（诊断脚本 · 恒退出 0）
//
// # 为什么单独查这个
//
// 白哥原话：「`\` 转义符出现在正文中，**几乎每句的句末**都有与**句号**同时出现」。
// 全量统计里 `\.` 残留 **19766** 个 ⇒ 形态对得上，但**位置**决定修法：
//   · 若在**代码块/行内代码**里 → 保留是对的（代码内容不能改），用户看到属预期
//   · 若在**普通正文**里 → 是真 bug，该消化
//   · 若在 `\(...\)` LaTeX 里 → 是「保护了渲染器不认的语法」，该改成 `$…$` 或消化
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_dot.dart

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  var inPlain = 0, inCode = 0, inLatex = 0;
  final samples = <String>[];
  final byId = <int, int>{};

  for (final r in rows) {
    final b = (r['body'] ?? '') as String;
    if (b.isEmpty || !b.contains(r'\')) continue;
    final out = unescapeRedundantMarkdown(markdown: b);

    // 记录「源码里属于跳过区」的区间：代码块 / 行内代码 / 链接 URL / LaTeX
    final codeRanges = _markdownCodeRanges(out);
    final latexRanges = _latexRanges(out);

    var n = 0;
    for (var i = 0; i < out.length - 1; i++) {
      if (out[i] != r'\' || out[i + 1] != '.') continue;
      n++;
      if (_inAny(codeRanges, i)) {
        inCode++;
      } else if (_inAny(latexRanges, i)) {
        inLatex++;
      } else {
        inPlain++;
        if (samples.length < 12) {
          final a = i - 55 < 0 ? 0 : i - 55;
          final z = i + 30 > out.length ? out.length : i + 30;
          samples.add('id=${r['id']} src=${r['src']}: '
              '…${out.substring(a, z).replaceAll('\n', r'\n')}…');
        }
      }
    }
    if (n > 0) byId[r['id'] as int] = n;
  }

  print('=' * 74);
  print('残留 `\\.` 的位置分布');
  print('=' * 74);
  print('  普通正文（🔴 该消化却没消化）: $inPlain');
  print('  代码块/行内代码（✅ 预期保留）: $inCode');
  print('  LaTeX 区（⚠️ 渲染器不认 ⇒ 暴露源码）: $inLatex');
  print('');
  print('🔥 普通正文里的残留样例（这最像白哥描述的形态）:');
  for (final s in samples) {
    print('   $s');
  }
  if (samples.isEmpty) {
    print('   （无 —— 普通正文里的 `\\.` 已被消化干净）');
  }
}

/// 行内代码 `` ` `` 与围栏代码块 ``` ``` 的区间（简化判定，够用即止）。
List<List<int>> _markdownCodeRanges(String s) {
  final ranges = <List<int>>[];
  final lines = s.split('\n');
  var pos = 0;
  var fence = false;
  var fenceStart = 0;
  for (final ln in lines) {
    final t = ln.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) {
      if (!fence) {
        fence = true;
        fenceStart = pos;
      } else {
        fence = false;
        ranges.add([fenceStart, pos + ln.length]);
      }
    }
    pos += ln.length + 1;
  }
  if (fence) ranges.add([fenceStart, s.length]);

  // 行内代码：成对的 `` ` ``（不在围栏内的）
  var i = 0;
  while (i < s.length) {
    if (s[i] == '`' && !_inAny(ranges, i)) {
      final end = s.indexOf('`', i + 1);
      if (end > i) {
        ranges.add([i, end + 1]);
        i = end + 1;
        continue;
      }
    }
    i++;
  }
  return ranges;
}

/// `\\(…\\)` 与 `\\[…\\]`（行首）的区间。
List<List<int>> _latexRanges(String s) {
  final ranges = <List<int>>[];
  for (final d in [['\\(', '\\)'], ['\\[', '\\]']]) {
    var i = 0;
    while (i < s.length - 1) {
      if (s[i] == r'\' && s[i + 1] == d[0][1]) {
        final end = s.indexOf(d[1], i + 2);
        if (end > i) {
          ranges.add([i, end + 2]);
          i = end + 2;
          continue;
        }
      }
      i++;
    }
  }
  return ranges;
}

bool _inAny(List<List<int>> rs, int i) =>
    rs.any((r) => i >= r[0] && i < r[1]);
