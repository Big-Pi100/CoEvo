import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/highlight_repository.dart';
import '../services/highlight_span.dart';
import 'user_db_provider.dart';

/// 划线的**来源键**（`family` 参数 —— 必须可比较，否则每次 rebuild 都会重查库）。
///
/// 🔑 三个字段与 `highlight` 表的 `(source_type, source_id, chapter_idx)` 三元组
///    **逐字对应** —— 不是「差不多」：(书, bookId) 与 (书, bookId, 第 3 章) 是两个
///    不同的查询，混了会让「翻到下一章还显示上一章的线」。
class HighlightSourceKey {
  const HighlightSourceKey({
    required this.type,
    required this.sourceId,
    this.chapterIdx,
  });

  final HighlightSourceType type;
  final String sourceId;

  /// 章内下标 —— **只有书有**；文章是单页 ⇒ `null`（此刻不按章过滤）。
  final int? chapterIdx;

  @override
  bool operator ==(Object other) =>
      other is HighlightSourceKey &&
      other.type == type &&
      other.sourceId == sourceId &&
      other.chapterIdx == chapterIdx;

  @override
  int get hashCode => Object.hash(type, sourceId, chapterIdx);

  @override
  String toString() => '${type.wire}:$sourceId${chapterIdx == null ? '' : '#$chapterIdx'}';
}

/// 某一来源的划线（**未删除**，按 `start_offset` 升序 —— 与渲染顺序一致）。
///
/// # 为什么是 `FutureProvider` 而不是 `StateNotifier`
///
/// 划线本身**没有「待提交的编辑」** —— 写入是即时的（划一下 = 一次 insert）。
/// 唯一需要「通知」的是「**别的地方刚划过 / 改了笔记**」，而那件事
/// `userDbRevisionProvider` 已经在管了（见本文件下方）。再包一层 notifier
/// 只会多出一份可能与库不同步的状态（📌 判据：**同一件事的口径只能一处权威**）。
///
/// # 🔴 刷新机制：读端自己 `watch` 修订号（反转依赖）
///
/// 原先「划完线正文要重新画下划线」这条链要写端记得 invalidate 本 provider。
/// 现在读端自己 `watch(userDbRevisionProvider)`，写端只 `bump()` 一次
/// （`word_lookup_selection.dart` 已接）。⇒ 新增读端**不用改写端**。
///
/// ⚠️ **`bump` 必须在写库成功之后**（顺序反了 ⇒ 读端在写入完成前重查旧值，
///    且修订号已变过 ⇒ **不会再有第二次刷新**）。
///
/// # ⚠️ 失败时不抛给界面
///
/// 与 `bookmarkProvider` 同一条（Step 3.22 的教训）：
/// **不要把易失败的外部依赖放在内容渲染的前置条件上**。
/// ⇒ 消费方必须用 [highlightRangesOf]（失败 ⇒ 空列表），**不要用 `when`**
/// —— `when(error:)` 会把「库打不开」变成「正文消失」。
final highlightsForSourceProvider = FutureProvider.autoDispose
    .family<List<Highlight>, HighlightSourceKey>((ref, key) async {
  // 库要打开（首次 0.5–2 s）—— `watch` 它，就绪后自动重算
  final db = await ref.watch(userDbProvider.future);

  // 🔑 关键一行：划线 / 改笔记 / 取消 之后，本 provider 自动重算
  ref.watch(userDbRevisionProvider);

  final repo = HighlightRepository(db);
  return repo.listForSource(
    sourceType: key.type,
    sourceId: key.sourceId,
    chapterIdx: key.chapterIdx,
  );
});

/// **全部**划线（记忆列表的数据源）—— 按 `created_at DESC`（「我刚划了什么」）。
///
/// # 🔑 与 [highlightsForSourceProvider] **不合并**
///
/// | | [highlightsForSourceProvider] | 本 provider |
/// |---|---|---|
/// | 谁用 | 正文渲染（画下划线）| 记忆列表（清单）|
/// | 范围 | 某个来源 + 某一章 | **全部** |
/// | key | `HighlightSourceKey` | 无 |
///
/// ⇒ 硬合成一个 family 会让「渲染」与「清单」**共用缓存** ——
/// 改一处（如给清单加筛选）会影响到渲染，反之亦然（📌 判据：**作用域不同 ⇒ 不合并**）。
///
/// ⚠️ 数据量大时这里是**全量查**（没有分页）。真机上若条目过千再考虑分页 ——
///    `listAll` 已经带了 `limit` / `offset` 参数（**接口先留好**）。
final highlightListProvider =
    FutureProvider.autoDispose<List<Highlight>>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  // 🔑 划 / 删 / 改笔记后自动重算（写端只 `bump()` 一次，见 `userDbRevisionProvider`）
  ref.watch(userDbRevisionProvider);
  return HighlightRepository(db).listAll();
});

/// 把 provider 的异步值**安全地**转成渲染用的区间列表。
///
/// · 加载中 / 失败 ⇒ **空列表**（正文照常渲染，只是没有下划线）
/// · 恰好是「没有划线」⇒ 也是空列表（两者在渲染层等价 —— 都是「不画线」）
///
/// 🔑 这就是「不把外部依赖放在渲染前置条件上」的落点：
///    本函数**永不抛**，调用方拿到的永远是一个可用的列表。
///
/// ⚠️ 与 [highlightListOf] **不是同一个东西**：
///    那个给**清单**用（且清单需要区分「空」与「打不开」）；
///    本函数给**正文渲染**用（在那里两者等价）。
List<HighlightRange> highlightRangesOf(AsyncValue<List<Highlight>> v) {
  final rows = v.valueOrNull;
  if (rows == null) return const <HighlightRange>[];
  return rows
      // 定位失败的（`start = -1`）不参与渲染 —— 它的语义是「只复习，不高亮」
      .where((h) => h.startOffset >= 0 && h.endOffset > h.startOffset)
      .map((h) => HighlightRange(id: h.id, start: h.startOffset, end: h.endOffset))
      .toList(growable: false);
}

/// 把 provider 的异步值**安全地**转成列表（失败 / 加载中 ⇒ 空列表）。
///
/// ⚠️ 与 [highlightRangesOf] 同一条取向（**不抛**），但用途不同：
///    本函数给**清单**用。⚠️ 而清单页**需要区分**「空」与「打不开」
///    （空态要给引导文案，打不开要给准确提示）⇒ 那里**额外**用 `isReady` 判断，
///    不能只靠本函数（它把两者都变成空列表）。见 `highlights_screen`。
List<Highlight> highlightListOf(AsyncValue<List<Highlight>> v) =>
    v.valueOrNull ?? const <Highlight>[];
