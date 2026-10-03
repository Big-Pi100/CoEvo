// CoEvo · 入库「内容质量闸门」两个判据的**最终阈值验证**（诊断脚本 · 恒退出 0）
//
// 拟定两个独立判据（各自管一类坏内容）：
//   A. 语言：拉丁字母占「全部字母」比例 < 0.9  → 非英语（俄语等）
//   B. 乱码：U+FFFD 替换字符占比 > 0.05        → 二进制被当文本（PDF 等）
//
// 本脚本要回答的是：
//   ① 正例是否都被拦住（俄语 / 2 篇 PDF）
//   ② 反例是否都保住（519 篇正常文章，**一篇都不能误杀**）
//   ③ 除已知 3 篇外，**分布的上界在哪**（找「临界样本」，防阈值踩线）
//
// 跑法：cd scripts/trace_verify && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run bin/probe_gate.dart

import 'dart:convert';
import 'dart:io';

const kLatinTh = 0.90;
const kJunkTh = 0.05;

bool _isLatin(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0x00C0 && c <= 0x024F);

bool _isLetter(int c) =>
    _isLatin(c) ||
    (c >= 0x0370 && c <= 0x03FF) ||
    (c >= 0x0400 && c <= 0x04FF) ||
    (c >= 0x0590 && c <= 0x05FF) ||
    (c >= 0x0600 && c <= 0x06FF) ||
    (c >= 0x4E00 && c <= 0x9FFF) ||
    (c >= 0x3040 && c <= 0x30FF) ||
    (c >= 0xAC00 && c <= 0xD7AF);

/// 拉丁字母占全部字母的比例（无字母 → 1.0，不因「无字母」误杀）。
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

/// 替换字符（U+FFFD）占比 —— 解码失败的标志。
double fffdRatio(String s) {
  if (s.isEmpty) return 0.0;
  var n = 0, total = 0;
  for (final c in s.runes) {
    total++;
    if (c == 0xFFFD) n++;
  }
  return total == 0 ? 0.0 : n / total;
}

/// 控制字符占比（排除 \n \t \r）—— 二进制数据的另一特征。
double ctrlRatio(String s) {
  if (s.isEmpty) return 0.0;
  var n = 0, total = 0;
  for (final c in s.runes) {
    total++;
    if (c < 0x20 && c != 0x0A && c != 0x09 && c != 0x0D) n++;
  }
  return total == 0 ? 0.0 : n / total;
}

void main() {
  final rows =
      jsonDecode(File('fixtures/all_bodies.json').readAsStringSync(encoding: utf8))
          as List;

  final mustDrop = <int>{2658, 2041, 2692}; // 正例
  final dropped = <int>[];
  final keptLowLatin = <List<Object>>[];
  final keptHighJunk = <List<Object>>[];
  var kept = 0;

  for (final r in rows) {
    final id = r['id'] as int;
    final text = '${r['title']}\n${r['body'] ?? ''}';
    if (text.trim().isEmpty) continue;

    final lat = latinRatio(text);
    final junk = fffdRatio(text);
    final ctrl = ctrlRatio(text);

    final drop = lat < kLatinTh || junk > kJunkTh;
    if (drop) {
      dropped.add(id);
      final why = lat < kLatinTh ? '非英语' : '乱码';
      final mark = mustDrop.contains(id) ? '✅' : '⚠️ 未预期的命中';
      print('  $mark id=$id [$why] 拉丁=${(lat * 100).toStringAsFixed(1)}% '
          'FFFD=${(junk * 100).toStringAsFixed(1)}% ctrl=${(ctrl * 100).toStringAsFixed(1)}%');
    } else {
      kept++;
      // 记录「接近阈值」的（临界样本）
      if (lat < 0.97) keptLowLatin.add([id, lat, r['title']]);
      if (junk > 0.005) keptHighJunk.add([id, junk, r['title']]);
    }
  }

  print('');
  print('=' * 76);
  print('结果');
  print('=' * 76);
  print('  丢弃 ${dropped.length} 篇 · 保留 $kept 篇 · 合计 ${dropped.length + kept}');
  final missed = mustDrop.difference(dropped.toSet());
  print('  正例漏网: ${missed.isEmpty ? "无 ✅" : "🔴 $missed"}');
  final wrong = dropped.where((x) => !mustDrop.contains(x)).toList();
  print('  误杀: ${wrong.isEmpty ? "无 ✅" : "🔴 $wrong"}');

  keptLowLatin.sort((a, b) => (a[1] as double).compareTo(b[1] as double));
  print('');
  print('  临界样本 · 保留的里拉丁占比最低的 5 篇（离阈值 $kLatinTh 有多远）:');
  for (final k in keptLowLatin.take(5)) {
    final t = k[2] as String;
    print('    id=${k[0]}  ${((k[1] as double) * 100).toStringAsFixed(2)}%  '
        '${t.length > 44 ? t.substring(0, 44) : t}');
  }

  keptHighJunk.sort((a, b) => (b[1] as double).compareTo(a[1] as double));
  print('');
  print('  临界样本 · 保留的里 FFFD 最高的 5 篇（离阈值 $kJunkTh 有多远）:');
  if (keptHighJunk.isEmpty) {
    print('    （全部为 0% —— 判据极干净）');
  }
  for (final k in keptHighJunk.take(5)) {
    final t = k[2] as String;
    print('    id=${k[0]}  ${((k[1] as double) * 100).toStringAsFixed(3)}%  '
        '${t.length > 44 ? t.substring(0, 44) : t}');
  }
}
