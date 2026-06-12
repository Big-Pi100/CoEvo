import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../config/k12_subjects.dart';
import '../theme/app_theme.dart';

/// K12 结构化学习 — 选科+选年级入口
///
/// 数据源改为 API 驱动，从 /api/k12/subjects 获取科目元数据。
/// 颜色和图标从本地 fallback 字典获取。
class K12SubjectScreen extends ConsumerStatefulWidget {
  const K12SubjectScreen({super.key});

  @override
  ConsumerState<K12SubjectScreen> createState() => _K12SubjectScreenState();
}

class _K12SubjectScreenState extends ConsumerState<K12SubjectScreen> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  bool _loading = false;
  bool _subjectsLoading = true;
  String? _error;
  List<Map<String, dynamic>> _subjects = [];

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  Future<void> _loadSubjects() async {
    setState(() { _subjectsLoading = true; _error = null; });
    try {
      final auth = ref.read(authProvider);
      final client = ChatClient(
        userId: auth.userId ?? 'default_user',
        token: auth.token,
      );
      final subjects = await client.getK12Subjects();
      if (mounted) {
        setState(() {
          _subjects = subjects;
          _subjectsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = '加载失败: $e'; _subjectsLoading = false; });
      }
    }
  }

  Future<void> _selectSubject(Map<String, dynamic> subjectData) async {
    final code = (subjectData['subject'] as String?) ?? '';
    final displayName = (subjectData['display_name'] as String?) ?? code;

    // 从 fallback 获取年级列表
    final fallback = k12SubjectFallbacks[code];
    final grades = fallback?.k12Grades ?? ['g1-2', 'g3-4', 'g5-6', 'g7-9', 'g10-12'];

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
    if (gradeBand == null || !mounted) return;

    setState(() { _loading = true; _error = null; });

    try {
      final auth = ref.read(authProvider);
      final client = ChatClient(
        userId: auth.userId ?? 'default_user',
        token: auth.token,
      );
      final result = await client.k12Init(subject: code, gradeBand: gradeBand);
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
      body: _subjectsLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _subjects.isEmpty
              ? Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)))
              : _buildContent(theme),
    );
  }

  Widget _buildContent(ThemeData theme) {
    return Padding(
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
                childAspectRatio: 1.0,
              ),
              itemCount: _subjects.length,
              itemBuilder: (ctx, i) {
                final s = _subjects[i];
                final code = (s['subject'] as String?) ?? '';
                final displayName = (s['display_name'] as String?) ?? code;
                final title = s['title'] as String? ?? '';
                final author = s['author'] as String? ?? '';
                final fallback = k12SubjectFallbacks[code];
                final color = fallback?.color ?? theme.colorScheme.primary;
                final icon = fallback?.icon ?? Icons.school;

                return Card(
                  color: color.withAlpha(20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: color.withAlpha(60), width: 0.5),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: _loading ? null : () => _selectSubject(s),
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.spacingSm),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, color: color, size: 28),
                          const SizedBox(height: AppTheme.spacingXs),
                          Text(
                            displayName,
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (title.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              title,
                              style: theme.textTheme.bodySmall?.copyWith(color: _cs.onSurfaceVariant, fontSize: 10),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          if (author.isNotEmpty) ...[
                            const SizedBox(height: 1),
                            Text(
                              author,
                              style: TextStyle(color: _cs.onSurfaceVariant.withAlpha(150), fontSize: 9),
                              textAlign: TextAlign.center,
                            ),
                          ],
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
    );
  }
}
