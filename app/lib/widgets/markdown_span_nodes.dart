import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'graph_widget.dart';

/// 错误边界 — 捕获子组件构建/渲染异常，兜底显示
class _ErrorBoundary extends StatelessWidget {
  final Widget child;
  final String fallbackMsg;
  const _ErrorBoundary({required this.child, this.fallbackMsg = '渲染异常'});

  @override
  Widget build(BuildContext context) {
    final _cs = Theme.of(context).colorScheme;
    try {
      // Builder 确保在正确的 Element 上下文中捕获构建异常
      return Builder(builder: (_) => child);
    } catch (_) {
      return _renderFallback(fallbackMsg, _cs);
    }
  }
}

Widget _renderFallback(String msg, ColorScheme cs) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: cs.errorContainer,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: cs.error.withAlpha(51)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 16, color: cs.error),
        const SizedBox(width: 6),
        Flexible(child: Text(msg, style: TextStyle(fontSize: 12, color: cs.onErrorContainer))),
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
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
  if (color.r < 60 && color.g < 60 && color.b < 60) return formula;
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  final hex = '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
  return r'\textcolor{' '$hex' '}{' '$formula' '}';
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

    // 检测 JSON 格式的 back（课文/诗词的结构化数据）
    final trimmed = text.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final parsed = jsonDecode(trimmed) as Map<String, dynamic>;
        return _buildJsonBack(parsed);
      } catch (_) {
        // 不是合法 JSON，继续按普通文本处理
      }
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
        case BlockType.hr:
          children.add(Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: textColor.withAlpha(50),
            ),
          ));
          break;
        case BlockType.table:
          children.add(_renderMarkdownTable(block.content, textColor: textColor));
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

  /// 渲染 JSON 格式的卡片 back（课文/诗词/古典文学/词典等结构化数据）
  Widget _buildJsonBack(Map<String, dynamic> data) {
    // ── 英语词典查询条 ──
    if (data.containsKey('word') && data.containsKey('definitions')) {
      return _buildDictionaryCard(data);
    }

    // ── 中文词典查询条 ──
    if (data.containsKey('character') && data.containsKey('pinyin')) {
      return _buildChineseDictionaryCard(data);
    }

    final segments = <Widget>[];

    // 正文（full_text）
    if (data.containsKey('full_text')) {
      segments.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          data['full_text'] as String? ?? '',
          style: TextStyle(fontSize: 16, height: 1.6, color: textColor),
        ),
      ));
    }

    // 作者 + 朝代
    final author = data['author'] as String?;
    final dynasty = data['dynasty'] as String?;
    if (author != null || dynasty != null) {
      segments.add(_metaRow('作者', '${dynasty != null ? "$dynasty · " : ""}$author'));
    }

    // 意象 / 名句
    final famousLines = data['famous_lines'] as List?;
    if (famousLines != null && famousLines.isNotEmpty) {
      segments.add(_metaRow('名句', famousLines.join('；')));
    }

    // 意象
    final imagery = data['imagery'] as List?;
    if (imagery != null && imagery.isNotEmpty) {
      segments.add(_metaRow('意象', imagery.join('；')));
    }

    // 手法
    final technique = data['technique'] as List?;
    if (technique != null && technique.isNotEmpty) {
      segments.add(_metaRow('手法', technique.join('、')));
    }

    // 主题
    final theme = data['theme'] as String?;
    if (theme != null && theme.isNotEmpty) {
      segments.add(_metaRow('主题', theme));
    }

    // 常见错误
    final mistakes = data['common_mistakes'] as String?;
    if (mistakes != null && mistakes.isNotEmpty) {
      segments.add(_metaRow('易错', mistakes));
    }

    if (segments.isEmpty) {
      return Text(data.toString(), style: TextStyle(color: textColor));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: segments,
    );
  }

  /// 渲染中文词典查询条
  Widget _buildChineseDictionaryCard(Map<String, dynamic> data) {
    final character = data['character'] as String? ?? '';
    final pinyin = data['pinyin'] as String? ?? '';
    final radical = data['radical'] as String? ?? '';
    final strokes = data['strokes'] as String? ?? '';
    final definitions = data['definitions'] as List<dynamic>? ?? [];
    final commonWords = data['common_words'] as String? ?? '';

    final children = <Widget>[];

    // 标题行：字 + 拼音 + 部首 + 笔画
    children.add(Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(character, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: textColor)),
          if (pinyin.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(pinyin, style: TextStyle(fontSize: 16, color: textColor.withAlpha(150))),
          ],
          if (radical.isNotEmpty) ...[
            const SizedBox(width: 10),
            _buildTag('部首 $radical'),
          ],
          if (strokes.isNotEmpty) ...[
            const SizedBox(width: 6),
            _buildTag(strokes),
          ],
        ],
      ),
    ));

    // 分隔线
    children.add(Divider(height: 1, color: textColor.withAlpha(20)));

    // 每条释义
    for (int i = 0; i < definitions.length; i++) {
      final def = definitions[i] as Map<String, dynamic>;
      final dPos = def['pos'] as String? ?? '';
      final meaning = def['meaning'] as String? ?? '';
      final example = def['example'] as String? ?? '';

      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}. ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor)),
                if (dPos.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: textColor.withAlpha(15),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(dPos, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor.withAlpha(160))),
                  ),
                Expanded(
                  child: Text(meaning, style: TextStyle(fontSize: 14, color: textColor)),
                ),
              ],
            ),
            if (example.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('➤ ', style: TextStyle(fontSize: 13, color: textColor.withAlpha(100))),
                    Expanded(
                      child: Text(example, style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: textColor.withAlpha(160))),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ));
    }

    // 常用词
    if (commonWords.isNotEmpty) {
      children.add(Divider(height: 1, color: textColor.withAlpha(20)));
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text.rich(
          TextSpan(
            text: '常用词：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textColor.withAlpha(180)),
            children: [TextSpan(text: commonWords, style: TextStyle(fontWeight: FontWeight.normal, color: textColor))],
          ),
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 小型标签
  Widget _buildTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: textColor.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: textColor.withAlpha(180))),
    );
  }

  /// 渲染英语词典查询条
  Widget _buildDictionaryCard(Map<String, dynamic> data) {
    final word = data['word'] as String? ?? '';
    final phonetic = data['phonetic'] as String? ?? '';
    final pos = data['pos'] as String? ?? '';
    final definitions = data['definitions'] as List<dynamic>? ?? [];
    final collocations = data['collocations'] as String? ?? '';
    final chinese = data['chinese'] as String? ?? '';

    final children = <Widget>[];

    // 标题行：词 + 音标 + 词性
    children.add(Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(word, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor)),
          if (phonetic.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(phonetic, style: TextStyle(fontSize: 14, color: textColor.withAlpha(150))),
          ],
          if (pos.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: textColor.withAlpha(20),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(pos, style: TextStyle(fontSize: 11, color: textColor.withAlpha(180))),
            ),
          ],
        ],
      ),
    ));

    // 中文摘要
    if (chinese.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(chinese, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: textColor.withAlpha(200))),
      ));
    }

    // 分隔线
    children.add(Divider(height: 1, color: textColor.withAlpha(20)));

    // 每条释义
    for (int i = 0; i < definitions.length; i++) {
      final def = definitions[i] as Map<String, dynamic>;
      final dPos = def['pos'] as String? ?? '';
      final meaning = def['meaning'] as String? ?? '';
      final dChinese = def['chinese'] as String? ?? '';
      final example = def['example'] as String? ?? '';

      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 释义行：序号 + POS标签 + 英文释义 + 中文
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}. ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textColor)),
                if (dPos.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: textColor.withAlpha(15),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(dPos, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor.withAlpha(160))),
                  ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: meaning, style: TextStyle(fontSize: 14, color: textColor)),
                        if (dChinese.isNotEmpty)
                          TextSpan(text: ' （$dChinese）', style: TextStyle(fontSize: 13, color: textColor.withAlpha(140))),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // 例句
            if (example.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('➤ ', style: TextStyle(fontSize: 13, color: textColor.withAlpha(100))),
                    Expanded(
                      child: Text(example, style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: textColor.withAlpha(160))),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ));
    }

    // 搭配
    if (collocations.isNotEmpty) {
      children.add(Divider(height: 1, color: textColor.withAlpha(20)));
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text.rich(
          TextSpan(
            text: '搭配：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textColor.withAlpha(180)),
            children: [TextSpan(text: collocations, style: TextStyle(fontWeight: FontWeight.normal, color: textColor))],
          ),
        ),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 元数据行
  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text('$label：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textColor.withAlpha(180))),
          ),
          Expanded(child: Text(value, style: TextStyle(fontSize: 14, color: textColor))),
        ],
      ),
    );
  }

  Widget _renderTextWithInlineMath(String text) {
    // 预处理: 修复 LLM 常见 Markdown 格式问题
    final fixed = _fixMarkdown(text);
    // 替换 keycap 序号（1️⃣→①）解决 CanvasKit 下序号黑框不居中问题
    final cleaned = _fixKeycaps(fixed);
    final theme = GptMarkdownThemeData(
      brightness: Brightness.light,
      h1: TextStyle(color: textColor, fontSize: 17, fontWeight: FontWeight.w600, height: 1.4),
      h2: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
      h3: TextStyle(color: textColor, fontSize: 15, fontWeight: FontWeight.w600, height: 1.4),
      h4: TextStyle(color: textColor, fontSize: 15, fontWeight: FontWeight.w600),
      h5: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w500),
      h6: TextStyle(color: textColor.withAlpha(180), fontSize: 13),
      hrLineThickness: 1,
      hrLineColor: textColor.withAlpha(50),
      highlightColor: textColor.withAlpha(25),
    );
    return GptMarkdownTheme(
      gptThemeData: theme,
      child: GptMarkdown(
        cleaned,
        style: TextStyle(color: textColor, fontSize: 15, height: 1.5),
        textDirection: TextDirection.ltr,
      ),
    );
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

