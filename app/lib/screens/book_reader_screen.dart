// CoEvo · 电子书阅读页（`/books/:id`）
//
// 🔴 **为什么不复用 `ReaderScreen`**（设计文档 §4.1）：
//    那个页面绑**后端的 `articleId`**（正文从 `/api/...` 取），
//    而电子书是**端侧本地内容**（正文在 `book.db` 的 `book_chapter` 里）。
//    两者唯一的共同点是「显示一段长文本」—— 而复用会让
//    「取内容」这一步在两处各有分支（正是漂移的来源）。
//
// # ✅ 划词查词**已补上**（2026-10-05）
//
// 原文（留档，防止又被绕回去）：
// > 本轮**没有**做划词查词 …… `reader_screen.dart` 里的划词逻辑**内联在页面里、
// > 没有抽成组件** ⇒ 要在书内也支持查词只有两条路：复制一份（违反一处权威）/
// > 抽成公共组件（那是一次重构）⇒ 本轮取后者，但**不在这一轮做**。
//
// 白哥真机反馈「书库中的书籍划词不成功」⇒ 那次重构**这一轮做了**：
//   · **查词逻辑** → `services/word_lookup.dart`（`lookupWord`，公开）
//   · **手势 + 防抖** → `widgets/word_lookup_selection.dart`（`WordLookupSelection`）
//   · 信息流页 `reader_screen` 与**本页共用**这两份（判据：一处定义）
//
// 🔑 之所以能从 1284 行里安全搬出那一段，是因为它**早就是顶层函数、
//    不依赖任何 State**（`reader_screen` 的原文注释自己写着这一点）——
//    那是更早一次重构留下的收益。
//
// 🔴 **本页传 `articleId: null`**（有意，不是漏传）：
//    痕迹键是 `lookup_event.article_id`（**int**），而书的 id 是 String uuid ——
//    硬塞一个 int 会**污染痕迹数据**（将来 id 撞上就串）。
//    ⇒ 书库**不记「本文查过的词」底色**，但**查词 / 入生词本照常**。
//    📌 见 `services/word_lookup.dart` 头部「`articleId` 可空」那一节。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/book_provider.dart';
import '../services/tts_service.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/word_lookup_selection.dart';

class BookReaderScreen extends ConsumerStatefulWidget {
  const BookReaderScreen({super.key, required this.bookId});

  final String bookId;

  @override
  ConsumerState<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends ConsumerState<BookReaderScreen> {
  final _scroll = ScrollController();

  ChapterText? _chapter;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openFromSavedProgress();
  }

  @override
  void dispose() {
    // 🔑 离开页面就停朗读 —— 否则用户退出去了声音还在念（听起来像 App 失控）
    ref.read(ttsServiceProvider).stop();
    _scroll.dispose();
    super.dispose();
  }

