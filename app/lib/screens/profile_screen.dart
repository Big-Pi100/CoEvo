import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../services/tts_service.dart';

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
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _displayName = prefs.getString('display_name') ?? auth.username ?? '用户';
    });

    if (auth.userId == null || auth.token == null) {
      setState(() => _isLoading = false);
      return;
    }

    // 检查头像是否存在
    _avatarUrl = '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar';

    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final data = await client.getProfile();
      if (mounted) setState(() { _data = data; _isLoading = false; });
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
    request.files.add(await http.MultipartFile.fromPath('file', picked.path));

    try {
      final streamed = await request.send();
      if (streamed.statusCode == 200) {
        setState(() => _avatarUrl = '${ApiConfig.baseUrl}/api/user/${auth.userId}/avatar?t=${DateTime.now().millisecondsSinceEpoch}');
      }
    } catch (_) {}

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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('display_name', result.trim());
      setState(() => _displayName = result.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () { setState(() => _isLoading = true); _load(); },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              ref.read(authProvider.notifier).logout();
              context.go('/auth');
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, auth),
    );
  }

  Widget _buildContent(BuildContext context, AuthState auth) {
    final stats = _data?['stats'] as Map<String, dynamic>? ?? {};
    final achievements = (_data?['achievements'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

    final totalCards = stats['total_cards'] ?? 0;
    final totalReviews = stats['total_reviews'] ?? 0;
    final streakDays = stats['streak_days'] ?? 0;
    final domainsCovered = stats['domains_covered'] ?? 0;
    final todayReviews = stats['today_reviews'] ?? 0;

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

        // 统计卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('学习统计', style: Theme.of(context).textTheme.titleMedium),
                const Divider(height: 24),
                _StatRow(icon: Icons.auto_stories, label: '卡片总数', value: '$totalCards'),
                _StatRow(icon: Icons.replay, label: '累计复习', value: '$totalReviews'),
                _StatRow(icon: Icons.today, label: '今日复习', value: '$todayReviews'),
                _StatRow(icon: Icons.category, label: '覆盖领域', value: '$domainsCovered'),
              ],
            ),
          ),
        ),
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
                        Text('${tts.speechRate.toStringAsFixed(1)}',
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                      ],
                    ),
                    Slider(
                      value: tts.speechRate,
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      label: tts.speechRate.toStringAsFixed(1),
                      onChanged: (v) => tts.speechRate = v,
                    ),
                    const SizedBox(height: 8),

                    // 音色
                    if (voices.isNotEmpty) ...[
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
                        items: voices.map<DropdownMenuItem<String>>((v) {
                          final name = v['name'] ?? '';
                          final locale = v['locale'] ?? '';
                          return DropdownMenuItem(
                            value: name as String,
                            child: Text('$name ($locale)',
                                overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (voiceName) {
                          if (voiceName != null) {
                            final match = voices.cast<Map<String, dynamic>?>().firstWhere(
                              (v) => v?['name'] == voiceName,
                              orElse: () => null,
                            );
                            if (match != null) {
                              tts.selectVoice(match);
                              // 选中后自动试听
                              tts.speak('你好，这是试听语音',
                                  language: 'zh-CN');
                            }
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
        const SizedBox(height: 16),

        // 成就卡片
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('成就', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    Text('${achievements.length}/11',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                  ],
                ),
                const Divider(height: 24),
                if (achievements.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.emoji_events, size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 8),
                          Text('还没有成就', style: TextStyle(color: Colors.grey.shade500)),
                          const SizedBox(height: 4),
                          Text('去对话学习，解锁第一个成就',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
                        ],
                      ),
                    ),
                  )
                else
                  Wrap(
                    spacing: 8, runSpacing: 12,
                    children: achievements.map((a) => _AchievementTile(
                      icon: a['icon'] as String? ?? '🌟',
                      name: a['name'] as String? ?? '',
                      unlockedAt: a['unlocked_at'] as String? ?? '',
                    )).toList(),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          )),
        ],
      ),
    );
  }
}

class _AchievementTile extends StatelessWidget {
  final String icon;
  final String name;
  final String unlockedAt;

  const _AchievementTile({
    required this.icon, required this.name, required this.unlockedAt,
  });

  @override
  Widget build(BuildContext context) {
    final date = unlockedAt.length >= 10 ? unlockedAt.substring(0, 10) : '';
    return Tooltip(
      message: date,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Theme.of(context).colorScheme.primary.withAlpha(40)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
