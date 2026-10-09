// CoEvo · 翻译端侧**接线**验收
//   ① 译文浮层的来源标题：有实参、且不是 id、且浮层真的用了它
//   ② 未登录态**必须有出口**（不是只留一句「请去登录」）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_translation_wiring.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（这一类问题的形状：「有实现、无接线」）
//
// `showTranslationSheet` 从 2026-10-07 起就有 `sourceLabel` 参数，浮层也把它渲染成
// 顶栏那句「翻译 · 来自 XXX」—— 但**两个阅读页都没传** ⇒ 这一整块 UI 从未显示过。
// · analyzer **不会报**（可空参数不传是合法的）
// · 真机上也**看不出少**（一句本来就不该出现的话，没出现不像 bug）
// ⇒ 只有结构断言能守住。这与 `verify_auth_entry.dart` 守的是同一类东西。
//
// # 🔴 本脚本自身的证伪方式（改断言后必须各跑一遍）
//
// · 删掉 `book_reader_screen.dart` 里的 `title: ch.bookTitle,`
//   → 第 ①-1 条必须变红
// · 把 `reader_screen.dart` 的 `title: item.title,` 改成 `title: sourceId,`
//   → 第 ①-2 条必须变红
// · 把 `translation_sheet.dart` 里 `TranslateNeedLogin()` 那一态的
//   `_Action(label: '去登录' ...)` 整块删掉
//   → 第 ②-1 条必须变红
//
// # ⚠️ 口径（如实标注）
//
// · 本脚本只做**词法级**扫描（剥整行注释 + 括号配对取块）⇒ 能锁住
//   「实参存在 / 不是 id / 动作数够」，**不能**替代真机点一次。
// · 「浮层真的用了 sourceLabel」这条是通过**引用存在**判定的 ——
//   它挡得住「参数收了完全不用」，但挡不住「传了却渲染成空白」
//   （那要看 `_header` 的逻辑，属真机范畴）。
// · 🔑 **剥注释只能按整行剥**（本项目判据：切 `//` 会把 `https://` 里的 `//` 切掉）。

import 'dart:io';

import '_repo_paths.dart';

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

/// 剥掉**整行**注释（行首到行尾 `//` 之后全丢）。
///
/// 🔑 按整行剥而不是「切 `//`」：切法会把字符串里的 `//`（如 URL）切掉 ⇒ **漏检**。
///    代价是行内注释（`foo(); // 说明`）剥不掉 —— 可接受：
///    本脚本查的是「构造函数实参」，它不会写在行内注释里。
String _stripLineComments(String source) => source
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? '' : l)
    .join('\n');

