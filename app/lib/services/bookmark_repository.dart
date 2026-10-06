// CoEvo · 收藏（bookmark）仓储 —— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）。
//
// # 依据
// `docs/design/visual-feed-bookmark-2026-09-25.html` §四「数据层：极简」
//   ① `content_id` 直接当主键 —— 收藏没有数量/顺序/分类需求
//   ② 时间戳 DESC 排序（「我刚存了什么」的直觉）
//   ③ 跟着已有同步机制（`pending_push` + 增量 pull/push）
//   ④ ~~**取消收藏 = `DELETE`**（硬删）~~ → 🔴 **2026-10-05 改为「软删」**（`deleted` 字段）
//      **为什么改**：跨设备同步的合并是**并集**，而并集**只增不减** ⇒ 硬删会让
//      「另一端取消掉的收藏」在下次同步时**被并回来**（用户看到「删了又自己回来」，
//      且**无从解释**）。改成字段值后，合并规则变成「按时间取较新」，问题**消失**。
//      📄 `docs/design/sync-implementation-assessment-2026-10-04.md` §3.3
//      ⚠️ 设计稿 §四 ④ 那句「可再生的用户意图 ⇒ 可以硬删」在**无同步**时成立；
//        引入同步后**不再成立** —— 这是**同步需求引入的改变**，不是原设计有误。
//   ⑤ 收藏数不单独存，`COUNT(*)` 即可
//
// # 设计稿 §三 ④ 那条约束（**代码级落实**）
// > 「⚠️ 收藏 ≠ 已读标记。收藏是**用户主动的意图**（「我还要再读」），不是系统状态。
// >  **所以不自动收藏、不预置、不根据阅读时长推断** —— 保持它的语义纯净。」
//
// → 本仓储**只提供**「用户点了一下」这一个入口（`add` / `remove` / `toggle`）。
//    **没有** `markRead`、`autoBookmark`、`recordReadingTime` 之类的方法，
//    也不接受「阅读进度」参数。**语义纯净靠接口形状保证，不靠注释提醒。**

import 'package:sqflite_common/sqlite_api.dart';

/// 一条收藏记录。
class Bookmark {
  /// 内容 id（一篇文章一个）。
  final int contentId;

  /// **最后一次改变收藏状态的时刻** —— **UTC ISO8601**（库中该列恒带 `Z`）。
  ///
  /// # 🔴 语义在 v6（软删）之后变宽了，别按旧含义理解
  ///
  /// 软删之前：`remove()` 是 `DELETE`（行没了）⇒ 本列只能是「收藏时刻」。
  /// 软删之后：行会留下 ⇒ **取消收藏也必须刷新本列**，否则有两个后果：
  ///   ① **同步被丢弃**：服务端按 `bookmarked_at` 比大小决定谁赢（`>`），
  ///      若取消不刷新，取消传上去的值与收藏时**同值** ⇒ `t > t` 为假
  ///      ⇒ 服务端**保留旧的 `deleted = 0`** ⇒ 另一台拉回去
  ///      ⇒ 用户看到「**取消了的收藏又自己回来**」（软删本来就是为了解决它）。
  ///   ② **「最近操作」无法排序**（收藏列表按本列倒序）。
  /// 📄 详见 `docs/design/sync-implementation-assessment-2026-10-04.md` §3.3.3
  ///
  /// ⚠️ 已知边界：判定用**严格大于**（`>`）。若取消与收藏落在**同一毫秒**，
  ///    取消会被丢弃。人手操作不可能撞上毫秒，且改 `>=` 会让「重复推送」
  ///    也刷新服务端收货时间（**破坏幂等**）⇒ 有意的取舍，别顺手改成 `>=`。
  final DateTime bookmarkedAt;

  /// 是否已取消收藏（**软删**，`deleted = 1`）。
  ///
  /// 🔑 软删的行**仍在表里**（同步需要把「删除」这件事推出去）。
  ///    ⇒ 凡是**读**收藏清单的地方都必须按本字段过滤（`WHERE deleted = 0`）；
  ///      凡是**推**同步的地方都必须带上本字段（否则别端不知道你取消了）。
  final bool deleted;

  /// 是否待同步（`pending_push = 1`）。
  final bool pendingPush;

  const Bookmark({
    required this.contentId,
    required this.bookmarkedAt,
    this.deleted = false,
    required this.pendingPush,
  });

  @override
  bool operator ==(Object other) =>
      other is Bookmark &&
      other.contentId == contentId &&
      other.bookmarkedAt == bookmarkedAt &&
      other.deleted == deleted &&
      other.pendingPush == pendingPush;

