/// 成就墙 —— 「我的」页顶部成就区点「全部」进来的**二级页**。
///
/// # 🔴 为什么它是**顶层路由**（而不是「我的」页里的一个状态）
/// 判据是项目已定的那条：**它是不是 tab 的内容** ——
/// 否（它是覆盖全屏的二级页）→ **顶层路由**。
/// 同 `/review/session`（翻卡）· `/article/:id`（阅读器）· `/aggregate/:id`（聚合页）。
///
/// ⚠️ 反例（2026-09-28 踩过）：把这类界面做成「页内 `bool` 状态」时，
///    它会**静默继承**所在页面的布局约束（`extendBody` + tabbar ≈100px）
///    → 底部内容被盖住且拉不出来，而**编译器不报错**。
///
/// # 依据
/// `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §4.2：
/// 「连续天数 / 里程碑的逻辑并入「我的」页顶部成就区；**原独立页面取消**」
/// → 本页**不是**旧 `achievements_screen`（1,000 行 · 含 plan/概念卡成就）的复活，
///    而是一个**只展示当前 20 个端侧成就**的轻量二级页。
///
/// # 界面
/// ```
/// ‹ 返回                    成就
/// ─────────────────────────────
///   已解锁 7/20   ▓▓▓▓░░░░░░
/// ─────────────────────────────
/// 🔥 坚持                    2/4
///   (徽章) 起步      连续 3 天学习        06-12
///   (灰)   一周达人  连续 7 天学习        3/7
/// ...
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/achievement_provider.dart';
import '../services/achievement_rules.dart';
import '../services/achievement_service.dart';
import '../shared/achievement_icons.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/achievement_section.dart' show AchievementBadge;

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = CoEvoTokensExt.of(context);
    final async = ref.watch(achievementSnapshotProvider);

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _TopBar(title: '成就'),
            Expanded(
              child: async.when(
                // 首次加载 → 什么都不画（画空态会先闪一下「打不开」，是谎报）
                loading: () => const SizedBox.shrink(),
                error: (e, _) => _Unavailable(detail: '$e'),
                data: (snap) => _AchievementList(snapshot: snap, token: t),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表主体（含解锁时间）。
class _AchievementList extends ConsumerWidget {
  final AchievementSnapshot snapshot;
  final CoEvoTokens token;

  const _AchievementList({required this.snapshot, required this.token});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 解锁时间：`snapshot` 里不含，需要从库读。
    // 🔑 用 `FutureProvider` 会引入第二个异步源 → 两处 loading 不一致；
    //    改为**同一个 provider 派生**（见 `unlockTimesProvider`）。
    final times = ref.watch(achievementUnlockTimesProvider);

    final unlocked = snapshot.unlocked.length;
    final total = kAchievements.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        // ── 总进度 ────────────────────────────────────────
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('已解锁 ',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14,
                  color: Color(token.ink2.argb32),
                )),
            Text('$unlocked',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  color: Color(token.accent.argb32),
                )),
            Text('/$total',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14,
                  color: Color(token.ink2.argb32),
                )),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: snapshot.overallProgress,
            minHeight: 5,
            backgroundColor: Color(token.line.argb32),
            valueColor: AlwaysStoppedAnimation(Color(token.accent.argb32)),
          ),
        ),
        const SizedBox(height: 20),

        // ── 按分类分组 ────────────────────────────────────
        for (final meta in kCategoryMeta) ...[
          _CategoryHeader(
            meta: meta,
            unlockedInCategory: achievementsInCategory(meta.category)
                .where((d) => snapshot.unlocked.contains(d.key))
                .length,
            totalInCategory: achievementsInCategory(meta.category).length,
            token: token,
          ),
          const SizedBox(height: 6),
          for (final def in achievementsInCategory(meta.category))
            _AchievementRow(
              def: def,
              unlocked: snapshot.unlocked.contains(def.key),
              unlockedAt: times.valueOrNull?[def.key],
              progressLabel: achievementProgressLabel(def, snapshot.metrics),
              progress: achievementProgress(def, snapshot.metrics),
              token: token,
            ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

/// 分类标题行。
class _CategoryHeader extends StatelessWidget {
  final CategoryMeta meta;
  final int unlockedInCategory;
  final int totalInCategory;
  final CoEvoTokens token;

  const _CategoryHeader({
    required this.meta,
    required this.unlockedInCategory,
    required this.totalInCategory,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(categoryIcon(meta.category), size: 15, color: Color(token.accent.argb32)),
        const SizedBox(width: 6),
        Text(meta.label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(token.ink.argb32),
            )),
        const Spacer(),
        Text('$unlockedInCategory/$totalInCategory',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12,
              color: Color(token.ink3.argb32),
            )),
      ],
    );
  }
}

/// 单个成就行：徽章 + 名称/描述 + 右侧（解锁日期 或 进度）。
class _AchievementRow extends StatelessWidget {
  final AchievementDef def;
  final bool unlocked;
  final DateTime? unlockedAt;
  final String progressLabel;
  final double progress;
  final CoEvoTokens token;

  const _AchievementRow({
    required this.def,
    required this.unlocked,
    required this.unlockedAt,
    required this.progressLabel,
    required this.progress,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          AchievementBadge(def: def, unlocked: unlocked, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(def.name,
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          // 未解锁 → 用次级色（**可见但不抢眼**）
                          color: Color(
                              unlocked ? token.ink.argb32 : token.ink2.argb32),
                        )),
                    const SizedBox(width: 6),
                    Text(tierLabel(def.tier),
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 10,
                          color: unlocked
                              ? tierColor(def.tier)
                              : Color(token.ink3.argb32),
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                Text(def.description,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12,
                      color: Color(token.ink3.argb32),
                    )),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // 右侧：已解锁 → 日期；未解锁 → 进度（含细进度条）
          SizedBox(
            width: 58,
            child: unlocked
                ? Text(
                    unlockedAt == null ? '已解锁' : _fmtDate(unlockedAt!),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11,
                      color: Color(token.accent.argb32),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(progressLabel,
                          style: TextStyle(
                            fontFamily: CoFonts.uiSans,
                            fontSize: 11,
                            color: Color(token.ink3.argb32),
                          )),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          backgroundColor: Color(token.line.argb32),
                          valueColor: AlwaysStoppedAnimation(
                              Color(token.accentBright.argb32)),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// `YYYY-MM-DD`（**手写** —— 项目未引入 `intl`，见 pubspec 的说明）。
String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 顶栏（与聚合页同款：`‹ 返回` + 标题）。
class _TopBar extends StatelessWidget {
  final String title;

  const _TopBar({required this.title});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 18, 8),
      child: Row(
        children: [
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('‹',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 20,
                        height: 1,
                        color: Color(t.ink2.argb32),
                      )),
                  const SizedBox(width: 4),
                  Text('返回',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 14,
                        color: Color(t.ink2.argb32),
                      )),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text(title,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              )),
        ],
      ),
    );
  }
}

/// 库打不开 / 查询失败 —— **给准确的话**，不留静默失败。
class _Unavailable extends StatelessWidget {
  final String? detail;

  const _Unavailable({this.detail});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.emoji_events_outlined,
                size: 30, color: Color(t.ink3.argb32)),
            const SizedBox(height: 12),
            Text('成就暂时打不开',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14,
                  color: Color(t.ink2.argb32),
                )),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(detail!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 11,
                    color: Color(t.ink3.argb32),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}
