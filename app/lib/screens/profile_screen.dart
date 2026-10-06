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
import '../services/tts_service.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../widgets/stats_card.dart';
import '../widgets/header_chip.dart';
import '../widgets/claim_dialog.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/clay_button.dart';
import '../widgets/clay_field.dart';
import '../widgets/co_dialog.dart';
import '../widgets/interest_filter_section.dart';
import '../widgets/order_history.dart';
import '../theme/clay.dart';
import '../providers/sync_provider.dart';
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

  /// 正在注销（防重入 —— 用户连点入口会开出两个确认弹层）。
  bool _deletingAccount = false;
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
      //      · `_referralCode` → `StatsCard` 的分享文案会拼 `?ref=<码>`。
      //        不清 → 未登录用户分享出去的是**上一个登录用户的推荐码**
      //        （推荐码是「分享链接的身份」，`_loadReferralCode` 的注释原文）。
      //      · `_unreadCount` / `_avatarUrl` → 当前已随登录态隐藏，
      //        但留着会让「下次登录前的瞬间」显示旧值（闪烁）。
      //
      // 🔑 判据：**登录态是一组状态的所有者** —— 切换时该**整体复位**，
      //    而不是逐个等到「用到了才发现不对」。
      //    同族：`verification-rules` 的「资源所有权唯一」。
      if (!next.isAuthenticated && prev?.isAuthenticated == true) {
        setState(() {
          _unreadCount = 0;
          _referralCode = null;
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
      if (mounted)
        setState(() {
          _isLoading = false;
          _error = '加载失败，请检查网络连接';
        });
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
    //    在它的 `dispose()` 里释放（`ClaimDialog` 就是这个形态，它没有这个问题）。
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
  static const String _nativePreviewText = 'Hello. This is a sample sentence.';

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
            Text(_error ?? '请检查网络连接后重试',
                style: _tt.bodyMedium?.copyWith(color: _cs.onSurfaceVariant),
                textAlign: TextAlign.center),
            const SizedBox(height: CoSpacing.xl),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _error = null;
                });
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
    // 版本标签用**端侧状态**（与订阅卡同源 —— 两处口径必须一致，
    // 否则会出现「卡片说订阅中、副标题说免费版」这种自相矛盾）
    final version = versionLabel(iapSnapshotOf(ref).isActive);
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
        StatsCard(referralCode: _referralCode),
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

        // ── ④ 订阅 ──
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

        // ── ⑤ 其他 ──
        //    🔑 「我的成就」是**到成就墙的入口**（不是成就列表本身）。
        //      本页不再展示徽章/进度 —— 那两样都在 `/achievements`。
        //
        //    🔴 2026-09-29：「联系工作人员」**已移到「关于」页**（白哥定）。
        //      它属「关于本 App」那一族（与隐私政策/用户协议/版本/备案号同类），
        //      不是「高频操作」—— 放在这里会把「偶尔点」和「经常点」混在一起。
        //      📄 现由 `about_screen` 承载（含二维码弹窗）。
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
        _navTile(
          icon: Icons.info_outline,
          title: '关于',
          subtitle: '版本 $kCoEvoVersion',
          onTap: () => context.push('/about'),
        ),
        const SizedBox(height: CoSpacing.xl),

        // ── ⑥ 账号级操作（**仅已登录**）──
        //
        // 🔑 「注销账号」放在「退出账号」**正上方**：两者都是账号级操作，
        //    而注销**更重**（不可逆）—— 放在下面会显得「顺手就能点」。
        //    ⚠️ 但**不能藏起来**：Apple 明确要求「入口要显眼，别藏太深」
        //       （它只禁止「仅靠邮件/客服才能注销」，不禁止放在设置区）。
        //
        // 🔴 未登录无账号可注销 —— 与 `_buildSignOutTile` 同一条理由
        //    （未登录时看到一个「注销账号」，点了只会 401）。
        if (auth.isAuthenticated) ...[
          _navTile(
            icon: Icons.delete_forever_outlined,
            title: '注销账号',
            subtitle: '永久删除账号与云端数据',
            onTap: _showDeleteAccountDialog,
          ),
          const SizedBox(height: CoSpacing.sm),
          _buildSignOutTile(),
        ],
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
  /// 📌 判据：**「本次只做 X」这类阶段说明必须带日期，且后续变更要回来改它** ——
  ///    否则它会**永久停格**在当时的时点，而读者会信它 ⇒ 比没有注释更糟。
  ///    🔑 与「改名后须扫旧名残留」同族：**状态变了，指着旧状态的文字也要变。**
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

    // 🔴 2026-09-29：由 `isTrialAccount(auth.username)`（靠 `trial_` 前缀猜）改为
    //    `!auth.isRegistered`（= 邮箱为空）。判据从「用户名长什么样」换成
    //    「有没有完成注册」—— 后者才是真正要表达的东西，且不会被改名影响。
    final trial = !auth.isRegistered;
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
          // ── 邮箱：**显示已绑定的账号**，不再是「绑定」入口 ──
          //
          // 🔴 2026-09-29 语义变更：注册时就要求填邮箱 → 登录后**必然已有邮箱**，
          //    所以这一行不再是「去绑定」的动作，而是「显示你用的是哪个邮箱」。
          //    旧文案「绑定邮箱 / 用于找回账号 · 跨设备同步」在注册即绑邮箱之后
          //    会让人以为「还没绑、要去绑一次」—— 那是错的。
          //
          // ⚠️ 邮箱目前**不可修改**（后端无改邮箱端点）→ 点了给明确说明，
          //    而不是留一个点了没反应的行。
          _navTile(
            icon: Icons.mail_outline,
            title: auth.email ?? '未绑定邮箱',
            subtitle: '登录账号 · 找回账号靠它',
            onTap: () => _comingSoon('修改邮箱'),
            bare: true,
          ),
          Divider(height: 1, thickness: 1, color: Color(t.line.argb32)),
          // ── 🆕 2026-10-05 修改密码 ──
          //
          // 位置（白哥定案 · 设计稿 §二 方案 A）：**账号组内、邮箱下方**。
          // · 语义归属：它与「邮箱」「注销账号」同属**账号级**操作 ⇒ 同一组
          // · 放在「邮箱」之后而不是最末：组内顺序 = 「看账号 → 改凭证」，
          //   而**破坏性**操作（注销/退出）在页尾**独立成卡**，隔得很远 ✅
          // · 判据：**控件放哪两维度缺一不可**（语义归属 × 常驻成本）——
          //   它低频但不占地方（一行），且语义上必须与账号同组。
          //
          // 🔴 为什么和「忘记密码」是两件事（都缺就都做）：
          //   只有「忘记密码」⇒ 记得密码的人**改不了**；
          //   只有「修改密码」⇒ 忘了密码的人**进不去**。
          _navTile(
            icon: Icons.lock_outline,
            title: '修改密码',
            subtitle: '定期更换更安全',
            onTap: _showChangePasswordDialog,
            bare: true,
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
          '退出后将清除本机登录状态。你的学习记录仍保留在本机；'
          '已同步到云端的数据也仍保留，重新登录后可继续同步。',
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
  ///    📄 详见 [ClaimDialog] 的类文档 · 判据：「删一个元素前先查它还承担什么职责」。
  ///
  /// 🔑 登录成功后**不必**在这里刷数据：`initState` 的 `listenManual` 已监听
  ///    「未登录 → 已登录」并调用 `_load()`（一处权威，别写两遍）。
  void _showLoginDialog() {
    ClaimDialog.show(context);
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
                      style:
                          TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
                ],
              ),
              // 🔴 范围**引用常量**，不写字面量 —— 见 `kSpeechRateMax` 的说明：
              //    原先这里是 `max: 2.0`（超库声明上限 33%），
              //    导致「拖到右半边就没声音」，且**不报任何错**。
              //    范围只有一处权威 ⇒ 将来调上下限不必回来找这个 Slider。
              Slider(
                value: tts.speechRate,
                min: kSpeechRateMin,
                max: kSpeechRateMax,
                // 步长 0.1：(1.5 − 0.1) / 0.1 = 14 档
                divisions: ((kSpeechRateMax - kSpeechRateMin) / 0.1).round(),
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
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: CoSpacing.md, vertical: 10),
                  border: OutlineInputBorder(),
                ),
                // 🔴 原为「系统默认 (zh-CN)」—— 语义错误：本产品朗读英文，
                // 未指定音色时 `_pickBestVoice` 会按**文本语言**自动匹配（英文 → en-US）
                hint: Tw('系统默认（自动匹配语言）'),
                items: [
                  const DropdownMenuItem(value: '', child: Tw('系统默认（自动匹配语言）')),
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
                  final match = voices.cast<Map<String, dynamic>?>().firstWhere(
                      (v) => v?['name'] == voiceName,
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

  // ── 推荐码（**不是分销账本** —— 见 `_loadReferralCode` 内的说明）──
  Future<void> _loadReferralCode() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    try {
      final resp = await http.get(
        Uri.parse(
            '${ApiConfig.baseUrl}/api/referral/my-code?user_id=${auth.userId}'),
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
    //    理由：**购买与恢复都不需要登录**（StoreKit 走 Apple ID）⇒
    //    未登录时只给「去登录」等于**把购买路径堵死**，违反产品原则
    //    「除生词本上限外不验证登录态」。
    //    ⇒ 统一按**端侧状态**展示；登录只影响「记录能否同步到账号」。

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
    final snap = iapSnapshotOf(ref);
    final bool isActivated = snap.isActive;

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (isActivated) {
      final expires = snap.expiresAtUtc;
      statusText = expires == null
          ? '订阅中'
          : '订阅中 · 到期日 ${expires.toLocal().toString().substring(0, 10)}';
      statusColor = _cs.primary;
      statusIcon = Icons.verified;
    } else if (snap.entitlement == IapEntitlementStatus.expired) {
      // 🔑 到期**不没收资产**（§4.4.4）—— 文案只说「续订后继续」，
      //    不说「已锁定」（生词仍可读可复习，只是不能新增/朗读）
      statusText = '会员已到期 · 续订后继续';
      statusColor = _cs.error;
      statusIcon = Icons.lock_clock;
    } else {
      // 🔑 价值主张要具体（§4.4.1 判据 3）—— 不写「解锁全部功能」
      statusText = '无限生词本 · 文章朗读';
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
  /// 🔴 恢复的是 **Apple ID 名下的交易**，与我们的账号无关 ⇒
  ///    未登录也**必须能用**（这是换设备/重装后找回的唯一途径）。
  Future<void> _restorePurchases() async {
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
              text: '你设备上的学习数据（生词、复习记录、已导入的电子书）不会被删除。',
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
