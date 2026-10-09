// CoEvo · 划词菜单「布局契约」验收
//   ① `_buildMenu` 必须返回 `CustomSingleChildLayout` + `TextSelectionToolbarLayoutDelegate`
//   ② 锚点必须来自 SDK（`region.contextMenuAnchors`），不得硬编码
//   ③ 菜单只能经由「被包着」这一条路被构造（`_menuBody` 唯一构造点、唯一调用点）
//   ④ 全项目：凡用了 `contextMenuBuilder` 的文件都必须有「放松约束」的手段
//
// 跑法：cd scripts/query_verify && dart run bin/verify_selection_menu_layout.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（这不是审美问题，是一条 **SDK 契约**）
//
// 2026-10-08 白哥真机：「正文长按菜单弹出时**变成白屏**」。根因不是样式，是**布局契约**：
//   · `contextMenuBuilder` 的返回值被 `ContextMenuController` **直接 `Overlay.insert`**
//     （不是 `Positioned`）— `context_menu_controller.dart:64`
//   · Overlay 给**非定位 entry** 的约束是 `BoxConstraints.tight(size)`（**全屏紧约束**）
//     — `overlay.dart:1426`，SDK 原注释：
//     「Equivalent to BoxConstraints used by RenderStack for `StackFit.expand`」
//   · 该约束经 `_SelectionToolbarWrapper`（`TapRegion→Directionality→FadeTransition→
//     CompositedTransformFollower`；最后者 `extends RenderProxyBox` 且**不覆写
//     `performLayout`**）**原样透传**到菜单 — `text_selection.dart:1954` + `proxy_box.dart:4550`
//   · `ConstrainedBox` / `SizedBox` 这类**放松不掉**它（`enforce` 遇更紧的父约束只会**更紧**）
//   ⇒ 菜单被撑成**全屏**，而它的实心底 `card` 色盖住整屏 ⇒ 用户看到的就是「白屏」
//
// 框架自带的 `AdaptiveTextSelectionToolbar` 之所以正常，是因为它内部用
// `TextSelectionToolbarLayoutDelegate.getConstraintsForChild → constraints.loosen()`
// **解除**了这个约束（`text_selection_toolbar_layout_delegate.dart:73`）。
// ⇒ **任何自定义 `contextMenuBuilder` 都必须自己做同一件事。**
//
// 🔴 而这件事 **analyzer / type checker 都看不见**（约束是运行期的，`ConstrainedBox`
//    在类型上完全合法）⇒ **只能靠结构断言守**。
//
// # 🔴 本脚本自身的证伪方式（改断言后必须各跑一次）
//
// · 把 `_buildMenu` 的 `return CustomSingleChildLayout(` 改成 `return _menuBody(region, text, kind);`
//   → ①-1 必须变红（①-3 也会红）
// · 把 `TextSelectionToolbarLayoutDelegate(` 换成自写的 delegate → ①-2 必须变红
// · 把 `anchorAbove: anchors.primaryAnchor` 改成 `anchorAbove: Offset.zero` → ②-2 必须变红
// · 在别处再写一处 `SelectionMenu(items: [...])` → ③-1 必须变红
// · 把 `region.contextMenuAnchors` 改成手写常量 → ②-1 必须变红
//
// # ⚠️ 口径（如实标注）
//
// · 只做**词法级**扫描（剥整行注释 + 括号配对取块）⇒ 能锁「结构在不在」，
//   **不能**替代真机看一眼 —— 「菜单出现在选区旁、上方不足时翻转、不溢出屏幕」
//   仍属**真机范畴**（本机跑不了 Flutter 渲染）。
// · 「放松约束」的手段是**多选一**（`CustomSingleChildLayout` / `UnconstrainedBox` /
//   `OverflowBox` / `loosen(`）—— 不锁死单一写法（判据：别把断言锁死在一个实现上）。
// · 剥注释只到「行首 `//`」与「行内 `//`（前面无引号）」两级 —— 够用，
//   但不处理块注释 `/* */`（本项目不用那种风格）。

import 'dart:io';

import '_repo_paths.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(detail == null ? label : '$label —— $detail');
    print('  ❌ $label${detail == null ? '' : ' —— $detail'}');
  }
}

/// 剥注释：整行 `//` 一律去掉；行尾 `//` 在「前面没有引号」时截断。
///
/// 🔑 **必须剥**：`_buildMenu` 里写着大段解释性注释，里面就含
///    `CustomSingleChildLayout` 这些词 —— 不剥会把注释当成实现（**假绿**）。
String stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    if (raw.trimLeft().startsWith('//')) continue;
    final i = raw.indexOf('//');
    if (i >= 0 &&
        !raw.substring(0, i).contains("'") &&
        !raw.substring(0, i).contains('"')) {
      out.add(raw.substring(0, i));
    } else {
      out.add(raw);
    }
  }
  return out.join('\n');
}

/// 从 [signature] 出现处开始，取到**配对的大括号**结束（含 `}`）。
String? blockAt(String src, String signature) {
  final at = src.indexOf(signature);
  if (at < 0) return null;
  final open = src.indexOf('{', at);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return null;
}

