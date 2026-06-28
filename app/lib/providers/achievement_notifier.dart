// 成就通知队列管理
//
// 维护一个 FIFO 队列，全局 Overlay 监听并逐个展示成就特效卡。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 成就通知数据
class AchievementNotification {
  final String key;
  final String name;
  final String? description;
  final String? icon;        // Material icon name，兜底用 achievementIcon(icon)
  final String? color;      // hex 字符串，如 "#FFC107"
  final String tier;        // bronze / silver / gold / platinum / diamond
  final String category;    // seed / consistency / knowledge / mastery / exploration / special
  final String? unlockedAt;

  AchievementNotification({
    required this.key,
    required this.name,
    this.description,
    this.icon,
    this.color,
    this.tier = 'bronze',
    this.category = 'seed',
    this.unlockedAt,
  });

  /// 从 API JSON 构造
  factory AchievementNotification.fromJson(Map<String, dynamic> json) =>
      AchievementNotification(
        key: json['key'] as String? ?? json['achievement_key'] as String? ?? '',
        name: json['name'] as String? ?? '成就',
        description: json['description'] as String?,
        icon: json['icon'] as String?,
        color: json['color'] as String?,
        tier: (json['tier'] as String?) ?? 'bronze',
        category: (json['category'] as String?) ?? 'seed',
        unlockedAt: json['unlocked_at'] as String?,
      );
}

/// 成就通知状态
class AchievementNotifier extends StateNotifier<List<AchievementNotification>> {
  AchievementNotifier() : super([]);

  /// 推送成就到展示队列（支持同时解锁多个成就）
  void push(AchievementNotification achievement) {
    state = [...state, achievement];
  }

  /// 推送多个成就
  void pushAll(List<AchievementNotification> achievements) {
    state = [...state, ...achievements];
  }

  /// 移除队列头部（当前展示的成就已 dismissed）
  void dismiss() {
    if (state.isNotEmpty) {
      state = state.sublist(1);
    }
  }

  /// 当前是否有待展示的成就
  bool get hasNext => state.isNotEmpty;

  /// 队列头部（当前展示的），无则返回 null
  AchievementNotification? get current => state.isNotEmpty ? state.first : null;
}

/// Riverpod provider
final achievementNotifierProvider =
    StateNotifierProvider<AchievementNotifier, List<AchievementNotification>>(
  (ref) => AchievementNotifier(),
);
