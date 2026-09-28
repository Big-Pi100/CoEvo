// CoEvo · `user.db` 的**共享连接** provider
//
// 🔴 设计约束：本文件**只负责「打开一次、统一释放」**，不含任何业务查询。
//
// # 🔴🔴 为什么必须共享（2026-09-28 引入 · 防一个具体 bug）
//
// 原先只有 `bookmarkProvider` 打开 `user.db`，自己 `ref.onDispose(() => db.close())`。
// Step 3.4c 又要加「生词本 / 查词记录」—— 若它**也自己 open 一次**：
//
// · `sqflite` 默认 **`singleInstance: true`** → 同路径第二次 `openDatabase`
//   返回的是**同一个 `Database` 对象**（不是新连接）
// · 两个 provider **各自 `onDispose(close)`** → 谁先销毁谁把**共用的那个**关掉
//   → 另一个 provider 继续用 → `database_closed` 异常
//
// 🔑 所以「多个功能共用一个库」时，**连接的所有权必须唯一**。
//    本 provider 就是那个唯一所有者：谁要用库，都 `await ref.watch(userDbProvider.future)`。
//
// ⚠️ 这是本项目已记录过的坑（`ARCHIVE.md` 的通用技术教训）：
//    「`sqflite` 默认 `singleInstance: true` → `close()` **连带关掉别处连接**」。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
// `Database` 类型来自 `sqflite_common`（`sqflite` 是它的实现）——
// `user_db.dart` 只导出函数，不 re-export 类型，故这里显式引入。
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../services/user_db.dart';

/// 已打开的 `user.db`（**全局唯一**）。
///
/// 用法：
/// ```dart
/// final db = await ref.watch(userDbProvider.future);
/// final repo = BookmarkRepository(db);
/// ```
///
/// 🔑 用 `watch(...future)` 而不是 `read` —— 消费方通常在 `AsyncNotifier.build()`
///    里，需要**等它就绪**（同 `word_db_provider` 的 `ref.watch` 教训：
///    只 `read` 会让「第一次使用」赶在初始化之前 → 必失败）。
///
/// ## ⚠️ 消费约定（同 `bookmarkProvider` 的硬约束）
/// **不要把本 provider 当作「内容能不能渲染」的前置条件** ——
/// 库打不开时，信息流 / 阅读器**照常渲染**，只是那些依赖它的功能不可用。
/// 详见 `bookmark_provider.dart` 顶部的说明。
final userDbProvider = FutureProvider<Database>((ref) async {
  try {
    // 🔑 DDL 由 Flutter 侧读入并注入 —— 连接层（`user_db.dart`）因此保持**纯 Dart**，
    //    能在脚本里独立验证（见 `scripts/query_verify/`）。
    final schema = await rootBundle.loadString(kUserDbSchemaAsset);

    // 应用支持目录（**不是** Documents）：
    //   · Documents 会被 iCloud 备份、且用户在「文件」App 里看得见
    //   · `user.db` 是内部状态库（复习状态 / 收藏 / 生词）→ 不该暴露给用户
    //   · Application Support 正好是「App 私有」的语义
    final dir = await getApplicationSupportDirectory();
    final db = await openUserDb(
      factory: sqflite.databaseFactory,
      path: p.join(dir.path, kUserDbFileName),
      schemaSql: schema,
    );

    // 🔑 **唯一的释放点**（见文件头「为什么必须共享」）——
    //    provider 销毁 = 应用退出。消费方**不允许**自己 close。
    ref.onDispose(() => db.close());

    return db;
  } catch (e, st) {
    // 🔴🔴 **必须留痕**（2026-09-27 补 · 从 `bookmark_provider` 迁来）
    //
    // 背景：真机报「收藏按钮点击没用」时，**logcat 里一行都没有** ——
    // 因为 provider 刻意不 catch（语义对）→ 异常变成 `AsyncError` 进了 state，
    // 却**从未写进日志** → 只能靠读代码反推根因，代价极大。
    //
    // 🔑 「刻意不 catch」与「不打日志」是**两件事**：
    //    · 不 catch = 让失败如实成为 `AsyncError` → **这是对的**（语义正确）
    //    · 不打日志 = 失败**无法被诊断** → **这是遗漏**
    // 所以「打日志 + `rethrow`」：语义完全不变，只多一条可查的痕迹。
    //
    // ⚠️ 日志前缀比原先更准确：以前是 `[bookmark] user.db 打开失败`，
    //    但**打开的是整个 user.db**、不只服务收藏 → 现统一为 `[user_db]`。
    //    排查时请用 `adb logcat | grep user_db`。
    debugPrint('[user_db] 打开失败：$e\n$st');
    rethrow;
  }
});

