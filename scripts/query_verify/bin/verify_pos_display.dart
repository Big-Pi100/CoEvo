// CoEvo · 词性归一化验收（**读真库的 47 种写法**）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_pos_display.dart
// 退出码：0 = 全通过；1 = 有失败
//
// # 为什么必须用**真库数据**而不是手写样例
// 手写样例只能覆盖「我想到的写法」—— 而 `pos` 的混乱恰恰是**没被想到的那些**造成的
// （实测 47 种，含 `[c, u]` / `[modal v]` / `[adj（phrase）]` 这类非常规输入）。
// → 本脚本从 `word.db` 里**取全部出现过的 pos 值**跑一遍，报告任何未识别项。
//
// 🔑 这让「映射表的缺口」**可观测** —— 不用等用户在界面上看到 `xyz.` 才发现。

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/pos_display.dart';

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _failures.add('$label  $detail');
  }
}

void show(String label, bool ok, [String detail = '']) {
  check(label, ok, detail);
  print('  ${ok ? '✅' : '🔴'} $label${detail.isEmpty ? '' : '  ($detail)'}');
}

void eq(String label, Object? actual, Object? expected) =>
    show(label, actual == expected,
        actual == expected ? '' : '实得 ${actual!} · 期望 $expected');

String _repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${d.path}/app').existsSync() &&
        File('${d.path}/app/pubspec.yaml').existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

Future<void> main() async {
  print('═' * 72);
  print('CoEvo 词性归一化验收（真库数据）');
  print('═' * 72);

  // ═══ 【1】三类输入的规则（不依赖库）═══
  print('\n【1】归一化规则（词典惯例缩写）');
  eq('[n] → n.', normalizePos('[n]'), 'n.');
  eq('n → n.', normalizePos('n'), 'n.');
  eq('noun → n.', normalizePos('noun'), 'n.');
  show('🔑 同一词性的三种写法归一后相同',
      normalizePos('[n]') == normalizePos('n') && normalizePos('n') == normalizePos('noun'));
  eq('[n.] 剥尾点 → n.', normalizePos('[n.]'), 'n.');
  eq('大写 NOUN → n.', normalizePos('NOUN'), 'n.');
  eq('两侧空白被忽略', normalizePos('  [adj]  '), 'adj.');

  print('\n【2】可数性标记（c/u/pl 是名词的属性，不是独立词性）');
  eq('[c, u] → n.', normalizePos('[c, u]'), 'n.');
  eq('[u, c] → n.', normalizePos('[u, c]'), 'n.');
  eq('[n pl] → n.', normalizePos('[n pl]'), 'n.');
  show('🔑 三段都归 n.（去重后不重复）',
      normalizePos('[c, u]') == 'n.' && normalizePos('[n pl]') == 'n.');

  print('\n【3】复合与特殊形态');
  eq('[adj/adv] → adj. / adv.', normalizePos('[adj/adv]'), 'adj. / adv.');
  eq('[adj/v] → adj. / v.', normalizePos('[adj/v]'), 'adj. / v.');
  eq('[det./pron.] → det. / pron.', normalizePos('[det./pron.]'), 'det. / pron.');
  eq('[modal verb] 整串优先（不被拆开）', normalizePos('[modal verb]'), 'modal v.');
  eq('[modal v] 整串优先', normalizePos('[modal v]'), 'modal v.');
  eq('[adj（phrase）] 全角括号被剥掉', normalizePos('[adj（phrase）]'), 'adj.');
  eq('[prep phrase] → prep. phr.', normalizePos('[prep phrase]'), 'prep. phr.');

  print('\n【4】同义写法归一');
  for (final pair in [
    ('[interj]', '[int]'),
    ('[interj]', '[interjection]'),
    ('[v]', '[verb]'),
    ('[adj]', '[adjective]'),
    ('[adv]', '[adverb]'),
  ]) {
    show('${pair.$1} 与 ${pair.$2} 归一后相同',
        normalizePos(pair.$1) == normalizePos(pair.$2),
        '${normalizePos(pair.$1)} vs ${normalizePos(pair.$2)}');
  }

  print('\n【5】空与防御');
  eq('null → 空串', normalizePos(null), '');
  eq('空串 → 空串', normalizePos(''), '');
  eq('纯空格 → 空串', normalizePos('   '), '');
  eq('只有方括号 → 空串', normalizePos('[]'), '');
  eq('未知写法 → 原样保留（**不猜**）', normalizePos('zzz'), 'zzz');

  // ═══ 【6】🔴 真库全量：47 种写法是否全部被识别 ═══
  print('\n【6】真库全量 —— 取 word.db 里**所有出现过的 pos** 跑一遍');
  sqfliteFfiInit();
  final dbPath = '${_repoRoot()}/data/word.db';
  if (!File(dbPath).existsSync()) {
    show('word.db 存在', false, dbPath);
    _summary();
    exit(1);
  }

  final db = await databaseFactoryFfi.openDatabase(dbPath,
      options: OpenDatabaseOptions(readOnly: true));
  final rows = await db.query('card', columns: ['content']);
  await db.close();

  final allPos = <String, int>{}; // 归一化前的原始写法 → 出现次数
  for (final r in rows) {
    final raw = r['content'] as String?;
    if (raw == null) continue;
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final secs = (doc['sections'] as List?) ?? const [];
    for (final s in secs) {
      if (s is! Map || s['type'] != 'definition') continue;
      final pos = (s['pos'] as String?)?.trim() ?? '';
      if (pos.isEmpty) continue;
      allPos[pos] = (allPos[pos] ?? 0) + 1;
      break; // 只取首个 definition（与渲染层一致）
    }
  }

  print('  真库共 ${allPos.length} 种写法 · ${rows.length} 张卡');

  final unrecognized = <String, int>{};
  final normalized = <String, int>{}; // 归一化后 → 覆盖多少卡
  for (final e in allPos.entries) {
    if (!isPosRecognized(e.key)) unrecognized[e.key] = e.value;
    final n = normalizePos(e.key);
    normalized[n] = (normalized[n] ?? 0) + e.value;
  }

  show('🔴 全部 ${allPos.length} 种写法都被映射表识别',
      unrecognized.isEmpty, unrecognized.isEmpty ? '' : '未识别：$unrecognized');

  // 归一化后的分布（应集中到少数几类 —— 这是「归一化生效」的证据）
  final sorted = normalized.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('\n  归一化后的分布（应集中在少数几类）:');
  for (final e in sorted) {
    print('    ${e.key.padRight(14)} ${e.value.toString().padLeft(6)}  '
        '${(e.value / rows.length * 100).toStringAsFixed(1)}%');
  }
  show('归一化后类别数 ≤ 20（原 ${allPos.length} 种）',
      sorted.length <= 20, '实得 ${sorted.length} 类');

  // 每一类都必须以句点结尾（词典惯例 —— 除了未知原样保留的那些）
  final badFormat = sorted
      .map((e) => e.key)
      .where((k) => !k.split(' / ').every((p) => p.endsWith('.')))
      .toList();
  show('所有归一化结果都以「.」结尾（词典惯例）', badFormat.isEmpty,
      badFormat.isEmpty ? '' : '例外：$badFormat');

  _summary();
  exit(_failures.isEmpty ? 0 : 1);
}

void _summary() {
  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
  }
  print('═' * 72);
  if (_failures.isEmpty) {
    print('\n✅ 词性归一化覆盖真库全部写法，且结果统一为词典惯例缩写');
  }
}
