/// 「我的」页的**兴趣筛选分区** —— 可折叠，收起态**只占一行**。
///
/// # 名称变更（2026-10-03）：`InterestFilterBar` → `InterestFilterSection`
///
/// 🔑 **位置/语义变了，名字也要一起审**（本项目判据：「改名若改变了命名约定的含义，
///    位置也要一起审」—— 反过来同样成立）。
///    · `Bar` 暗示**横向条**（顶栏下方那种常驻条）—— 那是上一版在**信息流页顶部**的形态；
///    · 现在是「我的」页里的一个**设置分区** ⇒ `Section` 才名实相符。
///
/// # 🔴 两次真机反馈，两个不同的问题（都值得记）
///
/// | 版本 | 形态 | 白哥反馈 | 真问题 |
/// |---|---|---|---|
/// | v1 | 「我的」页 · **12 个胶囊全展开** | 「UI 设计不好」 | 12 个胶囊**常驻铺开**，把设置页撑乱 |
/// | v2 | **信息流页顶部** · 一行 chip + 浮层 | 「阅读界面**太拥挤**」 | 🔴 见下 |
/// | **v3** ⭐ | 「我的」页 · **收起成一行** + 就地展开 | — | — |
///
/// ## 为什么 v2 是错的（我上一轮的判断漏了一个维度）
///
/// 我上轮总结的判据是「**控件属于哪一屏**」（兴趣筛选是「看信息流的前置控制」
/// ⇒ 该放信息流页）。**方向对，但漏了「使用频率」这一维**：
///
/// ```
/// 搜索框   ：高频 + 小占用  ⇒ 放主界面（每天都点）
/// 兴趣筛选 ：低频（设一次长期不动）+ 大占用 ⇒ 放设置页
/// ```
///
/// 🔴 它是**低频**操作，却要在信息流页**常驻占一行** ⇒
///    **用一次的便利，换每天的拥挤** —— 不划算。信息流页的垂直空间是**稀缺资源**。
///
/// 📌 **修正后的判据（已写入规格 §10.3.2）**：
///    「前置控制放哪」= **使用频率 × 占用空间**，而不是「它是不是前置控制」。
///    · 高频 + 小占用 ⇒ 主界面（搜索框）
///    · 低频 + 任意占用 ⇒ 设置页（兴趣筛选）—— **且必须能收起来**
///    · 高频 + 大占用 ⇒ 主界面但**默认收起**（如筛选抽屉）
///
/// ## 而 v1 的真问题也不是「位置」（它位置本来就在「我的」页）
///
/// v1 的白哥反馈是「UI 设计不好」。真问题是 **12 个胶囊常驻全展开**：
/// 一个低频设置项占了**半屏**，把「我的」页的节奏撑散了。
/// ⇒ v3 保留 v1 的位置、修掉 v1 的形态：**默认收起成一行**。
///
/// # 形态
///
/// ```
/// 收起态（默认）：           展开态（点击标题行）：
/// ╭────────────────────────╮  ╭────────────────────────╮
/// │ 🎯 兴趣筛选      [全部 ▾]│  │ 🎯 兴趣筛选      [3 类 ▴]│
/// │    全部类别              │  │    News · Tech · Science │
/// ╰────────────────────────╯  │  ──────────────────────  │
///                              │  决定信息流显示哪些类别，  │
///                              │  不选 = 全部              │
///                              │  [News][Tech][Business]… │
///                              │                  [清除]   │
///                              ╰────────────────────────╯
/// ```
///
/// 🔑 **收起态仍能一眼扫出「现在选了啥」**（副标题 = 当前状态）——
///    否则用户得点开才知道自己筛了什么，那就是「藏信息」而不是「收纳」。
///
/// # 交互决定（都有理由）
///
/// · **整卡可点 = 展开/收起**：收起时点击区**很大**（好按）；展开时点空白也可收起
///   （常见交互，且**不误触** —— 展开区里的胶囊/按钮是子 widget，
///   会先在手势竞技场里消费点击，**不会冒泡到外层**）。
/// · **「再点标题收起」**（白哥 2026-10-03 定）⇒ 展开区**不放「完成」按钮**：
///   收起动作只有一处出口，不制造第二个。
/// · **但保留「清除」** —— 语义不同：**收起** = 藏起面板（勾选仍在）；
///   **清除** = 取消全部勾选（回到「全部」）。仅在有勾选时出现。
/// · **展开区里才有那句说明**（「决定信息流显示哪些类别，不选 = 全部」）：
///   收起态留给**状态**，说明只在需要选择时才出现 ⇒ 平时更清爽。
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

/// 「我的」页的兴趣筛选分区（可折叠 · 收起态只占一行）。
///
/// 🔑 **自包含**：自己 `ref.watch(interestProvider)` +
///    自己管展开态 ⇒ 调用方只需一行 `const InterestFilterSection()`。
class InterestFilterSection extends ConsumerStatefulWidget {
  const InterestFilterSection({super.key});

  @override
  ConsumerState<InterestFilterSection> createState() =>
      _InterestFilterSectionState();
}

