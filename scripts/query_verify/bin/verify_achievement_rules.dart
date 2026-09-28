// CoEvo · 成就**规则层**验收（纯逻辑 · 无需 DB / 真机）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_achievement_rules.dart
//
// # 为什么这个脚本最重要
// `achievement_rules.dart` 决定「**什么算解锁**」。它错了 → **静默给错成就**
// （用户看到不该有的徽章 / 该有的永远不亮），而且**没有任何报错**。
// → 按项目判据：「**核心业务逻辑必须可独立验证**」。
//
// # 覆盖
// | 组 | 内容 |
// |---|---|
// | 【1】 | `computeStreakDays`（含「今天没学但昨天学了」这类边界） |
// | 【2】 | `computeMaxGapDays` |
// | 【3】 | `computeMaxLookupsIn1h`（**左闭右开**窗口） |
// | 【4】 | `evaluateAchievements`（含**边界**：恰好等于 / 差 1） |
// | 【5】 | 进度计算 |
// | 【6】 | 🔴 **清单自洽性**（key 唯一 · metric 同名 · 分类齐全）—— 防「拼错一个字」的静默失败 |
// | 【7】 | 🔴 **口径守护**：本地日 vs UTC 日（防后人改回 `utc_day`） |

import '../../../app/lib/services/achievement_rules.dart';

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

void hr(String t) {
  print('');
  print('═' * 74);
  print(t);
  print('═' * 74);
}

/// 便于构造「某天」的本地时间。
DateTime d(int y, int m, int day, [int h = 12]) => DateTime(y, m, day, h);

