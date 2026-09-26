// CoEvo · FSRS 调度验收
//
// 为什么存在：2026-09-26 审计发现自研 `fsrs5.rs` 的**四档单调性全反**
//   （「熟练」比「一般」更早重来）+ **elapsed 被忽略**（间隔与"隔了多久"无关）。
//   这个 bug 能存在的直接原因 = **没有任何测试断言过「四档单调」**。
//   → 白哥 2026-09-26 决策：「四档单调性单测」作为**强制项**。
//
// 本脚本是纯 Dart、零 Flutter 依赖，可在任何装了 Dart 的机器上跑：
//   cd scripts/fsrs_verify && dart pub get && dart run bin/verify.dart
//
// 退出码 0 = 全部通过；1 = 有断言失败（可挂进 CI）。
//
// ⚠️ 时间一律 UTC —— fsrs 包对非 UTC 的 reviewDateTime 会直接抛错。

import 'dart:io';
import 'package:fsrs/fsrs.dart';

// ─────────────────────────── 断言框架 ───────────────────────────
var _pass = 0;
var _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $name${detail.isEmpty ? '' : '  —— $detail'}');
  } else {
    _fail++;
    _failures.add(name);
    print('  🔴 $name${detail.isEmpty ? '' : '  —— $detail'}');
  }
}

// ─────────────────────────── 工具 ───────────────────────────
String fmt(Duration d) {
  if (d.inSeconds < 3600) return '${d.inMinutes} 分钟';
  if (d.inHours < 24) return '${(d.inMinutes / 60).toStringAsFixed(1)} 小时';
  if (d.inDays < 30) return '${d.inDays} 天';
  if (d.inDays < 365) return '${(d.inDays / 30.44).toStringAsFixed(1)} 个月';
  return '${(d.inDays / 365).toStringAsFixed(1)} 年';
}

/// 预览四档 —— 与 App 里按钮上「下次 X 天」用的是同一段逻辑。
/// 依赖：fsrs 的 `reviewCard()` 内部先 copyWith，**不改原卡**。
Map<Rating, Duration> previewIntervals(
  Scheduler s,
  Card card,
  DateTime nowUtc,
) {
  assert(nowUtc.isUtc, 'nowUtc 必须是 UTC');
  final out = <Rating, Duration>{};
  final before = card.due; // 用于验证原卡未被改动
  for (final r in Rating.values) {
    out[r] =
        s.reviewCard(card, r, reviewDateTime: nowUtc).card.due.difference(nowUtc);
  }
  assert(card.due == before, 'reviewCard 不应改动原卡');
  return out;
}

bool monotonic(Map<Rating, Duration> m) =>
    m[Rating.again]!.inSeconds < m[Rating.hard]!.inSeconds &&
    m[Rating.hard]!.inSeconds < m[Rating.good]!.inSeconds &&
    m[Rating.good]!.inSeconds < m[Rating.easy]!.inSeconds;

String show(Map<Rating, Duration> m) => Rating.values
    .map((r) => '${r.name}=${fmt(m[r]!)}')
    .join('  ');

/// 造一张「已复习若干次」的卡
(Card, DateTime) graduate(Scheduler s, DateTime t0, int times) {
  var card = Card(cardId: 1);
  var now = t0;
  for (var i = 0; i < times; i++) {
    card = s.reviewCard(card, Rating.good, reviewDateTime: now).card;
    now = card.due;
  }
  return (card, now);
}

