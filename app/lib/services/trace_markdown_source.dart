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
// # 🆕 2026-10-07：**划线**也走这条路径（但匹配方式不同）
//
// 划线与痕迹是**同一条链上的两种标记**，共用「插标记 → `InlinePattern` 渲染」这个机制，
// 差别只在**怎么找到要标的那段文字**：
//
// | | 怎么找 | 为什么 |
// |---|---|---|
// | 痕迹 | **按词匹配**（`\b词\b`）| 已查词只有「哪些词」，**没有位置** |
// | **划线** | **按字符区间（offset）** | 用户拖动**选中**了它 ⇒ `highlight` 表存了 `start/end` |
//
// 🔴 **注入顺序是硬约束**（错了就静默画错位置）：
// ```
// 原始 markdown ──① 划线（按 offset）──▶ ──② unescape ──▶ ──③ 痕迹（按词）──▶ 渲染
// ```
// · ① 必须在 ② **之前**：unescape 会**删反斜杠**（`\.` → `.`）⇒ 之后偏移全错位
// · ② 必须在 ③ 之前：这是**既有**顺序（痕迹标记描述的是「消化后要渲染的那段文本里的词」）
// · ③ 会自动**跳过** ① 插入的标记（见 [injectTraceMarkers] 的 ④ 分支）——
//   划线**优先**：划过的片段里那些已查词**不再有底色**（两者都是高亮，叠加会互相干扰）
//
// ⚠️ 两处「使用同一批跳过区」：`_noMarkRanges`（划线用）与主循环 ①②③（痕迹用）
//    共用 [_atFence] / [_skipFence] / [_skipBacktick] / [_skipParen]，
//    但**入口条件各写一份** ⇒ 改一处必须看另一处。
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

// ───────────────────────────────────────────────────────────────────────
// 划线：另一种「正文上的标记」（2026-10-07）
// ───────────────────────────────────────────────────────────────────────

/// **划线**标记的控制字符。
///
/// 与痕迹同族（`\u0001` / `\u0002`），取下一个可用值 —— 理由完全相同：
/// **正文不可能包含 C0 控制码**（见文件头那张候选对照表）。
///
/// 🔑 用**第三个**字符而不是复用 `\u0001`：痕迹与划线是**两种语义**
/// （「系统记的已查词」vs「我划的」），要渲染成**两种样式**
/// （底色浸透 vs 下划线）—— 复用字符就区分不出来了。
const String kHighlightOpen = '\u0003';

/// 匹配一段划线标记：`\u0003内容\u0003`。
///
/// 同 [kTraceMarkerPattern]：**同字符开闭** ⇒ 半截标记不会被吞掉。
final RegExp kHighlightMarkerPattern = RegExp('\u0003([^\u0003]*?)\u0003');

