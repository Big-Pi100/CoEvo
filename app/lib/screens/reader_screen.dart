import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';
import '../providers/feed_provider.dart';
import '../services/article_text.dart';
import '../services/markdown_unescape.dart';
import '../models/article.dart';
import '../providers/bookmark_provider.dart';
import '../providers/highlight_provider.dart';
import '../providers/reading_settings_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../providers/word_db_provider.dart';
import '../services/article_read_repository.dart';
import '../services/highlight_repository.dart';
import '../services/reading_completion.dart';
import '../services/tts_service.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/bookmark_button.dart';
import '../widgets/reading_settings_panel.dart';
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
  /// 🔴 **2026-10-06：从「硬编码常量」改为「用户可调状态」** ——
  ///    值现在来自 `readingSettingsProvider`（规格链见 `services/reading_settings.dart`）。
  ///    本页**不再持有**字号常量（同一件事两处口径 ⇒ 必然漂移）。
  ///
  /// ⚠️ 它**不进主题 token**（理由不变）：字号是**用户偏好**，行高才是**主题相关**
  ///    （`readLineHeight` 三档 1.82/1.74/1.84 —— 不同底色下人眼舒适度不同）。
  ///    一个是「设置」，一个是「主题」—— 混进同一层会分不清谁覆盖谁。

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

    // 🔴 离开页面就停朗读 —— **不跨页**（白哥 2026-10-06 定）。
    //
    // 理由（与 `book_reader_screen` 同一条）：退出去了声音还在念，
    // 用户回到列表页**找不到在哪关** —— 那是最典型的「失控感」。
    // 书库已有先例（`book_reader_screen.dart` 的 dispose），两处**同一判据**。
    //
    // ⚠️ 无条件 stop（不判断「是否本页启动的」）—— 与书库一致。
    //    刻意如此：本页停的是**全局唯一**的播放流，若这里有条件地停，
    //    就会出现「退出后残留播放」的路径，而那种 bug 只在真机上偶发。
    ref.read(ttsServiceProvider).stop();

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

    // 阅读器设置（字号 + 痕迹开关）—— 🆕 2026-10-06（spec §5.1 面板）
    final rs = ref.watch(readingSettingsProvider);

    // ── 朗读（整篇）· 2026-10-06 ──
    //
    // 🔑 判据与书库**完全同一个** `isSpeaking(body)`（不是另写一套「是否在播」）。
    //    `watch` 是必需的：TTS 状态变了要重建，否则图标永远停在「空闲」。
    //
    // 🔴 传的是 [body] **原文**（Markdown），**不是**「已清好的纯文本」：
    //    ① 清洗发生在 `speakLong` 内部（`_cleanText` → `speechTextFromMarkdown`）
    //       ⇒ **一处权威**，本页不重复实现一遍；
    //    ② `isSpeaking()` 判的是「字符串相等」，两边传**同一个对象**才便宜
    //       （若这里现算纯文本，每次 build 都要重扫整篇长正文，
    //        且与内部存的不是同一实例 ⇒ 变成逐字符比较）。
    //    🔴 所以「`_cleanText` 委托出去」是**这个按钮成立的前提**：
    //       `speechTextFromMarkdown` 里那条「链接只去 URL、保留文字」的规则
    //       正是本页正文必需的（NPR 正文里 `### [Law](https://…)` 很常见）。
    final tts = ref.watch(ttsServiceProvider);
    final speaking = tts.isSpeaking(body);

    // 🔴 设置里关了朗读 → **不渲染**朗读键（与 `widgets/speak_button.dart` 同一判据）：
    //    「**静默失败 + 无出口」比「报错」更糟** —— 留着它，用户点了没反应，
    //    只会以为「App 坏了」。⚠️ 这是扫尾时补上的：第一版漏了这条，
    //    而词卡那 5 个喇叭**早就遵守了**（同族功能的既有约定，新入口必须也遵守）。
    final ttsEnabled = ref.watch(ttsEnabledProvider);

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
              // 「这篇」是否正在朗读 —— 判据与书库**同一个** `isSpeaking()`。
              speaking: speaking,
              onToggleSpeech: () => _toggleSpeech(body),
              // 关了朗读 ⇒ 整个键不渲染（不是「渲染成禁用态」）
              showSpeak: ttsEnabled,
              // 🆕 阅读设置面板（字号 / 底色 / 痕迹 / 语速）
              onOpenSettings: () => showReadingSettingsPanel(context),
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
                  // 🆕 2026-10-06：**单击正文唤出阅读设置面板**（spec §5.1 原定交互）。
                  //    ⚠️ 只在「无选区」时生效 —— 有选区时这一次点击让给「清空选区」
                  //       （否则用户取消不掉选区，见 `onTap` 的长说明）。
                  onTap: () => showReadingSettingsPanel(context),
                  // 🆕 2026-10-07 划线来源 —— 传了它，菜单里才出现「划线」项。
                  //    ⚠️ `plainText` 用**渲染用的那一份**（`body`）。
                  //    文章正文是 Markdown ⇒ 定位出的 offset 落在 Markdown 空间里；
                  //    这是**如实接受的近似**（复习内容仍然正确 —— 划线存的是全文）。
                  highlightSource: HighlightSource(
                    type: HighlightSourceType.article,
                    sourceId: '${widget.articleId}',
                    // 🔴🔴 `plainText` 必须是**用户真正看到的那一份正文**（2026-10-08 修）
                    //
                    // 用户选中并划线的文本来自**渲染后**的正文，而渲染前
                    // `TraceMarkdown` 会用 `unescapeRedundantMarkdown` 删掉后端
                    // 过度转义的反斜杠（`\.` → `.`）⇒ 文本**变短**。
                    // 若这里传**未 unescape** 的 `body`，`locateSelection` 的
                    // 朴素 `indexOf` 就会**找不到** ⇒ `start = -1` ⇒
                    // `highlightRangesOf` 过滤掉（「只复习，不高亮」）⇒
                    // **划线存下来了、笔记页也有，但正文不画线**（且不报错）。
                    //
                    // 📊 探针实测（6 篇真实正文 · 72 句）：未 unescape ⇒ **4%** 成功；
                    //    已 unescape ⇒ **100%**。
                    //
                    // 🔑 用的是与 `trace_markdown.dart` **同一个函数**（口径一处权威）——
                    //    断言 `verify_highlight_locate` 守着「两处必须是同一个」。
                    plainText: unescapeRedundantMarkdown(markdown: body),
                    // 🆕 2026-10-08：译文浮层顶栏的「来自 XXX」。
                    //    🔑 用**文章标题**（用户认得出「我在读哪篇」），
                    //    不是 id —— 把 `articleId` 显示出来等于给用户看一串数字。
                    title: item.title,
                  ),
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
                        // 🔑 字号来自用户设置（已 clamp 15–24）
                        bodyFontSize: rs.fontSize.toDouble(),
                        // 🆕 痕迹开关（面板内控制；值已由 provider 钳过）
                        traceEnabled: rs.traceEnabled,
                        // 🆕 2026-10-07 本文的**划线区间** —— 正文里画下划线。
                        //
                        // 🔑 用 `articleId`（**转成字符串**）而不是别的键：
                        //    必须与 `WordLookupSelection.highlightSource.sourceId`
                        //    **逐字一致**（那里写的是 `'${widget.articleId}'`），
                        //    否则「划完线正文不出现下划线」—— 且**不报错**。
                        //
                        // ⚠️ `chapterIdx` 不传（文章是单页，与入库时一致）。
                        //
                        // 🔑 失败 / 加载中 ⇒ 空列表 ⇒ 正文照常渲染（只是没下划线）——
                        //    「不把易失败的外部依赖放在内容渲染的前置条件上」。
                        highlights: highlightRangesOf(
                          ref.watch(highlightsForSourceProvider(
                            HighlightSourceKey(
                              type: HighlightSourceType.article,
                              sourceId: '${widget.articleId}',
                            ),
                          )),
                        ),
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

  /// 点朗读按钮：正在读这篇 → **停**；否则 → **读整篇**。
  ///
  /// # 为什么用 [TtsService.speakLong] 而不是 [TtsService.togglePlay]
  ///
  /// `togglePlay` 是**短文本**用的（词卡 / 试听）：它一次 `speak()` 交出全文。
  /// 而文章正文**远超平台单次朗读上限**（Android `getMaxSpeechInputLength()` ≈ 4000 字符）
  /// ⇒ 交上去会被**静默拒收**：没有报错、没有声音。
  ///
  /// 🔴 这不是推测 —— 书库「整章朗读」踩过同一个坑（真机反馈「没声音」），
  ///    修法就是改调 `speakLong`（分段 + 依次播放）。两处**同一判据**。
  ///
  /// # 为什么停止用 `stop()` 而不是再点一次 `togglePlay`
  ///
  /// 长文本的语义是「**读完整篇**」，不是「再点一次切歌」——
  /// 用户在长文朗读中点第二次，想的是「别念了」，不是「从头再念一遍」。
  /// （`speakLong` 的文档里也写了这一条。）
  ///
  /// # 为什么读 [body] 原文
  ///
  /// 清洗在 `speakLong` 内部（`_cleanText`）—— 本页**不预先清洗**，
  /// 否则就变成「同一件事两处口径」（见 `_buildReader` 里的说明）。
  ///
  /// ⚠️ 点击时**重新读一次**当前状态（`ref.read`），不用 build 时的 `speaking` 快照：
  ///    朗读状态可能在「渲染完这一帧」到「用户点上去」之间变了
  ///    （如朗读自然读完 → 那时应按「开始播」而不是「停止」）。
  void _toggleSpeech(String body) {
    final tts = ref.read(ttsServiceProvider);
    if (tts.isSpeaking(body)) {
      tts.stop();
    } else {
      tts.speakLong(body);
    }
  }
}

