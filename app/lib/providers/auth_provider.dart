import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_config.dart';
import '../api/auth_client.dart';

const _tokenKey = 'coevo_auth_token';
const _userIdKey = 'coevo_auth_user_id';
const _usernameKey = 'coevo_auth_username';

/// 「本设备已用过试用」标记的 prefs key。
///
/// 原实现用 `dart:html` 的 `window.localStorage`（仅 Web 可用）→ 原生编不过；
/// 改为 `shared_preferences`（Web 上底层同样是 localStorage，行为等价）。
const _kTrialUsedKey = 'coevo_trial_used';

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
  /// 清除「已用过试用」标记（原为 localStorage，现为 shared_preferences）。
  void _clearTrialStorageFlags() {
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.remove(_kTrialUsedKey);
    }).catchError((Object e) {
      debugPrint('_clearTrialStorageFlags failed: $e');
    });
  }

  /// 将原始异常文本转为用户能读懂的话。
  ///
  /// 🔴 它是**错误文案的唯一出口** —— 映射不到就**原样透传**，
  /// 于是用户看到的是 `TimeoutException after 0:00:10.000000: Future not completed`、
  /// `SocketConnection refused (OS Error: errno = 111)` 这类机器话。
  /// 而「超时」和「连不上」恰恰是网络故障里**最常发生的两种** ——
  /// 最该给人话的两处，之前恰好都没映射。
  ///
  /// ⚠️ 入参传 `e.toString()` **原文**，不要在外面预先剥前缀（原因见下）。
  static String _friendlyError(String raw) {
    // 🔴 只剥「**恰好**以 `Exception: ` 开头」的前缀 —— **不能用 `replaceFirst`**：
    //    `SocketException: Connection refused` 中间也含 `Exception: `，
    //    replaceFirst 会把它啃成 `SocketConnection refused`（前缀被损坏），
    //    且下面所有 `contains('SocketException')` 判断**将永远匹配不到**。
    //    —— 这不是假想：2026-09-27 改这里时实测复现过。
    final msg = raw.startsWith('Exception: ')
        ? raw.substring('Exception: '.length)
        : raw;

    if (msg == 'rate_limited' || msg.contains('Rate limit')) {
      return '操作太频繁，请稍后再试';
    }
    // 「连上了但没人应」—— 2026-09-27 给 auth 全部请求补 `.timeout()` 后才可能出现
    if (msg.contains('TimeoutException')) {
      return '网络超时，请检查网络后重试';
    }
    // 「连不上」—— 端口无监听 / DNS 失败 / 无网络
    if (msg.contains('SocketException') ||
        msg.contains('Connection refused') ||
        msg.contains('Failed host lookup')) {
      return '连不上服务器，请检查网络后重试';
    }
    return msg;
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
      // 错误会显示在 UI，但日志仍要打（含端点）——排查时不必让用户复述弹窗文字
      debugPrint('register 失败 endpoint=${ApiConfig.baseUrl} '
          'username=$username error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
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
      debugPrint('login 失败 endpoint=${ApiConfig.baseUrl} '
          'username=$username error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
      );
      rethrow;
    }
  }

  Future<void> logout() async {
    await _clearCredentials();
    // 清除 SharedPreferences 缓存（display_name 等）
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('display_name');
    } catch (e) {
      // 清缓存失败不影响登出结果（凭证已清）→ 不向用户报错，但留一行日志
      debugPrint('logout: 清除本地缓存失败: $e');
    }
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
      // 🔑 日志**必须带端点** —— 「连错地址」是本项目踩过的真坑：
      //    `flutter run` 默认 `localhost:8080`，而后端在 VPS，
      //    失败信息里若没有端点，就要靠猜。
      debugPrint('trialStart 失败 endpoint=${ApiConfig.baseUrl} '
          'refCode=$refCode campaignId=$campaignId error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
      );
    }
  }

  /// 标记「本设备已使用过试用」，防止退出后无限创建新试用。
  ///
  /// 原实现写 `html.window.localStorage`（web-only）→ 改为 `shared_preferences`。
  void _setTrialUsedFlag() {
    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setBool(_kTrialUsedKey, true);
    }).catchError((Object e) {
      debugPrint('_setTrialUsedFlag failed: $e');
    });
  }

  /// 检查本设备是否已创建过试用账户。
  ///
  /// ⚠️ 原实现是**同步**读 `localStorage`；改用 `shared_preferences` 后必须 `await`。
  static Future<bool> hasUsedTrial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kTrialUsedKey) ?? false;
    } catch (e) {
      debugPrint('hasUsedTrial failed: $e');
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
      debugPrint('trialClaim 失败 endpoint=${ApiConfig.baseUrl} '
          'userId=${state.userId} username=$username error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
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
