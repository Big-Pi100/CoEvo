// CoEvo · 「选中的是什么」—— 划词菜单第一项靠它决定（**纯 Dart · 本机可独立验证**）
//
// # 它只回答一个问题
//
// **选中的这段，是一个「可查的词」，还是一段「多词内容」？**
//
// 用途**单一**：决定划词菜单**第一项**是「查词」还是「翻译」。
//
// 🔴🔴 它**不参与查词** —— 真正送进 `lookupWord` 的永远是**原始选中文本**。
//    反例（`widgets/word_lookup_selection.dart` 头部已记录）：
//    `a.m.` / `dr.` 的词条**本身就带句点**，剥掉再查反而查不到。
//    ⇒ 「剥标点」这件事**只发生在判定里**，绝不外流到查询层。
//
// # 🔴 为什么单独成一个文件（而不是写在组件里）
//
// `widgets/word_lookup_selection.dart` **import Flutter** ⇒ 本机跑不了
// （鸿蒙定制 SDK · `CreateFile failed 231`）。
// 而判定是**纯字符串逻辑**、用例密、边界碎（撇号 / 连字符 / 内部句点 /
// 重音字母 / 中文 / 数字符号…）—— 恰恰是**最需要逐条跑**的那一类。
// ⇒ 搬到一个零依赖文件里，由纯 Dart 脚本独立验证
//   （同 `spelling_grader.dart` 的理由：**判定逻辑必须本地可验**）。
//
// ⚠️ **本文件不得 import 任何东西**（含 `package:flutter`）——
//    一旦引入，「本机可跑」这个前提立刻失效。这是它唯一的硬约束。

/// 选中内容的形态 —— 决定划词菜单的**第一项**。
enum PickedKind {
  /// **单个可查的词**（不含空白）⇒ 第一项是「**查词**」。
  word,

  /// 其余一切（多词 / 纯符号数字 / 非拉丁文字）⇒ 第一项是「**翻译**」。
  phrase,
}

/// **词形字符**（单个 rune）：拉丁字母（含重音）· 组合记号 · 撇号 / 连字符 / 句点。
///
/// 🔴 为什么是「**拉丁**」而不是「任意字母」：
/// 本项目词库是**英文词库**。若把中文 / 西里尔字母也当词，
/// 划一段中文会走「查词」→ 词库未命中 → **在线制卡** →
/// 服务端 `validate_spelling` 以 **400** 拒掉（它只收纯词形）——
/// 用户看到的是一次**无意义的参数错误**。
/// ⇒ 非拉丁一律判 [PickedKind.phrase]（走翻译），**不制造那条坏路径**。
///
/// 🆕 **必须收「打字机变体」**（本轮实测补上，否则会静默误判）：
/// | 字符 | 码位 | 为什么收 |
/// |---|---|---|
/// | `’` | U+2019 | **iOS 智能标点**把 `'` 自动换成弯撇号 ⇒ 正文里的 `don’t` 若只认 ASCII 撇号，会被判成「短语」，**这个词就再也没有查词入口** |
/// | `‐` `‑` | U+2010 / U+2011 | 排版的连字符变体（含**不换行连字符**）—— 电子书里常见 |
///
/// ⚠️ **不收 `–`（en dash）/ `—`（em dash）** —— 它们是**分隔符**不是词内字符。
/// 但它们在**首尾**时会被 [_stripNonWordEdges] 剥掉（`— attention` ⇒ `attention`）✅。
final RegExp _wordChar =
    RegExp(r"^[\p{Script=Latin}\p{M}\u0027\u2019\u2010\u2011.\-]$", unicode: true);

/// 是否含**至少一个拉丁字母** —— 排除 `!!` / `123` / `...` 这类纯符号。
final RegExp _hasLatin = RegExp(r'\p{Script=Latin}', unicode: true);

/// 空白（含全角空格 `U+3000` —— 中文输入法下极易打出）。
final RegExp _hasWhitespace = RegExp(r'\s');

bool _isWordChar(String ch) => _wordChar.hasMatch(ch);

/// 剥掉**首尾**的「非词形字符」—— **只剥首尾，内部一律不动**。
///
/// ⚠️ 用 `runes` 而不是 `codeUnits`：后者会把代理对（emoji 等）劈成两半。
String _stripNonWordEdges(String s) {
  if (s.isEmpty) return s;
  final chars = s.runes.map(String.fromCharCode).toList();
  var i = 0;
  var j = chars.length;
  while (i < j && !_isWordChar(chars[i])) {
    i++;
  }
  while (j > i && !_isWordChar(chars[j - 1])) {
    j--;
  }
  return chars.sublist(i, j).join();
}

/// 判定选中文本的形态。
///
/// # 规则（对应 L1 锚点 `visual-selection-menu-2026-10-07.html` §1）
/// ```
/// ① t = 剥掉 trim(原文本) 的首尾非词形字符
/// ② t 为空                ⇒ phrase   （!! / 123 / 中文）
/// ③ t 含空白              ⇒ phrase   （give up / 一整句）
/// ④ t 不含任何拉丁字母     ⇒ phrase   （同上，兜底）
/// ⑤ t 含内部非词形字符     ⇒ phrase   （a,b）
/// ⑥ 否则                  ⇒ word
/// ```
///
/// # ⚠️ 与锚点 §1 的**两处有意偏离**（锚点写窄了 · 反例见验证脚本）
///
/// | 锚点原文 | 本实现 | 为什么偏离 |
/// |---|---|---|
/// | 「只由 `[A-Za-z'\-.]` 组成 ⇒ 单词」 | 允**重音拉丁字母**（`é` `ç` `ñ`…） | 词库里有 `café` / `cybercafé` / `français`（`spelling_grader` 实测 **3 个非 ASCII 词条**）⇒ 按纯 ASCII 判会把它们误判成「多词」，菜单第一项变成「翻译」，**这个词就再也没有查词入口了** |
/// | （未涉及首尾引号 / 破折号） | 首尾的引号、破折号、逗号**一并剥掉** | 书里高频：`— attention`（对话破折号）· `"attention,"`（引号+逗号）⇒ 剥掉后**仍是同一个词**，而按锚点原文会判成「短语」 |
///
/// 📌 判据：**锚点写的是「意图」，实现要覆盖「意图的全部合法形式」** ——
///    发现锚点漏了合法形式时，**改实现并回标锚点**，而不是照着窄规则硬实现。
PickedKind classifyPicked(String raw) {
  final t = _stripNonWordEdges(raw.trim());

  if (t.isEmpty) return PickedKind.phrase;
  if (_hasWhitespace.hasMatch(t)) return PickedKind.phrase;
  if (!_hasLatin.hasMatch(t)) return PickedKind.phrase;

  // 内部字符也必须全是词形字符（`don't` / `e-mail` / `a.m.` 通过；`a,b` 不通过）
  for (final rune in t.runes) {
    if (!_isWordChar(String.fromCharCode(rune))) return PickedKind.phrase;
  }
  return PickedKind.word;
}
