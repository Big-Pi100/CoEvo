// CoEvo · 发版收敛：把端侧的 `ext:<拼写>` 收敛为正式 `word.id`
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` / `word_query_service.dart`）：
//    纯 Dart 才能用 `sqflite_common_ffi` 在本地独立验证
//    （见 `scripts/query_verify/bin/verify_word_id_convergence.dart`）。
//    IO 通过**注入的 `Database`** 完成 —— 本文件自己不打开任何库。
//
// # 它解决什么
// 词库外的词在端侧以**合成 id** `ext:brainstorm` 存在
// （见 `external_word_id.dart`）。当这个词被**回流**进 `word.db` 后，
// 端侧还拿着旧 id → 同一个词会有**两条身份**：
//
// | 时间 | 用户查 `brainstorm` | `user_word.word_id` |
// |---|---|---|
// | 回流前 | 词库里没有 → 在线制卡 | `ext:brainstorm` |
// | **回流后** | 词库里**有了** → 直接命中 | `w011524` |
//
// ⇒ 🔴 **同一个词两行**，而且 `UNIQUE(word_id)` **拦不住**
//    （它约束的是「同一个 id 只能一行」，而这是两个**不同**的 id）。
//    复习状态由此**分裂成两份** —— 直接违反「按 lemma 唯一」。
//
// # 🔑 收敛**不需要 mapping 文件**（这是本设计最省事的一点）
// `ext:<拼写>` 里的**拼写就是桥** → 拿它去**新** `word.db` 查：
// ```sql
// SELECT id FROM word WHERE spelling = ? COLLATE NOCASE LIMIT 1
// ```
// 查得到 ⇒ 已回流 ⇒ 收敛；查不到 ⇒ 未回流 ⇒ **原样保留**。
//
// # 🔴🔴 硬约束：**「改三张表」与「删缓存」必须在同一个事务里**（原子性）
// 若分成两个操作、且删缓存先提交了：
// 事务回滚后 ⇒ 数据还指着 `ext:`、**而缓存已经没了** ⇒ **取不到卡**
// —— 比「不收敛」更糟（不收敛只是重复，取不到卡是**功能缺失**）。
//
// 本实现把四步放进**同一个事务** ⇒ 要么全成、要么全滚
// （由 `verify_word_id_convergence.dart` §3 **注入失败真跑**验证）。
//
// ## ⚠️ 关于「顺序」：**当前是防御性的，不是必需的**（别把它说成必需）
// 在**同一事务**内，先改表还是先删缓存**不影响结果** —— 原子性已经保证正确。
// 我曾在文档里写成「顺序不可颠倒，否则丢卡」，**证伪实验否掉了这个说法**：
// 把删缓存移到事务体最前（顺序反了）→ 断言**全绿**，结果**依然正确**。
// 🔑 顺序仍写在正确的位置上，是**防御**：将来若有人把某步挪出事务，
//    顺序就成为唯一防线（断言里也留了这条，标为「防御性顺序」）。
//
// # ⚠️ 诚实边界
// · 收敛的**真实效果未在真机验证过**（端侧目前 `ext:` 数据为 0 —— A2 刚落地）
//   → 断言用**构造库**演练（见 `scripts/query_verify/bin/verify_word_id_convergence.dart`）
// · **`lookup_event` 有意不收敛**（表见 `externalWordIdsIn` 的说明）：
//   它是**历史事实**（「当时词库里没有」），收敛它等于**篡改历史**。
// · **`external_word_cache` 里「未回流的词」的缓存永远保留** —— 「清空缓存」是
//   **单调递减**，不是一次清光（清光 = 那些词的卡就没了）。

import 'package:sqflite_common/sqlite_api.dart';

import 'external_word_id.dart';

// ─────────────────────────────────────────────────────────────
// 纯逻辑（可独立断言）
// ─────────────────────────────────────────────────────────────

/// 「拼写 → 新词库里的 id」—— 查得到说明**已回流**。
typedef SpellingResolver = Future<String?> Function(String spelling);

/// 一对可收敛的 id。
class ConvergencePair {
  const ConvergencePair({required this.fromId, required this.toId});

  /// 端侧现存的合成 id（`ext:brainstorm`）
  final String fromId;

  /// 词库里的正式 id（`w011524`）
  final String toId;

  /// 该词的拼写（由 `fromId` 解析；**删缓存时用它**）。
  String get spelling => externalSpellingOf(fromId) ?? '';

