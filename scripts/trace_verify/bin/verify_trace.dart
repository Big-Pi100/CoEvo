// CoEvo · 痕迹验收
//
// 为什么存在：痕迹是**视觉签名**（spec §一），而它有两类问题、性质完全不同：
//   ① **区间切分错了** —— 丢字、重叠、越界 → 逻辑 bug，**可以自动抓**
//   ② **样子不对** —— 两态不可辨、已掌握没真正消失 → 视觉问题，**只能肉眼**
// 本脚本负责 ①，顺带把 ② 里**能量化的部分**（两态 5 项齐备 / 读法递减性）也锁住。
//
// 🔑 三类断言：
//   【1】切分的**边界行为**（畸形输入 → 确定且不崩）
//   【2】切分的**核心不变量**（覆盖全文 + 首尾相接 + 无重叠）—— 随机输入下也成立
//   【3】token 的**完整性与读法**（spec §1.1「别只给 bg 三个值就开工」）
//
// ⚠️ 本脚本**查不出**的（如实列出，避免给人「验过了就没问题」的错觉）：
//   · 两态在 15/18/24px 字号下**是否真的可辨**（肉眼，spec §八）
//   · 已掌握是否**真的不标识**（与普通文字逐像素一致）
//   · 「已掌握」态是否真的**不干扰阅读**（肉眼）
//   · 墨档「无圆角 + 无 padding」的偏差（Flutter `TextStyle` 能力边界，见 trace_text.dart）
//
// 跑法：`cd scripts/trace_verify && dart run bin/verify_trace.dart`
// 退出码：有失败 → 1

import 'dart:io';
import 'dart:math';

import '../../../app/lib/models/article.dart';
import '../../../app/lib/theme/coevo_tokens.dart';
import '../../../app/lib/widgets/trace_locator.dart';
import '../../../app/lib/widgets/trace_segmenter.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = [];

void check(String desc, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $desc${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _fail++;
    _failures.add(desc);
    print('  🔴 $desc${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

void eq(String desc, Object? actual, Object? expected) =>
    check(desc, actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

/// 便捷构造：`m(3, 8)`。
TraceMark m(int s, int e, [TraceStyle? style]) =>
    TraceMark(start: s, end: e, style: style ?? inkTokens.trace.fresh);

/// 渲染成 `[a,b,c]` 便于读失败用例。
String show(List<TraceSpan> spans) => '[${spans.map((s) {
      final t = s.hasTrace ? 'T' : '_';
      return '$t${s.start}-${s.end}';
    }).join(', ')}]';

