// CoEvo · **整篇朗读接线验收**（信息流阅读器 + 清洗口径唯一化）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_reader_tts.dart
// 🔴 退出码：0 = 全过，1 = 有失败（**直读**，别接 `| tail` —— 管道会把 `$?` 变成 tail 的）。
//
// # 它守什么（四件，全是**静默**失效）
//
// ① **清洗只有一处权威**：`tts_service._cleanText` 必须**委托** `speechTextFromMarkdown`，
//    不得再留一份手写的 `replaceAll` 链。
//    🔴 反例（真事故）：旧实现只去**转义的**方括号 `\[`，而正文里是**普通**方括号
//    ⇒ `[Law](https://www.npr.org/sections/law/)` 的 URL **被逐字念出来**。
//    两份实现并存时，只有一份会随新用例修好 —— 另一份**静默地**留在旧口径上。
//
// ② **阅读器真的接了朗读**：`speakLong`（不是 `togglePlay`）+ `isSpeaking` 判状态
//    + `dispose` 停（**不跨页**）。这三条**都不报错**：
//    · 用 `togglePlay` 读长文 → 超过平台上限 → **静默无声**（真机才知道）
//    · 不判 `isSpeaking` → 点第二次不会停
//    · 不在 dispose 停 → 退出去了声音还在念，用户**找不到在哪关**
//
// ③ **判据的实参必须是「同一份正文」**：`isSpeaking(X)` 与 `speakLong(Y)` 若 X≠Y，
//    按钮**永远显示「空闲」**（点第二次只会重头再念）—— 这是本项目记过的
//    「子串断言锁不到接线」的典型：名字都在，接错了。
//
// ④ **入口位置与形态**：朗读键排在**收藏左边**（收藏仍最右）· **纯图标**（无文字标签）。
//    位置错了不会有任何报错，只是「和设计稿不一致」—— 只有断言能守。
//
// # 🔴 已实测的证伪结果（**10/10**，每一条都 exit=1）
//
// | 注入的回归 | 实测 |
// |---|---|
// | `_cleanText` 换回**真实的旧实现**（从 `git show HEAD:` 取，不是凭记忆重写）| 红 7 项 |
// | 去掉 `<graph>` 清理 | 红 4 项 |
// | 阅读器 `speakLong` → `togglePlay` | 红 3 项 |
// | `final speaking = … isSpeaking(body)` → `isSpeaking('x')` | 红 2 项 |
// | 删掉 `dispose` 里的 stop | 红 2 项 |
// | 朗读键挪到 `BookmarkButton` **之后** | 红 2 项 |
// | `_SpeakButton` 里加 `Text('朗读')` | 红 3 项 |
// | 删掉 `tts_service.dart` 的 import | 红 2 项 |
// | `showSpeak: ttsEnabled` → `true`（关了朗读仍显示键）| 红 2 项 |
// | 删掉「两个朗读键的分工」说明 | 红 2 项 |
//
// ⚠️ 证伪脚本会因**实现改动**而失效（注入串匹配不到）：
//    ⑥ 就曾因加了 `if (showSpeak) ...[` 而**匹配不到** ⇒ 报「证伪无效」而不是「假绿」。
//    📌 判据：**证伪脚本本身也要维护**；「注入串未匹配」必须**显式报错**，
//      否则会被误读成「断言没抓到」（方向相反的结论）。
//
// # 🔴🔴 证伪**抓到 2 处假绿**（这才是证伪的价值 —— 都已在下方注释里标明）
//
// ① **捕获组写窄**：`isSpeaking\(([\w.]+)\)` 匹配不到 `isSpeaking('x')`（字面量含引号）
//    ⇒ 那一项**静默缺项**、并集仍是 `{body}` ⇒ **绿**。
//    📌 判据：**「检测为 0」先证检测器有效** —— 捕获组太窄时，漏检会伪装成「没问题」。
// ② **判据口径差一层**：`dispose` 体里查 `.stop()` —— 而那里还有 `_dwell.stop()`
//    ⇒ **TTS 的 stop 被删掉之后仍是绿的**。差的那一层是「**谁**在被停」。
//    📌 判据：**「判据口径差一层」不报错只给错数** —— 与比例类判据的「分母」同族。
//
// ⚠️ 第一次跑还红过一次（假红）：用**文本位置**判 `_cleanText` 的顺序 ——
//    而 `speechTextFromMarkdown(text.replaceAll(…))` 的**求值顺序**与文本顺序相反。
//    📌 判据：**「文本顺序」≠「求值顺序」**（把 A 套在 B 外面时两者相反）。
//
// # ⚠️ 口径（如实标注）
// · 只 import `dart:io` ⇒ 不需要 Flutter / 真库 / fixture，**本机完整可跑**。
// · 它是**源级断言**：只证明「代码是这么写的」，**不**证明「真机上听着对」。
//   真机要验两件（本轮**未**验）：① 文章朗读有声音 ② 书库整章朗读**没有**退化
//   （`_cleanText` 是三处共用 ⇒ 词卡 / 书库 / 文章）。
// · ⚠️ 曾有一条排除说明：`app/lib/services/speech_text.dart.bak` 是历史备份。
//   🆕 2026-10-06 该文件**已删**（白哥「备份清理」）—— 它是「两段式 pass」旧实现的
//   孤本（git 里没有），且那个实现的缺陷已完整写在正式版
//   「🔴🔴 为什么必须合并成一次遍历」的注释里 ⇒ 保留无价值。
//   本脚本只读 `.dart` 正式文件（`.bak` 不参与编译，也不该被断言）。

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

