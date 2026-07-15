import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../providers/achievement_notifier.dart';
import '../services/tts_service.dart';
import '../widgets/skeleton.dart';
import '../widgets/subscribe_panel.dart';
import '../widgets/claim_dialog.dart';
import '../widgets/review_dialog.dart';
import '../providers/subscription_provider.dart';
import '../providers/dialog_queue_provider.dart';
import 'chat/chat_concept_dialog.dart';
import 'chat/chat_input.dart';
import 'chat/chat_plan_panel.dart';
import 'chat/chat_reading_passage.dart';
import 'chat/chat_message_bubble.dart';
import '../theme/app_theme.dart';
import '../providers/plan_provider.dart' hide cardRefreshProvider;
import '../widgets/twemoji.dart';

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
  final _messageController = TextEditingController();
  final _messages = <Message>[];
  final _scrollController = ScrollController();

  ChatClient? _client;
  WsChatSession? _session;
  StreamSubscription<WsEvent>? _sessionSub;
  bool _isWaiting = false;
  bool _subscriptionBlocked = false;
  String _convId = '';
  bool _isInitializing = true;

  // 学习计划 (现由 PlanProvider 管理)
  final _planCollapseSignal = ValueNotifier<int>(0);

  // 订阅状态
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
        // 认证已恢复但 userId 仍为 null → 用户已在后端被删除，提前退出
        if (auth.isRestored) break;
        await Future.delayed(const Duration(milliseconds: 150));
      }
      if (userId == null) {
        debugPrint('ChatScreen._init: 认证不可用 (用户可能已在后端被删除), 跳转到首页');
        if (mounted) context.go('/');
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

      // 绑定 TTS 客户端（用于朗读时读取引擎偏好）
      ref.read(ttsServiceProvider).bindClient(_client!);

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
          try { setState(() {
            for (final turn in ascTurns) {
              _messages.add(Message(
                role: turn['role'] as String? ?? 'assistant',
                content: turn['content'] as String? ?? '',
                timestamp: DateTime.now(),
              ));
            }
          }); } catch (_) {}
          _scrollToBottom();
        } else {
          try { if (mounted) setState(() {
            _messages.add(Message(
              role: 'assistant',
              content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
              timestamp: DateTime.now(),
            ));
          }); } catch (_) {}
        }
      } catch (e) {
        debugPrint('_init: history load failed: $e');
        try { if (mounted) setState(() {
          _messages.add(Message(
            role: 'assistant',
            content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
            timestamp: DateTime.now(),
          ));
        }); } catch (_) {}
      }

      // 等待计划和订阅加载完成
      await planFuture;
      await subFuture;

      // ── 检查复习状态 → 触发复习弹窗 ──
      debugPrint('_init: planFuture + subFuture done, calling _checkReviewStatus');
      _checkReviewStatus();

    } catch (e) {
      debugPrint('_init: fatal error: $e');
      try { if (mounted) setState(() {
        _messages.add(Message(
          role: 'assistant',
          content: '你好！我是你的 AI 学习助手。有什么想学的吗？',
          timestamp: DateTime.now(),
        ));
      }); } catch (_) {}
    } finally {
      // 无论如何都要解除初始化状态，防止永久灰屏
      try { if (mounted) setState(() => _isInitializing = false); } catch (_) {}
      // 注册/认领弹窗由首页 HomeScreen 统一处理，聊天页不再独立弹出
    }
  }

  Future<void> _loadPlan() async {
    if (_client == null) return;
    try { await ref.read(planProvider.notifier).loadPlans(_client!, conversationId: _convId); } catch (_) {}
  }

  Future<void> _checkSubscription() async {
    await ref.fetchSubscription();
    // provider 状态已更新，后续 build 通过 ref.watch 自动响应
  }

  /// 查询复习状态，有到期卡片且未推迟时触发复习弹窗
  Future<void> _checkReviewStatus() async {
    final client = _client;
    if (client == null) return;
    // 重新拉取订阅状态（切换会话时缓存可能过期）
    await ref.fetchSubscription();
    final subStatus = ref.read(subscriptionProvider);
    if (subStatus.isExpired || subStatus.isRequired) {
      debugPrint('_checkReviewStatus: skipped (subscription not active)');
      return;
    }
    try {
      final uri = Uri.parse('${client.baseUrl}/api/review/status').replace(
        queryParameters: {
          'user_id': client.userId,
          if (_convId.isNotEmpty) 'conversation_id': _convId,
        },
      );
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (client.token != null && client.token!.isNotEmpty)
          'Authorization': 'Bearer ${client.token}',
      };
      final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 5));
      debugPrint('_checkReviewStatus: status=${resp.statusCode} body=${resp.body}');
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final hasDue = data['has_due'] as bool? ?? false;
      final isDeferred = data['is_deferred'] as bool? ?? false;
      if (!hasDue || isDeferred) return;

      // 锁定当前会话 ID（防止 async 期间 _convId 因 widget 重建而变化）
      final lockedConvId = _convId;

      // 有到期卡片且未推迟 → 获取所有到期卡片（支持分页累加）
      List<DueCard> allCards = [];
      int offset = 0;
      const int pageSize = 200;
      bool hasMore = true;
      while (hasMore) {
        final dueUri = Uri.parse('${client.baseUrl}/api/review/due').replace(
          queryParameters: {
            'user_id': client.userId,
            'limit': pageSize.toString(),
            'offset': offset.toString(),
            if (lockedConvId.isNotEmpty) 'conversation_id': lockedConvId,
          },
        );
        final dueResp = await http.get(dueUri, headers: {
          'Content-Type': 'application/json',
          if (client.token != null && client.token!.isNotEmpty)
            'Authorization': 'Bearer ${client.token}',
        }).timeout(const Duration(seconds: 10));
        if (dueResp.statusCode != 200) return;
        final dueData = jsonDecode(dueResp.body) as Map<String, dynamic>;
        final batch = (dueData['cards'] as List<dynamic>?)
                ?.map((e) => DueCard.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        allCards.addAll(batch);
        hasMore = dueData['has_more'] as bool? ?? false;
        offset += batch.length;
      }
      if (allCards.isEmpty) return;

      if (!mounted) return;
      debugPrint('_checkReviewStatus: ReviewDialog with ${allCards.length} cards');

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ReviewDialog(
          cards: allCards,
          conversationId: lockedConvId.isNotEmpty ? lockedConvId : null,
        ),
      ).then((_) {
        // 对话框关闭后重新检查是否还有到期卡片
        if (mounted) _checkReviewStatus();
      });
      debugPrint('_checkReviewStatus: review dialog shown');
    } catch (e) {
      debugPrint('ChatScreen._checkReviewStatus error: $e');
    }
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _session?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    try { ref.read(planProvider.notifier).clear(); } catch (_) {}
    super.dispose();
  }

  void _addMessage(Message msg) {
    setState(() => _messages.add(msg));
    Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _client == null || _isWaiting || _subscriptionBlocked) return;

    // 用户发新消息时停止正在播放的 TTS，避免与即将到来的新回复音频交叠
    ref.read(ttsServiceProvider).stop();

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
          context.go('/');
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
            context.go('/');
          }
          break;
        }
        if (event.content == 'subscription_expired') {
          ref.read(subscriptionProvider.notifier).setExpired();
          setState(() {
            _isWaiting = false;
            _subscriptionBlocked = true;
          });
          // 清理空的 AI 气泡
          if (_streamingIndex >= 0 && _streamingIndex < _messages.length) {
            _messages.removeAt(_streamingIndex);
          }
          _streamingIndex = -1;
          _streamingBuffer = '';
          if (!_subscriptionDialogShown) {
            _subscriptionDialogShown = true;
            if (_isTrialUser()) {
              _showTrialClaimDialog();
            } else {
              _showSubscriptionDialog('订阅已到期');
            }
          }
        } else if (event.content == 'subscription_required') {
          ref.read(subscriptionProvider.notifier).setRequired();
          setState(() {
            _isWaiting = false;
            _subscriptionBlocked = true;
          });
          // 清理空的 AI 气泡
          if (_streamingIndex >= 0 && _streamingIndex < _messages.length) {
            _messages.removeAt(_streamingIndex);
          }
          _streamingIndex = -1;
          _streamingBuffer = '';
          if (!_subscriptionDialogShown) {
            _subscriptionDialogShown = true;
            if (_isTrialUser()) {
              _showTrialClaimDialog();
            } else {
              _showSubscriptionDialog('需要激活');
            }
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
      case 'tts_audio':
        // 收到 TTS 音频 → 缓存并检查自动播放开关
        if (event.audio != null && event.audio!.isNotEmpty) {
          final text = _getLastAssistantText();
          if (text != null) {
            try {
              final bytes = base64Decode(event.audio!);
              if (bytes.isEmpty) {
                debugPrint('[TTS] WS tts_audio: decoded audio is empty');
                break;
              }
              final tts = ref.read(ttsServiceProvider);
              tts.cacheAudio(text, Uint8List.fromList(bytes));
              if (ref.read(ttsAutoPlayProvider)) {
                tts.playAutoStream(Uint8List.fromList(bytes));
              }
            } catch (e) {
              debugPrint('[TTS] WS tts_audio decode failed: $e');
            }
          }
        }
        break;
    }
  }

  void _updateStreaming(String content) {
    if (_streamingIndex < 0 || _streamingIndex >= _messages.length) {
      return;
    }
    setState(() {
      _messages[_streamingIndex] = Message(
        role: 'assistant', content: content, timestamp: DateTime.now(),
      );
    });
    _scrollToBottom();
  }

  void _finalizeStreaming(String reply) {
    if (_streamingIndex < 0) {
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
    _scrollToBottom();
    // 自动朗读：WS tts_audio 消息由 case 'tts_audio' 统一处理
    // （腾讯云引擎走 WS 推送，本地引擎走用户点击按钮）
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

  bool _isTrialUser() {
    final auth = ref.read(authProvider);
    return (auth.username ?? '').startsWith('trial_');
  }

  void _showSubscriptionDialog(String title) {
    if (!mounted) return;
    final auth = ref.read(authProvider);
    final isTrial = (auth.username ?? '').startsWith('trial_');

    // 临时账户 → 弹出注册弹窗
    if (isTrial) {
      _showTrialClaimDialog();
      return;
    }

    // 正常账户 → 订阅面板
    // 使用微任务延迟到当前帧结束后再弹出，避免嵌套 setState 导致 context 失效
    Future.microtask(() {
      if (!mounted) return;
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
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SubscribePanel(),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Tw('我知道了'),
            ),
          ],
        ),
      );
    });
  }

  void _showTrialClaimDialog() {
    if (!mounted) return;
    Future.microtask(() {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) => const ClaimDialog(),
      );
    });
  }

  /// 订阅状态横幅（主动检查结果显示在聊天页顶部）
  Widget _buildSubscriptionBanner() {
    final subStatus = ref.watch(subscriptionProvider);
    if (!subStatus.isChecked) return const SizedBox.shrink();
    if (!subStatus.isRequired && !subStatus.isExpired) return const SizedBox.shrink();

    final isExpired = subStatus.isExpired;
    final auth = ref.read(authProvider);
    final isTrial = (auth.username ?? '').startsWith('trial_');

    // 临时账户 → 引导注册
    if (isTrial) {
      return Container(
        margin: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _cs.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _cs.primary),
        ),
        child: Row(
          children: [
            Icon(Icons.card_giftcard, size: 18, color: _cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: () => _showTrialClaimDialog(),
                child: Tw(
                  '试用已到期，立即注册即可获得3天免费试用',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _cs.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 正常账户 → 续费引导
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
            child: GestureDetector(
              onTap: () => _showSubscriptionDialog(isExpired ? '订阅已到期' : '需要订阅'),
              child: Tw(
                isExpired ? '订阅已到期，点击续费' : '需要激活订阅，点击开通',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isExpired ? _cs.error : _cs.secondary,
                ),
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
            child: Tw(
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
    debugPrint('ChatScreen.build: mounted=$mounted isInitializing=$_isInitializing');
    final planState = ref.watch(planProvider);
    final activePlan = planState.getPlanForConversation(_convId);
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
                if (mounted) {
                  setState(() => _isInitializing = false);
                  _checkReviewStatus(); // 新会话的复习检查
                }
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
      body: GestureDetector(
        onTap: () => _planCollapseSignal.value++,
        behavior: HitTestBehavior.translucent,
        child: Column(
          children: [
          // 学习计划面板（持久展示，不被对话推没）
          if (activePlan != null)
            ChatPlanPanel(
              plan: {
                'goal': activePlan.goal,
                'plan': {'stages': activePlan.stages ?? []},
                'conversation_id': activePlan.conversationId,
                'card_count': activePlan.totalCards,
              },
              collapseSignal: _planCollapseSignal,
            )
          else if (planState.isLoading)
            // Plan 加载中
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在加载学习计划...', style: TextStyle(fontSize: 13, color: Colors.grey)),
                ],
              ),
            ),
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
                              label: Tw('重试', style: TextStyle(fontSize: 13)),
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
            isBlocked: _subscriptionBlocked,
            onSend: _sendMessage,
          ),
        ],
      ),
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

  /// 获取最后一条助理回复的文本（用于 TTS 缓存键）
  String? _getLastAssistantText() {
    if (_streamingIndex >= 0 && _streamingIndex < _messages.length) {
      final msg = _messages[_streamingIndex];
      if (msg.role == 'assistant') return msg.content;
    }
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'assistant') return _messages[i].content;
    }
    return null;
  }

}

