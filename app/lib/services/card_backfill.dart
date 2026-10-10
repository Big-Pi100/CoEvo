// CoEvo · pull 之后的「排期补建」—— 把别端拉回的划线 / 生词补上 `card_review_state` 行
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包** ——
//    `sync_service`（纯逻辑层）要用它，而那个文件能被 `scripts/query_verify` 直接 import。
//
// # 为什么必须有它（白哥真机：安卓复习页有、iOS 没有的那张划线卡）
//
// 本地「进复习队列」是**两张表一起写**：
//   · `highlight` / `user_word`  —— 内容本体（**参与同步**）
//   · `card_review_state`        —— FSRS 排期（**不参与同步**：它是派生态）
//
// 而 `pull` 的应用层只写**数据表** ⇒ 别端拉回一条划线后，**没有对应的排期行**。
// 复习页以 `card_review_state` 为**主表**（`LEFT JOIN`）⇒
// **这张卡根本不出现、也不进「今天该复习」计数** —— 全程**不报错**。
//
// # 🔑 为什么 `review_log` 重放救不了
//
// 重放**只能还原「复习过的卡」**（有 event 才有行）。
// 「**新加入、从未复习**」的卡**没有 event** ⇒ 永远不出现。
// 影响范围 = **所有**「新加入但从未复习」的卡（划线 / 生词 / 电子书划线），
// 而不只是某一台设备上的某一张。
//
// 📄 调查报告：`docs/review/card-not-synced-cross-device-2026-10-11.md`

import 'package:sqflite_common/sqlite_api.dart';

import 'highlight_enqueue.dart' show highlightCardDisplayName;
import 'highlight_id.dart';
import 'review_list_query.dart';

/// pull 之后：为**本地缺少排期行**的划线 / 生词补建排期。
///
/// [highlightIds] / [wordIds] = **本次 pull 拉回来的**那些 id。
/// 返回**真的插入了**的条数（本地已有 = 不动，不计入）。
///
/// ⚠️ **幂等**：重复调用不会重复插（底层是 `INSERT OR IGNORE`）。
/// ⚠️ **绝不覆盖**已有排期 —— 用户在本机积累的 FSRS 进度必须保住
///    （见 `ReviewListQuery.insertStateIfAbsent` 的说明）。
Future<int> backfillCardsAfterPull({
  required Database db,
  required List<String> highlightIds,
  required List<String> wordIds,
}) async {
  final review = ReviewListQuery(db);
  var n = 0;
  n += await _backfillHighlights(db, review, highlightIds);
  n += await _backfillWords(db, review, wordIds);
  return n;
}

/// 划线卡（`hl:<uuid>`）。
Future<int> _backfillHighlights(
  Database db,
  ReviewListQuery review,
  List<String> ids,
) async {
  if (ids.isEmpty) return 0;
  var n = 0;
  for (final id in ids) {
    final rows = await db.query(
      'highlight',
      columns: ['text', 'created_at', 'deleted'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) continue; // 没落库（例如已被过滤）⇒ 不补
    final r = rows.first;

    // 🔴 已删除的**不补** —— 补回来等于让「别端已取消的划线」在本端**复活**。
    // ⚠️ 反过来，`paused = 1` 的**要补**：它在列表里显示「暂停」而**不是隐藏**
    //    （不补 ⇒ 两端差一行，一边有一边没有）。
    if ((r['deleted'] as num?)?.toInt() == 1) continue;

    // 🔴 排期取**划线当时的入队时刻**（`created_at`），**不是** `now`：
    //    用 `now` ⇒ 每次新机 / 重装都「从今天重新开始」，历史到期日全丢。
    // ⚠️ 时间解析失败就**跳过**（**不用 `now` 兜底** —— 那正是上面要防的事）。
    final at = DateTime.tryParse(r['created_at'] as String? ?? '');
    if (at == null) continue;

    final inserted = await review.insertStateIfAbsent(
      wordId: highlightWordId(id),
      // 🔑 显示名走**同一处口径**（`highlight_enqueue` 的 40 字符截断）——
      //    否则同一张卡在本机（40 字）与别端补建（别的口径）显示**不同标题**。
      spelling: highlightCardDisplayName(r['text'] as String? ?? ''),
      nextReviewAt: at.toUtc(),
    );
    if (inserted) n++;
  }
  return n;
}

/// 生词卡（`w…` / `ext:…`）。
Future<int> _backfillWords(
  Database db,
  ReviewListQuery review,
  List<String> ids,
) async {
  if (ids.isEmpty) return 0;
  var n = 0;
  for (final id in ids) {
    final rows = await db.query(
      'user_word',
      columns: ['spelling', 'added_at', 'deleted'],
      where: 'word_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) continue;
    final r = rows.first;
    // 同划线：`deleted = 1`（已移出生词本）**不补**
    if ((r['deleted'] as num?)?.toInt() == 1) continue;

    // 🔴 排期取 `added_at`（该词加入生词本的时刻），理由同划线卡
    final at = DateTime.tryParse(r['added_at'] as String? ?? '');
    if (at == null) continue;

    final inserted = await review.insertStateIfAbsent(
      wordId: id,
      spelling: r['spelling'] as String? ?? id,
      nextReviewAt: at.toUtc(),
    );
    if (inserted) n++;
  }
  return n;
}
