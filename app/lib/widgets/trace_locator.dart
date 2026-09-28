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
List<TraceMark> locateTraceMarks({
  required String text,
  required List<ArticleLookup> lookups,
  required TraceTokens tokens,
}) {
  if (text.isEmpty || lookups.isEmpty) return const [];

  final marks = <TraceMark>[];
  // 同一个词在 lookups 里出现两次是数据错误 —— 去重，结果只由第一条决定
  // （否则会产生重叠标记，而 splitTraceSpans 的「先到优先」在这里没有意义）。
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
