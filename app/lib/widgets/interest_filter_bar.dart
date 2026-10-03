/// 信息流页顶部的**兴趣筛选栏**（下拉展开）。
///
/// # 🆕 2026-10-03 从「我的」页移到这里（白哥真机反馈）
///
/// 白哥原话：「真机测试筛选正常，但 **UI 设计不好**，把兴趣筛选做成**下拉栏**吧」。
///
/// 🔑 **问题不只是形态，是位置**。原来的路径：
/// ```
/// 信息流 → 切「我的」tab → 找到「内容偏好」→ 点胶囊 → 切回信息流
/// （4 步，且筛选器与「被它筛的东西」不在同一屏）
/// ```
/// 而兴趣筛选本质是「**看信息流的前置控制**」—— 放在「我的」页是**语义错位**，
/// 所以用起来才会别扭。⇒ 移到信息流页顶部，**1 步**可切。
///
/// ⚠️ 这是一次「**撤回已定案**」——按项目判据，撤回是一组动作（实现 / 锚点 / 规格 /
///    断言 / 设计稿）。本轮同步改了：
///    · 本组件（新实现）
///    · `visual-feed-bookmark`（信息流锚点新增筛选栏）
///    · `profile-redesign`（移除「内容偏好」区块）
///    · `implementation-plan-v2` §10.3.2（位置决策）
///    · `verify_feed_wiring`（断言改指向本文件）
///
/// # 形态
///
/// ```
/// 收起态：  [全部 ▾]
/// 展开态：  [全部 ▴]
///           ╭──────────────────────────╮
///           │ News Tech Business Sci…  │
///           │                  [清除]   │
///           ╰──────────────────────────╯
/// ```
/// **再点标题收起**（白哥 2026-10-03 定），所以面板里**没有**「完成」按钮 ——
/// 收起动作只有一处，不制造第二个出口。
///
/// # 🔑 为什么是自包含组件（自己 watch / 自己管展开态）
///
/// · **自己 watch `interestProvider`** ⇒ 与 `home_screen` 的 `_feedKey`
///   （`interestKeyOf(ref.watch(interestProvider).valueOrNull)`）**天然同步** ——
///   两者读的是同一个 provider，不存在「界面显示 A、实际请求 B」的漂移。
/// · **展开态是纯 UI 状态**（不该持久化、不该进 provider）⇒ 放本组件的 `State` 里。
///   `home_screen` 只需一行 `const InterestFilterBar()`。
///
/// # ⚠️ 为什么没用公共组件 `HeaderChip`（**如实记录这个取舍**）
///
/// `HeaderChip` 是本项目「标题栏药丸」的**唯一权威定义**，本项目判据是
/// 「**同一外观只有一处定义**」。这里却自绘了 [_TriggerChip]，理由是**结构性的**：
/// · 它需要尾部有一个**展开指示**（`▾`，展开时旋转 180°）；
///   `HeaderChip` 的尾部位置是 `count`（`int`），**放不下任意 widget**，
///   而它的 `icon` 在**左侧**（语义是「这是什么」的图标，不是「可以展开」的指示）。
/// · 它**不需要** `labelReserve` 定宽 —— 定宽是为了解决「在标题栏里与别的元素并排时抖动」，
///   而本 chip 独占一行左侧，无对齐依赖 ⇒ 自然宽即可（宽度随「全部」/「12 类」变化可接受）。
///
/// 🔑 但我**逐个复制了 `HeaderChip` 的样式常量**（圆角 13 · 字号 11.5 w600 ·
///    `accent` 色 · padding 7×12 · `pressed + sunken` 的凹陷形态）——
///    **形态语汇必须一致**，只是允许结构不同（与 `HeaderChip` 类文档里
///    「两处结构不同是有意的，但形态完全共用」是同一条理由）。
///
/// 📌 **若将来第三处也需要这种「带展开指示的药丸」，就该把它抽成公共组件了** ——
///    两处可以各画一个，三处不行（那时漂移概率高到不值得）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/feed_item.dart';
import '../providers/interest_provider.dart';
import '../services/interest_selection.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

/// 信息流页顶部的兴趣筛选栏（下拉展开）。
class InterestFilterBar extends ConsumerStatefulWidget {
  const InterestFilterBar({super.key});

  @override
  ConsumerState<InterestFilterBar> createState() => _InterestFilterBarState();
}

