// 「复习」tab 的双段结构（复习 ｜ 笔记）—— 验收（纯 Dart · 可进 CI）
//
// 跑：cd scripts/query_verify && dart run bin/verify_review_tab.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail` —— 本项目已踩过）。
//
// # 这批断言守什么（2026-10-08 白哥定案）
//
// > 「把『我的划线』移动到复习页面，名称改为『笔记』与『复习』同级，
// >  就像阅读页面有『今日精选』和『书架』两个同级页面一样」
//
// 这件事里有**六类编译器全都抓不到**的走偏：
//
// | # | 会静默走偏的事 | 靠什么守 |
// |---|---|---|
// | ① | 标题文案被改回「我的划线」/ 改成「高亮」 | 集合断言（**恰好** {复习, 笔记}）|
// | ② | 两个段的 `stackIndex` 与声明顺序不一致 | 逐条断言（点笔记会显示复习）|
// | ③ | **改名后旧名残留**（UI 里还写着「我的划线」）| 源级扫描 |
// | ④ | 旧顶层路由 `/highlights` 没删 ⇒ **两个入口指向同一份数据** | 源级扫描 |
// | ⑤ | 「我的」页那个入口没删（同上）| 源级扫描 |
// | ⑥ | 「复习」标题**两处都有**（容器 + 页面自己）| 源级扫描（页面不该再有 23px「复习」）|
//
// 📌 判据①：**能落成常量的产品决定，别让它散在 UI 代码的字符串字面量里**（同 `reading_section`）。
// 📌 判据②③④：**改名 / 搬家是一组动作** —— 光改新地方不算完，
//    旧名字与旧入口的残留会让「两个入口指向同一份数据」，而**编译器不会报**。

import 'dart:io';

import '../../../app/lib/screens/review_section.dart';
import '_repo_paths.dart';

var _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String _read(String rel) {
  final f = File(repoPath(rel));
  if (!f.existsSync()) {
    throw StateError('读不到 $rel —— 路径变了，本断言已失效（不是通过）');
  }
  return f.readAsStringSync();
}

/// 剥**整行**注释（项目判据：只能按整行剥，切 `//` 会切掉 `https://`）。
String _strip(String s) => s
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

