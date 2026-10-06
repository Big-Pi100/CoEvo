// CoEvo · 「朗读用纯文本」—— 把 Markdown 正文变成**能听**的文本（纯逻辑 · 零 import）
//
// 🔴 零 Flutter 依赖（同 `reading_completion` / `sync_merge` / `speech_chunks`）⇒
//    本机可完整验证（`scripts/query_verify/bin/verify_speech_text.dart`）。
//
// # 🔴 为什么必须有这一层（不是「顺手优化」）
//
// 信息流的正文是 **Markdown 原文**（`reader_screen` 的注释明说「正文**原文**（Markdown 形态）」），
// 而**书库的章节是纯文本** ⇒ 书库那套朗读直接搬过来会念出**标记本身**。
//
// 生产库实测（NPR 源）：
// ```
// ### [Law](https://www.npr.org/sections/law/)
// - [Download](https://ondemand.npr.org/anon.npr-mp3/npr/atc/2026/...)
// **Supreme Court case centers on battle over liability for climate change harms**
// ```
// ⇒ 不处理的话会听到：「hash hash hash **link** … h-t-t-p-s colon slash slash
//    w-w-w dot n-p-r dot o-r-g …」—— 而且**每一段都这样**。
//
// 📌 判据：**「界面里看着对」≠「听出来是对的」** ——
//    渲染层（`gpt_markdown`）把标记变成了样式，而 TTS 拿到的是**原始字符串**。
//    两个消费者、两种形态 ⇒ 朗读侧必须自己剥。
//
// # 🔴 与 `markdown_unescape` 的分工（**口径不同，别合并**）
//
// | | 显示（`gpt_markdown` 消费）| **朗读（本文件）** |
// |---|---|---|
// | 反斜杠 | 🔴 **要智能保留**（行首 `\(` 可能是 LaTeX 定界符，替掉会破坏公式）| **一个都不留**（念出来是噪声，且听不出差别）|
// | HTML 标签 | 可能被渲染 | 必须去掉（否则念标签名）|
// | `_` 下划线 | 按 CommonMark 渲染 | ⚠️ **词内下划线不能动**（`snake_case` 是标识符，不是强调）|
//
// ⇒ 显示侧用 `unescapeRedundantMarkdown`（有 LaTeX 白名单），朗读侧用本文件。
//    两者**目标不同**，共用一份实现会有一边错。
//
// # 🔑 三条设计原则
//
// 1. **不丢内容**（宁可留一个符号，也不能把正文删掉）——
//    所以链接/图片只去 **URL**，保留**可见文字**；强调只去标记、保留文字。
// 2. **只剥「语法上确实是标记」的东西** ——
//    最典型的是 `_`：`snake_case` 里的下划线是**词的一部分**，
//    无条件替换会把 `my_var_name` 念成 `myvarname`（**内容被破坏**）。
//    ⇒ 下划线强调要求**词边界**（前后都不是字母/数字）。
// 3. **纯语法行整行删**（表格分隔线 `|---|---|`、水平线 `---`）——
//    它们**没有任何可读内容**，念出来只会是噪声。
//
// # ⚠️ 一期**不做**的事（如实记录）
// * **不合并同义标记的嵌套**（`***x***` → 只剥外层，罕见且无害）
// * **不做语音学处理**（数字/缩写读法交给系统 TTS —— 那是它的强项）
// * **不改动正文里的时间/日期格式**（如 `October 5, 20265:31 PM` 是**源数据**的问题，
//   属于内容源侧，不该在这一层"修"）

import 'article_text.dart';