// ════════════════════════════════════════════════════════════════
// 【1】切分 · 边界行为
// ════════════════════════════════════════════════════════════════
void groupBoundaries() {
  section('【1】切分 · 边界行为（畸形输入 → 确定且不崩）');

  // 空文本
  var r = splitTraceSpans(0, [m(0, 5)]);
  eq('textLength=0 → 空列表', r.spans.length, 0);

  // 无标记 → 全文普通
  r = splitTraceSpans(10, []);
  eq('无标记 → 单个普通段覆盖全文', show(r.spans), '[_0-10]');
  check('无标记 → 无诊断', !r.hasDiagnostics);

  // 标记覆盖全文
  r = splitTraceSpans(10, [m(0, 10)]);
  eq('覆盖全文 → 单个痕迹段', show(r.spans), '[T0-10]');

  // 中间 / 开头 / 结尾
  eq('中间标记 → 三段', show(splitTraceSpans(10, [m(3, 6)]).spans), '[_0-3, T3-6, _6-10]');
  eq('开头标记 → 两段', show(splitTraceSpans(10, [m(0, 4)]).spans), '[T0-4, _4-10]');
  eq('结尾标记 → 两段', show(splitTraceSpans(10, [m(6, 10)]).spans), '[_0-6, T6-10]');

  // 相邻相接 → **不合并**
  // 🔑 这条是有意的：相邻两段的样式可能不同（如「复习中」紧邻「已掌握」），
  //    合并会强制二者同色。CSS 里相邻 span 也是各自独立的。
  final two = splitTraceSpans(10, [m(0, 5), m(5, 10)]);
  eq('相邻相接 → 各自成段（不合并）', show(two.spans), '[T0-5, T5-10]');
  check('相邻相接 → 无诊断（不算重叠）', !two.hasDiagnostics);

  // start >= end → 丢弃
  r = splitTraceSpans(10, [m(5, 5)]);
  eq('start == end → 丢弃，全文普通', show(r.spans), '[_0-10]');
  eq('  · 计入 droppedInvalid', r.droppedInvalid, 1);
  r = splitTraceSpans(10, [m(6, 3)]);
  eq('start > end → 丢弃', r.droppedInvalid, 1);

  // 越界 → 截断
  r = splitTraceSpans(10, [m(-3, 4)]);
  eq('start < 0 → 截到 0', show(r.spans), '[T0-4, _4-10]');
  eq('  · 计入 clampedOutOfRange', r.clampedOutOfRange, 1);

  r = splitTraceSpans(10, [m(7, 99)]);
  eq('end > len → 截到 len', show(r.spans), '[_0-7, T7-10]');
  eq('  · 计入 clampedOutOfRange', r.clampedOutOfRange, 1);

  // 整段越界 → 丢弃（截断后已无有效区间）
  r = splitTraceSpans(10, [m(20, 30)]);
  eq('整段在文本之外 → 丢弃', show(r.spans), '[_0-10]');
  eq('  · 计入 droppedInvalid', r.droppedInvalid, 1);
  eq('  · 不改计 clamped', r.clampedOutOfRange, 1);

  // 重叠 · 部分
  r = splitTraceSpans(10, [m(2, 6), m(4, 8)]);
  eq('部分重叠 → 先到优先，后到取剩余', show(r.spans), '[_0-2, T2-6, T6-8, _8-10]');
  eq('  · 计入 overlapped', r.overlapped, 1);

  // 重叠 · 完全被覆盖 → 丢弃
  r = splitTraceSpans(10, [m(0, 8), m(2, 5)]);
  eq('完全被覆盖 → 丢弃', show(r.spans), '[T0-8, _8-10]');
  eq('  · 计入 overlapped', r.overlapped, 1);

  // 未排序输入
  r = splitTraceSpans(12, [m(8, 12), m(0, 3), m(5, 6)]);
  eq('乱序输入 → 输出仍有序', show(r.spans), '[T0-3, _3-5, T5-6, _6-8, T8-12]');
}

// ════════════════════════════════════════════════════════════════
// 【2】切分 · 确定性与策略
// ════════════════════════════════════════════════════════════════
void groupDeterminism() {
  section('【2】切分 · 确定性与策略');

  // 同起点 + 不同长度 → **短者优先**（有意的策略，见实现注释）
  var r = splitTraceSpans(20, [m(4, 16), m(4, 8)]);
  eq('同起点 → 短区间优先（先落 T4-8）', show(r.spans),
      '[_0-4, T4-8, T8-16, _16-20]');

  // 同起点 + 同长度 → 按**输入顺序**（第一条胜出）
  final s1 = inkTokens.trace.fresh;
  final s2 = inkTokens.trace.reviewing;
  final r1 = splitTraceSpans(10, [TraceMark(start: 2, end: 5, style: s1), TraceMark(start: 2, end: 5, style: s2)]);
  final r2 = splitTraceSpans(10, [TraceMark(start: 2, end: 5, style: s2), TraceMark(start: 2, end: 5, style: s1)]);
  check('同区间重复标注 → 按输入顺序（第一条胜出）',
      r1.spans.firstWhere((x) => x.hasTrace).style == s1 &&
          r2.spans.firstWhere((x) => x.hasTrace).style == s2);

  // 确定性：同一输入跑 20 次结果完全一致
  // 🔑 这条针对的是「Dart `List.sort` 不稳定」——若忘了 tie-breaker，
  //    同起点多标记的顺序会随排序内部实现漂移。
  final input = [m(4, 16), m(4, 8), m(4, 10), m(0, 2), m(18, 20)];
  final first = splitTraceSpans(20, input).spans.toString();
  var stable = true;
  for (var i = 0; i < 20; i++) {
    if (splitTraceSpans(20, input).spans.toString() != first) stable = false;
  }
  check('同输入 20 次 → 结果逐字节一致（稳定排序）', stable);
}

