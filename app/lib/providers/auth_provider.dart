import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_config.dart';
import '../api/auth_client.dart';
import '../services/auth_session_policy.dart';
import '../services/translation_cache.dart';
import 'subscription_provider.dart';
import 'user_db_provider.dart';

const _tokenKey = 'coevo_auth_token';
const _userIdKey = 'coevo_auth_user_id';
const _usernameKey = 'coevo_auth_username';

/// 卡片刷新信号 — 制卡成功后递增
final cardRefreshProvider = StateProvider<int>((ref) => 0);

class AuthState {
  final bool isAuthenticated;
  final String? userId;
  final String? token;

  /// **内部标识**，不是用户输入的东西。
  ///
  /// ⚠️ 2026-09-29 起用户不再填用户名（注册标识改为 [email]）——
  ///    `/api/auth/register` 生成的是 `u_*`。
  ///    🔴 历史上还有 `trial_*`（匿名试用账号，**2026-10-09 已删除该机制**）——
  ///      存量的 `trial_*` 账号仍可能存在（见 `maintenance` 的 30 天清理）。
  /// 🔴 **不要用它判断「是否已注册」**（旧代码靠 `trial_` 前缀猜，username 一改就失效）
  ///    → 用 [isRegistered]。
  final String? username;

  /// 注册邮箱。
  ///
  /// 🔴 它取代了原来的 `realName`（实名是微信时代遗留，已随「改用邮箱注册」移除）。
  /// ⚠️ 存量匿名账号（`trial_*`）的 `email` 为 `null` —— 新账号不可能为 null。
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

  /// 是否**已完成注册**（= 有没有邮箱）。
  ///
  /// 🔑 判据是「有没有邮箱」—— 注册的唯一标志。
  ///    比旧实现「`username` 是否以 `trial_` 开头」可靠：那个判据一旦 username 被改就失效。
  ///
  /// ⚠️ **2026-10-09 起它几乎恒为 `true`**：不再创建匿名账号（见
  ///    `docs/review/trial-account-removal-2026-10-09.md`）⇒ 只剩**存量**
  ///    匿名账号会给出 `false`。保留它是因为 `app.dart` 的订阅覆盖层仍要放行
  ///    那些存量账号（它们不该被反复推订阅）。
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

  AuthNotifier(this._client, {this.onLogout})
      : _storage = const FlutterSecureStorage(),
        super(const AuthState());

  /// 退出登录时的**额外清理**（可空，但注入处**必须真的传** —— 见 `authProvider`）。
  ///
  /// # 🔑 为什么用回调，而不是在本类里直接清
  ///
  /// 本类只该管**凭据**；「还有哪些本地状态与账号绑定」是**其它模块的知识**。
  /// 写成回调 ⇒ 将来新增一类需清理的状态时，**只改注入处**，不动本类。
  ///
  /// 🔴 而它**不是可选项的语义**：`logout` 的承诺是「退出即清干净」，
  ///    漏注入一类状态就是**跨账号泄漏**（本项目已多次踩到「靠人记得」的机制）。
  final Future<void> Function()? onLogout;

