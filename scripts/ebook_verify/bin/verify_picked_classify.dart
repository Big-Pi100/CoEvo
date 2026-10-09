// 「选中形态判定」验收（`classifyPicked`）—— 纯 Dart · 本机可跑 · 可进 CI
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_picked_classify.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail` —— 本项目已踩过）。
//
// # 为什么这件事必须单独验
//
// `classifyPicked` 决定**划词菜单第一项**是「查词」还是「翻译」。
// 而它住在 `app/lib/services/picked_text.dart`（**零依赖纯 Dart**）——
// 所以本机能跑（`widgets/word_lookup_selection.dart` import Flutter，跑不了）。
//
// 🔑 判据：**判定逻辑必须本地可验**（同 `spelling_grader.dart` 的理由）。
//    它的边界特别碎：撇号（直/弯）· 连字符（三种码位）· 内部句点 ·
//    重音字母 · 中文 · 纯符号 —— **全靠逐条跑**，读代码看不出来。
//
// # 🔴 本脚本也守着「锚点的两处偏离」
//
// 锚点 `visual-selection-menu-2026-10-07.html` §1 原文写「只由 `[A-Za-z'\-.]` 组成 ⇒ 单词」，
// 有两个反例会让它判错（见下方 `café` / `— attention` 两组）。
// 实现按**意图**放宽了，这组用例把「不许再收回去」钉住。

import '../../../app/lib/services/picked_text.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add('  · $name${detail == null ? '' : '  —— $detail'}');
  }
}

