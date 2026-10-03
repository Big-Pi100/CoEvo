// 本地符号解析 + lint 检查 —— 用 `package:analyzer` 做**编译级**诊断（不经 analysis_server）。
//
// # 为什么需要它（2026-10-03 的两次真实事故）
//
// 本机 Flutter 是鸿蒙定制版：`flutter analyze` / `dart analyze` 会崩
// （`CreateFile failed 231`，analysis_server 起不来）。
// 于是长期只能靠 `dart format --output=none` 做**语法**检查 ——
// **而「语法通过」≠「能编译」也≠「能过 CI」**。
//
// 事故 ①（error 级）：
//   `kCategoryLabels` 改名后仍留在 `FeedItem` 类内，而调用方按「`k` 前缀 = 顶层常量」
//   的惯例**裸写** ⇒ **符号解析不到** ⇒ `flutter build` 失败。
//   `dart format` 完全通过（语法没错）。
//
// 事故 ②（warning 级）：
//   一次改动多写了一个**未使用的 import**。CI 的判据是
//   `flutter analyze --no-fatal-infos` ⇒ **`error` 与 `warning` 都致命，`info` 不致命**。
//   本工具**当时只过滤 `Severity.error`** ⇒ 漏掉那条 warning ⇒
//   本地「全绿」而 **CI 红**。
//   📌 教训：**「本地检查的判据」必须与「CI 的判据」逐条对齐** ——
//      包括「哪一档算失败」。
//
// ⇒ 本脚本直接调用 analyzer **库**，不经过 analysis_server ⇒ 不受那个崩溃影响。
//
// # 判定档位（**刻意与 CI 对齐**）
//
// | 档 | 是否判失败 | 对应 CI |
// |---|---|---|
// | `error` | ✅ | `flutter analyze` 默认致命 |
// | `warning` | ✅ | `--no-fatal-infos` **不含** warning ⇒ 仍致命 |
// | `info` (lint) | ❌（除非 `--strict`）| `--no-fatal-infos` 让 info 不致命 |
//
// 用法：
//   dart run bin/check.dart <目录绝对路径>        # error + warning 判失败（= CI 判据）
//   dart run bin/check.dart <目录> --strict       # 连 info 也判失败（更严）
//   dart run bin/check.dart <目录> --all          # 全部列出（判失败口径不变）
//
// # 前提
// `app/.dart_tool/package_config.json` 必须存在且含 `sky_engine`
// （`dart:ui` 的来源）—— 实测本项目有 ✅

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

Future<int> main(List<String> args) async {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final strict = args.contains('--strict');
  final showAll = args.contains('--all') || strict;
  if (paths.length != 1) {
    stderr.writeln('用法: dart run bin/check.dart <目录绝对路径> [--strict] [--all]');
    return 2;
  }

  // 🔴 analyzer 要求「绝对且**规范化**」的路径 —— Windows 上就是要求反斜杠。
  //    `Directory().absolute.path` **不会**把 `/` 转成 `\`（实测：传
  //    `E:/CoEvo/app/lib` 会抛 "Only absolute normalized paths are supported"）。
  final root =
      Directory(paths.first).absolute.path.replaceAll('/', Platform.pathSeparator);
  if (!Directory(root).existsSync()) {
    stderr.writeln('🔴 目录不存在: $root');
    return 2;
  }

  final collection = AnalysisContextCollection(includedPaths: [root]);
  final bySeverity = <Severity, List<String>>{
    Severity.error: [],
    Severity.warning: [],
    Severity.info: [],
  };
  final noise = <String>[];
  var scanned = 0;

  for (final ctx in collection.contexts) {
    for (final path in ctx.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      scanned++;
      final r = await ctx.currentSession.getResolvedUnit(path);
      if (r is! ResolvedUnitResult) continue;
      for (final d in r.errors) {
        final m = d.problemMessage;
        final text = '${m.filePath}:${_lineOf(m.filePath, m.offset)}  '
            '${m.messageText(includeUrl: false)}';
        if (_isEmbedderNoise(m)) {
          noise.add(text);
        } else {
          bySeverity[d.severity]!.add(text);
        }
      }
    }
  }
  collection.dispose();

  print('扫描 $scanned 个 .dart（$root）');
  print('=' * 78);
  if (noise.isNotEmpty) {
    print('⚠️ 疑似 `dart:ui` embedder 噪音 ${noise.length} 条（**不计入判定**）:');
    for (final n in noise.take(2)) {
      print('    · $n');
    }
    print('');
  }

  final errors = bySeverity[Severity.error]!;
  final warnings = bySeverity[Severity.warning]!;
  final infos = bySeverity[Severity.info]!;

  void dump(String label, List<String> items, {required bool listed}) {
    if (items.isEmpty) return;
    print('$label ${items.length} 条${listed ? '' : '（未列出，用 --all 看）'}:');
    if (listed) {
      for (final s in items.take(40)) {
        print('    · $s');
      }
      if (items.length > 40) print('    … 还有 ${items.length - 40} 条');
    }
    print('');
  }

  dump('🔴 error', errors, listed: true);
  dump('🟠 warning', warnings, listed: true);
  dump('ℹ️ info', infos, listed: showAll);

  print('=' * 78);
  print('error ${errors.length} · warning ${warnings.length} · info ${infos.length}');
  print('判定口径: error + warning 判失败'
      '${strict ? " + info（--strict）" : "（info 不判失败 —— 与 CI 的 --no-fatal-infos 一致）"}');

  // 🔴 **必须显式设置退出码** —— Dart 的 `main` **返回值不用作进程退出码**！
  //    （2026-10-03 实测踩到：脚本**检测到了 error**、也打印了，
  //      但 `return 1` 对 shell 而言退出码仍是 **0** ⇒ **门禁完全失效**。
  //      🔑 是「用注入缺陷做证伪」时发现的 —— 只跑一次「全绿」的用例，
  //         这个 bug 永远不会暴露。）
  //    📌 同族判据：**「输出里有 error」≠「退出码非零」** —— 判定必须落在退出码上。
  final failed =
      errors.isNotEmpty || warnings.isNotEmpty || (strict && infos.isNotEmpty);
  if (!failed) {
    print('✅ 通过（口径内 0 条）');
    exitCode = 0;
    return 0;
  }
  print('🔴 不通过 —— 退出码 1');
  exitCode = 1;
  return 1;
}

/// `offset` → 行号（1 基）。读源文件数换行 —— 为此不值得引入 `Source` 的 API。
int _lineOf(String filePath, int offset) {
  try {
    final bytes = File(filePath).readAsBytesSync();
    final end = offset < bytes.length ? offset : bytes.length;
    var line = 1;
    for (var i = 0; i < end; i++) {
      if (bytes[i] == 0x0A) line++;
    }
    return line;
  } catch (_) {
    return 0;
  }
}

/// 是否是「analyzer 没接上 Flutter embedder」造成的噪音。
///
/// ⚠️ 特征：提到 `dart:ui` / `sky_engine` / URI 不存在。
///    这说明**环境**没配好，不是代码有问题 ⇒ **如实分开**，避免噪音淹没真问题。
bool _isEmbedderNoise(DiagnosticMessage m) {
  final t = m.messageText(includeUrl: false);
  return t.contains('dart:ui') ||
      t.contains('sky_engine') ||
      t.contains("Target of URI doesn't exist");
}
