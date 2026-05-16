import 'package:flutter/material.dart';

/// 学习计划面板 — 可折叠的阶段/任务进度视图
class ChatPlanPanel extends StatefulWidget {
  final Map<String, dynamic> plan;

  const ChatPlanPanel({super.key, required this.plan});

  @override
  State<ChatPlanPanel> createState() => _ChatPlanPanelState();
}

class _ChatPlanPanelState extends State<ChatPlanPanel> {
  bool _expanded = true;

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
    final (total, done) = _countProgress(stages);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: total > 0 ? done / total : 0,
          minHeight: 6,
          backgroundColor: Colors.grey.shade200,
          valueColor: AlwaysStoppedAnimation(Theme.of(context).colorScheme.primary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final goal = plan['goal'] as String? ?? '';
    final planJson = plan['plan'] as Map<String, dynamic>? ?? {};
    final stages = planJson['stages'] as List<dynamic>? ?? [];

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withAlpha(30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.school, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(goal, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Text(_progressSummary(stages),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(width: 6),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
          if (_expanded) _buildProgressBar(stages),
          if (_expanded)
            ...stages.map((stage) {
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
                padding: const EdgeInsets.only(left: 14, right: 14, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isActive ? Icons.play_circle_fill : Icons.check_circle,
                          size: 14,
                          color: isActive ? Theme.of(context).colorScheme.primary : Colors.green,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(stageName,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                              color: isActive ? null : Colors.grey,
                            )),
                        ),
                        Text('$doneTasks/${tasks.length}',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: tasks.isEmpty ? 0 : doneTasks / tasks.length,
                        minHeight: 4,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation(
                          stageStatus == 'done' ? Colors.green : Theme.of(context).colorScheme.primary),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...tasks.map((task) {
                      final t = task as Map<String, dynamic>;
                      final taskName = t['name'] as String? ?? '';
                      final taskStatus = t['status'] as String? ?? 'pending';
                      final isTaskActive = taskStatus == 'in_progress';
                      return Padding(
                        padding: const EdgeInsets.only(left: 16, top: 2),
                        child: Row(
                          children: [
                            Icon(
                              taskStatus == 'done' ? Icons.check_circle_outline :
                              isTaskActive ? Icons.radio_button_checked : Icons.radio_button_checked_outlined,
                              size: 12,
                              color: taskStatus == 'done' ? Colors.green :
                                     isTaskActive ? Theme.of(context).colorScheme.primary : Colors.grey.shade400,
                            ),
                            const SizedBox(width: 4),
                            Text(taskName,
                              style: TextStyle(
                                fontSize: 12,
                                color: taskStatus == 'done' ? Colors.green.shade600 :
                                       isTaskActive ? null : Colors.grey.shade500,
                                fontWeight: isTaskActive ? FontWeight.w500 : FontWeight.normal,
                              )),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