  @override
  bool operator ==(Object other) =>
      other is ConvergencePair && other.fromId == fromId && other.toId == toId;

  @override
  int get hashCode => Object.hash(fromId, toId);

  @override
  String toString() => '$fromId → $toId';
}

/// 🔑 **纯逻辑**：算出「哪些合成 id 可以收敛」。
///
/// | 输入 | 输出 | 理由 |
/// |---|---|---|
/// | 不是 `ext:` 形态 | 跳过 | 真 id 不受影响 |
/// | 解析不出拼写（`ext:` 后为空）| 跳过 | 畸形数据，不动它 |
/// | 新库里**查不到**该拼写 | **跳过（保留）** | 🔴 **未回流的词必须原样保留** —— 否则它就没卡了 |
/// | 查得到 | 收进计划 | 该词已回流 |
///
/// ⚠️ **幂等**：收敛后 `user.db` 里不再有 `ext:` 候选 → 第二次跑拿到空计划。
///    所以中途失败**可以直接下次启动重来**，不需要断点续传。
///
/// ⚠️ **不改 spelling**：`user_word.spelling` / `card_review_state.spelling` 是冗余列，
///    其一致性由「`word_id` 永久不变 ⇒ 拼写也不变」保证。而 `ext:` 里的拼写
///    已是归一化值、与 `word.db.spelling`（实测全小写）一致
///    → 改它只会多一个能出错的地方。**只改 `word_id`。**
Future<List<ConvergencePair>> planConvergence({
  required Iterable<String> externalWordIds,
  required SpellingResolver resolve,
}) async {
  final out = <ConvergencePair>[];
  final seen = <String>{};
  for (final id in externalWordIds) {
    // 去重（三张表取并集时同一 id 会出现多次）
    if (!seen.add(id)) continue;
    final sp = externalSpellingOf(id);
    if (sp == null) continue;          // 非 ext: 或畸形
    final toId = await resolve(sp);
    if (toId == null) continue;        // 🔴 未回流 → 保留
    out.add(ConvergencePair(fromId: id, toId: toId));
  }
  return out;
}

// ─────────────────────────────────────────────────────────────
// IO 执行
// ─────────────────────────────────────────────────────────────

/// 收敛结果（诊断用；调用方据此打日志）。
class ConvergenceResult {
  const ConvergenceResult({
    required this.converged,
    required this.mergedUserWord,
    required this.mergedReviewState,
    required this.droppedReviewLog,
    required this.clearedCache,
  });

  /// 真的改了 `word_id` 的词数
  final int converged;

  /// `user_word` 里发生「合并」（两边都有、删掉了一行）的次数
  final int mergedUserWord;

  /// `card_review_state` 里发生合并的次数
  final int mergedReviewState;

  /// `review_log` 里因撞 `UNIQUE(word_id, reviewed_at, device_id)` 被丢弃的行数
  final int droppedReviewLog;

  /// 删掉的缓存条数
  final int clearedCache;

  static const empty = ConvergenceResult(
    converged: 0,
    mergedUserWord: 0,
    mergedReviewState: 0,
    droppedReviewLog: 0,
    clearedCache: 0,
  );

  bool get didSomething => converged > 0;

  String describe() => '收敛 $converged 个词（user_word 合并 $mergedUserWord · '
      'card_review_state 合并 $mergedReviewState · '
      'review_log 丢弃 $droppedReviewLog · 清缓存 $clearedCache）';

  @override
  String toString() => 'ConvergenceResult(${describe()})';
}

