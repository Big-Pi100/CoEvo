// CoEvo · 成就**采集/服务层**验收（真库 · `sqflite_common_ffi`）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_achievement_service.dart
//
// # 与 `verify_achievement_rules.dart` 的分工
// | 脚本 | 验什么 |
// |---|---|
// | `verify_achievement_rules` | **判定逻辑**（纯函数 · 无 DB） |
// | **本脚本** | **指标采集**（真库 SQL）+ **UTC→本地转换** + **落库幂等** |
//
// 🔴 本脚本专补纯函数层**验不到**的部分：时区转换、SQL 口径、`INSERT OR IGNORE` 幂等。
//
// # 🔑 时间断言**跨时区稳健**（重要写法）
// 本机是 GMT+8，但断言**不能**硬编码「UTC 17:00 = 本地次日 01:00」——
// 那会让脚本在别的时区变红（或更糟：巧合变绿）。
// → 做法：**先构造本地时刻，再转 UTC 存库**：
//   `DateTime(2026,9,28,23).toUtc().toIso8601String()`
//   这样无论运行在哪个时区，「本地 23 点」这条记录都真实成立。
// 🔑 这同时**证明了 `toLocal()` 确实被调用了**：
//   若实现漏掉 `toLocal()`，本地 23 点会被算成 UTC 23 点 → 时段统计错位。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/achievement_rules.dart';
import '../../../app/lib/services/achievement_service.dart';
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

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final dir = await Directory.systemTemp.createTemp('coevo_ach_');
  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  final db = await openUserDb(
    factory: factory,
    path: '${dir.path}/user.db',
    schemaSql: schemaSql,
  );
  final svc = AchievementService(db);

  // 固定「现在」为本地时间（可测的关键 —— 实现里不调 DateTime.now()）
  final now = DateTime(2026, 9, 29, 20, 0);

  // ══════════════════════════════════════════════════════════
  section('【1】空库 → 全部指标为 0，无解锁');
  // ══════════════════════════════════════════════════════════
  var m = await svc.collectMetrics(now: now);
  // 🔑 **不写死数量**（原写「10 个」→ 加第 11 个指标时文案就过时了），
  //    并且从「包含」升级为**集合相等** —— `.every(containsKey)` 只能发现「缺」，
  //    发现不了「多」（采集端多采一个键 = 潜在的口径分叉，也是问题）。
  final gotKeys = m.keys.toSet();
  final wantKeys = AchievementMetrics.all.toSet();
  check('🔴 采集的指标键与 `AchievementMetrics.all` **集合相等**（缺/多都能发现）',
      gotKeys.length == wantKeys.length && gotKeys.containsAll(wantKeys),
      '实际 ${gotKeys.length} / 期望 ${wantKeys.length}'
      '${gotKeys.length == wantKeys.length ? '' : '（差: ${gotKeys.difference(wantKeys)} / ${wantKeys.difference(gotKeys)}）'}');
  check('空库时全部指标为 0', m.values.every((v) => v == 0));
  check('空库时无解锁', (await svc.snapshot(now: now)).satisfied.isEmpty);

  // ══════════════════════════════════════════════════════════
  section('【2】复习量 + 准确率（口径 rating >= 2）');
  // ══════════════════════════════════════════════════════════
  var seq = 0;
  Future<void> addReview({
    required int rating,
    required DateTime localTime,
    required String wordId,
  }) async {
    await db.insert('review_log', {
      'word_id': wordId,
      'rating': rating,
      // 🔑 存** UTC**（本库硬约束）—— 断言用本地时刻构造，故跨时区稳健
      'reviewed_at': localTime.toUtc().toIso8601String(),
      'utc_day': localTime.toUtc().toIso8601String().substring(0, 10),
      'device_id': 'test',
      'synced': 1,
    });
    seq++;
  }

  // 先造 7 条「非忘了」（rating 2/3/4）→ 100%
  for (var i = 0; i < 7; i++) {
    await addReview(
      rating: 2 + (i % 3),
      localTime: DateTime(2026, 9, 1, 10).add(Duration(minutes: i)),
      wordId: 'w${i.toString().padLeft(6, '0')}',
    );
  }
  m = await svc.collectMetrics(now: now);
  check('total_reviews = 7', m[AchievementMetrics.totalReviews] == 7);
  check('不足 50 次时按已有次数算准确率（7 条全过 → 100）',
      m[AchievementMetrics.recentAccuracy50] == 100,
      '${m[AchievementMetrics.recentAccuracy50]}');

  // 再造 3 条「忘了」（rating = 1，时间**更晚** → 落在最近 50 内）
  for (var i = 0; i < 3; i++) {
    await addReview(
      rating: 1,
      localTime: DateTime(2026, 9, 2, 10).add(Duration(minutes: i)),
      wordId: 'w${(100 + i).toString().padLeft(6, '0')}',
    );
  }
  m = await svc.collectMetrics(now: now);
  check('total_reviews = 10', m[AchievementMetrics.totalReviews] == 10);
  // 7 过 / 10 总 = 70%
  check('🔴 准确率 = 70（rating>=2 口径：3 条 rating=1 不计入通过）',
      m[AchievementMetrics.recentAccuracy50] == 70,
      '${m[AchievementMetrics.recentAccuracy50]}');
  check('🔴 rating=2（困难）算**通过** ← 与 «>= 3» 口径的关键区别',
      m[AchievementMetrics.recentAccuracy50] == 70,
      '若按 >=3：通过数 5/10 = 50（本实现不是这个值）');

  // ══════════════════════════════════════════════════════════
  section('【3】mature 口径（stability >= 21）');
  // ══════════════════════════════════════════════════════════
  // 🔑 下面这些 `21.0` / `25.0` / `20.9` / `21` 是**硬编码的独立期望值** ——
  //    **故意不引用** `kMatureStabilityDays`。判据：**期望值须独立于被测逻辑**。
  //    若改成一引用同一常量，则常量被改成 30 时断言会**跟着一起变**、
  //    永远看不出「门槛被改了」⇒ 断言失去区分度（本项目「假绿」家族的常见形状）。
  //    ✅ 正确行为：改 `kMatureStabilityDays` → 这里的断言**必须变红**，逼人同步改测试。
  Future<void> addState(String id, double? stability, int state) =>
      db.insert('card_review_state', {
        'word_id': id,
        'spelling': id,
        'state': state,
        'stability': stability,
        'next_review_at': '2026-09-30T00:00:00Z',
      });

  await addState('m1', 21.0, 2); // 恰好 21 → 算
  await addState('m2', 30.5, 2); // > 21 → 算
  await addState('m3', 20.9, 2); // < 21 → **不算**
  await addState('m4', null, 1); // 未学（无 stability）→ 不算
  await addState('m5', 5.0, 1); // learning → 不算
  m = await svc.collectMetrics(now: now);
  check('🔴 mature_cards = 2（21 与 30.5；20.9 与 null 不算）',
      m[AchievementMetrics.matureCards] == 2,
      '${m[AchievementMetrics.matureCards]}');
  check('🔴 边界：stability 恰好 21 → 算 mature（>= 而非 >）',
      m[AchievementMetrics.matureCards] == 2);

  // ── 🆕 「暂停的词**仍计入**已掌握」（白哥 2026-09-29 定 · 见规则层文件头 ④）──
  //
  // 🔑 为什么必须**断言**它：实现里 mature 的 SQL **有意不 JOIN `user_word`**，
  //    而「生词本 / 复习页都过滤了暂停，唯独这里没有」看着就像是遗漏 ——
  //    后人很可能顺手补 `AND deleted = 0` → **静默改变语义**
  //    （用户的「已掌握」会随暂停掉数字，且不报错）。
  //    决策只写在注释里挡不住这个，断言能。
  await addState('m6', 25.0, 2); // stability 25 >= 21 → 本应计入
  await db.insert(
      'user_word', {'word_id': 'm6', 'spelling': 'm6', 'deleted': 1}); // 且已暂停
  m = await svc.collectMetrics(now: now);
  check('🔴 暂停（`user_word.deleted = 1`）的已掌握词**仍计入**（掌握 = 历史成就）',
      m[AchievementMetrics.matureCards] == 3,
      '${m[AchievementMetrics.matureCards]}');

  // 对照：把 m6 改回「未暂停」→ 计数**不变**
  // 🔑 这条对照不可省：只断言「=3」的话，仅证明了「多了一行 crs」，
  //    证明不了「与 user_word 无关」。改回 0 之后**仍是 3** ⇒ 该指标确实不读 user_word。
  await db.update('user_word', {'deleted': 0},
      where: 'word_id = ?', whereArgs: ['m6']);
  m = await svc.collectMetrics(now: now);
  check('对照：改回未暂停后计数**仍为 3**（证明该指标完全不读 `user_word`）',
      m[AchievementMetrics.matureCards] == 3,
      '${m[AchievementMetrics.matureCards]}');

  // 🔑 清理：不给后续段留痕迹 ——【4】段要断言 `total_words` 的**精确值**。
  //    造完不删的话，m6 会悄悄把它变成 11，而失败信息只显示「11 != 10」（难定位）。
  await db.delete('user_word', where: 'word_id = ?', whereArgs: ['m6']);

  // ══════════════════════════════════════════════════════════
  section('【3b】🆕 阅读篇数（`articles_read` —— 供「我的」页展示，**不驱动成就**）');
  // ══════════════════════════════════════════════════════════
  check('空表时 articles_read = 0',
      (await svc.collectMetrics(now: now))[AchievementMetrics.articlesRead] == 0);

  final artRepo = ArticleReadRepository(db);
  await artRepo.markRead(1);
  await artRepo.markRead(2);
  await artRepo.markRead(2); // 🔑 重复 —— 必须**仍算 1 篇**（口径乙的核心前提）
  final readMetric =
      (await svc.collectMetrics(now: now))[AchievementMetrics.articlesRead];
  check('🔴 标记 2 篇（其中 1 篇重复）后 = 2（去重生效）', readMetric == 2,
      '$readMetric');
  // 🔑 与 repository 直接算的**同源**（两处口径必须一致）
  check('🔴 指标值与 `ArticleReadRepository.countRead()` 一致（一处口径）',
      readMetric == await artRepo.countRead(), '$readMetric');

  // 🔴 锁住「它不驱动任何成就」这个**有意**状态：
  //    将来若有人给它挂成就，这条会变红 → 提醒「阈值/文案要一并设计」，
  //    而不是静默多出一个成就。
  final users = kAchievements
      .where((a) => a.metric == AchievementMetrics.articlesRead)
      .toList();
  check('🆕 `articles_read` 目前不驱动任何成就（有意如此）', users.isEmpty,
      '${users.length} 个引用');

  // ══════════════════════════════════════════════════════════
  section('【4】生词 + 查词 + 1 小时峰值');
  // ══════════════════════════════════════════════════════════
  Future<void> addWord(String id, {int deleted = 0}) =>
      db.insert('user_word', {
        'word_id': id,
        'spelling': id,
        'deleted': deleted,
      });

  await addWord('w000001');
  await addWord('w000002');
  await addWord('w000003');
  // 补到 **10 个**（刚好解锁 `words_10`）—— 这样 §8 才能验证「软删后不撤销」
  // 🔑 若只造 3 个，`words_10` 永远不解锁 → §8 那条断言会**恒真**（假绿）。
  //    ⚠️ 我第一版就是只造了 3 个，跑完看到「前后都是 false」才发现。
  for (var i = 4; i <= 10; i++) {
    await addWord('w${i.toString().padLeft(6, '0')}');
  }
  await addWord('w000099', deleted: 1); // 软删 → **不占额度**
  m = await svc.collectMetrics(now: now);
  check('🔴 total_words = 10（软删的 1 条不计 —— 与「200 上限」同口径）',
      m[AchievementMetrics.totalWords] == 10,
      '${m[AchievementMetrics.totalWords]}');

  Future<void> addLookup(String spelling, DateTime localTime) =>
      db.insert('lookup_event', {
        'word_id': 'w-unknown',
        'spelling': spelling,
        'looked_up_at': localTime.toUtc().toIso8601String(),
      });

  // 同一小时内查 5 个**不同**的词 + 同一个词重复查 4 次
  for (var i = 0; i < 5; i++) {
    await addLookup('spell$i', DateTime(2026, 9, 10, 15).add(Duration(minutes: i)));
  }
  for (var i = 0; i < 4; i++) {
    await addLookup('spell0', DateTime(2026, 9, 10, 15).add(Duration(minutes: 30 + i)));
  }
  m = await svc.collectMetrics(now: now);
  check('lookup_count = 9（每次查词都算，含重复）',
      m[AchievementMetrics.lookupCount] == 9,
      '${m[AchievementMetrics.lookupCount]}');
  check('🔴 lookups_in_1h = 5（**按词去重**：同一个词查 4 次只算 1 个）',
      m[AchievementMetrics.lookupsIn1h] == 5,
      '${m[AchievementMetrics.lookupsIn1h]}');

  // ══════════════════════════════════════════════════════════
  section('【5】时段统计（🔴 本地小时 · 跨时区稳健写法）');
  // ══════════════════════════════════════════════════════════
  // 用**本地时刻**构造 → 转 UTC 存库。若实现漏了 `toLocal()`，下面会错位。
  for (var i = 0; i < 5; i++) {
    await addReview(
      rating: 3,
      localTime: DateTime(2026, 9, 20, 23, i), // 本地 23:xx
      wordId: 'night$i',
    );
  }
  for (var i = 0; i < 5; i++) {
    await addReview(
      rating: 3,
      localTime: DateTime(2026, 9, 21, 7, i), // 本地 07:xx
      wordId: 'early$i',
    );
  }
  // 各加一条**不该算**的（本地 12:00）
  await addReview(rating: 3, localTime: DateTime(2026, 9, 21, 12), wordId: 'noon');
  await addReview(rating: 3, localTime: DateTime(2026, 9, 21, 4), wordId: 'four');

  m = await svc.collectMetrics(now: now);
  check('🔴 night_sessions = 5（本地 23 点 × 5；12 点与 4 点不算）',
      m[AchievementMetrics.nightSessions] == 5,
      '${m[AchievementMetrics.nightSessions]}');
  check('🔴 early_sessions = 5（本地 7 点 × 5）',
      m[AchievementMetrics.earlySessions] == 5,
      '${m[AchievementMetrics.earlySessions]}');

  // 补一条本地 01:00（跨零点区间 22:00–02:00 的另一半）
  await addReview(rating: 3, localTime: DateTime(2026, 9, 21, 1), wordId: 'oneAm');
  m = await svc.collectMetrics(now: now);
  check('🔴 22:00–02:00 是**跨零点**区间：本地 01:00 也算深夜（→ 6）',
      m[AchievementMetrics.nightSessions] == 6,
      '${m[AchievementMetrics.nightSessions]}');

  // ══════════════════════════════════════════════════════════
  section('【6】streak（端到端 · UTC 存 / 本地算）');
  // ══════════════════════════════════════════════════════════
  // 造「今天 + 昨天 + 前天」都有复习（本地时间）
  for (final d in [
    DateTime(2026, 9, 29, 9),
    DateTime(2026, 9, 28, 9),
    DateTime(2026, 9, 27, 21),
  ]) {
    await addReview(
        rating: 3, localTime: d, wordId: 'streak${d.day}');
  }
  // 🔴 关键：本地 09-29 01:00 那条 —— 在 UTC 下属于 09-28
  //    （GMT+8 时）。若实现按 `utc_day` 算，streak 会错位。
  await addReview(
      rating: 3, localTime: DateTime(2026, 9, 29, 1), wordId: 'midnight29');

  m = await svc.collectMetrics(now: now);
  check('🔴 streak_days = 3（本地 27/28/29 连续；含 29 日凌晨那条）',
      m[AchievementMetrics.streakDays] == 3,
      '${m[AchievementMetrics.streakDays]}');
  check('「今天没学但昨天学了」不算断（now=9/30 → 仍为 3）',
      (await svc.collectMetrics(now: DateTime(2026, 9, 30, 12)))
              [AchievementMetrics.streakDays] ==
          3,
      '最后学习日 9/29 = 昨天 → 未断');
  // ⚠️ 本组**不**验「UTC 日 vs 本地日」（我第一版在这里写过一条，是**假绿**：
  //    无论凌晨那条算 28 还是 29 日，streak 都是 3 → 验不出差异）。
  //    🔑 真正的时区守护在 §【5】的时段统计 ——
  //       本地 23:00 → UTC 15:00（GMT+8），若实现漏 `toLocal()`，hour 会是 15
  //       → `night_sessions` 变 0 ≠ 5 → **当场报红**，且该断言跨时区成立。

  // ══════════════════════════════════════════════════════════
  section('【7】checkAndUnlock —— 落库 / 幂等 / unlocked_at 不被覆盖');
  // ══════════════════════════════════════════════════════════
  final newly1 = await svc.checkAndUnlock(now: now);
  final newlyKeys1 = newly1.map((d) => d.key).toSet();
  check('首次调用返回非空（数据已足够解锁若干成就）', newly1.isNotEmpty,
      '${newly1.length} 个: ${newlyKeys1.join(", ")}');
  check('🔴 返回顺序与 `kAchievements` 声明顺序一致（通知队列可预期）',
      newly1.map((d) => d.key).toList().toString() ==
          kAchievements
              .where((d) => newlyKeys1.contains(d.key))
              .map((d) => d.key)
              .toList()
              .toString());

  final firstAt = (await svc.loadUnlocks());
  check('落库后可读回（条数 = 新解锁数）', firstAt.length == newly1.length,
      '${firstAt.length}/${newly1.length}');
  check('🔴 unlocked_at 已写入且非空', firstAt.values.every((t) => t.year >= 2020),
      '${firstAt.values.firstOrNull}');

  // 幂等：再调一次应返回空
  final newly2 = await svc.checkAndUnlock(now: now);
  check('🔴 二次调用返回**空**（幂等：不会重复解锁）', newly2.isEmpty,
      '返回 ${newly2.length} 个');
  check('二次调用后记录条数不变', (await svc.loadUnlocks()).length == firstAt.length);

  // unlocked_at 不被覆盖
  final before = (await svc.loadUnlocks());
  await Future<void>.delayed(const Duration(milliseconds: 5));
  await svc.checkAndUnlock(now: now);
  final after = (await svc.loadUnlocks());
  check('🔴 已有记录的 unlocked_at **未被覆盖**（首次解锁时刻是权威）',
      before.toString() == after.toString());

  // ══════════════════════════════════════════════════════════
  section('【8】解锁取**并集**（数据减少不撤销已得成就）');
  // ══════════════════════════════════════════════════════════
  final snapBefore = await svc.snapshot(now: now);
  check('unlocked 是 satisfied ∪ recorded', snapBefore.unlocked.length >=
      snapBefore.satisfied.length);
  // 🔑 前置：必须先确认「软删前 words_10 真的解锁了」——
  //    否则下面那条「仍含」是**恒真**（我第一版就踩了：只造 3 个生词 → 永远 false）
  check('前置：软删前 words_10 已被满足（10 个生词）',
      snapBefore.satisfied.contains('words_10'));

  // 软删所有生词 → total_words 归 0
  await db.update('user_word', {'deleted': 1});
  final snapAfter = await svc.snapshot(now: now);
  check('软删后 total_words 归 0',
      snapAfter.metrics[AchievementMetrics.totalWords] == 0);
  check('🔴 且 `satisfied` 不再含 words_10（当前条件确实不满足了）',
      !snapAfter.satisfied.contains('words_10'));
  check('🔴 但 `unlocked` **仍含** words_10（取并集 · 成就不可撤销）',
      snapAfter.unlocked.contains('words_10'),
      'recorded=${(await svc.loadUnlocks()).containsKey('words_10')}');
  check('🔴 且 `recorded` 未被清空（表里记录仍在）',
      (await svc.loadUnlocks()).isNotEmpty);

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
