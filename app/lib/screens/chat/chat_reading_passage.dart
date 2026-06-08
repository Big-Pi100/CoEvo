import 'dart:convert';
import 'package:flutter/material.dart';
import '../../api/chat_client.dart';
import '../../theme/app_theme.dart';

/// 课文阅读面板 — 显示当前 task 的课文全文
/// 仅对 reading-first 模式（english/chinese）生效
class ChatReadingPassage extends StatefulWidget {
  final ChatClient client;
  final String conversationId;

  const ChatReadingPassage({
    super.key,
    required this.client,
    required this.conversationId,
  });

  @override
  State<ChatReadingPassage> createState() => _ChatReadingPassageState();
}

class _ChatReadingPassageState extends State<ChatReadingPassage> {
  Map<String, dynamic>? _card;
  bool _loading = true;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _loadCard();
  }

  Future<void> _loadCard() async {
    if (widget.conversationId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final card = await widget.client.getCurrentReadingCard(widget.conversationId);
    if (mounted) {
      setState(() {
        _card = card;
        _loading = false;
      });
    }
  }

  String _extractFullText(Map<String, dynamic> card) {
    // Try direct full_text field first
    final ft = card['full_text'] as String?;
    if (ft != null && ft.isNotEmpty) return ft;
    // Try parsing back JSON
    final back = card['back'];
    if (back is String) {
      try {
        final parsed = jsonDecode(back) as Map<String, dynamic>;
        return parsed['full_text'] as String? ?? '';
      } catch (_) {}
    } else if (back is Map) {
      return (back as Map<String, dynamic>)['full_text'] as String? ?? '';
    }
    return '';
  }

  String _extractTranslation(Map<String, dynamic> card) {
    final back = card['back'];
    if (back is String) {
      try {
        final parsed = jsonDecode(back) as Map<String, dynamic>;
        return parsed['translation'] as String? ?? '';
      } catch (_) {}
    } else if (back is Map) {
      return (back as Map<String, dynamic>)['translation'] as String? ?? '';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const SizedBox.shrink();
    if (_card == null) return const SizedBox.shrink();

    final fullText = _extractFullText(_card!);
    if (fullText.isEmpty) return const SizedBox.shrink();

    final title = _card!['front'] as String? ?? '课文';
    final titleShort = title.length > 30 ? '${title.substring(0, 30)}…' : title;
    final translation = _extractTranslation(_card!);

    return Container(
      margin: const EdgeInsets.fromLTRB(AppTheme.spacingMd, AppTheme.spacingSm, AppTheme.spacingMd, 0),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.secondary.withAlpha(40)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 头部 ──
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.vertical(top: const Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.menu_book, size: 18, color: cs.secondary),
                  const SizedBox(width: AppTheme.spacingSm),
                  Expanded(
                    child: Text(titleShort, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Icon(
                    _expanded ? Icons.unfold_less : Icons.unfold_more,
                    size: 18, color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // ── 课文正文 ──
          if (_expanded) ...[
            const Divider(height: 1, indent: 14, endIndent: 14),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fullText,
                    style: TextStyle(fontSize: 14, height: 1.6, color: cs.onSurface),
                  ),
                  if (translation.isNotEmpty) ...[
                    const SizedBox(height: AppTheme.spacingSm),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withAlpha(80),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        translation,
                        style: TextStyle(fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
