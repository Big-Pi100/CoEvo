// CoEvo · 端侧 FSRS 调度服务
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**。
//   理由：本地 Flutter 是鸿蒙定制版、`flutter analyze` 会因 Windows 管道耗尽崩溃，
//   纯 Dart 才能本地独立跑验证（见 scripts/fsrs_verify/）。
//
// 依据：docs/design/fsrs-client-side-migration-plan-2026-09-26.md
//   · 端侧权威（v1 §10.1「本地计算」）
//   · maximumInterval = 365 天
//   · learningSteps = [1 分钟, 10 分钟]
//   · 多端同步 = 事件日志 + 重放；同日（UTC）只保留最后一次
//
// 🔑 三个容易踩的点（已在 scripts/fsrs_verify 用断言锁住）：
//   1. fsrs 包**只支持 UTC** —— 非 UTC 的 `reviewDateTime` 会抛 ArgumentError
//   2. `reviewCard()` 内部先 `copyWith()`，**不改原卡** → 对四档各调一次即可预览
//   3. **不要开 fsrs 自带的 fuzz**（`enableFuzzing`）—— 它是有状态随机，
//      会让「预览」与「提交」算出不同数字。改用下面的**确定性抖动**。

import 'dart:math' as math;

import 'package:fsrs/fsrs.dart';

/// 最大间隔 = 365 天。
///
/// 官方默认 36500 天（100 年），但实测连续评 Good **第 6 次就排到 5.8 年** ——
/// 对「英语学习」场景等于「不再复习」。压到 1 年，用户一年后还会再见一次。
const int kMaxIntervalDays = 365;

/// 学习步（新卡在 learning 状态内的短间隔）。
///
/// ⚠️ **绝不能设成空数组** —— 实测会让「忘了」变成 **1 天**，
/// 与按钮语义（"马上重来"）直接矛盾。见 `scripts/fsrs_verify` 的断言 4。
const List<Duration> kLearningSteps = [
  Duration(minutes: 1),
  Duration(minutes: 10),
];

/// 重学步（从 review 掉到 relearning 时的短间隔）。
const List<Duration> kRelearningSteps = [
  Duration(minutes: 10),
];

/// 目标保留率。固定 0.9 —— 是基础体验，不作订阅权益。
const double kDesiredRetention = 0.9;

/// 确定性抖动的开关。
///
/// 目的：避免大量卡片到期日撞在同一天。
/// 与官方 fuzz 的区别：**按 cardId 哈希算，同一张卡永远同样的抖动** →
/// 预览与提交一致。因此本服务关掉 fsrs 自带 fuzz，改用这个。
const bool kEnableDeterministicFuzz = true;

/// 抖动幅度：间隔的 2.5%，上限 ±3 天；间隔 < 3 天不动。
const double _kFuzzRatio = 0.025;
const int _kFuzzCapDays = 3;
const int _kFuzzMinIntervalDays = 3;

// ───────────────────────── 评分四档 ─────────────────────────

/// 四档自评（对外类型，UI 只依赖它，不直接依赖 fsrs 包的 enum）。
enum ReviewRating {
  again(1, '忘了', 'again'),
  hard(2, '困难', 'hard'),
  good(3, '记得', 'good'),
  easy(4, '熟练', 'easy');

  const ReviewRating(this.value, this.label, this.code);

  /// 与 fsrs 包的 `Rating` 数值一致（1–4），也是 `review_log.rating` 的取值。
  final int value;

  /// UI 按钮中文（白哥 2026-09-26 定：`Good` 译「记得」而非「一般」）。
  final String label;

  /// 英文副标题（白哥定：保留）。
  final String code;

  static ReviewRating fromValue(int v) => switch (v) {
        1 => ReviewRating.again,
        2 => ReviewRating.hard,
        3 => ReviewRating.good,
        4 => ReviewRating.easy,
        _ => throw ArgumentError('rating 必须在 1–4，收到 $v'),
      };

  Rating get fsrs => Rating.fromValue(value);
}

// ───────────────────────── 数据模型 ─────────────────────────

/// 复习状态行 —— 对应 `user.db.card_review_state`（v1 §3.2）。
class ReviewState {
  ReviewState({
    required this.wordId,
    this.state = 0,
    this.step,
    this.stability,
    this.difficulty,
    this.reps = 0,
    this.lapses = 0,
    this.lastReviewAt,
    required this.nextReviewAt,
    this.pendingPush = 1,
  });

  /// 词库 `word.id`（TEXT，如 `w008732`）。
  final String wordId;

