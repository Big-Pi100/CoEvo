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

import '../providers/review_list_provider.dart';
import '../providers/user_word_provider.dart';
import '../services/review_list_query.dart';
import '../theme/clay.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';

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

  final _searchController = TextEditingController();

  /// 搜索输入框的焦点 —— 展开时自动聚焦（否则用户还要再点一下输入框）。
  final _searchFocus = FocusNode();

  /// 搜索是否**已展开**（默认收起为左上角一个放大镜图标）。
  ///
  /// 🔑 白哥 2026-09-28：「复习页的搜索单词**缩小成左上角图标，点击才展开**」。
  ///    理由：搜索是**低频**动作，不该常驻占一行 —— 常驻会把「今天该复习什么」
  ///    这个主要信息挤下去。
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
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(userWordProvider.future);
      final changed = await repo.pause(item.wordId);

      // `false` = 本来就已经是暂停状态（本次无动作）→ 不刷界面、不提示
      if (!changed) return;

      // 🔑 列表与计数**都要失效**：两者共用一套暂停过滤，
      //    只刷一个会出现「列表少了一条但『N 个今天该看』没变」。
      ref.invalidate(reviewListProvider);
      ref.invalidate(reviewDueCountProvider);

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已暂停「${item.spelling}」，再次查词就会恢复。'),
          duration: const Duration(seconds: 2),
        ));
    } catch (e, st) {
      debugPrint('[review] 暂停失败 wordId=${item.wordId}：$e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final list = ref.watch(reviewListProvider(_args));
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
                data: (items) => items.isEmpty
                    ? _EmptyState(filtered: _isFiltering)
                    : _list(items),
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
  bool get _isFiltering => _args.search.isNotEmpty || _args.dueOnly;

  // ────────────────────────────────────────────────────────────
  // 标题栏（含搜索的两种状态）
  // ────────────────────────────────────────────────────────────
  Widget _header(CoEvoTokens t, int? dueCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 收起态：🔍 + 「复习」+ 筛选 ──────────────────────
          // ── 展开态：搜索框 + 「取消」 ────────────────────────
          //
          // 🔑 两态**共用同一行**（而不是「搜索框另起一行」）——
          //    这样展开/收起时下方内容**不会跳动**
          //    （另起一行会让列表整体下移，是廉价但明显的抖）。
          if (!_searchExpanded)
            Row(
              children: [
                _SearchIconButton(onTap: _expandSearch),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '复习',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 23 * -0.015,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                ),
                // 🆕 筛选：显示全部 / 显示已到期（白哥 2026-09-28 定）
                _FilterChip(
                  dueOnly: _args.dueOnly,
                  onTap: () => setState(
                      () => _args = _args.copyWith(dueOnly: !_args.dueOnly)),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(child: _searchField(t)),
                const SizedBox(width: 6),
                // 「取消」而**不是**一个 ✕ 图标：清空输入与退出搜索是**两件事**，
                // 两个都要有出口 —— ✕ 语义含糊（用户不知道是清空还是退出）。
                InkWell(
                  onTap: _collapseSearch,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
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
                ),
              ],
            ),

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
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
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
  // 三档排序
  // ────────────────────────────────────────────────────────────
  Widget _sortBar(CoEvoTokens t) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          for (final s in ReviewSort.values) ...[
            if (s != ReviewSort.values.first) const SizedBox(width: 8),
            _SortChip(
              label: s.label,
              selected: _args.sort == s,
              onTap: () => setState(() => _args = _args.copyWith(sort: s)),
            ),
          ],
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────
  // 列表
  // ────────────────────────────────────────────────────────────
  Widget _list(List<ReviewListItem> items) {
    final now = DateTime.now();
    // 🔑 分组用**数据层**的静态方法（与 `dueCount` 同一判据）——
    //    在 UI 里重写一遍「是否到期」会让「顶部计数」与「分组标题」打架。
    final g = ReviewListQuery.group(items, now);

    final rows = <Widget>[];
    if (g.due.isNotEmpty) {
      rows.add(_GroupHeader(
        label: '今天该复习',
        count: g.due.length,
        accent: true,
      ));
      for (final it in g.due) {
        rows.add(_WordRow(item: it, now: now, onPause: () => _pause(it)));
      }
    }
    if (g.later.isNotEmpty) {
      rows.add(
          _GroupHeader(label: '之后', count: g.later.length, accent: false));
      for (final it in g.later) {
        rows.add(_WordRow(item: it, now: now, onPause: () => _pause(it)));
      }
    }

    return ListView.separated(
      // 底部留出 tabbar 高度 —— `_ShellScaffold` 开了 `extendBody: true`
      padding: const EdgeInsets.fromLTRB(18, 0, 18, CoSpacing.tabBarClearance),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => rows[i],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// 子组件
// ════════════════════════════════════════════════════════════════

/// 左上角的搜索图标 —— 搜索的**唯一入口**（默认收起态）。
///
/// 🔑 形态与 `_FilterChip` 同族：**粘土凹陷**（`Clay(pressed)` + `sunken` 底）。
///    凹陷 = 「可以按下去」，与筛选药丸、收藏入口是同一种物理语汇。
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

/// 筛选按钮 —— 「全部 / 已到期」二态切换。
///
/// 🔑 它是**筛选**不是**排序** —— 与三档排序正交，用**不同形态**表达：
///    排序是「平坦文字 + 选中变药丸」（`_SortChip`），筛选是「一个会翻面的小药丸」。
///    ⚠️ 若两者长得一样，用户会以为它们是一组单选。
class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.dueOnly, required this.onTap});

  final bool dueOnly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    // 选中（只看已到期）→ 强调色填充；未选中 → 凹陷
    final bg = dueOnly ? t.accent : t.sunken;
    final fg = dueOnly ? t.accentInk : t.ink2;

    return Clay(
      state: dueOnly ? ClayState.selected : ClayState.pressed,
      fill: bg,
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.filter_alt_outlined, size: 13, color: Color(fg.argb32)),
          const SizedBox(width: 5),
          Text(
            dueOnly ? '已到期' : '全部',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color(fg.argb32),
            ),
          ),
        ],
      ),
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
/// 显示：**单词 · 熟度三点 · 到期状态 · 暂停**。
///
/// 🔑 **刻意没有 `onTap`**（第一步的范围）—— 点进翻卡属第二步。
///    按 3.22 的教训，宁可不给暗示（无 `›`、无点击反馈），
///    也不给一个点了没反应的入口。
class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.item,
    required this.now,
    required this.onPause,
  });

  final ReviewListItem item;
  final DateTime now;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);
    final due = item.isDue(now);

    return Clay(
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

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 52, 22, 52),
      child: Column(
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
