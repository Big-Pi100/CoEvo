import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// 学习计划面板 — 可折叠的阶段/任务进度视图
class ChatPlanPanel extends StatefulWidget {
  final Map<String, dynamic> plan;
  /// 父级通过 push 此 notifier 来触发收起（如点击聊天区域）
  final ValueNotifier<int>? collapseSignal;

  const ChatPlanPanel({super.key, required this.plan, this.collapseSignal});

  @override
  State<ChatPlanPanel> createState() => _ChatPlanPanelState();
}

class _ChatPlanPanelState extends State<ChatPlanPanel> {
  bool _expanded = false; // 默认收起

  @override
  void initState() {
    super.initState();
    widget.collapseSignal?.addListener(_onCollapseSignal);
  }

  @override
  void dispose() {
    widget.collapseSignal?.removeListener(_onCollapseSignal);
    super.dispose();
  }

  void _onCollapseSignal() {
    if (_expanded && mounted) {
      setState(() => _expanded = false);
    }
  }

  String _progressSummary(List<dynamic> stages) {
    int total = 0, done = 0;
    for (final stage in stages) {
      final s = stage as Map<String, dynamic>;
      final tasks = s['tasks'] as List<dynamic>? ?? [];
      for (final t in tasks) {
        total++;
        final ts = t is Map ? (t['status'] as String? ?? '') : '';
        if (ts == 'done') done++;
      }
    }
    return total > 0 ? '$done/$total' : '';
  }

  (int, int) _countProgress(List<dynamic> stages) {
    int total = 0, done = 0;
    for (final stage in stages) {
      final s = stage as Map<String, dynamic>;
      final tasks = s['tasks'] as List<dynamic>? ?? [];
      for (final t in tasks) {
        total++;
        final ts = t is Map ? (t['status'] as String? ?? '') : '';
        if (ts == 'done') done++;
      }
    }
    return (total, done);
  }

  Widget _buildProgressBar(List<dynamic> stages) {
    final colorScheme = Theme.of(context).colorScheme;
    final (total, done) = _countProgress(stages);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: total > 0 ? done / total : 0,
          minHeight: 6,
          backgroundColor: colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(Theme.of(context).colorScheme.primary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final plan = widget.plan;
    final goal = plan['goal'] as String? ?? '';
    final planJson = plan['plan'] as Map<String, dynamic>? ?? {};
    final stages = planJson['stages'] as List<dynamic>? ?? [];

    return Container(
      margin: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
      decoration: BoxDecoration(
        color: colorScheme.primary.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withAlpha(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 头部：点击切换展开/收起 ──
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.vertical(top: const Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.school, size: 18, color: colorScheme.primary),
                  const SizedBox(width: AppTheme.spacingSm),
                  Expanded(
                    child: Text(goal, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Text(_progressSummary(stages),
                    style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.unfold_less : Icons.unfold_more,
                    size: 18,
                    color: colorScheme.primary.withAlpha(180),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            _buildProgressBar(stages),
            // ── 可滚动 stage 列表 ──
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: Scrollbar(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: AppTheme.spacingSm),
                  children: stages.map((stage) {
                    final s = stage as Map<String, dynamic>;
                    final stageName = s['name'] as String? ?? '';
                    final stageStatus = s['status'] as String? ?? 'pending';
                    final tasks = s['tasks'] as List<dynamic>? ?? [];
                    final isActive = stageStatus == 'in_progress';
                    final doneTasks = tasks.where((t) {
                      final ts = t is Map ? (t['status'] as String? ?? '') : '';
                      return ts == 'done';
                    }).length;

                    return Padding(
                      padding: const EdgeInsets.only(left: 14, right: 14, bottom: AppTheme.spacingSm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isActive ? Icons.play_circle_fill : Icons.check_circle,
                                size: 14,
                                color: isActive ? colorScheme.primary : colorScheme.tertiary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(stageName,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                                    color: isActive ? null : colorScheme.outline,
                                  )),
                              ),
                              Text('$doneTasks/${tasks.length}',
                                style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                            ],
                          ),
                          const SizedBox(height: AppTheme.spacingXs),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: tasks.isEmpty ? 0 : doneTasks / tasks.length,
                              minHeight: 4,
                              backgroundColor: colorScheme.surfaceContainerHighest,
                              valueColor: AlwaysStoppedAnimation(
                                stageStatus == 'done' ? colorScheme.tertiary : colorScheme.primary),
                            ),
                          ),
                          const SizedBox(height: AppTheme.spacingXs),
                          ...tasks.map((task) {
                            final t = task as Map<String, dynamic>;
                            final taskName = t['name'] as String? ?? '';
                            final taskStatus = t['status'] as String? ?? 'pending';
                            final isTaskActive = taskStatus == 'in_progress';
                            return Padding(
                              padding: const EdgeInsets.only(left: AppTheme.spacingLg, top: 2),
                              child: Row(
                                children: [
                                  Icon(
                                    taskStatus == 'done' ? Icons.check_circle_outline :
                                    isTaskActive ? Icons.radio_button_checked : Icons.radio_button_checked_outlined,
                                    size: 12,
                                    color: taskStatus == 'done' ? colorScheme.tertiary :
                                           isTaskActive ? colorScheme.primary : colorScheme.outline,
                                  ),
                                  const SizedBox(width: AppTheme.spacingXs),
                                  Text(taskName,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: taskStatus == 'done' ? colorScheme.tertiary :
                                             isTaskActive ? null : colorScheme.onSurfaceVariant,
                                      fontWeight: isTaskActive ? FontWeight.w500 : FontWeight.normal,
                                    )),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
          // ── 底部收起/展开按钮已合并到头部 ──
        ],
      ),
    );
  }
}
