import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'graph_widget.dart';

/// 错误边界 — 捕获子组件构建/渲染异常，兜底显示
class _ErrorBoundary extends StatelessWidget {
  final Widget child;
  final String fallbackMsg;
  const _ErrorBoundary({required this.child, this.fallbackMsg = '渲染异常'});

  @override
  Widget build(BuildContext context) {
    try {
      // Builder 确保在正确的 Element 上下文中捕获构建异常
      return Builder(builder: (_) => child);
    } catch (_) {
      return _renderFallback(fallbackMsg);
    }
  }
}

Widget _renderFallback(String msg) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.orange.shade200),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 16, color: Colors.orange.shade700),
        const SizedBox(width: 6),
        Flexible(child: Text(msg, style: TextStyle(fontSize: 12, color: Colors.orange.shade800))),
      ],
    ),
  );
}

/// 将 LaTeX display 公式渲染为独立块
///
/// flutter_math_fork 0.7.x 存在已知问题: textStyle.color 不会传递到所有 TeX 原子
/// 这里使用 \textcolor 注入来强制数字/符号的颜色一致
class DisplayMathBlock extends StatelessWidget {
  final String formula;
  final Color textColor;
  const DisplayMathBlock(this.formula, {this.textColor = Colors.black87, super.key});

  @override
  Widget build(BuildContext context) {
    final fixed = _addColorCmd(formula, textColor);
    return _ErrorBoundary(
      fallbackMsg: '公式渲染失败',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Math.tex(
            fixed,
            mathStyle: MathStyle.display,
            textStyle: TextStyle(fontSize: 16, color: textColor),
          ),
        ),
      ),
    );
  }
}

/// 在 LaTeX 公式外包裹 \textcolor，解决数字/符号颜色不继承的问题
/// 如果公式已有颜色指令则跳过。仅对简单公式注入，复杂公式（含环境）跳过以免破坏语法
String _addColorCmd(String formula, Color color) {
  if (color == Colors.black87 || color == Colors.black || color == Colors.white) return formula;
  // 已有颜色指令
  if (formula.contains(r'\color') || formula.contains(r'\textcolor')) return formula;
  // 含复杂环境时跳过，\textcolor 包裹会破坏内部结构
  if (formula.contains(r'\begin') || formula.contains(r'\\') || formula.contains(r'\cr')) return formula;
  // 颜色接近深色/黑色时也跳过（flutter_math_fork 对深色渲染正常）
  if (color.red < 60 && color.green < 60 && color.blue < 60) return formula;
  final hex = '#${color.red.toRadixString(16).padLeft(2, '0')}${color.green.toRadixString(16).padLeft(2, '0')}${color.blue.toRadixString(16).padLeft(2, '0')}';
  return r'\textcolor{' + hex + '}{' + formula + '}';
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
          children.add(_ErrorBoundary(
            fallbackMsg: '图形渲染失败',
            child: GraphWidget(jsonStr: block.content),
          ));
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
      // 纯文本块：MarkdownWidget — 强制继承 textColor
      // 预处理: 修复 LLM 常见 Markdown 格式问题
      final fixed = _fixMarkdown(text);
      return DefaultTextStyle(
        style: TextStyle(color: textColor, fontSize: 15, height: 1.5),
        child: MarkdownWidget(
          data: fixed,
          shrinkWrap: true,
          config: MarkdownConfig(configs: [
            BlockquoteConfig(textColor: textColor, sideColor: textColor.withAlpha(80)),
            PreConfig(textStyle: TextStyle(color: textColor, fontSize: 14),
              decoration: BoxDecoration(color: textColor.withAlpha(15), borderRadius: const BorderRadius.all(Radius.circular(8)))),
            CodeConfig(style: TextStyle(color: textColor, backgroundColor: textColor.withAlpha(20))),
            PConfig(textStyle: TextStyle(color: textColor, fontSize: 15)),
          ]),
        ),
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
      final fixedFormula = _addColorCmd(formula, textColor);
      spans.add(WidgetSpan(
        child: _ErrorBoundary(
          fallbackMsg: '公式错误',
          child: Math.tex(
            fixedFormula,
            mathStyle: MathStyle.text,
            textStyle: TextStyle(fontSize: 14, color: textColor),
          ),
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

/// 修复 LLM 常见 Markdown 格式问题
/// 1. `##text` → `## text`（CommonMark 要求 # 后有空格）
/// 2. 缺失表格分隔行 → 自动补 `|---|---|`
String _fixMarkdown(String text) {
  // 1. ATX 标题：确保 # 后有空格
  var fixed = text.replaceAllMapped(
    RegExp(r'^(#{1,6})([^\s#])', multiLine: true),
    (m) => '${m.group(1)} ${m.group(2)}',
  );

  // 2. 表格：如果第一行是 |...|，第二行不是 |---|，自动补分隔行
  final lines = fixed.split('\n');
  final buf = <String>[];
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    buf.add(lines[i]); // 保留原始缩进

    // 检测表格头行
    if (line.startsWith('|') && line.endsWith('|') && line.contains('|')) {
      // 检查下一行是否是分隔行
      final nextIdx = i + 1;
      if (nextIdx < lines.length) {
        final next = lines[nextIdx].trim();
        final isSep = RegExp(r'^\|[\s\-:]+\|').hasMatch(next);
        if (!isSep && next.startsWith('|') && !next.contains('---')) {
          // 缺失分隔行 — 自动生成
          final cols = '|'.allMatches(line).length - 1;
          final sep = List.filled(cols, '---').join('|');
          buf.add('|$sep|');
          i = nextIdx - 1; // 下一轮处理原来的"下一行"
        }
      }
    }
  }
  return buf.join('\n');
}
