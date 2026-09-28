// CoEvo · 痕迹区间切分（纯逻辑）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**。
//   理由同 `services/fsrs_service.dart`：本地 Flutter 是鸿蒙定制版、
//   `flutter analyze` 会因 Windows 管道耗尽崩溃 —— 纯 Dart 才能本地独立验证
//   （见 `scripts/trace_verify/`）。
//
// # 为什么把它从渲染层拆出来
// 「痕迹」= 正文 + 「哪些词处于什么熟练度」→ 在正文里落成**带样式的区间**。
// - 「区间怎么切」是**纯计算** → 能被断言锁住（重叠 / 越界 / 相邻 / 空洞）
// - 「区间长什么样」才是 Flutter 的事 → 只能靠肉眼
// **两类问题不该混在一起**：切分错了是逻辑 bug（可自动抓），
// 样式不对是视觉问题（自动抓不到，且可能只是设计稿有待商榷）。
//
// # 依据
// `docs/design/design-system-spec-2026-09-25.md` §一 · `visual-feed-bookmark-2026-09-25.html`
//   两态：刚查过（reps=0）/ 复习中（reps 1–2）
//   🔴 **已掌握（reps ≥3 且 lapses=0）→ 不标识**（痕迹消失，白哥 2026-09-27 定）——
//   `TraceTokens.forReps` 对它返回 **`null`**，调用方**跳过该标记**。
//   ⚠️ 不要传「透明样式」代替：透明确实看不见，但 `padding` 仍会撑开字距 → 还是标识。
//   ⚠️ 本文件**不判断熟练度** —— 那是 `TraceTokens.forReps()` 的职责。
//   调用方先算出 style（可能为 `null`），非 null 的才包成 [TraceMark] 传进来。

import '../theme/coevo_tokens.dart';

/// 一个痕迹标记 —— 「正文的 [start, end) 这一段用这个样式」。
///
/// 区间是**半开区间**（`start` 含、`end` 不含），与 Dart 的 `substring` 一致 ——
/// 用闭区间迟早会在「相邻两段」处多算/少算一个字符。
class TraceMark {
  final int start;
  final int end;
  final TraceStyle style;

  const TraceMark({
    required this.start,
    required this.end,
    required this.style,
  });

  @override
  String toString() => 'TraceMark($start..$end)';
}

/// 切分后的一段。
///
/// [style] 为 `null` = **普通文字**（未被任何标记覆盖）。
///
/// 🔑 为什么留 `null` 而不是「只返回被标记的段」：
/// 渲染要的是**覆盖全文、首尾相接**的段序列 —— 中间的空洞必须显式表达出来，
/// 否则渲染层得自己「猜哪里是空洞」，等于把同一套区间逻辑写两遍。
class TraceSpan {
  final int start;
  final int end;

  /// `null` = 无痕迹。
  final TraceStyle? style;

  const TraceSpan({required this.start, required this.end, this.style});

  bool get hasTrace => style != null;
  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is TraceSpan &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'TraceSpan($start..$end${hasTrace ? '' : ' · plain'})';
}

/// 切分结果 + **诊断计数**。
///
/// 🔑 为什么把畸形输入**计数**而不是静默处理：
/// 区间来自上游（分词 + 词表命中），理论上不会越界或重叠；
/// 一旦发生就是**上游有 bug**。静默吞掉 → 表现为「某些词莫名没痕迹」，
/// 而排查时毫无线索（本项目已反复踩过「静默失败」的坑，见 `_friendlyError` 那段）。
/// 计数让「本该不发生的事」**可见**：调用方可以 assert，也可以只是 debugPrint。
///
/// 四个计数互不重叠：一个畸形标记只归入其中一类。
class TraceSplit {
  final List<TraceSpan> spans;

  /// `start >= end`（空区间或反向区间）→ 无意义，丢弃。
  final int droppedInvalid;

  /// 超出 `[0, textLength]` → 截断到边界。截断后仍无效则计入 [droppedInvalid]。
  final int clampedOutOfRange;

  /// 与**已覆盖区间**重叠 → 只取未覆盖部分；完全被覆盖则丢弃。
  final int overlapped;

  const TraceSplit({
    required this.spans,
    this.droppedInvalid = 0,
    this.clampedOutOfRange = 0,
    this.overlapped = 0,
  });

  /// 有任何畸形输入。
  bool get hasDiagnostics =>
      droppedInvalid > 0 || clampedOutOfRange > 0 || overlapped > 0;

  /// 一句话摘要（便于 debugPrint）。
  String get diagnostics =>
      'invalid=$droppedInvalid clamped=$clampedOutOfRange overlapped=$overlapped';

