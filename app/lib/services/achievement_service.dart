// CoEvo · 成就**采集与服务层**（`user.db` 侧）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）：
//   本地 `flutter analyze` 会崩，纯 Dart 才能独立验证（`sqflite_common_ffi`）。
//
// # 职责边界（**刻意分开**，别把判定逻辑搬进来）
// | 层 | 文件 | 职责 |
// |---|---|---|
// | 规则 | `achievement_rules.dart` | 「什么算解锁」—— **纯函数**，零 IO |
// | 采集 | **本文件** | 「把 `user.db` 的原始数据算成指标」+ 「解锁落库」 |
// → 🔑 **判定不进本文件** —— 否则「口径」会有两处定义。
//
// # 🔴🔴 三个必须知道的实现要点
//
// ## ① 时间口径：`reviewed_at` 是 UTC，streak 要**本地日**
// 见 `achievement_rules.dart` 文件头 ②。本文件负责 `toLocal()`：
// **纯函数层不做时区转换**（它只按传入值的日历字段取日）。
//
// ## ② 时段统计（深夜/早起）也要**本地小时**
// `review_log` 里只有 UTC 时间。**没有**用 SQL 的 `'localtime'` 修饰符 ——
// 那依赖 SQLite 构建时的时区处理（Android / iOS / ffi 三套实现未必一致），
// 属于「**未经验证的平台行为**」。改为读出 `reviewed_at` 单列在 Dart 侧 `toLocal()`。
// · 代价：要读全表的 `reviewed_at`。量级评估：1 万次复习 × ~24 字节 ≈ 240 KB，
//   一次性读入可接受（复习是用户主动行为，不会到百万级）。
// · 🔑 若将来真的到瓶颈，再按「只查需要的时段」优化 —— 现在做属于**没有依据的复杂度**。
//
// ## ③ 「1 小时查词」要先**按词去重**
// `computeMaxLookupsIn1h` 接收的是「时间列表」。语义要的是「1 小时内遇到多少个**不同**的词」
// → 本层先把同 `spelling` 的记录只保留**最早**那一次，再交给纯函数。
// 🔑 这样纯函数保持简单（不关心词），语义在采集端表达清楚。

import 'package:sqflite_common/sqlite_api.dart';

import 'achievement_rules.dart';

/// 一次「指标快照 + 解锁状态」的查询结果（**只读**）。
class AchievementSnapshot {
  /// 指标名 → 数值（键见 `AchievementMetrics`）。
  final Map<String, num> metrics;

  /// 当前**满足条件**的成就 key（由纯函数算出，不代表已落库）。
  final Set<String> satisfied;

  /// 已在 `achievement_unlock` 里记录的 key。
  final Set<String> recorded;

  const AchievementSnapshot({
    required this.metrics,
    required this.satisfied,
    required this.recorded,
  });

  /// 已解锁（两者取并集 —— 满足过又因数据减少而不满足的，仍算解锁过）。
  ///
  /// 🔑 **为什么取并集**：成就是「**曾经达成**」的荣誉，不该因为
  /// （比如用户软删了生词）就撤销。`recorded` 是权威 —— 它记着历史。
  Set<String> get unlocked => {...recorded, ...satisfied};

  /// 进度（0.0 ~ 1.0）—— 全清单的平均完成度，供「我的」页顶部展示。
  double get overallProgress {
    if (kAchievements.isEmpty) return 0;
    final total = kAchievements.fold<double>(
        0, (sum, d) => sum + achievementProgress(d, metrics));
    return total / kAchievements.length;
  }
}

/// 成就服务 —— 采集指标 + 解锁落库。
///
/// 用法（UI 层）：
/// ```dart
/// final svc = AchievementService(db);
/// final snapshot = await svc.snapshot(now: DateTime.now());
/// // 复习提交后：
/// final newly = await svc.checkAndUnlock(now: DateTime.now());
/// if (newly.isNotEmpty) notifier.push(newly);   // 弹解锁通知
/// ```
class AchievementService {
  final Database db;

  const AchievementService(this.db);

