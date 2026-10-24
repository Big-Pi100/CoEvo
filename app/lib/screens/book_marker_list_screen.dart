import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/book_marker_provider.dart';
import '../services/ebook/book_marker.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 本书的书签**列表页**（独立页面，不是弹窗）。
///
/// # 🔑 为什么是独立页面（2026-10-24 白哥定的）
///
/// 原来做成底部弹窗（`BookMarkerSheet`）。白哥的原话：
/// 「书签列表不应该是一个弹窗，而是一个**独立页面**，因为内容有可能会很多，
///  一个弹窗无法承载」。
///
/// 弹窗的上限是「半屏」（`maxHeight: 0.5 * screen`）—— 一本书读到一半
/// 十几二十条书签太正常了，半屏只够看五六条，而且**列表本身还在滚**，
/// 和「下拉关闭」的手势会抢。独立页没有这些限制。
///
/// # 返回约定
///
/// 点一条 ⇒ `Navigator.pop(context, marker)` 把选中的书签**带回去**，
/// 由调用方决定怎么跳（滚动页滚、翻页页切章 + 定位）。
/// 🔑 页面只负责「选」，不负责「跳」 —— 跳转方式两个阅读器不同，
///    写在这里会把两套坐标逻辑塞进同一个页面。
class BookMarkerListScreen extends ConsumerWidget {
  const BookMarkerListScreen({
    super.key,
    required this.bookId,
    this.bookTitle,
  });

  final String bookId;

  /// 顶栏显示的来源（书名）。可空 —— 拿不到就只写「书签」。
  final String? bookTitle;

  static Future<BookMarker?> push(
    BuildContext context, {
    required String bookId,
    String? bookTitle,
  }) {
    return Navigator.of(context).push<BookMarker>(
      MaterialPageRoute(
        builder: (_) => BookMarkerListScreen(
          bookId: bookId,
          bookTitle: bookTitle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);
    final markers = bookMarkersOf(ref.watch(bookMarkersProvider(bookId)));

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 顶栏：与阅读页同一套取位（‹ + 标题 + 计数）──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    borderRadius: BorderRadius.circular(22),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 8),
                      child: Text(
                        '‹',
                        style: TextStyle(
                          fontSize: 19,
                          height: 1,
                          color: Color(t.ink3.argb32),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      bookTitle == null ? '书签' : '书签 · $bookTitle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(t.ink2.argb32),
                      ),
                    ),
                  ),
                  Text(
                    markers.isEmpty ? '还没有' : '${markers.length} 处',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: markers.isEmpty
                  ? _empty(t)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      itemCount: markers.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 1,
                        color: Color(t.line.argb32),
                      ),
                      itemBuilder: (context, i) {
                        final m = markers[i];
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(m),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 14, 4, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.excerpt,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: CoFonts.latinSerif,
                                    fontSize: 14,
                                    height: 1.55,
                                    color: Color(t.ink.argb32),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  // 🔑 章序 +1（库里 0 起）；比例给整数百分比
                                  //    —— 它是**近似**位置，给小数是假精度
                                  '第 ${m.chapterIdx + 1} 章 · '
                                  '${(m.scrollRatio * 100).round()}%',
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

  Widget _empty(CoEvoTokens t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Text(
          '在正文上**向下拖动**一下，就能把此刻的位置记下来。\n'
          '有书签的地方，再拖一次就是取消。',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.8,
            color: Color(t.ink3.argb32),
          ),
        ),
      );
}
