// CoEvo · 划线「入队」—— 一条划线同时进**两张表**（纯 Dart · 可被脚本驱动验证）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**。
//
// # 为什么是「一个组合动作」而不是塞进仓储
//
// 划线要能被复习，需要**两件事同时成立**：
//   ① `highlight` 表里有这条划线（内容 / 位置 / 笔记）
//   ② `card_review_state` 里有一行 `word_id = 'hl:<uuid>'`（FSRS 排期）
//
// 而**两张表的失败语义不同**：
//   · ① 失败 = **用户白划了**（内容都没存下）
//   · ② 失败 = 划线还在，只是**暂时不复习**（下次能补）
//
// ⇒ 不塞进一个 `HighlightRepository.add` 里（那会让「内容存下了但没排期」
//   变成「整个操作失败」，用户重划一次反而产生**重复内容**）。
//   本函数按 ①→② 顺序做，**① 失败就直接返回**（② 没有意义）。
//
// # 🔑 id 由**调用方**生成（uuid），理由见 `highlight_id.dart`
//
// # 🔴 `spelling` 冗余列写什么
// `card_review_state.spelling` 是**两库不 JOIN 时的显示名**（见 schema 注释）。
// 划线卡写 `excerpt`（正文摘录）—— 复习列表里那一行要能看出「这是哪条划线」，
// 而不是一串 uuid。

import 'package:sqflite_common/sqlite_api.dart';

import 'highlight_id.dart';
import 'highlight_repository.dart';
import 'review_list_query.dart';

/// 「入队」的结果。
enum HighlightEnqueueResult {
  /// 两条都写成功。
  ok,

  /// 划线本身写失败（内容没存下）—— 用户应当被告知。
  contentFailed,
}

/// 把一条划线入队（写 `highlight` + 写 `card_review_state`）。
///
/// [uuid] 由调用方用 `const Uuid().v4()` 生成（见 `highlight_id.dart` 的说明）。
Future<HighlightEnqueueResult> enqueueHighlight({
  required Database db,
  required String uuid,
  required HighlightSourceType sourceType,
  required String sourceId,
  int? chapterIdx,
  required int startOffset,
  required int endOffset,
  required String text,
  DateTime? now,
}) async {
  final repo = HighlightRepository(db);

  // ① 内容 —— 失败即终止（② 没有意义）
  try {
    await repo.add(
      id: uuid,
      sourceType: sourceType,
      sourceId: sourceId,
      chapterIdx: chapterIdx,
      startOffset: startOffset,
      endOffset: endOffset,
      text: text,
    );
  } catch (_) {
    return HighlightEnqueueResult.contentFailed;
  }

  // ② 排期 —— 🔑 **复用既有的 `ReviewListQuery`**，不另造一份 FSRS 写入。
  //    `next_review_at = 现在` ⇒ **立即到期**（与查词入生词本时的处理**逐字一致**，
  //    见 `word_lookup.dart` 的 `upsertState(state: 0, nextReviewAt: DateTime.now())`）。
  final review = ReviewListQuery(db);
  await review.upsertState(
    wordId: highlightWordId(uuid),
    spelling: _displayName(text),
    state: 0, // 未学
    nextReviewAt: (now ?? DateTime.now()).toUtc(),
  );

  return HighlightEnqueueResult.ok;
}

/// 复习列表里那一行显示什么 —— 取正文**首 40 字符**、单行。
///
/// ⚠️ 与 `Highlight.excerpt`（60 字符）**不是同一个口径**，也**刻意不去复用**：
/// 那个是「划线清单」里给人认的，这个是「复习队列」里的一行 —— 宽度不同。
/// 📌 若将来两处要统一，改的是**同一处**（这里），不是各改各的。
String _displayName(String text) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 40 ? oneLine : '${oneLine.substring(0, 40)}…';
}
