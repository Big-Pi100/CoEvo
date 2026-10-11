// CoEvo · 选区手势层的**结构性不变量**
//
// 跑法：cd scripts/query_verify && dart run bin/verify_selection_gesture_structure.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（一条**运行期**契约，analyzer 完全看不见）
//
// 白哥 2026-10-11 真机：「**iOS 上长按选中、松手后两头没有手柄、无法调整**
// （安卓两头有光标可调）」。
//
// 根因**不在 Flutter**，在本项目的一行三元表达式：
//
// ```dart
// final withTap = widget.onTap == null || _selectionActive   // 🔴 旧写法
//     ? body                                                 //   ⇒ 有选区时 child 变成「裸 body」
//     : GestureDetector(...);
// ```
//
// ⇒ 选区一出现（`_selectionActive` false→true）就让 `SelectionArea` 的 child
//   **widget 类型**从 `GestureDetector` 变成 `body`
// ⇒ Flutter **卸载旧 Element 树、重建**（确定性行为）
// ⇒ `_selectionDelegate` 里的 `SelectionPoint` 指向**已 unmount 的旧 RenderObject**
// ⇒ 算不出选区几何 ⇒ `selectable_region.dart` 的 `_updateSelectionStatus` 走 else
//    分支 **`_selectionOverlay.dispose()`** ⇒ **手柄被销毁**。
//
// ⚠️ 为什么只在 iOS 暴露（Flutter 的平台时机差）：
//    · `selectable_region.dart:1000` —— **iOS 在「长按一开始」就 `_showHandles()`**
//    · `selectable_region.dart:1020` —— **Android 在「长按结束」再显示一次**（= 兜底）
//    ⇒ Android 每次松手都把手柄找回来，iOS **丢了就再也回不来**。
// ⚠️ 菜单却还在：`_showToolbar`（`:1366`）发现 overlay 为 `null` 会**重建**它
//    ⇒ 症状正是「**能点划线，但两头没光标**」。
//
// 🔑 结论（本条不变量）：**`SelectionArea` 的 child 结构不得依赖选区状态。**
//    要「让出单击」，只能切 `onTap` 是否为 `null`（Flutter 在 `onTap == null` 时
//    **不注册** `TapGestureRecognizer`）—— 这就是原注释里那条判据的正确形态：
//    「**要让出事件，只能不注册识别器**」。
//
// # 🔴 本脚本自身的证伪方式（改断言后必须跑一次）
//
// 把 `build` 里的
//   `GestureDetector(onTap: _selectionActive ? null : widget.onTap, ...)`
// 改回
//   `widget.onTap == null || _selectionActive ? body : GestureDetector(onTap: widget.onTap, ...)`
// ⇒ ①-1 / ①-2 / ①-3 必须**同时变红**（且只红这几项）。
//
// # ⚠️ 能力边界（如实标注）
//
// · 只做**词法级**扫描（剥注释 + 正则）⇒ 能锁「结构不依赖选区状态」，
//   **不能**替代真机 —— 「iOS 上手柄真的出现了、能拖动调整」仍属**真机范畴**
//   （本机无 iOS 环境；而这条 bug **只在 iOS 暴露**，Android 有兜底）。
// · 因此本脚本是**防复发**，不是**证真**。真机判据见 `docs/review/ios-selection-handles-vanish-2026-10-11.md` §四。

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
/// 🔑 **必须剥**：本次改动在注释里**大量提到** `_selectionActive` 与 `GestureDetector`
///    —— 不剥就会把解释文字当成实现（本项目已踩过：注释里的提及**既会假绿也会假红**）。
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

/// 从 [anchor] 出现处取到**第一个 `;`**（含）—— 本项目这几条语句里没有嵌套 `;`。
String? stmtAt(String src, String anchor) {
  final at = src.indexOf(anchor);
  if (at < 0) return null;
  final end = src.indexOf(';', at);
  if (end < 0) return null;
  return src.substring(at, end + 1);
}