/// 顶部栏 —— 设计稿 `.rd-bar`：**返回 / 分类 / 朗读 / 书签**四元素。
///
/// 设计稿的原话：「书签是「**动作**」不是「**显示元素**」—— 不占版面、不干扰阅读，
/// 也不违反「阅读界面保持单纯」」。
///
/// # 🆕 朗读键（2026-10-06）—— 位置与形态由白哥定
///
/// 依据 `docs/design/article-tts-entry-2026-10-06.html`：
/// · **位置 = A（顶栏右侧）** —— 与「其他页面的 title 按钮都靠右」一致；
///   且**不违反 spec §5.1**（「阅读器底部无操作栏」）⇒ 不选底部栏方案。
/// · **形态 = 纯图标** —— 顶栏已有返回 / 分类 / 收藏，再加「朗读」两个字会把
///   分类挤成省略号。
/// · **排在收藏左边** —— 收藏仍是最右（白哥 2026-10-05 定的规则不变）。
///
/// 🔴 **为什么它不用粘土（与书签不同）**：本页的注释写明「**顶部栏的书签按钮是
///    唯一的粘土**」，那是**有意保留**的一条（spec §八「阅读界面零粘土」的边界）。
///    再加一个粘土按钮会把那条说明变成假的（两个就不叫「唯一」）。
///    设计稿里它本来就是**平面**（`.icon-btn` 无底色，只有播放中一层淡朱砂底）。
class _ReaderBar extends StatelessWidget {
  const _ReaderBar({
    required this.tokens,
    required this.category,
    required this.bookmarked,
    required this.onToggleBookmark,
    required this.speaking,
    required this.onToggleSpeech,
    required this.showSpeak,
    required this.onOpenSettings,
  });

