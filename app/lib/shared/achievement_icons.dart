// 成就图标和颜色的函数式映射
//
// 使用函数而非 const Map，避免跨文件 const 解析异常导致的运行时白屏问题。
// 当 API 返回 icon/color 字段时优先使用 API 数据，以下映射作为兜底。

import 'package:flutter/material.dart';

/// 成就图标映射（兜底用，优先使用 API 返回的 icon 字段）
IconData achievementIcon(String key) {
  final map = <String, IconData>{
    // 🌱 启程
    'first_card': Icons.auto_stories,
    'first_review': Icons.check_circle,
    'first_conversation': Icons.chat_bubble,
    'first_plan': Icons.task_alt,
    'first_hard_card': Icons.keyboard_double_arrow_up,
    'ten_conversations': Icons.forum,
    // 🔥 坚持
    'streak_3': Icons.whatshot,
    'streak_7': Icons.local_fire_department,
    'streak_30': Icons.self_improvement,
    'streak_100': Icons.trending_up,
    'streak_365': Icons.emoji_events,
    'weekend_warrior': Icons.weekend,
    'night_owl': Icons.nightlight,
    'early_bird': Icons.wb_sunny,
    // 📚 博学
    'cards_10': Icons.collections_bookmark,
    'cards_50': Icons.library_books,
    'cards_200': Icons.account_balance,
    'cards_500': Icons.school,
    'cards_2000': Icons.castle,
    'reviews_100': Icons.refresh,
    'reviews_1000': Icons.history,
    'reviews_10000': Icons.all_inclusive,
    // 🎯 精进
    'accuracy_80': Icons.track_changes,
    'accuracy_90': Icons.verified,
    'accuracy_95': Icons.fact_check,
    'hard_master': Icons.gavel,
    'perfect_session': Icons.star,
    'fsrs_mature': Icons.nature,
    'fsrs_learning': Icons.science,
    'no_skip_7': Icons.block,
    // 🗺️ 探索
    'domains_2': Icons.explore,
    'domains_5': Icons.travel_explore,
    'domains_10': Icons.public,
    'subjects_3': Icons.menu_book,
    'languages_2': Icons.translate,
    'all_subjects': Icons.bolt,
    // ⭐ 特殊
    'secret_speed': Icons.flash_on,
    'secret_comeback': Icons.restart_alt,
    'secret_daily': Icons.dark_mode,
    'secret_early': Icons.child_care,
  };
  return map[key] ?? Icons.emoji_events;
}

/// 成就颜色映射（兜底用，优先使用 API 返回的 color 字段）
Color achievementColor(String key) {
  final map = <String, Color>{
    // Bronze 青铜
    'first_card': const Color(0xFFCD7F32),
    'first_review': const Color(0xFFCD7F32),
    'first_conversation': const Color(0xFFCD7F32),
    'streak_3': const Color(0xFFCD7F32),
    'cards_10': const Color(0xFFCD7F32),
    'reviews_100': const Color(0xFFCD7F32),
    'domains_2': const Color(0xFFCD7F32),
    // Silver 白银
    'first_plan': const Color(0xFFC0C0C0),
    'first_hard_card': const Color(0xFFC0C0C0),
    'streak_7': const Color(0xFFC0C0C0),
    'cards_50': const Color(0xFFC0C0C0),
    'domains_5': const Color(0xFFC0C0C0),
    'subjects_3': const Color(0xFFC0C0C0),
    'night_owl': const Color(0xFFC0C0C0),
    'early_bird': const Color(0xFFC0C0C0),
    'perfect_session': const Color(0xFFC0C0C0),
    'fsrs_learning': const Color(0xFFC0C0C0),
    // Gold 黄金
    'streak_30': const Color(0xFFFFD700),
    'cards_200': const Color(0xFFFFD700),
    'reviews_1000': const Color(0xFFFFD700),
    'accuracy_90': const Color(0xFFFFD700),
    'hard_master': const Color(0xFFFFD700),
    'domains_10': const Color(0xFFFFD700),
    'languages_2': const Color(0xFFFFD700),
    'no_skip_7': const Color(0xFFFFD700),
    'secret_comeback': const Color(0xFFFFD700),
    // Platinum 铂金
    'streak_100': const Color(0xFFE5E4E2),
    'cards_500': const Color(0xFFE5E4E2),
    'accuracy_95': const Color(0xFFE5E4E2),
    'fsrs_mature': const Color(0xFFE5E4E2),
    'secret_speed': const Color(0xFFE5E4E2),
    'secret_daily': const Color(0xFFE5E4E2),
    // Diamond 钻石
    'streak_365': const Color(0xFFB9F2FF),
    'cards_2000': const Color(0xFFB9F2FF),
    'reviews_10000': const Color(0xFFB9F2FF),
    'all_subjects': const Color(0xFFB9F2FF),
    'secret_early': const Color(0xFFB9F2FF),
  };
  return map[key] ?? const Color(0xFFCD7F32);
}

/// Tier 颜色（分级色环，用于成就页面彩色圆环）
Color tierColor(String tier) {
  final map = <String, Color>{
    'bronze': const Color(0xFFCD7F32),
    'silver': const Color(0xFFC0C0C0),
    'gold': const Color(0xFFFFD700),
    'platinum': const Color(0xFFE5E4E2),
    'diamond': const Color(0xFFB9F2FF),
  };
  return map[tier.toLowerCase()] ?? const Color(0xFF9E9E9E);
}

/// Tier 显示名
String tierLabel(String tier) {
  final map = <String, String>{
    'bronze': '青铜',
    'silver': '白银',
    'gold': '黄金',
    'platinum': '铂金',
    'diamond': '钻石',
  };
  return map[tier.toLowerCase()] ?? tier;
}

/// Category 图标
IconData categoryIcon(String category) {
  final map = <String, IconData>{
    'seed': Icons.spa,
    'consistency': Icons.local_fire_department,
    'knowledge': Icons.library_books,
    'mastery': Icons.verified,
    'exploration': Icons.explore,
    'special': Icons.star,
  };
  return map[category.toLowerCase()] ?? Icons.emoji_events;
}
