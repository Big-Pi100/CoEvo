// CoEvo · 「选中的那段在正文里的哪个位置」—— 划线定位（纯 Dart · 本机可独立验证）
//
// # 🔴 这个文件存在的原因：**框架不给我们偏移量**
//
// 读 Flutter SDK 实测：`SelectionArea` 的 `onSelectionChanged` 回调给的是
// `SelectedContent` —— 它**只有 `plainText`，没有 start/end 偏移**
// （`widgets/selectable_region.dart` 的 `_updateSelectedContentIfNeeded`）。
// 而 `contextMenuBuilder` 给的是**屏幕坐标**（`contextMenuAnchors`），也不是字符偏移。
//
// ⇒ 只能**反查**：拿选中文本去正文明文里找它出现的位置。
//
// # 🔴 由此产生的两条如实标注的边界（**不是 bug，是框架限制**）
//
// | 边界 | 说明 | 缓解 |
// |---|---|---|
// | **只能取「首个」出现** | 同一段文字在正文里出现多次时，无法知道用户划的是哪一次 | ① **存全文**（`highlight.text`）⇒ **复习内容总是对的**，只是高亮位置可能偏；② 渲染侧用**同一个函数**算 ⇒ 两侧一致，不会「存的是一处、画的是另一处」 |
// | **找不到** ⇒ `start = -1` | 正文明文与选中的文本来自不同的渲染层（Markdown / 分页），可能对不上 | 允许存 `-1` = 「**只复习，不高亮**」。⚠️ **不能**因为定位失败就丢弃这条划线 —— 用户的意图是「记住这段」，位置只是附属信息 |
//
// ⚠️ 本文件不得 import 任何东西（含 `package:flutter`）—— 纯 Dart 才能本地独立验证。

/// 一段文字在正文里的字符区间（**半开** `[start, end)`）。
class HighlightSpan {
  const HighlightSpan(this.start, this.end);

  final int start;
  final int end;

  /// 定位失败（正文明文里找不到这段文字）⇒ 存储时用 `-1`。
  ///
  /// 🔑 语义是「**位置未知**」，不是「位置是开头」—— 所以**不能**把它当成 0 用。
  static const HighlightSpan notFound = HighlightSpan(-1, -1);

  /// 是否定位成功。
  bool get isLocated => start >= 0 && end > start;

  @override
  bool operator ==(Object other) =>
      other is HighlightSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => isLocated ? '[$start,$end)' : 'notFound';
}

/// 把「选中的文本」定位到「正文明文」里的字符区间。
///
/// # 规则（刻意只有一条）
/// · 用 [String.indexOf] 取**首个**出现（理由见文件头）
/// · 找不到 ⇒ [HighlightSpan.notFound]
/// · 空 `picked` ⇒ [HighlightSpan.notFound]（**空内容不该变成一条划线**）
///
/// ⚠️ **不做模糊匹配**（大小写、空白、标点）—— 定位与「判定」是两件事：
///    判定可以宽松（少个逗号不算错），但**定位必须精确**，
///    否则会把高亮画到别处（比不画更糟：用户会以为划线**自己跑了**）。
HighlightSpan locateSelection({
  required String plainText,
  required String picked,
}) {
  if (picked.isEmpty) return HighlightSpan.notFound;
  final i = plainText.indexOf(picked);
  if (i < 0) return HighlightSpan.notFound;
  return HighlightSpan(i, i + picked.length);
}

// ───────────────────────────────────────────────────────────────────────
// 渲染用：把正文按「划线区间」切成若干段
// ───────────────────────────────────────────────────────────────────────

/// 一条划线在渲染时需要的**最小信息**。
///
/// 🔑 刻意**不是** `Highlight`（仓储模型）：本文件是纯 Dart（见文件头），
///    而仓储模型在 `highlight_repository.dart` 里、带 `sqflite` 依赖 ⇒
///    import 它会让本文件失去「本机可独立验证」。调用方做一次映射即可。
class HighlightRange {
  const HighlightRange({required this.id, required this.start, required this.end});

  /// 划线 id —— 渲染时用来绑定「点这一段的线 → 打开哪条划线」。
  final String id;

  final int start;
  final int end;

  @override
  String toString() => '$id[$start,$end)';
}

/// 切分后的一段正文。
class TextSegment {
  const TextSegment({required this.text, required this.start, this.highlightId});

  /// 这一段的文字。🔑 所有段的 `text` 拼接起来**必须等于**原文（见 [buildTextSegments]）。
  final String text;