  @override
  int get hashCode => Object.hash(contentId, bookmarkedAt, deleted, pendingPush);

  @override
  String toString() => 'Bookmark(#$contentId @ ${bookmarkedAt.toIso8601String()}'
      '${deleted ? ' · 已取消' : ''}${pendingPush ? ' · 待同步' : ''})';
}

/// 收藏仓储。
///
/// ## 为什么用「全量载入内存集合」而不是每次查库
///
/// 收藏的读取形态是**两个高频问题**：
/// 1. 「这篇文章收藏了吗？」—— 信息流每张卡片都要问（滚动时反复问）
/// 2. 「收藏数是多少？」—— 标题栏一直显示
///
/// 若每次都 `SELECT`：
/// - 问题 1 变成「每张卡一次查询」→ 列表滚动时 N 次 IO
/// - 问题 2 变成「每次 build 一次 `COUNT(*)`」
///
/// 而收藏的**数据量极小**（设计稿 §四 ⑤：「单用户量级极小」）→
/// 启动时 `SELECT content_id` 全量载入一个 `Set<int>`，两个问题都变成**内存操作**。
///
/// 🔑 这是「按访问形态选数据结构」，不是「为了快」：
/// 收藏的访问是**读多写极少 + 单条判定**，正是集合的强项。
/// ⚠️ 代价：多端同步后用**外部写入**（另一台的增量 push 落库）时，
///    本层的内存集合不会自动刷新 → 需要显式 `reload()`。
///    **当前无多端同步**（Phase 3），所以先如实记下，不提前造同步机制。
class BookmarkRepository {
  BookmarkRepository(this._db);

  final Database _db;

  /// 内存中的收藏集合 —— 「收藏了吗」与「收藏数」都走它。
  Set<int> _ids = <int>{};

  /// 当前收藏数（**不发查询**）。
  int get count => _ids.length;

  /// 全部已收藏的 content_id（**只读视图**，避免外部改到内部状态）。
  Set<int> get ids => Set.unmodifiable(_ids);

  /// 是否已收藏。
  bool contains(int contentId) => _ids.contains(contentId);

  /// 从库中重新载入（打开后必须调一次；外部写入后也可调）。
  Future<void> reload() async {
    // 🔴 v6 起必须 `WHERE deleted = 0` —— 否则「取消过的收藏」会被当成已收藏
    final rows = await _db.query('bookmark',
        columns: ['content_id'], where: 'deleted = 0');
    _ids = {
      for (final r in rows) (r['content_id'] as num).toInt(),
    };
  }

  /// 收藏一篇文章。**已收藏则什么都不做**（幂等，不刷新时间戳）。
  ///
  /// 🔑 幂等而非「刷新时间戳」的理由：`bookmarked_at` 表达「我什么时候存的」，
  /// 重复点击不该把它改成「我什么时候又点了一次」——
  /// 后者会让「最近收藏」列表的顺序被无意义的重复点击搅乱。
  ///
  /// 返回 `true` = **本次真的新增了**（UI 可据此决定要不要弹 toast）。
  Future<bool> add(int contentId) async {
    if (_ids.contains(contentId)) return false;
    // 🔴 **不能用 `INSERT OR IGNORE`**（v6 软删引入的真陷阱）：
    //    若这一行**曾经被软删**（`deleted = 1`），PK 冲突会让 `INSERT` 被**忽略**
    //    ⇒ 那行仍是 `deleted = 1` ⇒ **收藏不生效**，而界面看着「点了没反应」（**静默**）。
    // ✅ 用 upsert：不存在则插；存在则**归零 + 刷新 `bookmarked_at`**。
    //    🔑 刷新时间是设计要求的（`sync-...-assessment` §3.3.3 第 3 条）：
    //       「重新收藏」= 重新计时，否则它在「最近收藏」列表里的位置是错的。
    // ⚠️ 时间用 `kSqlNowUtc`（毫秒精度）而非 Dart 侧生成 ——
    //    与 DDL 的 DEFAULT **同一表达式**（同一口径），且不依赖客户端时钟。
    // 🔴 **首次插入也要显式给 `bookmarked_at`** —— 否则走 DDL 的 DEFAULT，
    //    而「走 DEFAULT 的插入」与「走本表达式的 upsert」若精度不同，
    //    同一列会混出两种精度（`.000Z` 与 `.123Z`）⇒ 详见 `kSqlNowUtc` 的注释。
    await _db.rawInsert(
      '''
      INSERT INTO bookmark (content_id, deleted, bookmarked_at)
      VALUES (?, 0, $kSqlNowUtc)
      ON CONFLICT (content_id) DO UPDATE SET
        deleted       = 0,
        bookmarked_at = $kSqlNowUtc,
        pending_push  = 1
      ''',
      [contentId],
    );
    _ids.add(contentId);
    return true;
  }

