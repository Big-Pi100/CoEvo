// TXT 电子书解析
//
// 🔴 **本文件只 import `dart:convert` / `dart:typed_data`**（都是标准库，非 Flutter）
//   ⇒ 可用 `dart run` 在本机跑真断言。
//
// # 三件事，按顺序
//   ① **编码探测** —— 编错码 = 整本书乱码，而且**不会报错**（最隐蔽的失败）
//   ② **分章**     —— 识别「第X章 / Chapter N」等常见标记
//   ③ **兜底切分** —— 没有章节标记时按段落边界等分（否则一整本一章，滚动体验极差）

import 'dart:convert';
import 'dart:typed_data';

import 'book_text.dart';

/// TXT 章节标题的识别规则。
///
/// ⚠️ **只匹配「整行就是个标题」**（`matchEntire` + 长度上限）——
///    否则「第一章讲的是……」这种正文句子会被误当标题，把书切得支离破碎。
///
/// 📌 这套规则注定是**启发式**（TXT 没有标准）⇒ 宁可漏判（退化成按字数切分），
///    不可误判（把正文切开）。所以每条都加了长度与「整行」约束。
final List<RegExp> _chapterTitlePatterns = [
  // 中文章节：第X章 / 第X节 / 第X回 / 第X卷 / 第X篇 / 第X部
  // 数字支持阿拉伯、全角、中文数字
  RegExp(
    r'^第\s*[0-9０-９一二三四五六七八九十百千零〇两]+\s*[章节回卷篇部]\s*.{0,30}$',
  ),
  // 英文：Chapter 1 / CHAPTER IV
  RegExp(r'^(Chapter|CHAPTER|chapter)\s+([0-9]+|[IVXLCDM]+)\b.{0,40}$'),
  // 常见英文分节词（同样要求整行短）
  RegExp(r'^(PART|Part|BOOK|Book|PROLOGUE|EPILOGUE|Prologue|Epilogue)\b.{0,40}$'),
  // 纯数字行（如「1」「12」独占一行）—— ⚠️ 限制 1~4 位，避免把正文里的数字切成标题
  RegExp(r'^\s*\d{1,4}\s*$'),
];

/// 一个候选标题行的最大长度。超过即认为是正文（防误判）。
const int _kMaxTitleLineChars = 60;

/// 解析 TXT。
///
/// [bytes] 原始字节。**由调用方读文件** —— 本层不碰 `dart:io`，
/// 这样验证脚本可以直接喂字节数组，不必造临时文件。
///
/// [fileName] 用于推导书名（去扩展名）。为 null 时书名取 `未知书名`。
EbookParseResult parseTxt(Uint8List bytes, {String? fileName}) {
  if (bytes.isEmpty) {
    return const EbookParseFailure(EbookParseErrorKind.empty, '空文件（0 字节）');
  }
  if (bytes.length > kMaxEbookBytes) {
    return EbookParseFailure(
      EbookParseErrorKind.tooLarge,
      '体积 ${bytes.length} 字节 > 上限 $kMaxEbookBytes',
    );
  }

  final decoded = decodeTextBytes(bytes);
  if (decoded == null) {
    // 🔴 **不猜编码** —— 猜错就是整本乱码且无任何错误提示。
    //    ⇒ 明确失败，让用户自己转成 UTF-8（比静默乱码好得多）。
    return const EbookParseFailure(
      EbookParseErrorKind.unknownEncoding,
      '不是合法 UTF-8，且无 UTF-8/UTF-16 BOM ⇒ 可能是 GBK/GB18030 等编码',
    );
  }

  final text = decoded.text;
  if (text.trim().isEmpty) {
    return const EbookParseFailure(EbookParseErrorKind.empty, '解码后无任何正文');
  }

  final chapters = splitIntoChapters(text);
  if (chapters.isEmpty) {
    return const EbookParseFailure(EbookParseErrorKind.empty, '分章后无内容');
  }
  if (chapters.length > kMaxEbookChapters) {
    return EbookParseFailure(
      EbookParseErrorKind.tooLarge,
      '章节数 ${chapters.length} > 上限 $kMaxEbookChapters（多半是章节规则误判）',
    );
  }

  return EbookParseSuccess(
    BookDraft(
      title: _titleFromFileName(fileName),
      author: null, // TXT 没有元数据 —— 不编造
      language: decoded.looksLikeAsciiEnglish ? 'en' : null,
      sourceFormat: 'txt',
      chapters: chapters,
    ),
  );
}

/// 编码探测的结果。
class DecodedText {
  const DecodedText(this.text, {required this.encoding});

  final String text;

  /// 实际采用的编码（写日志用）。
  final String encoding;

  /// 内容是否「基本是 ASCII」——用于**推测语言**（TXT 没有元数据）。
  ///
  /// 🔑 判据故意宽松：只要非 ASCII 字符占比 < 1% 就算英文。
  ///    宁可推断不出语言（null），也不要把中文书标成英文。
  bool get looksLikeAsciiEnglish {
    if (text.isEmpty) return false;
    var nonAscii = 0;
    for (final r in text.runes) {
      if (r > 0x7F) nonAscii++;
    }
    return nonAscii / text.runes.length < 0.01;
  }
}

