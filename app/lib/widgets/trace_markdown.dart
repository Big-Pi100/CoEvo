import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/article.dart';
import '../services/highlight_span.dart' show HighlightRange;
import '../services/markdown_unescape.dart';
import '../services/trace_markdown_source.dart';
import '../theme/coevo_tokens.dart';
import 'trace_locator.dart';
import 'trace_style.dart';

/// 正文渲染（Markdown）—— **痕迹** 与 **Markdown 语法** 同时工作。
///
/// # 背景（2026-10-02 · S4）
/// 后端正文提取已换成 `dom_smoothie`（见 `content-pipeline-rebuild-plan`），
/// 产出从「压平的纯文本」变成 **Markdown**（` ``` ` 围栏、`##`、`**粗体**`、
/// 反引号内联代码）。端侧必须跟着换渲染器 —— 否则：
/// · 代码块的多行/缩进**仍会被压平**（纯文本渲染按段落折叠换行）
/// · ``` / `##` / `**` 会作为**普通文字**显示出来
///
/// # 🔴 本文件存在的唯一理由：痕迹
/// 直接 `GptMarkdown(text)` 一行就能渲染 —— 但会**丢掉痕迹**（已查词高亮）。
///
/// 原因是**结构冲突**：
/// | | 纯文本渲染（旧） | Markdown 渲染（新） |
/// |---|---|---|
/// | 痕迹怎么表达 | 词 → **字符区间** → 逐 span 上色 | 词 → **源里插标记** → `InlinePattern` 渲染 |
/// | 字符位置 | 稳定 | 🔴 解析后偏移全变（语法标记被吃掉）|
///
/// ⇒ 本文件做三件事：
/// 1. [`pickedTraceTiers`] —— 判定「哪些词该标、哪一档」（**与旧路径共用判据**）
/// 2. [`injectTraceMarkers`] —— 把词包成控制字符标记（跳过代码块/URL）
/// 3. `GptMarkdown(inlinePatterns: …)` —— 让成熟包把标记渲染成带痕迹样式的 span
///
/// 🔑 **渲染本身仍完全走成熟包**（`plusparse` 新管线 + 所有内置组件）——
///    我们只提供「一个自定义 inline 语法」，这正是 `InlinePattern` 的设计用途。
///
/// # 为什么用 `GptMarkdown` 而不是 `SliverGptMarkdown`
/// 两者 1.3.0 都有。选**非 sliver** 版是为了**保持现有页面结构**：
/// 阅读页是 `SingleChildScrollView` + `Column`，且 `_scroll` controller 参与
/// 「读完」判定（读 `position.extentAfter`）—— 改成 sliver 要重排整个页面，
/// 而收益（长文懒渲染）**目前还没有被观察到需要**。
/// 📌 与项目既有判据一致：**不做没依据的优化** —— 收益未被观察到就不做。
/// ⚠️ 若真机实测长文掉帧 → 换 `SliverGptMarkdown` 即可（两个 API 几乎一致），
///    届时把 `SingleChildScrollView` 换成 `CustomScrollView`。
///
/// # ⚠️ 待真机目视的三项（文本断言验不到「好看」）
/// 1. **代码块底色/间距**是否与墨/格/夜三档协调（现取 `sunken` 底 + `line` 边）
/// 2. **内联代码 chip** 的观感（现取 `sunken` 底 + 4px 圆角）
/// 3. 标题（`##`）层级是否与设计稿一致
class TraceMarkdown extends StatelessWidget {
  const TraceMarkdown({
    super.key,
    required this.markdown,
    required this.lookups,
    required this.tokens,
    required this.bodyFontSize,
    this.traceEnabled = true,
    this.highlights = const [],
  });

  /// 正文（**Markdown 形态**）。
  final String markdown;

  /// 已查词（痕迹的数据源）。
  final List<ArticleLookup> lookups;

  /// 设计 token（墨/格/夜三档）。
  final CoEvoTokens tokens;

  /// 正文字号（由调用方给 —— 阅读器有「字号」概念，不在 token 层）。
  final double bodyFontSize;

