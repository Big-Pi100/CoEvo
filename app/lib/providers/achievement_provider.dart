// CoEvo · 成就的 Riverpod 入口（只读快照 + 解锁检查）
//
// 🔴 设计约束：本文件**只提供数据**，不做 UI。
//    UI 在：
//      · `widgets/achievement_section.dart`（「我的」页顶部成就区）
//      · `screens/achievements_screen.dart`（成就墙二级页）
//
// # 🔑 消费约定（沿用 `bookmark_provider.dart` / `user_db_provider.dart` 的既定原则）
// **不要把本 provider 当作「页面能不能渲染」的前置条件。**
// 库打不开时，「我的」页**照常渲染**（账号 / 订阅 / 主题都在），
// 只有成就区显示占位或空态。
// ⚠️ 本项目判据：「**静默失败 + 无出口**」比报错更糟 ——
//    所以成就区自己处理 loading/error，**不向上抛**。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../services/achievement_rules.dart';
import '../services/achievement_service.dart';
import 'user_db_provider.dart';

/// 成就快照（**只读**：采集指标 + 判定 + 读解锁记录）。
///
/// · 用 `FutureProvider`（**不 autoDispose**）：成就查询要读 `review_log` 全表，
///   切页就重查属于浪费。需要刷新时显式 `ref.invalidate(...)`（见下）。
/// · `now` 用 `DateTime.now()`（**本地时间**）—— 口径要求见 `achievement_rules.dart` 文件头 ②。
final achievementSnapshotProvider =
    FutureProvider<AchievementSnapshot>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  return AchievementService(db).snapshot(now: DateTime.now());
});

/// 成就**解锁时间**（`key → 本地时间`）。
///
/// 🔑 为什么与 `achievementSnapshotProvider` **分开**：
/// · snapshot 只要「哪些已解锁」（判定结果），解锁时间只用于**成就墙的展示**
/// · 合成一个 provider 会让「我的」页顶部也去读时间 → 白读一次
/// · 两者**必须一起失效**（见 `checkAndRefreshAchievements`），否则成就墙会显示旧日期
final achievementUnlockTimesProvider =
    FutureProvider<Map<String, DateTime>>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  return AchievementService(db).loadUnlocks();
});

/// **检查并落库 + 刷新快照**；返回本次新解锁（供弹通知）。
///
/// 调用时机（方案 §七）：
/// · 复习提交后（`review_session` 的提交路径）
/// · 查词入库后（`word_query_service` 的写回路径）
/// · 进入「我的」页时（兜底 —— 保证不会因为漏调而永远不解锁）
///
/// 🔑 **幂等**：内部用 `INSERT OR IGNORE`，重复调用安全（见 `achievement_service.dart`）。
/// 因此「多处触发」不需要协调，**宁可多调**（漏调才会导致成就不解锁）。
///
/// ⚠️ 失败时**不抛**：成就解锁不该影响主流程（复习/查词）。返回空列表。
///
/// 🔑 形参类型是 **`WidgetRef`**（不是 `Ref`）—— 两者在 Riverpod 2.x 里是不同类，
///    不能互相赋值。本函数**只由 UI 层调用**（复习提交 / 查词写回 / 进入我的页），
///    所以取 `WidgetRef`。（实测：写成 `Ref` 会编译报 E 类错误。）
Future<List<AchievementDef>> checkAndRefreshAchievements(WidgetRef ref) async {
  try {
    final db = await ref.read(userDbProvider.future);
    final newly = await AchievementService(db)
        .checkAndUnlock(now: DateTime.now());
    if (newly.isNotEmpty) {
      // 有新解锁 → 让两处缓存都失效（否则成就墙显示不到新日期）
      ref.invalidate(achievementSnapshotProvider);
      ref.invalidate(achievementUnlockTimesProvider);
    }
    return newly;
  } catch (e) {
    // 🔑 留痕但不打断：失败原因要可见（否则「成就永远不亮」无法排查）
    //    本项目判据：「provider 失败必须留日志」——「不 catch」与「不打日志」是两件事
    // ignore: avoid_print
    print('[achievement] checkAndUnlock 失败（不影响主流程）: $e');
    return const [];
  }
}

/// 便捷：拿一个 `AchievementService`（已有打开的库时用）。
AchievementService achievementServiceOf(Database db) => AchievementService(db);
