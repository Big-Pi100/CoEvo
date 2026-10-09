// CoEvo · 「复习」tab 的**容器**（双标题 + 两段切换）
//
// # 这一页解决什么（2026-10-08 白哥定案）
//
// 「我的划线」原本是**顶层路由** `/highlights`（入口在「我的」页里 push 进去）。
// 白哥定了新形态：
// > 「把『我的划线』移动到复习页面，名称改为『笔记』与『复习』同级，
// >  就像阅读页面有『今日精选』和『书架』两个同级页面一样」
//
// ⇒ 本文件 = 「阅读」tab 容器（`reading_tab_screen.dart`）的**同构实现**：
//    标题级双 Tab + `IndexedStack`（两段都留在树上，切换瞬时、状态保留）。
//
// # 🔑 为什么用 `IndexedStack` 而不是 `if (section == ...)`
//
// 后者会在切换时**销毁**另一段 —— 用户从「笔记」切回「复习」时，
// 复习列表会重新加载（滚动位置、筛选状态全丢）。「阅读」tab 已经踩过这个权衡，
// 这边沿用同一结论（见 `reading_tab_screen.dart` 的同一段注释）。
//
// # ⚠️ 与「阅读」tab 的一处**有意差异**
//
// 阅读 tab 的标题行右侧有动作（feed=「收藏 N」药丸 / books=「导入」）。
// 本容器**暂时不放右侧动作**：复习段的筛选/搜索/排序是**三件**东西、
// 且状态都在 `ReviewScreen` 内部（`_isFiltering` 等）——
// 把它们提到容器要搬一整套状态，而收益只是「标题行少一行工具条」。
// 📌 判据：**动状态的位置要有理由**；这里没有。（将来若要加，优先加「到期 N」药丸。）
//
// # 🔴 段文案来自 `review_section.dart`（纯 Dart · 可断言）
//
// 同 `reading_section.dart`：能落成常量的产品决定，别让它散在 UI 代码的字符串字面量里。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/review_list_provider.dart';
import '../theme/coevo_tokens.dart';
import '../widgets/header_chip.dart';
import '../theme/tokens_ext.dart';
import 'highlights_screen.dart';
import 'review_screen.dart';
import 'review_section.dart';

class ReviewTabScreen extends ConsumerStatefulWidget {
  const ReviewTabScreen({super.key});

  @override
  ConsumerState<ReviewTabScreen> createState() => _ReviewTabScreenState();
}

class _ReviewTabScreenState extends ConsumerState<ReviewTabScreen> {
  ReviewSection _section = ReviewSection.review;

  void _select(ReviewSection s) {
    if (s == _section) return;
    setState(() => _section = s);
  }

  /// 标题栏段落间距 —— 与阅读 tab 同一值（`reading_tab_screen._titleGap`）。
  /// 🔑 两个 tab 的标题行必须**像素级一致**，否则切 tab 时标题会横移。
  static const double _titleGap = 16;

  /// 下划线高度 —— 同阅读 tab（`_underlineHeight`）。
  static const double _underlineHeight = 3;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(t),

            // ── 两段内容（同时留在树上，切换瞬时）──
            Expanded(
              child: IndexedStack(
                index: _section.stackIndex,
                children: const [
                  ReviewScreen(),
                  HighlightsScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题栏：`复习 ｜ 笔记`。
  ///
  /// 版式照阅读 tab 的 `.feed-hd`：`padding: 2px 18px 14px`。
  Widget _header(CoEvoTokens t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
      child: Row(
        children: [
          // 🔑 `Expanded`（不是 `Flexible`）—— 理由同阅读 tab：
          //    `Flexible` 只给内容宽 ⇒ 右侧元素会紧贴标题、不贴屏幕右缘。
          //    当前右侧为空，但保持同一结构，将来加动作时不会踩这个坑。
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              // 缩放时靠左 —— 标题始终从左边开始，不因缩放横移
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in ReviewSection.values) ...[
                    if (s != ReviewSection.values.first)
                      const SizedBox(width: _titleGap),
                    _titleTab(t, s),
                  ],
                ],
              ),
            ),
          ),

          // 🆕 2026-10-08：复习段的「全部 / 已到期」筛选 —— 与两个标题**同一行**。
          //
          // 🔑 为什么它由**容器**渲染（而不是复习页自己）：
          //    标题行在容器里 ⇒ 任何想与标题同行的元素都必须在容器渲染，
          //    否则必然落到**下一行**。白哥真机反馈的正是这个 ——
          //    改成「复习 ｜ 笔记」双标题之后，筛选 chip 从「与标题同行」变成了「下一行」。
          //
          // 🔑 与阅读 tab 同构：那边的右侧动作（收藏 N / 导入）也归容器。
          //
          // ⚠️ **只在复习段显示** —— 它是**复习列表**的筛选，笔记段没有这个概念。
          //    📌「控件放哪」的第二维：除常驻成本外还有**语义归属**。
          if (_section == ReviewSection.review)
            HeaderChip(
              label: ref.watch(reviewDueOnlyProvider) ? '已到期' : '全部',
              active: ref.watch(reviewDueOnlyProvider),
              // 🔑 传**参照文案**而不是像素宽：宽度由引擎实测 ⇒ 两态同宽、
              //    文字居中、且与字体/缩放无关地**永不折行**
              //    （历史：传 36px 估算值时「已到期」在真机上折成两行）。
              labelReserve: _filterChipReserveLabel,
              onTap: () =>
                  ref.read(reviewDueOnlyProvider.notifier).update((v) => !v),
            ),
        ],
      ),
    );
  }

  /// 「全部 / 已到期」两态同宽的**参照文案**（chip 自己实测宽度）。
  static const String _filterChipReserveLabel = '已到期';

  /// 一个**标题级** Tab（23px / w600 / 字距 -1.5%）—— 与阅读 tab 同一规格。
  ///
  /// 结构用 `Stack`：下划线 `Positioned(left:1, right:1)` 贴住**文字宽**
  /// （不用 `IntrinsicWidth` —— `Stack` 的尺寸本就由非 `Positioned` 子元素决定）。
  Widget _titleTab(CoEvoTokens t, ReviewSection s) {
    final on = s == _section;
    return GestureDetector(
      // `opaque`：整块文字区域都可点（含下方 8px 留白），不只是字形上
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(s),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s.title,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 23,
                fontWeight: FontWeight.w600,
                letterSpacing: 23 * -0.015,
                // 选中 = 主文字色；未选中 = 次要色（读作「另一个标题」而非「灰掉的按钮」）
                color: Color((on ? t.ink : t.ink3).argb32),
              ),
            ),
          ),
          Positioned(
            left: 1,
            right: 1,
            bottom: 0,
            child: Container(
              height: _underlineHeight,
              decoration: BoxDecoration(
                // 未选中用透明而非「不画」：保证两态**高度一致**，切换时不跳
                color: on ? Color(t.accent.argb32) : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