  /// 首次进入：**从上次读到的章继续**（这是「阅读进度」的意义所在）。
  Future<void> _openFromSavedProgress() async {
    try {
      final db = await ref.read(bookDbProvider.future);
      final rows = await db.query('book_progress',
          columns: ['chapter_idx'],
          where: 'book_id = ?',
          whereArgs: [widget.bookId],
          limit: 1);
      final idx = rows.isEmpty ? 0 : ((rows.first['chapter_idx'] as int?) ?? 0);
      await _loadChapter(idx);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadChapter(int idx) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = await ref.read(bookDbProvider.future);
      final ch = await loadChapter(db, bookId: widget.bookId, idx: idx);
      if (!mounted) return;
      if (ch == null) {
        setState(() {
          _loading = false;
          // 🔴 明确的失败（不是空页面）—— 「静默失败 + 无出口」比报错更糟
          _error = '这一章读不到了。可能是文件损坏，试试重新导入。';
        });
        return;
      }
      setState(() {
        _chapter = ch;
        _loading = false;
      });
      // 翻章后回到顶部（否则「下一章」会停在上一章的滚动位置，看着像没翻）
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _saveProgress(idx);
    } catch (e) {
      if (mounted) setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 记进度（fire-and-forget）。
  ///
  /// 🔴 **不 await** —— 记进度失败**不该阻止用户继续读**。
  ///    判据：**易失败的依赖别放在「渲染」的前置**（同产品原则里的那条）。
  /// ⚠️ 用 `unawaited()` 显式标注「有意不等待」——
  ///    否则将来有人开 `unawaited_futures` lint 时会把它当 bug 修掉（反而改错）。
  void _saveProgress(int idx) {
    unawaited(Future(() async {
      try {
        final db = await ref.read(bookDbProvider.future);
        await saveProgress(db, bookId: widget.bookId, chapterIdx: idx);
        // 🔑 写库成功后才 bump（书库列表的进度要跟着变）
        ref.read(bookDbRevisionProvider.notifier).bump();
      } catch (_) {
        // 静默：进度记不上不影响阅读本身
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final ch = _chapter;

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(t, ch),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _error != null
                      ? _errorState(t)
                      : _body(t, ch!),
            ),
            if (ch != null && _error == null) _footer(t, ch),
          ],
        ),
      ),
    );
  }

  Widget _header(CoEvoTokens t, ChapterText? ch) {
    final accent = Color(t.accent.argb32);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 14, 10),
      child: Row(
        children: [
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 6, 10, 6),
              child: Icon(Icons.arrow_back_ios_new, size: 17, color: accent),
            ),
          ),
          Expanded(
            child: Text(
              // 🔑 顶栏显示**书名**，章节名在正文上方 —— 书名是「我在读哪本」，
              //    翻章时它不该变（变了会让用户以为换了书）。
              ch?.bookTitle ?? '阅读',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(CoEvoTokens t, ChapterText ch) => ListView(
        controller: _scroll,
        // 🔑 用**衬线字体**（`CoFonts.latinSerif` = Literata）读长文 —— 与信息流的
        //    正文同一取向（设计系统里长文本用衬线）。
        padding: const EdgeInsets.fromLTRB(
            CoSpacing.xxl, 0, CoSpacing.xxl, CoSpacing.xxl),
        children: [
          if ((ch.chapterTitle ?? '').isNotEmpty) ...[
            Text(
              ch.chapterTitle!,
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 19,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: CoSpacing.lg),
          ],
          // 🔑 **划词查词**（2026-10-05 补）—— 与信息流页**同一份实现**：
          //    `WordLookupSelection`（手势 + 防抖）+ `lookupWord`（查词逻辑）。
          //    原文这里是**不可选**的 `Text`，注释写着「不用 `SelectionArea` 是
          //    **有意**的（有出口的假象比没出口更困惑）」——那个取舍当年是对的
          //    （宁可没有，也不要假装有），但白哥真机反馈「书库划词不成功」
          //    ⇒ 现在真的做出来了，取舍不再适用。
          WordLookupSelection(
            // 🔴 **传 null 是有意的**（不是漏传）：书不是「文章」——
            //    书的 id 是 String uuid，而痕迹键 `lookup_event.article_id` 是 int，
            //    硬塞一个 int 会**污染痕迹数据**。
            //    ⇒ 书库**不记「本文查过的词」底色**，但查词 / 入生词本**照常**。
            articleId: null,
            child: Text(
              ch.text,
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 17,
                height: 1.75,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
          const SizedBox(height: CoSpacing.xxl),
        ],
      );

  Widget _footer(CoEvoTokens t, ChapterText ch) {
    final accent = Color(t.accent.argb32);
    final hasPrev = ch.idx > 0;
    final hasNext = ch.idx < ch.chapterCount - 1;
    final speaking = ref.watch(ttsServiceProvider).isSpeaking(ch.text);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
      child: Row(
        children: [
          _navButton(t, '上一章', hasPrev, () => _loadChapter(ch.idx - 1)),
          const SizedBox(width: CoSpacing.md),
          // 整章朗读 —— 🔴 **免费**（设计文档 §六 #2：订阅已改卖「云端同步」，
          // 朗读与词卡朗读是同一个 `flutter_tts` 能力，收费会显得抠）
          //
          // 🔴 2026-10-05 修：原来调 `togglePlay(ch.text)`（**短文本**用）——
          //    而整章正文远超平台单次朗读上限（Android
          //    `getMaxSpeechInputLength()` ≈ 4000 字符）⇒ 静默无声（真机反馈）。
          //    ⇒ 改调 `speakLong`：**分段 + 依次播放**（分段逻辑见
          //    `services/speech_chunks.dart`，零 import 纯 Dart、已断言）。
          //
          // 🔑 停止用 `stop()` 而不是 `togglePlay` —— 长文本的语义是「整章读完」，
          //    不是「再点一次切歌」；点击时按 `isSpeaking(整章原文)` 判断当前状态。
          InkWell(
            onTap: () {
              final tts = ref.read(ttsServiceProvider);
              if (tts.isSpeaking(ch.text)) {
                tts.stop();
              } else {
                tts.speakLong(ch.text);
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(
                speaking ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                size: 22,
                color: accent,
              ),
            ),
          ),
          const SizedBox(width: CoSpacing.md),
          _navButton(t, '下一章', hasNext, () => _loadChapter(ch.idx + 1)),
        ],
      ),
    );
  }

  Widget _navButton(CoEvoTokens t, String label, bool enabled, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              // 🔴 到头时**明显变灰**（不是隐藏）—— 「这里没有下一章」
              //    与「按钮不见了」是两种信息，后者会让用户找一圈。
              color: enabled ? Color(t.accent.argb32) : Color(t.ink3.argb32),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorState(CoEvoTokens t) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CoSpacing.xxl),
          child: Text(
            _error ?? '出错了',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              height: 1.6,
              color: Color(t.ink2.argb32),
            ),
          ),
        ),
      );
}
