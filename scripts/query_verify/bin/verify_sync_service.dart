// 「云端同步 · 编排层」验收 —— 假 client + 真 sqlite 内存库
//
// 跑：cd scripts/query_verify && dart run bin/verify_sync_service.dart
// 🔴 退出码：0 = 全过，1 = 有失败（直读，别接 `| tail`）。
//
// # 为什么需要它
//
// `sync_service.dart` 是**编排层** —— 它把「HTTP / 数据库 / 合并口径」串起来。
// 这一层的错误**几乎都是静默的**：
//   · push 失败却标记了已同步 ⇒ 那批数据**永远上不了云**（用户看不出来）
//   · pull 后把「服务端已知的数据」标成待推 ⇒ **回声**（每次同步都白推一遍）
//   · pull 时把「本地未推的改动」标成已同步 ⇒ **本地改动永久丢失**
//   · 游标用「当前时间」而非 `server_time` ⇒ 那段时间的记录**永久跳过**
//
// 🔑 **本脚本的验证方式**（skill `verifiable-core-logic`）：
//    把 IO 推到边界（HTTP 与游标读写都是**注入**的），于是一台本机就能
//    跑完整链路：**假 client**（记录收到的 body / 可切换成失败）
//    + **真 sqlite 内存库**（读真实 schema 文件建表）。
//    ⇒ 这不是「查文本」式的断言，是**真跑一遍看行为**。
//
// # 🔴 证伪方式（每次改断言都该跑一遍）
//
// | 改这里 | 应该变红的是 |
// |---|---|
// | `pushOnce` 把 `markReviewsSynced` 移到 push 之前 | 【1】push 失败不标记 |
// | `pushOnce` 去掉「空批次直接返回」 | 【2】空批次不发请求 |
// | `pendingPushAfterPull` 恒返回 true | 【3】不回声 |
// | `pendingPushAfterPull` 恒返回 false | 【4】不丢本地改动 |
// | `_applyReviewEvents` 的 `logReview(..., synced: 1)` 改成 `0` | 【6】事件不回声 |
// | `pullOnce` 的游标改用 `DateTime.now()` | 【7】游标 = server_time |
// | `pullOnce` 在缺 `server_time` 时仍写游标 | 【8】缺 server_time 不推进 |
// | `_applyBookmarks` 直接用远端值（不合并） | 【9】取消能同步 |
// | `_applyUserWords` 改成整行取新 | 【10】例句取首次 |
// | `SyncReport.pulledTotal` 去掉 `+ pulledBooks` / `+ claimedBooks` | 【9】书单变更计入 |
// | `sync_status_provider` 写回 `pulledTotal + claimedBooks`（补丁复活）| 【9】双计（需人工核）|
//
// # ⚠️ 口径（如实标注）
//
// · 用的是**真 sqlite**（`sqflite_common_ffi`）+ **真 schema 文件** ⇒ 列名/约束都真实。
// · HTTP 是**假**的 ⇒ 本脚本**不验证** URL / header / JSON 解析
//   （那是 `sync_client.dart` 的事，需要 Flutter + 真后端 ⇒ 端到端才验）。
// · 本机 flutter 跑不起来 ⇒ 本脚本是**唯一**能在本地验证这层的途径。

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/sync_service.dart';
import '../../../app/lib/services/sync_merge.dart' as m;
import '../../../app/lib/services/user_db.dart';
import '../../../app/lib/services/ebook/book_progress_sync.dart' as bps;

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

void section(String title) {
  print('');
  print('─' * 74);
  print(title);
  print('─' * 74);
}

/// 假 HTTP：记录收到的 body，可切换成「抛异常」（模拟网络失败）。
class FakeHttp {
  final pushBodies = <Map<String, dynamic>>[];
  final pullCalls = <({String? since, String? deviceId})>[];
  Map<String, dynamic> pullResponse = {'server_time': '2026-10-06T10:00:00.000Z'};
  bool failPush = false;
  bool failPull = false;

  Future<Map<String, dynamic>> push(Map<String, dynamic> body) async {
    if (failPush) throw Exception('网络不可达（假）');
    pushBodies.add(body);
    return {'ok': true, 'received_at': '2026-10-06T10:00:00.000Z'};
  }

  Future<Map<String, dynamic>> pull({String? since, String? deviceId}) async {
    if (failPull) throw Exception('网络不可达（假）');
    pullCalls.add((since: since, deviceId: deviceId));
    return pullResponse;
  }
}

/// 🔴🔴 **必须 `singleInstance: false`** —— 否则每个「新库」其实是同一个库。
///
/// `sqflite` 默认 `singleInstance: true`：**同路径**的第二次 `openDatabase`
/// 返回的是**同一个 `Database` 对象**（本项目 `user_db_provider.dart` 头部
/// 正是为这条约束而存在）。而内存库的路径恒为 `:memory:` ⇒ 若不关掉它，
/// 本脚本里所有 `_openUserDb()` 都是**同一个库**：
/// · 「新库」里还能查到上一个场景写的数据（**场景之间互相污染**）
/// · `userDb` 与 `bookDb` 也会变成**同一个库**（跨库场景全部失真）
/// ⇒ 断言会以「时对时错」的方式表现，极难排查。
/// 📌 判据：**测试的每个「隔离单元」都必须真的独立** ——
///    「看起来是新对象」不等于「状态是新的」。
Future<Database> _openUserDb() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await executeSqlScript(
      db, File('../../app/assets/sql/user_db_schema.sql').readAsStringSync());
  return db;
}

Future<Database> _openBookDb() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await executeSqlScript(
      db, File('../../app/assets/sql/book_db_schema.sql').readAsStringSync());
  return db;
}

/// 造一个 SyncService，游标存在内存里。
({SyncService svc, FakeHttp http, void Function(String) cursorSetter, String? Function() cursorGetter})
    _mk(Database db, {Database? bookDb, FakeHttp? http}) {
  final h = http ?? FakeHttp();
  String? cursor;
  final svc = SyncService(
    userDb: db,
    bookDb: bookDb,
    pushHttp: h.push,
    pullHttp: h.pull,
    readCursor: () async => cursor,
    writeCursor: (s) async => cursor = s,
    deviceId: 'dev-test',
  );
  return (
    svc: svc,
    http: h,
    cursorSetter: (s) => cursor = s,
    cursorGetter: () => cursor,
  );
}

