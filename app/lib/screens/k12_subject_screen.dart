import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../config/k12_subjects.dart';
import '../theme/app_theme.dart';

/// K12 结构化学习 — 选科+选年级入口
class K12SubjectScreen extends ConsumerStatefulWidget {
  const K12SubjectScreen({super.key});

  @override
  ConsumerState<K12SubjectScreen> createState() => _K12SubjectScreenState();
}

class _K12SubjectScreenState extends ConsumerState<K12SubjectScreen> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;
  bool _loading = false;
  String? _error;

  /// 只渲染 visible 的科目
  List<K12SubjectConfig> get _visibleSubjects => k12VisibleSubjects;

  Future<void> _selectSubject(K12SubjectConfig cfg) async {
    final grades = cfg.k12Grades;

    final gradeBand = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('选择 ${cfg.displayName} 年级'),
        children: grades.map((g) => SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(g),
          child: Text(k12GradeNames[g] ?? g),
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
      final result = await client.k12Init(subject: cfg.code, gradeBand: gradeBand);
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
    final visibleSubjects = _visibleSubjects;

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
                SizedBox(height: AppTheme.spacingLg),
                Text('正在初始化学习计划...'),
              ],
            ))
          : Padding(
              padding: const EdgeInsets.all(AppTheme.spacingLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择科目', style: theme.textTheme.titleLarge),
                  const SizedBox(height: AppTheme.spacingXs),
                  Text('按课程标准预生成的学习计划，选择年级后自动导入',
                      style: theme.textTheme.bodyMedium?.copyWith(color: _cs.onSurfaceVariant)),
                  if (_error != null) ...[
                    const SizedBox(height: AppTheme.spacingSm),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: AppTheme.spacingLg),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.2,
                      ),
                      itemCount: visibleSubjects.length,
                      itemBuilder: (ctx, i) {
                        final cfg = visibleSubjects[i];
                        return Card(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _selectSubject(cfg),
                            child: Padding(
                              padding: const EdgeInsets.all(AppTheme.spacingSm),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    cfg.displayName,
                                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: AppTheme.spacingXs),
                                  Text(
                                    _gradeRangeLabel(cfg.k12Grades),
                                    style: theme.textTheme.bodySmall?.copyWith(color: _cs.onSurfaceVariant),
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
    final first = k12GradeNames[grades.first] ?? '';
    if (grades.length == 1) return first;
    final lastLabel = k12GradeNames[grades.last] ?? '';
    return '$first ~ $lastLabel';
  }
}

