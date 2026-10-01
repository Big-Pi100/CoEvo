// CoEvo · 发版收敛（`ext:` → `word.id`）验收 —— **跑真库 + 构造老库**
//
// 跑法：cd scripts/query_verify && dart run bin/verify_word_id_convergence.dart
//
// # 为什么必须验（这件事**会改用户学习数据**）
// 收敛把三张表的 `word_id` 改掉。改错的后果：
// · **未回流的词被收敛** → 那个词的卡取不到了（缓存被删 + 新库没有它）
// · **顺序反了** → 缓存先没、数据还指着 `ext:` → 取不到卡
// · **冲突合并取错行** → 用户的复习进度（`reps`）或「第一次收它的时间」被抹掉
// 三种都**不报错**，只是用户的记录慢慢变错。
//
// # 关键：**用构造库演练**（真实端侧现在没有 `ext:` 数据）
// `ext:` 是 A2 才落地的，白哥真机上还没有 → 只能**造一个含 `ext:` 的老库**
// （这也正是「迁移类逻辑不能用新库验」那条判据 —— 全新库里这条路径**根本不执行**）。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/external_word_id.dart';
import '../../../app/lib/services/user_db.dart' show splitSqlStatements;
import '../../../app/lib/services/word_id_convergence.dart';

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

void eq(String label, Object? actual, Object? expected) => check(label,
    actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

Future<Database> freshDb(String path, String schema) =>
    databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          for (final s in splitSqlStatements(schema)) {
            await db.execute(s);
          }
        },
      ),
    );

/// 建一个「含词库外生词」的 `user.db`（= 收敛前的端侧状态）。
Future<void> seedExternal(Database db) async {
  // user_word：ext:brainstorm 与 真 id w005333（**同词两行** —— 冲突场景）
  await db.insert('user_word', {
    'word_id': 'ext:brainstorm',
    'spelling': 'brainstorm',
    // 更早 → 合并时应保留它
    'added_at': '2026-09-01T00:00:00Z',
    'source_sentence': 'She had a brainstorm.',
  });
  await db.insert('user_word', {
    'word_id': 'w005333',
    'spelling': 'brainstorm',
    'added_at': '2026-09-20T00:00:00Z',
  });
  // user_word：未回流的词（**必须原样保留**）
  await db.insert('user_word', {
    'word_id': 'ext:zzznotinlib',
    'spelling': 'zzznotinlib',
    'added_at': '2026-09-10T00:00:00Z',
  });

  // card_review_state：ext: 的 reps 更大 → 合并时应保留它
  await db.insert('card_review_state', {
    'word_id': 'ext:brainstorm',
    'spelling': 'brainstorm',
    'state': 2,
    'reps': 9,
    'next_review_at': '2026-10-05T00:00:00Z',
  });
  await db.insert('card_review_state', {
    'word_id': 'w005333',
    'spelling': 'brainstorm',
    'state': 1,
    'reps': 2,
    'next_review_at': '2026-10-02T00:00:00Z',
  });
  await db.insert('card_review_state', {
    'word_id': 'ext:zzznotinlib',
    'spelling': 'zzznotinlib',
    'state': 0,
    'reps': 0,
    'next_review_at': '2026-10-01T00:00:00Z',
  });

  // review_log：一条不撞车 + 一条**撞车**（同 reviewed_at+device_id 已存在于 w005333）
  await db.insert('review_log', {
    'word_id': 'ext:brainstorm',
    'rating': 3,
    'reviewed_at': '2026-09-30T10:00:00Z',
    'utc_day': '2026-09-30',
    'device_id': 'dev-1',
  });
  await db.insert('review_log', {
    'word_id': 'w005333',
    'rating': 2,
    'reviewed_at': '2026-09-30T10:00:00Z',   // 同一时刻、同一设备 → 撞 UNIQUE
    'utc_day': '2026-09-30',
    'device_id': 'dev-1',
  });

  // 缓存：已回流词 + 未回流词各一份
  await db.insert('external_word_cache', {
    'spelling': 'brainstorm',
    'card_content': '{"front":"brainstorm","sections":[]}',
  });
  await db.insert('external_word_cache', {
    'spelling': 'zzznotinlib',
    'card_content': '{"front":"zzznotinlib","sections":[]}',
  });
}

