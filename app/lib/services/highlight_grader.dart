// CoEvo · 划线记忆的「默写」判定 —— 给骨架 → 写出原文 → 判定（**纯 Dart · 本机可独立验证**）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `spelling_grader.dart` /
//    `review_list_query.dart` 的理由）→ 纯 Dart 才能本地独立验证
//    （见 `scripts/query_verify/bin/verify_highlight_grader.dart`）。
//
// # 它服务什么（白哥 2026-10-07 定）
// > 「**复习的时候考默写，和单词一样**」
//
// ⇒ **动作一样**：看到提示 → 写出内容 → 判定 → 两档（`good` / `again`）。
//   差别只在**提示形式**：
//   · 单词卡：提示 = 释义（中文）
//   · **划线卡：提示 = 首字母骨架**（纯算法生成 · 零成本 · 任意长度都能生成）
//
// # 🔴🔴 判定**不能**复用 `gradeSpelling` —— 标点口径相反
// | 处理 | 单词卡（`spelling_grader`） | **划线卡（本文件）** |
// |---|---|---|
// | 大小写 / 全角 / 首尾空白 | ✅ 归一化 | ✅ 归一化 |
// | **句读标点**（`,` `.` `!` `?` …） | 🔴 **敏感** —— 刻意保留（`a.m.` ≠ `am` 是词库里真实区分） | ✅ **剔除** —— 默写长句少一个逗号**不代表没记住** |
// | 比较单位 | 整串相等 | **逐词对齐 + 按错词比例判** |
//
// ⇒ 硬用 `gradeSpelling` 会让「少一个逗号」判成「忘了」—— 对长句是**灾难**。
//   但 **`ratingForSpelling(correct:)` 直接复用**（对/错 → good/again 的映射没变）。
//
// # 🔑 为什么「按比例判」而不是「错一个就全错」
// 固定容错数（错 ≤1 词）在**短句上太松**、在**长句上太严**；
// **比例阈值天然两端都对**，且它是**用户可调**的（「我的 → 记忆」的滑动条）。
//
// ⚠️ 阈值默认 **5%**（白哥 2026-10-07 定）—— 它**很严**：
//    判定用**整数比较** `错词数 × 100 ≤ 总词数 × 百分比`（避开浮点）。
//    对**≤19 词**的内容：错 1 个即 > 5% ⇒ **与单词卡的逐字严格同级**。
//    ⇒ 短语 / 短句与单词卡同一条线，容错只对**长段**生效。

/// 默写判定的默认阈值（%）。
///
/// 🔑 与「我的 → 记忆」滑动条的**初值**是同一个数 —— 但那个是**用户设置值**，
/// 运行时以设置值为准，本常量只是缺省与文档锚点。
const int kClozeDefaultMaxWrongPercent = 5;

/// 阈值的可调范围（滑动条 0–30%）。
///
/// · **0** = 严格全对（与单词卡逐字一致）
/// · **30** = 最宽（只要大意对就算记住）
const int kClozeMinWrongPercent = 0;
const int kClozeMaxWrongPercent = 30;

/// 骨架的揭示程度。
///
/// 🔑 「揭示多少」是**一个参数** —— 难度不用改结构就能调。
/// 第一期固定 [firstLetter] 不开放（设计稿 §1）。
enum SkeletonReveal {
  /// 一个字都不给：`_____`。
  none,

  /// 只给首字母：`a________. N___ of t___ …`（**默认**）。
  firstLetter,

  /// 给前两个字母。
  firstTwo,
}

/// 一个「词」里的字符：字母 / 数字。
final RegExp _wordRune = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

/// 词内连接符 —— 撇号与连字符**属于词**（`don't` · `e-mail`），原样保留。
///
/// 🆕 收打字机变体：`’`(U+2019)（**iOS 智能标点**会把 `'` 换掉）· `‐`/`‑`(U+2010/2011)。
/// 理由同 `picked_text.dart` —— 不认它们会让同一句话在两侧归一化成不同结果。
bool _isJoinRune(int r) =>
    r == 0x27 || // '
    r == 0x2019 || // ’
    r == 0x2D || // -
    r == 0x2010 || // ‐
    r == 0x2011; // ‑

