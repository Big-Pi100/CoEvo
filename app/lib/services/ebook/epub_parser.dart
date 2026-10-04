// EPUB 电子书解析
//
// 🔴 **本文件不 import 任何 Flutter 包** —— 只依赖纯 Dart 的 `archive` / `xml`
//   ⇒ 可用 `dart run` 在本机跑真断言（含**真造的 EPUB 样本**，见 verify_epub_parser.dart）。
//
// # EPUB 的本质
//
// `.epub` = **一个 zip**，里面长这样：
//
//   mimetype                      ← 必须是第一个且**不压缩**（我们只是读取，不生成，故不关心）
//   META-INF/container.xml        ← 指向 OPF 的路径（**唯一的入口**）
//   META-INF/encryption.xml       ← 🔴 **存在即表示有 DRM**（最高频失败原因）
//   OEBPS/content.opf             ← 书目：metadata / manifest / spine
//   OEBPS/chapter1.xhtml          ← 正文
//
// # 🔴 三个最容易写错的地方
//
// ① **章节顺序必须按 `<spine>`，不是文件名**
//    文件名排序在真实 EPUB 里经常是错的：`ch10.xhtml` 会排在 `ch2.xhtml` 前面。
//    spine 里的 `<itemref idref="...">` 顺序**才是**阅读顺序。
//
// ② **路径要相对 OPF 所在目录解析**（还要处理 `../`）
//    `container.xml` 给的是 `OEBPS/content.opf`；
//    OPF 里 manifest 的 `href="text/ch1.xhtml"` 是**相对 `OEBPS/`** 的。
//
// ③ **不能在解压阶段就放弃** ——
//    zip 里可能有我们不认识的文件（字体、图片、CSS）。**只挑需要的**，
//    其余忽略；不认识的文件不该导致失败。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'book_text.dart';

/// EPUB 必需的定位文件。
const String _kContainerPath = 'META-INF/container.xml';

/// DRM 标志文件（存在即表示加密）。
const String _kEncryptionPath = 'META-INF/encryption.xml';