Future<void> main() async {
  sqfliteFfiInit();
  final schema = File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  // ═══ 【1】纯逻辑 `planConvergence` ═══
  section('【1】纯逻辑 planConvergence（哪些可以收敛）');
  {
    // 假 resolver：只有 brainstorm 已回流
    Future<String?> res(String sp) async => sp == 'brainstorm' ? 'w005333' : null;

    final plan = await planConvergence(
      externalWordIds: ['ext:brainstorm', 'ext:zzznotinlib', 'w000001'],
      resolve: res,
    );
    eq('只收敛已回流的那个', plan.length, 1);
    eq('…fromId 是合成 id', plan.first.fromId, 'ext:brainstorm');
    eq('…toId 是词库 id', plan.first.toId, 'w005333');
    eq('…spelling 由 fromId 解析（删缓存要用）', plan.first.spelling, 'brainstorm');

    // 🔴 幂等的基础：收敛后不再有 ext: 候选 → 空计划
    final empty = await planConvergence(externalWordIds: [], resolve: res);
    eq('无候选 → 空计划', empty.length, 0);

    // 畸形数据（ext: 后为空）不能被当成候选
    final malformed = await planConvergence(
        externalWordIds: ['ext:', 'w000001'], resolve: res);
    eq('畸形/非 ext: 一律跳过', malformed.length, 0);

    // 去重（三表并集会让同一 id 出现多次）
    final dup = await planConvergence(
        externalWordIds: ['ext:brainstorm', 'ext:brainstorm', 'ext:brainstorm'],
        resolve: res);
    eq('🔑 同一 id 出现多次只收敛一次', dup.length, 1);
  }

  // ═══ 【2】🔴 端到端：构造老库 → 收敛 → 断言 ═══
  section('【2】端到端收敛（构造含 ext: 的老库）');
  {
    final dir = await Directory.systemTemp.createTemp('coevo_conv_');
    final db = await freshDb('${dir.path}/user.db', schema);
    await seedExternal(db);

    eq('前提：user_word 有 3 行', _n(await db.rawQuery(
        'SELECT count(*) AS n FROM user_word')), 3);
    eq('前提：含 2 个 ext: 词', (await externalWordIdsIn(db)).length, 2);

    // 模拟「新词库」：只有 brainstorm 回流了（拿到真 id）
    Future<String?> resolve(String sp) async =>
        sp == 'brainstorm' ? 'w005333' : null;

    final candidates = await externalWordIdsIn(db);
    final pairs = await planConvergence(
        externalWordIds: candidates, resolve: resolve);
    eq('可收敛 1 个（zzznotinlib 未回流 → 保留）', pairs.length, 1);

    final r = await convergeExternalWordIds(userDb: db, pairs: pairs);
    eq('converged = 1', r.converged, 1);
    eq('user_word 发生 1 次合并', r.mergedUserWord, 1);
    eq('card_review_state 发生 1 次合并', r.mergedReviewState, 1);
    eq('🔴 review_log 丢弃 1 条撞车行', r.droppedReviewLog, 1);
    eq('清掉 1 条缓存', r.clearedCache, 1);

    // ── user_word ──
    check('🔴 `ext:brainstorm` 已不存在',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM user_word WHERE word_id='ext:brainstorm'")) ==
            0);
    final uw = await db.query('user_word', where: 'word_id = ?', whereArgs: ['w005333']);
    eq('合并后 w005333 只剩 1 行', uw.length, 1);
    check('🔑 保留了 `added_at` **更早**的那行（「第一次收它」不能被改错）',
        uw.first['added_at'] == '2026-09-01T00:00:00Z',
        '${uw.first['added_at']}');
    check('🔑 连带保住了那行的 `source_sentence`（首次语境）',
        uw.first['source_sentence'] == 'She had a brainstorm.',
        '${uw.first['source_sentence']}');

    // ── card_review_state ──
    final crs = await db.query('card_review_state',
        where: 'word_id = ?', whereArgs: ['w005333']);
    eq('合并后只剩 1 行', crs.length, 1);
    eq('🔴 保留了 `reps` **更大**的那行（学得更多的 = 真实进度）',
        (crs.first['reps'] as num).toInt(), 9);
    eq('…`state` 也跟着那行（FSRS 三元组必须自洽，不能混搭）',
        (crs.first['state'] as num).toInt(), 2);

    // ── review_log ──
    final logs = await db.query('review_log', where: 'word_id = ?', whereArgs: ['w005333']);
    eq('🔴 撞车的重复事件被丢弃 → 只剩 1 条', logs.length, 1);
    eq('…留下的是**原本就在 to 上的**那条（rating=2）',
        (logs.first['rating'] as num).toInt(), 2);
    check('🔴 不再有任何 ext: 的 review_log',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM review_log WHERE word_id LIKE 'ext:%'")) ==
            0);

    // ── 未回流的词：**原样保留** ──
    eq('🔴 未回流的词仍在 user_word（没被误收敛）',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM user_word WHERE word_id='ext:zzznotinlib'")),
        1);
    eq('🔴 未回流的词仍在 card_review_state',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM card_review_state WHERE word_id='ext:zzznotinlib'")),
        1);
    eq('🔴 未回流的词**缓存仍在**（删了它就没卡了）',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM external_word_cache WHERE spelling='zzznotinlib'")),
        1);
    eq('已回流词的缓存**已清**', _n(await db.rawQuery(
            "SELECT count(*) AS n FROM external_word_cache WHERE spelling='brainstorm'")),
        0);

    // ── 🔑 幂等：再跑一次应无事发生 ──
    final again = await planConvergence(
        externalWordIds: await externalWordIdsIn(db), resolve: resolve);
    eq('🔑 第二次候选只剩未回流的那个', (await externalWordIdsIn(db)).length, 1);
    eq('🔑 第二次收敛计划为空（幂等）', again.length, 0);
    final r2 = await convergeExternalWordIds(userDb: db, pairs: again);
    check('🔑 第二次跑零改动', !r2.didSomething && r2.clearedCache == 0);

    await db.close();
    await dir.delete(recursive: true);
  }

  // ═══ 【3】🔴 顺序：先改表、后删缓存 —— **行为验证**（不是扫源码）═══
  section('【3】🔴 顺序（注入失败 → 必须**全部回滚**）');
  {
    final dir = await Directory.systemTemp.createTemp('coevo_conv3_');
    final db = await freshDb('${dir.path}/user.db', schema);
    await seedExternal(db);

    Future<String?> resolve(String sp) async =>
        sp == 'brainstorm' ? 'w005333' : null;
    final pairs = await planConvergence(
        externalWordIds: await externalWordIdsIn(db), resolve: resolve);
    eq('前提：有 1 个可收敛的词', pairs.length, 1);

    // 🔴 在「三张表改完、即将删缓存」处注入一次失败
    var threw = false;
    try {
      await convergeExternalWordIds(
        userDb: db,
        pairs: pairs,
        beforeClearCacheHook: () => throw StateError('注入：删缓存前失败'),
      );
    } catch (_) {
      threw = true;
    }
    check('注入的失败确实抛出来了（前提）', threw);

    // 🔴 核心：**一切都没变** —— 证明「改表」与「删缓存」在同一事务
    eq('🔴 缓存**还在**（若删缓存不在此事务内，它就已经没了 → 取不到卡）',
        _n(await db.rawQuery(
            "SELECT count(*) AS n FROM external_word_cache WHERE spelling='brainstorm'")),
        1);
    eq('🔴 `user_word` 仍是 ext: 形态（改表也回滚了）',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM user_word WHERE word_id='ext:brainstorm'")),
        1);
    eq('🔴 `card_review_state` 也回滚',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM card_review_state WHERE word_id='ext:brainstorm'")),
        1);
    eq('🔴 `review_log` 也回滚（两条都还在）',
        _n(await db.rawQuery(
                "SELECT count(*) AS n FROM review_log WHERE word_id IN ('ext:brainstorm','w005333')")),
        2);

    // 🔑 且**重跑能成功**（事务回滚得干净 → 幂等的前提）
    final r = await convergeExternalWordIds(userDb: db, pairs: pairs);
    eq('注入失败后重跑 → 成功收敛 1 个', r.converged, 1);
    eq('…这次缓存真的清了', _n(await db.rawQuery(
            "SELECT count(*) AS n FROM external_word_cache WHERE spelling='brainstorm'")),
        0);

    // 🔑 第二层：**结构断言** —— 删缓存必须在**事务体内**
    //
    //    🔴 这层是被证伪逼出来的（2026-10-01）：
    //    我第一版只断言「删缓存那一句排在 `_retargetReviewLog` 之后」——
    //    然后把删缓存**移到事务外**（变成两个独立操作），**44 项仍全绿**。
    //    因为「位置在后面」与「在同一个事务里」是**两件事**。
    //
    //    🔑 而且这正是**真正危险的那一种**：删缓存在事务外 ⇒
    //       事务回滚时「表恢复了、缓存却已经被删」⇒ 数据指着 `ext:` 而缓存没了
    //       ⇒ **取不到卡**（比不收敛更糟）。
    //    📌 与 §19 同一条教训：**位置/文本断言证明不了「在同一个作用域里」** ——
    //       要切出作用域再断言。
    final src = File('../../app/lib/services/word_id_convergence.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final txAt = code.indexOf('userDb.transaction(');
    final txBody = _bracesFrom(code, txAt);
    // 哨兵：切错了「往往会切出一个仍非空但不对的区间」
    check('能切出事务体（下面断言的前提）',
        txBody.contains('_mergeUserWord(') && txBody.contains('_mergeReviewState('),
        'len=${txBody.length}');

    check('🔴 **删缓存也在事务体内**（否则事务回滚后缓存已被删 → 取不到卡）',
        txBody.contains("'external_word_cache'"));
    check('🔴 三张表的改写也都在事务体内',
        txBody.contains('_mergeUserWord(') &&
            txBody.contains('_mergeReviewState(') &&
            txBody.contains('_retargetReviewLog('));
    // 🔑 顺序作为**第二层**防线（当前单事务下顺序不影响结果 —— 事务保证原子性；
    //    但若将来有人把某步挪出事务，顺序就成了唯一防线）
    final uwAt = txBody.indexOf('_mergeUserWord(');
    final crsAt = txBody.indexOf('_mergeReviewState(');
    final logAt = txBody.indexOf('_retargetReviewLog(');
    final clearAt = txBody.lastIndexOf("'external_word_cache'");
    check('🔑 事务体内「删缓存」也排在最后（防御性顺序）',
        clearAt > logAt && clearAt > crsAt && clearAt > uwAt,
        'clear@$clearAt log@$logAt crs@$crsAt uw@$uwAt');

    await db.close();
    await dir.delete(recursive: true);
  }

  // ═══ 【4】`lookup_event` **有意不收敛** ═══
  section('【4】lookup_event 不动（历史事实，收敛它 = 篡改历史）');
  {
    final src =
        File('../../app/lib/services/word_id_convergence.dart').readAsStringSync();
    final code = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    check('🔴 收敛代码里**没有** `lookup_event`（有意为之，不是漏了）',
        !code.contains('lookup_event'));
    check('🔑 但候选来源是三张表（含 review_log）',
        RegExp(r"for \(final table in \['user_word', 'card_review_state', 'review_log'\]\)")
            .hasMatch(code));
  }

  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
  }
  print('═' * 72);
  exit(_failures.isEmpty ? 0 : 1);
}

int _n(List<Map<String, Object?>> rows) =>
    rows.isEmpty ? -1 : (rows.first.values.first as num).toInt();

/// 从 `start` 起按**花括号配对**取出区间的文本（**含** `start` 那个 `{`）。
///
/// 🔑 为什么要「切区间」而不是「比位置」：见 §3 的证伪记录 ——
///    「排在后面」与「在同一个作用域里」是两件事，位置断言抓不到后者。
///
/// ⚠️ 调用方**必须**另加**哨兵断言**（切错后区间往往**仍非空**，
///    只是内容不对）。边界同 `tokens_verify` 的 `_braces`：
///    不理解字符串字面量里的 `{` / `}`（本项目这两处代码没有该写法）。
String _bracesFrom(String src, int start) {
  if (start < 0) return '';
  final open = src.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var j = open; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, j + 1);
    }
  }
  return '';
}
