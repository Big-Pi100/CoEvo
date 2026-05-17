import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'graph_widget.dart';

/// 将 LaTeX display 公式渲染为独立块
class DisplayMathBlock extends StatelessWidget {
  final String formula;
  final Color textColor;
  const DisplayMathBlock(this.formula, {this.textColor = Colors.black87, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Math.tex(
          formula,
          mathStyle: MathStyle.display,
          textStyle: TextStyle(fontSize: 16, color: textColor),
        ),
      ),
    );
  }
}

/// 预处理管线入口：块分割 → Markdown + 自定义块混合渲染
class RichContentBuilder {
  final bool isStreaming;
  final Color textColor;

  RichContentBuilder({this.isStreaming = false, this.textColor = Colors.black87});

  Widget build(String text) {
    if (isStreaming) {
      return Text(text, style: TextStyle(color: textColor, fontSize: 15, height: 1.5));
    }

    final blocks = _splitBlockLevel(text);

    final children = <Widget>[];
    for (final block in blocks) {
      switch (block.type) {
        case BlockType.text:
          if (block.content.trim().isNotEmpty) {
            children.add(_renderTextWithInlineMath(block.content));
          }
          break;
        case BlockType.graph:
          children.add(GraphWidget(jsonStr: block.content));
          break;
        case BlockType.displayMath:
          children.add(DisplayMathBlock(block.content, textColor: textColor));
          break;
      }
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _renderTextWithInlineMath(String text) {
    final inlineRegex = RegExp(r'\\\((.+?)\\\)');
    final matches = inlineRegex.allMatches(text).toList();

    if (matches.isEmpty) {
      // 纯文本块：用 MarkdownWidget（继承默认暗色文字）
      return MarkdownWidget(
        data: text,
        shrinkWrap: true,
        config: MarkdownConfig(configs: [
          BlockquoteConfig(
            textColor: textColor,
            sideColor: textColor.withAlpha(80),
          ),
          PreConfig(
            textStyle: TextStyle(color: textColor, fontSize: 14),
            decoration: BoxDecoration(
              color: textColor.withAlpha(15),
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
          ),
          CodeConfig(
            style: TextStyle(color: textColor, backgroundColor: textColor.withAlpha(20)),
          ),
        ]),
      );
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final m in matches) {
      if (m.start > lastEnd) {
        final mdText = text.substring(lastEnd, m.start);
        _appendMarkdownInline(mdText, spans);
      }

      final formula = m.group(1)!.trim();
      spans.add(WidgetSpan(
        child: Math.tex(
          formula,
          mathStyle: MathStyle.text,
          textStyle: TextStyle(fontSize: 14, color: textColor),
        ),
        alignment: PlaceholderAlignment.middle,
      ));

      lastEnd = m.end;
    }

    if (lastEnd < text.length) {
      _appendMarkdownInline(text.substring(lastEnd), spans);
    }

    return RichText(
      text: TextSpan(style: TextStyle(color: textColor), children: spans),
    );
  }

  void _appendMarkdownInline(String mdText, List<InlineSpan> spans) {
    final boldRegex = RegExp(r'\*\*(.+?)\*\*');
    final codeRegex = RegExp(r'`([^`]+)`');
    final italicRegex = RegExp(r'(?<!\*)\*([^*]+)\*(?!\*)');

    final allMatches = <_InlineMatch>[];
    for (final regex in [boldRegex, codeRegex, italicRegex]) {
      for (final m in regex.allMatches(mdText)) {
        allMatches.add(_InlineMatch(m.start, m.end, m.group(0)!, regex));
      }
    }
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    if (allMatches.isEmpty) {
      spans.add(TextSpan(text: mdText, style: TextStyle(color: textColor)));
      return;
    }

    int pos = 0;
    for (final im in allMatches) {
      if (im.start < pos) continue;
      if (im.start > pos) {
        spans.add(TextSpan(text: mdText.substring(pos, im.start), style: TextStyle(color: textColor)));
      }

      final inner = im.match.group(1) ?? '';
      TextStyle style = TextStyle(color: textColor);
      if (im.regex == boldRegex) {
        style = style.copyWith(fontWeight: FontWeight.bold);
      } else if (im.regex == codeRegex) {
        style = style.copyWith(fontFamily: 'monospace', backgroundColor: textColor.withAlpha(15));
      } else if (im.regex == italicRegex) {
        style = style.copyWith(fontStyle: FontStyle.italic);
      }

      spans.add(TextSpan(text: inner, style: style));
      pos = im.end;
    }

    if (pos < mdText.length) {
      spans.add(TextSpan(text: mdText.substring(pos), style: TextStyle(color: textColor)));
    }
  }
}

class _InlineMatch {
  final int start, end;
  final String full;
  final RegExp regex;
  final RegExpMatch match;
  _InlineMatch(this.start, this.end, this.full, this.regex) : match = regex.firstMatch(full) as RegExpMatch;
}

// ── 块分割 ──

enum BlockType { text, graph, displayMath }

class ContentBlock {
  final BlockType type;
  final String content;
  ContentBlock(this.type, this.content);
}

List<ContentBlock> _splitBlockLevel(String text) {
  final blocks = <ContentBlock>[];
  final splitter = RegExp(r'(<graph>.*?</graph>|\\\[(.+?)\\\])', dotAll: true);
  final matches = splitter.allMatches(text).toList();

  if (matches.isEmpty) {
    blocks.add(ContentBlock(BlockType.text, text));
    return blocks;
  }

  int lastEnd = 0;
  for (final m in matches) {
    if (m.start > lastEnd) {
      final segment = text.substring(lastEnd, m.start);
      if (segment.trim().isNotEmpty) {
        blocks.add(ContentBlock(BlockType.text, segment));
      }
    }

    final raw = m.group(0)!;
    if (raw.startsWith('<graph>')) {
      final json = raw.replaceFirst('<graph>', '').replaceFirst('</graph>', '').trim();
      blocks.add(ContentBlock(BlockType.graph, json));
    } else {
      final formula = m.group(2)?.trim() ?? '';
      blocks.add(ContentBlock(BlockType.displayMath, formula));
    }

    lastEnd = m.end;
  }

  if (lastEnd < text.length) {
    final tail = text.substring(lastEnd);
    if (tail.trim().isNotEmpty) {
      blocks.add(ContentBlock(BlockType.text, tail));
    }
  }

  return blocks;
}
