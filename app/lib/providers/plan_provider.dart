import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import '../api/chat_client.dart';

/// 计划刷新信号 — 制卡/复习/计划更新后递增，触发各页面重新加载
final planRefreshProvider = StateProvider<int>((ref) => 0);

/// 卡片刷新信号（兼容旧引用）
final cardRefreshProvider = StateProvider<int>((ref) => 0);

/// 单个 Plan 数据模型
class PlanData {
  final String id;
  final String? conversationId;
  final String goal;
  final String? subject;
  final String? gradeBand;
  final List<Map<String, dynamic>>? stages;
  final int totalCards;
  final int dueCards;

  PlanData({
    required this.id,
    this.conversationId,
    required this.goal,
    this.subject,
    this.gradeBand,
    this.stages,
    this.totalCards = 0,
    this.dueCards = 0,
  });

  factory PlanData.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>>? stages;
    // 后端返回 plan 字段（内含 stages）
    final rawPlan = json['plan'];
    if (rawPlan is Map<String, dynamic>) {
      final s = rawPlan['stages'];
      if (s is List) stages = s.cast<Map<String, dynamic>>();
    } else if (rawPlan is String && rawPlan.isNotEmpty) {
      try {
        final parsed = jsonDecode(rawPlan);
        final s = (parsed is Map<String, dynamic>) ? parsed['stages'] : null;
        if (s is List) stages = s.cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    return PlanData(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString(),
      goal: json['goal']?.toString() ?? '',
      subject: json['subject']?.toString(),
      gradeBand: json['grade_band']?.toString(),
      stages: stages,
      totalCards: (json['card_count'] as num?)?.toInt() ?? (json['due_card_count'] as num?)?.toInt() ?? 0,
      dueCards: (json['due_card_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Plan 状态
class PlanState {
  final List<PlanData> plans;
  final bool isLoading;
  final String? selectedConversationId;

  const PlanState({
    this.plans = const [],
    this.isLoading = false,
    this.selectedConversationId,
  });

  PlanState copyWith({
    List<PlanData>? plans,
    bool? isLoading,
    String? selectedConversationId,
    bool clearSelected = false,
  }) {
    return PlanState(
      plans: plans ?? this.plans,
      isLoading: isLoading ?? this.isLoading,
      selectedConversationId: clearSelected ? null : (selectedConversationId ?? this.selectedConversationId),
    );
  }

  PlanData? getPlanForConversation(String conversationId) {
    for (final p in plans) {
      if (p.conversationId == conversationId) return p;
    }
    return null;
  }
}

/// Plan Notifier — 接受 ChatClient 实例，管理 Plan 加载和选中状态
class PlanNotifier extends StateNotifier<PlanState> {
  PlanNotifier() : super(const PlanState());

  /// 从 API 加载 plans
  Future<void> loadPlans(ChatClient client, {String? conversationId}) async {
    state = state.copyWith(isLoading: true);
    try {
      final raw = await client.getPlans(conversationId: conversationId);
      final list = (raw as List<dynamic>?)
              ?.where((p) => p is Map<String, dynamic>)
              .map((p) => PlanData.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [];
      state = state.copyWith(plans: list, isLoading: false);
    } catch (e) {
      debugPrint('PlanNotifier.loadPlans error: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void selectConversation(String? id) {
    state = state.copyWith(selectedConversationId: id);
  }

  void clear() {
    state = const PlanState();
  }
}

final planProvider = StateNotifierProvider<PlanNotifier, PlanState>((ref) {
  return PlanNotifier();
});
