/// 复习 —— **单一列表页**（导航第二个 tab）。
///
/// # 🔴 这一页是什么：**生词本 ≡ 复习页**
///
/// 白哥原话（`ui-ux-refactor-assessment-2026-09-25.md` §6.2）：
/// > 「我认为**生词本就是复习管理**，其实**复习页面只要一个就行了**，
/// >   卡片按 FSRS 管理状态和排序，同时支持搜索和按时序、字母排序，
/// >   默认是 FSRS 排序，这样如何，**就不要移入移出了**」
///
/// → 所以**没有**「生词本列表」与「复习队列」两个视图，也**没有**在两者之间搬运的动作。
///   「到期 / 未到期」只是**同一列表里的一项属性**（决定排序位置与分组）。
///
/// # ⚠️ 与旧实现的关系：整体替换
/// 旧 `review_screen.dart`（1,529 行）是 **K12 遗留**：读**后端 `plans` 接口**
/// （`planProvider` / `DueCard` / `ChatClient`），做的是「AI 出题 → 判分」，
/// 与本地生词表**毫无关系** —— 这正是「查词后进复习 tab 什么也看不到」的原因
/// （2026-09-28 白哥实机发现）。
///
/// 本页替代它：数据源全部来自**端侧 `user.db`**（`card_review_state` + `user_word`），
/// **不依赖登录态、不联网** —— 符合产品原则「除生词表上限外不验证登录状态」。
///
/// # 规格依据（逐项）
/// | 项 | 出处 |
/// |---|---|
/// | 单一列表 · 无移入移出 | §6.2 |
/// | 三档排序（记忆曲线默认 / 最近 / A–Z） | §6.2 |
/// | 按单词搜索 | §6.2 |
/// | 分组「今天该复习 / 之后」+ 顶部「N 个今天该看」 | `review_list_query.dart` 类注释 |
/// | 点击 → 翻卡复习 | §293 |
/// | 「暂停」= 离开视野（不是移出） | §6.2.1 |
///
/// # 🔴 本页**第一步只做列表**（白哥 2026-09-28 定「分两步，先列表后卡片」）
/// 所以：
/// · 列表行**不给点击暗示**（无 `onTap`、无 `›`）—— 卡片（四段结构 + 四键评分）
///   属第二步。**刻意不做「点了没反应的死入口」**（3.22 的教训：
///   「静默无效的操作」比「禁用 / 尚未提供」更糟）。
/// · 等第二步接上卡片后，行才获得 `onTap` + `›`。
///
/// ⚠️ 卡片形态的权威锚点是 `docs/design/visual-word-card-target-2026-09-26.html`
///   （四段：① 词根词缀 ② 词源故事 ③ 释义 ④ 语境原句；四键各标**下次时间**）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/review_list_provider.dart';
import '../providers/review_session_provider.dart';
import '../providers/user_db_provider.dart';
import '../providers/user_word_provider.dart';
import '../services/highlight_repository.dart';
import '../services/review_list_query.dart';
import '../services/review_pause.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/theme_builder.dart';
import '../theme/tokens_ext.dart';
import '../widgets/clay_button.dart';
import '../widgets/co_dialog.dart';
import '../widgets/twemoji.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  /// 列表的排序 / 搜索 / 筛选 —— **单一状态源**。
  ///
  /// 🔑 筛选（`dueOnly`）放在这里而不是单独的 `bool` 字段：
  ///    它和排序一样是「查询参数」，两份状态会出现「界面显示已筛、查询没筛」的错位。
  ReviewListArgs _args = const ReviewListArgs();

  // 🆕 2026-10-08：筛选 chip 的两态参照文案常量 **已随 chip 一起搬到
  //    `ReviewTabScreen`**（它现在渲染在容器标题行 —— 见 `reviewDueOnlyProvider`）。
  //    📌 判据：常量跟着**唯一的消费者**走，别留在原地当「孤儿常量」。

  final _searchController = TextEditingController();

  /// 搜索输入框的焦点 —— 展开时自动聚焦（否则用户还要再点一下输入框）。
  final _searchFocus = FocusNode();

  /// 搜索是否**已展开**（默认收起为排序行最右侧一个放大镜图标）。
  ///
  /// 🔑 白哥 2026-09-28：「复习页的搜索单词**缩小成图标，点击才展开**」。
  ///    理由：搜索是**低频**动作，不该常驻占一行 —— 常驻会把「今天该复习什么」
  ///    这个主要信息挤下去。
  ///
  /// ⚠️ 位置后来调整过一次（同一天）：从标题栏**最左**移到**排序行最右**
  ///    （白哥：「应该放到『记忆曲线、最近、A-Z』这个排序按钮的同一行最右侧」）。
  ///    🔑 展开态也**跟着留在这一行**（排序 chip 让位）——
  ///       否则展开会把输入框放回标题栏，两态分处两行、列表会整体位移。
  ///
  /// 🔴 **收起时一并清空搜索词**（见 [_collapseSearch]）——
  ///    若保留搜索词，界面收起后看不出「列表正被筛着」→ 用户会以为**词丢了**。
  ///    这是「界面状态与数据状态必须一致」的直接要求。
  bool _searchExpanded = false;

  /// 搜索防抖 —— 本地查库虽快，但连续按键会连打多次查询。
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _args = _args.copyWith(search: v.trim()));
    });
  }

  void _expandSearch() {
    setState(() => _searchExpanded = true);
    // 输入框在**这一帧之后**才挂上去 → 必须等下一帧再请求焦点
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _collapseSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      _searchExpanded = false;
      // 🔴 与收起同步清空筛选条件（见 `_searchExpanded` 的说明：不能只收界面不收数据）
      _args = _args.copyWith(search: '');
    });
  }

  /// 暂停一个词（**不是「移出」** —— 见 `UserWordRepository.pause` 的说明）。
  ///
  /// 🔴 失败时**不改界面状态**：不能因为写库失败就把这一行从列表里抹掉 ——
  /// 那会让用户以为「暂停成功了」，下次打开它又回来。
  Future<void> _pause(ReviewListItem item) async {
    // ① 🆕 2026-10-08：**二次确认**（白哥真机反馈「很容易误点」）。
    //
    // 🔑 必须排在本函数的**最前**（先于取 `messenger` / `revision`）：
    //    那两个引用是「在任何 `await` 之前先拿到」的兜底（见下），
    //    而确认框**本身就是一次 await** ⇒ 它只能最先做。
    //    确认之后的 `!mounted` 检查同样必要 —— 弹窗期间页面可能已销毁。
    //
    // ⚠️ `t` 要**在这里自己取**：它是 `build` 的局部量，不在本方法作用域内
    //    （取 token 不涉及 await ⇒ 放在这里安全）。
    final t = CoEvoTokensExt.of(context);
    final confirmed = await CoDialog.show<bool>(
      context,
      builder: (dialogCtx) => CoDialog(
        // ⚠️ 标题**不带词**：划线卡（`hl:<uuid>`）没有可读的 `spelling`，
        //    分两套标题会让「同一件事两处口径」（同 `pauseConfirmBody` 的取舍）。
        title: '暂停复习？',
        child: Tw(
          pauseConfirmBody(wordId: item.wordId, spelling: item.spelling),
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 14.5,
            height: 1.7,
            color: Color(t.ink2.argb32),
          ),
        ),
        actions: [
          // 🔑 顺序按 iOS 惯例：次要在左、主要（确定）在右。
          //    「暂停」用 primary 而不是 destructive 色 —— 它**可恢复**
          //    （同一判据：`highlights_screen` 里「删除」才用弱化色）。
          ClayButton(
            label: '取消',
            variant: ClayButtonVariant.secondary,
            expanded: true,
            onTap: () => Navigator.of(dialogCtx).pop(false),
          ),
          ClayButton(
            label: '暂停',
            expanded: true,
            onTap: () => Navigator.of(dialogCtx).pop(true),
          ),
        ],
      ),
    );
    // 点遮罩 / 返回键关闭 ⇒ `null` ⇒ 与「取消」同义（什么都不做）
    if (confirmed != true) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    // 🔑 **在任何 `await` 之前**取到 notifier 引用（同另外两处写入端）：
    //    `await repo.pause(...)` 期间页面可能被销毁 → `ref` 失效。
    final revision = ref.read(userDbRevisionProvider.notifier);
    try {
      // 🔴 **两种卡的「暂停」落在两张不同的表上**（详见 `services/review_pause.dart`
      //    的文件头）：生词 → `user_word.deleted` · 划线（`hl:<uuid>`）→ `highlight.paused`。
      //    🔴 2026-10-08 之前**只写了生词那一支** ⇒ 划线卡点暂停时
      //    `UPDATE user_word … WHERE word_id = 'hl:…'` 影响 0 行 ⇒ 仓储返回 false
      //    ⇒ 下面 `if (!changed) return;` ⇒ **静默、连提示都没有**（白哥真机报的就是它）。
      //    ⚠️ 分派判据**不在本页** —— 在 `review_pause.dart`（纯 Dart，可被脚本验）。
      final db = await ref.read(userDbProvider.future);
      final changed = await pauseReviewCard(
        wordId: item.wordId,
        pauseWord: (id) async =>
            (await ref.read(userWordProvider.future)).pause(id),
        pauseHighlight: (id) => HighlightRepository(db).pause(id),
      );

      // `false` = 本来就已经是暂停状态（本次无动作）→ 不刷界面、不提示
      if (!changed) return;

      // 🔑 只为**真的改了库**才 bump（`changed == false` 时已提前 return）。
      //    以前这里要手工点名两个 provider（`reviewListProvider` +
      //    `reviewDueCountProvider`），少点一个就会出现「列表少了一条但
      //    顶部计数没变」；现在写端不必知道有哪些读端 ——
      //    读端自己 watch 修订号（见 `user_db_provider.dart` 的 `UserDbRevision`）。
      revision.bump();

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          // 🔴 文案**按卡片类型分两套**：划线卡没有「再次查词」这个动作，
          //    沿用生词那句就是**说谎**（用户会照做然后发现没用）。
          //    放在 `review_pause.dart` 与分派判据同一处 ⇒ 不会两处漂。
          content: Text(pausedMessage(
            wordId: item.wordId,
            spelling: item.spelling,
          )),
          duration: const Duration(seconds: 2),
        ));
    } catch (e, st) {
      debugPrint('[review] 暂停失败 wordId=${item.wordId}：$e\n$st');
    }
  }

  /// 进入**全屏翻卡**（顶层路由 `/review/session`）。
  ///
  /// 🔴 顺序不能反：**先把队列写进 provider，再 push**。
  ///    翻卡页 `build` 时就 `watch` 这个 provider —— 若先 push 后写，
  ///    它的**首帧会拿到空队列**（表现为「刚进去就显示 1 / 0」或直接空白）。
  ///
  /// 🔑 为什么是顶层路由而不是页内状态：见 `review_session_screen` 的类文档
  ///    （页内状态会继承所在页面的布局约束 → 四键被 tabbar 遮挡）。
  void _openSession(List<ReviewRow> rows, int index) {
    // 防御：`rows.indexOf(r)` 理论上不会返回 -1，但真出现时
    // push 一个「第 -1 张」的会话会直接崩在页面上 → 宁可什么都不做
    if (index < 0 || index >= rows.length) return;
    ref.read(reviewSessionProvider.notifier).start(rows, index);
    context.push('/review/session');
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🔑 `dueOnly` 从 provider 取（它的 chip 在**容器标题行**，不在本页 ——
    //    见 `reviewDueOnlyProvider` 的说明）；其余字段（搜索 / 排序）仍来自本页 `_args`。
    final dueOnly = ref.watch(reviewDueOnlyProvider);
    final list = ref.watch(reviewListProvider(_args.copyWith(dueOnly: dueOnly)));
    final dueCount = ref.watch(reviewDueCountProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 底部交给自绘粘土 tabbar（`app.dart` 的 `_ClayTabBar`）处理
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(t, dueCount),
            const SizedBox(height: 12),
            _sortBar(t),
            const SizedBox(height: 14),
            Expanded(
              child: list.when(
                // 首次加载 → **什么都不画**（画空状态会在有词时先闪一下「还没有生词」，是谎报）
                loading: () => const SizedBox.shrink(),
                // 读失败 → 给**准确**的话，不冒充「还没有生词」
                error: (e, st) => const _Unavailable(),
                data: (rows) => rows.isEmpty
                    ? _EmptyState(filtered: _isFiltering(dueOnly))
                    : _list(rows),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前是否处于「筛选 / 搜索」状态 —— 决定空状态该说什么。
  ///
  /// 🔑 两种空状态**必须分开**：
  /// · 真的没有词 → 教用户「词从哪来」
  /// · 有词但被筛掉了 → 告诉用户「换个条件」
  /// 混用会让一个搜不到词的用户以为自己的生词没了。
  /// 是否处于「筛选/搜索」态（决定空态文案）。
  ///
  /// ⚠️ 是**方法**不是 getter：`dueOnly` 现在来自 provider，
  ///    而 getter 拿不到 `ref`（调用处把值传进来）。
  bool _isFiltering(bool dueOnly) => _args.search.isNotEmpty || dueOnly;

  // ────────────────────────────────────────────────────────────
  // 标题栏（含搜索的两种状态）
  // ────────────────────────────────────────────────────────────
  Widget _header(CoEvoTokens t, int? dueCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 🆕 2026-10-08：「全部 / 已到期」筛选 chip **已上提到容器标题行**
          //    （`ReviewTabScreen`）—— 与「复习 ｜ 笔记」两个标题**同一行**。
          //    🔴 之前的形态是「页面里独占一行」⇒ 视觉上落在容器标题行的**下一行**，
          //       看起来像标题与筛选分家了（白哥真机反馈）。
          //    📌 状态在 `reviewDueOnlyProvider`（控件在谁手里，状态就在谁手里）。


          // 副标题只在**收起态**显示 —— 展开搜索时它让位于输入框（那才是当下焦点）
          if (!_searchExpanded) ...[
            const SizedBox(height: 6),
            Text(
              // 计数未就绪时**不显示 0** —— 那可能是谎报（库还没读出来）
              dueCount == null
                  ? '你的生词会按记忆曲线安排在这里。'
                  : dueCount == 0
                      ? '今天没有要复习的，随便翻翻吧。'
                      : '今天有 $dueCount 个该看',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12,
                height: 1.6,
                color: Color(dueCount != null && dueCount > 0
                    ? t.accent.argb32
                    : t.ink3.argb32),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 搜索输入框（仅展开态使用）。
  Widget _searchField(CoEvoTokens t) {
    return Clay(
      // 凹陷 = 「可以输入的地方」（粘土语汇里 `pressed` 就是「可交互的容器」）
      state: ClayState.pressed,
      fill: t.sunken,
      borderRadius: BorderRadius.circular(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: Color(t.ink3.argb32)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 14,
                color: Color(t.ink.argb32),
              ),
              // 🔴 必须走 `borderlessInputDecoration` —— **不能**只写
              //    `border: InputBorder.none`：theme 全局设了 `focusedBorder`
              //    （朱砂 1.6px），只覆盖 `border` 时聚焦仍会冒出红色线框。
              //    本页展开搜索会**自动聚焦**（见 `_searchExpanded` 的注释）→ 必现。
              //    根因与判据 → `theme_builder.dart` 的 `borderlessInputDecoration`
              decoration: borderlessInputDecoration(
                hintText: '搜索单词',
                hintStyle: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 14,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
          ),
          // ✕ = **只清空输入**（退出搜索走右侧「取消」）—— 两个出口语义分明
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                _debounce?.cancel();
                setState(() => _args = _args.copyWith(search: ''));
              },
              child: Icon(Icons.close, size: 16, color: Color(t.ink3.argb32)),
            ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────
  // 三档排序 + 搜索入口（同一行）
  // ────────────────────────────────────────────────────────────
  //
  // 🔴 搜索入口的位置（白哥 2026-09-28 定）：**这一行的最右侧**。
  //    此前它在标题栏最左侧。移过来的理由：它属于「对列表的操纵」，
  //    与排序 / 筛选是**同一类动作** → 放在同一区域，视线不必来回跳。
  //
  // 🔑 两态共用**同一行**（展开时排序 chip 让位给输入框）——
  //    这样展开/收起时下方列表**不会整体位移**。若给输入框另起一行，
  //    列表会被推下去，是廉价但明显的抖。
  Widget _sortBar(CoEvoTokens t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          if (_searchExpanded) ...[
            Expanded(child: _searchField(t)),
            const SizedBox(width: 6),
            _cancelSearch(t),
          ] else ...[
            for (final s in ReviewSort.values) ...[
              if (s != ReviewSort.values.first) const SizedBox(width: 8),
              _SortChip(
                label: s.label,
                selected: _args.sort == s,
                onTap: () => setState(() => _args = _args.copyWith(sort: s)),
              ),
            ],
            // 🔴 用 `Spacer` 把它推到行尾 —— 排序 chip 的宽度随文案变化，
            //    写死一个 `SizedBox` 会在换字号/换语种时错位。
            const Spacer(),
            const SizedBox(width: 8),
            _SearchIconButton(onTap: _expandSearch),
          ],
        ],
      ),
    );
  }

  /// 「取消」而**不是**一个 ✕ 图标：清空输入（✕）与退出搜索（取消）是**两件事**，
  /// 两个都要有出口 —— ✕ 语义含糊（用户不知道是清空还是退出）。
  Widget _cancelSearch(CoEvoTokens t) {
    return InkWell(
      onTap: _collapseSearch,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          '取消',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(t.accent.argb32),
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────
  // 列表
  // ────────────────────────────────────────────────────────────
  Widget _list(List<ReviewRow> rows) {
    final now = DateTime.now();

    // 🔑 分组仍走**数据层**的静态方法（与 `dueCount` 同一判据）——
    //    在 UI 里重写一遍「是否到期」会让「顶部计数」与「分组标题」打架。
    //
    // ⚠️ 但 `group()` 处理的是 `ReviewListItem`，而列表项现在携带**释义**
    //    （`ReviewRow`）→ 用 `wordId` 把它映射回来，**不重新构造**。
    //    这样「分组判据」只有一处定义，释义也不丢。
    final g = ReviewListQuery.group(rows.map((e) => e.item).toList(), now);
    final byId = {for (final r in rows) r.item.wordId: r};
    final dueRows = [for (final i in g.due) byId[i.wordId]!];
    final laterRows = [for (final i in g.later) byId[i.wordId]!];

    final out = <Widget>[];
    if (dueRows.isNotEmpty) {
      out.add(_GroupHeader(
        label: '今天该复习',
        count: dueRows.length,
        accent: true,
      ));
      for (final r in dueRows) {
        out.add(_WordRow(
          row: r,
          now: now,
          onPause: () => _pause(r.item),
          onOpen: () => _openSession(rows, rows.indexOf(r)),
        ));
      }
    }
    if (laterRows.isNotEmpty) {
      out.add(_GroupHeader(
          label: '之后', count: laterRows.length, accent: false));
      for (final r in laterRows) {
        out.add(_WordRow(
          row: r,
          now: now,
          onPause: () => _pause(r.item),
          onOpen: () => _openSession(rows, rows.indexOf(r)),
        ));
      }
    }

    return ListView.separated(
      // 底部留出 tabbar 高度 —— `_ShellScaffold` 开了 `extendBody: true`
      padding: const EdgeInsets.fromLTRB(18, 0, 18, CoSpacing.tabBarClearance),
      itemCount: out.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => out[i],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 子组件
// ════════════════════════════════════════════════════════════════

/// 搜索图标 —— 搜索的**唯一入口**（默认收起态）。
///
/// 🔴 位置（白哥 2026-09-28 定）：**排序行的最右侧**（此前在标题栏最左侧）。
///    理由：它属于「对列表的操纵」，与三档排序 / 筛选是**同一类动作**
///    → 放在同一区域，视线不必在页面上下两处来回跳。
///
/// 🔑 形态与 `HeaderChip`（收藏入口 / 筛选药丸）**同族**：
///    **粘土凹陷**（`Clay(pressed)` + `sunken` 底）—— 凹陷 = 「可以按下去」。
///    ⚠️ 但圆角用 10 而非 13：它是**方形图标按钮**（正方形、无文字），
///    与细长药丸不是同一形状（同 `BookmarkButton` 的 10）。
///
/// 🔑 字色用 `ink2` 而非 `ink3`：它是**可点元素**，必须可辨认。
///    （`ink3` 在三种底色上对比度都 < 4.5 —— 见 `_ClayTabBar` 的实测表。）
class _SearchIconButton extends StatelessWidget {
  const _SearchIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Clay(
      state: ClayState.pressed,
      fill: t.sunken,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      padding: const EdgeInsets.all(7),
      child: Icon(Icons.search, size: 16, color: Color(t.ink2.argb32)),
    );
  }
}


/// 三档排序的一个档位。
class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    if (!selected) {
      // 未选中 = 平坦（同 `_ClayTabBar` 的定案：不给未激活项加实体，
      // 否则一排 chip 会变成各自独立的「物件」）
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(t.ink2.argb32),
            ),
          ),
        ),
      );
    }

    return Clay(
      state: ClayState.selected,
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: CoFonts.uiSans,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Color(t.accentInk.argb32),
        ),
      ),
    );
  }
}

