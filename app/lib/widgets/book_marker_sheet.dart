import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/book_provider.dart';
import '../providers/book_marker_provider.dart';
import '../services/ebook/book_marker.dart';
import '../services/ebook/book_marker_repository.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 本书的书签列表（底部弹层）—— **滚动阅读器与翻页阅读器共用**。
///
/// 🔑 为什么抽成公共 widget（2026-10-24）：白哥指出「书签加了以后没有读取入口」。
///    两个阅读器都需要「看这本的全部书签 + 点一条跳过去」，
///    各写一份必然漂（本项目「同一件事的口径只能一处权威」）。
///
/// 数据源 `BookMarkerRepository.listForBook`（按位置排序：章 → 章内比例），
/// 点一条把 [onPick] 交给调用方 —— **跳转方式两页不同**：
/// · 滚动页：滚到 `offset = ratio * maxScrollExtent`
/// · 翻页页：先切到那一章，再按比例定位
/// ⇒ 所以这里只负责**列表**，不负责跳。

class BookMarkerSheet extends ConsumerWidget {
  const BookMarkerSheet({super.key, required this.bookId, required this.onPick});

  final String bookId;
  final void Function(BookMarker) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);
    final markers = bookMarkersOf(ref.watch(bookMarkersProvider(bookId)));

    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Clay(
        borderRadius: BorderRadius.circular(18),
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Row(
                children: [
                  Text(
                    '书签',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    markers.isEmpty ? '还没有' : '共 ${markers.length} 处',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
            if (markers.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 26),
                child: Text(
                  '在阅读时点顶栏的书签键，就能把「此刻的位置」记下来 ——\n'
                  '之后长按这个键，可以回到这里选择要去哪一处。',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12.5,
                    height: 1.7,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              )
            else
              ConstrainedBox(
                // ⚠️ 不设上限的话，书签多了这个面板会顶满整屏（把正文全遮住）
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  itemCount: markers.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    thickness: 1,
                    color: Color(t.line.argb32),
                  ),
                  itemBuilder: (context, i) {
                    final m = markers[i];
                    return InkWell(
                      onTap: () => onPick(m),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.excerpt,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: CoFonts.latinSerif,
                                fontSize: 13,
                                height: 1.55,
                                color: Color(t.ink.argb32),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              // 🔑 章序 **+1**（库里 0 起）；比例给整数百分比就够
                              //    （它是**近似**位置，给小数是假精度）
                              '第 ${m.chapterIdx + 1} 章 · ${(m.scrollRatio * 100).round()}%',
                              style: TextStyle(
                                fontFamily: CoFonts.uiSans,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: .5,
                                color: Color(t.ink3.argb32),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
