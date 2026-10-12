import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
// ⚠️ `flutter/rendering.dart` 与 `shade.dart` 的 `ImageFilter`/`BlurStyle` 同名冲突，
//    这里用 `as ui` 前缀限定 `dart:ui`（原先直接 import 两者会歧义）。
import 'package:flutter/rendering.dart';
import '../api/user_api_client.dart';
import '../api/api_config.dart';
import '../constants/app_info.dart';
import '../providers/auth_provider.dart';
import '../providers/iap_provider.dart';
import '../providers/theme_provider.dart';
import '../services/iap_plan.dart';
import '../services/iap_service.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../providers/memory_settings_provider.dart';
import '../services/memory_settings.dart';
import '../widgets/stats_card.dart';
import '../widgets/header_chip.dart';
import '../widgets/auth_dialog.dart';
import '../widgets/change_email_dialog.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/clay_button.dart';
import '../widgets/clay_field.dart';
import '../widgets/co_dialog.dart';
import '../widgets/interest_filter_section.dart';
import '../widgets/order_history.dart';
import '../widgets/sync_cloud_badge.dart';
import '../theme/clay.dart';
import '../providers/sync_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/highlight_translate_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/tokens_ext.dart';
import '../theme/coevo_tokens.dart';
import 'notification_panel.dart';
import '../widgets/twemoji.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  // ── Theme access ──
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;

  bool _isLoading = true;

  /// 🔴 **只表示「账号资料（`getProfile`）没取到」**，**不再**决定整页渲染。
  ///
  /// # 为什么从「整页错误」降级为「局部错误」（2026-10-10 · 真机踩到）
  ///
  /// 旧实现：`getProfile()` 失败 ⇒ `_error != null` ⇒ `build()` 走 `_buildErrorView()`
  /// ⇒ **整页被替换** ⇒ 本页的 `StatsCard()`（学习记录）**以及所有入口一起消失**。
  ///
  /// 🔴 而 `StatsCard` 是**纯端侧**数据（`widgets/stats_card.dart` 里**零**网络调用）——
  ///    它**根本不需要登录**，却被一个**需要登录**的后端接口的失败**连带抹掉**。
  ///    ⇒ 用户看到「我的」页一片「加载失败」，进而以为**数据没同步/丢了**
  ///    （真实案例：iOS 上就是这样，而数据其实一直在本机）。
  ///
  /// 🔑 判据（正是本文件 `_buildTopBar` 里早就写下的那条）：
  ///    **数据在后端 → 必须登录；数据在端侧 → 不需要。**
  ///    ⇒ 一个页面里**不同数据源的失败必须分层降级**，不能「一起死」。
  ///
  /// 📄 `docs/review/device-sync-and-profile-failure-2026-10-10.md`
  String? _profileError;

  /// `_profileError` 是否由 **401（登录态失效）** 引起 —— 决定给不给「重新登录」出口。
  ///
  /// 🔑 区分这两者很重要：网络错误**重试有意义**；401 是**终态**，
  ///    「重试」永远失败 ⇒ 只给重试等于**没给出口**（真机上这正是用户卡住的原因）。
  bool _profileAuthExpired = false;

  String? _avatarUrl;
  String _displayName = '';
  bool _isUploading = false;

  /// 正在注销（防重入 —— 用户连点入口会开出两个确认弹层）。
  bool _deletingAccount = false;
  ProviderSubscription? _authSub;
  int _unreadCount = 0;

  /// 「账号」组的展开态 —— **默认收起**（白哥 2026-10-08 定）。
  ///
  /// # 🔴 形态变更（2026-10-08 · 白哥真机指令）
  ///
  /// > 「账号下第一个栏目 —— **账号登录状态**，现在不需要修改昵称，
  /// >  点击**下拉**修改密码、退出账号、修改邮箱等。」
  ///
  /// 于是第一行从「**改昵称**的入口」变成「**状态的显示器** + 展开开关」，
  /// 账号级操作全部收进下拉区。
  ///
  /// 🔑 纯 **UI 状态**：不持久化、不进 provider —— 与 `InterestFilterSection._expanded`
  ///    同一条判据（它不是「用户偏好」，只是「这一刻面板开着」）。
  /// 🔑 **默认收起**也同上：收起态信息量更大（一行就说完「我是谁、登录着没有」）。
  bool _accountExpanded = false;

  // 🆕 v1.12（2026-10-11）「批量补译划线译文」的运行态。
  // 🔑 放 `State` 而不是 provider：它是**这一次点击的进度**，
  //    离开页面就该丢（不是需要跨页共享的状态）。
  bool _backfillRunning = false;
  int _backfillDone = 0;
  int _backfillTotal = 0;

  // ── 🗑 2026-09-29 删除的状态（「我的」页重设计 · 白哥定）──
  // · `_hasShownClaimDialog` / `_realName` / `_phone` —— trial 认领与实名（已定不做）
  // · `_qrKey` / `_referralStats` / `_statsLoading` —— 分销账本（`ui-ux` §4.2 定「删分销」）
  // 🔑 只删「显示层」是不够的：名字/字段留着会被后来的人当成「还需要的功能」加回来
  //    （判据：「删掉一个功能后，要清理它的语义残留」）。
  //
  // 🆕 2026-10-06：**`_referralCode` 也删了**（连带 `_loadReferralCode` 与
  //    `GET /api/referral/my-code` 的调用）。
  //    当初留它的理由只有一条：「`StatsCard` 分享时要拼 `?ref=<码>`」——
  //    而新分享形态（3:4 分享图）按规格 §5.7.3「**只放品牌名 · 不加二维码/链接**」
  //    ⇒ 推荐码**失去唯一用途**；留着它等于继续拖着一个 K12 分销端点的调用。
  //    📌 判据：**「当初为什么留」的理由消失时，要回来删掉它** ——
  //       否则残留会**自我延续**（后人看到字段还在，就以为这功能还需要）。

  // TTS：2026-09-26 起只剩端侧 flutter_tts（腾讯云分支与引擎选择已取消）
  // 语速/音色由 `TtsService` 自持（`speechRate` / `selectedVoice`），本页不再另存状态

  @override
  void initState() {
    super.initState();
    _authSub = ref.listenManual(authProvider, (prev, next) {
      if (!mounted) return;

      // ① 未登录 → 已登录：拉取本账号的数据
      if (next.isAuthenticated && prev?.isAuthenticated == false) {
        _load();
        return;
      }

      // ② 已登录 → 未登录（**退出登录**）：清掉所有「属于上一个账号」的状态
      //
      // 🔴 为什么必须清（不只是「干净一点」）：
      //    这几个字段**在未登录时仍会被使用** ——
      //      · `_unreadCount` / `_avatarUrl` → 当前已随登录态隐藏，
      //        但留着会让「下次登录前的瞬间」显示旧值（闪烁）。
      //      · （`_referralCode` 曾在此列 —— 2026-10-06 随分享图改造一并删除）
      //
      // 🔑 判据：**登录态是一组状态的所有者** —— 切换时该**整体复位**，
      //    而不是逐个等到「用到了才发现不对」。
      //    同族：`verification-rules` 的「资源所有权唯一」。
      if (!next.isAuthenticated && prev?.isAuthenticated == true) {
        setState(() {
          _unreadCount = 0;
          _avatarUrl = null;
        });
        return;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());

    // 🔑 **兜底检查**：进入「我的」页时检查一次成就解锁。
    //
    // 为什么需要它（即使复习/查词处都已触发）：
    //   · 那两处是**主动路径**，但用户可能「上次解锁条件已满足、却因 App 被杀
    //     而没走到检查」→ 成就永远不亮
    //   · 而 `checkAndUnlock` 是**幂等**的 → 多调一次零代价
    // 🔑 判据：**宁可多调，不可漏调**（漏调 = 静默不解锁，且无法自愈）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkAchievements());
    });
  }

  /// 「我的」页的兜底成就检查（失败只记日志 —— 见 `achievement_provider.dart`）。
  Future<void> _checkAchievements() async {
    final newly = await checkAndRefreshAchievements(ref);
    if (newly.isEmpty || !mounted) return;
    ref.read(achievementUnlockProvider.notifier).pushAll(newly);
  }

  Future<void> _loadUnreadCount() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    try {
      final resp = await http.get(
        Uri.parse(
            '${ApiConfig.baseUrl}/api/notifications?user_id=${auth.userId}'),
        headers: {'Authorization': 'Bearer ${auth.token}'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _unreadCount = (data['unread_count'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _displayName = prefs.getString('display_name') ?? auth.username ?? '用户';
      // 重试 / 下拉刷新时先清掉上一次的错误态，否则成功也会显示旧错误。
      _profileError = null;
      _profileAuthExpired = false;
    });

    if (auth.userId == null || auth.token == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // 存储头像 URL，预检是否有效（后台 fire-and-forget，不阻塞 UI）
    final avatarUrl = '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar';
    // 预检：如果头像不存在，将 URL 置 null 防止 NetworkImage 抛未捕获异常
    try {
      final resp = await http.head(Uri.parse(avatarUrl));
      if (resp.statusCode == 200) {
        _avatarUrl = avatarUrl;
      }
    } catch (_) {
      // 网络错误则保持 _avatarUrl 为 null
    }

    final client = UserApiClient(userId: auth.userId!, token: auth.token);
    try {
      // 🗑 2026-09-29：原先这里用 `Future.wait` 同时发 `getProfile()` + `getPreferences()`，
      //    但偏好结果**从未被消费**（下面只用了 `results[0]`）。
      //    原注释称「请求暂留（`review_screen` 仍在用）」—— 🔴 该理由**已失效**：
      //    `review_screen` 已于 09-28 整体重写（数据源全走端侧 `user.db`、**不联网**、
      //    不依赖登录态），**不再使用 chat_client**（注释写于 09-26，所指版本已不存在）。
      //    → 该请求纯属多余（每次进本页多一次后端调用），已删除。
      final data = await client.getProfile();
      // 如果后端有 display_name，覆盖本地缓存
      final backendName = data['display_name'] as String?;
      if (backendName != null && backendName != _displayName && mounted) {
        await prefs.setString('display_name', backendName);
        setState(() => _displayName = backendName);
      }
      // 🗑 2026-09-29：「真实姓名 / 手机号」已随旧版分区删除（`ui-ux` §4.2 定「删实名」）
      //    → 这里不再保存它们。后端仍可能返回这两个字段，但**本页不再消费**。
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      // 异步加载未读通知数（不阻塞主流程）
      _loadUnreadCount();
    } catch (e) {
      // 🔴 只降级「账号资料」这一块，**不整页失败**（见 `_profileError` 的类文档）。
      //    `isUnauthorized` 用**类型**判别（`ApiStatusException`），不靠字符串匹配 ——
      //    否则改一次文案就会静默失去「重新登录」入口。
      final expired = e is ApiStatusException && e.isUnauthorized;
      if (mounted) {
        setState(() {
          _isLoading = false;
          _profileAuthExpired = expired;
          _profileError = expired
              ? '登录状态已失效（可能在本账号的其它设备上重新登录过）'
              : '资料加载失败，请检查网络连接';
        });
      }
    }
  }

  /// 🔑 **401 的出口**（2026-10-10 新增）。
  ///
  /// 旧实现只有「重试」——而 401 是**终态**：重试用的还是 `authProvider` 里**同一个**
  /// 失效 token ⇒ **必然再 401** ⇒ 用户被卡在「加载失败」上，
  /// **唯一出路是杀掉 App 重开**（真机复现）。
  ///
  /// 这里先调 `tryRestore()`：它会**在服务端校验**该 token，
  /// 失效则清掉本地凭据（⇒ 本页回到「登录 / 注册」入口）；
  /// 若只是**网络抖动**，它刻意宽松（`verifyToken` 网络失败时返回 `valid:true`）⇒ 不会误清。
  Future<void> _reloginAfterTokenInvalid() async {
    await ref.read(authProvider.notifier).tryRestore();
    if (!mounted) return;
    if (!ref.read(authProvider).isAuthenticated) {
      _showLoginDialog();
    } else {
      // 校验其实仍有效（例如 401 来自瞬时抖动）⇒ 直接重取即可
      setState(() {
        _isLoading = true;
        _profileError = null;
        _profileAuthExpired = false;
      });
      await _load();
    }
  }

  Future<void> _uploadAvatar() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
    if (picked == null) return;

    setState(() => _isUploading = true);

    final uri =
        Uri.parse('${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer ${auth.token}';
    try {
      final bytes = await picked.readAsBytes();
      request.files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: 'avatar.png'));
      final streamed =
          await request.send().timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 200 && mounted) {
        setState(() => _avatarUrl =
            '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar?t=${DateTime.now().millisecondsSinceEpoch}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('头像已更新'), duration: Duration(seconds: 2)),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败 (${streamed.statusCode})')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传出错: $e')),
        );
      }
    }

    if (mounted) setState(() => _isUploading = false);
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _displayName);
    // ⚠️ 既有的 `TextEditingController` **未释放**（2026-09-29 复核时发现，已列入报告）。
    //    不能在这里补一行 `controller.dispose()` —— `Navigator.pop` 之后弹窗还有
    //    约 200ms 的关闭动画，期间 `TextField` 仍在渲染 → 立刻 dispose 会抛
    //    「used after being disposed」。正解是把弹窗本体做成 `StatefulWidget`，
    //    在它的 `dispose()` 里释放（`AuthDialog` 就是这个形态，它没有这个问题）。
    final result = await CoDialog.show<String>(
      context,
      builder: (ctx) => CoDialog(
        title: '修改昵称',
        actions: [
          ClayButton(
            label: '取消',
            variant: ClayButtonVariant.secondary,
            expanded: true,
            onTap: () => Navigator.pop(ctx),
          ),
          ClayButton(
            label: '保存',
            expanded: true,
            onTap: () => Navigator.pop(ctx, controller.text),
          ),
        ],
        child: ClayField(
          controller: controller,
          hintText: '输入昵称',
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ),
    );
    if (result != null && result.trim().isNotEmpty && result != _displayName) {
      final auth = ref.read(authProvider);
      final trimmed = result.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('display_name', trimmed);
      // 同步到后端
      if (auth.userId != null && auth.token != null) {
        final client = UserApiClient(userId: auth.userId!, token: auth.token);
        try {
          await client.updateDisplayName(trimmed);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text('昵称同步失败: $e'),
                  action: SnackBarAction(
                      label: '重试', onPressed: () => _editName())),
            );
          }
        }
      }
      setState(() => _displayName = trimmed);
    }
  }

  /// 账号资料区的**局部**降级提示（2026-10-10 新增，取代原 `_buildErrorView`）。
  ///
  /// # 与原 `_buildErrorView` 的区别（本质区别，不是样式微调）
  ///
  /// | | 原实现 | 本实现 |
  /// |---|---|---|
  /// | 渲染位置 | **整页**（`body` 三选一）| **「账号」组内**一行 |
  /// | 影响范围 | 🔴 学习记录 / 各入口**一起消失** | ✅ 本页其余内容**照常** |
  /// | 出口 | 只有「重新加载」 | 网络错误给「重试」；**401 给「重新登录」** |
  ///
  /// 🔑 「网络错误」与「401」必须给**不同的动作** —— 前者重试有意义，
  ///    后者是终态（重试必然再失败）⇒ 只给重试等于**没有出口**。
  Widget _buildProfileErrorNotice() {
    final expired = _profileAuthExpired;
    return Padding(
      padding: const EdgeInsets.fromLTRB(CoSpacing.lg, 0, CoSpacing.lg, CoSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            expired ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
            size: 18,
            color: Color(CoEvoTokensExt.of(context).ink3.argb32),
          ),
          const SizedBox(width: CoSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _profileError ?? '资料暂不可用',
                  style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant),
                ),
                const SizedBox(height: CoSpacing.xs),
                // 🔴 401 ⇒ 「重新登录」（唯一有效出口）；其余 ⇒ 「重试」
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: expired ? _reloginAfterTokenInvalid : _load,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Tw(expired ? '重新登录' : '重试'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 简单内联行，用于个人信息卡片内的每一行（无 Card 嵌套）
  /// [onTap] 为 null 时只读显示（无 InkWell 和箭头）
  /// 图标宽度固定为 32px，与昵称行的头像宽度对齐
  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      // 🔴 **自绘顶栏**（不用 `AppBar`）—— 与其他 tab 页（信息流 / 复习）**逐字一致**：
      //    23px / w600 / 字距 −0.015em / `t.ink`、外层 `padding LTRB(18, 2, 18, 14)`。
      //
      //    ⚠️ 这是本页此前**最显眼的「风格不符」**：用着 Material `AppBar`
      //      （19px / w500 + 默认阴影），而另外两个 tab 早就换成了自绘顶栏。
      //    🔑 「统一」不是抽象要求 —— 它意味着**同一组数值**（字号/字重/字距/内边距）。
      backgroundColor: Color(CoEvoTokensExt.of(context).page.argb32),
      // 🔴 2026-10-10：**删掉了「整页错误」分支**（原为 `_error != null ? _buildErrorView() : …`）。
      //
      //    原实现的后果（真机复现）：`getProfile()`（**需要登录**）失败
      //    ⇒ **整页**被替换成「加载失败」⇒ 本页的 `StatsCard()`（学习记录，
      //    **纯端侧、零网络**）与所有入口一起消失 ⇒ 用户以为数据丢了/没同步。
      //
      //    🔑 判据：**一个页面里不同数据源的失败必须分层降级**（局部提示），
      //      不能「一起死」。详见 `_profileError` 的类文档。
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopBar(auth),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: () async {
                            setState(() {
                              _isLoading = true;
                              _profileError = null;
                              _profileAuthExpired = false;
                            });
                            await _load();
                          },
                          child: _buildContent(context, auth),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// 顶栏：标题 + 副标题（左）· 通知入口（右上）。
  ///
  /// # 🔴 两个元素都**依赖登录态**（2026-09-29 白哥复核后定）
  ///
  /// | 元素 | 未登录 | 为什么 |
  /// |---|---|---|
  /// | 副标题 | 只显示 `免费版`（**不含昵称**） | 昵称来自登录账号 —— 没登录就没有名字可显示。<br>⚠️ 但 `免费版` / `订阅版` 是**真实状态**（不依赖登录）→ **保留** |
  /// | 通知入口 | **不渲染** | 未读数来自 `/api/notifications?user_id=`；未登录时面板里 `_userId.isEmpty` 直接 return → **点开是空白** |
  ///
  /// 🔑 判据：**数据在后端 → 必须登录；数据在端侧 → 不需要。**
  ///    详见方案 §11.6.1b。
  Widget _buildTopBar(AuthState auth) {
    final t = CoEvoTokensExt.of(context);
    // 版本标签与订阅卡**同源** —— 两处口径必须一致，
    // 否则会出现「卡片说订阅中、副标题说免费版」这种自相矛盾。
    // 🔴 2026-10-09：来源由「纯端侧 `iapSnapshotOf`」改为**全库唯一判据**
    //    `subscriptionActiveNow`（端侧 OR 服务端对账值）——
    //    纯端侧在安卓验证机 / 后台授予的订阅上永远给 false（白哥真机踩到）。
    final version = versionLabel(subscriptionActiveNow(ref));
    final subtitle = auth.isAuthenticated
        ? '${_displayName.isEmpty ? '用户' : _displayName} · $version'
        : version;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '我的',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 23,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 23 * -0.015,
                    color: Color(t.ink.argb32),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ],
            ),
          ),
          // ── 通知入口（**已登录才显示** · 白哥 2026-09-29：「右上角的通知按钮保留」）──
          //
          // 🔑 用的是**现役公共组件 `HeaderChip`**（信息流右上角「收藏 N」、
          //    复习页「全部/已到期」**同一个**）—— 不是自创一个新样式。
          // 🔑 `count: null`（未读为 0）= **不显示计数**（而不是显示「0」）。
          //
          // 🔴 **未登录时不渲染**：未读数接口要 `user_id`，
          //    未登录时 `_loadUnreadCount()` 直接 return → 计数恒为 null（看似正常），
          //    但点进去 `NotificationPanel` 里 `_userId.isEmpty` 也直接 return
          //    → **用户看到的是一个空白页**（「静默失败 + 无出口」）。
          //    隐藏比「显示一个点不开的入口」诚实。
          if (auth.isAuthenticated) ...[
            const SizedBox(width: 12),
            HeaderChip(
              icon: Icons.notifications_none,
              label: '通知',
              count: _unreadCount > 0 ? _unreadCount : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationPanel()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // 页面内容（2026-09-29 重设计 · 白哥定）
  // 📄 `docs/design/profile-redesign-plan-2026-09-29.md`
  //
  // 🔴 删掉的 5 个旧版分区（依据 `ui-ux-refactor-assessment-2026-09-25` §4.2 / §6.1）：
  //    推广二维码 · 推广统计 + 收益明细/我的团队/提现 · 真实姓名/手机号 ·
  //    「跳过的概念」 · trial 认领弹窗
  //    🔑 其中 **4 个按钮指向未注册路由**（`/earnings` `/team` `/withdraw` `/skipped`）
  //      → 点了落到 `/:unknown`。这正是「很乱」的一个**可复现来源**：
  //        删掉它们，那个 bug 就不存在了 —— **修 bug 不需要额外工作**。
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildContent(BuildContext context, AuthState auth) {
    return ListView(
      // 底部留出 tabbar 高度 —— `_ShellScaffold` 开了 `extendBody: true`，
      // 正文会延伸到 tabbar 之后，不留距离的话最后一项会被按钮压住。
      // 依据见 `CoSpacing.tabBarClearance`。
      padding: const EdgeInsets.fromLTRB(CoSpacing.xxl, CoSpacing.sm,
          CoSpacing.xxl, CoSpacing.tabBarClearance),
      children: [
        // ── ① 顶部统计卡（三列：连续天数 / 掌握词数 / 阅读篇数 + 分享）──
        //    🔑 规格：「顶部：统计区 + 分享入口」。
        //    ⚠️ 「成就列表」（徽章行 / 进度条）按白哥 2026-09-29 决策**移出**本页
        //       → 它们在 `/achievements` 完整存在（本页只留一个入口，见 ④）。
        StatsCard(),
        const SizedBox(height: CoSpacing.xl),

        // ── ② 账号（未登录 / 已登录两态）──
        _groupLabel('账号'),
        _buildAccountGroup(auth),
        const SizedBox(height: CoSpacing.lg),

        // ── ③ 内容偏好（兴趣筛选）──
        //    🔴 **位置与形态都改过两轮**，最终定在这里（白哥 2026-10-03 两次真机反馈）：
        //      · v1 「我的」页 · 12 个胶囊**全展开** ⇒「UI 设计不好」（低频项占半屏，撑乱本页）
        //      · v2 **信息流页顶部** · 常驻一行 ⇒「**阅读界面太拥挤**」
        //      · v3 ⭐ **「我的」页 · 收起成一行**（本版）—— 保留 v1 的位置，修掉 v1 的形态
        //    🔑 **判据（修正后）**：「前置控制放哪」= **使用频率 × 占用空间**，
        //       不是「它是不是前置控制」。兴趣筛选**低频**（设一次长期不动）
        //       ⇒ 属设置页，**且必须能收起来**（收起态只占一行）。
        //    📌 完整推导 + 两次反馈的对照表 → `widgets/interest_filter_section.dart` 类文档。
        _groupLabel('内容偏好'),
        const InterestFilterSection(),
        const SizedBox(height: CoSpacing.lg),

        // ── ④ 记忆（默写准确率）──
        //    🔑 单独一个分组，**不塞进「其他」** —— 那里是「关于」之类的杂项，
        //       学习行为的设置放进去会被埋掉。
        //       放置依据是本项目那条既有判据：**语义归属 × 常驻成本**
        //       （学习行为 + 低频 ⇒ 设置页）。
        //    📌 依据：白哥 2026-10-07「让记忆准确率可调吧，在我的页面弄个设置的滑动条」。
        _groupLabel('记忆'),
        _buildMemoryTile(),
        const SizedBox(height: CoSpacing.sm),
        // 🆕 2026-10-07 记忆列表入口 —— 在设计稿 §8 定的：
        //    **与「默写准确率」同组**（两者都属「记忆」这件事：一个调标准，一个看结果）。
        //    ⚠️ 它**不是**「其他」那一族的杂项 —— 那是「关于」类。
        // 🔄 2026-10-08：「我的划线」的入口**已删除** ——
        //    白哥定案把它改名「笔记」并移入**「复习」tab**，与「复习」平级
        //    （`ReviewTabScreen` 的标题行就是它的入口）。
        //    🔴 为什么删而不是留着：**两个入口指向同一份数据**会让栈行为分叉
        //       —— 生词本那次（`/home/words` 独立页）已经踩过，结论是
        //       「**同一份数据只留一个入口**」。
        //    ⚠️ 「阅读」tab 的书架段同理：它也没有一个「我的书架」的二级入口。
        const SizedBox(height: CoSpacing.lg),

        // ── ⑤ 订阅 ──
        //    🔴 登录态分流的**三处之一**（另两处：顶栏通知入口 · 账号组）。
        //
        //    未登录时**不隐藏订阅组**，而是换文案为「订阅完整版」入口 ——
        //    依据 `ui-ux` §4.4 判据 6 原文：
        //      「朗读按钮在免费层**可见但点击时提示订阅 —— **不要藏起来**。
        //        让用户知道有这个能力，才能成为订阅动机」
        //    + §4.4.4：「未订阅 → 「我的」页显示「**订阅完整版**」入口」。
        //    → 未登录 = 必然未订阅 ⇒ 应显示**入口**。**藏起来会切断订阅动机。**
        _groupLabel('订阅'),
        _buildSubscriptionCard(auth),
        // 🆕 2026-10-09 云端同步的**独立胶囊**（白哥定：「还是在我的里弄个独立的胶囊吧」）。
        //
        // 🔑 为什么是**独立**的、而不是贴在上面那张订阅卡里：
        //    那张卡说的是「**你订了什么**」（账号级、由服务端/StoreKit 决定），
        //    这枚胶囊说的是「**云端数据走到哪了**」（一次同步的进行状态）——
        //    两件事，只是同属「订阅」这个语义组。
        //    贴在一起时它会被读成订阅卡的一个字段（而且图标形态说不出时间）。
        //    📌 判据：**控件放哪 = 语义归属 × 常驻成本**（同 `interest_filter_section`）。
        //
        // 🔑 它**自包含**：自己判订阅（未订阅 ⇒ 零高）+ 自己 watch 同步状态
        //    ⇒ 调用方一行。形态的取舍见 `widgets/sync_cloud_badge.dart` 的类文档。
        const SyncCloudChip(),
        const SizedBox(height: CoSpacing.sm),
        // 🆕 「恢复购买」—— `ui-ux §4.4.3` 明确要求**两处**入口
        //    （订阅页 + 本页）。理由：**用户订阅后就不会再进订阅页了**，
        //    得从「我的」页也能找到（Apple 审核会检查这一项）。
        //
        // 🔑 与上面「我的成就 / 关于」同样用 `_navTile` —— 同族入口行，
        //    不做特殊外壳（判据：统一的是外壳与层级）。
        _navTile(
          icon: Icons.restore,
          title: '恢复购买',
          subtitle: '换设备或重装后找回已订阅',
          onTap: _restorePurchases,
        ),
        //    ⚠️ 历史订单**未登录时不渲染**：它按 `user_id` 查（`_loadOrders`
        //       里 `userId == null` 直接 return）→ 未登录必然显示「暂无订单」。
        //       显示一个恒空的列表没有信息量，属「未登录态多出来的东西」。
        if (auth.isAuthenticated) ...[
          const SizedBox(height: CoSpacing.sm),
          const OrderHistory(),
        ],
        const SizedBox(height: CoSpacing.lg),

        // ── ⑥ 其他 ──
        //    🔑 「我的成就」是**到成就墙的入口**（不是成就列表本身）。
        //      本页不再展示徽章/进度 —— 那两样都在 `/achievements`。
        //
        //    🔴 2026-09-29：「联系工作人员」**已移到「关于」页**（白哥定）。
        //      它属「关于本 App」那一族（与隐私政策/用户协议/版本/备案号同类），
        //      不是「高频操作」—— 放在这里会把「偶尔点」和「经常点」混在一起。
        //      📄 现由 `about_screen` 承载（含二维码弹窗）。
        _groupLabel('其他'),
        _buildThemeTile(),
        // 🔴 2026-10-06：「朗读设置」卡（语速 + 音色 + 试听）**已搬走** ——
        //    搬进**阅读设置面板**（`widgets/reading_settings_panel.dart`）。
        //    依据：白哥 2026-10-06 定「搬」+ spec §5.1「面板内：字号/…/发音语速音色」。
        //    ⚠️ 那张卡原先也服务**词卡朗读**场景 ⇒ 搬走后词卡里调音色需先进入文章。
        //      这是白哥权衡后的决定，代价记在 `reading_settings_panel` 的类文档里。
        //    🔑 状态**没有搬** —— 语速/音色仍是 `ttsServiceProvider` 的同一个值，
        //      只是入口换了个位置（「入口位置」与「状态权威」是两件事）。
        const SizedBox(height: CoSpacing.sm),
        _navTile(
          icon: Icons.emoji_events_outlined,
          title: '我的成就',
          subtitle: '查看全部成就与进度',
          onTap: () => context.push('/achievements'),
        ),
        const SizedBox(height: CoSpacing.sm),
        _navTile(
          icon: Icons.info_outline,
          title: '关于',
          subtitle: '版本 $kCoEvoVersion',
          onTap: () => context.push('/about'),
        ),

        // 🔴 2026-10-09：本页**页尾原先还有一块「账号级操作」**（只剩「注销账号」）——
        //    已随「退出账号」一起搬进「账号」组的下拉区（白哥：「注销账号也应该放进去」）。
        //
        //    这里现在**什么都不留**（连它的间距也删了）：那一块原先靠
        //    `if (auth.isAuthenticated)` 才渲染，而未登录时账号组本来就是一个单行入口
        //    ⇒ 它是**有条件才出现的孤立卡**。搬走之后留着间距，会变成一块
        //    「说不出用途的空白」。
        //    📌 判据：**搬走一个入口后要问「它是不是这块地方唯一的住户」** ——
        //       是的话，连容器/间距一起撤，而不是留个空壳。
        //    ⚠️ 底部仍留了 `CoSpacing.tabBarClearance`（见 `ListView` 的 padding）——
        //       那是给自绘 tabbar 让位的，与本次搬迁无关，**不要**顺手删。
      ],
    );
  }

  /// 分组标题（11px / w600 / 字距 .06em / `ink3`）。
  ///
  /// 🔑 分组是「乱」的解药之一 —— 判据：
  ///    **视觉「乱」先查「容器与分隔」，最后才查字号**。
  Widget _groupLabel(String label) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, CoSpacing.sm),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 11 * 0.06,
          color: Color(t.ink3.argb32),
        ),
      ),
    );
  }

  /// 账号组 —— **两态**（未登录 / 已登录）。
  ///
  /// # 🔴🔴 2026-10-05 更正：下面这张表**已是历史记录**，三行状态全部过时
  ///
  /// 原表是 **2026-09-29「只做 UI 骨架」那一次**的时点状态。此后账号线已大幅推进，
  /// 而表**没跟着改** ⇒ 它会把后来人引向错方向（最典型：「注销还没做」）。
  ///
  /// | 项 | 09-29 原记 | **实际（2026-10-05 核实）** |
  /// |---|---|---|
  /// | 已登录：昵称（可改） | ✅ | ✅ 仍是（`_editName`） |
  /// | 绑定邮箱 | 🟠 占位<br>「后端 `users` 表**连 `email` 列都没有**」 | ✅ **已实现** —— `users.email` **有列 + 部分唯一索引**（`schema.rs:23` · 迁移 `ADD COLUMN email TEXT DEFAULT NULL`）<br>🔴 且**语义已变**：注册即绑邮箱 ⇒ 该行从「**去绑定**」变成「**显示你用的是哪个邮箱**」（邮箱暂不可改，后端无改邮箱端点，故点了给明确说明，不是死入口） |
  /// | 未登录：引导行 | ✅ 点了提示 | ✅ **已实现** —— 点了真的开登录弹层（`_showLoginDialog`：邮箱注册/登录） |
  /// | Apple 登录 / 邮箱验证 | ❌ | ❌ **仍未做** —— 这一项是**唯一**还成立的 |
  /// | **注销** | ❌ 「后端 + SDK 全未做」 | ✅ **已完成** —— `POST /api/user/me/delete`（`user_purge.rs`）· 满足 Apple 5.1.1(v) 的**App 内自助真删**（软删/硬删两档） |
  ///
  /// ### 🔴 2026-10-08 / 10-09 追加（第 3 次变更 · 上表**又有两格过时**）
  ///
  /// 白哥定：① **第一行改为「账号登录状态」**（点击 = 展开下拉，不再是改昵称）；
  /// ② 账号级操作全部收进下拉区；③「修改邮箱」只留四个字的动作名；
  /// ④ 次日追加：「**注销账号也应该放进去**」。
  /// ⇒ 上表要读成：
  /// · 「已登录：昵称（可改）」→ **昵称仍可改，但入口在下拉区的「修改昵称」项**
  /// · 「**注销**」那一格的**入口位置**变了 —— 实现没变（仍是 `POST /api/user/me/delete`），
  ///   但它从**页尾**搬进了**下拉区最末**（页尾那一小块卡连同间距一起删了）。
  ///
  /// 📌 判据：**「本次只做 X」这类阶段说明必须带日期，且后续变更要回来改它** ——
  ///    否则它会**永久停格**在当时的时点，而读者会信它 ⇒ 比没有注释更糟。
  ///    🔑 与「改名后须扫旧名残留」同族：**状态变了，指着旧状态的文字也要变。**
  ///    ⚠️ 注意这里过时的是「**位置**」而不是「做没做」—— 同一个位置字段被改过两次，
  ///       说明**位置类描述最容易漂**（可发现性/形态类需求会反复调）。
  ///
  /// 🔑 当初「拆开做」的判断仍然成立（留档）：账号 UI 是**纯前端**
  ///    （现有 `authProvider` 就够），而 Apple 登录 / 邮箱验证要
  ///    **改后端 + 加 SDK + iOS Capability** ⇒ 混在一批会让
  ///    「一个页面重排」膨胀成「认证系统改造」。
  Widget _buildAccountGroup(AuthState auth) {
    final t = CoEvoTokensExt.of(context);
    final radius = BorderRadius.circular(16);

    if (!auth.isAuthenticated) {
      // 🔑 未登录时这一行是**入口**，不是「状态」（白哥 2026-09-29 定）。
      //
      //    旧文案「未登录 / 登录后可跨设备同步 · 找回订阅」的问题在于措辞：
      //    它把头两个字放在「你缺了个账号」上，而用户此刻关心的是「登录有什么用」。
      //    → 改成动作（「登录 / 注册」）+ **价值**（跨设备同步 · 找回已购订阅）。
      //
      //    这正好对应规格 §10.1.1 说的那两类时刻：
      //    「**匿名可用 → 需要同步或购买时引导注册**」
      //    「账号只在两类时刻出现：**要同步**、**要付费**」
      return Clay(
        borderRadius: radius,
        padding: EdgeInsets.zero,
        child: _navTile(
          icon: Icons.person_outline,
          title: '登录 / 注册',
          subtitle: '跨设备同步 · 找回已购订阅',
          onTap: _showLoginDialog,
          bare: true,
        ),
      );
    }

    // 🔴 2026-10-09：原先这里有 `final trial = !auth.isRegistered;`，用来在
    //    下拉区给**匿名试用账号**额外挂一个「登录 / 注册」项（认领语义）。
    //    试用账号机制整体退役 ⇒ 那一项连同这个局部变量一起删除。
    //    📌 「未登录」时仍有登录入口 —— 就是本方法开头那一整行（未登录分支）。
    return Clay(
      borderRadius: radius,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ══════════════════════════════════════════════════════════════
          // ① 账号登录状态 —— **纯状态显示**（整行点击 = 展开 / 收起）
          //
          // 🔴 2026-10-08 白哥定：「账号下第一个栏目 —— 账号登录状态，
          //    **现在不需要修改昵称**，点击下拉修改密码、退出账号、修改邮箱等。」
          //    ⇒ 整行 `onTap` 由 `_editName`（改昵称）改为**切换展开态**。
          //
          // ⚠️ 改昵称**没有被删**，只是搬进了下拉区（见 ②）——
          //    若只换整行的 `onTap` 而不管旧动作，`_editName` 就成了**零调用方**，
          //    改昵称能力会**静默消失**（编译器不报：没人用不是错误）。
          //    📌 与 `_navTile` 里那条「头像差点失去 `_uploadAvatar` 调用点」同族：
          //       **换一个整行的点击目标时，先查原来那个动作还有没有别处能触发。**
          //
    // 🔑 副标题 = **登录状态**；顺带显示**登录用的邮箱**：
    //    「修改邮箱」行改成四个字的动作名之后（白哥同批指令），邮箱地址会从
    //    界面上消失，而 `ChangeEmailDialog` 里**也不显示当前邮箱**
    //    ⇒ 用户再也看不到自己绑的是哪个邮箱。这里补上（超长截断）。
    // 🔴 2026-10-09：删掉了 `trial ? '已登录 · 试用账号'` 那一支 ——
    //    不再创建匿名试用账号（存量账号的 `email` 仍可能为 null ⇒ 显示「已登录」）。
    _navTile(
      icon: Icons.person_outline,
      title: _displayName.isEmpty ? '用户' : _displayName,
      subtitle: auth.email ?? '已登录',
            showAvatar: true,
            onTap: () => setState(() => _accountExpanded = !_accountExpanded),
            // 展开指示：展开时转 180°（`▾` → `▴`）。
            // 🔑 与 `InterestFilterSection` **逐参数一致**（18 · ink3 · 180ms · easeOutCubic）——
            //    「同类元素共享版式」：两处展开控件长得不一样，用户会以为是两种机制。
            trailing: AnimatedRotation(
              turns: _accountExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child:
                  Icon(Icons.expand_more, size: 18, color: Color(t.ink3.argb32)),
            ),
            bare: true,
          ),
          // 🆕 2026-10-10：**账号资料取不到时的「局部」降级提示**。
          //
          // 🔴 它必须挂在这里（账号组内），**不能**再回到「整页替换」——
          //    否则一个需要登录的接口失败，会连带抹掉本页**纯端侧**的学习记录
          //    （真机复现；详见 `_profileError` 的类文档）。
          // 🔑 401 与网络错误给**不同的动作**（重新登录 / 重试）——
          //    401 是终态，只给「重试」等于没有出口。
          if (_profileError != null) _buildProfileErrorNotice(),
          // ══════════════════════════════════════════════════════════════
          // ② 下拉区 —— 账号级操作（**默认收起**）
          //
          // 🔑 全是**动作** ⇒ **一律只有名称、不带说明**：
          //    ① 白哥 2026-10-08 明确「『修改邮箱』只要这四个字」；
          //    ② 下拉是动作菜单，每条都挂一句小字说明会让整列全是噪音；
          //    ③ 与 `InterestFilterSection` 同一交互语汇（`AnimatedSize` 180ms 就地向下长）。
          //    ⚠️ 旧说明「登录账号 · 找回账号靠它」已删（那是**状态说明**，
          //       挂在一个动作项下面词不达意）—— 断言里加了反向项防它复活。
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            // ⚠️ 收起时用 `SizedBox(width: double.infinity)` 而不是 `SizedBox.shrink()`：
            //    后者宽度为 0 ⇒ 展开时会**同时**从 0 宽长到全宽（横向拉伸感，很怪）。
            //    （同一个坑，`InterestFilterSection` 里已记着一次。）
            child: _accountExpanded
                ? Column(
                    children: [
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(t.line.argb32)),
                      // 🔴 2026-10-09：原先这里在 `if (trial)`（= 未完成注册）时
                      //    额外挂一个「登录 / 注册」项 —— 因为当时 App **首次启动就会
                      //    自动建匿名试用账号** ⇒ 用户几乎永远「已登录」⇒ 本页开头
                      //    「未登录」那一行基本不出现 ⇒ 自动弹窗一取消，**登录入口会整条消失**。
                      //    试用账号退役后**那个隐患消失了**：新用户初始就是「未登录」，
                      //    本页账号组的第一行（未登录分支）**就是**登录 / 注册入口。
                      //
                      // 🔑 判据（仍然有效，别忘）：**删一个「入口」前，先查它是不是
                      //    别的东西的唯一入口** —— 弹窗不该**自动**打扰，但入口必须**常驻**。
                      //    ⚠️ 所以「未登录」那一条分支**不能**顺手动 —— 它现在承担全部入口职责。
                      // ── 修改昵称：**从「第一行点击」搬来的**（能力保留，换了入口）──
                      _navTile(
                        icon: Icons.edit_outlined,
                        title: '修改昵称',
                        onTap: _editName,
                        bare: true,
                      ),
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(t.line.argb32)),
                      // ── 修改邮箱 ──
                      //
                      // 🔴 2026-09-29 语义变更：注册时就要求填邮箱
                      //    ⇒ 登录后**必然已有邮箱**，这一行从来不是「去绑定」。
                      // 🔴 2026-10-07 **已可修改**：后端加了
                      //    `/api/auth/change-email/code` + `/api/auth/change-email` 两步端点。
                      //    🔑 它是**敏感操作**（邮箱正是找回密码的收信地址）⇒ 要
                      //    「当前密码 + 发到新邮箱的验证码」两道凭据，见 `ChangeEmailDialog`。
                      // 🔴 2026-10-08 文案：`title` 由「邮箱地址」改为**动作名**（白哥：
                      //    「只要『修改邮箱』四个字」），`subtitle` 整条删掉。
                      //    当前邮箱改由 ① 的副标题显示（否则界面上看不到绑的是哪个）。
                      _navTile(
                        icon: Icons.mail_outline,
                        title: '修改邮箱',
                        onTap: _showChangeEmailDialog,
                        bare: true,
                      ),
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(t.line.argb32)),
                      // ── 修改密码 ──
                      //
                      // 🔴 为什么和「忘记密码」是两件事（都缺就都做）：
                      //   只有「忘记密码」⇒ 记得密码的人**改不了**；
                      //   只有「修改密码」⇒ 忘了密码的人**进不去**。
                      _navTile(
                        icon: Icons.lock_outline,
                        title: '修改密码',
                        onTap: _showChangePasswordDialog,
                        bare: true,
                      ),
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(t.line.argb32)),
                      // ── 退出账号 ──
                      //
                      // # 🔴 为什么在本组内（原先在「我的」页**最底部**）
                      //
                      // 它原先挂在页尾（「注销账号」正下方）。要看到它得**滚过六组**：
                      // 统计卡 → 账号 → 兴趣 → 记忆 → 订阅 → 其他 —— 真机上表现为
                      // **「App 里没有退出账号的入口」**（白哥 2026-10-08 原话）。
                      // 📌 判据：**「入口存在」≠「入口找得到」** —— 可发现性是入口的一部分。
                      //    同族：Apple 要求账号操作**显眼、别藏太深**（它只禁止
                      //    「仅靠邮件 / 客服才能操作」，不禁止放在设置区）。
                      //
                      // 🔑 与注销账号的关系：两项现在**同在下拉区**，靠**顺序**分工 ——
                      //    「退出」可逆（登出而已）在前，「注销」不可逆在**最末**
                      //    （理由见下面那一条）。两者语义完全不同、**不能互相替代**：
                      //    退出只清**本机**凭据 —— 学习记录在端侧 `user.db`、不受影响。
                      _navTile(
                        icon: Icons.logout,
                        title: '退出账号',
                        onTap: _confirmSignOut,
                        bare: true,
                      ),
                      Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(t.line.argb32)),
                      // ── 注销账号（**最末**：本组唯一不可逆的一项）──
                      //
                      // 🔴 2026-10-09 白哥：「注销账号也应该放进去」——
                      //    此前它在「我的」页**页尾**独立成一小块卡（本轮已删）。
                      //
                      // 🔑 为什么放**最末**：它上面那条「退出」是**可逆**的（登出而已），
                      //    而「注销」不可逆 —— 相邻两项里，不可逆的那个要离日常项最远。
                      //    列表是从上往下扫的 ⇒ 最末一项被误触的概率最低。
                      //    ⚠️ 顺序反过来（销毁在前、登出在后）会把两者都放错位置。
                      //
                      // 🔴 风险提示**不写在这一行**（下拉项一律只有动作名，白哥定）——
                      //    由**二次确认弹窗**承担，且那三条文案比一行小字完整得多：
                      //    ① 账号与云端数据永久删除 ② 本机学习数据（生词/复习/电子书）不受影响
                      //    ③ 不影响 Apple 订阅（要退订得去 Apple ID 设置）
                      //    ⇒ 见 `_showDeleteAccountDialog`。**不要**因为少了这行小字
                      //      就以为「警示不够」而把它加回来（那会破坏下拉的统一形态）。
                      //
                      // ✅ 合规：Apple 5.1.1(v) 要求「**App 内**能自助注销」（禁止只留邮件/客服），
                      //    **不禁止**要点两下才到 ⇒ 收进下拉仍满足。
                      //    `verify_iap_plan` 的断言查的就是「『我的』页里有这个入口」，
                      //    **与它在页面的哪个位置无关** ⇒ 搬迁不会让它变红（这是对的：位置不是契约）。
                      //
                      // ⚠️ **「注销」≠「退出」**（不能互相替代）：
                      //    注销会删**服务端**账号；退出只清本机凭据。
                      _navTile(
                        icon: Icons.delete_forever_outlined,
                        title: '注销账号',
                        onTap: _showDeleteAccountDialog,
                        bare: true,
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// 打开「修改密码」弹层；成功则提示。
  ///
  /// 🔑 toast 放在**这里**而不是弹层内部：弹层关闭的瞬间它自己的 `context`
  ///    已失效，若在里面弹 toast 会跟着一起消失（判据：**时序：等条件成立**）。
  Future<void> _showChangePasswordDialog() async {
    final ok = await ChangePasswordDialog.show(context);
    if (ok != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      // 文案用「已修改」（**状态**）而不是「修改成功」（系统播报口吻）——
      // 与既有提示的语感一致。
      SnackBar(content: Tw('密码已修改')),
    );
  }

  /// 通用行：图标（或头像）+ 标题 + 副标题 + 右箭头。
  ///
  /// [bare]：`true` = **自身不带外壳**（父层已是 `Clay` 分组容器）；
  /// `false` = 自己套一个 `Clay`（用于单行成卡的场景）。
  /// 🔑 这个参数存在的理由：分组内外两种用法都要同一套内部版式 ——
  ///    若各写一份，两处的字号/间距迟早会漂。
  Widget _navTile({
    required IconData icon,
    required String title,
    String? subtitle,
    bool showAvatar = false,
    VoidCallback? onTap,
    bool bare = false,
    Widget? trailing,
  }) {
    final t = CoEvoTokensExt.of(context);

    final row = Padding(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      child: Row(
        children: [
          if (showAvatar)
            // 🔑 头像**单独可点**（= 换头像），与整行点击（**展开 / 收起**）**分开**。
            //    ⚠️ 改造时差点漏掉：只把整行 `onTap` 设成 `_editName`，
            //      头像的 `_uploadAvatar` 就**没有调用点**了
            //      （功能静默消失 —— 编译器不会报，因为「没人用」不是错误）。
            //    🔴 2026-10-08 同一形状**又出现一次**（这次是 `_editName` 差点失去调用点）：
            //       整行 `onTap` 由「改昵称」改成「切换展开」时，必须把改昵称
            //       **搬进下拉区**（见 `_buildAccountGroup` ②）。
            //       📌 判据：**换一个整行的点击目标时，先查原来那个动作还有没有别处能触发** ——
            //          这个坑在这一个 widget 里已踩两次，不是偶发。
            GestureDetector(
              onTap: _uploadAvatar,
              child: CircleAvatar(
                radius: 16,
                backgroundColor: Color(t.accent.argb32).withValues(alpha: 0.12),
                backgroundImage:
                    _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                child: _isUploading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : (_avatarUrl == null
                        ? Icon(Icons.person,
                            size: 18, color: Color(t.accent.argb32))
                        : null),
              ),
            )
          else
            SizedBox(
              width: 21,
              child: Icon(icon, size: 17, color: Color(t.ink3.argb32)),
            ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(t.ink.argb32),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    // 🔴 2026-10-08：副标题现在可能承载**邮箱地址**（账号状态行）——
                    //    没有 `maxLines` 时它会**折成两行**（`Expanded` 里宽度受限但高度不限），
                    //    把行高撑起来、与相邻行对不齐。截断比折行好：
                    //    完整值在「修改邮箱」弹层里仍然可用。
                    // 📌 判据：**可变的、用户产生的文本进布局时要给上界**
                    //    （同「界面换算值须与判定层核对」那一族：长内容不能撑破版式）。
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 🔑 [trailing] 用于「行尾不是箭头」的场景（如订阅行的「续费」按钮）；
          //    不传时给默认的 `chevron_right`（导航行语义）。
          if (trailing != null)
            trailing
          else
            Icon(Icons.chevron_right, size: 18, color: Color(t.ink3.argb32)),
        ],
      ),
    );

    if (bare) {
      return InkWell(onTap: onTap, child: row);
    }
    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: row,
    );
  }

  /// 「记忆」分组：**默写准确率**（滑动条）。
  ///
  /// # 🔴 为什么这个设置存在（而不是我替用户定一个数）
  ///
  /// 划线卡的复习是**默写**（白哥 2026-10-07 定「考默写，和单词一样」），
  /// 判据是「**错词比例**」。但「多准算记住」本来就不是一个客观正确的数字 ——
  /// 它是**用户对自己要求的差别**：有人要逐字不差，有人抓到大意就够。
  /// ⇒ **交还给用户**，而不是我猜死一个阈值。
  ///
  /// # 🔑 显示「最多错几个」，而不是「15%」
  ///
  /// 「15%」用户看不懂；「**20 个词的句子最多错 3 个**」他立刻懂。
  /// 而且数字是**实时算**的（`maxWrongWordsFor`）—— 不是写死的文案：
  /// 写死的话，将来改了判定口径，设置页的说明会与判定**静默不符**。
  /// 📌 先例：复习结果页的「下次复习：X 天」同样是实算值。
  ///
  /// # 🔴 作用范围必须写明（不是可选的提示）
  ///
  /// **只影响划线卡的默写**。单词卡的答案是**唯一**的（`scale` 就是 `scale`），
  /// 「多准算对」在它上面**没有意义** —— 拼错一个字母就是拼错了。
  /// ⚠️ 不写这句，用户会以为它把所有判定都放宽了
  /// （而如果真去放宽单词卡，**复习信号就被弄脏了**）。
  ///
  /// # ⚠️ 刻度用 5% 步进（`divisions: 6`）
  ///
  /// 1% 的差别在判定上**没有意义**（20 词的句子错 1 个就是 5%），
  /// 而 30 档会让轨道上挤满刻度线。
  /// 📌 **真机目视**：`Slider` 的默认内边距可能让两端与卡片边缘不齐 ——
  /// 本机验不了渲染，看到不齐再套 `SliderTheme` 收窄。
  Widget _buildMemoryTile() {
    final t = CoEvoTokensExt.of(context);
    final v = ref.watch(memorySettingsProvider).maxWrongPercent;

    // 🔑 实时算「这意味着什么」—— 两个长度各给一个具体后果
    final longAllow = maxWrongWordsFor(expectedWords: 20, percent: v);
    final shortAllow = maxWrongWordsFor(expectedWords: 7, percent: v);

    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 14, 15, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 21,
                  child: Icon(Icons.spellcheck,
                      size: 17, color: Color(t.ink3.argb32)),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    '默写准确率',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                ),
                // 🔑 当前值放**行尾**（同 `_navTile` 的副标题位置）——
                //    不新造版式，本页所有「标题 + 值」都是这个布局
                Text(
                  '$v%',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Padding(
              // 与标题文字左对齐（图标 21 + 间距 11）
              padding: const EdgeInsets.only(left: 32),
              child: Text(
                '只影响划线记忆的默写 · 单词卡的拼写判定不受影响',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11.5,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
            Slider(
              value: v.toDouble(),
              min: kMemoryMaxWrongPercentMin.toDouble(),
              max: kMemoryMaxWrongPercentMax.toDouble(),
              divisions: 6, // ⇒ 步进 5%（0/5/10/15/20/25/30）
              label: '$v%',
              // 🔑 拖一次可能写库数次 —— 可接受：provider 在「值没变」时提前返回，
              //    且步进是 5% ⇒ 一次拖动最多落几个档。
              //    📌 不为它单开一条「松手才存」的路径：那会让「写端」有两处
              //    （判据：同一件事的口径只能一处权威）。
              onChanged: (x) =>
                  ref.read(memorySettingsProvider.notifier).setMaxWrongPercent(x),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 8, bottom: 10),
              child: Text(
                '当前标准：20 个词的句子最多错 $longAllow 个 · '
                '7 个词的短句最多错 $shortAllow 个',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 11.5,
                  height: 1.5,
                  color: Color(t.ink2.argb32),
                ),
              ),
            ),
            // 🆕 v1.12（2026-10-11）批量补译入口。
            //
            // # 🔑 为什么放在「记忆」这张卡里
            // · **语义归属**：它补的是**划线卡默写的提示**（译文）⇒ 属于「记忆」
            // · **常驻成本**：低频（一次性补齐历史划线）⇒ 进设置页、不占主界面
            //   判据：「控件放哪」两维度缺一不可 —— 只按语义归属会把它塞进复习页。
            //
            // # ⚠️ 为什么不做成「划线时自动翻译」
            // 翻译是**订阅权益**（免费 10 次/月）⇒ 自动翻译会让成本随划线量线性增长。
            // 做成**用户显式的一次性动作**，成本可见可控。详见 `highlight_translate_provider.dart`。
            _buildBackfillRow(t),
          ],
        ),
      ),
    );
  }

  /// 「补全划线译文」那一行 —— 标题 + 右侧动作（`N 条` 与「补全」）。
  ///
  /// 🔑 三种形态**互斥**且都由真实状态驱动：
  /// | 状态 | 显示 |
  /// |---|---|
  /// | 正在补 | 进度 `3/12` + 转圈，**不可点**（防重复触发） |
  /// | 还有 N 条 | `还有 N 条划线没有译文` + 可点的「补全」 |
  /// | 已补全 | `划线译文已补全`（**不可点** —— 没有可做的事就不给按钮） |
  Widget _buildBackfillRow(CoEvoTokens t) {
    final pendingAsync = ref.watch(highlightTranslationPendingCountProvider);
    final count = pendingAsync.valueOrNull ?? 0;
    final busy = _backfillRunning;

    final label = busy
        ? '正在补译 ${_backfillDone}/${_backfillTotal}…'
        : (count == 0 ? '划线译文已补全' : '还有 $count 条划线没有译文');

    return Padding(
      padding: const EdgeInsets.only(left: 32, right: 8, bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 11.5,
                color: Color(t.ink3.argb32),
              ),
            ),
          ),
          if (busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: Color(t.accent.argb32),
              ),
            )
          else if (count > 0)
            // ⚠️ 只有**真的有事可做**时才给可点文字 ——
            //    「没有可做的事」还画一个按钮，是让用户白点一次（本项目「有动作、无出口」的反面）
            GestureDetector(
              onTap: _runBackfill,
              behavior: HitTestBehavior.opaque,
              child: Text(
                '补全',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(t.accent.argb32),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 跑一次「批量补译」，并把结果**如实**告诉用户。
  ///
  /// 🔴 三种结局必须分开说（不能都收成「完成了」）：
  ///   ① 全补完 ② **额度用尽中断**（说清补了几条 + 什么时候恢复）
  ///   ③ 部分失败（说清成功/失败各几条）
  Future<void> _runBackfill() async {
    if (_backfillRunning) return;
    // 🔑 先取 messenger（异步之后 `context` 可能已失效）
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _backfillRunning = true;
      _backfillDone = 0;
      _backfillTotal = 0;
    });

    try {
      final r = await backfillHighlightTranslations(
        ref,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _backfillDone = done;
              _backfillTotal = total;
            });
          }
        },
      );

      final msg = r.nothingToDo
          ? '没有需要补译的划线'
          : r.stopped
              ? '已补 ${r.ok} 条后停止：${r.stopMessage}'
              : (r.failed > 0
                  ? '补译结束：成功 ${r.ok} 条 · 失败 ${r.failed} 条（可再点一次重试）'
                  : '已补全 ${r.ok} 条划线译文');

      messenger.showSnackBar(SnackBar(content: Text(msg)));
      // 计数重算（否则那一行还停在旧数字）
      ref.invalidate(highlightTranslationPendingCountProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('补译失败：$e')));
    } finally {
      if (mounted) {
        setState(() {
          _backfillRunning = false;
          _backfillDone = 0;
          _backfillTotal = 0;
        });
      }
    }
  }

  /// 退出前二次确认。
  ///
  /// 🔴 2026-10-08：入口**已从页尾移进「账号」组**（见 `_buildAccountGroup`）——
  ///    原先那个「页尾独立项」的 `_buildSignOutTile` 因此成了死代码，已删除。
  ///    🔑 版式随之改用组内统一的 `_navTile`：它**同样带文字**
  ///       （Apple 要求账号操作可见，一个没有文字的图标不合格），
  ///       但不再自造第六种行样式（判据：**同类元素共享版式**）。
  ///
  /// 🔑 必须确认：退出会清掉本地凭证（下次要重新登录）——
  ///    不可逆且用户可能误触，属于「该拦一下」的操作。
  Future<void> _confirmSignOut() async {
    final t = CoEvoTokensExt.of(context);
    final ok = await CoDialog.show<bool>(
      context,
      builder: (ctx) => CoDialog(
        title: '退出账号',
        actions: [
          // 🔑 「取消」= 次按钮（`sunken` 暗底，不抢视线）·「退出」= 主按钮。
          //    破坏性动作给**唯一的强调色按钮** —— 让「点错」的可能性降到最低
          //    （两个按钮同权重时，误触概率取决于手指落点）。
          ClayButton(
            label: '取消',
            variant: ClayButtonVariant.secondary,
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(false),
          ),
          ClayButton(
            label: '退出',
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
        child: Tw(
          // 🆕 2026-10-06：原文案只说「保存在本机」——
          //    云端同步上线后它**不完整**了（同步过的数据在服务端也有一份，
          //    且退出登录**不会**删除它）。按「声明要与配置一致」补齐。
          //
          // 🆕 2026-10-09（**归属账号**）：再补最后一句。
          //    本机数据是**账号维度**（`local_data_owner.dart`）⇒ 用**别的账号**登录时
          //    本机数据会被清空。这是**不可逆**的（旧账号若从未同步过，云端没有副本），
          //    所以必须在**用户做决定的这一刻**说清 ——
          //    判据：**「后果不可见 + 恢复路径远」的动作要在决策点告知**
          //    （等换账号时再提示已经晚了：那时凭据已换、数据已走）。
          '退出后将清除本机登录状态。你的学习记录仍保留在本机；'
          '已同步到云端的数据也仍保留，重新登录后可继续同步。\n'
          '⚠️ 若改用其它账号登录，本机学习数据会被清空'
          '（本机数据只属于一个账号）。',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 12.5,
            height: 1.7,
            color: Color(t.ink3.argb32),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // 🔴 **先 flush 再 logout**（设计 §4.5）—— 清凭据前把「本地写了但还没推」的
    //    数据送上去。否则那批数据要等**下次登录**才上去，而用户可能不再登录
    //    （或换账号 ⇒ 那批数据永久留在这台机器上）。
    //    ⚠️ 失败**不阻止登出** —— 把用户困在账号里比丢几个待推数据更糟
    //    （`flushBeforeLogout` 内部已把异常收敛成日志）。
    await flushBeforeLogout(ref);
    await ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/');
  }

  /// 打开**登录 / 注册弹窗** —— 全应用唯一的账号入口。
  ///
  /// 🔴 2026-09-29 接回：此前三处（账号行 / 订阅卡整块 / 订阅卡「查看」按钮）
  ///    都指向 `_comingSoon('登录')`（点开提示「即将开放」）。根因是重排那批
  ///    把「trial 认领弹窗」当作旧功能删掉了 —— 而**它同时也是登录的唯一入口**。
  ///    📄 详见 [AuthDialog] 的类文档 · 判据：「删一个元素前先查它还承担什么职责」。
  ///
  /// 🔑 登录成功后**不必**在这里刷数据：`initState` 的 `listenManual` 已监听
  ///    「未登录 → 已登录」并调用 `_load()`（一处权威，别写两遍）。
  void _showLoginDialog() {
    AuthDialog.show(context);
  }

  /// 打开「修改邮箱」弹层；成功则提示。
  ///
  /// 🔑 toast 放在**这里**而不是弹层内部：弹层关闭的瞬间它自己的 `context`
  ///    已失效，若在里面弹 toast 会跟着一起消失
  ///    （判据：**时序 —— 等条件成立**；与 `_showChangePasswordDialog` 同一处理）。
  ///
  /// 🔑 界面上的邮箱**不需要**在这里手动刷新：弹层的第 2 步成功后，
  ///    `AuthProvider.changeEmail` 已把新邮箱写回 `state`（订阅者自动重建）。
  ///    ⚠️ 若将来有人把那段写回删掉，这里就必须自己补上 ——
  ///    否则出现「提示说改成功了，而页面上还是旧邮箱」。
  Future<void> _showChangeEmailDialog() async {
    final updated = await ChangeEmailDialog.show(context);
    if (updated == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      // 文案用「已修改」（**状态**）而不是「修改成功」（系统播报口吻）——
      // 与「密码已修改」的语感一致。
      SnackBar(content: Tw('邮箱已修改')),
    );
  }

  @override
  void dispose() {
    _authSub?.close();
    super.dispose();
  }

  /// 主题入口 —— **三档底色**（墨 / 格 / 夜）+「跟随系统」开关（spec §二）。
  ///
  /// 🔑 「跟随系统」是**开关不是第四个主题**：浅色环境用所选档，深色环境用「夜」。
  Widget _buildThemeTile() {
    final settings = ref.watch(themeProvider);
    final tokens = allTokens[settings.theme]!;
    final label = settings.followSystem
        ? '${tokens.label} · 跟随系统'
        : '${tokens.label} · ${tokens.character}';

    // 🔑 用统一的 `_navTile`（而不是各写一个 `Card + ListTile`）——
    //    原来主题/订阅/联系三张卡是**三份独立实现**，图标大小（默认 24 / 22）、
    //    标题字号（默认 16 / 14）、间距各不相同 → 这正是「**看起来乱**」的来源之一。
    //    ⚠️ 判据：**同类元素共享版式**，别让每个都自己长一副样子。
    return _navTile(
      icon: _themeIcon(settings.theme),
      title: '主题',
      subtitle: label,
      onTap: _showThemeDialog,
    );
  }

  static IconData _themeIcon(ReadingTheme theme) => switch (theme) {
        ReadingTheme.ink => Icons.menu_book_outlined,
        ReadingTheme.grid => Icons.grid_on,
        ReadingTheme.night => Icons.dark_mode_outlined,
      };

  Future<void> _showThemeDialog() async {
    final notifier = ref.read(themeProvider.notifier);

    await CoDialog.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 每次重建都重新读 —— 切档要即时看到选中态
          final settings = ref.read(themeProvider);
          final t = CoEvoTokensExt.of(ctx);
          return CoDialog(
            title: '选择主题',
            actions: [
              ClayButton(
                label: '关闭',
                variant: ClayButtonVariant.secondary,
                expanded: true,
                onTap: () => Navigator.of(ctx).pop(),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final theme in ReadingTheme.values)
                  _themeOption(
                    theme,
                    selected: settings.theme == theme,
                    onTap: () async {
                      await notifier.setTheme(theme);
                      if (ctx.mounted) setDialogState(() {});
                    },
                  ),
                // 分隔线属 spec §6.3 的「平面」类（不是粘土元素）→ 用 Material
                // `Divider` 是**对的**，只是颜色必须走 token：
                // 裸 `Divider` 的默认色来自 Material 色板，会在「格」档下与页面其它线不同源。
                Divider(height: 1, thickness: 1, color: Color(t.line.argb32)),
                Padding(
                  padding: const EdgeInsets.only(top: CoSpacing.sm),
                  child: Row(
                    children: [
                      Icon(Icons.brightness_auto,
                          size: 20, color: Color(t.accent.argb32)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tw(
                              '跟随系统',
                              style: TextStyle(
                                fontFamily: CoFonts.uiSans,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(t.ink.argb32),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Tw(
                              '深色时自动切到「夜」',
                              style: TextStyle(
                                fontFamily: CoFonts.uiSans,
                                fontSize: 11.5,
                                color: Color(t.ink3.argb32),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 🔑 **保留** Material `Switch` 本体：规格未定义「开关」的粘土形态，
                      //    这里不发明新控件（否则又多一种「本项目特有的开关」）。
                      //    去掉的是 `SwitchListTile` 那层 **Material 外壳** ——
                      //    它自带 ListTile 的内边距 / 点击水波纹 / 高度约束，
                      //    与这一列「粘土选项行」不是一套语汇。
                      Switch(
                        value: settings.followSystem,
                        onChanged: (v) async {
                          await notifier.setFollowSystem(v);
                          if (ctx.mounted) setDialogState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单档预览 —— **用该档自己的 token 画一块粘土**（而不是当前主题的参数）。
  ///
  /// 🔑 这样「切换主题」是**所见即所得**：看到的就是那一档真实的 底 / 卡 / 强调色。
  /// 顺带让**粘土组件**（`Clay`）第一次出现在真实界面里：未选中 = 凸起，选中 = 选中态。
  Widget _themeOption(
    ReadingTheme theme, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final t = allTokens[theme]!;
    // 选中态填充 `accent` → 字用 `accentInk`；默认态填充 = 卡面色 → 字用 `ink`
    final fg = selected ? t.accentInk : t.ink;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CoSpacing.sm,
        vertical: CoSpacing.xs,
      ),
      child: Clay(
        // 🔴 必须传**目标档**的 token —— 否则预览块会跟着当前主题变，失去比较意义
        tokens: t,
        state: selected ? ClayState.selected : ClayState.raised,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: CoSpacing.lg,
          vertical: CoSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.label,
                    style: TextStyle(
                      color: Color(fg.argb32),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.character,
                    style: TextStyle(
                      color: Color(fg.scaleAlpha(0.72).argb32),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle, size: 20, color: Color(fg.argb32)),
          ],
        ),
      ),
    );
  }

  /// 订阅状态卡片。
  ///
  /// # 🔴 两态分流（2026-09-29 白哥复核后定）
  ///
  /// | 态 | 显示 | 依据 |
  /// |---|---|---|
  /// | **未登录** | 「**订阅完整版**」入口 + 「查看」按钮 → 引导登录 | `ui-ux` §4.4 判据 6（**不要藏起来**）· §4.4.4（未订阅显示入口）· §10.1.1（要付费时引导注册） |
  /// | 已登录 | 状态文案（按到期日分档）+ 「续费」按钮 | 原实现 |
  ///
  /// ⚠️ **未登录与「已登录但未订阅」原先不可区分** ——
  ///    两者都落到 `!isActivated` 分支，统一显示「未激活 — 请联系服务人员开通」。
  ///    对**未登录**用户这是**误导**（他会去找客服，其实只是没登录）。
  ///
  /// ✅ **2026-10-04 已完成（支付批次）**：原遗留的两句
  ///    「未激活 — 请联系服务人员**开通**」/「已到期 — 请联系服务人员**续费**」
  ///    是微信 Native 扫码支付时代的残留，**已随本轮 IAP 改造删除**：
  ///    · 状态判定改为**端侧 IAP**（`iapSnapshot`），不再看后端 `subscriptionProvider`
  ///      （端侧权威：离线可判、刚买完立刻生效，不等对账）
  ///    · 开通/续费由 Apple 自动处理 ⇒ **不再有「找服务人员」这一环**
  ///    · 已订阅时按钮变「管理」→ 跳 Apple 订阅管理（§4.4.4）
  Widget _buildSubscriptionCard(AuthState auth) {
    // ── 状态展示（**未登录也显示**）────────────────────────────────
    //
    // 🔴 2026-10-04（支付批次）：原为「未登录 → 引导登录」的独立分支，已合并。
    //    当时的理由是「**购买与恢复都不需要登录**（StoreKit 走 Apple ID）」
    //    ⇒ 未登录时只给「去登录」等于把购买路径堵死。
    //
    // 🔴🔴 2026-10-12（白哥定案「**订阅与账号一一绑定**」）：那条口径**已反转** ——
    //    订阅现在**必须先登录**（订阅页在点击购买/恢复时引导登录；
    //    服务层 `IapService.buy()` 另有硬拦截，见其注释）。
    //    ⚠️ 但**本卡片仍然未登录也显示**，这不是遗漏 ——
    //      它只是「状态 + 入口」，未登录用户点「升级」进订阅页后**会被引导登录**，
    //      路径没堵死；卡片本身不是购买入口，无需在这里再加一道登录墙。
    //    📌 判据：**登录墙加在「动作」上，不加在「状态展示」上**。
    //    ⇒ 状态仍按 `subscriptionActiveNow`（端侧 OR 服务端对账值）展示。

    // ── 状态判定：**端侧 IAP 为权威** ──────────────────────────────
    //
    // 🔴 2026-10-04（支付批次）判定源变更：后端 `subscriptionProvider`
    //    → **端侧 `iapSnapshot`**。三条理由：
    //      ① **离线可用** —— 后端记录拿不到时不该显示「未订阅」
    //      ② **刚买完立刻生效** —— 不等 `/api/iap/verify` 对账回来
    //      ③ 与产品原则一致：端侧是权益判据，后端只作对账留档
    //    ⚠️ 删掉的两句「未激活 — 请联系服务人员**开通**」/「已到期 — 请联系服务人员**续费**」
    //       是**微信 Native 扫码时代**的残留（原注释已标注「待支付批次改」）——
    //       IAP 下开通/续费都由 Apple 自动处理，**没有「找服务人员」这一环**。
    //
    // 🔴 2026-10-09：状态来源由「纯端侧 `snap.isActive`」改为**全库唯一判据**
    //    `subscriptionActiveNow`（端侧 **或** 服务端对账值）。
    //    理由见 `iap_plan.subscriptionActive` 的文档：端侧是**权威**但不是**独占** ——
    //    安卓没有 StoreKit、后台授予的订阅端侧也无从知道，只看端侧就会出现
    //    「服务端明明有效，界面显示未订阅」（白哥 2026-10-09 真机）。
    final snap = iapSnapshotOf(ref);
    final bool isActivated = subscriptionActiveNow(ref);

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (isActivated) {
      // 🔑 到期日走全库唯一换算点（端侧精确时刻优先 → 退回服务端对账值）
      final expiry = subscriptionExpiryLabel(
        iapExpiresAtUtc: snap.expiresAtUtc,
        backendExpiresAt: ref.watch(subscriptionProvider).expiresAt,
      );
      statusText = expiry == null ? '订阅中' : '订阅中 · 到期日 $expiry';
      statusColor = _cs.primary;
      statusIcon = Icons.verified;
    } else if (subscriptionLapsedNow(ref, snap)) {
      // 🔑 到期**不没收资产**（§4.4.4）—— 文案只说「续订后继续」，
      //    不说「已锁定」（生词仍可读可复习；到期后少的是同步/云端书架/翻译额度）
      statusText = '会员已到期 · 续订后继续';
      statusColor = _cs.error;
      statusIcon = Icons.lock_clock;
    } else {
      // 🔑 价值主张要具体（§4.4.1 判据 3）—— 不写「解锁全部功能」。
      //
      // 🔴 2026-10-09 修掉一句**虚假陈述**：原文案是
      //    「无限生词本 · 文章朗读」—— 这两个能力**早已免费**
      //    （2026-10-01 取消生词上限；朗读已免费全量，见 `iap_plan.benefits` 的留档表），
      //    把它们说成订阅权益是**方向相反的错**（不是漏写，是错写）。
      //    ⇒ 改为引用 `SubscriptionLegalText.shortPitch()`（与权益清单同源，
      //      断言锁着「短标语里的每一项都能在 benefits 里找到」）。
      statusText = SubscriptionLegalText.shortPitch();
      statusColor = _cs.tertiary;
      statusIcon = Icons.workspace_premium_outlined;
    }

    // 🔑 只换**外壳**（`Card` → `Clay`），内部保持原样 ——
    //    本行有**状态色**（即将到期用 tertiary）和尾部按钮，与标准导航行不同构，
    //    硬套 `_navTile` 反而要为它加两个只为它存在的参数。
    //    ⚠️ 判据：**统一的是外壳与层级，不是把每个都压成同一个组件。**
    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      // 整行进订阅页（便利区）；右侧按钮是**同一个动作**的显式 CTA
      onTap: () => context.push('/subscribe'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
        child: Row(
          children: [
            Icon(statusIcon, color: statusColor, size: 19),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('订阅状态',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(CoEvoTokensExt.of(context).ink.argb32),
                      )),
                  const SizedBox(height: 2),
                  Text(statusText,
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 11.5,
                        color: statusColor,
                      )),
                ],
              ),
            ),
            // 🆕 2026-10-09：云端同步的**云朵状态标**。
            //    🔴 它**不在这张卡上** —— 白哥同日定：「还是在我的里弄个独立的胶囊吧」。
            //       原先是把一枚图标**贴在**这行里（副标题右侧、按钮左侧）；
            //       贴着会被读成「订阅状态的一部分」，而且图标形态说不出「上次同步是几点」。
            //    ⇒ 现在它是**独立胶囊**，挂在「订阅」组内、本卡**下方**
            //       （见 `_groupLabel('订阅')` 那一段的 `SyncCloudChip`）。
            //       📌 判据：**控件放哪 = 语义归属 × 常驻成本** —— 语义上它属于「订阅」组，
            //          但它不是这张卡的一个字段（那张卡说的是「你订了什么」，
            //          胶囊说的是「云端数据走到哪了」）。
            // 🔑 用**粘土按钮**而非 Material `FilledButton.tonal` ——
            //    规格 §6.1 把「主/次按钮」列在**粘土**元素里。
            //    两者不是「换个皮肤」：Material 那套没有 `accentOut` 外阴影、
            //    没有内暗/内亮，按下反馈也不同源（水波纹 vs `scale(.97)`）。
            //    见 `widgets/clay_button.dart` 的类文档。
            // ⚠️ 与本行的整行 `onTap` **同一个动作**（都开订阅弹层）——
            //    这是有意的：按钮是**可见的 CTA 提示**，整行点击是便利区。
            //
            // 🔑 **label 按状态切换**（原先硬编码「续费」）：
            //    未订阅时说「续费」是错的 —— 没订阅过，哪来的「续」？
            //    原型 ② 屏画的也是「升级」。→ 未激活/已到期 = 升级；有效 = 续费。
            ClayButton(
              // 🔑 已订阅 → 「管理」（跳 **Apple** 订阅管理，§4.4.4）；
              //    未订阅 → 「升级」（进我们自己的订阅页）
              label: isActivated ? '管理' : '升级',
              onTap: isActivated
                  ? _openAppleSubscriptions
                  : () => context.push('/subscribe'),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开 Apple 的订阅管理页（§4.4.4「已订阅 → 管理订阅」）。
  ///
  /// 🔑 取消 / 改档**由 Apple 提供**，我们不自建（既做不到也没权限）——
  ///    但**必须在界面上给出路径**（判例：「不是发了就行，要看得见、找得到、关得掉」）。
  Future<void> _openAppleSubscriptions() async {
    final uri = Uri.tryParse(kAppleManageSubscriptionsUrl);
    if (uri == null) return;
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (ok || !mounted) return;
    // 🔴 打开失败必须让用户看见（点了没反应 = 「静默失败 + 无出口」）
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接，请稍后重试')),
    );
  }

  /// 「恢复购买」—— §4.4.3 要求**两处**入口（订阅页 + 本页）。
  ///
  /// 🔴 恢复的是 **Apple ID 名下的交易**（StoreKit 那层与我们的账号无关），
  ///    但**我们的权益必须落到账号上** ⇒ 恢复前要求登录。
  ///
  /// 🔴🔴 2026-10-12（白哥定案「**订阅与账号一一绑定**」）：本条**已改口径** ——
  ///    原文写的是「未登录也**必须能用**（这是换设备/重装后找回的唯一途径）」。
  ///    现在：未登录 ⇒ **先引导登录，登录成功后自动继续恢复**（不再要求用户点第二次）。
  ///    ⚠️ Apple 3.1.1 要求的是「**提供恢复购买入口**」—— 入口仍在、可见、点了能走完，
  ///       只是中间多一步登录 ⇒ 仍然符合要求。
  ///    📌 必须与订阅页 `subscribe_screen._restore` **同一套行为**（两处一致）。
  Future<void> _restorePurchases() async {
    if (!ref.read(authProvider).isAuthenticated) {
      final ok = await AuthDialog.show(context);
      if (!mounted) return;
      if (ok != true || !ref.read(authProvider).isAuthenticated) return;
    }
    final outcome = await ref.read(iapServiceProvider).restore();
    if (!mounted) return;
    final msg = switch (outcome) {
      RestoreOutcome.restored => '已恢复订阅',
      RestoreOutcome.notFound => '未找到订阅记录',
      RestoreOutcome.failed => '恢复购买失败，请稍后重试',
      RestoreOutcome.unavailable => '当前无法连接 App Store',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ══════════════════════════════════════════════════════════════════════
  // 注销账号（Apple 5.1.1(v)：支持注册的 App **必须**能 App 内自助注销）
  // ══════════════════════════════════════════════════════════════════════

  /// 二次确认 → 执行注销。
  ///
  /// 🔴 **为什么必须二次确认**（Apple 明确允许且推荐）：
  ///    注销**不可逆**。Apple 的规定是「不得要求用户发邮件/打电话」，
  ///    **但**「may include confirmation steps to prevent users from accidentally
  ///    deleting their account」—— 确认步骤是允许的，也是这里唯一的安全网。
  Future<void> _showDeleteAccountDialog() async {
    if (_deletingAccount) return; // 防重入

    final t = CoEvoTokensExt.of(context);
    final confirmed = await CoDialog.show<bool>(
      context,
      builder: (ctx) => CoDialog(
        title: '注销账号',
        actions: [
          ClayButton(
            label: '取消',
            variant: ClayButtonVariant.secondary,
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(false),
          ),
          ClayButton(
            label: '确认注销',
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🔴 三条必须说清的（顺序＝用户最该先知道的）
            //
            // ⚠️ 文案**不用 `**粗体**`**：`Tw` 是否解析 markdown 未确认
            //    ⇒ 万一不解析，页面上会**原样显示星号**（比不加粗更糟）。
            //    重点靠**图标颜色 + 位置（第一条）**传达。
            _deleteDialogLine(
              t,
              icon: Icons.warning_amber_rounded,
              // 最关键的一条放第一行
              text: '账号与云端数据（邮箱、密码、订阅记录）将被永久删除，无法恢复。',
              emphasize: true,
            ),
            const SizedBox(height: CoSpacing.md),
            _deleteDialogLine(
              t,
              icon: Icons.phone_iphone,
              // 🔑 与《用户协议》§三.5 的措辞一致 ——
              //    不写清这一条，用户会以为生词也一起没了（那是不必要的流失）
              //
              // 🆕 2026-10-09（**归属账号**）：补后半句。
              //    本机数据现在**属于账号**（`local_data_owner.dart`）⇒
              //    「注销不会删本机数据」这句仍成立，但**再用别的账号登录会清空它** ——
              //    不写出来，用户注销后注册新号会发现数据没了，而**那时才被告知**已经晚了。
              //    📌 判据同登出弹窗：**后果不可见 + 恢复路径远 ⇒ 在决策点告知**。
              text: '你设备上的学习数据（生词、复习记录、已导入的电子书）不会被删除；'
                  '但若改用其它账号登录，本机学习数据会被清空（本机数据只属于一个账号）。',
            ),
            const SizedBox(height: CoSpacing.md),
            _deleteDialogLine(
              t,
              icon: Icons.credit_card,
              // ⚠️ 必须说 —— 否则用户会以为「注销 = 退订/退款」
              text: '注销不会自动取消订阅。如需取消，请在 Apple ID 设置的「订阅」中操作。',
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    await _doDeleteAccount();
  }

  /// 弹层里的一行说明（图标 + 文字）。
  ///
  /// ⚠️ 用 `Tw`（Twemoji 渲染）而非裸 `Text` —— 与「我的」页其它文案一致；
  ///    且 `**粗体**` 由它统一处理，不必在这里手写 RichText。
  Widget _deleteDialogLine(
    CoEvoTokens t, {
    required IconData icon,
    required String text,
    bool emphasize = false,
  }) {
    // ⚠️ 用 ColorScheme 的 error（**不是** tokens）——
    //    `CoEvoTokens` **没有** `danger` 字段（初版凭印象写了 `t.danger`，编译会挂）。
    //    「危险提示用 error 色」也正是 Material 语义槽的用途。
    final danger = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            icon,
            size: 16,
            color: emphasize ? danger : Color(t.ink3.argb32),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Tw(
            text,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              height: 1.5,
              color: Color(emphasize ? t.ink.argb32 : t.ink2.argb32),
            ),
          ),
        ),
      ],
    );
  }

  /// 真正执行注销。
  ///
  /// # 🔴 失败时**必须说清「账号还在」**
  ///
  /// 服务端是事务的（失败即回滚 ⇒ 账号未删），所以失败时**不能**让用户以为
  /// 「可能删了一半」。文案写「注销未完成，账号未被删除」——
  /// 这正是本项目判据「**「静默失败 + 无出口」比「报错」更糟**」的应用。
  Future<void> _doDeleteAccount() async {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    setState(() => _deletingAccount = true);
    String? error;
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/user/me/delete'),
        // 🔴 **不传 uid** —— 服务端只认 token 里的身份
        //    （见 `user_purge::resolve_uid_from_token`）。
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        error = '注销未完成，账号未被删除（服务端返回 ${resp.statusCode}）';
      }
    } catch (_) {
      error = '注销未完成，账号未被删除（网络异常）';
    }

    if (!mounted) {
      return;
    }

    if (error != null) {
      setState(() => _deletingAccount = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    // ── 成功：清本地登录态 + 回首页 ──
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    setState(() => _deletingAccount = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('账号已注销')),
    );
    context.go('/home');
  }
}