enum BlockType { text, table, graph, displayMath, hr }

class _TableSegment {
  final int start;
  final int end;
  const _TableSegment(this.start, this.end);
}

class ContentBlock {
  final BlockType type;
  final String content;
  ContentBlock(this.type, this.content);
}

List<ContentBlock> _splitBlockLevel(String text) {
  final lines = text.split('\n');
  final n = lines.length;

  // 第一阶段：扫描以 | 开头的连续行，标记为表格块（至少3行）
  final tableSegments = <_TableSegment>[];
  int i = 0;
  while (i < n) {
    if (lines[i].trimLeft().startsWith('|')) {
      final start = i;
      while (i < n && lines[i].trimLeft().startsWith('|')) {
        i++;
      }
      if (i - start >= 3) {
        tableSegments.add(_TableSegment(start, i));
      }
    } else {
      i++;
    }
  }

  // 第二阶段：按表格位置切片，表格块之间的文本继续用原有的 graph/displayMath 分割
  final blocks = <ContentBlock>[];
  int lastEnd = 0;

  for (final seg in tableSegments) {
    // 表格之前的文本段
    if (seg.start > lastEnd) {
      final segment = lines.sublist(lastEnd, seg.start).join('\n');
      if (segment.trim().isNotEmpty) {
        blocks.addAll(_splitBySpecialBlocks(segment));
      }
    }
    // 表格块
    final tableText = lines.sublist(seg.start, seg.end).join('\n');
    blocks.add(ContentBlock(BlockType.table, tableText));
    lastEnd = seg.end;
  }

  // 尾部
  if (lastEnd < n) {
    final tail = lines.sublist(lastEnd).join('\n');
    if (tail.trim().isNotEmpty) {
      blocks.addAll(_splitBySpecialBlocks(tail));
    }
  }

  return blocks;
}

