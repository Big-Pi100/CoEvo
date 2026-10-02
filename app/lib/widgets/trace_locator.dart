import '../models/article.dart';
import '../theme/coevo_tokens.dart';
import 'trace_segmenter.dart';

/// 痕迹定位器 —— 把「我查过哪些词」落到正文里的**字符区间**上。
///
/// 纯逻辑、**零 Flutter 依赖**（与 `trace_segmenter` 同层同风格），
/// 所以能由 `scripts/trace_verify/` 独立断言。
///
/// ```
/// 正文文本 + 已查词表(词/reps/lapses)
///   → locateTraceMarks() → List<TraceMark>
///   → splitTraceSpans()  → 连续分段
///   → TraceText          → 渲染
/// ```
///
/// # 🔴 本文件唯一的难点：词边界
/// 若用朴素的 `text.indexOf(word)`，则查过 `art` 会把 `start` / `part` /
/// `artist` 全标上痕迹 —— 而用户从没查过这些词。
/// 这类错误**不报错、只是多画几处底色**，肉眼扫过去很难发现，
/// 所以必须由断言锁死（见 `verify_trace.dart` 的 locator 组）。
///
/// 判据用的是正则 `\b` ——「单词字符与非单词字符的交界」。
/// 于是 `vertical` 匹配 `vertical` 而不匹配 `vertically`
/// （`l` 与 `y` 都是单词字符，中间没有边界）。
///
/// # ⚠️ 已知限制（如实说明）
/// `\b` 只认 `[A-Za-z0-9_]` 为单词字符，所以：
/// - 词以**非单词字符**开头/结尾时（如 `well-known`），`\b` 的位置会不符合直觉；
/// - 含 `'` 的缩写（`don't`）同理。
///
/// 当前词库 `word.spelling` **100% 是全小写单词**（连专名也是 `india` / `isaac`），
/// 不存在这两类形态 —— 所以不额外处理。若将来词库引入短语/带连字符的词，
/// 这里要一并改（**别在这里默默加兜底**）。
/// 挑出「要标痕迹的词」及其**档位** —— 两条渲染路径**共用这一份判据**。
///
/// # 🔴 为什么必须抽出来（2026-10-02 · S4）
/// S4 把正文渲染从「纯文本逐段」换成 **Markdown 渲染**后，痕迹有了**两条路径**：
///
/// | 路径 | 怎么表达痕迹 |
/// |---|---|
/// | 纯文本（`TraceText`）| 词 → **字符区间** → 逐 span 上色 |
/// | Markdown（`gpt_markdown`）| 词 → **源里插标记** → `InlinePattern` 渲染成 span |
///
/// 两条路**表达方式不同**（区间 vs 标记），但「**哪些词该标、标哪一档**」
/// 必须**完全一致** —— 否则会出现「同一个词在 A 路径有痕迹、B 路径没有」
/// 这种最难查的不一致（不报错，只是少画一处底色）。
///
/// 📌 判据：**同一件事的口径只能有一处权威** —— 表达层可以有两份实现，
///    但「判定」必须只有一份。
///
/// # 返回
/// `词（小写）→ 档位`，档位即 [`TraceTokens.forReps`] 的输入：
/// · `0` → `fresh`（新词）
/// · `1` → `reviewing`（复习中）
///
/// ⚠️ **已掌握的词不会出现在结果里**（`forReps` 返回 `null` 就跳过）——
///    见下方注释，这是白哥 2026-09-27 的决策。
///
/// 🔑 返回**档位**而不是 `TraceStyle`：样式由消费方自己向 `tokens.forReps` 取，
///    这样「档位 → 样式」的映射也只有一处（token 层），本函数只管「判定」。
Map<String, int> pickedTraceTiers({
  required List<ArticleLookup> lookups,
  required TraceTokens tokens,
}) {
  final out = <String, int>{};
  if (lookups.isEmpty) return out;

  final seen = <String>{};
  for (final lk in lookups) {
    final word = lk.word.trim();
    if (word.isEmpty) continue;
    final key = word.toLowerCase();
    if (!seen.add(key)) continue;

    // 🔑 已掌握 → `forReps` 返回 null → **不产生标记**（白哥 2026-09-27 决策）。
    //    注意这个词仍然在 lookups 里（它是事实），只是渲染层不表达它。
    final style = tokens.forReps(lk.reps, lapses: lk.lapses);
    if (style == null) continue;

    // 档位 = 「是不是 fresh」这一条判据（forReps 只有 fresh / reviewing / null 三种输出）
    out[key] = identical(style, tokens.fresh) ? 0 : 1;
  }
  return out;
}

List<TraceMark> locateTraceMarks({
  required String text,
  required List<ArticleLookup> lookups,
  required TraceTokens tokens,
}) {
  if (text.isEmpty || lookups.isEmpty) return const [];

  final marks = <TraceMark>[];
  // 🔑 词筛选（去重 + 已掌握排除）**复用共享判据** —— 别在这里再写一份
  //    （Markdown 渲染路径用的是同一个函数，两边漂移会静默少画痕迹）。
  final tiers = pickedTraceTiers(lookups: lookups, tokens: tokens);

  for (final entry in tiers.entries) {
    final word = entry.key;
    final style = tokens.forReps(entry.value);
    if (style == null) continue;

    final re = RegExp(
      '\\b${RegExp.escape(word)}\\b',
      caseSensitive: false,
    );
    for (final m in re.allMatches(text)) {
      marks.add(TraceMark(start: m.start, end: m.end, style: style));
    }
  }

  return marks;
}