  /// 采集全部指标（**只读**，不落库）。
  ///
  /// [now]：当前**本地**时间 —— 必须由调用方传入（**不在本层调 `DateTime.now()`**）：
  /// 理由是「可测」（验证脚本要能构造任意「今天」）。
  Future<Map<String, num>> collectMetrics({required DateTime now}) async {
    final metrics = <String, num>{};

    // ── 直接可由 SQL 计数的（5 个）──────────────────────────
    metrics[AchievementMetrics.lookupCount] = await _count('lookup_event');
    metrics[AchievementMetrics.totalWords] =
        await _count('user_word', where: 'deleted = 0');
    metrics[AchievementMetrics.totalReviews] = await _count('review_log');
    // `stability >= kMatureStabilityDays` 天 = FSRS 的 mature 门槛
    // （门槛数值的唯一出处见 `achievement_rules.dart` 的 `kMatureStabilityDays`）
    //
    // 🔴 **有意不 JOIN `user_word`** —— 即**不过滤「暂停」的词**（白哥 2026-09-29 定）：
    //    「掌握」是**历史成就**，暂停（先不学了）≠ 忘记了。
    //    对照：生词本（`deleted = 0`）与复习页（`COALESCE(uw.deleted, 0) = 0`）**都**过滤。
    //    ⚠️ 两者口径不同是**有意的**，不要当遗漏去「修」——
    //    守护断言见 `scripts/query_verify/bin/verify_achievement_service.dart`【3】。
    metrics[AchievementMetrics.matureCards] = await _count(
        'card_review_state',
        where: 'stability >= $kMatureStabilityDays');
    // 🆕 「阅读篇数」—— 不驱动成就，只供「我的」页顶部展示（同源采集，避免两处口径）
    metrics[AchievementMetrics.articlesRead] = await _count('article_read');

    // ── 最近 50 次准确率（1 个）────────────────────────────
    metrics[AchievementMetrics.recentAccuracy50] = await _recentAccuracy50();

    // ── 需要「本地时间」的（4 个）──────────────────────────
    // 🔴 一次查询同时喂给 streak / gap / 时段统计 —— 避免三次全表扫描
    final localReviewTimes = await _localReviewTimes();
    metrics[AchievementMetrics.streakDays] =
        computeStreakDays(localReviewTimes, now);
    metrics[AchievementMetrics.maxGapDays] = computeMaxGapDays(localReviewTimes);
    metrics[AchievementMetrics.nightSessions] = localReviewTimes
        .where((t) => t.hour >= 22 || t.hour < 2) // 22:00–02:00（跨零点）
        .length;
    metrics[AchievementMetrics.earlySessions] =
        localReviewTimes.where((t) => t.hour >= 6 && t.hour < 8).length;

    // ── 1 小时查词峰值（1 个）──────────────────────────────
    metrics[AchievementMetrics.lookupsIn1h] = computeMaxLookupsIn1h(
        await _firstLookupTimesPerWord());

    return metrics;
  }

  /// 读解锁记录（`key → unlocked_at`）。
  Future<Map<String, DateTime>> loadUnlocks() async {
    final rows = await db.query('achievement_unlock');
    final out = <String, DateTime>{};
    for (final r in rows) {
      final key = r['key'] as String?;
      final at = r['unlocked_at'] as String?;
      if (key == null || at == null) continue;
      // 本库时间列统一 UTC ISO8601 带 Z（硬约束 1）→ 解析后是 UTC
      final parsed = DateTime.tryParse(at);
      if (parsed != null) out[key] = parsed.toLocal();
    }
    return out;
  }

  /// **只读**快照（采集 + 判定 + 读记录，不改库）。
  Future<AchievementSnapshot> snapshot({required DateTime now}) async {
    final metrics = await collectMetrics(now: now);
    final satisfied = evaluateAchievements(metrics);
    final recorded = (await loadUnlocks()).keys.toSet();
    return AchievementSnapshot(
      metrics: metrics,
      satisfied: satisfied,
      recorded: recorded,
    );
  }

