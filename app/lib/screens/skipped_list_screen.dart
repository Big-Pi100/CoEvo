import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../widgets/empty_state.dart';

class SkippedListScreen extends ConsumerStatefulWidget {
  const SkippedListScreen({super.key});

  @override
  ConsumerState<SkippedListScreen> createState() => _SkippedListScreenState();
}

class _SkippedListScreenState extends ConsumerState<SkippedListScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  bool _hasLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    ref.listenManual(authProvider, (prev, next) {
      if (!_hasLoadedOnce && next.userId != null) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getSkippedConcepts();
      setState(() {
        _items = (resp['skipped'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
        _isLoading = false;
        _hasLoadedOnce = true;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _remove(String id) async {
    final auth = ref.read(authProvider);
    if (auth.token == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      await client.deleteSkipped(id);
      setState(() => _items.removeWhere((i) => i['id'] == id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已取消跳过，该概念将重新出现')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跳过的概念'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                setState(() => _isLoading = true);
                await _load();
              },
              child: _items.isEmpty
                  ? ListView(
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.6,
                          child: const EmptyState(
                            icon: Icons.inbox,
                            title: '没有跳过的概念',
                            subtitle: '对话中弹出的知识点如果不感兴趣可以跳过',
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: _items.length,
                  itemBuilder: (_, i) {
                    final item = _items[i];
                    final front = item['front'] as String? ?? '';
                    final source = item['source_text'] as String? ?? '';
                    final skippedAt = item['skipped_at'] as int? ?? 0;
                    final date = skippedAt > 0
                        ? DateTime.fromMillisecondsSinceEpoch(skippedAt * 1000)
                            .toString().substring(0, 16)
                        : '';
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange.withAlpha(30),
                          child: const Icon(Icons.skip_next, color: Colors.orange),
                        ),
                        title: Text(front, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          source.isNotEmpty ? '来源: $source' : '跳过于 $date',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: TextButton.icon(
                          icon: const Icon(Icons.undo, size: 18),
                          label: const Text('取消跳过'),
                          onPressed: () => _remove(item['id'] as String),
                        ),
                      ),
                    );
                  },
                ),
              ),
    );
  }
}
