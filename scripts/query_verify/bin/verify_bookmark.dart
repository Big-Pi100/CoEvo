// CoEvo · 收藏（`bookmark`）验收 + `user.db` 连接层验收
//
// 跑法：cd scripts/query_verify && dart pub get --offline
//       dart run bin/verify_bookmark.dart
//
// 与 `verify_review_list.dart` 同目录的理由：两者都是**端侧数据层**验收，
// 共用 `sqflite_common_ffi` 依赖与已缓存的服务层源码导入路径。
// （新开一个 `scripts/bookmark_verify/` 会让脚本目录碎片化，且要再 `pub get` 一遍。）
//
// 验证目标：
//   · **SQL 脚本拆分器**（纯逻辑，六类边界 + 一处**有意的能力边界**）
//   · `user_db.dart` 连接层：真库可创建、schema 可执行、表与索引齐备
//   · `BookmarkRepository`：增 / 删 / 切换 / 幂等 / 时间戳不被重复点击刷新
//   · 🔴 **取消后可再收藏**（设计稿 §四 ④ 的「硬删」语义）
//   · 时间列格式（UTC ISO8601 带 `Z`）+ 解析器**拒绝**无 `Z` 的串
//   · 待同步字段（`pending_push`）与 `list()` 的倒序

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/bookmark_repository.dart';
import '../../../app/lib/services/user_db.dart';
import '_repo_paths.dart';

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

/// 值比较 —— 对 `List` / `Set` 做**逐元素**比较。
///
/// ⚠️ **不能直接 `==`**：Dart 的 `List` / `Set` 没有值等价语义（`==` 是引用比较），
/// 于是「实得 `[1,2]` · 期望 `[1,2]`」也会被判失败 ——
/// 这种失败**看起来像实现错、其实是断言错**，最容易误导
/// （本脚本首跑 8 项红**全是这个原因**。判据：实得与期望的**文本完全相同**）。
bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    return a.length == b.length && a.every(b.contains);
  }
  return a == b;
}

void eq(String label, Object? actual, Object? expected) =>
    check(label, deepEquals(actual, expected), '实得 $actual · 期望 $expected');

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

// ════════════════════════════════════════════════════════════════
// 【1】SQL 脚本拆分器（纯逻辑）
// ════════════════════════════════════════════════════════════════
void groupSplitter() {
  section('【1】SQL 脚本拆分器（纯逻辑 · 不碰数据库）');

  // 行注释整行丢弃
  eq('行注释整行丢弃',
      splitSqlStatements('-- 说明\nSELECT 1;'),
      ['SELECT 1']);

  // 行内注释（语句中间）—— ⚠️ 旧的内联实现（`split(';')` + 过滤 `--` 开头行）
  //    对这种情况会把 `--` 之后的**整行**都留下，包括注释文本
  eq('行内注释只去掉注释部分',
      splitSqlStatements('SELECT 1 -- 这里说明\n;'),
      ['SELECT 1']);

  // 块注释（含跨行）
  eq('跨行块注释整段丢弃',
      splitSqlStatements('/* 第一行\n   第二行 */\nSELECT 2;'),
      ['SELECT 2']);

  // 多语句
  eq('多条语句按分号切开',
      splitSqlStatements('CREATE TABLE a (x INT);\nCREATE TABLE b (y INT);'),
      ['CREATE TABLE a (x INT)', 'CREATE TABLE b (y INT)']);

  // 连续分号 → 空语句丢弃（否则 SQLite 会报 syntax error）
  eq('空语句丢弃（连续分号）',
      splitSqlStatements('SELECT 1;;\n;\nSELECT 2;'),
      ['SELECT 1', 'SELECT 2']);

  // 末尾无分号（脚本最后一条常省略）
  eq('末尾无分号也保留',
      splitSqlStatements('SELECT 1;\nSELECT 2'),
      ['SELECT 1', 'SELECT 2']);

  // 纯注释 / 纯空白 → 无语句
  eq('纯注释不产出语句',
      splitSqlStatements('-- 只有注释\n/* 块注释 */\n'),
      <String>[]);

  // 换行与空白保留在语句内部（多行 CREATE TABLE 必须完整）
  final multi = splitSqlStatements('CREATE TABLE t (\n  a INT,\n  b TEXT\n);');
  check('多行单语句不被拆散', multi.length == 1 && multi.first.contains('b TEXT'),
      '${multi.length} 段');

  // 🔴 **有意的能力边界**：拆分器**不理解字符串字面量**
  //    → 含 `;` 的字符串会被错误切开。本项目的 DDL 不用这种写法，
  //      这里把它**显式锁住**：不是「应该如此」，而是「已知如此、且我们依赖它不出现」。
  //      将来有人引入 `DEFAULT 'a;b'` 时，这条断言会提示他：得先升级拆分器。
  final withSemicolonInString = splitSqlStatements("SELECT 'a;b';");
  check('⚠️ 已知边界：字符串里的分号会被误切（本项目 DDL 不使用该写法）',
      withSemicolonInString.length == 2,
      '实得 ${withSemicolonInString.length} 段：$withSemicolonInString');
}

