import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/stt_service.dart';

/// 聊天输入栏 — 文本输入 + 语音输入切换
class ChatInput extends ConsumerStatefulWidget {
  final TextEditingController textController;
  final bool isWaiting;
  final bool isDeleted;
  final VoidCallback onSend;

  const ChatInput({
    super.key,
    required this.textController,
    required this.isWaiting,
    required this.isDeleted,
    required this.onSend,
  });

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends ConsumerState<ChatInput> {
  bool _voiceMode = false;
  bool _isRecording = false;
  bool _isCancelling = false;
  SttService? _stt;
  String? _sttError;

  @override
  Widget build(BuildContext context) {
    if (widget.isDeleted) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 模式切换按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                icon: Icon(_voiceMode ? Icons.keyboard : Icons.mic, size: 20),
                onPressed: () => setState(() {
                  _voiceMode = !_voiceMode;
                  _isRecording = false;
                  _isCancelling = false;
                  _sttError = null;
                }),
                tooltip: _voiceMode ? '键盘输入' : '语音输入',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
          if (_voiceMode) _buildVoiceInput() else _buildTextInput(),
        ],
      ),
    );
  }

  // ── 文本输入 ──
  Widget _buildTextInput() {
    return Row(
      children: [
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: widget.textController,
            decoration: const InputDecoration(
              hintText: '输入消息...',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => widget.onSend(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: widget.isWaiting ? null : widget.onSend,
          icon: widget.isWaiting
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.send),
        ),
      ],
    );
  }

  // ── 语音输入 ──
  Widget _buildVoiceInput() {
    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_sttError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_sttError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
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
                        widget.textController.text = text;
                        widget.onSend();
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
}
