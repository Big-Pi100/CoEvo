import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';

class ConversationListScreen extends ConsumerStatefulWidget {
  const ConversationListScreen({super.key});

  @override
  ConsumerState<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends ConsumerState<ConversationListScreen> {
  List<Map<String, dynamic>> _conversations = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;
    final client = ChatClient(userId: auth.userId!, token: auth.token);
    try {
      final resp = await client.getConversationList();
      setState(() {
        _conversations = (resp['conversations'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('对话列表')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text('还没有对话', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: () => context.go('/chat'),
                        icon: const Icon(Icons.add),
                        label: const Text('开始新对话'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _conversations.length,
                  itemBuilder: (_, i) {
                    final conv = _conversations[i];
                    final title = conv['title'] as String? ?? '新对话';
                    final turnCount = conv['turn_count'] as int? ?? 0;
                    final startedAtStr = conv['started_at'] as String? ?? '';
                    // 相对时间格式化
                    String dateLabel;
                    try {
                      final dt = DateTime.parse(startedAtStr).toLocal();
                      final now = DateTime.now();
                      final diff = now.difference(dt);
                      if (diff.inMinutes < 1) {
                        dateLabel = '刚刚';
                      } else if (diff.inHours < 1) {
                        dateLabel = '${diff.inMinutes} 分钟前';
                      } else if (diff.inDays < 1) {
                        dateLabel = DateFormat('HH:mm').format(dt);
                      } else if (diff.inDays < 7) {
                        dateLabel = '${diff.inDays} 天前';
                      } else {
                        dateLabel = DateFormat('MM-dd').format(dt);
                      }
                    } catch (_) {
                      dateLabel = startedAtStr.length >= 10 ? startedAtStr.substring(0, 10) : '';
                    }
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                          child: const Icon(Icons.chat, size: 20),
                        ),
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('$dateLabel · $turnCount 轮对话',
                            style: const TextStyle(fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          final convId = conv['id'] as String?;
                          if (convId != null) {
                            context.push('/chat', extra: convId);
                          }
                        },
                      ),
                    );
                  },
                ),
                ),
    );
  }
}
