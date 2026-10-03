import 'dart:async';

import 'package:flutter/material.dart';
// 🔑 `SelectedContent`（`onSelectionChanged` 的参数类型）由 rendering 导出，
//    **不在** `material.dart` / `widgets.dart` 的导出链里。
//    用 `show` 只引入这一个符号 —— 不把整个 rendering 命名空间拖进来。
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/content_client.dart';
import '../api/generate_card_client.dart';
import '../models/feed_item.dart';
import '../providers/feed_provider.dart';
import '../services/article_text.dart';
import '../models/article.dart';
import '../providers/achievement_notifier.dart';
import '../providers/achievement_provider.dart';
import '../providers/bookmark_provider.dart';
import '../providers/device_id_provider.dart';
import '../providers/generate_card_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../providers/word_db_provider.dart';
import '../services/article_read_repository.dart';
import '../services/external_word_cache_repository.dart';
import '../services/external_word_id.dart';
import '../services/generated_card_adapter.dart';
import '../services/reading_completion.dart';
import '../services/review_list_query.dart';
import '../services/user_word_repository.dart';
import '../services/word_query_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_button.dart';
import '../widgets/lookup_sheet.dart';
import '../widgets/trace_markdown.dart';

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
      // 🔴 **必须传 `articleId`**：它是「痕迹」的唯一键 ——
      //    `lookup_event.article_id` 为空 ⇒ 阅读页永远查不到「本文查过的词」⇒ 痕迹恒不显示。
      _lookupWord(context, ref, text, articleId: widget.articleId);
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
          message: notFound ? '它可能已被移除。返回上一页看看别的。' : '内容需要联网读取，现在读不到。\n稍后再试。',
          // 只在「可能好起来」时给重试（404 不会好）
          onRetry: notFound
              ? null
              : () => ref.invalidate(articleDetailProvider(widget.articleId)),
        );
      },
      // ③ 拿到详情 —— 再分「有正文」「只有摘要」「什么都没有」
      data: (value) {
        final item = value.item;
        // 🆕 2026-10-02：取的是 `renderable`（**带来源**），不再是 `readableText`。
        // 🔴 原来那个 `String?` 把「全文」与「兜底摘要」压成同一个东西 →
        //    某篇的 summary 是源站报错时，**那句报错被当正文渲染**
        //    （用户看到「只有半句话」）。见 `ArticleTextSource` 的说明。
        final renderable = value.renderable;
        final body = renderable?.text ?? '';
        final summaryOnly = renderable?.source == ArticleTextSource.summary;

        // 「有没有正文」的判据**保持不变**（仍是 `splitParagraphs` 切出非空段落）。
        // 🔑 为什么不改成「Markdown 是否为空」：那是把**一个判据换成另一个**，
        //    而现判据有它自己的语义（「至少有一段能读的文字」，
        //    不设「至少 N 段」门槛 —— 一句话短讯也是合法内容）。
        //    正文形态从纯文本变 Markdown **不影响这条**：Markdown 的段落同样按空行分。
        //    📌 换渲染器时，「呈现」要跟着换，「判据」要能不动就不动。
        final paragraphs = splitParagraphs(body);

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
        return _buildReader(
          context,
          t,
          item,
          body,
          lookups,
          summaryOnly: summaryOnly,
        );
      },
    );
  }

  /// 正文可读时的阅读界面（从原 `build` 抽出 —— 让上面的四态分派保持扁平）。
  ///
  /// [body] 正文**原文**（Markdown 形态）—— 交给 [`TraceMarkdown`] 渲染，
  /// 本层**不再分段**（分段与排版是渲染器的事）。
  ///
  /// [summaryOnly] = 现在渲染的不是全文，而是**兜底摘要**（见 [ArticleTextSource]）。
  /// 此时顶部加一条明确说明 —— 🔴 **不许让摘要冒充正文**：
  /// 用户读到一段就结束、却以为「文章就这么短」，比看到一句实话更糟。
  Widget _buildReader(
    BuildContext context,
    CoEvoTokens t,
    FeedItem item,
    String body,
    List<ArticleLookup> lookups, {
    bool summaryOnly = false,
  }) {
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
                  ? () => ref.read(bookmarkProvider.notifier).toggle(item.id)
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
                      // 🆕 「这不是全文」必须**在正文之前**说 ——
                      //    放在末尾等于用户读完了才知道（那时已经误解了）。
                      if (summaryOnly) ...[
                        const SizedBox(height: 16),
                        _SummaryOnlyBanner(tokens: t),
                      ],
                      // ── 正文（Markdown 渲染）──
                      // 🆕 2026-10-02（S4）：从「逐段 `TraceText`」换成 `TraceMarkdown`。
                      //
                      // 🔴 为什么必须换（不是风格选择）：后端正文已变成 **Markdown**，
                      //    而纯文本渲染会：
                      //      · 把代码块的多行/缩进**压平**（段落内换行 → 空格）
                      //      · 把 ``` / `##` / `**` 当**普通文字**显示
                      //    ⇒ 不换 = 白哥报的症状一个都没治好，还多出 Markdown 标记。
                      //
                      // 🔑 痕迹**没丢** —— 它换了一种表达方式（字符区间 → 源内标记），
                      //    判定逻辑仍是同一个 `pickedTraceTiers`（见 `trace_locator.dart`）。
                      TraceMarkdown(
                        markdown: body,
                        lookups: lookups,
                        tokens: t,
                        bodyFontSize: _bodyFontSize,
                        // ⚠️ 2026-10-03：`onLinkFailed` 已移除 ——
                        //    正文里的链接现在**不可点**（白哥定），
                        //    所以「打不开链接」这个失败路径**不存在了**。
                        //    见 `trace_markdown.dart` 的「链接」一节。
                      ),
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
/// # 🔴 五种「拿不到词卡」必须各有明确表达（不能静默无效，也不能笼统）
///
/// | 情况 | 表达 | 能不能等 |
/// |---|---|---|
/// | **当前平台没有本地 SQLite**（web） | 「查词需在手机上使用」 | ❌ **永久** |
/// | **真机上落盘/打开失败** | 「词库打开失败，请重启 App 后再试」 | ❌ 需重启 |
/// | **还在首次落盘**（`valueOrNull == null`） | 「词库正在准备，请稍候再试」 | ✅ 约 0.5–2 s |
/// | 🆕 **词库外**（未命中 + 词形还原也没命中） | **转圈 → 在线制卡**（见 `_lookupExternalWord`）| ✅ 约 5–10 s |
/// | 🆕 词库外**且制卡失败** | 服务端的**准确文案**（网络 / 正在生成中 / 合规拒绝各有措辞）| ⚠️ 看情形 |
///
/// 🔑 **前两者与第三者必须分开** —— 笼统说「请稍候再试」会让 web 用户
/// 一直重试一个**永远不会成功**的操作（见 `word_db_provider` 的 [WordDbLoad] 文档）。
///
/// 🆕 **2026-10-01（A2）**：第四行**原来是**「只说一句『词库里没有「X」』就结束」——
///    那是 A2 落地前的状态（`reader_screen` 的旧注释自己就写着「为 Phase 3 留了输入」）。
///    现在**词库外的词也能查**（在线制卡），所以那不再是一个终点，而是一个**分支**。
///
/// 🔑 提成顶层函数（而非 State 方法）：它不依赖任何 State 字段
/// （只用到 `context` 与 `ref`，两者都由调用处传入）→ 挂在 State 上没有理由。
Future<void> _lookupWord(
  BuildContext context,
  WidgetRef ref,
  String rawText, {
  /// 🔴 **「这篇」的 id —— 痕迹的命根子**（2026-10-02 真机定位的缺口）。
  ///
  /// 它一路传到 `lookup_event.article_id`，而读取侧是
  /// `lookupsForArticle(articleId) → WHERE le.article_id = ?1`。
  /// 两边只要有一边缺，痕迹就**恒为空** —— 且**不报任何错**（只是少画底色）。
  ///
  /// 📌 判据：**「写了 A 端」≠「B 端会显示」** —— 这条链跨了 3 个文件
  ///    （本文件 → `_writeBackLookup` → `recordLookup` → SQL），
  ///    任一处漏传都会静默失效。故 `tokens_verify` 里有**接线断言**守着。
  required int articleId,
}) async {
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
    // 🆕 A2：词库外的词 → **在线制卡**（2026-10-01）
    //
    // 产品原则：**仍不验证登录态**、**仍不打断阅读** ——
    // 失败时给准确提示，成功时弹与词库内词**同一个**浮层。
    await _lookupExternalWord(context, ref, text, articleId: articleId);
    return;
  }

  await LookupSheet.show(context, result);

  // 浮层已展示（或被用户关掉）→ 再做写入。
  // 🔑 传 `sentence: text` 不是语境 —— 本轮没有可靠的「所在句」来源，
  //    故**只记词本身**；`source_sentence` 留空比记一句错的好。
  //    （真实语境需从正文渲染层拿到句子边界，属后续增强。）
  unawaited(_writeBackLookup(
    ref,
    articleId: articleId,
    wordId: result.card.wordId,
    spelling: result.card.spelling,
  ));
}