// ════════════════════════════════════════════════════════════════
// 「数据变了」的单一信号源
// ════════════════════════════════════════════════════════════════

/// `user.db` 的**修订号** —— 凡是「库里的数据被改动过」，就让这个数字 +1。
///
/// # 🔴 为什么需要它（2026-09-28 白哥真机报的**两个**现象）
/// > 「划词后进入复习页面，第一时间看不到新单词，要切换一下内部 tab 才能看到；
/// >   考试后单词状态也不能第一时间改变，同样也要切换一下」
///
/// 根因：读端是**带缓存的** `FutureProvider`（`reviewListProvider` /
/// `reviewDueCountProvider`），只有 `invalidate` 或失去监听者才重算。
/// 而写端有三处（划词 / 评级 / 暂停），**通知步骤靠人记**：
/// · 划词写回 —— 🔴 **一处都没有**
/// · 评级提交 —— ⚠️ 只在 `dispose()` 里（时机脆弱：把「数据变了」押在「页面被销毁」上）
/// · 暂停 —— ✅ 有（唯一一处正确范例）
///
/// 🔑 **判据：靠「每个写端都要记得通知每个读端」的机制，迟早会漏。**
///    这里读端有 2 个、写端有 3 个 → 6 条线要维护；将来（3.7 聚合页等）
///    只会更多。**漏掉一条的表现正是本次的现象：数据对、界面不更新。**
///
/// → 改为**反转依赖**：读端自己 `watch` 修订号，写端只 `bump()` 一次。
///   · 新增读端 → 自动跟随（写端**不用改**）
///   · 新增写端 → 只需记得 `bump()` 一次（不必知道有哪些读端）
///
/// 🔑 这也消掉了「忘了 invalidate 某一个 provider」这类漏点：
///    原先每次刷新要**同时**点名 `reviewListProvider` + `reviewDueCountProvider`
///    （少点一个 → 「列表少了一条但顶部计数没变」）。现在写端不必点名任何人。
///
/// # ⚠️ 与 `invalidate` 的分工（**不要两套并存**）
/// 本文件引入修订号后，**针对复习数据的 `invalidate` 应全部移除** ——
/// 同一个目的有两套机制时，改了一处、另一处仍在按老路子工作，
/// 会让下次排查无从下手（本项目已多次踩到「两处定义 = 漂移源」）。
/// `invalidate` 仍适用于**与库无关**的刷新意图。
///
/// # 🔑 为什么放在本文件（而不是新开一个 provider 文件）
/// 它描述的是**这个库**的状态 —— 与「库的唯一所有者 / 唯一 open-close 点」
/// 是同一个概念。放一起，才能让「库有变化」这件事只有一个出处。
class UserDbRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// 报告「库被改动了」。**在写库成功之后**调用（不是之前、也不是并发地）。
  ///
  /// ⚠️ 顺序很重要：先写库再 bump。反过来的话，读端可能在写入完成前
  ///    就重新查库 → 查到的仍是旧数据，然后**不会再自动刷新一次**
  ///    （修订号已经变过了，值没再变 → 读端不会重算）→ 表现为「这次没刷新」。
  void bump() => state = state + 1;
}

final userDbRevisionProvider =
    NotifierProvider<UserDbRevision, int>(UserDbRevision.new);
