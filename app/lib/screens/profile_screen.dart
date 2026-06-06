// ignore_for_file: unnecessary_cast, unnecessary_non_null_assertion, unused_element
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/tts_service.dart';
import '../utils/validators.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Map<String, dynamic>? _data;
  bool _isLoading = true;
  String? _avatarUrl;
  String _displayName = '';
  String? _realName;
  String? _phone;
  bool _isUploading = false;
  ProviderSubscription? _authSub;

  // 订阅状态
  String? _subscriptionExpires;  // ISO 8601 或 null（未激活）

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

    // 存储头像 URL（NetworkImage 加载失败会优雅降级）
    _avatarUrl = '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar';

    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      // 绑定 TTS 客户端（用于偏好同步）
      final tts = ref.read(ttsServiceProvider);
      tts.bindClient(client);

      final results = await Future.wait([
        client.getProfile(),
        client.getPreferences(),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final serverPrefs = results[1] as Map<String, String>;
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
          _data = data;
          _subscriptionExpires = serverPrefs['subscription_expires'];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
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
        await client.updateDisplayName(trimmed);
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
    } catch (_) {}
  }

  Widget _buildInfoTile({required IconData icon, required String label, required String value, required VoidCallback onTap}) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 20, color: Colors.grey),
        title: Text(label, style: const TextStyle(fontSize: 14, color: Colors.grey)),
        subtitle: Text(value, style: const TextStyle(fontSize: 16)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authProvider.notifier).logout();
              if (context.mounted) context.go('/auth');
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                setState(() => _isLoading = true);
                await _load();
              },
              child: _buildContent(context, auth),
            ),
    );
  }

  Widget _buildContent(BuildContext context, AuthState auth) {
    final stats = _data?['stats'] as Map<String, dynamic>? ?? {};

    final streakDays = stats['streak_days'] ?? 0;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // 用户头像 + 名字（可点击自定义）
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: _uploadAvatar,
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                  backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                  child: _isUploading
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : (_avatarUrl == null
                          ? Icon(Icons.person, size: 40, color: Theme.of(context).colorScheme.primary)
                          : null),
                ),
              ),
              const SizedBox(height: 4),
              Text('点击更换头像', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _editName,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_displayName, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(width: 6),
                    Icon(Icons.edit, size: 16, color: Colors.grey.shade400),
                  ],
                ),
              ),
              if (streakDays > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department, color: Colors.orange, size: 18),
                      const SizedBox(width: 4),
                      Text('连续学习 $streakDays 天',
                          style: TextStyle(color: Colors.orange.shade700)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // ── 真实姓名 + 手机号 ──
        _buildInfoTile(
          icon: Icons.badge_outlined,
          label: '真实姓名',
          value: _realName ?? '未填写',
          onTap: () => _editInfoField('真实姓名', _realName, Validators.realName, (v) => _updateProfile({'real_name': v})),
        ),
        _buildInfoTile(
          icon: Icons.phone_outlined,
          label: '手机号',
          value: _phone ?? '未填写',
          onTap: () => _editInfoField('手机号', _phone, Validators.phone, (v) => _updateProfile({'phone': v})),
        ),
        const SizedBox(height: 16),

        // 订阅状态
        _buildSubscriptionCard(),
        const SizedBox(height: 16),

        // 跳过的概念
        Card(
          child: ListTile(
            leading: const Icon(Icons.skip_next, color: Colors.orange),
            title: const Text('跳过的概念'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/skipped'),
          ),
        ),
        const SizedBox(height: 16),

        // 主题风格
        _buildThemeTile(),
        const SizedBox(height: 16),

        // 朗读设置
        Consumer(
          builder: (_, ref, __) {
            final tts = ref.watch(ttsServiceProvider);
            final voices = tts.availableVoices;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('朗读设置', style: Theme.of(context).textTheme.titleMedium),
                    const Divider(height: 24),

                    // 语速
                    Row(
                      children: [
                        const Icon(Icons.speed, size: 18),
                        const SizedBox(width: 8),
                        Text('语速', style: Theme.of(context).textTheme.bodyMedium),
                        const Spacer(),
                        Text(tts.speechRate.toStringAsFixed(1),
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
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
                    const SizedBox(height: 8),

                    // 音色
                    Row(
                      children: [
                        const Icon(Icons.record_voice_over, size: 18),
                        const SizedBox(width: 8),
                        Text('音色', style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: tts.selectedVoice?['name'] as String?,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
        subtitle: Text(modeLabel, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
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
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: selected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 20)
            : const SizedBox(width: 20),
        onTap: () => Navigator.pop(ctx, result),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// 订阅状态卡片
  Widget _buildSubscriptionCard() {
    final expiresStr = _subscriptionExpires;
    final bool isActivated = expiresStr != null && expiresStr.isNotEmpty;
    final bool isExpired = isActivated && DateTime.tryParse(expiresStr)?.isBefore(DateTime.now()) == true;

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (!isActivated) {
      statusText = '未激活 — 请联系服务人员开通';
      statusColor = Colors.orange;
      statusIcon = Icons.lock_outline;
    } else if (isExpired) {
      statusText = '已到期 — 请联系服务人员续费';
      statusColor = Colors.red;
      statusIcon = Icons.lock_clock;
    } else {
      final expires = DateTime.tryParse(expiresStr!)!;
      final remaining = expires.difference(DateTime.now());
      if (remaining.inDays > 30) {
        statusText = '有效 — 到期日: ${expiresStr.substring(0, 10)}';
        statusColor = Colors.green;
        statusIcon = Icons.verified;
      } else if (remaining.inDays > 0) {
        statusText = '即将到期 — 剩余 ${remaining.inDays} 天';
        statusColor = Colors.orange;
        statusIcon = Icons.access_time;
      } else {
        statusText = '已到期 — 请联系服务人员续费';
        statusColor = Colors.red;
        statusIcon = Icons.lock_clock;
      }
    }

    return Card(
      child: ListTile(
        leading: Icon(statusIcon, color: statusColor, size: 24),
        title: Text('订阅状态', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(statusText, style: TextStyle(color: statusColor, fontSize: 13)),
      ),
    );
  }

}

/// CEFR 等级进度条
class _CefrBar extends StatelessWidget {
  final String level;
  final int total;
  final int mastered;
  final double ratio;

  const _CefrBar({
    required this.level,
    required this.total,
    required this.mastered,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) {
    final color = _levelColor(level);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(level, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    backgroundColor: color.withAlpha(25),
                    valueColor: AlwaysStoppedAnimation(color),
                    minHeight: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: Text('$mastered/$total', textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'A1': return Colors.green;
      case 'A2': return Colors.teal;
      case 'B1': return Colors.blue;
      case 'B2': return Colors.orange;
      case 'C1': return Colors.deepPurple;
      case 'C2': return Colors.red;
      default: return Colors.grey;
    }
  }
}