  /// **检查并落库**：返回**本次新解锁**的成就（供弹通知用）。
  ///
  /// · 幂等：靠 `INSERT OR IGNORE` + 主键 —— 重复调用不会重复解锁
  /// · **不改已有记录**（`unlocked_at` 是「首次解锁时刻」，不能被后来覆盖）
  Future<List<AchievementDef>> checkAndUnlock({required DateTime now}) async {
    final metrics = await collectMetrics(now: now);
    final satisfied = evaluateAchievements(metrics);
    final recorded = (await loadUnlocks()).keys.toSet();

    final newKeys = satisfied.difference(recorded);
    if (newKeys.isEmpty) return const [];

    // 🔑 `OR IGNORE` 而非普通 INSERT：
    //    UI 可能在多处（复习后 / 查词后 / 进入我的页）触发检查，
    //    两次快速调用之间可能都算出同一个「新解锁」→ 主键冲突。
    //    用 OR IGNORE 让**第二个调用静默无害**，而不是抛异常。
    final batch = db.batch();
    for (final key in newKeys) {
      batch.insert('achievement_unlock', {'key': key},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);

    // 按 `kAchievements` 的声明顺序返回（稳定顺序 → 通知队列顺序可预期）
    return kAchievements.where((d) => newKeys.contains(d.key)).toList();
  }

  // ══════════════════════════════════════════════════════════
  // 🆕 v10：跨设备同步（`achievement_unlock`）
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 为什么值得同步：成就**内容**能由指标重算，但「**解锁时间**」算不出来 ——
  //    新设备上会记成「现在」而不是「当初」⇒ 成就墙的日期是假的。
  // 🔑 合并语义已定：`unlocked_at` 取**较早**（首次解锁这一事实，同 `article_read.read_at`）。
  //    ⚠️ 「A 端解锁 B 端没解锁」不成问题 —— 解锁记录是**并集**（指标够了会重算出来）。

  /// 待同步的解锁记录（`pending_push = 1`）。
  ///
  /// ⚠️ 返回**行形状**（`key` / `unlocked_at`）—— 与后端 `AchievementUnlockInput` 字段一致，
  ///    供 `sync_service` 直接组装请求体。
  ///
  /// ⚠️ [limit]：与其余表的 `pending()` 同一理由（单次请求每表 ≤ 1000）
  ///    —— 本表**最多只有成就条数**（几十），加它只是为了**口径统一**。
  Future<List<Map<String, Object?>>> pendingUnlocks({int? limit}) async {
    final rows = await db.query('achievement_unlock',
        where: 'pending_push = 1', orderBy: 'unlocked_at ASC', limit: limit);
    return rows
        .map((r) => <String, Object?>{
              'key': r['key'],
              'unlocked_at': r['unlocked_at'],
            })
        .toList(growable: false);
  }

  /// 标记已同步（push 成功后调用）。
  Future<void> markUnlocksSynced(Iterable<String> keys) async {
    final list = keys.where((k) => k.isNotEmpty).toList();
    if (list.isEmpty) return;
    final ph = List.filled(list.length, '?').join(',');
    await db.update('achievement_unlock', {'pending_push': 0},
        where: 'key IN ($ph)', whereArgs: list);
  }

  // ══════════════════════════════════════════════════════════
  // 内部查询
  // ══════════════════════════════════════════════════════════

  Future<int> _count(String table, {String? where}) async {
    final sql = 'SELECT COUNT(*) AS n FROM $table'
        '${where == null ? '' : ' WHERE $where'}';
    final rows = await db.rawQuery(sql);
    return _firstInt(rows);
  }

  /// 最近 50 次复习的准确率（百分数，取整）。
  ///
  /// 🔴 口径：`rating >= 2`（非「忘了」）—— 见 `achievement_rules.dart` 文件头 ①。
  /// · 不足 50 次时按**已有次数**算（不是 0）—— 否则新用户永远看不到进度。
  /// · 与 `review_log` 的索引 `idx_log_word_replay(word_id, reviewed_at)` 不匹配，
  ///   但 `review_log` 是**单用户**表（量级：千），`ORDER BY ... LIMIT 50` 的全表扫可接受。
  ///   🔑 不为此加索引 —— 那是「没有依据的优化」（同文件头 ② 的原则）。
  Future<num> _recentAccuracy50() async {
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS total,
             SUM(CASE WHEN rating >= 2 THEN 1 ELSE 0 END) AS passed
      FROM (SELECT rating FROM review_log ORDER BY reviewed_at DESC LIMIT 50)
    ''');
    if (rows.isEmpty) return 0;
    final total = _asInt(rows.first['total']);
    if (total == 0) return 0;
    final passed = _asInt(rows.first['passed']);
    // 四舍五入到整数百分点（阈值是 90，不必更高精度）
    return ((passed * 100) / total).round();
  }

  /// 全部复习时刻 → **本地时间**（见文件头 ①）。
  Future<List<DateTime>> _localReviewTimes() async {
    final rows = await db.rawQuery('SELECT reviewed_at FROM review_log');
    return _parseUtcToLocal(rows, 'reviewed_at');
  }

  /// 每个**不同词**的**首次**查词时刻 → 本地时间（见文件头 ③）。
  ///
  /// `spelling` 在 DDL 里是 `COLLATE NOCASE` → SQL 的 `MIN` 分组天然按大小写不敏感，
  /// 与「同一个词查 5 遍算 1 个」的语义一致。
  Future<List<DateTime>> _firstLookupTimesPerWord() async {
    final rows = await db.rawQuery('''
      SELECT MIN(looked_up_at) AS t FROM lookup_event GROUP BY spelling
    ''');
    return _parseUtcToLocal(rows, 't');
  }

  /// 把一组 UTC ISO8601 字符串列解析成**本地** `DateTime`（丢弃无法解析的行）。
  ///
  /// 🔑 丢弃而不是抛错：一行脏数据不该让整个成就页打不开
  /// （本项目判据：「静默失败 + 无出口」最糟 —— 这里选择**跳过该行但继续**）。
  List<DateTime> _parseUtcToLocal(
      List<Map<String, Object?>> rows, String column) {
    final out = <DateTime>[];
    for (final r in rows) {
      final v = r[column];
      if (v is! String || v.isEmpty) continue;
      final parsed = DateTime.tryParse(v);
      if (parsed != null) out.add(parsed.toLocal());
    }
    return out;
  }

  int _firstInt(List<Map<String, Object?>> rows) =>
      rows.isEmpty ? 0 : _asInt(rows.first.values.first);

  int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
