/// 对 `app/lib` 做**语义级**静态分析 —— 只关心 `error`（编译期真错）。
///
/// # 🔴 为什么需要它（2026-09-28 白哥构建失败后补）
/// 我这边的环境**跑不了 `flutter analyze` / `dart analyze`**
/// （`CreateFile failed 231`：Dart 进程 spawn 子进程时 `CreateNamedPipe` 失败），
/// 于是长期用 `dart format --output=none` 冒充「编译检查」。
/// **但 `dart format` 只做语法解析，不做名字解析** ——
/// 「未定义的 getter / 类 / 方法」这类**语义错误它完全看不见**。
///
/// 实例（2026-09-28）：`aggregate_page_screen.dart` 里实例方法用了 `context`：
/// ```dart
/// Widget _topBar(CoEvoTokens t) { ... context.pop() ... }   // 🔴 context 未定义
/// ```
/// `dart format` **通过**（语法完全正确）→ 错误留到白哥跑 `flutter build` 才暴露。
/// 🔑 结论：**「语法通过」≠「能编译」** —— 两者的检查强度差一个数量级。
///
/// # 🔑 为什么 analyzer 包能跑（而 `dart analyze` 不能）
/// `package:analyzer` 是**纯 Dart 包** —— 用 `dart run` 直接跑，
/// **不 spawn 额外的分析进程**（那正是崩溃的环节）。
/// 它借 `app/.dart_tool/package_config.json` 解析 `package:flutter/...`，
/// 所以能真正分析 Flutter 代码。
///
/// # ⚠️ 本脚本只判 `error`，不判 `warning` / `info`
/// 与项目既定判据一致：**`error` = 已知故障，必须为 0**；
/// `warning`/`info`（含全部 lint 规则）= 噪音，不作为门槛
/// （`analysis_options.yaml` 里的 lints 也是这个级别）。
///
/// 用法：`dart run bin/check.dart`（须用 `D:\flutter\bin\dart.bat` 全路径 ——
/// PATH 里的 `dart` 是鸿蒙版，语言上限 3.6）
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  final libDir = Directory('$root${Platform.pathSeparator}app'
      '${Platform.pathSeparator}lib');
  if (!libDir.existsSync()) {
    stderr.writeln('🔴 找不到 app/lib：${libDir.path}');
    exit(2);
  }

  // 🔑 `AnalysisContextCollection` 会在各包向上找 `.dart_tool/package_config.json`
  //    → 因此能解析 `package:flutter/...`（app 下那份 37 KB 的配置里有 182 个包）
  final collection = AnalysisContextCollection(includedPaths: [libDir.path]);

  final errors = <String>[];
  final warnings = <String>[];
  var fileCount = 0;
  var infoCount = 0;

  for (final context in collection.contexts) {
    for (final path in context.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      fileCount++;

      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) continue;

      for (final d in result.diagnostics) {
        final loc = result.lineInfo.getLocation(d.offset);
        final at = '${_rel(path, root)}:${loc.lineNumber}:${loc.columnNumber}';
        switch (d.severity) {
          case Severity.error:
            errors.add('$at  ${d.message}');
          case Severity.warning:
            warnings.add('${d.diagnosticCode.name}  $at  ${d.message}');
          case Severity.info:
            infoCount++;
        }
      }
    }
  }

  print('${'=' * 68}');
  print('静态分析（语义级）· 分析 $fileCount 个文件');
  print('${'=' * 68}');

  // ── warnings / infos 只报汇总（噪音，不作门槛）──
  //
  // ⚠️ 但 `unused_import` / `unused_element` / `unused_field` 例外 ——
  //    它们是**删代码留下的语义残留**（本项目判据：删功能要清语义残留），
  //    会随 `--verbose` 打出明细，它们是真正该修的。
  if (warnings.isNotEmpty) {
    final byCode = <String, List<String>>{};
    for (final w in warnings) {
      (byCode[w.split('  ').first] ??= []).add(w);
    }
    print('\n⚠️  warning（不阻塞，仅参考）共 ${warnings.length} 条：');
    final sorted = byCode.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final e in sorted) {
      print('      ${e.value.length.toString().padLeft(4)}  ${e.key}');
    }
    // 🔑 `unused_*` 是**删代码的残留**（不是风格噪音）→ 默认打出明细。
    //    `invalid_*` 也打出 —— 它常暗示「某处类型变了」（原来可空、现在不可空）
    //    → 虽不阻塞，但是**值得看一眼的信号**。
    final residual = warnings
        .where((w) => w.startsWith('unused_') || w.startsWith('invalid_'))
        .toList(growable: false);
    if (residual.isNotEmpty) {
      print('\n   🔴 其中「删代码残留 / 类型信号」类 ——**这些值得看**：');
      for (final r in residual) {
        print('      $r');
      }
    }
  }
  if (infoCount > 0) print('\nℹ️  info（lint 等）共 $infoCount 条');

  // ── errors = 门槛 ──
  if (errors.isEmpty) {
    print('\n✅ error = 0（编译期错误为零）');
    print('   ⚠️ 提醒：本检查**只覆盖 app/lib**；'
        '`flutter build` 还包含资源/平台配置（assets、Gradle、Info.plist 等）——');
    print('      那部分我这边仍无法验证，须由构建确认。');
    exit(0);
  }

  print('\n🔴 error 共 ${errors.length} 条（**必须为 0** —— 这些是真编译错误）：');
  for (final e in errors) {
    print('   $e');
  }
  print('\n🔑 这类错误 `dart format` **抓不到**（它只解析语法）——'
      ' 所以本脚本是「语法通过」到「能编译」之间唯一的一道防线。');
  exit(1);
}

/// 仓库根 —— 从脚本位置（`scripts/static_check/bin/`）上溯三级。
String _repoRoot() {
  var dir = Directory.current;
  // 允许从仓库根或本目录跑
  for (var i = 0; i < 4; i++) {
    if (Directory('${dir.path}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}lib')
        .existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

String _rel(String path, String root) =>
    path.startsWith(root) ? path.substring(root.length + 1) : path;
