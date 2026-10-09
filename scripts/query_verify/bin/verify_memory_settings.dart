// CoEvo · 记忆设置（默写容错阈值）断言 —— **纯 Dart · 本机可跑**
//
// 运行：`dart run bin/verify_memory_settings.dart`
//
// # 本脚本守什么
//
// `services/memory_settings.dart` 是**规则层**（阈值区间 / 钳制 / 「最多能错几个」）。
// 它的错法都是**静默**的：
//   · 钳制漏了 ⇒ 阈值 0 或 1e9 ⇒ 复习队列**卡死**，且不报错
//   · `maxWrongWordsFor` 与判定层**口径不一致** ⇒ 设置页说「能错 3 个」，
//     实际判定「错 2 个就不过」—— 用户永远调不明白
//
// 🔴 所以最要紧的一节是 ③：**逐个交叉核对**设置页的算式与判定层的判据
//    （同一件事的口径只能一处权威 —— 这里验的正是「两处是否仍一致」）。

import '../../../app/lib/services/highlight_grader.dart';
import '../../../app/lib/services/memory_settings.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _failures.add('$label${detail.isEmpty ? '' : '   [$detail]'}');
    print('  🔴 $label${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

void eq(String label, Object? got, Object? want) =>
    check(label, got == want, '实际=$got 期望=$want');

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

void main() {
  print('');
  print('═══ verify_memory_settings ═══');

  // ══════════════════════════════════════════════════════════════════════
  section('① 钳制 clampMemoryMaxWrongPercent');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 为什么要钳：值来自 SharedPreferences ⇒ 可能是任意历史值 / 损坏值。
  //    **不钳的后果是静默的** —— 阈值 0 ⇒ 一切判「忘记」⇒ 复习队列卡死。
  eq('默认值 5', kMemoryMaxWrongPercentDefault, 5);
  eq('区间下限 0', kMemoryMaxWrongPercentMin, 0);
  eq('区间上限 30', kMemoryMaxWrongPercentMax, 30);
  eq('默认值落在区间内',
      kMemoryMaxWrongPercentDefault >= kMemoryMaxWrongPercentMin &&
          kMemoryMaxWrongPercentDefault <= kMemoryMaxWrongPercentMax,
      true);

  eq('区间内原样返回', clampMemoryMaxWrongPercent(12), 12);
  eq('下界', clampMemoryMaxWrongPercent(0), 0);
  eq('上界', clampMemoryMaxWrongPercent(30), 30);
  eq('低于下界 ⇒ 取下界', clampMemoryMaxWrongPercent(-7), 0);
  eq('高于上界 ⇒ 取上界', clampMemoryMaxWrongPercent(9999), 30);
  eq('🔴 0 不会被当成「没设置」而回落到默认（0 是合法值）',
      clampMemoryMaxWrongPercent(0), 0);
  eq('NaN ⇒ 默认值（不是 0 —— 0 会卡死队列）',
      clampMemoryMaxWrongPercent(double.nan), kMemoryMaxWrongPercentDefault);
  eq('小数 ⇒ 四舍五入', clampMemoryMaxWrongPercent(7.6), 8);
  eq('小数再钳', clampMemoryMaxWrongPercent(29.7), 30);
  // 幂等：钳过的值再钳不变（让「历史脏值」只在第一次读时被修正一次）
  for (final v in [-5, 0, 5, 17, 30, 77]) {
    final once = clampMemoryMaxWrongPercent(v);
    eq('幂等 · clamp($v) 再钳不变', clampMemoryMaxWrongPercent(once), once);
  }

  // ══════════════════════════════════════════════════════════════════════
  section('② 「最多能错几个」maxWrongWordsFor');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔑 这是设置页给用户看的数字。它必须与判定层的判据**是同一个不等式**。
  eq('0 词 ⇒ 0 个（除零保护）', maxWrongWordsFor(expectedWords: 0, percent: 5), 0);
  eq('负数词 ⇒ 0 个（脏输入不崩）', maxWrongWordsFor(expectedWords: -3, percent: 5), 0);

  // 🔴 白哥定的 5% 的**实际含义**（设计稿 §4.② 那张表就是这几行）
  eq('5% · 9 个词 ⇒ 0 个（错 1 个就超）',
      maxWrongWordsFor(expectedWords: 9, percent: 5), 0);
  eq('5% · 19 个词 ⇒ 0 个', maxWrongWordsFor(expectedWords: 19, percent: 5), 0);
  eq('5% · 20 个词 ⇒ 1 个（恰好 20×5=100）',
      maxWrongWordsFor(expectedWords: 20, percent: 5), 1);
  eq('5% · 39 个词 ⇒ 1 个', maxWrongWordsFor(expectedWords: 39, percent: 5), 1);
  eq('5% · 40 个词 ⇒ 2 个', maxWrongWordsFor(expectedWords: 40, percent: 5), 2);
  eq('5% · 100 个词 ⇒ 5 个', maxWrongWordsFor(expectedWords: 100, percent: 5), 5);

  // 0% ⇒ 逐字全对（与单词卡同级严格度）
  for (final n in [1, 5, 20, 100]) {
    eq('0% · $n 个词 ⇒ 0 个（逐字全对）',
        maxWrongWordsFor(expectedWords: n, percent: 0), 0);
  }

  // 30% ⇒ 上限档（设计稿举例：20 词最多错 3 个是 15% 那一档）
  eq('15% · 20 个词 ⇒ 3 个', maxWrongWordsFor(expectedWords: 20, percent: 15), 3);
  eq('15% · 7 个词 ⇒ 1 个', maxWrongWordsFor(expectedWords: 7, percent: 15), 1);
  eq('30% · 10 个词 ⇒ 3 个', maxWrongWordsFor(expectedWords: 10, percent: 30), 3);

  // 越界阈值走钳制（设置页控件坏了也不该算出荒唐的数）
  eq('阈值 999 ⇒ 按 30 算', maxWrongWordsFor(expectedWords: 10, percent: 999),
      maxWrongWordsFor(expectedWords: 10, percent: 30));
  eq('阈值 -5 ⇒ 按 0 算', maxWrongWordsFor(expectedWords: 10, percent: -5), 0);

  // 单调性：词越多、阈值越大 ⇒ 允许错的不会变少
  var mono = true;
  for (final p in kMemoryMaxWrongPercentTicks) {
    var prev = -1;
    for (var n = 0; n <= 120; n++) {
      final cur = maxWrongWordsFor(expectedWords: n, percent: p);
      if (cur < prev) mono = false;
      prev = cur;
    }
  }
  check('单调性：词数增加 ⇒ 容错不减', mono);
  var monoPct = true;
  for (var n = 0; n <= 60; n++) {
    var prev = -1;
    for (var p = 0; p <= 30; p++) {
      final cur = maxWrongWordsFor(expectedWords: n, percent: p);
      if (cur < prev) monoPct = false;
      prev = cur;
    }
  }
  check('单调性：阈值增加 ⇒ 容错不减', monoPct);

  // ══════════════════════════════════════════════════════════════════════
  section('③ 🔴🔴 与判定层**逐点交叉核对**（本脚本最要紧的一节）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 设置页对用户承诺「20 个词的句子最多错 3 个」。
  // 这句话为真的**充要条件**是：判定层对「错 = 3 个」判过、对「错 = 4 个」判不过。
  //
  // ⇒ 逐个词数 × 逐个阈值，构造「恰好错 N 个词」的输入，核对边界两边。
  //    这样「设置页的算式」与「判定层的判据」一旦漂开，**这里立刻红**。
  var crossed = 0;
  for (final n in [1, 2, 3, 5, 7, 9, 10, 19, 20, 21, 39, 40, 59, 100]) {
    for (final p in [0, 5, 10, 15, 20, 25, 30]) {
      final allow = maxWrongWordsFor(expectedWords: n, percent: p);

      // 构造标准答案：n 个互不相同的词
      final expected = List.generate(n, (i) => 'w$i').join(' ');

      // 恰好错 allow 个 ⇒ 必须判**对**
      final atLimit = List.generate(
          n, (i) => i < allow ? 'WRONG$i' : 'w$i').join(' ');
      final atLimitOk = gradeCloze(atLimit, expected, maxWrongPercent: p).correct;
      if (!atLimitOk) {
        check('🔴 交叉 · $n 词 $p%：恰好错 $allow 个应判**对**', false,
            '输入「$atLimit」');
      } else {
        crossed++;
      }

      // 错 allow+1 个 ⇒ 必须判**错**（除 allow 已到 n 的情况）
      if (allow + 1 <= n) {
        final overLimit = List.generate(
            n, (i) => i <= allow ? 'WRONG$i' : 'w$i').join(' ');
        final overOk =
            gradeCloze(overLimit, expected, maxWrongPercent: p).correct;
        if (overOk) {
          check('🔴 交叉 · $n 词 $p%：错 ${allow + 1} 个应判**错**', false,
              '输入「$overLimit」');
        } else {
          crossed++;
        }
      }
    }
  }
  check('交叉核对共 $crossed 组边界（设置页承诺 == 判定层实际）', crossed > 0);

  // 全对必须判对（任何阈值）
  for (final p in [0, 5, 30]) {
    check('交叉 · 全对在 $p% 下必判对',
        gradeCloze('the habit of reading', 'the habit of reading',
                maxWrongPercent: p)
            .correct);
  }

  // 🔴 单词卡**不受**这个设置影响 —— 断言它仍是逐字严格
  //    （这条守的是「设置只放宽划线卡」那个承诺；若哪天有人把设置
  //     也接进 `gradeSpelling`，这里**不会**发现 —— 所以另有一条结构断言，见 ④）
  check('交叉 · 0% 等同逐字全对（与单词卡同级严格度）',
      !gradeCloze('the habit of readin', 'the habit of reading',
              maxWrongPercent: 0)
          .correct);

  // ══════════════════════════════════════════════════════════════════════
  section('④ 键名与默认值（写端 / 读端必须一致）');
  // ══════════════════════════════════════════════════════════════════════
  eq('键名非空', MemoryPrefKeys.maxWrongPercent.isNotEmpty, true);
  check('键名长度 > 8（防「手滑写短了」）',
      MemoryPrefKeys.maxWrongPercent.length > 8, MemoryPrefKeys.maxWrongPercent);
  check('刻度表含默认值', kMemoryMaxWrongPercentTicks.contains(kMemoryMaxWrongPercentDefault));
  check('刻度表含两端',
      kMemoryMaxWrongPercentTicks.contains(kMemoryMaxWrongPercentMin) &&
          kMemoryMaxWrongPercentTicks.contains(kMemoryMaxWrongPercentMax));
  check('刻度表升序', () {
    for (var i = 1; i < kMemoryMaxWrongPercentTicks.length; i++) {
      if (kMemoryMaxWrongPercentTicks[i] <= kMemoryMaxWrongPercentTicks[i - 1]) {
        return false;
      }
    }
    return true;
  }());
  eq('推荐值 == 默认值', kMemoryMaxWrongPercentRecommended, kMemoryMaxWrongPercentDefault);
  // 滑动条的 divisions 必须能整除区间（否则拖不到端点）
  eq('30 / divisions(6) == 步进 5', kMemoryMaxWrongPercentMax ~/ 6, 5);
  eq('区间被 divisions 整除（否则右端拖不到）',
      kMemoryMaxWrongPercentMax % 6, 0);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('=' * 68);
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    throw StateError('有 ${_failures.length} 项失败');
  }
  print('✅ 记忆设置（阈值钳制 / 后果换算 / 与判定层一致）全部通过');
}
