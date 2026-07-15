import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dialog_queue_provider.dart';
import '../../providers/plan_provider.dart' hide cardRefreshProvider;
import '../../theme/app_theme.dart';

/// 制卡确认弹窗 — 分页展示候选概念，用户勾选确认或跳过
class ConceptDialog {
  /// Show the card-creation confirmation dialog.
  /// [candidates]: concepts extracted from AI reply
  /// [client]: chat client for batch-create / skip API calls
  /// [ref]: Riverpod ref for refreshing card count
  static void show(
    BuildContext context, {
    required List<ConceptCandidate> candidates,
    required ChatClient? client,
    required WidgetRef ref,
    String? conversationId,
    bool useDialogQueue = false,
  }) {
    if (candidates.isEmpty) return;

    const pageSize = 5;
    final totalPages = (candidates.length + pageSize - 1) ~/ pageSize;
    final selected = List.generate(candidates.length, (_) => true);
    var page = 0;

    void nextPage() => page++;
    int start() => page * pageSize;
    int end() => (start() + pageSize).clamp(0, candidates.length);
    List<ConceptCandidate> pageItems() => candidates.sublist(start(), end());
    bool isLastPage() => page >= totalPages - 1;

    // DialogQueue 模式
    if (useDialogQueue) {
      final dialogId = 'concept_${DateTime.now().millisecondsSinceEpoch}';
      
      Widget buildContent(BuildContext ctx, void Function(void Function()) setDialogState) {
        return AlertDialog(
          title: Text('发现知识点 (${page + 1}/$totalPages)'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('第 ${start() + 1}~${end()} 条 / 共 ${candidates.length} 条',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: AppTheme.spacingSm),
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: pageItems().length,
                  itemBuilder: (_, i) {
                    final realIdx = start() + i;
                    return CheckboxListTile(
                      title: Text(pageItems()[i].front),
                      subtitle: pageItems()[i].back != null
                          ? Text(pageItems()[i].back!, maxLines: 2, overflow: TextOverflow.ellipsis)
                          : null,
                      value: selected[realIdx],
                      onChanged: (v) => setDialogState(() => selected[realIdx] = v ?? false),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (isLastPage()) {
                  ref.read(dialogQueueProvider.notifier).dequeue();
                } else {
                  for (int i = (page + 1) * pageSize;
                       i < ((page + 1) * pageSize + pageSize).clamp(0, candidates.length);
                       i++) {
                    selected[i] = true;
                  }
                  nextPage();
                  setDialogState(() {});
                }
              },
              child: Text(isLastPage() ? '跳过' : '跳过并继续'),
            ),
            FilledButton(
              onPressed: () async {
                final toCreate = <String>[];
                for (int i = start(); i < end(); i++) {
                  final cardId = candidates[i].id;
                  if (cardId == null) continue;
                  if (selected[i]) {
                    toCreate.add(cardId);
                  } else {
                    client?.updateCardStatus(cardId, 'skipped');
                  }
                }
                if (toCreate.isNotEmpty && client != null) {
                  final result = await client.batchUpdateStatus(toCreate, 'active');
                  if (context.mounted) {
                    final count = (result['updated'] as num?)?.toInt() ?? 0;
                    if (count > 0) ref.read(cardRefreshProvider.notifier).state++;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已创建 $count 张卡片'),
                        behavior: SnackBarBehavior.floating,
                        margin: EdgeInsets.only(
                          bottom: MediaQuery.of(context).size.height - 120,
                          left: 16,
                          right: 16,
                        ),
                      ),
                    );
                  }
                }
                if (isLastPage()) {
                  ref.read(dialogQueueProvider.notifier).dequeue();
                } else {
                  for (int i = (page + 1) * pageSize;
                       i < ((page + 1) * pageSize + pageSize).clamp(0, candidates.length);
                       i++) {
                    selected[i] = true;
                  }
                  nextPage();
                  setDialogState(() {});
                }
              },
              child: Text(isLastPage() ? '确认制卡' : '确认并继续'),
            ),
          ],
        );
      }

      ref.read(dialogQueueProvider.notifier).enqueue(
        DialogItem(
          id: dialogId,
          priority: DialogPriority.P2_CP1_CONCEPT,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => buildContent(ctx, setDialogState),
          ),
        ),
      );
      return;
    }

    // 原始模式：直接 showDialog
    showDialog(
      context: context,
      barrierDismissible: false, // 只允许按钮关闭，防止误触
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text('发现知识点 (${page + 1}/$totalPages)'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('第 ${start() + 1}~${end()} 条 / 共 ${candidates.length} 条',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: AppTheme.spacingSm),
                  ListView.builder(
                    shrinkWrap: true,
                    itemCount: pageItems().length,
                    itemBuilder: (_, i) {
                      final realIdx = start() + i;
                      return CheckboxListTile(
                        title: Text(pageItems()[i].front),
                        subtitle: pageItems()[i].back != null
                            ? Text(pageItems()[i].back!, maxLines: 2, overflow: TextOverflow.ellipsis)
                            : null,
                        value: selected[realIdx],
                        onChanged: (v) => setDialogState(() => selected[realIdx] = v ?? false),
                      );
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // 不再逐个跳过 — 待确认卡片保持 pending 状态，待批量更新
                  if (isLastPage()) {
                    Navigator.pop(ctx);
                  } else {
                    for (int i = (page + 1) * pageSize;
                         i < ((page + 1) * pageSize + pageSize).clamp(0, candidates.length);
                         i++) {
                      selected[i] = true;
                    }
                    nextPage();
                    setDialogState(() {});
                  }
                },
                child: Text(isLastPage() ? '跳过' : '跳过并继续'),
              ),
              FilledButton(
                onPressed: () async {
                  final toCreate = <String>[];
                  for (int i = start(); i < end(); i++) {
                    final cardId = candidates[i].id;
                    if (cardId == null) continue;
                    if (selected[i]) {
                      toCreate.add(cardId);
                    } else {
                      client?.updateCardStatus(cardId, 'skipped');
                    }
                  }
                  if (toCreate.isNotEmpty && client != null) {
                    final result = await client.batchUpdateStatus(toCreate, 'active');
                    if (context.mounted) {
                      final count = (result['updated'] as num?)?.toInt() ?? 0;
                      if (count > 0) ref.read(cardRefreshProvider.notifier).state++;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已创建 $count 张卡片'),
                          behavior: SnackBarBehavior.floating,
                          margin: EdgeInsets.only(
                            bottom: MediaQuery.of(context).size.height - 120,
                            left: 16,
                            right: 16,
                          ),
                        ),
                      );
                    }
                  }
                  if (isLastPage()) {
                    if (ctx.mounted) Navigator.pop(ctx);
                  } else {
                    for (int i = (page + 1) * pageSize;
                         i < ((page + 1) * pageSize + pageSize).clamp(0, candidates.length);
                         i++) {
                      selected[i] = true;
                    }
                    nextPage();
                    setDialogState(() {});
                  }
                },
                child: Text(isLastPage() ? '确认制卡' : '确认并继续'),
              ),
            ],
          );
        },
      ),
    );
  }
}
