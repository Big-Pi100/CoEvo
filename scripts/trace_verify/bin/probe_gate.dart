// CoEvo · 入库「内容质量闸门」—— **Dart 侧独立实现**（与 Rust 生产实现逐定义对齐）
//
// # 它做什么
//
// 用**同一份数据**（生产库只读导出的 fixture）跑两套实现，输出逐条判定，
// 两份输出**必须完全一致**：
//
// ```bash
// cd backend && cargo run --release --example gate_replay -- --tsv \
//     ../scripts/trace_verify/fixtures/prod_content_all.json > /tmp/rust.tsv
// cd scripts/trace_verify && dart run bin/probe_gate.dart > /tmp/dart.tsv
// diff <(cut -f1,8,9 /tmp/rust.tsv) <(cut -f1,2,3 /tmp/dart.tsv)   # 应无差异
// ```
//
// # 🔴 为什么必须逐定义对齐（2026-10-03 的教训）
//
// 上一轮「两处实现」只对齐了**阈值**，没对齐**字符区间表** ⇒
// 我拿 Python 的 `str.isalpha()`（第三套口径）去「验证」前两套 ⇒
// 三方都不一致却谁也没发现（越南语那篇在 Python 口径下 86.8%、在真实实现下 100%）。
// 📌 判据：**跨实现的「相等」必须覆盖全部共享定义** ——
//    阈值 / 区间表 / 词表 / 分词规则 / 分母规则，一个都不能少。
//
// 共享定义清单（改任一 ⇒ **两边同时改**）：
//   ① 阈值          kMinLetters · kEngCharsetTh · kMinTokens · kEngWordTh · kReplacementTh
//   ② 字符区间表    _isEnglishCharset · _isLetter
//   ③ 词表          kEnglishFunctionWords（242 词，从 Rust 侧逐字复制）
//   ④ 分词 + 分母   englishWordStats · _countsAsLanguageWord
//   ⑤ URL 形态      kNonHtmlExtensions · nonHtmlExtension
//
// 跑法：cd scripts/trace_verify && dart run bin/probe_gate.dart [fixture.json]

import 'dart:convert';
import 'dart:io';

// ── ① 阈值（与 Rust `content_quality.rs` 一致）──
const kMinLetters = 50;
const kEngCharsetTh = 0.90;
const kMinTokens = 30;
const kEngWordTh = 0.08;
const kReplacementTh = 0.05;

// ── ⑤ URL 形态（与 Rust `NON_HTML_EXTENSIONS` 一致）──
const kNonHtmlExtensions = <String>{
  "pdf", "doc", "docx", "odt", "rtf", "txt", "epub", "mobi",
  "xls", "xlsx", "ods", "csv", "ppt", "pptx", "odp",
  "zip", "tar", "gz", "bz2", "xz", "7z",
};

// ── ② 字符区间表（与 Rust 一致）──
//
// `_isEnglishCharset` = 「**英语所用字符**」：ASCII 字母 + Latin-1 补充 + 拉丁扩展 A/B。
// ⚠️ **有意排除** `U+1E00–U+1EFF`（拉丁扩展附加，越南语声调字符）——
//    它们**是拉丁字母**，但英语文章不用 ⇒ 算作「非英语字符」。
bool _isEnglishCharset(int c) =>
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    (c >= 0x00C0 && c <= 0x024F); // Latin-1 补充 + 拉丁扩展 A/B

// 「字母」= 分母的覆盖面。多覆盖 ⇒ 更容易拦（不误杀）；少覆盖 ⇒ 漏拦。
bool _isLetter(int c) =>
    _isEnglishCharset(c) ||
    (c >= 0x0300 && c <= 0x036F) || // 组合变音符号（Mn）
    (c >= 0x0370 && c <= 0x03FF) || // 希腊
    (c >= 0x0400 && c <= 0x04FF) || // 西里尔
    (c >= 0x0590 && c <= 0x05FF) || // 希伯来
    (c >= 0x0600 && c <= 0x06FF) || // 阿拉伯
    (c >= 0x1E00 && c <= 0x1EFF) || // 🔴 拉丁扩展附加（越南语声调）★ 上一轮的 bug
    (c >= 0x2C60 && c <= 0x2C7F) || // 拉丁扩展 C
    (c >= 0xA720 && c <= 0xA7FF) || // 拉丁扩展 D
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK
    (c >= 0x3040 && c <= 0x30FF) || // 日文假名
    (c >= 0xAC00 && c <= 0xD7AF); // 韩文音节

