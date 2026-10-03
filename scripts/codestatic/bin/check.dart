// 本地符号解析检查 —— 用 `package:analyzer` 做**编译级**诊断（不经 analysis_server）。
//
// # 为什么需要它（2026-10-03 的真实动机）
//
// 本机 Flutter 是鸿蒙定制版：`flutter analyze` / `dart analyze` 会崩
// （`CreateFile failed 231`，analysis_server 起不来）。
// 于是长期只能靠 `dart format --output=none` 做**语法**检查 ——
// 而**语法通过 ≠ 能编译**：
//
//   实例（本日踩到）：`kCategoryLabels` 改名后仍留在 `FeedItem` 类内，
//   调用方按「`k` 前缀 = 顶层常量」的惯例**裸写** ⇒ **符号解析不到**。
//   `dart format` 完全通过（语法没错），只有**符号解析**才报
//   "The getter 'kCategoryLabels' isn't defined"。
//
// ⇒ 本脚本直接调用 analyzer **库**，不经过 analysis_server ⇒ 不受那个崩溃影响。
//
// # 前提
// `app/.dart_tool/package_config.json` 必须存在且含 `sky_engine`
// （`dart:ui` 的来源）—— 实测本项目有 ✅
//
// 跑法：dart run bin/check.dart <被分析目录的绝对路径>

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

Future<int> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('用法: dart run bin/check.dart <被分析目录的绝对路径>');
    return 2;
  }
  // 🔴 analyzer 要求「绝对且**规范化**」的路径 —— 在 Windows 上就是要求反斜杠。
  //    `Directory().absolute.path` **不会**把 `/` 转成 `\`（实测：传
  //    `E:/CoEvo/app/lib/models` 会抛 "Only absolute normalized paths are supported"）。
  //    ⇒ 显式按平台分隔符替换。
  final root = Directory(args[0])
      .absolute
      .path
      .replaceAll('/', Platform.pathSeparator);
  if (!Directory(root).existsSync()) {
    stderr.writeln('🔴 目录不存在: $root');
    return 2;
  }

  final collection = AnalysisContextCollection(includedPaths: [root]);
  final errors = <String>[];
  final noise = <String>[];
  var scanned = 0;

  for (final ctx in collection.contexts) {
    for (final path in ctx.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart')) continue;
      scanned++;
      final r = await ctx.currentSession.getResolvedUnit(path);
      if (r is! ResolvedUnitResult) continue;
      for (final d in r.errors) {
        if (d.severity != Severity.error) continue;
        final m = d.problemMessage;
        final text = m.messageText(includeUrl: false);
        final line = '${m.filePath}:${_lineOf(m.filePath, m.offset)}  $text';
        if (_isEmbedderNoise(text)) {
          noise.add(line);
        } else {
          errors.add(line);
        }
      }
    }
  }
  collection.dispose();

  print('扫描 $scanned 个 .dart（$root）');
  print('=' * 74);
  if (noise.isNotEmpty) {
    print('⚠️ 疑似 `dart:ui` embedder 噪音 ${noise.length} 条'
        '（**不计入判定** —— 说明 analyzer 未接上 Flutter embedder）:');
    for (final n in noise.take(2)) {
      print('    · $n');
    }
    print('');
  }
  // 🔴 **必须显式设置退出码** —— Dart 的 `main` **返回值不用作进程退出码**！
  //    （2026-10-03 实测踩到：脚本**检测到了 error**、也打印了，
  //      但 `return 1` 对 shell 而言退出码仍是 **0** ⇒ **门禁完全失效**。
  //      🔑 是「用注入缺陷做证伪」时发现的 —— 若只跑一次「全绿」的用例，
  //         这个 bug 永远不会暴露。）
  //    📌 同族判据：**「输出里有 error」≠「退出码非零」** —— 判定必须落在退出码上。
  if (errors.isEmpty) {
    print('✅ **0 个 error** —— 符号解析全部通过');
    exitCode = 0;
    return 0;
  }
  print('🔴 ${errors.length} 个 error:');
  for (final e in errors) {
    print('    · $e');
  }
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
///    这说明**环境**没配好，不是代码有问题 ⇒ **如实分开**，避免噪音淹没真错误。
bool _isEmbedderNoise(String msg) =>
    msg.contains('dart:ui') ||
    msg.contains('sky_engine') ||
    msg.contains("Target of URI doesn't exist");
