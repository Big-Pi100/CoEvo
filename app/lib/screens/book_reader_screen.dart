// CoEvo · 电子书阅读页（`/books/:id`）
//
// 🔴 **为什么不复用 `ReaderScreen`**（设计文档 §4.1）：
//    那个页面绑**后端的 `articleId`**（正文从 `/api/...` 取），
//    而电子书是**端侧本地内容**（正文在 `book.db` 的 `book_chapter` 里）。
//    两者唯一的共同点是「显示一段长文本」—— 而复用会让
//    「取内容」这一步在两处各有分支（正是漂移的来源）。
//
// # 🔴 本轮**没有**做划词查词（如实交代，不是漏了）
//
// `reader_screen.dart`（1284 行）里的划词逻辑（`SelectionArea` + 防抖 +
// 自绘 `contextMenuBuilder` + `WordLookupResult`）**内联在页面里、没有抽成组件**。
// 要在书内也支持查词，只有两条路：
//   · 复制一份 ⇒ 违反「同一件事只能有一处权威」（将来改查词逻辑要改两处）
//   · 把它抽成公共组件 ⇒ **那是一次重构**（涉及 1284 行里最精细的一段：
//     防抖、菜单自绘、手势与滚动的相互影响），应当**单独做 + 单独验证**
// ⇒ 本轮取后者，但**不在这一轮做**。本页先给「阅读 + 翻章 + 进度 + 朗读」。
// ⏳ 下一轮：把 `reader_screen` 的划词抽成 `WordLookupSelection`，
//    两页共用（那时也顺手统一两处的菜单行为）。
//
// ⚠️ 在划词补上之前，本页**不宣称**支持查词 —— 有断言守「页面里不得出现
//    `lookup` 字样」（防「宣称了却没实现」）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/book_provider.dart';
import '../services/tts_service.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

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
          // ⚠️ 一期用 `Text`（不可选）—— 划词查词留到下一轮（见文件头）。
          //    不用 `SelectionArea` 是**有意**的：那会让用户以为能查词，
          //    选了却没有菜单 ⇒ 「有出口的假象」比「没有出口」更让人困惑。
          Text(
            ch.text,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 17,
              height: 1.75,
              color: Color(t.ink.argb32),
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
          InkWell(
            onTap: () => ref.read(ttsServiceProvider).togglePlay(ch.text),
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