/// 分组标题（「今天该复习 / 之后」）。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.label,
    required this.count,
    required this.accent,
  });

  final String label;
  final int count;

  /// 「今天该复习」用强调色 —— 它是**行动号召**；「之后」用次要色。
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 12 * 0.04,
              color: Color((accent ? t.accent : t.ink3).argb32),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11,
              color: Color(t.ink3.argb32),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条生词。
///
/// 显示：**单词 · 释义 · 熟度三点 · 到期状态 · 暂停**（设计稿 §02 的四要素 + 行内动作）。
///
/// # 🔑 整行可点 → 进入**全屏翻卡**
/// 设计稿：「**点任意一项 → 进入翻卡**」。
///
/// 🔴 2026-09-28 修正记录：这一行**曾经**是「`Clay` 凸起（看起来能点）
/// 但**没有** `onTap`（点了没反应）」——**静默无效的操作**，本项目明令避免的形态。
/// 现在两个问题都修了：
/// 1. 行有 `onTap` → 「暂停」是**行内的独立按钮**（点它不会触发行）
/// 2. 翻卡是**顶层路由**（不是页内状态）→ 四键不再被 tabbar 遮挡
///
/// ⚠️ 另：翻卡**不再是本页的一个状态** —— `_openSession` 会 push 一个全屏路由。
///    原因见 `review_session_screen` 的类文档（「页内状态会继承所在页面的布局约束」）。
class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.row,
    required this.now,
    required this.onPause,
    required this.onOpen,
  });

  final ReviewRow row;
  final DateTime now;
  final VoidCallback onPause;

  /// 点行 → 进入翻卡（设计稿：「**点任意一项 → 进入翻卡**」）
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final item = row.item;
    final due = item.isDue(now);

    // 🔑 整行 `Clay(onTap:)` = **可点**（与 `FeedCard` 同一语汇）。
    //    ⚠️ 这正是 2026-09-28 修正的那处：先前同行是「Clay 凸起（看起来能点）
    //       但无 onTap（点了没反应）」——「静默无效的操作」是本项目明令避免的。
    //    现在行有 `onTap`，「暂停」是**行内的独立按钮**（点它不会触发行）。
    return Clay(
      onTap: onOpen,
      padding: const EdgeInsets.fromLTRB(16, 13, 10, 13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.spelling,
                  style: TextStyle(
                    fontFamily: CoFonts.latinSerif,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    letterSpacing: 18 * -0.011,
                    color: Color(t.ink.argb32),
                  ),
                ),
                // 🆕 释义 —— 设计稿 §02：「列表项 = 单词 + **释义** +
                //     熟练度三点 + 下次到期时间」。
                // ⚠️ 取不到释义时**整行不渲染**（不是空行、不是占位符）——
                //     空行会读成「加载失败」，占位符会读成「这个词没释义」。
                if ((row.definition ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    row.definition!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: t.type.mnemNote, // 12.5
                      height: 1.4,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    _Dots(count: _dotsOf(item), t: t),
                    const SizedBox(width: 9),
                    Text(
                      _dueLabel(item, now),
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 11.5,
                        fontWeight: due ? FontWeight.w600 : FontWeight.w400,
                        color: Color((due ? t.accent : t.ink3).argb32),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _PauseButton(onTap: onPause),
        ],
      ),
    );
  }

  /// 熟度 → **0..3 个点**。
  ///
  /// ## 🔴 这是**渲染层判定**，不是数据层字段
  /// `ReviewListQuery` 的类注释明确：「库级只回答可不可以，渲染层决定展示」
  /// （见 `mnemonic-layer-separation`）→ 数据层只给原始 `state` / `reps`，
  /// **不输出 `dots: 2`**。所以映射规则写在这里，改它不动数据层。
  ///
  /// ## ⚠️ 阈值是**暂定**的（待真机看观感后调）
  /// 依据是 `reps`（复习次数）而非 `stability`：后者是 FSRS 的内部单位（天），
  /// 直接拿来分档会让用户看到「1.7 天 = 两点」这种无法解释的边界。
  /// `reps` 的语义直白（复习过几次），分档也稳定。
  static int _dotsOf(ReviewListItem it) {
    if (it.state == 0 || it.reps <= 0) return 0;
    if (it.reps <= 2) return 1;
    if (it.reps <= 5) return 2;
    return 3;
  }

  /// 到期文案：`现在复习 / 25 分钟后 / 3 小时后 / 4 天后 / 2 个月后`。
  static String _dueLabel(ReviewListItem it, DateTime now) {
    final d = it.untilDue(now);
    if (d.inMinutes <= 0) return '现在复习';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟后';
    if (d.inHours < 24) return '${d.inHours} 小时后';
    if (d.inDays < 30) return '${d.inDays} 天后';
    final months = (d.inDays / 30).round();
    if (months < 12) return '$months 个月后';
    return '${(d.inDays / 365).round()} 年后';
  }
}

