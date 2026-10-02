// Markdown 转义消化 —— 把「多余的转义」还原成字面标点（纯字符串处理 · 零 import）。
//
// # 🔴 为什么需要这一层（问题的本质）
//
// **产出侧按 CommonMark 转义，消费侧只实现了子集。**
//
// | 侧 | 行为 |
// |---|---|
// | **产出侧**（后端 `dom_smoothie`）| 输出**标准 CommonMark 转义** —— 而且是**过度**转义：<br>`DELETE\.` · `\"QUERY\"` · `\{ ... \}`（句点/引号/花括号**本来都不需要转**）|
// | **消费侧**（端侧 `gpt_markdown` 1.3.0）| 源码原话：<br>`Only \| is unescaped: a general \X rule would change how \*, \_ and friends render`<br>⇒ **只反转义 `\|`**，其余 `\X` **原样显示** |
//
// ⇒ 用户看到：`Most developers are familiar with ... DELETE\.`（反斜杠裸露）。
//
// 📌 判据：**「支持 Markdown」≠「符合 CommonMark 标准」** ——
//    选包时核了 API / 能力覆盖 / 依赖栈 / 体积，**漏了「它是否符合规范的转义规则」**，
//    而转义恰好是产出侧**大量在用**的写法。详见 `docs/review/s4-device-feedback-findings-2026-10-02.md` §4。
//
// # 🔑 为什么消化放在端侧（而不是改后端）
//
// 报告 §4.4 评估过三条路，端侧是**唯一不动产出侧**的那条：
// · 后端剥转义 ⇒ 「后端替消费侧做决定」，将来换渲染器又要撤回来
// · 换渲染包 ⇒ 成本最大（1.3.0 的懒渲染/流式刚适配好）
// · **端侧前置消化** ⇒ 产出侧保持标准 Markdown，本层只**补上消费侧的缺口**
//
// ⚠️ **但要说清：这是在补消费侧的缺口，不是在修产出侧的 bug。**
//    产出侧的 `\.` 是**合法且冗余**的 CommonMark（`\.` 与 `.` 语义相同）——
//    真正不符合规范的是 `gpt_markdown`（未实现通用反转义）。
//    若将来换一个合规的渲染包，**本文件就没必要了**，应当一起删掉。
//
// # 🔴 白名单，不是黑名单 —— 只消化「确定无语法意义」的标点
//
// 反转义做宽了会**制造新语法**（比不修更糟）。所以只消化下面这些字符：
//
// ```
// .  ,  ;  :  "  '  !  ?  %  &  ^  @  /  =  {  }
// ```
//
// **一律保留**的（在 `gpt_markdown` 里行内就有语法意义）：
//
// | 保留 | 为什么 |
// |---|---|
// | `\*` `\_` | emphasis —— 若消掉，`\*` → `*` 会**开始强调** |
// | `` \` `` | 行内代码 |
// | `\[` `\]` `\(` `\)` | 🔴 **LaTeX 定界符**（实测生产库有 `\(x\)` `\(+\)` `\(E\)`，34 篇成对）—— 消掉公式就废了 |
// | `\|` | 表格分隔（`gpt_markdown` **自己**会反转义成 `\|`，重复处理会**切坏表格**）|
// | `\#` `\>` `\-` `\+` | 行首语法（标题 / 引用 / 列表）|
// | `\~` | 删除线（`~~text~~`）|
// | `\<` | HTML / 自动链接 |
// | `\$` | 数学（我们没启用，但保留以防万一）|
// | `\\` | 反斜杠本身 **+ LaTeX 换行**（`\\[1em]`）—— 两种含义无法无上下文区分 |
// | `\` + 字母/数字 | **CommonMark 规定原样保留**（实测库里有正则 `\d+` `\s+`，属代码内容）|
//
// ⚠️ `\#` `\+` 实测有 43 / 39 处**且都在行内**（如 `\#Hacktoberfest2026`、`4,000\+`）——
//    行内确实不需要转义。但「行首才保留 / 行内可消化」这条规则需要额外的位置判断，
//    而收益（43+39 处）远小于风险（判错就多一个标题/列表）。
//    📌 取舍：**宁可少消化，不可造语法**。将来若这类抱怨变多，再按「位置」细化。

