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
/// # 🆕 两态：一凹一凸（2026-09-28 20:1x 白哥定）
/// > 「全部/已到期两个状态……应该**一个凹陷一个浮起**，而不是都一样」
///
/// 参数 [active] 控制：
/// | `active` | 态 | 读作 | 谁在用 |
/// |---|---|---|---|
/// | `false`（默认） | `pressed` + `sunken` | **凹陷** = 「可按下」 | 信息流「收藏」入口 · 复习页「全部」 |
/// | `true` | `raised` + `clayFill` | **浮起** = 「**激活中**」 | 复习页「已到期」 |
///
/// 🔑 **为什么「激活」用 `raised` 而不是 `selected`**：
///    `selected` = 凸起 **+ 强调色填充**（`Clay` 内部 `isSelected ? tokens.accent : …`），
///    而项目已定：卡片上的「选中」若用强调填充，会与 `_SortChip` 的选中态**撞脸**
///    （两者都变成实心药丸 → 用户会以为它们是同一组单选）。
///    [active] 只改**凸凹**、不改填充色 → 与 `_SortChip` 保持区分，
///    同时与 `BookmarkButton`（已收藏 = 凸起）**同一语汇**。
///
/// # 🆕 宽度固定（[minWidth]，同一次定案）
/// > 「两个状态的大小应该统一，最好和阅读页面的收藏大小一致」
///
/// 🔴 **不固定会怎样**：`label` 在「全部」(2 字) / 「已到期」(3 字) 间切换 →
///    药丸宽度**跳变约 11.5px**（一个字的宽），切换时整条标题栏跟着抖。
///    传 [minWidth] 后两个状态同宽，且可与其它药丸（信息流「收藏 N」）**视觉等宽**。
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
    this.active = false,
    this.minWidth,
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

  /// **激活态**（凸起）—— 默认 `false` = 凹陷（与既有调用处行为一致）。
  ///
  /// 语义见类文档：`true` = 「**它正处于生效状态**」（如「已到期」筛选已开），
  /// 只改**凸凹**、**不改填充色**（避免与 `_SortChip` 撞脸）。
  final bool active;

  /// **最小宽度** —— 用于「文案长度会变」的药丸，避免切换时宽度跳变。
  ///
  /// 传 `null`（默认）= 自然宽（既有调用处行为不变）。
  /// 复习页传一个与信息流「收藏 N」药丸相当的宽度 → 两处视觉等宽。
  ///
  /// ⚠️ 实现上会给内容**居中**（`MainAxisAlignment.center`），
  ///    否则短文案会贴左、长文案贴右，两个状态的文字位置不一致。
  final double? minWidth;

  /// 设计稿 `.bm-entry{border-radius:13px}` —— 写死，不走 token。
  static final BorderRadius _radius = BorderRadius.circular(13);

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final fg = Color(t.accent.argb32);
    final n = count;
    final w = minWidth;

    return Clay(
      state: active ? ClayState.raised : ClayState.pressed,
      // ⚠️ 必须显式给 `sunken`：`Clay` 默认填充是 `clayFill`（= `card`），
      //    而设计稿这里的底是 `--sunken`（比 `page` 更暗）。同 `BookmarkButton`。
      // 🔑 `active` 时不传（`null` → `Clay` 用 `clayFill`）——
      //    于是「凹 = 暗底 + 内阴影」「凸 = 亮底 + 外阴影」，**填充色也跟着区分**，
      //    凸凹差异更明确（但仍**不是**强调色填充 → 不与 `_SortChip` 撞脸）。
      fill: active ? null : t.sunken,
      borderRadius: _radius,
      onTap: onTap,
      // 设计稿 `.bm-entry{padding:7px 12px}`
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: w ?? 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          // ⚠️ 有 `minWidth` 时必须居中：否则宽度被撑到 minWidth 后，
          //    内容仍贴左 → 两个状态的文字位置看起来不一致（正是要修的问题）。
          mainAxisAlignment:
              w == null ? MainAxisAlignment.start : MainAxisAlignment.center,
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
      ),
    );
  }
}
