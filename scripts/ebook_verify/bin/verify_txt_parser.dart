// 电子书导入 —— TXT 解析器验收（纯 Dart · 零依赖 · 本机可跑）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_txt_parser.dart
// 🔴 退出码：0 = 全过，1 = 有失败（注意用 `; echo $?` 直读，
//    写成 `| tail` 会让 `$?` 取到 tail 的退出码 —— 本项目已踩过）。
//
// # 为什么断言要写这么细
//
// TXT 分章是**启发式**，最容易犯两类错，且都**不会报错**：
//   · 漏判 → 整本被当成一章（滚动体验极差，但「能打开」）
//   · 误判 → 正文里的「第一章讲的是……」被当成章节标题，把书切碎
// ⇒ 所以「**不该切的不能切**」这一类**反向断言**比正向更重要。

import 'dart:convert';
import 'dart:typed_data';

import '../../../app/lib/services/ebook/book_text.dart';
import '../../../app/lib/services/ebook/txt_parser.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail == null ? name : '$name —— $detail');
  }
}

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

/// 取解析结果的章节列表（失败时返回空表，由调用方的断言去发现）。
List<ChapterDraft> chaptersOf(EbookParseResult r) =>
    r is EbookParseSuccess ? r.book.chapters : const [];

EbookParseErrorKind? kindOf(EbookParseResult r) =>
    r is EbookParseFailure ? r.kind : null;

