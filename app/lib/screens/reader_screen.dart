import 'dart:async';

import 'package:flutter/material.dart';
// 🔑 `SelectedContent`（`onSelectionChanged` 的参数类型）由 rendering 导出，
//    **不在** `material.dart` / `widgets.dart` 的导出链里。
//    用 `show` 只引入这一个符号 —— 不把整个 rendering 命名空间拖进来。
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../providers/feed_provider.dart';
import '../services/article_text.dart';
import '../models/article.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../providers/bookmark_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../providers/word_db_provider.dart';
import '../services/article_read_repository.dart';
import '../services/reading_completion.dart';
import '../services/review_list_query.dart';
import '../services/user_word_repository.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_button.dart';
import '../widgets/lookup_sheet.dart';
import '../widgets/trace_locator.dart';
import '../widgets/trace_text.dart';

/// # 阅读器 —— 一篇文章的正文 + 痕迹
///
/// 目标态：`docs/design/visual-feed-bookmark-2026-09-25.html` 的「阅读界面」一格
/// （尺寸逐项取自其 CSS，不自行调整）。
///
/// | 元素 | CSS 选择器 | 值 |
/// |---|---|---|
/// | 顶部栏内边距 | `.rd-bar` | `0 20 14` · 间距 12 |
/// | 返回符 | `.rd-bar .back` | 19 / `ink3` |
/// | 分类 | `.rd-bar .ttl` | 12.5 / w600 / `ink2` |
/// | 正文区左右内边距 | `.rd` | 26 |
/// | 标题区 | `.rd-hd` | `6 0 20` |
/// | 来源行 | `.rd-hd .src` | 10.5 / w600 / 字距 .07em / 大写 / `accent` |
/// | 标题 | `.rd-hd h3` | Literata 21 / w500 / 行高 1.3 / 字距 -.012em / `ink` |
/// | 正文 | `.rd .body` | Literata **17** / 行高随主题 / 字距 .002em / `ink` |
/// | 段间距 | `.rd .body p+p` | 16 |
///
/// # 🔴 spec §八 的硬验收：「阅读界面零粘土」
/// 本页的**正文区（含标题区）不得出现任何粘土类**（`Clay` / 阴影 / 凹陷底）——
/// 「沉浸来自「什么都没有」，不是来自「很好看」」（spec §〇 规则 2）。
///
/// ⚠️ **顶部栏的书签按钮是唯一的粘土**，这是**有意保留**的：
/// - 设计稿里 `.bm`（书签）**是卡片与阅读界面共用的同一个类**（`.fc .bm` / `.rd-bar .bm`），
///   本来就是粘土的「凹/凸」两态 —— 若在阅读界面把它改成平面，
///   同一个动作在两个界面会长得不一样，破坏「一套语汇」。
/// - spec §八 的**自动检查措辞**是「**阅读区容器内**不得出现粘土类」——
///   限定范围是**阅读区**，不含顶部栏；该页只有这一个动作按钮，不构成「不沉浸」。
///
/// # ⚠️ 本轮未做（有意留白，不是遗漏）
/// - **顶部栏「下滑隐藏」**（spec §5.1）：spec 只给了这四个字，没给触发阈值/回弹规则；
///   自行定一个数等于替设计做决定 → 留到有明确规格时再做。
/// - **单击中央唤出阅读设置面板**（spec §5.1 · Kindle 模式）：面板本身（字号/行高/主题/
///   痕迹开关/语速）是独立一批，不在骨架内。🔑 这也是白哥选「长按选择」来划词的原因 ——
///   若单击既查词又唤面板，一个手势会有两种含义。
/// - **划词查词**（长按选择 → 浮层）：属 **3.4b**。
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.articleId});

  final int articleId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

