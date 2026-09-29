// CoEvo · 成就徽章（圆形底 + 档位色 + 图标）
//
// 从 `achievement_section.dart` 拆出（2026-09-29）——
// 那个文件原本同时承载「我的」页顶部统计区与徽章组件，
// 而按白哥 2026-09-29 决策，顶部统计区**不再展示成就列表**（含徽章行）
// → 徽章行从「我的」页移除，但**徽章本身**是「成就墙」页（`achievements_screen`）
//   的核心元素，必须独立存活。
// 🔑 判据：**组件被谁用，决定它住在哪** —— 唯一消费者在成就页，
//    就不该把它留在一个「统计卡」文件里。

import 'package:flutter/material.dart';

import '../services/achievement_rules.dart';
import '../shared/achievement_icons.dart';

/// 单个成就徽章（圆形底 + 图标）。
///
/// 🔑 已解锁 = **档位实色底 + 白图标**；未解锁 = **中性灰底 + 半透明图标**。
/// 用「**颜色 + 明度**」两种手段同时区分（不靠单一细微色差）——
/// 依据：判据「能靠形状/明度区分就别靠参数」。
class AchievementBadge extends StatelessWidget {
  final AchievementDef def;
  final bool unlocked;
  final double size;

  const AchievementBadge({
    super.key,
    required this.def,
    required this.unlocked,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final bg = unlocked ? tierColor(def.tier) : kLockedBadgeColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg.withValues(alpha: unlocked ? 1.0 : 0.35),
        shape: BoxShape.circle,
      ),
      child: Icon(
        achievementIcon(def.icon),
        size: size * 0.52,
        color: Colors.white.withValues(alpha: unlocked ? 1.0 : 0.55),
      ),
    );
  }
}
