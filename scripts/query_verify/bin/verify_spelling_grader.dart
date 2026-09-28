// CoEvo · 拼写判定验收 —— `services/spelling_grader.dart`
//
// 🔑 为什么值得单独一层验收：
//   判定规则是「**用户答对/答错**」的唯一裁判 —— 它错一次，
//   就会把一个「会」记成「忘了」（或反之）→ **直接污染 FSRS 数据**，
//   而 FSRS 的数据是不可回溯的（历史评级驱动后续所有间隔）。
//
// 🔴 本脚本**用真库跑**（`app/assets/word.db` 的 11,523 个词），
//    而不是只测几个手写用例 —— 因为「严格判定」的实际后果取决于
//    **词库里到底有什么词**（218 个含标点/空格、3 个含非 ASCII）。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/fsrs_service.dart';
import '../../../app/lib/services/spelling_grader.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _failures.add(label);
    print('  🔴 $label${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

String _repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${d.path}/app').existsSync()) return d.path;
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return Directory.current.path;
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final dbPath = '${_repoRoot()}/app/assets/word.db';

  print('CoEvo 拼写判定验收\n');
  print('词库: $dbPath');

  final db = await factory.openDatabase(dbPath,
      options: OpenDatabaseOptions(readOnly: true));

  try {
    // ── 1. 基本判定 ────────────────────────────────────────────
    print('\n【1】基本判定');
    check('完全一致 → 对', gradeSpelling('receive', 'receive'));
    check('不同拼写 → 错', !gradeSpelling('recieve', 'receive'));
    check('少字母 → 错', !gradeSpelling('receve', 'receive'));
    check('多字母 → 错', !gradeSpelling('receivee', 'receive'));

    // ── 2. 输入卫生（这些**不该**算错）────────────────────────────
    //
    // 🔑 三条都不属于「拼写能力」，且都有客观理由（见 grader 的文档）：
    //    · 大小写 → 词库自身 `COLLATE NOCASE`
    //    · 首尾空格 → 多按一个空格不是拼错
    //    · 全角 → **中文输入法**的字符变体（目标用户是中文母语者）
    print('\n【2】输入卫生 —— 不该算错（不是拼写能力）');
    check('大小写不敏感（Reception = reception）',
        gradeSpelling('reception', 'Reception'));
    check('首尾空格忽略', gradeSpelling('  receive  ', 'receive'));
    check('制表/换行也忽略（trim 的固有行为）',
        gradeSpelling('\treceive\n', 'receive'));
    check('🔑 全角字母（中文输入法打出）→ 算对',
        gradeSpelling('ｒｅｃｅｉｖｅ', 'receive'));
    check('🔑 全角空格（U+3000）→ 当作普通空格',
        gradeSpelling('air\u3000conditioning', 'air conditioning'));
    check('全角句点 → 算对', gradeSpelling('a．m．', 'a.m.'));

    // 🔴 归一化**不得**改变真正的非 ASCII 字母（否则会把严格变成宽容）
    check('🔴 重音符不被抹掉（é 不是全角字符）',
        normalizeSpelling('café') == 'café',
        normalizeSpelling('café'));
    check('🔴 归一化不把 café 变成 cafe（严格性未受损）',
        !gradeSpelling('cafe', 'café'));

    // ── 3. 严格要求项（白哥选「严格」→ 这些**都算错**）────────────
    //
    // ⚠️ 这些是**有意的后果**，不是 bug。若日后发现误判代价太高，
    //    改 `normalizeSpelling` 一个函数即可（全库只有这一处判定）。
    print('\n【3】严格项 —— 都算错（白哥 2026-09-28 选「严格」）');
    check('连字符 vs 空格 → 错', !gradeSpelling('bad tempered', 'bad-tempered'));
    check('省句点 → 错（a.m. 是词条本身）', !gradeSpelling('am', 'a.m.'));
    check('省重音符 → 错', !gradeSpelling('cafe', 'café'));
    check('内部多空格 → 错', !gradeSpelling('according  to', 'according to'));
    check('内部少空格 → 错',
        !gradeSpelling('airconditioning', 'air conditioning'));
    check('撇号省略 → 错', !gradeSpelling('drivers license', "driver's license"));

    // ── 4. 真库全量：严格规则的实际影响面 ───────────────────────
    //
    // 🔑 这一节的价值：把「严格」的**代价**变成可核验的数字，
    //    而不是等用户抱怨「明明会却判我错」。
    print('\n【4】真库全量：严格规则的实际影响面');
    final rows = await db.rawQuery('SELECT spelling FROM word');
    final all = rows.map((r) => r['spelling']! as String).toList();
    check('词库总数 11,523', all.length == 11523, '${all.length}');

    // 每个词按权威拼写自身判定 → **必须全部为对**
    // 🔑 这是一条「零风险证伪法」形态的断言：若判定器对权威拼写都判错，
    //    说明归一化写坏了（而不是词有问题）。
    final selfWrong = all.where((w) => !gradeSpelling(w, w)).toList();
    check('🔴 每个词的权威拼写判定自身 → 全部为「对」',
        selfWrong.isEmpty, selfWrong.take(5).join(', '));

    final withPunct =
        all.where((w) => RegExp(r"[\s\-\.']").hasMatch(w)).toList();
    final nonAscii =
        all.where((w) => w.runes.any((c) => c > 127)).toList();
    check('含空格/连字符/句点/撇号的词 = 218',
        withPunct.length == 218, '${withPunct.length}');
    check('含非 ASCII 的词 = 3', nonAscii.length == 3, '$nonAscii');

    // 🔑 抽样：破坏一个字符后必须判错（证明严格真的生效）
    //
    // ⚠️ 破坏方式要**按词的类型选** —— 我第一版用「统一去标点」，
    //    结果对 `café` 无效（它没有标点可去，去完还是自己）→ **断言假红**。
    //    🔑 「见红先分清实现错还是断言错」：那次是**断言错**
    //       （手法与词的构造不匹配），不是实现错。
    final strictSamples = <String, String>{
      'a.m.': 'am', // 去句点
      'according to': 'accordingto', // 去空格
      'bad-tempered': 'bad tempered', // 连字符→空格
      'café': 'cafe', // 去重音符
    };
    strictSamples.forEach((word, broken) {
      check('严格生效：「$word」写成「$broken」判错',
          !gradeSpelling(broken, word), '$broken ≠ $word');
    });

    // 🔑 反向：普通词不受归一化影响（不该被误伤）
    final plain = all.where((w) => RegExp(r'^[a-z]+$').hasMatch(w) && w.length > 3).take(300);
    final plainBroken = plain.where((w) => normalizeSpelling(w) != w).toList();
    check('🔴 纯小写普通词归一化后不变（没有被误伤）',
        plainBroken.isEmpty, plainBroken.take(5).join(', '));

    // ── 5. FSRS 映射（白哥定：2 档）────────────────────────────
    print('\n【5】判定结果 → FSRS 档位（2 档）');
    check('拼对 → good（记得）',
        ratingForSpelling(correct: true) == ReviewRating.good);
    check('拼错 → again（忘了）',
        ratingForSpelling(correct: false) == ReviewRating.again);
    check('🔴 hard / easy 不再被使用（只有两个分支）',
        {ratingForSpelling(correct: true), ratingForSpelling(correct: false)}
                .length ==
            2);
    check('映射值与 fsrs 包一致（good=3 / again=1）',
        ReviewRating.good.value == 3 && ReviewRating.again.value == 1);

    // ── 6. 归一化的幂等性 ──────────────────────────────────────
    print('\n【6】归一化幂等（防「判两次结果不同」这类诡异 bug）');
    final idem =
        all.where((w) => normalizeSpelling(normalizeSpelling(w)) != normalizeSpelling(w));
    check('🔴 归一化幂等（全库 11,523 词）', idem.isEmpty,
        idem.take(3).join(', '));
  } finally {
    await db.close();
  }

  print('\n${'=' * 68}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exit(1);
  }
  print('✅ 拼写判定全部通过');
  exit(0);
}
