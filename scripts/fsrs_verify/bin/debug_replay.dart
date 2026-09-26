import '../../../app/lib/services/fsrs_service.dart';

void main() {
  final day1 = DateTime.utc(2026, 9, 1, 9);
  final svc = FsrsService();

  print('=== 逐步追踪：从新卡开始，看 state / step / stability / due ===');
  var st = svc.newState('w9', day1);
  void dump(String tag, ReviewState s) {
    print('  $tag  state=${s.state} step=${s.step} '
        'S=${s.stability?.toStringAsFixed(3)} D=${s.difficulty?.toStringAsFixed(2)} '
        'reps=${s.reps} due=${s.nextReviewAt.toIso8601String()}');
  }

  dump('初始', st);
  st = svc.apply(ReviewRating.again, st, day1.add(const Duration(hours: 5)));
  dump('again@+5h', st);
  st = svc.apply(ReviewRating.good, st, DateTime.utc(2026, 9, 4, 9));
  dump('good@09-04', st);
  st = svc.apply(ReviewRating.good, st, DateTime.utc(2026, 9, 6, 9));
  dump('good@09-06', st);
  st = svc.apply(ReviewRating.good, st, DateTime.utc(2026, 9, 10, 9));
  dump('good@09-10', st);

  print('\n=== 去重 vs 不去重：逐条对比 ===');
  final events = <ReviewEvent>[
    ReviewEvent(wordId: 'w9', rating: ReviewRating.good, reviewedAt: day1, deviceId: 'A'),
    ReviewEvent(wordId: 'w9', rating: ReviewRating.again,
        reviewedAt: day1.add(const Duration(hours: 5)), deviceId: 'B'),
    ReviewEvent(wordId: 'w9', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 4, 9), deviceId: 'A'),
    ReviewEvent(wordId: 'w9', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 6, 9), deviceId: 'A'),
    ReviewEvent(wordId: 'w9', rating: ReviewRating.good,
        reviewedAt: DateTime.utc(2026, 9, 10, 9), deviceId: 'A'),
  ];

  final dedup = svc.replay('w9', events, createdAt: day1);
  dump('去重重放', dedup);

  var all = svc.newState('w9', day1);
  final sorted = [...events]..sort((a, b) => a.reviewedAt.compareTo(b.reviewedAt));
  for (final e in sorted) {
    all = svc.apply(e.rating, all, e.reviewedAt);
  }
  dump('不去重重放', all);

  print('\n=== 判定 ===');
  print('  reps   : 去重=${dedup.reps}  不去重=${all.reps}');
  print('  S      : 去重=${dedup.stability?.toStringAsFixed(3)}  '
      '不去重=${all.stability?.toStringAsFixed(3)}');
  print('  due    : 去重=${dedup.nextReviewAt.toIso8601String()}  '
      '不去重=${all.nextReviewAt.toIso8601String()}');
  print('  state  : 去重=${dedup.state}  不去重=${all.state}');
}
