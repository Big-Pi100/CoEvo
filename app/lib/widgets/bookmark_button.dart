import 'package:flutter/material.dart';

import '../theme/clay.dart';
import '../theme/tokens_ext.dart';

/// 书签按钮 —— 设计稿 `.bm` / `.bm.on`。
///
/// # 为什么单独成文件
/// 设计稿里**卡片右上角与阅读界面顶部栏用的是同一个 `.bm` 类**
/// （`.fc .bm` 与 `.rd-bar .bm` 共享样式）→ 它就应该是**一个组件**，
/// 而不是两处各画一遍。3.3 时它和 `FeedCard` 同文件，
/// 3.4 阅读器也要用 → 抽出来（否则阅读器得 `import 'feed_card.dart'` 只为拿个按钮，
/// 依赖方向会变得莫名）。
///
/// # 🔑 「凹 → 凸」正好是粘土的 `pressed` / `selected` 语义
/// 设计稿的两个态**本来就是粘土的两种物理状态**，不需要新机制：
///
/// | 态 | 设计稿 | `ClayState` |
/// |---|---|---|
/// | 未收藏 | `background:var(--sunken)` + **两个 inset** | **`pressed`**（凹陷） |
/// | 已收藏 | `background:var(--accent)` + **外阴影 `accent-out`** + inset | **`selected`**（凸起 + 强调色填充） |
///
/// → 与 `clay.dart` 的类注释完全对应：「默认（三层齐全）/ 按下（凹陷）/ **选中（凸起 + 强调色填充，读作「激活」）**」。
/// 设计稿的原话是「已收藏 = 书签**实心 + 强调色底**，与粘土语汇一致（**凸起表示「已激活」**）」——
/// 它自己就点明了这是粘土的激活态。
///
/// # 尺寸（设计稿 `.bm`）
/// `30×30` · 圆角 **10px（写死，不在主题变量里）** · 图标 `15×15`。
///
/// ⚠️ 圆角显式传 10、**不走 token 档位** —— 与 `_ClayTabBar` 的「17px 写死」同一情况：
/// token 的 sm 档会给「墨 13 / 格 14 / 夜 12」，而设计稿三档共用 10。
/// 这是 Step 3.1 定下的处理方式（**照设计稿**），两处保持一致。
class BookmarkButton extends StatelessWidget {
  const BookmarkButton({
    super.key,
    required this.bookmarked,
    this.onPressed,
  });

  final bool bookmarked;

  /// `null` = 禁用（不可点，且视觉上变淡）。
  final VoidCallback? onPressed;

  /// 设计稿 `.bm{width:30px;height:30px}`。
  static const double _size = 30;

  /// 设计稿 `.bm{border-radius:10px}` —— **写死，不走 token**（见类文档）。
  static final BorderRadius _radius = BorderRadius.circular(10);

  /// 设计稿 `.bm svg{width:15px;height:15px}`。
  static const double _iconSize = 15;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final disabled = onPressed == null;

    // 图标颜色：已收藏压 `accentInk`（朱砂底上的字），未收藏用 `ink3`
    final iconColor =
        bookmarked ? Color(t.accentInk.argb32) : Color(t.ink3.argb32);

    return SizedBox(
      width: _size,
      height: _size,
      // 🔴 不可交互时**整体降透明度** ——
      //    ⚠️ 刻意**不用 `ClayState.disabled`**：那个态的定义是
      //    「抽掉内亮 + 外阴影减半」，即**从「凸起」变「瘪」**；
      //    而书签未收藏时本来就是**凹陷**（`pressed`）→ 套 disabled 会变成「凸起」，
      //    **语义直接反转**（凹陷 = 未收藏，凸起 = 已收藏，不能乱）。
      //    → 只用一层透明度表达「当前不可用」，不触碰粘土的物理语义。
      //
      //    设计稿**没有定义**禁用态（它的书签永远可点），所以这层透明度是
      //    我按「不引入新语义」的原则加的最小表达 —— 而不是自创一个粘土的第五态。
      //
      //    ⚠️ 实际观感：这个状态**极短暂**（打开数据库通常 <100ms），
      //    只有在数据库**打开失败**时才会长期停留（那时它就是「该功能不可用」的诚实表达）。
      child: Opacity(
        opacity: disabled ? 0.45 : 1.0,
        child: Clay(
          // 🔴 未收藏 = 凹陷（pressed）· 已收藏 = 凸起 + 强调色（selected）
          state: bookmarked ? ClayState.selected : ClayState.pressed,
          // ⚠️ 未收藏态必须显式给 `sunken` 填充：`Clay` 的默认填充是 `clayFill`（= `card`），
          //    而设计稿的未收藏底是 `--sunken`（比卡面更暗）—— 不给就会「凹了但看不出来」。
          fill: bookmarked ? null : t.sunken,
          borderRadius: _radius,
          // 禁用时不传 onTap —— `Clay` 会因此去掉交互与按下动效
          onTap: onPressed,
          child: Center(
            child: Icon(
              bookmarked ? Icons.bookmark : Icons.bookmark_border,
              size: _iconSize,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