int countOf(String src, String needle) {
  var n = 0;
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    n++;
    from = i + needle.length;
  }
  return n;
}

String baseName(String path) => path.split(RegExp(r'[/\\]')).last;

void main() {
  final src = stripComments(
      File(repoPath('app/lib/widgets/word_lookup_selection.dart')).readAsStringSync());

  // ────────────────────────────────────────────────────────────────
  print('① `_buildMenu` 的返回必须解除 Overlay 的全屏紧约束');

  final buildMenu = blockAt(src, 'Widget _buildMenu(');
  check('①-0 找得到 `_buildMenu` 的函数体', buildMenu != null,
      '扫不到 ⇒ 后面的「全过」是空过（先证检测器有效）');

  if (buildMenu != null) {
    check('①-1 `return` 的直接返回值是 `CustomSingleChildLayout(`',
        RegExp(r'return\s+CustomSingleChildLayout\(').hasMatch(buildMenu),
        '若直接 return 菜单本体 ⇒ 被 Overlay 撑成全屏 ⇒ 白屏');
    check('①-2 delegate 是框架的 `TextSelectionToolbarLayoutDelegate(`',
        buildMenu.contains('TextSelectionToolbarLayoutDelegate('),
        '自写 delegate 若不 loosen 约束 ⇒ 同样白屏');
    check('①-3 菜单本体挂在 `child:`（唯一正确槽位）',
        buildMenu.contains('child: _menuBody('));
  }

  // ────────────────────────────────────────────────────────────────
  print('');
  print('② 锚点必须来自 SDK（不得硬编码）');

  if (buildMenu != null) {
    check('②-1 取 `region.contextMenuAnchors`（SDK 给的锚点）',
        buildMenu.contains('region.contextMenuAnchors'));
    // ⚠️ 这里锁的是「实参**来自 SDK 锚点**」，不是「有这个键」。
    //    我第一版写的是 `contains('anchorAbove:')` —— 那把实参换成
    //    `anchorAbove: Offset.zero`（硬编码）**照样通过** ⇒ **假绿**。
    //    📌 判据：**断言要锁「值从哪来」，不能只锁「键在不在」**。
    check('②-2 `anchorAbove:` 的实参来自 SDK 锚点',
        RegExp(r'anchorAbove:\s*anchors\.').hasMatch(buildMenu));
    check('②-3 `anchorBelow:` 的实参来自 SDK 锚点',
        RegExp(r'anchorBelow:\s*anchors\.').hasMatch(buildMenu));
  }

  // ────────────────────────────────────────────────────────────────
  print('');
  print('③ 菜单只能经由「被包着」这一条路被构造');

  final menuSites = countOf(src, 'SelectionMenu(items:');
  check('③-1 `SelectionMenu(items:` 全文件只出现 1 次（唯一构造点）',
      menuSites == 1, '实际 $menuSites 处');

  final bodyDef = blockAt(src, 'Widget _menuBody(');
  check('③-2 `_menuBody` 的定义存在', bodyDef != null);
  if (bodyDef != null) {
    check('③-3 唯一构造点在 `_menuBody` 内',
        bodyDef.contains('SelectionMenu(items:'));
  }

  final bodyRefs = countOf(src, '_menuBody(');
  check('③-4 `_menuBody(` 只出现 2 次（1 处定义 + 1 处调用）', bodyRefs == 2,
      '实际 $bodyRefs 处 —— 多出来的调用点可能绕过了那层 wrapper（⇒ 白屏）');

  // ────────────────────────────────────────────────────────────────
  print('');
  print('④ 全项目：凡自定义 `contextMenuBuilder` 的文件都必须有「放松约束」的手段');

  const relaxers = [
    'CustomSingleChildLayout',
    'UnconstrainedBox',
    'OverflowBox',
    'loosen(',
  ];
  final hits = <String>[];
  final missing = <String>[];
  for (final f in Directory(repoPath('app/lib'))
      .listSync(recursive: true)
      .whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final s = stripComments(f.readAsStringSync());
    if (!s.contains('contextMenuBuilder')) continue;
    hits.add(f.path);
    if (!relaxers.any(s.contains)) missing.add(baseName(f.path));
  }
  check('④-0 至少扫到一个用 `contextMenuBuilder` 的文件（阴性对照）',
      hits.isNotEmpty, '一个都没扫到 ⇒ 检测口径已失效（改名了？）');
  check('④-1 每个这样的文件都有「放松约束」的手段', missing.isEmpty,
      '缺：${missing.join(', ')}');

  // ────────────────────────────────────────────────────────────────
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
    print('🔑 最可能的原因：');
    print('    · 菜单被「直接 return」了（或在别处 new 了一个 `SelectionMenu`）——');
    print('      analyzer 不会报，真机表现是**整屏白**（card 底色被撑满全屏）。');
    print('    · 或者换了 delegate：只有 `TextSelectionToolbarLayoutDelegate`');
    print('      （或任何 `getConstraintsForChild → loosen()` 的实现）能解除那个紧约束。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