void section(String s) {
  print('');
  print('─' * 74);
  print(s);
  print('─' * 74);
}

/// 剥掉**整行**注释。
///
/// 🔴 必须是整行 —— 「每行找 `//` 切后半」会把**代码里的 `//`** 当注释起点
/// （`'https://host/path'` / `RegExp(r'…://…')`）⇒ 后半段消失 ⇒ **反向断言假绿**。
/// 本项目已踩过（实测 5 处里 3 处是错的），这里是修好的那一形态。
/// ⚠️ 已知代价：**行尾注释不被剥**（不假装没有）。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String readNoComment(String rel) => stripComments(File(rel).readAsStringSync());

/// 取 `signature` 所在的方法/函数**体**（按大括号配平）。
///
/// ⚠️ 不是「找下一个 `}`」—— 体内还有嵌套块（`if` / `RegExp` 字面量等）。
/// 🔑 配平会跳过**字符串字面量里的括号**吗？—— 不会，本实现不感知字符串。
///    代价是「体内含不成对括号的字符串」时会切错 ⇒ 所以调用点都断言了切片长度，
///    切片为空/异常时**报红**而不是静默通过（见 `body()` 的返回 `null` 处理）。
String? extractBody(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) return null;
  final open = src.indexOf('{', i);
  if (open < 0) return null;
  var depth = 0;
  for (var j = open; j < src.length; j++) {
    final c = src[j];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, j);
    }
  }
  return null;
}

/// 取一个**类**的切片（从 `class X` 到下一个 `class ` 之前）。
String? extractClass(String src, String name) {
  final i = src.indexOf('class $name');
  if (i < 0) return null;
  final next = src.indexOf('\nclass ', i + 1);
  return next < 0 ? src.substring(i) : src.substring(i, next);
}

String read(String rel) => File(rel).readAsStringSync();

