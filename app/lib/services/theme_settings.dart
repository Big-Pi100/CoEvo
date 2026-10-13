// ════════════════════════════════════════════════════════════════════════
// 主题设置 —— **纯逻辑层**（零 Flutter / Riverpod 依赖）
// ════════════════════════════════════════════════════════════════════════
//
// 🔴 为什么单独一个文件、且不 import Flutter：
//    与同目录的 `reading_settings.dart` **同一模式** —— 纯逻辑可以用
//    `dart run` 做**完整类型检查 + 行为断言**；而 `providers/theme_provider.dart`
//    （带 `SharedPreferences` + `StateNotifier`）本机跑不起来。
//    ⇒ 判据：**把能验证的尽量下沉**。
//
// 📌 2026-10-13 从 `providers/theme_provider.dart` 拆出 ——
//    起因：「手动选档 ⇒ 应自动关闭『跟随系统』」这条**语义**必须可断言
//    （白哥真机实测发现点了「夜」主题色不变）。

import '../theme/coevo_tokens.dart';

/// 主题**最终生效的明暗意图** —— 与 Flutter 的 `ThemeMode` 一一对应。
///
/// 🔑 为什么不用 `ThemeMode` 本体：本文件**零 Flutter 依赖**，
///    这样才能被 `dart run` 断言（见文件头）。调用方做一次 `switch` 映射即可 ——
///    而 `switch` 对枚举是**穷尽检查**的，将来加成员会编译报错而不是静默漏掉。
enum ThemeIntent {
  /// 跟随系统明暗（→ `ThemeMode.system`）
  followSystem,

  /// 强制浅色（→ `ThemeMode.light`）
  light,

  /// 强制深色（→ `ThemeMode.dark`）
  dark,
}

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

  /// **浅色槽**该用哪一档（供 `MaterialApp.theme`）。
  ///
  /// 🔑 「夜」不是浅色档 —— 它必须回落到「墨」，否则浅色环境下会停在深底。
  /// ⚠️ 注意本 getter **不看 [followSystem]** —— 它只是「浅色槽放什么」，
  ///    实际是否生效由 [intent] 决定（`followSystem=true` 且系统为浅色时才走这一槽）。
  ReadingTheme get lightTheme =>
      theme == ReadingTheme.night ? ReadingTheme.ink : theme;

  /// **最终生效的明暗意图** —— 由设置推出的唯一判定点。
  ///
  /// 🔑 为什么要有它（而不是在 `app.dart` 里写三元表达式）：
  ///    那条三元式是「**点了夜主题色不变**」这个 bug 的**根源判据**，
  ///    而它原先只存在于 Flutter 文件里 ⇒ 本机测不了。
  ///    下沉成纯枚举后，`dart run` 就能把每种组合都断言一遍。
  ///    📌 判据：**把能验证的尽量下沉**。
  ///
  /// ⚠️ 它**不 import `ThemeMode`**（那是 Flutter 类型）—— 调用方做一次映射即可，
  ///    而映射是 `switch` 穷尽的，漏一个分支编译不过。
  ThemeIntent get intent => followSystem
      ? ThemeIntent.followSystem
      : (theme == ReadingTheme.night ? ThemeIntent.dark : ThemeIntent.light);

  ThemeSettings copyWith({ReadingTheme? theme, bool? followSystem}) =>
      ThemeSettings(
        theme: theme ?? this.theme,
        followSystem: followSystem ?? this.followSystem,
      );

  /// 用户**手动选档**后的新状态 —— **「跟随系统」自动关闭**。
  ///
  /// # 🔴 2026-10-13（白哥真机实测）：为什么必须关
  ///
  /// 原实现 `setTheme()` 只改档位、**不动开关**；而生效判据是
  /// （`app.dart`）：
  ///
  /// ```dart
  /// themeMode: settings.followSystem
  ///     ? ThemeMode.system                                   // ← 开关开着就走这条
  ///     : (theme == night ? ThemeMode.dark : ThemeMode.light)
  /// ```
  ///
  /// ⇒ 开着「跟随系统」时用户去点「夜」，`themeMode` 仍是 `system`
  /// ⇒ **档位被静默绕过**（且浅色环境下 [lightTheme] 还会把「夜」回落成「墨」）。
  /// 用户看到的现象正是：**点了「夜」，主题色不变** ——
  /// 而字号等其它设置照常生效（它们不走这条判据），于是更显得诡异。
  ///
  /// 🔑 语义依据：**手动选档 = 一次明确的覆盖意图** ⇒ 它与「跟随系统」互斥，
  ///    必须顺手把开关关掉。否则就是本项目最忌的「**操作了但没反应**」——
  ///    用户以为坏了，而代码没有任何东西报错。
  ///    ⏳ 想恢复自动：再手动打开「跟随系统」即可（`setFollowSystem(true)`）。
  ///
  /// ⚠️ 注意**即使点的就是当前档位**也要关（见 [ThemeNotifier.setTheme] 的早退条件）——
  ///    用户点「墨」这个动作本身就表达了「我要墨，别替我做主」。
  ThemeSettings manualTheme(ReadingTheme theme) =>
      ThemeSettings(theme: theme, followSystem: false);
}
