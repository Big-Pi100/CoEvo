// CoEvo · 收藏（bookmark）仓储 —— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）。
//
// # 依据
// `docs/design/visual-feed-bookmark-2026-09-25.html` §四「数据层：极简」
//   ① `content_id` 直接当主键 —— 收藏没有数量/顺序/分类需求
//   ② 时间戳 DESC 排序（「我刚存了什么」的直觉）
//   ③ 跟着已有同步机制（`pending_push` + 增量 pull/push）
//   ④ **取消收藏 = `DELETE`** —— 收藏是**可再生的用户意图**，与「生词本不能硬删」不同
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

  /// 收藏时刻 —— **UTC ISO8601**（库中该列恒带 `Z`）。
  final DateTime bookmarkedAt;

  /// 是否待同步（`pending_push = 1`）。
  final bool pendingPush;

  const Bookmark({
    required this.contentId,
    required this.bookmarkedAt,
    required this.pendingPush,
  });

  @override
  bool operator ==(Object other) =>
      other is Bookmark &&
      other.contentId == contentId &&
      other.bookmarkedAt == bookmarkedAt &&
      other.pendingPush == pendingPush;

  @override
  int get hashCode => Object.hash(contentId, bookmarkedAt, pendingPush);

  @override
  String toString() =>
      'Bookmark(#$contentId @ ${bookmarkedAt.toIso8601String()}${pendingPush ? ' · 待同步' : ''})';
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
    final rows = await _db.query('bookmark', columns: ['content_id']);
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
    await _db.insert(
      'bookmark',
      {
        'content_id': contentId,
        // 不传 `bookmarked_at` / `pending_push` —— 由 DDL 的 DEFAULT 生成。
        // 🔑 为什么不在 Dart 侧生成时间戳：那样「同一时刻」这个语义就取决于客户端时钟；
        //    而 DEFAULT 用的是**数据库时钟**，与 `card_review_state` 同源。
        //    （也顺便避免了 Dart/UTC 格式化写错时区。）
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    _ids.add(contentId);
    return true;
  }

  /// 取消收藏。
  ///
  /// 🔑 **硬删**（设计稿 §四 ④ 明确）—— 与「生词本不能硬删」不同：
  /// 收藏是可再生的用户意图，删了再点一次就回来了，没有学习数据损失。
  ///
  /// 返回 `true` = **本次真的删掉了**（UI 可据此决定要不要弹 toast）。
  Future<bool> remove(int contentId) async {
    if (!_ids.contains(contentId)) return false;
    await _db.delete(
      'bookmark',
      where: 'content_id = ?',
      whereArgs: [contentId],
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
        pendingPush: (r['pending_push'] as num).toInt() == 1,
      );
}

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
DateTime parseUserDbUtc(String raw) {
  if (!raw.endsWith('Z')) {
    throw FormatException(
      '时间串不是 UTC ISO8601（缺尾随 Z）："$raw"。'
      '本库硬约束：所有时间列必须带 Z（无时区标记会被 DateTime.parse 按本地时间解释）。',
    );
  }
  return DateTime.parse(raw);
}
