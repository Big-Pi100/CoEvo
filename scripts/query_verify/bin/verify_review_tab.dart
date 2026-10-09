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
