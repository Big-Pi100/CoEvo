import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../widgets/referral_qr_code.dart';
import '../providers/auth_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/theme_provider.dart';
import '../services/tts_service.dart';
import '../widgets/order_history.dart';
import '../widgets/subscribe_panel.dart';
import '../widgets/claim_dialog.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../utils/image_export.dart';
import '../pages/user/distribution/notification_panel.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
  bool _hasShownClaimDialog = false;
  String? _avatarUrl;
  String _displayName = '';
  String? _realName;
  String? _phone;
  bool _isUploading = false;
  ProviderSubscription? _authSub;
  int _unreadCount = 0;

  // 推广码
  String? _referralCode;
  final GlobalKey _qrKey = GlobalKey();
  Map<String, dynamic>? _referralStats;
  bool _statsLoading = false;

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

    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final results = await Future.wait([
        client.getProfile(),
        client.getPreferences(),
      ]);
      final data = results[0];
      // ⚠️ `results[1]`（用户偏好）自 2026-09-26 起本页不再消费：
      // TTS 偏好已改为 `TtsService` 自持（引擎只剩端侧，无偏好需同步）。
      // 请求暂留（通用接口，`review_screen` 仍在用；且本页后续可能展示其他偏好）。
      // 如果后端有 display_name，覆盖本地缓存
      final backendName = data['display_name'] as String?;
      if (backendName != null && backendName != _displayName && mounted) {
        await prefs.setString('display_name', backendName);
        setState(() => _displayName = backendName);
      }
      // 真实姓名 + 手机号
      setState(() {
        _realName = data['real_name'] as String?;
        _phone = data['phone'] as String?;
      });
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

  Future<void> _checkTrialClaim() async {
    final auth = ref.read(authProvider);
    // 已有真实姓名 → 已认领，跳过
    if (auth.realName != null && auth.realName!.trim().isNotEmpty) return;

    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const ClaimDialog(),
    );
    if (result == true && mounted) {
      _load();
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
        final client = ChatClient(userId: auth.userId!, token: auth.token);
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

  Future<void> _editInfoField(String label, String? current, String? Function(String?) validator, Future<void> Function(String) onSave) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('修改$label'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: '输入$label'),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            if (validator(v.trim()) == null) Navigator.pop(ctx, v.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Tw('取消')),
          FilledButton(onPressed: () {
            final v = controller.text.trim();
            if (validator(v) == null) { Navigator.pop(ctx, v); }
            else { ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(validator(v)!))); }
          }, child: Tw('保存')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await onSave(result);
    }
  }

  Future<void> _updateProfile(Map<String, String> fields) async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    try {
      final resp = await http.put(
        Uri.parse('${ApiConfig.baseUrl}/api/user/${auth.userId}/profile'),
        headers: {'Authorization': 'Bearer ${auth.token}', 'Content-Type': 'application/json'},
        body: jsonEncode(fields),
      );
      if (resp.statusCode == 200) {
        setState(() {
          if (fields.containsKey('real_name')) _realName = fields['real_name'];
          if (fields.containsKey('phone')) _phone = fields['phone'];
        });
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
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
  Widget _buildProfileRow({required IconData icon, required String label, required String value, VoidCallback? onTap}) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: CoSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Center(child: Icon(icon, size: 20, color: _cs.outline)),
          ),
          const SizedBox(width: 8),
          Text(label, style: _tt.bodyMedium?.copyWith(color: _cs.outline)),
          const Spacer(),
          Flexible(
            child: Text(value, style: _tt.bodyLarge, overflow: TextOverflow.ellipsis, maxLines: 1),
          ),
          ],
      ),
    );
    return onTap != null ? InkWell(onTap: onTap, child: row) : row;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // 检测并弹出注册弹窗（首次进入个人页时）
    if (!_hasShownClaimDialog && !_isLoading) {
      _hasShownClaimDialog = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkTrialClaim());
    }

    return Scaffold(
      appBar: AppBar(
        title: Tw('个人'),
        actions: [
          Badge(
            isLabelVisible: _unreadCount > 0,
            label: Text('$_unreadCount', style: const TextStyle(fontSize: 10)),
            child: IconButton(
              icon: const Icon(Icons.notifications_outlined),
              tooltip: '通知',
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationPanel())),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go('/');
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
              : RefreshIndicator(
                  onRefresh: () async {
                    setState(() { _isLoading = true; _error = null; });
                    await _load();
                  },
                  child: _buildContent(context, auth),
                ),
    );
  }

  Widget _buildContent(BuildContext context, AuthState auth) {

    return ListView(
      padding: const EdgeInsets.all(CoSpacing.xxl),
      children: [
        // ── 推广二维码 ──
        if (_referralCode != null)
          Container(
            padding: const EdgeInsets.all(CoSpacing.lg),
            decoration: BoxDecoration(
              color: _cs.surfaceContainerHighest.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                // 二维码
                InkWell(
                  onTap: () => _saveQrCode(),
                  child: RepaintBoundary(
                    key: _qrKey,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _cs.outlineVariant),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: ReferralQrCode(
                        referralCode: _referralCode ?? '',
                        camp: 'profile',
                        size: 104,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: CoSpacing.md),
              ],
            ),
          )
        else if (_referralCode == null)
          const SizedBox.shrink(),
        const SizedBox(height: CoSpacing.lg),

        // ── 个人信息（头像嵌入昵称行｜姓名｜手机号） ──
        Container(
          padding: const EdgeInsets.all(CoSpacing.md),
          decoration: BoxDecoration(
            color: _cs.surfaceContainerHighest.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              // Row 1：头像 + 昵称
              InkWell(
                onTap: _editName,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: CoSpacing.sm),
                  child: Row(
                    children: [
                      // 左栏固定宽度，与 _buildProfileRow 的图标栏对齐
                      SizedBox(
                        width: 32,
                        child: GestureDetector(
                          onTap: _uploadAvatar,
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                            backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                            child: _isUploading
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : (_avatarUrl == null
                                    ? Icon(Icons.person, size: 18, color: Theme.of(context).colorScheme.primary)
                                    : null),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('昵称', style: _tt.bodyMedium?.copyWith(color: _cs.outline)),
                      const Spacer(),
                      Text(_displayName, style: _tt.bodyLarge),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 18, color: _cs.outline),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              // Row 2：真实姓名（已认领后不可修改）
              _buildProfileRow(
                icon: Icons.badge_outlined,
                label: '真实姓名',
                value: _realName ?? '未填写',
                onTap: (_realName != null && _realName!.isNotEmpty)
                    ? null
                    : () => _editInfoField(
                      '真实姓名', _realName,
                      (v) => (v == null || v.isEmpty) ? '请输入真实姓名' : null,
                      (v) => _updateProfile({'real_name': v}),
                    ),
              ),
              const Divider(height: 1),
              // Row 3：手机号（已认领后不可修改）
              _buildProfileRow(
                icon: Icons.phone_outlined,
                label: '手机号',
                value: _phone ?? '未填写',
                onTap: (_realName != null && _realName!.isNotEmpty)
                    ? null
                    : () => _editInfoField(
                      '手机号', _phone,
                      (v) {
                        if (v == null || v.isEmpty) return '请输入手机号';
                        final digitsOnly = v.replaceAll(RegExp(r'\D'), '');
                        if (digitsOnly.length != 11) return '手机号格式不正确';
                        return null;
                      },
                      (v) => _updateProfile({'phone': v}),
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: CoSpacing.lg),

        // 推广统计 + 导航
        if (_referralCode != null) ...[
          // 统计卡片
          if (_statsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: CoSpacing.md),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(vertical: CoSpacing.md),
              decoration: BoxDecoration(
                color: _cs.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(child: _statItem(Icons.people, '邀请人数', '${_referralStats?['total_registrations'] ?? 0}')),
                  Container(width: 1, height: 32, color: _cs.outlineVariant),
                  Expanded(child: _statItem(Icons.monetization_on, '累计收益', '¥${((_referralStats?['total_earned'] as num?)?.toDouble() ?? 0) / 100}')),
                  Container(width: 1, height: 32, color: _cs.outlineVariant),
                  Expanded(child: _statItem(Icons.timeline, '分享次数', '${_referralStats?['total_clicks'] ?? 0}')),
                ],
              ),
            ),
          const SizedBox(height: CoSpacing.md),
          // 导航按钮
          Row(
            children: [
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.account_tree, size: 16),
                onPressed: () => context.push('/earnings'),
                label: Tw('收益明细', style: TextStyle(fontSize: 12)),
              )),
              const SizedBox(width: CoSpacing.sm),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.group, size: 16),
                onPressed: () => context.push('/team'),
                label: Tw('我的团队', style: TextStyle(fontSize: 12)),
              )),
              const SizedBox(width: CoSpacing.sm),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.payments, size: 16),
                onPressed: () => context.push('/withdraw'),
                label: Tw('提现', style: TextStyle(fontSize: 12)),
              )),
            ],
          ),
          const SizedBox(height: CoSpacing.lg),
        ],

        // 订阅状态
        _buildSubscriptionCard(),
        const SizedBox(height: CoSpacing.sm),

        // 联系工作人员
        _buildContactCard(),
        const SizedBox(height: CoSpacing.md),

        // 历史订单
        const OrderHistory(),
        const SizedBox(height: CoSpacing.lg),

        // 跳过的概念
        Card(
          child: ListTile(
            leading: Icon(Icons.skip_next, color: _cs.tertiary),
            title: Tw('跳过的概念'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/skipped'),
          ),
        ),
        const SizedBox(height: CoSpacing.lg),

        // 主题风格
        _buildThemeTile(),
        const SizedBox(height: CoSpacing.lg),

        // 朗读设置
        Consumer(
          builder: (_, ref, __) {
            final tts = ref.watch(ttsServiceProvider);
            final voices = tts.availableVoices;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(CoSpacing.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('朗读设置', style: Theme.of(context).textTheme.titleMedium),
                    const Divider(height: 24),

                    // ── 朗读设置：端侧 flutter_tts（2026-09-26 起唯一引擎，腾讯云分支已取消）──
                    // ── 本地原生 TTS 设置 ──
                    // 语速
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

                    // 音色
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
                        contentPadding: EdgeInsets.symmetric(horizontal: CoSpacing.md, vertical: 10),
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
                          orElse: () => null,
                        );
                        if (match != null) {
                          tts.selectVoice(match);
                          // 切换音色后自动试听（英文），方便立即对比
                          tts.speak(_nativePreviewText, language: 'en-US');
                        }
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
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

    return Card(
      child: ListTile(
        leading: Icon(_themeIcon(settings.theme),
            color: Theme.of(context).colorScheme.primary),
        title: Tw('主题'),
        subtitle: Text(label,
            style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _showThemeDialog(),
      ),
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

  Widget _themeOption(
    ReadingTheme theme, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    final tokens = allTokens[theme]!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CoSpacing.sm),
      child: ListTile(
        leading: Icon(_themeIcon(theme),
            color: Theme.of(context).colorScheme.primary),
        title: Text('${tokens.label} · ${tokens.character}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: selected
            ? Icon(Icons.check_circle,
                color: Theme.of(context).colorScheme.primary, size: 20)
            : const SizedBox(width: CoSpacing.xl),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── 推广码 ──
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
        _referralCode = data['referral_code'] as String?;
        _loadReferralStats();
      }
    } catch (_) {}
  }

  Future<void> _loadReferralStats() async {
    final auth = ref.read(authProvider);
    final uid = auth.userId;
    if (uid == null) return;
    setState(() => _statsLoading = true);
    try {
      final token = auth.token;
      final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};
      final resp = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/api/referral/my-stats?user_id=$uid'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        _referralStats = jsonDecode(resp.body) as Map<String, dynamic>?;
      }
    } catch (_) {}
    if (mounted) setState(() => _statsLoading = false);
  }

  /// 保存二维码图片到本地
  void _saveQrCode() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Tw('保存推广二维码'),
        content: Tw('将二维码保存到本地，可分享给好友扫码注册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Tw('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _doSaveQrCode();
            },
            child: Tw('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _doSaveQrCode() async {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      // 原实现为 web-only（Blob + AnchorElement 下载）→ 见 utils/image_export.dart
      final err = await exportPngBytes(
        data.buffer.asUint8List(),
        fileName: 'coevo_qr.png',
        shareText: 'https://keyievolution.fun/?ref=$_referralCode',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err == null ? '二维码已导出' : '导出失败，已复制链接')),
      );
      if (err != null) {
        await Clipboard.setData(ClipboardData(
          text: 'https://keyievolution.fun/?ref=$_referralCode',
        ));
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(
        text: 'https://keyievolution.fun/?ref=$_referralCode',
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('注册链接已复制')),
        );
      }
    }
  }

  Widget _statItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, size: 18, color: _cs.primary),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        Text(label,
            style: TextStyle(fontSize: 11, color: _cs.onSurfaceVariant)),
      ],
    );
  }

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

    return Card(
      child: ListTile(
        leading: Icon(statusIcon, color: statusColor, size: 24),
        title: Text('订阅状态', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 13)),
        trailing: FilledButton.tonal(
          onPressed: () => _showSubscribeDialog(),
          child: Tw('续费'),
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
    return Card(
      child: ListTile(
        leading: Icon(Icons.headset_mic, color: _cs.primary, size: 22),
        title: Tw('联系工作人员', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        trailing: Icon(Icons.chevron_right, color: _cs.onSurfaceVariant, size: 20),
        onTap: _showContactDialog,
      ),
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

