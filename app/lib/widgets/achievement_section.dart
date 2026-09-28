// CoEvo · 「我的」页顶部**成就区**（规格落地）
//
// # 依据
// `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §4.2 / §6.1：
// 「**顶部成就区（连续天数 / 掌握词数 + 分享入口）**」
// 「统计内容（连续天数/掌握词数）**合并进「我的」页顶部**，作为成就展示区 + 分享入口」
// → 本 widget 就是那一块。**不设独立 tab、不设独立页面**（原 `achievements_screen` 已取消）。
//
// 「全部成就」是**二级页**（`screens/achievements_screen.dart`），从本区块进入。
//
// # 🔑 三态处理（**不向上抛**）
// 库打不开 / 查询失败时，本区块**自己**显示降级态，
// **不影响「我的」页其它内容**（账号 / 订阅 / 主题照常）。
// 依据：`bookmark_provider.dart` 的既定原则 ——「不要把 provider 当作内容渲染的前置条件」。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/achievement_provider.dart';
import '../services/achievement_rules.dart';
import '../services/achievement_service.dart';
import '../shared/achievement_icons.dart';
import '../theme/co_spacing.dart';

/// 「我的」页顶部的成就展示区。
///
/// [referralCode]：用于分享文案里带上推荐链接（可为 null —— 未登录/未拉到时纯文字分享）。
class AchievementSection extends ConsumerWidget {
  final String? referralCode;