/// 生成默写提示骨架。
///
/// # 规则
/// · **只遮「字母 / 数字」**，标点与空白**原样保留**（它们是句子的骨架，不是要背的内容）
/// · 每个词保留前 `keep` 个「字母/数字」，其余**逐字**换成 `_`（长度信息不丢）
/// · 词内的撇号 / 连字符**原样保留**（`don't` → `d__'_`）—— 它们是**结构**
/// · **不做小写化**：骨架保留原文大小写（`None` → `N___`）
///
/// ⚠️ 骨架是在**原文**上做的，不是在归一化结果上 —— 否则标点会被吃掉，
///    而骨架的意义之一正是「让人看出句子的形状」。
String skeletonFor(
  String text, {
  SkeletonReveal reveal = SkeletonReveal.firstLetter,
}) {
  final keep = switch (reveal) {
    SkeletonReveal.none => 0,
    SkeletonReveal.firstLetter => 1,
    SkeletonReveal.firstTwo => 2,
  };

  final out = StringBuffer();
  var inWord = false;
  var letterIndex = 0;

  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    if (_wordRune.hasMatch(ch)) {
      if (!inWord) {
        inWord = true;
        letterIndex = 0;
      }
      out.write(letterIndex < keep ? ch : '_');
      letterIndex++;
    } else if (_isJoinRune(r) && inWord) {
      out.write(ch); // 词内连接符：保留
    } else {
      inWord = false;
      out.write(ch); // 标点 / 空白：原样
    }
  }
  return out.toString();
}

/// **句子级归一化** —— 只做「与"记住内容"无关的那些差异」的折叠。
///
/// | 处理 | 为什么 |
/// |---|---|
/// | 全角 → 半角（含全角空格 `U+3000`） | **中文输入法**下极易打出全角 —— 那是**输入法变体**，不是另一种内容 |
/// | 🆕 **打字机变体 → ASCII** | `’`→`'` · `‐`/`‑`→`-`。🔴 **iOS 智能标点会把 `'` 自动换成 `’`** ⇒ 不折叠的话，用户明明写对也被判错 |
/// | 统一小写 | 大小写不是「记没记住」的判据 |
/// | 🔴 **句读标点 → 词边界** | 「少一个逗号」不该判成「忘了」（对比：单词卡**刻意**对标点敏感） |
/// | 折叠连续空白 | 多按空格不是内容错 |
/// | **保留**撇号 / 连字符 | `don't` · `e-mail` 里它们是**词的一部分**（与 `spelling_grader` 的严格口径一致） |
///
/// 🔑 **标点变「空格」而不是「删除」** —— 删除会让 `well,then` 粘成 `wellthen`（凭空造词）；
///    变空格则得到 `well then`（正确的词边界）。
///
/// ⚠️ 副作用（**有意接受**）：`a.m.` 会归一化成 `a m`（两句点变空格）。
///    这**不造成误判** —— 因为 input 与 expected 走**同一个函数**，两边一致。
String normalizeSentence(String raw) {
  final out = StringBuffer();
  var pendingSpace = false;
  var wroteAny = false;

  for (final r in raw.runes) {
    var c = r;
    // 全角 ASCII（U+FF01–U+FF5E）→ 半角（U+0021–U+007E）：偏移 0xFEE0
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20; // 全角空格
    // 🆕 打字机变体 → ASCII：两侧必须折叠到**同一个字面**，
    //    否则「原文用 `'`、用户打出 `’`」会判成不相等（iOS 智能标点会替换）。
    if (c == 0x2018 || c == 0x2019) c = 0x27; // ‘ ’ → '
    if (c == 0x2010 || c == 0x2011) c = 0x2D; // ‐ ‑ → -

    final ch = String.fromCharCode(c);
    if (_wordRune.hasMatch(ch) || _isJoinRune(c)) {
      if (pendingSpace && wroteAny) out.write(' ');
      pendingSpace = false;
      out.write(ch);
      wroteAny = true;
    } else {
      // 空白 / 句读标点 ⇒ 都当「词边界」（折叠成单个空格）
      pendingSpace = true;
    }
  }

  return out.toString().toLowerCase();
}

/// 归一化后切成词。
List<String> sentenceWords(String text) {
  final n = normalizeSentence(text);
  if (n.isEmpty) return const [];
  return n.split(' ').where((w) => w.isNotEmpty).toList(growable: false);
}

/// 对齐后的逐词差异类型（供结果页**标出错在哪**）。
enum ClozeWordKind {
  /// 一致。
  ok,

  /// 该位置写错了（替换）。
  wrong,

  /// 原文有、用户没写（漏）。
  missing,

  /// 用户多写的（多）。
  extra,
}

/// 一个对齐项。
class ClozeWordDiff {
  const ClozeWordDiff({
    required this.kind,
    required this.expectedIndex,
    this.expected,
    this.got,
  });

  final ClozeWordKind kind;

  /// 在**原文词序列**里的下标（[ClozeWordKind.extra] 时表示「插在这个位置之前」）。
  final int expectedIndex;

  final String? expected;
  final String? got;

  @override
  String toString() => '${kind.name}(${expected ?? '-'} / ${got ?? '-'})';
}

/// 一次默写判定的结果。
class ClozeGrade {
  const ClozeGrade({
    required this.expectedWords,
    required this.wrongWords,
    required this.maxWrongPercent,
    required this.diffs,
  });

