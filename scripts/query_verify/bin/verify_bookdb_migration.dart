// `book.db` 迁移验收 —— **专测「从 v1 升级」**（不是「全新建库」）
//
// 跑：cd scripts/query_verify && dart run bin/verify_bookdb_migration.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（2026-10-05 加）
//
// `book.db` 在 v2（跨设备同步）新增了两样东西，**性质不同**：
//
// | 变更 | 重跑全量幂等脚本能覆盖吗 |
// |---|---|
// | 🆕 `book_progress_pending` 表 | ✅ **能**（`CREATE TABLE IF NOT EXISTS`）|
// | 🆕 `book.content_hash` **列** | 🔴 **不能**（`IF NOT EXISTS` 对已存在的表**整条跳过**）|
//
// ⇒ 后者**只能靠 `onUpgrade` 里的 `ALTER`**。而它漏了是**静默的**：
//    老库永远没有 `content_hash` ⇒ 跨设备认领进度时**永远匹配不上**
//    （用户在新设备导入同一本书，进度却回不来），而**不报任何错**。
//
// 📌 判据（本仓库反复出现）：**「新建库跑通」≠「老库能升级」** ——
//    只测 `onCreate` 会**假绿**（全新的当然有这一列，因为建表语句里写了）。
// 📄 参照既有做法：`bin/verify_userdb_migration.dart`（同族，那个测 `user.db`）。
//
// ⚠️ 如实标注：`book.db` **尚未上线**（真机上不存在 v1 库）⇒
//    这条升级路径在当前**没有真实用户**。
//    写它是因为「**为将来稳妥**」（设计文档 §5.1 原话）+ 防止将来真的改了列而没人验。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/book_db.dart';

int _pass = 0;
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

void section(String s) {
  print('');
  print('─' * 74);
  print('【$s】');
  print('─' * 74);
}

/// **v1 的 schema**（2026-10-04 时点的样子）= `book` + `book_chapter` + `book_progress`。
///
/// 🔑 **历史快照，只增不改** —— 它必须**不含** v2 才有的东西
///    （`content_hash` / `book_progress_pending` / `idx_book_hash`），
///    否则「老库升级拿到了新列」这条断言就失去意义（它本来就存在）。
const String _v1Schema = '''
CREATE TABLE IF NOT EXISTS book (
  id            TEXT PRIMARY KEY,
  title         TEXT NOT NULL,
  author        TEXT,
  language      TEXT,
  source_format TEXT NOT NULL CHECK (source_format IN ('epub', 'txt')),
  source_name   TEXT,
  chapter_count INTEGER NOT NULL DEFAULT 0,
  char_count    INTEGER NOT NULL DEFAULT 0,
  added_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_book_added ON book(added_at DESC);

CREATE TABLE IF NOT EXISTS book_chapter (
  id         TEXT PRIMARY KEY,
  book_id    TEXT NOT NULL,
  idx        INTEGER NOT NULL,
  title      TEXT,
  text       TEXT NOT NULL,
  char_count INTEGER NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE,
  UNIQUE (book_id, idx)
);

CREATE INDEX IF NOT EXISTS idx_book_chapter ON book_chapter(book_id, idx);

CREATE TABLE IF NOT EXISTS book_progress (
  book_id      TEXT PRIMARY KEY,
  chapter_idx  INTEGER NOT NULL DEFAULT 0,
  scroll_ratio REAL    NOT NULL DEFAULT 0,
  updated_at   TEXT NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id) ON DELETE CASCADE
);
''';

Future<List<String>> _columnsOf(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toList();
}

Future<List<String>> _tables(Database db) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  return rows.map((r) => r['name'] as String).toList();
}

Future<bool> _hasIndex(Database db, String idx) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name = ?", [idx]);
  return rows.isNotEmpty;
}