  /// 0 = 未学（包内无此态）；1 = learning；2 = review；3 = relearning
  int state;
  int? step;
  double? stability;
  double? difficulty;
  int reps;
  int lapses;

  /// UTC
  DateTime? lastReviewAt;

  /// UTC
  DateTime nextReviewAt;

  /// 待同步标记
  int pendingPush;

  /// 是否已到期（`nowUtc` 必须 UTC）
  bool isDue(DateTime nowUtc) => !nextReviewAt.isAfter(nowUtc.toUtc());

  /// 距到期的时长（负数 = 已过期）
  Duration untilDue(DateTime nowUtc) => nextReviewAt.difference(nowUtc.toUtc());

  /// 转为 `user.db.card_review_state` 的一行。
  ///
  /// `spelling` 是**冗余字段**（跨库方案 A，2026-09-26 白哥已定）：
  /// 复习列表要显示单词并支持按单词搜索，而本库只有 `word_id`。
  /// 冗余后列表渲染与搜索**完全不碰 word.db**（只有取释义才按需查它）。
  ///
  /// 🔑 刻意**不把 `spelling` 放进 `ReviewState` 字段** —— 那是 FSRS 状态，
  /// 与展示字段无关；由调用方（刚查完词、知道拼写）显式传入，
  /// 让「持久化需要拼写」这件事由**编译器强制**，而不是靠注释提醒。
  Map<String, Object?> toRow({required String spelling}) => {
        'word_id': wordId,
        'spelling': spelling,
        'state': state,
        'step': step,
        'stability': stability,
        'difficulty': difficulty,
        'reps': reps,
        'lapses': lapses,
        'last_review_at': lastReviewAt?.toUtc().toIso8601String(),
        'next_review_at': nextReviewAt.toUtc().toIso8601String(),
      };

  /// 从 DB 行恢复（`spelling` 由调用方另行持有，不参与 FSRS 状态）。
  static ReviewState fromRow(Map<String, Object?> row) => ReviewState(
        wordId: row['word_id']! as String,
        state: (row['state'] as int?) ?? 0,
        step: row['step'] as int?,
        stability: (row['stability'] as num?)?.toDouble(),
        difficulty: (row['difficulty'] as num?)?.toDouble(),
        reps: (row['reps'] as int?) ?? 0,
        lapses: (row['lapses'] as int?) ?? 0,
        lastReviewAt: _parseUtc(row['last_review_at'] as String?),
        nextReviewAt: _parseUtc(row['next_review_at'] as String?) ?? DateTime.now().toUtc(),
        pendingPush: (row['pending_push'] as int?) ?? 1,
      );

  static DateTime? _parseUtc(String? s) {
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toUtc();
  }
}

/// 复习事件 —— 对应 `user.db.review_log`，**也是多端同步的最小单位**。
///
/// 多端同步选「事件日志 + 重放」：各端只同步本表行，按时间序重放得权威状态。
class ReviewEvent {
  ReviewEvent({
    required this.wordId,
    required this.rating,
    required this.reviewedAt,
    this.durationMs,
    this.deviceId,
    this.synced = 0,
  });

  final String wordId;
  final ReviewRating rating;

  /// UTC
  final DateTime reviewedAt;

  final int? durationMs;

  /// 产生该事件的设备（冲突判定用）
  final String? deviceId;

  /// 0 = 待上传；1 = 已同步
  int synced;

  /// 同日（UTC 日历日）去重用的键
  String get utcDay =>
      '${reviewedAt.toUtc().year.toString().padLeft(4, '0')}-'
      '${reviewedAt.toUtc().month.toString().padLeft(2, '0')}-'
      '${reviewedAt.toUtc().day.toString().padLeft(2, '0')}';

  Map<String, Object?> toRow() => {
        'word_id': wordId,
        'rating': rating.value,
        'duration_ms': durationMs,
        'reviewed_at': reviewedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
      };

  static ReviewEvent fromRow(Map<String, Object?> r) => ReviewEvent(
        wordId: r['word_id']! as String,
        rating: ReviewRating.fromValue(r['rating']! as int),
        reviewedAt: DateTime.parse(r['reviewed_at']! as String).toUtc(),
        durationMs: r['duration_ms'] as int?,
        deviceId: r['device_id'] as String?,
        synced: (r['synced'] as int?) ?? 0,
      );
}

// ───────────────────────── 服务 ─────────────────────────