/// 把**划线**包成标记（**按字符区间**，在**原始 markdown** 上做）。
///
/// # 🔴 为什么划线可以按 offset，而痕迹必须按词匹配
///
/// 这是两者最关键的区别，也是本函数与 [injectTraceMarkers] 分开的原因：
///
/// | | 输入是什么 | 能不能用偏移 |
/// |---|---|---|
/// | 痕迹 | 「哪些词已查过」——**没有位置信息** | ❌ 只能按词匹配 |
/// | **划线** | 用户拖动**选中的区间** ⇒ 存了 `start/end` | ✅ **有偏移，且是准的** |
///
/// 🔑 而偏移之所以准，是因为**顺序**：
/// ```
/// 原始 markdown ──① 本函数（按 offset 插划线标记）──▶ ──② unescape ──▶ ──③ 痕迹（按词）──▶ 渲染
/// ```
/// ③ 必须在 ① 之后（痕迹不看偏移）；而 ① 必须在 **② 之前** ——
/// 因为 unescape 会**删反斜杠**（`\.` → `.`），② 之后偏移就全错位了。
///
/// ⚠️ 划线**不含它自己的位置以外的信息**：本函数只收 `(start, end)`，
///    不收 id —— 因为渲染层此刻不需要「点它打开哪条」（那要等划线清单页）。
///    将来若要做可点击，是**给这条 record 加字段**，不是另写一份注入。
///
/// # 🔴 与三个「禁插区」的关系：**做差集，不是整条丢弃**
///
/// 代码块 / 行内代码 / 链接 URL 里**不能**插控制字符（插了会污染代码、破坏链接）。
/// 若一条划线**跨**过它们：
///
/// | 做法 | 后果 |
/// |---|---|
/// | 整条不画 | 用户划了一大段，其中只有一个行内代码 ⇒ **整段都看不到下划线** |
/// | **做差集（本函数）** | 划线在禁插处**断开**，两侧照画 ⇒ 视觉上正确（代码本就不该有下划线）|
///
/// 📌 判据：**「局部无效」不该让「整体失效」** —— 能保住的部分就保住。
///
/// # ⚠️ 幂等性：本函数**要求输入是未插过标记的原始 markdown**
///
/// 检测到 [kHighlightOpen] 就**原样返回**（不做任何事）——
/// 因为一旦已有标记，长度就变了，**偏移全部失配**，再插一次会把标记插错位置。
/// 🔑 与其静默插错，不如**什么都不做**（渲染出来是「划线没画」，而不是「线画到别处」）。
/// ⚠️ 调用方（`TraceMarkdown`）保证只在渲染前调一次。
String injectHighlightMarkers({
  required String markdown,
  required List<({int start, int end})> ranges,
}) {
  if (markdown.isEmpty || ranges.isEmpty) return markdown;
  // 已插过 ⇒ 偏移已失配 ⇒ 不做（见上文「幂等性」）
  if (markdown.contains(kHighlightOpen)) return markdown;

  // ── ① 过滤 + 钳制 + 排序 + 合并重叠 ──
  //
  // 🔴 口径必须与 `highlight_span.buildTextSegments`（书架页的切分）**一致** ——
  //    同一个文本在两页渲染成不同数量的下划线，是最难查的一类不一致。
  //    ⚠️ 但**不共用代码**：那边产出的是 `TextSegment`（含 id、供点击），
  //       这边产出的是 String（供 Markdown 解析）。共用的应该是**口径**，不是函数。
  final usable = <({int start, int end})>[];
  for (final r in ranges) {
    if (r.start < 0 || r.end <= r.start) continue;
    if (r.start >= markdown.length) continue;
    usable.add((
      start: r.start,
      end: r.end > markdown.length ? markdown.length : r.end,
    ));
  }
  if (usable.isEmpty) return markdown;
  usable.sort((a, b) => a.start.compareTo(b.start));
  final merged = <({int start, int end})>[];
  for (final r in usable) {
    if (merged.isEmpty) {
      merged.add(r);
      continue;
    }
    final last = merged.last;
    if (r.start < last.end) {
      merged[merged.length - 1] = (
        start: last.start,
        end: r.end > last.end ? r.end : last.end,
      );
    } else {
      merged.add(r);
    }
  }

  // ── ② 不可包标记的区间（代码 / URL / 行内语法）──
  final noMark = _noMarkRanges(markdown);

  // ── ③ 逐条插标记（与禁插区做差集）──
  final out = StringBuffer();
  var cursor = 0;
  for (final r in merged) {
    for (final seg in _subtract(noMark, r.start, r.end)) {
      // 🔴 防御：`_subtract` 保证 `seg` 落在 `[r.start, r.end]` 内，
      //    且按序返回 ⇒ `seg.start >= cursor` 恒成立。
      //    写出来是**为了不改坏时立刻暴露**（若哪天 `_subtract` 改了行为，
      //    这里会跳过而不是产出乱序文本 —— 静默产出错序文本比少画一条线糟得多）。
      if (seg.start < cursor || seg.end <= seg.start) continue;
      out.write(markdown.substring(cursor, seg.start));
      out.write(kHighlightOpen);
      out.write(markdown.substring(seg.start, seg.end));
      out.write(kHighlightOpen);
      cursor = seg.end;
    }
  }
  out.write(markdown.substring(cursor));
  return out.toString();
}

