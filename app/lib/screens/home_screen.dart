import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import 'chat_screen.dart';

/// 首页 — 科目直选 + 模式自动路由
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // 科目列表（key=英文代码, value=可用学段）
  static const _subjects = <String, List<String>>{
    'math': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    'chinese': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    'english': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    'physics': ['g7-9', 'g10', 'g11-12'],
    'chemistry': ['g7-9', 'g10', 'g11-12'],
    'biology': ['g7-9', 'g10', 'g11-12'],
    'history': ['g7-9', 'g10', 'g11-12'],
    'geography': ['g7-9', 'g10', 'g11-12'],
    'politics': ['g10', 'g11-12'],
    'science': ['g3-4', 'g5-6', 'g7-9'],
    'it': ['g1-2', 'g3-4', 'g5-6', 'g7-9'],
    'japanese': ['g5-6', 'g7-9', 'g10', 'g11-12'],
    'russian': ['g7-9', 'g10', 'g11-12'],
  };

  // 科目中文显示名
  static const _subjectDisplayNames = <String, String>{
    'math': '数学',
    'chinese': '语文',
    'english': '英语',
    'physics': '物理',
    'chemistry': '化学',
    'biology': '生物',
    'history': '历史',
    'geography': '地理',
    'politics': '政治',
    'science': '科学',
    'it': '信息技术',
    'japanese': '日语',
    'russian': '俄语',
  };

  static const _gradeNames = {
    'g1-2': '小学低年级',
    'g3-4': '小学中年级',
    'g5-6': '小学高年级',
    'g7-9': '初中',
    'g10': '高中一年级',
    'g11-12': '高中二三年级',
    'g10-12': '高中',
  };

  // 科目颜色
  static const _subjectColors = <String, Color>{
    'math': Color(0xFFE57373),
    'chinese': Color(0xFF64B5F6),
    'english': Color(0xFF81C784),
    'physics': Color(0xFFFFB74D),
    'chemistry': Color(0xFFBA68C8),
    'biology': Color(0xFF4DB6AC),
    'history': Color(0xFFF06292),
    'geography': Color(0xFF4FC3F7),
    'politics': Color(0xFFA1887F),
    'science': Color(0xFF90A4AE),
    '信息技术': Color(0xFF7986CB),
    'japanese': Color(0xFFE0A050),
    'russian': Color(0xFFC0392B),
  };

  // 科目图标
  static final _subjectIcons = <String, IconData>{
    'math': Icons.calculate,
    'chinese': Icons.menu_book,
    'english': Icons.language,
    'physics': Icons.science,
    'chemistry': Icons.biotech,
    'biology': Icons.pets,
    'history': Icons.auto_stories,
    'geography': Icons.explore,
    'politics': Icons.account_balance,
    'science': Icons.travel_explore,
    'it': Icons.computer,
    'japanese': Icons.translate,
    'russian': Icons.translate,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('刻意进化学习'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text('今天想学什么？', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text('选择科目开始结构化学习',
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
            const SizedBox(height: 16),

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
            const SizedBox(height: 16),

            // 历史对话入口
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.orange.withAlpha(30),
                  child: Icon(Icons.history, color: Colors.orange.shade700),
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
            const SizedBox(height: 16),

            // 科目网格
            Text('科目', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.9,
                ),
                itemCount: _subjects.length,
                itemBuilder: (ctx, i) {
                  final subject = _subjects.keys.elementAt(i);
                  final color = _subjectColors[subject] ?? Colors.grey;
                  final grades = _subjects[subject]!;
                  return _SubjectCard(
                    name: _subjectDisplayNames[subject] ?? subject,
                    color: color,
                    icon: _subjectIcons[subject] ?? Icons.school,
                    onTap: () => _startSubject(context, ref, subject, grades),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startSubject(
    BuildContext context,
    WidgetRef ref,
    String subject,
    List<String> grades,
  ) async {
    // 合并高中选项（g10 + g11-12 → g10-12），前端统一显示为"高中"
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
        title: Text('选择 ${_subjectDisplayNames[subject] ?? subject} 年级'),
        children: grades.map((g) => SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(g),
          child: Text(_gradeNames[g] ?? g),
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

      final result = await client.k12Init(subject: subject, gradeBand: gradeBand);

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
