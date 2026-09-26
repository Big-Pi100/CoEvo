// 进程内静态分析 —— 绕开 `dart analyze` 的 analysis_server 子进程
//
// 背景（2026-09-26 实测）：
//   `dart analyze` / `flutter analyze` 在架构上必须 `Process.start()` 一个
//   `analysis_server_aot.dart.snapshot` 子进程；本机当前环境下 Windows 命名管道实例耗尽
//   （`CreateFile failed 231` = ERROR_PIPE_BUSY），**任何子进程都创建不了**，
//   因此 dartdev 的 analyze 命令必然失败 —— 与 Flutter 是官方版还是鸿蒙定制版无关
//   （标准版 Dart 3.11.0 与鸿蒙版 Dart 3.6.2 崩在同一行 `AnalysisServer._startProcess`）。
//
//   但 `dart run <脚本>` 是**同进程**执行，可以正常工作 → 于是把分析器跑在本进程内。
//
// 用法：
//   dart run bin/analyze.dart <文件或目录>...
//   退出码 0 = 无 error；1 = 有 error；2 = 用法错误

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/physical_file_system.dart';

/// web-only 库 —— 原生（iOS/Android）平台没有，import 它们 = 编不过。
///
/// analyzer 本身**不检查这个**：这些库在 Dart SDK 里是存在的（web 用），
/// 所以 `dart analyze` 只会报 `unused_import`，不会报「平台不可用」。
/// 只有 `flutter build ios` 才真正报错 —— 但那要 fork 子进程（本机做不了）。
/// → 于是把这个判据**在本脚本内自己实现**，补上本地验证的最后一块缺口。
const _kWebOnlyLibraries = {
  'dart:html',
  'dart:js',
  'dart:js_util',
  'dart:js_interop', // ⚠️ 语义上对 native 部分可用，但本项目里出现即为 web 遗留
  'dart:indexed_db',
  'dart:svg',
  'dart:web_audio',
  'dart:web_gl',
  'dart:web_sql',
  'dart:ui_web',
};

Future<void> main(List<String> args) async {
  final inputs = args.where((a) => !a.startsWith('--')).toList();
  final onlyErrors = args.contains('--errors-only');
  final quiet = args.contains('--quiet');
  final webCheck = !args.contains('--no-web-check');

  if (inputs.isEmpty) {
    stderr.writeln('用法: dart run bin/analyze.dart <文件或目录>... [--errors-only] [--quiet]');
    exit(2);
  }

  final paths = <String>[];
  for (final p in inputs) {
    final f = FileSystemEntity.typeSync(p);
    if (f == FileSystemEntityType.notFound) {
      stderr.writeln('路径不存在: $p');
      exit(2);
    }
    final abs = File(p).absolute.path;
    // analyzer 要求平台规范化的绝对路径（Windows 下必须是 `E:\a\b` 而非 `E:/a/b`）
    paths.add(Platform.isWindows ? abs.replaceAll('/', r'\') : abs);
  }

  final sw = Stopwatch()..start();
  final collection = AnalysisContextCollection(
    includedPaths: paths,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );

  var nErr = 0, nWarn = 0, nInfo = 0, nFiles = 0, nSkipped = 0;
  final lines = <String>[];

  for (final ctx in collection.contexts) {
    for (final path in ctx.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      nFiles++;
      final r = await ctx.currentSession.getResolvedUnit(path);
      if (r is! ResolvedUnitResult) {
        nSkipped++;
        continue;
      }
      // ── 平台可用性检查（analyzer 不做，本脚本自己做）──────────────
      if (webCheck) {
        for (final directive in r.unit.directives) {
          if (directive is! ImportDirective) continue;
          final uri = directive.uri.stringValue;
          if (uri == null || !_kWebOnlyLibraries.contains(uri)) continue;
          nErr++;
          final loc = r.lineInfo.getLocation(directive.offset);
          lines.add('ERROR   ${'web_only_library'.padRight(40)} '
              '${_rel(path)}:${loc.lineNumber}:${loc.columnNumber}  '
              '`$uri` 原生平台不可用（web-only）→ iOS/Android 编不过');
        }
      }

      for (final d in r.errors) {
        final sev = d.severity;
        if (sev == Severity.error) {
          nErr++;
        } else if (sev == Severity.warning) {
          nWarn++;
        } else {
          nInfo++;
          if (onlyErrors) continue;
        }
        final loc = r.lineInfo.getLocation(d.offset);
        final rel = _rel(path);
        lines.add('${sev.name.toUpperCase().padRight(7)} '
            '${d.diagnosticCode.name.padRight(40)} '
            '$rel:${loc.lineNumber}:${loc.columnNumber}  ${d.message}');
      }
    }
  }

  sw.stop();
  lines.sort();
  for (final l in lines) {
    print(l);
  }

  if (!quiet) {
    print('');
    print('分析文件 $nFiles 个'
        '${nSkipped > 0 ? "（$nSkipped 个未解析成功）" : ""}'
        ' · 耗时 ${sw.elapsedMilliseconds} ms');
    print('error=$nErr  warning=$nWarn  info=$nInfo');
  }

  exit(nErr > 0 ? 1 : 0);
}

String _rel(String path) {
  final cwd = Directory.current.path;
  final p = path.replaceAll(r'\', '/');
  final c = cwd.replaceAll(r'\', '/');
  return p.startsWith('$c/') ? p.substring(c.length + 1) : p;
}