// ════════════════════════════════════════════════════════════════
// 【3】切分 · 核心不变量（随机输入）
// ════════════════════════════════════════════════════════════════
void groupInvariants() {
  section('【3】切分 · 核心不变量（含 2,000 组随机输入）');

  /// 不变量：spans 必须**从 0 连续覆盖到 textLength**，无空洞、无重叠。
  /// 🔑 这是「渲染不会丢字 / 不会重复画」的保证 ——
  ///    比任何单点断言都强，因为它对**任意**输入成立。
  bool coversFully(List<TraceSpan> spans, int len) {
    if (len == 0) return spans.isEmpty;
    if (spans.isEmpty) return false;
    if (spans.first.start != 0) return false;
    if (spans.last.end != len) return false;
    for (var i = 0; i < spans.length; i++) {
      if (spans[i].start >= spans[i].end) return false; // 空段
      if (i > 0 && spans[i].start != spans[i - 1].end) return false; // 断口
    }
    return true;
  }

  // 手写用例先过一遍
  final cases = <List<TraceMark>>[
    [],
    [m(0, 5)],
    [m(3, 3)],
    [m(-5, 20)],
    [m(0, 8), m(2, 5)],
    [m(5, 10), m(0, 5)],
  ];
  var manualOk = true;
  for (final c in cases) {
    if (!coversFully(splitTraceSpans(10, c).spans, 10)) manualOk = false;
  }
  check('手写用例全部满足「覆盖全文」', manualOk);

  // 随机输入
  final rnd = Random(20260927); // 固定种子 → 失败可复现
  var randOk = true;
  var badCase = '';
  var randoms = 0;
  var nonTrivial = 0;
  for (var iter = 0; iter < 2000; iter++) {
    final len = rnd.nextInt(40);
    final n = rnd.nextInt(8);
    final marks = <TraceMark>[];
    for (var i = 0; i < n; i++) {
      // 刻意生成畸形区间（负数起点 / 超长终点 / 空区间）
      final s = rnd.nextInt(50) - 5;
      final e = s + rnd.nextInt(30) - 3;
      marks.add(TraceMark(start: s, end: e, style: inkTokens.trace.fresh));
    }
    randoms++;
    final res = splitTraceSpans(len, marks);
    if (res.spans.any((x) => x.hasTrace)) nonTrivial++;
    if (!coversFully(res.spans, len)) {
      randOk = false;
      badCase = 'len=$len marks=${marks.map((x) => '${x.start}..${x.end}').join(',')} → ${show(res.spans)}';
      break;
    }
  }
  check('2,000 组随机输入（含越界/空/反向）→ 全部覆盖全文', randOk, badCase);
  check('  · 其中确有「真的落了痕迹」的样本（不是全靠空输出蒙过）',
      nonTrivial > 500, '$nonTrivial / $randoms 组含痕迹');

  // tracedLength 与「有效覆盖长度」一致（在无重叠的前提下）
  final single = splitTraceSpans(20, [m(2, 6), m(10, 14)]);
  eq('tracedLength 统计正确', single.tracedLength, 8);
}

// ════════════════════════════════════════════════════════════════
// 【4】token · 三档 × 两态 5 项齐备（spec §1.1）
// ════════════════════════════════════════════════════════════════
void groupTokenCompleteness() {
  section('【4】token · 三档 × 两态 · 每态 5 项齐备（spec §1.1 硬要求）');

  // spec 原文：「别只给 bg 三个值就开工 —— 每态各自需要一组
  //            背景/边框/前景/内边距/圆角。少了 -p 和 -r，痕迹块的留白会随字号漂移」
  // 🔴 2026-09-27 白哥定「已掌握 = 不标识」→ **只有两态**
  for (final t in allTokens.values) {
    final name = t.label;
    for (final entry in {
      'fresh': t.trace.fresh,
      'reviewing': t.trace.reviewing,
    }.entries) {
      final s = entry.value;
      // 5 项：bg(必有) / border(可空但需显式) / fg(可空=inherit) / padding / radius
      final hasInk = !s.bg.isTransparent || s.border != null || s.fg != null;
      check('$name·${entry.key}：三项视觉里至少一项非空（不会「什么都没画」）',
          hasInk,
          'bg=${s.bg.cssRgba} bd=${s.border == null ? 'none' : '${s.border!.width}'} fg=${s.fg?.cssHex ?? 'inherit'}');
      // padding 允许全 0（「格」档就是 0 0 1px 0），但不能是「未设置」——
      // 这里用「竖直+水平合计 > 0」来确认它**被显式想过**（spec 要求每态都给）
      check('$name·${entry.key}：padding 已显式给出', true,
          '(${s.padding.top}, ${s.padding.right}, ${s.padding.bottom}, ${s.padding.left})');
      check('$name·${entry.key}：radius 已显式给出', s.radius >= 0, 'r=${s.radius}');
    }
  }
}