void main() {
  print('');
  print('#' * 74);
  print('# 整篇朗读接线验收 —— 清洗一处权威 · 阅读器接线 · 入口位置与形态');
  print('#' * 74);

  final ttsSrc = readNoComment('../../app/lib/services/tts_service.dart');
  final readerSrc = readNoComment('../../app/lib/screens/reader_screen.dart');
  final bookSrc = readNoComment('../../app/lib/screens/book_reader_screen.dart');
  // ⚠️ 用**含注释**的原文 —— 判断「代码里有没有某个类」时注释不该干扰。
  //    （本脚本只在**剥注释后**的文本上做「不得出现」类断言。）
  final readerRaw = read('../../app/lib/screens/reader_screen.dart');

  // ══════════════════════════════════════════════════════════
  section('【1】`_cleanText` 委托给 `speechTextFromMarkdown`（一处权威）');
  // ══════════════════════════════════════════════════════════
  final cleanBody = extractBody(ttsSrc, 'String _cleanText(');
  check('能定位 `_cleanText` 的方法体', cleanBody != null,
      cleanBody == null ? '未找到签名 —— 方法被改名/删除？' : '');
  final cb = cleanBody ?? '';

  check('🔴 体内**调用**了 `speechTextFromMarkdown(`',
      cb.contains('speechTextFromMarkdown('),
      '这是「一处权威」的全部意义 —— 不调它，本页的 URL 就会念出来');
  check('  `tts_service.dart` import 了 `speech_text.dart`',
      ttsSrc.contains("import 'speech_text.dart';"), '');

  // ══════════════════════════════════════════════════════════
  section('【2】🔴 反向：手写剥标记的 `replaceAll` 链**不得残留**（否则两处权威）');
  // ══════════════════════════════════════════════════════════
  //
  // ⚠️ 断言的是**这个 bug 的形态**，不是「不许出现 replaceAll」——
  //    `_cleanText` 里合法地保留了 `<graph>` 的那一条（【3】）。
  check('没有 `.replaceAll(\'**\', \'\')`（旧实现的第一条）',
      !cb.contains("replaceAll('**'"), '');
  check('没有 `### ` / `## ` / `# ` 的硬编码剥标题',
      !cb.contains("replaceAll('### '") &&
          !cb.contains("replaceAll('## '") &&
          !cb.contains("replaceAll('# '"), '');

  // ⚠️ 反斜杠类的那两条**必须用正则**，不能写死字面量 ——
  //    Dart 源码里 `.replaceAll('\[', '')` 有两种写法：
  //      · `replaceAll('\[', '')`  ← **一个**反斜杠（会让 Dart 报 `\W` 类警告）
  //      · `replaceAll('\\[', '')` ← **两个**（正确：字符串值才是一个 `\`）
  //    🔴 本脚本第一版只写了**一种** ⇒ 另一种**匹配不上** ⇒ 「改回去也不红」= **假绿**。
  //    📌 判据：**锁「语义形状」（正则）不锁「拼写」（字面量）** ——
  //      本项目已三令五申；这次是「同一条规则的不同书写形式」这个变体。
  //    ✅ 用 `\\+` 同时覆盖一个/多个反斜杠；`\[` 与 `\]` 各查一次。
  final legacyBracket = RegExp(r"replaceAll\('\\+\[',\s*''\)").hasMatch(cb) ||
      RegExp(r"replaceAll\('\\+\]',\s*''\)").hasMatch(cb);
  check('🔴🔴 没有只去「转义的」方括号（**这就是那个真事故**）', !legacyBracket,
      r"`\[` 那条规则对 `[Law](https://…)` **完全无效** ⇒ URL 被逐字念出来");
  final legacyParen = RegExp(r"replaceAll\('\\+\(',\s*''\)").hasMatch(cb) ||
      RegExp(r"replaceAll\('\\+\)',\s*''\)").hasMatch(cb);
  check('没有只去「转义的」圆括号', !legacyParen, '');

  // ══════════════════════════════════════════════════════════
  section('【3】TTS 特有的 `<graph>` 清理**必须保留**（委托前先删）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 为什么不能靠 `speechTextFromMarkdown`：它的 HTML 标签规则会剥掉
  //    `<graph>` **标签本身**，却**留下里面的图形 JSON**（那段会被逐字念出来）。
  check('体内仍有 `<graph>` 的整体删除',
      cb.contains('<graph>') && cb.contains('</graph>'),
      '漏了 ⇒ 图形 JSON 会被念出来');
  check('  且是 `dotAll: true` 的**跨行**匹配（图形 JSON 是多行的）',
      cb.contains('dotAll: true'), '');
  // 🔑 顺序判据：**不能用「文本里的先后位置」** ——
  //    实现写成 `speechTextFromMarkdown(text.replaceAll(RegExp(…), ''))` 时，
  //    外层调用名在**文本上先出现**，但它**求值在实参之后**。
  //    按位置比较会**反向误判**（本脚本第一版就踩到，红了一次）。
  //    📌 判据：**「文本顺序」≠「求值顺序」** —— 把 A 套在 B 外面时两者相反。
  //    ⇒ 形状判据应为：`<graph>` 的删除**落在委托调用的实参里**。
  final delegateCall = RegExp(r'speechTextFromMarkdown\(([\s\S]*?)\)\s*;')
      .firstMatch(cb);
  final argText = delegateCall?.group(1) ?? '';
  check('🔑 `<graph>` 删除在委托调用的**实参**里（求值 = 先删图形、再委托）',
      argText.contains('<graph>') && argText.contains('replaceAll'),
      delegateCall == null
          ? '未匹配到 `speechTextFromMarkdown(…);` 的调用形状'
          : '实参里 graph=${argText.contains('<graph>')} replaceAll=${argText.contains('replaceAll')}');

  // ══════════════════════════════════════════════════════════
  section('【4】阅读器：朗读入口真的接上了（不是「写了没人调」）');
  // ══════════════════════════════════════════════════════════
  check('`reader_screen` import 了 `tts_service.dart`',
      readerSrc.contains("import '../services/tts_service.dart';"), '');
  check('🔴 调的是 `speakLong(`（整篇）—— **不是** `togglePlay`',
      readerSrc.contains('speakLong(') && !readerSrc.contains('togglePlay'),
      '`togglePlay` 一次交全文 ⇒ 超平台上限 ⇒ **静默无声**（书库踩过同一个坑）');
  check('  用 `isSpeaking(` 判「这篇在播吗」',
      readerSrc.contains('isSpeaking('), '');

  // ══════════════════════════════════════════════════════════
  section('【5】阅读器：点一下 = 「在播就停，没播就读整篇」');
  // ══════════════════════════════════════════════════════════
  final toggleBody = extractBody(readerSrc, 'void _toggleSpeech(');
  check('能定位 `_toggleSpeech` 的方法体', toggleBody != null,
      toggleBody == null ? '未找到签名' : '');
  final tb = toggleBody ?? '';
  check('  有 `isSpeaking(` 分流', tb.contains('isSpeaking('), '');
  check('  「在播」分支调 `stop()`', tb.contains('.stop()'), '');
  check('  「没播」分支调 `speakLong(`', tb.contains('speakLong('), '');

  // ══════════════════════════════════════════════════════════
  section('【6】🔴 实参同一性：`isSpeaking(X)` 与 `speakLong(Y)` 必须 X == Y');
  // ══════════════════════════════════════════════════════════
  //
  // 📌 这是本脚本**最重要**的一条 —— 本项目记过「**子串断言锁不到接线**」：
  //    两个名字都在文件里，但传的**不是同一份文本** ⇒ 按钮永远显示「空闲」，
  //    点第二次只会**从头再念一遍**（用户以为「停不掉」）。
  //    用**捕获比较**而不是字符串常量比较 ⇒ 对改名免疫，但锁住了同一性。
  final argsInToggle = RegExp(r'(?:isSpeaking|speakLong)\(\s*([\w.]+)\s*\)')
      .allMatches(tb)
      .map((m) => m.group(1))
      .whereType<String>()
      .toSet();
  check('🔴 两个调用取到**同一个实参**', argsInToggle.length == 1,
      '实参集合 = $argsInToggle（应只有 1 个）');

  // 按钮侧：`onToggleSpeech: () => _toggleSpeech(X)`
  final callArgs = RegExp(r'_toggleSpeech\(\s*([^)]*)\)')
      .allMatches(readerSrc)
      .map((m) => (m.group(1) ?? '').trim())
      .where((s) => s.isNotEmpty && !s.startsWith('String '))
      .toSet();
  check('🔴 按钮把**正文**传进去（`_toggleSpeech(正文)`）', callArgs.length == 1,
      '传入实参集合 = $callArgs（应只有 1 个）');
  check('  传入的不是字面量/其它变量（语义：整篇正文）',
      callArgs.length == 1 && !callArgs.first.contains("'"),
      '$callArgs');

  // `speaking` 也必须来自同一个 `isSpeaking(...)`
  //
  // ⚠️ 捕获组用 `([^)]*)`（**任意实参**）而不是 `([\w.]+)`（只认标识符）——
  //    证伪时实测踩到：注入 `isSpeaking('x')` 后正则**不匹配**（字面量含引号），
  //    于是这一项**静默缺项**、并集仍是 `{body}` ⇒ **假绿**。
  //    📌 判据：**「检测为 0」先证检测器有效** —— 捕获组写窄了，漏检会伪装成「没问题」。
  final speakingDecl =
      RegExp(r'final\s+speaking\s*=\s*[\w.]*isSpeaking\(\s*([^)]*)\s*\)')
          .firstMatch(readerSrc);
  check('  确实有 `final speaking = … isSpeaking(…)` 这一行（检测器有效）',
      speakingDecl != null,
      '没这行 ⇒ 下面那条「同一实参」会因缺项而**假绿**');
  // 定义处的**形参名**（`void _toggleSpeech(String body)`）
  final paramDecl =
      RegExp(r'void\s+_toggleSpeech\(\s*String\s+(\w+)\s*\)').firstMatch(readerSrc);

  // 🔴🔴 把**四处**（托盘回调的实参 · 方法形参 · 方法内的两个调用 · `speaking` 的来源）
  //     并成一个集合比较 —— 任何一处与其他三处不一致，按钮就会「显示空闲但停不掉」。
  //
  // ⚠️ 为什么必须**合并**比：本脚本第一版把它们分成四条独立断言，
  //    只检查「各自存在」⇒ 证伪时实测**漏掉**了一个真回归（④）：
  //    把 `final speaking = tts.isSpeaking(body)` 改成 `isSpeaking('x')`，
  //    四条断言**全绿** —— 典型的「**子串断言锁不到接线**」。
  //    📌 判据：同一件事的多处实参要**两两比对**，不是「各自存在」。
  final allArgs = <String>{
    ...argsInToggle, // 方法体内 isSpeaking/speakLong 的实参
    ...callArgs, // 托盘回调传入的实参
    if (speakingDecl != null) speakingDecl.group(1)!.trim(),
    if (paramDecl != null) paramDecl.group(1)!,
  };
  check('🔴🔴 四处（回调实参/形参/方法内两处/`speaking` 来源）是**同一个**',
      allArgs.length == 1 && allArgs.isNotEmpty,
      '并集 = $allArgs（应只有 1 个元素）');

  // ══════════════════════════════════════════════════════════
  section('【7】不跨页：`dispose` 里停朗读');
  // ══════════════════════════════════════════════════════════
  final disposeBody = extractBody(readerSrc, 'void dispose()');
  check('能定位 `dispose` 的方法体', disposeBody != null, '');
  //
  // 🔴🔴 **必须指定「接收者与 TTS 有关」，不能只查 `.stop()`** ——
  //    证伪时实测踩到（⑤ 假绿）：本页 `dispose` 里还有 `_dwell.stop()` /
  //    （`ScrollController` 的 `dispose()`）⇒ 一个宽松的 `.stop()` 断言，
  //    在**TTS 的 stop 被删掉之后仍然是绿的**。
  //    📌 判据：**「判据口径差一层」不报错只给错数** —— 这里差的那一层是「谁在被停」。
  //    ✅ 修法：抓出**接收者**，要求其中至少一个是 TTS 服务（名字含 `tts`，大小写不敏感）
  //       ⇒ 既精确、又对「改成局部变量再 stop」这类重构友好（不能锁死 `ttsServiceProvider` 拼写）。
  final stopReceivers = RegExp(r'([\w.$?]+(?:\([^()]*\))?)\s*\.\s*stop\(\)')
      .allMatches(disposeBody ?? '')
      .map((m) => m.group(1)!)
      .toList();
  check('🔴 `dispose` 停的是**朗读**（接收者与 TTS 有关 · 白哥 2026-10-06 定「不跨页」）',
      stopReceivers.any((r) => r.toLowerCase().contains('tts')),
      '实测接收者 = $stopReceivers（`_dwell.stop()` 那种不算 —— 它正是⑤假绿的来源）');

  // ══════════════════════════════════════════════════════════
  section('【8】与书库**同一套判据**（不是各写一份）');
  // ══════════════════════════════════════════════════════════
  check('书库也用 `isSpeaking(`', bookSrc.contains('isSpeaking('), '');
  check('书库也用 `speakLong(`', bookSrc.contains('speakLong('), '');
  final bookDispose = extractBody(bookSrc, 'void dispose()') ?? '';
  check('书库 `dispose` 也 `stop()`（先例）', bookDispose.contains('.stop()'), '');
  check('两处图标是**同一对**：`play_circle_outline` / `stop_circle_outlined`',
      readerSrc.contains('Icons.play_circle_outline') &&
          readerSrc.contains('Icons.stop_circle_outlined') &&
          bookSrc.contains('Icons.play_circle_outline') &&
          bookSrc.contains('Icons.stop_circle_outlined'),
      '');

  // ══════════════════════════════════════════════════════════
  section('【9】入口位置：朗读键排在**收藏左边**（收藏仍最右）');
  // ══════════════════════════════════════════════════════════
  //
  // ⚠️ 在 `_ReaderBar` 的 `build` 体里比索引 —— 用**类切片**再取 `build`，
  //    否则 `indexOf` 会先命中别的类里的同名符号（本文件有多个 `build`）。
  final barClass = extractClass(readerRaw, '_ReaderBar');
  check('能定位 `_ReaderBar` 类', barClass != null, '');
  final barBuild = extractBody(stripComments(barClass ?? ''), 'Widget build(');
  check('能定位 `_ReaderBar.build`', barBuild != null, '');
  final bb = barBuild ?? '';
  final speakIdx = bb.indexOf('_SpeakButton(');
  final bookmarkIdx = bb.indexOf('BookmarkButton(');
  check('  build 里两个键都出现',
      speakIdx >= 0 && bookmarkIdx >= 0, 'speak=$speakIdx bookmark=$bookmarkIdx');
  check('🔴 朗读键在**收藏之前**（= 视觉上收藏在最右）',
      speakIdx >= 0 && bookmarkIdx >= 0 && speakIdx < bookmarkIdx,
      '顺序反了 ⇒ 收藏不再是「最右的动作」（白哥 2026-10-05 定的规则）');

  // ══════════════════════════════════════════════════════════
  section('【10】形态：**纯图标**（无文字标签）· 平面（不粘土）');
  // ══════════════════════════════════════════════════════════
  final speakClassRaw = extractClass(readerRaw, '_SpeakButton');
  check('能定位 `_SpeakButton` 类', speakClassRaw != null, '');
  final sc = stripComments(speakClassRaw ?? '');
  check('🔴 类体内**没有** `Text(` —— 纯图标（白哥 2026-10-06 定）',
      sc.isNotEmpty && !sc.contains('Text('),
      '加了文字会把同行的分类挤成省略号');
  check('  用的是 `InkWell`（平面）而不是 `Clay`（粘土）',
      sc.contains('InkWell') && !sc.contains('Clay'),
      '阅读页只允许**一个**粘土 = 书签（spec §八的边界，见 `reader_screen` 类注释）');
  check('  图标尺寸与书库同档（`_iconSize = 22`）',
      RegExp(r'_iconSize\s*=\s*22\b').hasMatch(sc),
      '两个入口读同一件事，图标不该有第二套尺寸');

  // ══════════════════════════════════════════════════════════
  section('【11】反向：阅读页**自己不多造**粘土（唯一那个来自书签组件）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 为什么守这条：`reader_screen` 的类注释里写着「顶部栏的书签按钮是**唯一的粘土**」。
  //    本页再自己造一个，那条注释就变成**假话** —— 而注释是后来人判断边界的唯一依据。
  //
  // ⚠️ 断言口径要说清：书签那个粘土在 **`widgets/bookmark_button.dart`**（本页只是用它）
  //    ⇒ 本页**应该 0 次**。第一版断言写「应为 1 次」，**红了一次**（假红）——
  //    它把「跨文件的组件」当成了「本文件的代码」。
  //    📌 判据：**断言的范围必须等于被测对象的范围**（同族：本项目记过的
  //      「注释里提到 ≠ 代码里写了」——这里反过来：「别的文件里的 ≠ 本文件里的」）。
  final readerClayCount = RegExp(r'\bClay\(').allMatches(readerSrc).length;
  check('  `reader_screen` 自己 `Clay(` 0 次（不引粘土组件）',
      readerClayCount == 0, '实测 $readerClayCount 次');
  check('  也未 import `theme/clay.dart`',
      !readerSrc.contains("clay.dart"), '');

  // ══════════════════════════════════════════════════════════
  section('【12】关了朗读 ⇒ **不渲染**朗读键（不留「点了没反应」的键）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 判据（本项目既有）：「**静默失败 + 无出口」比「报错」更糟**。
  //    词卡的 5 个喇叭**早就遵守**（`widgets/speak_button.dart` 在
  //    `ttsEnabledProvider == false` 时返回 `SizedBox.shrink()`）。
  //    ⇒ 新入口必须也遵守 —— 这是「**同族功能的既有约定**」。
  //    ⚠️ 第一版实现**漏了**这条，是**扫尾时跨文件扫同类实现**才发现的
  //      （对齐「显式提出的需求」不够，还要扫「同族已有的约定」）。
  check('🔴 阅读器读了 `ttsEnabledProvider`',
      readerSrc.contains('ttsEnabledProvider'),
      '不读它 ⇒ 关了朗读仍显示按钮 ⇒ 点了没反应');
  check('  `showSpeak` 由它决定（不是写死 `true`）',
      RegExp(r'showSpeak:\s*\w*(ttsEnabled|enabled)').hasMatch(readerSrc), '');
  check('  朗读键是**条件渲染**（`if (showSpeak)`）',
      RegExp(r'if\s*\(\s*showSpeak\s*\)').hasMatch(readerSrc),
      '渲染成「禁用态」也不对：禁用态与「不存在」是两种不同的产品决策');

  // ══════════════════════════════════════════════════════════
  section('【13】两个朗读键的**分工必须写下来**（防「顺手合并」）');
  // ══════════════════════════════════════════════════════════
  //
  // ⚠️ `widgets/speak_button.dart` 的类文档原本写着「全应用**唯一**一处定义」——
  //    本页加了第二个朗读键后，**那句话就变成假话**（断言口径：
  //    「**声明**与**配置**必须一致」）。已改为「**词卡场景**的唯一一处定义」+ 分工表。
  //
  // 🔴 为什么这条重要：不写明，后来人会看到两个喇叭、两套图标，
  //    顺手合并 → 把**长文**交给 `togglePlay` → **静默无声**（回到书库那个坑）。
  //
  // ⚠️ 必须读**含注释**的原文 —— 那段分工全在 `///` 里，剥注释就查不到（会假红）。
  //    📌 判据：**断言的范围必须等于被测对象的范围**。
  final speakBtnRaw = read('../../app/lib/widgets/speak_button.dart');
  check('🔴 `speak_button.dart` 已写明与阅读器键的分工',
      speakBtnRaw.contains('_SpeakButton'),
      '不写明 ⇒ 后来人会顺手合并，然后把长文交给 `togglePlay`');
  check('  且不再自称「全应用唯一」',
      !speakBtnRaw.contains('全应用**唯一**一处定义'), '那句已随本页的加入变成假话');

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
    print('🔑 最可能的原因（这几条**都不报错**，只有真机能听出来）：');
    print('   · 清洗没委托 ⇒ 正文里的 URL 被逐字念出来（NPR 正文很常见）');
    print('   · 用了 `togglePlay` 读长文 ⇒ 超平台上限 ⇒ 静默无声');
    print('   · `isSpeaking` 与 `speakLong` 传的不是同一份文本 ⇒ 停不掉');
    print('   · `dispose` 没停 ⇒ 退出后还在念');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
