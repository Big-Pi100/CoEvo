import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/article.dart';
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

    // ② 🔴 消化**多余的 Markdown 转义**（2026-10-02 · 白哥真机反馈「转义没消化」）
    //
    // 产出侧（后端 `dom_smoothie`）按 **CommonMark** 全量转义 —— 且是**过度**转义：
    // `DELETE\.` · `\"QUERY\"` · `\(66\.4%\)`（句点/引号/圆括号**本来都不需要转**）。
    // 而消费侧（`gpt_markdown` 1.3.0）**只反转义 `\|`**（源码原话：`Only \| is unescaped`）
    // ⇒ 其余 `\X` 原样显示 ⇒ 用户看到满屏反斜杠。
    //
    // 🔑 消化放在**渲染之前**（而不是渲染后处理字符串）：
    //    渲染后拿到的是 span，改它要动 `gpt_markdown` 的渲染结果 —— 既不归我们管，也不好测。
    //    📌 判据：**能改输入的，就别改输出**（同 `injectTraceMarkers` 的思路）。
    //
    // ⚠️ 顺序：**先消化转义、再注入痕迹标记**。
    //    · 消化会**删字符**（缩短文本），而痕迹注入是「按词匹配」不依赖偏移 ⇒ 两者互不干扰
    //    · 反过来（先注入）也不出错，但「修正源文本」在语义上该先做 ——
    //      痕迹标记描述的是「最终要渲染的那段文本里的词」
    final unescaped = unescapeRedundantMarkdown(markdown: markdown);

    // ③ 编码：把词包成控制字符标记（跳过代码块 / 行内代码 / 链接 URL）
    final marked = injectTraceMarkers(markdown: unescaped, tiers: tiers);

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
      inlinePatterns: [_tracePattern()],

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

  /// 痕迹的 inline 语法规则 —— 把 [`kTraceMarkerPattern`] 匹配到的内容
  /// 渲染成带痕迹样式的 [`TextSpan`]。
  ///
  /// 🔑 档位从**标记字符**反推（`\u0001` = fresh / `\u0002` = reviewing），
  ///    样式再向 `tokens.trace.forReps(档位)` 取 —— 这样「档位 → 样式」的映射
  ///    仍然只有 token 层一处权威（本函数不做任何样式判断）。
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
