// CoEvo · 书签仓储（`book.db` 的 `book_marker` 表）
//
// 🔴 **本文件不得 import 任何 Flutter 包** —— 它要被「真库断言脚本」驱动
//    （`sqflite_common_ffi`）跑，那是在纯 Dart 进程里。
//
// # 与 `HighlightRepository` 的关系：**同族、不同库、不同型**
//
// | | `HighlightRepository` | 本类 |
// |---|---|---|
// | 库 | `user.db`（学习状态）| **`book.db`**（用户内容）|
// | 表 | `highlight` | `book_marker` |
// | 有文字/笔记吗 | ✅ 有（`text` / `note`）| ❌ **没有**（书签是位置）|
// | 进复习吗 | ✅ 进（写 `card_review_state`）| ❌ **不进** |
//
// ⇒ 两者**不共用一个仓储**：库不同（事务边界不同）、字段不同、下游不同。
//    📌 判据：「**共用数据 ≠ 同判据**」的另一面 —— **不同库的东西不要硬凑一个仓储**。
//
// # 🔴 时间戳口径
//
// 存 **ISO8601 UTC 字符串**（`toUtc().toIso8601String()`）——
// 与同库的 `book.added_at` **同口径**（那一列也是 Dart 侧生成的 ISO8601 UTC）。
// ⚠️ **不要混格式**：同一个库里两种格式会让 `sync_merge.isNewer` 的比较出错，
//    而且 `user.db` 用的是 SQL 侧 `kSqlNowUtc`（毫秒）—— 那是**另一个库**的约定，
//    不要搬过来（📌 判据：跨库口径不要顺手统一，它们各自有理由）。

import 'package:sqflite_common/sqlite_api.dart';

import 'book_marker.dart';

class BookMarkerRepository {
  BookMarkerRepository(this._db);

  final Database _db;

  /// 打一条书签（`id` 与 `createdAt` 由**调用方注入** —— 便于断言与统一生成点）。
  ///
  /// ⚠️ 本方法**不去重**：「同一位置不重复」由调用方的
  /// [findAt] → [remove] / [add] 这条组合保证（见类文档与 `book_marker.dart` 的容差说明）。
  /// 🔑 不在这里做去重的原因：**「点一下 = 打/取消」需要先问「当前在不在书签处」**，
  ///    而那个判断还要服务 UI 的图标状态 ⇒ 让 UI 与写入**共用同一个询问**
  ///    （`findAt`），而不是各判一次（两处判据迟早会漂）。
  Future<void> add({
    required String id,
    required String bookId,
    required int chapterIdx,
    required double scrollRatio,
    required String excerpt,
    required DateTime createdAt,
  }) async {
    await _db.insert(
      'book_marker',
      {
        'id': id,
        'book_id': bookId,
        'chapter_idx': chapterIdx,
        'scroll_ratio': scrollRatio,
        'excerpt': excerpt,
        'created_at': createdAt.toUtc().toIso8601String(),
        'deleted': 0,
      },
      // 🔑 `replace` 而不是 `ignore` —— 同 id 重复插入要**覆盖**而不是静默失败
      //    （`INSERT OR IGNORE` 那个陷阱已在 `highlight` 的 upsert 上踩过一次：
      //     软删过的 id 再也加不回来，而界面看着「点了没反应」）。
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 某本书的全部书签（**未删除**，按**位置**排序：章 → 章内比例）。
  ///
  /// 🔑 按位置而不是按时间：找地方是按顺序找，不是按「我什么时候标的」找。
  Future<List<BookMarker>> listForBook(String bookId) async {
    final rows = await _db.query(
      'book_marker',
      where: 'book_id = ? AND deleted = 0',
      whereArgs: [bookId],
      orderBy: 'chapter_idx ASC, scroll_ratio ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 找「当前位置」是否已在某条书签处（**容差内**）—— 供「点一下 = 打/取消」用。
  ///
  /// 🔴 容差在 **SQL 里**用 `ABS(...) <= ?` 判（不是取回来在 Dart 侧比）：
  ///    免得为了一次询问把整本书的书签都读出来。
  ///    ⚠️ 但**容差的定义只有一处**（`kBookmarkSamePositionTolerance`），
  ///       这里只是把它传进 SQL —— 不是另写一个判据。
  ///
  /// ⚠️ SQLite 的 `ABS()` 对 REAL 可用；`deleted = 0` 必须带上，
  ///    否则「取消过的位置」会被当成「已在书签处」⇒ 再点变成「取消一条已取消的」。
  Future<BookMarker?> findAt({
    required String bookId,
    required int chapterIdx,
    required double scrollRatio,
    double tolerance = kBookmarkSamePositionTolerance,
  }) async {
    if (scrollRatio.isNaN) return null; // 坏值 ⇒ 当「不在书签处」（别让 NaN 造出奇怪匹配）
    final rows = await _db.query(
      'book_marker',
      where: 'book_id = ? AND chapter_idx = ? AND deleted = 0 '
          'AND ABS(scroll_ratio - ?) <= ?',
      whereArgs: [bookId, chapterIdx, scrollRatio, tolerance],
      orderBy: 'scroll_ratio ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// 取消（**软删** —— 行留在库里）。
  ///
  /// 🔑 为什么软删而不是 `DELETE`：同步是**并集**语义（同 `bookmark` 的教训）——
  ///    硬删之后另一台设备的旧副本会把它**并回来**。
  ///    📌 所以「删除」也要能被同步看见。
  ///
  /// ⚠️ 当前**同步管线尚未接入本表**（见 schema 里的如实标注），
  ///    但表结构与删除语义已按最终形态做 —— 免得接入时要迁移用户数据。
  Future<void> remove(String id) async {
    await _db.update(
      'book_marker',
      {'deleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 某本书的有效书签条数（供 UI 显示「N 个书签」）。
  Future<int> countForBook(String bookId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM book_marker WHERE book_id = ? AND deleted = 0',
      [bookId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 全部有效书签的条数（跨所有书 —— 供断言与将来的「资料」页用）。
  Future<int> countAll() async {
    final rows = await _db
        .rawQuery('SELECT COUNT(*) AS c FROM book_marker WHERE deleted = 0');
    return (rows.first['c'] as int?) ?? 0;
  }

  BookMarker _fromRow(Map<String, Object?> r) => BookMarker(
        id: r['id'] as String,
        bookId: r['book_id'] as String,
        chapterIdx: (r['chapter_idx'] as int?) ?? 0,
        scrollRatio: (r['scroll_ratio'] as num?)?.toDouble() ?? 0,
        excerpt: (r['excerpt'] as String?) ?? '',
        // 🔑 存的是 UTC ISO8601；读回后**保持 UTC** ——
        //    转本地是**显示层**的事（`highlight_display.highlightTimeLabel` 里 `toLocal()`）。
        //    📌 判据：时区转换只在一处（显示层），存储层不掺和。
        createdAt:
            DateTime.tryParse((r['created_at'] as String?) ?? '')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// 供 [BookMarkerRepository.remove] 的调用方（UI）用的语义别名 —— 「点一下」的两种结果。
///
/// 🔑 把「打 / 取消」这个二选一**显式化**（而不是让 UI 自己 `if (found == null)`）：
///    UI 里的分支越少越好，而「当前态 → 点一下变成什么」是**同一个判断**，
///    它应该与写入走同一条路（`findAt`）。
enum BookmarkToggleOutcome {
  /// 新打了一条书签。
  added,

  /// 取消了原来那条。
  removed,
}
