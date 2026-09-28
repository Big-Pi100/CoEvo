// CoEvo · 复习列表（单一列表）的 provider
//
// # 依据
// `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §6.2（✅ 白哥定稿的「合并为单一列表」）
// + `docs/design/visual-word-card-target-2026-09-26.html`（卡片形态，属 Step 3.6 第二步）
//
// # 🔴 为什么「生词本」与「复习」是同一个东西
// 白哥原话（§6.2，2026-09-25）：
// > 「我认为生词本就是复习管理，其实复习页面只要一个就行了，卡片按 FSRS 管理状态和排序，
// >   同时支持搜索和按时序、字母排序，默认是 FSRS 排序，这样如何，就不要移入移出了」
//
// 🔑 所以本 provider **没有**「生词本列表」与「复习队列」两份 —— 只有一个列表。
//    「到期 / 未到期」只是同一列表里的一项属性（排序依据 + 分组依据）。
//
// ⚠️ 数据源是 `card_review_state`（**不是** `user_word`）：
//    · 排序要 `next_review_at`（FSRS 调度），只有 `card_review_state` 有
//    · `user_word` 只提供「暂停」状态（`deleted`）→ 由 `ReviewListQuery` 内部 JOIN

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/review_list_query.dart';
import 'user_db_provider.dart';

/// 复习列表的**排序档** —— `ui-ux` §6.2 规定的三档。
///
/// 🔑 默认「记忆曲线」：按到期时间升序，**最该看的排最前**。
///
/// ⚠️ 每个档位都绑定 `ReviewListQuery` 里的常量（**不在这里重写 SQL 片段**）：
///    排序串是**数据层**的知识（它知道哪个索引能命中），UI 只负责「选哪一档」。
enum ReviewSort {
  /// 记忆曲线（默认）—— 走 `idx_crs_due`
  memoryCurve('记忆曲线', ReviewListQuery.orderMemoryCurve),

  /// 最近加入或复习的（走 `updated_at`）
  recent('最近', ReviewListQuery.orderRecent),

  /// 字母序（走 `idx_crs_spelling`）
  alphabetical('A–Z', ReviewListQuery.orderAlphabetical);

  const ReviewSort(this.label, this.order);

  /// 分段控件上的文案
  final String label;

  /// 传给 [ReviewListQuery.list] 的 `order` 参数
  final String order;
}

/// 列表的筛选与排序参数。**必须是值类型**（`==` / `hashCode`）——
/// `FutureProvider.family` 用它做缓存键，否则每次 build 都会重新查库。
class ReviewListArgs {
  const ReviewListArgs({
    this.sort = ReviewSort.memoryCurve,
    this.search = '',
    this.dueOnly = false,
  });

  final ReviewSort sort;

  /// 搜索词（前缀匹配）。空串 = 不筛。
  final String search;

  /// 🆕 只显示**已到期**的（白哥 2026-09-28 定的筛选按钮「显示全部 / 显示已到期」）。
  ///
  /// 🔑 它是**筛选**不是**排序** —— 与「三档排序」正交，两者可叠加
  ///    （如「只看已到期 + 按 A–Z」）。
  final bool dueOnly;

  ReviewListArgs copyWith({
    ReviewSort? sort,
    String? search,
    bool? dueOnly,
  }) =>
      ReviewListArgs(
        sort: sort ?? this.sort,
        search: search ?? this.search,
        dueOnly: dueOnly ?? this.dueOnly,
      );

  @override
  bool operator ==(Object other) =>
      other is ReviewListArgs &&
      other.sort == sort &&
      other.search == search &&
      other.dueOnly == dueOnly;

  @override
  int get hashCode => Object.hash(sort, search, dueOnly);
}

/// 复习列表 —— 单一列表（全部生词，含未到期的）。
///
/// # 🔑 为什么 `watch(userDbProvider)` 而不是 `read`
/// 同 `bookmarkListProvider`：`watch` 让「库就绪」本身成为依赖 →
/// 库打开完成时列表**自动重查**；只 `read` 会拿到「还没就绪」的空态。
///
/// # ⚠️ 读失败**会抛**（不吞成空列表）
/// 复习列表是**用户自己攒下的词**，读不出来必须**明确告知**（页面渲染错误态），
/// 不能显示成「还没有生词」—— 那是**谎报**
/// （同 `userWordListProvider` / `bookmark_list_screen._Unavailable` 的既定原则）。
///
/// # 刷新
/// 「暂停」一个词后，调用方需 `ref.invalidate(reviewListProvider)` 与
/// `ref.invalidate(reviewDueCountProvider)`（见 `review_screen._pause`）。
final reviewListProvider =
    FutureProvider.autoDispose.family<List<ReviewListItem>, ReviewListArgs>(
  (ref, args) async {
    final db = await ref.watch(userDbProvider.future);
    return ReviewListQuery(db).list(
      search: args.search,
      order: args.sort.order,
      dueOnly: args.dueOnly,
    );
  },
);

/// 「N 个今天该看」—— 顶部摘要用。
///
/// ⚠️ 与 [reviewListProvider] **分开**：它**不受**排序/搜索/筛选影响
/// （用户切到「A–Z」或搜索某个词时，不该让「今天该看 N 个」跟着变）。
/// 两者共用 `ReviewListQuery` 里**同一套暂停过滤** → 不会出现
/// 「顶部说 5 个该看，列表里只数得出 3 个」。
final reviewDueCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  return ReviewListQuery(db).dueCount(DateTime.now());
});