/// 用原有的 graph/displayMath 正则分割文本块，并在文本块内再分割标题和分割线
List<ContentBlock> _splitBySpecialBlocks(String text) {
  final blocks = <ContentBlock>[];
  final splitter = RegExp(r'(<graph>.*?</graph>|\\\[(.+?)\\\])', dotAll: true);
  final matches = splitter.allMatches(text).toList();

  /// 将文本段按标题（##+ 或 ###文本）和分割线（---）进一步分割为独立块
  void splitTextBlock(String segment) {
    final lines = segment.split('\n');
    var buf = <String>[];
    for (int i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      // 检测标题：已带空格（### 标题）或未带空格（###标题 → 补空格）
      final headingMatch = RegExp(r'^(#{1,6})(\s?.*)$').firstMatch(trimmed);
      if (headingMatch != null) {
        final hash = headingMatch.group(1)!;
        final rest = headingMatch.group(2)!;
        if (rest.isNotEmpty && !rest.startsWith('#')) {
          if (buf.isNotEmpty) {
            blocks.add(ContentBlock(BlockType.text, buf.join('\n')));
            buf = <String>[];
          }
          // 确保 hash 后有空格
          final fixed = rest.startsWith(' ') ? trimmed : '$hash $rest';
          blocks.add(ContentBlock(BlockType.text, fixed));
          continue;
        }
      }
      if (RegExp(r'^-{3,}$').hasMatch(trimmed)) {
        if (buf.isNotEmpty) {
          blocks.add(ContentBlock(BlockType.text, buf.join('\n')));
          buf = <String>[];
        }
        blocks.add(ContentBlock(BlockType.text, trimmed));
      } else if (RegExp(r'^-{3,}$').hasMatch(trimmed)) {
        if (buf.isNotEmpty) {
          blocks.add(ContentBlock(BlockType.text, buf.join('\n')));
          buf = <String>[];
        }
        blocks.add(ContentBlock(BlockType.hr, '---'));
      } else {
        buf.add(lines[i]);
      }
    }
    if (buf.isNotEmpty) {
      blocks.add(ContentBlock(BlockType.text, buf.join('\n')));
    }
  }

  if (matches.isEmpty) {
    splitTextBlock(text);
    return blocks;
  }

  int lastEnd = 0;
  for (final m in matches) {
    if (m.start > lastEnd) {
      final segment = text.substring(lastEnd, m.start);
      if (segment.trim().isNotEmpty) {
        splitTextBlock(segment);
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

/// 用 Flutter Table widget 渲染 Markdown 表格
Widget _renderMarkdownTable(String tableText, {Color textColor = Colors.black87}) {
  final lines = tableText.split('\n');
  if (lines.length < 2) return const SizedBox.shrink();

  // 表头行
  final headerRow = _splitTableRow(lines[0]);
  // 找分隔行（|---| 样式）
  int dataStart = 1;
  if (lines.length > 1 && RegExp(r'^\|[\s\-:]+\|').hasMatch(lines[1].trim())) {
    dataStart = 2;
  }

  // 统一列数
  int colCount = headerRow.length;
  for (int i = dataStart; i < lines.length; i++) {
    final row = _splitTableRow(lines[i]);
    if (row.length > colCount) colCount = row.length;
  }
  if (colCount == 0) return const SizedBox.shrink();

  final children = <TableRow>[];

  // 表头行
  children.add(TableRow(
    decoration: BoxDecoration(color: textColor.withAlpha(15)),
    children: List.generate(colCount, (i) {
      final cellText = i < headerRow.length ? headerRow[i].trim() : '';
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: _buildRichCell(cellText, bold: true, textColor: textColor),
      );
    }),
  ));

  // 数据行
  for (int r = dataStart; r < lines.length; r++) {
    final row = _splitTableRow(lines[r]);
    final isEven = (r - dataStart) % 2 == 0;
    children.add(TableRow(
      decoration: isEven
          ? BoxDecoration(color: textColor.withAlpha(6))
          : null,
      children: List.generate(colCount, (i) {
        final cellText = i < row.length ? row[i].trim() : '';
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: _buildRichCell(cellText, textColor: textColor),
        );
      }),
    ));
  }

  return LayoutBuilder(
    builder: (context, constraints) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Table(
          border: TableBorder.all(color: textColor.withAlpha(40), width: 0.5),
          columnWidths: Map.fromIterables(
            List.generate(colCount, (i) => i),
            // 所有列均分父容器宽度，文字自动换行，不会撑爆屏幕
            List.filled(colCount, FlexColumnWidth(1.0 / colCount)),
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: children,
        ),
      );
    },
  );
}

/// 按 | 分割一行表格文本
List<String> _splitTableRow(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) return [];
  final inner = trimmed.substring(1, trimmed.length - 1);
  final parts = <String>[];
  int depth = 0;
  final buf = StringBuffer();
  for (int i = 0; i < inner.length; i++) {
    final c = inner[i];
    if (c == '|' && depth == 0) {
      parts.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  parts.add(buf.toString());
  // 分隔行（|---| 样式）跳过
  if (parts.every((p) => RegExp(r'^-+\s*$').hasMatch(p.trim()))) return [];
  return parts;
}

/// 构建单个单元格，支持 **bold** 和 \(...\) 公式
Widget _buildRichCell(String text, {bool bold = false, Color textColor = Colors.black87}) {
  if (text.isEmpty) return const SizedBox.shrink();

  // 处理 **bold**
  final boldRegex = RegExp(r'\*\*(.+?)\*\*');
  final formulaRegex = RegExp(r'\\\((.+?)\\\)');

  bool hasBold = boldRegex.hasMatch(text);
  bool hasFormula = formulaRegex.hasMatch(text);

  if (!hasBold && !hasFormula) {
    return Text(
      text,
      softWrap: true,
      style: TextStyle(
        fontSize: 14,
        color: textColor,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  final spans = <InlineSpan>[];
  final combined = <_InlineMatch>[];
  for (final m in boldRegex.allMatches(text)) {
    combined.add(_InlineMatch(m.start, m.end, m.group(0)!, boldRegex));
  }
  for (final m in formulaRegex.allMatches(text)) {
    combined.add(_InlineMatch(m.start, m.end, m.group(0)!, formulaRegex));
  }
  combined.sort((a, b) => a.start.compareTo(b.start));

  int pos = 0;
  for (final im in combined) {
    if (im.start < pos) continue;
    if (im.start > pos) {
      spans.add(TextSpan(
        text: text.substring(pos, im.start),
        style: TextStyle(color: textColor, fontSize: 14),
      ));
    }

    if (im.regex == boldRegex) {
      final inner = im.match.group(1) ?? '';
      spans.add(TextSpan(
        text: inner,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ));
    } else if (im.regex == formulaRegex) {
      final formula = im.match.group(1) ?? '';
      final fixedFormula = _addColorCmd(formula.trim(), textColor);
      spans.add(WidgetSpan(
        child: _ErrorBoundary(
          fallbackMsg: '公式错误',
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Math.tex(
              fixedFormula,
              mathStyle: MathStyle.text,
              textStyle: TextStyle(fontSize: 14, color: textColor),
            ),
          ),
        ),
        alignment: PlaceholderAlignment.middle,
      ));
    }

    pos = im.end;
  }

  if (pos < text.length) {
    spans.add(TextSpan(
      text: text.substring(pos),
      style: TextStyle(color: textColor, fontSize: 14),
    ));
  }

  return RichText(
    text: TextSpan(
      style: TextStyle(
        color: textColor,
        fontSize: 14,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      ),
      children: spans,
    ),
  );
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

/// 替换 keycap 序号表情（1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣）为 circled 数字（① ② ③ ④ ⑤）
/// CanvasKit 不擅长渲染 U+FE0F+U+20E3 组合，导致黑框+不居中+重叠。
String _fixKeycaps(String text) {
  const map = {
    '0️⃣': '⓪', '1️⃣': '①', '2️⃣': '②', '3️⃣': '③', '4️⃣': '④',
    '5️⃣': '⑤', '6️⃣': '⑥', '7️⃣': '⑦', '8️⃣': '⑧', '9️⃣': '⑨',
    '🔟': '⑩',
  };
  var result = text;
  for (final e in map.entries) {
    result = result.replaceAll(e.key, e.value);
  }
  return result;
}
