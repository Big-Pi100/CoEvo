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

  // ═══ 【5】🆕 版本信号 —— 「大小相同但内容不同」的解药 ═══
  //
  // 🔑 本组存在的理由：只比大小的方案对**同大小不同内容**永远判 skipped
  //    → 词库不更新 + 发版收敛不执行，**且完全静默**。
  //    而回流机制上线后「词库更新」会成为常态 → 这个洞会被反复踩到。
  section('【5】版本信号（2026-10-01 新增）');
  {
    // 🔴 **本组最核心一条** —— 大小一模一样、只有版本不同
    check('🔴 大小相同但版本不同 → **必须复制**（这正是它取代「比大小」的理由）',
        needsCopy(
            target: const TargetState(exists: true, size: 1000, version: 'v1'),
            assetSize: 1000,
            assetVersion: 'v2'));
    check('版本相同 + 大小相同 → 跳过（绝大多数启动）',
        !needsCopy(
            target: const TargetState(exists: true, size: 1000, version: 'v2'),
            assetSize: 1000,
            assetVersion: 'v2'));
    check('版本相同但大小不同 → 仍复制（两信号取并集，宁可多复制一次）',
        needsCopy(
            target: const TargetState(exists: true, size: 900, version: 'v2'),
            assetSize: 1000,
            assetVersion: 'v2'));

    // ── 向后兼容：没有版本信号时行为必须与从前**完全一致** ──
    check('资产无版本 → 退回纯大小比较（保留原能力）',
        !needsCopy(
            target: const TargetState(exists: true, size: 1000, version: 'v1'),
            assetSize: 1000,
            assetVersion: null));
    check('资产版本为空串 → 同样退回纯大小（**不把空串当信号**）',
        !needsCopy(
            target: const TargetState(exists: true, size: 1000, version: 'v1'),
            assetSize: 1000,
            assetVersion: ''));

    // 🔑 target 无版本 = 旧版 App 落的盘 / 版本文件被删 → 复制一次对齐
    check('🔑 target 无版本（旧版落的盘）+ 资产有版本 → 复制一次以对齐',
        needsCopy(
            target: const TargetState(exists: true, size: 1000),
            assetSize: 1000,
            assetVersion: 'v2'));

    // 🔴 既有防线**优先于**版本判断：版本号再准，也不能让「用坏资产盖掉好库」成立
    check('🔴 资产 0 字节 + 版本不同 → **仍然不覆盖**（防线优先）',
        !needsCopy(
            target: const TargetState(exists: true, size: 1000, version: 'v1'),
            assetSize: 0,
            assetVersion: 'v2'));

    eq('版本不同 → replaced',
        planBootstrap(
            target: const TargetState(exists: true, size: 1000, version: 'v1'),
            assetSize: 1000,
            assetVersion: 'v2'),
        BootstrapAction.replaced);
    eq('版本相同 + 大小相同 → skipped',
        planBootstrap(
            target: const TargetState(exists: true, size: 1000, version: 'v2'),
            assetSize: 1000,
            assetVersion: 'v2'),
        BootstrapAction.skipped);
  }

  // ═══ 【6】🔴 写入顺序 —— 顺序反了会「永不自愈」且无任何报错 ═══
  section('【6】写入顺序（先库、后版本）');
  {
    Future<BootstrapResult> run({required TargetState target, required List<String> log}) =>
        ensureWordDb(
          targetPath: '/tmp/x.db',
          readAsset: () async => _fakeBytes(500),
          probe: () => target,
          write: (b) async => log.add('db'),
          readAssetVersion: () async => 'v9',
          writeVersion: (v) async => log.add('version:$v'),
        );

    final log1 = <String>[];
    await run(target: const TargetState.missing(), log: log1);
    eq('🔴 首次：**先写库、后写版本**（反了 = 「旧库 + 新版本」→ 永远不更新）',
        log1.join(','), 'db,version:v9');

    final log2 = <String>[];
    await run(target: const TargetState(exists: true, size: 900, version: 'v1'), log: log2);
    eq('版本变化：同样先库后版本', log2.join(','), 'db,version:v9');

    // 🔴 跳过时**不许**写版本 —— 否则「库没更新，版本却被标成最新」→ 永不自愈
    final log3 = <String>[];
    await run(target: const TargetState(exists: true, size: 500, version: 'v9'), log: log3);
    eq('🔴 跳过时**一个字节都不写**（尤其不许写版本号）', log3.join(','), '');
  }

  // ═══ 【7】版本参与后，日志要能说出「为什么」 ═══
  section('【7】describe 的版本口径');
  {
    final a = BootstrapResult(
      action: BootstrapAction.replaced,
      assetSize: 1000,
      targetBefore: const TargetState(exists: true, size: 1000, version: 'v1'),
      assetVersion: 'v2',
    );
    check('版本不同 → 日志写明「版本不同」并给出前后值',
        a.describe('/x').contains('版本不同') && a.describe('/x').contains('v1'), a.describe('/x'));

    final b = BootstrapResult(
      action: BootstrapAction.replaced,
      assetSize: 1000,
      targetBefore: const TargetState(exists: true, size: 1000),
      assetVersion: 'v2',
    );
    check('target 无版本 → 日志说明是「首次带版本号」（而不是含糊称「变了」）',
        b.describe('/x').contains('首次'), b.describe('/x'));

    // ⚠️ 大小变化时**仍要说「大小不同」**（别被版本口径盖掉 —— 那是另一条判据）
    //    用真实量级（31/33 MB），让打印出来的日志也易读
    final c = BootstrapResult(
      action: BootstrapAction.replaced,
      assetSize: 33 * 1024 * 1024,
      targetBefore: const TargetState(exists: true, size: 31 * 1024 * 1024, version: 'v2'),
      assetVersion: 'v2',
    );
    check('版本相同、仅大小变化 → 日志说「大小不同」',
        c.describe('/x').contains('大小不同') && c.describe('/x').contains('31.0 MB'),
        c.describe('/x'));

    final d = BootstrapResult(
      action: BootstrapAction.skipped,
      assetSize: 1000,
      targetBefore: const TargetState(exists: true, size: 1000, version: 'v2'),
      assetVersion: 'v2',
    );
    check('跳过 → 日志带版本号（事后能核对「当时比的是哪个版本」）',
        d.describe('/x').contains('v2'), d.describe('/x'));
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