void main() {
  // ══════════════════════════════════════════════════════════════════════
  // ① 编码探测 —— 编错码不会报错，只会整本乱码，所以必须逐种锁住
  // ══════════════════════════════════════════════════════════════════════

  // 无 BOM 的合法 UTF-8
  final d1 = decodeTextBytes(bytesOf('Hello world'));
  check('UTF-8 无 BOM 能解码', d1 != null && d1.text == 'Hello world');
  check('  识别为 utf-8', d1?.encoding == 'utf-8', d1?.encoding);

  // UTF-8 BOM
  final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('Hi')]);
  final d2 = decodeTextBytes(withBom);
  check('UTF-8 BOM 能解码且去掉 BOM', d2 != null && d2.text == 'Hi', d2?.text);
  check('  识别为 utf-8-bom', d2?.encoding == 'utf-8-bom', d2?.encoding);

  // UTF-16 LE BOM（中文）
  final utf16le = <int>[0xFF, 0xFE];
  for (final unit in '中文'.codeUnits) {
    utf16le.addAll([unit & 0xFF, unit >> 8]);
  }
  final d3 = decodeTextBytes(Uint8List.fromList(utf16le));
  check('UTF-16LE BOM 能解出中文', d3 != null && d3.text == '中文', d3?.text);

  // UTF-16 代理对（emoji / 罕见字）—— 漏了会变两个乱码字符
  final emoji = <int>[0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE]; // 😀 U+1F600
  final d4 = decodeTextBytes(Uint8List.fromList(emoji));
  check(
    'UTF-16 代理对合成一个码位（不是两个乱码）',
    d4 != null && d4!.text.runes.length == 1 && d4.text.runes.first == 0x1F600,
    d4 == null ? 'null' : 'runes=${d4.text.runes.map((r) => r.toRadixString(16))}',
  );

  // 🔴 GBK 字节 ⇒ **必须返回 null**（不猜编码）
  //    「中文」的 GBK 编码是 D6 D0 CE C4 —— 它不是合法 UTF-8
  final gbk = Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]);
  check(
    '🔴 GBK 字节 → 返回 null（绝不猜编码）',
    decodeTextBytes(gbk) == null,
    '若这里拿到非 null，说明解码器在「猜」，会导致静默乱码',
  );

  // 并断言 parseTxt 对 GBK 给的是**专门**的失败类别
  final gbkResult = parseTxt(gbk, fileName: 'book.txt');
  check(
    '🔴 GBK → unknownEncoding（不是笼统的 unknown）',
    kindOf(gbkResult) == EbookParseErrorKind.unknownEncoding,
    '${kindOf(gbkResult)}',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ② 分章：正向（该切的要切）
  // ══════════════════════════════════════════════════════════════════════

  // 中文章节
  final zh = '''
第一章 起点

这是第一章的正文。

第二章 转折

这是第二章的正文。

第三章 终局

这是第三章的正文。
''';
  final zhCh = chaptersOf(parseTxt(bytesOf(zh), fileName: 'story.txt'));
  check('中文「第X章」切出 3 章', zhCh.length == 3, '实际 ${zhCh.length}');
  check('  第 1 章标题 = 第一章 起点', zhCh.isNotEmpty && zhCh[0].title == '第一章 起点', zhCh.isNotEmpty ? zhCh[0].title : '空');
  check('  第 2 章标题正确', zhCh.length > 1 && zhCh[1].title == '第二章 转折');

  // 全角数字
  final fullWidth = '第１章 A\n\nx\n\n第２章 B\n\ny';
  check(
    '全角数字「第１章」也能识别',
    chaptersOf(parseTxt(bytesOf(fullWidth))).length == 2,
  );

  // 英文章节
  final en = '''
Chapter 1

First body.

Chapter 2

Second body.

Chapter 3

Third body.
''';
  final enCh = chaptersOf(parseTxt(bytesOf(en), fileName: 'book.txt'));
  check('英文「Chapter N」切出 3 章', enCh.length == 3, '实际 ${enCh.length}');

  // 罗马数字章
  final roman = 'CHAPTER I\n\na\n\nCHAPTER II\n\nb';
  check('罗马数字 CHAPTER II 能识别', chaptersOf(parseTxt(bytesOf(roman))).length == 2);

  // 纯数字行
  final numbers = '1\n\naaa\n\n2\n\nbbb\n\n3\n\nccc';
  check('纯数字行「1/2/3」能识别', chaptersOf(parseTxt(bytesOf(numbers))).length == 3);

  // PROLOGUE / EPILOGUE
  final prologue = 'PROLOGUE\n\naaa\n\nChapter 1\n\nbbb';
  check('PROLOGUE 与 Chapter 混用能识别', chaptersOf(parseTxt(bytesOf(prologue))).length == 2);

  // 第一个标题**之前**的内容要保留（序言/版权页）
  final withHead = '版权页信息\n\n第一章 A\n\n正文a\n\n第二章 B\n\n正文b';
  final headCh = chaptersOf(parseTxt(bytesOf(withHead)));
  check('第一个标题前的内容保留为独立章', headCh.length == 3, '实际 ${headCh.length}');
  check('  该章 title 为 null（它不是标题行）', headCh.isNotEmpty && headCh[0].title == null);

  // ══════════════════════════════════════════════════════════════════════
  // ③ 分章：🔴 反向（不该切的不能切）—— 这一类最容易漏
  // ══════════════════════════════════════════════════════════════════════

  // 正文句子里的「第一章」**不应**被当标题（有长度/整行约束）
  final trap = '''
第一章 开始

正文正文。

第一章讲的是主角小时候的故事，这段话说得非常长，所以它只是一句正文而不是标题。

第二章 继续

更多正文。
''';
  final trapCh = chaptersOf(parseTxt(bytesOf(trap)));
  check(
    '🔴 正文里的「第一章讲的是……」不被当标题',
    trapCh.length == 2,
    '实际切出 ${trapCh.length} 章 —— 说明标题规则误判了正文',
  );

  // 长行（超过 60 字）绝不可能是标题
  //
  // 🔴 断言写法注意：**不能写成 `isEmpty || first.title == null`** ——
  //    `||` 会让「解析失败（章节为空）」也算通过，那是**假绿**。
  //    ⇒ 必须**先断言解析成功**，再断言里面的 title 都是 null。
  final longLine = '第1章 ${'x' * 80}\n\naaa\n\n第2章 ${'y' * 80}\n\nbbb';
  final longLineCh = chaptersOf(parseTxt(bytesOf(longLine), fileName: 'l.txt'));
  check(
    '预置：长行样本仍能成书（否则下面的断言无意义）',
    longLineCh.isNotEmpty,
    '解析出 0 章 —— 说明样本本身有问题，不是「长度约束生效」',
  );
  check(
    '🔴 超长行（>60 字）不被当标题',
    longLineCh.isNotEmpty && longLineCh.every((c) => c.title == null),
    '拿到 title：${longLineCh.map((c) => c.title).where((t) => t != null).toList()}',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ④ 兜底切分：无章节标记
  // ══════════════════════════════════════════════════════════════════════

  // 短文本无标记 ⇒ 走兜底，仍应产出**至少 1 章**（不能被判空）
  final noMark = 'Just a plain paragraph.\n\nAnother paragraph.';
  final noMarkCh = chaptersOf(parseTxt(bytesOf(noMark), fileName: 'plain.txt'));
  check('无章节标记也能成书（不判失败）', noMarkCh.isNotEmpty, '实际 ${noMarkCh.length}');

  // 长文本无标记 ⇒ 按 ~kTxtFallbackChapterChars 切多章
  final para = '${'word ' * 400}\n\n'; // 每段约 2000 字符
  final longText = para * 12; // 约 24000 字符 ⇒ 应切出 >= 3 章
  final longCh = chaptersOf(parseTxt(bytesOf(longText), fileName: 'long.txt'));
  check(
    '长文本无标记 → 按长度切成多章（>=3）',
    longCh.length >= 3,
    '实际 ${longCh.length} 章',
  );
  check(
    '  每章不超过 2 倍目标长度（防止切分失效）',
    longCh.every((c) => c.charCount <= kTxtFallbackChapterChars * 2),
    '存在超长章',
  );

  // 只有一个标题行 ⇒ 应走兜底（而不是「1 章 + 后面全归它」）
  final oneTitle = '第一章 唯一\n\n${'content ' * 2000}';
  final oneCh = chaptersOf(parseTxt(bytesOf(oneTitle)));
  check(
    '仅 1 个标题 → 走兜底切分（产出多章）',
    oneCh.length >= 2,
    '实际 ${oneCh.length}',
  );

  // 极端长单段（无空行）⇒ 必须硬切，不能吐出一章超长
  final oneHugePara = 'x' * (kTxtFallbackChapterChars * 3);
  final hugeCh = chaptersOf(parseTxt(bytesOf(oneHugePara), fileName: 'huge.txt'));
  check(
    '🔴 单个超长段落被硬切（不产出一章 24000 字符）',
    hugeCh.length >= 3 && hugeCh.every((c) => c.charCount <= kTxtFallbackChapterChars),
    '实际 ${hugeCh.length} 章，最长 ${hugeCh.isEmpty ? 0 : hugeCh.map((c) => c.charCount).reduce((a, b) => a > b ? a : b)}',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ⑤ 边界与失败路径
  // ══════════════════════════════════════════════════════════════════════

  check('空字节 → empty', kindOf(parseTxt(Uint8List(0))) == EbookParseErrorKind.empty);
  check(
    '全空白 → empty（不能产出空章节）',
    kindOf(parseTxt(bytesOf('   \n\n  \t '))) == EbookParseErrorKind.empty,
  );

  final tooBig = Uint8List(kMaxEbookBytes + 1);
  check(
    '超上限 → tooLarge',
    kindOf(parseTxt(tooBig)) == EbookParseErrorKind.tooLarge,
  );

  // 书名：去扩展名；没有文件名时**不编造**
  final named = parseTxt(bytesOf('第一章 A\n\nx\n\n第二章 B\n\ny'), fileName: 'Pride and Prejudice.epub.txt');
  check(
    '书名取文件名（去掉最后一个扩展名）',
    named is EbookParseSuccess && named.book.title == 'Pride and Prejudice.epub',
    named is EbookParseSuccess ? named.book.title : '解析失败',
  );
  final unnamed = parseTxt(bytesOf('第一章 A\n\nx\n\n第二章 B\n\ny'));
  check(
    '无文件名 → 「未命名」（不编造书名）',
    unnamed is EbookParseSuccess && unnamed.book.title == '未命名',
  );

  // 语言推测：纯英文 ⇒ en；中文 ⇒ null（**宁可 null 也不误标**）
  final enBook = parseTxt(bytesOf('Chapter 1\n\nenglish text here\n\nChapter 2\n\nmore text'), fileName: 'a.txt');
  check(
    '英文内容 → language = en',
    enBook is EbookParseSuccess && enBook.book.language == 'en',
    enBook is EbookParseSuccess ? '${enBook.book.language}' : '失败',
  );
  final zhBook = parseTxt(bytesOf('第一章 开始\n\n这是中文正文内容\n\n第二章 结束\n\n更多中文'), fileName: 'b.txt');
  check(
    '中文内容 → language = null（不误标成 en）',
    zhBook is EbookParseSuccess && zhBook.book.language == null,
    zhBook is EbookParseSuccess ? '${zhBook.book.language}' : '失败',
  );

  // sourceFormat 与 book.source_format 的 CHECK 约束一致
  final fmt = parseTxt(bytesOf('Chapter 1\n\na\n\nChapter 2\n\nb'));
  check(
    "sourceFormat = 'txt'（与 DB CHECK 约束一致）",
    fmt is EbookParseSuccess && fmt.book.sourceFormat == 'txt',
  );

  // charCount 应等于各章之和（落库字段的语义）
  final counting = parseTxt(bytesOf('Chapter 1\n\nabcde\n\nChapter 2\n\nfghij'));
  if (counting is EbookParseSuccess) {
    final sum = counting.book.chapters.fold(0, (a, c) => a + c.charCount);
    check('charCount = 各章字符数之和', counting.book.charCount == sum, '${counting.book.charCount} vs $sum');
  } else {
    check('charCount = 各章字符数之和', false, '解析失败');
  }

  _report();
}

void _report() {
  final total = _pass + _fail;
  if (_failures.isNotEmpty) {
    print('\n🔴 失败 ${_failures.length} 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('\n通过 $_pass / $total');
  if (_fail == 0) {
    print('✅ 全部通过');
  }
  // 🔴 显式退出码（`dart run` 默认不因 print 而改变退出码）
  if (_fail > 0) {
    throw StateError('电子书 TXT 解析验收失败 $_fail 项');
  }
}
