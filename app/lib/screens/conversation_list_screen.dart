import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../widgets/empty_state.dart';
import '../theme/app_theme.dart';

class ConversationListScreen extends ConsumerStatefulWidget {
  const ConversationListScreen({super.key});

  @override
  ConsumerState<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends ConsumerState<ConversationListScreen>
    with SingleTickerProviderStateMixin {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;
  late final TabController _tabController;
  List<Map<String, dynamic>> _activeConversations = [];
  List<Map<String, dynamic>> _deletedConversations = [];
  bool _isLoadingActive = true;
  bool _isLoadingDeleted = false;
  bool _hasLoadedOnce = false;
  bool _deletedLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && _tabController.index == 1) {
        // 切换到已删除 tab 时加载一次
        if (!_deletedLoadedOnce) {
          _deletedLoadedOnce = true;
          _loadDeleted();
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadActive());
    ref.listenManual(authProvider, (prev, next) {
      if (!_hasLoadedOnce && next.userId != null) {
        _loadActive();
      }
    });
  }

  ChatClient _makeClient() {
    final auth = ref.read(authProvider);
    return ChatClient(
      userId: auth.userId ?? 'default_user',
      token: auth.token,
    );
  }

  Future<void> _loadActive() async {
    final auth = ref.read(authProvider);
    if (auth.userId == null) {
      if (mounted) setState(() => _isLoadingActive = false);
      return;
    }
    final client = _makeClient();
    try {
      final resp = await client.getConversationList();
      setState(() {
        _activeConversations = (resp['conversations'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
        _isLoadingActive = false;
        _hasLoadedOnce = true;
      });
    } catch (e) {
      setState(() => _isLoadingActive = false);
    }
  }

  Future<void> _loadDeleted() async {
    setState(() => _isLoadingDeleted = true);
    final client = _makeClient();
    try {
      final resp = await client.getConversationList(includeDeleted: 'only');
      setState(() {
        _deletedConversations = (resp['conversations'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
        _isLoadingDeleted = false;
      });
    } catch (e) {
      setState(() => _isLoadingDeleted = false);
    }
  }

  Future<void> _doDelete(Map<String, dynamic> conv) async {
    final convId = conv['id'] as String;
    final client = _makeClient();
    final resp = await client.deleteConversation(convId);
    if (resp != null) {
      _loadActive();
      // 重置已删除列表缓存，下次切到该 tab 时自动刷新
      _deletedLoadedOnce = false;
    }
  }

  Future<void> _restoreConversation(Map<String, dynamic> conv) async {
    final convId = conv['id'] as String;
    final client = _makeClient();
    final ok = await client.restoreConversation(convId);
    if (ok) {
      _deletedLoadedOnce = false;
      _loadActive();
      _tabController.animateTo(0);
    }
  }

  Future<void> _showDeleteDialog(Map<String, dynamic> conv) async {
    final title = (conv['title'] as String?) ?? '此对话';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('「$title」将移至回收站，30天内可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _cs.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _doDelete(conv);
    }
  }

  Future<void> _showPermanentDeleteDialog(Map<String, dynamic> conv) async {
    final title = (conv['title'] as String?) ?? '此对话';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text('「$title」将被永久删除，无法恢复。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _cs.error),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final client = _makeClient();
      await client.permanentDeleteConversation(conv['id'] as String);
      _deletedLoadedOnce = false;
    }
  }

  String _formatDate(String isoStr) {
    try {
      final dt = DateTime.parse(isoStr).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return '刚刚';
      if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
      if (diff.inDays < 1) return DateFormat('HH:mm').format(dt);
      if (diff.inDays < 7) return '${diff.inDays} 天前';
      return DateFormat('MM-dd').format(dt);
    } catch (_) {
      return isoStr.length >= 10 ? isoStr.substring(0, 10) : '';
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('对话列表'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: '活跃 (${_activeConversations.length})'),
            const Tab(text: '已删除'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildActiveList(),
          _buildDeletedList(),
        ],
      ),
    );
  }

  // ── 活跃列表 ──

  Widget _buildActiveList() {
    if (_isLoadingActive) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_activeConversations.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline,
        title: '还没有对话',
        actionLabel: '开始新对话',
        onAction: () => context.go('/chat'),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadActive,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppTheme.spacingMd),
        itemCount: _activeConversations.length,
        itemBuilder: (_, i) => _buildActiveTile(_activeConversations[i]),
      ),
    );
  }

  Widget _buildActiveTile(Map<String, dynamic> conv) {
    final title = (conv['title'] as String?) ?? '新对话';
    final turnCount = conv['turn_count'] as int? ?? 0;
    final startedAtStr = (conv['started_at'] as String?) ?? '';
    final dateLabel = _formatDate(startedAtStr);

    return Dismissible(
      key: Key(conv['id'] as String),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppTheme.spacingXl),
        color: _cs.error,
        child: Icon(Icons.delete, color: _cs.onError),
      ),
      confirmDismiss: (_) async {
        await _showDeleteDialog(conv);
        return false; // Dismissible 不自动移除，由 _doDelete 刷新列表
      },
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
            child: const Icon(Icons.chat, size: 20),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$dateLabel · $turnCount 轮对话',
              style: _tt.bodySmall!),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            final convId = conv['id'] as String?;
            if (convId != null) {
              context.pop(convId);
            }
          },
        ),
      ),
    );
  }

  // ── 已删除列表（回收站） ──

  Widget _buildDeletedList() {
    if (_isLoadingDeleted) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_deletedConversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 64, color: _cs.outlineVariant),
            const SizedBox(height: AppTheme.spacingLg),
            Text('回收站为空', style: TextStyle(color: _cs.onSurfaceVariant)),
            const SizedBox(height: AppTheme.spacingSm),
            Text('已删除的对话将保留30天',
                style: _tt.bodySmall?.copyWith(color: _cs.outline)),
          ],
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppTheme.spacingMd),
            itemCount: _deletedConversations.length,
            itemBuilder: (_, i) => _buildDeletedTile(_deletedConversations[i]),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(AppTheme.spacingMd),
          color: _cs.surfaceContainerLow,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline, size: 14, color: _cs.outlineVariant),
              const SizedBox(width: 6),
              Text('已删除的对话将在30天后自动清理',
                  style: _tt.labelSmall?.copyWith(color: _cs.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeletedTile(Map<String, dynamic> conv) {
    final title = (conv['title'] as String?) ?? '新对话';
    final turnCount = conv['turn_count'] as int? ?? 0;
    final deletedAtStr = (conv['deleted_at'] as String?) ?? '';
    final dateLabel = _formatDate(deletedAtStr);

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _cs.surfaceContainerHighest,
          child: Icon(Icons.delete_outline, size: 20, color: _cs.onSurfaceVariant),
        ),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _cs.onSurface)),
        subtitle: Text('$turnCount轮对话 · 删除于 $dateLabel',
            style: _tt.bodySmall?.copyWith(color: _cs.onSurfaceVariant)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('恢复'),
              onPressed: () => _restoreConversation(conv),
            ),
            IconButton(
              icon: Icon(Icons.delete_forever, size: 20, color: _cs.error),
              tooltip: '彻底删除',
              onPressed: () => _showPermanentDeleteDialog(conv),
            ),
          ],
        ),
      ),
    );
  }
}

