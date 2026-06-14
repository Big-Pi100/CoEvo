import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/chat_client.dart';
import '../../services/tts_service.dart';
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
    // 优先取顶层 full_text 字段（后端已平铺）
    final ft = card['full_text'] as String?;
    if (ft != null && ft.isNotEmpty) return ft;
    // V4 回退：back 本身已是纯文本（literature 卡片的 plt.full_text）
    final back = card['back'];
    if (back is String && !back.startsWith('{') && !back.startsWith('[')) {
      return back;
    }
    return '';
  }

  String _extractTranslation(Map<String, dynamic> card) {
    // 取顶层 translation 字段（后端已平铺）
    final t = card['translation'] as String?;
    if (t != null && t.isNotEmpty) return t;
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
                  if (fullText.isNotEmpty)
                    Consumer(builder: (_, ref, __) {
                      final tts = ref.read(ttsServiceProvider);
                      final isTtsLoading = tts.state == TtsState.loading;
                      final isPlaying = tts.isPlaying;
                      return IconButton(
                        icon: isTtsLoading
                            ? SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2, color: cs.secondary,
                                ),
                              )
                            : Icon(
                                isPlaying ? Icons.stop_circle_outlined : Icons.volume_up,
                                size: 18, color: cs.secondary,
                              ),
                        onPressed: isTtsLoading ? null : () => tts.togglePlay(fullText),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        tooltip: '朗读课文',
                      );
                    }),
                  const SizedBox(width: 4),
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
