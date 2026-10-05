// 脚本的**可移植性**验收 —— 防「只在本机成立」的路径重新长出来
//
// 跑：cd scripts/query_verify && dart run bin/verify_script_portability.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（2026-10-05 的真实 CI 红）
//
// 我把 19 个脚本接进 CI 时，**本机（Windows）19 个全绿**就以为没问题了。
// 结果 CI 报：
// ```
// Run dart run bin/verify_word_query.dart
// 找不到 word.db: E:\CoEvo\data\word.db        ← 🔴 硬编码的 Windows 绝对路径
// Error: Process completed with exit code 2.
// ```
// **`ubuntu-latest` 上没有 `E:` 盘** ⇒ 必然失败。
//
// # 🔴 更麻烦的是「CI 顺序执行、第一个红就停」
//
// 那次 CI 只报了 **1 个**（`verify_word_query`，B 组第 3 个）；
// 而实际有 **5 个**脚本写着 `r'E:\...'`：
// `bench` · `query_probe` · `verify_word_query` · `verify_bookmark` · `verify_review_list`。
// ⇒ 后面 4 个**根本没跑到**，也就**不会被报出来** —— 修完第 1 个，第 2 个才浮现。
// 📌 判据：**「门禁报了 N 项」≠「只有 N 项」** —— 顺序执行的门禁只报**第一个**；
//    要拿全清单，必须**静态扫**（本脚本就是干这个的），而不是靠反复跑。
//
// # 本脚本守什么
//
// ① `scripts/**` 下**不得出现盘符绝对路径**（`r'E:\...'` / `"C:/..."` …）
// ② **不得用「依赖 cwd 的相对路径」读仓库资源**（`File('data/word.db')` 等）——
//    cwd 是包根（`scripts/<pkg>`）⇒ 相对路径会指到 `scripts/<pkg>/data/...`（不存在）。
//    ⚠️ 这一条**比第 ① 条更隐蔽**：它在本地**也**红，所以更容易被发现；
//       但若某天有人从仓库根跑脚本，它又会「恰好能跑」⇒ 变成偶发。
//
// # ⚠️ 口径（如实标注）
//
// · 扫描范围 = `scripts/**/*.dart`（**含 `bin/_repo_paths.dart`** —— 它的注释里
//   有 `r'E:\CoEvo\data\word.db'` 作为**反例示例**）
//   ⇒ 因此**必须先剥整行注释再查**（否则那条示例会造成**假红**）。
//   🔑 这正是本项目记过的「剥注释」判据，且**只能按整行剥**（切 `//` 会把
//      `https://` 里的 `//` 切掉 ⇒ 漏检）。
// · 本脚本**不查** Python/Shell 脚本（`scripts/**/*.py`）—— 本轮事故只在 Dart 侧；
//   要扩应先核实 Python 侧是否真有同类（不假装覆盖了没验的东西）。

import 'dart:io';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail.isEmpty ? name : '$name —— $detail');
  }
}

