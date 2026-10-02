// 痕迹标记注入 —— 把「已查词」包成 Markdown 里的**自定义 inline 标记**（纯函数 · 零框架依赖）。
//
// # 🔴🔴 为什么需要这一层（问题的本质）
//
// 痕迹 = 「已查过的词在正文里带样式」。它**原本**的实现是
// **`locateTraceMarks`（按词匹配）→ 字符区间 → `TraceText` 逐 span 上色**。
// （⚠️ 那条路径与那两个符号已于 2026-10-02 随 S4 一并删除 ——
//   正因为「偏移在解析后全变」，本文件才改成「往源里插标记」。）
//
// 而 S4 把正文渲染换成 **Markdown 渲染器**（`gpt_markdown`）后，这条路断了：
//
// | | 纯文本渲染（旧） | Markdown 渲染（新） |
// |---|---|---|
// | 源文本 | 就是显示文本 | 含 `**`/`` ` ``/`##` 等**语法标记** |
// | 字符位置 | 稳定 | 🔴 **解析后偏移全变**（语法标记被吃掉了）|
//
// ⇒ **「按字符区间标注」在 Markdown 渲染下没有意义** —— 偏移对不上。
//
// # 🔑 解法：把「区间」换成「标记」
//
// Markdown 渲染器不认识「第 12–20 个字符」，但它**认识语法**。
// 于是：**在渲染之前，把已查词在源文本里包成一个自定义 inline 标记**，
// 再由 `InlinePattern` 的 builder 把它渲染成带痕迹样式的 span。
//
// ```
// 源：  A great **achievement** indeed.
// 注入：A great **\u0001achievement\u0001** indeed.
// 渲染：A great <b><带痕迹样式的>achievement</></b>
// ```
//
// 🔑 这样做的两个好处：
// 1. **仍走成熟包的完整管线**（新 `plusparse` 解析器 + 所有内置组件）——
//    没有绕回旧渲染器，也没有自己写渲染
// 2. **不必重新计算偏移** —— 标记随文本一起被解析器处理，位置天然正确
//
// # 🔴 标记字符为什么用控制字符 `\u0001` / `\u0002`
//
// 要求：**正文里不可能出现**。候选比较：
// | 候选 | 问题 |
// |---|---|
// | `==词==` | 与 Markdown 的高亮语法冲突；且只能表达一种样式 |
// | `~~词~~` | GFM 的删除线语法 → 会被解析成删除线 |
// | `~词~` | 正文里的单个 `~`（「约」、代码）会误匹配 |
// | **`\u0001` / `\u0002`** | ✅ **正文不可能包含控制字符**（U+0001/U+0002 是 C0 控制码）|
//
// 而用**两个不同字符**是为了编码**档位**：
// · `\u0001词\u0001` = `fresh`（新词，reps ≤ 0）
// · `\u0002词\u0002` = `reviewing`（复习中）
//
// 🔑 只有两档 —— 依据 [`TraceTokens.forReps`]：它只有三种输出
// （`fresh` / `reviewing` / **`null`**，`null` = 已掌握 = **不产生标记**）。
// 所以标记里**不需要编码完整的 reps 数**，两档足够。
//
// # 🔴 三类区域**必须跳过**（否则会破坏正文）
//
// | 区域 | 不跳过的后果 |
// |---|---|
// | ``` 围栏代码块 | 代码里的标识符被标痕迹 → 视觉混乱（代码块本该是「原样呈现」）|
// | `` ` `` 行内代码 | 同上；且插进来的控制字符会被当成代码内容显示 |
// | `](url)` 里的 URL | 🔴 **链接会坏**（URL 里插入控制字符 → 链接失效）|
//
// ⇒ 本文件的核心就是「**切出这些区域，只在其外做词匹配**」。
//
// # 与 `trace_locator.dart` 的分工（判据别各写一份）
//
// | 谁 | 负责 |
// |---|---|
// | `trace_locator.pickedTraceTiers` | **哪些词**该标、**哪一档**（含去重 + 已掌握排除）|
// | 本文件 `_markWords` | 把那些词在正文里**匹配出来**并包上标记 |
//
// ⚠️ 本文件**不重新判断**「该不该标」（`tiers` 直接来自判据层），只做「匹配 + 编码」。
//    判据若在两处各写一份，会出现「同一个词在 A 处标了、B 处没标」这种最难查的不一致
//    —— 不报错，只是少画一处底色。
//
// # 🔴 词匹配唯一的难点：词边界（`\b`）
//
// 若用朴素的 `text.indexOf(word)`，则查过 `art` 会把 `start` / `part` /
// `artist` 全标上痕迹 —— 而用户从没查过这些词。
// 这类错误**不报错、只是多画几处底色**，肉眼扫过去很难发现，
// 所以必须由断言锁死（见 `scripts/trace_verify/bin/verify_trace_markdown.dart` 第【5】组）。
//
// 判据用正则 `\b` ——「单词字符与非单词字符的交界」。
// 于是 `vertical` 匹配 `vertical` 而不匹配 `vertically`
// （`l` 与 `y` 都是单词字符，中间没有边界）。
//
// ⚠️ **已知限制（如实说明）**：`\b` 只认 `[A-Za-z0-9_]` 为单词字符，所以：
// · 词以**非单词字符**开头/结尾时（如 `well-known`），`\b` 的位置会不符合直觉
// · 含 `'` 的缩写（`don't`）同理
//
// 当前词库 `word.spelling` **100% 是全小写 ASCII 单词**（连专名也是 `india` / `isaac`），
// 不存在这些形态 —— 所以不额外处理。若将来词库引入短语 / 带连字符 / 带重音的词，
// 这里要一并改（**别在这里默默加兜底**）。
//
// # 性能
// 一次扫描 + 每个词一次正则匹配（与旧路径同级）。文章数千字符、词表数十词 → 毫秒级。
//
// ⚠️ **本文件零 import**（纯字符串处理）—— 判据由 `trace_locator.pickedTraceTiers`
//    给出（那是「哪些词、哪一档」的唯一权威），本文件只负责「把档位编码成标记」。
//    📌 这样切开的好处：判据可独立断言，编码可独立断言，两者互不牵连。