// ─────────────────────────────────────────────────────────────
// 🆕 词库外查词 → 在线制卡（A2 · 2026-10-01）
// ─────────────────────────────────────────────────────────────

/// **词库外查词** —— 查端侧缓存，没有才联网制卡。
///
/// # 流程（照 L0 §九「用户查词流程」的未命中分支）
/// ```
/// word.db 未命中
///   → ① 查端侧缓存 `external_word_cache` ──命中──► 直接展示（0 次网络）
///   → ② 未命中 → 转圈 → POST /api/generate-card → 写缓存 → 展示
/// ```
///
/// # 🔴 五条**已定裁决**（白哥 2026-09-29 · `llm-card-online-path` §21.3 · 本次照做，不再问）
/// | # | 事项 | 定案 |
/// |---|---|---|
/// | 1 | 写入目标 | **`external_word_cache`**（端侧独立缓存表，不动 `word.db`）|
/// | 2 | 失败路径 | **直接报错 + 稍后重试**（**不**做 L0 原文的「降级卡」）|
/// | 3 | 等待 UI | **转圈** |
/// | 4 | 一致性 | 与预制**同一套** prompt / 契约 / 校验（服务端已如此）|
/// | 5 | 登录态 | **不验证** —— 划词是内容渲染的一部分（产品原则）|
///
/// # ⚠️ 不做「会话内内存缓存」（如实标注，**不是漏了**）
/// 我曾在实施方案里列过这一项，复核 L0 后**删掉**：L0 §九 只要求
/// 「查 `external_word_cache`」，**没有**内存缓存这一层。
/// 而端侧 SQLite 命中是**本地查询**（~40 µs 量级，见 `word_query_service` 的实测注释）
/// → 加一层内存只多出「生命周期 / 失效 / 上限」三个要维护的东西，收益极小。
/// 📌 判据：**别为「看起来会更快」加一层，除非能指出它挡掉了什么**。
Future<void> _lookupExternalWord(
  BuildContext context,
  WidgetRef ref,
  String text, {
  /// 见 `_lookupWord` 的同名参数：痕迹的唯一键，**必须一路传下去**。
  required int articleId,
}) async {
  // ── ① 端侧缓存（离线也能看 + 免一次网络往返）──
  String? raw;
  try {
    final db = await ref.read(userDbProvider.future);
    raw = await ExternalWordCacheRepository(db).contentOf(text);
  } catch (e) {
    // 读缓存失败 → **降级为「当作没有缓存」**（继续走联网），不是终止。
    // 🔑 缓存是**优化**：它坏了只该让这条路变慢，不该让它走不通。
    debugPrint('[lookup] 读词库外缓存失败（$text）：$e');
  }

  // ── ② 没有缓存 → 联网制卡（转圈）──
  if (raw == null) {
    raw = await _generateExternalCard(context, ref, text);
  }

  // ── ③ 展示 ──
  if (raw == null) return; // 失败路径已在 `_generateExternalCard` 里给过提示
  if (!context.mounted) return;

  final c = parseCardContent(raw);
  if (c.sections.isEmpty) {
    // 缓存里存了个空壳（理论上不该发生 —— 适配器写入前已校验 section 非空）；
    // 宁可说「不完整」也不要弹一张**没有任何内容**的卡。
    _hint(context, '「$text」的词卡不完整，请稍后重试');
    return;
  }

  // 🔑 与词库内词**共用同一个浮层**（`LookupSheet` 只读 spelling / ipa /
  //    definition / context 四样）→ 用户体验完全一致，没有「另一种卡」。
  await LookupSheet.show(
    context,
    WordLookupResult(
      card: WordCard(
        wordId: externalWordId(text),
        spelling: c.front.isEmpty ? text : c.front,
        ipa: c.ipa.isEmpty ? null : c.ipa,
        entryType: c.entryType.isEmpty ? null : c.entryType,
        sections: c.sections.map(WordSection.new).toList(growable: false),
      ),
      query: text,
    ),
  );

  // ── ④ 写入生词本（🔑 用**合成 id**，于是它立刻进复习队列）──
  //    与词库内词走**同一条**写回链（`_writeBackLookup`）——
  //    区别只有 `wordId` 的形态（`ext:brainstorm` vs `w005333`）。
  unawaited(_writeBackLookup(
    ref,
    articleId: articleId,
    wordId: externalWordId(text),
    spelling: text,
  ));
}

