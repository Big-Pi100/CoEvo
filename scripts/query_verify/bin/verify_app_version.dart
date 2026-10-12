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

  // ════════════════════════════════════════════════════════════════
  // 🔴 产品名一致性（2026-10-12 新增）
  // ════════════════════════════════════════════════════════════════
  //
  // # 为什么需要它
  // **改名是一组动作，不是一处字符串** —— 产品名散在 **6 个载体**：
  // | # | 载体 | 谁看到 |
  // |---|---|---|
  // | ① | `app/lib/constants/app_info.dart` 的 `kCoEvoName` | 「关于」页 |
  // | ② | `app/ios/Runner/Info.plist` 的 `CFBundleDisplayName` | **手机图标下那行字** |
  // | ③ | `app/android/app/src/main/AndroidManifest.xml` 的 `android:label` | 同上（安卓） |
  // | ④ | `app/lib/services/share_card_data.dart` 的 `kShareCardBrand` | 分享图品牌 |
  // | ⑤ | `iap_plan.dart` ×2 + `subscribe_screen.dart` ×1 的 `title: 'X 专业版'` | 订阅页套餐名 |
  // | ⑥ | **ASC 网页 + ICP 备案** | ⏳ 脚本管不到 ⇒ 见 `launch-final-steps` §9.6 |
  //
  // 🔴 **备案的两条硬约束，让 ② 绝不能偷懒**：
  //    · **备案名 = 手机上图标下方的名称**（腾讯云 FAQ 原文）
  //    · **ASC 后台填的 App 名称必须与备案名逐字一致**（Apple 强校验 ⇒ 不符无法提审）
  //
  // 📌 判据：**「注释里写『记得同步改』」不是防线，脚本才是**（同本文件头部那条）。
  //
  // 🔴 本组断言的**证伪方式**：把 `Info.plist` 的 `CFBundleDisplayName` 改成别的
  //    ⇒ 本脚本**必须变红**。（2026-10-12 已实测。）
  print('');
  print('─' * 74);
  print('🔴 产品名一致性（6 个载体）');
  print('─' * 74);

  String? grab(String path, RegExp re, String label) {
    final f = File(path);
    if (!f.existsSync()) {
      check('$label：文件存在', false, path);
      return null;
    }
    final mt = re.firstMatch(f.readAsStringSync());
    if (mt == null) {
      check('$label：可解析', false, path);
      return null;
    }
    return mt.group(1)!.trim();
  }

  final appName = grab('../../app/lib/constants/app_info.dart',
      RegExp(r"kCoEvoName\s*=\s*'([^']*)'"), 'app_info.dart `kCoEvoName`');
  check('产品名非空', appName != null && appName.isNotEmpty, appName ?? '(null)');

  if (appName != null) {
    // ── ② ③ ④ 必须与 ① 完全一致 ──
    final carriers = <String, String?>{
      'iOS Info.plist（图标下显示名）': grab(
          '../../app/ios/Runner/Info.plist',
          RegExp(r'<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>'),
          'Info.plist `CFBundleDisplayName`'),
      'Android label': grab(
          '../../app/android/app/src/main/AndroidManifest.xml',
          RegExp(r'android:label="([^"]*)"'),
          'AndroidManifest `android:label`'),
      '分享图品牌': grab('../../app/lib/services/share_card_data.dart',
          RegExp(r"kShareCardBrand\s*=\s*'([^']*)'"), '`kShareCardBrand`'),
    };
    for (final e in carriers.entries) {
      check('🔴 ${e.key} 与 `kCoEvoName` 一致', e.value == appName,
          '${e.key}=${e.value} / kCoEvoName=$appName');
    }

    // ── ⑤ 套餐名 = 产品名 + ' 专业版'
    //      ⚠️ **不硬编码品牌名**（否则改名时断言本身要跟着改 ⇒ 又会漏）
    //      ⇒ 期望值由 `kCoEvoName` **动态推导**（判据：断言跟「意图」走，不跟「拼写」走）。
    final expectTitle = '$appName 专业版';
    final titles = <String>[
      for (final p in [
        '../../app/lib/services/iap_plan.dart',
        '../../app/lib/screens/subscribe_screen.dart',
      ])
        ...RegExp(r"title:\s*'([^']*专业版)'")
            .allMatches(File(p).readAsStringSync())
            .map((m) => m.group(1)!),
    ];
    check('🔴 套餐名共 3 处（iap_plan ×2 + subscribe_screen ×1）',
        titles.length == 3, 'found=${titles.length}');
    check('🔴 每处都是「$expectTitle」',
        titles.isNotEmpty && titles.every((t) => t == expectTitle),
        titles.join(' / '));
  }

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