void main() {
  print('');
  print('【1】段定义（纯 Dart · 可直接断言）');

  check(
    '① 标题集合**恰好**是 {复习, 笔记}（集合相等，不是「包含」）',
    ReviewSection.values.map((s) => s.title).toSet().toString() ==
        {'复习', '笔记'}.toString(),
    ReviewSection.values.map((s) => s.title).join(' / '),
  );
  check('①-2 「复习」是**默认段**（声明顺序第一个 = 点进 tab 看到的那段）',
      ReviewSection.values.first == ReviewSection.review);
  check('② `stackIndex` 与声明顺序一致（0/1）',
      ReviewSection.review.stackIndex == 0 && ReviewSection.notes.stackIndex == 1,
      '${ReviewSection.review.stackIndex}/${ReviewSection.notes.stackIndex}');
  check('②-2 `other` 是互反的（切换用）',
      ReviewSection.review.other == ReviewSection.notes &&
          ReviewSection.notes.other == ReviewSection.review);
  check('①-3 两段标题都是 **2 字**（与「今日精选 ｜ 书架」并排时不给右侧留空位）',
      ReviewSection.values.every((s) => s.title.length == 2),
      ReviewSection.values.map((s) => s.title.length).join(','));

  print('');
  print('【2】与「阅读」tab **同构**（白哥要的就是「像阅读页面那样」）');

  final readingSec = _strip(_read('app/lib/screens/reading_section.dart'));
  final reviewSec = _strip(_read('app/lib/screens/review_section.dart'));
  for (final m in ['String get title', 'int get stackIndex', 'get other']) {
    check('两边的段扩展都提供 `$m`', readingSec.contains(m) && reviewSec.contains(m));
  }

  print('');
  print('【3】改名 / 搬家后**旧东西要清干净**（源级扫描 · 只扫签名级）');

  final app = _strip(_read('app/lib/app.dart'));
  check('④ 旧顶层路由 `/highlights` 已删除', !app.contains("'/highlights'"));
  check('④-2 `/review` 指向**容器** `ReviewTabScreen`（不是单页 ReviewScreen）',
      app.contains('const ReviewTabScreen()') &&
          !app.contains('const ReviewScreen()'));

  final profile = _strip(_read('app/lib/screens/profile_screen.dart'));
  check('⑤ 「我的」页不再有 `/highlights` 入口', !profile.contains('/highlights'));

  final review = _strip(_read('app/lib/screens/review_screen.dart'));
  check('⑥ `review_screen` 不再自带「复习」标题（标题由容器给，两处都有会显示两个）',
      !review.contains("'复习'"),
      '（若它仍含 23px 的 \'复习\' ⇒ 容器标题 + 页内标题会同时出现）');

  final hi = _strip(_read('app/lib/screens/highlights_screen.dart'));
  check('③ 划线页里不再有旧名「我的划线」', !hi.contains('我的划线'));
  check('③-2 划线页不再有「返回」按钮（tab 内视图的出口是切 tab / 底部 tabbar）',
      !hi.contains("'返回'") && !hi.contains('context.pop()'));

  print('');
  print('【4】容器本身（结构断言 · 只锁「有没有那两块」）');

  final tab = _strip(_read('app/lib/screens/review_tab_screen.dart'));
  check('容器用 `IndexedStack`（切换瞬时 + 状态保留，不是 if/else 重建）',
      tab.contains('IndexedStack'));
  check('容器按 `stackIndex` 选段', tab.contains('_section.stackIndex'));
  check('两段内容都在容器里（`ReviewScreen` + `HighlightsScreen`）',
      tab.contains('ReviewScreen()') && tab.contains('HighlightsScreen()'));
  check('标题字号 23 / w600 与阅读 tab 同规格（切 tab 时标题不横移）',
      tab.contains('fontSize: 23') && tab.contains('FontWeight.w600'));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('⑤ 🆕 「全部 / 已到期」筛选 chip 的位置（2026-10-08）');
  // ══════════════════════════════════════════════════════════════
  //
  // 🔴 这条守的是**布局回归**：筛选 chip 必须与两个标题**同一行**。
  //    标题行在容器（`ReviewTabScreen`）里 ⇒ 任何想与标题同行的元素
  //    **必须在容器渲染**；留在复习页里就必然落到**下一行**
  //    （白哥真机反馈：「『全部』按钮不和 title 在一行，而是到了下一行」）。
  // （用本文件既有的 `_strip(_read(...))` helper —— 别再造一套）
  final screen = _strip(_read('app/lib/screens/review_screen.dart'));
  check('⑤-1 容器标题行里有 `HeaderChip`', tab.contains('HeaderChip('),
      '不在容器 ⇒ 必然落到标题的下一行');
  check('⑤-2 它只在**复习**段显示（笔记段没有这个概念）',
      tab.contains('if (_section == ReviewSection.review)'));
  check('⑤-3 🔴 复习页里**不再有** `HeaderChip`（否则又回到「下一行」）',
      !screen.contains('HeaderChip('));
  check('⑤-4 两边共用 `reviewDueOnlyProvider`（一个状态源）',
      tab.contains('reviewDueOnlyProvider') &&
          screen.contains('reviewDueOnlyProvider'));
  check('⑤-5 🆕 文章页渲染用 `inlineDirectives`（不是未接线的 `inlinePatterns`）',
      _strip(_read('app/lib/widgets/trace_markdown.dart'))
          .contains('inlineDirectives:'),
      '传 `inlinePatterns` ⇒ 痕迹与划线**静默不显示**（analyzer 不报）');

  // ══════════════════════════════════════════════════════════════
  print('⑥ 🆕 空 / 加载态的**引导文字**（2026-10-13 白哥：复习页为空时什么都没有）');
  // ══════════════════════════════════════════════════════════════
  //
  // 🔴 事故：白哥看到复习页**一片空白**（连引导都没有），
  //    以为「之前有的东西不见了」。实测**根因不是回归** —— 三种形态里：
  //
  // | 形态 | 改前 |
  // |---|---|
  // | 真空态 | ✅ 本来就有：图标 + 标题 +「词从哪来」的说明 |
  // | 筛选态 | 🟠 只有**一行 13px 小字**（无图标无标题）⇒ 读起来像「词没了」|
  // | **加载态** | 🔴 `SizedBox.shrink()` ⇒ **完全空白** ← 白哥撞上的正是这个 |
  //
  // 加载态那一支的原判据是「画空状态会在有词时先闪一下『还没有生词』= 谎报」，
  // ❌ 判断本身没错，但结论选错了 —— 换来的是**加载期一片空白**，
  //    而用户分不清「在加载」还是「页面坏了」，且那恰是
  //    **换账号 / 首次从云端拉数据**时最长的一段。
  //
  // ✅ 改法：加载态照**书架页**（`book_library_screen.dart:96`）显示**转圈**；
  //          筛选态补成「图标 + 标题 + 『你的生词都还在』」（与书架空态同构）。
  // 📌 判据：**避免谎报的正确做法是「说中性的话」，不是「什么都不说」** ——
  //    「什么都不说」在本项目里已被证明会被读成「坏了」。
  //
  // # 🔴 证伪方式
  // · 把 loading 分支改回 `SizedBox.shrink()` ⇒ ⑥-1 必红
  // · 删掉筛选态的标题或说明 ⇒ ⑥-3 必红
  check('⑥-1 🔴 加载态不得是空白（不得出现 `SizedBox.shrink`）',
      !screen.contains('SizedBox.shrink'),
      '空白会被读成「页面坏了」—— 加载中要给中性信号');
  check('⑥-2 🔴 加载态用 `CircularProgressIndicator`（与书架页同款）',
      screen.contains('CircularProgressIndicator'));
  check('⑥-3 🔴 筛选态空态要有「标题 + 说明」，不是光秃秃一行小字',
      screen.contains('没有符合条件的词') && screen.contains('你的生词都还在'),
      '「你的生词都还在」必须是第一句 —— 它直接消掉「词没了」的恐慌');
  check('⑥-4 🔴 真空态的「词从哪来」引导**不能丢**（那是教用户怎么用的唯一处）',
      screen.contains('还没有要复习的词') &&
          screen.contains('读文章时遇到不认识的词'));

  // ── 🆕 2026-10-13 真机回归：空态「只剩那个凹陷圆环、两行文字全不见」──────
  //
  // # 根因（**不是文案被删** —— 文案一直在，坏的是**布局**）
  //
  // 2026-10-10 为「空态也能下拉刷新」在**外层**加了 `_alwaysScrollable`
  // （`LayoutBuilder → SingleChildScrollView → ConstrainedBox(minHeight: 视口高)`），
  // 而 `_EmptyState` 当时**自带**一整套
  // `LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight: constraints.maxHeight - 48)`
  // ⇒ **两层嵌套滚动**。内层 `LayoutBuilder` 拿到的是**无界** `maxHeight`
  // （外层 scroll view 必然给出无界约束）⇒ `maxHeight - 48` 算出来是
  // **`double.infinity`** ⇒ Column 被撑成无穷高 ⇒ `mainAxisAlignment: center`
  // 把孩子摆到**无穷远** ⇒ 真机上只剩图标。
  //
  // 🔑 判据：**「谁能滚动」只能有一个**。
  //    嵌套滚动视图 + 无界约束**一定**算错高度，而且**不报错**（只是内容消失）。
  // 📌 两条方法论（本次踩到）：
  //    ① **「字符串存在」≠「能渲染出来」** —— 我上一轮只查了「文案有没有被删」，
  //       查不到就断言「不是回归」，**判据选错了对象**（该查的是布局约束）。
  //    ② 空态/错误态的**高度、居中、滚动**应由**一处**统一提供；
  //       组件自带一半、外层再补一半 ⇒ 必然打架。
  //
  // # 🔴 证伪方式
  // · 在 `_EmptyState` 里重新引入 `constraints.maxHeight` ⇒ ⑥-5 必红
  // · 给 `_EmptyState` 加回 `SingleChildScrollView` ⇒ ⑥-6 必红
  // · 把 `_alwaysScrollable(_EmptyState(` 拆开 ⇒ ⑥-7 必红
  final _esStart = screen.indexOf('class _EmptyState');
  final _esEnd = _esStart < 0 ? -1 : screen.indexOf('\n}', _esStart);
  final _emptyState =
      (_esStart >= 0 && _esEnd > _esStart) ? screen.substring(_esStart, _esEnd) : '';
  check('⑥-5 🔴 `_EmptyState` 不得依赖 `constraints.maxHeight`（外层给它的是无界约束）',
      _emptyState.isNotEmpty &&
          !_emptyState.contains('constraints.maxHeight'),
      '嵌套滚动下它算出来是 infinity ⇒ 内容被摆到无穷远，只剩图标（10-13 真机事故）');
  check('⑥-6 🔴 `_EmptyState` 不得自带滚动视图（「谁能滚动」只能有一个）',
      _emptyState.isNotEmpty &&
          !_emptyState.contains('SingleChildScrollView'),
      '与外层 `_alwaysScrollable` 形成两层嵌套 ⇒ 高度算错且**不报错**');
  check('⑥-7 🔴 空态仍被 `_alwaysScrollable` 包着（由它提供高度 + 下拉刷新）',
      // ⚠️ 必须容忍换行/缩进 —— 源码里写成了
      //    `_alwaysScrollable(\n    _EmptyState(...)`（格式化后必然断行），
      //    死写一个不含空白的字面量会**假红**。
      RegExp(r'_alwaysScrollable\(\s*_EmptyState\(').hasMatch(screen),
      '不包 ⇒ 内容挤在顶部，且空态无法下拉刷新（10-10 的需求）');

  // ── ⑧ 🆕 2026-10-13（白哥第二报）：空态「文字有了，但**不居中**」──────────
  //
  // # 根因（**不在空态自己身上**）
  //
  // `_ShellScaffold` 开了 `extendBody: true` ⇒ 列表区一直延伸到 **tabbar 之后**
  // ⇒ 空态按「区域高度」居中时，视觉重心落到 tabbar 后面 ⇒ **看起来偏低**。
  // 📌 不是「没居中」，是**居中在了错的地方**（居中的区域比看得见的区域大）。
  //
  // # 🔑 笔记页早就解决过同一个问题
  //
  // `highlights_screen` 的空态/错误态用 `Padding(fromLTRB(40, 0, 40, 60))`
  // 把内容**上移半个补偿量**。白哥原话：「这个问题在笔记页面也出现过」——
  // 而复习页当时没跟上 ⇒ **同一个问题、两页各写一个数字**，迟早再撞一次。
  // ⇒ 收成 `CoSpacing.emptyStateBottomInset`（**一处权威**）。
  //
  // # 🔴 证伪方式
  // · 去掉复习页空态的底部补偿 ⇒ ⑧-1 必红
  // · 把笔记页那份改回硬写的 `60` ⇒ ⑧-3 必红
  final spacingSrc = _strip(_read('app/lib/theme/co_spacing.dart'));
  final notesSrc = _strip(_read('app/lib/screens/highlights_screen.dart'));
  check('⑧-1 🔴 复习页空态必须用 `CoSpacing.emptyStateBottomInset`（否则居中偏低）',
      screen.contains('CoSpacing.emptyStateBottomInset'),
      '这是「文字有了但不居中」那次事故的直接防线');
  check('⑧-2 🔴 该常量**只定义一处**（两个页面都不许再自己定义）',
      spacingSrc.contains('emptyStateBottomInset') &&
          !screen.contains('emptyStateBottomInset =') &&
          !notesSrc.contains('emptyStateBottomInset ='),
      '在别处再定义一份 ⇒ 两个数字必然漂');
  check('⑧-3 🔴 笔记页与复习页引用**同一个**常量，且旧字面量不得复活',
      notesSrc.contains('CoSpacing.emptyStateBottomInset') &&
          !notesSrc.contains('40, 0, 40, 60') &&
          !screen.contains('40, 0, 40, 60'),
      '两页各硬写一个 60 正是这次复发的原因（反向断言，对重构免疫）');

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：**改名 / 搬家只做了一半** ——');
    print('    · 【1】红 ⇒ 标题文案被改（或又加了一段）');
    print('    · 【3】红 ⇒ 旧名「我的划线」/ 旧路由 `/highlights` / 旧入口还留着');
    print('      ⇒ 那会让**两个入口指向同一份数据**（栈行为分叉，生词本那次踩过）');
    print('    · 【4】红 ⇒ 容器结构被改（IndexedStack ↔ if/else 会让切换丢状态）');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