/// 字节 → 文本。**返回 null 表示无法确定编码**（不猜）。
///
/// 顺序（每一步都是**确定性**判断，不含猜测）：
///   ① BOM 优先 —— 有 BOM 就是明示，最可靠
///   ② 无 BOM ⇒ 试 **UTF-8 严格解码**（`allowMalformed: false`）
///      能解出来（不抛异常）就是合法 UTF-8 —— 这是**可判定的**，不是猜
///   ③ 失败 ⇒ 返回 null（当前不支持 GBK，见下方 TODO）
DecodedText? decodeTextBytes(Uint8List bytes) {
  // ① BOM
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return DecodedText(
      utf8.decode(bytes.sublist(3), allowMalformed: true),
      encoding: 'utf-8-bom',
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return DecodedText(
      _decodeUtf16(bytes.sublist(2), littleEndian: true),
      encoding: 'utf-16le',
    );
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return DecodedText(
      _decodeUtf16(bytes.sublist(2), littleEndian: false),
      encoding: 'utf-16be',
    );
  }

  // ② 无 BOM ⇒ UTF-8 严格校验（**可判定**，非猜测）
  try {
    return DecodedText(
      const Utf8Decoder(allowMalformed: false).convert(bytes),
      encoding: 'utf-8',
    );
  } on FormatException {
    // 落到 ③
  }

  // ③ ⏳ 非 UTF-8（多半是 GBK / GB18030）。
  //    🔴 **刻意不猜** —— 编错码的后果是「整本乱码且无任何报错」，
  //       比明确失败严重得多（用户会以为 App 坏了）。
  //    📌 待办：接一个 GBK 解码包（纯 Dart）后在此处补上，
  //       届时**仍以「严格校验失败」为前提**，不要退化成乱猜。
  return null;
}

/// 手工解码 UTF-16（`dart:convert` 不带 UTF-16 解码器）。
///
/// ⚠️ 代理对（surrogate pair）按 UTF-16 标准处理：
///   高位 0xD800–0xDBFF + 低位 0xDC00–0xDFFF ⇒ 合成为一个码位。
///   漏掉这一步会让 emoji / 罕见汉字变成两个乱码字符。
String _decodeUtf16(Uint8List b, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }

  final out = StringBuffer();
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF && i + 1 < units.length) {
      final lo = units[i + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        out.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00));
        i++; // 吃掉低位
        continue;
      }
    }
    out.writeCharCode(u);
  }
  return out.toString();
}

/// 书名：文件名去扩展名。没有文件名时给一个中性值（**不编造书名**）。
String _titleFromFileName(String? fileName) {
  if (fileName == null || fileName.trim().isEmpty) return '未命名';
  final base = fileName.replaceAll(r'\', '/').split('/').last;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  final trimmed = stem.trim();
  return trimmed.isEmpty ? '未命名' : trimmed;
}

/// 把整篇文本切成章节。
///
/// 有章节标记 ⇒ 按标记切；没有 ⇒ 按 [kTxtFallbackChapterChars] 在**段落边界**等分。
List<ChapterDraft> splitIntoChapters(String text) {
  final lines = const LineSplitter().convert(text);

  // ① 先找所有「标题行」的行号
  final titleAt = <int, String>{};
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.length > _kMaxTitleLineChars) continue;
    if (_isChapterTitle(line)) titleAt[i] = line;
  }

  // ② 没有标题（或只有一个开头标题）⇒ 退化为按长度切分
  //
  //    🔑 阈值判断为什么用「>= 2」：只有一个标题行时，切出来的结构与
  //       「无标题按长度切」几乎一样，但会丢掉后面所有内容的分段 —— 不如直接走兜底。
  if (titleAt.length < 2) {
    return _splitByLength(text);
  }

  // ③ 按标题切
  final chapters = <ChapterDraft>[];
  final indices = titleAt.keys.toList()..sort();

  // 第一个标题**之前**的内容（序言/版权页）
  if (indices.first > 0) {
    final head = lines.sublist(0, indices.first).join('\n').trim();
    if (head.isNotEmpty) {
      chapters.add(ChapterDraft(title: null, text: head));
    }
  }

  for (var k = 0; k < indices.length; k++) {
    final start = indices[k];
    final end = k + 1 < indices.length ? indices[k + 1] : lines.length;
    final body = lines.sublist(start, end).join('\n').trim();
    if (body.isNotEmpty) {
      chapters.add(ChapterDraft(title: titleAt[start], text: body));
    }
  }

  return chapters;
}

bool _isChapterTitle(String line) =>
    _chapterTitlePatterns.any((re) => re.hasMatch(line));

/// 「无章节标记」时的兜底切分：按字符数等分，**尽量落在段落边界**。
///
/// 段落 = 空行分隔的块。若单个段落就超过目标长度（极端长段），才硬切。
List<ChapterDraft> _splitByLength(String text) {
  final paragraphs = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  final chapters = <ChapterDraft>[];
  final buf = StringBuffer();

  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) {
      chapters.add(ChapterDraft(title: null, text: s));
    }
    buf.clear();
  }

  for (final p in paragraphs) {
    // 单个段落就超长 ⇒ 先交出已攒的，再硬切这一段
    if (p.length > kTxtFallbackChapterChars) {
      flush();
      for (var i = 0; i < p.length; i += kTxtFallbackChapterChars) {
        final end = (i + kTxtFallbackChapterChars).clamp(0, p.length);
        chapters.add(
          ChapterDraft(title: null, text: p.substring(i, end)),
        );
      }
      continue;
    }

    if (buf.length + p.length > kTxtFallbackChapterChars) {
      flush();
    }
    if (buf.isNotEmpty) buf.write('\n\n');
    buf.write(p);
  }
  flush();

  return chapters;
}