  /// 取消收藏。
  ///
  /// 🔴 **软删**（`deleted = 1`，v6 起）—— 不再是硬删。
  ///
  /// **为什么**：见文件头 §④ —— 并集同步下硬删会被别端「并回来」。
  /// ⚠️ 已删行**不会被清理**（一期刻意不做：一篇文章一行、几十字节，量极小）。
  ///    若将来要清，注意「清早了会让已删收藏复活」，且是**间歇性**的（难复现）。
  ///
  /// 返回 `true` = **本次真的删掉了**（UI 可据此决定要不要弹 toast）。
  Future<bool> remove(int contentId) async {
    if (!_ids.contains(contentId)) return false;
    // 🔑 `pending_push = 1` 必须一起置 —— 同步要能**把「删除」这件事推出去**
    //    （这正是软删相对硬删的**直接好处**：删除变成了一个可传输的字段值）。
    //
    // 🔴 `bookmarked_at` 也**必须刷新** —— 这不是「顺手更新」，是**同步的正确性前提**：
    //    服务端按 `excluded.bookmarked_at > sync_bookmark.bookmarked_at` 判谁赢。
    //    若取消不刷新，取消的值与收藏时**同值** ⇒ `t > t` 假 ⇒ 服务端保留 `deleted = 0`
    //    ⇒ 别的设备拉回去 ⇒ **「取消了的收藏又自己回来」**。
    //    ⚠️ 这条 2026-10-06 才发现 —— 上一版只置 `deleted`，**看起来对但同步是坏的**。
    //    实测依据：`scripts/query_verify/bin/verify_sync_merge.dart`【3】
    //    （断言「取消后 bookmarked_at 严格大于收藏时」）。
    //
    // ⚠️ 时间用 `kSqlNowUtc`（**毫秒**，理由见该常量注释）—— 精度不足会让
    //    「同一秒内 收藏→取消」得到相同时间戳 ⇒ 服务端 `t > t` 假 ⇒ 丢弃取消。
    await _db.rawUpdate(
      "UPDATE bookmark SET deleted = 1, pending_push = 1, "
      "bookmarked_at = $kSqlNowUtc "
      "WHERE content_id = ?",
      [contentId],
    );
    _ids.remove(contentId);
    return true;
  }

  /// 切换收藏。返回**切换后**是否处于已收藏状态。
  Future<bool> toggle(int contentId) async {
    if (_ids.contains(contentId)) {
      await remove(contentId);
      return false;
    }
    await add(contentId);
    return true;
  }

