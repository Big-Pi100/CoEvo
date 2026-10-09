import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/bookmark_repository.dart';
import 'user_db_provider.dart';

/// 收藏状态 —— 已收藏的 `content_id` 集合。
///
/// # 🔴 一条硬约束（沿用 Step 3.22 的教训）
///
/// > **不要把易失败的外部依赖放在内容渲染的前置条件上**
///
/// 所以本 provider **不是**「信息流能不能显示」的前置条件 ——
/// 数据库没打开好，信息流**照常渲染**，只是书签按钮**禁用**。
///
/// ## ⚠️ 消费本 provider 时必须遵守的约定
///
/// **只能用 [BookmarkStateX.idsOrEmpty] 与 [BookmarkStateX.isReady]，不要用 `when` / `maybeWhen`。**
///
/// 原因：`when(error:)` 会把「数据库打不开」渲染成一个**错误界面** ——
/// 而收藏只是信息流的一个附属动作，它坏了不该把内容页变成报错页。
/// 两个 getter 已经把这件事处理好了：
/// - 未就绪 / 失败 → 集合为空（显示「未收藏」）+ `isReady = false`（按钮禁用）
/// - 就绪 → 正常读写
///
/// # 为什么状态是 `Set<int>` 而不是 `List<Bookmark>`
///
/// 见 [BookmarkRepository] 的类注释：UI 只问两个问题 ——
/// 「这篇收藏了吗」（`contains`）与「收藏了几篇」（`length`），
/// 两者都靠集合 O(1) 回答。完整记录（含时间戳）只在**打开收藏清单**时查库。
final bookmarkProvider =
    AsyncNotifierProvider<BookmarkNotifier, Set<int>>(BookmarkNotifier.new);

class BookmarkNotifier extends AsyncNotifier<Set<int>> {
  BookmarkRepository? _repository;

  /// 已打开的仓储；`null` = 尚未就绪（或打开失败）。
  BookmarkRepository? get repository => _repository;

  @override
  Future<Set<int>> build() async {
    // 🔴🔴 2026-10-10：**订阅「库修订号」** —— 这是「写端 bump」的**另一半**。
    //
    //    `_runSync` 在 pull 之后会 `bump()`（2026-10-09 补的），但
    //    **bump 只对「订阅了它的读端」生效**。实测逐类核对：
    //      · `review_list_provider` 3 处 · `highlight_provider` 5 处
    //      · `book_provider` 3 处 · `word_db_provider` 2 处
    //      · **本 provider 0 处** ⇒ 6 类同步数据里**恰好漏了收藏这一类**
    //    ⇒ 同步拉回来的收藏**落了库却不重算** ⇒ 白哥真机看到的
    //      「收藏数据是对的，但要**关闭页面再打开**才显示」。
    //
    //    📌 判据：**`bump` 只在「读端也订阅」时才有效** ——
    //       加 bump 时必须**逐个读端核对订阅**（列一张表），只补 bump 不核订阅
    //       就会留下「6 类里漏 1 类」这种最难发现的缺口。
    //       同族：「写端逐个通知读端」是必漏结构 ⇒ **反转依赖**（读端 watch 修订号）才对。
    //
    //    ⚠️ 放在 `await` **之前** —— async body 里 `await` 之后再 watch
    //       可能撞上 provider 已被销毁（Riverpod 的 ref 在 async gap 后不再安全）。
    //       （与 `review_list_provider` 同一形态，见那里的同款注释。）
    ref.watch(userDbRevisionProvider);

    // 🔴 **连接不在这里打开**（2026-09-28 改为共享单例）
    //
    // 原先本方法自己 `rootBundle` + `getApplicationSupportDirectory` + `openUserDb`
    // + `ref.onDispose(close)`。Step 3.4c 加了「生词本」后**不能**再有第二份 ——
    // `sqflite` 默认 `singleInstance: true` → 第二次 open 拿到的是**同一个对象**，
    // 两个 provider 各自 close 会**互相踩**（`database_closed`）。
    // → 连接的所有权统一归 `userDbProvider`（见其文件头的详细说明）。
    //
    // 🔑 打开失败的处理也一并迁走：现在由 `userDbProvider` 打 `[user_db]` 日志并
    //    `rethrow` → 这里照旧收到 `AsyncError` → `isReady = false` → 按钮禁用。
    //    **语义完全不变**，只是日志前缀更准确（打开的是整个 user.db，不只服务收藏）。
    final db = await ref.watch(userDbProvider.future);

    final repo = BookmarkRepository(db);
    await repo.reload();
    _repository = repo;

    // ⚠️ **本方法刻意不 catch** —— 让失败如实成为 `AsyncError`：
    //    · 若吞掉并返回空集合，provider 会变成 `AsyncData({})`，
    //      于是 `isReady` 为 true → 按钮可点 → 点了却毫无反应（用户无法理解）。
    //    · 让它成为 `AsyncError`，`isReady` 自然为 false → 按钮禁用，语义正确。
    //    · 同时错误对象留在 state 里（将来可做「重试」），而不只是躺在日志。
    //    安全的前提是**消费方只用 `idsOrEmpty` / `isReady`**（见类文档的约定）。
    return repo.ids;
  }

