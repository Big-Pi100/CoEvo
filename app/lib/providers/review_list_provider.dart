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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/review_list_query.dart';
import 'user_db_provider.dart';
import 'word_db_provider.dart';

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
/// **写端不必点名本 provider** —— 只要在写库成功后 `bump()` 一次
/// `userDbRevisionProvider`，本 provider（及 `reviewDueCountProvider`）
/// 会自动重算。判据与根因见 `user_db_provider.dart` 的 `UserDbRevision`。
/// 复习列表的一项 = **复习状态 + 释义**。
///
/// 🔑 为什么把释义并进来而不是让页面各查各的：
/// · 设计稿 `visual-word-card-target` §02 定「**列表项 = 单词 + 释义 +
///   熟练度三点 + 下次到期时间**」→ 释义是列表项的一部分，不是额外装饰；
/// · 释义在 `word.db`（跨库），逐项异步查会让每个 item 各自维护加载态
///   → 一个列表里出现 N 个独立的「转圈」。
/// → 在 provider 里**一次批量取齐**（一次 `IN (...)` SQL）。
class ReviewRow {
  const ReviewRow({required this.item, this.definition});

  final ReviewListItem item;

  /// 首义中文；`null` = 取不到（词条缺失 / 无 `definition` 段 / 词库未就绪）
  /// → 列表项**不显示释义行**，而不是显示空行或占位符。
  final String? definition;
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
/// （同 `bookmark_list_screen._Unavailable` 的既定原则）。
///
/// # 🔴 但**释义**取不到**不抛**（两者严格区分）
/// 状态库（`user.db`）坏了 = 列表本身没了 → 必须报错。
/// 而词库（`word.db`）未就绪 / 查不到某个词 = 只是**少一行释义** →
/// 列表照常显示。
/// 🔑 这是「**不要把易失败的依赖放在内容渲染的前置条件上**」的直接落实：
///   词库要 31.4 MB 首次落盘（0.5–2 s），拿它当列表的前置条件
///   会让复习页在启动后一段时间内**整页空着**。
///
/// # 刷新
/// 「暂停」或提交评级后，**写端 `bump()` 修订号**即可 —— 本 provider 与
/// [reviewDueCountProvider] 都 watch 了它，会一起重算（见 `UserDbRevision`）。
final reviewListProvider =
    FutureProvider.autoDispose.family<List<ReviewRow>, ReviewListArgs>(
  (ref, args) async {
    // 🔑 **先接修订号**：库里任何写入（划词新增 / 评级 / 暂停）都会 `bump()`，
    //    这里一 watch 就自动重算 —— 不再依赖每个写端记得来 invalidate 本 provider。
    //    （根因与判据见 `user_db_provider.dart` 的 `UserDbRevision`。）
    //    ⚠️ 放在 `await` **之前** —— async body 里 `await` 之后再 watch 可能
    //       撞上 provider 已被销毁（Riverpod 的 ref 在 async gap 后不再安全）。
    ref.watch(userDbRevisionProvider);

    final db = await ref.watch(userDbProvider.future);
    final items = await ReviewListQuery(db).list(
      search: args.search,
      order: args.sort.order,
      dueOnly: args.dueOnly,
    );
    if (items.isEmpty) return const [];

    // ── 释义（尽力而为，失败不影响列表）──
    var defs = const <String, String>{};
    final load = ref.watch(wordQueryProvider).valueOrNull;
    if (load is WordDbReady) {
      try {
        defs = await load.service
            .firstDefinitionsOf(items.map((e) => e.wordId).toList());
      } catch (e) {
        // 🔑 只记日志 —— 见类文档：少一行释义 ≠ 列表不可用
        debugPrint('[review] 取释义失败（列表照常显示）：$e');
      }
    }

    return [
      for (final it in items)
        ReviewRow(item: it, definition: defs[it.wordId]),
    ];
  },
);

/// 「N 个今天该看」—— 顶部摘要用。
///
/// ⚠️ 与 [reviewListProvider] **分开**：它**不受**排序/搜索/筛选影响
/// （用户切到「A–Z」或搜索某个词时，不该让「今天该看 N 个」跟着变）。
/// 两者共用 `ReviewListQuery` 里**同一套暂停过滤** → 不会出现
/// 「顶部说 5 个该看，列表里只数得出 3 个」。
final reviewDueCountProvider = FutureProvider.autoDispose<int>((ref) async {
  // 🔑 同 `reviewListProvider`：靠修订号自动跟随库的变化
  //    （这也是「列表与计数同源刷新」的可靠保证 —— 以前要手工同时点名两个 provider，
  //     少点一个就出现「列表少了一条但顶部计数没变」）。
  ref.watch(userDbRevisionProvider);

  final db = await ref.watch(userDbProvider.future);
  return ReviewListQuery(db).dueCount(DateTime.now());
});
