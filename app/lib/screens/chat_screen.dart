import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/coevo_models.dart';
import '../api/chat_client.dart';
import '../providers/auth_provider.dart';
import '../services/stt_service.dart';

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
  bool _isWaiting = false;
  String _convId = '';

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
  }

  @override
  void dispose() {
    _session?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addMessage(Message msg) {
    setState(() => _messages.add(msg));
    _scrollToBottom();
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _client == null || _isWaiting) return;

    _messageController.clear();
    _addMessage(Message(
      role: 'user', content: text, timestamp: DateTime.now(),
    ));

    setState(() => _isWaiting = true);

    // 启动 WebSocket 流式通信
    _session?.cancel();
    _session = _client!.streamChat(text);

    _streamingBuffer = '';
    setState(() {
      _streamingIndex = _messages.length;
      _messages.add(Message(
        role: 'assistant', content: '', timestamp: DateTime.now(),
      ));
      _streamingIndex = _messages.length - 1;
    });

    _session!.events.listen(
      (event) {
        switch (event.type) {
          case 'thinking':
            _updateStreaming('思考中...');
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
            _finalizeStreaming('抱歉，出了点问题：${event.content}');
            break;
        }
      },
      onError: (error) => _finalizeStreaming('连接错误：$error'),
      onDone: () {
        if (_streamingIndex >= 0 && _streamingBuffer.isNotEmpty) {
          _finalizeStreaming(_streamingBuffer);
        }
      },
    );
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

  // ── 制卡确认弹窗 ──

  void _showConceptDialog(List<ConceptCandidate> candidates) {
    if (!mounted || candidates.isEmpty) return;
    final selected = List.generate(candidates.length, (_) => true);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('发现值得记住的知识点'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, i) => CheckboxListTile(
                  title: Text(candidates[i].front),
                  subtitle: candidates[i].back != null
                      ? Text(candidates[i].back!, maxLines: 2, overflow: TextOverflow.ellipsis)
                      : null,
                  value: selected[i],
                  onChanged: (v) => setDialogState(() => selected[i] = v ?? false),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // 跳过全部
                  for (final c in candidates) {
                    _client?.skipConcept(c.front, c.sourceSentence ?? '');
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('跳过全部'),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  // 批量制卡
                  final toCreate = <Map<String, dynamic>>[];
                  for (var i = 0; i < candidates.length; i++) {
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
                },
                child: const Text('确认制卡'),
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
        title: const Text('AI 对话'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '对话列表',
            onPressed: () => context.push('/conversations'),
          ),
          // 新对话按钮
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: '新对话',
            onPressed: () {
              ref.read(currentConversationIdProvider.notifier).state = null;
              setState(() {
                _messages.clear();
                _convId = 'conv_${DateTime.now().millisecondsSinceEpoch}';
                ref.read(currentConversationIdProvider.notifier).state = _convId;
              });
              _client = ChatClient(
                userId: ref.read(authProvider).userId ?? 'default_user',
                conversationId: _convId,
                token: ref.read(authProvider).token,
              );
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
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final msg = _messages[i];
                final isUser = msg.role == 'user';
                final isStreaming = i == _streamingIndex;
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser
                          ? Theme.of(context).colorScheme.primary
                          : const Color(0xFFF0F4FF),
                      borderRadius: BorderRadius.circular(20).copyWith(
                        bottomRight: isUser ? const Radius.circular(4) : null,
                        bottomLeft: !isUser ? const Radius.circular(4) : null,
                      ),
                    ),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    child: Text(
                      msg.content + (isStreaming ? '▌' : ''),
                      style: TextStyle(
                        color: isUser ? Colors.white : const Color(0xFF1A1A2E),
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),
                  ),
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