/// 联网制卡（含「转圈 → 关闭 → 提示」的时序）。
///
/// 返回**已转换的 `card.content` JSON**（`null` = 失败，且已提示过用户）。
///
/// # 🔴 时序要点：**先关转圈，再提示**
/// 若在浮层还开着时 `_hint`，SnackBar 会被 modal 遮住 —— 用户看到的是
/// 「转圈转完了，什么都没发生」。**静默失败**正是本项目一直在消灭的东西。
Future<String?> _generateExternalCard(
  BuildContext context,
  WidgetRef ref,
  String text,
) async {
  final closeLoading = _showGenerating(context, text);

  String? raw;
  String? error;

  try {
    // 🔑 device_id 是**可选**统计信号（服务端算 `distinct_user_count`，A3 回流门槛用）：
    //    取不到就传 `null` —— **不阻断制卡**（它是统计，不是功能前提）。
    final deviceId = await deviceIdOrNull(ref);
    final res = await ref.read(generateCardClientProvider).generate(
          text,
          deviceId: deviceId,
        );

    switch (res) {
      case GenerateCardReady():
        try {
          raw = toCardContent(
            res.card,
            spelling: text,
            contractVersion: res.contractVersion,
          );
          // 写缓存 —— ⚠️ 失败**不**影响本次展示（只在下次查同一个词时要重新联网）
          try {
            final db = await ref.read(userDbProvider.future);
            await ExternalWordCacheRepository(db).put(text, raw);
          } catch (e) {
            debugPrint('[lookup] 写词库外缓存失败（$text）：$e');
          }
        } on GeneratedCardException catch (e) {
          // 🔴 契约对不上 / 缺 definition → **显式失败**，不要静默弹一张空卡
          debugPrint('[lookup] 契约转换失败（$text）：$e');
          error = '「$text」的词卡格式异常，请稍后重试';
        }

      case GenerateCardInProgress():
        // 白哥裁决的「报错 + 稍后重试」—— 这不是故障，是「有人正在生成同一个词」
        error = '「$text」正在生成中，请稍后重试';

      case GenerateCardFailed(:final message):
        // 🔑 **不改写服务端的文案** —— 它已按情形给了**准确**的话
        //    （参数错 / 上游失败 / 合规拒绝各有措辞，见 `CardError::message()`）。
        //    端侧若自己拼一句笼统的「生成失败」，就把这些区别抹掉了。
        error = message;
    }
  } finally {
    await closeLoading();
  }

  if (error != null && context.mounted) {
    _hint(context, error);
  }
  return raw;
}

