// CoEvo · 语言过滤判据的**阈值实测**（诊断脚本 · 恒退出 0）
//
// # 🔴 为什么必须先跑这个，不能直接定阈值
//
// 我在调查报告里写的判据是「非 ASCII 字母占比 > 阈值」，
// 而 `probe_clean.dart` 里实现成了 `ord(ch) > 0x2000` —— **那是错的**：
//   西里尔 U+0400–U+04FF · 希腊 U+0370–U+03FF · **都小于 0x2000**
// ⇒ 那篇俄语（白哥报的那篇）**根本不会被滤掉**。
//   （这同时解释了当时那轮统计为何报「乱码 0 篇」。）
//
// 正确判据：**「拉丁字母」占「全部字母」的比例**。
//   拉丁 = A–Z a–z + 拉丁扩展（U+00C0–U+024F，含重音 é ü å）
//
// # 判据必须做**正反例双向验证**（只测反例会得到「永不误杀」的假结论）
//
// | 类型 | 样本 | 期望 |
// |---|---|---|
// | 正例（该滤） | id=2658 俄语 | **滤掉** |
// | 正例（该滤） | id=2041/2692 PDF 乱码 | **滤掉** |
// | 反例（不能滤） | 英文技术文（含 LaTeX/代码/人名）| **保留** |
// | 反例（不能滤） | id=744 标题英语+少量西里尔 | **保留** |
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_lang.dart

import 'dart:convert';
import 'dart:io';

/// 是否拉丁字母（含拉丁扩展的重音字母）。
bool _isLatin(int c) =>
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    (c >= 0x00C0 && c <= 0x024F); // 拉丁扩展（é ü å ñ …）

bool _isLetter(int c) =>
    _isLatin(c) ||
    (c >= 0x0370 && c <= 0x03FF) || // 希腊
    (c >= 0x0400 && c <= 0x04FF) || // 西里尔
    (c >= 0x0590 && c <= 0x05FF) || // 希伯来
    (c >= 0x0600 && c <= 0x06FF) || // 阿拉伯
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK
    (c >= 0x3040 && c <= 0x30FF) || // 日文假名
    (c >= 0xAC00 && c <= 0xD7AF); // 韩文

/// 拉丁字母占「全部字母」的比例。无字母 → 返回 1.0（不因「无字母」而误杀）。
double latinRatio(String s) {
  var letters = 0, latin = 0;
  for (final c in s.runes) {
    if (_isLetter(c)) {
      letters++;
      if (_isLatin(c)) latin++;
    }
  }
  return letters == 0 ? 1.0 : latin / letters;
}

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  const mustDrop = <int>{2658, 2041, 2692}; // 正例：必须滤掉
  const mustKeep = <int>{744}; // 反例：不能误杀

  print('=' * 78);
  print('① 正反例验证（先看这两组，通过才谈阈值）');
  print('=' * 78);
  for (final r in rows) {
    final id = r['id'] as int;
    if (!mustDrop.contains(id) && !mustKeep.contains(id)) continue;
    final b = (r['body'] ?? '') as String;
    final t = (r['title'] ?? '') as String;
    final ratio = latinRatio('$t\n$b');
    final expect = mustDrop.contains(id) ? '应滤掉' : '应保留';
    final ok = mustDrop.contains(id) ? ratio < 0.5 : ratio >= 0.5;
    print('  ${ok ? "✅" : "🔴"} id=$id $expect  拉丁占比=${(ratio * 100).toStringAsFixed(1)}%  '
        '${t.length > 38 ? t.substring(0, 38) : t}');
  }

  print('');
  print('=' * 78);
  print('② 阈值扫描（看每个阈值会滤掉谁）');
  print('=' * 78);
  for (final th in [0.5, 0.6, 0.7, 0.8, 0.9]) {
    final hit = <List<Object>>[];
    for (final r in rows) {
      final b = (r['body'] ?? '') as String;
      if (b.isEmpty) continue;
      final ratio = latinRatio('${r['title']}\n$b');
      if (ratio < th) hit.add([r['id'], r['src'], ratio, r['title']]);
    }
    print('');
    print('  阈值 $th → 命中 ${hit.length} 篇');
    for (final h in hit.take(6)) {
      final t = h[3] as String;
      print('     id=${h[0]} src=${h[1]} '
          '${((h[2] as double) * 100).toStringAsFixed(1)}%  '
          '${t.length > 44 ? t.substring(0, 44) : t}');
    }
    if (hit.length > 6) print('     …另有 ${hit.length - 6} 篇');
  }

  print('');
  print('=' * 78);
  print('③ 正常英文文章的占比分布（看误杀风险）');
  print('=' * 78);
  final ratios = <double>[];
  for (final r in rows) {
    final b = (r['body'] ?? '') as String;
    if (b.isEmpty) continue;
    ratios.add(latinRatio('${r['title']}\n$b'));
  }
  ratios.sort();
  print('  样本 ${ratios.length} 篇 · 最小 ${(ratios.first * 100).toStringAsFixed(1)}% · '
      'P1 ${(ratios[ratios.length ~/ 100] * 100).toStringAsFixed(1)}% · '
      '中位 ${(ratios[ratios.length ~/ 2] * 100).toStringAsFixed(1)}%');
  final low = ratios.where((x) => x < 0.9).length;
  print('  ⚠️ 占比 <90% 的: $low 篇（这些是「混入非拉丁字母」的候选，需人工看一眼）');
}