  const AchievementSection({super.key, this.referralCode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final async = ref.watch(achievementSnapshotProvider);

    return Container(
      padding: const EdgeInsets.all(CoSpacing.lg),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: async.when(
        // ① 加载中：**固定高度占位** —— 避免「数据到了之后整页跳动」
        loading: () => const SizedBox(
          height: 132,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        // ② 失败：**可见的降级**（不是静默空态）—— 本项目判据：
        //    「静默失败 + 无出口」比报错更糟 → 这里明确说出来
        error: (e, _) => _Fallback(
          icon: Icons.cloud_off,
          text: '成就暂时无法加载',
          detail: '$e',
        ),
        // ③ 正常
        data: (snap) => _Content(snapshot: snap, referralCode: referralCode),
      ),
    );
  }
}

/// 降级态（加载失败 / 不可用）。
class _Fallback extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? detail;

  const _Fallback({required this.icon, required this.text, this.detail});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 132,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: cs.onSurfaceVariant),
          const SizedBox(height: CoSpacing.sm),
          Text(text,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          if (detail != null) ...[
            const SizedBox(height: CoSpacing.xs),
            Text(
              detail!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 正常态内容。
class _Content extends StatelessWidget {
  final AchievementSnapshot snapshot;
  final String? referralCode;

  const _Content({required this.snapshot, this.referralCode});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final metrics = snapshot.metrics;
    final unlockedCount = snapshot.unlocked.length;
    final total = kAchievements.length;

    final streak = (metrics[AchievementMetrics.streakDays] ?? 0).toInt();
    final mature = (metrics[AchievementMetrics.matureCards] ?? 0).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 标题行 ────────────────────────────────────────
        Row(
          children: [
            Icon(Icons.emoji_events, size: 16, color: cs.primary),
            const SizedBox(width: CoSpacing.xs),
            Text('我的成就',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                )),
            const Spacer(),
            TextButton(
              onPressed: () => context.push('/achievements'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: CoSpacing.sm),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('全部 $unlockedCount/$total ›',
                  style: TextStyle(fontSize: 12, color: cs.primary)),
            ),
          ],
        ),
        const SizedBox(height: CoSpacing.md),

        // ── 两个核心数字（规格明确要：连续天数 / 掌握词数）──
        Row(
          children: [
            Expanded(
              child: _BigStat(
                icon: Icons.local_fire_department,
                value: '$streak',
                unit: '天',
                label: '连续学习',
              ),
            ),
            Container(
              width: 1,
              height: 34,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
            Expanded(
              child: _BigStat(
                icon: Icons.school,
                value: '$mature',
                unit: '词',
                label: '已掌握',
              ),
            ),
          ],
        ),
        const SizedBox(height: CoSpacing.md),

        // ── 徽章行（已解锁的档位色圆徽）────────────────────
        _BadgeRow(snapshot: snapshot),
        const SizedBox(height: CoSpacing.md),

        // ── 进度条 ────────────────────────────────────────
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: snapshot.overallProgress,
            minHeight: 5,
            backgroundColor: cs.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        const SizedBox(height: CoSpacing.sm),

        // ── 分享入口（规格明确要）──────────────────────────
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _share(context),
            icon: const Icon(Icons.ios_share, size: 15),
            label: const Text('分享我的进度', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: CoSpacing.sm),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }

  /// 分享文案。
  ///
  /// 🔑 只分享**统计数字**（连续天数 / 掌握词数 / 已解锁数）——
  /// 不分享生词内容（那是用户的阅读数据，不该外泄）。
  /// ⚠️ 若 [referralCode] 为空 → 不带链接（**不编造** URL）。
  Future<void> _share(BuildContext context) async {
    final metrics = snapshot.metrics;
    final streak = (metrics[AchievementMetrics.streakDays] ?? 0).toInt();
    final mature = (metrics[AchievementMetrics.matureCards] ?? 0).toInt();
    final words = (metrics[AchievementMetrics.totalWords] ?? 0).toInt();
    final unlocked = snapshot.unlocked.length;

    final buf = StringBuffer()
      ..writeln('我在 CoEvo 的学习进度：')
      ..writeln('🔥 连续学习 $streak 天')
      ..writeln('📚 生词本 $words 词 · 已掌握 $mature 词')
      ..writeln('🏆 解锁成就 $unlocked/${kAchievements.length}');
    if (referralCode != null && referralCode!.isNotEmpty) {
      buf.writeln();
      buf.write('一起来读英文新闻：https://keyievolution.fun/?ref=$referralCode');
    }

    try {
      await Share.share(buf.toString());
    } catch (e) {
      // 分享失败（用户取消不算错，但真异常要留痕且不崩）
      // ignore: avoid_print
      print('[achievement] share 失败: $e');
    }
  }
}

/// 一个大数字（图标 + 数值 + 单位 + 标签）。
class _BigStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String unit;
  final String label;

  const _BigStat({
    required this.icon,
    required this.value,
    required this.unit,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Icon(icon, size: 15, color: cs.primary),
            const SizedBox(width: CoSpacing.xs),
            // 🔑 数值是这一块的**主角** → 字号最大（视觉层级：数值 > 标签）
            Text(value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                )),
            const SizedBox(width: 2),
            Text(unit,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: CoSpacing.xs),
        Text(label,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

/// 徽章行：**已解锁的**按清单顺序展示（最多 8 个，多出显示 `+N`）。
///
/// 🔑 **只展示已解锁的**（未解锁的不显示成灰点）——
/// 理由：本区块是「我的成果」，不是「待办清单」。
/// 未解锁的完整列表去**成就墙**看（那里才有进度条）。
class _BadgeRow extends StatelessWidget {
  final AchievementSnapshot snapshot;

  const _BadgeRow({required this.snapshot});

  static const int _maxShown = 8;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unlockedDefs =
        kAchievements.where((d) => snapshot.unlocked.contains(d.key)).toList();

    if (unlockedDefs.isEmpty) {
      return Text(
        '还没有解锁成就 —— 去读一篇文章，查几个词试试',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }

    final shown = unlockedDefs.take(_maxShown).toList();
    final rest = unlockedDefs.length - shown.length;

    return Row(
      children: [
        for (final d in shown) ...[
          AchievementBadge(def: d, unlocked: true, size: 30),
          const SizedBox(width: CoSpacing.sm),
        ],
        if (rest > 0)
          Text('+$rest',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

/// 单个成就徽章（圆形底 + 图标）。
///
/// 🔑 已解锁 = **档位实色底 + 白图标**；未解锁 = **中性灰底 + 半透明图标**。
/// 用「**颜色 + 明度**」两种手段同时区分（不靠单一细微色差）——
/// 依据：判据「能靠形状/明度区分就别靠参数」。
class AchievementBadge extends StatelessWidget {
  final AchievementDef def;
  final bool unlocked;
  final double size;

  const AchievementBadge({
    super.key,
    required this.def,
    required this.unlocked,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final bg = unlocked ? tierColor(def.tier) : kLockedBadgeColor;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg.withValues(alpha: unlocked ? 1.0 : 0.35),
        shape: BoxShape.circle,
      ),
      child: Icon(
        achievementIcon(def.icon),
        size: size * 0.52,
        color: Colors.white.withValues(alpha: unlocked ? 1.0 : 0.55),
      ),
    );
  }
}
