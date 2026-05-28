import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';

/// 首页 — 科目直选 + 模式自动路由
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  // 科目列表（key=中文名, value=可用学段）
  static const _subjects = <String, List<String>>{
    '数学': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '语文': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '英语': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '物理': ['g7-9', 'g10', 'g11-12'],
    '化学': ['g7-9', 'g10', 'g11-12'],
    '生物': ['g7-9', 'g10', 'g11-12'],
    '历史': ['g7-9', 'g10', 'g11-12'],
    '地理': ['g7-9', 'g10', 'g11-12'],
    '政治': ['g10', 'g11-12'],
    '科学': ['g3-4', 'g5-6', 'g7-9'],
    '信息技术': ['g1-2', 'g3-4', 'g5-6', 'g7-9'],
    '日语': ['g5-6', 'g7-9', 'g10', 'g11-12'],
    '俄语': ['g7-9', 'g10', 'g11-12'],
  };

  static const _gradeNames = {
    'g1-2': '小学低年级（1-2年级）',
    'g3-4': '小学中年级（3-4年级）',
    'g5-6': '小学高年级（5-6年级）',
    'g7-9': '初中（7-9年级）',
    'g10': '高中一年级',
    'g11-12': '高中二三年级',
  };

  // 科目 → 模式
  static bool _isReadingSubject(String subject) => subject == '语文';

  // 科目颜色
  static const _subjectColors = <String, Color>{
    '数学': Color(0xFFE57373),
    '语文': Color(0xFF64B5F6),
    '英语': Color(0xFF81C784),
    '物理': Color(0xFFFFB74D),
    '化学': Color(0xFFBA68C8),
    '生物': Color(0xFF4DB6AC),
    '历史': Color(0xFFF06292),
    '地理': Color(0xFF4FC3F7),
    '政治': Color(0xFFA1887F),
    '科学': Color(0xFF90A4AE),
    '信息技术': Color(0xFF7986CB),
    '日语': Color(0xFFE0A050),
    '俄语': Color(0xFFC0392B),
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
                onTap: () => context.push('/chat'),
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
                    name: subject,
                    color: color,
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
    // 选择年级
    final gradeBand = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('选择 $subject 年级'),
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

      // 根据科目判定模式，调用对应 API
      final bool isReading = _isReadingSubject(subject);
      final result = isReading
          ? await client.k12ReadingInit(subject: subject, gradeBand: gradeBand)
          : await client.k12Init(subject: subject, gradeBand: gradeBand);

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
  final VoidCallback onTap;

  const _SubjectCard({
    required this.name,
    required this.color,
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
            Icon(Icons.school, color: color, size: 28),
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
