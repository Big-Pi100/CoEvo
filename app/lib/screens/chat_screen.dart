import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../providers/achievement_notifier.dart';
import '../widgets/skeleton.dart';
import 'chat/chat_concept_dialog.dart';
import 'chat/chat_input.dart';
import 'chat/chat_plan_panel.dart';
import 'chat/chat_reading_passage.dart';
import 'chat/chat_message_bubble.dart';
import '../theme/app_theme.dart';

/// 持久化 conversation_id 的 provider (跨页面保持)
final currentConversationIdProvider = StateProvider<String?>((ref) => null);

class ChatScreen extends ConsumerStatefulWidget {
  final String? conversationId;

  const ChatScreen({super.key, this.conversationId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _tt => Theme.of(context).textTheme;
  final _messageController = TextEditingController();
  final _messages = <Message>[];
  final _scrollController = ScrollController();

  ChatClient? _client;
  WsChatSession? _session;
  StreamSubscription<WsEvent>? _sessionSub;
  bool _isWaiting = false;
  String _convId = '';
  bool _isInitializing = true;

  // 学习计划
  Map<String, dynamic>? _activePlan;

  // 订阅状态
  bool _subscriptionRequired = false;
  bool _subscriptionExpired = false;
  bool _subscriptionChecked = false;
  bool _subscriptionDialogShown = false;

  // 对话删除状态
  // ignore: prefer_final_fields
  bool _isDeleted = false;

  // 历史对话分页
  int _historyOffset = 0;
  static const int _historyPageSize = 5;
  int _historyTotal = 0;
  bool _loadingMore = false;
  bool _isHistoryConversation = false;

  String _streamingBuffer = '';
  int _streamingIndex = -1;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    try {
      // Bug 2 修复：等待 authProvider.tryRestore() 完成（app.dart 中异步调用）
      // 避免因 auth.userId 为 null 而 fallback 到 'default_user'，
      // 导致订阅状态查询使用了错误的 user_id
      String? userId;
      String? token;
      for (int retry = 0; retry < 20; retry++) {
        if (!mounted) return;
        final auth = ref.read(authProvider);
        if (auth.userId != null && auth.userId!.isNotEmpty) {
          userId = auth.userId;
          token = auth.token;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }
      if (userId == null) {
        // 认证未恢复，跳转到登录页
        if (mounted) context.go('/auth');
        return;
      }

      // 恢复或创建 conversation_id (跨页面持久)
      _convId = widget.conversationId ?? ref.read(currentConversationIdProvider) ?? 'conv_${DateTime.now().millisecondsSinceEpoch}';
      ref.read(currentConversationIdProvider.notifier).state = _convId;

      _client = ChatClient(
        userId: userId,
        conversationId: _convId,
        token: token,
      );

      // 加载学习计划和订阅状态（并行发起，统一等待完成后再渲染）
      final planFuture = _loadPlan();
      final subFuture = _checkSubscription();

      // 加载历史对话（历史会话只加载最近5条）
      try {
        _isHistoryConversation = _convId.isNotEmpty && _convId != 'new';
        final initialLimit = _isHistoryConversation ? 5 : 50;
        final result = await _client!.getConversationTurns(_convId, limit: initialLimit);
        final history = (result['turns'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
        _historyTotal = (result['total'] as int?) ?? 0;
        _historyOffset = history.length;

        if (history.isNotEmpty && mounted) {
          final ascTurns = history.reversed.toList();
          setState(() {
            for (final turn in ascTurns) {
              _messages.add(Message(
                role: turn['role'] as String? ?? 'assistant',
                content: turn['content'] as String? ?? '',
                timestamp: DateTime.now(),
              ));
            }
          });
          _scrollToBottom();
        } else {
          setState(() {
            _messages.add(Message(
              role: 'assistant',
              content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
              timestamp: DateTime.now(),
            ));
          });
        }
      } catch (e) {
        debugPrint('_init: history load failed: $e');
        setState(() {
          _messages.add(Message(
            role: 'assistant',
            content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
            timestamp: DateTime.now(),
          ));
        });
      }

      // 等待计划和订阅加载完成
      await planFuture;
      await subFuture;

    } catch (e) {
      debugPrint('_init: fatal error: $e');
      if (mounted) {
        setState(() {
          _messages.add(Message(
            role: 'assistant',
            content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
            timestamp: DateTime.now(),
          ));
        });
      }
    } finally {
      // 无论如何都要解除初始化状态，防止永久灰屏
      if (mounted) setState(() => _isInitializing = false);
    }
  }

  Future<void> _loadPlan() async {
    if (_client == null) return;
    final plans = await _client!.getPlans(conversationId: _convId);
    if (plans.isNotEmpty && mounted) {
      setState(() => _activePlan = plans.first);
    }

  }

  Future<void> _checkSubscription() async {
    if (_client == null) return;
    try {
      final prefs = await _client!.getPreferences();
      final expiresStr = prefs['subscription_expires'];
      if (expiresStr == null || expiresStr.isEmpty) {
        if (mounted) {
          setState(() {
            _subscriptionRequired = true;
            _subscriptionExpired = false;
            _subscriptionChecked = true;
          });
        }
        return;
      }
      final expires = DateTime.tryParse(expiresStr);
      if (expires == null) {
        if (mounted) {
          setState(() {
            _subscriptionRequired = true;
            _subscriptionExpired = false;
            _subscriptionChecked = true;
          });
        }
        return;
      }
      final now = DateTime.now();
      if (mounted) {
        setState(() {
          _subscriptionExpired = now.isAfter(expires);
          _subscriptionRequired = false;
          _subscriptionChecked = true;
        });
      }
    } catch (e) {
      // 网络错误等，不阻断使用
      debugPrint('ChatScreen._checkSubscription: $e');
      if (mounted) setState(() => _subscriptionChecked = true);
    }
  }


  @override
  void dispose() {
    _sessionSub?.cancel();
    _session?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addMessage(Message msg) {
    setState(() => _messages.add(msg));
    Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _client == null || _isWaiting) return;

    debugPrint('📤 _sendMessage: text="$text" convId=$_convId session=${_session != null ? "reuse" : "new"}');

    _messageController.clear();
    _addMessage(Message(
      role: 'user', content: text, timestamp: DateTime.now(),
    ));

    setState(() => _isWaiting = true);

    if (_session == null) {
      // 首次通话：建立 WS 连接并启动监听
      debugPrint('📤 Creating new WS session...');
      _session = _client!.streamChat(text);

      // 竞态修复: 必须在 _addMessage（setState）之前订阅，确保 WS 事件不丢失
      _sessionSub = _session!.events.listen(
        (event) => _handleWsEvent(event),
        onError: (error) {
          debugPrint('🔴 WS stream error: $error');
          _finalizeStreamingWithRetry('连接错误：$error');
          // 确保 _isWaiting 复位
          if (mounted) setState(() => _isWaiting = false);
        },
        onDone: () {
          debugPrint('🔴 WS stream done. buf_len=${_streamingBuffer.length} idx=$_streamingIndex');
          if (_streamingIndex >= 0 && _streamingBuffer.isNotEmpty) {
            _finalizeStreaming(_streamingBuffer);
          } else if (_streamingIndex >= 0) {
            // 流关闭但没有内容——可能连接被拒绝（订阅检查等）
            _finalizeStreamingWithRetry('连接已关闭，请重试');
          }
          // 确保 _isWaiting 复位
          if (mounted) setState(() => _isWaiting = false);
        },
      );
      debugPrint('📤 WS listener registered');

      _streamingBuffer = '';
      _addMessage(Message(
        role: 'assistant', content: '', timestamp: DateTime.now(),
      ));
      _streamingIndex = _messages.length - 1;
      debugPrint('📤 AI bubble added at idx=$_streamingIndex, total msgs=${_messages.length}');
    } else {
      // 后续消息：复用已有连接；若连接已关闭则重建
      final auth = ref.read(authProvider);
      try {
        _session!.send(auth.userId ?? '', _convId, text);
      } catch (e) {
        // 连接已关闭，清理后重建
        debugPrint('ChatScreen._sendMessage session send failed: $e');
        _sessionSub?.cancel();
        _session = null;
        // 重置等待状态，避免递归调用被 _isWaiting 拦截
        if (mounted) setState(() => _isWaiting = false);
        // 递归调用自身，走首次连接分支
        _sendMessage();
        return;
      }

      _streamingBuffer = '';
      _addMessage(Message(
        role: 'assistant', content: '', timestamp: DateTime.now(),
      ));
      _streamingIndex = _messages.length - 1;
    }
  }

  void _handleWsEvent(WsEvent event) {
    debugPrint('🟢 WsEvent: type=${event.type} content=${event.content?.substring(0, event.content!.length > 50 ? 50 : event.content!.length)} reply_len=${event.reply?.length} streamingIdx=$_streamingIndex msgCount=${_messages.length}');
    switch (event.type) {
      case 'kicked':
        // 在另一台设备登录，当前连接被强制断开
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('账号已在其他设备登录，当前连接已断开')),
          );
          context.go('/auth');
        }
        break;
      case 'thinking':
        _updateStreaming('思考中...');
        break;
      case 'planning':
        // 计划生成中，清空已收到的碎片 token，显示占位
        _streamingBuffer = '';
        if (_streamingIndex < 0) {
          _addMessage(Message(
            role: 'assistant', content: '计划制定中……', timestamp: DateTime.now(),
          ));
          _streamingIndex = _messages.length - 1;
        }
        _updateStreaming('计划制定中……');
        break;
      case 'token':
        _streamingBuffer += event.content ?? '';
        _updateStreaming(_streamingBuffer);
        break;
      case 'done':
        _finalizeStreaming(event.reply ?? _streamingBuffer);
        break;
      case 'candidates':
        final list = event.candidates;
        if (list != null && list.isNotEmpty && list.any((c) => c.front.isNotEmpty)) {
          Future.delayed(Duration.zero, () { if (mounted) ConceptDialog.show(context, candidates: list, client: _client, ref: ref, conversationId: _convId); });
        }
        break;
      case 'achievements':
        final list = event.achievements;
        if (list != null && list.isNotEmpty) {
          final notifier = ref.read(achievementNotifierProvider.notifier);
          for (final a in list) {
            notifier.push(AchievementNotification.fromJson(a));
          }
        }
        break;
      case 'error':
        if (event.content == 'invalid_token' || event.content == 'missing_token') {
          // 被踢下线：token 已失效
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('账号已在其他设备登录，请重新登录')),
            );
            context.go('/auth');
          }
          break;
        }
        if (event.content == 'subscription_expired') {
          setState(() {
            _subscriptionExpired = true;
            _subscriptionRequired = false;
            _subscriptionChecked = true;
            _isWaiting = false;
          });
          // 清理空的 AI 气泡
          if (_streamingIndex >= 0 && _streamingIndex < _messages.length) {
            _messages.removeAt(_streamingIndex);
          }
          _streamingIndex = -1;
          _streamingBuffer = '';
          if (!_subscriptionDialogShown) {
            _subscriptionDialogShown = true;
            _showSubscriptionDialog('订阅已到期');
          }
        } else if (event.content == 'subscription_required') {
          setState(() {
            _subscriptionRequired = true;
            _subscriptionExpired = false;
            _subscriptionChecked = true;
            _isWaiting = false;
          });
          // 清理空的 AI 气泡
          if (_streamingIndex >= 0 && _streamingIndex < _messages.length) {
            _messages.removeAt(_streamingIndex);
          }
          _streamingIndex = -1;
          _streamingBuffer = '';
          if (!_subscriptionDialogShown) {
            _subscriptionDialogShown = true;
            _showSubscriptionDialog('需要激活');
          }
        } else {
          _finalizeStreamingWithRetry('抱歉，出了点问题：${event.content}');
        }
        break;
      case 'plan_updated':
        _loadPlan();
        // 通知复习页重新加载（CP2 创建新计划或解锁卡片后）
        ref.read(cardRefreshProvider.notifier).state++;
        break;
    }
  }

  void _updateStreaming(String content) {
    debugPrint('🔵 _updateStreaming: idx=$_streamingIndex content_len=${content.length} msgCount=${_messages.length} mounted=$mounted');
    if (_streamingIndex < 0 || _streamingIndex >= _messages.length) {
      debugPrint('🔴 _updateStreaming: SKIPPED (idx out of range)');
      return;
    }
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant', content: content, timestamp: DateTime.now(),
      );
    });
    debugPrint('🔵 _updateStreaming: setState done, new content="${content.substring(0, content.length > 30 ? 30 : content.length)}"');
    _scrollToBottom();
  }

  void _finalizeStreaming(String reply) {
    debugPrint('🟡 _finalizeStreaming: idx=$_streamingIndex reply_len=${reply.length} mounted=$mounted');
    if (_streamingIndex < 0) {
      debugPrint('🔴 _finalizeStreaming: SKIPPED (idx=-1)');
      return;
    }
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant', content: reply, timestamp: DateTime.now(),
      );
      _isWaiting = false;
      _streamingIndex = -1;
      _streamingBuffer = '';
    });
    debugPrint('🟡 _finalizeStreaming: done, msgCount=${_messages.length}');
    _scrollToBottom();
  }

  /// 带重试按钮的错误提示
  void _finalizeStreamingWithRetry(String errorMsg) {
    if (_streamingIndex < 0) return;
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant',
        content: errorMsg,
        timestamp: DateTime.now(),
      );
      _isWaiting = false;
      _streamingIndex = -1;
      _streamingBuffer = '';
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSubscriptionDialog(String title) {
    if (!mounted) return;
    setState(() {
      if (title.contains('到期') || title.contains('过期')) {
        _subscriptionExpired = true;
        _subscriptionRequired = false;
      } else {
        _subscriptionRequired = true;
        _subscriptionExpired = false;
      }
      _subscriptionChecked = true;
    });
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lock, size: 20),
            const SizedBox(width: AppTheme.spacingSm),
            Text(title),
          ],
        ),
        content: const Text('请联系你的服务人员续费。\n续费后刷新页面即可恢复使用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  /// 订阅状态横幅（主动检查结果显示在聊天页顶部）
  Widget _buildSubscriptionBanner() {
    if (!_subscriptionChecked) return const SizedBox.shrink();
    if (!_subscriptionRequired && !_subscriptionExpired) return const SizedBox.shrink();

    final isExpired = _subscriptionExpired;
    return Container(
      margin: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isExpired ? _cs.errorContainer : _cs.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isExpired ? _cs.error : _cs.secondary),
      ),
      child: Row(
        children: [
          Icon(
            isExpired ? Icons.lock_clock : Icons.lock_outline,
            size: 18,
            color: isExpired ? _cs.error : _cs.secondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isExpired ? '订阅已到期，请联系服务人员续费' : '需要激活订阅才能使用 AI 对话',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isExpired ? _cs.error : _cs.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 对话已删除横幅
  Widget _buildDeletedBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: _cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '此对话已被删除。你可以在对话列表的回收站中恢复。',
              style: TextStyle(fontSize: 13, color: _cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadMoreButton() {
    final remaining = _historyTotal - _historyOffset;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextButton.icon(
        icon: _loadingMore
            ? const SizedBox(width: AppTheme.spacingLg, height: AppTheme.spacingLg, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.expand_less, size: 18),
        label: Text(_loadingMore ? '加载中...' : '查看更早对话 ($remaining 条)',
            style: const TextStyle(fontSize: 13)),
        onPressed: _loadingMore ? null : _loadMoreHistory,
      ),
    );
  }

  Future<void> _loadMoreHistory() async {
    if (_loadingMore || _client == null) return;
    setState(() => _loadingMore = true);
    try {
      final result = await _client!.getConversationTurns(
        _convId, limit: _historyPageSize, offset: _historyOffset,
      );
      final more = (result['turns'] as List<dynamic>?)
          ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
      if (more.isNotEmpty && mounted) {
        final ascMore = more.reversed.toList();
        setState(() {
          for (final turn in ascMore) {
            _messages.insert(0, Message(
              role: turn['role'] as String? ?? 'assistant',
              content: turn['content'] as String? ?? '',
              timestamp: DateTime.now(),
            ));
          }
          _historyOffset += more.length;
        });
      }
    } catch (e) {
      debugPrint('_loadMoreHistory error: $e');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home'),
        ),
        title: Row(
          children: [
            Icon(Icons.auto_awesome, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppTheme.spacingSm),
            Text('CoEvo', style: TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
              color: Theme.of(context).colorScheme.primary,
            )),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '对话列表',
            onPressed: () async {
              final result = await context.push<String>('/conversations');
              if (result != null && mounted) {
                // 切换到已有对话
                _sessionSub?.cancel();
                _session = null;
                _convId = result;
                _activePlan = null;
                _isInitializing = true;
                ref.read(currentConversationIdProvider.notifier).state = _convId;
                _client = ChatClient(
                  userId: ref.read(authProvider).userId ?? 'default_user',
                  conversationId: _convId,
                  token: ref.read(authProvider).token,
                );
                _loadPlan();
                // 清空旧消息并重新加载历史
                setState(() => _messages.clear());
                try {
                  _isHistoryConversation = _convId.isNotEmpty;
                  final result = await _client!.getConversationTurns(_convId, limit: _isHistoryConversation ? 5 : 50);
                  final history = (result['turns'] as List<dynamic>?)
                      ?.map((e) => e as Map<String, dynamic>).toList() ?? [];
                  _historyTotal = (result['total'] as int?) ?? 0;
                  _historyOffset = history.length;
                  if (history.isNotEmpty && mounted) {
                    final ascTurns = history.reversed.toList();
                    setState(() {
                      for (final turn in ascTurns) {
                        _messages.add(Message(
                          role: turn['role'] as String? ?? 'assistant',
                          content: turn['content'] as String? ?? '',
                          timestamp: DateTime.now(),
                        ));
                      }
                    });
                  } else {
                    setState(() {
                      _messages.add(Message(
                        role: 'assistant',
                        content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                        timestamp: DateTime.now(),
                      ));
                    });
                  }
                } catch (e) {
                  debugPrint('Conversation switch: history load failed: $e');
                  setState(() {
                    _messages.add(Message(
                      role: 'assistant',
                      content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                      timestamp: DateTime.now(),
                    ));
                  });
                }
                if (mounted) setState(() => _isInitializing = false);
              } else if (mounted) {
                // 返回但没选会话：重置 WS 连接，避免使用过期连接
                _sessionSub?.cancel();
                _session = null;
              }
            },
          ),
          // 新对话按钮
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: '新对话',
            onPressed: () {
              _sessionSub?.cancel();
              _session = null;
              final newConvId = 'conv_${DateTime.now().millisecondsSinceEpoch}';
              ref.read(currentConversationIdProvider.notifier).state = newConvId;
              setState(() {
                _messages.clear();
                _messages.add(Message(
                  role: 'assistant',
                  content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                  timestamp: DateTime.now(),
                ));
                _convId = newConvId;
                _activePlan = null;
                _isInitializing = false;
              });
              _client = ChatClient(
                userId: ref.read(authProvider).userId ?? 'default_user',
                conversationId: newConvId,
                token: ref.read(authProvider).token,
              );
              _loadPlan();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 学习计划面板（持久展示，不被对话推没）
          if (_activePlan != null) ChatPlanPanel(plan: _activePlan!),
          // 课文阅读面板（reading-first 模式，自动隐藏不可用）
          if (_client != null && _convId.isNotEmpty)
            ChatReadingPassage(client: _client!, conversationId: _convId),
          // 订阅状态横幅
          _buildSubscriptionBanner(),
          // 对话已删除横幅
          if (_isDeleted) _buildDeletedBanner(),
          Expanded(
            child: _isInitializing
                ? const ChatSkeleton()
                : Column(
              children: [
                if (_isHistoryConversation && _historyOffset < _historyTotal)
                  _buildLoadMoreButton(),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    padding: const EdgeInsets.all(AppTheme.spacingLg),
                    itemBuilder: (_, i) {
                      final msg = _messages[i];
                final isUser = msg.role == 'user';
                final isStreaming = i == _streamingIndex;
                return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppTheme.spacingSm),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                            children: [
                              // 气泡：用户自适应 / AI 100%宽度
                              if (isUser)
                                Flexible(
                                  child: _buildBubble(context, isUser, isStreaming, msg),
                                )
                              else
                                Expanded(
                                  child: _buildBubble(context, isUser, isStreaming, msg),
                                ),
                            ],
                          ),
                        ),
                        // 错误重试按钮
                        if (!isUser && msg.content.startsWith('抱歉') || msg.content.startsWith('连接错误'))
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppTheme.spacingMd, left: AppTheme.spacingSm),
                            child: TextButton.icon(
                              onPressed: _isWaiting ? null : () {
                                final lastUserIdx = _messages.lastIndexWhere((m) => m.role == 'user');
                                if (lastUserIdx >= 0) {
                                  _messageController.text = _messages[lastUserIdx].content;
                                  _sendMessage();
                                }
                              },
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试', style: TextStyle(fontSize: 13)),
                            ),
                          ),
                      ],
                );
              },
            ),
              ),
            ],
            ),
          ),
          if (_isWaiting)
            const Padding(
              padding: EdgeInsets.all(AppTheme.spacingSm),
              child: LinearProgressIndicator(),
            ),
          ChatInput(
            textController: _messageController,
            isWaiting: _isWaiting,
            isDeleted: _isDeleted,
            onSend: _sendMessage,
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(BuildContext context, bool isUser, bool isStreaming, Message msg) {
    if (isUser) {
      // 用户消息：带气泡的完整宽度
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingMd),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(20).copyWith(
            bottomRight: const Radius.circular(4),
          ),
        ),
        child: ChatMessageBubble(text: msg.content, isUser: true, isStreaming: isStreaming),
      );
    } else {
      // AI 消息：无气泡，无背景，满宽显示
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingXs),
        child: ChatMessageBubble(text: msg.content, isUser: false, isStreaming: isStreaming),
      );
    }
  }

}