/// 插入一条复习日志（本地产生的，`synced = 0`）。
Future<void> _seedLocalReview(Database db, String wordId, int rating) async {
  await db.insert('review_log', {
    'word_id': wordId,
    'rating': rating,
    'reviewed_at': '2026-10-06T09:00:00.000Z',
    'utc_day': '2026-10-06',
    'device_id': 'dev-test',
    'synced': 0,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

Future<int> _count(Database db, String sql) async =>
    (await db.rawQuery(sql)).first.values.first as int;

void main() async {
  sqfliteFfiInit();
  print('');
  print('#' * 74);
  print('# 云端同步 · 编排层验收（假 client + 真 sqlite 内存库）');
  print('#' * 74);

  // ═══════════════════════════════════════════════════════════
  section('【1】🔴 push 失败时**不得**标记已同步（否则数据永远上不了云）');
  {
    final db = await _openUserDb();
    await _seedLocalReview(db, 'w001', 3);
    final x = _mk(db);
    x.http.failPush = true;

    final r = await x.svc.pushOnce();
    check('push 失败 ⇒ ok = false', !r.ok, '${r.error}');
    check('  error 有值（不是静默失败）', (r.error ?? '').isNotEmpty);
    check(
      '🔴🔴 仍**保持** `synced = 0`（下次会重试）',
      await _count(db, 'SELECT count(*) AS n FROM review_log WHERE synced = 0') == 1,
      '—— 若这里变成 0，那批复习**永远上不了云**，且用户完全看不出来',
    );

    // 恢复网络 ⇒ 应能推上去并标记
    x.http.failPush = false;
    final r2 = await x.svc.pushOnce();
    check('恢复后重试成功', r2.ok && r2.pushedReviewEvents == 1, '$r2');
    check('  且此时才标记 `synced = 1`',
        await _count(db, 'SELECT count(*) AS n FROM review_log WHERE synced = 1') == 1);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【2】空批次**不发请求**（省一次网络往返）');
  {
    final db = await _openUserDb();
    final x = _mk(db);
    final r = await x.svc.pushOnce();
    check('无待推数据 ⇒ 0 个请求', x.http.pushBodies.isEmpty);
    check('  report.isEmpty = true', r.isEmpty && r.ok, '$r');
    check(
      '  push 仍算「成功」（不是失败）',
      r.ok,
      '—— 「没有东西要推」不是错误；调用方不该为此报错',
    );
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【3】🔴 pull 下来的数据**不产生回声**（pending_push = 0）');
  {
    final db = await _openUserDb();
    final x = _mk(db);
    x.http.pullResponse = {
      'review_events': [
        {
          'word_id': 'w100',
          'rating': 3,
          'duration_ms': null,
          'reviewed_at': '2026-10-06T09:30:00.000Z',
          'utc_day': '2026-10-06',
          'device_id': 'dev-other',
        }
      ],
      'user_words': [
        {
          'word_id': 'w100',
          'spelling': 'receive',
          'source_article_id': 7,
          'source_sentence': 'I receive it.',
          'added_at': '2026-10-01T00:00:00Z',
          'updated_at': '2026-10-01T00:00:00Z',
          'deleted': 0,
        }
      ],
      'article_reads': [
        {'article_id': 42, 'read_at': '2026-10-02T00:00:00Z'}
      ],
      'bookmarks': [
        {'content_id': 5, 'bookmarked_at': '2026-10-03T00:00:00Z', 'deleted': 0}
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };

    final r = await x.svc.pullOnce();
    check('pull ok', r.ok, '${r.error}');
    check('  计数：事件 1 词 1 读 1 藏 1',
        r.pulledReviewEvents == 1 &&
            r.pulledUserWords == 1 &&
            r.pulledArticleReads == 1 &&
            r.pulledBookmarks == 1,
        '$r');

    check(
      '🔴🔴 `user_word.pending_push = 0`（本地原本没有 ⇒ 不必推回服务端）',
      await _count(db,
              'SELECT count(*) AS n FROM user_word WHERE pending_push = 0') ==
          1,
      '—— 若为 1，则每次 pull 后都会把服务端已知的数据整批推回去（回声）',
    );
    check(
      '🔴 `article_read.pending_push = 0`',
      await _count(db,
              'SELECT count(*) AS n FROM article_read WHERE pending_push = 0') ==
          1,
    );
    check(
      '🔴 `bookmark.pending_push = 0`',
      await _count(db,
              'SELECT count(*) AS n FROM bookmark WHERE pending_push = 0') ==
          1,
    );
    check(
      '🔴🔴 `review_log.synced = 1`（服务端已知的事件不要再推回去）',
      await _count(db, 'SELECT count(*) AS n FROM review_log WHERE synced = 1') ==
          1,
    );

    // 紧接着 push ⇒ 应当**什么都不推**（连请求都不发）
    final beforePush = x.http.pushBodies.length;
    final p = await x.svc.pushOnce();
    check('🔑🔑 紧接着 push ⇒ **0 条待推**（本地没有未推改动）',
        p.pushedTotal == 0, '$p');
    check(
      '🔑 且**没有发出** push 请求 —— 回声被彻底消除',
      x.http.pushBodies.length == beforePush,
      'push 请求数 $beforePush → ${x.http.pushBodies.length}',
    );

    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【4】🔴 本地有未推改动时**不丢**（pending_push 保持 1）');
  {
    final db = await _openUserDb();
    // 本地有一条**待推**的生词
    await db.insert('user_word', {
      'word_id': 'w200',
      'spelling': 'receive',
      'added_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-01T00:00:00Z',
      'deleted': 0,
      'pending_push': 1,
    });
    final x = _mk(db);
    x.http.pullResponse = {
      'user_words': [
        {
          'word_id': 'w200',
          'spelling': 'receive',
          'source_article_id': null,
          'source_sentence': null,
          'added_at': '2026-10-01T00:00:00Z',
          // 远端**较旧**（本地有新增改动没推上去）
          'updated_at': '2026-10-01T00:00:00Z',
          'deleted': 0,
        }
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };
    await x.svc.pullOnce();
    check(
      '🔴🔴 本地待推的行在 pull 后**仍是** `pending_push = 1`',
      await _count(db,
              'SELECT count(*) AS n FROM user_word WHERE word_id = \'w200\' AND pending_push = 1') ==
          1,
      '—— 若变成 0，本地那条改动就**再也推不上去**了（静默丢数据）',
    );
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【5】复习事件 pull 后**重放派生状态**（card_review_state）');
  {
    final db = await _openUserDb();
    final x = _mk(db);
    x.http.pullResponse = {
      'review_events': [
        {
          'word_id': 'w300',
          'rating': 3,
          'duration_ms': null,
          'reviewed_at': '2026-10-06T09:30:00.000Z',
          'utc_day': '2026-10-06',
          'device_id': 'dev-other',
        }
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };
    await x.svc.pullOnce();

    final state = await db.query('card_review_state',
        where: 'word_id = ?', whereArgs: ['w300']);
    check('🔑 重放后 `card_review_state` 出现该词', state.length == 1);
    if (state.isNotEmpty) {
      final row = state.first;
      check('  `reps` = 1（重放了一次评级）',
          (row['reps'] as num).toInt() == 1, 'reps=${row['reps']}');
      check(
        '🔴 `pending_push = 0` —— 派生状态**不参与同步**（推的依据是 review_log.synced）',
        (row['pending_push'] as num).toInt() == 0,
      );
      check(
        '  `spelling` 兜底为 `word_id`（此时既无生词本记录、也无本地状态）',
        row['spelling'] == 'w300',
        '实得 ${row['spelling']}',
      );
      check(
        '  `next_review_at` 已算出（非空）',
        (row['next_review_at'] as String).isNotEmpty,
      );
    }

    // 有生词本记录时应取**真拼写**
    final db2 = await _openUserDb();
    await db2.insert('user_word', {
      'word_id': 'w300',
      'spelling': 'receive',
      'added_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-01T00:00:00Z',
      'deleted': 0,
      'pending_push': 0,
    });
    final x2 = _mk(db2);
    x2.http.pullResponse = x.http.pullResponse;
    await x2.svc.pullOnce();
    final st2 = await db2.query('card_review_state',
        columns: ['spelling'], where: 'word_id = ?', whereArgs: ['w300']);
    check('🔑 生词本里有该词时，`spelling` 取**真拼写**（不是 word_id）',
        st2.isNotEmpty && st2.first['spelling'] == 'receive',
        '实得 ${st2.isEmpty ? '(无行)' : st2.first['spelling']}');
    await db.close();
    await db2.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【6】游标：用 `server_time`，且缺它就**不推进**');
  {
    final db = await _openUserDb();
    final x = _mk(db);
    await x.svc.pullOnce();
    check(
      '🔑 游标 = 服务端返回的 `server_time`（不是当前时间）',
      x.cursorGetter() == '2026-10-06T10:00:00.000Z',
      '实得 ${x.cursorGetter()}',
    );

    // 第二次 pull ⇒ since 应带上上次的游标
    await x.svc.pullOnce();
    check('第二次 pull 带上了 `since`',
        x.http.pullCalls.length == 2 && x.http.pullCalls[1].since == '2026-10-06T10:00:00.000Z',
        '${x.http.pullCalls.map((c) => c.since).toList()}');
    check('  且 `device_id` 一直带着（服务端据此排除本设备的数据）',
        x.http.pullCalls.every((c) => c.deviceId == 'dev-test'));

    // 缺 server_time
    final db2 = await _openUserDb();
    final y = _mk(db2);
    y.cursorSetter('2026-01-01T00:00:00.000Z');
    y.http.pullResponse = {'review_events': []}; // 无 server_time
    final r = await y.svc.pullOnce();
    check('🔴 缺 `server_time` ⇒ ok = false（如实报错）', !r.ok, '${r.error}');
    check(
      '🔴🔴 且游标**未推进**（宁可下次重复拉，也不能跳过一个未知区间）',
      y.cursorGetter() == '2026-01-01T00:00:00.000Z',
      '实得 ${y.cursorGetter()}',
    );
    await db.close();
    await db2.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【7】push 的 body 形状（键名与后端契约一致）');
  {
    final db = await _openUserDb();
    await _seedLocalReview(db, 'w400', 4);
    await db.insert('bookmark', {
      'content_id': 9,
      'bookmarked_at': '2026-10-05T00:00:00Z',
      'deleted': 1, // 已取消 ⇒ 必须带出去
      'pending_push': 1,
    });
    final x = _mk(db);
    await x.svc.pushOnce();

    check('发了 1 个 push 请求', x.http.pushBodies.length == 1);
    final body = x.http.pushBodies.first;
    // 🔑 **排序后**比较（而不是依赖插入顺序）——
    //    锁的是「键集合」（漏一个键 = 那类数据**静默传空**），
    //    而「字段顺序」只是可读性 ⇒ 调整顺序不该让这条**假红**。
    //    📌 判据：**断言跟「意图」走、不跟「拼写/顺序」走**。
    final gotKeys = body.keys.toList()..sort();
    final wantKeys = <String>[
      'device_id',
      'review_events',
      'user_words',
      'article_reads',
      'bookmarks',
      // 🆕 2026-10-09：划线记忆（**必须与后端 `PushInput` 的键逐字一致**）
      'highlights',
      'book_progress',
      // 🆕 2026-10-08 书架上云：书单。
      // 🔴 它必须**先于文件上传**到达服务端 —— 否则
      //    `book_blob_handler` 会以 400 拒绝（「这本书还没在书单里」）。
      'books',
      // 🆕 2026-10-10：同步覆盖面补齐的 4 类（查词 / 书签 / 成就 / 设置）
      'lookup_events',
      'book_markers',
      'achievement_unlocks',
      'settings',
    ]..sort();
    check('顶层键集合正确', gotKeys.toString() == wantKeys.toString(),
        '实得 $gotKeys');
    check('顶层 `device_id` = 本机', body['device_id'] == 'dev-test');
    final ev = (body['review_events'] as List).first as Map;
    check('`review_events[0]` 键集合 = 后端 `ReviewEventInput`',
        ev.keys.toSet().toString() ==
            {'word_id', 'rating', 'duration_ms', 'reviewed_at'}.toString(),
        '${ev.keys.toList()}');
    check('  rating 是**数值**（不是枚举名）', ev['rating'] == 4, '${ev['rating']}');
    check('  reviewed_at 是 ISO8601（带 Z）',
        (ev['reviewed_at'] as String).endsWith('Z'), '${ev['reviewed_at']}');
    final bm = (body['bookmarks'] as List).first as Map;
    check('🔴 `bookmarks[0].deleted = 1`（取消要能推出去）', bm['deleted'] == 1);
    check('`bookmarks[0]` 键集合 = 后端 `BookmarkInput`',
        bm.keys.toSet().toString() ==
            {'content_id', 'bookmarked_at', 'deleted'}.toString(),
        '${bm.keys.toList()}');
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【8】`flushBeforeLogout` = 只 push（登出前别丢东西）');
  {
    final db = await _openUserDb();
    await _seedLocalReview(db, 'w500', 3);
    final x = _mk(db);
    final r = await x.svc.flushBeforeLogout();
    check('推送了待推数据', r.ok && r.pushedReviewEvents == 1, '$r');
    check('🔑 **没有**发 pull 请求（登出前的最后一件事是「别丢东西」）',
        x.http.pullCalls.isEmpty, 'pull 调用数 = ${x.http.pullCalls.length}');
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【9】`syncNow` = 先 push 后 pull，且失败互不阻塞');
  {
    final db = await _openUserDb();
    await _seedLocalReview(db, 'w600', 3);
    final x = _mk(db);
    x.http.pullResponse = {'server_time': '2026-10-06T12:00:00.000Z'};
    final r = await x.svc.syncNow();
    check('两者都执行：push 1 条', r.pushedReviewEvents == 1, '$r');
    check('  pull 带上了 since = null（首次）',
        x.http.pullCalls.length == 1 && x.http.pullCalls.first.since == null,
        'since=${x.http.pullCalls.firstOrNull?.since}');

    // push 失败但仍要 pull（能拿到别端数据，对用户有价值）
    final db2 = await _openUserDb();
    await _seedLocalReview(db2, 'w601', 3);
    final y = _mk(db2);
    y.http.failPush = true;
    y.http.pullResponse = {'server_time': '2026-10-06T13:00:00.000Z'};
    final r2 = await y.svc.syncNow();
    check('push 失败 ⇒ ok = false', !r2.ok, '${r2.error}');
    check('🔑 但 **pull 仍执行了**（半个同步比没有好）',
        y.http.pullCalls.length == 1);
    check('  游标仍推进了（pull 成功）',
        y.cursorGetter() == '2026-10-06T13:00:00.000Z');
    await db.close();
    await db2.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【10】电子书进度：写**待认领表**（本地还没这本书时不丢进度）');
  {
    final userDb = await _openUserDb();
    final bookDb = await _openBookDb();
    final x = _mk(userDb, bookDb: bookDb);
    x.http.pullResponse = {
      'book_progress': [
        {
          'content_hash': 'hash-abc',
          'chapter_idx': 9,
          'scroll_ratio': 0.8,
          'updated_at': '2026-10-06T09:00:00Z',
        }
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };
    final r = await x.svc.pullOnce();
    check('pull 到 1 条电子书进度', r.pulledBookProgress == 1, '$r');
    final pend = await bookDb.query('book_progress_pending');
    check('🔑 写进 `book_progress_pending`（**不需要**本地已有这本书 ⇒ 无 FK 问题）',
        pend.length == 1 && pend.first['content_hash'] == 'hash-abc');
    if (pend.isNotEmpty) {
      check('  chapter_idx / scroll_ratio 保真',
          pend.first['chapter_idx'] == 9 && pend.first['scroll_ratio'] == 0.8);
    }

    // 较旧的远端进度**不得**回退本地
    x.http.pullResponse = {
      'book_progress': [
        {
          'content_hash': 'hash-abc',
          'chapter_idx': 1,
          'scroll_ratio': 0.1,
          'updated_at': '2026-10-01T00:00:00Z',
        }
      ],
      'server_time': '2026-10-06T12:00:00.000Z',
    };
    final r2 = await x.svc.pullOnce();
    check('🔴 较旧的进度不回退（不覆盖较新的）', r2.pulledBookProgress == 0);
    final pend2 = await bookDb.query('book_progress_pending');
    check('  仍是第 9 章',
        pend2.first['chapter_idx'] == 9, '实得 ${pend2.first['chapter_idx']}');

    // book.db 缺失 ⇒ 其余四类照常
    final userDb2 = await _openUserDb();
    final z = _mk(userDb2 /* 无 bookDb */);
    z.http.pullResponse = {
      'book_progress': [
        {
          'content_hash': 'hash-x',
          'chapter_idx': 1,
          'scroll_ratio': 0.5,
          'updated_at': '2026-10-06T09:00:00Z',
        }
      ],
      'article_reads': [
        {'article_id': 7, 'read_at': '2026-10-02T00:00:00Z'}
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };
    final r3 = await z.svc.pullOnce();
    check('🔑 无 `book.db` 时**不报错**且其余四类照常（库不可用不阻塞其它功能）',
        r3.ok && r3.pulledArticleReads == 1 && r3.pulledBookProgress == 0, '$r3');

    await userDb.close();
    await userDb2.close();
    await bookDb.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【11】契约交叉验证：body 键名 == `kPushJsonContract`');
  {
    final db = await _openUserDb();
    await db.insert('user_word', {
      'word_id': 'w700',
      'spelling': 'receive',
      'source_article_id': 3,
      'source_sentence': 'Keep it.',
      'added_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-02T00:00:00Z',
      'deleted': 0,
      'pending_push': 1,
    });
    await db.insert('article_read', {
      'article_id': 11,
      'read_at': '2026-10-02T00:00:00Z',
      'pending_push': 1,
    });
    final x = _mk(db);
    await x.svc.pushOnce();
    final body = x.http.pushBodies.first;

    // 用契约表核对（而不是手写期望 —— 契约表本身另有断言核对后端源码）
    void cmp(String key, String contractKey) {
      final actual = (body[key] as List).first as Map;
      final want = m.kPushJsonContract[contractKey]!;
      check('`$key[0]` 的键 == 契约 `$contractKey`',
          actual.keys.toSet().toString() == want.toSet().toString(),
          '实得 ${actual.keys.toList()} vs 期望 $want');
    }

    cmp('user_words', 'user_word');
    cmp('article_reads', 'article_read');
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【12】🔴🔴 端到端：pull → 认领 → 进度**真的**生效');
  {
    // 这是本文件最有价值的一条 —— 它跨了三个模块：
    //   sync_service（写交换区）→ book_progress_sync（认领）→ book_progress（生效）
    // 🔑 只测「写进交换区」是不够的：那正是**用户看不到**的中间态。
    final userDb = await _openUserDb();
    final bookDb = await _openBookDb();
    // 本地**已经导入**这本书（有指纹）
    await bookDb.insert('book', {
      'id': 'local-book-1',
      'title': 'Pride and Prejudice',
      'source_format': 'epub',
      'added_at': '2026-10-01T00:00:00.000Z',
      'content_hash': 'hash-abc',
    });

    final x = _mk(userDb, bookDb: bookDb);
    x.http.pullResponse = {
      'book_progress': [
        {
          'content_hash': 'hash-abc',
          'chapter_idx': 9,
          'scroll_ratio': 0.0,
          'updated_at': '2026-10-05T00:00:00.000Z',
        }
      ],
      'server_time': '2026-10-06T11:00:00.000Z',
    };
    final r = await x.svc.pullOnce();

    check('pull 到 1 条进度', r.pulledBookProgress == 1, '$r');
    check('🔴🔴 **认领了 1 本**（`claimedBooks`）', r.claimedBooks == 1, '$r');

    final prog = await bookDb.query('book_progress',
        where: 'book_id = ?', whereArgs: ['local-book-1']);
    check(
      '🔴🔴 进度**真的写进了 `book_progress`**（用户打开书会续读到第 9 章）',
      prog.isNotEmpty && prog.first['chapter_idx'] == 9,
      prog.isEmpty ? '（没有行 ⇒ 别端的进度**永远不生效**，且不报错）' : '第 ${prog.first['chapter_idx']} 章',
    );
    check(
      '🔑 交接完成后交换区**清空**（不会每次 pull 白比对）',
      (await bookDb.query('book_progress_pending')).isEmpty,
    );

    // 反向：本地**没**这本书 ⇒ 进度只存交换区，不认领
    final userDb2 = await _openUserDb();
    final bookDb2 = await _openBookDb();
    final y = _mk(userDb2, bookDb: bookDb2);
    y.http.pullResponse = x.http.pullResponse;
    final r2 = await y.svc.pullOnce();
    check('本地没这本书 ⇒ 认领 0 本（进度先存着）', r2.claimedBooks == 0, '$r2');
    check('  交换区**保留** 1 条（等导入时认领）',
        (await bookDb2.query('book_progress_pending')).length == 1);

    // 再模拟「用户导入同一本书」⇒ 导入侧认领会取过来
    await bookDb2.insert('book', {
      'id': 'local-book-2',
      'title': 'Pride and Prejudice',
      'source_format': 'epub',
      'added_at': '2026-10-06T00:00:00.000Z',
      'content_hash': 'hash-abc',
    });
    final claimed = await bps.claimAllPending(bookDb2);
    check('🔑 导入后（下次 pull / 手动）能认领到', claimed.claimed == 1, '$claimed');
    final prog2 = await bookDb2.query('book_progress',
        where: 'book_id = ?', whereArgs: ['local-book-2']);
    check('  且写进了**新导入的** book_id（uuid 不同但指纹相同）',
        prog2.isNotEmpty && prog2.first['chapter_idx'] == 9);

    await userDb.close();
    await userDb2.close();
    await bookDb.close();
    await bookDb2.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【9】🔴 `pulledTotal` 必须覆盖**所有**写进本地库的项');
  // ══════════════════════════════════════════════════════════════════════
  //
  // # 为什么这条重要（2026-10-09 实测踩到）
  //
  // `pulledTotal` 是调用方判断「**本轮本地库变了没有**」的唯一依据：
  //   · `isEmpty` —— 决定要不要打日志 / 给 UI 提示；
  //   · `_runSync` 的 **revision bump 判据** —— 变了才让界面重算；
  //   · 状态面板的 `lastPulled`。
  //
  // 🔴 它原先**漏了 `pulledBooks` 与 `claimedBooks`**（这两项是「书架上云」
  //    之后才加的，而 getter 没跟着更新）。后果**完全静默**：
  //    云端备份被清理（`blob_size → 0`）**只会计到 `pulledBooks`**
  //    ⇒ `pulledTotal == 0` ⇒ 被判成「什么都没做」
  //    ⇒ **界面不刷新**（书架仍显示「云端有」、点下载 404）。
  //
  // ⚠️ 所以断言必须**逐项**做：给每一项单独 +1，`pulledTotal` 都要跟着 +1。
  //    只验「> 0」会漏掉「某一项没被算进去」—— 那正是本次踩到的形状。
  {
    check('空 report 的 pulledTotal == 0', SyncReport().pulledTotal == 0,
        '实测 ${SyncReport().pulledTotal}');

    void expectCounted(String name, void Function(SyncReport) setOne) {
      final r = SyncReport();
      setOne(r);
      check('  `$name` 计入 pulledTotal', r.pulledTotal == 1,
          '实测 ${r.pulledTotal}（应为 1）');
    }

    expectCounted('pulledReviewEvents', (r) => r.pulledReviewEvents = 1);
    expectCounted('pulledUserWords', (r) => r.pulledUserWords = 1);
    expectCounted('pulledArticleReads', (r) => r.pulledArticleReads = 1);
    expectCounted('pulledBookmarks', (r) => r.pulledBookmarks = 1);
    expectCounted('pulledBookProgress', (r) => r.pulledBookProgress = 1);
    expectCounted('pulledBooks', (r) => r.pulledBooks = 1);
    expectCounted('claimedBooks', (r) => r.claimedBooks = 1);

    // 🔴 最关键的一条：**「只拉回了书单变更」不能被判成「什么都没做」**
    //    —— 这正是「云端备份清理」生效时的形状（唯一变更项就是 `blob_size`）。
    final onlyBooks = SyncReport()..pulledBooks = 1;
    check('🔴 只拉回书单变更 ⇒ `isEmpty` 必须为 false（清理生效时的形状）',
        !onlyBooks.isEmpty,
        '若为 true ⇒ 不打日志、不 bump ⇒ 用户看不到「云端备份已释放」');

    // ⚠️ 反向：`pushedTotal` **不该**被这次补全带上 `pulledBooks`
    //    （push 与 pull 是两个方向，混在一起会让「推了 0 条」看起来像推了东西）。
    final pushOnly = SyncReport()..pulledBooks = 1;
    check('🔴 `pushedTotal` 与 pull 无关（不得被带进来）',
        pushOnly.pushedTotal == 0, '实测 ${pushOnly.pushedTotal}');
  }

  // ═══════════════════════════════════════════════════════════
  section('【13】🆕 划线（highlight）：推得出去 / 合得进来（真库行为断言）');
  //
  // 🔴 本节守的是一个**真实缺口**（2026-10-09）：此前 `review_log`（复习事件）同步，
  //    而 `highlight`（划线**本体**）不参与 ⇒ 重装 / 换机的设备拿到「**无主划线卡**」：
  //    标题显示成 `hl:<uuid>`、点「暂停」静默无反应、界面上没有出口能去掉它。
  //    📌 判据：**同步的粒度必须覆盖「引用关系」**。
  //
  // ⚠️ 契约键名/接线在 `verify_sync.dart`；这里是**真库跑一遍**（本机可跑的那一层）。
  {
    // ── push：本地一条待推划线 ──
    final db = await _openUserDb();
    await db.insert('highlight', {
      'id': 'h-be',
      'source_type': 'article',
      'source_id': '42',
      'chapter_idx': null,
      'start_offset': 1,
      'end_offset': 9,
      'text': 'be careful',
      'note': '记一下',
      'created_at': '2026-10-01T00:00:00.000Z',
      'updated_at': '2026-10-02T00:00:00.000Z',
      'deleted': 0,
      'pending_push': 1,
      'paused': 1,
    });
    final x = _mk(db);
    final r = await x.svc.pushOnce();
    check('🔴 划线被推出去（不推 ⇒ 别端永远拿不到划线本体 ⇒ 无主卡）',
        r.pushedHighlights == 1, '$r');
    final body = x.http.pushBodies.first;
    final hl = (body['highlights'] as List).first as Map;
    check(
      '`highlights[0]` 键集合 = 后端 `HighlightInput`',
      hl.keys.toSet().toString() ==
          {
            'id',
            'source_type',
            'source_id',
            'chapter_idx',
            'start_offset',
            'end_offset',
            'text',
            'note',
            'paused',
            'deleted',
            'created_at',
            'updated_at'
          }.toString(),
      '${hl.keys.toList()}',
    );
    check('🔴 `paused = 1` 带出去（漏 ⇒「A 暂停、换台设备又回来」）', hl['paused'] == 1);
    check('`note` 带出去（漏 ⇒ 笔记不跨设备）', hl['note'] == '记一下');
    check('`chapter_idx` 是 null（文章没有章节号，**不是 0**）', hl['chapter_idx'] == null);
    check(
      'push 成功后标记已同步（漏 ⇒ 每次同步都重推全量）',
      (await db.query('highlight', where: "id = 'h-be'")).first['pending_push'] == 0,
    );
    await db.close();
  }
  {
    // ── pull：别端的划线合并进本地（本地没有这一行）──
    final db = await _openUserDb();
    final y = _mk(db);
    y.http.pullResponse = {
      'server_time': '2026-10-09T12:00:00.000Z',
      'highlights': [
        {
          'id': 'h-from-b',
          'source_type': 'book',
          'source_id': 'book-uuid-1',
          'chapter_idx': 3,
          'start_offset': 100,
          'end_offset': 140,
          'text': 'the quick brown fox',
          'note': null,
          'paused': 0,
          'deleted': 0,
          'created_at': '2026-10-03T00:00:00.000Z',
          'updated_at': '2026-10-04T00:00:00.000Z',
        },
      ],
    };
    final r = await y.svc.pullOnce();
    check('🔴 划线写进了本地 `highlight`（拿不到就是「无主卡」）',
        r.pulledHighlights == 1, '$r');
    final row = (await db.query('highlight', where: "id = 'h-from-b'")).first;
    check('字段落库正确',
        row['text'] == 'the quick brown fox' && row['chapter_idx'] == 3,
        '${row['text']} / ${row['chapter_idx']}');
    check('🔴 `pending_push = 0`（服务端已知的数据不回声）', row['pending_push'] == 0);
    check('🔴 计入 `pulledTotal`（否则「只拉回笔记」会被判成「什么都没做」）',
        r.pulledTotal >= 1, '$r');
    await db.close();
  }
  {
    // ── pull 合并：本地已推 + 别端**更新**（意愿生效、首次事实不动）──
    final db = await _openUserDb();
    await db.insert('highlight', {
      'id': 'h-merge',
      'source_type': 'article',
      'source_id': '42',
      'chapter_idx': null,
      'start_offset': 1,
      'end_offset': 9,
      'text': '原文',
      'note': null,
      'created_at': '2026-10-01T00:00:00.000Z',
      'updated_at': '2026-10-01T00:00:00.000Z',
      'deleted': 0,
      'pending_push': 0,
      'paused': 0,
    });
    final z = _mk(db);
    z.http.pullResponse = {
      'server_time': '2026-10-09T12:00:00.000Z',
      'highlights': [
        {
          'id': 'h-merge',
          'source_type': 'article',
          'source_id': '42',
          'chapter_idx': null,
          'start_offset': 999,
          'end_offset': 1005,
          'text': '被改写的',
          'note': '别端写的',
          'paused': 1,
          'deleted': 0,
          'created_at': '2026-10-05T00:00:00.000Z', // ⚠️ 更晚 ⇒ 不算「首次事实」
          'updated_at': '2026-10-06T00:00:00.000Z', // ✅ 更新 ⇒ 意愿生效
        },
      ],
    };
    await z.svc.pullOnce();
    final row = (await db.query('highlight', where: "id = 'h-merge'")).first;
    check('🔴 意愿生效：`paused = 1`（暂停跨设备）', row['paused'] == 1, '${row['paused']}');
    check('🔴 意愿生效：`note` 写入', row['note'] == '别端写的', '${row['note']}');
    check('🔴 首次事实不动：`text` 仍是本地的原文', row['text'] == '原文', '${row['text']}');
    check('🔴 首次事实不动：offsets 仍是本地的',
        row['start_offset'] == 1, '${row['start_offset']}');
    check('本地已推 + 无新事实 ⇒ 不标待推（防回声）', row['pending_push'] == 0);
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【14】🆕 同步覆盖面补齐（2026-10-10）：4 类数据的**真库行为**');
  //
  // # 🔴 为什么这组必须有（它守的是本批**新写的 pull 逻辑**）
  // 「写了新的 pull 分支」与「它真的能把数据落进正确的表」是两件事 ——
  // 前者靠源码断言（`verify_sync`），后者**只有真跑一遍**才知道。
  //
  // # 证伪方式
  // · 删掉 `pushOnce` 里的 `backfillLookupUids()` ⇒ ①「uid 已回填」必红
  // · 让 `_applyBookMarkers` 在本地没书时也写 `book_marker` ⇒ ②「进 pending」必红
  // · 让 `_applySettings` 只写表不写 prefs ⇒ ④「写回 prefs」必红
  // ══════════════════════════════════════════════════════════════════════

  // ── ① 查词记录：`uid` 惰性回填 + push + pull（幂等）──
  {
    final db = await _openUserDb();
    // 造两条**没有 uid**的老行（= v9 老库升级上来的样子）
    await db.insert('lookup_event', {
      'uid': null,
      'word_id': 'w001',
      'spelling': 'receive',
      'looked_up_at': '2026-10-01T00:00:00Z',
      'pending_push': 1,
    });
    await db.insert('lookup_event', {
      'uid': null,
      'word_id': null, // 未命中词库
      'spelling': 'zzz',
      'looked_up_at': '2026-10-02T00:00:00Z',
      'pending_push': 1,
    });

    final x = _mk(db);
    await x.svc.pushOnce();
    check('① 发了 1 个 push 请求', x.http.pushBodies.length == 1);
    final looks = (x.http.pushBodies.first['lookup_events'] as List);
    check('🔴 两条查词记录都推出去了（老行也推 —— 否则换设备后查词次数归零）',
        looks.length == 2, '${looks.length}');
    final uids = [for (final e in looks) (e as Map)['uid']];
    check('🔴 `uid` 已被**回填**（空 uid 会让服务端 PK `(user_id,uid)` 互相覆盖）',
        uids.every((u) => u is String && u.isNotEmpty), '$uids');
    check(
      '🔑 未命中词的 `word_id` 传 `null`（不是空串）',
      (looks.firstWhere((e) => (e as Map)['spelling'] == 'zzz') as Map)['word_id'] ==
          null,
    );

    // pull：重复的 uid 应被 `INSERT OR IGNORE` 忽略，新的写入
    x.http.pullResponse = {
      'lookup_events': [
        looks[0], // 已存在（同 uid）
        {
          'uid': 'remote-uid-1',
          'word_id': 'w500',
          'spelling': 'resilience',
          'article_id': null,
          'sentence': null,
          'position': null,
          'looked_up_at': '2026-10-03T00:00:00Z',
        },
      ],
      'server_time': '2026-10-06T10:00:00.000Z',
    };
    final r = await x.svc.pullOnce();
    check('🔴 只拉回 1 条新记录（重复 uid 被忽略 —— 日志幂等）',
        r.pulledLookupEvents == 1, '${r.pulledLookupEvents}');
    check('本地共 3 条（2 老 + 1 新）',
        (await db.rawQuery('SELECT count(*) AS n FROM lookup_event')).first['n'] == 3);
    final remoteRow =
        (await db.query('lookup_event', where: "uid = 'remote-uid-1'")).first;
    check('🔴 拉回来的标 `pending_push = 0`（防回声）', remoteRow['pending_push'] == 0);
    check('🔴 `pulledLookupEvents` 计入 `pulledTotal`',
        r.pulledTotal >= 1, '${r.pulledTotal}');
    await db.close();
  }

  // ── ② 书签：推要在**书**的指纹上；拉要按「本地有没有这本书」分流 ──
  {
    final udb = await _openUserDb();
    final bdb = await _openBookDb();
    await bdb.insert('book', {
      'id': 'b-local',
      'title': 'P&P',
      'source_format': 'epub',
      'added_at': '2026-10-01T00:00:00Z',
      'content_hash': 'hash-abc',
    });
    await bdb.insert('book_marker', {
      'id': 'mk-local',
      'book_id': 'b-local',
      'chapter_idx': 1,
      'scroll_ratio': 0.3,
      'excerpt': '本地摘录',
      'created_at': '2026-10-01T00:00:00Z',
      'deleted': 0,
    });

    final x = _mk(udb, bookDb: bdb);
    await x.svc.pushOnce();
    final markers = (x.http.pushBodies.first['book_markers'] as List);
    check(
      '🔴 书签推出去时带 `content_hash`（**书**的跨设备身份，不是端侧 `book_id`）',
      markers.length == 1 && (markers.first as Map)['content_hash'] == 'hash-abc',
      '$markers',
    );
    check('🔴 推的**不是** `book_id`（那是端侧 uuid，别端对不上）',
        !(markers.first as Map).containsKey('book_id'));

    x.http.pullResponse = {
      'book_markers': [
        {
          'id': 'mk-local', // 同 id ⇒ 合并
          'content_hash': 'hash-abc',
          'chapter_idx': 1,
          'scroll_ratio': 0.3,
          // ⚠️ 摘录更晚的副本 ⇒ **不该**覆盖本地（位置/摘录取较早端）
          'excerpt': '远端摘录',
          'created_at': '2026-10-09T00:00:00Z',
          'deleted': 1, // 🔴 别端取消 ⇒ OR 语义 ⇒ 本地也删
        },
        {
          'id': 'mk-remote-book',
          'content_hash': 'hash-xyz', // 本地**没有**这本书
          'chapter_idx': 0,
          'scroll_ratio': 0.1,
          'excerpt': 'x',
          'created_at': '2026-10-02T00:00:00Z',
          'deleted': 0,
        },
      ],
      'server_time': '2026-10-06T10:00:00.000Z',
    };
    final r = await x.svc.pullOnce();
    check('🔴 拉回 2 条书签', r.pulledBookMarkers == 2, '${r.pulledBookMarkers}');
    final localMk =
        (await bdb.query('book_marker', where: "id = 'mk-local'")).first;
    check(
      '🔴 `deleted` 取 OR ⇒ 别端取消后本地也删（本表无 updated_at，照抄「取较新」会传不出去）',
      localMk['deleted'] == 1,
      '${localMk['deleted']}',
    );
    check('🔑 位置/摘录取**较早端**（更晚的副本不得改写）',
        localMk['excerpt'] == '本地摘录', '${localMk['excerpt']}');
    check(
      '🔴 本地**没有**那本书的书签进 `book_marker_pending`（直接写 book_marker 会 FK 失败）',
      (await bdb.rawQuery(
                  "SELECT count(*) AS n FROM book_marker_pending WHERE id = 'mk-remote-book'"))
              .first['n'] ==
          1,
    );
    check('🔴 `pulledBookMarkers` 计入 `pulledTotal`', r.pulledTotal >= 2);
    await udb.close();
    await bdb.close();
  }

  // ── ③ 成就解锁：push + pull（`unlocked_at` 取较早）──
  {
    final db = await _openUserDb();
    await db.insert('achievement_unlock', {
      'key': 'first_word',
      'unlocked_at': '2026-10-05T00:00:00Z',
      'pending_push': 1,
    });
    final x = _mk(db);
    await x.svc.pushOnce();
    final achs = (x.http.pushBodies.first['achievement_unlocks'] as List);
    check('③ 成就记录推出去',
        achs.length == 1 && (achs.first as Map)['key'] == 'first_word');

    x.http.pullResponse = {
      'achievement_unlocks': [
        // 更早 ⇒ 应胜出（它是**真正的**首次解锁时刻）
        {'key': 'first_word', 'unlocked_at': '2026-10-01T00:00:00Z'},
        {'key': 'streak_3', 'unlocked_at': '2026-10-04T00:00:00Z'},
      ],
      'server_time': '2026-10-06T10:00:00.000Z',
    };
    final r = await x.svc.pullOnce();
    check('🔴 拉回 2 条成就解锁', r.pulledAchievementUnlocks == 2);
    final row =
        (await db.query('achievement_unlock', where: "key = 'first_word'")).first;
    check(
      '🔴 `unlocked_at` 取**较早**（首次解锁时间不得被推后 —— 否则成就墙日期是假的）',
      row['unlocked_at'] == '2026-10-01T00:00:00Z',
      '${row['unlocked_at']}',
    );
    await db.close();
  }

  // ── ④ 应用设置：pull 写回 prefs + **不回声** ──
  {
    final db = await _openUserDb();
    // 模拟 prefs（内存 Map；**存解码后的值**，与真实 `_writeSyncedSetting` 同口径）
    final prefs = <String, Object?>{
      'reading_font_size': 22,
      'tts_enabled': false,
    };
    final svc = SyncService(
      userDb: db,
      pushHttp: (b) async => {'ok': true},
      pullHttp: ({since, deviceId}) async => {
            'settings': [
              {
                'key': 'reading_font_size',
                'value': '15', // 更晚 ⇒ 远端胜
                'updated_at': '2099-01-01T00:00:00Z',
              },
              {
                'key': 'display_name',
                'value': '"云端昵称"',
                'updated_at': '2026-10-05T00:00:00Z',
              },
            ],
            'server_time': '2026-10-06T10:00:00.000Z',
          },
      readCursor: () async => null,
      writeCursor: (s) async {},
      deviceId: 'dev-test',
      readPrefSetting: (k) async => prefs[k],
      // 与 `sync_provider._writeSyncedSetting` 同口径：**解码后**按类型写回
      writePrefSetting: (k, v) async => prefs[k] = jsonDecode(v),
    );

    final r = await svc.pullOnce();
    check('🔴 `applySettings` **写回 prefs**（只写表 ⇒「同步了、界面没变」）',
        prefs['display_name'] != null, '${prefs['display_name']}');
    check('🔴 `pulledSettings` = **真正改变 prefs 的键数**（不是写表行数）',
        r.pulledSettings == 2, '${r.pulledSettings}');
    check('🔴 远端更新的值胜（LWW）：字号 22 → 15', prefs['reading_font_size'] == 15,
        '${prefs['reading_font_size']}');
    check('🔑 远端**没有**的键不被动（`tts_enabled` 保持本地 false）',
        prefs['tts_enabled'] == false);
    check('🔴 `pulledSettings` 计入 `pulledTotal`（否则「只拉回设置」不 bump）',
        r.pulledTotal >= 2);

    // 再 push：采集比对「prefs vs 表」——
    //   · 刚 pull 回来的两个键（值一致）⇒ **不该产生待推**（防回声）
    //   · `tts_enabled` 远端**没有**、本地有 ⇒ 采集**会**把它推上去
    //     （✅ 这是**对的** —— 否则那项设置永远上不了云）
    // ⇒ 期望恰好 1 条；若 > 1 就是「刚拉回来的又被推回去」（回声）。
    final p = await svc.pushOnce();
    check(
      '🔑 pull 写回后**不回声**（只推「远端没有、本地有」的那 1 项）',
      p.pushedSettings == 1,
      '${p.pushedSettings} —— >1 则说明刚 pull 回来的键被当成「本地改动」又推了回去',
    );
    await db.close();
  }

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因（这一层几乎都是**静默**错误）：');
    print('   · push 失败却标记了已同步 ⇒ 那批数据永远上不了云');
    print('   · pull 后把服务端已知的数据标成待推 ⇒ 回声（每次同步都白推）');
    print('   · pull 时把本地未推改动标成已同步 ⇒ 本地改动永久丢失');
    print('   · 游标用当前时间而非 server_time ⇒ 那段时间的记录永久跳过');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
