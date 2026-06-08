import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/app_theme.dart';

/// 聊天输入栏 — 文本输入
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
  ColorScheme get _cs => Theme.of(context).colorScheme;
  @override
  Widget build(BuildContext context) {
    if (widget.isDeleted) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingMd, vertical: AppTheme.spacingSm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: _buildTextInput(),
    );
  }

  // ── 文本输入 ──
  Widget _buildTextInput() {
    return Row(
      children: [
        const SizedBox(width: AppTheme.spacingXs),
        Expanded(
          child: TextField(
            controller: widget.textController,
            decoration: const InputDecoration(
              hintText: '输入消息...',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: AppTheme.spacingLg, vertical: AppTheme.spacingMd),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => widget.onSend(),
          ),
        ),
        const SizedBox(width: AppTheme.spacingSm),
        IconButton.filled(
          onPressed: widget.isWaiting ? null : widget.onSend,
          icon: widget.isWaiting
              ? SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _cs.onPrimary),
                )
              : const Icon(Icons.send),
        ),
      ],
    );
  }
}

