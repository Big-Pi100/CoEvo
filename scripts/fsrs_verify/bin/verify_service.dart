// CoEvo · `FsrsService` 验收（不是验证裸包，是验证**我们自己的服务层**）
//
// 与 verify.dart 的分工：
//   verify.dart         —— 验证 fsrs 包本身（四档单调 / elapsed / UTC 等）
//   verify_service.dart —— 验证 app/lib/services/fsrs_service.dart 的封装是否正确：
//                          · 预览与提交一致（确定性抖动）★ 本文件最核心的断言
//                          · 四档单调仍成立（服务层没有把它破坏）
//                          · maximumInterval = 365 天生效
//                          · 重放 / 同日去重 / 多端合并
//                          · 序列化往返
//
// 跑法：cd scripts/fsrs_verify && dart pub get && dart run bin/verify_service.dart
// 🔴 之所以能这样跑，是因为 `fsrs_service.dart` **不 import 任何 Flutter 包**。

import 'dart:io';

// 直接相对导入 app 的源码 —— 保证验证的是**实际要发布的实现**，不是副本
import '../../../app/lib/services/fsrs_service.dart';

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

void main() {
  // 固定时钟，避免测试依赖真实时间
  var fakeNow = DateTime.utc(2026, 9, 1, 9, 0, 0);
  final svc = FsrsService(clock: () => fakeNow);

  print('CoEvo · FsrsService 验收（验证服务层封装，非裸包）');
  print('=' * 68);

  // ── 1. 四档单调（服务层不能破坏它） ─────────────────────────
  print('\n【1】四档严格单调（服务层未破坏 fsrs 的行为）');
  var st = svc.newState('w000001', fakeNow);
  final preview = svc.previewAll(st, fakeNow);
  print('     新卡：${ReviewRating.values.map((r) => '${r.label}=${formatInterval(preview[r]!)}').join('  ')}');
  check(
    '新卡四档单调',
    preview[ReviewRating.again]!.inSeconds < preview[ReviewRating.hard]!.inSeconds &&
        preview[ReviewRating.hard]!.inSeconds < preview[ReviewRating.good]!.inSeconds &&
        preview[ReviewRating.good]!.inSeconds < preview[ReviewRating.easy]!.inSeconds,
  );

  // 复习几次变成熟卡
  for (var i = 0; i < 3; i++) {
    final r = svc.review(ReviewRating.good, st, fakeNow);
    st = r.state;
    fakeNow = st.nextReviewAt;
  }
  final mature = svc.previewAll(st, fakeNow);
  print('     熟卡：${ReviewRating.values.map((r) => '${r.label}=${formatInterval(mature[r]!)}').join('  ')}');
  check(
    '熟卡四档单调',
    mature[ReviewRating.again]!.inSeconds < mature[ReviewRating.hard]!.inSeconds &&
        mature[ReviewRating.hard]!.inSeconds < mature[ReviewRating.good]!.inSeconds &&
        mature[ReviewRating.good]!.inSeconds < mature[ReviewRating.easy]!.inSeconds,
  );

  // ── 2. ★ 核心：预览 == 提交（确定性抖动的意义） ─────────────
  print('\n【2】★ 预览与提交必须一致（这是自建确定性抖动替代 fsrs fuzz 的理由）');
  for (final r in ReviewRating.values) {
    final pv = svc.previewOne(r, st, fakeNow);
    final ap = svc.apply(r, st, fakeNow).nextReviewAt.difference(fakeNow);
    check(
      '${r.label}：预览 ${formatInterval(pv)} == 提交 ${formatInterval(ap)}',
      pv.inSeconds == ap.inSeconds,
      pv.inSeconds == ap.inSeconds ? '' : '差了 ${(pv - ap).inSeconds}s',
    );
  }

  // ── 3. 确定性抖动本身：同卡同结果，异卡不同结果 ──────────────
  print('\n【3】确定性抖动的性质：同卡稳定、异卡分散（避免到期撞车）');
  final p1 = svc.previewOne(ReviewRating.good, st, fakeNow);
  final p2 = svc.previewOne(ReviewRating.good, st, fakeNow);
  check('同一张卡两次预览完全相同', p1.inSeconds == p2.inSeconds);

  var st2 = svc.newState('w000002', fakeNow);
  for (var i = 0; i < 3; i++) {
    st2 = svc.review(ReviewRating.good, st2, fakeNow).state;
    fakeNow = st.nextReviewAt; // 同一时间基准
  }
  final other = svc.previewOne(ReviewRating.good, st2, fakeNow);
  check(
    '不同卡得到不同到期日（抖动确实在分散）',
    other.inSeconds != p1.inSeconds,
    'w000001=${formatInterval(p1)}  w000002=${formatInterval(other)}',
  );

  // ── 4. maximumInterval = 365 天 ────────────────────────────
  print('\n【4】maximumInterval = 365 天（防「5.8 年后再见」）');
  var long = svc.newState('w000003', fakeNow);
  var t = fakeNow;
  var maxSeen = Duration.zero;
  for (var i = 0; i < 12; i++) {
    final pv = svc.previewOne(ReviewRating.easy, long, t);
    if (pv > maxSeen) maxSeen = pv;
    final r = svc.review(ReviewRating.easy, long, t);
    long = r.state;
    t = long.nextReviewAt;
  }
  check('连评 12 次「熟练」后间隔 ≤ 365 天', maxSeen.inDays <= 365, '最大 ${maxSeen.inDays} 天');

  // ── 5. elapsed 敏感性 ──────────────────────────────────────
  print('\n【5】elapsed 敏感性（原自研实现此项完全失效）');
  final base = ReviewState(
    wordId: 'w000004',
    state: 2,
    stability: 9.0,
    difficulty: 5.0,
    lastReviewAt: DateTime.utc(2026, 8, 1),
    nextReviewAt: DateTime.utc(2026, 8, 10),
  );
  final r1 = svc.previewOne(ReviewRating.good, base, DateTime.utc(2026, 8, 2));
  final r365 = svc.previewOne(ReviewRating.good, base, DateTime.utc(2027, 8, 1));
  check('隔 1 天 ≠ 隔 365 天', r1.inSeconds != r365.inSeconds,
      '1天→${formatInterval(r1)}  365天→${formatInterval(r365)}');
  check('隔得越久下次越远', r365.inSeconds > r1.inSeconds);

  // ── 6. 「忘了」语义 ────────────────────────────────────────
  print('\n【6】评「忘了」必须很快回来（learningSteps 未失效）');
  final againNew = svc.previewOne(ReviewRating.again, svc.newState('w5', fakeNow), fakeNow);
  final againMature = svc.previewOne(ReviewRating.again, st, fakeNow);
  check('新卡「忘了」< 1 天', againNew.inHours < 24, formatInterval(againNew));
  check('熟卡「忘了」< 1 天', againMature.inHours < 24, formatInterval(againMature));
  final afterAgain = svc.apply(ReviewRating.again, st, fakeNow);
  check('熟卡「忘了」→ relearning（state=3）', afterAgain.state == 3, 'state=${afterAgain.state}');
  check('熟卡「忘了」→ lapses +1', afterAgain.lapses == st.lapses + 1);

  // ── 7. UTC 强制 ───────────────────────────────────────────
  print('\n【7】UTC 强制（fsrs 包只支持 UTC，提前给出更明确的错）');
  var threw = false;
  try {
    svc.previewOne(ReviewRating.good, st, DateTime(2026, 9, 1, 9)); // 本地时区
  } on ArgumentError {
    threw = true;
  }
  check('非 UTC → ArgumentError', threw);

  // ── 8. ★ 重放：同一天只保留最后一次 ─────────────────────────
  print('\n【8】★ 重放 + 同日（UTC）只保留最后一次');
  final day1 = DateTime.utc(2026, 9, 1, 9);
  // ⚠️ 事件序列必须**拉长到卡片毕业**（足够多的 good），
  //    否则卡停在 learning 状态，其 due 由固定 learningStep 决定、与 stability 无关 →
  //    此时比较 due 无法反映去重效果（这是第一版断言失败的原因，见文末教训）。
  final events = <ReviewEvent>[
    ReviewEvent(wordId: 'w000009', rating: ReviewRating.good, reviewedAt: day1, deviceId: 'A'),
    ReviewEvent(wordId: 'w000009', rating: ReviewRating.again,
        reviewedAt: day1.add(const Duration(hours: 5)), deviceId: 'B'), // ← 同一天，应被去重
    ReviewEvent(wordId: 'w000009', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 4, 9), deviceId: 'A'),
    ReviewEvent(wordId: 'w000009', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 6, 9), deviceId: 'A'),
    ReviewEvent(wordId: 'w000009', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 10, 9), deviceId: 'A'),
  ];
  final replayed = svc.replay('w000009', events, createdAt: day1);

  // 对照：全保留（不去重）
  var allApplied = svc.newState('w000009', day1);
  final sorted = [...events]..sort((a, b) => a.reviewedAt.compareTo(b.reviewedAt));
  for (final e in sorted) {
    allApplied = svc.apply(e.rating, allApplied, e.reviewedAt);
  }

  check('重放后已毕业（state=2 review）', replayed.state == 2, 'state=${replayed.state}');
  check(
    '同日去重生效：reps 少 1（5 条事件 → 4 次复习）',
    replayed.reps == 4 && allApplied.reps == 5,
    '去重=${replayed.reps} 不去重=${allApplied.reps}',
  );
  check(
    '同日去重生效：stability 不同（去重后更低，未叠加多余增益）',
    replayed.stability! < allApplied.stability!,
    '去重 S=${replayed.stability!.toStringAsFixed(3)} '
        '不去重 S=${allApplied.stability!.toStringAsFixed(3)}',
  );
  check(
    '同日去重生效：最终到期日不同',
    replayed.nextReviewAt != allApplied.nextReviewAt,
    '去重 due=${replayed.nextReviewAt.toIso8601String()} '
        '不去重 due=${allApplied.nextReviewAt.toIso8601String()}',
  );

  // ── 8b. 🔑 一个容易误判的事实：learning 阶段 due 由 learningStep 决定 ──
  print('\n【8b】learning 阶段 due 与 stability 无关（写断言时必须知道）');
  var learning = svc.newState('w8b', day1);
  learning = svc.apply(ReviewRating.again, learning, day1.add(const Duration(hours: 5)));
  learning = svc.apply(ReviewRating.good, learning, DateTime.utc(2026, 9, 4, 9));
  check('此时仍在 learning（未毕业）', learning.state == 1, 'state=${learning.state} step=${learning.step}');
  check(
    'learning 的 due = now + learningStep（10 分钟），与 S 无关',
    learning.nextReviewAt.difference(DateTime.utc(2026, 9, 4, 9)).inMinutes == 10,
    '间隔 ${learning.nextReviewAt.difference(DateTime.utc(2026, 9, 4, 9)).inMinutes} 分钟',
  );

  // ── 9. 重放幂等 ───────────────────────────────────────────
  print('\n【9】重放幂等：同一批事件重放两次结果一致');
  final again2 = svc.replay('w000009', events, createdAt: day1);
  check('两次重放 nextReviewAt 相同', replayed.nextReviewAt == again2.nextReviewAt);
  check('两次重放 stability 相同', replayed.stability == again2.stability);

  // ── 10. 多端合并 ──────────────────────────────────────────
  print('\n【10】多端合并：两端事件流合并不重复计');
  final devA = [
    ReviewEvent(wordId: 'w10', rating: ReviewRating.good, reviewedAt: DateTime.utc(2026, 9, 1, 9), deviceId: 'A'),
    ReviewEvent(wordId: 'w10', rating: ReviewRating.good, reviewedAt: DateTime.utc(2026, 9, 3, 9), deviceId: 'A'),
  ];
  final devB = [
    ReviewEvent(wordId: 'w10', rating: ReviewRating.hard, reviewedAt: DateTime.utc(2026, 9, 5, 9), deviceId: 'B'),
  ];
  final merged = svc.merge('w10', devA, devB, createdAt: DateTime.utc(2026, 9, 1, 9));
  check('合并后 reps = 3 天（9/1、9/3、9/5 各一次）', merged.reps == 3, 'reps=${merged.reps}');
  // 同一批数据合并两次（模拟重复拉取）结果不变
  final merged2 = svc.merge('w10', [...devA, ...devB], const [], createdAt: DateTime.utc(2026, 9, 1, 9));
  check('重复合并结果一致（幂等）', merged.nextReviewAt == merged2.nextReviewAt);

  // ── 11. 序列化往返 ────────────────────────────────────────
  print('\n【11】ReviewEvent / ReviewState 落库往返');
  final evRow = ReviewEvent(
    wordId: 'w11', rating: ReviewRating.hard,
    reviewedAt: DateTime.utc(2026, 9, 2, 8, 30), durationMs: 4200, deviceId: 'dev-1',
  );
  final evBack = ReviewEvent.fromRow({
    ...evRow.toRow(),
    'synced': 0,
  });
  check('ReviewEvent 往返 wordId', evBack.wordId == evRow.wordId);
  check('ReviewEvent 往返 rating', evBack.rating == evRow.rating);
  check('ReviewEvent 往返 reviewedAt', evBack.reviewedAt == evRow.reviewedAt);
  check('ReviewEvent 往返 deviceId', evBack.deviceId == evRow.deviceId);
  // 🔴 落库后必须仍是 UTC，否则重放会崩
  check('落库往返后仍是 UTC', evBack.reviewedAt.isUtc);

  final stRow = svc.apply(ReviewRating.good, st, fakeNow);
  check('ReviewState.nextReviewAt 是 UTC', stRow.nextReviewAt.isUtc);
  // 🔴 `toRow()` 需要 `spelling`（跨库方案 A 的冗余列，2026-09-26 起）——
  //    本脚本当时**没有跟着改** → 编译不过 → 整套 fsrs 验收**静默失效**
  //    （没人跑它，所以没人发现）。2026-09-28 修复。
  final rowMap = stRow.toRow(spelling: 'test');
  check('ReviewState.toRow 时间为 ISO8601 UTC',
      (rowMap['next_review_at']! as String).endsWith('Z'),
      rowMap['next_review_at']! as String);

  // ── 12. 四档译名（白哥定案） ───────────────────────────────
  print('\n【12】四档译名与英文副标题（白哥 2026-09-26 定）');
  check('Good 译「记得」不是「一般」', ReviewRating.good.label == '记得', ReviewRating.good.label);
  check('四档中文 = 忘了/困难/记得/熟练',
      ReviewRating.values.map((r) => r.label).join('/') == '忘了/困难/记得/熟练',
      ReviewRating.values.map((r) => r.label).join('/'));
  check('英文副标题保留',
      ReviewRating.values.map((r) => r.code).join('/') == 'again/hard/good/easy');

  // ── 13. retrievability ────────────────────────────────────
  print('\n【13】retrievability（列表熟度点 / 阅读痕迹用）');
  final justReviewed = svc.apply(ReviewRating.good, st, fakeNow);
  final rNow = svc.retrievability(justReviewed, fakeNow);
  check('刚复习完 R ≈ 1', rNow > 0.95, rNow.toStringAsFixed(4));
  final rLater = svc.retrievability(
      justReviewed, fakeNow.add(Duration(days: justReviewed.stability!.round())));
  check('距 = S 天时 R ≈ 0.9', (rLater - 0.9).abs() < 0.05, rLater.toStringAsFixed(4));
  check('未学卡 R = 0', svc.retrievability(svc.newState('w13', fakeNow), fakeNow) == 0);

  // ── 汇总 ──────────────────────────────────────────────────
  print('\n' + '=' * 68);
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    print('''
💡 排查技巧：如果是「重放 / 去重」类断言失败，先跑
     dart run bin/debug_replay.dart
   它会逐步打印 state / step / stability / due，一眼能看出卡在哪个状态。''');
    exit(1);
  }
  print('✅ FsrsService 全部通过');
  exit(0);
}
