// CoEvo · 「阅读」tab 的容器（两个平级视图：今日精选 ｜ 书库）
//
// # 为什么需要这一层（它解决的是「层级」问题）
//
// 🔴 **2026-10-04 白哥定案**（原话）：
// > 「书库与今日精选是**平级的页面**，入口不是一个下方的按钮而是与『今日精选』
// >  **title 平级**，你应该给我设计稿再做，而不是直接做」
//
// 上一版把入口做成了标题栏**下方**的一条淡色按钮 ⇒ 读起来像「标题的下属」，
// 且白占信息流一行（信息流页的垂直空间是稀缺资源 —— 兴趣筛选栏就是因此被移走的）。
//
// ⇒ 本容器负责**标题栏**：两个 23px 平级标题（`今日精选` / `书库`），
//    选中态 = `ink` 字色 + 3px 朱砂短线，未选中 = `ink3`；右侧动作**随段切换**。
//    内容区用 `IndexedStack` 在两段之间切换 —— **不新增路由、不做转场**
//    （平级切换是「同一屏换内容」，不是「进入另一个页面」）。
//
// 📄 设计稿（方案 A · 已定案）：`docs/design/book-library-entry-placement-2026-10-04.html`
//
// # 🔑 关键判据：为什么不是 push 一个新页面
//
// 项目已有判据：**「它是不是 tab 的内容」** ——
//   · 是 → 页内子视图（保留底部 tabbar）
//   · 否（覆盖全屏的沉浸态）→ 顶层路由
//
// 书库**是**「阅读」这个 tab 的内容（它就是「读的另一类材料」）⇒ 页内切换 ✅
// 这与「收藏清单」（`/home/bookmarks`，同为阅读 tab 的子视图）同类。
// 反例：阅读器 `/article/:id` 与翻卡 `/review/session` 是**覆盖全屏的沉浸态** ⇒ 顶层路由。
//
// # 为什么用 `IndexedStack` 而不是 `if (section == ...)`
//
// `if` 切换会把另一段**从树上摘掉** ⇒ State 被销毁：
//   · 信息流的滚动位置、已加载的分页丢失（切回来又从顶部开始）
//   · 书库列表重新查库（闪一下 loading）
// `IndexedStack` 两段**都留在树上**、只显示一个 ⇒ 切换是瞬时的、状态保留。
// ⚠️ 代价（如实记录）：两段在首帧**都会构建** ⇒ 启动时就会打开 `book.db`。
//    这是有意的取舍 —— 换来「切到书库即有内容」，且它不影响信息流渲染
//    （产品原则：「库可用性」不该成为「页面可见性」的开关，反向亦然）。
//
// # 🔴 标题文案来自 `reading_section.dart`（纯 Dart · 可断言）
//
// 「书库」这两个字是**白哥定的产品决定**（不用「我的书库」：4 字 23px 标题
// 与「今日精选」并排会挤满一行，右侧动作没有落脚处）。
// 放在零依赖文件里 ⇒ 能被 `scripts/ebook_verify/bin/verify_reading_tab.dart` 守住，
// 不会被后续迭代悄悄改回去。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/bookmark_provider.dart';
import '../services/ebook/book_import_flow.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/header_chip.dart';
import 'book_library_screen.dart';
import 'home_screen.dart';
import 'reading_section.dart';

/// 「阅读」tab：标题栏（双标题 + 右侧动作）+ 两段内容。
class ReadingTabScreen extends ConsumerStatefulWidget {
  const ReadingTabScreen({super.key});

  @override
  ConsumerState<ReadingTabScreen> createState() => _ReadingTabScreenState();
}

class _ReadingTabScreenState extends ConsumerState<ReadingTabScreen> {
  /// 当前段 —— 默认信息流（与旧行为一致：进 App 先看今日精选）。
  ReadingSection _section = ReadingSection.feed;

  void _select(ReadingSection s) {
    if (s == _section) return;
    setState(() => _section = s);
  }

