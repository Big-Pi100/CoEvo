// 信息流**分页状态机** —— 🔴 纯 Dart（**零 import**，连 `feed_item.dart` 都不依赖）
//
// # 🔑 为什么「零 import」是**设计要求**，不是巧合
//
// 本项目的 Flutter 是鸿蒙定制版、本机 `flutter analyze / build / test` 全崩
// （`CreateFile 231`：Dart 建不了子进程）。所以「**能在本地独立验证**」的代码
// 必须**不依赖 Flutter** —— 而 `models/feed_item.dart` 为了 `debugPrint`
// `import 'package:flutter/foundation.dart'` ⇒ 一旦本文件 import 它，就跟着变脏。
//
// ⇒ 本文件用**泛型 + `idOf` 回调**解耦：只要求「元素能被赋予一个 int 标识」，
//   不关心它是 `FeedItem` 还是别的。于是：
//
// ```dart
// final pager = FeedPager.first(pageItems, total, idOf: (it) => it.id);
// ```
//
// 验证脚本（`scripts/trace_verify/bin/verify_feed_pager.dart`）用
// `import '../../../app/lib/services/feed_pager.dart'` 引**真源码**（不是副本），
// 在本机纯 Dart 下跑 —— 与 `verify_unescape.dart` 同一套做法。

/// 一页信息流的分页状态。
///
/// # 🔴 最重要的一条：`fetched`（游标）**不等于** `items.length`
///
/// 这是本文件唯一容易写错、且**写错后症状很隐蔽**的地方。
///
/// ## 为什么会不等
///
/// 后端用 `ORDER BY published_at DESC LIMIT ? OFFSET ?` 分页，而抓取是
/// **6 小时一轮**。用户翻页时若正好赶上新一轮抓取，**新文章插在列表头部**
/// ⇒ 后续页的 `OFFSET` 整体位移 ⇒ 第 2 页会与第 1 页**重叠**。
///
/// | 步 | 服务端真实序列 | 请求 | 返回 | 处理 |
/// |---|---|---|---|---|
/// | ① | `[100 … 71]` | `OFFSET 0 LIMIT 30` | `[100…71]` | items 30 条 · fetched **30** |
/// | ② | 插入 5 条 ⇒ `[105…101, 100…71, …]` | `OFFSET 30 LIMIT 30` | `[95…66]`（与①重叠 25 条）| 去重 ⇒ items **35** 条 · fetched **60** |
///
/// ⚠️ 注意：内容**只增不减** ⇒ 位移只会造成**重复**，**不会遗漏**。
///    所以「按 id 去重」足够，**不必**改成 keyset（`WHERE published_at < ?`）分页。
///
/// ## 拿 `items.length` 当 offset 会怎样（**症状：永远翻不到底**）
///
/// 第 ② 步后 `items.length = 35`，若下一页发 `OFFSET 35`：
/// 拿回的还是那 25 条重复项 ⇒ 去重后 `items.length` **仍是 35**
/// ⇒ 下一次还是 `OFFSET 35` ⇒ **每一页都白拿，列表再也不增长**。
///
/// 📌 判据：**分页游标必须独立记录「已向服务端请求过多少条」**，
///    它属于「协议层」；而 `items.length` 是「展示层」的数字 ——
///    两者只有在**没有重复**时才恰好相等。
///
/// # 其余字段
///
/// | 字段 | 说明 |
/// |---|---|
/// | `total` | 服务端报告的该类总数（**会变**：新内容进来就涨）⇒ 每次追加都用最新的 |
/// | `ended` | 🔴 服务端**已明确没有更多**。见 [append] 里的「空页」防护 |
/// | `loadingMore` | 正在加载下一页（footer 显示转圈）|
/// | `loadMoreError` | 加载更多失败 —— **不影响已显示的列表**（footer 显示 + 可重试）|
/// | `refreshError` | 下拉刷新失败 —— **同样不影响已有列表**，用轻提示表达 |
///
/// # 为什么错误分两个字段（而不是一个 `error`）
///
/// 两者的**界面表达不同**，合并会丢信息：
/// · `loadMoreError` → 列表**底部**（那里正是用户刚操作的位置）
/// · `refreshError`  → 列表**顶部**的轻提示（用户是从顶部下拉触发的）
///
/// 🔑 而「首次加载失败」**不在本类里** —— 那条路径由 provider 的 `AsyncError`
///    承担（全屏错误页 + 重试）。判据：**有数据时失败 ≠ 没数据时失败** ——
///    前者只是「这次没成功」，后者是「什么都看不到」。
class FeedPager<T> {
  /// 展示用的条目 —— **已按 id 去重**，顺序 = 服务端给的顺序。
  final List<T> items;

