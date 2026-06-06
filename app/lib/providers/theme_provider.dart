import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用主题模式
enum AppThemeMode {
  system,    // 跟随系统
  light,     // CoEvo 浅色
  dark,      // CoEvo 深色
  duolingo,  // Duolingo 风格
}

/// 主题状态
class ThemeState {
  final AppThemeMode mode;
  const ThemeState({this.mode = AppThemeMode.duolingo});

  ThemeState copyWith({AppThemeMode? mode}) =>
      ThemeState(mode: mode ?? this.mode);
}

/// 主题状态管理器
class ThemeNotifier extends StateNotifier<ThemeState> {
  ThemeNotifier() : super(const ThemeState()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('app_theme_mode') ?? 3;
    if (index >= 0 && index < AppThemeMode.values.length) {
      state = ThemeState(mode: AppThemeMode.values[index]);
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('app_theme_mode', mode.index);
      state = ThemeState(mode: mode);
    } catch (e, st) {
      debugPrint('主题持久化失败: $e\n$st');
      rethrow;
    }
  }
}

/// 主题 Provider
final themeProvider =
    StateNotifierProvider<ThemeNotifier, ThemeState>((ref) {
  return ThemeNotifier();
});
