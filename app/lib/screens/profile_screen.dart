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
import '../services/tts_service.dart';
import '../utils/validators.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _report;  // Phase 3 学习报告
  Map<String, dynamic>? _activityData;  // Phase 3 热力图
  DateTime _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);  // 当前日历月份
  Map<String, dynamic>? _weeklyReport;  // Phase 3 周报
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
        client.getLearningReport(),
        client.getActivity(days: 90),
        client.getWeeklyReport(),
        client.getPreferences(),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final report = results[1] as Map<String, dynamic>?;
      final activity = results[2] as Map<String, dynamic>?;
      final weekly = results[3] as Map<String, dynamic>?;
      final serverPrefs = results[4] as Map<String, String>;
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
      if (mounted) setState(() {
        _data = data;
        _report = report;
        _activityData = activity;
        _weeklyReport = weekly;
        _subscriptionExpires = serverPrefs['subscription_expires'];
        _isLoading = false;
      });
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
            if (validator(v) == null) Navigator.pop(ctx, v);
            else ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(validator(v)!)));
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
    final client = ChatClient(userId: auth.userId!, token: auth.token);
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
    final achievements = (_data?['achievements'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

    final totalCards = stats['total_cards'] ?? 0;
    final totalReviews = stats['total_reviews'] ?? 0;
    final streakDays = stats['streak_days'] ?? 0;
    final domainsCovered = stats['domains_covered'] ?? 0;
    final todayReviews = stats['today_reviews'] ?? 0;
    final cefrStats = (_data?['cefr_stats'] as List<dynamic>?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [];

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

        // ── Phase 3: 学习报告 ──
        if (_report != null) ...[
          _buildReportSection(_report!, achievements),
          const SizedBox(height: 16),
        ],
        if (_activityData != null) ...[
          _buildHeatmap(_activityData!),
          const SizedBox(height: 16),
        ],
        if (_weeklyReport != null) ...[
          _buildWeeklyReport(_weeklyReport!),
          const SizedBox(height: 16),
        ],

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

        // ── CEFR 词汇仪表盘 ──
        if (cefrStats.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CEFR 词汇掌握度', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('统计已掌握的词汇量，按 CEFR 等级分阶展示',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const Divider(height: 20),
                  ...cefrStats.map((s) => _buildCefrBar(s)),
                  const Divider(height: 16),
                  _buildCefrTotal(cefrStats),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

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

  // ── Phase 3: 学习报告 ──
  Widget _buildReportSection(Map<String, dynamic> report, List<Map<String, dynamic>> achievements) {
    final plans = report['plans'] as List<dynamic>? ?? [];
    final tiers = report['achievements_by_tier'] as List<dynamic>? ?? [];
    final tierCount = tiers.fold<int>(0, (sum, t) => sum + ((t as Map<String, dynamic>)['count'] as int? ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 所有学习计划进度
        if (plans.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.school, size: 20),
                      const SizedBox(width: 8),
                      Text('学习计划 (${plans.length})', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...plans.asMap().entries.map((entry) {
                    final i = entry.key;
                    final plan = entry.value as Map<String, dynamic>;
                    return Padding(
                      padding: i < plans.length - 1 ? const EdgeInsets.only(bottom: 16) : EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                plan['mode'] == 'completed' || plan['current_stage'] == '完成'
                                    ? Icons.check_circle : Icons.play_circle,
                                size: 16,
                                color: plan['mode'] == 'completed'
                                    ? Colors.green : Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(plan['goal'] as String? ?? '',
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              ),
                              if (plan['mode'] == 'completed')
                                Text('已完成', style: TextStyle(fontSize: 11, color: Colors.green.shade600)),
                            ],
                          ),
                          if (plan['current_stage'] is String && (plan['current_stage'] as String).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 24, top: 4),
                              child: Text('当前阶段：${plan['current_stage']}',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                            ),
                          const SizedBox(height: 8),
                          if (((plan['total_tasks'] as int?) ?? 0) > 0)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: ((plan['done_tasks'] as int?) ?? 0) / ((plan['total_tasks'] as int?) ?? 1),
                                minHeight: 6,
                                backgroundColor: Colors.grey.shade200,
                                valueColor: AlwaysStoppedAnimation(
                                  plan['mode'] == 'completed' ? Colors.green : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(left: 24, top: 4),
                            child: Text('${plan['done_tasks']}/${plan['total_tasks']} 任务 (${plan['progress_pct']})',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),

        // 成就 tier 展示
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.emoji_events, size: 20),
                    const SizedBox(width: 8),
                    Text('成就 ($tierCount)', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                // tier 统计（汇总行）
                ...tiers.map((t) {
                  final tmap = t as Map<String, dynamic>;
                  final tier = tmap['tier'] as String? ?? '';
                  final count = tmap['count'] as int? ?? 0;
                  final icon = tier == 'bronze' ? '🥉' : tier == 'silver' ? '🥈' : tier == 'gold' ? '🥇' : tier == 'platinum' ? '🏆' : '🌟';
                  final label = tier == 'fixed' ? '固定成就' : tier == 'bronze' ? '任务级' : tier == 'silver' ? '阶段级' : tier == 'gold' ? '领域级' : '跨领域';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(icon, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
                        Text('$count', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      ],
                    ),
                  );
                }),
                if (achievements.isNotEmpty) ...[
                  const Divider(height: 24),
                  // 已解锁成就列表
                  Wrap(
                    spacing: 8, runSpacing: 12,
                    children: achievements.map((a) => _AchievementTile(
                      icon: a['icon'] as String? ?? '🌟',
                      name: a['name'] as String? ?? '',
                      unlockedAt: a['unlocked_at'] as String? ?? '',
                    )).toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Phase 3: 周报 ──
  Widget _buildWeeklyReport(Map<String, dynamic> report) {
    final activePlan = report['active_plan'] as String?;
    final newCards = report['new_cards'] as int? ?? 0;
    final reviews = report['reviews'] as int? ?? 0;
    final convs = report['conversation_turns'] as int? ?? 0;
    final newAchs = report['new_achievements'] as int? ?? 0;

    // 闲置提醒：有活跃计划但本周无活动
    final isIdle = activePlan != null && newCards == 0 && reviews == 0 && convs == 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assessment, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('本周学习报告', style: Theme.of(context).textTheme.titleMedium)),
                if (isIdle)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('待唤醒', style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (isIdle)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active, color: Colors.orange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('你的"$activePlan"学习计划等你回来继续！',
                            style: TextStyle(fontSize: 13, color: Colors.orange.shade800)),
                      ),
                    ],
                  ),
                ),
              ),
            _StatRow(icon: Icons.auto_stories, label: '新增卡片', value: '$newCards'),
            _StatRow(icon: Icons.replay, label: '本周复习', value: '$reviews'),
            _StatRow(icon: Icons.chat, label: '对话轮次', value: '$convs'),
            _StatRow(icon: Icons.emoji_events, label: '新成就', value: '$newAchs'),
          ],
        ),
      ),
    );
  }

  // ── Phase 3: 学习日历（真实月历） ──
  Widget _buildHeatmap(Map<String, dynamic> activity) {
    final days = activity['days'] as List<dynamic>? ?? [];
    // 构建日期→分数映射
    final scoreByDate = <String, int>{};
    final reviewsByDate = <String, int>{};
    final convsByDate = <String, int>{};
    final cardsByDate = <String, int>{};
    for (final d in days) {
      final day = d as Map<String, dynamic>;
      final date = day['date'] as String? ?? '';
      scoreByDate[date] = day['score'] as int? ?? 0;
      reviewsByDate[date] = day['reviews'] as int? ?? 0;
      convsByDate[date] = day['conversations'] as int? ?? 0;
      cardsByDate[date] = day['cards'] as int? ?? 0;
    }

    // 计算当前月
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDay = DateTime(year, month, 1);
    final lastDay = DateTime(year, month + 1, 0);
    final daysInMonth = lastDay.day;
    // Monday = 1 ... Sunday = 7
    final startWeekday = firstDay.weekday; // 1=Mon ... 7=Sun
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);

    // 月名前缀
    const monthNames = ['', '1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];
    final headerLabel = '$year年${monthNames[month]}';

    // 计算最大分数用于颜色强度
    final maxScore = scoreByDate.values.fold<int>(0, (m, s) => s > m ? s : m);

    Color cellColor(int score) {
      if (score == 0) return Colors.grey.shade100;
      final intensity = maxScore > 0 ? score / maxScore : 0.0;
      if (intensity < 0.25) return Colors.green.shade100;
      if (intensity < 0.5) return Colors.green.shade300;
      if (intensity < 0.75) return Colors.green.shade500;
      return Colors.green.shade700;
    }

    // 构建日历网格行
    final cells = <Widget>[];
    // 填充月初空白
    final leadingBlanks = startWeekday - 1; // Mon=1 → 0, ... Sun=7 → 6
    for (int i = 0; i < leadingBlanks; i++) {
      cells.add(const SizedBox(width: 40, height: 40));
    }
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr = '${year}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      final score = scoreByDate[dateStr] ?? 0;
      final isToday = dateStr == todayStr;
      final bgColor = cellColor(score);
      final textColor = score == 0 ? Colors.black54 : Colors.black;
      final reviews = reviewsByDate[dateStr] ?? 0;
      final convs = convsByDate[dateStr] ?? 0;
      final cardCount = cardsByDate[dateStr] ?? 0;

      cells.add(
        Tooltip(
          message: '$dateStr\n复习$reviews次 · $convs轮对话 · $cardCount张卡',
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: isToday ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 14,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                color: textColor,
              ),
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 月份导航
            Row(
              children: [
                const Icon(Icons.calendar_month, size: 20),
                const SizedBox(width: 8),
                Text(headerLabel, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 20),
                  onPressed: () => setState(() {
                    _calendarMonth = DateTime(year, month - 1);
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 20),
                  onPressed: () => setState(() {
                    _calendarMonth = DateTime(year, month + 1);
                  }),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 星期头
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: ['一', '二', '三', '四', '五', '六', '日'].map((d) =>
                SizedBox(
                  width: 40,
                  child: Text(d,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ),
              ).toList(),
            ),
            const SizedBox(height: 6),
            // 日历网格
            Wrap(
              spacing: 0,
              runSpacing: 4,
              children: cells,
            ),
            const SizedBox(height: 12),
            // 图例
            Row(
              children: [
                Text('少', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                const SizedBox(width: 4),
                Container(width: 16, height: 16, decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Container(width: 16, height: 16, decoration: BoxDecoration(color: Colors.green.shade300, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Container(width: 16, height: 16, decoration: BoxDecoration(color: Colors.green.shade500, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Container(width: 16, height: 16, decoration: BoxDecoration(color: Colors.green.shade700, borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Text('多', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _authSub?.close();
    super.dispose();
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
        statusText = '有效 — 到期日: ${expiresStr!.substring(0, 10)}';
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

  // ── CEFR 仪表盘辅助方法 ──

  Widget _buildCefrBar(Map<String, dynamic> stat) {
    final level = stat['level'] as String? ?? '';
    final total = stat['total'] as int? ?? 0;
    final mastered = stat['mastered'] as int? ?? 0;
    final ratio = total > 0 ? mastered / total : 0.0;
    return _CefrBar(level: level, total: total, mastered: mastered, ratio: ratio);
  }

  Widget _buildCefrTotal(List<Map<String, dynamic>> stats) {
    int totalMastered = 0, totalAll = 0;
    for (final s in stats) {
      totalMastered += s['mastered'] as int? ?? 0;
      totalAll += s['total'] as int? ?? 0;
    }
    final pct = totalAll > 0 ? (totalMastered * 100 / totalAll).toStringAsFixed(1) : '0.0';
    return Row(
      children: [
        Text('总计', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
        const Spacer(),
        Text('$totalMastered / $totalAll ($pct%)',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
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
