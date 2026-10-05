import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../providers/feed_provider.dart';
import '../services/article_text.dart';
import '../models/article.dart';
import '../providers/bookmark_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../providers/word_db_provider.dart';
import '../services/article_read_repository.dart';
import '../services/reading_completion.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_button.dart';
import '../widgets/trace_markdown.dart';
import '../widgets/word_lookup_selection.dart';

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
/// 需要构建之外的存活状态（滚动控制器 / 阅读进度计时器 等）。
/// ⚠️ **划词的防抖已不在本页** —— 2026-10-05 抽到 `WordLookupSelection`，
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
    // 若只被 `lookupWord` 里的 `ref.read` 消费，落盘就要等到
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
                // 🔑 划词手势已抽成公共组件（`WordLookupSelection`）——
                //    与书库阅读页**同一份实现**（判据：一处定义）。
                //    防抖 / 菜单屏蔽 / `_cleanPicked` 都在那里，本页只负责「包哪块」。
                child: WordLookupSelection(
                  // 🔴 信息流页**必传**（非空 int）—— 它是「痕迹」的唯一键：
                  //    `lookup_event.article_id` 为空 ⇒ 阅读页永远查不到
                  //    「本文查过的词」⇒ 痕迹恒不显示。
                  //    ⚠️ 书库页传 `null`（书不是「文章」），那是**有意不记痕迹**。
                  articleId: widget.articleId,
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