/// 端侧 FSRS 调度。
///
/// 用法（UI 层）：
/// ```dart
/// final svc = FsrsService();
/// final previews = svc.previewAll(now, state);      // 按钮上的「下次 X 天」
/// final next = svc.apply(rating, state, now);        // 提交
/// ```
class FsrsService {
  FsrsService({DateTime Function()? clock})
      : _clock = clock ?? (() => DateTime.now().toUtc()) {
    // 🔴 enableFuzzing: false —— 自带 fuzz 是有状态随机，会让预览与提交不一致。
    //    改用本类的 _deterministicFuzz（按 cardId 哈希，确定且稳定）。
    _scheduler = Scheduler(
      desiredRetention: kDesiredRetention,
      learningSteps: kLearningSteps,
      relearningSteps: kRelearningSteps,
      maximumInterval: kMaxIntervalDays,
      enableFuzzing: false,
    );
  }

  final DateTime Function() _clock;
  late final Scheduler _scheduler;

  /// 当前时间（UTC）。**全服务的时间都必须是 UTC**。
  DateTime nowUtc() => _clock().toUtc();

  // ── 预览 ───────────────────────────────────────────────

  /// 预览某一档的间隔。
  ///
  /// 🔑 依赖 fsrs 的 `reviewCard()` 内部先 `copyWith()` —— **不改原卡**，
  /// 所以可以连续对四档各调一次，互不影响。
  Duration previewOne(ReviewRating rating, ReviewState state, DateTime nowUtc) {
    final next = _applyToCard(rating, state, nowUtc);
    return next.due.difference(nowUtc.toUtc());
  }

  /// 预览四档 —— **界面稿按钮上「下次 X 天」就是这个**。
  Map<ReviewRating, Duration> previewAll(ReviewState state, DateTime nowUtc) => {
        for (final r in ReviewRating.values) r: previewOne(r, state, nowUtc),
      };

  // ── 提交 ───────────────────────────────────────────────

  /// 提交一次复习，返回新的状态。
  ///
  /// ⚠️ 与 [previewOne] 用**同一个 scheduler、同一套确定性抖动** →
  /// 预览显示「1.5 个月」，提交后就真的是 1.5 个月。
  ReviewState apply(
    ReviewRating rating,
    ReviewState state,
    DateTime nowUtc, {
    int? durationMs,
  }) {
    final now = _requireUtc(nowUtc);
    final next = _applyToCard(rating, state, now);
    return ReviewState(
      wordId: state.wordId,
      state: next.state.value,
      step: next.step,
      stability: next.stability,
      difficulty: next.difficulty,
      reps: state.reps + 1,
      lapses: state.lapses + (rating == ReviewRating.again ? 1 : 0),
      lastReviewAt: now,
      nextReviewAt: next.due,
      pendingPush: 1,
    );
  }

  /// 便捷：提交并产出同步事件（本地表要同时写 `card_review_state` + `review_log`）。
  ({ReviewState state, ReviewEvent event}) review(
    ReviewRating rating,
    ReviewState state,
    DateTime nowUtc, {
    int? durationMs,
    String? deviceId,
  }) {
    final now = _requireUtc(nowUtc);
    return (
      state: apply(rating, state, now),
      event: ReviewEvent(
        wordId: state.wordId,
        rating: rating,
        reviewedAt: now,
        durationMs: durationMs,
        deviceId: deviceId,
      ),
    );
  }

  // ── 多端同步：事件重放 ─────────────────────────────────

  /// 按事件序列重建权威状态（纯函数，任一设备算出同一结果）。
  ///
  /// 合并规则（白哥 2026-09-26 定）：
  /// **同一天（UTC 日历日）只保留最后一次** —— 否则一天内多次复习会让稳定性叠加，
  /// 间隔虚高（这正是官方 `w17`/`w18` same-day 分支要处理的问题）。
  ReviewState replay(String wordId, List<ReviewEvent> events,
      {DateTime? createdAt}) {
    final sorted = [...events]..sort((a, b) => a.reviewedAt.compareTo(b.reviewedAt));

    // 同 UTC 日去重：保留当天最后一条
    final byDay = <String, ReviewEvent>{};
    for (final e in sorted) {
      final prev = byDay[e.utcDay];
      if (prev == null || e.reviewedAt.isAfter(prev.reviewedAt)) {
        byDay[e.utcDay] = e;
      }
    }
    final deduped = byDay.values.toList()
      ..sort((a, b) => a.reviewedAt.compareTo(b.reviewedAt));

    // 从新卡开始重放
    var out = _newState(wordId, createdAt ?? deduped.first.reviewedAt);
    for (final e in deduped) {
      out = apply(e.rating, out, e.reviewedAt);
    }
    return out;
  }

