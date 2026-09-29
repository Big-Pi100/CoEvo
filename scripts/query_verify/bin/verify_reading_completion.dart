// CoEvo · 「读完」判定验收（纯函数 · 无需 Flutter）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_reading_completion.dart
//
// # 为什么这个脚本有存在价值
// 判定逻辑若写在 `reader_screen.dart` 里，就只能靠「真机上滑一下看看」验证 ——
// 而**边界情况（短文章 / 差 1px / 差 1ms）在真机上根本没法系统地试**。
// 抽成纯函数后，每条边界都能变成一行断言。
//
// # 🔴 本脚本最容易「假绿」的地方
// 如果只测「明显读完」与「明显没读完」两种情况，**任何实现都能通过**
// （哪怕把条件写成 `||` 也过）。
// → 所以每条关键断言都用**只差一点点**的输入（差 1px / 差 1ms）：
//    只有「两个条件都生效、且是 `&&`」的实现才能全部通过。

import '../../../app/lib/services/reading_completion.dart';

var _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

const _justEnough = Duration(seconds: 3); // 恰好达标
const _almostEnough = Duration(milliseconds: 2999); // 差 1ms

void main() {
  print('');
  print('#' * 74);
  print('# 「读完」判定验收 —— 口径：滚到底 **且** 停留 ≥3s');
  print('# 阈值：extentAfter ≤ ${kReadBottomThresholdPx}px · dwell ≥ ${kReadMinDwell.inSeconds}s');
  print('#' * 74);

  // ══════════════════════════════════════════════════════════
  section('【1】两个条件**都**满足 → 算读完');
  // ══════════════════════════════════════════════════════════
  check('精确到底（extentAfter = 0）+ 停留 3s',
      isArticleCompleted(extentAfter: 0, dwell: _justEnough));
  check('容差内（= 24，恰好等于阈值）+ 停留足够',
      isArticleCompleted(
          extentAfter: kReadBottomThresholdPx, dwell: _justEnough),
      '边界取闭区间（<=）');

  // ══════════════════════════════════════════════════════════
  section('【2】🔴 只满足一个条件 → **不算**（证明是 `&&` 而不是 `||`）');
  // ══════════════════════════════════════════════════════════
  // 若实现误写成 `||`，下面两条会**失败** —— 这正是本段的作用。
  check('🔴 到底了但停留不够 → 不算（防「滑到底就退」）',
      !isArticleCompleted(extentAfter: 0, dwell: _almostEnough));
  check('🔴 停留够久但没到底 → 不算（防「读了一半也算完」）',
      !isArticleCompleted(extentAfter: 500, dwell: const Duration(hours: 1)));

  // ══════════════════════════════════════════════════════════
  section('【3】🔴 阈值边界（差 1px / 差 1ms 必须翻转）');
  // ══════════════════════════════════════════════════════════
  check('🔴 extentAfter 超出阈值 1px → 不算',
      !isArticleCompleted(
          extentAfter: kReadBottomThresholdPx + 1, dwell: _justEnough));
  check('🔴 dwell 差 1ms → 不算',
      !isArticleCompleted(extentAfter: 0, dwell: _almostEnough));
  check('dwell 恰好等于阈值 → 算（闭区间）',
      isArticleCompleted(extentAfter: 0, dwell: kReadMinDwell));

  // ══════════════════════════════════════════════════════════
  section('【4】🔴 关键场景：**短文章**（extentAfter 恒为 0）');
  // ══════════════════════════════════════════════════════════
  // 内容不足一屏时 `maxScrollExtent == 0` → `extentAfter` 恒为 0。
  // 「点开就退」必须**不算** —— 这正是「最短停留」存在的唯一理由。
  check('🔴 点开即退（0.5s，extentAfter=0）→ **不算**',
      !isArticleCompleted(
          extentAfter: 0, dwell: const Duration(milliseconds: 500)),
      '短文章场景 —— 没有 minDwell 就会误判');
  check('短文章认真读了 3s+ → 算',
      isArticleCompleted(
          extentAfter: 0, dwell: const Duration(seconds: 10)));

  // ══════════════════════════════════════════════════════════
  section('【5】异常/退化输入不抛异常（调用方不必额外防御）');
  // ══════════════════════════════════════════════════════════
  // `extentAfter` 理论上非负，但列表未布局完 / 自定义 physics 下可能给出怪值。
  // 🔑 判定函数**不该抛** —— 它在滚动回调与定时器里被高频调用，
  //    抛异常会（在 debug 下）打断滚动 frame。
  var threw = false;
  try {
    isArticleCompleted(extentAfter: -1000, dwell: Duration.zero);
    isArticleCompleted(extentAfter: double.infinity, dwell: _justEnough);
    isArticleCompleted(
        extentAfter: double.nan, dwell: const Duration(days: 999));
  } catch (_) {
    threw = true;
  }
  check('🔴 负值 / infinity / NaN 均不抛异常', !threw);
  check('负数 extentAfter（越界回弹）视为到底 → 配合停留足够即算',
      isArticleCompleted(extentAfter: -50, dwell: _justEnough));
  check('infinity → 不算（未到底）',
      !isArticleCompleted(extentAfter: double.infinity, dwell: _justEnough));
  check('NaN → 不算（比较恒为 false，安全退化）',
      !isArticleCompleted(extentAfter: double.nan, dwell: _justEnough));

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('═' * 74);
}