  /// 🆕 痕迹开关（spec §5.1：**面板内**、默认开启 · 2026-10-06 接线）。
  ///
  /// 🔑 关掉时**不注入标记**（而不是「把样式改透明」）—— 两者对外观等价，
  ///    但「不注入」还省一次全文扫描，且天然满足验收要求
  ///    「**已掌握的痕迹与普通文字逐像素一致**」
  ///    （改透明可能残留一点颜色/间距，那是「看不见但不一致」）。
  ///
  /// ⚠️ 默认 `true` 是**刻意的**：本组件的既有调用方行为逐字不变
  ///    （同 `pick_body_candidates` 的 `refetch_existing` 默认 `false` 那一族原则——
  ///     加参数时让**旧行为成为默认值**）。
  final bool traceEnabled;

  /// 🆕 **划线**区间（在 [`markdown`] 里的字符区间 · 2026-10-07）。
  ///
  /// # 🔴 为什么是「区间」而不是「文本」
  ///
  /// 痕迹只能按**词**匹配（它只有「哪些词已查过」，没有位置）；
  /// 而划线是用户**拖动选中**的 ⇒ `highlight` 表里存了 `start/end`，
  /// 且这些偏移**就是这份 `markdown` 的偏移**（`reader_screen` 传的
  /// `plainText` 与 `markdown` 是**同一个字符串**）。
  /// ⇒ 用偏移比用文本匹配**更准**（文本匹配会被 Markdown 语法挡掉，
  ///   例：划中的文字在源里是 `**best**`，按文本找不到）。
  ///
  /// # ⚠️ 偏移有效的**前提是注入顺序**（见 [build] 里的三步）
  ///
  /// `unescapeRedundantMarkdown` 会**删反斜杠** ⇒ 它之后偏移就全错位了。
  /// ⇒ 划线必须在 unescape **之前**注入。改顺序 = 划线画到别处（且**不报错**）。
  ///
  /// # 默认空 ⇒ 既有调用方行为逐字不变
  ///
  /// 空列表时 [injectHighlightMarkers] 直接返回原文，`build` 里也不多做一次扫描
  /// （**逐字**走原路径）—— 同 [traceEnabled] 那条原则。
  ///
  /// ⚠️ 目前**只有信息流阅读页**用（书架页是纯 `Text.rich`，不走 Markdown）。
  ///
  /// 🔑 类型用 [`HighlightRange`]（而不是裸 record）—— 让它与
  ///    `highlightRangesOf(provider)` 的产出**同型** ⇒ 调用方**零转换**。
  ///    而 `injectHighlightMarkers` 收的是 `(start, end)` record（那个文件
  ///    要保持「零 import」）⇒ 转换发生在 [build] 里那一行（唯一一处）。
  ///    📌 判据：**类型转换只写一处** —— 写两处（调用方一次、这里一次）迟早在
  ///       一边改了字段名而另一边没改（且 Dart 会静默用上 record 的**位置**匹配）。
  final List<HighlightRange> highlights;

