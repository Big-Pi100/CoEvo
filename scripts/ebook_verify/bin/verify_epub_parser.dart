// 电子书导入 —— EPUB 解析器验收（纯 Dart · 本机可跑）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_epub_parser.dart
//
// # 为什么样本是**自己造**的
//
// 真 EPUB 样本无法进 git（版权 + 体积），而真机验证要等出包。
// ⇒ 用 `archive` 的 `ZipEncoder` **现场造一个 EPUB zip**：
//    · 断言自包含、可复现、能在 CI 跑
//    · 且能精确构造**真实世界的畸形情况**（缺 OPF / 带命名空间前缀 / spine 与文件名顺序不一致）
//      —— 这些用真书很难凑齐
//
// ⚠️ 边界（如实说明）：自造样本覆盖不了「真实 EPUB 的排版复杂度」。
//    真机验证时仍需 3~5 本真书（建议：Project Gutenberg 的无 DRM 公版书）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../app/lib/services/ebook/book_text.dart';
import '../../../app/lib/services/ebook/epub_parser.dart';

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

/// 用给定文件清单造一个 EPUB（zip）字节流。
Uint8List buildZip(Map<String, String> entries) {
  final ar = Archive();
  entries.forEach((path, content) {
    ar.add(ArchiveFile.string(path, content));
  });
  return ZipEncoder().encodeBytes(ar);
}

/// 造一份**标准三段式** EPUB 的文件清单。
///
/// [spineOrder] 与 [manifestHrefs] 刻意分开传 —— 好构造「spine 顺序 ≠ 文件名顺序」。
Map<String, String> epubEntries({
  required List<String> spineOrder, // manifest id 顺序（= 阅读顺序）
  required Map<String, String> manifestHrefs, // id → href
  required Map<String, String> chapterContents, // href → xhtml
  String? extraManifestItems,
  String title = '测试书名',
  String creator = '测试作者',
  String language = 'en',
  String opfPath = 'OEBPS/content.opf',
  String? containerOverride,
  bool withDrm = false,
}) {
  final entries = <String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': containerOverride ??
        '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
  };

  if (withDrm) {
    entries['META-INF/encryption.xml'] =
        '<?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData/></encryption>';
  }

  final manifestItems = manifestHrefs.entries
      .map((e) =>
          '<item id="${e.key}" href="${e.value}" media-type="application/xhtml+xml"/>')
      .join('\n    ');

  final spineRefs =
      spineOrder.map((id) => '<itemref idref="$id"/>').join('\n    ');

  final opfDir = opfPath.contains('/')
      ? opfPath.substring(0, opfPath.lastIndexOf('/'))
      : '';

  entries[opfPath] = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$creator</dc:creator>
    <dc:language>$language</dc:language>
  </metadata>
  <manifest>
    $manifestItems
    ${extraManifestItems ?? ''}
  </manifest>
  <spine>
    $spineRefs
  </spine>
</package>''';

  // 正文文件（路径相对 OPF 目录）
  chapterContents.forEach((href, xhtml) {
    final full = opfDir.isEmpty ? href : '$opfDir/$href';
    entries[full] = xhtml;
  });

  return entries;
}

String xhtml(String h1, String body) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>$h1</title></head>
<body><h1>$h1</h1>$body</body>
</html>''';

