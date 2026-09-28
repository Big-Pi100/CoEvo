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
