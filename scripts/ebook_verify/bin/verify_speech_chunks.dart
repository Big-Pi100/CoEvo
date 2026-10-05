// 朗读文本分段 —— 验收（纯 Dart · 零依赖 · 本机可跑 · 可进 CI）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_speech_chunks.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读 ——
//    写成 `| tail` 会让 `$?` 取到 tail 的退出码，本项目已踩过）。
//
// # 为什么这几条值得断言
//
// 分段是「为了绕开平台长度上限」而引入的**中间层**，它有三类**静默失效**：
//   · **丢字 / 重复**（切片边界算错）⇒ 朗读内容与正文不符，**用户很难发现**
//   · **仍超上限**（累积逻辑写错）⇒ 症状与分段之前**一模一样**（没声音）⇒ 等于没修
//   · **切出空段** ⇒ TTS 读一段静默，听起来像「卡了一下」
// ⇒ 前两条不报错、第三条只是「怪」，**全靠断言守**。
//
// 另有一条判据来源：真机反馈「整章朗读没声音」的根因就是**超平台单次上限**
// （Android `getMaxSpeechInputLength()` ≈ 4000）—— 见 `speech_chunks.dart` 文件头。

import '../../../app/lib/services/speech_chunks.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail == null ? name : '$name —— $detail');
  }
}

/// 去掉**所有空白字符**（判「内容守恒」用）。
///
/// 🔑 必须去空白：分段会在标点后/行末丢空白（那是分隔符，不是内容）。
///    若直接比字符串，会把「正常的空白差异」报成「丢字」⇒ **假红**。
String _noWs(String s) => s.replaceAll(RegExp(r'\s+'), '');

/// 造一段确定性的长文本（不依赖随机，保证可复现）。
String _longText({
  required int sentences,
  int wordsPerSentence = 6,
}) {
  final b = StringBuffer();
  for (var i = 0; i < sentences; i++) {
    b.write('This is sentence number $i with several words inside it.');
    if (i != sentences - 1) b.write(' ');
  }
  return b.toString();
}