  /// 被标记覆盖的字符数（校验用：可核对「痕迹覆盖率」）。
  int get tracedLength =>
      spans.where((s) => s.hasTrace).fold(0, (a, s) => a + s.length);

  @override
  String toString() =>
      'TraceSplit(${spans.length} spans · $diagnostics)';
}

/// 把 [marks] 切分成**覆盖 `[0, textLength)` 全文、首尾相接**的段序列。
///
/// # 确定性
/// 同样的输入**必然得到同样的输出**，包括存在重叠 / 同起点时 ——
/// 见下面实现里的稳定排序（Dart 的 `List.sort` **不是稳定排序**，
/// 直接用会让「同起点多标记」的结果随内部实现变化）。
///
/// # 边界行为（全部有断言锁住 · 见 `scripts/trace_verify/`）
/// | 输入 | 行为 |
/// |---|---|
/// | `textLength <= 0` | 返回空列表 |
/// | `marks` 为空 | 单个 `TraceSpan(0, textLength, null)` —— 全文普通 |
/// | `start >= end` | 丢弃，计入 [TraceSplit.droppedInvalid] |
/// | `start < 0` / `end > textLength` | 截断到边界，计入 [TraceSplit.clampedOutOfRange] |
/// | 相邻相接（A.end == B.start） | **各自成段**，不合并（样式可能不同） |
/// | 重叠 | 先到者优先；后到者只取未覆盖部分 |
/// | 中间有空隙 | 空隙落成 `style == null` 的段 |
TraceSplit splitTraceSpans(int textLength, List<TraceMark> marks) {
  if (textLength <= 0) {
    return const TraceSplit(spans: []);
  }

  if (marks.isEmpty) {
    return TraceSplit(
      spans: [TraceSpan(start: 0, end: textLength)],
    );
  }

  var droppedInvalid = 0;
  var clamped = 0;
  var overlapped = 0;

  // ── ① 归一化：截断越界 + 剔除无效 ──
  final normalized = <({int start, int end, int order, TraceStyle style})>[];
  for (var i = 0; i < marks.length; i++) {
    final m = marks[i];
    if (m.start >= m.end) {
      droppedInvalid++;
      continue;
    }
    var s = m.start;
    var e = m.end;
    if (s < 0 || e > textLength) {
      clamped++;
      s = s.clamp(0, textLength);
      e = e.clamp(0, textLength);
      if (s >= e) {
        // 截断后不再是一个有效区间（整段都在文本之外）
        droppedInvalid++;
        continue;
      }
    }
    normalized.add((start: s, end: e, order: i, style: m.style));
  }

  // ── ② 稳定排序 ──
  // 🔑 Dart 的 `List.sort` **不稳定** → 同起点的多个标记顺序不确定。
  //    加 `order`（原始下标）做 tie-breaker，让「谁先被处理」由输入顺序决定，
  //    而不是由排序算法的内部实现决定 —— 否则同样输入可能出不同结果。
  normalized.sort((a, b) {
    final c = a.start.compareTo(b.start);
    if (c != 0) return c;
    // 同起点：**短区间优先**（更精确的标注优先于跨度更大的标注）——
    // 这条是**有意的策略**，不是随意选择（长区间多为「整句/整段」级标注，
    // 短区间多为「单个词」，词级标注更该胜出）。
    final byLen = (a.end - a.start).compareTo(b.end - b.start);
    if (byLen != 0) return byLen;
    return a.order.compareTo(b.order);
  });

  // ── ③ 落段：已覆盖到哪，就从哪继续 ──
  final spans = <TraceSpan>[];
  var cursor = 0;

  for (final m in normalized) {
    if (m.start >= textLength) {
      // 起点已在文本之外（理论上被 ① 处理过；防御性保留）
      droppedInvalid++;
      continue;
    }
    if (m.start < cursor) {
      // 与已覆盖区间重叠 → 只取后面那段未覆盖的
      overlapped++;
      if (m.end <= cursor) continue; // 完全被覆盖
      spans.add(TraceSpan(start: cursor, end: m.end, style: m.style));
      cursor = m.end;
      continue;
    }
    // 空隙 → 普通文字
    if (m.start > cursor) {
      spans.add(TraceSpan(start: cursor, end: m.start));
    }
    spans.add(TraceSpan(start: m.start, end: m.end, style: m.style));
    cursor = m.end;
  }

  // 尾巴
  if (cursor < textLength) {
    spans.add(TraceSpan(start: cursor, end: textLength));
  }

  return TraceSplit(
    spans: spans,
    droppedInvalid: droppedInvalid,
    clampedOutOfRange: clamped,
    overlapped: overlapped,
  );
}
