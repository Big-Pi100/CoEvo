// CoEvo · 通知中心「外壳」与设计口径一致性验收
//
// 跑法：cd scripts/query_verify && dart run bin/verify_notification_shell.dart
// 退出码：0 = 全通过；1 = 有失败
//
// # 为什么要这个脚本（2026-10-09）
// `screens/notification_panel.dart` 曾是**全库唯一**用 Material `AppBar` 的页面
// （`grep -rl "appBar: AppBar(" app/lib` ⇒ 只有它）⇒ 与设计系统其余页面不一致。
//
// 🔴 本脚本守的**三条**（都是「改完就忘」的那类）：
// ① **返回入口**：原来的返回是 `AppBar` **隐式**给的 ⇒ 换掉外壳**会连它一起丢**。
//    同类事故有过：`bookmark_list_screen` 的「收藏列表根本没有返回按钮」（白哥实测）。
// ② **「全部已读」搬位置 ≠ 删**：它从顶栏移到标题行下方，**文案与动作必须还在**。
// ③ **设计口径**：标题行照设计稿 `.bm-hd`（`visual-feed-bookmark-2026-09-25.html:174-176`）
//    = **大标题左（23 / w600 / 字距 -.015em）+ 右侧一个 accent 12/w600 元素**，
//    且与 `bookmark_list_screen` **共用同一套数值** ⇒ 这才叫「设计统一」（可验证）。
//    ⚠️ 全库另有第二套顶栏形态（`achievements_screen._TopBar`：「‹ 返回」+ 小标题，
//       无设计稿依据）—— 本脚本断言通知中心**不**落进第二套，避免又造第三种。

import 'dart:io';

import '_repo_paths.dart';

int _pass = 0;
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

