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
import 'package:uuid/uuid.dart';

import '../providers/book_marker_provider.dart';
import '../providers/book_provider.dart';
import '../providers/highlight_provider.dart';
import '../providers/reading_settings_provider.dart';
import '../services/ebook/book_marker.dart';
import '../services/ebook/book_marker_repository.dart';
import '../services/highlight_repository.dart';
import '../services/highlight_span.dart';
import '../services/tts_service.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/reading_settings_panel.dart';
import '../widgets/book_marker_sheet.dart';
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

  /// 当前章节下标 —— 🆕 划线的「章内位置」需要它（`highlight.chapter_idx`）。
  ///
  /// ⚠️ 让它做**独立字段**而不是从 `_chapter` 上取：`_loadChapter(idx)` 的入参
  ///    才是权威值（`ChapterText` 自身不保证带下标）。
  int _chapterIdx = 0;
  bool _loading = true;
  String? _error;

  /// 🆕 当前**屏幕位置**命中的书签 id（`null` = 此处没有书签）—— 顶栏图标键的状态。
  ///
  /// # 🔑 为什么是「当前位置」而不是「本章有没有书签」
  ///
  /// 书签标的是**一个位置**（「此刻屏幕上的位置」），不是「一整章」——
  /// 所以同一个键连点两次是「打上 / 取消」（见设计稿 §1）。
  /// ⇒ 图标必须反映**当前位置**；若反映「本章有书签」，用户在章中间打了一条，
  ///   翻到下一屏图标仍是「已标记」⇒ 再点一次会**取消掉另一处**的书签。
  ///
  /// ⚠️ 代价：它要在**每次滚动结束**后查一次库（一次 `findAt`）——
  ///    那是可接受的（单条 SELECT）；真正的坑是**频繁**查，所以只在
  ///    `ScrollEndNotification` 时更新（见 `_body`）。
  String? _markerHere;

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
        _chapterIdx = idx;
        _loading = false;
      });
      // 翻章后回到顶部（否则「下一章」会停在上一章的滚动位置，看着像没翻）
      if (_scroll.hasClients) _scroll.jumpTo(0);
      // 🆕 书签图标状态跟着重置/重查 —— 章变了，`_chapterIdx` 也变了，
      //    上一条命中的 id 已经**不再代表当前位置**（留着会让图标显示错）。
      //    ⚠️ 不等它（它是纯图标状态，慢一点没关系）；失败静默（见 `_refreshMarkerHere`）。
      unawaited(_refreshMarkerHere());
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
                      // 🆕 书签键的「当前位置已标记」状态要在**滚动结束**时更新。
                      //
                      // 🔑 用 `ScrollEndNotification`（**框架给的准确信号**），
                      //    不是「等 300ms 猜用户停手了」那种防抖 ——
                      //    后者是拿不到的信号时的无奈之举（划词那边已删掉过一次）。
                      // ⚠️ 直接监听 `_scroll.position.isScrollingNotifier` 也行，
                      //    但那要求 position 已 attach（`initState` 时还没有）
                      //    ⇒ 通知冒泡更省心。
                      : NotificationListener<ScrollEndNotification>(
                          onNotification: (_) {
                            _refreshMarkerHere();
                            return false; // 不拦截，继续冒泡
                          },
                          child: _body(t, ch!),
                        ),
            ),
            if (ch != null && _error == null) _footer(t, ch),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 🆕 书签（2026-10-07 · 设计稿 `visual-bookmark-2026-10-07.html`）
  // ─────────────────────────────────────────────────────────────────────

  /// 当前滚动位置占**本章**的比例（0~1）—— 与 `book_progress` **同一套**表示。
  ///
  /// 🔴 **必须 `hasClients` + 防除零**：`maxScrollExtent == 0` 发生在
  ///    「本章内容不足一屏」时（短章节 / 章尾）—— 那时 `offset / 0` 是 `NaN`/`Infinity`，
  ///    而坏值会被写进库（`scroll_ratio` 是 REAL，SQLite **不拒绝 NaN**）⇒
  ///    之后「找当前位置的书签」永远匹配不上，且**不报错**。
  double _currentRatio() {
    if (!_scroll.hasClients) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.offset / max).clamp(0.0, 1.0);
  }

  /// 滚动结束后刷新「当前位置有没有书签」。
  ///
  /// ⚠️ 失败**静默**（不上抛、不提示）：它只是**图标状态**，
  ///    读不到不该打扰用户 —— 而且键**照常可点**（点了会写库，写失败**有**提示）。
  ///    📌 判据：**读失败不阻塞主流程**，写失败必须说。
  Future<void> _refreshMarkerHere() async {
    try {
      final db = await ref.read(bookDbProvider.future);
      final hit = await BookMarkerRepository(db).findAt(
        bookId: widget.bookId,
        chapterIdx: _chapterIdx,
        scrollRatio: _currentRatio(),
      );
      if (!mounted) return;
      // 🔑 去重：值没变就不 `setState`（滚动结束时本来就常是同一个结果）
      if (_markerHere == hit?.id) return;
      setState(() => _markerHere = hit?.id);
    } catch (_) {
      // 有意静默（见上）
    }
  }

  /// 点一下 = **打 / 取消**（同一个键，同一个判断）。
  ///
  /// 🔑 判断只有一处：[BookMarkerRepository.findAt] —— 图标状态与写入**共用**它
  ///    （若各判一次，「图标显示未标记、点了却取消掉一条」这类不一致迟早出现）。
  Future<void> _toggleBookmark() async {
    try {
      final db = await ref.read(bookDbProvider.future);
      final repo = BookMarkerRepository(db);
      final ratio = _currentRatio();

      final hit = await repo.findAt(
        bookId: widget.bookId,
        chapterIdx: _chapterIdx,
        scrollRatio: ratio,
      );

      if (hit != null) {
        await repo.remove(hit.id);
        if (!mounted) return;
        setState(() => _markerHere = null);
        _snack('已取消书签');
      } else {
        await repo.add(
          id: const Uuid().v4(),
          bookId: widget.bookId,
          chapterIdx: _chapterIdx,
          scrollRatio: ratio,
          // 摘录是**近似值**（比例估算 —— 见 `book_marker.dart` 的如实标注）
          excerpt: estimateBookmarkExcerpt(
            chapterText: _chapter?.text ?? '',
            scrollRatio: ratio,
          ),
          createdAt: DateTime.now(),
        );
        if (!mounted) return;
        _snack('已加书签 · 第 ${_chapterIdx + 1} 章');
        // 🔑 写库成功**之后**才刷新状态与 bump（顺序反了读端会拿到旧值）
        await _refreshMarkerHere();
      }

      // 🔑 写库成功之后才 bump（顺序不可颠倒 —— 同全项目一致的做法）
      ref.read(bookDbRevisionProvider.notifier).bump();
    } catch (e, st) {
      debugPrint('[book_marker] 书签写入失败：$e\n$st');
      if (!mounted) return;
      _snack('书签没存上，请再试一次');
    }
  }

  /// 长按 = 看这本书的**全部**书签（按位置排序）。
  ///
  /// 🔑 列表放在**书内**（这本的），不是全局页 —— 与「记忆列表」不同：
  ///    书签是「回这本书的某处」，脱离书没有意义。
  ///    （对照：划线做成全局清单，因为它要「跨来源看自己记过什么」。）
  void _showMarkers() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => BookMarkerSheet(
        bookId: widget.bookId,
        // 点一条 ⇒ 滚到那一处（同章内滚动；跨章要切章 ⇒ 见下方说明）
        onPick: (m) {
          Navigator.of(ctx).pop();
          _jumpToMarker(m);
        },
      ),
    );
  }

  /// 跳到某条书签的位置。
  ///
  /// ⚠️ **跨章要切换章节**（`_loadChapter` 之后等首帧再滚）；
  ///    同章内直接滚。
  ///    🔴 `scroll_ratio` 是**比例**，滚回去时按**当前**的 `maxScrollExtent` 换算 ——
  ///    这正是「不存绝对像素」那条判据的收益（换字号/换设备后仍然对）。
  Future<void> _jumpToMarker(BookMarker m) async {
    if (m.chapterIdx != _chapterIdx) {
      await _loadChapter(m.chapterIdx);
      if (!mounted) return;
      // 等这一帧的布局完成（`maxScrollExtent` 才有值）
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _scroll.jumpTo((m.scrollRatio * max).clamp(0.0, max));
    // 跳完刷新图标状态（跳到的正是书签处 ⇒ 应显示「已标记」）
    await _refreshMarkerHere();
  }

  /// 轻提示（全项目同一款式）。
  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  Widget _header(CoEvoTokens t, ChapterText? ch) {
    final accent = Color(t.accent.argb32);
    // 🔑 与 `accent` 一样是**方法级局部变量**（不是写在 `children: [...]` 里）——
    //    `children` 只能放 Widget 表达式，放语句会**语法错**（本轮踩过）。
    final marked = _markerHere != null;
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
          // 🆕 2026-10-07 书签键（在设置键**左边** —— 顶部图标靠右是本页既有取位）。
          //
          // 交互（设计稿 §1）：**点 = 打/取消 · 长按 = 看全部**。
          // 🔴 已标记态**不只是变色** —— 形状（空 `bookmark_border` → 实 `bookmark`）
          //    与重量（无底 → 有底）**都变**。依据是本项目那条
          //    「**形状区分优于参数**」：只换颜色在三个主题档下的可辨性不一致。
          //
          // ⚠️ 它反映的是**当前屏幕位置**有没有书签（不是「本章有没有」）——
          //    见 `_markerHere` 的字段说明。
          InkWell(
            onTap: _toggleBookmark,
            onLongPress: _showMarkers,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: marked
                  ? BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: Icon(
                marked ? Icons.bookmark : Icons.bookmark_border,
                size: 20,
                color: accent,
              ),
            ),
          ),
          // 🆕 2026-10-06：阅读设置键（白哥：「书库没有同步设置面板」）
          //
          // 🔑 与信息流阅读器**同一个面板、同一套状态**（`readingSettingsProvider`
          //    + 全局 `themeProvider` / `ttsServiceProvider`）——
          //    所以「在文章里调过的字号，进书库依然生效」，反之亦然。
          // ⚠️ 传 `showTrace: false`：书库**有意不记痕迹**
          //    （`articleId: null`），显示该开关 = 拨了没反应（静默失败）。
          InkWell(
            onTap: () => showReadingSettingsPanel(context, showTrace: false),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Icon(Icons.format_size, size: 20, color: accent),
            ),
          ),
        ],
      ),
    );
  }

  /// 正文字号 —— 来自用户设置（与信息流阅读器**同一份** provider）。
  ///
  /// 🆕 2026-10-06：此前是**写死的 17**（书库没有设置入口）。
  ///    白哥指出「书库没有同步设置面板」⇒ 现在两页共用同一个 `readingSettingsProvider`：
  ///    **在文章里调过的字号，进书库依然生效**，反之亦然。
  ///
  /// ⚠️ 用 `ref.watch`（不是 `read`）：用户拖字号时本页要**立即重排**。
  ///    在 build 路径上调用（`_body` / `_header` 均由 `build` 调）⇒ 合法。
  double get _bodyFontSize =>
      ref.watch(readingSettingsProvider).fontSize.toDouble();

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
                // 🔑 章节标题字号 = 正文字号 + 2 —— **跟随设置**（不是写死 19）。
                //    写死的话，用户把正文调到 24 时标题反而显得不突出
                //    （甚至层级反转 —— 而「字号层级不可反转」是本项目的既定不变量）。
                fontSize: _bodyFontSize + 2,
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
            // 🆕 2026-10-06：**单击正文唤出阅读设置**（与信息流阅读器同款交互）。
            //    ⚠️ 面板传 `showTrace: false`（书库不记痕迹，见上面 articleId 的说明）。
            onTap: () => showReadingSettingsPanel(context, showTrace: false),
            // 🆕 2026-10-07 划线来源 —— 传了它，菜单里才出现「划线」项。
            //    🔑 `plainText` 必须是**这里正在渲染的那份文本**（`ch.text`），
            //    否则 `locateSelection` 反查出来的位置会偏（框架不给偏移，只能反查）。
            highlightSource: HighlightSource(
              type: HighlightSourceType.book,
              sourceId: widget.bookId,
              chapterIdx: _chapterIdx,
              plainText: ch.text,
              // 🆕 2026-10-08：译文浮层顶栏的「来自 XXX」。
              //    🔑 用**书名**而不是章节名 —— 与顶栏同一口径
              //    （顶栏也是书名，见上面「翻章时它不该变」的说明）。
              title: ch.bookTitle,
            ),
            child: Text.rich(
              TextSpan(children: _bodySpans(t, ch)),
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                // 🆕 字号来自用户设置（已钳 15–24），不再是写死的 17
                fontSize: _bodyFontSize,
                height: 1.75,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
          const SizedBox(height: CoSpacing.xxl),
        ],
      );

  /// 正文的 span 列表 —— 划过的部分加 **下划线**。
  ///
  /// # 🔑 为什么划线是「下划线」，而痕迹是「底色」
  ///
  /// 两者都是「高亮」，同形状会**互相干扰**（用户分不清「我查过的词」和
  /// 「我划过的句子」）。⇒ 按项目既有判据「**形状区分优于参数**」：
  ///
  /// | | 形态 | 心智 |
  /// |---|---|---|
  /// | 痕迹（查过的词）| **底色浸染**（面）| 系统记的 |
  /// | 划线 | **下划线**（线）| **我**划的 |
  ///
  /// ⚠️ **本页不画痕迹**（`articleId: null`，见文件头）—— 所以这里与痕迹
  ///    其实不会同框。但下划线仍是正确形态：它跨的是**一段文字**而不是
  ///    单个词，面状底色盖住一整段会很脏。
  ///
  /// # ⚠️ 本机验不了的部分（如实标注）
  /// 下划线的**粗细 / 颜色 / 与文字的距离**只能**真机看** ——
  /// Flutter 的 `TextDecoration` 没有 CSS 的 `text-underline-offset`，
  /// 想调间距得靠 `height`，那是全局的。**先取默认，真机目视后再定**。
  /// 本机可验的是**切分**（`buildTextSegments` 的 129 项断言）。
  List<InlineSpan> _bodySpans(CoEvoTokens t, ChapterText ch) {
    // 🔑 用 `ch.idx`（这份文本自己的章号）而不是 `_chapterIdx` ——
    //    后者是「页面状态」，前者是「这段文本的身份」；两者不一致时
    //    （加载中途）要相信文本自己。
    final async = ref.watch(highlightsForSourceProvider(HighlightSourceKey(
      type: HighlightSourceType.book,
      sourceId: widget.bookId,
      chapterIdx: ch.idx,
    )));

    // 🔑 失败 / 加载中 ⇒ 空列表 ⇒ 正文照常渲染（只是没有下划线）。
    //    这就是「不把易失败的外部依赖放在内容渲染的前置条件上」。
    final segments = buildTextSegments(
      text: ch.text,
      ranges: highlightRangesOf(async),
    );

    return [
      for (final s in segments)
        if (s.isHighlighted)
          TextSpan(
            text: s.text,
            style: TextStyle(
              decoration: TextDecoration.underline,
              // 细线用 `accentBright`（项目规定：**细线与描边用亮调**，
              // `accent` 是实心填充色）
              decorationColor: Color(t.accentBright.argb32),
              decorationThickness: 1.2,
            ),
          )
        else
          TextSpan(text: s.text),
    ];
  }

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

/// **书内书签列表**（底部面板）—— 从顶栏书签键**长按**进入。
///
/// # 🔑 为什么是「书内的面板」而不是「全局页」
///
/// 书签回答的是「**回这本书的某处**」—— 脱离书没有意义。
/// ⚠️ 对照：「记忆列表」（划线）做成了**全局顶层页**，因为它要回答
///    「我记过什么」（跨文章 + 跨书）—— **两个功能的用途不同，形态就不同**。
///    📌 判据：**形态跟着用途走**，别因为「都是列表」就统一。
///
/// # 为什么每条必须有**摘录**
///
/// 只写「第 3 章 42%」用户认不出那是哪一段 ⇒ 等于白存。
/// ⚠️ 摘录是**近似值**（比例估算 —— 见 `book_marker.dart`），可能偏几十字；
///    但它的用途是「认出来」而不是「定位」⇒ 可接受。