class _InterestFilterBarState extends ConsumerState<InterestFilterBar> {
  /// 面板是否展开。
  ///
  /// 🔑 纯 **UI 状态**：不持久化（重启回到收起 —— 收起态信息量更大，是合理默认）、
  ///    不进 provider（它不是「用户偏好」，只是「这一刻面板开着」）。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    // 🔑 `valueOrNull ?? none`（同 `profile_screen` 的判据）：prefs 未读完 / 读失败
    //    ⇒ 按「全部」渲染。**不要** `.when(loading:)` 成空白 ——
    //    偏好读不出来不该挡住信息流（本项目判据：易失败的依赖不放渲染前置链）。
    final sel = ref.watch(interestProvider).valueOrNull ?? InterestSelection.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _trigger(t, sel),
          ),
        ),
        // 🔑 `AnimatedSize` + 高度 0 的占位：面板「就地向下展开」，
        //    收缩时下面的信息流自动上移（它在 `Expanded` 里，会让出空间）。
        //    `alignment: topCenter` 让动画从顶部往下长（符合「下拉」的直觉）。
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              // ⚠️ `width: double.infinity` 是必要的：只写 `SizedBox.shrink()`
              //    宽度会是 0 ⇒ 展开动画会**同时**从 0 宽长到全宽（横向拉伸感，很怪）。
              ? _panel(t, sel)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// 收起态的触发药丸：`[全部 ▾]` / `[3 类 ▾]`。
  ///
  /// 文案直接说明**当前状态**（而不是「筛选」这种动作词）——
  /// 用户扫一眼就知道「现在在看哪些」。
  Widget _trigger(CoEvoTokens t, InterestSelection sel) {
    final label = sel.isAll ? '全部' : '${sel.count} 类';
    return Clay(
      // 🔑 展开时**凸起**（`raised`）= 「它正开着」，与 `HeaderChip.active` 同一语汇
      //    （只改凸凹、不改填充色 —— 改填充色会与 `_SortChip` 的选中态撞脸）。
      state: _expanded ? ClayState.raised : ClayState.pressed,
      fill: _expanded ? null : t.sunken,
      borderRadius: BorderRadius.circular(13),
      onTap: () => setState(() => _expanded = !_expanded),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(t.accent.argb32),
            ),
          ),
          const SizedBox(width: 4),
          // 展开指示：展开时转 180°（`▾` → `▴`）。
          // 🔑 用 `AnimatedRotation` 而不是换图标 —— 换图标是**两帧硬切**，
          //    旋转是连续动效，与面板的 `AnimatedSize` 同一节奏（都 180ms）。
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.expand_more,
              size: 15,
              color: Color(t.accent.argb32),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开后的选择面板（凹陷抽屉：与触发药丸同一「可按下」语汇）。
  Widget _panel(CoEvoTokens t, InterestSelection sel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      child: Clay(
        state: ClayState.pressed,
        fill: t.sunken,
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: CoSpacing.sm,
              runSpacing: CoSpacing.sm,
              // 🔑 顺序 = `kCategoryLabels` 的声明顺序（与后端 `CONTENT_CATEGORIES`
              //    同源）⇒ 排序稳定，不随构建/字典序漂移。
              children: [
                for (final e in kCategoryLabels.entries)
                  _pill(
                    t,
                    label: e.value,
                    on: sel.contains(e.key),
                    onTap: () =>
                        ref.read(interestProvider.notifier).toggle(e.key),
                  ),
              ],
            ),
            // 「清除」= **回到全部的显式出口**（仅在确有勾选时出现）。
            // ⚠️ 与「再点标题收起」不重复：收起只是**藏起面板**，勾选仍在；
            //    清除是**取消全部勾选**。两者语义不同，都需要。
            if (!sel.isAll) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      ref.read(interestProvider.notifier).clear(),
                  child: const Text('清除'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个类别胶囊。
  ///
  /// 🔑 与「我的」页原来的实现**逐字相同**（形态：`Clay(state: selected)` ⇒
  ///    自动取 `accent` 填充 + `accentInk` 压字 + `accentOut` 外阴影）。
  ///    搬位置**不改形态** —— 已真机验证过的那部分不重做。
  ///
  /// ⚠️ 圆角用 `999` = 胶囊形（pill 的定义就是全圆角），不走 `clay` 的圆角派生 ——
  ///    后者是**尺寸档**的函数，而 pill 的形态与高度档无关。
  Widget _pill(
    CoEvoTokens t, {
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    return Clay(
      state: on ? ClayState.selected : ClayState.raised,
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 13,
          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
          // 选中时字压在 accent 上（`accentInk`）；未选时是普通次要文字
          color: Color(on ? t.accentInk.argb32 : t.ink2.argb32),
        ),
      ),
    );
  }
}