  @override
  Widget build(BuildContext context) {
    // ① 判定：哪些词该标、哪一档（与纯文本路径**同一份判据**）
    //
    // 🔑 关了痕迹 ⇒ 传**空 tiers**（而不是跳过注入那一步）：
    //    这样下面所有逻辑走**同一条路径**，只是「没有词要标」——
    //    少一个分支就少一处可能漂移的地方（判据：**能少一个分支就少一个**）。
    final tiers = traceEnabled
        ? pickedTraceTiers(lookups: lookups, tokens: tokens.trace)
        : const <String, int>{};

    // ① 🔴 规范化：**先把正文统一成「用户真正看到的那一份」**（2026-10-08 修复）
    //
    // # 为什么必须**最先**做（这是一个真 bug 的修复，不是整理）
    //
    // 产出侧（后端 `dom_smoothie`）按 CommonMark **过度**转义：`DELETE\.` · `\"QUERY\"` ·
    // `\(66\.4%\)`（句点/引号/括号本来都不需要转）。而消费侧（`gpt_markdown` 1.3.0）
    // 只反转义 `\|` ⇒ 其余 `\X` 原样显示 ⇒ 必须先删掉，否则用户看到满屏反斜杠。
    //
    // 🔴 但「删反斜杠」会**改变字符数** ⇒ 于是过去存在**两套坐标系**：
    //    · 用户看到并选中的文本 = **已 unescape** 的
    //    · 而拿给「划线定位」的 `plainText` = **未 unescape 的原文**
    //    ⇒ `locateSelection` 是朴素 `indexOf` ⇒ **找不到** ⇒ `start = -1`
    //    ⇒ `highlightRangesOf` 按设计过滤掉它（「只复习，不高亮」）
    //    ⇒ **划线存下来了、笔记页也有，但正文不画线，且不报错**。
    //
    // 📊 探针实测（`app/tool/highlight_locate_probe.dart` · 6 篇真实正文 · 72 句）：
    //
    //    | 口径 | 定位成功率 |
    //    |---|---|
    //    | `plainText` = 未 unescape 原文（修复前）| **3/72 = 4%** |
    //    | `plainText` = 已 unescape 正文（修复后）| **72/72 = 100%** |
    //
    //    ⇒ 修复前**96% 的划线都静默失效**（用户只会觉得「划了没反应」）。
    //
    // ✅ 修法：**三方口径统一到这一份 `canonical`** ——
    //    ① 用户定位用的文本（`reader_screen` 传 `HighlightSource.plainText` 时**用同一个函数**）
    //    ② 划线 offset 的坐标系 ③ 渲染的输入。
    //    📌 判据：**「同一件事的口径只能一处权威」** —— 有两套坐标系就必然有静默失效，
    //       而且**比例高达 96%**（因为英文正文里 `.` 几乎到处都是）。
    //
    // ⚠️ 书页（`book_reader_screen`）**不**走这里：它渲染纯文本、不经过 unescape，
    //    所以它的 `plainText` 也**不该** unescape（同一页内自洽即可 —— 见断言）。
    final canonical = unescapeRedundantMarkdown(markdown: markdown);

    // ② 划线：**按字符区间**注入（offset 落在 `canonical` 上 ⇒ 与用户定位**同坐标系**）
    //
    // 🔄 与修复前的差别只有一处：`unescape` 从「划线**之后**」挪到了「**最前**」。
    //    过去划线 offset 基于旧坐标系 ⇒ 与用户定位的坐标系不一致 ⇒ 就是上面那个 bug。
    //
    // ⚠️ 「划线先、痕迹后」的顺序**不变**：痕迹会**跳过**已有划线标记
    //    （划过的片段里那些已查词不再有底色，见 `injectTraceMarkers` ④）。
    // 🔑 空列表时**逐字**走原路径（不多一次扫描、不产生任何差异）。
    final highlighted = highlights.isEmpty
        ? canonical
        : injectHighlightMarkers(
            markdown: canonical,
            // 🔑 **唯一一处**类型转换（`HighlightRange` → record）—— 见 [highlights] 的说明
            ranges: [
              for (final h in highlights) (start: h.start, end: h.end),
            ],
          );

    // ③ 痕迹：把词包成控制字符标记（跳过代码块 / 行内代码 / 链接 URL / **已有划线标记**）
    final marked = injectTraceMarkers(markdown: highlighted, tiers: tiers);

    final base = TextStyle(
      fontFamily: CoFonts.latinSerif,
      fontSize: bodyFontSize,
      height: tokens.readLineHeight,
      letterSpacing: bodyFontSize * 0.002,
      color: Color(tokens.ink.argb32),
    );

    return GptMarkdown(
      marked,
      style: base,

      // 🔴 **必须显式传 false**：包默认是 `true`（为流式输出设计）。
      //    我们是**完整文本**一次渲染 → 走流式路径只会多出 reveal 记账的开销。
      isStreaming: false,

      // 痕迹：把控制字符标记渲染成带样式的 span（见文件头）
      // 🆕 划线：另一种标记、另一种样式（下划线）—— 两个 pattern 互不干扰
      //    （一个匹配 `\u0001/\u0002`，一个匹配 `\u0003`）
      // ⚠️ 曾在这里写着「**必须用 `inlineDirectives`，绝不能用 `inlinePatterns`**」——
      //    那条结论建立在**一次 grep 漏项**上：当时断言 `inlinePatterns` 在 1.3.0 里
      //    「没有消费点（传了等于没传）」，实际它有**五处**消费点
      //    （`InlinePatternMd` 组件注册 · `maskInlinePatterns` ×3 · `expandInlinePatterns`）。
      //    📌 判据：**「我没 grep 到」≠「不存在」** —— 结论若是「某 API 没被消费」，
      //       必须换多种模式复核（`part` 文件 · `copyWith` 转发 · 换关键词大小写）。
      //    🔴 真机症状（痕迹全不显示）的**真实根因**另在别处：见下「双注册」注释末尾。
      // 🆕 2026-10-08：**两条路都注册**（互补 —— 谁也吃不准哪个在本机/真机上先坏）。
      //
      // 为什么两个都留（而不是二选一）：
      //  · `inlinePatterns`  在**解析后**的文本 run 上匹配 ⇒ 若标记跨过 `**`/`` ` ``
      //    这类会拆节点的字符，正则就匹配不上 ⇒ **整条不显示**（探针实测过）。
      //  · `inlineDirectives` 在**解析前**把区间整段抽成 sentinel ⇒ 不受节点拆分影响，
      //    但它**完全依赖 mask 成功**；mask 一旦被跳过（`blockRegistry` 非空时只处理
      //    「自定义块之外」），sentinel 不存在 ⇒ 静默降级成不可见文本。
      //  ⇒ **两者的失效条件是正交的** ⇒ 同时注册等于给自己上一道保险。
      //  ⚠️ 不会重复渲染：directive 的 mask 先跑，标记被换走后 pattern 再匹配就找不到了。
      //
      // ══════════════════════════════════════════════════════════════
      // 🔴 2026-10-08 真机定位结果：**根因不在这一层**（诚实的存档）
      // ══════════════════════════════════════════════════════════════
      //
      // 为了查「文章页没有痕迹」，整条链在本机被逐一验过（注入 6 篇真实正文全过 ·
      // sentinel 存活 11 项全过 · 包内展开点逐环读完 · 版本路径 · 样式层 · 数据层）
      // —— **全部正确**。最后靠**真机诊断条**才看出来，真凶是**主题档位**：
      //
      // | 档 | `TraceSyntax` | 痕迹的**可见手段** | `fresh.bg` |
      // |---|---|---|---|
      // | 墨 | `wash`      | **底色**（`background: Paint`）| 朱砂 15%（有颜色）|
      // | 格 | `underline` | **下划线**（`decoration`）    | `transparent` ← **设计如此** |
      // | 夜 | `glow`      | **前景色**（`color`）         | `transparent` ← **设计如此** |
      //
      // 🔑 我在诊断条里只打印了 `bg`，看到 `trans=true` 就当成「痕迹不可见」——
      //    而那是**格档的正确值**（它本来就靠下划线表达）。
      // 📌 判据：**「同一份语义在多个变体下的表达手段可以不同」** ——
      //    只查其中一种手段（或只看一个档）会把**正常**读成**故障**。
      //    ⚠️ 与「三档主题」这种设计**天然同族**：每加一档就多一条表达路径要覆盖。
      //
      // ⚠️ 由此浮出的**真问题**（另案，未改）：格档的痕迹 = 下划线，而**划线也是下划线**
      //    ⇒ 用户在格档下**分不清「系统记的」和「我划的」**（只靠 2.5px vs 1.2px 粗细）。
      //    这与既定的「**形状区分优于参数**」相冲突 ⇒ 需白哥定（见当日交付说明）。
      inlinePatterns: [
        _tracePattern(),
        _highlightPattern(),
      ],

      inlineDirectives: [
        // 痕迹两档：标记字符不同 ⇒ 各注册一个 directive（builder 里硬编码档位）
        _traceDirectiveOf(kTraceFreshOpen, 0),
        _traceDirectiveOf(kTraceReviewingOpen, 1),
        // 划线（下划线）
        _highlightDirective(),
      ],

      // 内联代码：治「`<img>` 等标签裸奔」—— 等宽 + 底色 chip
      inlineCodeStyle: InlineCodeStyle(
        fontSizeFactor: 0.92,
        color: Color(tokens.ink.argb32),
        backgroundColor: Color(tokens.sunken.argb32),
        borderColor: Color(tokens.line.argb32),
        borderRadius: const Radius.circular(4),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      ),

      styleSheet: GptMarkdownStyleSheet(
        // 代码块：治「被压平」—— 保留换行缩进 + 语法高亮 + 语言标签
        codeBlock: CodeBlockStyle(
          backgroundColor: Color(tokens.sunken.argb32),
          borderColor: Color(tokens.line.argb32),
          borderWidth: 1,
          borderRadius: const Radius.circular(10),
          padding: const EdgeInsets.all(12),
          textColor: Color(tokens.ink.argb32),
          fontSize: bodyFontSize * 0.9,
          // 语言标签（```dart 的 `dart`）—— 保留，它有助于判断这段是什么
          showLanguageLabel: true,
        ),
        heading: HeadingStyle(
          textStyle: base.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.32,
            color: Color(tokens.ink.argb32),
          ),
          // 分隔线交给「视觉」而不是排版 —— 正文里的标题不该带横线
          // （阅读页已有自己的层级语言；横线会与痕迹下划线抢注意力）
          showDivider: false,
        ),
        link: LinkStyle(
          color: Color(tokens.accentBright.argb32),
          decoration: TextDecoration.underline,
        ),
        blockQuote: BlockQuoteStyle(
          barColor: Color(tokens.line.argb32),
          barWidth: 3,
          textStyle: base.copyWith(color: Color(tokens.ink2.argb32)),
        ),
      ),

      // 🔴 正文里的链接**渲染成普通文字**（不可点）—— 见下方「链接」一节
      inlineLinkBuilder: (details) => TextSpan(
        text: details.label,
        style: base,
      ),
    );
  }

  /// **pattern 版**的痕迹规则（与 [`_traceDirectiveOf`] 同时注册，见注册处说明）。
  ///
  /// 🔑 与原版（10-02 S4）**逐字一致** —— 它当时在 git 里，不凭记忆重写。
  InlinePattern _tracePattern() => InlinePattern(
        pattern: kTraceMarkerPattern,
        builder: (context, match, style) {
          final marker = match.group(1) ?? kTraceFreshOpen;
          final text = match.group(2) ?? '';
          final tier = marker == kTraceFreshOpen ? 0 : 1;

          final traceStyle = tokens.trace.forReps(tier);
          // `forReps` 返回 null = 已掌握 → 不该有标记。
          // 走到这里说明**标记与判据不一致**（不该发生），降级成普通文字。
          if (traceStyle == null) return TextSpan(text: text, style: style);

          return TextSpan(
              text: text, style: applyTraceStyle(style, traceStyle));
        },
      );

  /// **pattern 版**的划线规则（下划线）—— 样式与 [`_highlightDirective`] 同一口径。
  InlinePattern _highlightPattern() => InlinePattern(
        pattern: kHighlightMarkerPattern,
        builder: (context, match, style) {
          final text = match.group(1) ?? '';
          return TextSpan(
            text: text,
            style: style.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: Color(tokens.accentBright.argb32),
              decorationThickness: 1.2,
            ),
          );
        },
      );

  /// 痕迹的 inline 语法规则 —— 把 [`kTraceMarkerPattern`] 匹配到的内容
  /// 渲染成带痕迹样式的 [`TextSpan`]。
  ///
  /// 🔑 档位从**标记字符**反推（`\u0001` = fresh / `\u0002` = reviewing），
  ///    样式再向 `tokens.trace.forReps(档位)` 取 —— 这样「档位 → 样式」的映射
  ///    仍然只有 token 层一处权威（本函数不做任何样式判断）。
  /// 🔑 为什么**每档一个** directive 而不是「一个带档位参数」的：
  ///    `InlineDirective` 的 `open` / `close` 是**固定字符串**（不是正则）⇒
  ///    档位只能靠「注册的是哪一个」区分 ✓ 比从 `match.group(1)` 反推更直白。
  ///
  /// ⚠️ `open` 与 `close` **同一个字符**（与注入端 `\u0001内容\u0001` 逐字对应）——
  ///    `maskInlineDirectives` 是「先找 open、再从其后找 close」⇒ 同字符开闭可正常工作。
  ///    📌 改标记形态时，**注入端与这里的 open/close 必须一起改**（断言锁定）。
  InlineDirective _traceDirectiveOf(String marker, int tier) => InlineDirective(
        open: marker,
        close: marker,
        builder: (context, payload, style) {
          final traceStyle = tokens.trace.forReps(tier);
          // `forReps` 返回 null = 已掌握 → 不该有标记。
          // 走到这里说明**标记与判据不一致**（不该发生），降级成普通文字。
          if (traceStyle == null) return TextSpan(text: payload, style: style);

          return TextSpan(
              text: payload, style: applyTraceStyle(style, traceStyle));
        },
      );

  /// 🆕 **划线**的 inline 语法规则 —— 把 `\u0003…\u0003` 渲染成**带下划线**的 span。
  ///
  /// # 🔑 样式与书架页**同一条口径**（那里是 `Text.rich` 手工拼 span）
  ///
  /// | | 形态 | 心智 |
  /// |---|---|---|
  /// | 痕迹（已查词）| **底色浸染**（面）| 系统记的 |
  /// | 划线 | **下划线**（线）| **我**划的 |
  ///
  /// ⇒ 两者都是「高亮」，同形状会互相干扰 ⇒ 按项目既有判据「**形状区分优于参数**」。
  /// ⚠️ 两处的**数值必须一致**（`accentBright` · `thickness 1.2`）——
  ///    不同页面的同一种划线长得不一样，是最难看出来的不一致。
  ///    🔑 但**不共用常量**：两处的渲染路径不同（span 拼接 vs inline pattern），
  ///    硬抽一个常量出来反而要多一层间接；**共用的是口径**（写在这里，改时两处一起改）。
  ///
  /// ⚠️ **真机待目视**：下划线与字形的距离由字体决定，`TextDecoration` 没有
  ///    CSS 的 `text-underline-offset`（想调只能动 `height`，那是全局的）。
  InlineDirective _highlightDirective() => InlineDirective(
        open: kHighlightOpen,
        close: kHighlightOpen,
        builder: (context, payload, style) {
          return TextSpan(
            text: payload,
            style: style.copyWith(
              decoration: TextDecoration.underline,
              // 细线用 `accentBright`（项目规定：**细线与描边用亮调**，
              // `accent` 是实心填充色）
              decorationColor: Color(tokens.accentBright.argb32),
              decorationThickness: 1.2,
            ),
          );
        },
      );

  // ─────────────────────────────────────────────────────────────────────
  // 🔴 2026-10-03：**正文里的链接不再可点**（白哥定）
  // ─────────────────────────────────────────────────────────────────────
  //
  // 实现方式见 `build` 里的 `inlineLinkBuilder` —— 它返回一个**纯 `TextSpan`**
  // （不带 `recognizer`）⇒ 不可点。
  //
  // # 为什么（白哥真机反馈）
  //
  // 原话：「应该把正文内的 url 都过滤掉，**不然用户选词会跳转影响阅读**」。
  //
  // 🔑 痛点定位的关键：他说的是「**影响阅读**」，不是「URL 难看」。
  //    实测正文里 **262/523 篇**含 URL（共 2062 个，其中 1879 个是 `[文字](url)`
  //    的可点链接）—— 而阅读页的核心交互是**长按划词查词**，
  //    手指落下时若压到链接，会**直接跳出 App**，阅读被打断。
  //
  // # 取舍（当时给白哥的三个选项，他选 A）
  //
  // | 方案 | 结果 |
  // |---|---|
  // | **A. 禁用点击** ✅ | 文字保留、不可点 —— **对准痛点** |
  // | B. 只删裸 URL | 1879 个可点链接**仍在** ⇒ 没解决误触 |
  // | C. 全删 | 信息丢失（链接文字常是有意义的词）|
  //
  // # ⚠️ 为什么连「链接样式」也一起去掉（而不是只掐掉点击）
  //
  // 项目已有判据：**视觉元素的形态/作用域须与语义一致**。
  // 若保留蓝色下划线但点了没反应，用户会以为**功能坏了**（比没有链接更糟）。
  // ⇒ 渲染成与正文完全一致的样式：**看起来是普通文字，行为也是普通文字**。
  //
  // # 影响面（已核实）
  //
  // · 「打开原文」在**阅读页顶栏**，不走这里 ⇒ **不受影响**
  // · 其他用链接的地方（`notification_panel.dart`）**不受影响**（各自独立实现）
  // · `onLinkFailed` / `_openLink` / `url_launcher` **已一并移除** ——
  //   禁用点击后它们永远不会被调用，留着就是**死代码 + 误导**
  //   （📌 判据：删功能要清理语义残留，否则后续开发会把旧概念加回来）
}
