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
  int _requestGen = 0;

  @override
  set state(PlanState value) {
    try {
      super.state = value;
    } catch (_) {
      // Consumer widget 已 defunct，忽略
    }
  }

  /// 从 API 加载 plans
  Future<void> loadPlans(ChatClient client, {String? conversationId}) async {
    final gen = ++_requestGen;
    state = state.copyWith(isLoading: true);
    debugPrint('[loadPlans] start gen=$gen conv=$conversationId');
    try {
      final raw = await client.getPlans(conversationId: conversationId);
      debugPrint('[loadPlans] got response gen=$gen raw=${raw?.length}');
      if (gen != _requestGen) {
        debugPrint('[loadPlans] stale gen=$gen != $_requestGen, discard');
        return;
      }
      final list = (raw as List<dynamic>?)
              ?.where((p) => p is Map<String, dynamic>)
              .map((p) => PlanData.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [];
      state = state.copyWith(plans: list, isLoading: false);
      debugPrint('[loadPlans] done gen=$gen plans=${list.length}');
    } catch (e) {
      debugPrint('[loadPlans] error gen=$gen: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  void selectConversation(String? id) {
    state = state.copyWith(selectedConversationId: id);
  }

  /// 更新 plans 列表（用于前端过滤）
  void updatePlans(List<PlanData> newPlans) {
    state = state.copyWith(plans: newPlans);
  }

  void clear() {
    state = const PlanState();
  }
}

final planProvider = StateNotifierProvider<PlanNotifier, PlanState>((ref) {
  return PlanNotifier();
});