  /// 🔴 **游标**：已向服务端请求过的**原始**条数（**不是** `items.length`）。
  ///
  /// 下一页要发的 `offset` 就是它 —— 见类注释里「为什么不能拿 items.length 当 offset」。
  final int fetched;

  /// 服务端报告的总数（同 `category` 下）。用于判断还有没有更多。
  final int total;

  /// 🔴 服务端已明确「没有更多了」—— 由 [append] 收到**空页**时置位。
  ///
  /// ⚠️ 为什么不能只靠 `fetched < total`：`total` 是**另一个时刻**的数字。
  /// 若服务端 count 与实际可取条数不一致（并发删除 / 过滤条件差异），
  /// `fetched < total` 可能**恒为真** ⇒ 用户一直上拉、一直请求、**永远没有新内容**。
  /// 空页是**唯一可靠的终局信号**。
  final bool ended;

  final bool loadingMore;
  final Object? loadMoreError;
  final Object? refreshError;

  const FeedPager({
    this.items = const [],
    this.fetched = 0,
    this.total = 0,
    this.ended = false,
    this.loadingMore = false,
    this.loadMoreError,
    this.refreshError,
  });

  /// 还有下一页可拉吗。
  ///
  /// 🔑 `!ended` 必须在前 —— 空页之后 `fetched`/`total` 都可能不可靠。
  bool get hasMore => !ended && fetched < total;

  /// 下一页要发的 `offset`（= 已请求过的原始条数）。
  int get nextOffset => fetched;

  /// 展示层用到的是这个（去重后的条数）。
  int get loadedCount => items.length;

  bool get isEmpty => items.isEmpty;

  /// 从**第一页**建立（首次加载 / 下拉刷新成功）。
  ///
  /// ⚠️ 若第一页就是空的 ⇒ 直接 `ended = true`：
  ///    没有内容时不该让 UI 显示「上拉加载更多」。
  factory FeedPager.first(
    List<T> pageItems,
    int total, {
    required int Function(T) idOf,
  }) {
    // ⚠️ 必须**显式**写 `_dedupe<T>` 与 `List<T>.empty()`：
    //    `const []` 在泛型上下文里会被推断成 `List<dynamic>`
    //    ⇒ `_dedupe` 的 T 跟着变 dynamic ⇒ 返回 `List<dynamic>` 赋给 `List<T>` **报类型错**。
    //    （这不是理论风险 —— 本机纯 Dart 验证脚本第一次跑就抓到了这个错，
    //      见 `scripts/trace_verify/bin/verify_feed_pager.dart`。）
    final List<T> deduped = _dedupe<T>(List<T>.empty(), pageItems, idOf);
    return FeedPager<T>(
      items: deduped,
      fetched: pageItems.length,
      total: total,
      ended: pageItems.isEmpty,
    );
  }

  /// 追加一页（上拉加载更多成功）。
  ///
  /// 🔴 **空页必须终止分页** —— 见 [ended] 的说明。
  FeedPager<T> append(
    List<T> pageItems,
    int total, {
    required int Function(T) idOf,
  }) {
    // 🔴 终局信号优先于任何计数
    if (pageItems.isEmpty) {
      return FeedPager<T>(
        items: items,
        fetched: fetched,
        // 🔑 用 `fetched` 而不是服务端给的 `total`：让 `hasMore` 无论怎样都为假，
        //    且**不伪造**「已拉取条数」（不污染 `fetched` 的语义）
        total: fetched,
        ended: true,
        refreshError: refreshError,
      );
    }
    return FeedPager<T>(
      items: _dedupe(items, pageItems, idOf),
      // 🔴 累加**原始**条数（不是 items 的新长度）
      fetched: fetched + pageItems.length,
      total: total,
      ended: false,
      loadingMore: false,
      loadMoreError: null,
      refreshError: refreshError,
    );
  }