  final CoEvoTokens tokens;
  final String category;
  final bool bookmarked;
  final VoidCallback? onToggleBookmark;

  /// 整篇是否正在朗读（判据 = `TtsService.isSpeaking(body)`）。
  final bool speaking;

  /// 点朗读键（在播 → 停；没播 → 读整篇）。`null` 不可点。
  final VoidCallback? onToggleSpeech;

  /// **是否渲染**朗读键（`false` = 用户已关朗读）。
  ///
  /// 🔑 与 [onToggleSpeech] 分开是刻意的：`null` 在那里的语义是「不可点」，
  ///    而这里的语义是「**不存在**」—— 两者混用会让后来人分不清
  ///    （「禁用态」与「不渲染」是**两种不同的产品决策**）。
  final bool showSpeak;

  /// 🆕 打开阅读设置面板（2026-10-06）。
  ///
  /// # ✅ 入口有两个（**同一动作**，不是两种含义）
  ///
  /// | 入口 | 依据 | 状态 |
  /// |---|---|---|
  /// | **单击正文** | spec §5.1「单击屏幕中央唤出底部面板」 | ✅ 本轮实现（无选区时生效）|
  /// | **顶栏键** | 无（本项目的补充）| ✅ 保留 —— 见下 |
  ///
  /// # 🔑 为什么**两个都留**（而不是"有了单击就删顶栏键"）
  ///
  /// 1. **单击那条依赖手势竞技场**：`onTap` 放在 `SelectionArea` 的 child 里
  ///    （比内层 `SelectableRegion` 深 ⇒ 先加入竞技场 ⇒ 赢），这是**从 SDK 源码推断**的；
  ///    推理自洽但**本机验不了**（需真机）。留一个顶栏键 ⇒ **万一手势不生效，仍有入口**
  ///    （而不是"功能在、用户摸不到"那种最难查的状态）。
  /// 2. 二者**不冲突**：顶栏在 `SafeArea` 顶部、正文在滚动区 ⇒ 点击区域不重叠。
  /// 3. 无障碍角度：可点区域比"只能点正文"更好命中。
  ///
  /// ⚠️ 这与「**同一件事只能一处权威**」不矛盾 —— 那条讲的是**状态/口径**
  ///    （字号只有一份、痕迹只有一个开关），而这里是**入口**。
  ///    先例：恢复购买就有两处入口（订阅页 + 我的页），同一个 `iapService`。
  ///
  /// ⏳ **待真机确认**：单击是否真的生效（若生效，顶栏键可考虑去掉以省空间）。
  final VoidCallback onOpenSettings;

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
          // 阅读设置 —— **双入口之一**（另一个是「单击正文」，spec §5.1 原定）。
          // 见 [onOpenSettings] 的说明：为什么要留两个。
          InkWell(
            onTap: onOpenSettings,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Icon(
                Icons.format_size,
                size: 20,
                color: Color(tokens.ink2.argb32),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 朗读（整篇）—— 🔴 排在**收藏左边**（收藏仍最右）
          // 关了朗读时整段消失（不留「点了没反应」的键，见 [showSpeak]）
          if (showSpeak) ...[
            _SpeakButton(speaking: speaking, onPressed: onToggleSpeech),
            const SizedBox(width: 8),
          ],
          BookmarkButton(
            bookmarked: bookmarked,
            onPressed: onToggleBookmark,
          ),
        ],
      ),
    );
  }
}