/// 痕迹标记的控制字符（**正文不可能出现**，见文件头）。
///
/// 两个字符对应 [`TraceTokens.forReps`] 的两档可见样式。
const String kTraceFreshOpen = '\u0001';
const String kTraceReviewingOpen = '\u0002';

/// 匹配一段痕迹标记：`<控制字符>内容<同一控制字符>`。
///
/// 🔑 用**同一个字符**开闭（而不是任意组合）—— 这样「只有一个控制字符」的
/// 半截标记**不会**被匹配上（它是畸形的，应当原样显示而不是吞掉内容）。
/// 📌 判据：解析畸形输入时，**宁可少匹配也不要吞内容**。
final RegExp kTraceMarkerPattern = RegExp(
  '([\u0001\u0002])([^\u0001\u0002]*?)\\1',
);

/// 档位 → 标记字符。**只在这一个地方做这个映射**（见文件头说明）。
String traceMarkerOf(int tier) =>
    tier == 0 ? kTraceFreshOpen : kTraceReviewingOpen;

/// 把已查词包成痕迹标记（纯函数，可独立断言）。
///
/// [markdown] 正文（Markdown 形态）。
/// [tiers] `词（小写）→ 档位`，**直接来自 [`pickedTraceTiers`]** ——
///   本函数不做任何「该不该标」的判断（那是判据层的事），只做编码。
///   ⚠️ 调用方**不要**把已掌握的词放进来（`forReps` 返回 `null` 的那些）。
///
/// 返回注入标记后的文本。**任何时候都不会改变原文的可见内容**
/// （只插入控制字符，不删不改）。
String injectTraceMarkers({
  required String markdown,
  required Map<String, int> tiers,
}) {
  if (markdown.isEmpty || tiers.isEmpty) return markdown;

  final out = StringBuffer();
  var i = 0;
  final n = markdown.length;

  while (i < n) {
    // ── ① 围栏代码块：``` 或 ~~~ 开头 → 整块跳过 ──
    if (_atFence(markdown, i)) {
      final end = _skipFence(markdown, i);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ② 行内代码：`…` → 跳到配对的 ` ──
    if (markdown[i] == '`') {
      final end = _skipBacktick(markdown, i);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ③ 链接/图片的 URL：`](` 后的括号内容 → 跳过 ──
    //    🔴 这一步不能省：URL 里插入控制字符会让链接失效。
    if (markdown[i] == ']' && i + 1 < n && markdown[i + 1] == '(') {
      final end = _skipParen(markdown, i + 1);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ④ 🔑 已有痕迹标记 → 原样跳过（**保证幂等**）──
    //    为什么需要：控制字符不是「单词字符」，所以 `\bword\b` 在
    //    `\u0001word\u0001` 里**仍然匹配** word → 若不跳过，重复调用会变成
    //    `\u0001\u0001word\u0001\u0001`（双层标记 → 渲染出一层多余的控制字符）。
    //    📌 判据：**幂等不是「顺便做到的」，要么显式保证、要么显式声明非幂等** ——
    //       这里的代价只有几行，而「被调用两次」在生产代码里太容易发生
    //       （换渲染器的重构、重试、状态变化都会重新走一遍）。
    final c = markdown[i];
    if (c == kTraceFreshOpen || c == kTraceReviewingOpen) {
      final end = _skipMarker(markdown, i);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ⑤ 普通文本：从这里开始做词替换，直到下一个「特殊起点」 ──
    final next = _nextSpecial(markdown, i);

    // 🔴 **防御死循环**（证伪实验逼出来的，2026-10-02）
    //
    // 走到这里说明「①–④ 都没接管」，但 `_nextSpecial` **可能仍在 `i` 处返回**：
    // 上面那个「跳过 URL」分支的条件与 `_nextSpecial` 里那条判断**是同一个**，
    // 两处必须永远一致 —— 一旦不一致（改了这处忘了那处），
    // `next == i` → `substring(i, i)` 是空串 → `i` 原地不动 → **无限循环**。
    //
    // 📌 这不是假想：**证伪注入**（把 URL 分支改成 `if (false)`）时它**真的挂了**
    //    （脚本超时被 SIGTERM，而不是「报红」）。
    //    ⇒ 判据：**「两处条件必须一致」这种耦合不该靠人记得** ——
    //       让不一致的后果从「死循环」降级成「前进一个字符」。
    //    代价是每次不一致时少替换一个字符（可忽略），收益是不再有挂死的可能。
    if (next == i) {
      out.write(markdown[i]);
      i++;
      continue;
    }

    out.write(_markWords(markdown.substring(i, next), tiers));
    i = next;
  }

  return out.toString();
}

/// 从 [from] 起，下一个需要特殊处理的位置
/// （围栏 / 反引号 / `](` / **已有的痕迹标记**）。
///
/// 找不到则返回 `length`（走到结尾）。
int _nextSpecial(String s, int from) {
  for (var i = from; i < s.length; i++) {
    final c = s[i];
    if (c == '`') return i;
    if (c == kTraceFreshOpen || c == kTraceReviewingOpen) return i;
    if (c == '~' && _atFence(s, i)) return i;
    if (c == ']' && i + 1 < s.length && s[i + 1] == '(') return i;
  }
  return s.length;
}

/// 跳过一段**已有的**痕迹标记（[from] 是开头的控制字符）。
///
/// ⚠️ 找不到配对的收尾字符 → 返回 `from + 1`（只跳过这一个控制字符，不吞正文）。
/// 单个控制字符是畸形输入 —— 同 [_skipBacktick]：宁可少跳，不可吞内容。
int _skipMarker(String s, int from) {
  final c = s[from];
  final close = s.indexOf(c, from + 1);
  return close < 0 ? from + 1 : close + 1;
}

/// [i] 处是否是围栏代码块的开头（行首的 ``` 或 ~~~，至少 3 个）。
bool _atFence(String s, int i) {
  final c = s[i];
  if (c != '`' && c != '~') return false;
  // 必须**在行首**（前面只能是行首或空白）
  for (var j = i - 1; j >= 0; j--) {
    final p = s[j];
    if (p == '\n') break;
    if (p != ' ' && p != '\t') return false;
  }
  // 至少连续 3 个
  var k = i;
  while (k < s.length && s[k] == c) {
    k++;
  }
  return k - i >= 3;
}

/// 跳过一整段围栏代码块，返回**结束位置**（闭合围栏之后的第一个字符）。
///
/// ⚠️ 找不到闭合围栏 → 返回 `length`（把剩下的都当代码块）。
/// 这是**有意的保守选择**：宁可少标痕迹，也不要在「疑似代码」里插控制字符。
int _skipFence(String s, int from) {
  final fenceChar = s[from];
  var k = from;
  while (k < s.length && s[k] == fenceChar) {
    k++;
  }
  final fenceLen = k - from;
  // 找行首的同字符围栏（长度 ≥ 开头）
  var line = k;
  while (line < s.length) {
    final nl = s.indexOf('\n', line);
    if (nl < 0) return s.length;
    final lineStart = nl + 1;
    if (lineStart >= s.length) return s.length;
    // 校验这一行是否全是同字符且长度够
    var m = lineStart;
    while (m < s.length && s[m] == fenceChar) {
      m++;
    }
    if (m - lineStart >= fenceLen) {
      // 该行剩余部分应只有空白
      final rest = s.substring(
          m, s.indexOf('\n', m) < 0 ? s.length : s.indexOf('\n', m));
      if (rest.trim().isEmpty) {
        final after = s.indexOf('\n', m);
        return after < 0 ? s.length : after + 1;
      }
    }
    line = nl + 1;
  }
  return s.length;
}

/// 跳过一个行内代码段 `` `…` ``，返回结束位置（配对反引号之后）。
///
/// ⚠️ 找不到配对 → 返回 `from + 1`（只跳过这一个反引号，**不吞掉整篇**）。
/// 单个反引号是合法正文（如 ``a ` b``）—— 吞掉后半篇是更糟的错误。
int _skipBacktick(String s, int from) {
  final close = s.indexOf('`', from + 1);
  if (close < 0) return from + 1;
  return close + 1;
}

/// 跳过一对括号（[open] 位置是 `(`），返回结束位置（`)` 之后）。
///
/// ⚠️ 找不到配对 → 返回 `from + 1`（只跳过这一个字符）。同上：不吞正文。
/// 📌 括号可嵌套（URL 里少见但合法）→ 计数配对。
int _skipParen(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return open + 1;
}

/// 对一段**纯文本**做词替换（不含任何跳过的区域）。
///
/// 🔑 判据：正则 `\b词\b` + 大小写不敏感（理由与已知限制见文件头「词边界」一节）。
/// ⚠️ 同一个词**只处理一次**（`tiers` 是 Map，天然去重）。
String _markWords(String text, Map<String, int> tiers) {
  if (text.isEmpty || tiers.isEmpty) return text;

  var out = text;
  for (final entry in tiers.entries) {
    final word = entry.key;
    if (word.isEmpty) continue;
    final marker = traceMarkerOf(entry.value);
    final re = RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false);
    if (!re.hasMatch(out)) continue;
    out = out.replaceAllMapped(re, (m) => '$marker${m[0]}$marker');
  }
  return out;
}
