import 'package:sqflite_common/sqlite_api.dart';

/// 复习列表查询 —— `user.db` 侧，**纯 Dart，不 import Flutter**。
///
/// ## 为什么需要它
///
/// 复习页是**单一列表**（无「移入移出」，见 `ui-ux` §6.2），它要同时满足：
/// - 三档排序：**记忆曲线**（默认，按到期时间）/ 最近 / A–Z
/// - **按单词搜索**
/// - 分组：「今天该复习 / 之后」+ 顶部「N 个今天该看」
///
/// ## 为什么能完全不碰 `word.db`
///
/// 排序与搜索**只依赖 `spelling` + `next_review_at`**，二者都在本库：
/// - `next_review_at` → 索引 `idx_crs_due`
/// - `spelling` → 索引 `idx_crs_spelling`（**冗余列**，跨库方案 A，2026-09-26 白哥已定）
///
/// → 列表查询是**单库**操作。只有在渲染某一项、需要取**释义**时才按需查 `word.db`
/// （`WordQueryService.lookup`，~43 µs/词，且列表虚拟化后只查可见项）。
///
/// ## 刻意不做的事：熟度三点的映射
///
/// 按「**库级只回答可不可以，渲染层决定展示**」的架构约定
/// （见 `mnemonic-layer-separation`），本层**只返回原始 `state` / `reps`**，
/// **不输出 `dots: 2` 这类渲染判定** —— 三点怎么画是渲染层的事，改规则不应动数据层。
class ReviewListQuery {
  ReviewListQuery(this._db);

  final Database _db;

  /// 记忆曲线（默认）：按到期时间升序 —— 最该看的排最前
  static const String orderMemoryCurve = 'next_review_at ASC';

  /// 最近：最近**加入或复习**的排最前（`ui-ux` §6.2 的「最近」档）。
  ///
  /// 🔴 用 `updated_at` 而**不是** `COALESCE(last_review_at, updated_at)` ——
  /// 后者有个真实反例（本文件的验收脚本抓到的）：
  /// 一个**刚加入但上次复习较早**的词，`last_review_at` 非空 →
  /// `COALESCE` 取到那个较早的时间 → 它会被排到很后面，
  /// 与「最近加入」的语义**相反**。
  /// `updated_at` 在插入与更新时都会刷新，正好同时覆盖「加入」与「复习」两种事件。
  static const String orderRecent = 'updated_at DESC';

  /// A–Z：按拼写（大小写不敏感，与 `idx_crs_spelling` 的 COLLATE 一致）
  static const String orderAlphabetical = 'spelling COLLATE NOCASE ASC';

  /// 三档排序的允许值（防注入：**不接受调用方传任意 SQL**）
  static const Set<String> allowedOrders = {
    orderMemoryCurve,
    orderRecent,
    orderAlphabetical,
  };

  /// 列表查询。
  ///
  /// - [search]：按单词搜索。空/仅空白 = 不筛。用 `LIKE 'x%'` **前缀**匹配，
  ///   这样能走 `idx_crs_spelling`；模糊包含（`%x%`）会全表扫，故不提供。
  /// - [order]：必须是 [allowedOrders] 之一（否则回退到记忆曲线）——
  ///   🔑 **白名单而非拼接**，避免「排序字段」成为注入面。
  Future<List<ReviewListItem>> list({
    String? search,
    String order = orderMemoryCurve,
    int limit = 200,
    int offset = 0,
  }) async {
    final safeOrder = allowedOrders.contains(order) ? order : orderMemoryCurve;
    final q = search?.trim() ?? '';

    final sql = StringBuffer(
      'SELECT word_id, spelling, state, reps, lapses, stability, difficulty, '
      '       last_review_at, next_review_at, pending_push '
      'FROM card_review_state ',
    );
    final args = <Object?>[];

    if (q.isNotEmpty) {
      // 🔑 ESCAPE 处理通配符：用户搜 `%` 或 `_` 时按字面匹配，而不是当通配符
      sql.write("WHERE spelling LIKE ? ESCAPE '\\' ");
      args.add('${_escapeLike(q)}%');
    }
    sql.write('ORDER BY $safeOrder LIMIT ? OFFSET ?');
    args..add(limit)..add(offset);

    final rows = await _db.rawQuery(sql.toString(), args);
    return rows.map(ReviewListItem.fromRow).toList(growable: false);
  }

  /// 命中搜索的总数（分页用；与 [list] 用同一筛选条件）
  Future<int> count({String? search}) async {
    final q = search?.trim() ?? '';
    if (q.isEmpty) {
      final r = await _db.rawQuery('SELECT count(*) AS n FROM card_review_state');
      return (r.first['n'] as int?) ?? 0;
    }
    final r = await _db.rawQuery(
      "SELECT count(*) AS n FROM card_review_state WHERE spelling LIKE ? ESCAPE '\\'",
      ['${_escapeLike(q)}%'],
    );
    return (r.first['n'] as int?) ?? 0;
  }