void eq(String label, Object? actual, Object? expected) => check(label,
    actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

/// 按**整行**剥掉注释行（`//` / `///` 开头）。
///
/// 🔴🔴 **必须有这一步** —— 本脚本第一次跑就踩了：
/// 我在改码时把「原来这里是 `appBar: AppBar(`」写进了**解释性注释**，
/// 于是「全库 `appBar: AppBar(` 应为 0」这条**读到了自己的注释** ⇒ 假红。
/// 📌 判据（本项目已记过多次）：**「注释里提到」≠「代码里写了」** ——
///    文本断言必须先剥注释；且**只能按整行剥**（按子串剥会切坏字符串里的 `//`，如 URL）。
String _codeOnly(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 所有 `app/lib/**/*.dart` 的**代码**（已剥注释）—— 文本断言用。
Map<String, String> _libSources() {
  final root = repoPath('app/lib');
  final out = <String, String>{};
  for (final e in Directory(root).listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      final rel = e.path
          .substring(root.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      out[rel] = _codeOnly(e.readAsStringSync());
    }
  }
  return out;
}

/// 切片：`from` 之后到 `to` 之前（找不到 → 空串，由调用方的断言报红）。
String _slice(String src, String from, String to) {
  final i = src.indexOf(from);
  if (i < 0) return '';
  final j = src.indexOf(to, i + from.length);
  return j < 0 ? src.substring(i) : src.substring(i, j);
}

void main() {
  final lib = _libSources();
  String f(String rel) => lib[rel] ?? '';
  final panel = f('screens/notification_panel.dart');
  final bookmark = f('screens/bookmark_list_screen.dart');

  check('找到通知面板源码', panel.isNotEmpty);

  // ══════════════════════════════════════════════════════════════
  section('【1】🔴 外壳唯一口径：`appBar: AppBar(` 全库为 0');
  // ══════════════════════════════════════════════════════════════
  {
    final owners = lib.entries
        .where((e) => e.value.contains('appBar: AppBar('))
        .map((e) => e.key)
        .toList();
    eq('🔴 全库 `appBar: AppBar(` 的处数', owners.length, 0);
    check('…没有「另一个页面偷偷用回 Material AppBar」',
        owners.isEmpty, owners.join(', '));
  }

  // ══════════════════════════════════════════════════════════════
  section('【2】底色与安全区 —— 照**同类页**（独立 push 页）');
  //   🔑 通知中心是 `MaterialPageRoute` push 的全屏页（**不在 shell 内**、没有自绘 tabbar）
  //      ⇒ 参照物是 `achievements_screen`（`SafeArea(` 默认 bottom: true），
  //        **不是** `bookmark_list_screen`（它在 shell 内，写的是 `bottom: false`）。
  // ══════════════════════════════════════════════════════════════
  {
    check('底色用设计 token（`Color(t.page.argb32)`）',
        panel.contains('backgroundColor: Color(t.page.argb32)'));
    check('用了 `SafeArea(`', panel.contains('SafeArea('));
    check('🔑 独立页**要**避让底部安全区（不得写 `bottom: false` —— 那是 shell 内页的写法）',
        !panel.contains('bottom: false'));
  }

  // ══════════════════════════════════════════════════════════════
  section('【3】标题行 —— 照设计稿 `.bm-hd`（大标题左 + 右侧一个 accent 元素）');
  // ══════════════════════════════════════════════════════════════
  {
    // ⚠️ 锚点用 `'通知中心'` 而不是 `Text('通知中心'` —— 源码里 `Text(` 与字符串
    //    **不同行**（格式化换行），按 `Text('…'` 切会得到空串 ⇒ 全组假红。
    //    切片**收到 `'返回'` 为止** ⇒ 范围 = 标题自己的样式块（不含返回/动作块）。
    final head = _slice(panel, "'通知中心'", "'返回'");
    check("标题文案在（'通知中心'）", panel.contains("'通知中心'"));
    check('能切出标题行片段（下面断言的前提）', head.isNotEmpty);
    check('标题：与收藏页同档 `fontSize: 23`', head.contains('fontSize: 23'));
    check('标题：`letterSpacing: 23 * -0.015`（设计稿 -.015em）',
        head.contains('letterSpacing: 23 * -0.015'));
    check('标题：`FontWeight.w600`', head.contains('FontWeight.w600'));
    check('标题色用墨色 token（`t.ink`）', head.contains('t.ink.argb32'));
    check('用 `CoFonts.uiSans`（不是裸字体）',
        head.contains('CoFonts.uiSans'));
    // ⚠️ Padding 在标题 Text **之前**（它是 Row 的父）⇒ 上面那段切片够不到它。
    //    ⇒ 单独切「Padding → 返回」这一段（范围 = 标题行整体）来核对。
    final titleRow =
        _slice(panel, 'EdgeInsets.fromLTRB(18, 2, 14, 14)', "'返回'");
    check('🔑 标题行 Padding 与收藏页**同一套**（`fromLTRB(18, 2, 14, 14)`）',
        titleRow.contains('EdgeInsets.fromLTRB(18, 2, 14, 14)') &&
            titleRow.contains('fontSize: 23'));
  }

  // ══════════════════════════════════════════════════════════════
  section('【4】🔴 返回入口**显式**（原先是 AppBar 隐式给的 —— 换外壳会一起丢）');
  // ══════════════════════════════════════════════════════════════
  {
    // 切片收到 `'全部已读'` 为止 ⇒ 范围 = 返回链接自己的样式块（不含动作块）。
    final back = _slice(panel, "'返回'", "'全部已读'");
    check('🔴 有显式返回动作（`context.pop()`）', panel.contains('context.pop()'));
    check("🔴 有「返回」文案（'返回'）", panel.contains("'返回'"));
    check('返回：`fontSize: 12`（`.back` 口径）', back.contains('fontSize: 12'));
    check('返回：`FontWeight.w600`', back.contains('FontWeight.w600'));
    check('返回：accent 色（`t.accent.argb32`）', back.contains('t.accent.argb32'));
    check('返回：热区撑开（`EdgeInsets.symmetric` + 内边距）',
        back.contains('EdgeInsets.symmetric('));
    check('返回：`InkWell` + 圆角（可点、有反馈）',
        back.contains('InkWell(') && back.contains('BorderRadius.circular(8)'));
  }

  // ══════════════════════════════════════════════════════════════
  section('【5】🔴「全部已读」搬位置 ≠ 删（文案 + 动作 + 条件渲染都要在）');
  // ══════════════════════════════════════════════════════════════
  {
    check('文案仍在（`全部已读`）', panel.contains('全部已读'));
    check('🔴 动作仍接在 `_markAllRead`（不是只留一句死文案）',
        panel.contains('_markAllRead'));
    check('🔴 仍只在有未读时渲染（`unreadCount > 0`）',
        panel.contains('unreadCount > 0'));
    check('未读数仍由 `read == false` 数出来（口径未被顺手改掉）',
        panel.contains("n['read'] == false"));
    check('不再用 `TextButton`（项目里「动作」的统一形态是自绘文字链接）',
        !panel.contains('TextButton('));
  }

  // ══════════════════════════════════════════════════════════════
  section('【6】跨页一致 —— 这才叫「设计统一」（可验证的形式）');
  // ══════════════════════════════════════════════════════════════
  {
    check('找到收藏页源码（对照的前提）', bookmark.isNotEmpty);
    for (final key in [
      'fontSize: 23',
      'letterSpacing: 23 * -0.015',
      'EdgeInsets.fromLTRB(18, 2, 14, 14)',
      'BorderRadius.circular(8)',
    ]) {
      check('🔑 与收藏页**共用同一套标题行口径**：`$key`',
          panel.contains(key) && bookmark.contains(key));
    }
    check('🔴 不落进第二套形态（`achievements_screen._TopBar` 的「‹」返回）',
        !panel.contains('‹'));
    check('🔴 也不再自己造第三套（无 `AppBar` / 无 `PreferredSize` 顶栏）',
        !panel.contains('AppBar(') && !panel.contains('PreferredSize('));
  }

  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final x in _failures) {
      print('  · $x');
    }
  }
  print('═' * 72);
  exit(_failures.isEmpty ? 0 : 1);
}
