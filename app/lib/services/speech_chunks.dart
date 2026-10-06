// CoEvo · 朗读文本分段（**零 import · 纯 Dart** ⇒ 本机可断言）
//
// # 🔴 为什么必须分段（2026-10-05 真机反馈）
//
// 症状：书库「整章朗读」点了**没有任何声音**，且**不报错**。
//
// 根因链：
//   1. `book_reader_screen` 把**整章正文**（数千～数万字符）交给 `togglePlay`
//   2. `TtsService._cleanText` 只做字符串替换 —— **不截断、不分段**
//   3. 🔴 而平台有**单次输入上限**：
//      · Android `TextToSpeech.getMaxSpeechInputLength()` ≈ **4000 字符**（AOSP 常量）
//      · iOS `AVSpeechUtterance` 同样有实际输入上限
//      ⇒ 一章必然超
//   4. 🔴 且 `awaitSpeakCompletion` **未开启** ⇒ `speak()` 立即返回，
//      Dart 侧**收不到失败** ⇒ 「第三方库报成功」≠「真的读了」
//
// 📌 判据（两条，都是既有条目）：
//   · **「量级首次升级」** —— 既有调用点只有词卡（几十字符）与音色试听（十几字符），
//     从没触发上限；书库整章是**第一次喂大数据**
//   · **「第三方库报成功」不能当作「执行成功」**（同 `TtsService` 的语速事故那一族）
//
// # 为什么单独一个文件、且零 import
//
// 本项目**本机跑不了 flutter**（`dart analyze` 崩 · 渲染验不了）⇒
// 凡是能脱离框架的逻辑，都抽成**零 import 的纯 Dart**，这样：
//   · `dart run` 能做**完整类型检查** ✅
//   · 断言脚本能在**本机**跑（不必等 CI）✅
// 📌 同款先例：`book_import_plan.dart` / `reading_section.dart` / `iap_plan.dart`。
//
// ⚠️ 分段策略是**产品行为**（决定「一次读多长」）⇒ 改动须同步断言。

/// 单段字符上限。
///
/// 🔴 取 **3000**（而非平台上限 4000）留 25% 余量，理由：
/// · 平台常量是**上限**，贴着上限没有收益、只有风险
/// · 中文字符在多数引擎里按「字」计，英文按词 —— 混排文本的实际开销更高
/// · 分段发生在 `_cleanText` **之后**（`splitForSpeech(_cleanText(text))`）
///   ⇒ 算长度用的是**清洗后**的文本（标记已去掉 ⇒ 不会「按含标记的长度白切」）。
///   ⚠️ 本行曾写作「在 `_cleanText` **之前**」，与实现**正好相反** ——
///   属「注释 ≠ 实现」的静默失真（2026-10-06 扫尾时改正）。
const int kMaxSpeechChunk = 3000;

/// 可切分的「句末标点」（中英混排）。
///
/// 🔑 用**正向**匹配（而不是后顾 `(?<=…)`）—— 见 [_splitSentences] 的说明。
final RegExp _kSentenceBoundary = RegExp(r'[.!?。！？；;：:]+\s*');

/// 把长文本切成可供 TTS **依次朗读**的段，保证**每段 ≤ [maxLen]**。
///
/// 三级策略（每级只在上一级不够时启用）：
///   ① **按行**为一个单位 —— 最自然，段落之间本来就有停顿
///   ② 单行超长 → **按句末标点**切，并**累积到接近 [maxLen]**（不逐句成段，否则停顿过碎）
///   ③ 单句仍超长（无标点的长串）→ **硬切**
///
/// 🔑 **保证**：
///   · `result.every((s) => s.length <= maxLen)`
///   · **不含空白段**（空段会让 TTS 读一段静默）
///   · 🔴 **去空白后内容守恒**（不丢字、不重复）—— 由断言守着，这是分段最大的风险
List<String> splitForSpeech(String text, {int maxLen = kMaxSpeechChunk}) {
  if (maxLen <= 0) {
    throw ArgumentError.value(maxLen, 'maxLen', '必须为正数');
  }
  final out = <String>[];

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    _emitBlock(line, maxLen, out);
  }

  return out;
}

/// 把单块文本装进 [out]：够短直接放，够长则按句 / 硬切。
void _emitBlock(String block, int maxLen, List<String> out) {
  if (block.length <= maxLen) {
    out.add(block);
    return;
  }

  final buf = StringBuffer();

  void flush() {
    if (buf.isNotEmpty) {
      out.add(buf.toString());
      buf.clear();
    }
  }

  for (final sentence in _splitSentences(block)) {
    final s = sentence.trim();
    if (s.isEmpty) continue;

    if (s.length > maxLen) {
      // ③ 单句就超长（无标点的长串）→ 先冲掉缓冲，再硬切
      flush();
      for (final hard in _hardSplit(s, maxLen)) {
        out.add(hard);
      }
      continue;
    }

    // ② 累积到「再加就超」为止 —— 避免切得过碎（逐句成段会让停顿过多）
    if (buf.length + s.length > maxLen) {
      flush();
    }
    buf.write(s);
  }

  flush();
}

/// 按句末标点切分，**每段保留自己的标点**。
///
/// # 🔴 为什么不用 `String.split(正则)`
///
/// `_kSentenceBoundary` 里的 `\s*` 可以匹配**空串**（标点后紧跟非空白时）——
/// 而 Dart 官方对 `String.split` 的说明是：
/// > *If the pattern can match an empty string, the result is undefined.*
/// 📌 判据：**「未定义行为」不能当作「碰巧能用」** —— 它可能今天对、上游换实现就不对，
///    而且**不报错**（正是本项目最忌讳的失效模式）。
/// ⇒ 改为**手动扫描**：位置与切片范围完全由我们控制，内容守恒因此可证。
List<String> _splitSentences(String s) {
  final out = <String>[];
  var start = 0;
  for (final m in _kSentenceBoundary.allMatches(s)) {
    final end = m.end;
    if (end > start) {
      out.add(s.substring(start, end));
      start = end;
    }
  }
  if (start < s.length) {
    out.add(s.substring(start));
  }
  return out;
}

/// 硬切：按 [maxLen] 定长切开。
///
/// ⚠️ **已知代价（如实记录）**：可能把一个英文单词切成两半。
///    只在「单句超长且无标点」时触发（正常正文极少）——
///    而**不这么做的代价更大**：整段超上限 ⇒ 那一整段根本没声音。
///    📌 取舍原则：**「读得略生硬」优于「完全不读」**。
List<String> _hardSplit(String s, int maxLen) {
  final out = <String>[];
  for (var i = 0; i < s.length; i += maxLen) {
    final end = (i + maxLen < s.length) ? i + maxLen : s.length;
    out.add(s.substring(i, end));
  }
  return out;
}