class _InterestFilterSectionState extends ConsumerState<InterestFilterSection> {
  /// 是否展开（**默认收起** —— 这是本版存在的理由：低频项不该常驻铺开）。
  ///
  /// 🔑 纯 **UI 状态**：不持久化（重启回到收起 —— 收起态信息量更大，是合理默认）、
  ///    不进 provider（它不是「用户偏好」，只是「这一刻面板开着」）。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    // 🔑 `valueOrNull ?? none`（同 `interest_provider` 的降级判据）：
    //    prefs 未读完 / 读失败 ⇒ 按「全部」渲染 ——
    //    **不因为「偏好读不出来」而让这一行消失或空白**（本项目判据：
    //    易失败的依赖不放渲染前置链；且「静默消失」比「报错」更难被发现）。
    final sel = ref.watch(interestProvider).valueOrNull ?? InterestSelection.none;

    // 🔑 外层卡：与 `_navTile` **完全同一语汇**（Clay / 圆角 16 / padding 0）
    //    ⇒ 它在这页里读起来是「一个设置分区」，而不是外来的一块。
    return Clay(
      borderRadius: BorderRadius.circular(16),
      padding: EdgeInsets.zero,
      // 整卡可点 = 展开/收起（理由见文件头 §交互决定）
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(t, sel),
          // 🔑 `AnimatedSize` + 高度 0 的占位：展开区**就地向下长**，
          //    下面的分组自动下移。`alignment: topCenter` 让动画从顶部往下长。
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
      ),
    );
  }

  /// 标题行 —— 收起态就是**这一行**（图标 + 标题 + 状态 + 展开指示）。
  ///
  /// 内边距 / 字号 / 颜色**逐个对齐 `_navTile`**（15·13·15·13 / 14 w500 / 11.5 / ink3），
  /// 使它与「账号」「我的成就」等行**读起来是同一族**。
  Widget _header(CoEvoTokens t, InterestSelection sel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      child: Row(
        children: [
          // 图标槽：与 `_navTile` 同为「定宽 21 / 图标 17 / ink3」
          SizedBox(
            width: 21,
            child: Icon(Icons.track_changes_outlined,
                size: 17, color: Color(t.ink3.argb32)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '兴趣筛选',
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(t.ink.argb32),
                  ),
                ),
                const SizedBox(height: 2),
                // 🔑 副标题 = **当前状态**（不是说明文案）——
                //    收起态必须能一眼扫出「现在筛了什么」，否则是「藏信息」而非「收纳」。
                //    ⚠️ 单行 + 省略号：12 类全选时名字很长，**不能撑高这一行**
                //    （撑高就等于收起失败）。
                Text(
                  _summary(sel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 11.5,
                    color: Color(t.ink3.argb32),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 11),
          // 尾部：当前档位摘要 + 展开指示。
          // 🔑 用 `accent` 色 —— 与全站「可操作/激活」同一语汇（`HeaderChip` 也用 accent）。
          Text(
            sel.isAll ? '全部' : '${sel.count} 类',
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
          //    旋转是连续动效，与 `AnimatedSize` 同一节奏（都 180ms）。
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Icon(Icons.expand_more,
                size: 18, color: Color(t.ink3.argb32)),
          ),
        ],
      ),
    );
  }

  /// 副标题文案 —— **唯一的「当前选择 → 人话」转换点**。
  ///
  /// 抽成独立方法是为了让它**可被纯 Dart 断言覆盖**：
  /// 这条转换有个易错点 —— `kCategoryLabels` 是 `Map<String, String>`，
  /// 若某 key 在表里缺项，`map` 后会得到 `null` ⇒ 必须 `whereType<String>()` 过滤，
  /// 否则会渲染出字面量 `"null"`（**不报错，只是难看**，典型的静默失真）。
  String _summary(InterestSelection sel) {
    if (sel.isAll) return '全部类别（不筛选）';
    // `sel.keys` 已按字典序稳定排序（见 `InterestSelection.keys`），
    // ⇒ 同样的选择集合永远得到同样的文案（不随勾选顺序漂移）。
    final names = sel.keys
        .map((k) => kCategoryLabels[k])
        .whereType<String>() // 🔑 过滤缺项（见方法文档）
        .join(' · ');
    return names.isEmpty ? '全部类别（不筛选）' : names;
  }

  /// 展开后的选择区（说明 + 12 个胶囊 + 清除出口）。
  Widget _panel(CoEvoTokens t, InterestSelection sel) {
    return Padding(
      // 顶部 0：与标题行之间只隔它自带的 13 下边距 —— 避免出现「两道间距」。
      padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 说明只在展开时出现（收起态留给「状态」，见文件头 §交互决定）
          Text(
            '决定信息流显示哪些类别 · 不选 = 全部',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              height: 1.4,
              color: Color(t.ink3.argb32),
            ),
          ),
          const SizedBox(height: CoSpacing.sm),
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
                  onTap: () => ref.read(interestProvider.notifier).toggle(e.key),
                ),
            ],
          ),
          if (!sel.isAll) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => ref.read(interestProvider.notifier).clear(),
                child: const Text('清除'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 单个类别胶囊。
  ///
  /// 🔑 形态**与 v1（「我的」页初版）逐字相同** —— 胶囊本身**从未有问题**，
  ///    两轮反馈针对的都是「位置」与「是否常驻展开」。**已定稿的部分不重做。**
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
      // `state: selected` 会**自动**取 `accent` 填充 + `accentInk` 压字 + `accentOut` 外阴影
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