// ════════════════════════════════════════════════════════════════
// 【2】连接层 + schema
// ════════════════════════════════════════════════════════════════
Future<void> groupSchemaAndConnection(String schemaPath) async {
  section('【2】连接层：真库可创建 · schema 可执行 · 表与索引齐备');

  final schema = File(schemaPath).readAsStringSync();

  // 走**真实连接层**（不是手写 openDatabase）—— 这样测的是产品路径
  final tmpDir = Directory.systemTemp.createTempSync('coevo_bookmark_');
  final db = await openUserDb(
    factory: databaseFactoryFfi,
    path: '${tmpDir.path}${Platform.pathSeparator}user.db',
    schemaSql: schema,
  );

  check('openUserDb 成功建库并执行 schema', true, tmpDir.path);

  // ════════════════════════════════════════════════════════════════
  // 🔴🔴 【2.0】守护断言：schema 里**不得出现 PRAGMA**（2026-09-27 新增）
  // ════════════════════════════════════════════════════════════════
  //
  // 背景：schema 曾有 `PRAGMA journal_mode = WAL`，它在 **Android 上会让
  //       `openUserDb` 直接失败** ——
  //         `db.execute()` → `SQLiteDatabase.execSQL()`
  //                        → `SQLiteStatement.executeUpdateDelete()`（只接受
  //                          **不返回数据**的语句，而 journal_mode 会返回结果行）。
  //       Android 官方 javadoc 明文：per-connection PRAGMA 不该用 execSQL。
  //
  // 🔴 而**本脚本发现不了它**：FFI 直调 sqlite3 C API，没有 Android 那层限制
  //    → 49 项全过、问题被掩盖（「在错平台验证」的典型）。
  //    → 所以这里必须用**静态断言**把它挡住，靠运行期是挡不住的。
  //
  // ⚠️ 判据必须**先滤掉注释行** —— 文件顶部那段「为什么不能有 PRAGMA」的说明
  //    本身含 "PRAGMA" 字样，不滤就会把这条断言误判为失败（假红）。
  final schemaCodeLines = schema
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('--'))
      .toList();
  final pragmaLines =
      schemaCodeLines.where((l) => l.toUpperCase().contains('PRAGMA')).toList();
  check('schema 里不得出现 PRAGMA（连接级设置归 onConfigure）',
      pragmaLines.isEmpty, '实际含 PRAGMA 的代码行：$pragmaLines');

  // 连接级设置**真的生效了**（由 `onConfigure` 承担，不是靠 schema）
  final journalMode =
      '${(await db.rawQuery('PRAGMA journal_mode')).first.values.first}';
  check('journal_mode = wal（onConfigure 用 rawQuery 设置）',
      journalMode.toLowerCase() == 'wal', journalMode);

  final foreignKeys = (await db.rawQuery('PRAGMA foreign_keys')).first.values.first;
  check('foreign_keys = 1（onConfigure 设置）', foreignKeys == 1, '$foreignKeys');

  // 表齐备（v1 三张 + v1.2 的 bookmark）
  final tables = await db.query('sqlite_master',
      columns: ['name'], where: "type = 'table'");
  final names = tables.map((r) => r['name'] as String).toSet();
  for (final t in ['card_review_state', 'review_log', 'bookmark']) {
    check('表 $t 存在', names.contains(t));
  }

  // bookmark 的索引（设计稿只要求 idx_bm_time；idx_bm_pending 是本文件的补充）
  final idx = await db.rawQuery("PRAGMA index_list('bookmark')");
  final idxNames = idx.map((r) => r['name'] as String).toSet();
  check('索引 idx_bm_time 存在', idxNames.contains('idx_bm_time'), '$idxNames');
  check('索引 idx_bm_pending 存在（增量 push 用）', idxNames.contains('idx_bm_pending'));

  // 幂等：再次 openUserDb（同一路径）不应重复建表或报错
  //   🔑 这条测的是「应用重启」场景 —— schema 全是 IF NOT EXISTS，重开必须安全
  await db.close();
  final db2 = await openUserDb(
    factory: databaseFactoryFfi,
    path: '${tmpDir.path}${Platform.pathSeparator}user.db',
    schemaSql: schema,
  );
  final tables2 = await db2.query('sqlite_master',
      columns: ['name'], where: "type = 'table'");
  check('重开同一库（模拟应用重启）不报错、表不重复',
      tables2.length == tables.length, '${tables2.length} vs ${tables.length}');
  await db2.close();
  tmpDir.deleteSync(recursive: true);
}

