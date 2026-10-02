import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/article.dart';
import '../services/trace_markdown_source.dart';
import '../theme/coevo_tokens.dart';
import 'trace_locator.dart';
import 'trace_text.dart';

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
/// 📌 与 `TraceText` 里那条「不做没依据的优化」同一条原则。
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
    this.onLinkFailed,
  });

  /// 正文（**Markdown 形态**）。
  final String markdown;

  /// 已查词（痕迹的数据源）。
  final List<ArticleLookup> lookups;

  /// 设计 token（墨/格/夜三档）。
  final CoEvoTokens tokens;

  /// 正文字号（由调用方给 —— 阅读器有「字号」概念，不在 token 层）。
  final double bodyFontSize;

  /// 链接打不开时的回调（`null` = 静默）。
  ///
  /// ⚠️ 有回调**不等于**「必须弹提示」—— 调用方决定怎么表达。
  ///    这里给回调而不是自己弹，是因为**本组件不该知道怎么跟用户说话**
  ///    （与 `hasReadableBody` 只管判定、不管文案是同一条分层原则）。
  final void Function(String url)? onLinkFailed;

  @override
  Widget build(BuildContext context) {
    // ① 判定：哪些词该标、哪一档（与纯文本路径**同一份判据**）
    final tiers = pickedTraceTiers(lookups: lookups, tokens: tokens.trace);

    // ② 编码：把词包成控制字符标记（跳过代码块 / 行内代码 / 链接 URL）
    final marked = injectTraceMarkers(markdown: markdown, tiers: tiers);

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

      onLinkTap: (url, _) => _openLink(url),
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

  /// 打开外部链接。
  ///
  /// 🔑 沿用 `notification_panel.dart` 的惯例（`LaunchMode.externalApplication`）——
  /// 外部链接不该在 App 内用 WebView 打开（本项目不做 Web）。
  ///
  /// ⚠️ **失败必须可见**：`launchUrl` 返回 `false` 或被抛异常时，
  /// 静默什么都不做 = 用户以为「链接坏了」。→ 交给 [onLinkFailed] 表达。
  /// （📌 项目已有的教训：「静默失败 + 无出口」比「报错」更糟。）
  Future<void> _openLink(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) {
        onLinkFailed?.call(url);
        return;
      }
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) onLinkFailed?.call(url);
    } catch (e) {
      // 打不开是**预期内**的（没有浏览器 / scheme 不支持）→ 不当作崩溃
      debugPrint('[TraceMarkdown] 打开链接失败: $url ($e)');
      onLinkFailed?.call(url);
    }
  }
}
