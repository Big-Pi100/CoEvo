// 翻译端侧缓存的验收 —— 纯函数口径 + 真库行为
//
// 跑法：`cd scripts/query_verify && dart run bin/verify_translation_cache.dart`
//
// # 本脚本守的两类东西
//
// | 类 | 对象 | 错了会怎样 |
// |---|---|---|
// | **纯函数口径** | `normalizeTranslationSource` | 太松 ⇒ 给出**错的译文**（Apple/apple 共用）；太紧 ⇒ **同一句付两次钱** |
// | **真库行为** | 读写 / LRU / 覆盖不改 `created_at` | 只有真库能验（`INSERT OR REPLACE` 的语义、SQL 侧时间）|

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/translation_cache.dart';
import '../../../app/lib/services/user_db.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(label);
    print('  ❌ $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String label, Object? got, Object? want) {
  final ok = got == want;
  check(label, ok, ok ? '' : 'got=$got want=$want');
}

void section(String t) {
  print('');
  print('─' * 72);
  print(t);
  print('─' * 72);
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  // ══════════════════════════════════════════════════════════════════
  section('【1】规范化：只归一「排版差异」，绝不碰「内容差异」');
  // ══════════════════════════════════════════════════════════════════

  // ── 应当归一（排版差异）──
  eq('首尾空白被去掉', normalizeTranslationSource('  Hello.  '), 'Hello.');
  eq('连续空白折叠成一个', normalizeTranslationSource('Hello   world'),
      'Hello world');
  eq('换行/制表也折叠', normalizeTranslationSource('Hello\n\tworld'),
      'Hello world');
  eq('智能单引号 → ASCII', normalizeTranslationSource('don’t'), "don't");
  eq('智能双引号 → ASCII', normalizeTranslationSource('“hi”'), '"hi"');
  eq('全角空格 → 半角', normalizeTranslationSource('Hello\u3000world'),
      'Hello world');
  eq('换行变空格后**不留**首尾空白',
      normalizeTranslationSource('\nHello world\n'), 'Hello world');

  // ── 🔴 绝不能归一（内容差异）──
  check(
    '🔴 大小写**不动**（Apple 公司 ≠ apple 水果，压平会给出错的译文）',
    normalizeTranslationSource('Apple') != normalizeTranslationSource('apple'),
  );
  check(
    '🔴 句末标点**不动**（. 与 ? 语气不同）',
    normalizeTranslationSource('Fine.') != normalizeTranslationSource('Fine?'),
  );
  check(
    '🔴 撇号保留（don\'t ≠ dont）',
    normalizeTranslationSource("don't") != normalizeTranslationSource('dont'),
  );

  // ── 同族输入必须**落到同一个 key** ──
  section('【1b】「同一句话的不同排版」必须落到同一个 key');
  final a = normalizeTranslationSource('Hello   world.');
  final b = normalizeTranslationSource('  Hello world.  ');
  final c = normalizeTranslationSource('Hello\nworld.');
  check('三种排版的空格差异归一后相同', a == b && b == c, '$a | $b | $c');

  eq('空输入 ⇒ 空', normalizeTranslationSource('   '), '');
  eq('纯空白/换行 ⇒ 空', normalizeTranslationSource('\n\t '), '');

  // ══════════════════════════════════════════════════════════════════
  section('【2】真库：读写 / 覆盖 / LRU / 清空');
  // ══════════════════════════════════════════════════════════════════

  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();
  final dir = await Directory.systemTemp.createTemp('coevo_tcache');
  final path = '${dir.path}/user.db';
  final db = await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  final repo = TranslationCacheRepository(db);

  check('translation_cache 表已建出（schema 生效）',
      (await db.rawQuery(
              "SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='translation_cache'"))
          .first['n'] ==
          1);

  eq('初始为空', await repo.count(), 0);

  // ── 写入与命中 ──
  await repo.put('Hello world.', '[{"src":"Hello world.","dst":"你好，世界。"}]');
  eq('写入后 1 条', await repo.count(), 1);

  final hit = await repo.get('Hello world.');
  check('🔴 能命中', hit != null);
  check('译文原样返回', hit!.segmentsJson.contains('你好，世界。'));
  eq('🔴 命中的 key 是**规范化后**的文本', hit.srcText, 'Hello world.');

  // 🔴 排布不同但内容相同 ⇒ 必须命中同一行（否则白花一次钱）
  final hit2 = await repo.get('  Hello   world.  ');
  check('🔴 排版不同（多余空白）⇒ 仍命中同一行', hit2 != null);
  eq('🔴 且没有新增行（仍是 1 条）', await repo.count(), 1);

  // ── 未命中 ──
  check('没翻过的句子 ⇒ null', await repo.get('Never seen before.') == null);
  check('空输入 ⇒ null（不写垃圾行）', await repo.get('   ') == null);
  eq('空输入不会新增行', await repo.count(), 1);

  // ── 覆盖：同一句重翻 ⇒ 覆盖而非新增 ──
  final before = await db.query('translation_cache',
      columns: ['created_at'], where: 'src_text = ?', whereArgs: ['Hello world.']);
  await repo.put('Hello world.', '[{"src":"Hello world.","dst":"覆盖后的译文"}]');
  eq('🔴 覆盖式写入：仍只有 1 条', await repo.count(), 1);
  final after = await db.query('translation_cache',
      columns: ['created_at'], where: 'src_text = ?', whereArgs: ['Hello world.']);
  eq('🔴 覆盖**不改** `created_at`（保留「首次翻」的时刻）',
      after.first['created_at'], before.first['created_at']);
  final reread = await repo.get('Hello world.');
  check('内容已更新为新的译文', reread!.segmentsJson.contains('覆盖后的译文'));

  // ── 时间列格式（本库硬约束）──
  final row = (await db.query('translation_cache', limit: 1)).first;
  final usedAt = row['used_at'] as String;
  check('🔴 `used_at` 是 UTC ISO8601 带 Z（本库硬约束）',
      usedAt.endsWith('Z') && usedAt.contains('T'), usedAt);
  check('🔴 带毫秒（LRU 排序需要同秒内可区分）',
      RegExp(r'\.\d{3}Z$').hasMatch(usedAt), usedAt);

  // ── LRU 淘汰 ──
  section('【2b】LRU：超限时淘汰「最久没用过」的');
  for (var i = 0; i < 8; i++) {
    await repo.put('Sentence number $i.', '[{"src":"s$i","dst":"t$i"}]');
  }
  eq('先写入 8+1 条', await repo.count(), 9);

  // 把「Hello world.」touch 一下（它变成最近用过的）
  await repo.touch('Hello world.');
  // 用 SQL 把除它之外的所有行推成"很久以前"
  await db.rawUpdate(
      "UPDATE translation_cache SET used_at = '2020-01-01T00:00:00.000Z' WHERE src_text <> ?",
      ['Hello world.']);

  final deleted = await repo.prune(keep: 3);
  eq('🔴 淘汰了 9 - 3 = 6 条', deleted, 6);
  eq('剩余 3 条', await repo.count(), 3);
  check(
    '🔴 最近用过的（Hello world.）**没被淘汰**',
    (await repo.get('Hello world.')) != null,
  );
  eq('未超限时 prune 是空操作', await repo.prune(keep: 100), 0);

  // ── 清空（退出登录用）──
  section('【2c】清空');
  await repo.clear();
  eq('清空后 0 条', await repo.count(), 0);
  check('清空后查不到（不是「查得到但内容空」）',
      await repo.get('Hello world.') == null);

  await db.close();
  await dir.delete(recursive: true);

  // ══════════════════════════════════════════════════════════════════
  print('');
  print('═' * 72);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('❌ 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('   · $f');
    }
  }
  print('═' * 72);
  exit(_failures.isEmpty ? 0 : 1);
}
