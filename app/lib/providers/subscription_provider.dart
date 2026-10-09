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
  http.Client? _client;

  @override
  void dispose() {
    _client?.close(); // 取消进行中的 HTTP 请求
    _client = null;
    super.dispose();
  }

  /// 从后端 API 获取订阅状态
  Future<void> fetch({required String userId, required String? token}) async {
    if (userId.isEmpty) return;
    state = state.copyWith(isLoading: true);
    _client?.close();
    final c = http.Client();
    _client = c;

    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final resp = await c.get(
        Uri.parse('${ApiConfig.baseUrl}/api/user/$userId/subscription'),
        headers: headers,
      );

      if (_client != c) return; // 已被取消或新的请求已发起

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
      if (_client == c) {
        state = state.copyWith(
          isLoading: false,
          error: e.toString(),
        );
      }
    } finally {
      if (_client == c) _client = null;
    }
  }

  /// 从 WS 事件设置订阅状态
  void setExpired({String? expiresAt}) {
    state = SubscriptionState(
      status: SubscriptionStatus.expired,
      expiresAt: expiresAt,
    );
  }

  /// 🆕 2026-10-09：**复位到「未检查」** —— 登出时**必须**调。
  ///
  /// # 🔴 为什么必须（这是「账号级状态」的固有义务）
  ///
  /// 本 provider 持有的是**账号级**状态（读服务端 `users.subscription_expires`）。
  /// 登出后若不复位，下一个账号（或未登录态）会**看到上一个账号的订阅状态** ——
  /// 白哥 2026-10-09 真机实测到的正是这个：
  /// **退出登录后订阅状态不变，仍显示「订阅版」**。
  ///
  /// 📌 判据（项目已记）：**「登录态」是一组状态的「所有者」——
  ///    退出必须「整体复位」，否则跨账号泄漏。**
  /// ⚠️ 而这条泄漏是 2026-10-09 引入的：当天把本 provider 加进订阅 UI 的判据
  ///    （`subscriptionActiveNow` = 端侧 OR 服务端）⇒ **给判据加了一个来源，
  ///    却没有接管它的生命周期** ⇒ 新来源带着上一个账号的值跨了过来。
  ///    🔑 **「加一个数据来源」与「接管它的生命周期」是同一件事的两半。**
  ///
  /// # ⚠️ 与端侧 IAP 的区别（**不要**顺手把那个也"复位"）
  ///
  /// 端侧 `iapSnapshotProvider` 是 **Apple ID 级**（StoreKit `currentEntitlements`
  /// 跟 Apple ID 走，**不跟 App 账号走**）——
  /// 同一台设备上换个 App 账号，订阅权益**本来就还在**（用户确实付过钱）
  /// ⇒ 登出**不该**、也动不了它。两个来源的**所有者不同**，生命周期也就不同。
  void reset() {
    // 关掉进行中的请求（否则它回来时会把 state 又写成上一个账号的值）
    _client?.close();
    _client = null;
    state = const SubscriptionState();
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
