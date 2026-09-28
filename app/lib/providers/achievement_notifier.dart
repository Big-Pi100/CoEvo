// CoEvo · 成就**解锁通知队列**（Riverpod）
//
// # 职责
// 保存「**待展示**的解锁成就」队列，供 `widgets/achievement_unlock_overlay.dart` 逐个弹出。
//
// # 🔑 为什么需要队列（而不是「一次显示一个」）
// 一次检查可能同时解锁多个（例如连续 7 天 + 复习满 100 次 + 掌握 50 词）——
// 若直接覆盖显示，用户只能看到最后一个。
// 队列保证：**逐个展示，一个都不丢**（旧设计稿 §4.2 的「全局成就通知模块」）。
//
// # 🔑 与旧实现的差异
// 旧版（2026-06 删）由**后端**`new_achievements` 字段驱动 → 现已退役（后端成就引擎删除）。
// 现改为**端侧**：`checkAndRefreshAchievements()` 算出新解锁 → 入队 → Overlay 弹出。
// 📄 `docs/design/achievement-redesign-2026-09-29.md` §七

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/achievement_rules.dart';

/// 待展示的解锁队列（**队首 = 当前正在展示的那个**）。
class AchievementUnlockNotifier extends StateNotifier<List<AchievementDef>> {
  AchievementUnlockNotifier() : super(const []);

  /// 入队（**按 key 去重**）。
  ///
  /// 🔑 去重的必要性：`checkAndUnlock` 是幂等的，但**队列不是** ——
  /// 若同一成就被两次调用各入队一次（例如「查词后」与「进入我的页」接连触发，
  /// 而第二次调用恰好读到了第一次刚写入的记录），用户会看到两次弹窗。
  /// 用 key 去重从源头避免。
  void push(AchievementDef def) {
    if (state.any((d) => d.key == def.key)) return;
    state = [...state, def];
  }

  /// 批量入队（保持传入顺序 —— `checkAndUnlock` 已按清单顺序返回）。
  void pushAll(Iterable<AchievementDef> defs) {
    for (final d in defs) {
      push(d);
    }
  }

  /// 当前展示的那个已结束 → 出队。
  void dismissHead() {
    if (state.isEmpty) return;
    state = state.sublist(1);
  }

  /// 清空（用于调试 / 登出）。
  void clear() {
    if (state.isEmpty) return;
    state = const [];
  }
}

/// 解锁队列 provider。
final achievementUnlockProvider =
    StateNotifierProvider<AchievementUnlockNotifier, List<AchievementDef>>(
        (ref) => AchievementUnlockNotifier());
