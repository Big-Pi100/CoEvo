import 'dart:html' as html;
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
  final String? realName;
  final String? error;
  final bool isLoading;
  final bool isRestored;

  const AuthState({
    this.isAuthenticated = false,
    this.userId,
    this.token,
    this.username,
    this.realName,
    this.error,
    this.isLoading = false,
    this.isRestored = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? userId,
    String? token,
    String? username,
    String? realName,
    String? error,
    bool? isLoading,
    bool? isRestored,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      userId: userId ?? this.userId,
      token: token ?? this.token,
      username: username ?? this.username,
      realName: realName ?? this.realName,
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
      debugPrint('tryRestore: 开始恢复认证...');
      final token = await _storage.read(key: _tokenKey);
      final userId = await _storage.read(key: _userIdKey);
      final username = await _storage.read(key: _usernameKey);
      debugPrint('tryRestore: token=$token userId=$userId');
      if (token != null && userId != null) {
        final result = await _client.verifyToken(userId, token);
        final isValid = result['valid'] == true;
        final realName = result['real_name'] as String?;
        debugPrint('tryRestore: verifyToken=$isValid realName=$realName');
        if (isValid) {
          state = AuthState(
            isAuthenticated: true,
            userId: userId,
            token: token,
            username: username,
            realName: realName,
            isRestored: true,
          );
          debugPrint('tryRestore: 认证恢复成功');
          return;
        }
        debugPrint('tryRestore: token invalid on server, clearing credentials');
        await _clearCredentials();
      } else {
        debugPrint('tryRestore: 本地无存储的认证信息, 清理试用标记');
        // 凭证不存在（或被清过），但也清理试用标记，防止 hasUsedTrial() 卡住流程
        _clearTrialStorageFlags();
      }
    } catch (e) {
      debugPrint('tryRestore: failed to read secure storage: $e');
    }
    state = state.copyWith(isRestored: true);
    debugPrint('tryRestore: 完成 (isRestored=true)');
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
      // 清除 localStorage 中的试用标记，下次可重新创建试用账户
      _clearTrialStorageFlags();
    } catch (e) {
      debugPrint('_clearCredentials: failed to clear secure storage: $e');
    }
  }

  /// 清除浏览器 localStorage 中的试用状态标记
  void _clearTrialStorageFlags() {
    try {
      final storage = html.window.localStorage;
      storage.remove('coevo_trial_used');
    } catch (_) {}
    // SharedPreferences 中的认领标记在应用重启后会被清除，无需手动处理
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
        realName: realName,
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
        realName: result['real_name'] as String?,
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

  /// 创建临时账户，可选推广码（来自 URL ?ref=）
  Future<void> trialStart({String? refCode, String? campaignId}) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.trialStart(referralCode: refCode, campaignId: campaignId);
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      final trialUsername = result['username'] as String?;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, trialUsername ?? uid);
        // 标记浏览器已使用过试用，防止退出后无限创建新试用
        _setTrialUsedFlag();
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

  /// 在浏览器 localStorage 设置"已使用试用"标记
  void _setTrialUsedFlag() {
    try {
      // dart:html 在 Flutter Web 中可用
      final storage = html.window.localStorage;
      storage['coevo_trial_used'] = '1';
    } catch (_) {}
  }

  /// 检查当前浏览器是否已创建过试用账户
  static bool hasUsedTrial() {
    try {
      final storage = html.window.localStorage;
      return storage['coevo_trial_used'] == '1';
    } catch (_) {
      return false;
    }
  }

  /// 认领临时账户（注册）
  Future<void> trialClaim(String username, String password, {String? realName, String? phone, String? referralCode, String? campaignId}) async {
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
        campaignId: campaignId,
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
        realName: realName,
        isRestored: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString().replaceFirst('Exception: ', '')),
      );
      rethrow;
    }
  }
}

/// 检查用户是否为临时试用账户（username 以 trial_ 开头）
/// userId 是 UUID 格式，不能用于判断
bool isTrialAccount(String? username) {
  return username != null && username.startsWith('trial_');
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