void main() {
  final file = repoPath('app/lib/widgets/word_lookup_selection.dart');
  final src = stripComments(File(file).readAsStringSync());

  // ────────────────────────────────────────────────────────────────
  print('① `withTap` 的 widget 类型**不得随选区状态变化**（= iOS 手柄消失的成因）');

  final withTap = stmtAt(src, 'final withTap =');
  check('①-0 找得到 `withTap` 的赋值语句', withTap != null,
      '扫不到 ⇒ 后面的「全过」是空过（先证检测器有效：2026-10-11 前它叫别的名字？）');

  if (withTap != null) {
    check('①-1 切片有效（含完整三元与构造）',
        withTap.length > 120 && withTap.contains('GestureDetector('),
        '切片长 ${withTap.length}');

    // 🔴 核心判据：**三元的条件部分**不得含选区状态。
    //    条件段 = 从 `final withTap =` 到**第一个 `?`**。
    //    ✅ 新写法：第一个 `?` 属于 `widget.onTap == null ? body : ...`
    //    ❌ 旧写法：`widget.onTap == null || _selectionActive ? ...` ⇒ 条件段里出现它
    final q = withTap.indexOf('?');
    final cond = q < 0 ? withTap : withTap.substring(0, q);
    check(
        '🔴 ①-2 三元的**条件**里不含选区状态 —— 即「**child 类型恒定**、只切 `onTap` 参数」',
        !cond.contains('_selectionActive'),
        '条件段：`${cond.trim()}` —— 若这里出现 `_selectionActive`，'
            '选区一变就会**重建选区子树** ⇒ 手柄 overlay 被 dispose');

    check('🔴 ①-3 「让出单击」靠 `onTap: null`（不注册识别器），而不是短路掉整个 widget',
        withTap.contains('onTap: _selectionActive ? null : widget.onTap'),
        '原判据：「要让出事件，只能不注册识别器」—— 这里是它的正确形态');

    check('①-4 `GestureDetector(` 在该语句里只有**一处**构造（两个分支各写一个同样是错的）',
        countOf(withTap, 'GestureDetector(') == 1,
        '实际 ${countOf(withTap, 'GestureDetector(')} 处');

    check('①-5 🔴 反向：旧的短路反模式 `|| _selectionActive` **不得再出现**',
        !withTap.contains('|| _selectionActive'),
        '这正是 2026-10-11 那次的写法（iOS 手柄消失的直接成因）');
  }

  // ────────────────────────────────────────────────────────────────
  print('');
  print('② `withTap` 必须仍然挂在 `SelectionArea` 的 `child:` 上（内层，才能先赢竞技场）');

  check('②-1 `child: withTap` 存在',
      src.contains('child: withTap') || src.contains('child: withTap,'),
      '结构若变了，[onTap] 的「内层先加入竞技场」那段说明也要一并重写');
  check('②-2 `SelectionArea(` 全文件只构造 1 处',
      countOf(src, 'SelectionArea(') == 1,
      '实际 ${countOf(src, 'SelectionArea(')} 处');

  // ────────────────────────────────────────────────────────────────
  print('');
  print('③ 全项目：凡用了 `SelectionArea` 的文件，都不得让 child 依赖「选区状态」');

  // ⚠️ 这是**通用版**的同一判据 —— 上面 ① 只锁了 `withTap` 这个具体名字；
  //    若将来别处又写一个 `_xxxActive ? a : b` 放进 `SelectionArea(child:)`，
  //    ① 是**看不见**的。
  final suspects = <String>[];
  var scanned = 0;
  for (final f in Directory(repoPath('app/lib'))
      .listSync(recursive: true)
      .whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final s = stripComments(f.readAsStringSync());
    if (!s.contains('SelectionArea(')) continue;
    scanned++;
    // 找 `SelectionArea(` 之后最近的 `child:`（本项目的写法是 `child: xxx,` 或 `child: xxx)`）
    final at = s.indexOf('SelectionArea(');
    final tail = s.substring(at);
    final ci = tail.indexOf('child:');
    if (ci < 0) continue;
    // ⚠️ 切片要夹紧到字符串长度 —— 本项目已踩过「切片越界」这类崩（第三批的
    //    `RangeError`）。⚠️ 不用 `clamp()`：它返回 `num`，还得再转一次。
    final end = ci + 220 < tail.length ? ci + 220 : tail.length;
    final childExpr = tail.substring(ci, end);
    // 只查**该表达式内**是否用「三元 + 选区字样」决定 child
    if (RegExp(r'\?').hasMatch(childExpr) &&
        RegExp(r'[Ss]election').hasMatch(childExpr)) {
      suspects.add('${f.path.split(RegExp(r'[/\\]')).last}: ${childExpr.split('\n').first.trim()}');
    }
  }
  check('③-0 至少扫到一个用 `SelectionArea` 的文件（阴性对照）', scanned > 0,
      '一个都没扫到 ⇒ 扫描口径已失效（改名/换 API 了？）');
  check('③-1 没有任何文件用「三元 + 选区状态」决定 `SelectionArea` 的 child',
      suspects.isEmpty, suspects.join(' | '));

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
    print('🔑 最可能的原因：`SelectionArea` 的 child 结构随选区状态变了。');
    print('    analyzer 不会报，**iOS 真机表现是「松手后手柄消失、无法两头调整」**');
    print('    （Android 因为「长按结束再显示一次」而有兜底，看不出来）。');
    print('    正解：child 恒定，只切 `onTap` 是否为 `null`。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
