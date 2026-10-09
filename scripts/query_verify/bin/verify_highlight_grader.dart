// CoEvo · 划线默写判定验收 —— `services/highlight_grader.dart` + `services/highlight_id.dart`
//
// 跑：cd scripts/query_verify && dart run bin/verify_highlight_grader.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 🔑 为什么值得单独一层
// 判定是「用户答对 / 答错」的**唯一裁判** —— 它错一次就会把「会」记成「忘了」，
// 而 FSRS 的历史评级**不可回溯**（它驱动后续所有间隔）。
//
// 🔴 与 `verify_spelling_grader` 的差别：那条要**用真库跑**（判定后果取决于词库里有什么词）；
//    本条**不需要真库** —— 划线的判定只看字符串本身。⇒ 纯逻辑，用例即全部输入空间。
//
// # 🔴 两个特别要守的点
// ① **「漏一个词」不能导致后面全部错位** —— 若实现退化成「按下标逐位比」，
//    漏 1 个词会让剩余词**全部判错** ⇒ 长句也永远 again（正好违背本功能的意图）。
//    本脚本用 `a b c d e` 漏 `a` 这条回归钉死它。
// ② **iOS 智能标点**：`'` 会被替换成 `’` ⇒ 不折叠的话**用户写对也判错**。

import '../../../app/lib/services/highlight_grader.dart';
import '../../../app/lib/services/highlight_id.dart';
import '../../../app/lib/services/highlight_span.dart';

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

/// 显示不可见字符（否则失败信息里 `'` 与 `’` 看不出来）。
String show(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x20) {
      b.write('␠');
    } else if (r > 0x7E) {
      b.write('\\u${r.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      b.writeCharCode(r);
    }
  }
  return '`$b`';
}

void eq(String label, Object? got, Object? want) =>
    check(label, got == want, got == want ? '' : '实际 $got · 期望 $want');