// ─────────────────────────── 主流程 ───────────────────────────
void main() {
  // 关 fuzz：预览要确定性数字（App 里预览也这么做，提交时才开 fuzz）
  final s = Scheduler(enableFuzzing: false);
  final t0 = DateTime.utc(2026, 9, 1, 9, 0, 0);

  print('CoEvo · FSRS 调度验收（fsrs 包 · 关 fuzz）');
  print('=' * 66);

  // ── 1. 四档严格单调（3 种状态） ────────────────────────────
  print('\n【1】四档严格单调 again < hard < good < easy');
  final states = <String, (Card, DateTime)>{
    '全新卡(learning)': (Card(cardId: 1), t0),
    '复习 1 次': graduate(s, t0, 1),
    '复习 3 次(review)': graduate(s, t0, 3),
    '复习 6 次(成熟)': graduate(s, t0, 6),
  };
  states.forEach((label, pair) {
    final m = previewIntervals(s, pair.$1, pair.$2);
    check('单调性 · $label', monotonic(m), show(m));
  });

  // ── 2. elapsed 敏感性 ──────────────────────────────────────
  print('\n【2】elapsed 敏感性：隔得越久，下次越远（🔴 原自研实现此项完全失效）');
  final base = Card(
    cardId: 2,
    state: State.review,
    stability: 9.0,
    difficulty: 5.0,
    lastReview: DateTime.utc(2026, 8, 1),
    due: DateTime.utc(2026, 8, 10),
  );
  final gapDays = <int, Duration>{};
  for (final g in [1, 9, 30, 365]) {
    final at = DateTime.utc(2026, 8, 1).add(Duration(days: g));
    gapDays[g] =
        s.reviewCard(base, Rating.good, reviewDateTime: at).card.due.difference(at);
    print('     距上次 ${g.toString().padLeft(3)} 天 → ${fmt(gapDays[g]!)}');
  }
  check(
    'elapsed 改变结果（1 天 ≠ 365 天）',
    gapDays[1]!.inSeconds != gapDays[365]!.inSeconds,
  );
  check('elapsed 单调（365 天 > 30 天 > 9 天 > 1 天）',
      gapDays[365]!.inSeconds > gapDays[30]!.inSeconds &&
          gapDays[30]!.inSeconds > gapDays[9]!.inSeconds &&
          gapDays[9]!.inSeconds > gapDays[1]!.inSeconds);

  // ── 3. 同日重复复习不暴涨 ──────────────────────────────────
  print('\n【3】同日重复评 Good 4 次，间隔不应暴涨（🔴 原自研实现第 4 次达 480 天）');
  var c3 = Card(cardId: 3);
  var n3 = t0;
  final sameDay = <Duration>[];
  for (var i = 0; i < 4; i++) {
    final res = s.reviewCard(c3, Rating.good, reviewDateTime: n3); // 同一时刻
    sameDay.add(res.card.due.difference(n3));
    c3 = res.card;
  }
  print('     ${sameDay.asMap().entries.map((e) => '第${e.key + 1}次=${fmt(e.value)}').join('  ')}');
  print('     （第 1 次是 learningStep 固定间隔，不作基准；'
      '同一天内 R≈1 → 稳定性不再增长 → 第 2 次后应趋于稳定）');
  check(
    '同日重复不暴涨（第 4 次 ≤ 第 2 次 × 2）',
    sameDay[3]!.inSeconds <= sameDay[1]!.inSeconds * 2,
    '第2次=${fmt(sameDay[1]!)} 第4次=${fmt(sameDay[3]!)}',
  );
  check(
    '同日重复不持续翻倍（第 3、4 次 ≤ 第 2 次）',
    sameDay[2]!.inSeconds <= sameDay[1]!.inSeconds &&
        sameDay[3]!.inSeconds <= sameDay[1]!.inSeconds,
  );

  // ── 4. 「忘了」语义：必须很快回来 ───────────────────────────
  print('\n【4】评「忘了」后必须 < 1 天回来（若 = 1 天以上说明 learningSteps 被禁用）');
  final a1 = s.reviewCard(Card(cardId: 4), Rating.again, reviewDateTime: t0);
  final a1d = a1.card.due.difference(t0);
  check('新卡「忘了」 < 1 天', a1d.inHours < 24, fmt(a1d));
  final mature = graduate(s, t0, 3);
  final a2 = s.reviewCard(mature.$1, Rating.again, reviewDateTime: mature.$2);
  final a2d = a2.card.due.difference(mature.$2);
  check('成熟卡「忘了」 < 1 天', a2d.inHours < 24, fmt(a2d));
  check('成熟卡「忘了」进入 relearning', a2.card.state == State.relearning);

  // ── 5. UTC 强制 ───────────────────────────────────────────
  print('\n【5】非 UTC 时间必须抛错（防止线上踩坑）');
  var threw = false;
  try {
    s.reviewCard(Card(cardId: 5), Rating.good,
        reviewDateTime: DateTime(2026, 9, 1, 9)); // 本地时区
  } on ArgumentError {
    threw = true;
  }
  check('非 UTC → ArgumentError', threw);

  // ── 6. retrievability ─────────────────────────────────────
  print('\n【6】retrievability：距 = S 天时应 ≈ desiredRetention(0.9)');
  final r9 = s.getCardRetrievability(
      base, currentDateTime: DateTime.utc(2026, 8, 1).add(const Duration(days: 9)));
  check('R(9天, S=9) ≈ 0.90', (r9 - 0.9).abs() < 0.02, r9.toStringAsFixed(4));
  final r0 = s.getCardRetrievability(
      base, currentDateTime: DateTime.utc(2026, 8, 1).add(const Duration(minutes: 1)));
  check('R(刚复习完) > 0.95', r0 > 0.95, r0.toStringAsFixed(4));

  // ── 7. 预览不改原卡 ────────────────────────────────────────
  print('\n【7】预览四档不得改动原卡（App 靠这个特性预览）');
  final gc = graduate(s, t0, 3);
  final beforeDue = gc.$1.due;
  final beforeS = gc.$1.stability;
  previewIntervals(s, gc.$1, gc.$2);
  check('预览后 due 不变', gc.$1.due == beforeDue);
  check('预览后 stability 不变', gc.$1.stability == beforeS);

  // ── 8. 序列化往返 ──────────────────────────────────────────
  print('\n【8】Card/Scheduler toMap ↔ fromMap 往返一致（落库要用）');
  final map = gc.$1.toMap();
  final back = Card.fromMap(map);
  check('Card 往返 due 一致', back.due == gc.$1.due);
  check('Card 往返 stability 一致', back.stability == gc.$1.stability);
  check('Card 往返 state 一致', back.state == gc.$1.state);

  // ── 汇总 ──────────────────────────────────────────────────
  print('\n' + '=' * 66);
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exit(1);
  }
  print('✅ 全部通过 —— FSRS 调度符合预期');
  exit(0);
}
