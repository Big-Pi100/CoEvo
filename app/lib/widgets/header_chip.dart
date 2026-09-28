/// 标题栏上的**药丸** —— 全应用**唯一**一处定义。
///
/// # 消费者（2026-09-28 起两个）
/// | 位置 | 用法 |
/// |---|---|
/// | 信息流标题栏 | 「收藏 N」入口（带计数） |
/// | 复习页标题栏 | 「全部 / 已到期」筛选（不带计数） |
///
/// # 🔴 为什么抽成公共组件（而不是两处各画一个）
/// 白哥 2026-09-28：「『全部、已到期』按钮应该和阅读页的**收藏按钮的外观保持一致**」。
///
/// 🔑 **「外观一致」最可靠的实现方式 = 只有一处定义。**
///    两处各写一份，即使今天参数完全相同，也会在下次改一处时**静默走偏**
///    （这类漂移编译器看不出来，且往往到真机上才被发现）。
///    这与项目既有判据一致：「设计稿里是同一个东西，实现里就该是一处」
///    （同 `toggleBookmarkWithToast`、`_ClayTabBar` 被抽出来的理由）。
///
/// # 形态来源：设计稿 `.bm-entry`
/// ```
/// .bm-entry{display:flex;align-items:center;gap:6px;
///   font-size:11.5px;font-weight:600;color:var(--accent);
///   background:var(--sunken);border-radius:13px;padding:7px 12px;
///   box-shadow:inset 2px 2px 6px var(--cl-shade), inset -2px -2px 5px var(--cl-light)}
/// ```
///
/// 🔑 **它是「凹陷」的** —— `background:var(--sunken)` + **两个 inset**（没有外阴影）=
/// 粘土语汇里的 `pressed`（凹）。与 `BookmarkButton` 的未收藏态**同一种物理形态**：
/// 凹陷 = 「可以按下去」。这不是巧合，设计稿把「未激活的入口」统一做成凹陷。
///
/// # ⚠️ 圆角显式传 13、不走 token 档位
/// （同 `_ClayTabBar` 的 17、`BookmarkButton` 的 10）：设计稿写死 `13px`
/// 且不在主题变量里 → 三档共用。这是项目已定的处理方式。
///
/// ⚠️ **字体用 `CoFonts.uiSans` 而非设计稿的 `--round`**：`--round` 是 Quicksand，
/// 项目未打包该字体 → 与 `FeedCard` / `_ClayTabBar` 同一取舍。
library;

import 'package:flutter/material.dart';

import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

class HeaderChip extends StatelessWidget {
  const HeaderChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
  });

  /// 图标（由调用方注入 —— 「收藏」用书签、筛选用 filter）。
  final IconData icon;

  /// 文案（「收藏」/「全部」/「已到期」）。
  final String label;

  /// 计数（设计稿 `.bm-entry .n`）。
  ///
  /// 🔑 **可选**：不是所有药丸都要计数 —— 复习页的筛选按钮只表达「当前在看哪一档」，
  ///    硬塞一个数字反而会让用户以为那是「已到期的数量」。
  ///    传 `null` = 不渲染计数段（含它前面那个 `gap`）。
  final int? count;

  final VoidCallback onTap;

  /// 设计稿 `.bm-entry{border-radius:13px}` —— 写死，不走 token。
  static final BorderRadius _radius = BorderRadius.circular(13);

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final fg = Color(t.accent.argb32);
    final n = count;

    return Clay(
      state: ClayState.pressed,
      // ⚠️ 必须显式给 `sunken`：`Clay` 默认填充是 `clayFill`（= `card`），
      //    而设计稿这里的底是 `--sunken`（比 `page` 更暗）。同 `BookmarkButton`。
      fill: t.sunken,
      borderRadius: _radius,
      onTap: onTap,
      // 设计稿 `.bm-entry{padding:7px 12px}`
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 设计稿 `<svg width="13" height="13">`（2px 描边）
          Icon(icon, size: 13, color: fg),
          // 设计稿 `.bm-entry{gap:6px}`
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
          if (n != null) ...[
            const SizedBox(width: 6),
            // 设计稿 `.bm-entry .n{font-size:10.5px;opacity:.7}`
            // ⚠️ 用 `Opacity` 而不是改 alpha：与设计稿的 `opacity` 语义一致
            //    （整段变淡，而不是换一个更浅的颜色）。
            Opacity(
              opacity: 0.7,
              child: Text(
                '$n',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 10.5,
                  color: fg,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
