import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';
import '../widgets/skeleton.dart';
import 'package:flutter_math_fork/flutter_math.dart';

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

  // 订阅状态
  bool _subscriptionRequired = false;
  bool _subscriptionExpired = false;
  bool _subscriptionChecked = false;
  bool _subscriptionDialogShown = false;

  // 对话删除状态
  // ignore: prefer_final_fields
  bool _isDeleted = false;

  String _streamingBuffer = '';
  int _streamingIndex = -1;

  // 语音输入
  bool _voiceMode = false;
  bool _isRecording = false;
  bool _isCancelling = false;
  SttService? _stt;
  String? _sttError;

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

      // 加载历史对话
      try {
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
      if (mounted) setState(() {
        _messages.add(Message(
          role: 'assistant',
          content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
          timestamp: DateTime.now(),
        ));
      });
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
        if (mounted) setState(() {
          _subscriptionRequired = true;
          _subscriptionExpired = false;
          _subscriptionChecked = true;
        });
        return;
      }
      final expires = DateTime.tryParse(expiresStr);
      if (expires == null) {
        if (mounted) setState(() {
          _subscriptionRequired = true;
          _subscriptionExpired = false;
          _subscriptionChecked = true;
        });
        return;
      }
      final now = DateTime.now();
      if (mounted) setState(() {
        _subscriptionExpired = now.isAfter(expires);
        _subscriptionRequired = false;
        _subscriptionChecked = true;
      });
    } catch (e) {
      // 网络错误等，不阻断使用
      debugPrint('ChatScreen._checkSubscription: $e');
      if (mounted) setState(() => _subscriptionChecked = true);
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
            const SizedBox(width: 8),
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
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isExpired ? Colors.red.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isExpired ? Colors.red.shade200 : Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(
            isExpired ? Icons.lock_clock : Icons.lock_outline,
            size: 18,
            color: isExpired ? Colors.red.shade700 : Colors.orange.shade700,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isExpired ? '订阅已到期，请联系服务人员续费' : '需要激活订阅才能使用 AI 对话',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isExpired ? Colors.red.shade800 : Colors.orange.shade800,
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
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '此对话已被删除。你可以在对话列表的回收站中恢复。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
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
          _buildPlanPanel(),
          // 订阅状态横幅
          _buildSubscriptionBanner(),
          // 对话已删除横幅
          if (_isDeleted) _buildDeletedBanner(),
          Expanded(
            child: _isInitializing
                ? const ChatSkeleton()
                : ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              padding: const EdgeInsets.all(16),
              itemBuilder: (_, i) {
                final msg = _messages[i];
                final isUser = msg.role == 'user';
                final isStreaming = i == _streamingIndex;
                return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // ── AI 消息布局：头像 | 气泡 | Spacer ──
                              if (!isUser)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: CircleAvatar(
                                    radius: 12,
                                    backgroundColor: Theme.of(context).colorScheme.primary.withAlpha(30),
                                    child: Icon(Icons.auto_awesome, size: 12, color: Theme.of(context).colorScheme.primary),
                                  ),
                                ),
                              // ── 用户消息布局：Spacer | 气泡 | 头像 ──
                              if (isUser)
                                const Spacer(),
                              // 气泡
                              Container(
                                constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.70,
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(20).copyWith(
                                    bottomRight: isUser ? const Radius.circular(4) : null,
                                    bottomLeft: !isUser ? const Radius.circular(4) : null,
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    // 消息文字（支持 LaTeX 数学公式渲染）
                                    _buildRichContent(
                                      msg.content,
                                      isUser: isUser,
                                      isStreaming: isStreaming,
                                    ),
                                    // AI 消息朗读按钮（流式输出时不显示）
                                    if (!isUser && !isStreaming)
                                      _buildTtsButton(_cleanText(msg.content)),
                                  ],
                                ),
                              ),
                              if (!isUser)
                                const Spacer(),
                              if (isUser)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: CircleAvatar(
                                    radius: 12,
                                    backgroundColor: Theme.of(context).colorScheme.primary,
                                    child: const Icon(Icons.person, size: 12, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
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
                );
              },
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
              child: _buildTextInput(),
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
            // 错误提示
            if (_sttError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_sttError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
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
                      setState(() { _isRecording = true; _sttError = null; });
                      final stt = ref.read(sttServiceProvider);
                      setState(() => _stt = stt);
                      await stt.startRecording();
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
                      final error = _stt!.lastError;
                      setState(() {
                        _isRecording = false;
                        _isCancelling = false;
                        _stt = null;
                        _sttError = error;
                      });
                      if (error != null) return;
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

  /// 构建 AI 消息朗读按钮（气泡右下角小喇叭）
  Widget _buildTtsButton(String text) {
    return Consumer(
      builder: (_, ref, __) {
        final enabled = ref.watch(ttsEnabledProvider);
        if (!enabled) return const SizedBox.shrink();
        final tts = ref.watch(ttsServiceProvider);
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () => tts.speak(text, language: 'zh-CN'),
              child: Icon(
                Icons.volume_up_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSecondaryContainer.withAlpha(120),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 去除标记符号，使朗读和显示更干净
  String _cleanText(String text) {
    return text
        .replaceAll('**', '')
        .replaceAll('### ', '')
        .replaceAll('## ', '')
        .replaceAll('# ', '')
        .replaceAll('\\(', '')
        .replaceAll('\\)', '')
        .replaceAll('\\[', '')
        .replaceAll('\\]', '');
  }

  /// 渲染消息内容，支持 \(...\) 行内公式和 \[...\] 独立公式
  ///
  /// 流式输出期间跳过数学公式正则解析，避免因 token 分片导致 \(...\) 定界符
  /// 不完整时 raw LaTeX 与渲染公式之间反复闪烁。done 事件后 _streamingIndex 置 -1，
  /// isStreaming 变为 false，由 _finalizeStreaming 触发的 rebuild 会正常渲染全部公式。
  Widget _buildRichContent(String text, {required bool isUser, bool isStreaming = false}) {
    final baseColor = isUser
        ? Colors.white
        : Theme.of(context).colorScheme.onSecondaryContainer;
    final trailing = isStreaming ? '▌' : '';

    // 流式输出期间：纯文本渲染，不解析数学公式
    if (isStreaming) {
      return Text(
        '$text$trailing',
        style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
      );
    }

    // 匹配 \(inline\) 和 \[display\] 数学公式
    final mathRegex = RegExp(r'\\[\(\[](.+?)\\[[)\]]', dotAll: true);

    final matches = mathRegex.allMatches(text).toList();

    if (matches.isEmpty) {
      return Text(
        '$text$trailing',
        style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
      );
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      // 公式前的纯文本
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
        ));
      }

      final isDisplay = text[match.start + 1] == '[';
      final formula = match.group(1)!.trim();

      spans.add(WidgetSpan(
        child: Math.tex(
          formula,
          mathStyle: isDisplay ? MathStyle.display : MathStyle.text,
          textStyle: TextStyle(fontSize: 15, color: baseColor),
        ),
        alignment: PlaceholderAlignment.middle,
      ));

      lastEnd = match.end;
    }

    // 剩余纯文本
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
      ));
    }

    // 流式光标
    if (trailing.isNotEmpty) {
      spans.add(TextSpan(
        text: trailing,
        style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
    );
  }
}