/// **CommonMark 规定可被 `\` 转义的字符**（ASCII 标点全集）。
///
/// 🔴 **刻意不复用 `markdown_unescape.dart` 的 `kUnescapablePunct`** —— 两者**口径不同**：
///
/// | | `kUnescapablePunct`（显示侧）| **本常量（朗读侧）** |
/// |---|---|---|
/// | 用途 | 决定「哪些 `\X` 该消化」| 判定「哪些 `\X` 是转义序列」|
/// | `\|` | 🔴 **故意排除** —— `gpt_markdown` 自己会反转义 `\|`，重复处理会**切坏表格** | ✅ **必须包含**（朗读不经过 `gpt_markdown`，留着会念出竖线）|
/// | 语义 | 「值得消化的」= **产品判断** | 「语法上是转义」= **规范事实** |
///
/// ⇒ 借用它会让朗读侧**漏掉 `\|`**（表格单元格里的竖线残留）。
/// 📌 泛化：**「看起来能复用」的常量，要先确认它的语义边界是否一致** ——
///    本项目已多次踩「复用为 A 设计的参数」（同族）。
/// ⚠️ 用 **`Set`** 而不是拼成一个大字符串：这些字符里同时含 `"` 与 `'`，
///    用 raw string 两种引号都会撞车，用普通字符串又要在同一行里同时转义
///    `"` `\` `$`（本人踩过一次 —— 写出来是**语法错误 26 条**）。
///    ⇒ 逐字符列举：每个元素独立，**没有一整行的转义地狱**。
///
/// 🔑 `Set` 还让 `contains` 是 O(1)（虽然 32 个元素无所谓，但语义更贴切：
///    这里问的是「是否属于这个集合」）。
const Set<String> _kEscapablePunct = {
  '!', '"', '#', r'$', '%', '&', "'", '(', ')', '*', '+', ',', '-', '.', '/',
  ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|',
  '}', '~',
};

/// 哨兵：暂存「被转义的标点」，使其在剥标记阶段**不被当成标记**。
///
/// 🔴 用 `\u0000`（NUL）：正文里**不可能**出现（Markdown 是文本格式，
///    而 NUL 在 JSON 里必须写成 `\u0000`，被解析后不会出现在正常内容中）。
/// ⚠️ 若正文真含 NUL（异常数据），最坏结果是**该字符消失** —— 无害（它本来就不可读）。
const String _sentinel = '\u0000';