/// 扫描出**禁止包标记**的区间。
///
/// # 两类来源（判据不同，但后果同一条：那里不能出现控制字符）
///
/// | 类 | 区间 | 不排除的后果 |
/// |---|---|---|
/// | **① 结构区**（顺序扫描）| 围栏代码块 · 行内代码 · 链接 URL | 污染代码内容 / 🔴 **链接失效** |
/// | **② 行内语法定界符**（逐字符）| `*` `~` `[` `]` | 🔴 **整条划线不显示**（见下）|
///
/// # 🔴 ② 是**探针实测**逼出来的，不是推理出来的
///
/// 探针：`app/tool/highlight_marker_probe.dart`（注入 → **真实解析器** `plusparse` → 匹配）。
/// 结论：**标记一旦跨过会改变节点结构的字符，就会被拆到不同节点** ⇒
/// 渲染层的 `InlinePattern`（它匹配的是「**解析产出的文本**」，见 `gpt_markdown` 文档）
/// 匹配不上 ⇒ 划线**整条不显示**。
///
/// ```
/// 源　：A ⟦ great **best** moment⟦ today.      ← 标记跨过 `**`
/// 解析：T「A ⟦ great 」 + B(T「best」) + T「 moment⟦ today.」   ← 一对标记被拆开 ⇒ 匹配不上
/// ```
///
/// ✅ **好消息**：最坏情况是「少画一条线」，**不是**「把 `**` 当字面文本显示」——
///    控制字符本身不会被渲染出来（探针确认）。
/// ❌ 但它**静默**（用户划了一整句，因为句里有个粗体词 ⇒ 整句都没有下划线）。
///
/// # 🔴 所以排除的是**定界符本身**，不是整个语法单元
///
/// ⚠️ 这里踩过一次：**首版把 `**bold**` 整段排除**，探针立刻报出回归 ——
///    那会让「**划线整个落在粗体里**」也变成「不画」（本该正常工作的情形）。
///    📌 判据：**排除的范围要精确到「真的会拆节点的那几个字符」**，
///       过宽会把能工作的情形一起排除掉（同 `markdown_unescape` 里
///       「保留的面必须精确到真的会构成列表那些位置」那一族）。
///
/// 排除定界符之后，标记在它们**两侧断开**，各自成对：
/// ```
/// 注入：A ⟦A ⟦**⟦great⟦**⟦ b⟦     （示意）
/// 解析：T(A…两个标记) + B(T(great…成对)) + T( b…成对)  ⇒ 都匹配 ✅
/// ```
/// 视觉上：下划线在粗体词处**断开**（粗体词自身也有下划线，只是被 `**` 隔成独立 span
/// —— 相邻 span 的下划线在视觉上仍是连着的）。**可以接受**。
///
/// 📌 判据：**「局部无效」不该让「整体失效」** —— 与「跨代码块」是同一条。
List<({int start, int end})> _noMarkRanges(String s) {
  final out = <({int start, int end})>[];

  // ── ① 结构区：顺序扫描（与 `injectTraceMarkers` 主循环的 ①②③ 同判据）──
  var i = 0;
  while (i < s.length) {
    if (_atFence(s, i)) {
      final e = _skipFence(s, i);
      out.add((start: i, end: e));
      i = e;
      continue;
    }
    if (s[i] == '`') {
      final e = _skipBacktick(s, i);
      out.add((start: i, end: e));
      i = e;
      continue;
    }
    if (s[i] == ']' && i + 1 < s.length && s[i + 1] == '(') {
      // ⚠️ 只跳括号（URL）——`[文字]` 那部分由 ② 的 `[` `]` 覆盖
      final e = _skipParen(s, i + 1);
      out.add((start: i, end: e));
      i = e;
      continue;
    }
    i++;
  }

  // ── ② 行内语法定界符：逐字符（只排字符本身，不排内容）──
  for (var k = 0; k < s.length; k++) {
    if (_kInlineDelimiters.contains(s[k])) {
      out.add((start: k, end: k + 1));
    }
  }

  return out;
}