  /// 切换某篇文章的收藏状态。
  ///
  /// 返回**切换后**是否已收藏；`null` = 仓储未就绪或写入失败，**本次没有动作**。
  ///
  /// 🔑 返回可空而不是 `false`：调用方要区分
  /// 「成功取消了收藏」与「压根没执行」——
  /// 两者若都返回 `false`，UI 会为一次**没发生的操作**弹 toast。
  Future<bool?> toggle(int contentId) async {
    final repo = _repository;
    if (repo == null) return null;

    try {
      final on = await repo.toggle(contentId);
      state = AsyncData(repo.ids);
      return on;
    } catch (e, st) {
      debugPrint('[bookmark] 切换收藏失败 contentId=$contentId：$e\n$st');
      // 状态没变 → 保持原样；返回 null 让 UI 知道「没成功」
      return null;
    }
  }
}

/// 给 UI 的派生视图 —— 让「未就绪」的处理只写一次。
extension BookmarkStateX on AsyncValue<Set<int>> {
  /// 数据库是否已就绪（**就绪才允许点击**）。
  ///
  /// - `AsyncData` → `true`
  /// - `AsyncLoading`（首次加载）→ `false`
  /// - `AsyncError`（打开失败）→ `false` ← 于是按钮禁用，用户不会点了个没反应的按钮
  bool get isReady => hasValue;

  /// 已收藏集合（未就绪 / 失败时为空集 → UI 一律显示「未收藏」）。
  Set<int> get idsOrEmpty => valueOrNull ?? const <int>{};
}

/// 收藏清单（**按收藏时间倒序**）—— 供收藏清单页使用。
///
/// # 🔑 为什么不直接用 [bookmarkProvider] 的 `Set<int>`
/// **集合没有顺序**。而清单的排序是设计明确要求的
/// （设计稿 §四 ②：「时间戳 DESC 排序 —— 「我刚存了什么」的直觉」）
/// → 必须回到仓储层拿**带时间戳的记录**（[Bookmark.bookmarkedAt]）。
///
/// # 🔑 为什么 `watch(bookmarkProvider.future)`，不能只 `read`（同 3.32 的教训）
/// · 只 `read` → 不等仓储就绪 → **第一次打开清单必然是空**（而它其实有内容）
/// · `watch` 还带来一个必要行为：**收藏变化后清单自动刷新** ——
///   [BookmarkNotifier] 每次 `toggle` 都会 `state = AsyncData(...)` →
///   本 provider 重算 → 在清单里点掉一个收藏，它会**立刻从列表消失**。
///   （这正是「取关即消失」的预期表现，不用手写 `setState`。）
final bookmarkListProvider = FutureProvider<List<Bookmark>>((ref) async {
  await ref.watch(bookmarkProvider.future);
  final repo = ref.read(bookmarkProvider.notifier).repository;
  // 仓储为 null = 打开失败 → 返回空表。
  // ⚠️ 这里**返回空表而不是抛错**：调用方要区分「没有收藏」与「库不可用」，
  //    靠的是**另一个** [AsyncValue]（`bookmarkProvider.isReady`），
  //    而不是让本 provider 变成 `AsyncError`（那会把整页渲染成报错页）。
  // 🔑 两支都要**同类型**：`repo.list()` 返回 `Future<List<Bookmark>>`，
  //    而不加 `await` 时三元表达式的两支分别是 `List<Bookmark>` 与 `Future<...>`
  //    → 最小上界退化成 `Object` → 与 `async` 闭包的返回类型不符（analyzer 报 error）。
  //    `async` 函数里 `return future` 本来就会隐式 await → 补上 `await`
  //    **只把意图写明、不改行为**（这也是 analyzer 认可的写法）。
  return repo == null ? const <Bookmark>[] : await repo.list();
});
