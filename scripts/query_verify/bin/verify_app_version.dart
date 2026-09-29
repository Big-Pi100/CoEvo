// CoEvo · 版本号一致性验收
//
// 跑法：cd scripts/query_verify && dart run bin/verify_app_version.dart
//
// # 为什么需要它
// 版本号出现在**两处**，而它们会漂：
// | 位置 | 用途 | 谁读 |
// |---|---|---|
// | `app/pubspec.yaml` 的 `version: x.y.z+N` | **构建系统**（iOS `CFBundleShortVersionString` / Android `versionName`） | Flutter / Xcode / Gradle |
// | `app/lib/constants/app_info.dart` 的 `kCoEvoVersion` | **界面显示**（「关于」页 / 「我的」页副标题） | Dart |
//
// 🔑 **「注释里提醒『记得同步改』」不是防线** —— 那是**约定**，不是**约束**。
//    只有脚本能在漂的那一刻变红。本项目已有同类先例（词库两份一致性用
//    `verify_worddb_sync.dart` 守）。
//
// # 🔴 本脚本自身的证伪方式
// 把 `app_info.dart` 的 `kCoEvoVersion` 改成 `'9.9.9'` → 本脚本**必须变红**。

import 'dart:io';

var _pass = 0;
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

void main() {
  print('');
  print('#' * 74);
  print('# 版本号一致性 —— pubspec.yaml ↔ app_info.dart');
  print('#' * 74);

  // ── 读 pubspec 的 version ──
  final pubspec = File('../../app/pubspec.yaml').readAsStringSync();
  final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
  if (m == null) {
    check('pubspec.yaml 有 version 行', false);
    _report();
    return;
  }
  final raw = m.group(1)!;
  // 口径：`x.y.z` 是**界面可见**的版本号；`+N`（build number）只给构建系统用
  final parts = raw.split('+');
  final pubVersion = parts[0];
  final buildNumber = parts.length > 1 ? parts[1] : null;

  check('pubspec version 可解析', pubVersion.isNotEmpty, raw);
  check('pubspec 含 build number（`+N`）', buildNumber != null,
      buildNumber ?? '（缺 —— 每次发版/上传需递增，见记忆「版本号两段」）');

  // ── 读 Dart 常量 ──
  final info = File('../../app/lib/constants/app_info.dart').readAsStringSync();
  final dm = RegExp(r"kCoEvoVersion\s*=\s*'([^']*)'").firstMatch(info);
  if (dm == null) {
    check('app_info.dart 有 kCoEvoVersion 常量', false);
    _report();
    return;
  }
  final dartVersion = dm.group(1)!;
  check('app_info.dart 的 kCoEvoVersion 可解析', dartVersion.isNotEmpty,
      dartVersion);

  // ── 🔴 核心断言：两处必须一致 ──
  check('🔴 pubspec 与 app_info 的版本号**一致**', pubVersion == dartVersion,
      'pubspec=$pubVersion  dart=$dartVersion');

  // ── 格式约定（`x.y.z` 三段数字）──
  final semver = RegExp(r'^\d+\.\d+\.\d+$');
  check('版本号是 `x.y.z` 三段式（界面显示口径）', semver.hasMatch(pubVersion),
      pubVersion);

  // ── 界面里不应出现 `+N`（build number 只给构建系统）──
  check('🔴 `+N` 不出现在界面常量里（避免「为什么有两个版本」）',
      !dartVersion.contains('+'), dartVersion);

  _report();
}

void _report() {
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 修法：让 `app/pubspec.yaml` 的 `version:` 与');
    print('    `app/lib/constants/app_info.dart` 的 `kCoEvoVersion` 一致');
    print('    （`+N` 之后的部分只给构建系统，不参与比较）。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
