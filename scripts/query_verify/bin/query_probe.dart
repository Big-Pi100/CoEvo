import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 探针：验证「纯 Dart（无 Flutter）能否打开真 word.db 并跑查词」。
///
/// 这是 Phase 1 #11（端侧索引化查询）可行性的决定性前提：
/// 若能 → 查询层可做成纯 Dart → 本地可验证（符合 verifiable-core-logic）
/// 若不能 → 只能等真机/CI 验证
Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty
      ? args[0]
      : r'E:\CoEvo\data\word.db';

  if (!File(dbPath).existsSync()) {
    stderr.writeln('找不到 word.db: $dbPath');
    exit(2);
  }

  // 纯 Dart 环境必须显式初始化 ffi factory（Flutter 里由 sqflite 插件接管）
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  print('DB: $dbPath  (${(File(dbPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB)');
  print('');

  final db = await factory.openDatabase(dbPath, options: OpenDatabaseOptions(readOnly: true));

  try {
    // ── 1. 表与索引 ────────────────────────────────────────────
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name");
    print('表 ${tables.length} 个 · 索引 ${indexes.length} 个');

    // ── 2. 精确查词（核心路径）──────────────────────────────────
    print('');
    print('【精确查词】receive');
    final sw = Stopwatch()..start();
    final w = await db.rawQuery(
        'SELECT id, spelling, cefr_level, entry_type FROM word WHERE spelling = ?', ['receive']);
    sw.stop();
    print('  word 查询: ${sw.elapsedMicroseconds}us → ${w.length} 行'
        '${w.isNotEmpty ? "  id=${w.first['id']} cefr=${w.first['cefr_level']}" : ""}');

    if (w.isNotEmpty) {
      final wid = w.first['id'] as String;
      final sw2 = Stopwatch()..start();
      final card = await db.rawQuery('SELECT content FROM card WHERE word_id = ?', [wid]);
      sw2.stop();
      final len = (card.isEmpty ? 0 : (card.first['content'] as String).length);
      print('  card 查询: ${sw2.elapsedMicroseconds}us → ${card.length} 行, content ${len} 字符');
    }

    // ── 3. 词形还原（received → receive）──────────────────────
    print('');
    print('【词形还原】received → ?');
    final sw3 = Stopwatch()..start();
    final f = await db.rawQuery(
        'SELECT form, base, anchor, depth, in_vocab FROM word_form WHERE form = ?', ['received']);
    sw3.stop();
    print('  word_form: ${sw3.elapsedMicroseconds}us → ${f.length} 行');
    for (final r in f) {
      print('    form=${r['form']} base=${r['base']} anchor=${r['anchor']} '
          'depth=${r['depth']} in_vocab=${r['in_vocab']}');
    }

    // ── 4. 执行计划（确认走索引）──────────────────────────────
    print('');
    print('【EXPLAIN QUERY PLAN】');
    for (final sql in [
      "SELECT id FROM word WHERE spelling='receive'",
      "SELECT base FROM word_form WHERE form='received'",
      "SELECT content FROM card WHERE word_id='w000001'",
    ]) {
      final plan = await db.rawQuery('EXPLAIN QUERY PLAN $sql');
      print('  ${plan.map((r) => r['detail']).join(' | ')}');
    }

    // ── 5. 参数化查询的安全性（防注入）────────────────────────
    print('');
    print('【参数化查询】含引号/特殊字符的输入不应报错也不应注入');
    final evil = await db.rawQuery(
        "SELECT id FROM word WHERE spelling = ?", ["receive' OR '1'='1"]);
    print('  注入尝试返回 ${evil.length} 行（应为 0）');
  } finally {
    await db.close();
  }

  print('');
  print('✅ 纯 Dart 可用 sqflite_common_ffi 打开真 word.db 并查询');
}
