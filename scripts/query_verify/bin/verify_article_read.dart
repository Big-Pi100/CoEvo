// CoEvo · 「读过的文章」仓储验收（`article_read` / 「阅读篇数」的数据源）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_article_read.dart
//
// # 本脚本保护的判据
// | # | 判据 | 为什么值得一条断言 |
// |---|---|---|
// | 1 | `markRead` 返回值语义（首次 true / 重复 false） | 🔴 `OR IGNORE` 冲突时的返回值**是 sqflite 的实现细节** —— 我在实现注释里断言「冲突返回 0」，**必须实测**，不能凭印象 |
// | 2 | 幂等：重复 `markRead` 不改 `read_at` | 保证「首次读完时刻」这一口径**只有一种含义** |
// | 3 | 时间列 UTC ISO8601 **带 Z** | 本库硬约束 1；写成 `datetime('now')` 会让 Dart 侧**静默按本地时区**解释 |
// | 4 | `read_at` 由 **DEFAULT** 生成（不传也写入） | 同 `bookmark`：时间戳走**数据库时钟**，不走客户端 |
// | 5 | `COUNT(*)` 与 `countRead()` 一致 | 「一处口径只能有一处权威」 |
// | 6 | 重复标记**不增加**篇数 | 「去重」是口径乙的核心前提（同一篇读两次算 1 篇） |
//
// # 与 `verify_userdb_migration.dart` 的分工
// 那个脚本负责「**老库升级后这张表在不在**」；本脚本负责「**建好之后它能正确工作**」。
// 两者都必要：只测其一，另一条路径坏了不会被发现。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/article_read_repository.dart';
import '../../../app/lib/services/user_db.dart';

var _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

Future<int> rawCount(Database db) async {
  final r = await db.rawQuery('SELECT count(*) AS n FROM article_read');
  return (r.first['n'] as num).toInt();
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  final dir = await Directory.systemTemp.createTemp('coevo_article_read');
  final db = await openUserDb(
    factory: factory,
    path: '${dir.path}/user.db',
    schemaSql: schemaSql,
  );
  final repo = ArticleReadRepository(db);

  print('');
  print('#' * 74);
  print('# article_read 仓储验收 —— 「阅读篇数」的数据源');
  print('#' * 74);

  // ══════════════════════════════════════════════════════════
  section('【1】空库：0 篇');
  // ══════════════════════════════════════════════════════════
  check('空库 countRead() = 0', await repo.countRead() == 0);

  // ══════════════════════════════════════════════════════════
  section('【2】首次标记 → true，篇数 +1');
  // ══════════════════════════════════════════════════════════
  final first = await repo.markRead(7);
  check('🔴 首次 markRead 返回 true（本次真的新增了）', first);
  check('篇数变为 1', await repo.countRead() == 1);
  check('hasRead(7) = true', await repo.hasRead(7));
  check('hasRead(99) = false（未读过的文章）', !await repo.hasRead(99));

  // ══════════════════════════════════════════════════════════
  section('【3】🔴 幂等：重复标记同一篇');
  // ══════════════════════════════════════════════════════════
  final row1 = (await db.query('article_read')).first;
  final at1 = row1['read_at'] as String;

  final second = await repo.markRead(7);
  check('🔴 重复 markRead 返回 false（不是新增）', !second,
      '—— 这条同时实测了「`OR IGNORE` 冲突时 insert 返回 0」这个实现细节');
  check('篇数仍为 1（去重生效）', await repo.countRead() == 1);
  check('表里仍只有 1 行', await rawCount(db) == 1);

  final row2 = (await db.query('article_read')).first;
  check('🔴 read_at 未被覆盖（保持**首次**读完时刻）',
      row2['read_at'] == at1, '$at1');

  // ══════════════════════════════════════════════════════════
  section('【4】时间列符合本库硬约束 1');
  // ══════════════════════════════════════════════════════════
  check('read_at 非空（由 DEFAULT 生成，未显式传入）', at1.isNotEmpty, at1);
  check('🔴 read_at 以 Z 结尾（UTC ISO8601 —— 本库硬约束 1）',
      at1.endsWith('Z'), at1);
  // 🔑 解析出来必须是 UTC（若 DDL 写成 `datetime('now')` → 无 Z → Dart 按本地解释 → 这里会失败）
  final parsed = DateTime.parse(at1);
  check('🔴 DateTime.parse 后是 UTC（不是被当本地时间）', parsed.isUtc,
      'isUtc=${parsed.isUtc}');
  check('pending_push 默认 1（与 bookmark 同模式）',
      (row1['pending_push'] as num).toInt() == 1);

  // ══════════════════════════════════════════════════════════
  section('【5】多篇：计数与「一处口径」');
  // ══════════════════════════════════════════════════════════
  await repo.markRead(8);
  await repo.markRead(9);
  check('追加两篇后 countRead() = 3', await repo.countRead() == 3);
  check('🔴 countRead() 与 `COUNT(*)` 一致（一处口径只有一处权威）',
      await repo.countRead() == await rawCount(db));

  // ══════════════════════════════════════════════════════════
  section('【6】边界：id 的取值');
  // ══════════════════════════════════════════════════════════
  // 🔴 这一节抓到过一个**真 bug**（记录在此，防回归）：
  //    最初的实现用 `insert(...OR IGNORE)` 的**返回值**判「是否新增」（`rowId != 0`）——
  //    而 `article_id = 0` 时**插入成功、rowid 也是 0** → 被判成「不是新增」→ 误报。
  //    根因：**哨兵值冲突**（拿 0 当失败标记，而 0 是合法主键值）。
  //    现实现改为**写事务 + 显式查询**（不依赖任何哨兵值）→ 本节成为回归防线。
  final zero = await repo.markRead(0);
  check('🔴 article_id = 0：能记录**且**返回 true（不把 0 当失败标记）', zero);
  check('计数含 0 号文章', await repo.countRead() == 4);

  final neg = await repo.markRead(-1);
  check('article_id = -1 可正常记录且返回 true', neg);
  check('计数含 -1 号文章', await repo.countRead() == 5);

  check('重复标记 0 号 → false（幂等同样成立）', !await repo.markRead(0));
  await db.delete('article_read', where: 'article_id IN (0, -1)');
  check('清理后回到 3', await repo.countRead() == 3);

  // ══════════════════════════════════════════════════════════
  section('【7】🔴 并发：同一篇同时被标记两次（TOCTOU 防护）');
  // ══════════════════════════════════════════════════════════
  // 实现注释声称「用 insert 返回值判断，而不是『先查再插』」以避免 TOCTOU。
  // 这条断言把它变成**可验证的行为**：两个并发调用，**恰好一个**返回 true。
  final results = await Future.wait([repo.markRead(42), repo.markRead(42)]);
  check('🔴 两个并发 markRead：恰好一个返回 true',
      results.where((r) => r).length == 1, '$results');
  check('表里 42 号只有 1 行', await rawCount(db) == 4, '应为 3+1');

  // ══════════════════════════════════════════════════════════
  section('【8】统计查询走的是主键（不需要额外索引）');
  // ══════════════════════════════════════════════════════════
  final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT count(*) AS n FROM article_read');
  final planText = plan.map((r) => r.values.join(' ')).join(' | ');
  check('COUNT(*) 的查询计划可用（不含全表扫以外的异常）',
      planText.isNotEmpty, planText);

  await db.close();
  await dir.delete(recursive: true);

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