  /// 触发导入 —— **本页有两处入口**（标题栏药丸、书库空态的「导入文件」按钮）。
  ///
  /// # 🔴 2026-10-05：本页**不再持有任何导入状态**
  ///
  /// 原设计：`_importing` 驱动「导入」药丸变成「导入中…」并禁用。
  /// 白哥真机反馈两点 ⇒ 改为**无忙碌态**：
  /// · 为容纳更长的「导入中」文案，药丸要传 `labelReserve` ——
  ///   而那个参数**本是为「文字居中」设计的**（复习页筛选药丸），它假定药丸右侧没有
  ///   其它元素 ⇒ 副作用是**左右内边距不对称**（左 8 / 右 27），与「收藏」并排不协调
  /// · 忙碌态还要同步到空态按钮 ⇒ 一个状态被两处 UI 读取，改一处忘一处
  ///
  /// ⇒ 防重入**移进 `runBookImportFlow` 内部**（它才是「是否正在导入」的所有者），
  ///   本页退化为**纯触发者**（无状态）。
  /// 📌 判据复用：**防重入放在「状态的唯一所有者」上** —— 只是所有者变了。
  Future<void> _import() => runBookImportFlow(context: context, ref: ref);

  /// 标题栏段落间距 —— 设计稿 `.hd-tabs{gap:16px}`。
  static const double _titleGap = 16;

  /// 下划线高度 —— 设计稿 `.ht.on::after{height:3px}`。
  static const double _underlineHeight = 3;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🔑 只取 `idsOrEmpty`：库没就绪时计数为 0、**不影响标题栏渲染**
    //    （同 home_screen 的判据：不用 `when`，不让「收藏可用性」成为渲染前置）。
    final bookmarkCount = ref.watch(bookmarkProvider).idsOrEmpty.length;

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理，这里只避让状态栏
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(t, bookmarkCount),

