import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/coevo_tokens.dart';

/// 主题设置。
///
/// 🔑 spec §二：**持久化只需两个字段** —— 档位 + 跟随系统开关。
/// 「跟随系统」是**开关，不是第四个主题**：
/// - 浅色环境 → 用户选的浅色档（墨 / 格）
/// - 深色环境 → [ReadingTheme.night]
///
/// > 旧实现是 4 值枚举 `{system, light, dark, duolingo}` + 默认 `duolingo`，
/// > 已被本模型整体取代（2026-09-27）。旧偏好值不做迁移 —— 直接以
/// > 「墨 + 跟随系统」为默认起点。
class ThemeSettings {
  /// 用户选的档位。
  ///
  /// ⚠️ 当 [followSystem] 为 true 时，它表达的是「**浅色环境下**用哪一档」——
  /// 取 [lightTheme] 而不是直接用它。
  final ReadingTheme theme;

  /// 跟随系统明暗自动切换。
  final bool followSystem;

  const ThemeSettings({
    this.theme = ReadingTheme.ink,
    this.followSystem = true,
  });

  /// 浅色环境实际生效的档位。
  ///
  /// 🔑 「夜」不是浅色档 —— 用户选了夜又开着跟随系统时，白天要回落到「墨」，
  /// 否则「跟着系统走」在浅色环境下会失效（永远停在深底）。
  ReadingTheme get lightTheme =>
      theme == ReadingTheme.night ? ReadingTheme.ink : theme;

  ThemeSettings copyWith({ReadingTheme? theme, bool? followSystem}) =>
      ThemeSettings(
        theme: theme ?? this.theme,
        followSystem: followSystem ?? this.followSystem,
      );
}

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

  Future<void> setTheme(ReadingTheme theme) async {
    if (state.theme == theme) return;
    state = state.copyWith(theme: theme);
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
