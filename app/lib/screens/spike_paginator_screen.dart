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

  /// 书签图标是否处于「刚被下拉触发」的脉冲态（放大再回弹）。
  bool _markerPulse = false;

  /// 一句短提示（「已加书签 / 已取消书签」）—— 2 秒后自动消失。
  ///
  /// 🔑 用**页面内的一行字**而不是 SnackBar：SnackBar 会从底部升起、
  ///    盖住页码条，而且下拉是「每页都可能触发」的动作，高频浮层比没反馈更烦。
  String? _markerHint;
  Timer? _markerHintTimer;

  void _clearMarkerHintSoon() {
    _markerHintTimer?.cancel();
    _markerHintTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _markerHint = null);
    });
  }

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
    _c.pullRatio.addListener(_onPullRatio);
    _c.pullEndTick.addListener(_onPullRelease);
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
    final hl = await _loadHighlights();
    if (!mounted) return;
    await _c.setChapters(
      [
        for (final ch in all)
          _textToHtml(ch.text, ch.chapterTitle, hl[ch.idx] ?? const []),
      ],
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
  /// 把一章纯文本转成 HTML（**含划线下划线**）。
  ///
  /// 🆕 2026-10-24：原来完全不读划线 ⇒ 用户在正式页划过的线，到翻页页**看不见**
  /// （白哥接入前检查时点出来的缺口）。
  ///
  /// [hl] 是本章的划线区间（**全章原文偏移**，来自 `highlight.start_offset/end_offset`）。
  ///
  /// ⚠️ 段落必须**按原文顺序**切，且记下每段第一个字在原文里的偏移 ——
  ///    直接用 `split().map(trim)` 拿不到偏移，划线就会画到别的段上。
  static String _textToHtml(
    String text,
    String? chapterTitle,
    List<(int, int)> hl,
  ) {
    final buf = StringBuffer();
    // ⚠️ 标题不进正文（`char_offset` 只算正文段落）——
    //    所以标题单独用 `<h2 class="ch-title">`，偏移计算时按 class 跳过。
    if (chapterTitle != null && chapterTitle.trim().isNotEmpty) {
      buf.write('<h2 class="ch-title">${_escape(chapterTitle.trim())}</h2>');
    }
    final re = RegExp(r'\n\s*\n');
    var cursor = 0;
    for (final raw in text.split(re)) {
      final idx = text.indexOf(raw, cursor);
      if (idx < 0) continue;
      cursor = idx + raw.length;
      final p = raw.trim();
      if (p.isEmpty) continue;
      // 段首在**原文**里的偏移（trim 掉前导空白也要算进去）
      final base = idx + raw.indexOf(p);
      buf.write('<p>${_paraHtml(p, base, hl)}</p>');
    }
    return buf.toString();
  }

  /// 读整本书的划线，按章分组（`chapter_idx` → 区间列表）。
  Future<Map<int, List<(int, int)>>> _loadHighlights() async {
    final id = _bookId;
    if (id == null) return const {};
    try {
      final db = await ref.read(userDbProvider.future);
      final rows = await HighlightRepository(db).listForSource(
        sourceType: HighlightSourceType.book,
        sourceId: id,
        // 🔑 不传 chapterIdx ⇒ 一次拿全书的划线（N 章查 N 次没必要）
      );
      final out = <int, List<(int, int)>>{};
      for (final h in rows) {
        final ch = h.chapterIdx;
        if (ch == null) continue;
        // 定位失败存的是 -1（「位置未知」）⇒ 不画线，免得画到开头
        if (h.startOffset < 0 || h.endOffset <= h.startOffset) continue;
        (out[ch] ??= <(int, int)>[]).add((h.startOffset, h.endOffset));
      }
      return out;
    } catch (_) {
      // 读划线失败不该影响阅读 —— 退化为「没有线」
      return const {};
    }
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// 段内按划线区间插入 `<span class="hl">`。
  ///
  /// [base] 是本段第一个字在**全章原文**里的偏移 —— 划线存的是全章偏移，
  /// 段落切分后必须换算成段内偏移，否则会错位到别的段。
  ///
  /// ⚠️ 区间可能**跨段**（用户从一段划到下一段）⇒ 每段只取它与本段的**交集**。
  ///    区间也可能**互相重叠** ⇒ 先排序再用 `cur` 推进，避免嵌套 span。
  static String _paraHtml(String p, int base, List<(int, int)> hl) {
    final segEnd = base + p.length;
    final marks = <(int, int)>[];
    for (final (s, e) in hl) {
      final a = s > base ? s : base;
      final b = e < segEnd ? e : segEnd;
      if (a < b) marks.add((a - base, b - base));
    }
    if (marks.isEmpty) return _escape(p);
    marks.sort((x, y) => x.$1.compareTo(y.$1));
    final buf = StringBuffer();
    var cur = 0;
    for (final (a, b) in marks) {
      if (a > cur) buf.write(_escape(p.substring(cur, a)));
      // 重叠部分已被前一段覆盖 ⇒ 只补剩下的
      final from = a > cur ? a : cur;
      if (b > from) {
        buf.write('<span class="hl">${_escape(p.substring(from, b))}</span>');
      }
      if (b > cur) cur = b;
    }
    if (cur < p.length) buf.write(_escape(p.substring(cur)));
    return buf.toString();
  }

  void _onErr() {
    final e = _c.lastError.value;
    if (e != null && mounted) setState(() => _error = e);
  }

  /// 正文竖直下拉 —— 打/取消书签。
  ///
  /// 白哥定：「无书签的下拉加书签，有书签的下拉删除书签」。
  /// 判据完全交给 `_toggleMarker`（它用 `_markerHere` 决定加还是删），
  /// 这里**不重复判断**。
  /// 下拉的跟手位移量（px）—— 拖动时正文整体下移，做出「拉动」的手感。
  double _pullDy = 0;

  /// 下拉是否已松手且**达标**（松手后转圈一会儿再回弹，给「已触发」一个收尾）。
  bool _pullArmed = false;

  /// 下拉过程中**临时**显示顶栏（让用户看到书签图标的变化）。
  ///
  /// 🔑 为什么和 `_bars` 分开：单击正文是「顶栏 + 设置面板一起出」（同生同死），
  ///    而**下拉只需要顶栏** —— 面板会挡住正文，用户反而看不到书签状态变了。
  ///    ⇒ 顶栏的可见条件 = `_bars || _pullTopBar`；面板只看 `_bars`。
  bool _pullTopBar = false;

  void _onPullRatio() {
    if (!mounted) return;
    final r = _c.pullRatio.value;

    // 🔴🔴 2026-10-24 白哥：「下拉后不会回弹，一直在转圈」
    //
    // 根因就在这一行：原来写的是 `if (r == null) return;` ——
    //   松手时 JS 会把 `pullRatio` 置 null（表示「这次手势结束了」），
    //   而我**直接 return**，`_pullDy` 就永远停在 96px、转圈也永远不停。
    //   ⇒ null 的语义是「回到静止」，必须**归零**，不是「忽略」。
    if (r == null) {
      if (_pullDy != 0 || _pullArmed || _pullTopBar) {
        setState(() {
          _pullDy = 0;
          _pullArmed = false;
          // 回弹时顶栏一起收起（白哥：「回弹时上栏也同时收起」）
          _pullTopBar = false;
        });
      }
      return;
    }
    // 位移封顶 96px：再往下拖内容会飞出屏幕，也不再有信息量
    setState(() {
      _pullDy = r * 96;
      _pullArmed = r >= 1;
      // 白哥：「下拉时应该显示上栏，让用户知道书签状态变化」
      final wasHidden = !_pullTopBar;
      _pullTopBar = r > 0;
      // 顶栏刚被下拉点亮 ⇒ 立刻查一次「当前位置在不在书签处」，
      // 否则用户下拉看到的是一个还没刷新的空图标（点下去才知道对不对）
      if (wasHidden && r > 0) _refreshMarkerHere();
    });
  }

  void _onPullRelease() {
    // ⚠️ 用**计数器**而不是 `ValueNotifier<bool>`：
    //    连续两次下拉都达标时 bool 值都是 true ⇒ **不触发通知** ⇒ 第二次不回弹。
    //    （同样的问题在 `tapTick` 上已经用过一次正确解法，这里沿用它。）
    if (!mounted) return;
    final ok = _c.pullEndArmed;
    if (ok) _onPullDown();
    // 无论达标与否都回弹；达标时多停 260ms 让转圈收个尾
    Future<void>.delayed(Duration(milliseconds: ok ? 260 : 0), () {
      if (!mounted) return;
      setState(() {
        _pullDy = 0;
        _pullArmed = false;
        _pullTopBar = false;
      });
    });
  }

  void _onPullDown() {
    if (!mounted) return;
    // 🔴 2026-10-24 白哥：「下拉无动画反馈，屏幕不动、不转圈，
    //    用户根本不知道动作是否有效」
    //
    // ⇒ 三重反馈，越轻越好（这是**每页都可能触发**的高频动作）：
    //   ① **震动**：立刻可感，不占屏幕
    //   ② **书签图标脉冲**（放大 1.25× 再回弹 220ms）：给眼睛一个落点
    //   ③ **加/删的文案提示**（在 `_toggleMarker` 里，短暂显示）
    HapticFeedback.mediumImpact();
    _pulseMarker();
    _toggleMarker();
  }

  /// 书签图标脉冲：让用户「看到」这次下拉被接收了。
  ///
  /// ⚠️ 不弹 SnackBar：它会从底部升起、盖住页码条，而且每翻几页就可能触发一次，
  ///    高频出现的浮层比「没反馈」更烦。
  Future<void> _pulseMarker() async {
    if (!mounted) return;
    setState(() => _markerPulse = true);
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (mounted) setState(() => _markerPulse = false);
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
        if (mounted) {
          setState(() {
            _markerHere = null;
            _markerHint = '已取消书签';
          });
          _clearMarkerHintSoon();
        }
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
      if (mounted) {
        setState(() {
          _markerHere = marker;
          _markerHint = '已加书签 · 第 ${marker.chapterIdx + 1} 章';
        });
        _clearMarkerHintSoon();
      }
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
    _markerHintTimer?.cancel();
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
    _c.pullRatio.removeListener(_onPullRatio);
    _c.pullEndTick.removeListener(_onPullRelease);
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
              // 🔑 下拉跟手：把整块正文（含内部 WebView）一起下移。
              //    用 `Transform.translate` 而不是改 padding —— 后者会触发重排，
              //    拖拽时每帧重排必然掉帧。
              child: Transform.translate(
                offset: Offset(0, _pullDy),
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
          ),

          // 🆕 下拉转圈（学「今日精选」那种）：**跟手出现**，达标后转为不确定动画
          if (_pullDy > 0)
            Positioned(
              top: safe.top + _pullDy - 34,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: _pullArmed
                      // 达标 ⇒ 转圈（表示「松手就会执行」）
                      ? CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _hex(t.fg).withValues(alpha: 0.5),
                        )
                      // 未达标 ⇒ 进度环（跟手，让用户知道还差多少）
                      : CircularProgressIndicator(
                          strokeWidth: 2,
                          value: (_pullDy / 96).clamp(0.0, 1.0),
                          color: _hex(t.fg).withValues(alpha: 0.35),
                        ),
                ),
              ),
            ),
          // 🆕 划词浮层（2026-10-23）—— 复用正式页的 `SelectionMenu`（同一个 UI，
          //    「长什么样」不重写），只是锚点从 `SelectableRegion` 换成了 WebView 的选区矩形。
          //    ⚠️ 展开成 List：空态时**一个子节点都不加**（见 `_selectionWidgets` 的长注释）。
          ..._selectionWidgets(safe.top),
          // 🆕 下拉书签的一句短提示（「已加书签」/「已取消书签」）
          //    位置在页码条上方，2 秒自动消失；不挡正文、不占布局（Stack 浮层）
          if (_markerHint != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 44,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: _hex(t.fg).withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _markerHint!,
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 12,
                        color: _hex(t.bg),
                      ),
                    ),
                  ),
                ),
              ),
            ),

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
            // 🔑 顶栏可见 = 单击唤出（_bars）**或** 下拉过程中（_pullTopBar）
            //    下拉时**只出顶栏、不弹面板** —— 面板会挡住正文，
            //    用户就看不到「书签图标从空心变实心」这个变化了。
            top: (_bars || _pullTopBar) ? 0 : -(safe.top + 64),
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
                      // 🔴 2026-10-24 白哥：「上栏的字体远小于下栏，很不协调」。
                      //    原来 12.5（照热点页 `_ReaderBar` 抄的），而：
                      //    · 页码条 12 · 设置面板标题 15 · 面板项 14 · 正文 17
                      //    ⇒ 顶栏是**全页最小的一档**，夹在一排 19~22px 的图标中间
                      //    显得又小又散。调到 **15**（与面板标题同档），
                      //    层级变成：正文 17 > 顶栏/面板标题 15 > 面板项 14 > 页码 12。
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _hex(t.fg).withValues(alpha: 0.78),
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
                  child: AnimatedScale(
                    // 下拉时放大一下再回弹 —— 让用户「看到」动作被接收
                    scale: _markerPulse ? 1.25 : 1.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
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
