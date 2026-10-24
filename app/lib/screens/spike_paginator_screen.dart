import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';

import 'package:uuid/uuid.dart';

import '../providers/book_provider.dart';
import '../services/ebook/book_marker.dart';
import '../services/ebook/book_marker_repository.dart';
import '../services/highlight_enqueue.dart';
import '../services/highlight_repository.dart';
import '../services/highlight_span.dart';
import '../services/picked_text.dart';
import '../providers/reading_settings_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/user_db_provider.dart';
import '../services/tts_service.dart';
import '../services/word_lookup.dart';
import '../widgets/translation_sheet.dart';
import 'book_marker_list_screen.dart';
import '../widgets/foliate_reader_view.dart';
import '../theme/coevo_tokens.dart';
import '../widgets/reading_settings_panel.dart';
import '../widgets/selection_menu.dart';

/// 🔬 翻页阅读器 **spike 页面**（2026-10-22）。
///
/// # 目的
/// 在真机上验证三件事，**验完再决定要不要全量替换现有阅读器**：
/// 1. 翻页手感（foliate 的 CSS 多栏分页在 iOS WebView 里顺不顺）
/// 2. 主题注入（三档颜色能不能干净切换，不闪白）
/// 3. 选词回传（长按选中 → Flutter 能不能拿到文本）
///
/// # 为什么是独立页面
/// 主流程一行没动 —— 它就是「先有可看的目标」：手感不行就撤，损失控制在这个文件里。
///
/// ⚠️ 内置文本是**手写的英文长文**（与真书同样是 `<p>` 段落结构），
///    目的是能把页数撑到 6 页以上，好看清分页是否连续。
class SpikePaginatorScreen extends ConsumerStatefulWidget {
  const SpikePaginatorScreen({super.key});

  @override
  ConsumerState<SpikePaginatorScreen> createState() =>
      _SpikePaginatorScreenState();
}