/// 弹一个「正在生成」的等待浮层，返回**关闭它的函数**。
///
/// # 为什么是「转圈」而不是骨架屏 / 进度条
/// 白哥 2026-09-29 已裁决（`llm-card-online-path` §21.3）。理由（我们的推断）：
/// 生成耗时**不可预估**（依赖上游 LLM），进度条会给出**假承诺**；
/// 而「转圈 + 一句话说明」是诚实的 —— 用户知道在等，也知道大概等多久。
///
/// # 🔴🔴 关闭时必须**等「对话框真的挂载」这个条件**，不能等一个猜的时长
///
/// `showDialog` 是异步的：它内部走 `Navigator.push`，而对话框要**下一次渲染**
/// 才会执行 `builder`。所以「请求返回」与「对话框出现」是两个独立的时序。
///
/// ⚠️ **曾经的写法是错的**（2026-10-02 修）：
/// ```dart
/// await Future<void>.delayed(Duration.zero);   // ❌ 只让出**事件循环**（Timer(0)，≈0 ms）
/// final c = dialogCtx;
/// if (c != null && c.mounted) Navigator.of(c).pop();   // c 为 null 时**静默什么都不做**
/// ```
/// `Duration.zero` **不保证渲染帧已经跑过**（帧间隔 ~16 ms）。于是：
/// **请求比一帧还快返回时**（断网 / 连接被拒 / DNS 失败，HTTP 可能几毫秒就失败）
/// → 关闭函数执行时 `builder` 还没跑、`dialogCtx` 仍是 `null` → **不 pop** →
/// 对话框**随后**才出现 → **永久留在屏幕上**。
///
/// 🔴 后果被两个设置放大到「必须杀 App」：
/// · `barrierDismissible: false`（生成期间不许点掉等待）
/// · 本项目**仅 iOS** —— 没有 Android 的系统返回键可退
///
/// ✅ **修法**：等 `builder` **真正执行过**这个事实（`Completer`），
///    并加**有界超时**兜底（万一 builder 因故永不运行，也不能把调用方挂死）。
///    🔑 一般化：`等一个猜的时长` ＜ `等一个条件成立`。
///    （这与 flaky test 的经典修法同一条：**永远不要 sleep，要等状态**。）
///
/// 📌 **这一类缺陷文本断言验不到** —— 代码「看起来」是对的（有 null 检查、有延迟），
///    只有**构造极端路径真跑**才暴露。所以它的最终防线是
///    `docs/review/a2-device-verification-checklist-2026-10-02.md` §2b
///    （**断网**下划一个没查过的词库外词 → 转圈必须消失）。
///
/// ⚠️ 本函数**是同步的**（返回「关闭函数」而不是「Future<关闭函数>」）——
///    写成 `async` 会让调用处拿到 `Future` 却当函数调，类型不符（我初稿正是这么写的）。
Future<void> Function() _showGenerating(BuildContext context, String word) {
  BuildContext? dialogCtx;
  // 「builder 已执行」的信号 —— 关闭函数等的就是它
  final dialogReady = Completer<void>();
  void markReady() {
    if (!dialogReady.isCompleted) dialogReady.complete();
  }

  unawaited(showDialog<void>(
    context: context,
    // 🔴 不可点外部关闭：生成期间用户不该能「点掉等待」——
    //    那会留下「有个请求还在飞，但界面已回到阅读」的模糊状态。
    barrierDismissible: false,
    // 🔑 与 `LookupSheet` 同一轻遮罩（12% 黑）：等待**不该像跳到了另一个界面**
    barrierColor: const Color(0x1F000000),
    builder: (c) {
      dialogCtx = c;
      markReady(); // ← 到这一刻，「关闭它」才是安全的
      return _GeneratingDialog(word: word);
    },
  ).whenComplete(() {
    // 兜底：对话框因别的原因结束（页面已 pop / 被系统关掉）→ 也要解除等待，
    // 否则关闭函数会一直挂着，调用方那一步就卡住了。
    markReady();
  }));

  return () async {
    // 🔴 等**条件**（builder 跑过），不是等时长。
    // ⚠️ 超时是**兜底而非正常路径**：3 秒内 builder 都没跑，
    //    说明对话框根本没弹出来（如页面已 pop）→ 此时不该再等、也不该 pop 别的东西。
    await dialogReady.future
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    final c = dialogCtx;
    if (c != null && c.mounted) Navigator.of(c).pop();
  };
}