  /// 原文词数（**比例的分母** —— 用原文而不是用户输入，避免「少写一半」反而显得更准）。
  final int expectedWords;

  /// **错词数** = 词级编辑距离（替换 + 漏 + 多）。
  ///
  /// 🔑 用编辑距离而**不是**「按下标逐位比」—— 后者在**漏一个词**时会让后面**全部错位**，
  ///    错词数虚高到接近总词数 ⇒ **长句也会被判「忘了」**，正好违背本功能的意图。
  final int wrongWords;

  final int maxWrongPercent;

  /// 对齐路径（按原文顺序），供结果页标注。
  final List<ClozeWordDiff> diffs;

  /// 错词比例（仅供展示 —— **判定本身用整数比较**）。
  double get wrongRatio =>
      expectedWords == 0 ? 1 : wrongWords / expectedWords;

  /// 是否判为「记得」。
  ///
  /// 🔴 **整数比较**：`错词数 × 100 ≤ 总词数 × 百分比`。
  ///    用浮点会在 `0.1 + 0.2` 这类值上出现「本该相等却不等」的边界抖动。
  bool get correct =>
      expectedWords > 0 && wrongWords * 100 <= expectedWords * maxWrongPercent;

  /// 结果页要标出的错词（不含 [ClozeWordKind.ok]）。
  List<ClozeWordDiff> get mistakes =>
      diffs.where((d) => d.kind != ClozeWordKind.ok).toList(growable: false);
}

/// 判定一次默写：`input` 是用户写的，`expected` 是原文。
///
/// # 阈值语义（**必须与「我的 → 记忆」滑动条的口径一致**）
/// 传进来的是**百分比整数**（0–30）。默认 [kClozeDefaultMaxWrongPercent]。
///
/// ⚠️ 越界值**夹紧**而不是抛错：阈值来自用户设置，历史设置值可能超出当前范围
/// （比如以后把上限从 30 收到 20）—— 那时**应该仍然能判定**，不是崩掉。
ClozeGrade gradeCloze(
  String input,
  String expected, {
  int maxWrongPercent = kClozeDefaultMaxWrongPercent,
}) {
  final pct = maxWrongPercent.clamp(
    kClozeMinWrongPercent,
    kClozeMaxWrongPercent,
  );

  final e = sentenceWords(expected);
  final g = sentenceWords(input);

  final n = e.length;
  final m = g.length;

  // ── 词级编辑距离 DP ──
  // dp[i][j] = 把 e[0..i) 变成 g[0..j) 的最少操作数
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 1; i <= n; i++) {
    dp[i][0] = i; // 原文有的，用户全没写 ⇒ 每个都是「漏」
  }
  for (var j = 1; j <= m; j++) {
    dp[0][j] = j; // 用户多写的 ⇒ 每个都是「多」
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (e[i - 1] == g[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1];
      } else {
        final sub = dp[i - 1][j - 1] + 1;
        final del = dp[i - 1][j] + 1;
        final ins = dp[i][j - 1] + 1;
        dp[i][j] = sub < del ? (sub < ins ? sub : ins) : (del < ins ? del : ins);
      }
    }
  }

  // ── 回溯出对齐路径（供结果页标错）──
  final reversed = <ClozeWordDiff>[];
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && e[i - 1] == g[j - 1] && dp[i][j] == dp[i - 1][j - 1]) {
      reversed.add(ClozeWordDiff(
        kind: ClozeWordKind.ok,
        expectedIndex: i - 1,
        expected: e[i - 1],
        got: g[j - 1],
      ));
      i--;
      j--;
    } else if (i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1) {
      reversed.add(ClozeWordDiff(
        kind: ClozeWordKind.wrong,
        expectedIndex: i - 1,
        expected: e[i - 1],
        got: g[j - 1],
      ));
      i--;
      j--;
    } else if (i > 0 && dp[i][j] == dp[i - 1][j] + 1) {
      reversed.add(ClozeWordDiff(
        kind: ClozeWordKind.missing,
        expectedIndex: i - 1,
        expected: e[i - 1],
      ));
      i--;
    } else if (j > 0 && dp[i][j] == dp[i][j - 1] + 1) {
      reversed.add(ClozeWordDiff(
        kind: ClozeWordKind.extra,
        expectedIndex: i, // 插在 i 之前
        got: g[j - 1],
      ));
      j--;
    } else {
      // 防御：正常的 Levenshtein 表**必然**命中上面某一支。
      // 走到这里说明 DP 被改坏了 —— 宁可少标一个词，也不能死循环。
      i--;
      j--;
    }
  }

  return ClozeGrade(
    expectedWords: n,
    wrongWords: dp[n][m],
    maxWrongPercent: pct,
    diffs: reversed.reversed.toList(growable: false),
  );
}
