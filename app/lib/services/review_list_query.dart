import 'package:sqflite_common/sqlite_api.dart';

import 'fsrs_service.dart' show ReviewEvent, ReviewState;
import 'highlight_id.dart' show kHighlightIdPrefix;

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
  ///
  /// ⚠️ 三个排序串**都带 `crs.` 前缀** —— 因为 [list] 会 `LEFT JOIN user_word`，
  /// 而 `spelling` / `updated_at` **两表同名列**（都是冗余出来的）→
  /// 不加限定 SQLite 会报 `ambiguous column name`。
  static const String orderMemoryCurve = 'crs.next_review_at ASC';

  /// 最近：最近**加入或复习**的排最前（`ui-ux` §6.2 的「最近」档）。
  ///
  /// 🔴 用 `updated_at` 而**不是** `COALESCE(last_review_at, updated_at)` ——
  /// 后者有个真实反例（本文件的验收脚本抓到的）：
  /// 一个**刚加入但上次复习较早**的词，`last_review_at` 非空 →
  /// `COALESCE` 取到那个较早的时间 → 它会被排到很后面，
  /// 与「最近加入」的语义**相反**。
  /// `updated_at` 在插入与更新时都会刷新，正好同时覆盖「加入」与「复习」两种事件。
  static const String orderRecent = 'crs.updated_at DESC';

  /// A–Z：按拼写（大小写不敏感，与 `idx_crs_spelling` 的 COLLATE 一致）
  static const String orderAlphabetical = 'crs.spelling COLLATE NOCASE ASC';

  /// 三档排序的允许值（防注入：**不接受调用方传任意 SQL**）
  static const Set<String> allowedOrders = {
    orderMemoryCurve,
    orderRecent,
    orderAlphabetical,
  };

  /// 两个 JOIN —— 「暂停 / 不该显示」的状态在**另外两张表**里，本表只放排期。
  ///
  /// | JOIN | 给谁用 | 判据列 |
  /// |---|---|---|
  /// | `user_word uw` | **生词**卡（`w…`）| `uw.deleted`（= 移出生词本 / 暂停）|
  /// | `highlight h` | **划线**卡（`hl:<uuid>`）| `h.deleted`（取消划线）+ `h.paused`（暂停复习）|
  ///
  /// 🔑 JOIN 键：划线卡的 `crs.word_id` 就是**前缀 + 划线 id**（见 `highlight_id.dart`）
  ///    ⇒ `crs.word_id = 'hl:' || h.id`。用常量插值而不是手写 `'hl:'`，
  ///    这样前缀改了口径**只改一处**。
  ///
  /// ⚠️ 代价（如实标注）：JOIN 条件左边是表达式 ⇒ **走不了 `highlight.id` 的索引**，
  ///    对 `highlight` 是全表扫。可接受，因为该表只装**用户自己的划线**
  ///    （量级 10²–10³，SQLite 扫千行在亚毫秒级）。
  ///    真要优化就加一个可索引的冗余列 —— 但那要多维护一处一致性，
  ///    在「问题尚未被观察到」之前不做（同 `trace_markdown` 那条判据）。
  static const String _joins =
      'LEFT JOIN user_word uw ON uw.word_id = crs.word_id '
      'LEFT JOIN highlight h ON crs.word_id = \'$kHighlightIdPrefix\' || h.id ';

  /// 列表**可见性**的四条判据 —— `list` / `count` / `dueCount` **必须共用**。
  ///
  /// 🔴 抽成常量而不是在三处各写一遍：三处不一致会出现
  ///    「列表里 3 条，顶部却写 5 个该复习」这类**自相矛盾**（本文件的设计原则）。
  ///
  /// 🔴 为什么是 `COALESCE(x, 0) = 0` 而不是 `x = 0`：
  ///    一张卡**只会命中其中一个 JOIN**（生词卡在 `highlight` 里没有行、
  ///    划线卡在 `user_word` 里没有行）⇒ 另一个的列是 NULL。
  ///    写成 `h.paused = 0` 会把「JOIN 不上」判成 NULL ⇒ 整行被过滤掉 ⇒
  ///    **所有生词卡都会从复习页消失**。`COALESCE` 把 NULL 当作「不适用」。
  static const List<String> _visibilityWheres = [
    'COALESCE(uw.deleted, 0) = 0', // 生词：移出生词本 / 暂停
    'COALESCE(h.deleted, 0) = 0', // 划线：**已取消**的划线，卡也跟着消失
    'COALESCE(h.paused, 0) = 0', // 划线：**暂停复习**（2026-10-08 新增）
    // ── 🆕 2026-10-09 ④「无主划线卡」不得出现 ──────────────────────────
    "(crs.word_id NOT LIKE '$kHighlightIdPrefix%' OR h.id IS NOT NULL)",
  ];

  /// # 🆕 2026-10-09 ④：**无主划线卡**（孤儿卡）
  ///
  /// ## 现象（白哥真机）
  ///
  /// 复习列表顶部有一张标题显示成 `hl:8613b24d-…` 的卡，**点「暂停」没有任何反应**
  /// （不报错、不提示），而且界面上**没有任何出口**能把它去掉。
  ///
  /// ## 根因（两层，都是既有的设计事实）
  ///
  /// ① `highlight`（划线本体）**从不参与同步** —— 服务端连 `sync_highlight` 表都没有
  ///    （6 张 `sync_*` 表：review_log / user_word / article_read / bookmark /
  ///     book_progress / book）。端侧 push/pull 也不含它。
  /// ② 而 `review_log`（复习事件）**参与同步**，`hl:<uuid>` 的复习事件照常上云。
  ///
  /// ⇒ 一旦本机的 `highlight` 行没了而服务端的复习事件还在（**重装 / 换机 / 清数据**），
  ///    pull 回来的复习事件会被重放成一行 `card_review_state`（`word_id = 'hl:…'`），
  ///    而它引用的划线**在本机不存在** —— 这就是「无主卡」。
  ///    🔴 直查线上确认：`sync_review_log` 里确有 `hl:8613b24d-…` 的事件，
  ///       而该设备的 `highlight` 表里没有它（`user.db` 被重装清掉）。
  ///
  /// ## 🔴 为什么修在**判据层**（而不是在「暂停」按钮上补一段）
  ///
  /// 判据：**补丁 ≠ 修法 —— 判据有洞时先问「还有哪些地方有」再一次性改全。**
  ///    · 无主卡**不是某一次点击的问题**：它出现在**列表**里、被**计数**统计、
  ///      还能被点进翻卡页。修在按钮上只堵住其中一个出口，而且要先让用户**找到并点它**。
  ///    · 而它的成因（重装/换机）**对每个用户都会发生**⇒ 必须一次性、系统性地挡住。
  ///    ⇒ 修在**可见性判据**（`list` / `count` / `dueCount` 三处自动同源）：
  ///      无主卡**立刻全部不可见**，用户不需要做任何动作。
  ///
  /// ## 🔴 为什么**不删**那一行派生数据（曾提过「清掉它的复习状态」）
  ///
  /// 1. **删了也留不住**：`card_review_state` 是 `review_log` 的**派生态**，
  ///    `_applyReviewEvents` 的重放随时能重建它（同 `user_db_schema.sql` 里
  ///    `paused` 那条注释的判据：**「会被重建的表」不能存用户意图**，
  ///    反过来也一样 —— 从它上面删东西，别端一重放就回来了）。
  /// 2. **留着是可恢复的前提**：`paused` 列那条注释记着同族结论 ——
  ///    待「划线纳入同步」上线后，只要那条划线从别端同步回来，
  ///    卡片就会**自动恢复可用**（排期还在）。删掉这一行就把这条恢复路径**永久切断**了。
  /// 3. 它在「不可见」之后**没有任何副作用**（不占屏、不进计数、不影响任何查询）。
  /// ⇒ 📌 判据：**「不显示」是可逆的，「删除」不是** —— 能用前者解决就不要用后者。
  ///
  /// ## ⚠️ 代价（如实标注）
  ///
  /// 这是一个**全表判据**（`crs.word_id` 上的 `LIKE` + `h.id IS NOT NULL`），
  /// 走不了索引 —— 但与 [_joins] 里那个 `'hl:' || h.id` 同性质、同量级
  ///（`card_review_state` 是用户自己的卡，10²–10³ 行）。
  ///
  /// ## 反向断言（防「顺手改成删数据」）
  ///
  /// `verify_review_list.dart` 锁住：判据里**不得**出现 `DELETE`
  /// （清理无主卡唯一允许的手段是「不显示」）。

  /// 列表查询。
  ///
  /// - [search]：按单词搜索。空/仅空白 = 不筛。用 `LIKE 'x%'` **前缀**匹配，
  ///   这样能走 `idx_crs_spelling`；模糊包含（`%x%`）会全表扫，故不提供。
  /// - [order]：必须是 [allowedOrders] 之一（否则回退到记忆曲线）——
  ///   🔑 **白名单而非拼接**，避免「排序字段」成为注入面。
  /// - [dueOnly]：🆕 只取**已到期**的（`next_review_at <= nowUtc`）。
  ///   对应复习页顶部的筛选「显示全部 / 显示已到期」（白哥 2026-09-28 定）。
  ///   ⚠️ 传 `true` 时 [nowUtc] 应一并给出；省略则取当前时刻。
  Future<List<ReviewListItem>> list({
    String? search,
    String order = orderMemoryCurve,
    bool dueOnly = false,
    DateTime? nowUtc,
    int limit = 200,
    int offset = 0,
  }) async {
    final safeOrder = allowedOrders.contains(order) ? order : orderMemoryCurve;
    final q = search?.trim() ?? '';

    final sql = StringBuffer(
      'SELECT crs.word_id, crs.spelling, crs.state, crs.step, crs.reps, crs.lapses, '
      '       crs.stability, crs.difficulty, crs.last_review_at, '
      '       crs.next_review_at, crs.pending_push '
      'FROM card_review_state crs '
      // 🔴 两个 JOIN 与三条可见性判据都走 [_joins] / [_visibilityWheres]
      //    （见那里的长说明）—— 它们是 `list` / `count` / `dueCount` 的**唯一口径**，
      //    别在这里另写一份（三处不一致会出现「列表 3 条但顶部写 5 个」）。
      //
      // ## 为什么是 `LEFT` 而不是 `INNER`（有意的）
      // 以 `card_review_state` 为**主表**（FSRS 状态是复习页的核心）。
      // 一张卡**只会命中其中一个 JOIN**（生词卡在 `highlight` 里没有行、
      // 划线卡在 `user_word` 里没有行）⇒ 用 `INNER` 会让**一半的卡静默消失**；
      // `LEFT` + `COALESCE(..., 0) = 0` 把「不适用」当作「没暂停」。
      // 🔑 「宁可显示一个状态可疑的词，也不让用户的词无声消失」。
      '$_joins',
    );
    final args = <Object?>[];
    final wheres = <String>[..._visibilityWheres];

    if (q.isNotEmpty) {
      // 🔑 ESCAPE 处理通配符：用户搜 `%` 或 `_` 时按字面匹配，而不是当通配符
      wheres.add("crs.spelling LIKE ? ESCAPE '\\'");
      args.add('${_escapeLike(q)}%');
    }
    if (dueOnly) {
      wheres.add('crs.next_review_at <= ?');
      args.add(_iso(nowUtc ?? DateTime.now()));
    }

    sql.write('WHERE ${wheres.join(' AND ')} ');
    sql.write('ORDER BY $safeOrder LIMIT ? OFFSET ?');
    args..add(limit)..add(offset);

    final rows = await _db.rawQuery(sql.toString(), args);
    return rows.map(ReviewListItem.fromRow).toList(growable: false);
  }

  /// 命中筛选条件的总数（分页用；与 [list] 用**同一条件**）
  ///
  /// ⚠️ 三条（`list` / `count` / `dueCount`）必须共用同一套筛选，
  /// 否则会出现「列表 3 条但顶部写 5 个」这类自相矛盾（本文件的设计原则）。
  Future<int> count({
    String? search,
    bool dueOnly = false,
    DateTime? nowUtc,
  }) async {
    final q = search?.trim() ?? '';
    final wheres = <String>[..._visibilityWheres];
    final args = <Object?>[];

    if (q.isNotEmpty) {
      wheres.add("crs.spelling LIKE ? ESCAPE '\\'");
      args.add('${_escapeLike(q)}%');
    }
    if (dueOnly) {
      wheres.add('crs.next_review_at <= ?');
      args.add(_iso(nowUtc ?? DateTime.now()));
    }

    final r = await _db.rawQuery(
      'SELECT count(*) AS n FROM card_review_state crs '
      '$_joins'
      'WHERE ${wheres.join(' AND ')}',
      args,
    );
    return (r.first['n'] as int?) ?? 0;
  }

  /// 「N 个今天该看」—— `next_review_at <= nowUtc` 的条目数。
  ///
  /// 走 `idx_crs_due`（范围扫描）。
  ///
  /// ⚠️ 必须与 [list] / [count] 同样排除**暂停**的词 ——
  /// 否则会出现「顶部说 5 个该看，列表里只数得出 3 个」。
  Future<int> dueCount(DateTime nowUtc) async {
    final r = await _db.rawQuery(
      'SELECT count(*) AS n FROM card_review_state crs '
      '$_joins'
      "WHERE ${_visibilityWheres.join(' AND ')} AND crs.next_review_at <= ?",
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
      'SELECT word_id, spelling, state, step, reps, lapses, stability, difficulty, '
      '       last_review_at, next_review_at, pending_push '
      'FROM card_review_state WHERE word_id = ?',
      [wordId],
    );
    return rows.isEmpty ? null : ReviewListItem.fromRow(rows.first);
  }

  /// 记一条复习日志（`review_log`）—— 卡片的四键提交时调用。
  ///
  /// # 🔑 为什么必须写这张表（不能只更新 `card_review_state`）
  /// 两者分工不同（见 `v1` §3.2）：
  /// · `card_review_state` = **当前状态**（下次什么时候到期）→ 复习页排序用
  /// · `review_log` = **每次评级的流水** → ① 多端同步的**最小单位**
  ///   ② 「今天复习了多少个」这类统计的唯一来源
  ///
  /// 只写前者 → **历史丢失且不可恢复**（重放需要每一次评级的时间和档位）。
  ///
  /// ⚠️ 幂等由表自身的 `UNIQUE (word_id, reviewed_at, device_id)` 保证 →
  ///    用 `INSERT OR IGNORE`（多端拉取重复事件时天然去重）。
  ///
  /// # 🆕 `synced` 参数（2026-10-06 · 云端同步阶段 3）
  ///
  /// | 来源 | 该传什么 | 为什么 |
  /// |---|---|---|
  /// | **本地复习**（用户刚评的） | `0`（默认） | 还没上云 ⇒ 要推 |
  /// | **pull 拉回来的** | **`1`** | 🔴 服务端**已经知道**这些事件 ⇒ 若标 0 会被推回去（**回声**）|
  ///
  /// 🔑 默认值取 `0`（本地复习是最常见的调用方）+ pull 侧**显式**传 `1`
  ///    —— 「默认安全、例外显式」比反过来好：默认 1 会让「忘了传」变成静默漏推。
  Future<void> logReview(ReviewEvent event, {int synced = 0}) async {
    await _db.insert(
      'review_log',
      {...event.toRow(), 'synced': synced},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 某词的全部复习事件（**升序**），用于重放。
  ///
  /// 同步的「重放派生状态」需要它（`FsrsService.replay`）。
  Future<List<ReviewEvent>> eventsOf(String wordId) async {
    final rows = await _db.query(
      'review_log',
      where: 'word_id = ?',
      whereArgs: [wordId],
      orderBy: 'reviewed_at ASC',
    );
    return rows.map(ReviewEvent.fromRow).toList();
  }

  // ───────────────────────────────────────────────────────────
  // 跨设备同步（2026-10-06 · 云端同步阶段 3）
  // ───────────────────────────────────────────────────────────

  /// 待同步的复习事件（`synced = 0`），按 `reviewed_at` 升序。
  ///
  /// 🔑 **为什么带 `rowId`**：`ReviewEvent` 是「事件的值」（业务概念），
  ///    没有行号；而 `markReviewsSynced` 需要精确指向「刚推上去的那几行」。
  ///    用 `(word_id, reviewed_at, device_id)` 三元组也能定位，但那要重复
  ///    拼 SQL 条件且**依赖幂等键不变**；`id` 是表自增主键，更直接。
  ///    ⇒ 用 record 把「值」与「行号」一起带出（不改 `ReviewEvent` 的形状，
  ///      它是 FSRS 的对外类型，不该被 DB 细节污染）。
  ///
  /// ⚠️ `ReviewEvent.fromRow` 要求 `rating` 是**合法档位（1–4）** ——
  ///    表上有 CHECK 约束，所以库里不会出现非法值；这里不再兜底（多一层兜底
  ///    会让「约束失效」这种真问题被静默吞掉）。
  Future<List<({int rowId, ReviewEvent event})>> pendingReviews() async {
    final rows = await _db.query(
      'review_log',
      where: 'synced = 0',
      orderBy: 'reviewed_at ASC',
    );
    return rows
        .map((r) => (
              rowId: (r['id'] as num).toInt(),
              event: ReviewEvent.fromRow(r),
            ))
        .toList();
  }

  /// 标记已同步（push 成功后调用）。
  ///
  /// ⚠️ 同 `ArticleReadRepository.markSynced`：**只在 push 真正成功后调**。
  Future<void> markReviewsSynced(Iterable<int> rowIds) async {
    final ids = rowIds.toList();
    if (ids.isEmpty) return;
    final ph = List.filled(ids.length, '?').join(',');
    await _db.update(
      'review_log',
      {'synced': 1},
      where: 'id IN ($ph)',
      whereArgs: ids,
    );
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
    this.step,
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

  /// 🆕 学习/重学态的**当前步**（`review` 态为 NULL）。
  ///
  /// 🔴 为什么必须补这一列（2026-09-28 加）：
  /// 词卡上的四键要显示「下次 X 天」，那要用 `FsrsService.previewAll` 算 ——
  /// 而它接受的是完整的 `ReviewState`，**`step` 是其中一环**
  /// （`learning` / `relearning` 态的间隔由「第几步」决定）。
  /// 少了它，预览会**当成 step=null 去算**，于是新词四键显示的数字全是错的
  /// —— 而错得**看不出来**（数字看起来照样合理）。
  final int? step;

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

  /// 转成 FSRS 层的 [ReviewState] —— 供 `FsrsService.previewAll` / `apply` 使用。
  ///
  /// 🔑 转换放在**数据层**而不是页面：这是「本库的行 ↔ FSRS 的状态」的字段映射，
  ///    属数据职责；页面不该知道 `step` / `stability` 这些内部单位。
  ///
  /// ⚠️ 字段必须**逐个写全** —— 漏一个（如 `step`）不会报错，
  ///    但会让预览算错（见 [step] 的说明）。断言锁住这个映射。
  ReviewState toReviewState() => ReviewState(
        wordId: wordId,
        state: state,
        step: step,
        stability: stability,
        difficulty: difficulty,
        reps: reps,
        lapses: lapses,
        lastReviewAt: lastReviewAt,
        nextReviewAt: nextReviewAt,
        pendingPush: pendingPush,
      );

  static ReviewListItem fromRow(Map<String, Object?> r) => ReviewListItem(
        wordId: r['word_id']! as String,
        spelling: (r['spelling'] as String?) ?? '',
        state: (r['state'] as int?) ?? 0,
        step: r['step'] as int?,
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