// ════════════════════════════════════════════════════════════════
// 【3】BookmarkRepository
// ════════════════════════════════════════════════════════════════
Future<void> groupRepository(String schemaPath) async {
  section('【3】BookmarkRepository：增删切换 · 幂等 · 时间戳语义');

  final schema = File(schemaPath).readAsStringSync();
  final tmpDir = Directory.systemTemp.createTempSync('coevo_bm_repo_');
  final db = await openUserDb(
    factory: databaseFactoryFfi,
    path: '${tmpDir.path}${Platform.pathSeparator}user.db',
    schemaSql: schema,
  );
  final repo = BookmarkRepository(db);
  await repo.reload();

  // ── 初始状态 ──
  eq('初始为空', repo.count, 0);
  check('未收藏时 contains 为 false', !repo.contains(1));

  // ── 新增 ──
  final added = await repo.add(1);
  check('add 返回 true（本次真的新增）', added);
  check('contains 变 true', repo.contains(1));
  eq('count = 1', repo.count, 1);

  // ── 幂等：重复 add ──
  final addedAgain = await repo.add(1);
  check('重复 add 返回 false（幂等）', !addedAgain);
  eq('重复 add 后 count 仍为 1', repo.count, 1);

  // 🔴 **重复点击不得刷新时间戳**
  //    做法：先把时间戳改成「很久以前」，再 add 一次，看它有没有被刷新。
  //    （直接连点两次无法验证 —— SQLite 的 strftime 精度是秒，同秒内值相同。）
  await db.update('bookmark', {'bookmarked_at': '2020-01-01T00:00:00Z'},
      where: 'content_id = ?', whereArgs: [1]);
  await repo.reload();
  await repo.add(1);
  final row = (await db.query('bookmark', where: 'content_id = ?', whereArgs: [1])).first;
  eq('重复收藏**不刷新** bookmarked_at（表达「我什么时候存的」）',
      row['bookmarked_at'], '2020-01-01T00:00:00Z');

  // ── 取消 ──
  final removed = await repo.remove(1);
  check('remove 返回 true', removed);
  check('contains 变 false', !repo.contains(1));
  eq('count = 0', repo.count, 0);
  // ── 🔴 v6（2026-10-05 · 跨设备同步）：取消收藏由**硬删**改为**软删** ──
  //
  // 这条断言原来写的是「表里确实没有该行」（= 硬删）。改软删后**它必然红** ——
  // ✅ 这正是它该做的：**断言守着实现，把「语义变更」显式暴露**，而不是静默放过。
  // 📄 依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §3.3
  //    （硬删在**并集同步**下会被别端「并回来」⇒ 删除必须变成**字段值**）
  final rowsAfterRemove = await db.query('bookmark');
  eq('🔴 remove 后该行**仍在**（软删，不是硬删）', rowsAfterRemove.length, 1);
  // ⚠️ **必须判空再取 `.first`** —— 若上面那条红了（= 又变回硬删，行数为 0），
  //    这里直接 `.first` 会抛异常 ⇒ **整个脚本崩栈**（后面的断言一条都不跑、汇总也不打印）
  //    ⇒ 门禁从「红 + 说清原因」退化成「崩 + 什么都不说」，极易被误读成环境问题。
  // 📌 判据：**依赖前提的断言要在前提不成立时跳过**（前面已经红了，门禁已经是红的）。
  if (rowsAfterRemove.isNotEmpty) {
    eq('🔴 且该行 `deleted = 1`',
        (rowsAfterRemove.first['deleted'] as num).toInt(), 1);
    eq('🔴 且 `pending_push = 1` —— 同步要能把「删除」推出去',
        (rowsAfterRemove.first['pending_push'] as num).toInt(), 1);
  }
  // 🔴 **最关键的一条**：软删后**界面不能还显示它** ——
  //    `reload()` / `list()` 都必须带 `WHERE deleted = 0`，漏一处就是「删了还在」。
  check('🔴 reload 后内存集合不含已删项（否则界面显示「已取消的收藏」）',
      !repo.contains(1) && repo.count == 0);
  final listedAfterRemove = await repo.list();
  check('🔴 list 不返回已软删的项',
      listedAfterRemove.every((b) => b.contentId != 1),
      '实得 ${listedAfterRemove.map((b) => b.contentId).toList()}');

  // 移除不存在的 → false（不报错）
  check('remove 不存在的条目返回 false', !(await repo.remove(999)));

  // 🔴 **取消后可再收藏**（设计稿 §四 ④：收藏是**可再生的用户意图**，硬删）
  final readded = await repo.add(1);
  check('取消后可以再收藏', readded);
  final row2 = (await db.query('bookmark', where: 'content_id = ?', whereArgs: [1])).first;
  check('再收藏的时间戳**是新的**（不是 2020 那个）',
      row2['bookmarked_at'] != '2020-01-01T00:00:00Z', '${row2['bookmarked_at']}');

  // ── toggle ──
  eq('toggle 已收藏 → 返回 false（变为未收藏）', await repo.toggle(1), false);
  eq('toggle 未收藏 → 返回 true（变为已收藏）', await repo.toggle(1), true);
  check('toggle 后确实已收藏', repo.contains(1));

  // ── 待同步 ──
  final pendingBefore = await repo.pending();
  eq('新增的记录 pending_push = 1', pendingBefore.length, 1);
  await repo.markSynced([1]);
  eq('markSynced 后无待同步', (await repo.pending()).length, 0);
  await repo.reload();
  eq('reload 后 pendingPush 字段为 false',
      (await repo.list()).first.pendingPush, false);
  // 幂等：空集合不报错
  await repo.markSynced(<int>[]);
  check('markSynced 空集合不报错', true);

  // ── list 倒序 ──
  await db.delete('bookmark');
  await repo.reload();
  // 手工写入**可控时间戳**（不依赖真实时钟，避免同秒导致顺序不确定）
  for (final (id, ts) in [
    (10, '2026-09-01T00:00:00Z'),
    (11, '2026-09-03T00:00:00Z'),
    (12, '2026-09-02T00:00:00Z'),
  ]) {
    await db.insert('bookmark', {'content_id': id, 'bookmarked_at': ts});
  }
  await repo.reload();
  final listed = await repo.list();
  eq('list 按 bookmarked_at 倒序（最近收藏在前）',
      listed.map((b) => b.contentId).toList(), [11, 12, 10]);
  check('list 解析出 UTC 时间',
      listed.first.bookmarkedAt.isUtc &&
          listed.first.bookmarkedAt == DateTime.utc(2026, 9, 3),
      '${listed.first.bookmarkedAt.toIso8601String()}');
  // limit / offset
  eq('list 支持 limit', (await repo.list(limit: 2)).length, 2);
  eq('list 支持 offset', (await repo.list(offset: 1)).first.contentId, 12);

  // ── 库中时间列格式 ──
  await db.insert('bookmark', {'content_id': 99});
  final raw = (await db.query('bookmark', where: 'content_id = ?', whereArgs: [99])).first;
  final ts = raw['bookmarked_at'] as String;
  check('DEFAULT 生成的时间串带尾随 Z（UTC ISO8601）', ts.endsWith('Z'), ts);
  check('DEFAULT 生成的时间戳可被 parseUserDbUtc 解析',
      parseUserDbUtc(ts).isUtc);
  eq('pending_push 默认值为 1', raw['pending_push'], 1);

  await db.close();
  tmpDir.deleteSync(recursive: true);
}