/// 行内**语法定界符**字符 —— 它们会改变解析出的节点结构。
///
/// ⚠️ 只放「**确实会拆节点**」的（探针实测）：
/// · `*` —— 强调 / 粗体（`**` 由两个 `*` 自然覆盖）
/// · `~` —— 删除线（`~~`）
/// · `[` `]` —— 链接文字的边界
///
/// 🔴 **不放** `` ` ``：行内代码由 ① 整段跳过（连内容一起），逐字符排除是多余的。
/// 🔴 **不放** `_`：`plusparse` **不支持** `_` 强调（`ast_probe.dart` 实测）⇒
///    它不拆节点，排除了反而白断。
/// 🔴 **不放** `(` `)`：单独出现是普通括号；而真正的 URL 已由 ① 跳过。
const Set<String> _kInlineDelimiters = {'*', '~', '[', ']'};

/// `[a, b)` 减去 [forbidden] 里的所有区间，返回剩下的若干**保序不重叠**子区间。
///
/// 纯区间运算（同一份 `forbidden` 用于所有划线 ⇒ 由调用方算一次）。
/// 返回的子区间**按位置升序**，且两两不重叠 —— 调用方依赖这两条性质。
List<({int start, int end})> _subtract(
  List<({int start, int end})> forbidden,
  int a,
  int b,
) {
  var segs = <({int start, int end})>[(start: a, end: b)];
  for (final f in forbidden) {
    if (segs.isEmpty) break;
    final next = <({int start, int end})>[];
    for (final s in segs) {
      // 不相交 ⇒ 原样留下
      if (f.end <= s.start || f.start >= s.end) {
        next.add(s);
        continue;
      }
      // 相交 ⇒ 切掉中间那段（两侧若有剩余则各自成为一段）
      if (f.start > s.start) next.add((start: s.start, end: f.start));
      if (f.end < s.end) next.add((start: f.end, end: s.end));
    }
    segs = next;
  }
  return segs;
}

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

    // ── ④ 🔑 已有标记（痕迹 或 🆕划线）→ 原样跳过（**保证幂等**）──
    //    为什么需要：控制字符不是「单词字符」，所以 `\bword\b` 在
    //    `\u0001word\u0001` 里**仍然匹配** word → 若不跳过，重复调用会变成
    //    `\u0001\u0001word\u0001\u0001`（双层标记 → 渲染出一层多余的控制字符）。
    //    📌 判据：**幂等不是「顺便做到的」，要么显式保证、要么显式声明非幂等** ——
    //       这里的代价只有几行，而「被调用两次」在生产代码里太容易发生
    //       （换渲染器的重构、重试、状态变化都会重新走一遍）。
    //
    // 🆕 2026-10-07：**划线标记也一并跳过**。
    //    🔴 这不只是「避免双层标记」，而是一次**有意的语义取舍**：
    //       划线区间**整段**跳过 ⇒ 划过的片段里那些「已查过的词」**不再有痕迹底色**，
    //       只显示下划线。
    //    🔑 为什么这样取舍：两者都是「高亮」，叠加会**互相干扰**
    //       （下划线 + 底色同时出现在一个词上，用户分不清哪个是谁留的）。
    //       ⇒ 按项目既有判据「**形状区分优于参数**」，这里让它们**互斥**：
    //          **用户自己的动作（划线）优先于系统的记录（痕迹）**。
    //    ⚠️ 顺序上这也是必然的：划线按 offset 注入（必须先做），
    //       痕迹按词注入（后做）—— 后做的那个必然遇到先做的标记。
    //    📌 若要改成「共存」，动的是这里（要渲染嵌套 span），**不是加个开关**。
    final c = markdown[i];
    if (c == kTraceFreshOpen ||
        c == kTraceReviewingOpen ||
        c == kHighlightOpen) {
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
/// （围栏 / 反引号 / `](` / **已有的痕迹或划线标记**）。
///
/// 找不到则返回 `length`（走到结尾）。
///
/// ⚠️ 这里的条件与 [injectTraceMarkers] 主循环的 ①②③④ 分支**必须永远一致** ——
///    不一致的后果是死循环（见主循环里那段 `next == i` 的防御）。
/// 🆕 2026-10-07：加 `\u0003`（划线标记）—— 与主循环 ④ 同步改，**不能只改一处**。
int _nextSpecial(String s, int from) {
  for (var i = from; i < s.length; i++) {
    final c = s[i];
    if (c == '`') return i;
    if (c == kTraceFreshOpen ||
        c == kTraceReviewingOpen ||
        c == kHighlightOpen) {
      return i;
    }
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