/// 「正在生成」等待浮层（详见 `_showGenerating` 的说明）。
class _GeneratingDialog extends StatelessWidget {
  const _GeneratingDialog({required this.word});

  final String word;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          decoration: BoxDecoration(
            color: Color(t.card.argb32),
            borderRadius: BorderRadius.circular(t.clay.radius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(t.accent.argb32),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '正在制作「$word」',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: Color(t.ink.argb32),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                // 🔑 **给一个时间预期**（不是精确承诺）—— 否则用户会在第 3 秒就放弃。
                '第一次遇到这个词需要现场生成，约 5–10 秒',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 12,
                  height: 1.5,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 查词写入 —— **失败只记日志，绝不打扰用户**（见调用处的说明）。
///
/// 分工（照 v1 §九 的分支）：
///   ① `lookup_event` —— **每次都记**（命中/未命中都记 · 白哥定 Q2）
///   ② `user_word` —— **只在有 `wordId` 时**写
///   ③ `card_review_state` —— 让新词**立刻进复习队列**（v1 §八 的
///      「INSERT user_word + card_review_state」是同一动作的两半）
///
/// # 🆕 `wordId` 的三种来源（2026-10-01 · A2）
/// | 情形 | `wordId` | 说明 |
/// |---|---|---|
/// | 命中词库 | `w0xxxxx` | 真主键 |
/// | **词库外**（在线制卡成功） | **`ext:<拼写>`** | 合成 id，见 `external_word_id.dart` |
/// | 彻底取不到卡 | `null` | 只写 `lookup_event`（`word_id` 留 NULL），到此为止 |
///
/// ⚠️ **`lookup_event.word_id` 的含义随之变化**：原来是「命中才写、未命中留 NULL」，
///    现在多了一种「**词库外但有卡**」→ 写 `ext:` 合成 id。
///    三种都仍能回答它原本要回答的问题（「查过哪些词」「当时那句是什么」）。
///
/// ⚠️ 三者**不是事务**：任一步失败，前面的已经写入 ——
///    这是**有意**的（可接受的降级）。理由：
///    · 查词写入是「尽力而为」的旁路，不该因为复习调度写失败而丢掉落词记录
///    · 三张表各自独立可用（复习页只看 `card_review_state`、生词本只看 `user_word`）
///    → 若将来要做严格一致，才需要包事务；**当前没有这个必要**。
Future<void> _writeBackLookup(
  WidgetRef ref, {
  /// 🔴 **`required`，不是可选** —— 这是本次真机事故的修法（2026-10-02）。
  ///
  /// 它曾经**不在签名里**，于是两个调用点也都没传 ⇒ `lookup_event.article_id`
  /// 恒为 `NULL` ⇒ 阅读页 `WHERE le.article_id = ?1` 永不匹配 ⇒ **痕迹恒不显示** ——
  /// 而且**没有任何报错**（只是少画底色），所以躺了很久才被发现。
  ///
  /// 🔑 用 `required` 而**不是**「默认 null + 祈祷调用方记得传」：
  ///    ⇒ 漏传会在**编译期**就失败，而不是在真机上表现为「某个功能悄悄没了」。
  ///    📌 判据：**能用类型系统保证的，就不要靠自觉**（同 `CollocationItem.zh`
  ///       删死判空那次的理由 —— 「编译器强制处理」比「运行时守卫」更早）。
  required int articleId,
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
    await repo.recordLookup(
      articleId: articleId,
      wordId: wordId,
      spelling: spelling,
    );

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
/// ⚠️ **已知边界（待办 · 现状已随 A2 变化）**：长按后**拖动手柄**会把相邻标点带进来
///    （`vertical,`）——
///    · 🆕 2026-10-01 前：会提示「词库里没有『vertical,』」
///    · 🆕 2026-10-01 后（A2）：会**送去在线制卡** —— 服务端的 `validate_spelling`
///      会以 400 拒掉带标点的输入（`bad!word` 之类），用户看到的是**参数错误**。
///    ⇒ 体验上仍是「不理想但不出错」，正解没变：查询层加**「精确 → 剥标点」两段查**。
///      那要同步 `verify_word_query`，**不在本轮**。
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
/// 「以下是摘要，不是全文」的说明条。
///
/// # 🔑 为什么必须显式说明（而不是「有内容就显示」）
/// 后端抓正文是**只试一次**的（`content_pool.body_attempted_at` 的语义），
/// 所以「只有摘要」这个状态**不会自愈** —— 用户下次打开还是它。
/// 不说明的话，用户会把「摘要戛然而止」理解成「文章写完了/App 内容不全」。
///
/// 🔴 这与「半句话」事故是**同一类问题的两面**：
/// · 事故：把**源站报错**当正文渲染（后端已过滤该脏数据 + 本层不再兜底当正文）
/// · 本件：把**摘要**当正文渲染 → 会误导，所以要么明说、要么不显示
/// 📌 判据：**降级可以，但降级必须可见**（静默降级 = 用户以为拿到了完整内容）。
class _SummaryOnlyBanner extends StatelessWidget {
  const _SummaryOnlyBanner({required this.tokens});

  final CoEvoTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Color(tokens.card.argb32),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Color(tokens.line.argb32)),
      ),
      child: Text(
        '正文还没取到，以下是摘要。',
        style: TextStyle(
          fontFamily: CoFonts.latinSerif,
          fontSize: 12.5,
          height: 1.45,
          color: Color(tokens.ink3.argb32),
        ),
      ),
    );
  }
}

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
