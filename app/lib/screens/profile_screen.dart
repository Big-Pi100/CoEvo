import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ⚠️ `flutter/rendering.dart` 与 `shade.dart` 的 `ImageFilter`/`BlurStyle` 同名冲突，
//    这里用 `as ui` 前缀限定 `dart:ui`（原先直接 import 两者会歧义）。
import 'package:flutter/rendering.dart';
import '../api/user_api_client.dart';
import '../api/api_config.dart';
import '../constants/app_info.dart';
import '../providers/auth_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/theme_provider.dart';
import '../services/tts_service.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../widgets/stats_card.dart';
import '../widgets/header_chip.dart';
import '../widgets/order_history.dart';
import '../widgets/subscribe_panel.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/tokens_ext.dart';
import '../theme/coevo_tokens.dart';
import '../pages/user/distribution/notification_panel.dart';
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
  String? _error;
  String? _avatarUrl;
  String _displayName = '';
  bool _isUploading = false;
  ProviderSubscription? _authSub;
  int _unreadCount = 0;

  // ── 🗑 2026-09-29 删除的状态（「我的」页重设计 · 白哥定）──
  // · `_hasShownClaimDialog` / `_realName` / `_phone` —— trial 认领与实名（已定不做）
  // · `_referralCode` / `_qrKey` / `_referralStats` / `_statsLoading` —— 分销（`ui-ux` §4.2 定「删分销」）
  // 🔑 只删「显示层」是不够的：名字/字段留着会被后来的人当成「还需要的功能」加回来
  //    （判据：「删掉一个功能后，要清理它的语义残留」）。
  //
  // ⚠️ 但**分享入口**保留 → `StatsCard` 仍需要推荐码来拼分享链接
  //    → `_referralCode` **保留**，且 `_loadReferralCode` 也保留（只取码，不取推广统计）。
  //    🔑 区分：**推荐码 = 分享链接的身份**（要留）；**推广统计/收益/提现 = 分销账本**（已删）。
  String? _referralCode;

  // TTS：2026-09-26 起只剩端侧 flutter_tts（腾讯云分支与引擎选择已取消）
  // 语速/音色由 `TtsService` 自持（`speechRate` / `selectedVoice`），本页不再另存状态

  @override
  void initState() {
    super.initState();
    _authSub = ref.listenManual(authProvider, (prev, next) {
      if (next.isAuthenticated && prev?.isAuthenticated == false && mounted) {
        _load();
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
        Uri.parse('${ApiConfig.baseUrl}/api/notifications?user_id=${auth.userId}'),
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
      // 异步加载推广数据
      _loadReferralCode();
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _error = '加载失败，请检查网络连接'; });
    }
  }

  Future<void> _uploadAvatar() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
    if (picked == null) return;

    setState(() => _isUploading = true);

    final uri = Uri.parse('${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer ${auth.token}';
    try {
      final bytes = await picked.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: 'avatar.png'));
      final streamed = await request.send().timeout(const Duration(seconds: 15));
      if (streamed.statusCode == 200 && mounted) {
        setState(() => _avatarUrl = '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar?t=${DateTime.now().millisecondsSinceEpoch}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('头像已更新'), duration: Duration(seconds: 2)),
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
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('修改昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入昵称'),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Tw('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Tw('保存'),
          ),
        ],
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
              SnackBar(content: Text('昵称同步失败: $e'), action: SnackBarAction(label: '重试', onPressed: () => _editName())),
            );
          }
        }
      }
      setState(() => _displayName = trimmed);
    }
  }

  /// 试听本地原生 TTS —— 用**当前选中的音色 + 当前语速**
  ///
  /// 设计要点（2026-09-26 修正）：
  /// - 🔴 **文本必须是英文**：本产品是英语学习 App，用户实际听到的永远是英文；
  ///   原先读「你好，这是试听语音」(zh-CN) 无法反映真实朗读效果。
  /// - ✅ **跟随语速**：`TtsService.speak` → `_speakWithNative` 每次都会
  ///   `setSpeechRate(_speechRate)`，因此自动跟随上方语速滑块。
  /// - 🔑 **复用 `TtsService`** 而非新建 `FlutterTts`：继承其音色选择（`_selectedVoice`）、
  ///   代检查（`_playGen`）与停止逻辑，避免出现两套播放状态。
  Future<void> _previewNativeTts() async {
    final tts = ref.read(ttsServiceProvider);
    await tts.speak(_nativePreviewText, language: 'en-US');
  }

  /// 本地音色试听文本（纯英文，贴近词卡朗读场景：先单词、后例句）
  static const String _nativePreviewText =
      'Hello. This is a sample sentence.';

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CoSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 48, color: _cs.outline),
            const SizedBox(height: CoSpacing.lg),
            Text('加载失败', style: _tt.titleLarge?.copyWith(color: _cs.onSurface)),
            const SizedBox(height: CoSpacing.sm),
            Text(_error ?? '请检查网络连接后重试', style: _tt.bodyMedium?.copyWith(color: _cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: CoSpacing.xl),
            FilledButton.icon(
              onPressed: () {
                setState(() { _isLoading = true; _error = null; });
                _load();
              },
              icon: const Icon(Icons.refresh),
              label: Tw('重新加载'),
            ),
          ],
        ),
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
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
                              _error = null;
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
  /// 副标题的用途是**让订阅状态在首屏可见**（与收藏页副标题同规格）。
  Widget _buildTopBar(AuthState auth) {
    final t = CoEvoTokensExt.of(context);
    final sub = ref.watch(subscriptionProvider);

    // 「白哥 · 免费版」—— 昵称 + 版本
    final version = sub.isActive ? '订阅版' : '免费版';
    final subtitle = '${_displayName.isEmpty ? '用户' : _displayName} · $version';

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
          const SizedBox(width: 12),
          // ── 通知入口（**保留** · 白哥 2026-09-29：「右上角的通知按钮保留」）──
          //
          // 🔑 用的是**现役公共组件 `HeaderChip`**（信息流右上角「收藏 N」、
          //    复习页「全部/已到期」**同一个**）—— 不是自创一个新样式。
          // ⚠️ 此前是 `AppBar.actions` 里的 `Badge + IconButton`；
          //    顶栏改成自绘后那里无处可放，本组件正好补位。
          // 🔑 `count: null`（未读为 0）= **不显示计数**（而不是显示「0」）。
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
      padding: const EdgeInsets.fromLTRB(
          CoSpacing.xxl, CoSpacing.sm, CoSpacing.xxl, CoSpacing.tabBarClearance),
      children: [
        // ── ① 顶部统计卡（三列：连续天数 / 掌握词数 / 阅读篇数 + 分享）──
        //    🔑 规格：「顶部：统计区 + 分享入口」。
        //    ⚠️ 「成就列表」（徽章行 / 进度条）按白哥 2026-09-29 决策**移出**本页
        //       → 它们在 `/achievements` 完整存在（本页只留一个入口，见 ④）。
        StatsCard(referralCode: _referralCode),
        const SizedBox(height: CoSpacing.xl),

        // ── ② 账号（未登录 / 已登录两态）──
        _groupLabel('账号'),
        _buildAccountGroup(auth),
        const SizedBox(height: CoSpacing.lg),

        // ── ③ 订阅 ──
        _groupLabel('订阅'),
        _buildSubscriptionCard(),
        const SizedBox(height: CoSpacing.sm),
        const OrderHistory(),
        const SizedBox(height: CoSpacing.lg),

        // ── ④ 其他 ──
        //    🔑 「我的成就」是**到成就墙的入口**（不是成就列表本身）。
        //      本页不再展示徽章/进度 —— 那两样都在 `/achievements`。
        _groupLabel('其他'),
        _buildThemeTile(),
        const SizedBox(height: CoSpacing.sm),
        _buildSpeechCard(),
        const SizedBox(height: CoSpacing.sm),
        _navTile(
          icon: Icons.emoji_events_outlined,
          title: '我的成就',
          subtitle: '查看全部成就与进度',
          onTap: () => context.push('/achievements'),
        ),
        const SizedBox(height: CoSpacing.sm),
        _buildContactCard(),
        const SizedBox(height: CoSpacing.sm),
        _navTile(
          icon: Icons.info_outline,
          title: '关于',
          subtitle: '版本 $kCoEvoVersion',
          onTap: () => context.push('/about'),
        ),
        const SizedBox(height: CoSpacing.xl),

        // ── ⑤ 退出账号 ──
        _buildSignOutTile(),
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
  /// # 🔴 本次只做 **UI 骨架**（白哥 2026-09-29 定）
  /// | 项 | 本次 | 说明 |
  /// |---|---|---|
  /// | 已登录：昵称（可改） | ✅ | 复用既有 `_editName` |
  /// | **绑定邮箱** | 🟠 **占位** | 点了提示「即将开放」—— 🔴 后端 `users` 表**连 `email` 列都没有** |
  /// | 未登录：引导行 | ✅ | 点了同样提示（登录页尚未做） |
  /// | Apple 登录 / 邮箱验证 / **注销** | ❌ | 后端 + SDK 全未做 → **独立一批**（方案 §6.4） |
  ///
  /// 🔑 为什么拆开：账号 UI 是**纯前端**（现有 `authProvider` 就够），
  ///    而 Apple/邮箱要**改后端 + 加 SDK + iOS Capability**。
  ///    混在一批会让「一个页面重排」膨胀成「认证系统改造」。
  Widget _buildAccountGroup(AuthState auth) {
    final t = CoEvoTokensExt.of(context);
    final radius = BorderRadius.circular(16);

    if (!auth.isAuthenticated) {
      return Clay(
        borderRadius: radius,
        padding: EdgeInsets.zero,
        child: _navTile(
          icon: Icons.person_outline,
          title: '未登录',
          subtitle: '登录后可跨设备同步 · 找回订阅',
          onTap: () => _comingSoon('登录'),
          bare: true,
        ),
      );
    }

    final trial = isTrialAccount(auth.username);
    return Clay(
      borderRadius: radius,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _navTile(
            icon: Icons.person_outline,
            title: _displayName.isEmpty ? '用户' : _displayName,
            subtitle: trial ? '已登录 · 试用账号' : '已登录',
            showAvatar: true,
            onTap: _editName,
            bare: true,
          ),
          Divider(height: 1, thickness: 1, color: Color(t.line.argb32)),
          _navTile(
            icon: Icons.mail_outline,
            title: '绑定邮箱',
            subtitle: '用于找回账号 · 跨设备同步',
            onTap: () => _comingSoon('绑定邮箱'),
            bare: true,
          ),
        ],
      ),
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
            // 🔑 头像**单独可点**（= 换头像），与整行点击（= 改昵称）**分开**。
            //    ⚠️ 改造时差点漏掉：只把整行 `onTap` 设成 `_editName`，
            //      头像的 `_uploadAvatar` 就**没有调用点**了
            //      （功能静默消失 —— 编译器不会报，因为「没人用」不是错误）。
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

  /// 退出账号（页尾独立项 · **带文字** + 二次确认）。
  ///
  /// 🔑 **为什么不放顶栏图标**：
  ///    ① 顶栏改用 `HeaderChip` 放通知后，原来的 `IconButton` 槽位没有了；
  ///    ② 更重要的是 —— **Apple 审核要求账号操作可见**（应用内需有账号通道）。
  ///       一个没有文字的图标不合格。
  /// ⚠️ **「退出」≠「注销」**：退出只清本地凭证（学习记录在端侧 `user.db`，不受影响）；
  ///    **注销要删服务端账号**（Apple 指南 5.1.1(v)）→ 需后端接口，属独立一批。
  Widget _buildSignOutTile() {
    final t = CoEvoTokensExt.of(context);
    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      onTap: _confirmSignOut,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Center(
          child: Text(
            '退出账号',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(t.accent.argb32),
            ),
          ),
        ),
      ),
    );
  }

  /// 退出前二次确认。
  ///
  /// 🔑 必须确认：退出会清掉本地凭证（下次要重新登录）——
  ///    不可逆且用户可能误触，属于「该拦一下」的操作。
  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('退出账号'),
        content: Tw('退出后将清除本机登录状态。'
            '你的学习记录（生词本 / 复习进度）保存在本机，不会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Tw('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Tw('退出'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/');
  }

  /// 「即将开放」提示。
  ///
  /// 🔑 占位入口**点了必须有反馈** —— 判据：
  ///    「**静默失败 + 无出口**」比报错更糟。一个点了没反应的入口，
  ///    用户只会以为 App 坏了。
  void _comingSoon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Tw('$what即将开放')),
    );
  }

  /// 朗读设置（外壳 `Clay`；**内容与改造前一致** · 决策 1：本次**不搬家**）。
  ///
  /// 🔑 「搬去阅读面板」的前提是**面板先存在** —— 而它尚未实现
  ///    （`reader_screen.dart` 明载「面板是独立一批」）。
  ///    所以现在这里仍是**唯一**入口 → 搬走 = 用户没地方调。
  Widget _buildSpeechCard() {
    final t = CoEvoTokensExt.of(context);
    return Consumer(
      builder: (_, ref, __) {
        final tts = ref.watch(ttsServiceProvider);
        final voices = tts.availableVoices;
        return Clay(
          borderRadius: BorderRadius.circular(16),
          padding: const EdgeInsets.all(CoSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('朗读设置',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(t.ink.argb32),
                  )),
              const Divider(height: 24),

              // ── 语速 ──
              Row(
                children: [
                  const Icon(Icons.speed, size: 18),
                  const SizedBox(width: CoSpacing.sm),
                  Text('语速', style: Theme.of(context).textTheme.bodyMedium),
                  const Spacer(),
                  Text(tts.speechRate.toStringAsFixed(1),
                      style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
                ],
              ),
              Slider(
                value: tts.speechRate,
                min: 0.1,
                max: 2.0,
                divisions: 19,
                label: tts.speechRate.toStringAsFixed(1),
                onChanged: (v) => tts.speechRate = v,
              ),
              const SizedBox(height: CoSpacing.sm),

              // ── 音色 ──
              Row(
                children: [
                  const Icon(Icons.record_voice_over, size: 18),
                  const SizedBox(width: CoSpacing.sm),
                  Text('音色', style: Theme.of(context).textTheme.bodyMedium),
                  const Spacer(),
                  // 🆕 显式试听按钮（2026-09-26 修正）——
                  // 原先只有「切换音色时自动读一句」，用户想重听必须来回切音色，不直观
                  SizedBox(
                    height: 32,
                    child: TextButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: Tw('试听', style: TextStyle(fontSize: 12)),
                      onPressed: () => _previewNativeTts(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CoSpacing.sm),
              DropdownButtonFormField<String>(
                value: tts.selectedVoice?['name'] as String?,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: CoSpacing.md, vertical: 10),
                  border: OutlineInputBorder(),
                ),
                // 🔴 原为「系统默认 (zh-CN)」—— 语义错误：本产品朗读英文，
                // 未指定音色时 `_pickBestVoice` 会按**文本语言**自动匹配（英文 → en-US）
                hint: Tw('系统默认（自动匹配语言）'),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Tw('系统默认（自动匹配语言）')),
                  if (voices.isNotEmpty)
                    ...voices.map<DropdownMenuItem<String>>((v) {
                      final name = v['name'] ?? '';
                      final locale = v['locale'] ?? '';
                      return DropdownMenuItem(
                        value: name as String,
                        child: Tw('$name ($locale)',
                            overflow: TextOverflow.ellipsis),
                      );
                    }),
                ],
                onChanged: (voiceName) {
                  if (voiceName == null || voiceName.isEmpty) {
                    tts.selectVoice(null);
                    return;
                  }
                  final match = voices
                      .cast<Map<String, dynamic>?>()
                      .firstWhere((v) => v?['name'] == voiceName,
                          orElse: () => null);
                  if (match != null) {
                    tts.selectVoice(match);
                    // 切换音色后自动试听（英文），方便立即对比
                    tts.speak(_nativePreviewText, language: 'en-US');
                  }
                },
              ),
            ],
          ),
        );
      },
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

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 每次重建都重新读 —— 切档要即时看到选中态
          final settings = ref.read(themeProvider);
          return SimpleDialog(
            title: Tw('选择主题'),
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
              const Divider(height: 1),
              SwitchListTile(
                value: settings.followSystem,
                secondary: Icon(Icons.brightness_auto,
                    color: Theme.of(context).colorScheme.primary),
                title: const Text('跟随系统',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('深色时自动切到「夜」', style: _tt.bodySmall!),
                onChanged: (v) async {
                  await notifier.setFollowSystem(v);
                  if (ctx.mounted) setDialogState(() {});
                },
              ),
            ],
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

  // ── 推荐码（**不是分销账本** —— 见 `_loadReferralCode` 内的说明）──
  Future<void> _loadReferralCode() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    try {
      final resp = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/referral/my-code?user_id=${auth.userId}'),
        headers: {'Authorization': 'Bearer ${auth.token}'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        // 🔑 **只取推荐码，不取推广统计** ——
        //    推荐码是「**分享链接的身份**」（`StatsCard` 的分享文案要用），
        //    而推广统计（邀请数 / 收益 / 提现）是**分销账本**，按 `ui-ux` §4.2 已删。
        //    🔑 这两件事以前写在同一个方法里，删的时候容易一起删掉 ——
        //       但「分享」还在（规格明确要），所以码必须留。
        _referralCode = data['referral_code'] as String?;
      }
    } catch (_) {}
  }

  /// 保存二维码图片到本地
  // ── 订阅状态卡片
  Widget _buildSubscriptionCard() {
    final sub = ref.watch(subscriptionProvider);
    final expiresStr = sub.expiresAt;
    final bool isActivated = expiresStr != null && expiresStr.isNotEmpty;
    final bool isExpired = sub.isExpired;

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (!isActivated) {
      statusText = '未激活 — 请联系服务人员开通';
      statusColor = _cs.tertiary;
      statusIcon = Icons.lock_outline;
    } else if (isExpired) {
      statusText = '已到期 — 请联系服务人员续费';
      statusColor = _cs.error;
      statusIcon = Icons.lock_clock;
    } else {
      final dt = expiresStr.contains('T')
          ? DateTime.tryParse(expiresStr)
          : DateTime.tryParse('${expiresStr.substring(0, 10)}T00:00:00Z');
      final expires = dt ?? DateTime.now().toUtc();
      final remaining = expires.difference(DateTime.now().toUtc());
      if (remaining.isNegative) {
        statusText = '已到期 — 请联系服务人员续费';
        statusColor = _cs.error;
        statusIcon = Icons.lock_clock;
      } else if (remaining.inDays > 30) {
        statusText = '有效 — 到期日: ${expiresStr.substring(0, 10)}';
        statusColor = _cs.primary;
        statusIcon = Icons.verified;
      } else if (remaining.inDays > 0) {
        statusText = '即将到期 — 剩余 ${remaining.inDays} 天';
        statusColor = _cs.tertiary;
        statusIcon = Icons.access_time;
      } else {
        final hours = remaining.inHours;
        statusText = hours > 0
            ? '即将到期 — 剩余 $hours 小时'
            : '即将到期 — 剩余 ${remaining.inMinutes} 分钟';
        statusColor = _cs.tertiary;
        statusIcon = Icons.access_time;
      }
    }

    // 🔑 只换**外壳**（`Card` → `Clay`），内部保持原样 ——
    //    本行有**状态色**（即将到期用 tertiary）和尾部按钮，与标准导航行不同构，
    //    硬套 `_navTile` 反而要为它加两个只为它存在的参数。
    //    ⚠️ 判据：**统一的是外壳与层级，不是把每个都压成同一个组件。**
    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      onTap: _showSubscribeDialog,
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
            FilledButton.tonal(
              onPressed: () => _showSubscribeDialog(),
              child: Tw('续费'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSubscribeDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('订阅套餐'),
        content: const SubscribePanel(),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Tw('关闭'),
          ),
        ],
      ),
    );
  }

  /// 联系工作人员
  Widget _buildContactCard() {
    return _navTile(
      icon: Icons.headset_mic_outlined,
      title: '联系工作人员',
      onTap: _showContactDialog,
    );
  }

  void _showContactDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('联系工作人员'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tw('扫码添加工作人员微信', style: TextStyle(fontSize: 13)),
            const SizedBox(height: CoSpacing.lg),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image(
                image: NetworkImage('${ApiConfig.baseUrl}/api/public/qrcode'),
                width: 200,
                height: 200,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.image_not_supported, size: 64, color: _cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Tw('关闭')),
        ],
      ),
    );
  }
}

