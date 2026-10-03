// 内容源 provider —— 信息流列表 / 文章详情 / 按 id 批量
//
// # 数据源
// 后端 `/api/feed`（服务端共享内容池）—— 不是 mock、不是端侧库。
// 🔴 **本 provider 不依赖登录态**（见 `content_client.dart` 文件头的说明）。
//
// # 与 `bookmarkProvider` 的分工
// | | `bookmarkProvider` | 本文件 |
// |---|---|---|
// | 数据源 | 端侧 `user.db` | 后端 `/api/feed` |
// | 是否需登录 | ❌ | ❌ |
// | 是否可能长时间不可用 | 库未就绪（短） | **网络/服务不可用（可能长时间）** |
// → 🔑 正因为它**依赖网络**，三态（加载/失败/空）必须都有出口 ——
//   这是本项目反复的教训：「**静默失败 + 无出口**」比报错更糟。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../services/feed_pager.dart';

/// 内容源客户端（单例 —— `http.Client` 复用连接池）。
final contentClientProvider = Provider<ContentApiClient>((ref) {
  final client = ContentApiClient();
  ref.onDispose(client.dispose);
  return client;
});

/// 信息流每页条数。
///
/// ⚠️ **后端上限是 50**（`content_handler.rs` 的 `MAX_LIMIT`）——
///    超过会被 `clamp` 到 50，**不报错**（静默）。所以这里不能随便写大。
const int kFeedPageSize = 30;

/// 信息流列表 —— **支持分页 + 下拉刷新**（2026-10-03）。
///
/// # 🔑 为什么从 `FutureProvider` 改成 `AsyncNotifier`
///
/// 原实现返回**单页**（`FeedPage`）⇒ 结构上**无法累积**「第 2 页、第 3 页」。
/// 分页要求维护「已加载到哪 / 正在加载 / 加载失败」这些**可变状态**，
/// 而 `FutureProvider` 是「一次算完」的语义 ⇒ 必须换成 notifier。
///
/// # ⚠️ 关于 `family`（参数 = category）
///
/// 保留 `family` 是**有意的**：「分类筛选」是既定下一步，此后只需在 UI 传非空 key。
/// ⚠️ 但注意 **UI 目前只传 `''`**（`home_screen.dart`）—— 参数**从未被传出非空值**。
///    ⇒ 「兴趣选择」还没做（见 `docs/review/feed-paging-refresh-and-interests-2026-10-03.md`）。
///
/// 约定：参数用 **key 字符串**（`''` = 全部）而不是 `null` ——
/// `family` 的参数参与相等性比较，用 `null` 会让「未筛选」有多个等价写法。
///
/// # 状态是 [FeedPager]（**纯 Dart · 可独立验证**）
///
/// 分页的全部逻辑（累积 / 去重 / 游标 / 终局判定 / 错误保留）都在
/// `services/feed_pager.dart` 里，它是**零 import 的纯 Dart**
/// ⇒ 本机跑不了 Flutter 也能验（`scripts/trace_verify/bin/verify_feed_pager.dart`，54 项）。
/// 本文件只做「**发请求 → 把结果喂给 FeedPager**」这一件事。
final feedProvider =
    AsyncNotifierProvider.family<FeedNotifier, FeedPager<FeedItem>, String>(
  FeedNotifier.new,
);

class FeedNotifier extends FamilyAsyncNotifier<FeedPager<FeedItem>, String> {
  /// `''` = 不筛（后端按 `(?1 IS NULL OR ...)` 处理）。
  String? get _category => arg.isEmpty ? null : arg;

  static int _idOf(FeedItem it) => it.id;

  @override
  Future<FeedPager<FeedItem>> build(String categoryKey) async {
    // 🔑 用 `arg`（而不是 build 的参数）读 category —— 两者此时相等，
    //    但 `_category` 这个 getter 也被 loadMore/refresh 复用，
    //    统一从它读可避免「两处各读一份、改一处忘另一处」。
    final client = ref.watch(contentClientProvider);
    final page = await client.fetchFeed(
      category: _category,
      limit: kFeedPageSize,
      offset: 0,
    );
    return FeedPager<FeedItem>.first(page.items, page.total, idOf: _idOf);
  }