/// **Markdown 正文 → 朗读用纯文本**。
///
/// 幂等于「纯文本输入」：不含标记的文本会被原样返回（只做空白归一）。
String speechTextFromMarkdown(String markdown) {
  if (markdown.isEmpty) return '';

  // ── ① 藏起「被转义的标点」──
  //   `\*` 里的星号**不是**强调标记；不藏起来会在第 ③ 步被误剥
  //   （`a \* b \* c` 会被当成 `*b*` 的强调）。
  var s = _hideEscapes(markdown);

  // ── ② 逐行剥（块级 + 行内**在同一次遍历**里做）──
  //
  // 🔴🔴 **为什么必须合并成一次遍历**（本人踩到的真 bug）：
  //    初版是「先 `_stripBlockLevel`（逐行，带围栏状态）再 `_stripInline`（**整个字符串**）」——
  //    而后者是全局的 ⇒ **围栏内的行也走行内剥** ⇒ 围栏保护只挡住了块级标记。
  //    实测：一个围栏代码块里的 `char *a *b;` 被剥成 `char a b;` —— **代码内容被改**。
  //    ✅ 合并后，围栏状态是**循环里的局部变量**，天然对块级与行内同时生效。
  //    📌 判据：**「有状态的处理」不要拆成两个全局 pass** ——
  //      状态在第一个 pass 里活着、在第二个 pass 里已经丢了。
  s = _stripLineByLine(s);

  // ── ④ 还原被转义的标点（= 反转义；朗读场景**无条件**还原）──
  s = s.replaceAll(_sentinel, '');

  // ── ⑤ 空白归一：去掉行尾空格、压缩 3+ 连续换行为 2 ──
  final lines = s.split('\n').map((l) => l.trimRight()).toList();
  s = lines.join('\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  return s.trim();
}

/// 把 `\` + 标点 换成哨兵 + 标点（使其暂时"隐身"）。
///
/// ⚠️ 只处理**标点前**的反斜杠（与 CommonMark 一致）；
///    `\a` 这种（反斜杠+字母）**不是转义**，原样保留 —— 保持与显示侧同一判据。
String _hideEscapes(String src) {
  final sb = StringBuffer();
  for (var i = 0; i < src.length; i++) {
    final c = src[i];
    if (c == '\\' &&
        i + 1 < src.length &&
        _kEscapablePunct.contains(src[i + 1])) {
      sb.write(_sentinel);
      sb.write(src[i + 1]);
      i++; // 跳过被转义的字符
    } else {
      sb.write(c);
    }
  }
  return sb.toString();
}

/// 围栏代码块标记（``` 或 ~~~）—— 用于**状态切换**（围栏内不做行内处理）。
final RegExp _fenceRe = RegExp(r'^\s*(```|~~~)');

/// 行首块级标记（标题 / 引用 / 列表）。
///
/// 🔑 **一律允许前导空格**（`^\s*`）—— 嵌套列表（`  - item`）在正文里很常见
///    （NPR 的「Download」那行就是列表项）。
///    ⚠️ 严格按 CommonMark，缩进 4 空格以上的是**代码块**而非列表；
///    但朗读场景**宽容处理更合适**：多去一个 `-` 只是少个符号，
///    而不去会在朗读里念出「dash」。
///    📌 判据：**朗读侧优先「不要念出符号」，显示侧才需要严格遵守规范**。
final RegExp _headingRe = RegExp(r'^\s*#{1,6}\s+');
final RegExp _quoteRe = RegExp(r'^\s*>\s?');
final RegExp _bulletRe = RegExp(r'^\s*[-*+]\s+');
final RegExp _orderedRe = RegExp(r'^\s*\d{1,9}[.)]\s+');
/// 表格**分隔行**（`|---|---|` / `:--:|`）—— 纯语法，无内容。
final RegExp _tableDividerRe = RegExp(r'^\s*\|?[\s:|-]*-[\s:|-]*\|[\s:|-]*$');
/// 水平线（`---` / `***` / `___`，3 个以上）。
final RegExp _hrRe = RegExp(r'^\s*(?:[-*_]\s*){3,}$');

/// **逐行**剥块级与行内标记（围栏状态在本循环里维护）。
///
/// 🔑 围栏内的行**完全不动**（块级与行内都不动）—— 理由见调用点的长注释。
String _stripLineByLine(String src) {
  final out = <String>[];
  var inFence = false;

  for (final line in src.split('\n')) {
    if (_fenceRe.hasMatch(line)) {
      inFence = !inFence; // 围栏行本身**丢弃**（里面没有可读内容）
      continue;
    }
    if (inFence) {
      // 代码内容**原样保留**（强调/链接在代码里可能是语法：
      // `char *a *b;` 的星号、`a_b` 的下划线）
      out.add(line);
      continue;
    }
    if (_tableDividerRe.hasMatch(line) || _hrRe.hasMatch(line)) continue;

    var l = line;
    l = l.replaceFirst(_headingRe, '');
    l = l.replaceFirst(_quoteRe, '');
    l = l.replaceFirst(_bulletRe, '');
    l = l.replaceFirst(_orderedRe, '');
    l = _stripInline(l); // ← 行内也在同一趟里做
    out.add(l);
  }
  return out.join('\n');
}

/// 行内标记。
///
/// ⚠️ **顺序刻意如此**（先长的、结构明确的，后短的、易误伤的）：
///    嵌套双星 vs 单星 —— 先剥 `**` 再剥 `*`，否则 `**x**` 会被单星规则
///    先吃掉一半（`*x*` → `x**` 这种残渣）。
final RegExp _imageRe = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final RegExp _linkRe = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final RegExp _autoLinkRe = RegExp(r'<(?:https?|mailto):[^>]*>');
final RegExp _htmlTagRe = RegExp(r'</?[A-Za-z][^>]*>');
final RegExp _bareUrlRe = RegExp(r'https?://[^\s<>()\[\]]+');
final RegExp _inlineCodeRe = RegExp(r'`+([^`]*)`+');
final RegExp _boldRe = RegExp(r'\*\*([^*]+)\*\*');
/// 🔴 下划线粗体：同 `_italicUnderscoreRe` 的判据 —— **只剥「含空格」的**。
///
/// 反例（实测）**`call __init__ method`** ⇒ 若剥掉会念成 `init`（内容错）。
/// 而 `__bold text__` 含空格 ⇒ 一定是粗体（标识符不含空格）⇒ 放心剥。
///
/// 📌 判据：**显示侧按规范，朗读侧按「别把内容念错」** ——
///    对同一份 Markdown 采取不同口径是**正确的**（消费者不同、目标不同）。
final RegExp _boldUnderscoreRe =
    RegExp(r'(?<![\w])__([^_]*\s[^_]*?)__(?![\w])');
final RegExp _strikeRe = RegExp(r'~~([^~]+)~~');
final RegExp _italicStarRe = RegExp(r'\*([^*\n]+)\*');
/// 🔴🔴 **下划线强调的判据：只剥「含空格」的**（这条是权衡的结果，不是随手写）
///
/// # 为什么词边界不够（实测踩到）
///
/// `_` 有**两种身份**，而且规范层面**无法区分**：
///
/// | 输入 | CommonMark 怎么看 | 朗读侧想要 |
/// |---|---|---|
/// | `call __init__ method` | ✅ **是粗体**（`__` 成对、左右都是边界）| ❌ 原样（Python 的 dunder 方法名）|
/// | `my_var_name` | 不是强调（`_` 在词内）| ✅ 原样 —— 词边界能挡 |
/// | `_emphasized_` | ✅ 是斜体 | ❓ 剥掉更好听，但**也可能是标识符**（`_private`）|
///
/// ⇒ `(?<![\w])` 对 `__init__` **无效**（它前面真的是空格）⇒ 那条路走不通。
///
/// # 采用的判据
///
/// **含空格 ⇒ 一定是强调**（标识符里不会有空格）；
/// **不含空格 ⇒ 不碰**（宁可留两个下划线，也不冒破坏标识符的风险）。
///
/// 📌 依据：**「宁可少剥，不可破坏内容」** —— 本项目已有同族判据
///    （显示侧的「宁可少消化，不可造语法」）。
/// 🔑 且代价极小：TTS 对孤立的 `_` 通常**不发音**（或轻读），
///    而把 `__init__` 念成 `init` 是**实害**（内容错了）。
///
/// ⚠️ 星号强调**没有**这个限制 —— `*` 不是标识符字符（见 `_italicStarRe`）。
final RegExp _italicUnderscoreRe =
    RegExp(r'(?<![\w])_([^_\n]*\s[^_\n]*)_(?![\w])');

String _stripInline(String src) {
  var s = src;
  // 图片 → 保留 alt 文字（不丢内容）；URL 必须去掉
  s = s.replaceAllMapped(_imageRe, (m) => m.group(1) ?? '');
  // 链接 → 保留可见文字（**URL 必须去掉** —— 这是本文件存在的主因）
  s = s.replaceAllMapped(_linkRe, (m) => m.group(1) ?? '');
  s = s.replaceAll(_autoLinkRe, '');
  s = s.replaceAll(_htmlTagRe, '');
  s = s.replaceAll(_bareUrlRe, '');
  s = s.replaceAllMapped(_inlineCodeRe, (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(_boldRe, (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(_boldUnderscoreRe, (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(_strikeRe, (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(_italicStarRe, (m) => m.group(1) ?? '');
  s = s.replaceAllMapped(_italicUnderscoreRe, (m) => m.group(1) ?? '');
  return s;
}

/// 把正文转成**朗读用的段落列表**（每段再交给 `speech_chunks` 分段）。
///
/// 🔑 存在的理由：`speakLong` 对**整篇**分段是按长度切的，
///    段落边界对它不可见 ⇒ 一段的结尾与下一段的开头会被**连起来读**。
///    先按段落切开，朗读时**段间留停顿**（由调用方控制），听感正常得多。
///
/// ⚠️ 复用 `article_text.splitParagraphs` 的段落口径（同一套规则，
///    不再写第二份 —— 「同一件事的口径只能一处权威」）。
List<String> speechParagraphsFromMarkdown(String markdown) =>
    splitParagraphs(speechTextFromMarkdown(markdown));
