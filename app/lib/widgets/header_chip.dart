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
/// # 🆕 宽度固定 + **文字真居中**（[labelMinWidth]，2026-09-28 21:0x 修正）
/// 白哥真机两条反馈：「**药丸太宽**」「**内容看起来不居中**」。
///
/// ## ① 上一版的两个错
/// · 🔴 **宽度口径搞错**：上一版把「≈ 收藏药丸宽（含 padding 的 **整宽** 84）」
///   传给了作用在 **`padding` 内部**的 `minWidth` → 实际整宽 = 84 + 24 = **108**，
///   比目标宽 24px（内容只占药丸的 39%，看着**空**）。
/// · 🔴 **文字偏右**：把「图标 + 文字」**整块**居中时，文字必然偏右
///   —— 图标（13）+ 间距（6）只占左边，居中后文字被推右 `(13+6)/2 = 9.5px`。
///
/// ## ② 修法：按「**让文字落在药丸正中**」反推内边距
/// 设文字区起点距左 = `L`，文字区宽 = `labelW`，右内边距 = `R`：
/// ```
/// 药丸宽      = L + labelW + R
/// 文字区中心  = L + labelW / 2
/// 药丸中心    = (L + labelW + R) / 2
/// 令两者相等 → L + labelW/2 = (L + labelW + R)/2 → L = R
/// ```
/// 🔑 **结论：只要「左右到文字区的距离相等」，文字就正好在药丸正中。**
///    而 `L` 里含图标（`_iconLead + _iconSize + _iconGap`）→ **`R` 必须等于 `L`**。
///    即右内边距要**故意比左内边距大**（多出「图标 + 间距」）。
///
/// ⚠️ **取舍（必须知情）**：这样图标会**看起来靠左** ——
///    这是「文字居中」的必然结果，因为图标只占左边、右边没有对称物。
///    **「图标+文字整块居中」与「文字居中」不能同时成立**（两者差 9.5px）。
///    白哥要的是**文字居中**，所以按上面反推。
///
/// 📐 **实际尺寸**（`labelMinWidth = 36` 时）：
/// ```
/// 药丸 = 8(左) + 13(图标) + 6(间距) + 36(文字区) + 27(右) = 90
/// 文字区 27…63，中心 45 ； 药丸中心 90/2 = 45   ← 精确相等
/// ```
/// ⚠️ 仍略宽于「收藏 N」药丸（≈84）—— 因为**文字居中**要求右侧留出与图标等量的空间。
///    若要更窄，只能缩小 [_iconLead] 或去掉图标。
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
    this.labelMinWidth,
  }) : assert(
          labelMinWidth == null || count == null,
          'labelMinWidth 与 count 不能同时用：文字居中的推导（L == R）'
          '假设文字区右侧没有其它元素；带计数时请走自然宽（不传 labelMinWidth）。',
        );

  /// 图标（由调用方注入 —— 「收藏」用书签、筛选用 filter）。
  final IconData icon;

  /// 文案（「收藏」/「全部」/「已到期」）。
  final String label;

  /// 计数（设计稿 `.bm-entry .n`）。
  ///
  /// 🔑 **可选**：不是所有药丸都要计数 —— 复习页的筛选按钮只表达「当前在看哪一档」，
  ///    硬塞一个数字反而会让用户以为那是「已到期的数量」。
  ///    传 `null` = 不渲染计数段（含它前面那个 `gap`）。
  /// ⚠️ 与 [labelMinWidth] **互斥**（见构造函数的 `assert`）。
  final int? count;

  final VoidCallback onTap;

  /// **激活态**（凸起）—— 默认 `false` = 凹陷（与既有调用处行为一致）。
  ///
  /// 语义见类文档：`true` = 「**它正处于生效状态**」（如「已到期」筛选已开），
  /// 只改**凸凹**、**不改填充色**（避免与 `_SortChip` 撞脸）。
  final bool active;

  /// **文字区最小宽**（可选）—— 用于「文案长度会变」的药丸。
  ///
  /// 传 `null`（默认）= 自然宽 + 设计稿的对称内边距（信息流「收藏 N」走这条）。
  ///
  /// 🔑 **传了它，同时得到三件事**（推导见类文档 §🆕）：
  /// 1. **两态同宽**：`label` 在「全部」(2 字) / 「已到期」(3 字) 间切换时，
  ///    自然宽会跳变 ~11.5px（一个字宽）→ 整条标题栏跟着抖。
  /// 2. **文字位置不横移**：文字区定宽 + 居中 → 两个 label 的中心**完全同位**。
  ///    （不定宽时，位移 = 两 label 宽度差 / 2 ≈ 5.75px）
  /// 3. **文字落在药丸正中**：右内边距被反推为 `L`（＝左内边距 + 图标 + 间距）。
  ///
  /// ⚠️ **取值要能容纳最长的那个 label**（复习页「已到期」3 字 × 11.5px = 34.5 → 取 36）。
  final double? labelMinWidth;

  /// 设计稿 `.bm-entry{border-radius:13px}` —— 写死，不走 token。
  static final BorderRadius _radius = BorderRadius.circular(13);

  /// 设计稿 `<svg width="13" height="13">`（2px 描边）。
  static const double _iconSize = 13;

  /// 设计稿 `.bm-entry{gap:6px}`。
  static const double _iconGap = 6;

  /// 图标**距药丸左边缘**的留白（仅在传了 [labelMinWidth] 时生效）。
  ///
  /// 🔑 **它同时决定药丸宽度**：`宽 = 2 × (_iconLead + _iconSize + _iconGap) + labelW`
  ///    → 想更窄就调小它（代价：图标离边缘更近）。
  static const double _iconLead = 8;

  /// 上下内边距 —— 设计稿 `padding:7px 12px` 的纵向部分（两态共用，不参与居中推导）。
  static const double _padV = 7;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final fg = Color(t.accent.argb32);
    final n = count;
    final lw = labelMinWidth;

    // 🔑 传了 `labelMinWidth` → **左右内边距故意不等**，好让「文字」落在药丸正中
    //    （推导：`L == R`，而 L 含图标）。没传 → 设计稿的对称 12 + 自然宽。
    final leftPad = lw == null ? 12.0 : _iconLead;
    final rightPad = lw == null ? 12.0 : _iconLead + _iconSize + _iconGap;

    final labelStyle = TextStyle(
      fontFamily: CoFonts.uiSans,
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: fg,
    );

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
      // 设计稿 `.bm-entry{padding:7px 12px}` —— 仅**自然宽**时左右对称（见上面的推导）
      padding:
          EdgeInsets.only(left: leftPad, right: rightPad, top: _padV, bottom: _padV),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 设计稿 `<svg width="13" height="13">`（2px 描边）
          Icon(icon, size: _iconSize, color: fg),
          const SizedBox(width: _iconGap),
          if (lw == null)
            Text(label, style: labelStyle)
          else
            // 🔑 文字区**定宽 + 居中** —— 于是「全部」/「已到期」的中心**完全同位**，
            //    且该中心 = 药丸中心（由上面的 `leftPad`/`rightPad` 保证）。
            SizedBox(
              width: lw,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: labelStyle,
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
