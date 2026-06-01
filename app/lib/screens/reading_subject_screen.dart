import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';

/// 课文阅读模式 — 语文独立入口（reading_first / nursery_rhyme）
class ReadingSubjectScreen extends ConsumerStatefulWidget {
  const ReadingSubjectScreen({super.key});

  @override
  ConsumerState<ReadingSubjectScreen> createState() => _ReadingSubjectScreenState();
}

class _ReadingSubjectScreenState extends ConsumerState<ReadingSubjectScreen> {
  bool _loading = false;
  String? _error;

  // 支持课文阅读模式的科目
  static const _availableSubjects = <String, List<String>>{
    // 语文用国内K12课文（已建 reading_plan）
    'chinese': ['g7-9', 'g10', 'g11-12'],
  };

  static const _subjectDisplayNames = <String, String>{
    'chinese': '语文',
  };

  static const _gradeNames = {
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
        title: Text('选择 ${_subjectDisplayNames[subject] ?? subject} 年级'),
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
      final result = await client.k12ReadingInit(subject: subject, gradeBand: gradeBand);
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
        title: const Text('课文阅读学习'),
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
                Text('正在初始化课文阅读计划...'),
              ],
            ))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择科目', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('基于课文组织的母语级阅读学习，每篇课文聚焦一个教学点',
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
                          color: Colors.blue.shade50,
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
                                    '课文阅读',
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
}