  /// 上拉加载更多（由页面的滚动监听触发）。
  ///
  /// # 三道前置守卫（都很重要）
  ///
  /// | 守卫 | 不做会怎样 |
  /// |---|---|
  /// | `valueOrNull == null` | 首次加载**还没成功**就触发 ⇒ 与 `build` 抢状态 |
  /// | `loadingMore` | 滚动回调**每帧都会触发** ⇒ 不去重会并发发出十几个请求 |
  /// | `!hasMore` | 到底了还发请求 ⇒ 白耗流量 + 服务端白跑 |
  ///
  /// # 🔴 `await` 之后必须**重新读** `state`
  ///
  /// 请求期间用户可能已经**下拉刷新**（`state` 被换成新的 pager）。
  /// 若沿用 `await` 前的引用去 `append`，会**把旧列表拼回去** ——
  /// 表现为「刷新完了，但翻上去发现是旧内容」。
  /// ⇒ 这是本方法唯一容易写错的地方。
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore) return;

    state = AsyncData(current.startingLoadMore());

    final client = ref.read(contentClientProvider);
    try {
      final page = await client.fetchFeed(
        category: _category,
        limit: kFeedPageSize,
        offset: current.nextOffset, // 🔑 游标（≠ items.length，见 FeedPager 文档）
      );
      // 🔴 重新读 state（见上面「await 之后必须重新读」）
      final latest = state.valueOrNull;
      if (latest == null) return; // 期间变成了错误态 ⇒ 丢弃本次结果
      state = AsyncData(
        latest.append(page.items, page.total, idOf: _idOf),
      );
    } catch (e) {
      final latest = state.valueOrNull;
      if (latest == null) return;
      // ⚠️ **不把整体变成 AsyncError** —— 列表已有内容，
      //    变成错误态会让用户「一上拉，整个列表消失变报错页」。
      state = AsyncData(latest.loadMoreFailed(e));
    }
  }

  /// 下拉刷新（由 `RefreshIndicator` 触发）。
  ///
  /// 🔴 **失败时的行为与首次加载不同**（这是刻意的）：
  ///
  /// | 情况 | 行为 |
  /// |---|---|
  /// | 本来**没有**数据（首屏就失败）| `AsyncError` ⇒ 全屏错误页 + 重试 |
  /// | 本来**有**数据 | 保留列表 + `refreshError`（轻提示）|
  ///
  /// 📌 判据：**「有数据时失败」≠「没数据时失败」** ——
  ///    前者只是「这次没成功」，后者是「什么都看不到」。
  ///    把前者也渲染成全屏报错，等于因为一次性网络抖动**把已有内容也收走**。
  Future<void> refresh() async {
    final current = state.valueOrNull;
    if (current != null) {
      // 保留旧列表，只标记「正在刷新」（避免闪白）
      state = AsyncData(current.startingRefresh());
    }

    final client = ref.read(contentClientProvider);
    try {
      final page = await client.fetchFeed(
        category: _category,
        limit: kFeedPageSize,
        offset: 0,
      );
      state = AsyncData(
        FeedPager<FeedItem>.first(page.items, page.total, idOf: _idOf),
      );
    } catch (e, st) {
      final latest = state.valueOrNull;
      if (latest == null) {
        state = AsyncError(e, st); // 本来就没数据 ⇒ 该进全屏错误态
      } else {
        state = AsyncData(latest.refreshFailed(e)); // 有数据 ⇒ 保留 + 提示
      }
    }
  }

  /// 清掉「刷新失败」的轻提示（SnackBar 显示完之后调）。
  void clearRefreshError() {
    final current = state.valueOrNull;
    if (current == null || current.refreshError == null) return;
    state = AsyncData(current.clearRefreshError());
  }
}

/// 按 id 批量取（收藏清单）。
///
/// 🔑 参数是**排好序的 id 列表**，但返回的是 `Map<id, item>` ——
///    因为后端响应顺序**不保证**等于请求顺序（它按 `published_at DESC`）。
///    调用方拿映射后**按自己的顺序取**（收藏清单的顺序是收藏时间倒序，
///    那是端侧 `bookmark` 表的顺序，不是后端能知道的）。
///
/// ⚠️ `family` 的参数参与相等性：`List` 的默认 `==` 是**引用比较** ——
///    传一个新建的 list 每次都会重新请求。所以调用方应传**稳定**的列表
///    （如直接来自 provider 的 state），或改用 `join(',')` 后的字符串。
///    → 这里用**字符串 key**（逗号分隔，已排序），天然值相等 ✅
final feedByIdsProvider =
    FutureProvider.family<Map<int, FeedItem>, String>((ref, idsKey) async {
  final ids = idsKey
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toList();
  if (ids.isEmpty) return const {};
  final client = ref.watch(contentClientProvider);
  final items = await client.fetchByIds(ids);
  return {for (final it in items) it.id: it};
});

/// 单篇详情（阅读器用）。
///
/// ⚠️ `autoDispose`：读完退出后释放 —— 全文可能几 KB，
///    读者翻过几十篇都不释放会积在内存里。
///    而信息流列表（上面那个）**不** autoDispose（切 tab 回来不该重新拉）。
final articleDetailProvider =
    FutureProvider.autoDispose.family<ArticleDetail, int>((ref, id) async {
  final client = ref.watch(contentClientProvider);
  return client.fetchArticle(id);
});