/// 熟度三点 —— 实心 = 已点亮。
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.t});

  final int count;
  final CoEvoTokens t;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 点亮 → accent；未点亮 → `line`（与背景同族的浅色，不抢眼）
              color: Color((i < count ? t.accent : t.line).argb32),
            ),
          ),
        ],
      ],
    );
  }
}

/// 「暂停」—— 12 / accent / w600 文字链接（同收藏清单的「返回」版式）。
class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '暂停',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(t.accent.argb32),
          ),
        ),
      ),
    );
  }
}

/// 空状态 —— **两种**（见 `_isFiltering` 的说明）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filtered});

  /// `true` = 有词但被筛掉 / 搜不到；`false` = 真的一个词都没有。
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    if (filtered) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有符合条件的词。\n换个排序、或关掉「已到期」筛选看看。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 13,
              height: 1.7,
              color: Color(t.ink2.argb32),
            ),
          ),
        ),
      );
    }

    // 🔴 2026-10-07 真机修复（白哥反馈 #6）：让空状态**真正在页面居中**。
    //
    // 原实现是 `SingleChildScrollView(padding: fromLTRB(22,52,22,52)) + Column`：
    //   · **垂直不居中** —— 从顶部起算 + 52 上边距 ⇒ 内容浮在偏上
    //   · **水平可能被收缩** —— 外层 `Column(crossAxisAlignment: .start)`
    //     （见 `build` 里那个 `.start`，它是**有意给 header / sortBar 用的，不要动**）
    //     会给孩子**宽松宽度约束** ⇒ 空状态可能收缩到内容宽度 ⇒ 视觉上靠左
    //
    // 修法：`LayoutBuilder` + `ConstrainedBox(minHeight: 可用高度)` +
    //      `Column(mainAxisAlignment: center)`
    //   ⇒ **内容短时垂直居中、内容超屏时可滚动**，两头都顾到。
    // ⚠️ 不能直接写 `Center(child: SingleChildScrollView(...))` ——
    //    scroll view 的 viewport 高度会取 `maxHeight` ⇒ 撑满 ⇒ `Center` 就失效了。
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
        child: ConstrainedBox(
          // 🔴 2026-10-07 真机修复（**第二次**）：必须**同时**给 `minWidth`。
          //
          // 第一次只加了 `minHeight` ⇒ 修好了「上/下居中」，**留下了「左/右靠左」**。
          // 原因：只约束高度时，宽度仍是外层
          // `Column(crossAxisAlignment: CrossAxisAlignment.start)` 传下来的
          // **宽松约束** ⇒ 内层 `Column` 会 shrink-wrap 到内容宽度 ⇒ 视觉上靠左。
          // ⇒ 用 `minWidth: double.infinity` 强制撑满可用宽度，
          //   内层 `Column` 的 `center` 才真正相对于**页面**居中。
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight - 48,
            minWidth: double.infinity,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
          // 粘土凹陷圆环（与收藏清单同一版式语言，两页解决的是同一个问题）
          SizedBox(
            width: 74,
            height: 74,
            child: Clay(
              state: ClayState.pressed,
              fill: t.sunken,
              borderRadius: BorderRadius.circular(37),
              child: Center(
                child: Icon(
                  Icons.style_outlined,
                  size: 26,
                  color: Color(t.ink3.argb32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '还没有要复习的词',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(t.ink.argb32),
            ),
          ),
          const SizedBox(height: 9),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 250),
            child: Text(
              '读文章时遇到不认识的词，长按选中就能查看释义，'
              '查过的词会自动收进来，按记忆曲线安排复习。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 13,
                height: 1.7,
                color: Color(t.ink2.argb32),
              ),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 库不可用 —— 取最小诚实表达（**不冒充「还没有生词」**）。
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '生词暂时读不出来，重启应用可再试。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.7,
            color: Color(t.ink3.argb32),
          ),
        ),
      ),
    );
  }
}