/// 把不可见字符显示出来（否则失败信息里看不出差别）。
String _show(String s) {
  if (s.isEmpty) return '（空串）';
  final buf = StringBuffer('`');
  for (final r in s.runes) {
    if (r == 0x20) {
      buf.write('␠');
    } else if (r > 0x7E) {
      buf.write('\\u${r.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      buf.writeCharCode(r);
    }
  }
  buf.write('`');
  return buf.toString();
}

void _expect(String input, PickedKind want) {
  final got = classifyPicked(input);
  check('${_show(input)} ⇒ ${want.name}', got == want,
      got == want ? null : '实际 ${got.name}');
}

void main() {
  print('');
  print('═══ verify_picked_classify ═══');

  // ══════════════════════════════════════════════════════════════════════
  // ① word —— 「菜单第一项 = 查词」
  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('① 判为 word（第一项「查词」）');
  _expect('attention', PickedKind.word);

  // 拖手柄把相邻标点带进来 —— 标点不是用户选的，是手柄的副产物
  _expect('attention.', PickedKind.word);
  _expect('attention,', PickedKind.word);
  _expect('(attention)', PickedKind.word);

  // 撇号 / 连字符 / 内部句点 **属于词**（词库里含内部标点的词共 64 个）
  _expect("don't", PickedKind.word);
  _expect('e-mail', PickedKind.word);
  _expect('a.m.', PickedKind.word);
  _expect('brother-in-law', PickedKind.word);

  // 🆕 打字机变体 —— 不收就会**静默误判**（正文里就是这些字形）
  _expect('don\u2019t', PickedKind.word); // 弯撇号 U+2019（iOS 智能标点）
  _expect('co\u2010operate', PickedKind.word); // U+2010 连字符
  _expect('co\u2011operate', PickedKind.word); // U+2011 不换行连字符

  // 🆕🔴 偏离锚点①：重音拉丁字母
  //    锚点只写 `[A-Za-z'\-.]` ⇒ 会把下面这些判成「短语」⇒ **没有查词入口**
  //    而词库里真的有它们（`spelling_grader` 实测 3 个非 ASCII 词条）
  //
  // ⚠️ **用例必须能区分「对」与「错」** —— `café` 其实**不具区分力**：
  //    它的重音在**末尾**，会被「剥首尾」顺手剥掉（`café` → `caf`，仍是词）
  //    ⇒ **纯 ASCII 的实现也能过这一条**（假绿）。
  //    所以真正的判据在**重音位于词内**的例子：`naïve` / `résumé` / `français`。
  //    （本组已用注入回归证伪：改回纯 ASCII ⇒ `français` 变红、退出码 1。）
  _expect('caf\u00e9', PickedKind.word); // café（真实用例 · 但见上注：不具区分力）
  _expect('na\u00efve', PickedKind.word); // naïve —— 重音在词内 ✅ 有区分力
  _expect('r\u00e9sum\u00e9', PickedKind.word); // résumé ✅
  _expect('fran\u00e7ais', PickedKind.word); // français ✅

  // 🆕🔴 偏离锚点②：首尾的破折号 / 引号 / 逗号被剥掉
  //    书里高频：对话破折号 · 引号包裹的词
  _expect('\u2014 attention', PickedKind.word); // — attention
  _expect('"attention,"', PickedKind.word);
  _expect('\u201cattention\u201d!', PickedKind.word); // 弯引号 + 叹号

  // 输入卫生：首尾空白（含全角空格 —— 中文输入法下极易打出）
  _expect('  attention  ', PickedKind.word);
  _expect('\u3000attention\u3000', PickedKind.word);

  // 大小写不影响形态（词库本身 `COLLATE NOCASE`）
  _expect('USA', PickedKind.word);
  _expect('Attention', PickedKind.word);

  // ══════════════════════════════════════════════════════════════════════
  // ② phrase —— 「菜单第一项 = 翻译」
  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('② 判为 phrase（第一项「翻译」）');

  // 含空白 ⇒ 多词
  _expect('give up', PickedKind.phrase);
  _expect('attention. None of this is new, but the scale is.', PickedKind.phrase);

  // ⚠️ **有意接受的边界**（锚点 §1 末）：词库里确实有含空格的词条
  //    （`driver's license` 之类），但按「含空白 ⇒ 多词」它们会走翻译。
  //    ⇒ 想查这类词请缩到单个词。**这是一条当前接受的限制，不是 bug。**
  _expect("driver's license", PickedKind.phrase);

  // 剥完首尾后什么都不剩 ⇒ 不是可查的词
  _expect('123', PickedKind.phrase);
  _expect('!!', PickedKind.phrase);
  _expect('...', PickedKind.phrase);
  _expect('\u2014', PickedKind.phrase); // 只有一个破折号
  _expect("'", PickedKind.phrase); // 只有一个撇号（无拉丁字母）

  // 非拉丁文字 ⇒ 一律走翻译
  // 🔴 理由：走「查词」会词库未命中 → 在线制卡 → 服务端 400（只收纯词形）
  //    ⇒ 用户看到一次**无意义的参数错误**。这条断言就是挡它的。
  _expect('\u4e2d\u6587', PickedKind.phrase); // 中文
  _expect('\u6ce8\u610f\u529b', PickedKind.phrase); // 注意力
  _expect('\u041f\u0440\u0438\u0432\u0435\u0442', PickedKind.phrase); // 西里尔

  // 内部非词形字符 ⇒ 不是词
  _expect('a,b', PickedKind.phrase);
  _expect('a/b', PickedKind.phrase);

  // 空 / 只有空白
  _expect('', PickedKind.phrase);
  _expect('   ', PickedKind.phrase);

  // ══════════════════════════════════════════════════════════════════════
  // ③ 结构性断言 —— 防「实现被悄悄改回窄规则」
  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('③ 结构 / 防回退');

  // 判定**只依赖纯字符串** ⇒ 同样的输入永远同样输出（没有隐藏状态）
  check('同一输入重复判定结果一致（无隐藏状态）',
      classifyPicked('attention') == classifyPicked('attention') &&
          classifyPicked('give up') == classifyPicked('give up'));

  // 🔴 反向断言：若有人把实现改回「纯 ASCII」，下面这条会红
  //    （正向断言 `café ⇒ word` 已在上方，这条是它的**反向前提**）
  check(
      '🔴 判定允许重音拉丁字母（改回纯 ASCII 会让 `café` 失去查词入口）',
      classifyPicked('caf\u00e9') == PickedKind.word &&
          classifyPicked('na\u00efve') == PickedKind.word);

  // 🔴 反向断言：非拉丁必须走翻译（否则会造出「400 参数错误」那条坏路径）
  check('🔴 非拉丁文字一律 phrase（挡掉「送去制卡 ⇒ 400」那条坏路径）',
      classifyPicked('\u4e2d\u6587') == PickedKind.phrase &&
          classifyPicked('\u041f\u0440\u0438\u0432\u0435\u0442') == PickedKind.phrase);

  print('');
  print('pass = $_pass · fail = $_fail');
  if (_failures.isNotEmpty) {
    print('失败项：');
    for (final f in _failures) {
      print(f);
    }
  }
  if (_fail > 0) {
    throw StateError('有 $_fail 项失败');
  }
}