/// 🔴 三张表里所有 `ext:` 形态的 `word_id`（**取并集**）。
///
/// # 三张表各自的处置（**不是一刀切**）
/// | 表 | 收敛？ | 为什么 |
/// |---|---|---|
/// | `user_word` | ✅ | 它是生词本 → 身份必须唯一 |
/// | `card_review_state` | ✅ | 它是复习状态 → 身份必须唯一（否则复习进度分裂）|
/// | `review_log` | ✅ | 它是**多端同步的最小单位** + 统计口径 → 留着 `ext:` 会与另外两表**不同名** |
/// | `lookup_event` | ❌ **有意不收敛** | 🔴 它是**历史事实**（「当时这个词在词库里没有」）—— 收敛它等于**篡改历史**。且它是纯展示用（「你读到的那句」），不参与复习与生词本 |
///
/// # 为什么要「取并集」而不是「只扫缓存表」
/// 缓存表（`external_word_cache`）看似是「词库外的词」的权威清单 ——
/// 但**它们可能不一致**：缓存被误删/写失败时，`user_word` 里仍有 `ext:` 行。
/// 若只扫缓存，那一行就**永远收敛不了**（用户的复习记录永远指着一个「不存在的词」）。
/// → 取并集更稳（多扫两张小表而已）。
///
/// ⚠️ `LIKE 'ext:%'` 的安全性：`_` 在 LIKE 里是**单字符通配**，
///    而前缀 `ext:` 里**没有** `_`（也没有 `%`）→ 无需 ESCAPE。
///    （若将来改前缀，**必须重新检查这一点**。）
Future<List<String>> externalWordIdsIn(Database db) async {
  final out = <String>{};
  for (final table in ['user_word', 'card_review_state', 'review_log']) {
    final rows = await db.rawQuery(
        "SELECT DISTINCT word_id AS w FROM $table WHERE word_id LIKE 'ext:%'");
    out.addAll(rows.map((r) => r['w'] as String));
  }
  return out.toList(growable: false);
}

/// 执行收敛（**单事务**，见文件头的顺序说明）。
///
/// [userDb] 一定是**可写**连接（`user.db` 是 App 自己的库）。
///
/// [beforeClearCacheHook] ⚠️ **仅供断言使用**（生产调用方**不要**传）。
/// 它在「三张表都改完、即将删缓存」那一刻被调用 —— 让断言能**注入一次失败**，
/// 从而**真实验证原子性**：注入后**一切都不该变**（缓存仍在、三张表仍是 `ext:`）。
/// 若某个步骤被挪出事务，注入的失败就会留下「一半改了、一半没改」的状态。
///
/// 🔑 为什么要这个钩子：**文本断言只能证明「代码这么写的」**
///    （2026-10-01 刚踩过：注入提前 `return` 后纯 `contains` 断言仍全绿）。
///    原子性必须**真跑一次**才算验过。
///
/// ⚠️ 它**不能**用来验证「顺序」—— 同一事务内顺序不影响结果（见文件头）。
Future<ConvergenceResult> convergeExternalWordIds({
  required Database userDb,
  required List<ConvergencePair> pairs,
  void Function()? beforeClearCacheHook,
}) async {
  if (pairs.isEmpty) return ConvergenceResult.empty;

  var mergedUw = 0;
  var mergedCrs = 0;
  var droppedLog = 0;
  var clearedCache = 0;

  await userDb.transaction((txn) async {
    for (final p in pairs) {
      // ── ① user_word ──
      final uw = await _mergeUserWord(txn, p);
      if (uw) mergedUw++;

      // ── ② card_review_state ──
      final crs = await _mergeReviewState(txn, p);
      if (crs) mergedCrs++;

      // ── ③ review_log ──
      droppedLog += await _retargetReviewLog(txn, p);

      // ── ④ 删缓存 ──
      //    🔴 **必须在这个事务体内**（原子性）—— 若挪出去，事务回滚会留下
      //       「表恢复了、缓存已删」⇒ 数据指着 `ext:` 而缓存没了 ⇒ **取不到卡**。
      //    ⚠️ 至于「排在最后」：**同一事务内顺序不影响结果**（见文件头），
      //       写在这里是**防御性**的 —— 防将来有人把某步挪出事务。
      //       （断言把它标为「防御性顺序」，不是「必需」。）
      beforeClearCacheHook?.call();

      final sp = p.spelling;
      if (sp.isNotEmpty) {
        clearedCache += await txn.delete(
          'external_word_cache',
          where: 'spelling = ?',
          whereArgs: [sp],
        );
      }
    }
  });

  return ConvergenceResult(
    converged: pairs.length,
    mergedUserWord: mergedUw,
    mergedReviewState: mergedCrs,
    droppedReviewLog: droppedLog,
    clearedCache: clearedCache,
  );
}