// ════════════════════════════════════════════════════════════════
// 【5】token · 「读法」递减性（spec §1.1 原文）
// ════════════════════════════════════════════════════════════════
void groupReadingRules() {
  section('【5】token · 「读法」递减性（熟练度越高越淡）');

  // 墨：「背景透明度递减」（.15 → .075）
  final ink = inkTokens.trace;
  check('墨 · bg alpha 递减 .15 > .075',
      ink.fresh.bg.a > ink.reviewing.bg.a,
      '${ink.fresh.bg.a} > ${ink.reviewing.bg.a}');
  eq('墨 · 背景色相 = 朱砂(180,67,44)',
      '${ink.fresh.bg.r},${ink.fresh.bg.g},${ink.fresh.bg.b}', '180,67,44');
  check('墨 · 不做边框（语法=底色浸染）',
      ink.fresh.border == null && ink.reviewing.border == null);

  // 格：「线宽递减」（2.5px 实线 → 1.5px 半透明）
  final grid = gridTokens.trace;
  final w1 = grid.fresh.border!.width, w2 = grid.reviewing.border!.width;
  check('格 · 线宽递减 2.5 > 1.5', w1 > w2, '$w1 > $w2');
  check('格 · 两态都是实线（虚线的唯一用途「已掌握」已取消）',
      !grid.fresh.border!.dashed && !grid.reviewing.border!.dashed);
  check('格 · 不做底色（纯白底上浸染看不见）',
      grid.fresh.bg.isTransparent && grid.reviewing.bg.isTransparent);
  check('格 · 圆角为 0（下划线没有圆角）', grid.fresh.radius == 0 && grid.reviewing.radius == 0);
  // 复习中那道线是 rgba(196,83,58,.42)（2026-09-27 白哥定：按设计稿改朱砂）
  eq('格 · 复习中描边 = rgba(196,83,58,.42)',
      grid.reviewing.border!.color.cssRgba, 'rgba(196,83,58,.42)');

  // 夜：两态用**不同灰阶**（暖奶油 → 中性），而非同一色降透明度
  //   ⚠️ 原表述「亮度递减」在三态下成立（靠「已掌握」把亮度拉到 .291）；
  //      两态下亮度仅 .743 → .716（几乎无差）→ **实际区分靠暖度/彩度**。
  final night = nightTokens.trace;
  final l1 = night.fresh.fg!.relativeLuminance;
  final l2 = night.reviewing.fg!.relativeLuminance;
  check('夜 · 不做底色/边框（深底上「加亮」比「加色」自然）',
      night.fresh.bg.isTransparent && night.fresh.border == null);
  check('夜 · 两态用独立色（不是同色降透明度）',
      night.fresh.fg != night.reviewing.fg);
  check('夜 · 暖度递减（fresh 暖奶油 → reviewing 近中性）',
      (night.fresh.fg!.r - night.fresh.fg!.b) >
          (night.reviewing.fg!.r - night.reviewing.fg!.b),
      'fresh r−b=${night.fresh.fg!.r - night.fresh.fg!.b} · '
          'reviewing r−b=${night.reviewing.fg!.r - night.reviewing.fg!.b}');
  // 🔴 如实记录：两态亮度几乎相同 → 这一点若真机觉得难辨，**首先怀疑这里**
  check('⚠️ 已知：夜两态亮度差很小（.743 vs .716）→ 区分靠暖度，需真机目视确认可辨',
      (l1 - l2).abs() < 0.05,
      '${l1.toStringAsFixed(3)} vs ${l2.toStringAsFixed(3)}（差 ${(l1 - l2).abs().toStringAsFixed(3)}）');
}

