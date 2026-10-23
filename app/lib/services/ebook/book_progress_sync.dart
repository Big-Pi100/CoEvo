// CoEvo · 电子书进度的**跨设备桥接** —— 「待认领进度」的两端
//
// 🔴 零 Flutter 依赖（同 `sync_merge.dart` / `sync_service.dart`）⇒ 本机可验。
//
// # 三个概念先分清（这是本文件存在的全部理由）
//
// | 表 | 键 | 角色 |
// |---|---|---|
// | `book_progress` | `book_id`（端侧 uuid）| **本地权威进度**（用户在这台机器上读的）|
// | `book_progress_pending` | `content_hash`（文件指纹）| **跨设备的进度交换区** |
//
// `book_id` 是**端侧生成的 uuid** ⇒ 同一本《Pride and Prejudice》在两台设备上是
// **两个不同的 id** ⇒ 直接用 `book_progress` 同步会「进度对不上」。
// 交换区用**文件指纹**（`sha256(原始字节)`）作键，才能跨设备认出「同一本书」。
//
// # 三个动作
//
// ```
//   pull   → 写交换区（不知道本地有没有这本书）      ← sync_service 已做
//   认领   → 交换区 → 本地权威（取较新）              ← 本文件
//   镜像   → 本地权威 → 交换区（供 push）             ← 本文件
// ```
//
// 🔑 **镜像为什么也要「取较新」**（而不是直接覆盖）：
//    交换区里可能已有**别端更新的进度还没认领**。若镜像无条件覆盖，
//    会出现「本地停在旧章 ⇒ 把别端的新进度冲掉 ⇒ 上传旧章」——
//    而且**两端都不会报错**（数字都对，只是内容回退了）。
//    ⇒ 用「较新者赢」，两种调用顺序都安全（幂等、可交换）。
//
// # 🔴 认领必须在**两个**时机被调用（这是 pull 之后才发现的设计缺口）
//
// | 时机 | 覆盖的情况 |
// |---|---|
// | **导入后** | 新导入的书 + 别端早已推送的进度（`pending` 里等着）|
// | **pull 之后** | 🔴 **已导入**的书 + 别端**刚刚**推送的进度 |
//
// ⚠️ 只做「导入后」会有个**静默缺口**：对已导入的书，pull 来的进度会写进交换区
//    但**永远不被应用**（用户在新设备上读到的仍是旧章节，且没有任何提示）。
//    这是设计文档 §3.4.3 只画了「导入 → 认领」那一条线时**看不出来**的。
//
// 📄 设计依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §3.4

import 'package:sqflite_common/sqlite_api.dart';

import '../sync_merge.dart' as m;

/// 认领的结果（**计数而不是布尔** —— 出问题时第一个想知道「认领了几本」）。
class ClaimResult {
  const ClaimResult({
    this.claimed = 0,
    this.skippedOlder = 0,
    this.skippedNoHash = 0,
  });

  /// 真正写进 `book_progress` 的条数。
  final int claimed;

  /// 跳过（本地权威进度**更新** ⇒ 交换区那份是旧的，不该回退）。
  final int skippedOlder;

  /// 跳过（书没有 `content_hash` ⇒ 算不出跨设备身份 ⇒ 不参与）。
  final int skippedNoHash;

  int get total => claimed + skippedOlder + skippedNoHash;

  bool get didSomething => claimed > 0;

  @override
  String toString() =>
      'ClaimResult(认领 $claimed · 本地更新跳过 $skippedOlder · 无指纹 $skippedNoHash)';
}

/// 认领**某一本书**的待认领进度（导入新书后调用）。
///
/// 返回 `ClaimResult`；书不存在 / 无指纹 / 交换区没有 ⇒ 都是**正常情况**（不抛）。
Future<ClaimResult> claimPendingForBook(
  Database db, {
  required String bookId,
}) async {
  final hash = await _contentHashOf(db, bookId);
  if (hash == null) return const ClaimResult(skippedNoHash: 1);

  final rows = await db.query(
    'book_progress_pending',
    where: 'content_hash = ?',
    whereArgs: [hash],
    limit: 1,
  );
  if (rows.isEmpty) return const ClaimResult();

  final r = await _claimOne(db, bookId: bookId, pending: {...rows.first});
  return ClaimResult(claimed: r.claimed, skippedOlder: r.skippedOlder);
}

/// 认领**所有**「本地已有、且指纹匹配」的待认领进度（**pull 之后**调用）。
///
/// 🔑 用一次 JOIN 找出「本地已有这本书」的 pending 行 —— 而不是遍历 pending
///    再逐本查 `book`（那是 N+1 次查询，且**顺序无关**）。
///
/// ⚠️ 这里**不做**「导入后」那条线（那是 [claimPendingForBook]）；
///    两条线都要有，理由见文件头。
Future<ClaimResult> claimAllPending(Database db) async {
  final rows = await db.rawQuery('''
    SELECT p.content_hash, p.chapter_idx, p.scroll_ratio, p.updated_at, b.id AS book_id
      FROM book_progress_pending p
      JOIN book b ON b.content_hash = p.content_hash
     WHERE b.content_hash IS NOT NULL
  ''');

  var claimed = 0;
  var skippedOlder = 0;
  for (final row in rows) {
    final bookId = row['book_id'] as String?;
    if (bookId == null || bookId.isEmpty) continue;
    final r = await _claimOne(db, bookId: bookId, pending: {...row});
    claimed += r.claimed;
    skippedOlder += r.skippedOlder;
  }
  return ClaimResult(claimed: claimed, skippedOlder: skippedOlder);
}