// ── ③ 英语功能词表（**逐字**复制自 Rust `ENGLISH_FUNCTION_WORDS`，242 词）──
const kEnglishFunctionWords = <String>{
  "a", "about", "above", "across", "after", "again",
  "against", "all", "almost", "along", "already", "also",
  "although", "always", "am", "among", "an", "and",
  "another", "any", "anyone", "anything", "are", "aren't",
  "around", "as", "at", "away", "back", "be",
  "because", "been", "before", "behind", "being", "below",
  "beneath", "beside", "besides", "between", "beyond", "both",
  "but", "by", "can", "can't", "cannot", "could",
  "couldn't", "despite", "did", "didn't", "do", "does",
  "doesn't", "doing", "don't", "done", "down", "during",
  "each", "either", "else", "enough", "even", "ever",
  "every", "everyone", "everything", "except", "far", "few",
  "for", "from", "further", "had", "hadn't", "has",
  "hasn't", "have", "haven't", "having", "he", "her",
  "here", "hers", "herself", "him", "himself", "his",
  "how", "however", "i", "i'd", "i'll", "i'm",
  "i've", "if", "in", "inside", "instead", "into",
  "is", "isn't", "it", "it's", "its", "itself",
  "just", "later", "let's", "many", "may", "me",
  "might", "mine", "more", "most", "much", "must",
  "my", "myself", "near", "neither", "never", "no",
  "nobody", "nor", "not", "nothing", "now", "of",
  "off", "often", "on", "once", "only", "onto",
  "or", "other", "otherwise", "ought", "our", "ours",
  "ourselves", "out", "outside", "over", "past", "per",
  "quite", "rarely", "rather", "same", "seldom", "shall",
  "she", "should", "shouldn't", "since", "so", "some",
  "someone", "something", "sometimes", "soon", "still", "such",
  "than", "that", "that's", "the", "their", "theirs",
  "them", "themselves", "then", "there", "there's", "therefore",
  "these", "they", "they're", "they've", "this", "those",
  "though", "through", "throughout", "thus", "to", "together",
  "too", "toward", "towards", "under", "underneath", "unless",
  "until", "up", "upon", "us", "usually", "very",
  "via", "was", "wasn't", "we", "we're", "we've",
  "were", "weren't", "what", "whatever", "when", "whenever",
  "where", "whereas", "wherever", "whether", "which", "whichever",
  "while", "who", "whom", "whose", "why", "will",
  "with", "within", "without", "won't", "would", "wouldn't",
  "yet", "you", "you're", "you've", "your", "yours",
  "yourself", "yourselves",
};

// ── ④ 判据实现 ──

/// `[字母总数, 英语所用字符数]`
List<int> countLetters(String s) {
  var letters = 0, eng = 0;
  for (final c in s.runes) {
    if (_isLetter(c)) {
      letters++;
      if (_isEnglishCharset(c)) eng++;
    }
  }
  return [letters, eng];
}

/// 替换字符 `U+FFFD` 占比
double replacementRatio(String s) {
  var n = 0, total = 0;
  for (final c in s.runes) {
    total++;
    if (c == 0xFFFD) n++;
  }
  return total == 0 ? 0.0 : n / total;
}

/// 这个 token 算不算「自然语言词」（→ 是否计入分母）。
/// 与 Rust `counts_as_language_word` 一致：缩写（全大写，≥2 字母）与超长串**不进分母**。
bool _countsAsLanguageWord(String tok) {
  final n = tok.runes.length;
  if (n < 2) return true; // 单字母（`I` / `a`）保留
  if (n > 20) return false;
  var upper = 0, lower = 0;
  for (final c in tok.runes) {
    if (c >= 0x41 && c <= 0x5A) upper++;
    if (c >= 0x61 && c <= 0x7A) lower++;
  }
  return !(upper >= 2 && lower == 0);
}