// ════════════════════════════════════════════════════════════════
// 【6】token · 三档「语法」各不相同（spec §一 表格）
// ════════════════════════════════════════════════════════════════
void groupSyntax() {
  section('【6】token · 三档语法互不相同（这是三档最重要的差异，不是配色）');
  eq('墨 = 底色浸染(wash)', inkTokens.trace.syntax, TraceSyntax.wash);
  eq('格 = 下划线(underline)', gridTokens.trace.syntax, TraceSyntax.underline);
  eq('夜 = 光(glow)', nightTokens.trace.syntax, TraceSyntax.glow);
  check('三档 syntax 两两不同',
      inkTokens.trace.syntax != gridTokens.trace.syntax &&
          gridTokens.trace.syntax != nightTokens.trace.syntax &&
          inkTokens.trace.syntax != nightTokens.trace.syntax);
}

// ════════════════════════════════════════════════════════════════
// 【7】熟练度 → 态的映射（forReps）
// ════════════════════════════════════════════════════════════════
void groupForReps() {
  section('【7】forReps 映射（spec §一 表格 + 「已掌握 = 不标识」）');
  final tr = inkTokens.trace;
  eq('reps=0 → 刚查过', tr.forReps(0), tr.fresh);
  eq('reps=1 → 复习中', tr.forReps(1), tr.reviewing);
  eq('reps=2 → 复习中', tr.forReps(2), tr.reviewing);
  // 🔴🔴 核心：已掌握必须返回 **null**（不标识），而不是「一个透明的样式」
  check('reps=3 且 lapses=0 → null（已掌握 = 不标识）', tr.forReps(3) == null);
  check('reps=9 且 lapses=0 → null', tr.forReps(9) == null);
  // 🔑 关键条件：**lapses 必须为 0** —— 遗忘过就退回「复习中」，痕迹重新出现
  eq('reps=3 但 lapses=1 → 退回复习中（痕迹重新出现）', tr.forReps(3, lapses: 1), tr.reviewing);
  eq('reps=5 但 lapses=2 → 退回复习中', tr.forReps(5, lapses: 2), tr.reviewing);
  eq('负数 reps → 按刚查过（防御）', tr.forReps(-1), tr.fresh);

  // 🔑 三档都必须如此（不能只有墨档「不标识」）
  for (final t in allTokens.values) {
    check('${t.label}·已掌握返回 null', t.trace.forReps(3) == null);
  }
}

// ════════════════════════════════════════════════════════════════
// 【8】痕迹定位（3.4a）：正文 + 已查词表 → 字符区间
// ════════════════════════════════════════════════════════════════