/// 解析 EPUB。
///
/// [bytes] 原始字节；[fileName] 仅用于**兜底书名**（OPF 里有 title 时以 OPF 为准）。
EbookParseResult parseEpub(Uint8List bytes, {String? fileName}) {
  if (bytes.isEmpty) {
    return const EbookParseFailure(EbookParseErrorKind.empty, '空文件（0 字节）');
  }
  if (bytes.length > kMaxEbookBytes) {
    return EbookParseFailure(
      EbookParseErrorKind.tooLarge,
      '体积 ${bytes.length} 字节 > 上限 $kMaxEbookBytes',
    );
  }

  // ── ① 先排除「根本不是 zip」────────────────────────────────────────────
  //
  // 🔴 **为什么不能只靠 `ZipDecoder` 抛异常**（本行是实测后补的）：
  //    给 `decodeBytes` 一段纯文本，它**不抛异常**，而是返回一个**空 Archive**
  //    ⇒ 代码会一路走到「缺 container.xml」⇒ 报 `brokenEpub`。
  //    但用户其实只是**选错了文件**（拖了个 .txt 进来）——
  //    告诉他「EPUB 结构不完整」会让他以为书坏了，而不是「我选错了」。
  //    ⇒ 用 zip 的 magic number（`PK`）做**确定性**判定。
  if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
    return EbookParseFailure(
      EbookParseErrorKind.notEpub,
      '文件头不是 zip 签名（期望 PK，实际 '
      '0x${bytes.isEmpty ? '--' : bytes[0].toRadixString(16)}'
      '${bytes.length < 2 ? '' : ' 0x${bytes[1].toRadixString(16)}'}）',
    );
  }

  // ── ② 解压 ────────────────────────────────────────────────────────────
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    // zip 签名对了但内容损坏
    return EbookParseFailure(EbookParseErrorKind.notEpub, 'zip 解压失败：$e');
  }

  // 建索引：路径 → 文件（**统一按 `/` 分隔**，且去掉开头的 `./`）
  final files = <String, ArchiveFile>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    files[_normalize(f.name)] = f;
  }

  // ── ③ DRM 检测（必须在解析正文之前 —— 否则会拿一堆乱码当正文）─────────
  if (files.containsKey(_kEncryptionPath)) {
    return const EbookParseFailure(
      EbookParseErrorKind.drmProtected,
      '存在 META-INF/encryption.xml',
    );
  }

  // ── ④ container.xml → OPF 路径 ────────────────────────────────────────
  final containerFile = files[_kContainerPath];
  if (containerFile == null) {
    return const EbookParseFailure(
      EbookParseErrorKind.brokenEpub,
      '缺 META-INF/container.xml',
    );
  }

  String opfPath;
  try {
    final doc = XmlDocument.parse(utf8.decode(containerFile.content));
    final rootfile = _findElements(doc, 'rootfile').firstOrNull;
    final full = rootfile?.getAttribute('full-path');
    if (full == null || full.trim().isEmpty) {
      return const EbookParseFailure(
        EbookParseErrorKind.brokenEpub,
        'container.xml 里没有 rootfile/@full-path',
      );
    }
    opfPath = _normalize(full);
  } catch (e) {
    return EbookParseFailure(EbookParseErrorKind.brokenEpub, '解析 container.xml 失败：$e');
  }

  final opfFile = files[opfPath];
  if (opfFile == null) {
    return EbookParseFailure(
      EbookParseErrorKind.brokenEpub,
      'container.xml 指向的 OPF 不存在：$opfPath',
    );
  }

  // ── ⑤ 解析 OPF：metadata / manifest / spine ──────────────────────────
  final XmlDocument opf;
  try {
    opf = XmlDocument.parse(utf8.decode(opfFile.content));
  } catch (e) {
    return EbookParseFailure(EbookParseErrorKind.brokenEpub, '解析 OPF 失败：$e');
  }

  final title = _firstText(opf, 'title');
  final creator = _firstText(opf, 'creator');
  final language = _firstText(opf, 'language');

  // manifest: id → href
  final manifest = <String, String>{};
  for (final item in _findElements(opf, 'item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && href != null) manifest[id] = href;
  }

  // spine: 有序的 idref 列表 —— 🔴 **这就是章节顺序**
  final spineIds = <String>[];
  for (final itemref in _findElements(opf, 'itemref')) {
    final idref = itemref.getAttribute('idref');
    if (idref != null) spineIds.add(idref);
  }

  if (spineIds.isEmpty) {
    return const EbookParseFailure(EbookParseErrorKind.brokenEpub, 'OPF 的 spine 为空');
  }

  // ── ⑥ 按 spine 顺序取正文 ─────────────────────────────────────────────
  //    href 是**相对 OPF 所在目录**的 ⇒ 先算出 OPF 的目录前缀
  final opfDir = _dirOf(opfPath);

  final chapters = <ChapterDraft>[];
  for (final id in spineIds) {
    final href = manifest[id];
    if (href == null) continue; // manifest 里没有 ⇒ 跳过（不算致命）

    // href 可能带 fragment（`ch1.xhtml#s2`）—— 去掉落
    final cleanHref = href.split('#').first;
    if (cleanHref.trim().isEmpty) continue;

    final path = _normalize(_join(opfDir, cleanHref));
    final file = files[path];
    if (file == null) continue; // 引用了不存在的文件 ⇒ 跳过

    final raw = utf8.decode(file.content, allowMalformed: true);
    final text = htmlToPlainText(raw);
    if (text.trim().isEmpty) continue; // 空章（如纯图片页）跳过

    // 章节标题：优先取 xhtml 里的 <h1>/<h2>/<title>
    chapters.add(
      ChapterDraft(title: _extractChapterTitle(raw), text: text),
    );
  }

  if (chapters.isEmpty) {
    return const EbookParseFailure(
      EbookParseErrorKind.empty,
      '按 spine 取正文后没有任何内容',
    );
  }
  if (chapters.length > kMaxEbookChapters) {
    return EbookParseFailure(
      EbookParseErrorKind.tooLarge,
      '章节数 ${chapters.length} > 上限 $kMaxEbookChapters',
    );
  }

  // OPF 里没 title 时，退回文件名 —— 但**不编造**
  final resolvedTitle = (title != null && title.trim().isNotEmpty)
      ? title.trim()
      : _titleFromFileName(fileName);

  return EbookParseSuccess(
    BookDraft(
      title: resolvedTitle,
      author: (creator != null && creator.trim().isNotEmpty) ? creator.trim() : null,
      language: (language != null && language.trim().isNotEmpty) ? language.trim() : null,
      sourceFormat: 'epub',
      chapters: chapters,
    ),
  );
}

