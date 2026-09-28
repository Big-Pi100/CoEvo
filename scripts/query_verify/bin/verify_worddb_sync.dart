// CoEvo · `word.db` 交付物一致性验收
//
// 跑法：cd scripts/query_verify && dart run bin/verify_worddb_sync.dart
// 退出码：0 = 一致；1 = 不一致（或缺失）
//
// # 为什么需要
// `word.db` 在仓库里有**两份**，它们必须永远相同：
//
// ```
// data/word.db          ← 唯一的「源」（词库产出脚本写这里）
// app/assets/word.db    ← 交付物（打包进 App 的那份）
// ```
//
// 🔑 为什么允许两份（而不是构建时复制）：
//   `git` 按**内容哈希**存 blob → 两份内容相同时**复用同一个 blob**，`.git` **不翻倍**
//   （实测：`git add` 第二份后松散对象 113 → 113，`.git` 仍 87 MB）。
//   于是「两份都进 git」换来「clone 即完整、CI 不需要任何前置复制步骤」。
//
// 🔴 代价就是**漂移风险** —— 只更新一份就会分叉，而**分叉后 App 用的是旧词库且不报错**。
//   这类失败**没有任何运行时症状**（App 照常启动、查词照样返回，只是数据旧）。
//   → 本脚本就是这条风险的唯一守卫。**改词库后必须跑它。**
//
// # 为什么用「逐字节比较」而不是「文件大小 + md5」
//   · 大小相同 ≠ 内容相同（SQLite 页面重排后可能等长）
//   · Dart 无内置 md5，引 `crypto` 只为算摘要不值当
//   · 逐字节能**报出第一处不同的字节偏移** → 定位比「摘要不同」有用得多（33 MB 约 0.2 s）

import 'dart:io';

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String _repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${d.path}/app').existsSync() &&
        File('${d.path}/app/pubspec.yaml').existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// 返回**第一处**不同的字节偏移；完全相同返回 null。
Future<int?> _firstDiff(File a, File b, int size) async {
  final ra = await a.open();
  final rb = await b.open();
  try {
    const chunk = 1 << 20; // 1 MB
    var off = 0;
    while (off < size) {
      final n = (size - off) < chunk ? (size - off) : chunk;
      final ba = await ra.read(n);
      final bb = await rb.read(n);
      for (var i = 0; i < n; i++) {
        if (ba[i] != bb[i]) return off + i;
      }
      off += n;
    }
    return null;
  } finally {
    await ra.close();
    await rb.close();
  }
}

Future<void> main() async {
  final root = _repoRoot();
  print('═' * 72);
  print('CoEvo word.db 交付物一致性验收');
  print('  repo: $root');
  print('═' * 72);

  const srcRel = 'data/word.db'; // 源
  const dstRel = 'app/assets/word.db'; // 交付物
  final src = File('$root/$srcRel');
  final dst = File('$root/$dstRel');

  print('\n【1】两份都存在');
  final srcOk = src.existsSync();
  final dstOk = dst.existsSync();
  check('源 $srcRel 存在', srcOk);
  check('交付物 $dstRel 存在', dstOk,
      dstOk ? '' : '→ 修：cp $srcRel $dstRel');
  if (!srcOk || !dstOk) {
    print('\n${'═' * 72}');
    print('通过 $_pass 项，失败 ${_failures.length} 项');
    print('🔴 缺文件，后续断言跳过（比较无从谈起）');
    print('═' * 72);
    exit(1);
  }

  print('\n【2】大小');
  final sa = src.lengthSync();
  final sb = dst.lengthSync();
  check('大小一致', sa == sb, '源 ${_mb(sa)} / 交付物 ${_mb(sb)}');
  check('大小非 0', sa > 0, _mb(sa));
  // 词库的合理量级（防「复制到一半」或「复制了空文件」）
  check('大小在合理区间（>20 MB）', sa > 20 * 1024 * 1024, _mb(sa));

  print('\n【3】逐字节一致');
  if (sa == sb) {
    final diff = await _firstDiff(src, dst, sa);
    check('内容逐字节相同', diff == null,
        diff == null ? '${_mb(sa)} 全同' : '第一处不同在偏移 $diff');
  } else {
    check('内容逐字节相同', false, '大小已不同，无需逐字节');
  }

  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    print('\n修法：cp data/word.db app/assets/word.db');
  }
  print('═' * 72);
  if (_failures.isEmpty) {
    print('\n✅ 两份一致 —— App 打包的那份与词库源同步');
  }
  exit(_failures.isEmpty ? 0 : 1);
}