/// 单行认领：把 `pending` 那条写进 `book_progress` 并**删掉 pending 行**。
///
/// 规则：**较新者赢**（用 `updated_at` 语义比较，见 `sync_merge.isNewer`）。
/// · 本地没有进度行 ⇒ 直接用 pending 的（新导入的书就是这种情况）
/// · 本地有且**更新** ⇒ 不动本地、**但也要删 pending**（那份已被本地覆盖，留着会反复回退）
/// · 本地有但更旧 ⇒ 用 pending 的覆盖
Future<({int claimed, int skippedOlder})> _claimOne(
  Database db, {
  required String bookId,
  required Map<String, Object?> pending,
}) async {
  final pendingAt = pending['updated_at'];
  final local = await db.query(
    'book_progress',
    columns: ['updated_at'],
    where: 'book_id = ?',
    whereArgs: [bookId],
    limit: 1,
  );

  var claimed = 0;
  var skippedOlder = 0;

  if (local.isEmpty || m.isNewer(pendingAt, local.first['updated_at'])) {
    await db.insert(
      'book_progress',
      {
        'book_id': bookId,
        'chapter_idx': pending['chapter_idx'],
        'scroll_ratio': pending['scroll_ratio'],
        // ⚠️ 用 pending 的**原时间戳**（不是 now）—— 那是「别端读到这里的时刻」，
        //    改成 now 会让它在本设备看起来「刚刚读过」，且下次镜像时压掉真正的较新值。
        'updated_at': pendingAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    claimed = 1;
  } else {
    skippedOlder = 1;
  }

  // 🔴 **两种情况下都要删** —— 留着它的唯一作用是「等被认领」。
  //    · 已认领 ⇒ 使命完成
  //    · 本地更新跳过 ⇒ 那份旧的**永远不该再被应用**（留着每次 pull 都白比对一次，
  //      且若本地进度行被删（用户删书重导）会突然「复活」一个陈旧进度）
  await db.delete(
    'book_progress_pending',
    where: 'content_hash = ?',
    whereArgs: [pending['content_hash']],
  );

  return (claimed: claimed, skippedOlder: skippedOlder);
}

/// 把**本地权威进度镜像**进交换区（用户读书后调用，供 push 上传）。
///
/// 🔑 「取较新」而不是无条件覆盖 —— 理由见文件头「镜像为什么也要取较新」。
/// ⚠️ 书没有 `content_hash`（老库 / 导入时算不出）⇒ **静默跳过**：
///    它不参与跨设备同步（设计 §3.4.2：拿错误指纹去匹配会**把用户带到错的书**，
///    比不同步更糟）。
Future<void> mirrorProgress(
  Database db, {
  required String bookId,
  required int chapterIdx,
  required double scrollRatio,
  required String updatedAt,
  /// 🆕 v6（2026-10-23）：字符偏移。翻页阅读器的原生坐标。
  /// `null` = 还不知道（老数据 / 滚动阅读器）⇒ 写 NULL，读端回退到 `scroll_ratio`。
  int? charOffset,
}) async {
  final hash = await _contentHashOf(db, bookId);
  if (hash == null) return;

  final existing = await db.query(
    'book_progress_pending',
    columns: ['updated_at'],
    where: 'content_hash = ?',
    whereArgs: [hash],
    limit: 1,
  );
  // 交换区已有**更新的**（别端推来、还没认领的）⇒ 不覆盖
  if (existing.isNotEmpty &&
      !m.isNewer(updatedAt, existing.first['updated_at'])) {
    return;
  }

  await db.insert(
    'book_progress_pending',
    {
      'content_hash': hash,
      'chapter_idx': chapterIdx,
      'scroll_ratio': scrollRatio,
      'char_offset': charOffset,
      'updated_at': updatedAt,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// 查某本书的 `content_hash`；**无指纹 / 空串 ⇒ `null`**。
///
/// 🔑 把「空串也算无指纹」归一到这里 —— 否则调用方要各自写
///    `if (h == null || h.isEmpty)`（本项目已踩过「同一个判据散在多处」）。
Future<String?> _contentHashOf(Database db, String bookId) async {
  final rows = await db.query(
    'book',
    columns: ['content_hash'],
    where: 'id = ?',
    whereArgs: [bookId],
    limit: 1,
  );
  if (rows.isEmpty) return null;
  final h = rows.first['content_hash'];
  if (h is! String || h.isEmpty) return null;
  return h;
}
