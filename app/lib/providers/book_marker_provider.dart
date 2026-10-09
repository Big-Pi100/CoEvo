import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ebook/book_marker.dart';
import '../services/ebook/book_marker_repository.dart';
import 'book_provider.dart';

/// 某本书的**书签**（未删除，按**位置**排序：章 → 章内比例）。
///
/// # 🔑 为什么依赖 `bookDbRevisionProvider` 而不是自己开一个修订号
///
/// 书签在 **`book.db`**（与书、章节、进度同库）——
/// 「这个库变了」这件事已经有唯一的表达（`bookDbRevisionProvider`，见 `book_provider.dart`）。
/// ⇒ 打/取消书签后**只 `bump()` 那一个**，本 provider 自动重算。
/// 📌 判据：**同一件事的口径只能一处权威** —— 再开一个「书签修订号」就会出现
///    「书变了但书签没刷新」这种半边更新。
///
/// # ⚠️ 失败 / 加载中 ⇒ 空列表（但**调用方要自己区分**）
///
/// 与 `highlightListProvider` 同一条取向：**不把易失败的外部依赖放在渲染的前置条件上**。
/// 顶栏那个图标键在「拿不到书签」时应该**照常可点**（点了会写库，写失败有提示）——
/// 不能因为读不到就把它禁用（那是「一个有出口的假象」的反面：无可用的入口）。
final bookMarkersProvider = FutureProvider.autoDispose
    .family<List<BookMarker>, String>((ref, bookId) async {
  final db = await ref.watch(bookDbProvider.future);
  // 🔑 打 / 取消书签后自动重算（写端只 bump 一次）
  ref.watch(bookDbRevisionProvider);
  return BookMarkerRepository(db).listForBook(bookId);
});

/// 安全取值（失败 / 加载中 ⇒ 空列表）。⚠️ 同 `highlightListOf` 的说明：
/// 本函数把「空」与「打不开」都变成空列表 —— 需要区分时用 `AsyncValue.isLoading` / `hasError`。
List<BookMarker> bookMarkersOf(AsyncValue<List<BookMarker>> v) =>
    v.valueOrNull ?? const <BookMarker>[];