void main() {
  // ══════════════════════════════════════════════════════════
  hr('【1】computeStreakDays —— 连续天数');
  // ══════════════════════════════════════════════════════════
  final today = d(2026, 9, 29);

  check('空列表 → 0', computeStreakDays([], today) == 0);
  check('只有今天 → 1', computeStreakDays([today], today) == 1);
  check('今天+昨天+前天 → 3',
      computeStreakDays([d(2026, 9, 29), d(2026, 9, 28), d(2026, 9, 27)], today) == 3);

  // 🔑 ① 关键口径：今天还没学，但昨天学了 → **不算断**
  check('🔑 今天没学但昨天学了 → 仍算 1（最后学习日是昨天，未断）',
      computeStreakDays([d(2026, 9, 28)], today) == 1);
  check('🔑 前天才学的（含更早）→ 0（已断）',
      computeStreakDays([d(2026, 9, 27), d(2026, 9, 26)], today) == 0);

  check('同一天多条 → 只算 1 天',
      computeStreakDays([d(2026, 9, 29, 9), d(2026, 9, 29, 20)], today) == 1);
  check('乱序输入 → 结果不受影响',
      computeStreakDays([d(2026, 9, 27), d(2026, 9, 29), d(2026, 9, 28)], today) == 3);
  check('中间有缺口 → 只回溯到缺口',
      computeStreakDays(
              [d(2026, 9, 29), d(2026, 9, 28), d(2026, 9, 26), d(2026, 9, 25)], today) ==
          2);
  check('跨月连续 → 正确',
      computeStreakDays(
              [d(2026, 10, 1), d(2026, 9, 30), d(2026, 9, 29)], d(2026, 10, 1)) ==
          3);
  check('跨年连续 → 正确',
      computeStreakDays(
              [d(2027, 1, 1), d(2026, 12, 31), d(2026, 12, 30)], d(2027, 1, 1)) ==
          3);
  // 🔴 口径 ②：必须按**本地日**
  check('🔴 同一天的不同时刻不产生额外天数（本地日去重）',
      computeStreakDays(
              [d(2026, 9, 29, 0), d(2026, 9, 29, 23), d(2026, 9, 28, 23)], today) ==
          2);

  // ══════════════════════════════════════════════════════════
  hr('【2】computeMaxGapDays —— 历史最长中断');
  // ══════════════════════════════════════════════════════════
  check('空 → 0', computeMaxGapDays([]) == 0);
  check('只有一天 → 0（无间隔可言）', computeMaxGapDays([today]) == 0);
  check('连续两天 → 0（中间没空整天）',
      computeMaxGapDays([d(2026, 9, 28), d(2026, 9, 29)]) == 0);
  check('间隔 1 天（9/27 与 9/29）→ 1',
      computeMaxGapDays([d(2026, 9, 27), d(2026, 9, 29)]) == 1);
  check('间隔 30 天 → 30',
      computeMaxGapDays([d(2026, 8, 29), d(2026, 9, 29)]) == 30);
  check('取**最大**间隔（多个间隔中最大的）',
      computeMaxGapDays([d(2026, 9, 25), d(2026, 9, 26), d(2026, 9, 28)]) == 1);
  check('🔑 只看学习日之间，不看「最后一天到今天」',
      computeMaxGapDays([d(2026, 1, 1), d(2026, 1, 2)]) == 0);

  // ══════════════════════════════════════════════════════════
  hr('【3】computeMaxLookupsIn1h —— 1 小时窗口（左闭右开）');
  // ══════════════════════════════════════════════════════════
  check('空 → 0', computeMaxLookupsIn1h([]) == 0);
  check('3 个词在 10 分钟内 → 3',
      computeMaxLookupsIn1h([
        d(2026, 9, 29, 10),
        d(2026, 9, 29, 10) .add(const Duration(minutes: 5)),
        d(2026, 9, 29, 10).add(const Duration(minutes: 10)),
      ]) == 3);
  // 🔴 窗口边界：59 分钟含，60 分钟不含
  check('🔴 相距 59 分钟 → 算在同一窗口（2）',
      computeMaxLookupsIn1h([
        d(2026, 9, 29, 10),
        d(2026, 9, 29, 10).add(const Duration(minutes: 59)),
      ]) == 2);
  check('🔴 相距恰好 60 分钟 → **不算**同窗口（各 1，取最大 → 1）',
      computeMaxLookupsIn1h([
        d(2026, 9, 29, 10),
        d(2026, 9, 29, 10).add(const Duration(minutes: 60)),
      ]) == 1);
  check('滑动窗口取最大值（跨越两簇）',
      computeMaxLookupsIn1h([
        d(2026, 9, 29, 10),
        d(2026, 9, 29, 10).add(const Duration(minutes: 10)),
        d(2026, 9, 29, 10).add(const Duration(minutes: 20)),
        d(2026, 9, 29, 14),
      ]) == 3);
  check('乱序输入 → 正确（内部排序）',
      computeMaxLookupsIn1h([
        d(2026, 9, 29, 10).add(const Duration(minutes: 20)),
        d(2026, 9, 29, 10),
        d(2026, 9, 29, 10).add(const Duration(minutes: 10)),
      ]) == 3);

  // ══════════════════════════════════════════════════════════
  hr('【4】evaluateAchievements —— 判定（含边界）');
  // ══════════════════════════════════════════════════════════
  check('空指标 → 无解锁（全部阈值为正）', evaluateAchievements({}).isEmpty);

  final m1 = <String, num>{AchievementMetrics.streakDays: 3};
  final u1 = evaluateAchievements(m1);
  check('streak=3 → 解锁 streak_3', u1.contains('streak_3'));
  check('streak=3 → **不解锁** streak_7（差 4）', !u1.contains('streak_7'));
  // 🔴 边界：恰好等于 → 解锁
  check('🔴 边界：streak=7 恰好达标 → 解锁 streak_7',
      evaluateAchievements({AchievementMetrics.streakDays: 7}).contains('streak_7'));
  check('🔴 边界：streak=6 差 1 → 不解锁',
      !evaluateAchievements({AchievementMetrics.streakDays: 6}).contains('streak_7'));

  check('🔴 未提供的指标按 0 处理 → 不传 streakDays 时坚持类全不解锁',
      !evaluateAchievements({AchievementMetrics.totalReviews: 5})
          .any((k) => k.startsWith('streak_')));
  check('缺失指标不影响其它成就判定',
      evaluateAchievements({AchievementMetrics.totalReviews: 5}).contains('first_review'));

  check('🔴 超过阈值（streak=500）→ 4 个坚持类全解锁',
      evaluateAchievements({AchievementMetrics.streakDays: 500})
          .where((k) => k.startsWith('streak_'))
          .length ==
          4);

  // 全指标拉满 → 清单里全部解锁（防「有成就永远解不开」）
  final all = <String, num>{for (final k in AchievementMetrics.all) k: 1e9};
  final allUnlocked = evaluateAchievements(all);
  check('🔴 全部指标拉满 → **清单里每个成就都能解锁**（无死成就）',
      allUnlocked.length == kAchievements.length,
      '${allUnlocked.length}/${kAchievements.length}');

  // ══════════════════════════════════════════════════════════
  hr('【5】进度计算');
  // ══════════════════════════════════════════════════════════
  final streak7 = kAchievements.firstWhere((d) => d.key == 'streak_7');
  check('进度 0/N → 0.0',
      achievementProgress(streak7, {AchievementMetrics.streakDays: 0}) == 0.0);
  check('进度 3/7 → ~0.428',
      (achievementProgress(streak7, {AchievementMetrics.streakDays: 3}) - 3 / 7).abs() <
          1e-9);
  check('进度超阈值 → 夹到 1.0',
      achievementProgress(streak7, {AchievementMetrics.streakDays: 100}) == 1.0);
  check('进度文案 3/7',
      achievementProgressLabel(streak7, {AchievementMetrics.streakDays: 3}) == '3/7');
  check('🔴 进度文案超阈值 → 显示 N/N（不显示 100/7）',
      achievementProgressLabel(streak7, {AchievementMetrics.streakDays: 100}) == '7/7');

  // ══════════════════════════════════════════════════════════
  hr('【6】🔴 清单自洽性（防「拼错一个字」的静默失败）');
  // ══════════════════════════════════════════════════════════
  final keys = kAchievements.map((d) => d.key).toList();
  check('成就 key 唯一（无重复）', keys.toSet().length == keys.length,
      '${keys.length} 个 key / ${keys.toSet().length} 个唯一');
  check('成就数量 = 20（方案 §三 定的）', kAchievements.length == 20,
      '实际 ${kAchievements.length}');

  final unknownMetrics = kAchievements
      .where((d) => !AchievementMetrics.all.contains(d.metric))
      .map((d) => '${d.key}→${d.metric}')
      .toList();
  check('🔴 每个成就的 metric 都在 `AchievementMetrics.all` 里（防拼错）',
      unknownMetrics.isEmpty, unknownMetrics.join(', '));

  check('所有阈值 > 0（阈值 0 会让成就在零进度就解锁）',
      kAchievements.every((d) => d.threshold > 0));

  final coveredCats = kAchievements.map((d) => d.category).toSet();
  check('每个分类都有成就（无空分类）',
      coveredCats.length == AchievementCategory.values.length,
      '${coveredCats.length}/${AchievementCategory.values.length}');

  final metaCats = kCategoryMeta.map((c) => c.category).toSet();
  check('每个分类都有展示元信息（label/icon）',
      metaCats.length == AchievementCategory.values.length,
      '${metaCats.length}/${AchievementCategory.values.length}');

  check('每个成就的 name 非空', kAchievements.every((d) => d.name.trim().isNotEmpty));
  check('每个成就的 description 非空',
      kAchievements.every((d) => d.description.trim().isNotEmpty));
  check('每个成就的 icon 非空（UI 层映射成 IconData）',
      kAchievements.every((d) => d.icon.trim().isNotEmpty));
  check('🔴 icon **只存字符串名**（本文件不依赖 Flutter）',
      kAchievements.every((d) => d.icon is String));

  // 🔴 图标名必须来自 `AchievementIcons.all` —— 否则 Flutter 侧映射表查不到
  //    → **静默显示默认图标**（不报错、不崩）。
  final badIcons = kAchievements
      .where((d) => !AchievementIcons.all.contains(d.icon))
      .map((d) => '${d.key}→${d.icon}')
      .toList();
  check('🔴 每个成就的 icon 都在 `AchievementIcons.all` 里（防拼错 → 静默用默认图标）',
      badIcons.isEmpty, badIcons.join(', '));

  final catIconBad = kCategoryMeta
      .where((c) => !AchievementIcons.all.contains(c.icon))
      .map((c) => '${c.category.name}→${c.icon}')
      .toList();
  check('🔴 每个分类的 icon 也都在 `AchievementIcons.all` 里',
      catIconBad.isEmpty, catIconBad.join(', '));

  check('🔴 `AchievementIcons.all` 无重复',
      AchievementIcons.all.toSet().length == AchievementIcons.all.length,
      '${AchievementIcons.all.length} 个');

  // 反向：清单里用到的 icon 必须都被声明（防「常量漏加进 all」）
  final used = <String>{
    ...kAchievements.map((d) => d.icon),
    ...kCategoryMeta.map((c) => c.icon),
  };
  final undeclared = used.difference(AchievementIcons.all.toSet());
  check('🔴 清单用到的 icon 全部已在 `all` 里声明',
      undeclared.isEmpty, undeclared.join(', '));

  // ══════════════════════════════════════════════════════════
  hr('【7】🔴 契约：本层只认传入 DateTime 的**日历字段**（不做时区转换）');
  // ══════════════════════════════════════════════════════════
  // 背景：`review_log.reviewed_at` 是 **UTC ISO8601**，而 streak 必须按**本地日**算
  // （见 `achievement_rules.dart` 文件头 ②）。
  // → 分工：**采集端**负责 `DateTime.parse(...).toLocal()`，
  //         **本层**只按传入值的日历字段取日。
  //
  // 🔑 因此这里**验不了**「UTC vs 本地」—— 那是采集端的职责，
  //    由 `verify_achievement_service.dart` 用真库（造 UTC 时间戳）来验。
  //    ⚠️ 本层若去猜时区，反而会让「同一函数在不同环境下结果不同」→ 更糟。
  //    （这条**刻意写下来**：我第一次就写错过一条断言，想在这里验「按 UTC 日会算成 28 日」——
  //      那是**恒绿或依赖运行环境时区**的假断言。）
  check('🔴 契约：同日凌晨 00:30 与深夜 23:30 **归入同一天**',
      computeStreakDays([DateTime(2026, 9, 29, 0, 30)], d(2026, 9, 29)) == 1 &&
          computeStreakDays([DateTime(2026, 9, 29, 23, 30)], d(2026, 9, 29)) == 1);
  check('🔴 契约：本层**不读系统时区** —— 传入的 `.day` 即结果（凌晨也算当天）',
      computeStreakDays([DateTime(2026, 9, 29, 0, 0)], d(2026, 9, 29)) == 1);
  check('🔴 契约：`DateTime.utc(...)` 的日历字段按 UTC 取（故调用方**必须**先 `.toLocal()`）',
      // 这里只验「本层照实取字段」，不验业务正确性（那是采集端的活）
      computeStreakDays([DateTime.utc(2026, 9, 28, 17)], d(2026, 9, 28)) == 1,
      'UTC 表示取到 28 日 —— 正是采集端必须先 toLocal 的原因');

  // ══════════════════════════════════════════════════════════
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
  if (_failures.isNotEmpty) {
    throw StateError('成就规则层验收失败：${_failures.length} 项');
  }
}