/// `[词总数, 其中英语功能词数]`
///
/// 🔑 分词规则：连续字母为词；撇号（`'` / `’`）算词内字符且归一为 `'`；
///    **保留原始大小写**（缩略语过滤要用），查表时才 `toLowerCase()`。
List<int> englishWordStats(String s) {
  var tokens = 0, hits = 0;
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    final tok = buf.toString();
    if (_countsAsLanguageWord(tok)) tokens++;
    if (kEnglishFunctionWords.contains(tok.toLowerCase())) hits++;
    buf.clear();
  }

  for (final c in s.runes) {
    if (_isLetter(c)) {
      buf.writeCharCode(c);
    } else if ((c == 0x27 || c == 0x2019) && buf.isNotEmpty) {
      buf.writeCharCode(0x27);
    } else {
      flush();
    }
  }
  flush();
  return [tokens, hits];
}

/// 从 URL 提取「非 HTML 文档」扩展名；`null` = 不是文档（或判不出来）。
String? nonHtmlExtension(String url) {
  final path = url.split(RegExp(r'[?#]')).first;
  // 取最后一个非空段（尾部斜杠时 `last` 会拿到空串 ⇒ 要跳过）
  String? last;
  for (final seg in path.split('/').reversed) {
    if (seg.isNotEmpty) {
      last = seg;
      break;
    }
  }
  if (last == null) return null;
  final i = last.lastIndexOf('.');
  if (i < 0 || i == last.length - 1) return null;
  final ext = last.substring(i + 1).toLowerCase();
  return kNonHtmlExtensions.contains(ext) ? ext : null;
}

/// 判定一条内容该不该入库。`null` = 通过。
String? checkContent(String title, String text, String url) {
  // ① URL 形态
  final ext = nonHtmlExtension(url);
  if (ext != null) return "非 HTML 文档（.$ext）";

  final all = "$title\n$text";

  // ② 乱码
  final rep = replacementRatio(all);
  if (rep > kReplacementTh) {
    return "编码乱码（替换字符 ${(rep * 100).round()}%）";
  }

  // ③ 字符集（样本不足则**不判，但继续**）
  final l = countLetters(all);
  if (l[0] >= kMinLetters) {
    final r = l[1] / l[0];
    if (r < kEngCharsetTh) {
      return "非英语文字（英语字符仅 ${(r * 100).round()}%）";
    }
  }

  // ④ 词汇
  final w = englishWordStats(all);
  if (w[0] >= kMinTokens) {
    final r = w[1] / w[0];
    if (r < kEngWordTh) {
      return "非英语词汇（英语功能词仅 ${(r * 100).round()}%）";
    }
  }

  return null;
}

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : 'fixtures/prod_content_all.json';

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln(
        "🔴 找不到 fixture: $path\n   先用 dump_prod_content.py 从生产库只读导出");
    exit(1);
  }

  final rows =
      jsonDecode(file.readAsStringSync(encoding: utf8)) as List<dynamic>;

  // 与 `gate_replay --tsv` 的 (id, verdict, criteria) 三列对齐
  for (final r in rows) {
    final m = r as Map<String, dynamic>;
    final body = (m['body'] ?? '') as String;
    final summary = (m['summary'] ?? '') as String;
    // 🔑 复刻 `write_items` 的取文本逻辑（非空才优先 body）
    final gate = body.trim().isNotEmpty ? body : summary;
    final v = checkContent(
      (m['title'] ?? '') as String,
      gate,
      (m['url'] ?? '') as String,
    );
    stdout.writeln('${m['id']}\t${v == null ? "keep" : "REJECT"}\t${v ?? ""}');
  }
  stderr.writeln('probe_gate: ${rows.length} 条已输出（stdout）');
}
