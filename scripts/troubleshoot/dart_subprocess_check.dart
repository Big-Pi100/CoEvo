// 🔴 最小复现：本机 Dart runtime **能否创建子进程**？
//
// # 为什么留这个脚本
//
// 2026-10-03：`flutter build apk` 崩在 `ProcessException: 231（管道忙）`，
// 而 `flutter --version` **也崩** ⇒ 一度以为是 git / flutter 版本问题。
// 用这个脚本一次判定：**Dart 连 `cmd /c echo hi` 都创建不了** ⇒
// 根因是 **Dart runtime 与当前进程环境的交互**（`process_win.cc:742`
// 走 `CreateNamedPipe`），**与项目代码、git、flutter 版本全都无关**。
//
// # 判据
//
// · 4/4 全 FAIL ⇒ **本机 Dart/Flutter 工具链不可用**（`flutter build` /
//   `flutter analyze` / `flutter test` 全部会崩，因为它们都要 spawn 子进程）
// · 但 **纯 Dart 逻辑脚本仍可跑**（`dart run xxx.dart` 本身能启动，
//   只要脚本内部不 spawn）⇒ 逻辑类断言不受影响
// · Rust / cargo **不受影响**（另一套进程模型）
//
// # 怎么办
//
// · 要出 App 包 → **在普通终端里跑**（本限制来自当前进程环境，不是系统级）
//   ```
//   cd E:\CoEvo\app
//   D:\flutter\bin\flutter.bat --no-version-check build apk --release
//   ```
// · 要跑 Dart 逻辑断言 → 可用（脚本里别 spawn 子进程）
//
// 用法：`D:\flutter\bin\cache\dart-sdk\bin\dart.exe run scripts/troubleshoot/dart_subprocess_check.dart`

import 'dart:io';

void main() {
  print('=== Dart 能否创建子进程 ===');
  var fail = 0, total = 0;

  void probe(String label, String exe, List<String> args) {
    total++;
    try {
      final r = Process.runSync(exe, args);
      final out = (r.stdout as String).trim();
      print('  $label -> exit=${r.exitCode}  $out');
    } catch (e) {
      fail++;
      print('  $label -> 🔴 FAIL: ${e.toString().split('\n').first}');
    }
  }

  probe('cmd echo    ', 'cmd', ['/c', 'echo hi']);
  probe('git --version', 'git', ['--version']);
  probe('git log -n 1', 'git', [
    '-c',
    'log.showSignature=false',
    'log',
    '-n',
    '1',
    '--pretty=format:%ar',
  ]);

  print('');
  if (fail == total) {
    print('🔴 $fail/$total 全失败 ⇒ 本机 Dart/Flutter 工具链不可用。');
    print('   flutter build / analyze / test 全部会崩（它们都要 spawn 子进程）。');
    print('   纯 Dart 逻辑脚本仍可跑；Rust/cargo 不受影响。');
    exit(1);
  } else if (fail > 0) {
    print('⚠️ $fail/$total 失败 ⇒ 不稳定，重试或换终端。');
  } else {
    print('✅ $total/$total 成功 ⇒ 工具链可用。');
  }
}
