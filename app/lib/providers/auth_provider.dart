import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/auth_client.dart';

const _tokenKey = 'coevo_auth_token';
const _userIdKey = 'coevo_auth_user_id';
const _usernameKey = 'coevo_auth_username';

/// 卡片刷新信号 — 制卡成功后递增
final cardRefreshProvider = StateProvider<int>((ref) => 0);

class AuthState {
  final bool isAuthenticated;
  final String? userId;
  final String? token;
  final String? username;
  final String? error;
  final bool isLoading;
  final bool isRestored; // true after tryRestore() completes

  const AuthState({
    this.isAuthenticated = false,
    this.userId,
    this.token,
    this.username,
    this.error,
    this.isLoading = false,
    this.isRestored = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? userId,
    String? token,
    String? username,
    String? error,
    bool? isLoading,
    bool? isRestored,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      userId: userId ?? this.userId,
      token: token ?? this.token,
      username: username ?? this.username,
      error: error,
      isLoading: isLoading ?? this.isLoading,
      isRestored: isRestored ?? this.isRestored,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthClient _client;
  final FlutterSecureStorage _storage;

  AuthNotifier(this._client)
      : _storage = const FlutterSecureStorage(),
        super(const AuthState());

  Future<void> tryRestore() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      final userId = await _storage.read(key: _userIdKey);
      final username = await _storage.read(key: _usernameKey);
      if (token != null && userId != null) {
        // Verify token with backend to ensure it's still valid
        final valid = await _client.verifyToken(userId, token);
        if (valid) {
          state = AuthState(
            isAuthenticated: true,
            userId: userId,
            token: token,
            username: username,
            isRestored: true,
          );
          return;
        }
        // Token invalid on server — clear local storage
        debugPrint('tryRestore: token invalid on server, clearing credentials');
        await _clearCredentials();
      }
    } catch (e) {
      debugPrint('tryRestore: failed to read secure storage: $e');
    }
    // Mark restore as complete even on failure
    state = state.copyWith(isRestored: true);
  }

  Future<void> _saveCredentials(String userId, String token, String? username) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _userIdKey, value: userId);
      if (username != null) {
        await _storage.write(key: _usernameKey, value: username);
      }
    } catch (e) {
      debugPrint('_saveCredentials: failed to write secure storage: $e');
    }
  }

  Future<void> _clearCredentials() async {
    try {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _userIdKey);
      await _storage.delete(key: _usernameKey);
    } catch (e) {
      debugPrint('_clearCredentials: failed to clear secure storage: $e');
    }
  }

  /// 将原始错误消息转为用户友好的中文
  static String _friendlyError(String raw) {
    if (raw == 'rate_limited') return '操作太频繁，请稍后再试';
    if (raw.contains('Rate limit')) return '操作太频繁，请稍后再试';
    return raw;
  }

  Future<void> register(String username, String password, {String? realName, String? phone, String? referralCode}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.register(username, password, realName: realName, phone: phone, referralCode: referralCode);
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, username);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        username: username,
        isRestored: true,
      );
      // 清除退出登录标记
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString().replaceFirst('Exception: ', '')),
      );
    }
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.login(username, password);
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, username);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        username: username,
        isRestored: true,
      );
      // 登录成功后清除退出登录标记
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString().replaceFirst('Exception: ', '')),
      );
      rethrow;
    }
  }

  Future<void> logout() async {
    await _clearCredentials();
    state = const AuthState(isRestored: true);
  }

  /// 创建临时账户
  Future<void> trialStart() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.trialStart();
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      final trialUsername = result['username'] as String?;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, trialUsername ?? uid);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        username: trialUsername ?? uid,
        isRestored: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString().replaceFirst('Exception: ', '')),
      );
    }
  }

  /// 认领临时账户（注册）
  Future<void> trialClaim(String username, String password, {String? realName, String? phone, String? referralCode}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.trialClaim(
        state.userId!,
        state.token!,
        username,
        password,
        realName: realName,
        phone: phone,
        referralCode: referralCode,
      );
      final newToken = result['token'] as String? ?? state.token;
      await _saveCredentials(state.userId!, newToken!, username);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('coevo_trial_claimed', true);
      await prefs.remove('coevo_show_login');
      state = AuthState(
        isAuthenticated: true,
        userId: state.userId,
        token: newToken,
        username: username,
        isRestored: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString().replaceFirst('Exception: ', '')),
      );
    }
  }
}

/// 检查用户 ID 是否为临时账户
bool isTrialAccount(String? userId) {
  return userId != null && userId.startsWith('trial_');
}

/// 检查是否已完成认领注册
Future<bool> isClaimed() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('coevo_trial_claimed') ?? false;
}

final authClientProvider = Provider<AuthClient>((ref) => AuthClient());
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(authClientProvider));
});