  /// 合并两端的事件流（多设备场景）：去重同一事件，再重放。
  ReviewState merge(
    String wordId,
    List<ReviewEvent> a,
    List<ReviewEvent> b, {
    DateTime? createdAt,
  }) {
    final seen = <String>{};
    final all = <ReviewEvent>[];
    for (final e in [...a, ...b]) {
      // 同一设备同一时刻同一评分 = 同一条事件
      final key = '${e.deviceId ?? '-'}|${e.reviewedAt.toIso8601String()}'
          '|${e.rating.value}|${e.wordId}';
      if (seen.add(key)) all.add(e);
    }
    return replay(wordId, all, createdAt: createdAt);
  }

  // ── 派生 ───────────────────────────────────────────────

  /// 当前保留概率（0–1）。用于「这条痕迹该多淡」与列表的熟度显示。
  double retrievability(ReviewState state, DateTime nowUtc) {
    final card = _toCard(state);
    if (card.stability == null) return 0;
    return _scheduler.getCardRetrievability(card, currentDateTime: nowUtc.toUtc());
  }

  /// 新卡状态（未学，立即到期）。
  ReviewState newState(String wordId, DateTime nowUtc) =>
      _newState(wordId, nowUtc);

  // ── 内部 ───────────────────────────────────────────────

  ReviewState _newState(String wordId, DateTime nowUtc) => ReviewState(
        wordId: wordId,
        state: 0,
        step: 0,
        reps: 0,
        lapses: 0,
        nextReviewAt: nowUtc.toUtc(),
      );

  /// `ReviewState` → fsrs `Card`。
  ///
  /// `cardId` 用 wordId 的稳定哈希 —— fsrs 只用它做标识，不参与算法，
  /// 因此哈希碰撞不会影响调度正确性（真正的身份由本地表的 `word_id` 保证）。
  Card _toCard(ReviewState s) {
    final state = s.state == 0 ? State.learning : State.fromValue(s.state);
    return Card(
      cardId: _stableId(s.wordId),
      state: state,
      step: s.state == 0 ? 0 : s.step,
      stability: s.stability,
      difficulty: s.difficulty,
      due: s.nextReviewAt.toUtc(),
      lastReview: s.lastReviewAt?.toUtc(),
    );
  }

  /// 跑一次 FSRS（不动传入的 state）。
  Card _applyToCard(ReviewRating rating, ReviewState s, DateTime nowUtc) {
    final now = _requireUtc(nowUtc);
    final res = _scheduler.reviewCard(
      _toCard(s),
      rating.fsrs,
      reviewDateTime: now,
    );
    return _withDeterministicFuzz(res.card, now);
  }

  DateTime _requireUtc(DateTime t) {
    if (!t.isUtc) {
      // fsrs 包会直接抛 ArgumentError，这里提前给出更明确的错误
      throw ArgumentError('必须传 UTC 时间（收到 $t）。用 DateTime.now().toUtc()');
    }
    return t;
  }

  /// 确定性抖动 —— 替代 fsrs 自带 fuzz。
  ///
  /// 🔑 关键差异：按 `cardId` 哈希计算，**同一张卡永远得到同一抖动** →
  /// 预览与提交一致（自带 fuzz 是有状态随机，做不到）。
  Card _withDeterministicFuzz(Card card, DateTime nowUtc) {
    if (!kEnableDeterministicFuzz) return card;

    final days = card.due.difference(nowUtc).inDays;
    if (days < _kFuzzMinIntervalDays) return card;

    final span = math.min((days * _kFuzzRatio).round(), _kFuzzCapDays);
    if (span <= 0) return card;

    // 用 cardId 派生确定性偏移，范围 [-span, +span]
    final h = _hash32('fuzz|${card.cardId}');
    final offset = (h % (2 * span + 1)) - span;
    if (offset == 0) return card;

    return card.copyWith(due: card.due.add(Duration(days: offset)));
  }

  static int _stableId(String s) => _hash32(s) & 0x1FFFFFFFFFFFFF; // 53-bit

  static int _hash32(String s) {
    // FNV-1a 32bit
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }
}

// ───────────────────────── 显示格式化 ─────────────────────────

/// 把间隔格式化成界面稿里的说法（「10 分钟 / 21 天 / 1.5 个月 / 4.5 个月」）。
///
/// 与 `scripts/fsrs_verify` 的 `fmt()` 同一套规则 —— 保持界面与实际一致。
String formatInterval(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} 秒';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
  if (d.inHours < 24) return '${(d.inMinutes / 60).toStringAsFixed(1)} 小时';
  if (d.inDays < 30) return '${d.inDays} 天';
  if (d.inDays < 365) return '${(d.inDays / 30.44).toStringAsFixed(1)} 个月';
  return '${(d.inDays / 365).toStringAsFixed(1)} 年';
}