void main() {
  const opf = 'OEBPS/content.opf';

  // ══════════════════════════════════════════════════════════════════════
  // ① 正常解析
  // ══════════════════════════════════════════════════════════════════════

  final normal = parseEpub(
    buildZip(epubEntries(
      spineOrder: ['c1', 'c2'],
      manifestHrefs: {'c1': 'text/ch1.xhtml', 'c2': 'text/ch2.xhtml'},
      chapterContents: {
        'text/ch1.xhtml': xhtml('第一章', '<p>Hello A.</p><p>Hello B.</p>'),
        'text/ch2.xhtml': xhtml('第二章', '<p>World C.</p>'),
      },
    )),
    fileName: 'book.epub',
  );

  check('正常 EPUB 解析成功', normal is EbookParseSuccess, '$normal');
  if (normal is EbookParseSuccess) {
    final b = normal.book;
    check('  书名取 OPF 的 dc:title（不是文件名）', b.title == '测试书名', b.title);
    check('  作者取 dc:creator', b.author == '测试作者', '${b.author}');
    check('  语言取 dc:language', b.language == 'en', '${b.language}');
    check("  sourceFormat = 'epub'", b.sourceFormat == 'epub', b.sourceFormat);
    check('  章节数 = 2', b.chapters.length == 2, '${b.chapters.length}');
    check('  章标题取 <h1>', b.chapters.isNotEmpty && b.chapters[0].title == '第一章',
        b.chapters.isNotEmpty ? '${b.chapters[0].title}' : '空');
    check(
      '  正文含两段且已分行',
      b.chapters.isNotEmpty && b.chapters[0].text.contains('Hello A.') &&
          b.chapters[0].text.contains('Hello B.') &&
          b.chapters[0].text.contains('\n'),
      b.chapters.isNotEmpty ? b.chapters[0].text : '',
    );
    check(
      '  正文不含 HTML 标签（已剥离）',
      b.chapters.every((c) => !c.text.contains('<')),
      '仍有 <',
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // ② 🔴 章节顺序必须按 spine（本项目最容易写错的一点）
  // ══════════════════════════════════════════════════════════════════════

  // spine 顺序: 1 → 10 → 2
  // 文件名顺序: ch1, ch10, ch2  ← 若代码按 href 排序，结果会变成 1,10,2 之外的顺序
  final spineTest = parseEpub(
    buildZip(epubEntries(
      spineOrder: ['c1', 'c10', 'c2'],
      manifestHrefs: {
        'c1': 'text/ch1.xhtml',
        'c10': 'text/ch10.xhtml',
        'c2': 'text/ch2.xhtml',
      },
      chapterContents: {
        'text/ch1.xhtml': xhtml('AAA', '<p>body of one</p>'),
        'text/ch10.xhtml': xhtml('BBB', '<p>body of ten</p>'),
        'text/ch2.xhtml': xhtml('CCC', '<p>body of two</p>'),
      },
    )),
  );

  if (spineTest is EbookParseSuccess) {
    final titles = spineTest.book.chapters.map((c) => c.title).toList();
    check(
      '🔴 章节顺序按 spine（1→10→2），不是文件名排序',
      titles.length == 3 && titles[0] == 'AAA' && titles[1] == 'BBB' && titles[2] == 'CCC',
      '实际顺序：$titles',
    );
  } else {
    check('🔴 章节顺序按 spine（1→10→2）', false, '解析失败：$spineTest');
  }

  // ══════════════════════════════════════════════════════════════════════
  // ③ 路径解析（相对 OPF 目录 + `../`）
  // ══════════════════════════════════════════════════════════════════════

  // OPF 在 OEBPS/，正文用 ../ 回到根再进 text/
  final dotdot = parseEpub(
    buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '<?xml version="1.0"?><container version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
      'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="b">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
  <manifest><item id="c1" href="../text/ch1.xhtml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>''',
      // ../text/ch1.xhtml 相对 OEBPS/ ⇒ 归一化后 = text/ch1.xhtml
      'text/ch1.xhtml': xhtml('DOTDOT', '<p>resolved</p>'),
    }),
  );
  check(
    '🔴 `../` 路径能正确归一化',
    dotdot is EbookParseSuccess &&
        dotdot.book.chapters.isNotEmpty &&
        dotdot.book.chapters[0].text.contains('resolved'),
    '$dotdot',
  );

  // href 带 fragment
  final withFragment = parseEpub(
    buildZip(epubEntries(
      spineOrder: ['c1'],
      manifestHrefs: {'c1': 'text/ch1.xhtml#s2'},
      chapterContents: {'text/ch1.xhtml': xhtml('FRAG', '<p>fragment ok</p>')},
    )),
  );
  check(
    'href 带 `#fragment` 能解析（去掉 fragment 后取文件）',
    withFragment is EbookParseSuccess &&
        withFragment.book.chapters.isNotEmpty &&
        withFragment.book.chapters[0].text.contains('fragment ok'),
    '$withFragment',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ④ 命名空间前缀（真实世界里存在 `opf:itemref`）
  // ══════════════════════════════════════════════════════════════════════

  final prefixed = parseEpub(
    buildZip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '<?xml version="1.0"?><c:container xmlns:c="urn:x" version="1.0"><c:rootfiles><c:rootfile full-path="OEBPS/content.opf"/></c:rootfiles></c:container>',
      'OEBPS/content.opf': '''<?xml version="1.0"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="b">
  <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Prefixed</dc:title></opf:metadata>
  <opf:manifest><opf:item id="c1" href="text/ch1.xhtml"/></opf:manifest>
  <opf:spine><opf:itemref idref="c1"/></opf:spine>
</opf:package>''',
      'OEBPS/text/ch1.xhtml': xhtml('PFX', '<p>prefixed works</p>'),
    }),
  );
  check(
    '🔴 带命名空间前缀（`opf:itemref`）也能解析',
    prefixed is EbookParseSuccess &&
        prefixed.book.chapters.isNotEmpty &&
        prefixed.book.chapters[0].text.contains('prefixed works'),
    '$prefixed',
  );
  check(
    '  且带前缀时书名也能取到',
    prefixed is EbookParseSuccess && prefixed.book.title == 'Prefixed',
    prefixed is EbookParseSuccess ? prefixed.book.title : '失败',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ⑤ 🔴 DRM —— 最高频失败原因，必须单列一类
  // ══════════════════════════════════════════════════════════════════════

  final drm = parseEpub(
    buildZip(epubEntries(
      spineOrder: ['c1'],
      manifestHrefs: {'c1': 'text/ch1.xhtml'},
      chapterContents: {'text/ch1.xhtml': xhtml('X', '<p>secret</p>')},
      withDrm: true,
    )),
  );
  check(
    '🔴 有 encryption.xml → drmProtected（不是笼统的失败）',
    drm is EbookParseFailure && drm.kind == EbookParseErrorKind.drmProtected,
    '$drm',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ⑥ 失败路径
  // ══════════════════════════════════════════════════════════════════════

  // 不是 zip
  final notZip = parseEpub(
    Uint8List.fromList(utf8.encode('this is definitely not a zip file at all')),
  );
  check(
    '不是 zip → notEpub',
    notZip is EbookParseFailure && notZip.kind == EbookParseErrorKind.notEpub,
    '$notZip',
  );

  // 缺 container.xml
  final noContainer = parseEpub(buildZip({
    'mimetype': 'application/epub+zip',
    'OEBPS/content.opf': '<package/>',
  }));
  check(
    '缺 container.xml → brokenEpub',
    noContainer is EbookParseFailure &&
        noContainer.kind == EbookParseErrorKind.brokenEpub,
    '$noContainer',
  );

  // container 指向的 OPF 不存在
  final missingOpf = parseEpub(buildZip({
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?><container version="1.0"><rootfiles><rootfile full-path="OEBPS/nope.opf"/></rootfiles></container>',
  }));
  check(
    'OPF 不存在 → brokenEpub',
    missingOpf is EbookParseFailure &&
        missingOpf.kind == EbookParseErrorKind.brokenEpub,
    '$missingOpf',
  );

  // 空 spine
  final emptySpine = parseEpub(buildZip({
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?><container version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
    'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="b">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
  <manifest><item id="c1" href="text/ch1.xhtml"/></manifest>
  <spine></spine>
</package>''',
    'OEBPS/text/ch1.xhtml': xhtml('X', '<p>body</p>'),
  }));
  check(
    'spine 为空 → brokenEpub（不是静默产出 0 章）',
    emptySpine is EbookParseFailure &&
        emptySpine.kind == EbookParseErrorKind.brokenEpub,
    '$emptySpine',
  );

  check('空字节 → empty', () {
    final r = parseEpub(Uint8List(0));
    return r is EbookParseFailure && r.kind == EbookParseErrorKind.empty;
  }());

  check(
    '超上限 → tooLarge',
    () {
      final r = parseEpub(Uint8List(kMaxEbookBytes + 1));
      return r is EbookParseFailure && r.kind == EbookParseErrorKind.tooLarge;
    }(),
  );

  // 空文件
  final emptyFile = parseEpub(buildZip({
    'mimetype': 'x',
    'META-INF/container.xml':
        '<?xml version="1.0"?><container version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
    'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="b">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
  <manifest><item id="c1" href="text/ch1.xhtml"/></manifest>
  <spine><itemref idref="c1"/></spine>
</package>''',
    // 🔴 真正空的章节 —— 连 `<h1>` 都没有。
    //    ⚠️ 不能用 `xhtml('X', '')`：它仍会生成 `<h1>X</h1>`，
    //       而 h1 的文字**就是内容** ⇒ 测不到「空章跳过」这条逻辑（本行是实测后改的）。
    'OEBPS/text/ch1.xhtml':
        '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>',
  }));
  check(
    '章节全空 → empty（不当成「成功的空书」）',
    emptyFile is EbookParseFailure && emptyFile.kind == EbookParseErrorKind.empty,
    '$emptyFile',
  );

  // 🔑 「是合法 zip，但里面什么都没有」—— 应报 brokenEpub（而不是 notEpub）
  //    这条与上一条的区别正是本次修的那个 bug 的反面：
  //    空 zip **有** PK 签名 ⇒ 不能报「不是 EPUB」。
  final emptyZip = parseEpub(buildZip({}));
  check(
    '合法但空的 zip → brokenEpub（不是 notEpub）',
    emptyZip is EbookParseFailure && emptyZip.kind == EbookParseErrorKind.brokenEpub,
    '$emptyZip',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ⑦ 容错：不该因为「无关文件」或「个别坏引用」整体失败
  // ══════════════════════════════════════════════════════════════════════

  final tolerant = parseEpub(
    buildZip(epubEntries(
      spineOrder: ['c1', 'missing', 'c2'],
      manifestHrefs: {
        'c1': 'text/ch1.xhtml',
        'missing': 'text/does_not_exist.xhtml', // 🔴 引用不存在
        'c2': 'text/ch2.xhtml',
      },
      chapterContents: {
        'text/ch1.xhtml': xhtml('OK1', '<p>first</p>'),
        'text/ch2.xhtml': xhtml('OK2', '<p>second</p>'),
      },
      // 无关文件（字体 / CSS / 图片）—— 不该影响解析
      extraManifestItems:
          '<item id="css" href="style.css" media-type="text/css"/>',
    )..addAll({
      'OEBPS/style.css': 'body{font-family:serif}',
      'OEBPS/fonts/x.ttf': 'not-a-real-font',
    })),
  );
  check(
    'spine 里有个不存在的文件 → 跳过它，其余照常（不整体失败）',
    tolerant is EbookParseSuccess && tolerant.book.chapters.length == 2,
    '$tolerant',
  );

  // ══════════════════════════════════════════════════════════════════════
  // ⑧ HTML → 纯文本（独立可测的纯函数）
  // ══════════════════════════════════════════════════════════════════════

  check(
    'script 内容被整块删除（不是只剩标签）',
    !htmlToPlainText('<p>a</p><script>var x = "<b>evil</b>";</script><p>b</p>')
        .contains('evil'),
  );

  check(
    '实体解码：&amp;lt; 不被二次解码成 <',
    htmlToPlainText('<p>&amp;lt;</p>') == '&lt;',
    htmlToPlainText('<p>&amp;lt;</p>'),
  );

  check(
    '实体解码：数字实体 &#39; 与 &#x41;',
    htmlToPlainText("<p>&#39;A&#x42;</p>") == "'AB",
    htmlToPlainText("<p>&#39;A&#x42;</p>"),
  );

  check(
    '&nbsp; → 空格',
    htmlToPlainText('<p>a&nbsp;b</p>') == 'a b',
    htmlToPlainText('<p>a&nbsp;b</p>'),
  );

  check(
    '块级标签转换行（</p> <br>）',
    htmlToPlainText('<p>one</p><p>two</p>').contains('\n'),
  );

  check(
    '连续空行压成一个（不产生大段空白）',
    !htmlToPlainText('<p>a</p><p></p><p></p><p></p><p>b</p>').contains('\n\n\n'),
  );

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
  if (_fail == 0) print('✅ 全部通过');
  if (_fail > 0) {
    throw StateError('电子书 EPUB 解析验收失败 $_fail 项');
  }
}
