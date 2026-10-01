// 探针：本机 Dart 能否**创建子进程**？
//
// 🔴 为什么需要这个测
//   本机 `flutter analyze` / `dart analyze` 会崩，报：
//       CreateFile failed 231 (所有的管道范例都在使用中)
//       ProcessException: ... (at ../../runtime/bin/process_win.cc:742)
//   → 根因是**无法创建子进程**。
//
//   如果这是**系统级**限制 → 换任何 Flutter/Dart 版本都没用（下载 1.8 GB 也白搭）。
//   如果只是**鸿蒙定制版工具链**的问题 → 装官方版就能解决。
//
//   两者处置完全不同 ⇒ **先测，别猜**。
//
// ⚠️ 写法注意：早期版本用了 `sleep()` 轮询 —— 那是**同步阻塞**（会卡死事件循环），
//    导致 `Process.run` 的 future 永远不完成 → 假「超时」。
//    ✅ 正确做法：`async main` + `await`（下面就是）。
//
// 跑法（用项目自己的 dart-sdk）：
//   /d/flutter/bin/cache/dart-sdk/bin/dart.exe probe_spawn.dart

import 'dart:io';

var ok = 0;
var fail = 0;

Future<void> attempt(String label, Future<ProcessResult> Function() run) async {
  try {
    final res = await run().timeout(const Duration(seconds: 20));
    final out = '${res.stdout}'.trim().replaceAll('\n', ' | ');
    print('  ✅ $label  → exit=${res.exitCode}  out="${out.length > 60 ? out.substring(0, 60) : out}"');
    ok++;
  } catch (e) {
    final s = '$e'.replaceAll('\n', ' ');
    print('  🔴 $label  → ${s.length > 110 ? s.substring(0, 110) : s}');
    fail++;
  }
}

Future<void> main() async {
  print('dart sdk : ${Platform.version}');
  print('pid      : $pid');
  print('');

  print('=== 逐个尝试「创建子进程」===');
  await attempt('run(cmd /c echo hi)',
      () => Process.run('cmd', ['/c', 'echo', 'hi']));
  await attempt('run(dart --version)',
      () => Process.run(Platform.resolvedExecutable, ['--version']));
  await attempt('run(git --version)',
      () => Process.run('git', ['--version']));
  await attempt('start + 管道读',
      () => Process.run('cmd', ['/c', 'echo', 'piped'], stdoutEncoding: null));

  print('');
  print('=== 结论 ===');
  if (ok > 0 && fail == 0) {
    print('  ✅ 能创建子进程 → 换官方 Flutter **很可能可行**（那 1.8 GB 值得下）');
  } else if (ok == 0) {
    print('  🔴 完全不能创建子进程 → 这是**环境/系统级**限制，');
    print('     换任何 Flutter/Dart 版本都**没用** ⇒ 别下那 1.8 GB。');
    print('     → 正路是：修系统（管道/句柄耗尽）或改用 WSL 构建。');
  } else {
    print('  🟠 部分可行（成功 $ok / 失败 $fail）→ 要看**是哪种调用**在崩。');
  }
  exit(0);
}
