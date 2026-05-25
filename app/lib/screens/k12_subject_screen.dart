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

  static const _subjects = [
    '数学', '语文', '英语', '物理', '化学', '生物',
    '历史', '地理', '政治', '科学', '信息技术',
    '体育', '艺术', '日语', '俄语',
  ];

  static const _grades = [
    ('g1-2', '小学低年级（1-2年级）'),
    ('g3-4', '小学中年级（3-4年级）'),
    ('g5-6', '小学高年级（5-6年级）'),
    ('g7-9', '初中（7-9年级）'),
    ('g10', '高中一年级'),
    ('g11-12', '高中二三年级'),
  ];

  Future<void> _selectSubject(String subject) async {
    final gradeBand = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('选择 $subject 年级'),
        children: _grades.map((g) => SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(g.$1),
          child: Text(g.$2),
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
        setState(() { _error = '初始化失败，请重试'; _loading = false; });
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
          onPressed: () => context.go('/chat'),
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
                        return Card(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _selectSubject(subject),
                            child: Center(
                              child: Text(
                                subject,
                                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
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
}