            // ── 两段内容（同时留在树上，切换瞬时）──
            Expanded(
              child: IndexedStack(
                index: _section.stackIndex,
                children: [
                  const HomeScreen(),
                  // ⚠️ `importing` 要传下去 —— 书库**空态**里那个「导入文件」按钮
                  //    也必须在导入中禁用（否则它成了一个可重复点、但点了没反应的入口）。
                  BookLibraryScreen(onImport: _import),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题栏：`今日精选 ｜ 书库` + 右侧动作。
  ///
  /// 版式照锚点设计稿的 `.feed-hd`：`padding: 2px 18px 14px`、`gap: 12px`。
  ///
  /// 🔴 **2026-10-05：标题由 `Flexible` 改 `Expanded`**（白哥真机反馈）
  /// > 「收藏按钮应该更靠右，其他页面的 title 按钮都是靠右的」
  ///
  /// **根因**：`Flexible` 只给「**内容宽**」—— 标题只占它自己那么宽，
  /// 剩余空间**没人占**，于是右侧元素紧跟在标题后面 ⇒ 停在标题右边、不贴屏幕右缘。
  /// `Expanded`（= `Flexible(fit: FlexFit.tight)`）让标题**占满剩余宽度**，
  /// 右缘元素自然被推到最右。
  ///
  /// 🔑 **对照（本项目其他两页本来就是对的）**：
  ///   · `review_screen.dart`  → `Expanded(Text('复习'))` → 药丸贴右
  ///   · `bookmark_list_screen` → `MainAxisAlignment.spaceBetween` → 动作贴右
  /// ⇒ 判据：**同一位置承担同类职责的元素，应有同一个落点**；
  ///   三页里两页对、一页错的，那页就是**离群值**。
  ///
  /// ⚠️ `FittedBox(scaleDown)` **保留在 `Expanded` 内部**（`alignment: centerLeft`）——
  ///    「小屏 + 系统大字体（本项目限到 1.3）不溢出」的兜底仍在，
  ///    只是它现在只作用于标题自身，不再影响右侧布局。
  Widget _header(CoEvoTokens t, int bookmarkCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 14),
      child: Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              // 🔑 缩放时**靠左**对齐 —— 标题始终从左边开始，不会因缩放而横移
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in ReadingSection.values) ...[
                    if (s != ReadingSection.values.first)
                      const SizedBox(width: _titleGap),
                    _titleTab(t, s),
                  ],
                ],
              ),
            ),
          ),
          // 设计稿 `.feed-hd{gap:12px}`
          const SizedBox(width: 12),
          _trailing(t, bookmarkCount),
        ],
      ),
    );
  }

  /// 一个**标题级** Tab（23px / w600 / 字距 -1.5%）——
  /// 它与另一个 tab 是**平级标题**，不是一个「按钮」。
  ///
  /// 结构用 `Stack`：下划线用 `Positioned(left:1, right:1)` 贴住**文字宽**。
  /// 🔑 为什么不用 `Column` + `CrossAxisAlignment.stretch`：
  ///    那样需要 `IntrinsicWidth` 才能把宽度收到文字宽；
  ///    `Stack` 的尺寸本就由非 `Positioned` 子元素（这里就是文字）决定 ——
  ///    同 `HeaderChip` 用 Stack 量参照文案宽度的做法。
  Widget _titleTab(CoEvoTokens t, ReadingSection s) {
    final on = s == _section;
    return GestureDetector(
      // `opaque`：整块文字区域都可点（含下方 8px 留白），不只是字形上
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(s),
      child: Stack(
        children: [
          Padding(
            // 给下划线留出位置（文字基线与短线下沿之间）
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

  /// 右侧动作 —— **随当前段切换**（设计稿：信息流是「收藏 N」，书库是「导入」）。
  ///
  /// 🔴 **2026-10-05：两段都用粘土药丸了**（白哥真机反馈）
  /// > 「书库界面的导入按钮应该也是一个一个粘土按钮，设计语言要统一」
  ///
  /// **改前**：`books` 分支是一段 `InkWell > Text('导入')` —— **零体积的纯文字**。
  /// 于是**同一行**出现了两种形态（收藏 = 凹陷药丸 / 导入 = 裸文字）。
  ///
  /// **改后**：用 `HeaderChip`（凹陷药丸）—— 与「收藏」**同一行、同一形态、同一处定义**。
  /// 🔑 依据 spec §〇 规则 1：「**有体积的只可能是可点的东西**」——
  ///    导入可点 ⇒ 可以有体积；而**凹陷**的物理语义正是「**可以按下去**」，与「导入」这个动作相合。
  ///
  /// ⚠️ **两段不会同时出现**（信息流段显示收藏、书库段显示导入）⇒ 无并排拥挤问题。
  ///
  /// # 🔴 「导入中」那一版**已撤销**（2026-10-05 白哥定）
  ///
  /// 曾经的做法：导入中把药丸换成 `HeaderChip(label: '导入中', labelReserve: '导入中',
  /// enabled: false)` —— 出发点（形状不变、标题栏不跳）是对的，但**副作用不可接受**：
  ///    · `labelReserve` 是**为「让文字居中」设计的**（复习页筛选药丸），
  ///      它**假定药丸右侧没有其它元素** ⇒ 借用它会导致**左右内边距不对称**
  ///      （左 8 / 右 27）⇒ 与「收藏」（走 `count` 分支，对称）并排**不协调**；
  ///    · 忙碌态还要同步给空态按钮 ⇒ 一个状态被两处 UI 读取，改一处忘一处。
  /// ⇒ 白哥定：**不要忙碌态**（防重入交给 `runBookImportFlow`），**顺手把加号也去掉**。
  /// 📌 判据：**「借用为 A 设计的参数」** —— 副作用会以「说不清哪里怪」的形式出现；
  ///    正解是**消除借用**，不是去调参数的副作用。
  Widget _trailing(CoEvoTokens t, int bookmarkCount) {
    switch (_section) {
      case ReadingSection.feed:
        // 「收藏 N」药丸（设计稿 `.bm-entry`）—— 实现在 `HeaderChip`（**唯一一处定义**）
        return HeaderChip(
          icon: Icons.bookmark_border,
          label: '收藏',
          count: bookmarkCount,
          onTap: () => context.push('/home/bookmarks'),
        );

      case ReadingSection.books:
        // 🔑 药丸形态与「收藏」**完全同源**（`HeaderChip`），只是文案/回调不同。
        //
        // 🔴 2026-10-05（白哥定）：**去掉图标、去掉忙碌态**。
        //    · 去图标：原来是 `Icons.add`（加号）—— 而「收藏」是「图标 + 文字 + 数字」，
        //      本按钮**没有数字** ⇒ 并排时看起来不协调（白哥原话）。
        //      去掉后只剩文字，与「收藏」的差异变成「有数字 / 无数字」这一条**语义差异**，
        //      而不是「多一个加号」这种**形态差异**。
        //    · 去忙碌态：不再传 `labelReserve`（它会让内边距不对称，见 `_import` 的文档）。
        //      ⇒ 无 `reserve` ⇒ 左右内边距对称 ⇒ 与「收藏」同一套版式。
        //    防重入改由 `runBookImportFlow` 内部负责（本页无状态）。
        return HeaderChip(label: '导入', onTap: _import);
    }
  }
}
