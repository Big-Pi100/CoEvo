// CoEvo · `user.db` **迁移验收**（★ Step 3.4c 最关键的一条）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_userdb_migration.dart
//
// # 🔴🔴 为什么必须单独有这一个脚本
//
// 现有**全部** `user.db` 验收（`verify_bookmark` / `verify_review_list` / …）
// 都跑在**新建的临时库**上 → 走的是 `onCreate` → **天然覆盖不到升级路径**。
//
// 而真机上的情况**完全不同**：白哥已验过收藏功能 → `user.db` **早已存在且
// `user_version = 1`** → 加了新表之后：
//   · `onCreate` **不重跑**（不是新库）
//   · 只有 `onUpgrade` 会触发
//
// → 若 `onUpgrade` 是坏的（或仍是「无条件抛错」），**新表根本不会创建**，
//   而**所有现有验收照样全绿** → 一个「在错条件下验证」的完美盲区。
//
// 🔑 判据：**「验收环境的初始状态」必须与「生产的初始状态」一致**。
//    这里的差异不是平台，而是**初始状态**（新库 vs 老库）—— 更隐蔽，
//    因为跑在同一台机器、同一个命令上，只差前置数据。
//
// 本脚本因此**显式构造一个 v1 老库**：
//   ① 用 **v1 的 DDL**（不含 `user_word` / `lookup_event`）建库
//   ② 写入真实数据（几条 `bookmark`）
//   ③ 用 **当前 `openUserDb`（version = 2，含全量 schema）** 重新打开
//   ④ 断言：新表存在 + **旧数据完好** + `user_version == 2`
//
// 🔑 **证伪方式**（本脚本自身的有效性验证）：
//    把 `user_db.dart` 里的 `kUserDbVersion` 改回 `1` → 本脚本**必须变红**。
//    （version 不变 → 不触发 `onUpgrade` → 新表不会建 → 步骤 ④ 失败）

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// **v1 的 schema**（2026-09-27 时点的样子）—— 有意**不含** `user_word` / `lookup_event`。
///
/// 🔑 为什么在这里**复制一份**而不是引用现文件：本脚本要的是**历史快照**。
///    若引用当前 `user_db_schema.sql`，那它永远等于「最新 schema」→
///    「老库」就不再是老的 → 这个脚本会**永远绿**（正是它要防的那种假保护）。
///    ⚠️ 所以这份 DDL **只增不改**：它描述「v1 长什么样」，是契约，不是实现。
const String _v1Schema = '''
CREATE TABLE IF NOT EXISTS card_review_state (
  word_id        TEXT    PRIMARY KEY,
  spelling       TEXT    NOT NULL COLLATE NOCASE,
  state          INTEGER NOT NULL DEFAULT 0 CHECK (state BETWEEN 0 AND 3),
  step           INTEGER,
  stability      REAL,
  difficulty     REAL,
  reps           INTEGER NOT NULL DEFAULT 0,
  lapses         INTEGER NOT NULL DEFAULT 0,
  last_review_at TEXT,
  next_review_at TEXT    NOT NULL,
  pending_push   INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1)),
  updated_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS review_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id     TEXT    NOT NULL,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
  duration_ms INTEGER,
  reviewed_at TEXT    NOT NULL,
  utc_day     TEXT    NOT NULL,
  device_id   TEXT    NOT NULL DEFAULT '',
  synced      INTEGER NOT NULL DEFAULT 0 CHECK (synced IN (0, 1)),
  UNIQUE (word_id, reviewed_at, device_id)
);
CREATE TABLE IF NOT EXISTS bookmark (
  content_id    INTEGER PRIMARY KEY,
  bookmarked_at TEXT    NOT NULL
                DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push  INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_bm_time ON bookmark (bookmarked_at DESC);
CREATE INDEX IF NOT EXISTS idx_bm_pending ON bookmark (pending_push)
  WHERE pending_push = 1;
''';

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final dir = await Directory.systemTemp.createTemp('coevo_migrate_');
  final path = '${dir.path}/user.db';
  // 当前 schema —— 与 App 侧 `rootBundle.loadString(kUserDbSchemaAsset)` 读的是**同一份文件**
  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  print('\n【1】构造一个真实的「v1 老库」（模拟白哥手机上已有的 user.db）');

  final old = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        for (final s in splitSqlStatements(_v1Schema)) {
          await db.execute(s);
        }
      },
    ),
  );
  // 写入真实数据（旧数据必须在升级后**完好无损**）
  await old.insert('bookmark', {'content_id': 42});
  await old.insert('bookmark', {'content_id': 99});
  await old.insert('card_review_state', {
    'word_id': 'w000001',
    'spelling': 'abandon',
    'next_review_at': '2026-09-28T00:00:00Z',
  });

  final oldVer = firstInt(await old.rawQuery('PRAGMA user_version'));
  final oldTables = await tableNames(old);
  check('老库已建立且 user_version = 1', oldVer == 1, '$oldVer');
  check('老库**不含** user_word（前提成立）', !oldTables.contains('user_word'));
  check('老库**不含** lookup_event（前提成立）', !oldTables.contains('lookup_event'));
  check('老库已有 bookmark 数据（2 条）',
      firstInt(await old.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  await old.close();

  print('\n【2】用「当前实现」（version=${kUserDbVersion} + 全量 schema）重新打开 → 触发升级');

  final db = await openUserDb(
    factory: factory,
    path: path,
    schemaSql: schemaSql,
  );

  final tables = await tableNames(db);
  final ver = firstInt(await db.rawQuery('PRAGMA user_version'));

  print('\n【3】升级结果 —— 🔴 本脚本的核心断言');

  check('被断言的前提：kUserDbVersion > 1（否则不会触发 onUpgrade）',
      kUserDbVersion > 1, '当前 $kUserDbVersion');
  check('🔴 user_word 已创建（老库升级拿到了新表）', tables.contains('user_word'));
  check('🔴 lookup_event 已创建（老库升级拿到了新表）',
      tables.contains('lookup_event'));
  check('user_version 已升到 $kUserDbVersion', ver == kUserDbVersion, '$ver');

  print('\n【4】旧数据完好（升级不能丢数据）');
  check(
      'bookmark 旧数据仍是 2 条',
      firstInt(await db.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check('bookmark 内容未被改动',
      (await db.query('bookmark', columns: ['content_id'], orderBy: 'content_id'))
              .map((r) => r['content_id'])
              .toList()
              .toString() ==
          '[42, 99]');
  check(
      'card_review_state 旧数据仍是 1 条',
      firstInt(await db.rawQuery(
              'SELECT count(*) AS n FROM card_review_state')) ==
          1);
  check(
      'card_review_state 的 spelling 未丢',
      (await db.query('card_review_state', columns: ['spelling'])).first['spelling'] ==
          'abandon');

  print('\n【5】新表可正常使用（不只是「存在」）');
  //
  // 🔴 **前置守卫**：若 §3 已判定「新表没建出来」，这里继续 `INSERT` 会**直接抛异常**
  //    → 脚本崩溃退出，**后面的断言一条都不跑**、汇总也不会打印。
  //    ⚠️ 崩溃比「干净报红」糟：崩溃容易被误读成「环境问题」，
  //       而这里要表达的恰恰是「**实现的迁移逻辑错了**」。
  //    → 所以显式跳过后面的节，并保留 §3 的报红作为结论。
  final brandNewTablesOk =
      tables.contains('user_word') && tables.contains('lookup_event');
  if (!brandNewTablesOk) {
    print('  ⏭  跳过：user_word / lookup_event 未创建 → 后续插入必然抛异常');
    print('      （**这是预期行为** —— 说明 §3 的报红已经定位到根因，不必再往下跑）');
  } else {
    await db.insert('user_word', {
      'word_id': 'w000001',
      'spelling': 'abandon',
      'source_sentence': 'He decided to abandon the plan.',
    });
    await db.insert('lookup_event', {
      'word_id': 'w000001',
      'spelling': 'abandon',
      'sentence': 'He decided to abandon the plan.',
    });
    await db.insert('lookup_event', {
      'word_id': null, // 未命中的词（白哥定：未命中也要记）
      'spelling': 'nonexistentword',
    });
    check('user_word 可写入并可读回',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM user_word')) == 1);
    check('lookup_event 可写入并可读回（含未命中那条）',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM lookup_event')) ==
            2);
    check('lookup_event 允许 word_id 为 NULL（未命中留痕）',
        firstInt(await db.rawQuery(
                'SELECT count(*) AS n FROM lookup_event WHERE word_id IS NULL')) ==
            1);

    print('\n【6】约束真的生效（不只是「表建出来了」）');
    // user_word 按 word_id 唯一
    var dupRejected = false;
    try {
      await db.insert('user_word', {'word_id': 'w000001', 'spelling': 'abandon'});
    } catch (_) {
      dupRejected = true;
    }
    check('user_word 的 UNIQUE(word_id) 生效（重复词被拒）', dupRejected);

    // deleted / pending_push 的 CHECK
    var checkRejected = false;
    try {
      await db.update('user_word', {'deleted': 7},
          where: 'word_id = ?', whereArgs: ['w000001']);
    } catch (_) {
      checkRejected = true;
    }
    check('user_word 的 CHECK (deleted IN (0,1)) 生效', checkRejected);
  }

  print('\n【7】幂等：再次打开不应报错、不应重复建表（App 每次启动都会走）');
  await db.close();
  final again =
      await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  check('二次打开成功（schema 全为 IF NOT EXISTS → 重跑安全）', true);
  check('二次打开后旧数据仍在（未误删）',
      firstInt(await again.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check('二次打开后 user_version 仍为 $kUserDbVersion',
      firstInt(await again.rawQuery('PRAGMA user_version')) == kUserDbVersion);
  await again.close();

  await dir.delete(recursive: true);

  print('\n${'═' * 62}');
  if (_failures.isEmpty) {
    print('通过 $_pass 项，失败 0 项');
    print('\n✅ 老库能升级出新表，且旧数据完好、新表约束生效');
  } else {
    print('通过 $_pass 项，**失败 ${_failures.length} 项**');
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    print('\n🔑 若「user_word 已创建」失败 → 检查 user_db.dart 的 '
        'kUserDbVersion 是否 > 1、onUpgrade 是否真的执行了 schema');
    exitCode = 1;
  }
}

/// `PRAGMA user_version` / `count(*)` 这类单值查询的取值（缺行返回 -1）。
int firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return -1;
  final v = rows.first.values.first;
  return v is num ? v.toInt() : -1;
}

Future<List<String>> tableNames(Database db) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  return rows.map((r) => r['name'] as String).toList();
}