  /// 标记「正在加载更多」—— 同时**清掉上次的加载错误**（重新试了）。
  ///
  /// ⚠️ 必须用 `clearLoadMoreError`（而不是传 `loadMoreError: null`）——
  ///    `_copy` 里是 `?? this.loadMoreError`，传 null **等于「不修改」**。
  ///    📌 这个坑在 `startingRefresh()` 与这里各踩一次，**由本地验证脚本抓到**
  ///    （见 `verify_feed_pager.dart` 的「重试时清掉上次的 loadMoreError」）。
  FeedPager<T> startingLoadMore() => _copy(
        loadingMore: true,
        clearLoadMoreError: true,
      );

  /// 加载更多失败 —— **保留已有条目**（只是这一页没拿到）。
  FeedPager<T> loadMoreFailed(Object error) => _copy(
        loadingMore: false,
        loadMoreError: error,
      );

  /// 下拉刷新**开始** —— 保留列表（刷新期间继续显示旧内容，不闪白）。
  ///
  /// 🔑 刻意**不清空 items**：下拉刷新时列表若瞬间清空，
  ///    用户会看到「本来有内容 → 突然空白 → 又有内容」，比不刷新更糟。
  ///
  /// ⚠️ 必须**显式清除**两个错误（`_copy` 的 `?? this.x` 语义下，传 `null` = 不修改）——
  ///    这正是 `clearXxxError` 这两个开关存在的原因。
  /// ⚠️ 同时要把 `loadingMore` 归零：刷新会**重置整个分页**，
  ///    若此时正好在加载更多，残留的 `loadingMore=true` 会让 footer 一直转圈。
  FeedPager<T> startingRefresh() => _copy(
        loadingMore: false,
        clearRefreshError: true,
        clearLoadMoreError: true,
      );

  /// 下拉刷新失败 —— **保留列表**，只记一条错误供轻提示。
  FeedPager<T> refreshFailed(Object error) => _copy(refreshError: error);

  /// 清掉轻提示（SnackBar 显示完 / 用户忽略）。
  FeedPager<T> clearRefreshError() => _copy(clearRefreshError: true);

  FeedPager<T> _copy({
    List<T>? items,
    bool? loadingMore,
    Object? loadMoreError,
    Object? refreshError,
    bool clearLoadMoreError = false,
    bool clearRefreshError = false,
  }) {
    return FeedPager<T>(
      items: items ?? this.items,
      fetched: fetched,
      total: total,
      ended: ended,
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreError: clearLoadMoreError ? null : (loadMoreError ?? this.loadMoreError),
      refreshError: clearRefreshError ? null : (refreshError ?? this.refreshError),
    );
  }

  /// 把 [incoming] 里**没见过的** id 追加到 [existing] 之后。
  ///
  /// 🔑 保留**首次出现**的位置（后来的重复项被丢弃）——
  ///    这样列表顺序**始终等于服务端第一页时的顺序**，不会因为重复而抖动。
  ///    （代价：若服务端更新了某条的摘要，列表里仍是旧的那份 —— 下拉刷新即恢复。
  ///      这个取舍是有意的：**分页期间列表顺序稳定**比「逐条更新」更重要。）
  static List<T> _dedupe<T>(
    List<T> existing,
    List<T> incoming,
    int Function(T) idOf,
  ) {
    if (incoming.isEmpty) return existing;
    final seen = <int>{ for (final e in existing) idOf(e) };
    final out = List<T>.of(existing);
    for (final e in incoming) {
      if (seen.add(idOf(e))) {
        out.add(e);
      }
    }
    return out;
  }

  @override
  String toString() =>
      'FeedPager(items: ${items.length}, fetched: $fetched, total: $total, '
      'ended: $ended, loadingMore: $loadingMore)';
}