/// 改 `user_word.word_id`；**冲突时保留 `added_at` 更早的那行**。
///
/// 🔑 为什么取「更早」：`added_at` 的语义是**「我第一次收它是什么时候」**
///    （见 `user_word_repository.add()` 的注释 —— 重复查词**刻意不刷新**它）。
///    合并时若取更晚的，就等于**把「第一次」这个事实改错了**。
///
/// 返回是否发生了「合并」（两边都有 → 删掉了一行）。
Future<bool> _mergeUserWord(Transaction txn, ConvergencePair p) async {
  final from = await txn.query('user_word',
      columns: ['added_at'], where: 'word_id = ?', whereArgs: [p.fromId], limit: 1);
  if (from.isEmpty) return false;

  final to = await txn.query('user_word',
      columns: ['added_at'], where: 'word_id = ?', whereArgs: [p.toId], limit: 1);

  if (to.isEmpty) {
    await txn.update('user_word', {'word_id': p.toId},
        where: 'word_id = ?', whereArgs: [p.fromId]);
    return false;
  }

  // ── 冲突：两行都在 ──
  final fromAt = (from.first['added_at'] as String?) ?? '';
  final toAt = (to.first['added_at'] as String?) ?? '';
  if (fromAt.compareTo(toAt) <= 0) {
    // from 更早（或相同）→ 保留 from，删 to
    await txn.delete('user_word', where: 'word_id = ?', whereArgs: [p.toId]);
    await txn.update('user_word', {'word_id': p.toId},
        where: 'word_id = ?', whereArgs: [p.fromId]);
  } else {
    // to 更早 → 保留 to，删 from
    await txn.delete('user_word', where: 'word_id = ?', whereArgs: [p.fromId]);
  }
  return true;
}

/// 改 `card_review_state.word_id`；**冲突时保留 `reps` 更大的那行**。
///
/// 🔑 为什么取「更大」：`reps` = 复习次数，**学得更多的那个才是用户真实的进度**。
///    取小的等于**把学习成果抹掉**。
/// ⚠️ 相等时保留 `to`（已在新 id 上的那行）—— 保证「reps 相同时结果确定」，
///    不依赖遍历顺序。（`stability` / `difficulty` 随之保留 `to` 行的值：
///    FSRS 的三元组应当来自**同一次**计算，混搭会产生不自洽的状态。）
Future<bool> _mergeReviewState(Transaction txn, ConvergencePair p) async {
  final from = await txn.query('card_review_state',
      columns: ['reps'], where: 'word_id = ?', whereArgs: [p.fromId], limit: 1);
  if (from.isEmpty) return false;

  final to = await txn.query('card_review_state',
      columns: ['reps'], where: 'word_id = ?', whereArgs: [p.toId], limit: 1);

  if (to.isEmpty) {
    await txn.update('card_review_state', {'word_id': p.toId},
        where: 'word_id = ?', whereArgs: [p.fromId]);
    return false;
  }

  final fromReps = (from.first['reps'] as num?)?.toInt() ?? 0;
  final toReps = (to.first['reps'] as num?)?.toInt() ?? 0;
  if (fromReps > toReps) {
    await txn.delete('card_review_state', where: 'word_id = ?', whereArgs: [p.toId]);
    await txn.update('card_review_state', {'word_id': p.toId},
        where: 'word_id = ?', whereArgs: [p.fromId]);
  } else {
    await txn.delete('card_review_state',
        where: 'word_id = ?', whereArgs: [p.fromId]);
  }
  return true;
}

/// 把 `review_log` 的 `word_id` 改过去；**撞 `UNIQUE(word_id, reviewed_at, device_id)` 的行丢弃**。
///
/// # 🔑 为什么是「UPDATE OR IGNORE + 随后的 DELETE」
/// ```sql
/// UPDATE OR IGNORE review_log SET word_id = ?1 WHERE word_id = ?2;
/// DELETE FROM review_log WHERE word_id = ?2;
/// ```
/// · **不撞车**的行 → 更新成功（`word_id` 变成 `toId`）→ 后面的 DELETE **碰不到它们**
/// · **撞车**的行 → 被 `OR IGNORE` 跳过（`word_id` 仍是 `fromId`）→ 被 DELETE 删掉
///
/// 🔑 被删掉的是**重复事件**：同一设备、同一时刻、对同一个词评了两次 ——
///    `UNIQUE` 约束的存在本身就说明「这在语义上不可能」。
///    （它们能同时存在，只是因为当时这个词有**两个 id**。）
///
/// 返回被丢弃的行数。
Future<int> _retargetReviewLog(Transaction txn, ConvergencePair p) async {
  await txn.rawUpdate(
      'UPDATE OR IGNORE review_log SET word_id = ? WHERE word_id = ?',
      [p.toId, p.fromId]);
  return await txn.rawDelete(
      'DELETE FROM review_log WHERE word_id = ?', [p.fromId]);
}
