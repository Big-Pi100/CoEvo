import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/coevo_models.dart';
import '../../api/chat_client.dart';
import '../../providers/auth_provider.dart';

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

    showDialog(
      context: context,
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
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
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
                  for (int i = start(); i < end(); i++) {
                    if (!selected[i]) {
                      client?.skipConcept(candidates[i].front, candidates[i].sourceSentence ?? '');
                    }
                  }
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
                child: Text(isLastPage() ? '完成' : '跳过并继续'),
              ),
              FilledButton(
                onPressed: () async {
                  final toCreate = <Map<String, dynamic>>[];
                  for (int i = start(); i < end(); i++) {
                    if (selected[i]) {
                      toCreate.add({
                        'front': candidates[i].front,
                        'back': candidates[i].back ?? candidates[i].front,
                        'source_sentence': candidates[i].sourceSentence ?? '',
                        'domain': candidates[i].domain ?? 'general',
                      });
                    } else {
                      client?.skipConcept(candidates[i].front, candidates[i].sourceSentence ?? '');
                    }
                  }
                  if (toCreate.isNotEmpty && client != null) {
                    final result = await client.batchCreateCards(toCreate);
                    if (context.mounted) {
                      final count = (result['created'] as List?)?.length ?? 0;
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
                child: Text(isLastPage() ? '确认制卡' : '确认并继续'),
              ),
            ],
          );
        },
      ),
    );
  }
}
