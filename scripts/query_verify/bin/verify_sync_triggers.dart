// CoEvo · 同步**触发时机**的结构契约
//   ① 「本地数据变更」钩子：零 import 的中立文件（避免循环依赖）
//   ② 两个 revision 的 `bump()` **都**接上钩子（= 覆盖全部写操作）
//   ③ 🔴 反向：`SettingsRevision` **不得**接（接上就是「同步→bump→同步」回环）
//   ④ `scheduleSyncAfterChange` 的**防回环闸门**（`_syncDepth`）
//   ⑤ 钩子在 `registerAppSyncRef` 里注入
//
// 跑法：cd scripts/query_verify && dart run bin/verify_sync_triggers.dart
// 🔴 退出码：0 = 全过，1 = 有失败
//
// # 为什么需要它（白哥 2026-10-11 问「同步的时机是什么时候」时暴露的缺口）
//
// 此前全仓**只有复习提交**调了 `scheduleSyncAfterChange()`
// （`review_session_screen.dart:188`，唯一调用点）⇒
// **划线 / 写笔记 / 批量补译 / 查词入生词本 / 阅读进度 / 收藏 / 电子书**
// 这些本地写操作**都不会**自动上云，只能等「进后台 / 回前台 / 手动点云朵」。
// ⇒ 单设备用户「改了却一直没上云」。
//
// ✅ 修法：把钩子挂在 `bump()` 这**一处**（所有写端都必须 bump 才能刷新界面）
//    ⇒ 覆盖全部写操作。📌 判据：**「一处覆盖全部」胜过「每个调用点各加一行」**
//    —— 后者必然漏一个（本缺口正是这么来的）。
//
// ⚠️ 本脚本只做**词法级**扫描；两端真实同步行为属真机范畴（本机跑不了 Flutter 运行时）。

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

/// 剥注释：整行 `//` 去掉；行尾 `//` 在「前面没有引号」时截断。
///
/// 🔑 **必须剥**：本次改动的注释里**大量提到** `onLocalDataChanged` / `_syncDepth`
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

/// 取 `[start, end)`（找不到任一端 ⇒ 空串，由调用方的「切片有效」断言兜住）。
String between(String src, String startAnchor, String endAnchor) {
  final a = src.indexOf(startAnchor);
  if (a < 0) return '';
  final b = src.indexOf(endAnchor, a + startAnchor.length);
  if (b < 0) return '';
  return src.substring(a, b);
}

/// 取**函数体**（含大括号）—— 比 `between` 可靠得多。
///
/// 🔴 为什么不能用 `between(sig, '\n  }')` 之类：
///    · 方法头 `  }) async {` **本身就含 `\n  }`** ⇒ 切片会在参数表处截断（本项目已踩过）；
///    · 命名参数块 `({required a, required b})` 里也有 `{` ⇒
///      若直接找 signature 之后的第一个 `{`，配对出来的只是**参数块**（本人第一版就踩了）。
/// ⇒ 这里先定位 `) async {` / `) {`，再从那个 `{` 起配对。
String bodyOf(String src, String sig) {
  final at = src.indexOf(sig);
  if (at < 0) return '';
  final a1 = src.indexOf(') async {', at);
  final a2 = src.indexOf(') {', at);
  var open = -1;
  if (a1 >= 0 && a2 >= 0) {
    open = a1 < a2 ? a1 : a2;
  } else {
    open = a1 >= 0 ? a1 : a2;
  }
  if (open < 0) return '';
  open = src.indexOf('{', open);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  return '';
}