  /// 清除「上一次操作留下的错误」。
  ///
  /// 🔴 2026-10-07 真机修复（白哥反馈 #7B）：
  ///    注册弹窗里**一直**显示「连不上服务器，请检查网络后重试」，但网络其实是通的
  ///    （服务器日志证明内容类与注册请求都 200）。
  ///    根因：`authState.error` **只在下次操作时才会被覆盖** ——
  ///    用户打开弹窗时看到的是**上一次**（常常是启动阶段）留下的旧错误。
  ///
  /// 📌 判据：**错误提示的生命周期要绑定「产生它的那次操作」** ——
  ///    新操作开始 / 弹窗打开时就该清掉，否则用户会把**旧故障当成新结果**。
  ///    （与「静默失败 + 无出口」是一对：这里是**有出口，但出口指向错的因**。）
  ///
  /// ⚠️ 实现细节：`AuthState.copyWith` 里写的是 `error: error`（**没有** `?? this.error`）
  ///    ⇒ **不带 `error` 调用即可清空**。那是有意设计（每次操作都重置错误），这里直接复用，
  ///    不要"顺手"给它加上 `?? this.error` —— 那会让本方法失效。
  void clearError() {
    if (state.error == null) return; // 避免无谓的通知
    state = state.copyWith();
  }

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
        // 🔴 2026-10-08：服务端**没答上**时（网络失败 / 5s 超时）用**本地已存的
        //    登录标识**兜底邮箱。
        //
        // 为什么必须兜底：`email` 的**唯一用途**是 [AuthState.isRegistered]
        //   （= 这个账号是否已完成注册）。而 `verifyToken` 的宽容兜底
        //   （`{'valid': true}`，见 `AuthClient.verifyToken`）**带不回 email**
        //   ⇒ 启动时网络一抖，已注册账号就被**静默降级**成「试用账号」
        //   ⇒ 凭空弹出登录引导（白哥 2026-10-08 真机报的正是这个形状）。
        //   📌 判据：**「宽容兜底」不能改变由该响应推导出的其它判断** ——
        //      兜底只该兜「验不了」，不该顺手把已知信息抹掉。
        //
        // 🔑 兜底数据就在本地：`username` 这个槽位存的是**登录标识**
        //   （`_saveCredentials` 的 `loginId`），自 2026-09-29 起就是邮箱。
        //   ⚠️ 但它不保证是邮箱（匿名试用账号存 `trial_*`）⇒ 由
        //   [emailFromStoredLoginId] 判定（含 `@` 才算），**不能**直接回填 ——
        //   那会把试用账号误判成「已注册」（反方向的错，更隐蔽）。
        final email =
            result['email'] as String? ?? emailFromStoredLoginId(username);
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
        // 🔴 2026-10-09：这里**不再清「已用过试用」标记** —— 该标记本身已删除
        //    （不再创建匿名试用账号 ⇒ 没有「试用名额」这回事）。
        //    ⚠️ 顺带修掉一个真漏洞：原先这里会清标记，而「重装后读不到凭据」
        //       恰会走到这里 ⇒ **每次重装都能再白嫖一次试用**（详见
        //       `docs/review/trial-auto-login-and-trial-subscription-2026-10-09.md`）。
        debugPrint('tryRestore: 本地无存储的认证信息 —— 保持未登录（不再自动建账号）');
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
    } catch (e) {
      debugPrint('_clearCredentials: failed to clear secure storage: $e');
    }
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

  /// **直接注册**（不需要既有账号）—— 未登录时注册的**唯一**正路。
  ///
  /// # 🔴 它取代了 `trialClaim`（2026-10-09 随试用账号机制一起删除）
  ///
  /// `trialClaim`（认领）内部用 `state.userId!` / `state.token!` ——
  /// **未登录时它们是 `null`** → 抛 `Null check operator used on a null value`，
  /// 而 `_friendlyError` 映射不到这种错误 → **用户看到一句英文机器话**。
  ///
  /// 那条路径在 2026-09-29「把登录入口接回『我的』页」之后**首次变得可达**
  /// （此前弹窗只从「已登录但无姓名」的分支打开，userId 必然有值）。
  ///
  /// ✅ 现在**只有这一条**：未登录 → 直接注册（没有可认领的匿名账号了）。
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

  /// Sign in with Apple（**建号 / 登录 / 绑定 三合一**）—— 2026-10-07
  ///
  /// [identityToken] 由**调用方（UI）**从 `sign_in_with_apple` 插件取得。
  /// 🔑 Provider 层刻意**不引入该插件**：这样它仍可在无 iOS 环境（纯 Dart 测试）里被驱动，
  ///    也不用把平台相关的异常处理混进状态管理。
  ///
  /// # 与 [login] 的唯一差别：会带上**当前 token**
  ///
  /// · 已登录（含匿名试用账号）⇒ 后端把 Apple 身份**绑到当前账号**
  ///   （**认领**语义：该账号已有的学习记录**不丢**）
  /// · 未登录 ⇒ 后端建号或按 `apple_user_id` / email 找到既有账号登录
  ///
  /// ⚠️ 这与后端 `/api/auth/apple` 的「一个端点覆盖两种情况」是同一设计，见其 handler 注释。
  Future<void> appleLogin(String identityToken) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await _client.appleLogin(
        identityToken: identityToken,
        token: state.token, // 已登录 ⇒ 绑定；未登录 ⇒ null
      );
      final uid = result['user_id'] as String?;
      final token = result['token'] as String?;
      final returnedEmail = result['email'] as String?;
      if (uid != null && token != null) {
        await _saveCredentials(uid, token, returnedEmail);
      }
      state = AuthState(
        isAuthenticated: true,
        userId: uid,
        token: token,
        // ⚠️ Apple 可能**不返回 email**（非首次授权；或隐藏邮箱且无转发地址）
        //    ⇒ 用「Apple 用户」兜底，与后端建号时的 `display_name` 一致。
        username: (returnedEmail ?? 'Apple 用户').split('@').first,
        email: returnedEmail,
        isRestored: true,
      );
      // 与 register / login 同一处理：清掉「退出登录」标记
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('coevo_show_login');
    } catch (e) {
      debugPrint('appleLogin 失败 endpoint=${ApiConfig.baseUrl} error=$e');
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
    // 🆕 清空**与账号绑定的行为数据**（翻译缓存）。
    //
    // 🔴 为什么必须清：「他翻过哪些句子」是**行为数据**，不是公共内容缓存 ——
    //    跨账号保留 = B 登录后能看到 A 翻过什么。
    //    见 `user_db_schema.sql` 的 `translation_cache` 注释。
    try {
      await onLogout?.call();
    } catch (e) {
      // 同上面 prefs 的取向：清理失败**不影响登出结果**（凭据已清），但要留痕 ——
      // 「静默失败」在这里的形态是「以为清干净了，其实没清」。
      debugPrint('logout: 清理账号绑定的本地数据失败: $e');
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
  ///   （与 `AuthDialog` 把两类错误收在**同一个位置**是同一条判据）。
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
  /// `state.isLoading` 与 `state.error` 的**唯一消费者是 `auth_dialog`**
  /// （实测 `grep`：全库只有它读这两个字段）。
  /// 而本方法由 `ForgotPasswordDialog` 调用 —— 那个弹层**自己有** `_error` / `_submitting`
  /// 局部状态。若这里也写 `state.error`：
  ///   · 弹层里显示一次（自己的 `_error`）
  ///   · **弹层关掉后**，后面的 `AuthDialog` 上还挂着一句错误 ⇒ 用户莫名其妙
  /// 若写 `state.isLoading`：弹层转圈时 `AuthDialog` 的按钮也变成「登录中…」。
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

  // ══════════════════════════════════════════════════════════════════════
  // 修改邮箱（两步）—— 2026-10-07
  // ══════════════════════════════════════════════════════════════════════

  /// 「修改邮箱」第 1 步 —— 发验证码到**新邮箱**（需登录 + **需当前密码**）。
  ///
  /// 🔑 同 [changePassword]：**只转发 + 抛异常**，loading / error 由弹层自己持有。
  ///    理由见 [changePassword] 的文档（借用页面级状态会让弹层与整页同时转圈/报错）。
  ///
  /// 🔴 为什么要密码：只验「新邮箱的码」等于让拿到已解锁设备的人把邮箱改成自己的，
  ///    随后走「忘记密码」彻底接管账号（后端 `auth::issue_email_change_code` 有详述）。
  Future<void> changeEmailCode({
    required String password,
    required String newEmail,
  }) async {
    final token = state.token;
    if (token == null || token.isEmpty) {
      // 兜底（判据同 `changePassword`：Provider 自带前置检查，别依赖 UI 状态）
      throw Exception('请先登录');
    }
    await _client.changeEmailCode(
      token: token,
      password: password,
      newEmail: newEmail,
    );
  }

  /// 「修改邮箱」第 2 步 —— 用验证码换绑（需登录）。返回**新邮箱**。
  ///
  /// 🔑 **成功后必须把新邮箱写回 `state`** —— 否则「我的」页仍显示旧邮箱，
  ///    而用户刚刚明明改成功了。这正是那条判据：
  ///    **「写了 A 端」≠「B 端会显示」**（写库 ≠ 界面已刷新）。
  Future<String> changeEmail({
    required String newEmail,
    required String code,
  }) async {
    final token = state.token;
    if (token == null || token.isEmpty) {
      throw Exception('请先登录');
    }
    final updated = await _client.changeEmail(
      token: token,
      newEmail: newEmail,
      code: code,
    );
    // 🔑 `username` 由邮箱前缀得来（与后端 `default_display_name` 同一规则）
    //    ⇒ 一起更新，否则「我的」页的副标题会留着旧前缀。
    state = state.copyWith(
      email: updated,
      username: updated.split('@').first,
    );
    return updated;
  }

  // 🔴 2026-10-09 已删 `trialStart()`（创建匿名试用账号）—— 见
  //    `docs/review/trial-account-removal-2026-10-09.md`。
  //
  // 白哥定：「**不需要试用账号，未登录状态本来就可以直接用**」。
  // 那套机制没有存在意义，还带来两个真问题：
  //   ① 它的 `subscription_expires` 被后端写成「1 小时后」⇒ 界面显示「订阅中」，
  //      且**真的**放开了云同步/云端书架/翻译额度（那些都读同一个字段）；
  //   ② 「本机已用过试用」标记会在**读不到凭据**时被清掉（`tryRestore` 的 else 分支）
  //      ⇒ 重装即可反复拿新试用。
  //
  // ⚠️ 保留的**存量兼容**：历史上建出来的 `trial_*` 账号仍在库里
  //    （`maintenance` 会在 30 天后硬删未认领的）；本文件里那些「匿名账号」
  //    的注释保留，是为了说明**读旧数据时**仍可能遇到 `email = NULL`。

  // 🔴 2026-10-09 已删 `_setTrialUsedFlag()` / `hasUsedTrial()`：
  //    不再创建匿名试用账号 ⇒ 没有「本机试用名额」这回事。
  //    ⚠️ prefs 里的旧键 `coevo_trial_used` **不做迁移**（读它的人已不存在）。

  // 🔴 2026-10-09 已删 `trialClaim()`（把匿名账号「认领」为正式账号）。
  //    它是**试用账号机制的另一半**：没有匿名账号可认领，认领就没有对象。
  //    ⇒ 未登录 → `register(email, password)`（直接建号）；已登录 → 什么都不做
  //      （登录态下不该出现注册动作）。
  //    📌 顺带清掉一个历史坑：原先「未登录点注册」会误调 `trialClaim`，
  //      而它内部用 `state.userId!` ⇒ 抛 `Null check operator used on a null value`
  //      ⇒ 用户看到一句英文机器话。现在那条路不存在了。
}

/// 🔴 已删的两个概念（留档，防复活）：
/// · `isTrialAccount(username)`（2026-09-29 删）—— 靠 `trial_` 前缀猜「是否试用账号」。
///   两个问题：① **脆弱**（username 一改就失效）② **口径错**（真正要判断的是
///   「是否已完成注册」，与用户名长什么样无关）。✅ 改用 `AuthState.isRegistered`。
/// · `isClaimed()` / `coevo_trial_claimed`（2026-10-09 删）—— 「本机是否认领过」
///   随 `trialClaim` 一起删除；判据本就是 `AuthState.isRegistered`。

final authClientProvider = Provider<AuthClient>((ref) => AuthClient());
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    ref.read(authClientProvider),
    // 🔑 **在这里注入**「退出登录还要清什么」——
    //    `AuthNotifier` 本身不 import 这些模块：既避免它变成「什么都管」的上帝对象，
    //    也避免与 `user_db_provider` 形成循环依赖。
    onLogout: () async {
      // 🔴🆕 2026-10-09：**这里绝不清理「本地数据归属」**（`local_meta.owner_user_id`）。
      //
      // 归属是**「这份数据属于谁」的记录**，它必须在登出后**留着** ——
      // 否则同一个人下次用**同一账号**登录时，判定会退化成「本机还没有归属」
      // ⇒ 走 `claim`（保留数据，看起来没问题），但当**换账号**时就失去了依据：
      // 拿不到旧归属 ⇒ 又变成「把 A 的数据当成 B 的」（回到本次要修的那个缺口）。
      // 📌 判据：**清除「状态」时要分清它是不是「判据」** ——
      //    判据被清掉不会报错，只会让下一次判定**静默地做错**。
      // （换账号的实际清理由 `providers/local_data_owner_provider.dart` 负责。）

      // 翻译缓存 = 行为数据（「他翻过哪些句子」）⇒ 不跨账号保留。
      // 见 `user_db_schema.sql` 的 `translation_cache` 注释与设计稿 §4。
      final db = await ref.read(userDbProvider.future);
      await TranslationCacheRepository(db).clear();

      // 🆕 2026-10-09 🔴 **订阅状态也是账号级状态，必须一起复位。**
      //
      // 它读的是服务端 `users.subscription_expires`（**账号级**）——
      // 登出后不复位，下一个账号/未登录态就会看到**上一个账号**的订阅状态：
      // 界面写「订阅版」而其实没有（白哥 2026-10-09 真机实测到。
      // 根因是当天把该 provider 加进订阅 UI 判据时**没接管它的生命周期**）。
      // 📌 判据：**「登录态」是一组状态的「所有者」—— 退出必须整体复位。**
      //
      // ⚠️ 与**端侧 IAP** 的区别：那个是 **Apple ID 级**（StoreKit 权益跟 Apple ID 走），
      //    登出不该动它 —— 同一台设备换 App 账号，权益本来就还在。**别顺手复位它。**
      //
      // ⚠️ 依赖方向说明：本文件因此 import 了 `subscription_provider.dart`，
      //    而它反向 import 本文件（为了那个 `SubscriptionFetch` 扩展）
      //    ⇒ 形成 **import 环**。Dart 允许，且两边**只在运行时**互相取用
      //    （没有顶层初始化依赖）⇒ 安全。
      //    🔑 但**不要**因此把复位挪到别处：`onLogout` 是「退出即整体复位」的**唯一入口**，
      //       散成多处才是真问题（本项目对「靠人记得」的机制已踩过多次）。
      ref.read(subscriptionProvider.notifier).reset();
    },
  );
});