class _SpikePaginatorScreenState
    extends ConsumerState<SpikePaginatorScreen> {
  final _c = FoliateReaderController();
  int _themeIdx = 0;
  String? _error;

  // ── 真书（2026-10-23：从演示文本改为读 `book.db` 的第一本书）──
  String? _bookTitle;
  String? _chapterTitle;
  int _chapterIdx = 0;
  int _chapterCount = 0;
  String? _bookId;
  bool _loading = true;

  /// 最近一次写进库的字符偏移（显示在底部，用来肉眼确认链路通了）
  int? _lastSaved;

  /// 本章**原文**（划线定位用：`locateSelection(plainText: ..., picked: ...)`）。
  String? _chapterPlainText;

  /// 当前正文字号 —— 来自 `readingSettingsProvider`（默认 17，范围 15–24）。
  /// 改它之后必须把内容**重排**（`setTheme` 内部会重建分页器）。
  double _fontSize = 17;


  /// 点过菜单项后临时收起（否则菜单会一直挂在原文上）。
  /// 下次选区变化（`selection` 变新对象）时重置。
  bool _hideSelectionMenu = false;

  /// 顶栏/底栏是否显示 —— **默认隐藏**（白哥：平时看不见，单击正文才弹出）。
  bool _bars = false;

  /// 当前位置是否已在书签处。
  ///
  /// 🔑 判据只有一处：`BookMarkerRepository.findAt(...)`。
  ///    **UI 的图标状态**与**写入前的「在不在」询问**共用同一个结果 ——
  ///    各判一次迟早会漂（正式页 `book_marker_repository` 类文档里记了这条）。
  BookMarker? _markerHere;

  /// 🔴 **三档色值直接取 `coevo_tokens.dart` 的真实值**（2026-10-23 白哥指出
  /// 「跟现在运行中的完全不一样」—— 主因就是我自己猜了色值）：
  ///
  /// | 档 | `read`（正文底）| `ink`（文字）| `accent`（链接）|
  /// |---|---|---|---|
  /// | 墨 | `#FAF8F4` | `#24211C` | `#B4432C` |
  /// | 格 | `#FFFFFF` | `#0A0A0A` | `#B4432C` |
  /// | 夜 | `#14161C` | `#EDEBE6` | `#DB7E6B`（深底版亮朱砂）|
  ///
  /// ⚠️ 原来写的是 `#F5F0E8 / #3A332C` 之类 —— **全是我编的**，底色和字色都不对，
  ///    所以观感「完全是另一个 App」。
  static const _themes = <({String name, String bg, String fg, String accent})>[
    (name: '墨', bg: '#FAF8F4', fg: '#24211C', accent: '#B4432C'),
    (name: '格', bg: '#FFFFFF', fg: '#0A0A0A', accent: '#B4432C'),
    (name: '夜', bg: '#14161C', fg: '#EDEBE6', accent: '#DB7E6B'),
  ];

  @override
  void initState() {
    super.initState();
    _c.lastError.addListener(_onErr);
    _c.selectedText.addListener(_onSel);
    _c.tapTick.addListener(_onTap);
    // 🆕 下拉 = 打/取消书签（白哥定：无书签则加、有书签则删）
    _c.pullDownTick.addListener(_onPullDown);
    _c.position.addListener(_onPosition);
    _loadRealBook();
  }

  /// 读 `book.db` 里**第一本书的第一章** —— 换成真书才看得出真实排版/性能。
  ///
  /// ⚠️ 演示文本留着不删：书架是空的时候还得有东西可翻（否则这个验证页直接白屏）。
  Future<void> _loadRealBook() async {
    try {
      final db = await ref.read(bookDbProvider.future);
      final rows = await db.query('book',
          columns: ['id', 'title', 'chapter_count'],
          orderBy: 'added_at DESC',
          limit: 1);
      if (rows.isEmpty) {
        // 书架为空 ⇒ 退回演示文本（并在底部提示）
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '书架为空，正在用演示文本';
          });
          await _c.setChapters(_demoChapters);
        }
        return;
      }
      if (!mounted) return;
      await _openBook(
        id: rows.first['id'] as String,
        title: rows.first['title'] as String?,
        chapterCount: (rows.first['chapter_count'] as int?) ?? 0,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读真书失败：$e';
        });
      }
      await _c.setChapters(_demoChapters);
    }
  }

  /// 打开指定书（换书时把章节索引归零）。
  Future<void> _openBook({
    required String id,
    required String? title,
    required int chapterCount,
  }) async {
    setState(() {
      _bookId = id;
      _bookTitle = title;
      _chapterCount = chapterCount;
      _chapterIdx = 0;
      _chapterTitle = null;
      _loading = false;
      _error = null;
    });
    await _loadWholeBook();
  }

  /// 选书 —— 🔑 必须能选：书架里可能同时有 **EPUB**（结构规范）和 **TXT**（结构松散），
  /// 验证翻页器要用 EPUB；否则会误把「TXT 切章不准」当成翻页器的 bug。
  Future<void> _openBookPicker() async {
    final db = await ref.read(bookDbProvider.future);
    final rows = await db.query('book',
        columns: ['id', 'title', 'chapter_count'],
        orderBy: 'added_at DESC');
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _hex(_themes[_themeIdx].bg),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final id = rows[i]['id'] as String;
            final title = (rows[i]['title'] as String?) ?? '（无标题）';
            final n = (rows[i]['chapter_count'] as int?) ?? 0;
            final current = id == _bookId;
            return ListTile(
              dense: true,
              selected: current,
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  color: _hex(_themes[_themeIdx].fg),
                ),
              ),
              subtitle: Text('$n 章',
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.of(ctx).pop();
                _openBook(id: id, title: rows[i]['title'] as String?, chapterCount: n);
              },
            );
          },
        ),
      ),
    );
  }

  /// 当前书的所有章节原文（索引 = 章节 idx）。
  /// 划线定位要用它（`locateSelection` 在**明文**里找选中片段，不是 HTML）。
  List<ChapterText> _chapters = const [];

  /// 加载**整本书**并一次性交给分页器。
  ///
  /// # 🔴 为什么不再「一次一章」（2026-10-23 白哥报「章末翻不动、还刷红字」）
  ///
  /// foliate 把 `sections` 当**定长数组**：翻到末页再往后它就取 `sections[N+1]`。
  /// 只传一章 ⇒ `sections[1]` 是 `undefined` ⇒
  /// `Promise: undefined is not an object (evaluating 'this.sections[index].load')`
  /// ⇒ 卡住 + 满屏报错。
  ///
  /// ⇒ 必须**一次传全**；`sections[i].load` 由 foliate **懒调用**（翻到才建 iframe），
  ///   所以预生成 N 个 HTML 字符串不会一次性渲染，只是内存里存着。
  Future<void> _loadWholeBook({int startAt = 0}) async {
    final id = _bookId;
    if (id == null) return;
    final db = await ref.read(bookDbProvider.future);
    final all = await loadAllChapters(db, bookId: id);
    if (all.isEmpty || !mounted) return;

    // 🔑 打开书时**先按用户当前的设置**（底色 + 字号）初始化，
    //    否则「上次调到 20 号字，这次打开还是 17」。
    final idx = switch (ref.read(themeProvider).theme) {
      ReadingTheme.ink => 0,
      ReadingTheme.grid => 1,
      ReadingTheme.night => 2,
    };
    setState(() {
      _chapters = all;
      _chapterIdx = startAt.clamp(0, all.length - 1);
      _chapterTitle = all[_chapterIdx].chapterTitle;
      _chapterPlainText = all[_chapterIdx].text;
      _themeIdx = idx;
      _fontSize = ref.read(readingSettingsProvider).fontSize.toDouble();
    });
    await _c.setChapters(
      [for (final ch in all) _textToHtml(ch.text, ch.chapterTitle)],
      startAt: _chapterIdx,
    );
    // 内容设好之后再套主题/字号（`setTheme` 内部会重建分页器，但 `state.chapters` 已存住）
    final th = _themes[_themeIdx];
    await _c.setTheme(
      background: th.bg,
      foreground: th.fg,
      accent: th.accent,
      fontSize: _fontSize,
      margin: 24,
    );
  }

  /// 跳到指定章节（目录点击用）。
  ///
  /// ⚠️ 现在**不需要**重新灌内容 —— 所有章节都已经在分页器里，
  ///    只要 `goTo({index})` 就行（这也是「章节已经全传」带来的好处）。
  Future<void> _goToChapter(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    setState(() {
      _chapterIdx = idx;
      _chapterTitle = _chapters[idx].chapterTitle;
      _chapterPlainText = _chapters[idx].text;
    });
    await _c.goToChapter(idx);
  }

  /// 纯文本 → HTML。
  ///
  /// 🔴 **这是 `char_offset` 口径的唯一来源**：偏移按这里生成的文本算
  /// （段落之间**不含分隔符**）。将来换成 `char_offset` 精确计算时，
  /// 反查必须用**同一份 HTML** —— 否则偏移会系统性错位**且不会报错**。
  static String _textToHtml(String text, String? chapterTitle) {
    final buf = StringBuffer();
    // ⚠️ 标题不进正文（`char_offset` 只算正文段落）——
    //    所以标题单独用 `<h2 class="ch-title">`，偏移计算时按 class 跳过。
    if (chapterTitle != null && chapterTitle.trim().isNotEmpty) {
      buf.write('<h2 class="ch-title">${_escape(chapterTitle.trim())}</h2>');
    }
    final paras = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    for (final p in paras) {
      buf.write('<p>${_escape(p)}</p>');
    }
    return buf.toString();
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  void _onErr() {
    final e = _c.lastError.value;
    if (e != null && mounted) setState(() => _error = e);
  }

  /// 正文竖直下拉 —— 打/取消书签。
  ///
  /// 白哥定：「无书签的下拉加书签，有书签的下拉删除书签」。
  /// 判据完全交给 `_toggleMarker`（它用 `_markerHere` 决定加还是删），
  /// 这里**不重复判断**。
  void _onPullDown() {
    if (!mounted) return;
    _toggleMarker();
  }

  void _onSel() {
    if (!mounted) return;
    // 选区一变（新对象）⇒ 菜单重新出现
    setState(() => _hideSelectionMenu = false);
  }

  /// 单击正文（由 WebView 的 tap 事件转发过来）。
  ///
  /// # 🔴 2026-10-24 白哥定的交互
  ///
  /// | 当前状态 | 单击正文后 |
  /// |---|---|
  /// | 顶栏隐藏 | **顶栏出现 + 阅读设置面板升起** |
  /// | 顶栏已显示 | **顶栏收起**（不弹面板） |
  ///
  /// ⚠️ 面板本身是模态（`showModalBottomSheet`）⇒ 弹着的时候点不到正文，
  ///    所以「再点一次收起」只在面板关掉之后才会发生。
  ///
  /// ⚠️ **页码条不参与**这个切换（白哥：它是阅读界面的一部分，只展示进度）。
  void _onTap() {
    if (!mounted) return;
    // 🔴🔴 2026-10-24 白哥（第四次强调）：
    //    「顶部栏和设置面板在**一层**，单击正文的时候**同时从上下弹出**，
    //     收起的时候**同时收起**」
    //
    // ⇒ 它们**不是一个层里的两个东西**，而是**同一个整体的上下两半**：
    //   `_bars` 一个状态位同时决定「顶栏在不在」和「面板升没升起」。
    //   ⇒ **没有**「顶栏在、面板不在」的中间态。
    final opening = !_bars;
    setState(() {
      _bars = opening;
      _hideSelectionMenu = true;
    });
    // 顶栏刚出现 ⇒ 立刻问一次「当前位置在不在书签处」（否则图标永远是空心）
    if (opening) _refreshMarkerHere();
  }

  /// 当前页起点在**本章**里的比例（0~1）—— 与 `book_marker.scroll_ratio` 同一口径。
  ///
  /// 🔑 书签表用的坐标是「**章内比例**」，而翻页器给的是「章内字符偏移」
  ///    ⇒ 用 `charOffset / totalChars` 换算。
  ///    ⚠️ 分母必须是 `totalChars`（本章纯文本长度），不是全书长度。
  double get _ratioHere {
    final p = _c.position.value;
    if (p.totalChars <= 0) return 0;
    return (p.charOffset / p.totalChars).clamp(0.0, 1.0);
  }

  /// 翻页后刷新「当前位置是否在书签处」（供顶栏图标的实心/空心）。
  ///
  /// ⚠️ 每次 relocate 都会查一次库 —— SQLite 本地查询 ~1ms，可以接受。
  ///    但它**只在顶栏可见时**才有意义 ⇒ 不可见就跳过，省掉无谓查询。
  Future<void> _refreshMarkerHere() async {
    final id = _bookId;
    if (id == null) return;
    try {
      final db = await ref.read(bookDbProvider.future);
      final m = await BookMarkerRepository(db).findAt(
        bookId: id,
        chapterIdx: _chapterIdx,
        scrollRatio: _ratioHere,
      );
      if (!mounted) return;
      if (m?.id != _markerHere?.id) setState(() => _markerHere = m);
    } catch (_) {
      // 查书签失败不该影响阅读 —— 顶栏图标退化为「未标记」
    }
  }

  /// 打开本书的书签列表（底部弹层）。
  ///
  /// 🔑 用**模态** bottom sheet 是**有意的**：用户在「看列表」这个模式里，
  ///    不需要顶栏；这和「阅读设置面板必须非模态」不矛盾 ——
  ///    设置面板要**边调边看正文**，书签列表不用。
  Future<void> _showMarkers() async {
    final id = _bookId;
    if (id == null) return;
    // 🔑 独立页面，不是弹窗（白哥：书签多了弹窗装不下）
    final picked = await BookMarkerListScreen.push(
      context,
      bookId: id,
      bookTitle: _bookTitle,
    );
    if (picked == null || !mounted) return;
    await _jumpToMarker(picked);
  }

  /// 跳到某条书签的位置。
  ///
  /// 🔑 **先切章、再按章内比例定位**（两步，不能一次做）：
  ///    `goTo({index, fraction})` 里的 fraction 是**全书**比例，
  ///    直接塞章内比例会跳到别的章。
  Future<void> _jumpToMarker(BookMarker m) async {
    if (m.chapterIdx != _chapterIdx) {
      await _goToChapter(m.chapterIdx);
    }
    await _c.goToChapterRatio(m.chapterIdx, m.scrollRatio);
    if (!mounted) return;
    // 跳完刷新图标状态（新位置可能就是这条书签）
    setState(() => _markerHere = m);
  }

  /// 点书签键 = **打 / 取消**。
  ///
  /// 判据用 `_markerHere`（与图标状态同一个值）——
  /// 不重新查一次，避免「图标显示已标记、点下去却当成未标记」的竞态。
  Future<void> _toggleMarker() async {
    final id = _bookId;
    if (id == null) return;
    final db = await ref.read(bookDbProvider.future);
    final repo = BookMarkerRepository(db);
    try {
      if (_markerHere != null) {
        await repo.remove(_markerHere!.id);
        if (mounted) setState(() => _markerHere = null);
        return;
      }
      // 摘录：从当前位置往后取 ~40 字（书签列表里用来认出「这是哪一处」）
      final plain = _chapterPlainText ?? '';
      final start = _c.position.value.charOffset.clamp(0, plain.length);
      final excerpt = plain.substring(
        start,
        (start + 40).clamp(0, plain.length),
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      final marker = BookMarker(
        id: const Uuid().v4(),
        bookId: id,
        chapterIdx: _chapterIdx,
        scrollRatio: _ratioHere,
        excerpt: excerpt,
        createdAt: DateTime.now().toUtc(),
      );
      await repo.add(
        id: marker.id,
        bookId: marker.bookId,
        chapterIdx: marker.chapterIdx,
        scrollRatio: marker.scrollRatio,
        excerpt: marker.excerpt,
        createdAt: marker.createdAt,
      );
      if (mounted) setState(() => _markerHere = marker);
    } catch (e) {
      if (mounted) setState(() => _error = '书签操作失败：$e');
    }
  }

  /// 把面板里改过的**底色 + 字号**同步给 WebView。
  ///
  /// 🔑 面板改的是全局 `themeProvider` / `readingSettingsProvider`，
  ///    而 WebView 内部的 CSS 是独立的 ⇒ 不同步就是「改了没反应」。
  Future<void> _syncTypoFromProviders() async {
    if (!mounted) return;
    final idx = switch (ref.read(themeProvider).theme) {
      ReadingTheme.ink => 0,
      ReadingTheme.grid => 1,
      ReadingTheme.night => 2,
    };
    final fs = ref.read(readingSettingsProvider).fontSize.toDouble();
    final themeChanged = idx != _themeIdx;
    final sizeChanged = fs != _fontSize;
    if (!themeChanged && !sizeChanged) return;
    setState(() {
      _themeIdx = idx;
      _fontSize = fs;
    });
    final th = _themes[idx];
    await _c.setTheme(
      background: th.bg,
      foreground: th.fg,
      accent: th.accent,
      fontSize: fs,
      margin: 24,
    );
  }

  Timer? _saveTimer;

  /// 🆕 v6：位置变化 → **节流 1.2 秒**写进度（带 `char_offset`）。
  ///
  /// 🔑 为什么节流：翻页很快，每页都写库会白白刷盘（而且 `saveProgress`
  ///    还要镜像到 `book_progress_pending`，两次写）。
  void _onPosition() {
    final pos = _c.position.value;

    // 🔴 **跨章翻页必须同步当前章**（2026-10-23 改成「一次传整本书」之后新增）。
    //    `pos.sectionIndex` 就是章节下标 —— 用它更新 `_chapterIdx` / 划线的原文，
    //    否则翻到第 3 章了，进度还写在第 1 章、划线定位也在第 1 章的文本里找。
    if (pos.sectionIndex != _chapterIdx &&
        pos.sectionIndex >= 0 &&
        pos.sectionIndex < _chapters.length) {
      final ch = _chapters[pos.sectionIndex];
      setState(() {
        _chapterIdx = pos.sectionIndex;
        _chapterTitle = ch.chapterTitle;
        _chapterPlainText = ch.text;
      });
    }

    final id = _bookId;
    if (id == null) return;

    // 位置变了 ⇒ 顶栏书签图标的实心/空心可能变化（只在顶栏可见时查，省无谓查询）
    if (_bars) _refreshMarkerHere();

    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () async {
      final p2 = _c.position.value;
      try {
        final db = await ref.read(bookDbProvider.future);
        await saveProgress(
          db,
          bookId: id,
          // ⚠️ 这里必须用**位置里的章号**，不能用 `_chapterIdx` 的旧值：
          //    节流 1.2s 内可能已经翻过章了。
          chapterIdx: p2.sectionIndex,
          charOffset: p2.charOffset,
        );
        if (mounted) setState(() => _lastSaved = p2.charOffset);
      } catch (e) {
        if (mounted) setState(() => _error = '写进度失败：$e');
      }
    });
  }

  @override
  void dispose() {
    _c.lastError.removeListener(_onErr);
    _c.selectedText.removeListener(_onSel);
    _c.tapTick.removeListener(_onTap);
    _c.pullDownTick.removeListener(_onPullDown);
    _c.position.removeListener(_onPosition);
    _saveTimer?.cancel();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    // 🔴🔴 2026-10-24 白哥：「阅读设置里的所有设置都不能直观地反馈到主界面，
    //    要关闭设置面板后才会应用」
    //
    // 根因：之前只在**收起面板时**才 `_syncTypoFromProviders()`。
    // ⇒ 改成**监听 provider**：面板里一动就同步（不用等关面板）。
    //
    // ⚠️ 这里只监听「影响正文渲染」的两项：底色（themeProvider）与字号
    //    （readingSettingsProvider）。语速/音色只影响朗读，不需要重排正文。
    // ⚠️ 字号是 `A-` / `A+` 点按（不是连续滑杆）⇒ 每次点击触发一次重排，可接受。
    ref.listen(themeProvider, (_, __) => _syncTypoFromProviders());
    ref.listen(readingSettingsProvider, (_, __) => _syncTypoFromProviders());

    final t = _themes[_themeIdx];
    final bg = _hex(t.bg);
    final safe = MediaQuery.of(context).padding;

    // 🔴 2026-10-22 白哥：「底部和顶部应该只有单击页面才会弹出以供用户选择，
    //    而平常是看不见的，用户应该有一个干净的阅读界面不被任何东西打扰。」
    //
    // ⇒ 改成 **Stack 覆盖式**：正文永远占满整屏，顶/底栏浮在上面、默认隐藏。
    //   `AnimatedSlide` 让它们滑出/滑入（不是淡出 —— 滑动更能表达「收起来」）。
    //   ⚠️ 正文要避开状态栏与 Home indicator（用 `MediaQuery.padding`），
    //      否则第一行文字会压到灵动岛下面。
    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(top: safe.top, bottom: safe.bottom),
              child: Stack(
                children: [
                  FoliateReaderView(
                    controller: _c,
                    onError: (m) => setState(() => _error = m),
                  ),
                  if (_loading)
                    Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _hex(t.fg).withValues(alpha: 0.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 🆕 划词浮层（2026-10-23）—— 复用正式页的 `SelectionMenu`（同一个 UI，
          //    「长什么样」不重写），只是锚点从 `SelectableRegion` 换成了 WebView 的选区矩形。
          //    ⚠️ 展开成 List：空态时**一个子节点都不加**（见 `_selectionWidgets` 的长注释）。
          ..._selectionWidgets(safe.top),
          // 🔴 2026-10-24 白哥定：**页码条常驻** —— 它是阅读界面的一部分，
          //    只用来展示进度，**不跟着单击出现/消失**。
          //    （之前它和顶栏一起 AnimatedPositioned，单击才露出来 ⇒ 白哥看到的就是
          //      「单击弹出的是阅读进度」，而不是他想要的阅读设置面板。）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _footer(bg),
          ),

          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            top: _bars ? 0 : -(safe.top + 64),
            left: 0,
            right: 0,
            child: _bar(t),
          ),
          // 🆕 2026-10-24：阅读设置面板**嵌在 Stack 里**（不是模态路由）。
          //
          // 🔴 白哥：「顶栏当然要能点才行…现在的状态是**无论如何都点不到**」。
          //    根因是 `showModalBottomSheet` 插一条模态路由、遮罩盖住整屏
          //    ⇒ 底下的顶栏收不到点击（Flutter 的模态语义，不是层级写错）。
          //    ⇒ 改成同层嵌入：面板升起时**顶栏照样能点**。
          //    ⚠️ 代价：没有「点遮罩关闭」了 —— 关闭方式 = 点正文 / 点 ×。
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            // 🔴 与顶栏**同生同死**：同一个 `_bars` 控制两者的进出
            bottom: _bars ? 0 : -(MediaQuery.of(context).size.height),
            left: 0,
            right: 0,
            child: Material(
              color: _hex(t.bg),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              clipBehavior: Clip.antiAlias,
              child: ReadingSettingsPanel(
                showTrace: false,
                onOpenChapters: _chapters.isEmpty ? null : _openChapters,
                onClose: () => setState(() => _bars = false),
              ),
            ),
          ),

        ],
      ),
    );
  }

  static Color _hex(String s) {
    final v = int.parse(s.replaceFirst('#', ''), radix: 16);
    return Color(0xFF000000 | v);
  }

  /// 上栏 —— **结构与「热点阅读页」的 `_ReaderBar` 完全一致**（2026-10-23 白哥定：
  /// 「三个阅读页的上栏都不一样，为什么不都和热点阅读页一致？」）。
  ///
  /// 权威是 `reader_screen.dart` 的 `_ReaderBar`（591–730）：
  /// `Padding(20,0,20,14)` + Row：`‹`(19, ink3) · 标题(12.5, w600, ink2) ·
  /// `Tt`(20, ink2) · 朗读(22) · 书签。
  ///
  /// ⚠️ **spike 暂时没有书签**（要写 `book_marker` 表，正式页已有实现）——
  ///    接正式页时补上，这里不放假按钮。
  Widget _bar(({String name, String bg, String fg, String accent}) t) => SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Row(
            children: [
              // 返回 —— 字形只有 19px，用 Padding 撑热区（不影响行高）
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
                      color: _hex(t.fg).withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 标题 —— 与 `_ReaderBar` 同款：12.5 / w600 / ink2
              Expanded(
                child: InkWell(
                  onTap: _loading ? null : _openBookPicker,
                  child: Text(
                    _bookTitle ?? '翻页 spike',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _hex(t.fg).withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ),
              // 朗读（右上角）—— 行为照抄正式页：isSpeaking(整章) 判状态、stop() 停止
              if (_chapterPlainText != null)
                Builder(builder: (_) {
                  final tts = ref.watch(ttsServiceProvider);
                  final plain = _chapterPlainText!;
                  final speaking = tts.isSpeaking(plain);
                  return InkWell(
                    onTap: () {
                      if (speaking) {
                        tts.stop();
                      } else {
                        tts.speakLong(plain);
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      child: Icon(
                        speaking
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline,
                        size: 22,
                        color: speaking
                            ? _hex(t.accent)
                            : _hex(t.fg).withValues(alpha: 0.72),
                      ),
                    ),
                  );
                }),
              const SizedBox(width: 6),
              InkWell(
                // 🔑 白哥定：**下拉 = 打/取消**，这个键 = **打开已存书签列表**
                //    （2026-10-24：「加了书签在哪里找回」）
                onTap: _showMarkers,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Icon(
                    _markerHere == null
                        ? Icons.bookmark_border
                        : Icons.bookmark,
                    size: 22,
                    color: _markerHere == null
                        ? _hex(t.fg).withValues(alpha: 0.72)
                        : _hex(t.accent),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      );


  /// 底栏 —— **只有一行页码**（2026-10-23 白哥定：
  /// 「底部除了页码信息什么都不要，目录放在底部弹窗里，翻页按钮不要了」）。
  ///
  /// 交互：**点页码 → 弹章节目录**（目录本身就是底部弹层）。
  ///
  /// ⚠️ 保留 `_error` 那一块：出错必须可见（真机没有控制台）。
  ///    其余诊断（阶段 / 字体 / char_offset / 选词回显）都是验证期临时用的，删掉。
  Widget _footer(Color bg) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          color: bg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('⚠️ $_error',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFB4432C))),
                ),
              ValueListenableBuilder<FoliatePosition>(
                valueListenable: _c.position,
                builder: (_, p, __) {
                  // 章号用「当前位置的 sectionIndex」而不是 `_chapterIdx`
                  // —— 跨章翻页时后者由 `_onPosition` 异步同步，这里直接用前者更准
                  final sec = p.sectionIndex + 1;
                  final total = _chapters.isNotEmpty
                      ? _chapters.length
                      : (_chapterCount > 0 ? _chapterCount : 1);
                  final pct =
                      (p.fraction * 100).clamp(0, 100).toStringAsFixed(0);
                  // 🔴 白哥：页码条**只用来展示进度**，不是按钮
                  //    ⇒ 目录入口已移到「阅读设置面板」里（那一行「目录 ›」）。
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Text(
                      '$sec / $total　·　$pct%',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 12,
                        color: _hex(_themes[_themeIdx].fg)
                            .withValues(alpha: 0.55),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );




  /// 划词浮层：把 `SelectionMenu` 摆在选区**上方**（放不下就放下方）。
  ///
  /// ⚠️ 坐标换算：`selection` 里的 x/y 是 **iframe 内的 CSS px**，
  ///    而 WebView 在 `Positioned.fill` + `Padding(top: safeTop)` 里
  ///    ⇒ 屏幕 y 要加 `safeTop`。**左右不加**（没有横向 padding）。
  ///    这是首版近似值，真机若偏高/偏低，只需要调这里的偏移常量。
  /// 划词浮层 —— **返回 List**（没有选区时是空列表）。
  ///
  /// # 🔴🔴 为什么必须返回 List（2026-10-23 真机「彻底白屏」的教训）
  ///
  /// `Stack` 的尺寸由**非定位子节点**决定。我第一版让它在没有选区时返回裸的
  /// `SizedBox.shrink()` —— 那是个**非定位子节点、尺寸 0**
  /// ⇒ 整个 `Stack` 塌成 `0×0` ⇒ **WebView 和上下栏全部消失**（纯白，连诊断条都没了）。
  ///
  /// ⇒ 现在**空态返回空列表**（`Stack(children: [..._selectionWidgets()])`），
  ///   连子节点都不存在，**不可能影响 Stack 尺寸**。
  ///
  /// # 坐标换算
  /// `selection.x/y` 是 **iframe 内的 CSS px**；WebView 在
  /// `Positioned.fill` + `Padding(top: safeTop)` 里 ⇒ 屏幕 y 要加 `safeTop`，左右不加。
  List<Widget> _selectionWidgets(double safeTop) {
    final sel = _c.selection.value;
    if (sel == null || _hideSelectionMenu) return const [];
    const menuH = 56.0;
    const gap = 8.0;
    final screenTop = sel.y + safeTop;
    final above = screenTop - menuH - gap >= safeTop;
    final top = above ? screenTop - menuH - gap : screenTop + sel.h + gap;
    final left = sel.x.clamp(8.0, MediaQuery.of(context).size.width - 8.0);
    return [
      Positioned(
        left: left,
        top: top,
        child: SelectionMenu(items: [
          // 🔴🔴 **还原正式页的逻辑**（2026-10-23 白哥指出「下栏弹窗和原来的不一样」）：
          //
          // 第一项是「查词」**或**「翻译」—— **二选一，不是并列两个**。
          // 判据 `classifyPicked(text)`：单个可查的英文词 ⇒ 查词；其余（多词/纯符号/
          // 非拉丁）⇒ 翻译。理由是词库只收纯词形，拿一句话去查词必然未命中、
          // 还会触发一次在线制卡被服务端 400 拒掉。
          if (_pickedKind(sel.text) == PickedKind.word)
            SelectionMenuItem(
              label: '查词',
              icon: Icons.menu_book_outlined,
              onTap: () {
                setState(() => _hideSelectionMenu = true);
                // ⚠️ 书不是「文章」⇒ `articleId: null`（不记痕迹，与正式书库页同一口径）
                lookupWord(context, ref, sel.text, articleId: null);
              },
            )
          else
            SelectionMenuItem(
              label: '翻译',
              icon: Icons.translate,
              onTap: () {
                setState(() => _hideSelectionMenu = true);
                showTranslationSheet(
                  context,
                  text: sel.text,
                  // 来源标题可选 —— 拿不到就传 null，浮层退化为只写「翻译」
                  sourceLabel: _bookTitle,
                  // 🔴 **这个参数决定面板里有没有「划线记住这段」按钮**（白哥要的）
                  //    原判据：`highlightSource == null ? null : ...`
                  //    ⇒ 拿不到正文来源就**不传**（否则按钮点了会静默失败）。
                  onRemember: _canHighlight
                      ? (String? translation) {
                          _enqueueHighlight(sel.text, translation: translation);
                        }
                      : null,
                );
              },
            ),
          // 划线 —— 只有拿到「正文来源」时才出现（同正式页 `highlightSource != null`）
          if (_canHighlight)
            SelectionMenuItem(
              label: '划线',
              icon: Icons.edit_outlined,
              onTap: () {
                setState(() => _hideSelectionMenu = true);
                _enqueueHighlight(sel.text);
              },
            ),
          SelectionMenuItem(
            label: '复制',
            icon: Icons.content_copy_outlined,
            onTap: () async {
              setState(() => _hideSelectionMenu = true);
              await Clipboard.setData(ClipboardData(text: sel.text));
            },
          ),
        ]),
      ),
    ];
  }

  /// 能否划线（同正式页的 `highlightSource != null` 判据）。
  /// 拿不到书 / 章节原文 ⇒ 定位不了 ⇒ **不显示「划线」也不传 `onRemember`**。
  bool get _canHighlight => _bookId != null && _chapterPlainText != null;

  /// 选中的是「一个词」还是「一段话」—— 决定第一项是「查词」还是「翻译」。
  /// 直接复用正式页的纯函数（**不重写**，避免两处判据漂移）。
  static PickedKind _pickedKind(String text) => classifyPicked(text);

  /// 划线入队（书）—— 与正式页**同一套服务**（`enqueueHighlight` + `locateSelection`）。
  ///
  /// 🔴 这里是 spike 里**唯一需要自己拼**的一段（正式页的 `_enqueueHighlight` 是私有方法，
  ///    且带 toast / 写笔记入口）。核心逻辑（定位 + 写库）全部走公开 API，没有复制实现。
  Future<void> _enqueueHighlight(String text, {String? translation}) async {
    final id = _bookId;
    final plain = _chapterPlainText;
    if (id == null || plain == null) return;
    // 在**本章原文**里定位选中的片段 ⇒ start/end 偏移（找不到返回 -1，语义是「位置未知」）
    final span = locateSelection(plainText: plain, picked: text);
    var ok = false;
    try {
      final db = await ref.read(userDbProvider.future);
      final r = await enqueueHighlight(
        db: db,
        uuid: const Uuid().v4(),
        sourceType: HighlightSourceType.book,
        sourceId: id,
        chapterIdx: _chapterIdx,
        startOffset: span.start,
        endOffset: span.end,
        text: text,
        // 🔑 从翻译面板那条路来的时候**带着刚翻出来的译文** ——
        //    不接住它就是白花（用户为这段文字付了额度），
        //    复习时也只有骨架没有译文提示。这是白哥 2026-10-11 真机反馈过的问题。
        translation: translation,
      );
      ok = r == HighlightEnqueueResult.ok;
    } catch (e) {
      debugPrint('[spike] 划线入队失败：$e');
    }
    if (!mounted) return;
    setState(() => _error = ok ? null : '划线没存上，请再试一次');
    if (ok) {
      ref.read(userDbRevisionProvider.notifier).bump();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已加入记忆 · 复习里会再见')),
      );
    }
  }

  /// 章节目录（底部弹层）—— 真书才有。
  Future<void> _openChapters() async {
    final id = _bookId;
    if (id == null) return;
    final db = await ref.read(bookDbProvider.future);
    final rows = await db.query('book_chapter',
        columns: ['idx', 'title'], where: 'book_id = ?', whereArgs: [id], orderBy: 'idx ASC');
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _hex(_themes[_themeIdx].bg),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final idx = rows[i]['idx'] as int;
            final title = (rows[i]['title'] as String?)?.trim();
            final current = idx == _chapterIdx;
            return ListTile(
              dense: true,
              selected: current,
              leading: Text('${idx + 1}',
                  style: const TextStyle(fontSize: 12, fontFeatures: [])),
              title: Text(
                (title == null || title.isEmpty) ? '第 ${idx + 1} 章' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  color: _hex(_themes[_themeIdx].fg),
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _goToChapter(idx);
              },
            );
          },
        ),
      ),
    );
  }

  /// 演示文本（真实段落结构；足够撑 6+ 页）。
  static const _demoChapters = <String>[
    '<h2>Chapter I. Down the Rabbit-Hole</h2>'
        '<p>Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, "and what is the use of a book," thought Alice, "without pictures or conversations?"</p>'
        '<p>So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.</p>'
        '<p>There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself, "Oh dear! Oh dear! I shall be late!" But when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it.</p>'
        '<p>Burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge. In another moment down went Alice after it, never once considering how in the world she was to get out again.</p>'
        '<p>The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.</p>'
        '<p>Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs.</p>'
        '<p>She took down a jar from one of the shelves as she passed; it was labelled "ORANGE MARMALADE", but to her great disappointment it was empty: she did not like to drop the jar for fear of killing somebody underneath, so managed to put it into one of the cupboards as she fell past it.</p>'
        '<p>"Well!" thought Alice to herself, "after such a fall as this, I shall think nothing of tumbling down stairs! How brave they will all think me at home! Why, I would not say anything about it, even if I fell off the top of the house!" (Which was very likely true.)</p>'
        '<p>Down, down, down. Would the fall never come to an end? "I wonder how many miles I have fallen by this time?" she said aloud. "I must be getting somewhere near the centre of the earth. Let me see: that would be four thousand miles down, I think—"</p>'
        '<p>Presently she began again. "I wonder if I shall fall right through the earth! How funny it will seem to come out among the people that walk with their heads downward! The Antipathies, I think—but I shall have to ask them what the name of the country is, you know."</p>'
        '<p>Down, down, down. There was nothing else to do, so Alice soon began talking again. "Dinah will miss me very much to-night, I should think!" (Dinah was the cat.) "I hope they will remember her saucer of milk at tea-time. Dinah, my dear! I wish you were down here with me!"</p>'
        '<p>Suddenly, thump! thump! down she came upon a heap of sticks and dry leaves, and the fall was over. Alice was not a bit hurt, and she jumped up on to her feet in a moment: she looked up, but it was all dark overhead; before her was another long passage.</p>',
  ];
}