// ════════════════════════════════════════════════════════════════
// 【4】时间解析器 —— 拒绝「无 Z」（静默错位防线）
// ════════════════════════════════════════════════════════════════
void groupUtcParsing() {
  section('【4】时间解析器：带 Z 通过 · 无 Z **抛错**（防静默时区错位）');

  check('带 Z 正确解析为 UTC',
      parseUserDbUtc('2026-09-27T05:00:00Z') == DateTime.utc(2026, 9, 27, 5));

  // 🔴 核心：无 Z 必须抛错。
  //    ⚠️ `DateTime.parse('2026-09-27T05:00:00')` **不会抛错** ——
  //    它会静默按**本地时区**解释（UTC+8 机器上 = UTC 前一天 21:00），
  //    于是「刚收藏的」显示成「昨天」，且没有任何异常。
  var threw = false;
  try {
    parseUserDbUtc('2026-09-27T05:00:00');
  } catch (_) {
    threw = true;
  }
  check('无 Z 的串**抛错**（而不是静默按本地时区解释）', threw);

  // 对照：证明「如果不管，Dart 会静默接受」
  final localParsed = DateTime.parse('2026-09-27T05:00:00');
  check('（对照）DateTime.parse 对无 Z 串**不抛错**，正是危险之处',
      !localParsed.isUtc, '被当成本地时间：$localParsed');

  var threwEmpty = false;
  try {
    parseUserDbUtc('');
  } catch (_) {
    threwEmpty = true;
  }
  check('空串抛错', threwEmpty);
}

// ════════════════════════════════════════════════════════════════
Future<void> main(List<String> args) async {
  final schemaPath = args.isNotEmpty ? args[0] : userDbSchemaPath();

  print('CoEvo 收藏验收 · SQL 拆分器 + user.db 连接层 + BookmarkRepository');
  print('schema: $schemaPath');

  if (!File(schemaPath).existsSync()) {
    stderr.writeln('找不到 schema: $schemaPath');
    exit(2);
  }

  sqfliteFfiInit();

  groupSplitter();
  groupUtcParsing();
  await groupSchemaAndConnection(schemaPath);
  await groupRepository(schemaPath);

  print('\n${'═' * 74}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败清单：');
    for (final f in _failures) {
      print('  · $f');
    }
  }
  print('═' * 74);
  if (_failures.isEmpty) {
    print('\n✅ 收藏数据层符合设计稿（§四）与 user.db 硬约束');
  }
  exit(_failures.isEmpty ? 0 : 1);
}