// ══════════════════════════════════════════════════════════════════════════
// XML 辅助 —— **按 local name 匹配**，不按 qualified name
// ══════════════════════════════════════════════════════════════════════════
//
// 🔑 为什么不用 `findAllElements('itemref')`：
//    那个方法匹配的是 **qualified name**。OPF 若写成 `<opf:itemref>`
//    （真实世界里确实有），`'itemref'` 就匹配不到 ⇒ **静默少章节**。
//    按 `name.local` 匹配可同时覆盖 `<itemref>` 与 `<opf:itemref>`。

Iterable<XmlElement> _findElements(XmlNode node, String localName) => node
    .descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == localName);

String? _firstText(XmlNode node, String localName) {
  for (final e in _findElements(node, localName)) {
    final t = e.innerText.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

// ══════════════════════════════════════════════════════════════════════════
// 路径处理
// ══════════════════════════════════════════════════════════════════════════

/// 归一化 zip 内路径：统一分隔符、去掉 `./`、解析 `..`。
String _normalize(String p) {
  final parts = p.replaceAll(r'\', '/').split('/');
  final out = <String>[];
  for (final seg in parts) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

/// `a/b/c.opf` → `a/b`（无目录时返回空串）。
String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

/// 相对路径拼接（`_normalize` 会处理 `..`）。
String _join(String dir, String rel) => dir.isEmpty ? rel : '$dir/$rel';

String _titleFromFileName(String? fileName) {
  if (fileName == null || fileName.trim().isEmpty) return '未命名';
  final base = fileName.replaceAll(r'\', '/').split('/').last;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  final trimmed = stem.trim();
  return trimmed.isEmpty ? '未命名' : trimmed;
}

// ══════════════════════════════════════════════════════════════════════════
// XHTML → 纯文本
// ══════════════════════════════════════════════════════════════════════════
//
// 🔑 **为什么用正则而不是 XML 解析器**：
//    EPUB 的 XHTML 在真实世界里**经常不是 well-formed**（未闭合的 `<br>`、
//    裸 `&`、重复属性…）。用 XML 解析器会直接抛异常 ⇒ **一本书都读不出来**。
//    我们只要纯文本 ⇒ 正则更鲁棒，且正文里的 `<` 极罕见。

/// XHTML/HTML → 纯文本（保留段落结构）。
String htmlToPlainText(String html) {
  var s = html;

  // ① 去掉**含内容**的块（script / style / head）—— 必须先于「去标签」
  s = s.replaceAll(
    RegExp(r'<(script|style|head)\b[^>]*>.*?</\1\s*>',
        caseSensitive: false, dotAll: true),
    '',
  );

  // ② 块级边界 → 换行（否则整章会挤成一行）
  s = s.replaceAll(
    RegExp(r'</(p|div|h[1-6]|li|blockquote|tr|section|article)\s*>',
        caseSensitive: false),
    '\n',
  );
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

  // ③ 去掉所有剩余标签
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');

  // ④ 解码 HTML 实体（先处理数字实体，再处理常见命名实体）
  s = s.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  s = s.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m.group(1)!)),
  );
  s = s.replaceAll('&nbsp;', ' ');
  s = s.replaceAll('&lt;', '<');
  s = s.replaceAll('&gt;', '>');
  s = s.replaceAll('&quot;', '"');
  s = s.replaceAll('&apos;', "'");
  // ⚠️ `&amp;` **必须放最后** —— 否则 `&amp;lt;` 会被二次解码成 `<`
  s = s.replaceAll('&amp;', '&');

  // ⑤ 规范化空白：行尾空格去掉、连续空行压成一个
  final lines = s.split('\n').map((l) => l.trim()).toList();
  final out = <String>[];
  var blankRun = 0;
  for (final l in lines) {
    if (l.isEmpty) {
      blankRun++;
      if (blankRun <= 1) out.add(''); // 最多保留一个空行
    } else {
      blankRun = 0;
      out.add(l);
    }
  }

  return out.join('\n').trim();
}

/// 章节标题：依次尝试 `<h1>` → `<h2>` → `<title>`。
///
/// 🔑 不编造 —— 都没有就返回 null（UI 会退化成显示「第 N 章」）。
String? _extractChapterTitle(String xhtml) {
  for (final tag in ['h1', 'h2', 'h3', 'title']) {
    final m = RegExp('<$tag\\b[^>]*>(.*?)</$tag\\s*>',
            caseSensitive: false, dotAll: true)
        .firstMatch(xhtml);
    if (m != null) {
      final t = htmlToPlainText(m.group(1)!);
      if (t.isNotEmpty && t.length <= 120) return t;
    }
  }
  return null;
}
