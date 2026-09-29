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
// # ⚠️ 副作用（实测）
//
// **可能触发 pub get**（首次运行/依赖不一致时）→ 会改写 `pubspec.lock` 与 `.dart_tool/`。
//    `pubspec.lock` **是被跟踪的** → 跑完看一眼 `git status`，被改就 `git checkout -- app/pubspec.lock` 还原。
//    🔴 根因：这个 `dart` 来自 **Dart SDK 3.11**，而项目构建用的是 **Flutter 3.27.5-ohos**
//    → 两者解析出的依赖版本可能不同（实测 `characters 1.4.1→1.3.0` 等 44 行降级）。
//    `.dart_tool/` 已被 gitignore，不用管（构建工具会自动重建）。
//
// # ⚠️ 覆盖边界（结论要按这个表述）
//
// 1. **只做「解析 / 类型」层检查**，不做「完整编译」：抓不到 const 求值、tree-shaking、
//    平台通道等编译后期问题。→ 只能说「**resolution 通过**」，**别说成「构建通过」**。
// 2. 🔴 **error 层：够用，但可能与 `flutter analyze` 不一致**（SDK 版本不同 → 宽严不同）。
//    实测对比（2026-09-29 · 本工具 analyzer **5.13** vs 项目 `flutter analyze`）：
//      · 本工具**多报** 1 个 error（`bookmark_provider.dart:124` 类型问题；
//        而 `flutter analyze` 报 **0 error**）→ 用**比项目新**的 SDK 分析可能**更严**
//        → **不要把本工具的 error 直接当结论**，要与项目权威工具交叉验证。
//      · 本工具**少报** 1 个 warning（`graph_widget.dart:851 unused_element`）。
// 3. 🔴 **warning / lint 层：规则集随版本变化，本工具不能替代 `flutter analyze`。**
//    → 定位：**本工具用于「改完立刻自查 error」；`flutter analyze` 仍是权威**（尤其 lint）。
//
// # ⚠️ 一个**别踩的坑**：路径解析口径
//
// 用**文件系统路径**手算相对 import 会**误判**：
//    `lib/screens/x.dart` 里的 `'../../api/y.dart'`
//    · 文件路径语义 → `app/api/y.dart`（不存在 → 误报「断链」）
//    · **Dart 语义** → 基于 `package:` URI，超出包根的 `..` 被忽略 → `lib/api/y.dart`（有效）
// → **别用脚本手算 import 路径来判断断链**，交给 analyzer（它按 Dart 语义解析）。
// 🔑 这两类 lint 对本文件**天然不适用**（用 `ignore_for_file` 而不是在
//    `analysis_options.yaml` 里 `exclude: tool/**`）：
//
//    · `avoid_print` —— 它就是个 print 型 CLI 工具，输出即产物。
//    · `depend_on_referenced_packages` —— 它**故意**用 app 环境的**传递依赖**
//      （`analyzer` 来自 flutter_test）：因为要靠 app 的 `.dart_tool/package_config.json`
//      解析 app 的依赖图。若改成在 `app/pubspec.yaml` 直接声明 `analyzer`，
//      就变成「为了工具给 app 加一个生产依赖」—— 更糟。
//
//    🔴 为什么**不**用 `exclude`（我第一版就是这么写的，已撤回）：
//      `exclude` 是「**不分析这个目录**」→ 它自己的真 error 也一起被藏起来；
//      而且会让 `dart tool/verify_resolution.dart tool`（**用它自己检查自己**）
//      返回「文件 0」→ **自验能力被自己破坏**。
//      `ignore_for_file` 只豁免列出的规则，**真 error 照报** → 噪音没了、安全网还在。
//      🔑 判据：**要消除噪音，优先「豁免具体规则」而不是「排除整个文件」**。
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;

  // ⚠️ 必须**归一化分隔符**：analyzer 要求「absolute normalized path」，
  //    混用 `\` 与 `/`（如 `E:\app\lib/tmp_x`）会抛
  //    `Only absolute normalized paths are supported`。
  //    🔑 这个 bug 是靠「用它自己跑一个子目录」的受控实验撞出来的。
  final sub = args.isEmpty
      ? 'lib'
      : args.first.replaceAll('/', Platform.pathSeparator);
  final target = args.isEmpty
      ? '$root${Platform.pathSeparator}$sub'
      : // 允许绝对路径直接传入
        (sub.startsWith(Platform.pathSeparator) || sub.contains(':')
            ? sub
            : '$root${Platform.pathSeparator}$sub');

  // 支持「目录」（分析整棵）与「单个文件」（只分析它）
  final kind = FileSystemEntity.typeSync(target);
  if (kind == FileSystemEntityType.notFound) {
    stderr.writeln('🔴 目标不存在: $target');
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
            // 🔑 warning 也要**打印详情**，不能只报数量：
            //    `unused_import` / `unused_local_variable` 这类 warning 是**真问题**
            //    （实测：只报数量时，我自己新引入的 `unused_local_variable` 一度被漏看）。
            print('🟠 ${_rel(path, root)}:${_line(path, e.offset)}  ${e.message}');
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
