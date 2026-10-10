// CoEvo · 书本内书签的**跨设备桥接** —— 「待认领书签」的两端
//
// 🔴 零 Flutter 依赖（同 `book_progress_sync.dart`）⇒ 本机可验。
//
// # 与 `book_progress_sync.dart` 的**关键差别**：主键不同（别照抄）
//
// | | 进度 | 书签（本文件）|
// |---|---|---|
// | 一本几条 | **一条**（覆盖式）| **多条**（用户可标多处）|
// | 交换区主键 | `content_hash` | 🔴 **书签 uuid（`id`）** |
// ⇒ ⚠️ 照抄「`content_hash` 作主键」会把同一本书的多个书签**互相覆盖**
//    （只留最后一条，且**不报错**）。
//
// # 两个动作（比进度少一个）
//
// ```
//   pull   → 写交换区 `book_marker_pending`（不需要本地已有这本书）   ← sync_service
//   认领   → 交换区 → `book_marker`（本地已有这本书时）               ← 本文件
// ```
//
// ⚠️ 与进度**不同**：书签**不做「镜像」** —— 它没有「本地权威 vs 交换区」两份，
//    写入 `book_marker` 后由 `sync_service._pendingBookMarkers()` 的**全量推**直接上传。
//    🔑 理由：书签是用户手动标的、**低频且行数少**，不值得为它加 `pending_push` 列
//      （那要再走一次 `book.db` 迁移；而服务端 UPSERT 的 `WHERE` 已保证全量推不产生回声）。
//
// # 🔴 认领必须在**两个**时机被调用（与进度同一条教训）
//
// | 时机 | 覆盖的情况 |
// |---|---|
// | **导入后** | 新导入的书 + 别端早已推送的书签（pending 里等着）|
// | **pull 之后** | 🔴 **已导入**的书 + 别端**刚刚**推送的书签 |
//
// ⚠️ 只做「导入后」有个**静默缺口**：对已导入的书，pull 来的书签会写进交换区
//    但**永远不被应用**（用户在书里看不到任何书签，且没有任何提示）。

import 'package:sqflite_common/sqlite_api.dart';

/// 写一行书签进 `book_marker`（**直写** —— 不经 `BookMarkerRepository` 的业务方法）。
///
/// 🔑 为什么直写：`BookMarkerRepository.add()` 带业务语义（「用户刚刚点了一下」）——
///    它用 `ConflictAlgorithm.replace` **整行替换**，会把 `deleted` 归零
///    ⇒ 用它做同步会让「别端**取消**的书签在本地**复活**」（同 `_upsertHighlight` 的判据）。
/// ⚠️ 列名**显式列出**（不依赖表的物理列顺序）。
Future<void> upsertMarkerRow(
  Database db, {
  required String bookId,
  required Map<String, Object?> row,
}) async {
  await db.rawInsert(
    'INSERT INTO book_marker '
    '(id, book_id, chapter_idx, scroll_ratio, excerpt, created_at, deleted) '
    'VALUES (?,?,?,?,?,?,?) '
    'ON CONFLICT (id) DO UPDATE SET '
    '  chapter_idx  = excluded.chapter_idx, '
    '  scroll_ratio = excluded.scroll_ratio, '
    '  excerpt      = excluded.excerpt, '
    '  created_at   = excluded.created_at, '
    '  deleted      = excluded.deleted',
    [
      row['id'],
      bookId,
      row['chapter_idx'],
      row['scroll_ratio'],
      row['excerpt'],
      row['created_at'],
      row['deleted'] ?? 0,
    ],
  );
}

/// 认领**某一本书**的待认领书签（**导入新书后**调用）。
///
/// 返回认领的条数（书不存在 / 没有待认领的 ⇒ `0`，都**不是错误**）。
Future<int> claimPendingMarkersForBook(
  Database db, {
  required String bookId,
}) async {
  final rows = await db.rawQuery('''
    SELECT p.id, p.content_hash, p.chapter_idx, p.scroll_ratio, p.excerpt,
           p.created_at, p.deleted
      FROM book_marker_pending p
      JOIN book b ON b.content_hash = p.content_hash
     WHERE b.id = ?1 AND b.content_hash IS NOT NULL AND b.content_hash <> ''
  ''', [bookId]);
  return _claimRows(db, rows, bookId);
}

/// 认领**所有**「本地已有这本书」的待认领书签（**pull 之后**调用）。
///
/// 🔑 用一次 JOIN 找出全部可认领的 —— 而不是遍历 pending 再逐本查 `book`
///    （那是 N+1 次查询，且顺序无关）。
/// ⚠️ 与「导入后认领」是**两条互补的线**，两条都要有（理由见文件头）。
Future<int> claimAllPendingMarkers(Database db) async {
  final rows = await db.rawQuery('''
    SELECT p.id, p.content_hash, p.chapter_idx, p.scroll_ratio, p.excerpt,
           p.created_at, p.deleted, b.id AS book_id
      FROM book_marker_pending p
      JOIN book b ON b.content_hash = p.content_hash
     WHERE b.content_hash IS NOT NULL AND b.content_hash <> ''
  ''');
  var n = 0;
  for (final r in rows) {
    final bookId = r['book_id'] as String? ?? '';
    if (bookId.isEmpty) continue;
    await upsertMarkerRow(db, bookId: bookId, row: {...r});
    await db.delete('book_marker_pending', where: 'id = ?', whereArgs: [r['id']]);
    n++;
  }
  return n;
}

/// [claimPendingMarkersForBook] 的共用实现（**一处口径**）。
Future<int> _claimRows(
  Database db,
  List<Map<String, Object?>> rows,
  String bookId,
) async {
  var n = 0;
  for (final r in rows) {
    await upsertMarkerRow(db, bookId: bookId, row: {...r});
    await db.delete('book_marker_pending', where: 'id = ?', whereArgs: [r['id']]);
    n++;
  }
  return n;
}
