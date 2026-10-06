import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/reading_settings.dart';

/// 阅读器设置 —— 与「设计系统主题」（`themeProvider`）**分开**。
///
/// # 🔑 为什么是两个 provider，不合并成一个「阅读设置」
///
/// | | `themeProvider` | 本 provider |
/// |---|---|---|
/// | 管什么 | **主题档位**（墨/格/夜）+ 跟随系统 | **正文可读性**（字号）+ 痕迹开关 |
/// | 作用面 | **全局**（所有页面都随主题变）| **只在阅读器**（字号不影响词卡/列表）|
/// | 归属 | 设计系统（spec §二）| 阅读器（spec §5.1）|
///
/// ⇒ 合并会让「全局主题」与「页内偏好」混成一个状态：
///    将来想给**复习卡**单独调字号时，会不知道动的是哪一份。
/// 📌 判据：**两个状态的「作用面」不同 ⇒ 不该合并**（同「共用数据≠同判据」一族）。
///
/// ⚠️ 但两者**在同一个面板里暴露**给用户（见 `widgets/reading_settings_panel.dart`）——
///    「面板写在一起」与「状态存在一起」是两件事。
class ReadingSettings {
  /// 正文字号（已钳到 15–24）。
  final int fontSize;

  /// 痕迹开关（spec §5.1：默认开）。
  final bool traceEnabled;

  const ReadingSettings({
    this.fontSize = kReadingFontSizeDefault,
    this.traceEnabled = kTraceEnabledDefault,
  });

  ReadingSettings copyWith({int? fontSize, bool? traceEnabled}) =>
      ReadingSettings(
        fontSize: fontSize ?? this.fontSize,
        traceEnabled: traceEnabled ?? this.traceEnabled,
      );
}

/// 阅读器设置状态管理器（读写 `SharedPreferences`）。
///
/// 🔑 与 `ThemeNotifier` **同一形态**（StateNotifier + 失败不上抛）——
///    同类东西两种写法迟早会走偏（本项目既定判据）。
class ReadingSettingsNotifier extends StateNotifier<ReadingSettings> {
  ReadingSettingsNotifier() : super(const ReadingSettings()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = ReadingSettings(
        // 🔴 **必须过 `clampReadingFontSize`** —— 存储值可能是旧版本写的 18、
        //    或损坏的 0 / 负数 / 超大值。不钳的话字号 0 = 正文不可见，
        //    且**不报错**（用户会以为文章是空的）。
        fontSize: clampReadingFontSize(
          prefs.getInt(ReadingPrefKeys.fontSize) ?? kReadingFontSizeDefault,
        ),
        traceEnabled:
            prefs.getBool(ReadingPrefKeys.traceEnabled) ?? kTraceEnabledDefault,
      );
    } catch (e, st) {
      // 读不到就用默认值，不打断启动（与主题同一条：纯偏好，失败不该崩）
      debugPrint('阅读器设置读取失败: $e\n$st');
    }
  }

  /// 设置字号（会钳到合法区间；越界输入不报错，静默取边界）。
  Future<void> setFontSize(num v) async {
    final next = clampReadingFontSize(v);
    if (state.fontSize == next) return;
    state = state.copyWith(fontSize: next);
    await _persist();
  }

  /// 按步长调整（−/+ 键用）。到边界后**不变**（由 UI 决定要不要禁用）。
  Future<void> stepFontSize(int delta) => setFontSize(state.fontSize + delta);

  Future<void> setTraceEnabled(bool value) async {
    if (state.traceEnabled == value) return;
    state = state.copyWith(traceEnabled: value);
    await _persist();
  }

  /// 🔑 持久化失败**不上抛** —— 纯偏好，写不进去不该崩（同 `ThemeNotifier._persist`）。
  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(ReadingPrefKeys.fontSize, state.fontSize);
      await prefs.setBool(ReadingPrefKeys.traceEnabled, state.traceEnabled);
    } catch (e, st) {
      debugPrint('阅读器设置持久化失败: $e\n$st');
    }
  }
}

final readingSettingsProvider =
    StateNotifierProvider<ReadingSettingsNotifier, ReadingSettings>(
  (ref) => ReadingSettingsNotifier(),
);