/// 剥掉**整行注释**（只剥整行，理由见文件头）。
String _stripComments(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// 仓库根（同 `bin/_repo_paths.dart` 的口径：靠**特征文件**定位，不靠层数）。
String _repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

void main() {
  final root = _repoRoot();
  final scriptsDir = Directory('$root${Platform.pathSeparator}scripts');
  check('scripts/ 目录存在（否则下面全是假绿）', scriptsDir.existsSync(), scriptsDir.path);
  if (!scriptsDir.existsSync()) {
    _report();
    return;
  }

  // ── 收集 scripts/**/*.dart（**排除** .dart_tool 里的生成物）──
  final files = <File>[];
  for (final e in scriptsDir.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    if (e.path.contains('${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}')) {
      continue;
    }
    files.add(e);
  }
  // 🔴 「扫了 0 个文件」必须能区分「真的没有」与「根本没跑到」
  //    （否则路径写错会让下面全部断言**假绿**）。
  check('扫到的脚本数 > 0（且要够多）', files.length >= 20,
      '实得 ${files.length} 个 —— 若为 0，说明扫描路径写错了');

  // ── ① 盘符绝对路径 ──
  //    形如 `r'E:\...'` / `r"C:/..."` / `'D:\...'` —— 盘符 + 冒号 + 斜杠。
  final driveRe = RegExp(r"""['"][A-Za-z]:[\\/]""");
  final driveHits = <String>[];
  for (final f in files) {
    final code = _stripComments(f.readAsStringSync());
    for (var i = 0; i < code.split('\n').length; i++) {
      final line = code.split('\n')[i];
      if (driveRe.hasMatch(line)) {
        driveRe.firstMatch(line);
        driveHits.add('${_rel(root, f.path)}:${i + 1}  ${line.trim()}');
      }
    }
  }
  check(
    '🔴 scripts/ 下没有盘符绝对路径（CI 是 Linux ⇒ 必然红）',
    driveHits.isEmpty,
    driveHits.isEmpty ? '' : '\n      ${driveHits.join('\n      ')}',
  );

  // ── ② 依赖 cwd 的相对资源路径 ──
  //    只查**已知的仓库资源**（`data/` / `app/assets/`）——
  //    不泛化到「所有相对路径」，因为 `../../app/lib/x.dart` 这种**相对包根**的写法
  //    是本包既有且成立的（CI 的 cwd 就是包根）。
  //    🔑 判据：**断言的范围要精确到「被测对象」** —— 泛化会误伤合法写法。
  //
  //    🔴 **必须有词边界**（`(?<![A-Za-z_])`）—— 第一次跑就被这条咬到：
  //       `ebook_verify` 里写的是 `File(_repoFile('app/assets/sql/...'))`，
  //       而 `_repoFile(` 的**末尾四个字符恰好是 `File(`** ⇒ 不加词边界会把它也命中，
  //       报出一处**假红**（那段代码本身是可移植的，它有自己的 `_repoFile()` helper）。
  //    📌 判据：**「子串匹配」在标识符边界上必然出错** —— 凡是查「某个调用」，
  //       都要排掉「更长标识符的后缀恰好是它」这一情形。
  final cwdRelRes = [
    RegExp(r"""(?<![A-Za-z_])File\(\s*['"]data/"""),
    RegExp(r"""(?<![A-Za-z_])File\(\s*['"]app/assets/"""),
    RegExp(r"""(?<![A-Za-z_])Directory\(\s*['"]data/"""),
    RegExp(r"""(?<![A-Za-z_])Directory\(\s*['"]app/assets/"""),
  ];

  final cwdHits = <String>[];
  for (final f in files) {
    final code = _stripComments(f.readAsStringSync());
    for (var i = 0; i < code.split('\n').length; i++) {
      final line = code.split('\n')[i];
      if (cwdRelRes.any((r) => r.hasMatch(line))) {
        cwdHits.add('${_rel(root, f.path)}:${i + 1}  ${line.trim()}');
      }
    }
  }
  check(
    '🔴 scripts/ 下没有「依赖 cwd 的仓库资源相对路径」（应走 _repo_paths.dart）',
    cwdHits.isEmpty,
    cwdHits.isEmpty ? '' : '\n      ${cwdHits.join('\n      ')}',
  );

  // ── 🔴 一条**试过但回退**的口径（如实记录，别再试第二遍）──
  //
  // 我曾想再补一条「把仓库资源相对路径**赋给变量**」（正则 `[:=]\s*['"]data/` 之类），
  // 用来兜住这个形态：
  // ```dart
  // final schemaPath = args.isNotEmpty ? args[0] : 'app/assets/sql/user_db_schema.sql';
  // final f = File(schemaPath);        // ← 运行时一样会指错
  // ```
  // **但实测它误伤了一个合法写法**（`verify_worddb_sync.dart`）：
  // ```dart
  // const srcRel = 'data/word.db';
  // final src = File('$root/$srcRel');   // ← 有 `$root/` 前缀 ⇒ 可移植 ✅
  // ```
  // 📌 判据：**文本断言无法区分「赋给变量后被根前缀拼接」与「直接当路径用」** ——
  //    那是**数据流分析**，超出源级扫描的能力。
  //    硬要抓就会「误伤合法写法」⇒ **假红**，而假红的危害是
  //    **消耗门禁可信度**（合理改动就报警 ⇒ 训练人忽略红灯 ⇒ 真回归也被忽略）。
  //
  // ✅ 那这个盲区怎么办 —— **用正向哨兵兜**（见下面 ④）：
  //    不去猜「路径从哪来」，而是**要求这 5 个文件必须调 helper**。
  //    证伪实测：把 `userDbSchemaPath()` 换回字面量 ⇒ **正向哨兵红、退出码 1**
  //    ⇒ 该回归**确实被抓住了**（只是抓它的是哨兵，不是「猜路径」的那种断言）。
  //    🔑 判据：**「回归被抓住」比「被哪条断言抓住」重要**；
  //       但**必须说明是安全网抓的**，否则会误以为「模式断言已覆盖」。
  //
  // ── 🔴 已知**未覆盖**的形态（如实标注，不假装能抓）──
  //  · 「先赋值给变量、再 `File(变量)`」（上面已说明为何不抓）
  //  · Python / Shell 脚本（本次事故只在 Dart 侧；**未核实** Python 侧是否有同类）
  //  · `String` 插值拼出来的路径（如 `'${prefix}data/word.db'`）
  //  ⇒ 这些最终靠「**真在 CI 上跑**」兜：跑不过就是最硬的门禁。

  // ── ③ 正向哨兵：可移植 helper 确实存在 ──
  //    🔑 反向断言（「不得含 X」）在「整个文件被删/改名」时会**静默变绿**
  //       ⇒ 必须配一条**正向**断言（本项目的既有判据）。
  final helper = File('$root${Platform.pathSeparator}scripts'
      '${Platform.pathSeparator}query_verify${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}_repo_paths.dart');
  check('正向哨兵：可移植路径 helper（`_repo_paths.dart`）存在', helper.existsSync(),
      helper.path);
  if (helper.existsSync()) {
    final h = _stripComments(helper.readAsStringSync());
    check('helper 提供 repoRoot()', h.contains('String repoRoot()'));
    check('helper 提供 wordDbPath()', h.contains('String wordDbPath()'));
    check('helper 提供 userDbSchemaPath()',
        h.contains('String userDbSchemaPath()'));
    // 🔑 helper 的定位依据必须是**特征文件**，不是层数 —— 层数会在目录结构变化时静默失效
    check('helper 靠特征文件定位（不是靠「向上 N 层」）',
        h.contains('app') && h.contains('pubspec.yaml'));
  }

  // ── ④ 正向哨兵：5 个原硬编码点确实改用 helper ──
  const migrated = {
    'bench.dart': 'wordDbPath()',
    'query_probe.dart': 'wordDbPath()',
    'verify_word_query.dart': 'wordDbPath()',
    'verify_bookmark.dart': 'userDbSchemaPath()',
    'verify_review_list.dart': 'userDbSchemaPath()',
  };
  for (final e in migrated.entries) {
    final f = File('$root${Platform.pathSeparator}scripts'
        '${Platform.pathSeparator}query_verify${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}${e.key}');
    check('正向哨兵：${e.key} 存在', f.existsSync(), f.path);
    if (!f.existsSync()) continue;
    final code = _stripComments(f.readAsStringSync());
    check('🔴 ${e.key} 已改用 ${e.value}（不再是硬编码）', code.contains(e.value),
        '未见到 ${e.value}');
  }

  _report();
}

String _rel(String root, String p) =>
    p.startsWith(root) ? p.substring(root.length + 1) : p;

void _report() {
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 脚本可移植性全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：有人在脚本里写了「只在本机成立」的路径。');
    print('   ① 盘符绝对路径（`E:\\...`）在 CI（Linux）上不存在；');
    print('   ② 相对路径（`data/word.db`）相对的是 cwd=包根，会指错地方。');
    print('   ✅ 两者都改用 `bin/_repo_paths.dart` 的 `wordDbPath()` /');
    print('      `userDbSchemaPath()`（从脚本位置向上找仓库根）。');
  }
  print('═' * 74);
  // 🔴 显式设置退出码（Dart 的 `main` 返回值**不是**退出码）
  exitCode = _fail == 0 ? 0 : 1;
}
