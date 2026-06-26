import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../api/api_config.dart';
import 'auth_provider.dart';

/// 订阅状态枚举
enum SubscriptionStatus {
  unknown,    // 尚未检查
  active,     // 有效
  expired,    // 已到期（有过期时间）
  required,   // 未激活（无过期时间）
}

/// 订阅状态数据类
class SubscriptionState {
  final SubscriptionStatus status;
  final String? expiresAt;     // ISO 8601 或 null
  final bool isLoading;
  final String? error;

  const SubscriptionState({
    this.status = SubscriptionStatus.unknown,
    this.expiresAt,
    this.isLoading = false,
    this.error,
  });

  bool get isExpired => status == SubscriptionStatus.expired;
  bool get isRequired => status == SubscriptionStatus.required;
  bool get isActive => status == SubscriptionStatus.active;
  bool get isChecked => status != SubscriptionStatus.unknown;

  SubscriptionState copyWith({
    SubscriptionStatus? status,
    String? expiresAt,
    bool? isLoading,
    String? error,
  }) {
    return SubscriptionState(
      status: status ?? this.status,
      expiresAt: expiresAt ?? this.expiresAt,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// 订阅状态管理 — 单一数据源，所有页面共用
class SubscriptionNotifier extends StateNotifier<SubscriptionState> {
  SubscriptionNotifier() : super(const SubscriptionState());

  /// 从后端 API 获取订阅状态
  Future<void> fetch({required String userId, required String? token}) async {
    if (userId.isEmpty) return;
    state = state.copyWith(isLoading: true);

    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final resp = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/user/$userId/subscription'),
        headers: headers,
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final expired = data['expired'] as bool? ?? false;
        final expiresAt = data['expires_at'] as String?;

        state = SubscriptionState(
          status: expired
              ? SubscriptionStatus.expired
              : SubscriptionStatus.active,
          expiresAt: expiresAt,
          isLoading: false,
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'HTTP ${resp.statusCode}',
        );
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// 从 WS 事件设置订阅状态
  void setExpired({String? expiresAt}) {
    state = SubscriptionState(
      status: SubscriptionStatus.expired,
      expiresAt: expiresAt,
    );
  }

  void setRequired() {
    state = const SubscriptionState(
      status: SubscriptionStatus.required,
    );
  }

  void setActive({String? expiresAt}) {
    state = SubscriptionState(
      status: SubscriptionStatus.active,
      expiresAt: expiresAt,
    );
  }

  void setError(String error) {
    state = state.copyWith(error: error);
  }
}

final subscriptionProvider =
    StateNotifierProvider<SubscriptionNotifier, SubscriptionState>((ref) {
  return SubscriptionNotifier();
});

/// 便捷方法：自动从 authProvider 获取 userId/token 并 fetch
extension SubscriptionFetch on WidgetRef {
  Future<void> fetchSubscription() {
    final auth = read(authProvider);
    final userId = auth.userId ?? '';
    final token = auth.token;
    return read(subscriptionProvider.notifier).fetch(
      userId: userId,
      token: token,
    );
  }
}
