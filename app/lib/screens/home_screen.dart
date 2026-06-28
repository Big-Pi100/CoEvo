import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../api/chat_client.dart';
import '../api/api_config.dart';
import '../providers/auth_provider.dart';
import '../config/k12_subjects.dart';
import 'chat_screen.dart';
import '../theme/app_theme.dart';
import '../pages/user/distribution/notification_panel.dart';
import '../widgets/claim_dialog.dart';

/// 首页 — 科目直选 + 模式自动路由
///
/// 数据源改为 API 驱动，从 /api/k12/subjects 获取科目元数据。
/// 颜色和图标从本地 fallback 字典获取。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _loading = true;
  bool _authReady = false;
  List<Map<String, dynamic>> _subjects = [];
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAuth());
    _loadSubjects();
    _loadUnreadCount();
  }

  Future<void> _initAuth() async {
    // 首次创建试用时读取 URL 推广码
    final refCode = _readRefCode();
    final auth = ref.read(authProvider);
    if (!auth.isRestored) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) _initAuth();
      return;
    }
    if (auth.isAuthenticated) {
      // 已认证但未认领的试用账户 → 弹注册框
      if (isTrialAccount(auth.userId) && !await isClaimed()) {
        if (mounted) _showAuthDialog();
        return;
      }
      // 正常用户 → 首页
      if (mounted) setState(() => _authReady = true);
      return;
    }
    // 未认证但已使用过试用 → 弹注册框
    if (AuthNotifier.hasUsedTrial()) {
      if (mounted) _showAuthDialog();
      return;
    }
    // 新用户：自动创建临时账户（携带推广码，后端直接绑定关系）
    await ref.read(authProvider.notifier).trialStart(refCode: refCode);
    if (mounted) {
      final updated = ref.read(authProvider);
      if (updated.isAuthenticated) {
        // 来自推广链接的新用户 → 弹注册框
        if (refCode != null && refCode.isNotEmpty) {
          if (mounted) _showAuthDialog();
        } else {
          setState(() => _authReady = true);
        }
      }
    }
  }

  void _showAuthDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const ClaimDialog(),
    ).then((_) {
      if (mounted) setState(() => _authReady = true);
    });
  }

  String? _readRefCode() {
    try {
      return GoRouter.of(context).state.uri.queryParameters['ref'];
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadUnreadCount() async {
    try {
      final auth = ref.read(authProvider);
      if (auth.userId == null || auth.token == null) return;
      final uri = Uri.parse(
          '${ApiConfig.baseUrl}/api/notifications?user_id=${auth.userId}');
      final resp = await http
          .get(uri, headers: {'Authorization': 'Bearer ${auth.token}'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final count = (data['unread_count'] as num?)?.toInt() ?? 0;
        setState(() => _unreadCount = count);
      }
    } catch (_) {
      // 网络异常时不阻塞页面加载
    }
  }

  Future<void> _loadSubjects() async {
    try {
      final auth = ref.read(authProvider);
      final client = ChatClient(
        userId: auth.userId ?? 'default_user',
        token: auth.token,
      );
      final subjects = await client.getK12Subjects();
      if (mounted) {
        setState(() { _subjects = subjects; _loading = false; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 认证初始化中 → 显示 loading
    if (!_authReady) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32, height: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 24),
              Text(
                'CoEvo 刻意进化',
                style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurfaceVariant.withAlpha(150)),
              ),
              const SizedBox(height: 8),
              Text(
                '正在为你创建学习空间...',
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant.withAlpha(100)),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('刻意进化'),
        automaticallyImplyLeading: false,
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
            icon: const Icon(Icons.person),
            onPressed: () {
              if (AuthNotifier.hasUsedTrial() && !ref.read(authProvider).isAuthenticated) {
                _showAuthDialog();
              } else {
                context.push('/profile');
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingLg),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Header
            Text('今天想学什么？', style: theme.textTheme.headlineMedium),
            const SizedBox(height: AppTheme.spacingXs),
            Text('选择科目开始结构化学习',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: AppTheme.spacingLg),

            // 自由对话入口
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withAlpha(30),
                  child: Icon(Icons.chat, color: theme.colorScheme.primary),
                ),
                title: Text('开始对话', style: theme.textTheme.titleMedium),
                subtitle: const Text('和 AI 自由对话学习新知识'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  ref.read(currentConversationIdProvider.notifier).state = null;
                  context.push('/chat');
                },
              ),
            ),
            const SizedBox(height: AppTheme.spacingLg),

            // 历史对话入口
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  child: Icon(Icons.history, color: theme.colorScheme.tertiary),
                ),
                title: Text('历史对话', style: theme.textTheme.titleMedium),
                subtitle: const Text('继续之前的对话，或恢复已学习内容'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final convId = await context.push<String>('/conversations');
                  if (convId != null && context.mounted) {
                    ref.read(currentConversationIdProvider.notifier).state = null;
                    context.push('/chat', extra: convId);
                  }
                },
              ),
            ),
            const SizedBox(height: AppTheme.spacingLg),

            // 科目网格
            Text('科目', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: AppTheme.spacingSm),
            _loading
                ? const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                : _subjects.isEmpty
                    ? Padding(padding: const EdgeInsets.all(32),
                        child: Center(child: Text('暂无可用的学习计划', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))))
                    : GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 0.9,
                          ),
                          itemCount: _subjects.length,
                          itemBuilder: (ctx, i) {
                            final s = _subjects[i];
                            final code = (s['subject'] as String?) ?? '';
                            final displayName = (s['display_name'] as String?) ?? code;
                            final fallback = k12SubjectFallbacks[code];
                            final color = fallback?.color ?? theme.colorScheme.primary;
                            final icon = fallback?.icon ?? Icons.school;

                            return _SubjectCard(
                              name: displayName,
                              color: color,
                              icon: icon,
                              onTap: () => _startSubject(context, s, fallback),
                            );
                          },
                        ),
          ],
        ),
      ),
    ),
  );
}

  Future<void> _startSubject(
    BuildContext context,
    Map<String, dynamic> subjectData,
    K12SubjectConfig? fallback,
  ) async {
    final code = (subjectData['subject'] as String?) ?? '';
    final displayName = (subjectData['display_name'] as String?) ?? code;

    // 从 fallback 或默认值获取年级列表
    List<String> homeGrades = fallback?.homeGrades ?? ['g1-2', 'g5-6', 'g7-9', 'g10', 'g11-12'];

    // 合并高中选项（g10 + g11-12 → g10-12），前端统一显示为"高中"
    List<String> grades = List.from(homeGrades);
    final hasG10 = grades.contains('g10');
    final hasG1112 = grades.contains('g11-12');
    if (hasG10 || hasG1112) {
      grades = grades
          .where((g) => g != 'g10' && g != 'g11-12')
          .toList()
        ..add('g10-12');
    }

    // 选择年级
    final gradeBand = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('选择 $displayName 年级'),
        children: grades.map((g) => SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(g),
          child: Text(k12GradeNames[g] ?? g),
        )).toList(),
      ),
    );
    if (gradeBand == null || !context.mounted) return;

    try {
      final auth = ref.read(authProvider);
      final client = ChatClient(
        userId: auth.userId ?? 'default_user',
        token: auth.token,
      );

      final result = await client.k12Init(subject: code, gradeBand: gradeBand);

      final convId = result['conversation_id'] as String?;
      if (convId != null && context.mounted) {
        context.replace('/chat', extra: convId);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('初始化失败: $e')),
        );
      }
    }
  }
}

/// 科目卡片
class _SubjectCard extends StatelessWidget {
  final String name;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  const _SubjectCard({
    required this.name,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withAlpha(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withAlpha(60), width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 6),
            Text(name,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