  /// 这一段的起始 offset 落在**原文**（不是切分后）的哪个位置。
  ///
  /// 🔑 存在的理由：这是「点某一段的划线 → 打开对应那条」的键。
  ///    用**原文**偏移而不是「累积段长」——后者在多段叠加时容易算错。
  final int start;

  /// `null` = 普通文字；非空 = 这段被这条划线覆盖。
  final String? highlightId;

  bool get isHighlighted => highlightId != null;

  @override
  String toString() => isHighlighted ? '{${'$highlightId'}$text}' : text;
}

/// 把 [text] 按 [ranges] 切成「普通段 / 划线段」交替的序列。
///
/// # 🔴 唯一的硬不变量
/// > **`result.map((s) => s.text).join()` 必须逐字等于 `text`。**
///
/// 渲染层用它拼 `TextSpan`，拼不回原文就会**掉字**（用户看不到划过的那段，
/// 而库里明明有它）。所以本函数**只做切割，不做任何文字变换**
/// （不 trim、不去标点、不归一化）—— 那是判定层的事。
///
/// # 非法输入一律**跳过**（不抛错）
/// 这些区间来自数据库，可能被历史版本或同步写入坏值：
///
/// | 情况 | 处理 | 理由 |
/// |---|---|---|
/// | `start < 0`（[HighlightSpan.notFound]）| 跳过 | 「只复习，不高亮」是**已支持的正常状态** |
/// | `start >= end` | 跳过 | 零宽区间画不出线 |
/// | `start >= text.length` | 跳过 | 正文比划线时短了（文章被重新抓取）|
/// | `end > text.length` | **钳到** `text.length` | 同上，但前半段仍然有效 ⇒ 保留可见部分 |
/// | **重叠** | **合并**成一条（取并集）| 视觉上无法表达重叠的下划线；不合并会画出两条互相覆盖的线 |
///
/// ⚠️ **端点相接不算重叠**（`[0,3)` 与 `[3,6)` 各自成段）——
///    它们是**两条**划线（用户划了两次），合并会丢掉一条的 `id` ⇒
///    点它只能打开到错误的那条。
List<TextSegment> buildTextSegments({
  required String text,
  required List<HighlightRange> ranges,
}) {
  if (text.isEmpty) return const <TextSegment>[];

  // ① 过滤 + 钳制
  final usable = <HighlightRange>[];
  for (final r in ranges) {
    if (r.start < 0 || r.end <= r.start) continue;
    if (r.start >= text.length) continue;
    usable.add(HighlightRange(
      id: r.id,
      start: r.start,
      end: r.end > text.length ? text.length : r.end,
    ));
  }

  if (usable.isEmpty) {
    return <TextSegment>[TextSegment(text: text, start: 0)];
  }

  // ② 按起点排序（同起点时**长的在前** —— 保证合并结果的 id 属于外层那条）
  usable.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : b.end.compareTo(a.end);
  });

  // ③ 合并重叠（端点相接**不**算重叠）
  final merged = <HighlightRange>[];
  for (final r in usable) {
    if (merged.isEmpty) {
      merged.add(r);
      continue;
    }
    final last = merged.last;
    if (r.start < last.end) {
      // 真重叠 ⇒ 取并集；id 保留**外层**那条（merged.last 的 id 不动）
      merged[merged.length - 1] = HighlightRange(
        id: last.id,
        start: last.start,
        end: r.end > last.end ? r.end : last.end,
      );
    } else {
      merged.add(r);
    }
  }

  // ④ 交替产出
  final out = <TextSegment>[];
  var cursor = 0;
  for (final r in merged) {
    if (r.start > cursor) {
      out.add(TextSegment(
        text: text.substring(cursor, r.start),
        start: cursor,
      ));
    }
    out.add(TextSegment(
      text: text.substring(r.start, r.end),
      start: r.start,
      highlightId: r.id,
    ));
    cursor = r.end;
  }
  if (cursor < text.length) {
    out.add(TextSegment(text: text.substring(cursor), start: cursor));
  }
  return out;
}

/// 取某一段（按**原文偏移**）所属的划线 id；不在任何划线上 ⇒ `null`。
///
/// 🔑 点正文里一条下划线时用它反查 —— 段本身就是「源码里的一段」，
///    所以「用段里的任意偏移去问」和「按段查」是同一件事
///    （📌 判据：**同一件事的口径只能一处权威**）。
String? highlightIdAt(List<TextSegment> segments, int offset) {
  for (final s in segments) {
    if (s.highlightId == null) continue;
    if (offset >= s.start && offset < s.start + s.text.length) {
      return s.highlightId;
    }
  }
  return null;
}