void main() {
  print('');
  print('═══ verify_highlight_grader ═══');

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('① 骨架 skeletonFor');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 规则：**只遮字母/数字**，标点与空白原样；每词保留前 N 个，其余逐字换 `_`；
  //       词内撇号/连字符保留；**不小写化**。
  eq('标准：只给首字母', skeletonFor('attention.'), 'a________.');
  eq('保留原文大小写（不做小写化）', skeletonFor('None'), 'N___');
  eq('两字母词也遮（统一规则）', skeletonFor('of'), 'o_');
  eq('连字符属于词', skeletonFor('e-mail'), 'e-____');
  eq('撇号属于词（且不占「字母位」）', skeletonFor("don't"), "d__'_");
  eq('数字同样被遮', skeletonFor('2026'), '2___');
  eq('标点与空白原样保留', skeletonFor('\u2014 "hi"'), '\u2014 "h_"');
  eq('reveal = none：一个字都不给', skeletonFor('attention.', reveal: SkeletonReveal.none),
      '_________.');
  eq('reveal = firstTwo：给前两个', skeletonFor('attention', reveal: SkeletonReveal.firstTwo),
      'at_______');
  eq('空串 → 空串', skeletonFor(''), '');
  eq('整句形状',
      skeletonFor('attention. None of this is new, but the scale is.'),
      'a________. N___ o_ t___ i_ n__, b__ t__ s____ i_.');
  check('骨架长度 == 原文本长度（遮罩不改变字符数）',
      skeletonFor('hello world').length == 'hello world'.length);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('② 句子级归一化 normalizeSentence');
  // ══════════════════════════════════════════════════════════════════════
  eq('句读标点剔除', normalizeSentence('Attention.'), 'attention');
  eq('逗号/叹号 → 词边界（不是删除）', normalizeSentence('Well, then!'), 'well then');
  eq('折叠连续空白 + 去首尾', normalizeSentence('  a   b  '), 'a b');
  eq('撇号保留（词的一部分）', normalizeSentence("don't"), "don't");
  eq('🔴 弯撇号折叠成直撇号（iOS 智能标点）', normalizeSentence('don\u2019t'), "don't");
  eq('🔴 连字符变体折叠', normalizeSentence('e\u2010mail'), 'e-mail');
  eq('全角 → 半角', normalizeSentence('\uFF21\uFF34\uFF34\uFF25\uFF2E\uFF34\uFF29\uFF2F\uFF2E'),
      'attention');
  eq('全角空格 → 半角', normalizeSentence('\u3000a\u3000b\u3000'), 'a b');
  eq('破折号 → 词边界', normalizeSentence('a\u2014b'), 'a b');
  eq('全标点 → 空串', normalizeSentence('...'), '');
  eq('空串 → 空串', normalizeSentence(''), '');

  eq('切词', sentenceWords('Attention. None of this is new, but the scale is.').length, 10);
  eq('空串切词 → 空表', sentenceWords('   ').length, 0);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('③ 默写判定 gradeCloze');
  // ══════════════════════════════════════════════════════════════════════
  const src = 'attention. None of this is new, but the scale is.'; // 10 词

  check('完全一致 ⇒ 记得', gradeCloze(src, src).correct);
  eq('完全一致 ⇒ 错词 0', gradeCloze(src, src).wrongWords, 0);
  check('🔴 少一个逗号不算错（标点被剔除）',
      gradeCloze('attention None of this is new but the scale is', src).correct);
  check('🔴 大小写不敏感', gradeCloze(src.toUpperCase(), src).correct);
  check('🔴 全角输入不算错', gradeCloze('ＡＴＴＥＮＴＩＯＮ．', 'attention.').correct);
  check('🔴 弯撇号 vs 直撇号不算错',
      gradeCloze('don\u2019t stop', "don't stop").correct);

  // 阈值语义：默认 5% ⇒ ≤19 词的内容**错 1 个就判错**（与单词卡同级严格）
  final oneWrong = gradeCloze('attention None of this is new but scale is', src);
  eq('10 词错 1 ⇒ 错词数 1', oneWrong.wrongWords, 1);
  check('🔴 10 词错 1 ⇒ 超过 5% ⇒ 判「忘了」（默认阈值很严）', !oneWrong.correct);

  // 🔴🔴 关键回归：**漏一个词不能造成后面全部错位**
  final missingHead = gradeCloze('b c d e', 'a b c d e');
  eq('🔴 漏首词 ⇒ 编辑距离 1（**不是** 4 —— 退化成「按下标比」就会错位）',
      missingHead.wrongWords, 1);
  final extraMid = gradeCloze('a b x c', 'a b c');
  eq('多写一个词 ⇒ 编辑距离 1', extraMid.wrongWords, 1);

  // 长内容容错：100 词错 5 = 5% ⇒ 记得；错 6 ⇒ 忘了
  final long = List.generate(100, (i) => 'w$i').join(' ');
  final long5 = List.generate(100, (i) => i < 5 ? 'x$i' : 'w$i').join(' ');
  final long6 = List.generate(100, (i) => i < 6 ? 'x$i' : 'w$i').join(' ');
  final g5 = gradeCloze(long5, long);
  final g6 = gradeCloze(long6, long);
  eq('100 词错 5 ⇒ 错词数 5', g5.wrongWords, 5);
  check('🆕 100 词错 5 = 5% ⇒ 记得（长内容自动放宽）', g5.correct);
  check('100 词错 6 > 5% ⇒ 忘了', !g6.correct);

  // 整数比较（不用浮点）
  check('🔴 边界恰好相等时判「记得」（整数比较：5×100 ≤ 100×5）',
      gradeCloze(long5, long).correct);

  // 空输入 / 空原文
  eq('空输入 ⇒ 错词数 = 原文词数', gradeCloze('', src).wrongWords, 10);
  check('空输入 ⇒ 忘了', !gradeCloze('', src).correct);
  check('🔴 空原文 ⇒ 一律判「忘了」（没有内容可判对）', !gradeCloze('x', '').correct);
  eq('空原文 ⇒ 词数 0', gradeCloze('x', '').expectedWords, 0);

  // 阈值可调（「我的 → 记忆」滑动条）
  check('阈值 0 ⇒ 严格全对（与单词卡逐字同级）',
      gradeCloze('a b c', 'a b c', maxWrongPercent: 0).correct &&
          !gradeCloze('a b x', 'a b c', maxWrongPercent: 0).correct);
  check('阈值 30 ⇒ 10 词错 3 也算记得',
      gradeCloze('a b c d e f g h x y z', 'a b c d e f g h i j k', maxWrongPercent: 30).correct);
  eq('🔴 阈值越界被夹紧到上限 30',
      gradeCloze(src, src, maxWrongPercent: 999).maxWrongPercent, kClozeMaxWrongPercent);
  eq('🔴 阈值越界被夹紧到下限 0',
      gradeCloze(src, src, maxWrongPercent: -5).maxWrongPercent, kClozeMinWrongPercent);

  // 对齐路径（结果页标错）
  final diffs = gradeCloze('a x c', 'a b c').diffs;
  eq('对齐路径长度 = 原文词数（无多写时）', diffs.length, 3);
  eq('对齐：第 2 个词是 wrong', diffs[1].kind, ClozeWordKind.wrong);
  eq('对齐：错词能拿到「原文词」与「写的词」',
      '${diffs[1].expected}/${diffs[1].got}', 'b/x');
  eq('mistakes 只含非 ok 项', gradeCloze('a x c', 'a b c').mistakes.length, 1);
  eq('全对时 mistakes 为空', gradeCloze(src, src).mistakes.length, 0);
  eq('漏词在路径里标 missing',
      gradeCloze('a c', 'a b c').diffs.map((d) => d.kind.name).toList().join(','),
      'ok,missing,ok');

  // 反向断言：判定的**两个极端**都必须正确（防「永远 correct」或「永远 again」）
  check('🔴 反向：全对必须 correct（防「永远 again」）', gradeCloze(src, src).correct);
  check('🔴 反向：完全不相关必须 incorrect（防「永远 correct」）',
      !gradeCloze('entirely different words here now ok', src).correct);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('④ 划线合成 id highlight_id');
  // ══════════════════════════════════════════════════════════════════════
  eq('构造', highlightWordId('A1B2-C3'), 'hl:a1b2-c3');
  check('识别：划线 id', isHighlightWordId('hl:abc'));
  check('识别：词库 id **不是**划线 id', !isHighlightWordId('w008732'));
  check('识别：ext: 合成 id **不是**划线 id', !isHighlightWordId('ext:brainstorm'));
  eq('解析', highlightUuidOf('hl:abc'), 'abc');
  eq('解析非划线 id ⇒ null', highlightUuidOf('w008732'), null);
  eq('解析空前缀 ⇒ null', highlightUuidOf('hl:'), null);
  eq('🔴 往返一致', highlightUuidOf(highlightWordId('Uu-1'))!.length, 4);
  check('🔴 三个前缀互不冲突（形态判断必须先问类型）',
      isHighlightWordId('hl:x') &&
          !isHighlightWordId('ext:x') &&
          !isHighlightWordId('w1') &&
          isExternalLooking('ext:x'));

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('⑤ 划线定位 locateSelection');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 为什么需要它：**框架不给偏移量** —— `SelectedContent` 只有 `plainText`
  //    ⇒ 只能拿选中文本去正文明文里反查（见 `highlight_span.dart` 文件头）。
  const page = 'The habit of reading closely is being replaced.';
  final wantStart = page.indexOf('reading'); // 🔑 不写死数字（改文案时会失效）
  eq('定位到文本出现处', locateSelection(plainText: page, picked: 'reading').start, wantStart);
  eq('区间长度 == 选中长度',
      locateSelection(plainText: page, picked: 'reading').end - wantStart, 'reading'.length);
  eq('🔴 同一段出现多次 ⇒ 取**首个**（如实标注的边界）',
      locateSelection(plainText: 'a b a b', picked: 'b').start, 2);
  check('找不到 ⇒ notFound', !locateSelection(plainText: page, picked: 'zzz').isLocated);
  eq('找不到时 start = -1（语义是「位置未知」，**不是** 0）',
      locateSelection(plainText: page, picked: 'zzz').start, -1);
  check('空选中 ⇒ notFound（空内容不该变成一条划线）',
      !locateSelection(plainText: page, picked: '').isLocated);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('⑥ 正文切分 buildTextSegments（渲染用）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 本节的**核心是一条不变量**：切出来的段拼回去必须**逐字等于原文**。
  //    掉字 ⇒ 用户划过的内容在正文里**看不见**，而库里明明有它。
  const body = 'The habit of reading closely is being replaced by skimming.';

  List<HighlightRange> r(int s, int e, [String id = 'h']) =>
      [HighlightRange(id: id, start: s, end: e)];

  /// 拼回原文 + 顺带断言段的 `start` 自洽（不是只看字数）。
  void checkRoundTrip(String label, String src, List<HighlightRange> rs) {
    final segs = buildTextSegments(text: src, ranges: rs);
    check('$label · 拼回 == 原文', segs.map((s) => s.text).join() == src,
        segs.map((s) => s.toString()).join());
    // 段长累加必须等于 start —— 否则「按段反查」会指向错误的位置
    var acc = 0;
    var ok = true;
    for (final s in segs) {
      if (s.start != acc) ok = false;
      acc += s.text.length;
    }
    check('$label · 每段 start == 前段累计长度', ok,
        segs.map((s) => '${s.start}').join(','));
  }

  checkRoundTrip('基本', body, r(body.indexOf('reading'), body.indexOf('reading') + 7));

  final segs1 = buildTextSegments(
      text: body, ranges: r(body.indexOf('reading'), body.indexOf('reading') + 7));
  eq('段数 == 3（普通 / 划线 / 普通）', segs1.length, 3);
  eq('中段是高亮段', segs1[1].isHighlighted, true);
  eq('中段文字 == 划的那段', segs1[1].text, 'reading');
  eq('首段与末段不是高亮段',
      segs1[0].isHighlighted || segs1[2].isHighlighted, false);
  eq('中段 start == 划线起点', segs1[1].start, body.indexOf('reading'));

  // ── 边界 ①：没有划线 ⇒ 单段（渲染层走同一条路径，少一个分支）──
  final none = buildTextSegments(text: body, ranges: const []);
  eq('无区间 ⇒ 1 段', none.length, 1);
  eq('无区间 ⇒ 该段不是高亮', none[0].isHighlighted, false);
  checkRoundTrip('无区间', body, const []);

  // ── 边界 ②：空文本 ──
  eq('空文本 ⇒ 0 段（不是 1 段空串）', buildTextSegments(text: '', ranges: const []).length, 0);
  eq('空文本 + 有区间 ⇒ 0 段（不越界）',
      buildTextSegments(text: '', ranges: r(0, 5)).length, 0);

  // ── 边界 ③：定位失败（start = -1）⇒ 跳过，但**文字不能丢** ──
  checkRoundTrip('start=-1 跳过', body, r(-1, -1));
  eq('start=-1 ⇒ 只有 1 段普通',
      buildTextSegments(text: body, ranges: r(-1, -1)).length, 1);

  // ── 边界 ④：零宽 / 反向区间 ⇒ 跳过 ──
  checkRoundTrip('零宽区间（start==end）', body, r(5, 5));
  eq('零宽 ⇒ 不产生带 id 的段',
      buildTextSegments(text: body, ranges: r(5, 5)).every((s) => !s.isHighlighted),
      true);
  checkRoundTrip('反向区间（start>end）', body, r(9, 4));

  // ── 边界 ⑤：越界 ──
  checkRoundTrip('end 超出长度 ⇒ 钳到末尾', body, r(body.length - 5, body.length + 99));
  final clamped =
      buildTextSegments(text: body, ranges: r(body.length - 5, body.length + 99));
  eq('越界钳制后仍是 2 段（普通 + 高亮到末尾）', clamped.length, 2);
  eq('越界段的文字 == 末尾 5 字符', clamped[1].text, body.substring(body.length - 5));
  checkRoundTrip('start 超出长度 ⇒ 跳过', body, r(body.length + 3, body.length + 9));

  // ── 边界 ⑥：乱序输入 ⇒ 按位置排序输出 ──
  final b1 = body.indexOf('habit');
  final b2 = body.indexOf('closely');
  final unordered = [
    HighlightRange(id: 'B', start: b2, end: b2 + 7),
    HighlightRange(id: 'A', start: b1, end: b1 + 5),
  ];
  final sorted = buildTextSegments(text: body, ranges: unordered);
  checkRoundTrip('乱序输入', body, unordered);
  eq('乱序 ⇒ 输出按位置排（先 habit）', sorted[1].text, 'habit');
  eq('乱序 ⇒ 段的 id 跟着各自的区间（不是输入顺序）', sorted[1].highlightId, 'A');
  eq('乱序 ⇒ 后一段的 id 也对', sorted[3].highlightId, 'B');

  // ── 边界 ⑦：重叠 ⇒ 合并 ──
  final ov = [
    HighlightRange(id: 'X', start: 10, end: 20),
    HighlightRange(id: 'Y', start: 15, end: 25),
  ];
  final ovSegs = buildTextSegments(text: body, ranges: ov);
  checkRoundTrip('重叠 ⇒ 合并', body, ov);
  eq('重叠合并后只有 1 个高亮段',
      ovSegs.where((s) => s.isHighlighted).length, 1);
  eq('合并取并集 [10,25)', ovSegs[1].start, 10);
  eq('合并后的段长 == 15', ovSegs[1].text.length, 15);
  eq('🔴 合并后 id 取**外层**那条（起点更小的）', ovSegs[1].highlightId, 'X');

  // ── 边界 ⑧：端点相接**不算**重叠（两条独立划线，别合并）──
  final adj = [
    HighlightRange(id: 'P', start: 5, end: 10),
    HighlightRange(id: 'Q', start: 10, end: 15),
  ];
  final adjSegs = buildTextSegments(text: body, ranges: adj);
  checkRoundTrip('端点相接', body, adj);
  eq('🔴 端点相接 ⇒ 2 个高亮段（合并会丢掉一条的 id）',
      adjSegs.where((s) => s.isHighlighted).length, 2);
  eq('相接的第一段 id = P', adjSegs[1].highlightId, 'P');
  eq('相接的第二段 id = Q', adjSegs[2].highlightId, 'Q');

  // ── 边界 ⑨：整段被覆盖 ⇒ 没有普通段 ──
  final all = buildTextSegments(text: body, ranges: r(0, body.length));
  checkRoundTrip('全覆盖', body, r(0, body.length));
  eq('全覆盖 ⇒ 1 段且是高亮', all.length, 1);
  eq('全覆盖 ⇒ 该段文字 == 全文', all[0].text, body);

  // ── 边界 ⑩：划到首/尾 ──
  checkRoundTrip('划到开头', body, r(0, 3));
  checkRoundTrip('划到末尾', body, r(body.length - 3, body.length));
  eq('划到开头 ⇒ 首段就是高亮（无空普通段）',
      buildTextSegments(text: body, ranges: r(0, 3))[0].isHighlighted, true);
  eq('划到末尾 ⇒ 末段是高亮（无空尾段）',
      buildTextSegments(text: body, ranges: r(body.length - 3, body.length)).last
          .isHighlighted,
      true);

  // ── 边界 ⑪：多条不重叠 ──
  final multi = [
    HighlightRange(id: 'M1', start: b1, end: b1 + 5),
    HighlightRange(id: 'M2', start: b2, end: b2 + 7),
  ];
  final multiSegs = buildTextSegments(text: body, ranges: multi);
  checkRoundTrip('多条不重叠', body, multi);
  eq('两条 ⇒ 恰好 2 个高亮段',
      multiSegs.where((s) => s.isHighlighted).length, 2);

  // ── 反查：点正文里的一条线 → 打开哪条划线 ──
  final look = buildTextSegments(
      text: body, ranges: r(body.indexOf('reading'), body.indexOf('reading') + 7, 'RID'));
  eq('反查：落在划线上 ⇒ 返回它的 id', highlightIdAt(look, body.indexOf('reading') + 2), 'RID');
  eq('反查：落在普通文字上 ⇒ null', highlightIdAt(look, 0), null);
  eq('反查：区间右端是**开**的（end 本身不算）',
      highlightIdAt(look, body.indexOf('reading') + 7), null);

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('=' * 68);
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    // ignore: avoid_print
    throw StateError('有 ${_failures.length} 项失败');
  }
  print('✅ 划线默写判定 + 合成 id 全部通过');
}

/// 只用于上面那条「前缀互不冲突」的断言 —— 不引入 app 侧实现，避免循环依赖。
bool isExternalLooking(String s) => s.startsWith('ext:');
