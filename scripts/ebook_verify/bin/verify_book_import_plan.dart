// 电子书导入 —— 落库计划验收（纯 Dart · 零依赖 · 本机可跑 · 可进 CI）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_book_import_plan.dart
// 🔴 退出码：0 = 全过，1 = 有失败（注意用 `; echo $?` 直读，
//    写成 `| tail` 会让 `$?` 取到 tail 的退出码 —— 本项目已踩过）。
//
// # 为什么这几条值得断言
//
// 落库映射里三类错**都不会报错**，只会让用户看到错的东西：
//   · `idx` 断号     → 阅读页「下一章」跳到空白
//   · 计数不一致     → 书库列表显示「共 N 章」是**假数据**
//   · 章节顺序错     → 书读起来是乱的（而每章内容都对 ⇒ 极难察觉）
// ⇒ 前两条是机器的活（算得出来），第三条只能靠「与输入逐项比对」。

import 'dart:typed_data';

import '../../../app/lib/services/ebook/book_import_plan.dart';
import '../../../app/lib/services/ebook/book_text.dart';

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

Uint8List bytesOf(List<int> b) => Uint8List.fromList(b);

/// zip 文件头（`PK\x03\x04`）。
final zipBytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);

/// 普通文本字节（非 zip）。
final textBytes = Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F]);

/// 造一个确定性 id 生成器（`id-1`, `id-2`, …）—— 便于逐字段比对。
String Function() seqIds() {
  var n = 0;
  return () => 'id-${++n}';
}

