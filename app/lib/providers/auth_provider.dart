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

  /// **内部标识**，不是用户输入的东西。
  ///
  /// ⚠️ 2026-09-29 起用户不再填用户名（注册标识改为 [email]）——
  ///    trial 匿名账号是 `trial_*`，`/api/auth/register` 生成的是 `u_*`。
  /// 🔴 **不要用它判断「是否已注册」**（旧代码靠 `trial_` 前缀猜，username 一改就失效）
  ///    → 用 [isRegistered]。
  final String? username;

  /// 注册邮箱；**匿名试用账号为 `null`**。
  ///
  /// 🔴 它取代了原来的 `realName`（实名是微信时代遗留，已随「改用邮箱注册」移除）。
  final String? email;

  final String? error;
  final bool isLoading;
  final bool isRestored;

  const AuthState({
    this.isAuthenticated = false,
    this.userId,
    this.token,
    this.username,
    this.email,
    this.error,
    this.isLoading = false,
    this.isRestored = false,
  });

  /// 是否**已完成注册**。
  ///
  /// 🔑 注意它与 `isAuthenticated` 不是一回事：**匿名试用账号也是「已登录」**，
  ///    但没有邮箱 → `isRegistered == false`。
  ///
  /// 🔑 判据是「有没有邮箱」—— 注册的唯一标志。
  ///    比旧实现「`username` 是否以 `trial_` 开头」可靠：
  ///    那个判据一旦 username 被改（trial 认领原先就会改它）就失效。
  bool get isRegistered => email != null && email!.trim().isNotEmpty;

  AuthState copyWith({
    bool? isAuthenticated,
    String? userId,
    String? token,
    String? username,
    String? email,
    String? error,
    bool? isLoading,
    bool? isRestored,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      userId: userId ?? this.userId,
      token: token ?? this.token,
      username: username ?? this.username,
      email: email ?? this.email,
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
        final email = result['email'] as String?;
        debugPrint('tryRestore: verifyToken=$isValid email=$email');
        if (isValid) {
          state = AuthState(
            isAuthenticated: true,
            userId: userId,
            token: token,
            username: username,
            email: email,
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

  /// 把凭证写入 secure storage。
  ///
  /// [loginId] 是「登录标识」—— 2026-09-29 起**通常是邮箱**；
  /// 匿名试用账号则是它的 `trial_*` 内部 id（此时还没有邮箱）。
  /// ⚠️ 参数名刻意不叫 `username`：那个词会让人以为它一定是个用户名。
  Future<void> _saveCredentials(String userId, String token, String? loginId) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      await _storage.write(key: _userIdKey, value: userId);
      if (loginId != null) {
        await _storage.write(key: _usernameKey, value: loginId);
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

  /// **直接注册**（不需要既有账号）—— 🆕 2026-09-29 起这是「未登录时注册」的正路。
  ///
  /// # 🔴 为什么它取代了 `trialClaim` 成为未登录注册的入口
  ///
  /// `trialClaim`（认领）内部用 `state.userId!` / `state.token!` ——
  /// **未登录时它们是 `null`** → 抛 `Null check operator used on a null value`，
  /// 而 `_friendlyError` 映射不到这种错误 → **用户看到一句英文机器话**。
  ///
  /// 那条路径在 2026-09-29「把登录入口接回『我的』页」之后**首次变得可达**
  /// （此前弹窗只从「已登录但无姓名」的分支打开，userId 必然有值）。
  ///
  /// ✅ 正解就是这里：**未登录 → 直接注册；已登录的匿名账号 → 认领**
  ///    （见 `ClaimDialog._submit`）。两者语义本就不同，不该走同一条路。
  Future<void> register(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.register(email, password);
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      final returnedEmail = result['email'] as String? ?? email;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, returnedEmail);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        // ⚠️ 没有 username 了（用户不再填）——用邮箱前缀当显示名，与后端 `default_display_name` 一致
        username: returnedEmail.split('@').first,
        email: returnedEmail,
        isRestored: true,
      );
      // 清除退出登录标记
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      debugPrint('register 失败 endpoint=${ApiConfig.baseUrl} '
          'email=$email error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
      );
      rethrow;
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.login(email, password);
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      final returnedEmail = result['email'] as String? ?? email;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, returnedEmail);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        username: returnedEmail.split('@').first,
        email: returnedEmail,
        isRestored: true,
      );
      // 登录成功后清除退出登录标记
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      debugPrint('login 失败 endpoint=${ApiConfig.baseUrl} '
          'email=$email error=$e');
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

  /// 修改密码（需登录）。
  ///
  /// # 为什么**不用** `state.isLoading` / `state.error`
  ///
  /// 那两个字段是**页面级**状态（`AuthState` 驱动登录弹窗与「我的」页的整体态）。
  /// 改密码是**弹层内**的操作 —— 若借用它们，会导致：
  /// · 弹层转圈的同时**整个页面**也在 loading（视觉上像整页在刷新）
  /// · 错误会同时出现在**弹层内**（本地 `_error`）与**页面**上（`state.error`）
  ///   ⇒ 用户看到两处同一句话，以为出了两个问题
  ///   （与 `ClaimDialog` 把两类错误收在**同一个位置**是同一条判据）。
  ///
  /// ⇒ 本方法**只做转发与异常抛出**：loading / error 由弹层的局部状态持有。
  /// ⚠️ 抛出的异常**消息即可直接展示**（后端文案已是中文且面向用户）。
  Future<void> changePassword(String oldPassword, String newPassword) async {
    final token = state.token;
    if (token == null || token.isEmpty) {
      // 未登录 —— 正常情况下「修改密码」入口只在已登录时可见，
      // 这里是**兜底**（判据：AuthProvider 应自带前置检查，别依赖 UI 状态）。
      throw Exception('请先登录');
    }
    try {
      await _client.changePassword(
        token: token,
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
    } catch (e) {
      debugPrint('changePassword 失败 endpoint=${ApiConfig.baseUrl} error=$e');
      rethrow;
    }
  }

  /// 「忘记密码」第 1 步：申请验证码（**无需登录**）。
  ///
  /// 与 `changePassword` 同一取舍：**不占用** `state.isLoading` / `state.error`
  /// —— 那两个是**页面级**字段，而这是弹层内的操作
  /// （借用它们会让弹层转圈时整页也在 loading，且错误同时出现在两处）。
  ///
  /// ⚠️ 抛出的消息**可直接展示**。后端在「邮箱未注册」时返回「该邮箱尚未注册」
  ///    （白哥 2026-10-05 定「明说」）⇒ 前端**原样显示**，不要自己改写。
  Future<void> forgotPassword(String email) async {
    try {
      await _client.forgotPassword(email);
    } catch (e) {
      debugPrint('forgotPassword 失败 endpoint=${ApiConfig.baseUrl} error=$e');
      rethrow;
    }
  }

  /// 「忘记密码」第 2 步：用验证码重置密码。
  ///
  /// # 🔴 它和 `forgotPassword` **不同**：这是一个**登录动作**
  ///
  /// 后端在重置成功时**直接返回新 token**（`auth::reset_password` 建了新会话）
  /// ⇒ 这里必须走和 `login` / `register` 一样的路径：**保存凭据 + 置登录态**，
  /// 让用户重置完直接进 App，不必拿新密码再登一次。
  ///
  /// 🔑 所以它**要用** `state`（与 `changePassword` / `forgotPassword` 相反）——
  ///    判据：**看这个动作是否改变「谁登录着」**。
  ///    改密码 / 发验证码：不改变 ⇒ 不碰页面态；
  ///    重置密码：改变 ⇒ 必须碰（否则 App 不知道用户已经登录了）。
  ///
  /// 🔴 另一处**语义差别**（后端已实现，前端无须处理但要知道）：
  ///    重置成功后该用户**所有**旧会话都被删除（与「修改密码」保留当前会话相反）。
  ///
  /// # 为什么**只**在成功时碰 `state`，失败时只 `rethrow`
  ///
  /// `state.isLoading` 与 `state.error` 的**唯一消费者是 `claim_dialog`**
  /// （实测 `grep`：全库只有它读这两个字段）。
  /// 而本方法由 `ForgotPasswordDialog` 调用 —— 那个弹层**自己有** `_error` / `_submitting`
  /// 局部状态。若这里也写 `state.error`：
  ///   · 弹层里显示一次（自己的 `_error`）
  ///   · **弹层关掉后**，后面的 `ClaimDialog` 上还挂着一句错误 ⇒ 用户莫名其妙
  /// 若写 `state.isLoading`：弹层转圈时 `ClaimDialog` 的按钮也变成「登录中…」。
  ///
  /// ⇒ 判据：**「谁在屏幕上」决定用哪套状态** —— 弹层内的操作不该污染页面级状态。
  ///    与 `changePassword` / `forgotPassword` 同一条，但**成功路径不同**：
  ///    那两者不改变「谁登录着」，本方法**改变** ⇒ 必须写 `AuthState`
  ///    （否则 App 不知道用户已经登录，重置完还被拦在门外）。
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final result = await _client.resetPassword(
      email: email,
      code: code,
      newPassword: newPassword,
    );
    final uid = result['user_id'] as String?;
    final token = result['token'] as String?;
    final returnedEmail = result['email'] as String? ?? email;
    if (uid != null && token != null) {
      await _saveCredentials(uid, token, returnedEmail);
    }
    state = AuthState(
      isAuthenticated: true,
      userId: uid,
      token: token,
      username: returnedEmail.split('@').first,
      email: returnedEmail,
      isRestored: true,
    );
    // 清除「退出登录」标记（与 register 同一处理）——
    // 否则刚重置完又被引导去登录页。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      // 清标记失败**不影响**重置结果（凭据已存、state 已登录）
      // ⇒ 只记日志，不向用户报错（同 `logout` 的处理）。
      debugPrint('resetPassword: 清除登录标记失败: $e');
    }
  }

  /// 创建临时账户（**匿名试用**）
  ///
  /// 🔴 2026-10-06：原 `refCode` / `campaignId` 两个参数已删 —— 分销/营销链
  /// 整体退役（后端 `/api/referral/*` 与 `/api/campaign*` 路由已不存在）。
  Future<void> trialStart() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.trialStart();
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
      debugPrint('trialStart 失败 endpoint=${ApiConfig.baseUrl} error=$e');
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
  /// 认领试用账号（把**匿名账号**升级为正式账号）。
  ///
  /// # 🔴 它要求「已登录」—— 未登录时请走 [register]
  ///
  /// 认领的对象是**当前这个匿名账号**（`state.userId`），所以必须先有账号。
  /// 未登录时（例如用户退出过登录、又直接点「注册」）调用它，
  /// 原先会由 `state.userId!` 抛 `Null check operator used on a null value` ——
  /// 而 `_friendlyError` 映射不到这种字符串 → **用户看到一句英文机器话**。
  ///
  /// ✅ 现在改为**显式前置检查 + 人话提示**。调用方（`ClaimDialog`）则为
  ///    「未登录」走 [register]，两个入口各司其职。
  Future<void> trialClaim(String email, String password) async {
    final userId = state.userId;
    final token = state.token;
    if (userId == null || token == null) {
      state = state.copyWith(
        isLoading: false,
        error: '登录状态异常，请重新打开 App 后再试',
      );
      throw StateError('trialClaim 需要已登录（匿名试用账号）');
    }

    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.trialClaim(
        userId,
        token,
        email,
        password,
      );
      final newToken = result['token'] as String? ?? token;
      final returnedEmail = result['email'] as String? ?? email;
      await _saveCredentials(userId, newToken, returnedEmail);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('coevo_trial_claimed', true);
      await prefs.remove('coevo_show_login');
      state = AuthState(
        isAuthenticated: true,
        userId: userId,
        token: newToken,
        // ⚠️ `username` **保持原值**（`trial_*`）—— 认领不再改它（它已退化为内部标识）
        username: state.username,
        email: returnedEmail,
        isRestored: true,
      );
    } catch (e) {
      debugPrint('trialClaim 失败 endpoint=${ApiConfig.baseUrl} '
          'userId=$userId email=$email error=$e');
      state = state.copyWith(
        isLoading: false,
        error: _friendlyError(e.toString()),
      );
      rethrow;
    }
  }
}

/// 🔴 2026-09-29 已删 `isTrialAccount(username)` —— 它靠 `trial_` 前缀猜「是否试用账号」。
///
/// 两个问题：
/// ① **脆弱**：trial 认领原先会改写 `username` → 一改就失效（前缀没了）。
/// ② **口径错**：真正要判断的是「**是否已完成注册**」，而那与用户名长什么样无关。
///
/// ✅ 改用 `AuthState.isRegistered`（判据 = 邮箱是否为空）—— 见那边的注释。

/// 检查是否已完成认领注册（本地标记）。
Future<bool> isClaimed() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('coevo_trial_claimed') ?? false;
}

final authClientProvider = Provider<AuthClient>((ref) => AuthClient());
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref.read(authClientProvider));
});
