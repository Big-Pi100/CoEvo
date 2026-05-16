import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import '../../widgets/graph_widget.dart';
import '../../services/tts_service.dart';

/// 消息气泡渲染 — 支持 Markdown 粗体、数学公式、图形标签
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

    final content = _buildRichContent(context, text, baseColor, isStreaming);

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

  // ── 内容渲染 ──

  Widget _buildRichContent(BuildContext context, String text, Color baseColor, bool isStreaming) {
    if (isStreaming) {
      return Text(text, style: TextStyle(color: baseColor, fontSize: 15, height: 1.5));
    }

    // <graph>...</graph> 标签解析
    final graphRegex = RegExp(r'<graph>(.*?)</graph>', dotAll: true);
    final graphMatches = graphRegex.allMatches(text).toList();

    if (graphMatches.isEmpty) {
      return _buildMathContent(text, baseColor);
    }

    final children = <Widget>[];
    int lastEnd = 0;
    for (final g in graphMatches) {
      if (g.start > lastEnd) {
        final segment = text.substring(lastEnd, g.start).trim();
        if (segment.isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildMathContent(segment, baseColor),
          ));
        }
      }
      children.add(GraphWidget(jsonStr: g.group(1)!));
      lastEnd = g.end;
    }
    if (lastEnd < text.length) {
      final tail = text.substring(lastEnd).trim();
      if (tail.isNotEmpty) {
        children.add(_buildMathContent(tail, baseColor));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 纯文本 + 数学公式渲染
  Widget _buildMathContent(String text, Color baseColor) {
    final mathRegex = RegExp(r'\\[\(\[](.+?)\\[[)\]]', dotAll: true);
    final matches = mathRegex.allMatches(text).toList();

    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: baseColor, fontSize: 15, height: 1.5));
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;
    for (final match in matches) {
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
          mathStyle: MathStyle.display,
          textStyle: TextStyle(
            fontSize: isDisplay ? 16 : 14,
            color: baseColor,
          ),
        ),
      ));
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(color: baseColor, fontSize: 15, height: 1.5),
      ));
    }

    return RichText(text: TextSpan(children: spans));
  }

  // ── TTS ──

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
              onTap: () => tts.speak(cleanText, language: 'zh-CN'),
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
        .replaceAll('\\]', '');
  }
}
