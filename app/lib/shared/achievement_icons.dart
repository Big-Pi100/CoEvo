// CoEvo · 成就的**图标与配色映射**（Flutter 侧唯一映射点）
//
// # 🔴 为什么单独一个文件
// `achievement_rules.dart` 是**纯 Dart**（零 Flutter 依赖，可在 `query_verify` 里跑断言），
// 所以它只能存**图标名字符串**，不能存 `IconData`。
// → 本文件是那层「字符串名 → `IconData`」的**唯一映射点**。
//
// # 🔑 覆盖性由断言守护（不是靠人记得）
// 映射键**必须覆盖** `AchievementIcons.all`（rules 侧声明）。
// · 漏一个 → 该成就**静默显示默认图标**（`Icons.emoji_events`），不报错、不崩 → 最难发现
// · 守护：`scripts/query_verify/bin/verify_achievement_rules.dart`【6】 断言
//   「每个成就的 icon 都在 `AchievementIcons.all` 里」，
//   而本文件用 `iconsCoverAll()` 在 debug 下自检**反向**（映射表是否覆盖了 all）。
//   ⚠️ 本文件 import Flutter → **不能**进 `query_verify`（那套是纯 Dart），
//      所以这一侧的断言只能放这里 + 由 `static_check` 保证编译。

import 'package:flutter/material.dart';

import '../services/achievement_rules.dart';

/// 图标名 → `IconData`。
///
/// ⚠️ 键必须与 `AchievementIcons` 的常量**逐字一致**（含拼写）。
final Map<String, IconData> _icons = {
  // 坚持
  AchievementIcons.whatshot: Icons.whatshot,
  AchievementIcons.fireDepartment: Icons.local_fire_department,
  AchievementIcons.selfImprovement: Icons.self_improvement,
  AchievementIcons.trendingUp: Icons.trending_up,
  // 阅读
  AchievementIcons.search: Icons.search,
  AchievementIcons.autoStories: Icons.auto_stories,
  AchievementIcons.libraryBooks: Icons.library_books,
  AchievementIcons.bolt: Icons.bolt,
  // 生词
  AchievementIcons.bookmarkAdd: Icons.bookmark_add,
  AchievementIcons.collectionsBookmark: Icons.collections_bookmark,
  AchievementIcons.accountBalance: Icons.account_balance,
  // 复习
  AchievementIcons.checkCircle: Icons.check_circle,
  AchievementIcons.replay: Icons.replay,
  AchievementIcons.allInclusive: Icons.all_inclusive,
  AchievementIcons.nature: Icons.nature,
  AchievementIcons.school: Icons.school,
  AchievementIcons.verified: Icons.verified,
  // 特殊
  AchievementIcons.nightlight: Icons.nightlight,
  AchievementIcons.wbSunny: Icons.wb_sunny,
  AchievementIcons.restartAlt: Icons.restart_alt,
  // 分类
  AchievementIcons.menuBook: Icons.menu_book,
  AchievementIcons.taskAlt: Icons.task_alt,
  AchievementIcons.autoAwesome: Icons.auto_awesome,
};

/// 取图标（未知名字回落到奖杯 —— **不应发生**，见文件头说明）。
IconData achievementIcon(String name) =>
    _icons[name] ?? Icons.emoji_events;

/// 映射表是否已覆盖 `AchievementIcons.all`（debug 自检用）。
///
/// 建议在 app 启动的 debug 分支里断一次：
/// `assert(iconsCoverAll(), '成就图标映射表未覆盖全部图标名');`
bool iconsCoverAll() =>
    AchievementIcons.all.every(_icons.containsKey);

/// 图标映射条数（供断言/调试显示）。
int get achievementIconCount => _icons.length;

// ══════════════════════════════════════════════════════════════
// 档位配色
// ══════════════════════════════════════════════════════════════

/// 五档色（**徽章底色的实色**，图标画在上面用白色）。
///
/// # 🔴 为什么不直接用「游戏化惯例」的原色
/// 惯例色（白银 `#C0C0C0`、铂金 `#E5E4E2`、钻石 `#B9F2FF`）都**极浅** ——
/// 在**墨档**（浅底 `#FFFFFF`）上几乎看不见，而徽章底还要承载白色图标
/// （白图标画在白底上 = 完全不可见）。
/// → 统一**加深到中饱和度**：保证「白图标 + 彩色底」在三档主题下都清晰。
/// 🔑 这是「**能靠形状/明度区分就别靠细微色差**」的落地。
const Map<AchievementTier, Color> _tierColors = {
  AchievementTier.bronze: Color(0xFFC8802E), // 青铜（橙褐）
  AchievementTier.silver: Color(0xFF8E9AA6), // 白银（冷灰）
  AchievementTier.gold: Color(0xFFD9A400), // 黄金
  AchievementTier.platinum: Color(0xFF6E7B8B), // 铂金（深冷灰）
  AchievementTier.diamond: Color(0xFF3B9EDB), // 钻石（亮蓝）
};

/// 档位主色（徽章底色）。
Color tierColor(AchievementTier tier) =>
    _tierColors[tier] ?? const Color(0xFF8E9AA6);

/// 档位名（中文）。
const Map<AchievementTier, String> _tierLabels = {
  AchievementTier.bronze: '青铜',
  AchievementTier.silver: '白银',
  AchievementTier.gold: '黄金',
  AchievementTier.platinum: '铂金',
  AchievementTier.diamond: '钻石',
};

String tierLabel(AchievementTier tier) => _tierLabels[tier] ?? '';

/// 未解锁徽章的底色（**中性灰** —— 不与任何档位色混淆）。
const Color kLockedBadgeColor = Color(0xFFB8BFC7);

/// 分类图标。
IconData categoryIcon(AchievementCategory category) {
  switch (category) {
    case AchievementCategory.streak:
      return Icons.local_fire_department;
    case AchievementCategory.reading:
      return Icons.menu_book;
    case AchievementCategory.words:
      return Icons.collections_bookmark;
    case AchievementCategory.review:
      return Icons.task_alt;
    case AchievementCategory.special:
      return Icons.auto_awesome;
  }
}

/// 分类中文名（取自 `kCategoryMeta`，避免两处定义）。
String categoryLabel(AchievementCategory category) {
  for (final m in kCategoryMeta) {
    if (m.category == category) return m.label;
  }
  return '';
}
