import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import '../api/chat_client.dart';
import '../api/api_config.dart';
import 'package:audioplayers/audioplayers.dart';
import '../widgets/referral_qr_code.dart';
import '../providers/auth_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/theme_provider.dart';
import '../services/tts_service.dart';
import '../widgets/order_history.dart';
import '../widgets/subscribe_panel.dart';
import '../widgets/claim_dialog.dart';
import '../theme/app_theme.dart';
import '../pages/user/distribution/notification_panel.dart';
import 'package:qr_flutter/qr_flutter.dart';

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

  // TTS 引擎配置
  String _ttsEngine = 'tencent';   // 'tencent' | 'native'
  int _ttsVoiceType = 101016;      // 智甜-女童声
  double _ttsSpeed = 1.2;          // 腾讯云语速 [-2, 6]

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
      // 绑定 TTS 客户端（用于偏好同步）
      final tts = ref.read(ttsServiceProvider);
      tts.bindClient(client);

      final results = await Future.wait([
        client.getProfile(),
        client.getPreferences(),
      ]);
      final data = results[0];
      final serverPrefs = results[1];
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
          _ttsEngine = serverPrefs['tts_engine'] ?? 'tencent';
          _ttsVoiceType = int.tryParse(serverPrefs['tts_voice_type'] ?? '') ?? 101016;
          _ttsSpeed = double.tryParse(serverPrefs['tts_speed'] ?? '') ?? 1.2;
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
        title: const Text('修改昵称'),
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () {
            final v = controller.text.trim();
            if (validator(v) == null) { Navigator.pop(ctx, v); }
            else { ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(validator(v)!))); }
          }, child: const Text('保存')),
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

  /// 保存 TTS 引擎选择
  Future<void> _saveTtsEngine(String engine) async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    await client.savePreferences({'tts_engine': engine});
  }

  /// 保存单条 TTS 偏好
  Future<void> _saveTtsPref(String key, String value) async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    await client.savePreferences({key: value});
  }

  /// 试听腾讯云 TTS
  Future<void> _previewTencentTts() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null || auth.token == null) return;
    try {
      final resp = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/tts/preview'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': '你好，欢迎使用腾讯云语音合成。这是当前音色的试听效果。',
          'voice_type': _ttsVoiceType,
          'speed': _ttsSpeed,
        }),
      );
      if (resp.statusCode == 200) {
        final player = AudioPlayer();
        player.setSource(BytesSource(Uint8List.fromList(resp.bodyBytes)));
        player.resume();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('试听失败: ${resp.body}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('试听失败: $e')),
        );
      }
    }
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 48, color: _cs.outline),
            const SizedBox(height: AppTheme.spacingLg),
            Text('加载失败', style: _tt.titleLarge?.copyWith(color: _cs.onSurface)),
            const SizedBox(height: AppTheme.spacingSm),
            Text(_error ?? '请检查网络连接后重试', style: _tt.bodyMedium?.copyWith(color: _cs.onSurfaceVariant), textAlign: TextAlign.center),
            const SizedBox(height: AppTheme.spacingXl),
            FilledButton.icon(
              onPressed: () {
                setState(() { _isLoading = true; _error = null; });
                _load();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
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
      padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSm),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Center(child: Icon(icon, size: 20, color: _cs.outline)),
          ),
          const SizedBox(width: 8),
          Text(label, style: _tt.bodyMedium?.copyWith(color: _cs.outline)),
          const Spacer(),
          Text(value, style: _tt.bodyLarge),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: _cs.outline),
          ],
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
        title: const Text('个人'),
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
      padding: const EdgeInsets.all(AppTheme.spacingXxl),
      children: [
        // ── 推广二维码 ──
        if (_referralCode != null)
          Container(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
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
                const SizedBox(height: AppTheme.spacingMd),
                // 推广码
                InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: _referralCode!));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('推广码已复制')),
                      );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: _cs.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _referralCode!,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _cs.primary,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.copy, size: 16, color: _cs.primary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (_referralCode == null)
          const SizedBox.shrink(),
        const SizedBox(height: AppTheme.spacingLg),

        // ── 个人信息（头像嵌入昵称行｜姓名｜手机号） ──
        Container(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
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
                  padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSm),
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
              // Row 2：真实姓名（可编辑）
              _buildProfileRow(
                icon: Icons.badge_outlined,
                label: '真实姓名',
                value: _realName ?? '未填写',
                onTap: () => _editInfoField(
                  '真实姓名', _realName,
                  (v) => (v == null || v.isEmpty) ? '请输入真实姓名' : null,
                  (v) => _updateProfile({'real_name': v}),
                ),
              ),
              const Divider(height: 1),
              // Row 3：手机号（可编辑）
              _buildProfileRow(
                icon: Icons.phone_outlined,
                label: '手机号',
                value: _phone ?? '未填写',
                onTap: () => _editInfoField(
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
        const SizedBox(height: AppTheme.spacingLg),

        // 推广统计 + 导航
        if (_referralCode != null) ...[
          // 统计卡片
          if (_statsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppTheme.spacingMd),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingMd),
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
          const SizedBox(height: AppTheme.spacingMd),
          // 导航按钮
          Row(
            children: [
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.account_tree, size: 16),
                onPressed: () => context.push('/earnings'),
                label: const Text('收益明细', style: TextStyle(fontSize: 12)),
              )),
              const SizedBox(width: AppTheme.spacingSm),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.group, size: 16),
                onPressed: () => context.push('/team'),
                label: const Text('我的团队', style: TextStyle(fontSize: 12)),
              )),
              const SizedBox(width: AppTheme.spacingSm),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.payments, size: 16),
                onPressed: () => context.push('/withdraw'),
                label: const Text('提现', style: TextStyle(fontSize: 12)),
              )),
            ],
          ),
          const SizedBox(height: AppTheme.spacingLg),
        ],

        // 订阅状态
        _buildSubscriptionCard(),
        const SizedBox(height: AppTheme.spacingSm),

        // 联系工作人员
        _buildContactCard(),
        const SizedBox(height: AppTheme.spacingMd),

        // 历史订单
        const OrderHistory(),
        const SizedBox(height: AppTheme.spacingLg),

        // 跳过的概念
        Card(
          child: ListTile(
            leading: Icon(Icons.skip_next, color: _cs.tertiary),
            title: const Text('跳过的概念'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/skipped'),
          ),
        ),
        const SizedBox(height: AppTheme.spacingLg),

        // 主题风格
        _buildThemeTile(),
        const SizedBox(height: AppTheme.spacingLg),

        // 朗读设置
        Consumer(
          builder: (_, ref, __) {
            final tts = ref.watch(ttsServiceProvider);
            final voices = tts.availableVoices;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.spacingXl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('朗读设置', style: Theme.of(context).textTheme.titleMedium),
                    const Divider(height: 24),

                    // ── TTS 引擎选择 ──
                    Row(
                      children: [
                        const Icon(Icons.settings_input_component, size: 18),
                        const SizedBox(width: AppTheme.spacingSm),
                        Text('TTS 引擎', style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                    const SizedBox(height: AppTheme.spacingSm),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'native', label: Text('本地原生', style: TextStyle(fontSize: 12))),
                        ButtonSegment(value: 'tencent', label: Text('腾讯云', style: TextStyle(fontSize: 12))),
                      ],
                      selected: {_ttsEngine},
                      onSelectionChanged: (v) {
                        final engine = v.first;
                        setState(() => _ttsEngine = engine);
                        _saveTtsEngine(engine);
                      },
                    ),
                    const SizedBox(height: AppTheme.spacingMd),

                    if (_ttsEngine == 'tencent') ...[
                      // ── 腾讯云音色 ID ──
                      Row(
                        children: [
                          const Icon(Icons.record_voice_over, size: 18),
                          const SizedBox(width: AppTheme.spacingSm),
                          Text('音色', style: Theme.of(context).textTheme.bodyMedium),
                          const Spacer(),
                          SizedBox(
                            height: 32,
                            child: TextButton.icon(
                              icon: const Icon(Icons.play_arrow, size: 16),
                              label: const Text('试听', style: TextStyle(fontSize: 12)),
                              onPressed: () => _previewTencentTts(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTheme.spacingSm),
                      DropdownButtonFormField<int>(
                        value: _ttsVoiceType,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 10),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('默认音色')),
                          DropdownMenuItem(value: 101001, child: Text('智瑜 — 情感女声')),
                          DropdownMenuItem(value: 101004, child: Text('智云 — 通用男声')),
                          DropdownMenuItem(value: 101011, child: Text('智燕 — 新闻女声')),
                          DropdownMenuItem(value: 101013, child: Text('智辉 — 新闻男声')),
                          DropdownMenuItem(value: 101015, child: Text('智萌 — 男童声')),
                          DropdownMenuItem(value: 101016, child: Text('智甜 — 女童声')),
                          DropdownMenuItem(value: 101019, child: Text('智彤 — 粤语女声')),
                          DropdownMenuItem(value: 101026, child: Text('智希 — 通用女声')),
                          DropdownMenuItem(value: 101030, child: Text('智柯 — 通用男声')),
                          DropdownMenuItem(value: 101050, child: Text('WeJack — 英文男声')),
                          DropdownMenuItem(value: 101054, child: Text('智友 — 通用男声')),
                          DropdownMenuItem(value: 101055, child: Text('智付 — 通用女声')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _ttsVoiceType = v);
                          _saveTtsPref('tts_voice_type', v.toString());
                        },
                      ),
                      const SizedBox(height: AppTheme.spacingMd),

                      // ── 腾讯云语速 ──
                      Row(
                        children: [
                          const Icon(Icons.speed, size: 18),
                          const SizedBox(width: AppTheme.spacingSm),
                          Text('语速', style: Theme.of(context).textTheme.bodyMedium),
                          const Spacer(),
                          Text(_ttsSpeed.toStringAsFixed(1),
                              style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
                        ],
                      ),
                      Slider(
                        value: _ttsSpeed,
                        min: -2.0,
                        max: 6.0,
                        divisions: 16,
                        label: _ttsSpeed.toStringAsFixed(1),
                        onChangeEnd: (v) => _saveTtsPref('tts_speed', v.toStringAsFixed(1)),
                        onChanged: (v) => setState(() => _ttsSpeed = v),
                      ),
                    ] else ...[
                      // ── 本地原生 TTS 设置 ──
                      // 语速
                      Row(
                        children: [
                          const Icon(Icons.speed, size: 18),
                          const SizedBox(width: AppTheme.spacingSm),
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
                      const SizedBox(height: AppTheme.spacingSm),

                      // 音色
                      Row(
                        children: [
                          const Icon(Icons.record_voice_over, size: 18),
                          const SizedBox(width: AppTheme.spacingSm),
                          Text('音色', style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                      const SizedBox(height: AppTheme.spacingSm),
                      DropdownButtonFormField<String>(
                        value: tts.selectedVoice?['name'] as String?,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: 10),
                          border: OutlineInputBorder(),
                        ),
                        hint: const Text('系统默认 (zh-CN)'),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('系统默认 (zh-CN)')),
                          if (voices.isNotEmpty)
                            ...voices.map<DropdownMenuItem<String>>((v) {
                              final name = v['name'] ?? '';
                              final locale = v['locale'] ?? '';
                              return DropdownMenuItem(
                                value: name as String,
                                child: Text('$name ($locale)',
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
                            tts.speak('你好，这是试听语音', language: 'zh-CN');
                          }
                        },
                      ),
                    ],
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

  /// 主题风格选择入口
  Widget _buildThemeTile() {
    final themeState = ref.watch(themeProvider);
    final modeLabel = switch (themeState.mode) {
      AppThemeMode.system => '跟随系统',
      AppThemeMode.light => 'CoEvo 浅色',
      AppThemeMode.dark => 'CoEvo 深色',
      AppThemeMode.duolingo => 'Duolingo 风格',
    };
    final modeIcon = switch (themeState.mode) {
      AppThemeMode.system => Icons.brightness_auto,
      AppThemeMode.light => Icons.light_mode,
      AppThemeMode.dark => Icons.dark_mode,
      AppThemeMode.duolingo => Icons.palette,
    };

    return Card(
      child: ListTile(
        leading: Icon(modeIcon, color: Theme.of(context).colorScheme.primary),
        title: const Text('主题风格'),
        subtitle: Text(modeLabel, style: TextStyle(color: _cs.onSurfaceVariant, fontSize: 13)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _showThemeDialog(),
      ),
    );
  }

  Future<void> _showThemeDialog() async {
    final themeNotifier = ref.read(themeProvider.notifier);
    final currentMode = ref.read(themeProvider).mode;

    final result = await showDialog<AppThemeMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择主题风格'),
        children: [
          _themeOption(
            ctx, result: AppThemeMode.duolingo,
            icon: Icons.palette, label: 'Duolingo 风格',
            subtitle: '游戏化学习界面（默认）',
            selected: currentMode == AppThemeMode.duolingo,
          ),
          _themeOption(
            ctx, result: AppThemeMode.system,
            icon: Icons.brightness_auto, label: '跟随系统',
            subtitle: '根据设备设置自动切换',
            selected: currentMode == AppThemeMode.system,
          ),
          _themeOption(
            ctx, result: AppThemeMode.light,
            icon: Icons.light_mode, label: 'CoEvo 浅色',
            subtitle: '深蓝 + 翠绿进化风格',
            selected: currentMode == AppThemeMode.light,
          ),
          _themeOption(
            ctx, result: AppThemeMode.dark,
            icon: Icons.dark_mode, label: 'CoEvo 深色',
            subtitle: '护眼暗色进化风格',
            selected: currentMode == AppThemeMode.dark,
          ),
        ],
      ),
    );

    if (result != null) {
      await themeNotifier.setMode(result);
    }
  }

  Widget _themeOption(
    BuildContext ctx, {
    required AppThemeMode result,
    required IconData icon,
    required String label,
    required String subtitle,
    required bool selected,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingSm),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: _tt.bodySmall!),
        trailing: selected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 20)
            : const SizedBox(width: AppTheme.spacingXl),
        onTap: () => Navigator.pop(ctx, result),
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
        title: const Text('保存推广二维码'),
        content: const Text('将二维码保存到本地，可分享给好友扫码注册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _doSaveQrCode();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _doSaveQrCode() {
    try {
      final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      boundary.toImage(pixelRatio: 3.0).then((image) {
        image.toByteData(format: ui.ImageByteFormat.png).then((data) {
          if (data == null) return;
          final blob = html.Blob([data.buffer.asUint8List()]);
          final url = html.Url.createObjectUrlFromBlob(blob);
          html.AnchorElement(href: url)
            ..setAttribute('download', 'coevo_qr.png')
            ..click();
          html.Url.revokeObjectUrl(url);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('二维码已保存')),
            );
          }
        });
      });
    } catch (_) {
      Clipboard.setData(ClipboardData(
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
      final expires = DateTime.tryParse(expiresStr) ?? DateTime.now();
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
          child: const Text('续费'),
        ),
      ),
    );
  }

  void _showSubscribeDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('订阅套餐'),
        content: const SubscribePanel(),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
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
        title: const Text('联系工作人员', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        trailing: Icon(Icons.chevron_right, color: _cs.onSurfaceVariant, size: 20),
        onTap: _showContactDialog,
      ),
    );
  }

  void _showContactDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('联系工作人员'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('扫码添加工作人员微信', style: TextStyle(fontSize: 13)),
            const SizedBox(height: AppTheme.spacingLg),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}

