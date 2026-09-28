// CoEvo · `user.db` **迁移验收**（★ 端侧最容易被漏掉的一类保护）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_userdb_migration.dart
//
// # 🔴🔴 为什么必须单独有这一个脚本
//
// 其他 `user.db` 验收（`verify_bookmark` / `verify_review_list` / …）
// 都跑在**新建的临时库**上 → 走的是 `onCreate` → **天然覆盖不到升级路径**。
//
// 而真机上的情况**完全不同**：
//   · 白哥已验过收藏 → 设备上早有 `user.db`（`user_version = 1`）
//   · 后来又验过生词本 → 可能已升到 **2**
//   → 加了新表之后：`onCreate` **不重跑**，**只有 `onUpgrade`** 会触发。
//
// → 若 `onUpgrade` 坏了，**新表根本不会创建**，而**所有其他验收照样全绿**
//   → 一个「在错条件下验证」的完美盲区。
//
// 🔑 判据：**「验收环境的初始状态」必须与「生产的初始状态」一致**。
//    这里的差异不是平台，而是**初始状态**（新库 vs 老库）—— 更隐蔽，
//    因为跑在同一台机器、同一个命令上，只差前置数据。
//
// # 本脚本的两个升级路径（2026-09-29 起）
// | 起始 | 快照 | 场景 |
// |---|---|---|
// | **v1** | `_v1Schema` | 最早装机的用户（只有 3 表） |
// | **v2** | `_v2Schema` | 验过生词本的用户（5 表） |
// → 两条都要能升到当前版本，且**旧数据完好**。
//
// # 🔑 自动覆盖「将来新增的表」
// §【4】从 `user_db_schema.sql` **直接提取全部建表语句**，断言升级后**全都在**
// → 以后再加表**不用改本脚本**也能被覆盖（防「加了表忘了加断言」）。
//
// # 🔑 本脚本自身的证伪方式
// 把 `user_db.dart` 的 `kUserDbVersion` 改回 **2** → 本脚本**必须变红**
// （version 不变 → 不触发 `onUpgrade` → `achievement_unlock` 不会建 → §【3】失败）。
// 已实测过一次（见方案 §七 实施记录）。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
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

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
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

/// **v2 的 schema**（2026-09-28 时点的样子）= v1 + `user_word` + `lookup_event`。
///
/// 🔑 同样是**历史快照**，只增不改（理由见 `_v1Schema`）。
const String _v2Schema = '''
$_v1Schema
CREATE TABLE IF NOT EXISTS user_word (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id           TEXT    NOT NULL,
  spelling          TEXT    NOT NULL COLLATE NOCASE,
  source_article_id INTEGER,
  source_sentence   TEXT,
  added_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  deleted           INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  pending_push      INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1)),
  UNIQUE (word_id)
);
CREATE TABLE IF NOT EXISTS lookup_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id      TEXT,
  spelling     TEXT    NOT NULL COLLATE NOCASE,
  article_id   INTEGER,
  sentence     TEXT,
  position     INTEGER,
  looked_up_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_le_word ON lookup_event (word_id, looked_up_at);
''';

/// 从 schema 文件里提取**全部建表语句的表名**。
///
/// 🔑 这样本脚本**不需要**维护一份「应该有哪张表」的清单 ——
///    将来新增表会自动纳入断言范围（防「加了表忘了加断言」）。
List<String> tableNamesInSchema(String sql) {
  final re = RegExp(r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([a-z_]+)',
      caseSensitive: false);
  // ⚠️ 先剥掉注释 —— 否则「注释里举例的建表语句」也会被数进去
  final noComment = splitSqlStatements(sql).join('\n');
  return re
      .allMatches(noComment)
      .map((m) => m.group(1)!)
      .toSet()
      .toList()
    ..sort();
}

Future<List<String>> tableNames(Database db) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  return rows.map((r) => r['name'] as String).toList();
}

int firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return -1;
  final v = rows.first.values.first;
  return v is num ? v.toInt() : -1;
}

