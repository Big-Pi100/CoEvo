/// 标题栏上的**药丸** —— 全应用**唯一**一处定义。
///
/// # 消费者（2026-09-28 起两个）
/// | 位置 | 图标 | 计数 | 宽度 |
/// |---|---|---|---|
/// | 信息流标题栏 | 书签 | **有**（`count`） | 自然宽（设计稿原样） |
/// | 复习页标题栏 | **无** | 无 | 定宽（`labelReserve: '已到期'` → **引擎实测**） |
///
/// 🔑 两处的**结构不同**是有意的（见 §🆕 ③：复习页去掉了图标），但**形态（凹陷/凸起）、
///    圆角、字号、配色完全共用** —— 这正是「抽公共组件」要保证的那部分。
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
/// # 🆕 宽度参照文案 + **文字真居中**（[labelReserve]，2026-09-28 修正四轮）
/// 白哥真机反馈依次是：「**药丸太宽**」→「**内容看起来不居中**」→
/// 「**还不如原来的**」→「**『已到期』变成两行了**」。
///
/// ## ① 为什么必须有一处「定宽」
/// 复习页这个药丸的文案会在「全部」(2 字) / 「已到期」(3 字) 之间切换。
/// 不定宽 → ① 药丸宽跳变 ~11.5px、② 文字中心横移 ~5.75px → 整条标题栏跟着抖。
///
/// ## ② 「让文字落在正中央」的推导（仍然有效，别丢）
/// 设文字区起点距左 = `L`、文字区宽 = `labelW`、右内边距 = `R`：
/// ```
/// 药丸宽 = L + labelW + R ；文字区中心 = L + labelW/2 ；药丸中心 = 药丸宽/2
/// 令两者相等 → L = R
/// ```
/// 🔑 **「左右到文字区的距离相等」⇔「文字落在药丸正中」。**
///    `L` 里含图标（`_iconLead + _iconSize + _iconGap`）→ **`R` 必须等于 `L`**。
///
/// ## ③ 走错的一步：用右侧留白换居中（已回退）
/// 白哥最先看到的是「药丸太宽」—— 把「≈ 收藏药丸的整宽 84」传给了作用在
/// `padding` **内部**的宽度 → 实际整宽 = 84 + 24 = **108**；
/// 以及「文字偏右」（整块居中时被前置图标推右 `(13+6)/2 = 9.5px`）。
/// 按 ② 反推出「右侧留出与图标等量的空白」→ 文字**确实**居中了，
/// 但白哥看完实际观感：「**更不对了，还不如原来的**」——
/// 右内边距 27px 的**纯空白**比「偏右 9.5px」更失衡。
///
/// 🔑 一条结论框定了可选范围：
/// ```
/// 药丸内容 = [图标 13][间距 6][文字]
/// 「图标 + 文字」整块居中 → 文字必然偏右 (13 + 6) / 2 = 9.5px   ← 数学必然
/// ```
/// 要消掉这 9.5px 只有两条路：「右侧留等量空白」（❌ 观感更差）或
/// 「**不要图标**」（✅ 文字正中且左右对称）→ 白哥选后者。
/// 去图标后 `iconBlock = 0`，左右内边距**自动退化为对称**（公式本身已统一两种情况）。
///
/// ## 🔴 ④ 最终修正：宽度**不再写死像素**（2026-09-28 22:2x 白哥真机）
/// 白哥：「**宽度应该按「已到期」三字，现在显示「已到期」时变成两行了**」。
///
/// **根因：`labelMinWidth = 36` 是「3 字 × 11.5px = 34.5」的*估算*，而真机更宽。**
/// ```dart
/// SizedBox(width: 36, child: Text('已到期'))   // 把文字硬塞进 36 → 塞不下就折行
/// ```
/// 估算为什么**迟早**失手：中文字形的 advance **并非恰好 1em** ——
/// 字体 fallback、`w600` 的合成加粗、系统「文字大小」缩放，都会让它更宽。
///
/// 🔑 **修法：把「写死的像素」换成「让引擎实测的参照文案」。**
///    调用方传 `labelReserve: '已到期'`（＝**最长的那个** label），
///    组件用一个**隐形占位**把它量出来：
/// ```dart
/// Stack(                                // Stack 取最大子元素 → 宽 = max(占位, 实际)
///   alignment: Alignment.center,
///   children: [
///     ExcludeSemantics(child: Opacity(          // 只参与布局：不绘制、不进语义树
///       opacity: 0, child: Text(reserve, style: labelStyle))),
///     Text(label, maxLines: 1, softWrap: false),  // 真正显示的文案
///   ],
/// )
/// ```
/// 于是三件事同时成立，且**不需要任何像素常量**：
/// | 想要 | 由什么保证 |
/// |---|---|
/// | 两态同宽（不抖） | 占位文案恒定 |
/// | 文字落在药丸正中 | `L == R`（② 的推导） |
/// | **永不折行** | 宽度是**实测**值 + `maxLines: 1` |
///
/// 🔑🔑 **判据（本次的通用教训）：凡由「字号 × 字数」反推出来的可用宽度，
///    迟早会在真机上不够。能用「让引擎实测另一个字符串」解决的，不要写死像素。**
///
/// 📊 五方案完整对比（含中心线标注：红虚线 = 药丸中心 / 蓝点线 = 文字中心）
/// 　→ `docs/design/filter-chip-options-2026-09-28.html`
/// ⚠️ 该图是「写死像素」时期画的，**宽度口径以本文件 §🆕 ④ 为准**。
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
    required this.label,
    required this.onTap,
    this.icon,
    this.count,
    this.active = false,
    this.labelReserve,
  }) : assert(
          labelReserve == null || count == null,
          'labelReserve 与 count 不能同时用：文字居中的推导（L == R）'
          '假设文字区右侧没有其它元素；带计数时请走自然宽（不传 labelReserve）。',
        );

  /// 图标（**可选** —— 见类文档 §🆕 ③）。
  ///
  /// · 传（信息流「收藏 N」）＝ 设计稿 `.bm-entry` 原样：图标 + 文字 + 计数。
  /// · 不传（复习页「全部 / 已到期」）＝ 纯文字药丸。
  ///
  /// 🔑 **可空是有意的**（2026-09-28 21:3x 白哥定）。两个理由：
  /// ① 「全部 / 已到期」是**筛选开关**，文字已说清状态；漏斗图标（`filter_alt`）
  ///    不提供额外信息。
  /// ② 它正是「**文字必然偏右 9.5px**」的根源（推导见类文档 §🆕 ③）——
  ///    去掉图标是**唯一**能让文字既不偏、又不用右侧留一大块空白的办法。
  final IconData? icon;

  /// 文案（「收藏」/「全部」/「已到期」）。
  final String label;

  /// 计数（设计稿 `.bm-entry .n`）。
  ///
  /// 🔑 **可选**：不是所有药丸都要计数 —— 复习页的筛选按钮只表达「当前在看哪一档」，
  ///    硬塞一个数字反而会让用户以为那是「已到期的数量」。
  ///    传 `null` = 不渲染计数段（含它前面那个 `gap`）。
  /// ⚠️ 与 [labelReserve] **互斥**（见构造函数的 `assert`）。
  final int? count;

  final VoidCallback onTap;

  /// **激活态**（凸起）—— 默认 `false` = 凹陷（与既有调用处行为一致）。
  ///
  /// 语义见类文档：`true` = 「**它正处于生效状态**」（如「已到期」筛选已开），
  /// 只改**凸凹**、**不改填充色**（避免与 `_SortChip` 撞脸）。
  final bool active;

  /// **宽度参照文案**（可选）—— 用于「文案长度会变」的药丸。
  ///
  /// 传 `null`（默认）= 自然宽 + 设计稿的对称内边距（信息流「收藏 N」走这条）。
  ///
  /// 🔑 **传「最长的那个 label」**（复习页传 `'已到期'`），于是同时得到三件事：
  /// 1. **两态同宽**：`label` 在「全部」(2 字) / 「已到期」(3 字) 间切换时，
  ///    自然宽会跳变 ~11.5px（一个字宽）→ 整条标题栏跟着抖。
  /// 2. **文字位置不横移**：宽度恒定 + 居中 → 两个 label 的中心**完全同位**。
  /// 3. **永不折行**：宽度由**引擎实测**（不是「字号 × 字数」的估算）→
  ///    换字体 / 系统「文字大小」缩放都不会把「已到期」挤成两行。
  ///
  /// ⚠️ **必须是「最长」的那个** —— 传短了，长 label 会被 `softWrap: false` 溢出
  ///    （不会折行，但也放不下）。
  final String? labelReserve;

  /// 设计稿 `.bm-entry{border-radius:13px}` —— 写死，不走 token。
  static final BorderRadius _radius = BorderRadius.circular(13);

  /// 设计稿 `<svg width="13" height="13">`（2px 描边）。
  static const double _iconSize = 13;

  /// 设计稿 `.bm-entry{gap:6px}`。
  static const double _iconGap = 6;

  /// **横向内边距的基准值** —— 设计稿 `.bm-entry{padding:7px 12px}` 的横向部分。
  ///
  /// 用于：① 自然宽时（左右都是它）；② **无图标 + 定宽**时（左右都是它 → 对称）。
  static const double _padH = 12;

  /// 图标**距药丸左边缘**的留白（仅「**有图标** + 传了 [labelReserve]」时生效）。
  ///
  /// 🔑 **它同时决定药丸宽度**：`宽 = 2 × (_iconLead + _iconSize + _iconGap) + labelW`
  ///    → 想更窄就调小它（代价：图标离边缘更近）。
  ///
  /// ⚠️ **无图标时不生效** —— 那时刻意用 [_padH]（12），使左右内边距**对称**；
  ///    这正是「文字居中、又不显空」的来源（复习页走这条）。
  ///
  /// 📌 **当前无消费者**（复习页已去图标、信息流不传 [labelReserve]）——
  ///    保留是为了「有图标 + 定宽」时上面那条公式仍然成立，删掉它公式就残缺了。
  static const double _iconLead = 8;

  /// 上下内边距 —— 设计稿 `padding:7px 12px` 的纵向部分（两态共用，不参与居中推导）。
  static const double _padV = 7;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final fg = Color(t.accent.argb32);
    final n = count;
    final reserve = labelReserve;

    // 🔑 传了 `labelReserve` → **左右内边距不一定相等**，好让「文字」落在药丸正中。
    //    统一条件：**右内边距 = 左内边距 + 图标块宽**（`L == R` 的推导结论）。
    //    · 有图标 → 右内边距 = 左 + (13 + 6)  （文字仍居中，但图标会显得靠左）
    //    · 无图标 → 图标块宽 = 0 → **退化为对称内边距**（无需特判，公式自动成立）
    final hasIcon = icon != null;
    final iconBlock = hasIcon ? (_iconSize + _iconGap) : 0.0;
    final leftPad = reserve == null ? _padH : (hasIcon ? _iconLead : _padH);
    final rightPad = reserve == null ? _padH : leftPad + iconBlock;

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
          // 设计稿 `<svg width="13" height="13">`（2px 描边）。
          // ⚠️ 写成 `if (icon != null)`（而不是 `if (hasIcon)`）——
          //    只有前者能让 Dart 对 `icon` 做**类型提升**，否则要写 `icon!`。
          if (icon != null) ...[
            Icon(icon, size: _iconSize, color: fg),
            // 设计稿 `.bm-entry{gap:6px}`
            const SizedBox(width: _iconGap),
          ],
          if (reserve == null)
            Text(label, style: labelStyle)
          else
            // 🔑 宽度**由引擎实测**（隐形占位 = 参照文案）——
            //    不是「字号 × 字数」的估算，那正是 `labelMinWidth = 36` 折行的根因
            //    （见类文档 §🆕 ④）。
            //    `Stack` 的尺寸取「最大的非 positioned 子元素」→ 宽 = max(占位, 实际)；
            //    占位只参与布局：**不绘制**（`Opacity(0)`）、**不进语义树**
            //    （`ExcludeSemantics` → 读屏不会把参照文案念第二遍）。
            Stack(
              alignment: Alignment.center,
              children: [
                ExcludeSemantics(
                  child: Opacity(
                    opacity: 0,
                    child: Text(
                      reserve,
                      style: labelStyle,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
                Text(
                  label,
                  style: labelStyle,
                  // 🔑 兜底：即便参照文案给短了，也只会**溢出**而**不会折成两行**
                  maxLines: 1,
                  softWrap: false,
                ),
              ],
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
