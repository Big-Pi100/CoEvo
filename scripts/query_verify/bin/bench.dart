import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 稳态性能测试 —— 区分「首查」与「稳态」。
///
/// ⚠️ 用途澄清：本测是 **Windows 桌面 FFI** 下的数值，用于验证「索引是否有效」
/// 与「查询复杂度是否 O(log n)」；**不代表 iOS 真机性能**（不同 SQLite 构建 + 闪存）。
Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : r'E:\CoEvo\data\word.db';
  sqfliteFfiInit();
  final db = await databaseFactoryFfi
      .openDatabase(dbPath, options: OpenDatabaseOptions(readOnly: true));

  final words = (await db.rawQuery('SELECT spelling FROM word'))
      .map((r) => r['spelling'] as String)
      .toList();
  final forms = (await db.rawQuery('SELECT form FROM word_form'))
      .map((r) => r['form'] as String)
      .toList();
  print('词表 ${words.length} · word_form ${forms.length}');
  print('');

  Future<List<int>> bench(String label, Future<void> Function(int) fn,
      {int n = 2000, int warm = 200}) async {
    for (var i = 0; i < warm; i++) {
      await fn(i);
    }
    final ts = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await fn(i);
      sw.stop();
      ts.add(sw.elapsedMicroseconds);
    }
    ts.sort();
    final p50 = ts[n ~/ 2], p95 = ts[(n * 0.95).floor()], mx = ts.last;
    print('  ${label.padRight(44)} p50=${p50.toString().padLeft(5)}us  '
        'p95=${p95.toString().padLeft(5)}us  max=${mx.toString().padLeft(6)}us');
    return ts;
  }

  print('═══ 稳态性能（sqflite_common_ffi · 纯 Dart · 2000 次取 p50）═══');
  print('');
  print('【首查 vs 稳态】（同一查询，看首查是否显著更慢）');
  final swFirst = Stopwatch()..start();
  await db.rawQuery('SELECT id FROM word WHERE spelling = ?', ['receive']);
  swFirst.stop();
  print('  首次查询（冷）: ${swFirst.elapsedMicroseconds}us');
  await bench('word WHERE spelling=? → id',
      (i) => db.rawQuery('SELECT id FROM word WHERE spelling = ?', [words[i % words.length]]));
  print('');
  print('【完整查词链路】');
  await bench('word → card.content', (i) async {
    final w = await db.rawQuery(
        'SELECT id FROM word WHERE spelling = ?', [words[i % words.length]]);
    if (w.isNotEmpty) {
      await db.rawQuery('SELECT content FROM card WHERE word_id = ?', [w.first['id']]);
    }
  });
  print('');
  print('【词形还原链路】');
  await bench('word_form WHERE form=? → base', (i) =>
      db.rawQuery('SELECT base, anchor FROM word_form WHERE form = ?', [forms[i % forms.length]]));
  await bench('词形还原 → 再查 word', (i) async {
    final f = await db.rawQuery('SELECT base FROM word_form WHERE form = ?', [forms[i % forms.length]]);
    if (f.isNotEmpty) {
      await db.rawQuery('SELECT id FROM word WHERE spelling = ?', [f.first['base']]);
    }
  });
  print('');

  // ── 复杂度验证：查词耗时应与词表规模无关（走索引 = O(log n)）──
  print('【复杂度验证】是否存在「查询不到」导致的退化');
  await bench('未命中词（应同样快）', (i) =>
      db.rawQuery('SELECT id FROM word WHERE spelling = ?', ['zzznotaword$i']));

  // ── 划词最坏情形：一次查多个词（句子级）──
  print('');
  print('【句子级批量】（模拟一次划词查 8 个词）');
  await bench('8 词命中查询（1 次事务内）', (i) async {
    await db.transaction((txn) async {
      for (var k = 0; k < 8; k++) {
        await txn.rawQuery('SELECT id FROM word WHERE spelling = ?', [words[(i + k) % words.length]]);
      }
    });
  }, n: 500, warm: 50);

  await db.close();
  print('');
  print('✅ 完成');
}
