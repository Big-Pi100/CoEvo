import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/auth_client.dart';

const _tokenKey = 'coevo_auth_token';
const _userIdKey = 'coevo_auth_user_id';
const _usernameKey = 'coevo_auth_username';

class AuthState {
  final bool isAuthenticated;
  final String? userId;
  final String? token;
  final String? username;
  final String? error;
  final bool isLoading;

  const AuthState({
    this.isAuthenticated = false,
    this.userId,
    this.token,
    this.username,
    this.error,
    this.isLoading = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? userId,
    String? token,
    String? username,
    String? error,
    bool? isLoading,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      userId: userId ?? this.userId,
      token: token ?? this.token,
      username: username ?? this.username,
      error: error,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthClient _client;

  AuthNotifier(this._client) : super(const AuthState());

  Future<void> tryRestore() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final userId = prefs.getString(_userIdKey);
    final username = prefs.getString(_usernameKey);
    if (token != null && userId != null) {
      state = AuthState(
        isAuthenticated: true,
        userId: userId,
        token: token,
        username: username,
      );
    }
  }

  Future<void> _saveCredentials(String userId, String token, String? username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_userIdKey, userId);
    if (username != null) await prefs.setString(_usernameKey, username);
  }

  Future<void> _clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(_usernameKey);
  }

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.register(username, password);
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
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
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
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  Future<void> logout() async {
    await _clearCredentials();
    state = const AuthState();
  }
}

final authClientProvider = Provider<AuthClient>((ref) => AuthClient());
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(authClientProvider));
});
