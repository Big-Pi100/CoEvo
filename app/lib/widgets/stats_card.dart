// CoEvo · 「我的」页顶部**统计卡**（规格落地）
//
// # 依据（白哥 2026-09-29 决策 · 这是本轮定稿）
// 原 `AchievementSection` 是「成就区」：两个数字 + **徽章行** + 进度条 + 分享。
// 白哥 2026-09-29 定为：
// > 「顶部**只放统计 + 分享**（连续天数 / 掌握词数 / **阅读篇数**）；
// >  **成就列表留在 /achievements**」
//
// → 本 widget **删掉了**徽章行、进度条与「我的成就」标题行（那三样都是「成就列表」的形态），
//   只保留**统计数字 + 分享**，并新增第三个数字「阅读篇数」。
//   ⚠️ 徽章行与进度条**不是被删功能** —— 它们仍在「成就墙」页完整存在（`achievements_screen`）。
//
// 上游规格（未变）：`docs/design/ui-ux-refactor-assessment-2026-09-25.md` §4.2 / §6.1
// 「**顶部**：统计区 + 分享入口」「统计内容合并进『我的』页顶部」
// → **不设独立统计 tab、不设独立页面**。
//
// # 🔑 三态处理（**不向上抛**）
// 库打不开 / 查询失败时，本区块**自己**显示降级态，
// **不影响「我的」页其它内容**（账号 / 订阅 / 主题照常）。
// 依据：`bookmark_provider.dart` 的既定原则 ——「不要把 provider 当作内容渲染的前置条件」。
//
// # 🔑 三个数字**同源**
// 都从 `AchievementMetrics` 的**一次采集**拿（`achievementSnapshotProvider`）。
// 「阅读篇数」（`articlesRead`）也走同一个采集 ——
// 避免「顶部两个数从 A 拿、第三个数从 B 拿」这种**口径分叉**。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/achievement_provider.dart';
import '../services/achievement_rules.dart';
import '../services/achievement_service.dart';
import '../theme/co_spacing.dart';

/// 「我的」页顶部的统计卡：**三列数字 + 分享**。
///
/// [referralCode]：用于分享文案里带上推荐链接（可为 null —— 未登录/未拉到时纯文字分享）。
class StatsCard extends ConsumerWidget {
  final String? referralCode;

  const StatsCard({super.key, this.referralCode});

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
          text: '统计暂时无法加载',
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
            Text(detail!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7))),
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
    final metrics = snapshot.metrics;

    final streak = (metrics[AchievementMetrics.streakDays] ?? 0).toInt();
    final mature = (metrics[AchievementMetrics.matureCards] ?? 0).toInt();
    // 🆕 阅读篇数（口径「乙」：读完 且 去重）—— 见 `article_read_repository.dart`
    final read = (metrics[AchievementMetrics.articlesRead] ?? 0).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 🔴 三列统计（白哥 2026-09-29：连续天数 / 掌握词数 / 阅读篇数）──
        //
        // 🔑 **三列不是「两列加一列」** —— 列宽、分隔线、字号都要按三列重新配平：
        //    · 两列时用竖直分隔线很好看；**三列时横向空间只剩 ~1/3**，
        //      再加两条分隔线会显得很挤 → 改为**不加分隔线**，靠间距分组。
        //    · 数字字号 24 → **21**：三列下 24px 的「248」会把列挤到贴边
        //      （「已掌握」的「词」单位会折行），21px 在 1/3 宽里留得住。
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
            Expanded(
              child: _BigStat(
                icon: Icons.school,
                value: '$mature',
                unit: '词',
                label: '已掌握',
              ),
            ),
            Expanded(
              child: _BigStat(
                icon: Icons.menu_book,
                value: '$read',
                unit: '篇',
                label: '已读完',
              ),
            ),
          ],
        ),
        const SizedBox(height: CoSpacing.md),

        // ── 分享入口（规格明确要）──────────────────────────
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _share(context),
            icon: const Icon(Icons.ios_share, size: 15),
            label: const Text('分享我的学习记录', style: TextStyle(fontSize: 12)),
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
  /// 🔑 只分享**统计数字**（连续天数 / 掌握 / 阅读篇数）——
  /// 不分享生词内容（那是用户的阅读数据，不该外泄）。
  /// ⚠️ 若 [referralCode] 为空 → 不带链接（**不编造** URL）。
  Future<void> _share(BuildContext context) async {
    final metrics = snapshot.metrics;
    final streak = (metrics[AchievementMetrics.streakDays] ?? 0).toInt();
    final mature = (metrics[AchievementMetrics.matureCards] ?? 0).toInt();
    final read = (metrics[AchievementMetrics.articlesRead] ?? 0).toInt();

    final buf = StringBuffer()
      ..writeln('我在 CoEvo 的学习记录：')
      ..writeln('🔥 连续学习 $streak 天')
      ..writeln('📚 已掌握 $mature 词 · 读完 $read 篇文章');
    if (referralCode != null && referralCode!.isNotEmpty) {
      buf.writeln();
      buf.write('一起来读英文新闻：https://keyievolution.fun/?ref=$referralCode');
    }

    try {
      await Share.share(buf.toString());
    } catch (e) {
      // 分享失败（用户取消不算错，但真异常要留痕且不崩）
      debugPrint('[stats] share 失败: $e');
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
            // ⚠️ 三列下**图标也要小**：15 → 14，且与数字间距压到 3
            //    （原先两列时 15+4 很舒展；三列会把它挤到贴边）
            Icon(icon, size: 14, color: cs.primary),
            const SizedBox(width: 3),
            // 🔑 数值是这一块的**主角** → 字号最大（视觉层级：数值 > 标签）
            //    ⚠️ 但三列下 24px 会顶到边 → 21px（见上面 §三列统计 的说明）
            Text(value,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                )),
            const SizedBox(width: 1),
            Text(unit,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: CoSpacing.xs),
        Text(label,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      ],
    );
  }
}
