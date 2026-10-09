import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/memory_settings.dart';

/// 记忆设置的**状态**（目前只有一项：默写容错阈值）。
///
/// 🔑 为什么单独一个类而不是直接 `StateProvider<int>`：
/// 同 `ReadingSettings` —— 将来加「是否开启划线卡复习」之类的项时，
/// **形状已经在了**（加字段 vs 把 int 换成对象）。
/// 📌 但**不预设**：现在只有一个字段就是只有一个。
class MemorySettings {
  /// 默写判定的容错阈值（**百分数整数** 0–30）。
  final int maxWrongPercent;

  const MemorySettings({this.maxWrongPercent = kMemoryMaxWrongPercentDefault});

  MemorySettings copyWith({int? maxWrongPercent}) => MemorySettings(
        maxWrongPercent: maxWrongPercent ?? this.maxWrongPercent,
      );
}

/// 记忆设置状态管理器（读写 `SharedPreferences`）。
///
/// 🔑 与 `ThemeNotifier` / `ReadingSettingsNotifier` **同一形态**
/// （StateNotifier + 失败不上抛 + 构造时 `_load`）——
/// 同类东西两种写法迟早会走偏（本项目既定判据）。
///
/// # ⚠️ 它与 `readingSettingsProvider` 是**两个** provider，不合并
///
/// | | `readingSettingsProvider` | 本 provider |
/// |---|---|---|
/// | 管什么 | **阅读可读性**（字号 / 痕迹）| **学习判定**（容错阈值）|
/// | 作用面 | 阅读器 | 复习页（且**只管划线卡**）|
/// | 归属 | 阅读器 | 记忆 / FSRS |
///
/// 🔑 判据同「两个状态的作用面不同 ⇒ 不该合并」：
///    合并后想给「复习卡单独调阈值」时会不知道动的是哪一份
///    （**这正是本条设置本身要管的事** —— 更要分开）。
class MemorySettingsNotifier extends StateNotifier<MemorySettings> {
  MemorySettingsNotifier() : super(const MemorySettings()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = MemorySettings(
        // 🔴 **必须过 `clampMemoryMaxWrongPercent`** —— 存储值可能是旧版本写的
        //    或损坏的（0 / -3 / 1e9）。不钳的话阈值 0 ⇒ 一切判「忘记」
        //    ⇒ **复习队列卡死**，且**不报错**（用户只看到「怎么都不通过」）。
        maxWrongPercent: clampMemoryMaxWrongPercent(
          prefs.getInt(MemoryPrefKeys.maxWrongPercent) ??
              kMemoryMaxWrongPercentDefault,
        ),
      );
    } catch (e, st) {
      // 读不到就用默认值，不打断启动（与主题 / 阅读设置同一条：纯偏好，失败不该崩）
      debugPrint('记忆设置读取失败: $e\n$st');
    }
  }

  /// 设置阈值（会钳到合法区间；越界输入不报错，静默取边界）。
  Future<void> setMaxWrongPercent(num v) async {
    final next = clampMemoryMaxWrongPercent(v);
    if (state.maxWrongPercent == next) return;
    state = state.copyWith(maxWrongPercent: next);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 🔑 存的是**钳过**的值 —— 这样「读回时再钳一次」是幂等的
      //    （幂等性让「历史脏数据」只在第一次读时被修正，不会反复漂）
      await prefs.setInt(MemoryPrefKeys.maxWrongPercent, state.maxWrongPercent);
    } catch (e, st) {
      // 写失败不改内存态（用户这次调整仍然生效，只是下次启动回默认）
      debugPrint('记忆设置写入失败: $e\n$st');
    }
  }
}

final memorySettingsProvider =
    StateNotifierProvider<MemorySettingsNotifier, MemorySettings>(
        (ref) => MemorySettingsNotifier());
