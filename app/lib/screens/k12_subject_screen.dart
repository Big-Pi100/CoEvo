import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';

/// K12 结构化学习 — 选科+选年级入口
class K12SubjectScreen extends ConsumerStatefulWidget {
  const K12SubjectScreen({super.key});

  @override
  ConsumerState<K12SubjectScreen> createState() => _K12SubjectScreenState();
}

class _K12SubjectScreenState extends ConsumerState<K12SubjectScreen> {
  bool _loading = false;
  String? _error;

  // 有预生成计划的科目（按课标实际覆盖的学段过滤）
  // key=科目名, value=可用学段列表
  static const _availableSubjects = <String, List<String>>{
    '数学': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '语文': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '英语': ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10', 'g11-12'],
    '物理': ['g7-9', 'g10', 'g11-12'],
    '化学': ['g7-9', 'g10', 'g11-12'],
    '生物': ['g7-9', 'g10', 'g11-12'],
    '历史': ['g7-9', 'g10', 'g11-12'],
    '地理': ['g7-9', 'g10', 'g11-12'],
    '政治': ['g10', 'g11-12'],
    '科学': ['g1-2', 'g5-6', 'g7-9'],
    '信息技术': ['g1-2', 'g3-4', 'g5-6', 'g7-9'],
    '体育': ['g1-2', 'g3-4', 'g5-6', 'g7-9'],
    '日语': ['g3-4', 'g5-6', 'g7-9'],
    '俄语': ['g7-9'],
  };

  static const _gradeNames = {
    'g1-2': '小学低年级（1-2年级）',
    'g3-4': '小学中年级（3-4年级）',
    'g5-6': '小学高年级（5-6年级）',
    'g7-9': '初中（7-9年级）',
    'g10': '高中一年级',
    'g11-12': '高中二三年级',
  };

  List<String> get _subjects => _availableSubjects.keys.toList();

  Future<void> _selectSubject(String subject) async {
    final grades = _availableSubjects[subject]!;

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
    if (gradeBand == null || !mounted) return;

    setState(() { _loading = true; _error = null; });

    try {
      final auth = ref.read(authProvider);
      final client = ChatClient(
        userId: auth.userId ?? 'default_user',
        token: auth.token,
      );
      final result = await client.k12Init(subject: subject, gradeBand: gradeBand);
      final convId = result['conversation_id'] as String?;

      if (convId != null && mounted) {
        context.replace('/chat', extra: convId);
      } else {
        setState(() {
          _error = result['error'] as String? ?? '初始化失败，请重试';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() { _error = '初始化失败: $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('K12 结构化学习'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: _loading
          ? const Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在初始化学习计划...'),
              ],
            ))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择科目', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('按课程标准预生成的学习计划，选择年级后自动导入',
                      style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey)),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.2,
                      ),
                      itemCount: _subjects.length,
                      itemBuilder: (ctx, i) {
                        final subject = _subjects[i];
                        final grades = _availableSubjects[subject]!;
                        return Card(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _selectSubject(subject),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    subject,
                                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _gradeRangeLabel(grades),
                                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _gradeRangeLabel(List<String> grades) {
    if (grades.isEmpty) return '';
    final first = _gradeNames[grades.first] ?? '';
    if (grades.length == 1) return first;
    final lastLabel = _gradeNames[grades.last] ?? '';
    return '$first ~ $lastLabel';
  }
}