void main() {
  // ══════════════════════════════════════════════════════════════════════
  // ① 基本形态：空 / 短
  // ══════════════════════════════════════════════════════════════════════
  check('空输入 → 空列表', splitForSpeech('').isEmpty);
  check('纯空白 → 空列表', splitForSpeech('   \n\n  \t ').isEmpty,
      '${splitForSpeech('   \n\n  \t ').length} 段');

  final one = splitForSpeech('Hello world.');
  check('短文本 → 恰好 1 段', one.length == 1, '${one.length} 段');
  check('短文本内容不变', one.isNotEmpty && one.first == 'Hello world.',
      one.isEmpty ? '（空）' : one.first);

  // 🔴 空行**不得**产生空段（空段会让 TTS 读一段静默 ⇒ 听起来像卡顿）
  final blanks = splitForSpeech('第一行\n\n\n第二行\n   \n第三行');
  check('🔴 空行不产生空段', blanks.every((s) => s.trim().isNotEmpty),
      blanks.toString());
  check('空行分隔 → 3 段', blanks.length == 3, '${blanks.length} 段');

  // ══════════════════════════════════════════════════════════════════════
  // ② 🔴 硬约束：每段 ≤ maxLen（这条不成立 ⇒ 症状与修复前一样）
  // ══════════════════════════════════════════════════════════════════════
  for (final maxLen in [50, 200, 3000]) {
    final text = _longText(sentences: 200);
    final chunks = splitForSpeech(text, maxLen: maxLen);
    final ok = chunks.every((s) => s.length <= maxLen);
    check('🔴 每段 ≤ maxLen($maxLen)', ok,
        ok ? '' : '最长段 ${chunks.map((s) => s.length).reduce((a, b) => a > b ? a : b)}');
    check('  ↳ 且确实切开了（>1 段）', chunks.length > 1, '${chunks.length} 段');
  }

  // 边界：正好 maxLen 不该被切；maxLen+1 必须切
  final exact = 'x' * 50;
  check('正好 maxLen → 1 段（不多切）',
      splitForSpeech(exact, maxLen: 50).length == 1);
  final over = 'x' * 51;
  final overChunks = splitForSpeech(over, maxLen: 50);
  check('maxLen+1 → 2 段', overChunks.length == 2, '${overChunks.length} 段');
  check('  ↳ 硬切后每段 ≤ maxLen', overChunks.every((s) => s.length <= 50),
      overChunks.map((s) => s.length).toString());

  // ══════════════════════════════════════════════════════════════════════
  // ③ 🔴🔴 内容守恒 —— 分段最大的风险（切错边界会丢字/重复）
  //
  // 「删/改一个字」在朗读里**几乎听不出来**，但在阅读对照里是硬错
  // ⇒ 必须用「去空白后逐字相等」这种**最强**判据，而不是抽查开头结尾。
  // ══════════════════════════════════════════════════════════════════════
  final cases = <String, String>{
    '英文长句': _longText(sentences: 300),
    '中文长文': List.generate(300, (i) => '这是第 $i 句话，用来测试分段。').join(),
    '中英混排': List.generate(150, (i) => 'Sentence $i 混排 with 中文，测试。').join(' '),
    '无标点长串': 'abcdefghij' * 100,
    '多行段落': List.generate(80, (i) => 'Line $i has some words here.').join('\n'),
    '含空行': List.generate(60, (i) => 'P$i text.\n').join('\n'),
  };
  cases.forEach((name, text) {
    final chunks = splitForSpeech(text, maxLen: 120);
    final joined = chunks.join();
    check('🔴 内容守恒（去空白）：$name',
        _noWs(joined) == _noWs(text),
        _noWs(joined) == _noWs(text)
            ? ''
            : '原 ${_noWs(text).length} 字 vs 分 ${_noWs(joined).length} 字');
  });

  // ══════════════════════════════════════════════════════════════════════
  // ④ 标点保留（丢标点会让 TTS 语调收尾不自然 —— 用户只觉「读得怪」）
  // ══════════════════════════════════════════════════════════════════════
  final punct = splitForSpeech('First one. Second two! Third three? 第四句。', maxLen: 20);
  final punctJoined = punct.join(' ');
  for (final mark in ['.', '!', '?', '。']) {
    check('标点保留：$mark', punctJoined.contains(mark), punctJoined);
  }

  // ══════════════════════════════════════════════════════════════════════
  // ⑤ 累积不过碎 —— 短句应被合进同一段（否则停顿过多，听感很差）
  // ══════════════════════════════════════════════════════════════════════
  final small = List.generate(20, (i) => 'Hi $i.').join(' '); // 总长 < 3000
  check('短句应合成 1 段（不逐句成段）', splitForSpeech(small).length == 1,
      '${splitForSpeech(small).length} 段');

  // 🔴🔴 **段数不得超过必要值**（防「过度切分」）—— 2026-10-05 证伪时补。
  //
  // 为什么单独立这一条：上面那条（`small` 全长 < 3000）走的是
  // `if (block.length <= maxLen) { out.add(block); return; }` 的**提前返回**分支
  // ⇒ **累积逻辑那段代码根本没被执行**。
  // 证伪实测：把累积改成「逐句成段」后，上面那条**照样绿** —— 因为没走到那里。
  // 📌 判据：**「注入生效」≠「注入的那条路径被执行」** ——
  //    验证覆盖时要问「这段代码真的跑到了吗」，而不是「文件改了吗」。
  //
  // 构造：文本 **超过 maxLen**（必走累积分支），且句短（可累积）⇒
  // 正确实现下段数 ≈ ceil(len/maxLen)；逐句成段则段数 = 句数（远大于前者）。
  final fill = List.generate(40, (i) => 'Sentence number $i.').join(' ');
  const fillMax = 100;
  final fillChunks = splitForSpeech(fill, maxLen: fillMax);
  final needAtLeast = (fill.length / fillMax).ceil(); // 理论下限
  check(
    '🔴 段数不超过必要值（防过度切分 = 累积逻辑真的生效）',
    fillChunks.length <= needAtLeast + 2,
    '${fillChunks.length} 段（理论上限 ${needAtLeast + 2}，句数 40）',
  );
  check('  ↳ 且每段 ≤ maxLen', fillChunks.every((s) => s.length <= fillMax),
      fillChunks.map((s) => s.length).toString());

  // ══════════════════════════════════════════════════════════════════════
  // ⑥ 参数校验
  // ══════════════════════════════════════════════════════════════════════
  var threw = false;
  try {
    splitForSpeech('abc', maxLen: 0);
  } on ArgumentError {
    threw = true;
  }
  check('maxLen <= 0 → 抛 ArgumentError', threw);

  // ══════════════════════════════════════════════════════════════════════
  // ⑦ 常量与平台上限的关系（防止有人把 kMaxSpeechChunk 调到平台线以上）
  // ══════════════════════════════════════════════════════════════════════
  check('🔴 kMaxSpeechChunk 必须 < 4000（Android 平台上限）',
      kMaxSpeechChunk < 4000, '实际 $kMaxSpeechChunk');

  // ══════════════════════════════════════════════════════════════════════
  print('通过 $_pass 项 · 失败 $_fail 项');
  if (_fail > 0) {
    print('── 失败明细 ──');
    for (final f in _failures) {
      print('  ✗ $f');
    }
    // 🔴 必须显式设退出码（Dart 的 main 返回值**不会**自动成为退出码）
    throw StateError('有 $_fail 项失败');
  }
}