void main() {
  // ══════════════════════════════════════════════════════════════════════
  // ① `fileExtension` —— 六个边界里有一半是「不该当成扩展名」
  // ══════════════════════════════════════════════════════════════════════
  check('普通扩展名', fileExtension('foo.epub') == 'epub', fileExtension('foo.epub'));
  check('大写转小写', fileExtension('foo.EPUB') == 'epub', fileExtension('foo.EPUB'));
  check('正斜杠路径只取文件名', fileExtension('a/b/foo.txt') == 'txt',
      fileExtension('a/b/foo.txt'));
  // 🔑 用户从 Windows 拷文件过来，路径可能是反斜杠形态
  check('反斜杠路径只取文件名', fileExtension(r'a\b\foo.txt') == 'txt',
      fileExtension(r'a\b\foo.txt'));
  check('无扩展名 → 空串', fileExtension('foo') == '', '「${fileExtension('foo')}」');
  // 🔴 反向：隐藏文件**没有**扩展名（`.gitignore` 不是「扩展名为 gitignore 的文件」）
  check('🔴 隐藏文件不算扩展名', fileExtension('.gitignore') == '',
      '「${fileExtension('.gitignore')}」');
  // 多点：只取最后一段
  check('多点只取最后一段', fileExtension('a.tar.gz') == 'gz',
      fileExtension('a.tar.gz'));
  // 🔴 点在**目录名**里，不在文件名里
  check('🔴 点在后缀目录里不算', fileExtension('a.b/c') == '',
      '「${fileExtension('a.b/c')}」');
  check('空串 → 空串', fileExtension('') == '', '「${fileExtension('')}」');

  // ══════════════════════════════════════════════════════════════════════
  // ② `pickFormat` —— 🔴 核心是**魔数 > 扩展名**这条优先级
  // ══════════════════════════════════════════════════════════════════════
  check('zip 魔数（无扩展名）→ epub',
      pickFormat(fileName: 'book', bytes: zipBytes) == EbookFormat.epub);
  // 🔴 用户把 epub 改名成 .txt —— 魔数必须赢，否则会拿 TXT 解析器去啃 zip
  check('🔴 zip 魔数 + .txt 扩展名 → 仍判 epub（魔数赢）',
      pickFormat(fileName: 'book.txt', bytes: zipBytes) == EbookFormat.epub);
  // 🔴 反向：叫 .epub 但不是 zip ⇒ **仍按 epub 解析**，好让解析器报「这不是有效的 EPUB」
  //    （要是改判 txt，用户会看到一本乱码书 —— 比报错更糟）
  check('🔴 非 zip + .epub → 仍判 epub（交给解析器报明确错）',
      pickFormat(fileName: 'book.epub', bytes: textBytes) == EbookFormat.epub);
  check('非 zip + .txt → txt',
      pickFormat(fileName: 'book.txt', bytes: textBytes) == EbookFormat.txt);
  // 🔑 兜底选 txt 而不是拒绝：TXT 解析器有编码探测，能兜住更多真实输入
  check('非 zip + 无扩展名 → txt（兜底，不拒收）',
      pickFormat(fileName: 'book', bytes: textBytes) == EbookFormat.txt);
  check('非 zip + 未知扩展名 → txt（兜底）',
      pickFormat(fileName: 'book.dat', bytes: textBytes) == EbookFormat.txt);
  check('字节数不足 2 时不会越界', 
      pickFormat(fileName: 'x', bytes: bytesOf([0x50])) == EbookFormat.txt);

  // ══════════════════════════════════════════════════════════════════════
  // ③ `buildImportPlan` —— 三条一致性保证
  // ══════════════════════════════════════════════════════════════════════
  final draft = BookDraft(
    title: 'Pride and Prejudice',
    author: 'Jane Austen',
    language: 'en',
    sourceFormat: 'epub',
    chapters: const [
      ChapterDraft(title: 'Chapter 1', text: 'aaa'),
      ChapterDraft(title: 'Chapter 2', text: 'bbbbb'),
      ChapterDraft(title: null, text: 'c'),
    ],
  );

  final plan = buildImportPlan(
    draft: draft,
    fileName: 'pride.epub',
    addedAt: '2026-10-04T00:00:00Z',
    newId: seqIds(),
    // 🆕 v2：内容指纹**由调用方传入**（算它需要原始字节，而本函数是纯逻辑）
    contentHash: 'e3b0c44298fc1c149afbf4c8996fb924',
  );

  // 🆕 指纹必须**原样透传** —— 它是跨设备识别「同一本书」的唯一依据；
  //    若在这里被截断/改写，另一台设备就**永远匹配不上** ⇒ 进度认领失败（静默）。
  check('🆕 contentHash 原样透传（不被截断/改写）',
      plan.contentHash == 'e3b0c44298fc1c149afbf4c8996fb924',
      '「${plan.contentHash}」');

  // ① `idx` 必须**连续 0..n-1**（不是「看起来连续」）
  check('🔴 章节 idx 连续 0..n-1',
      plan.chapters.map((c) => c.idx).join(',') == '0,1,2',
      plan.chapters.map((c) => c.idx).join(','));

  // ② 计数一致性 —— 这两个值会被书库列表显示，不一致就是假数据
  check('🔴 chapterCount == 章节数',
      plan.chapterCount == 3 && plan.chapterCount == plan.chapters.length,
      '${plan.chapterCount} vs ${plan.chapters.length}');
  check('🔴 charCount == 各章 charCount 之和',
      plan.charCount == 9, '${plan.charCount}（3+5+1=9）');

  // ③ 每章 charCount 由 text 现算（不由调用方传 ⇒ 消掉对不上的可能）
  check('每章 charCount 与 text 长度一致',
      plan.chapters.every((c) => c.charCount == c.text.length));

  // 章节顺序必须与输入**逐项相同**（顺序错了书就是乱的，而每章内容都对）
  check('🔴 章节顺序与输入逐项相同',
      plan.chapters.map((c) => c.text).join('|') == 'aaa|bbbbb|c',
      plan.chapters.map((c) => c.text).join('|'));
  // `null` 标题要原样保留为 null（不是空串 —— TXT 无章节时 UI 据此不显示章节名）
  check('null 章节标题保持 null', plan.chapters[2].title == null);

  // 字段透传
  check('标题透传', plan.title == 'Pride and Prejudice');
  check('作者透传', plan.author == 'Jane Austen');
  check('语言透传', plan.language == 'en');
  check('sourceFormat 与 CHECK 约束值一致（epub/txt）',
      plan.sourceFormat == 'epub' && EbookFormat.epub.name == 'epub');
  check('sourceName 落文件名', plan.sourceName == 'pride.epub');
  check('addedAt 原样落库（注入值）', plan.addedAt == '2026-10-04T00:00:00Z');

  // id 来自注入（每次调用都取新值 ⇒ 书 id 与各章 id 互不相同）
  final ids = <String>[plan.bookId, ...plan.chapters.map((c) => c.id)];
  check('🔴 书 id 与各章 id 互不相同（同一生成器连续取值）',
      ids.toSet().length == ids.length, ids.join(','));

  // ── 边界：空章节列表 ──
  final emptyDraft = BookDraft(
    title: 'Empty',
    author: null,
    language: null,
    sourceFormat: 'txt',
    chapters: const [],
  );
  final emptyPlan = buildImportPlan(
    draft: emptyDraft,
    fileName: '  ',
    addedAt: '2026-10-04T00:00:00Z',
    newId: seqIds(),
    contentHash: 'h-empty',
  );
  check('空章节 → chapterCount 0 且不崩', emptyPlan.chapterCount == 0);
  check('空章节 → charCount 0', emptyPlan.charCount == 0);
  // 🔴 全空白文件名 ⇒ 落 null（不是落一个空串 —— 列表里会显示成空白行）
  check('🔴 全空白文件名落 null', emptyPlan.sourceName == null,
      '「${emptyPlan.sourceName}」');
  check('无作者时 author 为 null', emptyPlan.author == null);

  // ── 边界：文件名前后空白被 trim ──
  final trimPlan = buildImportPlan(
    draft: emptyDraft,
    fileName: '  my book.epub  ',
    addedAt: '2026-10-04T00:00:00Z',
    newId: seqIds(),
    contentHash: 'h-trim',
  );
  check('文件名前后空白被 trim', trimPlan.sourceName == 'my book.epub',
      '「${trimPlan.sourceName}」');

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
    throw StateError('电子书落库计划验收失败 $_fail 项');
  }
}
