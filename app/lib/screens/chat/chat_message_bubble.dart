import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/markdown_span_nodes.dart';
import '../../services/tts_service.dart';

/// 消息气泡渲染 — 块分割 + Markdown + LaTeX + Graph
class ChatMessageBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final bool isStreaming;
  final bool showTts;

  const ChatMessageBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.isStreaming = false,
    this.showTts = true,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = isUser
        ? Colors.white
        : Theme.of(context).colorScheme.onSecondaryContainer;

    final content = RichContentBuilder(
      isStreaming: isStreaming,
      textColor: baseColor,
    ).build(text);

    if (isUser || !showTts) return content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        content,
        _buildTtsButton(context, _cleanText(text)),
      ],
    );
  }

  Widget _buildTtsButton(BuildContext context, String cleanText) {
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
              onTap: () => tts.speak(cleanText),
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

  String _cleanText(String text) {
    return text
        .replaceAll('**', '')
        .replaceAll('### ', '')
        .replaceAll('## ', '')
        .replaceAll('# ', '')
        .replaceAll('\\(', '')
        .replaceAll('\\)', '')
        .replaceAll('\\[', '')
        .replaceAll('\\]', '')
        .replaceAll(RegExp(r'<graph>.*?</graph>', dotAll: true), '');
  }
}