/// # 🔑 为什么是 StatefulWidget
/// 需要一个 [Timer] 做**防抖**（见 [_lookupDebounce]）—— 那是构建之外的存活状态。
///
/// ## 🔴 为什么必须防抖（这是本页最容易踩的坑）
/// `onSelectionChanged` **不是「选完才调一次」**：
/// · 长按抬起 → 调一次
/// · 之后**拖动手柄调整范围 → 每移动一次就调一次**
///
/// 若在回调里直接查库：一次「长按 + 拖动微调」会打**十几次 SQLite**、
/// 并弹出**十几个浮层**（且一个叠一个）。
/// → 所以：**停手 300ms 后才查**（人拖动时是连续移动，停顿即视为选完）。
///
/// 🔑 白哥 2026-09-27 去掉中间步骤：「中间那个点『查词』是多余的，直接弹出底部浮窗就可以了」
///    —— 原先的流程是「长按 → 弹『查词』按钮 → 点它 → 弹浮层」，
///    现在直接把最后两步合并（少一次点击、少一个悬浮元素）。
class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  /// 正文字号。
  ///
  /// spec §5.1 写「默认 18px，可调 15–24px」；白哥 2026-09-27 定为 **17**（对齐 L1 界面锚点
  /// `visual-word-card-target` §07）。
  ///
  /// 🔑 为什么**不进主题 token**：行高是**主题相关**的（`readLineHeight` 三档 1.82/1.74/1.84 ——
  /// 不同底色下人眼舒适度不同），而字号是**用户偏好**（将来可调 15–24）。
  /// 一个是「主题」，一个是「设置」—— 混进同一层，将来做设置面板时会分不清谁覆盖谁。
  ///
  /// ⚠️ 放在 State 里（而非 widget 类）：只为 build 使用，
  ///    且 Dart 的 State **访问不到** widget 类的私有 static 成员。
  static const double _bodyFontSize = 17;

  /// 段落间距（设计稿 `.rd .body p+p{margin-top:16px}`）。
  static const double _paragraphGap = 16;

  /// 选中文本变化的**防抖定时器**（每次回调重置，停手 300ms 后才查词）。
  ///
  /// 🔴 **不能省** —— `onSelectionChanged` 在拖动手柄调节范围期间会**连续触发**，
  ///    直接查库会打出十几次请求、弹出十几个浮层。见类文档。
  Timer? _lookupDebounce;

  // ─────────────────────────────────────────────────────────────
  // 「读完」判定（「阅读篇数」的唯一写入点）
  // ─────────────────────────────────────────────────────────────
  // 口径：**滚到底 且 停留 ≥3s**（白哥 2026-09-29 定 · 见 `reading_completion.dart`）。

  /// 滚动控制器 —— 🔑 **本次新加**（此前 `SingleChildScrollView` 不需要它）。
  ///
  /// 用途单一：读 `position.extentAfter` 判断「到底了没」。
  /// ⚠️ 因为它是新加的，判定逻辑**必须容忍「还没 attach」**（首帧前 `hasClients == false`）。
  final ScrollController _scroll = ScrollController();

  /// 从进页到此刻的停留时长。
  ///
  /// 🔑 用 `Stopwatch` 而**不是** `DateTime.now()` 相减：
  ///    `Stopwatch` 是**单调时钟** —— 用户改系统时间 / NTP 校时都不会让它跳变。
  ///    用墙上时钟算「停了多久」是经典 bug（改一次时间就能算出负数或巨值）。
  final Stopwatch _dwell = Stopwatch();

  /// 周期检查「读完」的定时器。
  ///
  /// 🔴 **不能只在滚动回调里判** —— 内容**短于一屏**时不产生任何滚动事件
  ///    → 只靠滚动监听会**永远不检查**。详见 `reading_completion.dart` 文件头。
  ///    同样地，**也不能只在定时器里判**（长文滚到底的那一刻就该记上，
  ///    不必再等最多 1s）→ 两者都调同一个 `_checkCompletion()`。
  Timer? _completionTimer;

  /// 已写过「读完」→ 停止检查（每次进页最多写一次）。
  bool _readMarked = false;

  /// 每 1s 检查一次「读完」。
  ///
  /// ⚠️ 1s 的粒度够用：这是**展示型统计**，晚 1 秒记上没有用户可感差异；
  ///    而更高频（如每帧）只会在滚动时白跑。
  static const Duration _completionCheckInterval = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    _dwell.start();

    // 🔑 滚动时**也**检查 —— 长文滚到底的那一刻就能记上，不必再等最多 1s。
    //    ⚠️ 与定时器**共用同一个 `_checkCompletion`**（不是各写一份判据）：
    //       两处各写一份迟早会漂（本项目已踩过「同一件事两处口径」的坑）。
    _scroll.addListener(_checkCompletion);

    // 🔑 **首帧之后**才开始检查 —— 首帧前 `ScrollPosition` 还没 attach，
    //    此时 `extentAfter` 读不到，而「读不到」与「内容不足一屏」**结论相反**
    //    （后者是真到底，前者是未知）→ 不能在这里判。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkCompletion();
      _completionTimer = Timer.periodic(
        _completionCheckInterval,
        (_) => _checkCompletion(),
      );
    });
  }

  @override
  void dispose() {
    // 🔴 必须取消：定时器回调里会 `_lookupWord`（用 context）——
    //    页面已销毁时触发会用到失效的 context。
    _lookupDebounce?.cancel();

    // 🔴 「读完」的两样也要收尾：
    //    · 定时器不停会在页面销毁后继续跑（`_checkCompletion` 里有 `mounted` 守卫，
    //      但白跑定时器本身是泄漏）
    //    · `ScrollController` 必须 dispose（Flutter 的资源约定）
    _completionTimer?.cancel();
    _scroll.dispose();
    _dwell.stop();

    super.dispose();
  }

  /// 检查是否已「读完」；满足则**记一次**并停止检查。
  ///
  /// 🔑 判定本身在 `reading_completion.dart`（**纯函数 · 已单测 13 项**）。
  ///    本方法只做三件杂事：**取数 → 调用判定 → 落库**。
  void _checkCompletion() {
    if (_readMarked || !mounted) return;

    // ⚠️ **布局未完成时不判** —— 见 `initState` 的说明。
    //    这也顺带覆盖了「页面已 push 但还未 layout」的窗口期。
    if (!_scroll.hasClients) return;

    final done = isArticleCompleted(
      extentAfter: _scroll.position.extentAfter,
      dwell: _dwell.elapsed,
    );
    if (!done) return;

    _readMarked = true;
    _completionTimer?.cancel();
    unawaited(_markArticleRead());
  }

  /// 写入「读完了这篇」。
  ///
  /// 🔑 **`ref.read` 必须在任何 `await` 之前**（同 `_writeBackLookup` 的教训）：
  ///    本方法是 fire-and-forget，期间用户可能已退出阅读页 → `ref` 失效 →
  ///    `await` 之后再 `ref.read` 会抛错。先取到 **Future / notifier 实例**的引用，
  ///    它们与 widget 的存活无关。
  Future<void> _markArticleRead() async {
    // 两样都先取引用（顺序在 await 之前，理由同上）
    final dbFuture = ref.read(userDbProvider.future);
    final revision = ref.read(userDbRevisionProvider.notifier);

    try {
      final db = await dbFuture;
      final added = await ArticleReadRepository(db).markRead(widget.articleId);

      // 🔑 只在**真的新增**时 bump —— 与查词写入同一条原则：
      //    刷新不是因为「操作发生了」，而是因为「**数据变了**」。
      //    （重读同一篇 → `markRead` 返回 false → 库没动 → 不该让读端白重算一遍。）
      if (added) {
        revision.bump();
        debugPrint('[article_read] 已记录读完 articleId=${widget.articleId}');
      }
    } catch (e, st) {
      // 🔑 **只记日志**（同查词写入）：这是旁路统计，
      //    写失败**不该**影响阅读本身 —— 更不该弹窗打断。
      debugPrint(
        '[article_read] 写入失败 articleId=${widget.articleId}：$e\n$st',
      );
    }
  }

  /// 选中文本变化 → **防抖后直接查词**（不再有中间的「查词」按钮）。
  ///
  /// 🔴 **防抖不是性能优化，是正确性** —— `onSelectionChanged` 在
  /// 「拖动手柄调节范围」期间会**连续触发**，每次都走到这里。
  /// 若直接查库：一次「长按 + 微调」= 十几次 SQLite 查询 + 十几个叠起来的浮层。
  ///
  /// 🔑 300ms 的取值理由：人手拖动是**连续移动**（间隔通常 < 100ms），
  /// 而「停下来看结果」的停顿远超 300ms → 这个阈值能把「一次连续操作」
  /// 合并成一次查词，又不会让用户等得可感。
  void _onSelectionChanged(SelectedContent? content, WidgetRef ref) {
    _lookupDebounce?.cancel();

    final text = _cleanPicked(content?.plainText);
    if (text.isEmpty) {
      // 拖动把手的瞬间会出现「空选中」→ 撤掉已排队的那次，但不查
      return;
    }

    _lookupDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _lookupWord(context, ref, text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🆕 2026-09-29：正文改从 `GET /api/feed/{id}` 取（此前是 `mockArticleById`）。
    // 🔴 **两个 `watch` 都在顶层**（不放进 `when` 回调）—— Riverpod 要求
    //    `watch` 无条件执行，放进条件分支会造成「上次订阅了、这次没订阅」的漂移，
    //    表现为「有时不刷新」且**不报错**。
    final detailAsync = ref.watch(articleDetailProvider(widget.articleId));
    // 痕迹：数据源是端侧 `lookup_event`（不是内容源）→ 独立 provider，独立成败
    final lookupsAsync = ref.watch(articleLookupsProvider(widget.articleId));

    // 🔑 四种状态各有明确表达，**不共用白屏** ——
    //    白屏用户只会以为 App 坏了（与「静默失败」同类）。
    //    新增的第 4 种（网络失败 + 重试）是**这次接服务端才出现的** ——
    //    数据源从本机 mock 变成网络，失败就成了需要表达的常态。
    return detailAsync.when(
      // ① 加载中：转圈（详情比列表慢，必须给反馈）
      loading: () => Scaffold(
        backgroundColor: Color(t.page.argb32),
        body: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      // ② 失败：**分清 404 与「拿不到」**（前者劝重试没意义）
      error: (error, _) {
        final notFound = error is ContentApiException && error.isNotFound;
        // ⚠️ `_Notice` **自带 Scaffold + 返回按钮 + 阅读底色** → 调用处不要再包一层
        return _Notice(
          tokens: t,
          icon: notFound ? Icons.search_off : Icons.cloud_off,
          title: notFound ? '找不到这篇文章' : '这篇文章暂时打不开',
          message: notFound
              ? '它可能已被移除。返回上一页看看别的。'
              : '内容需要联网读取，现在读不到。\n稍后再试。',
          // 只在「可能好起来」时给重试（404 不会好）
          onRetry: notFound
              ? null
              : () => ref.invalidate(articleDetailProvider(widget.articleId)),
        );
      },
      // ③ 拿到详情 —— 再分「有正文」与「没正文」
      data: (value) {
        final item = value.item;
        // 🔑 正文分段用**纯函数**（`article_text.splitParagraphs`）——
        //    后端已按 `\n\n` 分好段，本层只切不猜（见那里的说明）。
        final paragraphs = splitParagraphs(value.readableText);

        // 正文真的为空 → 「没有正文」。
        // ⚠️ 与「找不到」是**两种不同的**表达（一个还有机会，一个没有）。
        if (!hasReadableBody(paragraphs)) {
          return _Notice(
            tokens: t,
            icon: Icons.hourglass_empty,
            title: '这一篇还没有正文',
            message: '这个来源目前只提供标题。\n换一篇读，或者稍后再来看看。',
          );
        }

        // 痕迹取不到 → 空列表（正文照常显示，只是没有底色）。
        // 🔑 「增强」不该有能力阻断「主体」—— 见 `articleLookupsProvider` 的说明。
        final lookups = lookupsAsync.valueOrNull ?? const <ArticleLookup>[];
        return _buildReader(context, t, item, paragraphs, lookups);
      },
    );
  }

  /// 正文可读时的阅读界面（从原 `build` 抽出 —— 让上面的四态分派保持扁平）。
  Widget _buildReader(
    BuildContext context,
    CoEvoTokens t,
    FeedItem item,
    List<String> paragraphs,
    List<ArticleLookup> lookups,
  ) {
    // 书签状态 —— 与信息流卡片**同一个 provider**，两处永远一致。
    final bookmarkState = ref.watch(bookmarkProvider);
    final bookmarked = bookmarkState.idsOrEmpty.contains(item.id);
    final bookmarkReady = bookmarkState.isReady;

    // 🔴🔴 **词库预热 —— 这一行不能删**（2026-09-27 修）
    //
    // `wordQueryProvider` 首次落盘 31.4 MB 要 0.5–2 s。
    // 若只被 `_lookupWord` 里的 `ref.read` 消费，落盘就要等到
    // **用户第一次长按查词**那一刻才开始 —— 而那一刻 future 刚启动，
    // `valueOrNull` **必然还是 null** → **第一次查词 100% 失败**，
    // 且文案是「正在准备，请稍候」，用户只会以为是自己的问题。
    //
    // `ref.watch` 让它在**进入阅读器**时就启动：用户读正文的这几秒足够写完。
    // （`bookmarkProvider` 就是这么做的；同类东西两种做法是 bug。）
    //
    // ⚠️ 不要为了「省一次 rebuild」改成 `read` —— 它换来的是「第一次必失败」。
    ref.watch(wordQueryProvider);

    return Scaffold(
      // 阅读底（`--read`）· 三档：墨 #FAF8F4 / 格 #FFFFFF / 夜 #14161C
      backgroundColor: Color(t.read.argb32),
      body: SafeArea(
        // 阅读器是**全屏**页（spec §5.1「底部：无（保持单纯）」）→ 不避让底部，也没有 tabbar
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ReaderBar(
              tokens: t,
              category: item.category,
              bookmarked: bookmarked,
              // 库未就绪 → 传 null → 按钮禁用（不传「点了没反应」的回调）
              onToggleBookmark: bookmarkReady
                  ? () => ref
                      .read(bookmarkProvider.notifier)
                      .toggle(item.id)
                  : null,
            ),
            Expanded(
              child: SingleChildScrollView(
                // 「读完」判定要读 `position.extentAfter` → 必须挂 controller。
                // 🔑 滚动监听**只做触发**，不做判定（判定在 `_checkCompletion` 里，
                //    与定时器共用同一条路径 —— 两处各写一份判据迟早会漂）。
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 48),
                // ── 长按选择（3.4b）──
                // 🔑 白哥定的手势是**长按选择**，不是单击查词 ——
                //    因为 spec §5.1 把「单击屏幕中央」留给了「唤出阅读设置面板」，
                //    两者正交才能并存（单击 = 设置 · 长按 = 选词）。
                //
                // 🔑 **长按即查**（白哥 2026-09-27：「中间那个点『查词』是多余的」）——
                //    原先要「长按 → 点『查词』→ 弹浮层」三步，现在一步到位。
                //
                // 🔴🔴 **⚠️ 本功能只能在触摸设备上验证（web/桌面测不出来）**：
                //    `SelectableRegion` 的长按手势注册时限定设备为
                //    `{touch, stylus, invertedStylus}`（**不含 mouse**）→
                //    在 Chrome / Windows 桌面用**鼠标长按不会产生任何选择**。
                //    → 验证路径：**Chrome 设备模拟** / **Android 模拟器** / iPhone 真机（最终以此为准）。
                child: SelectionArea(
                  onSelectionChanged: (c) => _onSelectionChanged(c, ref),
                  // 🔑 **必须显式返回空** —— 不提供时 `SelectionArea` 会用默认的
                  //    `AdaptiveTextSelectionToolbar`（「复制 / 全选 / 查找」），
                  //    那会**盖在正文上、且要用户再找一次路**（我们要的是「无中间步骤」）。
                  //    ⚠️ 与 `main.dart` 里 web 的 `disableContextMenu()` 是**两个不同层**：
                  //       那行关的是**浏览器原生菜单**，这行关的是 **Flutter 自己的工具栏**。
                  contextMenuBuilder: (_, __) => const SizedBox.shrink(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    _ReaderHead(tokens: t, item: item),
                    for (var i = 0; i < paragraphs.length; i++) ...[
                      if (i > 0) const SizedBox(height: _paragraphGap),
                      TraceText(
                        text: paragraphs[i],
                        // 痕迹：已查词在正文里的位置（已掌握的词不产生标记）
                        marks: locateTraceMarks(
                          text: paragraphs[i],
                          lookups: lookups,
                          tokens: t.trace,
                        ),
                        style: TextStyle(
                          fontFamily: CoFonts.latinSerif,
                          fontSize: _bodyFontSize,
                          height: t.readLineHeight,
                          letterSpacing: _bodyFontSize * 0.002,
                          color: Color(t.ink.argb32),
                        ),
                      ),
                    ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

/// 查词 —— 长按选中后（经 300 ms 防抖）的落点。
///
/// # 🔴 四种「拿不到词卡」必须各有明确表达（不能静默无效，也不能笼统）
///
/// | 情况 | 表达 | 能不能等 |
/// |---|---|---|
/// | **当前平台没有本地 SQLite**（web） | 「查词需在手机上使用」 | ❌ **永久** |
/// | **真机上落盘/打开失败** | 「词库打开失败，请重启 App 后再试」 | ❌ 需重启 |
/// | **还在首次落盘**（`valueOrNull == null`） | 「词库正在准备，请稍候再试」 | ✅ 约 0.5–2 s |
/// | 词库外（未命中 + 词形还原也没命中） | 「词库里没有「X」」 | —（属 Phase 3 的 `external_word_cache`） |
///
/// 🔑 **前两者与第三者必须分开** —— 笼统说「请稍候再试」会让 web 用户
/// 一直重试一个**永远不会成功**的操作（见 `word_db_provider` 的 [WordDbLoad] 文档）。
///
/// 🔑 提成顶层函数（而非 State 方法）：它不依赖任何 State 字段
/// （只用到 `context` 与 `ref`，两者都由调用处传入）→ 挂在 State 上没有理由。
Future<void> _lookupWord(BuildContext context, WidgetRef ref, String rawText) async {
  // ⚠️ 这里用 `read`（不订阅）是对的 —— 预热由 `build` 里的 `watch` 负责。
  //    `valueOrNull == null` 表示 future **还没跑完**（首次落盘中）。
  final load = ref.read(wordQueryProvider).valueOrNull;

  if (load is! WordDbReady) {
    _hint(
      context,
      switch (load) {
        WordDbUnsupported() => '查词需在手机上使用（Web 端无本地词库）',
        WordDbFailed() => '词库打开失败，请重启 App 后再试',
        // 到这里的只有 `null`（future 未完成）—— `WordDbReady` 已被上面排除
        _ => '词库正在准备，请稍候再试',
      },
    );
    return;
  }

  final text = rawText.trim();
  final result = await load.service.lookup(text);
  if (!context.mounted) return;

  // ── 🔑 Step 3.4c：查词写入（v1 §八 / §九：**查词即自动入生词本，零额外操作**）──
  //
  // 🔴🔴 **必须先弹浮层，写入放后面 —— 且不得阻塞**
  //    「读到词义」是产品核心动作。写库失败（磁盘满 / 库损坏）
  //    **绝不能**让用户看不到释义。所以：
  //      · 命中 → 先 `await` 浮层（用户看到释义）→ 再异步写入
  //      · 未命中 → 只记 `lookup_event`（白哥定 Q2：未命中**也记**）
  //    ⚠️ 写入的失败**只记日志**，不打扰用户（见 `_writeBackLookup`）。
  if (result == null) {
    _hint(context, '词库里没有「$text」');
    // 未命中：仍然留痕（`word_id` 留 NULL）—— 这让「查过哪些词」完整，
    // 也为 Phase 3 的「未命中 → LLM 制卡」留了输入。
    unawaited(_writeBackLookup(ref, spelling: text));
    return;
  }

  await LookupSheet.show(context, result);

  // 浮层已展示（或被用户关掉）→ 再做写入。
  // 🔑 传 `sentence: text` 不是语境 —— 本轮没有可靠的「所在句」来源，
  //    故**只记词本身**；`source_sentence` 留空比记一句错的好。
  //    （真实语境需从正文渲染层拿到句子边界，属后续增强。）
  unawaited(_writeBackLookup(
    ref,
    wordId: result.card.wordId,
    spelling: result.card.spelling,
  ));
}

/// 查词写入 —— **失败只记日志，绝不打扰用户**（见调用处的说明）。
///
/// 分工（照 v1 §九 的命中分支）：
///   ① `lookup_event` —— **每次都记**（命中/未命中都记 · 白哥定 Q2）
///   ② `user_word` —— **只在命中且有词库 id 时**（未命中的词没有 word_id）
///   ③ `card_review_state` —— 让新词**立刻进复习队列**（v1 §八 的
///      「INSERT user_word + card_review_state」是同一动作的两半）
///
/// ⚠️ 三者**不是事务**：任一步失败，前面的已经写入 ——
///    这是**有意**的（可接受的降级）。理由：
///    · 查词写入是「尽力而为」的旁路，不该因为复习调度写失败而丢掉落词记录
///    · 三张表各自独立可用（复习页只看 `card_review_state`、生词本只看 `user_word`）
///    → 若将来要做严格一致，才需要包事务；**当前没有这个必要**。
Future<void> _writeBackLookup(
  WidgetRef ref, {
  String? wordId,
  required String spelling,
}) async {
  // 🔑 **在任何 `await` 之前**先取到 notifier 引用。
  //
  // 原因是本函数是 `unawaited(...)` 调用的（fire-and-forget，不阻塞释义浮层），
  // 期间用户可能已经退出阅读页 → `ref` 失效 → `await` 之后再 `ref.read` 会抛错。
  // 而 `Notifier` **实例**的存活与 widget 无关（`userDbRevisionProvider`
  // 是非 autoDispose，只要 app 在就一直在）→ 拿着引用调 `bump()` 永远安全。
  final revision = ref.read(userDbRevisionProvider.notifier);
  // 🔑 同理：成就解锁队列的 notifier **实例**（存活与 widget 无关）
  final unlockNotifier = ref.read(achievementUnlockProvider.notifier);

  try {
    final repo = await ref.read(userWordProvider.future);
    await repo.recordLookup(wordId: wordId, spelling: spelling);

    if (wordId == null) return; // 未命中：没有词库 id，到此为止
    // ⚠️ 未命中时**不 bump**：只写了 `lookup_event`，而复习页读的是
    //    `user_word` + `card_review_state` → 刷了也是白刷一次库。

    final added = await repo.add(wordId, spelling);

    // `alreadyExists` → `add()` 直接 return，**一行都没写** → 库没变，不 bump。
    // 🔑 「只在**真的写库后**才刷新」的落实点：刷新不是「操作发生了」，
    //    而是「数据变了」。两者在这里正好分道（`alreadyExists` 也有操作，
    //    但库没动）。
    if (added == AddWordResult.alreadyExists) return;

    // 新词 → 立刻进复习队列（`next_review_at` = 现在 → 立即到期）
    // 🔑 只在**真的新增**时插：`alreadyExists` / `revived` 时状态已存在，
    //    重插会把用户已经积累的 FSRS 进度**清零**（`INSERT OR REPLACE`）。
    if (added == AddWordResult.added) {
      final review = ReviewListQuery(await ref.read(userDbProvider.future));
      await review.upsertState(
        wordId: wordId,
        spelling: spelling,
        state: 0, // 未学
        nextReviewAt: DateTime.now().toUtc(),
      );
    }

    // 🔴 **写库完成之后**才签「库变了」—— 顺序不可颠倒（先 bump 会让读端
    //    在写入完成前重查一次旧值，而修订号已经变过 → 不会再重算 → 表现为没刷新）。
    //
    // 到这里的两种情形都真的改了库：
    //   · `added`   → 新增 `user_word` + `card_review_state` → 复习页会多一个词
    //   · `revived` → `user_word.deleted = 0` + `updated_at` 刷新 → 复习页重新看到它
    revision.bump();

    // 🔑 成就检查（**写库成功之后** · 与 bump 同一时机原则：「数据变了」才检查）。
    //    `unawaited` —— 不阻塞查词浮层；失败在 `checkAndRefreshAchievements` 内 catch
    //    （成就永不影响查词主流程）。
    unawaited(_checkAchievementsAfterLookup(ref, unlockNotifier));
  } catch (e, st) {
    // 🔑 **只记日志**（见调用处说明）：查词写入失败不影响「看到词义」。
    debugPrint('[lookup] 写入失败 spelling=$spelling：$e\n$st');
  }
}

/// 查词写回后的成就检查（**不阻塞查词流程**）。
///
/// 🔑 与 `review_session_screen._checkAchievements` 同一模式：
///    · `unawaited` 调用 → 队列 notifier 由调用方传入（`ref` 可能已失效）
///    · 失败在 `checkAndRefreshAchievements` 内 catch → 不打断查词
///
/// 🔴 **必须定义在 `_writeBackLookup` 之外** —— 2026-09-29 两次踩坑记录：
///   ① 用「大括号计数」找函数结尾时，`_writeBackLookup` 的**命名参数 `{`**
///      （`WidgetRef ref, {`）会先被当成函数体 → 函数被插进签名中间。
///   ② 更隐蔽：**先插入、再定位**时，刚插入的 helper 里也有 `) async {`
///      → 第二次定位找到的是**自己**，越修越坏。
///   🔑 正确做法：**从 `) async {` 之后开始计数**，且**先定位再插入**（一次完成）。
Future<void> _checkAchievementsAfterLookup(
  WidgetRef ref,
  AchievementUnlockNotifier notifier,
) async {
  final newly = await checkAndRefreshAchievements(ref);
  if (newly.isEmpty) return;
  notifier.pushAll(newly);
}


/// 轻提示（沿用首页 toast 的样式 —— `snackBarTheme` 已是「ink 底 + page 字 + floating」）。
void _hint(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
}

/// 归一化长按选中的文本（**只做输入卫生，不做任何猜测**）。
///
/// # 🔴 为什么不在这里剥首尾标点（我一度这么写，被实测否掉）
/// 直觉是「`word,` 在词库里查不到 → 剥掉逗号就好了」。但实测词库后发现**两个反例**：
///
/// | 词库真实词条 | 剥首尾标点后 | 后果 |
/// |---|---|---|
/// | **`a.m.`** · **`dr.`** | `a.m` · `dr` | 🔴 **反而查不到**（原词条就带句点） |
/// | **`café`** · `cybercafé` · `français` | ~~`caf`~~（若用 `[^A-Za-z0-9]`） | 🔴 **把词毁掉** |
///
/// 而词库里含内部标点的词共 **64 个**（`e-mail` · `brother-in-law` · `driver's license` …）
/// → 「把标点剥掉」这个动作**需要知道词库里有什么**，那是查询层的信息，UI 层没有。
///
/// 🔑 **结论：UI 层只做「去空白」这一件无争议的事**；标点/大小写等**宽松匹配属查询层**
///    （它才知道精确命中是否失败、该不该再试一次）。
///
/// ⚠️ **已知边界（待办）**：长按后**拖动手柄**会把相邻标点带进来（`vertical,`），
///    当前会提示「词库里没有『vertical,』」。修法是查询层加**「精确 → 剥标点」两段查**，
///    但那是查询层的改动（要同步 `verify_word_query`），**不在本轮**。
///    📌 主路径不受影响：长按**默认选中的就是一个词**（不含标点）。
String _cleanPicked(String? raw) => raw?.trim() ?? '';

/// 顶部栏 —— 设计稿 `.rd-bar`：**返回 / 分类 / 书签**三元素。
///
/// 设计稿的原话：「书签是「**动作**」不是「**显示元素**」—— 不占版面、不干扰阅读，
/// 也不违反「阅读界面保持单纯」」。
class _ReaderBar extends StatelessWidget {
  const _ReaderBar({
    required this.tokens,
    required this.category,
    required this.bookmarked,
    required this.onToggleBookmark,
  });

  final CoEvoTokens tokens;
  final String category;
  final bool bookmarked;
  final VoidCallback? onToggleBookmark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Row(
        children: [
          // 返回 —— ⚠️ 字形只有 19px，热区必须撑到 44（触达标准）。
          //    用 `Padding` 撑而不是 `SizedBox`，这样**不影响行的视觉高度**。
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: Text(
                '‹',
                style: TextStyle(
                  fontSize: 19,
                  height: 1,
                  color: Color(tokens.ink3.argb32),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              category,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // ⚠️ 设计稿 `--round`(Quicksand) 未打包 → 与卡片元信息行同样改用 `uiSans`
                fontFamily: CoFonts.uiSans,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(tokens.ink2.argb32),
              ),
            ),
          ),
          const SizedBox(width: 12),
          BookmarkButton(
            bookmarked: bookmarked,
            onPressed: onToggleBookmark,
          ),
        ],
      ),
    );
  }
}

/// 标题区 —— 设计稿 `.rd-hd`：来源行 + 标题。
class _ReaderHead extends StatelessWidget {
  const _ReaderHead({required this.tokens, required this.item});

  final CoEvoTokens tokens;
  final FeedItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // 设计稿 `.src` 的文本是「分类 · 来源」，且 `text-transform: uppercase`
            '${item.categoryLabel} · ${item.source}'.toUpperCase(),
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 10.5 * 0.07,
              color: Color(tokens.accent.argb32),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            style: TextStyle(
              fontFamily: CoFonts.latinSerif,
              fontSize: 21,
              fontWeight: FontWeight.w500,
              height: 1.3,
              letterSpacing: 21 * -0.012,
              color: Color(tokens.ink.argb32),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「读不了」的两种状态（id 不存在 / 正文未就绪）—— **共用同一套版式**，
/// 但文案不同（用户需要知道是「没了」还是「还没到」）。
///
/// 版式同样遵守「阅读界面零粘土」：一个图标 + 两行字，没有任何粘土类。
class _Notice extends StatelessWidget {
  const _Notice({
    required this.tokens,
    required this.icon,
    required this.title,
    required this.message,
    this.onRetry,
  });

  final CoEvoTokens tokens;
  final IconData icon;
  final String title;
  final String message;

  /// 重试回调。`null` = **不给重试按钮**（见下）。
  ///
  /// # 🔑 为什么区分「给不给」
  /// 本页有两种「看不到内容」：
  /// · **拿不到**（网络/服务失败）→ 会好起来，**重试有意义** ✅
  /// · **找不到**（404）/ **没有正文** → 重试一万次也一样
  /// → 后者不给按钮。给一个**按了没用**的按钮，比不给更糟：
  ///   用户会反复按，然后判定「App 坏了」。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(tokens.read.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: InkWell(
                onTap: () => context.pop(),
                borderRadius: BorderRadius.circular(22),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Text(
                    '‹',
                    style: TextStyle(
                      fontSize: 19,
                      height: 1,
                      color: Color(tokens.ink3.argb32),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 32, color: Color(tokens.ink3.argb32)),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: CoFonts.cjk,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(tokens.ink.argb32),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: CoFonts.cjk,
                          fontSize: 13,
                          height: 1.6,
                          color: Color(tokens.ink2.argb32),
                        ),
                      ),
                      // 🔑 重试**只在「可能好起来」时出现**（见 [onRetry] 的说明）
                      if (onRetry != null) ...[
                        const SizedBox(height: 20),
                        // ⚠️ 阅读区**零粘土**（spec §八）→ 用纯文字按钮，
                        //    与信息流/收藏页的重试保持**同一形制**（加粗 + 强调色）
                        TextButton(
                          onPressed: onRetry,
                          child: Text(
                            '重试',
                            style: TextStyle(
                              fontFamily: CoFonts.uiSans,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(tokens.accent.argb32),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
