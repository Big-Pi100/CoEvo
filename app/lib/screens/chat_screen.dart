import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../services/stt_service.dart';
import '../widgets/skeleton.dart';

/// 持久化 conversation_id 的 provider (跨页面保持)
final currentConversationIdProvider = StateProvider<String?>((ref) => null);

class ChatScreen extends ConsumerStatefulWidget {
  final String? conversationId;

  const ChatScreen({super.key, this.conversationId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messageController = TextEditingController();
  final _messages = <Message>[];
  GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  final _scrollController = ScrollController();
  ChatClient? _client;
  WsChatSession? _session;
  StreamSubscription<WsEvent>? _sessionSub;
  bool _isWaiting = false;
  String _convId = '';
  bool _isInitializing = true;

  // 学习计划
  Map<String, dynamic>? _activePlan;
  bool _planExpanded = true;

  String _streamingBuffer = '';
  int _streamingIndex = -1;

  // 语音输入
  bool _voiceMode = false;
  bool _isRecording = false;
  bool _isCancelling = false;
  SttService? _stt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final auth = ref.read(authProvider);

    // 恢复或创建 conversation_id (跨页面持久)
    _convId = widget.conversationId ?? ref.read(currentConversationIdProvider) ?? 'conv_${DateTime.now().millisecondsSinceEpoch}';
    ref.read(currentConversationIdProvider.notifier).state = _convId;

    _client = ChatClient(
      userId: auth.userId ?? 'default_user',
      conversationId: _convId,
      token: auth.token,
    );

    // 加载学习计划
    _loadPlan();

    // 加载历史对话
    final history = await _client!.getConversationTurns(_convId);
    if (history.isNotEmpty && mounted) {
      setState(() {
        for (final turn in history) {
          _messages.add(Message(
            role: turn['role'] as String? ?? 'assistant',
            content: turn['content'] as String? ?? '',
            timestamp: DateTime.now(),
          ));
        }
      });
      _scrollToBottom();
    } else {
      // 新对话: 显示欢迎消息
      setState(() {
        _messages.add(Message(
          role: 'assistant',
          content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
          timestamp: DateTime.now(),
        ));
      });
    }
    if (mounted) setState(() => _isInitializing = false);
  }

  Future<void> _loadPlan() async {
    if (_client == null) return;
    final plans = await _client!.getPlans(conversationId: _convId);
    if (plans.isNotEmpty && mounted) {
      setState(() => _activePlan = plans.first);
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

  Widget _buildProgressBar(List<dynamic> stages) {
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

  Widget _buildPlanPanel() {
    if (_activePlan == null) return const SizedBox.shrink();
    final plan = _activePlan!;
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
            onTap: () => setState(() => _planExpanded = !_planExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.school, size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(goal, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  // 进度摘要
                  Text(_progressSummary(stages),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(width: 6),
                  Icon(_planExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
          // 全局进度条
          if (_planExpanded) _buildProgressBar(stages),
          if (_planExpanded)
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
                        // Stage 进度: done/total
                        Text('$doneTasks/${tasks.length}',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Stage 进度条
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

  @override
  void dispose() {
    _sessionSub?.cancel();
    _session?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addMessage(Message msg) {
    _messages.add(msg);
    _listKey.currentState?.insertItem(_messages.length - 1, duration: const Duration(milliseconds: 300));
    Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _client == null || _isWaiting) return;

    _messageController.clear();
    _addMessage(Message(
      role: 'user', content: text, timestamp: DateTime.now(),
    ));

    setState(() => _isWaiting = true);

    if (_session == null) {
      // 首次通话：建立 WS 连接并启动监听
      _session = _client!.streamChat(text);

      _streamingBuffer = '';
      _addMessage(Message(
        role: 'assistant', content: '', timestamp: DateTime.now(),
      ));
      _streamingIndex = _messages.length - 1;

      _sessionSub = _session!.events.listen(
        (event) => _handleWsEvent(event),
        onError: (error) {
          _finalizeStreamingWithRetry('连接错误：$error');
        },
        onDone: () {
          if (_streamingIndex >= 0 && _streamingBuffer.isNotEmpty) {
            _finalizeStreaming(_streamingBuffer);
          }
        },
      );
    } else {
      // 后续消息：复用已有连接；若连接已关闭则重建
      final auth = ref.read(authProvider);
      try {
        _session!.send(auth.userId ?? '', _convId, text);
      } catch (_) {
        // 连接已关闭，清理后重建
        _sessionSub?.cancel();
        _session = null;
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
    switch (event.type) {
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
          Future.delayed(Duration.zero, () => _showConceptDialog(list));
        }
        break;
      case 'error':
        _finalizeStreamingWithRetry('抱歉，出了点问题：${event.content}');
        break;
      case 'plan_updated':
        _loadPlan();
        break;
    }
  }

  void _updateStreaming(String content) {
    if (_streamingIndex < 0 || _streamingIndex >= _messages.length) return;
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant', content: content, timestamp: DateTime.now(),
      );
    });
    _scrollToBottom();
  }

  void _finalizeStreaming(String reply) {
    if (_streamingIndex < 0) return;
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant', content: reply, timestamp: DateTime.now(),
      );
      _isWaiting = false;
      _streamingIndex = -1;
      _streamingBuffer = '';
    });
    _scrollToBottom();
  }

  /// 带重试按钮的错误提示
  void _finalizeStreamingWithRetry(String errorMsg) {
    if (_streamingIndex < 0) return;
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant',
        content: '${errorMsg}',
        timestamp: DateTime.now(),
      );
      _isWaiting = false;
      _streamingIndex = -1;
      _streamingBuffer = '';
    });
    _scrollToBottom();
  }

  // ── 制卡确认弹窗 ──

  void _showConceptDialog(List<ConceptCandidate> candidates) {
    if (!mounted || candidates.isEmpty) return;

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
                      _client?.skipConcept(candidates[i].front, candidates[i].sourceSentence ?? '');
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
                      _client?.skipConcept(candidates[i].front, candidates[i].sourceSentence ?? '');
                    }
                  }
                  if (toCreate.isNotEmpty && _client != null) {
                    final result = await _client!.batchCreateCards(toCreate);
                    if (mounted) {
                      final count = (result['created'] as List?)?.length ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已创建 $count 张卡片')),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.auto_awesome, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
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
                // 切换到新会话：重置 AnimatedList key 强制重建
                _listKey = GlobalKey<AnimatedListState>();
                _sessionSub?.cancel();
                _session = null;
                _convId = result;
                _activePlan = null;
                ref.read(currentConversationIdProvider.notifier).state = _convId;
                _client = ChatClient(
                  userId: ref.read(authProvider).userId ?? 'default_user',
                  conversationId: _convId,
                  token: ref.read(authProvider).token,
                );
                _loadPlan();
                // 加载历史对话
                final history = await _client!.getConversationTurns(_convId);
                setState(() {
                  _messages.clear();
                  if (history.isNotEmpty) {
                    for (final turn in history) {
                      _messages.add(Message(
                        role: turn['role'] as String? ?? 'assistant',
                        content: turn['content'] as String? ?? '',
                        timestamp: DateTime.now(),
                      ));
                    }
                  } else {
                    _messages.add(Message(
                      role: 'assistant',
                      content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                      timestamp: DateTime.now(),
                    ));
                  }
                });
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
              ref.read(currentConversationIdProvider.notifier).state = null;
              _listKey = GlobalKey<AnimatedListState>();
              setState(() {
                _messages.clear();
                _convId = 'conv_${DateTime.now().millisecondsSinceEpoch}';
                ref.read(currentConversationIdProvider.notifier).state = _convId;
                _activePlan = null;
                _session = null;
                _sessionSub?.cancel();
              });
              _client = ChatClient(
                userId: ref.read(authProvider).userId ?? 'default_user',
                conversationId: _convId,
                token: ref.read(authProvider).token,
              );
              _loadPlan();
              _addMessage(Message(
                role: 'assistant',
                content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
                timestamp: DateTime.now(),
              ));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 学习计划面板（持久展示，不被对话推没）
          _buildPlanPanel(),
          Expanded(
            child: _isInitializing
                ? const ChatSkeleton()
                : SelectionArea(
              child: AnimatedList(
              key: _listKey,
              controller: _scrollController,
              initialItemCount: _messages.length,
              padding: const EdgeInsets.all(16),
              itemBuilder: (_, i, animation) {
                final msg = _messages[i];
                final isUser = msg.role == 'user';
                final isStreaming = i == _streamingIndex;
                return SizeTransition(
                  sizeFactor: animation,
                  child: FadeTransition(
                    opacity: animation,
                    child: Column(
                      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // AI 头像（左侧）
                            if (!isUser)
                              Padding(
                                padding: const EdgeInsets.only(right: 8, bottom: 12),
                                child: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                                  child: Icon(Icons.auto_awesome, size: 14, color: Theme.of(context).colorScheme.primary),
                                ),
                              ),
                            // 气泡
                            Flexible(
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(20).copyWith(
                                    bottomRight: isUser ? const Radius.circular(4) : null,
                                    bottomLeft: !isUser ? const Radius.circular(4) : null,
                                  ),
                                ),
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.65,
                                ),
                                child: Text(
                                  msg.content + (isStreaming ? '▌' : ''),
                                  style: TextStyle(
                                    color: isUser ? Colors.white : Theme.of(context).colorScheme.onSecondaryContainer,
                                    fontSize: 16,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ),
                            // 用户头像（右侧）
                            if (isUser)
                              Padding(
                                padding: const EdgeInsets.only(left: 8, bottom: 12),
                                child: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: Theme.of(context).colorScheme.primary,
                                  child: const Icon(Icons.person, size: 14, color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                        // 错误重试按钮
                        if (!isUser && msg.content.startsWith('抱歉') || msg.content.startsWith('连接错误'))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12, left: 8),
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
                    ),
                  ),
                );
              },
            ),
          ),
          ),
          if (_isWaiting)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: SafeArea(
              child: _voiceMode ? _buildVoiceInput() : _buildTextInput(),
            ),
          ),
        ],
      ),
    );
  }

  // ── 文本输入模式 ──
  Widget _buildTextInput() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.keyboard_voice),
          onPressed: () => setState(() => _voiceMode = true),
          tooltip: '语音输入',
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: _messageController,
            decoration: const InputDecoration(
              hintText: '输入消息...',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendMessage(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: _isWaiting ? null : _sendMessage,
          icon: _isWaiting
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.send),
        ),
      ],
    );
  }

  // ── 语音输入模式 ──
  Widget _buildVoiceInput() {
    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 取消提示
            if (_isRecording)
              AnimatedOpacity(
                opacity: _isCancelling ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: _isCancelling ? Colors.red.shade50 : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_upward, size: 16,
                          color: _isCancelling ? Colors.red : Colors.grey),
                      const SizedBox(width: 4),
                      Text(
                        _isCancelling ? '松开取消' : '上滑取消',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isCancelling ? Colors.red : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                // 返回键盘
                IconButton(
                  icon: const Icon(Icons.keyboard),
                  onPressed: () => setState(() {
                    _voiceMode = false;
                    _isRecording = false;
                    _isCancelling = false;
                  }),
                  tooltip: '键盘输入',
                ),
                const SizedBox(width: 4),
                // 长按录音区域
                Expanded(
                  child: GestureDetector(
                    onLongPressStart: (_) async {
                      setState(() { _isRecording = true; });
                      final stt = ref.read(sttServiceProvider);
                      await stt.startRecording();
                      setState(() => _stt = stt);
                    },
                    onLongPressMoveUpdate: (details) {
                      setState(() {
                        _isCancelling = details.localPosition.dy < -60;
                      });
                    },
                    onLongPressEnd: (_) async {
                      if (_stt == null) return;
                      if (_isCancelling) {
                        await _stt!.stopRecording();
                        setState(() {
                          _isRecording = false;
                          _isCancelling = false;
                          _stt = null;
                        });
                        return;
                      }
                      final text = await _stt!.stopRecording();
                      setState(() {
                        _isRecording = false;
                        _isCancelling = false;
                        _stt = null;
                      });
                      if (text.isNotEmpty) {
                        _sendVoiceMessage(text);
                      }
                    },
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: _isRecording
                            ? (_isCancelling ? Colors.red.shade50 : Colors.blue.shade50)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _isRecording
                              ? (_isCancelling ? Colors.red : Colors.blue)
                              : Colors.grey.shade300,
                        ),
                      ),
                      child: Center(
                        child: _isRecording
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.mic, size: 20,
                                      color: _isCancelling ? Colors.red : Colors.blue),
                                  const SizedBox(width: 8),
                                  Text(
                                    _isCancelling ? '松开取消' : '录音中...',
                                    style: TextStyle(
                                      color: _isCancelling ? Colors.red : Colors.blue,
                                    ),
                                  ),
                                ],
                              )
                            : const Text('按住 说话',
                                style: TextStyle(color: Colors.grey)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  void _sendVoiceMessage(String text) {
    _messageController.text = text;
    _sendMessage();
  }
}