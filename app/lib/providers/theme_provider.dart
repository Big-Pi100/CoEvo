import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/coevo_tokens.dart';

// 🔴 2026-10-13：`ThemeSettings`（纯数据 + 纯语义）**已拆到
//    `services/theme_settings.dart`**。
//
//    理由：本文件带 `SharedPreferences` + `StateNotifier` ⇒ 本机跑不了断言；
//    而「手动选档 ⇒ 关闭跟随系统」这条**语义**必须可验证。
//    拆过去后零 Flutter 依赖 ⇒ `dart run` 能做完整类型检查 + 行为断言。
//    📌 判据：**把能验证的尽量下沉**（同 `services/reading_settings.dart` 的模式）。
import '../services/theme_settings.dart';

/// 主题状态管理器（读写 `SharedPreferences`）。
class ThemeNotifier extends StateNotifier<ThemeSettings> {
  ThemeNotifier() : super(const ThemeSettings()) {
    _load();
  }

  static const String _kTheme = 'reading_theme';
  static const String _kFollow = 'follow_system';

  /// 旧 4 值枚举的 key —— 只用于**清理**，不再读取。
  static const String _kLegacy = 'app_theme_mode';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 旧 key 属于被删除机制的语义残留 → 顺手清掉（幂等）
      if (prefs.containsKey(_kLegacy)) {
        await prefs.remove(_kLegacy);
      }
      final name = prefs.getString(_kTheme);
      state = ThemeSettings(
        theme: ReadingTheme.values.firstWhere(
          (v) => v.name == name,
          orElse: () => ReadingTheme.ink,
        ),
        followSystem: prefs.getBool(_kFollow) ?? true,
      );
    } catch (e, st) {
      // 读不到就用默认值，不打断启动
      debugPrint('主题读取失败: $e\n$st');
    }
  }

  /// 切档位 —— 🔴 **手动选档会顺手关闭「跟随系统」**（2026-10-13 白哥定）。
  ///
  /// 语义与完整理由见 [ThemeSettings.manualTheme]（那是**唯一的判定点**）；
  /// 这里只负责调它 + 落盘。
  ///
  /// ⚠️ 早退条件**不能**只写 `state.theme == theme`：
  ///    用户点「墨」时若正开着「跟随系统」，也必须把开关关掉
  ///    （他表达的是「我要墨」）⇒ **两个条件都满足**才无事可做。
  Future<void> setTheme(ReadingTheme theme) async {
    if (state.theme == theme && !state.followSystem) return;
    state = state.manualTheme(theme);
    await _persist();
  }

  Future<void> setFollowSystem(bool value) async {
    if (state.followSystem == value) return;
    state = state.copyWith(followSystem: value);
    await _persist();
  }

  /// 🔑 持久化失败**不上抛** —— 主题是纯偏好，写不进去不该崩掉设置页。
  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTheme, state.theme.name);
      await prefs.setBool(_kFollow, state.followSystem);
    } catch (e, st) {
      debugPrint('主题持久化失败: $e\n$st');
    }
  }
}

final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeSettings>(
  (ref) => ThemeNotifier(),
);
