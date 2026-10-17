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

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/fsrs_service.dart';
import '../../../app/lib/services/generated_card_adapter.dart'
    show firstDefinitionZhOf;
import '../../../app/lib/services/review_list_query.dart';
import '../../../app/lib/services/user_db.dart';
import '../../../app/lib/services/word_query_service.dart';
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

Future<void> main(List<String> args) async {
  final schemaPath = args.isNotEmpty ? args[0] : userDbSchemaPath();
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

    // 🔴 **前置守卫**：列表查询必须能读出刚写入的 4 条。
    //
    // 为什么单列一条：若这里就空了（JOIN 写错 / 表名错 / 过滤条件反了），
    // 后面**所有**依赖 `.first` 的断言都会**崩在异常上** ——
    // 而崩溃会被误读成「环境问题」（本项目已踩过：3.4c 的迁移脚本当时就是崩着退出的）。
    // → 先给一条**根因明确**的红，再让后续断言各自报红（而不是一起崩掉）。
    final baseline = await q.list();
    check('🔴 前置守卫：写入后可读出 4 条（否则后续断言会崩而非报红）',
        baseline.length == 4, '实得 ${baseline.length} 条');

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
        byRecent.isNotEmpty && byRecent.first.spelling == 'Reception',
        'Reception.lastReviewAt=30天前, updated_at=now → 实测 ${byRecent.length} 行');

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

    // ── 10. 暂停过滤（LEFT JOIN user_word）+ dueOnly 筛选 ──────
    //
    // 🔴 这一段锁「**单一列表**」的数据基础（`ui-ux` §6.2.1）：
    //    一个词「离开视野」不是被移出，而是 `user_word.deleted = 1`（暂停）。
    //    而排序依据 `next_review_at` 只在 `card_review_state` → 必须 JOIN 两张表。
    //
    // 🔑 三条查询（`list` / `count` / `dueCount`）**必须用同一套过滤** ——
    //    少一条就会出现「顶部说 N 个该看、列表只数得出 M 个」的自相矛盾。
    print('\n【10】暂停过滤（JOIN user_word）与 dueOnly 筛选');

    // 基线（上面的 4 个词：receive 到期 · capture/agent/Reception 未到期）
    check('基线：列表 4 条', (await q.list()).length == 4, '${(await q.list()).length}');
    check('基线：dueCount == 1', await q.dueCount(now) == 1);

    // capture 进生词本（未暂停）→ 不该影响列表
    await db.insert('user_word', {
      'word_id': 'w005359',
      'spelling': 'capture',
      'source_article_id': null,
      'source_sentence': null,
    });
    check('生词本有 capture（deleted=0）→ 列表仍 4 条',
        (await q.list()).length == 4);

    // 🔴 暂停它 → 三条查询都要跟着变
    await db.rawUpdate(
        "UPDATE user_word SET deleted = 1 WHERE word_id = 'w005359'");
    final afterPause = await q.list();
    check('🔴 暂停后列表少一条（3）', afterPause.length == 3, '${afterPause.length}');
    check('🔴 暂停的词不在列表里',
        !afterPause.any((e) => e.wordId == 'w005359'));
    check('🔴 count() 同步排除暂停（3）', await q.count() == 3, '${await q.count()}');
    check('🔴 搜索也排除暂停的词',
        (await q.list(search: 'cap')).isEmpty);
    check('🔴 dueCount 也排除暂停（口径一致）',
        await q.dueCount(now) == 1);

    // dueOnly 筛选（白哥 2026-09-28 新增的「显示全部 / 显示已到期」）
    final dueList = await q.list(dueOnly: true, nowUtc: now);
    check('dueOnly=true 只返回到期的（1 条）', dueList.length == 1,
        '${dueList.length}');
    check('dueOnly 的结果与 dueCount 一致',
        dueList.length == await q.dueCount(now));
    check('dueOnly 返回的确实是已到期那个',
        dueList.isNotEmpty && dueList.first.wordId == 'w001720');

    // 🔑 LEFT JOIN 的关键语义：`crs` 里有记录、但 `user_word` 里**没有行** → **仍然显示**
    //    （若写成 INNER JOIN，这个词会**静默消失** —— 用户的词无声不见）
    check('🔑 不在 user_word 里的词仍显示（LEFT 而非 INNER）',
        afterPause.any((e) => e.wordId == 'w000001'));

    // 复活（`deleted` 1→0）→ 回到列表
    await db.rawUpdate(
        "UPDATE user_word SET deleted = 0 WHERE word_id = 'w005359'");
    check('复活后列表恢复 4 条', (await q.list()).length == 4,
        '${(await q.list()).length}');

    // ── 11. 性能 ──────────────────────────────────────────────
    print('\n【11】性能');
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

    // ── 12. step 字段 + toReviewState 映射（FSRS 预览的前提）──
    //
    // 🔴 为什么必须有这一节（2026-09-28 · 做词卡时加）：
    //    词卡四键要显示「下次 X 天」，那是 `FsrsService.previewAll(state, now)` 算的，
    //    而它吃的是**完整的 `ReviewState`**。
    //    ⚠️ 列表项若漏了 `step`（learning / relearning 态的「第几步」），
    //       预览会**当 step=null 去算** → 新词四键的数字**全是错的**，
    //       而且**错得看不出来**（数字看起来照样合理）。
    //    → 字段映射必须逐字段锁住。
    print('\n【12】step 字段与 toReviewState 映射（词卡预览的前提）');

    await q.upsertState(
      wordId: 'wStepTest',
      spelling: 'stepTest',
      state: 1, // learning
      step: 3,
      stability: 1.5,
      difficulty: 6.0,
      reps: 2,
      lapses: 1,
      lastReviewAt: now.subtract(const Duration(hours: 1)),
      nextReviewAt: now.add(const Duration(minutes: 10)),
    );

    final stItem = await q.stateOf('wStepTest');
    check('列表能读回 step（不只是 state）', stItem?.step == 3, '${stItem?.step}');

    final rs = stItem!.toReviewState();
    check(
      '🔴 toReviewState 字段映射完整（漏一个会让四键预览算错）',
      rs.wordId == stItem.wordId &&
          rs.state == stItem.state &&
          rs.step == stItem.step &&
          rs.stability == stItem.stability &&
          rs.difficulty == stItem.difficulty &&
          rs.reps == stItem.reps &&
          rs.lapses == stItem.lapses &&
          rs.lastReviewAt == stItem.lastReviewAt &&
          rs.nextReviewAt == stItem.nextReviewAt,
      'state=${rs.state} step=${rs.step} S=${rs.stability} D=${rs.difficulty}',
    );

    // ── 13. review_log 落库（修掉一个「从未暴露」的 NOT NULL bug）──
    //
    // 🔴 背景（2026-09-28 发现）：`ReviewEvent.toRow()` **漏了 `utc_day`**，
    //    而 `review_log.utc_day` 是 `NOT NULL` 且**无 DEFAULT**
    //    → INSERT 必然 `NOT NULL constraint failed`。
    //    它从 2026-09-26 建表起就存在，**直到本次才被发现** ——
    //    因为在此之前**没有任何代码写过 `review_log`**（本方法从无调用方）。
    //    🔑 「从未被执行 ⇒ 缺陷不可见」。所以本节就是那个**第一次执行**。
    print('\n【13】review_log 落库（utc_day / device_id 的 NOT NULL 坑）');

    final ev = ReviewEvent(
      wordId: 'wStepTest',
      rating: ReviewRating.good,
      reviewedAt: now,
    );

    var logOk = true;
    String? logErr;
    try {
      await q.logReview(ev);
    } catch (e) {
      logOk = false;
      logErr = '$e';
    }
    check('🔴 logReview 落库成功（曾是 NOT NULL constraint failed）', logOk,
        logErr ?? '');

    // ⚠️ 断言**不能假设表是空的** —— 前面的【8】段已经写过一行 `review_log`
    //    （`device_id='devA'`）。改成「按本词取行」，与全局状态解耦。
    //    🔑 这是「断言范围」问题的又一形态：**前提假设**也是范围的一部分。
    Future<int> myLogCount() async {
      final r = await db.rawQuery(
          'SELECT count(*) AS n FROM review_log WHERE word_id = ?',
          ['wStepTest']);
      return (r.first['n'] as int?) ?? 0;
    }

    check('review_log 写入该词 1 行', await myLogCount() == 1,
        '${await myLogCount()} 行');

    // 🔑 幂等：同一条日志再写一次必须被忽略
    //    （幂等键是 `UNIQUE (word_id, reviewed_at, device_id)`）
    await q.logReview(ev);
    check('🔑 同一条日志重复写入被忽略（幂等）', await myLogCount() == 1,
        '${await myLogCount()} 行');

    final logRow = await db.rawQuery(
        'SELECT * FROM review_log WHERE word_id = ? LIMIT 1', ['wStepTest']);
    check('device_id 不为 NULL（NULL 会破坏 UNIQUE 幂等键）',
        logRow.first['device_id'] != null, '${logRow.first['device_id']}');
    check('utc_day 已写入（NOT NULL 列不可漏）',
        ((logRow.first['utc_day'] as String?) ?? '').isNotEmpty,
        '${logRow.first['utc_day']}');
    check('rating 落库为数值 1–4',
        (logRow.first['rating'] as int) >= 1 &&
            (logRow.first['rating'] as int) <= 4);
    check('reviewed_at 以 Z 结尾（UTC ISO8601）',
        ((logRow.first['reviewed_at'] as String?) ?? '').endsWith('Z'));

    // ── 14. 🔴「无主划线卡」不可见（2026-10-09）────────────────
    //
    // 现象（白哥真机）：复习列表顶部一张标题显示成 `hl:<uuid>` 的卡，
    //   **点「暂停」没有任何反应**（不报错、不提示），界面上也没有任何出口能去掉它。
    //
    // 根因（两层都是既有的设计事实）：
    //   ① `highlight`（划线本体）**从不参与同步**（服务端只有 6 张 `sync_*` 表，无它）；
    //   ② `review_log`（复习事件）**参与同步** ⇒ `hl:<uuid>` 的事件照常上云。
    //   ⇒ 重装 / 换机 / 清数据后，pull 回来的事件被重放成一行 `card_review_state`，
    //     而它引用的划线在**本机不存在** —— 即「无主卡」。
    //
    // 🔑 修在**判据层**（`_visibilityWheres` 第 ④ 条）而不是「暂停」按钮上：
    //    判据有洞时先问「还有哪些地方有」—— 无主卡出现在列表、被计数统计、还能点进翻卡页，
    //    修在按钮上只堵住一个出口；而它的成因**对每个用户都会发生**。
    //
    // 🔴 本节的证伪方式（改了必须变红）：
    //    · 删掉 `_visibilityWheres` 里那条 `OR h.id IS NOT NULL` ⇒ 「不在列表 / 不计入」变红
    //    · 把它改成 `AND h.id IS NULL`（方向写反）⇒ 「划线存在时卡片出现」变红
    print('\n【14】无主划线卡不可见（划线本体不在本机 ⇒ 卡片不显示）');

    const orphanUuid = 'deadbeef-0000-4000-8000-00000000cafe';
    const orphanWordId = 'hl:$orphanUuid';

    final baseList = (await q.list()).length;
    final baseCount = await q.count();
    final baseDue = await q.dueCount(now);

    // 造「有卡、无划线」的无主状态（= pull 重放之后的样子；`next_review_at` 取过去
    // 时刻，这样它也**已到期** —— 用来证明 `dueCount` 同样排除它）
    await q.upsertState(
      wordId: orphanWordId,
      // ⚠️ 故意写 id 当拼写：那只影响标题显示，与本节的可见性判据无关
      //    （脏拼写的修复见 `verify_review_spelling.dart`）
      spelling: orphanWordId,
      nextReviewAt: DateTime.utc(2020),
    );

    check('🔴 无主划线卡**不在列表**里（引用了本机不存在的划线）',
        !(await q.list()).any((e) => e.wordId == orphanWordId),
        '列表 ${(await q.list()).length} 条（基线 $baseList）');
    check('🔴 无主划线卡**不计入** count（列表与计数同源）',
        await q.count() == baseCount,
        '${await q.count()} vs 基线 $baseCount');
    check('🔴 无主划线卡**不计入** dueCount（即使它已到期）',
        await q.dueCount(now) == baseDue,
        '${await q.dueCount(now)} vs 基线 $baseDue');
    check('🔴 搜索也查不到它',
        (await q.list(search: 'hl:')).isEmpty);

    // 🔑 关键对照：**划线真的存在时，卡片必须立刻出现** ——
    //    证明这条判据是「按划线是否存在」判，而不是「把 `hl:` 一律挡掉」。
    await db.insert('highlight', {
      'id': orphanUuid,
      'source_type': 'article',
      'source_id': '42',
      'chapter_idx': null,
      'start_offset': 0,
      'end_offset': 5,
      'text': 'hello world',
      'note': null,
      'deleted': 0,
      'pending_push': 1,
      'paused': 0,
    });
    check('🔑 划线在本机存在 ⇒ 卡片立刻出现（没有误杀 `hl:`）',
        (await q.list()).any((e) => e.wordId == orphanWordId));
    check('🔑 它也计入 count', await q.count() == baseCount + 1);
    check('🔑 它已到期 ⇒ dueCount 也 +1',
        await q.dueCount(now) == baseDue + 1);

    // 既有的两条判据仍在那张卡上生效（暂停 / 取消）
    await db.rawUpdate(
        "UPDATE highlight SET paused = 1 WHERE id = '$orphanUuid'");
    check('🔑 有划线但已暂停 ⇒ 仍不显示（既有判据未被新判据顶掉）',
        !(await q.list()).any((e) => e.wordId == orphanWordId));

    await db.rawUpdate(
        "UPDATE highlight SET paused = 0, deleted = 1 WHERE id = '$orphanUuid'");
    check('🔑 有划线但已取消 ⇒ 仍不显示',
        !(await q.list()).any((e) => e.wordId == orphanWordId));

    // 🆕 同族的另一半：**已取消的划线 + 无主** 也要挡住
    //    （`h.id IS NOT NULL` 满足，所以靠的是原来的 `h.deleted` 那条 ——
    //     这里显式锁一次，防止将来有人把 ④ 写成「有行就放行」）
    await db.rawUpdate("DELETE FROM highlight WHERE id = '$orphanUuid'");
    check('🔴 划线被删掉后又回到「无主」⇒ 依然不可见',
        !(await q.list()).any((e) => e.wordId == orphanWordId));

    // 🔑 反向：**词卡不受这条判据影响** —— 它在 `highlight` 里没有行，
    //    若把 ④ 写成「必须 JOIN 上 highlight」就会让**所有词卡消失**。
    check('🔑 词卡不受这条判据影响（`w…` 在 highlight 里没有行也照常显示）',
        (await q.list()).any((e) => e.wordId == 'w000001'),
        '列表 ${(await q.list()).length} 条');
  } finally {
    await db.close();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════
  // ⑨ 🔴 复习列表取释义：**LLM 生成的词（`ext:`）必须也能取到**
  // ══════════════════════════════════════════════════════════════════════
  //
  // 2026-10-17 真机 bug：`weighin` / `papacy` 在复习列表**没有中文释义**，
  // 而 `rest` / `lung` 有。
  //
  // 根因：`firstDefinitionsOf` 原先**只查 `word.db.card`**，而 `ext:<spelling>` 的
  // 卡片内容存在 **`user.db.external_word_cache`** ——
  // `cardById`（卡片页 / 复习会话走它）**早就有** `ext:` 回落，这个方法漏了
  // ⇒ **同一件事两个实现，只跟上一遍**。
  //
  // 🔴 证伪方式
  // · 删掉 `readExternalContent` 分支 ⇒ **⑨-2 必红**
  // · 把 `firstDefinitionZhOf` 改成「取数组第一条 definition」⇒ **⑨-1 必红**
  // · 把 provider 的回调删掉 ⇒ **⑨-9 必红**
  {
    final dir = await Directory.systemTemp.createTemp('coevo_defs_');
    final path = '${dir.path}${Platform.pathSeparator}word_min.db';

    // 造**最小 word.db** —— `firstDefinitionsOf` 只查 `card` 表
    String cardJson(String zh) => jsonEncode({
          'front': 'x',
          'ipa': '',
          'entry_type': '',
          'sections': [
            // 🔴 三条 definition 的**数组顺序与 order 故意全不一致**，让三种可能的
            //    「错误实现」各自拿到不同的错值 ⇒ 只有「真的按 order 取最小」才会绿：
            //      · 取**数组第一条** ⇒ 「A-误1」
            //      · 取**数组最后一条** ⇒ 「A-误2」
            //      · 正确的 `order: 1` 夹在**中间** ⇒ 只有按 order 比较才拿得到
            //    ⚠️ 首版没这么设计（order 最小的恰在最后一条）⇒ 证伪时**没红**，
            //       是「断言太松 = 假绿」的实例。判据：**证伪必须真能红**。
            {'type': 'definition', 'order': 3, 'zh': '$zh-误1'},
            {'type': 'definition', 'order': 1, 'zh': zh},
            {'type': 'definition', 'order': 2, 'zh': '$zh-误2'},
            {'type': 'etymology', 'order': 0, 'text': '词源'},
          ],
        });

    final wdb = await factory.openDatabase(path);
    await wdb.execute(
        'CREATE TABLE card (word_id TEXT PRIMARY KEY, content TEXT)');
    await wdb.insert('card', {'word_id': 'w000001', 'content': cardJson('休息')});
    await wdb.close();

    // 模拟 `user.db.external_word_cache`（key = 归一化拼写）
    final extCache = <String, String>{'weighin': cardJson('称重')};

    final svc = await WordQueryService.open(
      databaseFactoryFfi,
      path,
      externalCardLoader: (sp) async => extCache[sp],
    );
    final defs = await svc.firstDefinitionsOf(
      ['w000001', 'ext:weighin', 'ext:nocache'],
      readExternalContent: (sp) async => extCache[sp],
    );
    await svc.close();

    check('⑨-1 词库词取到**首义**（`order` 最小的那条，不是数组第一条）',
        defs['w000001'] == '休息', '实际 ${defs['w000001']}');
    check(
        '⑨-2 🔴 LLM 生成的词（`ext:`）也能取到释义',
        defs['ext:weighin'] == '称重',
        '实际 ${defs['ext:weighin']} —— null 说明 ext 回落没生效（本次修复的核心）');
    check('⑨-3 缓存里也没有的词 ⇒ **不出现**（不是空串占位）',
        !defs.containsKey('ext:nocache'));
    check('⑨-4 加了 ext 分支后，词库词照旧能取到', defs.containsKey('w000001'));

    // ── 渐进语义：不传回调 ⇒ 只有词库词（与修复前一致）──
    final svc2 = await WordQueryService.open(databaseFactoryFfi, path);
    final defs2 = await svc2.firstDefinitionsOf(['w000001', 'ext:weighin']);
    await svc2.close();
    check('⑨-5 不传 `readExternalContent` ⇒ ext 词不出现（渐进语义）',
        defs2['w000001'] == '休息' && !defs2.containsKey('ext:weighin'));

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ── ⑩ 纯函数真值表 + 接线/反向断言 ──
  {
    check('⑩-1 无 `definition` 段 ⇒ null',
        firstDefinitionZhOf([
          {'type': 'etymology', 'order': 0, 'text': 'x'}
        ]) ==
            null);
    check(
        '⑩-2 `zh` 为空串/纯空白 ⇒ null（不是空串，让调用方能区分）',
        firstDefinitionZhOf([
              {'type': 'definition', 'order': 1, 'zh': '   '}
            ]) ==
            null);
    check(
        '⑩-3 `zh` 类型不对 ⇒ null（不抛）',
        firstDefinitionZhOf([
              {'type': 'definition', 'order': 1, 'zh': 42}
            ]) ==
            null);
    check(
        '⑩-4 正常值 trim 后返回',
        firstDefinitionZhOf([
              {'type': 'definition', 'order': 1, 'zh': '  休息  '}
            ]) ==
            '休息');

    String readSrc(String rel) {
      final f = File(repoPath(rel));
      return f.existsSync() ? f.readAsStringSync() : '';
    }

    final svcSrc = readSrc('app/lib/services/word_query_service.dart');
    check('⑩-5 `firstDefinitionsOf` 有 `readExternalContent` 参数',
        svcSrc.contains('readExternalContent'));
    check(
        '⑩-6 🔴 走**共用**解析 `firstDefinitionZhOf`（不再自己 jsonDecode 取 sections）',
        svcSrc.contains('firstDefinitionZhOf('));
    check('⑩-7 🔴 旧的 `_firstDefinitionZh` **不得复活**（反向断言）',
        !svcSrc.contains('static String? _firstDefinitionZh'),
        '复活 ⇒ 又出现两份 JSON 解析，迟早再漏一个来源');

    final prov = readSrc('app/lib/providers/review_list_provider.dart');
    check(
        '⑩-8 🔴 provider 真的注入了外部缓存读取器（防「代码写了没人接」）',
        prov.contains('readExternalContent:') &&
            prov.contains('ExternalWordCacheRepository'));
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