  /// 「N 个今天该看」—— `next_review_at <= nowUtc` 的条目数。
  ///
  /// 走 `idx_crs_due`（范围扫描）。
  Future<int> dueCount(DateTime nowUtc) async {
    final r = await _db.rawQuery(
      'SELECT count(*) AS n FROM card_review_state WHERE next_review_at <= ?',
      [_iso(nowUtc)],
    );
    return (r.first['n'] as int?) ?? 0;
  }

  /// 把列表切成「今天该复习 / 之后」两组。
  ///
  /// 与 [dueCount] 用同一判据（`next_review_at <= nowUtc`），
  /// 保证「顶部计数」与「分组标题」不会打架。
  static ({List<ReviewListItem> due, List<ReviewListItem> later}) group(
    List<ReviewListItem> items,
    DateTime nowUtc,
  ) {
    final due = <ReviewListItem>[];
    final later = <ReviewListItem>[];
    for (final it in items) {
      (it.isDue(nowUtc) ? due : later).add(it);
    }
    return (due: due, later: later);
  }

  /// 写入一行复习状态（`INSERT OR REPLACE`）。
  ///
  /// `spelling` 是**必传参数**（与 `ReviewState.toRow({required spelling})` 对齐）——
  /// 冗余列不能忘，否则 `NOT NULL` 约束会拦（这是刻意的编译期 + 约束期双重保障）。
  Future<void> upsertState({
    required String wordId,
    required String spelling,
    int state = 0,
    int? step,
    double? stability,
    double? difficulty,
    int reps = 0,
    int lapses = 0,
    DateTime? lastReviewAt,
    required DateTime nextReviewAt,
    int pendingPush = 1,
  }) async {
    await _db.rawInsert(
      'INSERT OR REPLACE INTO card_review_state '
      '(word_id, spelling, state, step, stability, difficulty, reps, lapses, '
      ' last_review_at, next_review_at, pending_push, updated_at) '
      "VALUES (?,?,?,?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))",
      [
        wordId,
        spelling,
        state,
        step,
        stability,
        difficulty,
        reps,
        lapses,
        lastReviewAt == null ? null : _iso(lastReviewAt),
        _iso(nextReviewAt),
        pendingPush,
      ],
    );
  }

  /// 取某一词的复习状态（查词后决定「已在生词本」还是「新增」）
  Future<ReviewListItem?> stateOf(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT word_id, spelling, state, reps, lapses, stability, difficulty, '
      '       last_review_at, next_review_at, pending_push '
      'FROM card_review_state WHERE word_id = ?',
      [wordId],
    );
    return rows.isEmpty ? null : ReviewListItem.fromRow(rows.first);
  }

  // ── 内部 ────────────────────────────────────────────────────

  /// UTC ISO8601（带 `Z`）—— 与 `fsrs_service` 的约定一致，也是 FSRS 的硬要求
  static String _iso(DateTime dt) => dt.toUtc().toIso8601String();

  /// 转义 `LIKE` 的通配符，使搜索按字面匹配
  static String _escapeLike(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
}

/// 复习列表的一项。**不含渲染字段**（如「熟度几点」）—— 那是渲染层的事。
class ReviewListItem {
  ReviewListItem({
    required this.wordId,
    required this.spelling,
    required this.state,
    this.reps = 0,
    this.lapses = 0,
    this.stability,
    this.difficulty,
    this.lastReviewAt,
    required this.nextReviewAt,
    this.pendingPush = 0,
  });

  final String wordId;

  /// 冗余列（来自 `word.db`，写入时同步）
  final String spelling;

  /// 0 未学 / 1 learning / 2 review / 3 relearning
  final int state;

  final int reps;
  final int lapses;
  final double? stability;
  final double? difficulty;
  final DateTime? lastReviewAt;
  final DateTime nextReviewAt;
  final int pendingPush;

  bool isDue(DateTime nowUtc) => !nextReviewAt.isAfter(nowUtc.toUtc());

  /// 距到期时长（负数 = 已过期）—— 界面显示「已到期 / 2 小时 / 4 天」
  Duration untilDue(DateTime nowUtc) => nextReviewAt.difference(nowUtc.toUtc());

  static ReviewListItem fromRow(Map<String, Object?> r) => ReviewListItem(
        wordId: r['word_id']! as String,
        spelling: (r['spelling'] as String?) ?? '',
        state: (r['state'] as int?) ?? 0,
        reps: (r['reps'] as int?) ?? 0,
        lapses: (r['lapses'] as int?) ?? 0,
        stability: (r['stability'] as num?)?.toDouble(),
        difficulty: (r['difficulty'] as num?)?.toDouble(),
        lastReviewAt: _parse(r['last_review_at'] as String?),
        nextReviewAt: _parse(r['next_review_at'] as String?) ?? DateTime.now().toUtc(),
        pendingPush: (r['pending_push'] as int?) ?? 0,
      );

  static DateTime? _parse(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s)?.toUtc();
}