/// 朗读键（顶栏）—— **纯图标 · 平面**（设计稿 `.icon-btn`）。
///
/// | 状态 | 图标 | 颜色 |
/// |---|---|---|
/// | 空闲 | `play_circle_outline` | `ink2`（顶栏常态色）|
/// | 播放中（含准备中）| `stop_circle_outlined` | `accent`（朱砂 = 「正在发生」）|
///
/// 🔑 判据来自 `TtsService.isSpeaking()` —— **与书库朗读键同一套**
///    （含「`loading` 也算在播」：首次朗读有准备时间，那段时间不能退回空闲态，
///      否则图标会「空闲 → 播放中」闪一下）。
///
/// ⚠️ **不用 `IconButton`**：它自带 48×48 的 Material 热区与 splash，
///    会把顶栏行高从 39（返回键决定的）撑到 48 —— 视觉上「顶部栏变高了」。
///    本组件用 `InkWell` + `Padding`，热区够大但**不改变行高**（与返回键同一手法）。
///
/// ⚠️ **热区说明（如实标注）**：图标 22 + 四周 7/6 ⇒ 视觉块约 36×36。
///    未达 44 的触达标准 —— 与同一行的书签键（30×30，设计稿定的）**同级**。
///    顶栏三个按钮挤在一行，单独把朗读键撑到 44 会让它比书签更醒目（视觉失衡）。
///    📌 若真机反馈难点，正解是**三个一起放大**，而不是只放这一个。
class _SpeakButton extends StatelessWidget {
  const _SpeakButton({required this.speaking, required this.onPressed});

  final bool speaking;
  final VoidCallback? onPressed;

  /// 🔑 22 = 书库朗读键的同一档（`book_reader_screen` 的 `size: 22`）——
  ///    两个入口读的是同一件事，图标大小不该有第二套口径。
  static const double _iconSize = 22;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        child: Icon(
          speaking ? Icons.stop_circle_outlined : Icons.play_circle_outline,
          size: _iconSize,
          color: Color(speaking ? t.accent.argb32 : t.ink2.argb32),
        ),
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
