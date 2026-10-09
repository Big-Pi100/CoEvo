/// A3 · 制卡回流 CLI —— 把导出 JSON 写进 `word.db` 的 `word` + `card` 两表。
///
/// # 用法
/// ```bash
/// # ① 先拷副本干跑（默认就是干跑，不会写任何东西）
/// cp data/word.db /tmp/word_copy.db
/// dart run bin/reflow_into_word_db.dart /tmp/reflow_candidates.json --db /tmp/word_copy.db
///
/// # ② 确认无误后真写副本
/// dart run bin/reflow_into_word_db.dart /tmp/c.json --db /tmp/word_copy.db --write
///
/// # ③ 最后才写源库（需要两道闸：--write + --allow-source）
/// dart run bin/reflow_into_word_db.dart /tmp/c.json --db data/word.db --write --allow-source
/// ```
///
/// # 🔴 两道安全闸（都是**故意**加的）
/// | 闸 | 作用 |
/// |---|---|
/// | 默认 **dry-run** | 不加 `--write` 就只打印「会插入什么」，**不碰库** |
/// | 默认**拒写源库** | 目标路径是 `data/word.db` 时必须再加 `--allow-source` —— 防「手滑把源库改了」 |
///
/// 理由：本脚本是**唯一**会往 `word.db` 插行的东西，而 `word.db` 是**打包进 App 的交付物**
/// （`app/assets/word.db` 由 `sync_word_db_asset.py` 从源同步）。误写一次就得重来。
///
/// # ⚠️ 本脚本**不做**的事
/// · **不同步 `app/assets/word.db`** —— 那是 `scripts/sync_word_db_asset.py` 的职责
/// · **不生成版本指纹** —— 那是 `scripts/gen_word_db_version.py` 的职责
/// （🔑 顺序：本脚本 → `gen_word_db_version.py` → `sync_word_db_asset.py`。
///   漏掉后两者 ⇒ 端侧**静默不更新**词库。）
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/reflow.dart';

Future<int> main(List<String> argv) async {
  // ── 解析参数（手写：本子项目不引 `args` 包，少一个依赖）──
  final positional = <String>[];
  var write = false;
  var allowSource = false;
  String? dbOverride;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--write') {
      write = true;
    } else if (a == '--dry-run') {
      write = false;
    } else if (a == '--allow-source') {
      allowSource = true;
    } else if (a == '--db') {
      if (i + 1 >= argv.length) {
        stderr.writeln('--db 后面缺路径');
        return 2;
      }
      dbOverride = argv[++i];
    } else if (a.startsWith('--db=')) {
      dbOverride = a.substring('--db='.length);
    } else if (a.startsWith('--')) {
      stderr.writeln('未知参数：$a');
      return 2;
    } else {
      positional.add(a);
    }
  }

  if (positional.isEmpty) {
    stderr.writeln('用法：dart run bin/reflow_into_word_db.dart <candidates.json> '
        '[--db <path>] [--write] [--allow-source]');
    return 2;
  }

  // ── 定位仓库根（scripts/reflow/bin/xxx.dart → 上溯 3 层）──
  final binDir = File.fromUri(Platform.script).parent; // …/scripts/reflow/bin
  final repoRoot = binDir.parent.parent.parent; // 仓库根
  final sourceDbPath = File('${repoRoot.path}/data/word.db')
      .absolute
      .uri
      .normalizePath()
      .toFilePath();

  final dbPath = dbOverride ?? 'data/word.db';
  final absDb = File(dbPath).absolute.uri.normalizePath().toFilePath();

  // ── 安全闸 2：拒写源库（除非显式 --allow-source）──
  final isSource = File(absDb).absolute.path == File(sourceDbPath).absolute.path;
  if (write && isSource && !allowSource) {
    stderr.writeln('🔴 拒绝写源库：$absDb');
    stderr.writeln('   源库是打包进 App 的交付物。请先拷副本干跑，');
    stderr.writeln('   确需写源库时再加 --allow-source。');
    return 2;
  }
  if (!File(absDb).existsSync()) {
    stderr.writeln('🔴 目标库不存在：$absDb');
    return 2;
  }

  // ── 读导出 JSON ──
  final jsonPath = positional.first;
  final f = File(jsonPath);
  if (!f.existsSync()) {
    stderr.writeln('🔴 导出文件不存在：$jsonPath');
    return 2;
  }
  final parsed = jsonDecode(await f.readAsString());
  if (parsed is! Map) {
    stderr.writeln('🔴 导出文件顶层不是对象');
    return 2;
  }
  final root = parsed.cast<String, Object?>();
  final rawList = root['candidates'];
  final candidates = <ReflowCandidate>[
    if (rawList is List)
      for (final e in rawList)
        if (e is Map) ReflowCandidate.fromJson(e.cast<String, Object?>()),
  ];

  stdout.writeln('── 输入 ──');
  stdout.writeln('  导出文件：$jsonPath');
  stdout.writeln('  导出时间：${root['exported_at']}');
  stdout.writeln('  门槛：${jsonEncode(root['threshold'])}');
  stdout.writeln('  候选数：${candidates.length}'
      '${(root['count'] as int?) == candidates.length ? '' : '（⚠️ 与 count=${root['count']} 不一致）'}');
  stdout.writeln('  目标库：$absDb${isSource ? '  ⚠️ 这是**源库**' : ''}');
  stdout.writeln('  模式：${write ? '写入' : '干跑（不会写任何东西）'}');
  stdout.writeln();

  // ── 跑 ──
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(absDb);
  ReflowReport report;
  try {
    report = await reflowIntoWordDb(db, candidates, dryRun: !write);
  } finally {
    await db.close();
  }

  stdout.writeln('── 结果 ──');
  stdout.write(report.summary());

  if (report.inserted.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('── 插入明细 ──');
    for (final i in report.inserted) {
      stdout.writeln('  ${i.spelling.padRight(24)} → ${i.wordId}  '
          'hash=${i.contentHash.substring(0, 8)}…  ${i.contentBytes}B  ${i.sectionCount} 段');
    }
  }

  if (report.inserted.isNotEmpty && write) {
    stdout.writeln();
    stdout.writeln('🔑 下一步（缺一不可，否则端侧**静默不更新**词库）：');
    stdout.writeln('   python scripts/gen_word_db_version.py        # 刷新版本指纹');
    stdout.writeln('   python scripts/sync_word_db_asset.py         # 同步到 app/assets');
  }
  return 0;
}

extension on Uri {
  /// 去掉 `..` / `.` 段（纯路径规范化，不访问文件系统）。
  Uri normalizePath() {
    final parts = <String>[];
    for (final seg in pathSegments) {
      if (seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty && parts.last != '..') {
          parts.removeLast();
        } else {
          parts.add('..');
        }
      } else {
        parts.add(seg);
      }
    }
    return replace(pathSegments: parts);
  }
}