void main() {
  // ────────────────────────────────────────────────────────────────
  print('① 「本地变更钩子」文件本身（纯 Dart · 零 import ⇒ 才不会形成循环依赖）');

  final hookRaw =
      File(repoPath('app/lib/providers/local_change_hook.dart')).readAsStringSync();
  final hook = stripComments(hookRaw);

  final importLines = hook
      .split('\n')
      .where((l) =>
          l.trimLeft().startsWith('import ') || l.trimLeft().startsWith('export '))
      .toList();
  check('①-0 钩子文件**零 import**（它就是靠这个被三方安全共用）',
      importLines.isEmpty, '实得：${importLines.join(' | ')}');
  check(
      '①-1 只有**一个**可变钩子（多个 = 注入点分散，迟早漏一个）',
      RegExp(r'void Function\(\)\? onLocalDataChanged;').allMatches(hook).length == 1);

  // ────────────────────────────────────────────────────────────────
  print('');
  print('② 两个 revision 的 `bump()` 都接上钩子（= 覆盖全部本地写操作）');

  final userDb = stripComments(
      File(repoPath('app/lib/providers/user_db_provider.dart')).readAsStringSync());
  final book = stripComments(
      File(repoPath('app/lib/providers/book_provider.dart')).readAsStringSync());

  final userRev =
      between(userDb, 'class UserDbRevision', 'final userDbRevisionProvider');
  check('②-0 `UserDbRevision` 类切片有效',
      userRev.length > 100 && userRev.contains('void bump()'), '切片长 ${userRev.length}');
  check(
      '🔴 ②-1 `UserDbRevision.bump()` 调 `onLocalDataChanged?.call()`'
          '（漏 ⇒ 划线/笔记/补译/查词/阅读/收藏 都不会自动上云）',
      userRev.contains('onLocalDataChanged?.call()'));

  final bookRev = between(book, 'class BookDbRevision', 'final bookDbRevisionProvider');
  check('②-2 `BookDbRevision` 类切片有效',
      bookRev.length > 100 && bookRev.contains('void bump()'), '切片长 ${bookRev.length}');
  check('🔴 ②-3 `BookDbRevision.bump()` 也调了（电子书/书架写操作同样要上云）',
      bookRev.contains('onLocalDataChanged?.call()'));

  // ────────────────────────────────────────────────────────────────
  print('');
  print('③ 🔴 反向：`SettingsRevision` **不得**接钩子（接上 = 同步→bump→同步 回环）');

  final settingsRev =
      between(userDb, 'class SettingsRevision', 'final settingsRevisionProvider');
  check('③-0 `SettingsRevision` 类切片有效', settingsRev.length > 100,
      '切片长 ${settingsRev.length}');
  check(
      '🔴 ③-1 它**没有**调钩子 —— 它按设计只服务「同步 pull 写回 prefs」那一条路径，'
          '接上会立刻形成回环',
      !settingsRev.contains('onLocalDataChanged'));

  // ────────────────────────────────────────────────────────────────
  print('');
  print('④ `scheduleSyncAfterChange` 的**防回环闸门**');

  final sync = stripComments(
      File(repoPath('app/lib/providers/sync_provider.dart')).readAsStringSync());

  check('④-0 `int _syncDepth = 0;` 存在（用计数而非 bool：并发同步会用 bool 互相复位）',
      RegExp(r'int _syncDepth = 0;').hasMatch(sync));

  final sched = bodyOf(sync, 'void scheduleSyncAfterChange()');
  check('④-1 `scheduleSyncAfterChange` 切片有效',
      sched.length > 200 && sched.contains('_changeSyncTimer'), '切片长 ${sched.length}');
  check(
      '🔴 ④-2 函数体里有 `if (_syncDepth > 0) return;`'
          '（没有它 ⇒ pull→bump→再同步 **每 4 秒一次请求，永不停**）',
      sched.contains('if (_syncDepth > 0) return;'));

  final runBody = bodyOf(sync, 'Future<void> _runSync(');
  check('④-3 `_runSync` 函数体切片有效',
      runBody.length > 500 && runBody.contains('status.begin()'),
      '切片长 ${runBody.length}');
  check('🔴 ④-4 同步开始时 `_syncDepth++`', runBody.contains('_syncDepth++'));
  check(
      '🔴 ④-5 **用 `finally` 配对** `_syncDepth--` —— '
          '`_runSync` 里有提前 return（未登录/库不可用），只在末尾 `--` 会让计数只增不减 '
          '⇒ 闸门永久关闭 ⇒ **同步再也不自动发生**（且界面一切正常）',
      RegExp(r'finally\s*\{[^}]*_syncDepth--').hasMatch(runBody));

  // ────────────────────────────────────────────────────────────────
  print('');
  print('⑤ 钩子注入点（`registerAppSyncRef`）');

  final reg = bodyOf(sync, 'void registerAppSyncRef(');
  check('⑤-0 `registerAppSyncRef` 切片有效', reg.length > 50, '切片长 ${reg.length}');
  check('🔴 ⑤-1 它把 `scheduleSyncAfterChange` 注入成钩子',
      reg.contains('onLocalDataChanged = scheduleSyncAfterChange;'));

  final app = stripComments(File(repoPath('app/lib/app.dart')).readAsStringSync());
  check(
      '⑤-2 `app.dart` 的 `initState` 调了 `registerAppSyncRef(ref)`'
          '（不调 ⇒ 钩子恒为 null ⇒ 整套自动同步**静默失效**）',
      app.contains('registerAppSyncRef(ref)'));

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
    print('    · 某个 revision 的 `bump()` 没接钩子 ⇒ 那类写操作**不会**自动上云；');
    print('    · 或 `_syncDepth` 的闸门/配对被改动 ⇒ 要么回环刷请求，要么闸门永久关闭。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
