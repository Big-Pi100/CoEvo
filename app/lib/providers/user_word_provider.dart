// CoEvo · 生词本 / 查词记录的 provider
//
// 🔴 设计约束：连接从 `userDbProvider` 取（**不自己 open**）—— 见其文件头「为什么必须共享」。
//
// # 与 `bookmarkProvider` 的分工
// | | `bookmarkProvider` | 本文件 |
// |---|---|---|
// | 关注点 | 「**这篇**收藏了吗」（`Set<int>` · 高频单条判定） | 「**收进去** / 记一次查词」（写为主） |
// | 状态 | `AsyncNotifier<Set<int>>`（要驱动 UI 重绘） | **不暴露状态**，只暴露仓储 |
//
// # 🔑 为什么本 provider **不**做成 `AsyncNotifier`
// 「某词是否在生词本」是**查词那一刻**才问的（不是每帧渲染都要问），
// 所以不需要一个长期订阅的状态对象 —— 那会带来「什么时候刷新」的额外问题
// （而 `bookmarkProvider` 需要它，是因为书签按钮**在信息流每张卡上都在渲染**）。
// → 保持最小：`FutureProvider<UserWordRepository>`，用到时 `await` 一次。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/user_word_repository.dart';
import 'user_db_provider.dart';

/// 生词本仓储（**已就绪**才拿得到 —— `await ref.read(...future)` 或 `watch`）。
///
/// 用法：
/// ```dart
/// final repo = await ref.read(userWordProvider.future);
/// final r = await repo.add(wordId, spelling, sentence: sentence);
/// ```
///
/// ## ⚠️ 消费约定（同 `bookmarkProvider` 的硬约束）
/// **查词写入不得阻塞释义渲染** —— 写入失败只记日志，
/// 用户照常看到浮层（读词义是产品核心，不该因为写库失败而看不到）。
/// 见 `reader_screen._lookupWord` 的调用处。
final userWordProvider = FutureProvider<UserWordRepository>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  return UserWordRepository(db);
});

/// 生词数（用于「生词本 N/200」与上限判定）。
///
/// ⚠️ 与 `bookmarkListProvider` 同理：这个值**会变**（每次查词可能 +1），
/// 所以用 `FutureProvider` + 需要时 `ref.invalidate` 刷新，
/// 而不是自己维护一个可能过期的副本。
final userWordCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(userWordProvider.future);
  try {
    return await repo.count();
  } catch (e, st) {
    // 🔑 读失败**不抛**：调用方要的是「显示个数」，不该因为库坏了把界面炸掉。
    //    （同 `userDbProvider` 的消费约定：不要把库当作内容渲染的前置条件。）
    debugPrint('[user_word] 取生词数失败：$e\n$st');
    return 0;
  }
});

/// 生词本列表（按加入时间倒序）—— 供**生词本页**使用。
///
/// # 🔑 为什么要有它（不能在页面里直接 `repo.list()`）
/// `FutureProvider` 会把自己注册进 Riverpod 的依赖图 → **`ref.invalidate` 能驱动页面重建**。
/// 若把 `repo.list()` 写在页面的 `initState` 里，就**没有**这个能力，
/// 于是「移出一个词后列表不刷新」得手写 `setState`（多一处会漏的状态）。
/// （同 `bookmarkListProvider` 存在的理由。）
///
/// # ⚠️ 排序由**仓储层**保证，UI 层不得再排一次
/// `UserWordRepository.list()` 已 `ORDER BY added_at DESC`（走 `idx_uw_time`）。
/// 两处排序定义 = 漂移源 → 页面**直接按返回顺序渲染**。
///
/// # ⚠️ 读失败**会抛**（与 `bookmarkListProvider` 的「返回空表」**有意相反**）
/// 生词本是**用户自己攒下的东西**，读不出来必须**明确告知**（页面渲染 `_Unavailable`），
/// 而不是显示「还没有生词」—— 后者是对用户的**谎报**
/// （同 `bookmark_list_screen._Unavailable` / `userDbProvider` 的既定原则）。
final userWordListProvider = FutureProvider<List<UserWord>>((ref) async {
  final repo = await ref.watch(userWordProvider.future);
  return repo.list();
});