/// 返回 [openIdx]（指向 `(`）所配对的 `)` 的下标；不配对时返回 `-1`。
///
/// ⚠️ 必须跳过**字符串**与**行注释** —— 否则 `'('` 之类会打乱深度计数
///    （本项目记过的「括号配对没跳字符串 ⇒ 静默取错块」）。
int _matchParen(String s, int openIdx) {
  var depth = 0;
  var i = openIdx;
  var inStr = false;
  var q = '';
  while (i < s.length) {
    final c = s[i];
    if (inStr) {
      if (c == r'\') {
        i += 2; // 转义字符：连它的目标一起跳过
        continue;
      }
      if (c == q) inStr = false;
    } else if (c == "'" || c == '"') {
      inStr = true;
      q = c;
    } else if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      final nl = s.indexOf('\n', i);
      if (nl < 0) break;
      i = nl;
      continue;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// 取出源码里**每一处** `marker(` 的实参块（不含 `marker(` 本身，含到配对的 `)`）。
///
/// ⚠️ [marker] **必须带上结尾的 `(`**（如 `'HighlightSource('`）——
///    不带的话「后面紧跟 `(`」这个判断就没了，会把同名前缀的标识符也算进来。
///
/// 🔑 用括号配对而不是正则 `marker\((.*?)\)`：后者遇到嵌套
///    （实参里还有函数调用）就会**提前截断**，取到的块缺尾巴
///    ⇒ 断言看着像通过其实是**假绿**。
List<({String block, int line})> _callBlocks(String source, String marker) {
  assert(marker.endsWith('('), 'marker 必须带结尾的 (');
  final out = <({String block, int line})>[];
  var from = 0;
  while (true) {
    final at = source.indexOf(marker, from);
    if (at < 0) break;
    final open = at + marker.length - 1; // 指向 `(`
    from = open + 1;
    final close = _matchParen(source, open);
    if (close < 0) continue;
    out.add((
      block: source.substring(open + 1, close),
      line: '\n'.allMatches(source.substring(0, at)).length + 1,
    ));
  }
  return out;
}

void main() {
  final lib = 'app/lib';

  String read(String rel) {
    final f = File(repoPath('$lib/$rel'));
    if (!f.existsSync()) {
      throw StateError('读不到 $rel —— 路径或文件名变了，本断言已失效（不是通过）');
    }
    return _stripLineComments(f.readAsStringSync());
  }

  final selection = read('widgets/word_lookup_selection.dart');
  final sheet = read('widgets/translation_sheet.dart');
  final reader = read('screens/reader_screen.dart');
  final bookReader = read('screens/book_reader_screen.dart');
  final app = read('app.dart');

  // ══════════════════════════════════════════════════════════════
  // ① 译文浮层的来源标题
  // ══════════════════════════════════════════════════════════════
  print('');
  print('① 来源标题（浮层顶栏「翻译 · 来自 XXX」）');

  // `HighlightSource(` 的定义处与全部构造处 —— 定义处含 `this.title`，
  // 构造处必须写 `title:`（断言同一个词，两处都覆盖）。
  final allSources = <({String block, int line, String file})>[
    for (final b in _callBlocks(selection, 'HighlightSource('))
      (block: b.block, line: b.line, file: 'word_lookup_selection.dart'),
    for (final b in _callBlocks(reader, 'HighlightSource('))
      (block: b.block, line: b.line, file: 'reader_screen.dart'),
    for (final b in _callBlocks(bookReader, 'HighlightSource('))
      (block: b.block, line: b.line, file: 'book_reader_screen.dart'),
  ];

  check(
    '①-0 扫到了 `HighlightSource(` 块（定义 1 + 构造 2 = 3）'
    '—— 扫不到说明 marker 已失效，后面的「全过」是空过',
    allSources.length == 3,
    '实际 ${allSources.length} 处：'
    '${allSources.map((e) => '${e.file}:${e.line}').join(' / ')}',
  );

  final missing = allSources
      .where((e) => !RegExp(r'\btitle\b').hasMatch(e.block))
      .toList();
  check(
    '①-1 每处 `HighlightSource(...)` 都带 `title`'
    '（漏了 ⇒ 浮层顶栏永远只写「翻译」，而 UI 看着「本来就该这样」）',
    missing.isEmpty,
    missing.isEmpty
        ? ''
        : '缺：${missing.map((e) => '${e.file}:${e.line}').join(', ')}',
  );

  // 🔴 「界面上显示内部标识」：title 传成 id 是最可能的退化写法
  final idAsTitle = <String>[];
  for (final e in allSources) {
    final m = RegExp(r'\btitle\s*:\s*(.*)').firstMatch(e.block);
    if (m == null) continue;
    final v = m.group(1)!.trim();
    if (RegExp(r'(articleId|bookId|sourceId)').hasMatch(v)) {
      idAsTitle.add('${e.file}:${e.line} → $v');
    }
  }
  check(
    '①-2 `title` 不能传 id（`articleId` / `bookId` / `sourceId`）'
    '—— 那是给用户看一串内部标识',
    idAsTitle.isEmpty,
    idAsTitle.isEmpty ? '' : idAsTitle.join(' / '),
  );

  // 调用点（浮层的入口参数）
  final showCalls = _callBlocks(selection, 'showTranslationSheet(');
  check(
    '①-3 找到了 `showTranslationSheet(` 的调用点',
    showCalls.isNotEmpty,
    '${showCalls.length} 处',
  );
  check(
    '①-4 调用点传了 `sourceLabel:`'
    '（不传 ⇒ ①-1 白做：参数通到门口就断了）',
    showCalls.every((c) => c.block.contains('sourceLabel:')),
  );

  check(
    '①-5 浮层**确实消费**了 `sourceLabel`（`_header` 里引用 `widget.sourceLabel`）'
    '—— 防「参数收了不用」',
    sheet.contains('widget.sourceLabel') &&
        RegExp(r'final label\s*=\s*widget\.sourceLabel').hasMatch(sheet),
  );

  // ══════════════════════════════════════════════════════════════
  // ② 未登录态必须有出口
  // ══════════════════════════════════════════════════════════════
  print('');
  print('② 未登录态的出口');

  // 取 `TranslateNeedLogin()` 后面那一段 `_message(...)` 的实参块
  final loginAt = sheet.indexOf('TranslateNeedLogin()');
  check(
    '②-0 找到了 `TranslateNeedLogin()` 分支',
    loginAt >= 0,
  );

  var loginBlock = '';
  if (loginAt >= 0) {
    final msgAt = sheet.indexOf('_message(', loginAt);
    if (msgAt >= 0) {
      final open = sheet.indexOf('(', msgAt);
      final close = _matchParen(sheet, open);
      if (close > 0) loginBlock = sheet.substring(open + 1, close);
    }
  }

  check(
    '②-0b 取到了该分支的 `_message(...)` 块（取不到 ⇒ 下面两条是空过）',
    loginBlock.isNotEmpty,
  );

  final actionCount = '_Action('.allMatches(loginBlock).length;
  check(
    '②-1 未登录态给了 **≥2 个**出口（「去登录」+ 一个关掉的路径）'
    '—— 只剩一个「知道了」会让用户读到「登录后可翻译」却无处可去',
    actionCount >= 2,
    '实际 $actionCount 个',
  );

  check(
    '②-2 其中一个出口是「去登录」',
    loginBlock.contains("label: '去登录'"),
  );

  // 点了「去登录」必须**先关浮层**再跳 —— 不关的话浮层压在「我的」页上面，
  // 用户会以为「点了没反应」。
  var loginActionBlock = '';
  final dlAt = loginBlock.indexOf("label: '去登录'");
  if (dlAt >= 0) {
    final actAt = loginBlock.lastIndexOf('_Action(', dlAt);
    if (actAt >= 0) {
      final open = loginBlock.indexOf('(', actAt);
      final close = _matchParen(loginBlock, open);
      if (close > 0) loginActionBlock = loginBlock.substring(open + 1, close);
    }
  }
  check(
    '②-3 「去登录」的动作里**先 `pop()`**（不关浮层就跳 ⇒ 浮层盖在新页面上）',
    loginActionBlock.contains('pop()'),
  );

  check(
    '②-4 跳转目标 `/mine` 在路由表里真实存在'
    '（写错路径 ⇒ 点了跳到 404 兜底页）',
    RegExp(r"path:\s*'/mine'").hasMatch(app),
  );

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
    print('🔑 最可能的两个原因：');
    print('    · 新增了阅读页（或改了 `HighlightSource`），但**没传 `title`** ——');
    print('      浮层顶栏会永远只写「翻译」，而界面上看不出「少了一句话」。');
    print('    · 未登录态被改回单按钮 —— 用户读到「登录后可翻译」却**无处可去**。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
