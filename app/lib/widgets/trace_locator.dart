import '../models/article.dart';
import '../theme/coevo_tokens.dart';

/// 痕迹判定 —— 从「已查词表」挑出**要标痕迹的词**及其**档位**。
///
/// 纯逻辑、**零 Flutter 依赖**，所以能由 `scripts/trace_verify/` 独立断言。
///
/// ```
/// 已查词表(词 / reps / lapses)
///   → pickedTraceTiers()            → Map<词, 档位>
///   → trace_markdown_source.injectTraceMarkers()  → 「词」包成源内控制字符标记
///   → trace_markdown.dart（gpt_markdown + InlinePattern）→ 渲染
/// ```
///
/// # 本文件的职责边界（S4 之后收窄了）
/// 它**只回答一个问题**：「这个查过的词，该不该标、标哪一档」。
/// · ❌ 不做词匹配 —— 那是 `trace_markdown_source._markWords` 里的 `\b` 正则
/// · ❌ 不做样式映射 —— 那是 `trace_style.applyTraceStyle`
/// · ❌ 不知道正文长什么样 —— Markdown 形态与本层无关
///
/// 🔴 原先这里还有第二件事：`locateTraceMarks()` —— 把词落成**字符区间**。
/// S4 把正文渲染换成 Markdown 后它失去了意义（**解析后字符偏移全变**，
/// 「第 12–20 个字符」对不上任何东西），已删。
/// 📄 依据 → `docs/review/content-pipeline-rebuild-plan-2026-10-02.md` §十四
///
/// 📌 **留下的这个函数是被「抽出来」过的**：换渲染器之前，纯文本路径与
///    Markdown 路径共用它做判定。正因为它当初被单独抽成一个函数，
///    这次换渲染器才只换了「表达层」—— **判定一行没动**。
///    🔑 判据：**同一件事的口径只能有一处权威** —— 表达层可以重写，
///       判定不该跟着重写（否则重写两次 = 两个真相）。
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
