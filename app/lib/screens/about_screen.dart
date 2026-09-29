// CoEvo · 关于页
//
// 从「我的」页进入（`/about`）—— 依据 `ui-ux-refactor-assessment-2026-09-25` §6.1
// 定稿的「我的」子树最后一项：「关于」。
//
// # 🔴 本页**只有真实存在的内容**（不放假链接）
//
// | 想放的 | 为什么现在没放 |
// |---|---|
// | **隐私政策** | 🔴 URL 尚未确定。它是 **Apple 上架的硬要求**（App Store Connect 必填 + App 内应有入口）→ **待白哥提供正式 URL 后补**。**不编造链接**（判据同 `stats_card` 的分享注释：「若不编造 URL」）。 |
// | **用户协议** | 同上 |
// | **ICP 备案号** | ✅ 已备案（粤ICP备2026061557号-1）→ **可以放**，中国区 App 常规要求 |
// | 开源许可 | Flutter / 字体的许可都是真实的 → 可放；本版先不铺开（一张长列表会把「关于」变成一堵墙） |
// → 🔑 判据：**页面上的每个链接都必须能打开**。放一个死链比不放进糟糕 ——
//    用户点了没反应，会以为是 App 坏了（同「静默失败 + 无出口」）。

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_info.dart';
import '../theme/co_spacing.dart';
import '../theme/tokens_ext.dart';
import '../theme/coevo_tokens.dart';
import '../widgets/twemoji.dart';

/// 关于页（版本 · 备案号 · 待补项）。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Scaffold(
      // 🔑 与全站一致：**自绘顶栏**（不用 Material `AppBar`）
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 顶栏：「返回」在右（照 `bookmark_list_screen` 的范式：
            //    设计稿 `.bm-hd .back` 是**右对齐的文字链接**，不是左箭头）──
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '关于',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 23 * -0.015,
                        color: Color(t.ink.argb32),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => context.pop(),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '返回',
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(t.accent.argb32),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    CoSpacing.xxl, 0, CoSpacing.xxl, CoSpacing.tabBarClearance),
                children: [
                  const SizedBox(height: CoSpacing.xl),
                  // ── App 名 + 版本 ──
                  Center(
                    child: Column(
                      children: [
                        Text(
                          kCoEvoName,
                          style: TextStyle(
                            fontFamily: CoFonts.uiSans,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: Color(t.ink.argb32),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '版本 $kCoEvoVersion',
                          style: TextStyle(
                            fontFamily: CoFonts.uiSans,
                            fontSize: 12.5,
                            color: Color(t.ink3.argb32),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: CoSpacing.xl),

                  _InfoRow(label: '应用名称', value: kCoEvoName),
                  _InfoRow(label: '版本', value: kCoEvoVersion),
                  // 🔑 备案号是**中国区上架的常规要求**，且已真实持有 → 直接放（不是占位）
                  _InfoRow(label: '备案号', value: '粤ICP备2026061557号-1'),

                  const SizedBox(height: CoSpacing.xl),
                  Divider(height: 1, color: Color(t.line.argb32)),
                  const SizedBox(height: CoSpacing.lg),

                  // ── 说明 ──
                  Text(
                    'CoEvo 是一款英语学习应用：读英文新闻、划词查词、'
                    '把生词收进生词本，再按记忆曲线复习。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      height: 1.8,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                  const SizedBox(height: CoSpacing.lg),

                  // ── 🔴 待补项（**可见地标注，而不是留死链**）──
                  //    Apple 上架需要「隐私政策」入口；URL 未定 → 先如实说明，
                  //    而不是放一个点了没反应的链接。
                  Text(
                    '隐私政策与用户协议即将上线。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「标签 — 值」一行。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              color: Color(t.ink3.argb32),
            ),
          ),
          const Spacer(),
          Flexible(
            child: Tw(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                color: Color(t.ink.argb32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
