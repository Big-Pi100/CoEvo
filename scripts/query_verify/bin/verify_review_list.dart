// CoEvo · `ReviewListQuery` 验收（user.db 侧：复习列表 / 搜索 / 排序 / 分组）
//
// 跑法：cd scripts/query_verify && dart pub get --offline && dart run bin/verify_review_list.dart
//
// 本脚本同时验证 **schema 文件本身** —— 它直接读 `app/assets/sql/user_db_schema.sql`
// 并执行，所以「文件写错了」会在这里暴露（而不是等到真机运行时）。
//
// 验证目标：
//   · schema 可执行（含 v1.1 新增的冗余 `spelling` 列与索引）
//   · 写入 / 读回 / 更新
//   · 三档排序（记忆曲线 / 最近 / A–Z）
//   · 按单词搜索（前缀匹配 + `LIKE` 通配符转义）
//   · 「N 个今天该看」与分组一致
//   · 排序字段白名单（防注入）
//   · `spelling` NOT NULL 约束（冗余列不能忘写）
//   · 性能

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/review_list_query.dart';
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

Future<void> main(List<String> args) async {
  final schemaPath = args.isNotEmpty
      ? args[0]
      : r'E:\CoEvo\app\assets\sql\user_db_schema.sql';
  final schemaFile = File(schemaPath);
  if (!schemaFile.existsSync()) {
    stderr.writeln('找不到 schema: $schemaPath');
    exit(2);
  }

  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  // 用临时库，避免污染任何真实数据
  final tmpDir = Directory.systemTemp.createTempSync('coevo_userdb_');
  final dbPath = '${tmpDir.path}${Platform.pathSeparator}user.db';
  print('schema: $schemaPath');
  print('临时库: $dbPath');
  print('');

  final db = await factory.openDatabase(dbPath);
  try {
    // ── 1. schema 可执行 ───────────────────────────────────────
    print('【1】schema 可执行 + v1.1 冗余列存在');
    final schema = schemaFile.readAsStringSync();
    // 逐语句执行，遇到失败即暴露
    //
    // 🔑 2026-09-27 起改用 `user_db.dart` 的 `executeSqlScript` —— 此前这里是
    //    **一套内联的弱拆分器**（`split(';')` + 过滤以 `--` 开头的行），问题是：
    //      · 不处理**行内注释**（`SELECT 1 -- 说明` 会把注释文本留下来）
    //      · 不处理**块注释** `/* ... */`
    //    而同一份 schema 在 `verify_bookmark.dart` 里走的是强拆分器
    //    → 「同一份文件、两套解析」迟早分叉（一个通一个不通，且症状诡异）。
    //    → 复用同一个实现，是「同一套逻辑不要写两遍」的直接落实。
    var schemaOk = true;
    String? schemaErr;
    try {
      await executeSqlScript(db, schema);
    } catch (e) {
      schemaOk = false;
      schemaErr = '$e';
    }
    check('schema 全部语句执行成功', schemaOk, schemaErr ?? '');

    final cols = await db.rawQuery('PRAGMA table_info(card_review_state)');
    final colNames = cols.map((c) => c['name'] as String).toSet();
    check('card_review_state 有 spelling 列', colNames.contains('spelling'));
    check('spelling 是 NOT NULL',
        cols.any((c) => c['name'] == 'spelling' && (c['notnull'] as int) == 1));

    final idx = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_crs_spelling'");
    check('存在 idx_crs_spelling 索引', idx.isNotEmpty);

    final q = ReviewListQuery(db);

    // ── 2. 写入 / 读回 ────────────────────────────────────────
    print('\n【2】写入与读回');
    final now = DateTime.utc(2026, 9, 26, 12, 0, 0);
    await q.upsertState(
      wordId: 'w001720',
      spelling: 'receive',
      state: 2,
      stability: 9.0,
      difficulty: 5.0,
      reps: 3,
      lastReviewAt: now.subtract(const Duration(days: 9)),
      nextReviewAt: now.subtract(const Duration(hours: 2)), // 已到期
    );
    await q.upsertState(
      wordId: 'w005359',
      spelling: 'capture',
      state: 1,
      reps: 1,
      nextReviewAt: now.add(const Duration(hours: 2)), // 未到期
    );
    await q.upsertState(
      wordId: 'w000001',
      spelling: 'agent',
      state: 0,
      nextReviewAt: now.add(const Duration(days: 4)),
    );
    await q.upsertState(
      wordId: 'w000004',
      spelling: 'Reception', // 故意大写，测 NOCASE 搜索
      state: 2,
      reps: 5,
      lastReviewAt: now.subtract(const Duration(days: 1)),
      nextReviewAt: now.add(const Duration(days: 14)),
    );

    final st = await q.stateOf('w001720');
    check('stateOf 读回成功', st != null);
    check('  spelling 正确', st?.spelling == 'receive', '${st?.spelling}');
    check('  state / reps 正确', st?.state == 2 && st?.reps == 3,
        'state=${st?.state} reps=${st?.reps}');
    check('  stability 正确', (st?.stability ?? 0) > 8.9, '${st?.stability}');
    check('stateOf 不存在的词返回 null', await q.stateOf('wZZZ') == null);

    check('count() == 4', await q.count() == 4, '${await q.count()}');

    // ── 3. 三档排序 ───────────────────────────────────────────
    print('\n【3】三档排序');
    final byDue = await q.list(order: ReviewListQuery.orderMemoryCurve);
    check('记忆曲线：按到期时间升序',
        byDue.map((e) => e.spelling).toList().join(',') ==
            'receive,capture,agent,Reception',
        byDue.map((e) => e.spelling).toList().join(','));

    final byAZ = await q.list(order: ReviewListQuery.orderAlphabetical);
    check('A–Z：大小写不敏感排序',
        byAZ.map((e) => e.spelling).toList().join(',') ==
            'agent,capture,receive,Reception',
        byAZ.map((e) => e.spelling).toList().join(','));

    // 「最近」档需要确定性的 updated_at —— upsertState 用 strftime('now')，
    // 四条会同时刻写入 → 并列，排序不定。故显式指定，并**专锁那个已修的 bug**：
    //   Reception 的 last_review_at 很老（30 天前）但刚被更新（updated_at = now）
    //   → 正确的「最近」应把它排第一；而错误的 `COALESCE(last_review_at, updated_at)`
    //     会取到 30 天前 → 排最后（正是本轮验收抓到的实现 bug）。
    Future<void> setUpdated(String wid, String iso) => db.rawUpdate(
        'UPDATE card_review_state SET updated_at = ? WHERE word_id = ?', [iso, wid]);
    await setUpdated('w001720', '2026-09-17T12:00:00Z'); // receive：最早
    await setUpdated('w005359', '2026-09-24T12:00:00Z'); // capture
    await setUpdated('w000001', '2026-08-27T12:00:00Z'); // agent：很久前加入
    await setUpdated('w000004', '2026-09-26T12:00:00Z'); // Reception：刚更新

    final byRecent = await q.list(order: ReviewListQuery.orderRecent);
    check('最近：按 updated_at 降序',
        byRecent.map((e) => e.spelling).toList().join(',') ==
            'Reception,capture,receive,agent',
        byRecent.map((e) => e.spelling).toList().join(','));
    check('🔑 刚更新但上次复习很早的词排第一（COALESCE 会排错）',
        byRecent.first.spelling == 'Reception',
        'Reception.lastReviewAt=30天前, updated_at=now → 实测排第 ${byRecent.indexOf(byRecent.first) + 1}');

    // ── 4. 排序白名单（防注入）────────────────────────────────
    print('\n【4】排序字段白名单（不接受任意 SQL）');
    final evil = await q.list(order: 'next_review_at ASC; DROP TABLE card_review_state; --');
    check('非法 order 回退到记忆曲线（不执行注入）', evil.length == 4, '${evil.length} 行');
    check('表未被破坏', await q.count() == 4);

    // ── 5. 搜索 ───────────────────────────────────────────────
    print('\n【5】按单词搜索（前缀匹配，走 idx_crs_spelling）');
    final s1 = await q.list(search: 'rece');
    check('搜 "rece" 命中 2 条（receive + Reception，NOCASE）', s1.length == 2,
        s1.map((e) => e.spelling).join(','));
    check('count(search) 与 list 一致', await q.count(search: 'rece') == s1.length);

    final s2 = await q.list(search: 'RE CE');
    check('搜 "RE CE" 命中 0 条（无该词）', s2.length == 0);

    final s3 = await q.list(search: '  capt  ');
    check('搜索自动 trim', s3.length == 1 && s3.first.spelling == 'capture');

    final s4 = await q.list(search: '');
    check('空搜索 = 不筛（返回全部）', s4.length == 4);

    print('\n【6】LIKE 通配符转义（用户搜 % 应按字面匹配）');
    final pct = await q.list(search: '%');
    check('搜 "%" 不匹配全部（被转义）', pct.length == 0, '${pct.length} 条');
    final us = await q.list(search: '_');
    check('搜 "_" 不匹配单字符（被转义）', us.length == 0, '${us.length} 条');

    // ── 7. 到期计数与分组 ─────────────────────────────────────
    print('\n【7】「N 个今天该看」与分组一致性');
    final due = await q.dueCount(now);
    check('dueCount == 1（只有 receive 已到期）', due == 1, '实测 $due');

    final all = await q.list(order: ReviewListQuery.orderMemoryCurve);
    final g = ReviewListQuery.group(all, now);
    check('分组 due 数量 == dueCount', g.due.length == due,
        'group=${g.due.length} count=$due');
    check('分组 later 数量正确', g.later.length == 3, '${g.later.length}');
    check('分组总和不丢项', g.due.length + g.later.length == all.length);

    // ── 8. 约束 ───────────────────────────────────────────────
    print('\n【8】约束：冗余 spelling 不能忘写');
    var blocked = false;
    try {
      await db.rawInsert(
          "INSERT INTO card_review_state(word_id, next_review_at) VALUES ('wX','2030-01-01T00:00:00.000Z')");
    } catch (_) {
      blocked = true;
    }
    check('缺 spelling 被 NOT NULL 拦', blocked);

    var ratingBlocked = false;
    try {
      await db.rawInsert(
          "INSERT INTO review_log(word_id, rating, reviewed_at, utc_day) "
          "VALUES ('w1', 9, '2026-09-26T00:00:00Z', '2026-09-26')");
    } catch (_) {
      ratingBlocked = true;
    }
    check('review_log.rating=9 被 CHECK 拦', ratingBlocked);

    // 幂等键（多端同步用）
    await db.rawInsert(
        "INSERT OR IGNORE INTO review_log(word_id, rating, reviewed_at, utc_day, device_id) "
        "VALUES ('w1', 3, '2026-09-26T10:00:00Z', '2026-09-26', 'devA')");
    await db.rawInsert(
        "INSERT OR IGNORE INTO review_log(word_id, rating, reviewed_at, utc_day, device_id) "
        "VALUES ('w1', 3, '2026-09-26T10:00:00Z', '2026-09-26', 'devA')");
    final logN = await db.rawQuery('SELECT count(*) AS n FROM review_log');
    check('review_log 幂等键生效（重复插入被忽略）', (logN.first['n'] as int) == 1,
        '${logN.first['n']} 行');

    // ── 9. 分页 ───────────────────────────────────────────────
    print('\n【9】分页');
    final page1 = await q.list(order: ReviewListQuery.orderAlphabetical, limit: 2, offset: 0);
    final page2 = await q.list(order: ReviewListQuery.orderAlphabetical, limit: 2, offset: 2);
    check('分页 limit/offset 生效', page1.length == 2 && page2.length == 2);
    check('两页无重复',
        page1.map((e) => e.wordId).toSet().intersection(page2.map((e) => e.wordId).toSet()).isEmpty);

    // ── 10. 性能 ──────────────────────────────────────────────
    print('\n【10】性能');
    // 灌 5000 条模拟真实规模（用 `bulk_` 前缀避开上面已用的 w000001/w001720 等真 id）
    await db.transaction((txn) async {
      for (var i = 0; i < 5000; i++) {
        await txn.rawInsert(
          'INSERT INTO card_review_state(word_id, spelling, state, next_review_at) '
          'VALUES (?,?,?,?)',
          [
            'bulk_${i.toString().padLeft(6, '0')}',
            'word$i',
            i % 4,
            DateTime.utc(2026, 9, 26).add(Duration(hours: i)).toIso8601String(),
          ],
        );
      }
    });
    final total = await q.count();
    check('灌入后总数 5004', total == 5004, '$total');

    Future<Map<String, double>> bench(Future<dynamic> Function() fn,
        {int n = 200, int warm = 30}) async {
      for (var i = 0; i < warm; i++) {
        await fn();
      }
      final ts = <int>[];
      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        await fn();
        sw.stop();
        ts.add(sw.elapsedMicroseconds);
      }
      ts.sort();
      return {'p50': ts[n ~/ 2].toDouble(), 'p95': ts[(n * 0.95).floor()].toDouble()};
    }

    String fmt(int us) => us < 1000 ? '${us}us' : '${(us / 1000).toStringAsFixed(2)}ms';

    final bDue = await bench(() => q.dueCount(now));
    final bList = await bench(() => q.list(order: ReviewListQuery.orderMemoryCurve, limit: 50));
    final bSearch = await bench(() => q.list(search: 'word12', limit: 50));
    final bAZ = await bench(() => q.list(order: ReviewListQuery.orderAlphabetical, limit: 50));

    print('    到期计数      : p50=${fmt(bDue['p50']!.toInt())}');
    print('    列表(记忆曲线): p50=${fmt(bList['p50']!.toInt())}');
    print('    列表(A–Z)     : p50=${fmt(bAZ['p50']!.toInt())}');
    print('    搜索          : p50=${fmt(bSearch['p50']!.toInt())}');

    check('到期计数 p50 < 5ms', bDue['p50']! < 5000, fmt(bDue['p50']!.toInt()));
    check('列表查询 p50 < 10ms', bList['p50']! < 10000, fmt(bList['p50']!.toInt()));
    check('搜索 p50 < 10ms', bSearch['p50']! < 10000, fmt(bSearch['p50']!.toInt()));
    check('A–Z 排序 p50 < 15ms', bAZ['p50']! < 15000, fmt(bAZ['p50']!.toInt()));
  } finally {
    await db.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('\n${'=' * 68}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exit(1);
  }
  print('✅ ReviewListQuery 全部通过');
  exit(0);
}
