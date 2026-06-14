import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../widgets/markdown_span_nodes.dart';
import '../../services/tts_service.dart';
import '../../theme/app_theme.dart';

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
        ? Theme.of(context).colorScheme.onPrimary
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
        final autoPlay = ref.watch(ttsAutoPlayProvider);
        final tts = ref.watch(ttsServiceProvider);
        final isLoading = tts.state == TtsState.loading;
        final isPlayingTts = tts.isPlaying;
        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: AppTheme.spacingXs),
            child: GestureDetector(
              onTap: isLoading ? null : () {
                if (autoPlay || isPlayingTts) {
                  // 正在播放或自动播放已开启 → 停止 + 关闭
                  tts.stop();
                  ref.read(ttsAutoPlayProvider.notifier).state = false;
                } else {
                  // 未播放 → 播放 + 开启自动播放
                  tts.togglePlay(cleanText);
                  ref.read(ttsAutoPlayProvider.notifier).state = true;
                }
              },
              child: isLoading
                  ? SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Icon(
                      autoPlay || isPlayingTts
                          ? Icons.volume_up
                          : Icons.volume_up_outlined,
                      size: 16,
                      color: autoPlay || isPlayingTts
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSecondaryContainer.withAlpha(120),
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