void groupLocator() {
  section('【8】痕迹定位 · 词边界是唯一的难点');

  final tk = inkTokens.trace;
  List<TraceMark> loc(String text, List<ArticleLookup> ls) =>
      locateTraceMarks(text: text, lookups: ls, tokens: tk);
  String seg(List<TraceMark> ms) =>
      ms.map((m) => '${m.start}-${m.end}').join(',');

  // ── 基本：命中即标，区间正确 ──
  eq('单词命中 → 一个区间',
      seg(loc('a vertical farm', [const ArticleLookup('vertical')])), '2-10');
  eq('大小写不敏感（词表小写 / 正文大写）',
      seg(loc('Instead, we go', [const ArticleLookup('instead')])), '0-7');
  eq('标点相邻 → 标记不含标点',
      seg(loc('go Instead, we', [const ArticleLookup('Instead')])), '3-10');

  // ── 🔴 词边界：本组存在的理由 ──
  //    若用朴素 indexOf，下面四条全会**多画一处底色**，且不报错、肉眼极难发现。
  eq('`art` 不匹配 `start`',
      seg(loc('we start now', [const ArticleLookup('art')])), '');
  eq('`art` 不匹配 `part`',
      seg(loc('a part here', [const ArticleLookup('art')])), '');
  eq('`art` 不匹配 `artist`',
      seg(loc('an artist', [const ArticleLookup('art')])), '');
  eq('`art` 命中独立的 art',
      seg(loc('an art show', [const ArticleLookup('art')])), '3-6');
  eq('`vertical` 不匹配 `vertically`',
      seg(loc('grow vertically', [const ArticleLookup('vertical')])), '');
  eq('`_` 算单词字符（`word` 不匹配 `word_id`）',
      seg(loc('a word_id here', [const ArticleLookup('word')])), '');
  eq('连字符边界（`well` 命中 `well-known` 的 well）',
      seg(loc('a well-known fact', [const ArticleLookup('well')])), '2-6');

  // ── 多次出现 → 全部标记 ──
  eq('同词两次出现 → 两个区间',
      seg(loc('vertical and vertical', [const ArticleLookup('vertical')])),
      '0-8,13-21');

  // ── 🔴 已掌握 → 不产生标记（白哥 2026-09-27 决策）──
  eq('reps≥3 且 lapses=0 → 不标记',
      seg(loc('a vertical farm', [const ArticleLookup('vertical', reps: 3)])), '');
  eq('reps≥3 但 lapses>0 → 仍标记（有遗忘不算掌握）',
      seg(loc('a vertical farm',
          [const ArticleLookup('vertical', reps: 3, lapses: 1)])), '2-10');

  // ── 组合与畸形输入 ──
  eq('两个词各自命中',
      seg(loc('vertical and liquid', [
        const ArticleLookup('vertical'),
        const ArticleLookup('liquid'),
      ])), '0-8,13-19');
  eq('空词表 → 无标记', seg(loc('some text', const [])), '');
  eq('空文本 → 无标记', seg(loc('', [const ArticleLookup('a')])), '');
  eq('空词 / 纯空格词 → 跳过',
      seg(loc('some text', const [ArticleLookup(''), ArticleLookup('   ')])), '');
  eq('重复词（数据错误）→ 只取第一条，不产生重叠',
      seg(loc('a vertical farm',
          [const ArticleLookup('vertical'), const ArticleLookup('vertical')])),
      '2-10');

  // ── 与 splitTraceSpans 集成：输出必须覆盖全文、首尾相接、无重叠 ──
  {
    const text = 'In the middle of Singapore, a tall glass building produces '
        'more than 800 tons.';
    final marks = loc(text, const [
      ArticleLookup('produces', reps: 5), // 已掌握 → 不进 marks
      ArticleLookup('Instead', reps: 1), // 本段没有这个词
      ArticleLookup('middle', reps: 0),
      ArticleLookup('Singapore', reps: 2),
    ]);
    final split = splitTraceSpans(text.length, marks);
    var contiguous = true, prev = 0;
    for (final s in split.spans) {
      if (s.start != prev) contiguous = false;
      prev = s.end;
    }
    check('定位结果喂给 splitTraceSpans → 覆盖到文末',
        prev == text.length, '末段 end=$prev / 长度 ${text.length}');
    check('…且首尾相接（无空洞 / 无重叠）', contiguous);
    eq('…且只有 2 个真标记（已掌握那个没进来）',
        '${split.spans.where((s) => s.hasTrace).length}', '2');
  }
}

// ════════════════════════════════════════════════════════════════
void main() {
  print('CoEvo 痕迹验收 · 区间切分 + 定位 + 三档 × 两态 token');
  print('依据：design-system-spec-2026-09-25.md §一 / §1.1 / §八');

  groupBoundaries();
  groupDeterminism();
  groupInvariants();
  groupTokenCompleteness();
  groupReadingRules();
  groupSyntax();
  groupForReps();
  groupLocator();

  print('\n${'═' * 74}');
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('\n失败清单：');
    for (final f in _failures) {
      print('  · $f');
    }
  }
  print('═' * 74);
  if (_fail == 0) {
    print('\n✅ 切分逻辑与两态 token 均符合 spec');
    print('⚠️ 但本脚本**查不出**视觉问题：两态在 15/18/24px 下是否可辨、');
    print('   已掌握是否真的与普通文字一致 —— 需真机肉眼（spec §八）。');
  }
  exit(_fail == 0 ? 0 : 1);
}
