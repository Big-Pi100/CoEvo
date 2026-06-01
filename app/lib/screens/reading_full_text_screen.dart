import 'package:flutter/material.dart';

/// 课文全文阅读界面
///
/// 从 chat_screen 的"查看全文"按钮进入，接收当前课文卡片的完整数据。
class ReadingFullTextScreen extends StatefulWidget {
  final String title;           // 课文名（front）
  final String author;          // 作者
  final String fullText;        // 全文
  final List<String>? appreciation;
  final List<String>? technique;
  final String? theme;
  final String? commonMistakes;

  const ReadingFullTextScreen({
    super.key,
    required this.title,
    this.author = '',
    required this.fullText,
    this.appreciation,
    this.technique,
    this.theme,
    this.commonMistakes,
  });

  @override
  State<ReadingFullTextScreen> createState() => _ReadingFullTextScreenState();
}

class _ReadingFullTextScreenState extends State<ReadingFullTextScreen> {
  double _fontSize = 17.0;
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      final show = currentScroll < maxScroll - 200;
      if (show != _showScrollToBottom) {
        setState(() => _showScrollToBottom = show);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            if (widget.author.isNotEmpty)
              Text(widget.author, style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          // 字号调节
          PopupMenuButton<double>(
            icon: const Icon(Icons.text_fields),
            tooltip: '字号',
            onSelected: (size) => setState(() => _fontSize = size),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 14.0, child: Text('小 (14px)')),
              const PopupMenuItem(value: 17.0, child: Text('中 (17px)')),
              const PopupMenuItem(value: 20.0, child: Text('大 (20px)')),
              const PopupMenuItem(value: 24.0, child: Text('超大 (24px)')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          // 正文
          SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: _fontSize + 6,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (widget.author.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.author,
                    style: TextStyle(
                      fontSize: _fontSize - 2,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                // 分隔线
                Divider(color: colorScheme.outlineVariant),
                const SizedBox(height: 16),
                // 正文
                SelectableText(
                  widget.fullText,
                  style: TextStyle(
                    fontSize: _fontSize,
                    height: 1.8,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 40),
                // 赏析（如有）
                if (widget.appreciation != null && widget.appreciation!.isNotEmpty) ...[
                  const Divider(),
                  const SizedBox(height: 8),
                  Text('语句赏析', style: TextStyle(
                    fontSize: _fontSize + 2, fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  )),
                  const SizedBox(height: 8),
                  ...widget.appreciation!.map((a) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.format_quote, size: 18, color: colorScheme.primary.withValues(alpha: 0.6)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(a, style: TextStyle(fontSize: _fontSize - 1, height: 1.6))),
                      ],
                    ),
                  )),
                ],
                // 手法（如有）
                if (widget.technique != null && widget.technique!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('写作手法', style: TextStyle(
                    fontSize: _fontSize + 2, fontWeight: FontWeight.w600,
                    color: colorScheme.secondary,
                  )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8, runSpacing: 6,
                    children: widget.technique!.map((t) => Chip(
                      label: Text(t, style: const TextStyle(fontSize: 13)),
                      visualDensity: VisualDensity.compact,
                    )).toList(),
                  ),
                ],
                // 主旨（如有）
                if (widget.theme != null && widget.theme!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('主旨', style: TextStyle(
                    fontSize: _fontSize + 2, fontWeight: FontWeight.w600,
                    color: colorScheme.tertiary,
                  )),
                  const SizedBox(height: 4),
                  Text(widget.theme!, style: TextStyle(fontSize: _fontSize - 1, height: 1.6)),
                ],
                // 底部留白
                const SizedBox(height: 100),
              ],
            ),
          ),
          // 滚动到底按钮
          if (_showScrollToBottom)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.small(
                heroTag: 'scroll_to_bottom',
                onPressed: _scrollToBottom,
                child: const Icon(Icons.arrow_downward),
              ),
            ),
        ],
      ),
    );
  }
}