  /// 收藏清单（按收藏时间**倒序** —— 「我刚存了什么」）。
  ///
  /// ⚠️ 只在**打开收藏清单时**调用（一次查询即可）；信息流的「收藏了吗」
  /// 走 [contains]，不要用本方法（那会为了一个布尔值拉全表）。
  Future<List<Bookmark>> list({int? limit, int? offset}) async {
    final rows = await _db.query(
      'bookmark',
      // 🔴 必须过滤 —— 软删的行仍在表里，漏了它界面会显示「已取消的收藏」
      where: 'deleted = 0',
      orderBy: 'bookmarked_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// 待同步的收藏（`pending_push = 1`）—— 供将来的增量 push 用。
  ///
  /// ⚠️ 当前**无调用方**（同步机制属 Phase 3）——
  /// 放在这里是因为「表有了、索引有了、查询也有了」才算一个完整的数据层，
  /// 而少这一块会让后人误以为「同步要从零写」。
  Future<List<Bookmark>> pending() async {
    final rows = await _db.query(
      'bookmark',
      where: 'pending_push = 1',
      orderBy: 'bookmarked_at ASC', // 同步按**发生顺序**推，不是倒序
    );
    return rows.map(_fromRow).toList();
  }

  /// 标记已同步（供将来的 push 成功后调用）。
  Future<void> markSynced(Iterable<int> contentIds) async {
    final ids = contentIds.toList();
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.update(
      'bookmark',
      {'pending_push': 0},
      where: 'content_id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  Bookmark _fromRow(Map<String, Object?> r) => Bookmark(
        contentId: (r['content_id'] as num).toInt(),
        bookmarkedAt: parseUserDbUtc(r['bookmarked_at'] as String),
        // ⚠️ 用 `as num?` 而非 `as num`：调用方若只 `SELECT` 了部分列（未取 `deleted`），
        //    缺失应**当作未删除**而不是抛 `TypeError`。
        //    📌 但「缺失」与「真的是 0」在这里结果相同 ⇒ 真漏了列**不会报错**
        //    ⇒ 由 `verify_sync_merge.dart` 的「列名与 schema 一致」断言兜。
        deleted: (r['deleted'] as num?)?.toInt() == 1,
        pendingPush: (r['pending_push'] as num).toInt() == 1,
      );
}

/// `user.db` 时间列的 **SQLite「当前时刻」表达式 —— 真·唯一口径**。
///
/// # 🔴 为什么必须是**毫秒**（`%f`）而不是秒（`%S`）
///
/// 同步的合并判定是「**谁的时间戳更新谁赢**」（服务端 `excluded.x > table.x`，
/// 严格大于）。若精度只到秒，**同一秒内的两次操作会得到相同时间戳** ⇒
/// 后者**永不生效**：
///
/// | 场景 | 秒精度 | 毫秒精度 |
/// |---|---|---|
/// | 点收藏 → 马上点取消（< 1s） | 两个时间戳**相同** ⇒ 服务端**丢弃取消** ⇒ 别端拉回去 = 「取消了的收藏又自己回来」 | 区分得开 ✅ |
/// | 读书滚动 → 进度连更（同秒多次） | 后一次进度**不生效** | ✅ |
///
/// ⚠️ 而**人手操作完全可能落在同一秒**（点一下收藏、后悔了立刻再点一下）。
/// 📌 判据：**判定的时间粒度 ≤ 两次操作的最小间隔**。这里最小间隔是人手点击
///     （~0.2 s）⇒ 必须毫秒；用秒就是「有窗口的缺陷」，且**只在多设备时可见**
///     （单设备本地永远是对的，因为它不走合并）。
///
/// # 🔑 为什么是一个常量，而不是各处内联
///
/// 这个表达式原先在 `bookmark_repository`（2 处内联）与 `user_word_repository`
/// （`_nowUtcSql`）里各写一份 ⇒ **改一处漏一处**（本次正是如此：改 bookmark 时
/// 才发现 user_word 那份也要改）。⇒ 收敛到一处（同 `parseUserDbUtc` 的理由）。
///
/// ⚠️ 与 DDL 的 `DEFAULT` 是**同一个表达式**（`user_db_schema.sql` 里那几个时间列
/// 也用 `%f`）—— 两处必须一致，否则「走 DEFAULT 的插入」与「走本常量的更新」
/// 会产出不同精度的值。断言见 `verify_sync_merge.dart`【12】。
const String kSqlNowUtc = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";

/// 解析 `user.db` 里的 UTC ISO8601 时间串（**公开以便独立断言**）。
///
/// 🔴 **必须显式要求尾随 `Z`**，不能只靠 `DateTime.parse`：
/// - 带 `Z` → 正确解析为 UTC ✅
/// - **漏 `Z` → `DateTime.parse` 静默按本地时区解释** 🔴
///
/// 后果不是「报错」，而是**静默的时间错位**：UTC+8 的机器上，
/// `2026-09-27T05:00:00`（本意是 UTC）会被读成本地 05:00 = UTC 21:00 前一天，
/// 于是「刚收藏的」显示成「昨天」，而且**没有任何异常**。
/// → 所以这里**宁可抛错也不猜**：缺 `Z` 说明写入侧有 bug，应当当场暴露。
///
/// 🔑 这条与 `fsrs_service.dart` 的 UTC 校验同源 —— 那个坑是「fsrs 包只支持 UTC，
/// 传本地时间会抛 ArgumentError」，这个是「漏 `Z` 不抛错、只是算错」，更难发现。
///
/// ⚠️ 本函数接受**任意精度**（`…:00Z` 与 `…:00.123Z` 都行）—— 库里两类混存是
///   正常现象（历史数据秒精度、v6 之后毫秒）。比较时间请用
///   `sync_merge.dart` 的 `isNewer`/`isEarlier`（**语义比较**），
///   若用字符串比较，这两种写法在**同一时刻**的次序是**反的**。
DateTime parseUserDbUtc(String raw) {
  if (!raw.endsWith('Z')) {
    throw FormatException(
      '时间串不是 UTC ISO8601（缺尾随 Z）："$raw"。'
      '本库硬约束：所有时间列必须带 Z（无时区标记会被 DateTime.parse 按本地时间解释）。',
    );
  }
  return DateTime.parse(raw);
}
