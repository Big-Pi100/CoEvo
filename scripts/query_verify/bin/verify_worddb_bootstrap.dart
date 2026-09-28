// CoEvo · `word.db` 落盘决策验收（**纯逻辑，不碰真库**）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_worddb_bootstrap.dart
// 退出码：0 = 全通过；1 = 有失败
//
// # 为什么值得单独验
// 落盘判断错**没有任何运行时症状**（见 `word_db_bootstrap.dart` 的类文档）：
//   · 该复制时没复制 → App 升级后**一直用旧词库**，查词结果陈旧
//   · 不该复制时复制 → 每次启动白等 ~1 s
//   · 资产异常时错误覆盖 → **用空文件盖掉好库**（最糟：不可逆）
// 而真机测这三条要「装旧版 → 升级 → 换词库」，成本高且不常做 → **换成断言**。

import 'dart:io';
import 'dart:typed_data';

import '../../../app/lib/services/word_db_bootstrap.dart';

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

void eq(String label, Object? actual, Object? expected) =>
    check(label, actual == expected,
        actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

Future<void> main() async {
  print('═' * 72);
  print('CoEvo word.db 落盘决策验收');
  print('═' * 72);

  // ═══ 【1】needsCopy —— 4 个边界 ═══
  section('【1】needsCopy（要不要复制）');
  check('目标不存在 → 复制',
      needsCopy(target: const TargetState.missing(), assetSize: 1000));
  check('大小相同 → 跳过',
      !needsCopy(target: const TargetState(exists: true, size: 1000), assetSize: 1000));
  check('大小不同 → 复制（词库更新 / App 升级）',
      needsCopy(target: const TargetState(exists: true, size: 900), assetSize: 1000));
  // 🔴 最有价值的一条：资产异常时**不覆盖**
  check('🔴 资产 0 字节 + 目标存在 → **不复制**（防「用空文件盖掉好库」）',
      !needsCopy(target: const TargetState(exists: true, size: 1000), assetSize: 0));
  check('资产 0 字节 + 目标不存在 → 复制（空库也比没有强，至少能报错）',
      needsCopy(target: const TargetState.missing(), assetSize: 0));

  // ═══ 【2】planBootstrap —— 动作分类 ═══
  section('【2】planBootstrap（给出可日志的动作）');
  eq('不存在 → created',
      planBootstrap(target: const TargetState.missing(), assetSize: 100),
      BootstrapAction.created);
  eq('大小不同 → replaced',
      planBootstrap(target: const TargetState(exists: true, size: 99), assetSize: 100),
      BootstrapAction.replaced);
  eq('大小相同 → skipped',
      planBootstrap(target: const TargetState(exists: true, size: 100), assetSize: 100),
      BootstrapAction.skipped);
  eq('资产异常 → skipped（不覆盖）',
      planBootstrap(target: const TargetState(exists: true, size: 100), assetSize: 0),
      BootstrapAction.skipped);

  // ═══ 【3】ensureWordDb —— 编排（是否真的调用了写盘）═══
  section('【3】ensureWordDb（编排：判断与写盘是否一致）');
  {
    var writeCalls = 0;
    var writtenBytes = -1;

    Future<BootstrapResult> run({required TargetState target, required int asset}) =>
        ensureWordDb(
          targetPath: '/tmp/x.db',
          readAsset: () async => _fakeBytes(asset),
          probe: () => target,
          write: (b) async {
            writeCalls++;
            writtenBytes = b.length;
          },
        );

    // 首次：必须写
    var r = await run(target: const TargetState.missing(), asset: 500);
    eq('首次（不存在）→ 写了 1 次', writeCalls, 1);
    eq('…写入字节数 = 资产大小', writtenBytes, 500);
    eq('…action = created', r.action, BootstrapAction.created);
    check('…didWrite = true', r.didWrite);

    // 第二次：同一大小 → **不该写**
    writeCalls = 0;
    r = await run(target: const TargetState(exists: true, size: 500), asset: 500);
    eq('第二次（大小相同）→ 写了 0 次', writeCalls, 0);
    check('…didWrite = false', !r.didWrite);

    // 词库更新：大小变了 → 该写
    writeCalls = 0;
    r = await run(target: const TargetState(exists: true, size: 400), asset: 500);
    eq('词库更新（大小变了）→ 写了 1 次', writeCalls, 1);
    eq('…action = replaced', r.action, BootstrapAction.replaced);

    // 🔴 资产异常：**绝不能写**（这是最重要的一条）
    writeCalls = 0;
    r = await run(target: const TargetState(exists: true, size: 500), asset: 0);
    eq('🔴 资产 0 字节 + 目标存在 → 写了 0 次（不覆盖好库）', writeCalls, 0);
    check('…didWrite = false', !r.didWrite);
  }

  // ═══ 【4】日志可读性 ═══
  section('【4】describe（日志必须能看出判断依据）');
  {
    final r = BootstrapResult(
      action: BootstrapAction.replaced,
      assetSize: 33 * 1024 * 1024,
      targetBefore: const TargetState(exists: true, size: 31 * 1024 * 1024),
    );
    final s = r.describe('/data/word.db');
    check('日志含动作', s.contains('覆盖'), s);
    check('日志含路径', s.contains('/data/word.db'));
    // ⚠️ 31 * 1024 * 1024 字节 = **31.0 MB**（不是 31.4 —— 后者是 word.db 的真实大小 32,960,512 B）
    check('日志含两侧大小（能看出为何判断不同）',
        s.contains('31.0 MB') && s.contains('33.0 MB'), s);
  }

  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
  }
  print('═' * 72);
  if (_failures.isEmpty) {
    print('\n✅ 落盘决策符合预期（含「资产异常不覆盖」这条防线）');
  }
  // 注意：本脚本**不验**「rootBundle 读得到 assets」与「写盘真的落盘」——
  // 那两条只有真机/真打包能验（见报告 §「只能真机看」）。
  print('⚠️ 本脚本不验：assets 是否真被打包、写盘是否真落盘 —— 需真机。');
  exit(_failures.isEmpty ? 0 : 1);
}

/// 造一个指定长度的假字节数组（`readAsset` 的替身）。
Future<Uint8List> _fakeBytes(int n) async => Uint8List(n);