/// 只消化这些标点前的反斜杠 —— 见文件头「白名单」一节。
///
/// 🔑 反斜杠 + 非标点字符**不在此表**（CommonMark 规定原样保留）。
///
/// ⚠️ `[` `]` **是实测补进来的**（初版没有它们）：
/// 生产库里 dom_smoothie 会把 JSON 数组的方括号也转义成 `\["IN", "US"\]`，
/// 而初版把 `\[` 一律当 LaTeX 定界符跳过 ⇒ **JSON 里的反斜杠全留下来了**
/// （实测 id=1444 残留 12 个反斜杠，全部来自两处 JSON 数组）。
/// 见 [unescapeRedundantMarkdown] 里「行首才算 LaTeX」的说明。
const Set<String> kUnescapablePunct = {
  '.', ',', ';', ':', '"', "'", '!', '?', '%', '&', '^', '@', '/', '=', '{', '}',
  '[', ']', '(', ')',
};

/// 消化正文里**多余的 Markdown 转义**（纯函数，可独立断言）。
///
/// 返回消化后的文本。**只删反斜杠、不改任何可见字符**（除非该反斜杠确实多余）。
///
/// # 跳过区（这些地方的反斜杠**有语义**，必须原样保留）
///
/// | 区域 | 不跳过的后果 |
/// |---|---|
/// | ``` 围栏代码块 | 代码里的正则 `\d+` 被改成 `d+` → **代码内容被篡改** |
/// | `` ` `` 行内代码 | 同上 |
/// | `\[ ... \]` 块级 LaTeX | `\\` 是 LaTeX 换行、`\%` 是转义百分号 → **公式被破坏** |
/// | `\( ... \)` 行内 LaTeX | 同上（实测生产库真有这些） |
/// | `](url)` 里的 URL | URL 里含 `%` / `_` 等被改写 → **链接失效** |
///
/// 🔑 与 [`injectTraceMarkers`] 的跳过区**高度重叠但不相同** ——
///    那边多跳（无 LaTeX 需求），这边必须多跳 LaTeX。
///    ⚠️ 两处的边界判据都是「脆弱耦合」，改动时**必须同时看**（那边已用
///    `next == i` 防御死循环；本函数用**显式 `i++`** 保证一定前进）。
String unescapeRedundantMarkdown({required String markdown}) {
  if (markdown.isEmpty || !markdown.contains(r'\')) return markdown;

  final out = StringBuffer();
  var i = 0;
  final n = markdown.length;

  while (i < n) {
    final c = markdown[i];

    // ── ① 围栏代码块：``` / ~~~ 开头 → 整块跳过 ──
    if (_atFence(markdown, i)) {
      final end = _skipFence(markdown, i);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ② 行内代码：`…` → 跳到配对的 ` ──
    if (c == '`') {
      final end = _skipBacktick(markdown, i);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ③ 链接/图片的 URL：`](` 后的括号内容 → 跳过（改写 URL 会让链接失效）──
    if (c == ']' && i + 1 < n && markdown[i + 1] == '(') {
      final end = _skipParen(markdown, i + 1);
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ④ LaTeX 区（必须跳过 —— 那里的反斜杠是数学记号）──
    //
    // 🔴 `_isOpeningLatex` 会排除 `\\[` / `\\(` 这种「转义的反斜杠 + 括号」形态：
    //    实测生产库有 LaTeX 换行 `\\[1em]` ——
    //    若只看「前一个字符是 `\` 且下一个是 `[`」就会把 `\\[1em]` 的**第二个反斜杠**
    //    误判成块级 LaTeX 开始，然后把后面整段当公式跳过（静默少消化一大片）。
    if (_isOpeningLatex(markdown, i, '[')) {
      final end = _skipLatex(markdown, i, '[');
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }
    if (_isOpeningLatex(markdown, i, '(')) {
      final end = _skipLatex(markdown, i, '(');
      out.write(markdown.substring(i, end));
      i = end;
      continue;
    }

    // ── ⑤ 转义：按白名单 + 两个保护条件决定是否消化 ──
    if (c == r'\' && i + 1 < n) {
      final nx = markdown[i + 1];
      if (_shouldUnescape(markdown, i, nx)) {
        out.write(nx); // 只写出标点本身 —— 即「吃掉反斜杠」
        i += 2;
        continue;
      }
      out.write(c);
      i++;
      continue;
    }

    // ── ⑥ 普通字符 ──
    out.write(c);
    i++;
  }

  return out.toString();
}

/// 判定「此处的 `\X` 该不该消化」。
///
/// 四个条件缺一不可：在白名单里 + 前一个字符不是反斜杠 + 不是列表形态 + 不是图片/链接形态。
bool _shouldUnescape(String s, int backslashAt, String nx) {
  if (!kUnescapablePunct.contains(nx)) return false;

  // 🔴 保护一：反斜杠**紧跟在反斜杠后面**时一律不动。
  //
  // 为什么（实测踩到，2026-10-02）：`\\[1em]` 是 **LaTeX 换行 + 间距参数**。
  // 原本 `\\` 被正确保留（`\` 不在白名单），但紧接着的 `\[` 会被当普通转义**消化成 `[`**
  // ⇒ 变成 `\[1em]` —— 语义完全变了（`\[` 在 LaTeX 里是**行间公式开始**）。
  //
  // 🔑 而 `\\X` 本身有两种无法用上下文区分的含义：
  //    · Markdown 视角：`\\` = 字面反斜杠，然后 `X`
  //    · LaTeX 视角：`\\` = 换行命令，`[1em]` 是它的可选间距
  // ⇒ **宁可全保留**（多一个反斜杠只是不好看；猜错会破坏公式）。
  // 📌 判据：**无法区分的两种情况，选「不动」而不是「猜一个」**。
  if (backslashAt > 0 && s[backslashAt - 1] == r'\') return false;

  // 🔴 保护二：`\.` 若构成**行首有序列表**形态（`1\.` / `2\.`）→ 保留。
  //    消掉会让 `1.` 变成列表项 —— 这正是本项目已定的判据：
  //    **「宁可少消化，不可造语法」**（多一个反斜杠只是不好看，多一个列表是语义错）。
  if (nx == '.' && _isOrderedListMarker(s, backslashAt)) return false;

  // 🔴 保护三：`\!` 后面紧跟 `[` → 消掉会变成 `![…](…)` **图片语法**。
  if (nx == '!' && backslashAt + 2 < s.length && s[backslashAt + 2] == '[') {
    return false;
  }

  // 🔴 保护四：`\]` 后面紧跟 `(` → 消掉会与前面的 `[` 合成 `[…](…)` **链接语法**。
  //    （实测 JSON 场景 `\["IN", "US"\],` 后面是逗号 ⇒ 不受影响，正常消化）
  if (nx == ']' && backslashAt + 2 < s.length && s[backslashAt + 2] == '(') {
    return false;
  }

  return true;
}

/// `backslashAt` 处的 `\.` 是否处于「行首有序列表」形态。
///
/// 形态：**行首（最多 3 个前导空格）→ 一串数字 → `\.` → 空白或行尾**。
///
/// # 🔴 两处实测补上的条件（初版都漏了，导致拒绝消化的面过大）
///
/// | 条件 | 漏了会怎样 | 实测实例 |
/// |---|---|---|
/// | `\.` 后必须是空白/行尾 | 小数 `66\.4%` / `5\.5` 被判成列表 → **拒绝消化** | 生产库残留 61 处 `\.` |
/// | 数字前的空白必须**一直延伸到行首** | 行内的 `1\.`（**不是**列表）被判成列表 → 拒绝消化 | `…headers in row 1\. If…` · `## 1\. The number…`（标题里）|
///
/// 📌 报据 CommonMark：有序列表标记最多允许 **3 个前导空格**，且必须在行首。
///    这两条都不是「顺手写的防御」，是**用生产数据实测出来的**（残留率暴露的）。
///
/// 🔑 取舍仍然是**宁可保留，不可造语法** —— 但「保留」的面必须精确到
///    **真的会构成列表**那些位置，否则白哥看到的反斜杠会留着不走。
bool _isOrderedListMarker(String s, int backslashAt) {
  // ① `\.` 之后必须是空白或行尾（否则是小数，如 `66\.4%`）
  final after = backslashAt + 2;
  if (after < s.length) {
    final nxt = s[after];
    if (nxt != ' ' && nxt != '\t' && nxt != '\n') return false;
  }

  // ② `\.` 之前必须是一串数字
  var j = backslashAt - 1;
  if (j < 0 || !_isDigit(s[j])) return false;
  while (j >= 0 && _isDigit(s[j])) {
    j--;
  }

  // ③ 数字之前：允许最多 3 个前导空格，再往前必须是行首
  //    🔴 这一步不能省 —— 只查「前一个字符是空白」会把行内/标题里的
  //       `row 1\.` `## 1\.` 也判成列表（实测踩到）。
  var spaces = 0;
  while (j >= 0 && (s[j] == ' ' || s[j] == '\t')) {
    j--;
    spaces++;
  }
  if (j < 0) return spaces <= 3; // 到文本开头也算行首
  return s[j] == '\n' && spaces <= 3;
}

bool _isDigit(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x30 && u <= 0x39;
}

/// [i] 处是否是 LaTeX 区开头，且**该反斜杠本身未被转义**。
///
/// # 🔴 `\[` 只在**行首**才算块级 LaTeX（与消费端对齐）
///
/// `gpt_markdown` 的 `block_parser` 判定块级数学用的是
/// `trimmed.startsWith(r'\[')` ⇒ **只认行首**。
/// 所以行内的 `\[` 在它那里**不是**数学定界符 ——
/// 而生产库恰恰用 `\[` 转义 **JSON 数组的方括号**（`\["IN", "US"\]`，实测 id=1444）。
///
/// ⇒ 若行内也当 LaTeX 跳过，**JSON 里的反斜杠会全部留下来**（白哥报的问题照旧）。
///
/// # 🔴 `\(` 要看**内容**才决定（实测发现它多半不是 LaTeX）
///
/// 我最初以为 `\(...\)` 都是 LaTeX（照 gpt_markdown 的 inline 数学语法）。
/// **用生产库实测后推翻**：437 对 `\(` 里绝大多数是**被转义的普通圆括号** ——
/// `\(66\.4%\)` = `(66.4%)` · `\($0\.10 vs\. $0\.20 for Opus\)`。
/// 若一律跳过，这些位置的反斜杠**永远消化不掉**（实测 id=1452 残留 10 处 `\.`，全在这里）。
///
/// ⇒ 改为**按内容判**：[`_looksLikeLatex`] 认为像公式才跳过，否则当普通括号消化。
/// 📌 判据：**别按「它可能是什么」决定，按「它实际是什么」决定** ——
///    实测数据推翻了我基于包文档的推断（同「支持 X ≠ 符合 X 标准」那类教训）。
///
/// ⚠️ `prev != r'\'` 那一条同样关键：`\\[1em]`（LaTeX 换行 + 间距）里
/// 第二个反斜杠前面也是反斜杠，但它**不是**定界符。
bool _isOpeningLatex(String s, int i, String opener) {
  if (s[i] != r'\') return false;
  if (i + 1 >= s.length || s[i + 1] != opener) return false;
  // 前一个字符若也是反斜杠 → 当前这个是被 `\\` 吃掉的，不是定界符
  if (i > 0 && s[i - 1] == r'\') return false;
  // `\[` 额外要求行首（对齐 gpt_markdown 的 block_parser；见上方说明）
  if (opener == '[') return _atLineStart(s, i);
  // `\(` 要求内容像公式（见上方说明）
  final close = s.indexOf(r'\)', i + 2);
  if (close < 0) return false; // 未闭合 → 不是 LaTeX → 允许按普通括号消化
  return _looksLikeLatex(s.substring(i + 2, close));
}

/// 判断 `\( … \)` 的内容是否**像 LaTeX 公式**。
///
/// # 🔴 必须与「被转义的普通括号」区分开
///
/// dom_smoothie 会把普通圆括号也转义（`(66.4%)` → `\(66\.4%\)`），
/// 而真 LaTeX 是 `\(\alpha\)` `\(\frac{1}{2}\)` `\(x^2\)`。
///
/// 判据用 LaTeX 才有的**标记**：
/// | 标记 | 例 | 会不会误判普通文本 |
/// |---|---|---|
/// | `\` + **字母** | `\alpha` `\frac` `\cdot` | 普通文本里几乎不会出现（`\.` 是反斜杠+非字母，不算）|
/// | `^` / `_` | `x^2` `a_1` | ⚠️ `snake_case` 会被误判 → 代价是**保留**（多显示反斜杠），不是坏结果 |
///
/// 📌 取舍：**宁可保留，不可破坏公式** —— 「多一个反斜杠」只是不好看，
///    「公式被当普通文本」是内容错误。
bool _looksLikeLatex(String inner) {
  // \ + 字母 = LaTeX 命令（\alpha / \frac / \cdot / \begin）
  if (RegExp(r'\\[A-Za-z]').hasMatch(inner)) return true;
  // 上下标
  if (inner.contains('^') || inner.contains('_')) return true;
  return false;
}

/// [i] 是否位于行首（前面只有空白，或就是文本开头）。
bool _atLineStart(String s, int i) {
  for (var j = i - 1; j >= 0; j--) {
    final p = s[j];
    if (p == '\n') return true;
    if (p != ' ' && p != '\t') return false;
  }
  return true;
}

/// 跳过一段 LaTeX（`\[ … \]` 或 `\( … \)`），返回结束位置。
///
/// ⚠️ 找不到闭合 → 返回 `from + 2`（只跳过定界符本身，**不吞掉整篇**）。
/// 同 [_skipBacktick]：**宁可少跳，不可吞内容**。
int _skipLatex(String s, int from, String opener) {
  final closer = opener == '[' ? r'\]' : r'\)';
  final end = s.indexOf(closer, from + 2);
  return end < 0 ? from + 2 : end + 2;
}

/// [i] 处是否是围栏代码块的开头（行首的 ``` 或 ~~~，至少 3 个）。
bool _atFence(String s, int i) {
  final c = s[i];
  if (c != '`' && c != '~') return false;
  for (var j = i - 1; j >= 0; j--) {
    final p = s[j];
    if (p == '\n') break;
    if (p != ' ' && p != '\t') return false;
  }
  var k = i;
  while (k < s.length && s[k] == c) {
    k++;
  }
  return k - i >= 3;
}

/// 跳过一整段围栏代码块，返回**结束位置**（闭合围栏之后的第一个字符）。
///
/// ⚠️ 找不到闭合围栏 → 返回 `length`（把剩下的都当代码块）。
/// 有意的保守选择：**宁可少消化，也不要在「疑似代码」里动反斜杠**。
int _skipFence(String s, int from) {
  final fenceChar = s[from];
  var k = from;
  while (k < s.length && s[k] == fenceChar) {
    k++;
  }
  final fenceLen = k - from;
  var line = k;
  while (line < s.length) {
    final nl = s.indexOf('\n', line);
    if (nl < 0) return s.length;
    final lineStart = nl + 1;
    if (lineStart >= s.length) return s.length;
    var m = lineStart;
    while (m < s.length && s[m] == fenceChar) {
      m++;
    }
    if (m - lineStart >= fenceLen) {
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

/// 跳过一个行内代码段 `` `…` ``，返回结束位置。
///
/// ⚠️ 找不到配对 → 返回 `from + 1`（只跳过这一个反引号，**不吞掉整篇**）。
int _skipBacktick(String s, int from) {
  final close = s.indexOf('`', from + 1);
  if (close < 0) return from + 1;
  return close + 1;
}

/// 跳过一对括号（`open` 位置是 `(`），返回结束位置（`)` 之后）。
///
/// ⚠️ 找不到配对 → 返回 `from + 1`。括号可嵌套 → 计数配对。
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
