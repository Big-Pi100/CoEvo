// 本机可用的 Dart 验证工具 —— 用 `package:analyzer` 在**单进程内**做 resolution 检查
//
// # 🔴 为什么需要它
//
// 本机 `flutter` / `dart analyze` **必崩**：
//     CreateFile failed 231 (所有的管道范例都在使用中)
//     ProcessException: ... (at ../../runtime/bin/process_win.cc:742)
// → 根因是**无法创建子进程**（管道耗尽，环境级限制）。
//   `flutter` 与 `dart analyze` 都要拉子进程（dartdev → analysis_server）→ 必崩。
//
// 但 **`flutter` 自带的 `dart` 二进制可以直接跑脚本**（不拉子进程）：
//     D:\flutter\bin\cache\dart-sdk\bin\dart.exe tool/verify_resolution.dart
// 而 `package:analyzer` 是**纯 Dart 库**，可在**同一进程内**完成 resolution
// → 于是绕开「无法创建子进程」的限制，拿到**编译级的 error 清单**。
//
// 🔑 价值：改完 Dart 代码**不必等别人编译**就能自查 ——
//    「删了文件/改了 import」这类破坏几乎都会以 error 形式暴露。
//
// # 用法（必须在 `app/` 目录下跑）
//
//     DART="/d/flutter/bin/cache/dart-sdk/bin/dart.exe"
//     "$DART" tool/verify_resolution.dart            # 检查 lib/
//     "$DART" tool/verify_resolution.dart lib/api    # 只检查子目录
//
// 退出码：有 error → 1；否则 0（可直接挂 CI 或脚本）。
//
// # ⚠️ 两个副作用与边界（实测）
//
// 1. **可能触发 pub get**（首次运行/依赖不一致时）→ 会改写 `pubspec.lock` 与
//    `.dart_tool/`。它们都在 `.dart_tool`（**已被 gitignore**），但 `pubspec.lock` 是被跟踪的
//    → 若发现它被改动（版本降级），用 `git checkout -- app/pubspec.lock` 还原。
//    🔴 根因：`dart` 来自 **Dart SDK 3.11**，而项目构建用的是 **Flutter 3.27.5-ohos**
//    → 两者解析出的依赖版本可能不同。
// 2. **它只做「解析/类型」层检查**，不做「完整编译」：抓不到 const 求值、tree-shaking、
//    平台通道等编译后期问题。**结论要按这个边界表述**（别说成「构建通过」）。
//
// # ⚠️ 一个**别踩的坑**：路径解析口径
//
// 用**文件系统路径**手算相对 import 会**误判**：
//    `lib/screens/x.dart` 里的 `'../../api/y.dart'`
//    · 文件路径语义 → `app/api/y.dart`（不存在 → 误报「断链」）
//    · **Dart 语义** → 基于 `package:` URI，超出包根的 `..` 被忽略 → `lib/api/y.dart`（有效）
// → **别用脚本手算 import 路径来判断断链**，交给 analyzer（它按 Dart 语义解析）。
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final target = args.isEmpty
      ? '$root${Platform.pathSeparator}lib'
      : '$root${Platform.pathSeparator}${args.first}';

  if (!Directory(target).existsSync()) {
    stderr.writeln('🔴 目标目录不存在: $target');
    exit(2);
  }

  // ⚠️ analyzer 要求「absolute **normalized** path」→ Windows 原生格式（`E:\...`），
  //    换成正斜杠会抛 Invalid argument。
  final collection = AnalysisContextCollection(includedPaths: [target]);

  var files = 0;
  var errors = 0;
  var warnings = 0;

  for (final ctx in collection.contexts) {
    for (final path in ctx.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      files++;
      final result = await ctx.currentSession.getErrors(path);
      if (result is! ErrorsResult) {
        print('🟠 无法取 errors: $path');
        continue;
      }
      for (final e in result.errors) {
        switch (e.severity.name) {
          case 'error':
            errors++;
            print('🔴 ${_rel(path, root)}:${_line(path, e.offset)}  ${e.message}');
          case 'warning':
            warnings++;
        }
      }
    }
  }

  print('====================================');
  print('文件 $files · 🔴 ERROR $errors · 🟠 WARNING $warnings');
  print(errors == 0
      ? '✅ 无 error（resolution 通过）'
      : '❌ 有 $errors 个 error');
  exit(errors == 0 ? 0 : 1);
}

String _rel(String path, String root) =>
    path.replaceAll(root, '').replaceAll(r'\', '/');

/// 由字符偏移换算行号（analyzer 5.x 的 `AnalysisError` 没有 `location` getter）。
String _line(String path, int offset) {
  try {
    final content = File(path).readAsStringSync();
    final end = offset < content.length ? offset : content.length;
    var line = 1;
    for (var i = 0; i < end; i++) {
      if (content.codeUnitAt(i) == 0x0A) line++;
    }
    return '$line';
  } catch (_) {
    return '?';
  }
}
