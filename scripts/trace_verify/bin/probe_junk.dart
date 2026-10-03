// CoEvo · 那两篇 PDF 条目的**真实性质**（诊断脚本 · 恒退出 0）
//
// 语言判据（拉丁字母占比）对它们无效 —— 它们 93% 是英文。
// ⇒ 它们不是「外语文章」，是**别的东西**。本脚本查清是什么。
//
// 假设（待验证，不预设）：
//   · HN 的 `[pdf]` 帖子 → 我们抓的是 PDF 二进制 → 当 HTML 解析 ⇒ 乱码
//   · 或：压缩流 / 字体嵌入数据被当正文
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_junk.dart

import 'dart:convert';
import 'dart:io';

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  for (final id in [2041, 2692]) {
    final r = rows.firstWhere((x) => x['id'] == id, orElse: () => null);
    if (r == null) continue;
    final b = (r['body'] ?? '') as String;

    var fffd = 0, ctrl = 0, printable = 0, latin = 0, total = 0;
    final ctrlSet = <int>{};
    for (final c in b.runes) {
      total++;
      if (c == 0xFFFD) {
        fffd++; // U+FFFD 替换字符 = 解码失败的标志
      } else if (c < 0x20 && c != 0x0A && c != 0x09 && c != 0x0D) {
        ctrl++;
        ctrlSet.add(c);
      } else if (c >= 0x20 && c < 0x7F) {
        printable++;
        if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) latin++;
      }
    }

    print('=' * 76);
    print('id=$id · 长度 $total');
    print('  U+FFFD（替换字符）: $fffd  (${(100 * fffd / total).toStringAsFixed(2)}%)');
    print('  控制字符: $ctrl  样本码点: ${ctrlSet.take(8).map((c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}').join(' ')}');
    print('  ASCII 可打印: $printable  (${(100 * printable / total).toStringAsFixed(2)}%)');
    print('  其中 a-zA-Z: $latin');
    print('  source_id=${r['src']}  title=${r['title']}');
    print('');
    print('  开头 200 字符（原样）:');
    print('  ${b.substring(0, 200.clamp(0, b.length)).replaceAll('\n', '⏎')}');
    print('');
    print('  中段 200 字符:');
    final mid = b.length ~/ 2;
    print('  ${b.substring(mid, (mid + 200).clamp(0, b.length)).replaceAll('\n', '⏎')}');
    print('');
  }

  print('=' * 76);
  print('对比：正常英文文章的同类指标（取 id=553 技术文）');
  final n = rows.firstWhere((x) => x['id'] == 553, orElse: () => null);
  if (n != null) {
    final b = (n['body'] ?? '') as String;
    var fffd = 0, ctrl = 0, printable = 0, total = 0;
    for (final c in b.runes) {
      total++;
      if (c == 0xFFFD) {
        fffd++;
      } else if (c < 0x20 && c != 0x0A && c != 0x09 && c != 0x0D) {
        ctrl++;
      } else if (c >= 0x20 && c < 0x7F) {
        printable++;
      }
    }
    print('  U+FFFD: $fffd (${(100 * fffd / total).toStringAsFixed(2)}%) · '
        '控制字符: $ctrl (${(100 * ctrl / total).toStringAsFixed(2)}%) · '
        'ASCII 可打印: ${(100 * printable / total).toStringAsFixed(2)}%');
  }
}