/// 跑一条升级路径：建 `fromVersion` 老库 → 写数据 → 用当前实现打开 → 断言。
Future<void> runUpgradeCase({
  required DatabaseFactory factory,
  required String schemaSql,
  required int fromVersion,
  required String oldSchema,
  required List<String> expectedTables,
}) async {
  print('');
  print('═' * 74);
  print('▶ 升级路径：v$fromVersion → v$kUserDbVersion');
  print('═' * 74);

  final dir = await Directory.systemTemp.createTemp('coevo_migrate_v$fromVersion');
  final path = '${dir.path}/user.db';

  section('【1】构造真实的「v$fromVersion 老库」（模拟用户设备上已有的 user.db）');
  final old = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: fromVersion,
      onCreate: (db, _) async {
        for (final s in splitSqlStatements(oldSchema)) {
          await db.execute(s);
        }
      },
    ),
  );
  // 真实数据（旧数据必须在升级后**完好无损**）
  await old.insert('bookmark', {'content_id': 42});
  await old.insert('bookmark', {'content_id': 99});
  await old.insert('card_review_state', {
    'word_id': 'w000001',
    'spelling': 'abandon',
    'next_review_at': '2026-09-28T00:00:00Z',
  });
  if (fromVersion >= 2) {
    await old.insert('user_word', {'word_id': 'w000002', 'spelling': 'benefit'});
  }

  final oldVer = firstInt(await old.rawQuery('PRAGMA user_version'));
  final oldTables = await tableNames(old);
  check('老库已建立且 user_version = $fromVersion', oldVer == fromVersion, '$oldVer');
  check('🔴 前提成立：老库**不含** achievement_unlock',
      !oldTables.contains('achievement_unlock'));
  check('老库已有 bookmark 数据（2 条）',
      firstInt(await old.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  await old.close();

  section('【2】用「当前实现」（version=$kUserDbVersion + 全量 schema）重新打开 → 触发升级');
  final db =
      await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  final tables = await tableNames(db);
  final ver = firstInt(await db.rawQuery('PRAGMA user_version'));

  section('【3】升级结果 —— 🔴 核心断言');
  check('被断言的前提：kUserDbVersion > $fromVersion（否则不触发 onUpgrade）',
      kUserDbVersion > fromVersion, '当前 $kUserDbVersion');
  check('🔴 achievement_unlock 已创建（老库升级拿到了新表）',
      tables.contains('achievement_unlock'));
  check('user_version 已升到 $kUserDbVersion', ver == kUserDbVersion, '$ver');

  section('【4】🔑 全量表清单（从 schema 自动提取 → 将来加表自动覆盖）');
  final missing = expectedTables.where((t) => !tables.contains(t)).toList();
  check('schema 里声明的 ${expectedTables.length} 张表**升级后全都在**',
      missing.isEmpty, missing.isEmpty ? '' : '缺: ${missing.join(", ")}');

  section('【5】旧数据完好（升级不能丢数据）');
  check('bookmark 旧数据仍是 2 条',
      firstInt(await db.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check(
      'bookmark 内容未被改动',
      (await db.query('bookmark', columns: ['content_id'], orderBy: 'content_id'))
              .map((r) => r['content_id'])
              .toList()
              .toString() ==
          '[42, 99]');
  check('card_review_state 旧数据仍是 1 条',
      firstInt(await db
              .rawQuery('SELECT count(*) AS n FROM card_review_state')) ==
          1);
  check('card_review_state 的 spelling 未丢',
      (await db.query('card_review_state', columns: ['spelling']))
              .first['spelling'] ==
          'abandon');
  if (fromVersion >= 2) {
    check('user_word 旧数据仍是 1 条（v2 库特有）',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM user_word')) == 1);
  }

  section('【6】新表**可正常使用**（不只是「存在」）');
  // 🔴 前置守卫：若 §3 判定「新表没建出来」，继续 INSERT 会**直接抛异常** →
  //    脚本崩溃、后面的断言一条都不跑、汇总也不打印。
  //    ⚠️ 崩溃比「干净报红」糟：容易被误读成「环境问题」，
  //       而这里要表达的恰恰是「**迁移逻辑错了**」。
  if (!tables.contains('achievement_unlock')) {
    print('  ⏭  跳过：achievement_unlock 未创建 → 后续插入必然抛异常');
    print('      （**这是预期行为** —— §3 的报红已定位到根因，不必再往下跑）');
  } else {
    await db.insert('achievement_unlock', {'key': 'first_review'});
    check('可写入、可读回',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM achievement_unlock')) ==
            1);
    // 🔑 DEFAULT 生效（插入时不提供 unlocked_at）
    final row = (await db.query('achievement_unlock')).first;
    check('🔴 unlocked_at 有 DEFAULT（未显式提供也写入）',
        (row['unlocked_at'] as String?)?.isNotEmpty == true,
        '${row['unlocked_at']}');
    check('🔴 unlocked_at 是 UTC ISO8601 带 Z（本库硬约束 1）',
        (row['unlocked_at'] as String).endsWith('Z'),
        '${row['unlocked_at']}');

    section('【7】约束真的生效');
    var dupRejected = false;
    try {
      await db.insert('achievement_unlock', {'key': 'first_review'});
    } catch (_) {
      dupRejected = true;
    }
    check('🔴 PRIMARY KEY(key) 生效（同一成就不会重复解锁）', dupRejected);
  }

  section('【8】幂等：再次打开不应报错、不应重复建表（App 每次启动都会走）');
  await db.close();
  final again =
      await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  check('二次打开成功（schema 全为 IF NOT EXISTS → 重跑安全）', true);
  final againTables = await tableNames(again);
  check('二次打开后全部表仍在',
      expectedTables.every(againTables.contains));
  check('二次打开后旧数据仍在（未误删）',
      firstInt(await again.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check('二次打开后 user_version 仍为 $kUserDbVersion',
      firstInt(await again.rawQuery('PRAGMA user_version')) == kUserDbVersion);
  await again.close();

  await dir.delete(recursive: true);
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  // 当前 schema —— 与 App 侧 `rootBundle.loadString(kUserDbSchemaAsset)` 读的是**同一份文件**
  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();
  final expectedTables = tableNamesInSchema(schemaSql);

  print('');
  print('#' * 74);
  print('# user.db 迁移验收 —— 起止版本 v1/v2 → v$kUserDbVersion');
  print('# schema 声明的表：${expectedTables.join(", ")}');
  print('#' * 74);

  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 1,
    oldSchema: _v1Schema,
    expectedTables: expectedTables,
  );
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 2,
    oldSchema: _v2Schema,
    expectedTables: expectedTables,
  );

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项（v1→v$kUserDbVersion 与 v2→v$kUserDbVersion 两条路径）');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「achievement_unlock 已创建」失败 → 检查 `user_db.dart` 的');
    print('    `kUserDbVersion` 是否 > 起始版本、`onUpgrade` 是否真的重跑了 schema。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