/// 跑一条路径：建 `fromVersion` 老库 → 写数据 → 用当前实现打开 → 断言。
Future<void> runCase({
  required DatabaseFactory factory,
  required String schemaSql,
  required int fromVersion,
  required String oldSchema,
}) async {
  final dir = await Directory.systemTemp.createTemp('coevo_book_migrate_v$fromVersion');
  final path = '${dir.path}/book.db';

  section('v$fromVersion → v$kBookDbVersion：构造老库');
  final old = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: fromVersion),
  );
  await old.execute('PRAGMA foreign_keys = ON');
  for (final stmt in oldSchema.split(';')) {
    final s = stmt.trim();
    if (s.isEmpty) continue;
    await old.execute(s);
  }
  // 老数据：一本书 + 一章 + 一条进度（升级后必须完好）
  await old.insert('book', {
    'id': 'b-old-1',
    'title': 'Pride and Prejudice',
    'source_format': 'epub',
    'chapter_count': 1,
    'char_count': 3,
    'added_at': '2026-10-04T00:00:00Z',
  });
  await old.insert('book_chapter', {
    'id': 'c-old-1',
    'book_id': 'b-old-1',
    'idx': 0,
    'text': 'abc',
    'char_count': 3,
  });
  await old.insert('book_progress', {
    'book_id': 'b-old-1',
    'chapter_idx': 0,
    'scroll_ratio': 0.5,
    'updated_at': '2026-10-04T00:00:00Z',
  });
  final oldCols = await _columnsOf(old, 'book');
  final oldTables = await _tables(old);
  final oldVer = (await old.rawQuery('PRAGMA user_version')).first.values.first;

  // 🔴 前提：老库**不该**有 v2 的东西（否则「升级后它存在」那条断言失去意义）
  check('老库 user_version = $fromVersion', oldVer == fromVersion, '$oldVer');
  check('🔴 前提成立：老库的 book **不含** content_hash（v2 才加）',
      !oldCols.contains('content_hash'), oldCols.join(','));
  check('🔴 前提成立：老库**不含** book_progress_pending（v2 才加）',
      !oldTables.contains('book_progress_pending'));
  check('老库已有 1 本书 + 1 章 + 1 条进度',
      (await old.rawQuery('SELECT count(*) AS n FROM book')).first['n'] == 1);
  await old.close();

  section('用「当前实现」打开 → 触发升级');
  final Database db;
  try {
    db = await openBookDb(factory: factory, path: path, schemaSql: schemaSql);
  } catch (e) {
    // 🔴 **升级过程自己抛异常**也要变成「干净的红」，不能让脚本崩栈。
    //
    // 实测（2026-10-05 证伪）：若 `onUpgrade` 的迁移分支缺失，`content_hash` 列就不会被加，
    // 而全量脚本里的 `CREATE INDEX ... ON book(content_hash)` 会报
    // `no such column` ⇒ **打开这一步就抛异常**。
    // ⚠️ 崩栈比干净红糟得多：**后面的断言一条都不跑、汇总也不打印**，
    //    容易被误读成「环境问题 / 脚本坏了」，而不是「迁移漏了加列」。
    // 📌 判据：**门禁的正确形态是「红 + 指出原因」** —— 所以这里捕获并如实报出。
    check('🔴 升级后能正常打开（`onUpgrade` 不抛异常）', false, '$e');
    return;
  }
  final cols = await _columnsOf(db, 'book');
  final tables = await _tables(db);

  section('🔴 核心断言');
  final hasCol = cols.contains('content_hash');
  final hasPending = tables.contains('book_progress_pending');
  check('🔴 `book` 有 `content_hash` 列 —— 加列**只能**靠 ALTER（全量脚本覆盖不了）',
      hasCol, cols.join(','));
  check('🔴 `book_progress_pending` 表已创建（新增表靠重跑全量脚本）', hasPending);
  check('🔴 `idx_book_hash` 索引已创建（新增索引同样靠重跑脚本）',
      await _hasIndex(db, 'idx_book_hash'));
  check('user_version 已升到 $kBookDbVersion',
      (await db.rawQuery('PRAGMA user_version')).first.values.first ==
          kBookDbVersion);

  section('旧数据完好（升级不能丢数据）');
  // ⚠️ 这条**不依赖新列** ⇒ 独立跑（升版本号/迁移分支缺失时它仍应成立）
  check('旧书仍是 1 本',
      (await db.rawQuery('SELECT count(*) AS n FROM book')).first['n'] == 1);
  check('旧章节仍是 1 章',
      (await db.rawQuery('SELECT count(*) AS n FROM book_chapter')).first['n'] ==
          1);

  // ⚠️ 下面两条**依赖前提**（列/表存在）—— 前提不成立时**跳过**，否则查询会抛
  //    `no such column/table` ⇒ 整个脚本崩栈（同上面 `catch` 那条注释的理由）。
  //    ✅ 跳过不会削弱门禁：上面那两条 check 已经红了，门禁已经是红的。
  if (hasCol) {
    check('🔴 旧书的 `content_hash` 是 **NULL**（不是被填了假值）',
        (await db.query('book', columns: ['content_hash']))
                .first['content_hash'] ==
            null,
        '—— NULL 表示「这本书的原始字节不可得」⇒ **不参与同步**，'
            '而不是拿一个假的指纹去匹配（那会把用户带到错的书）');
  }

  if (hasPending) {
    section('`book_progress_pending` 可用性');
    // 🔑 它的 PK 是 **content_hash**（不是 book_id）—— 这正是「本地还没导入这本书」
    //    也能先接住远端进度的关键（见 schema 里该表的注释）。
    await db.insert('book_progress_pending', {
      'content_hash': 'deadbeef',
      'chapter_idx': 3,
      'scroll_ratio': 0.42,
      'updated_at': '2026-10-05T00:00:00Z',
    });
    final got = (await db.query('book_progress_pending')).first;
    check('可写入、可读回（按 content_hash）', got['content_hash'] == 'deadbeef');
    check('chapter_idx / scroll_ratio 保真',
        got['chapter_idx'] == 3 && got['scroll_ratio'] == 0.42);
    var dupRejected = false;
    try {
      await db.insert('book_progress_pending', {
        'content_hash': 'deadbeef', // 同一指纹再来一条 ⇒ 必须被 PK 挡住
        'chapter_idx': 9,
        'scroll_ratio': 0.9,
        'updated_at': '2026-10-05T00:01:00Z',
      });
    } catch (_) {
      dupRejected = true;
    }
    check('🔴 PRIMARY KEY(content_hash) 生效（同一本书不会有两行进度）', dupRejected);
  }

  section('幂等：再次打开不应报错（App 每次启动都会走）');
  await db.close();
  final db2 = await openBookDb(factory: factory, path: path, schemaSql: schemaSql);
  check('二次打开成功', (await _tables(db2)).contains('book'));
  check('二次打开后 content_hash 仍在',
      (await _columnsOf(db2, 'book')).contains('content_hash'));
  await db2.close();
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final schemaSql =
      File('../../app/assets/sql/book_db_schema.sql').readAsStringSync();

  print('');
  print('#' * 74);
  print('# book.db 迁移验收 —— v1 → v$kBookDbVersion（专测「老库升级」）');
  print('#' * 74);

  await runCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 1,
    oldSchema: _v1Schema,
  );

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项（v1 → v$kBookDbVersion）');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：`book_db.dart` 的 `onUpgrade` 少了 v2 分支，');
    print('    或 `kBookDbVersion` 没升到 2（不升版本号 ⇒ `onUpgrade` 不触发）。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
