// CoEvo · **消化前后 AST 对比**（诊断脚本 · 恒退出 0）
//
// # 为什么需要它（本轮最关键的一步）
//
// 扩 `kUnescapablePunct` 白名单的风险是**「造语法」**：
// 消掉反斜杠后，原本是字面标点的字符可能**变成 Markdown 语法**。
//   · `\*text\*` → `*text*` = 变成**强调**
//   · `\# x`     → `# x`    = 变成**标题**
//   · `\+ x`     → `+ x`    = 变成**列表**
// 而这类错误**不报错**，只是渲染结果变了 ⇒ 只能靠断言/对比锁死。
//
// # 为什么能这么做（而不是只能靠真机）
//
// `gpt_markdown` 的解析器 `plusparse` 是 **纯 Dart**（全部文件零 Flutter import），
// 官方 API：`Plusparse.parse(md) -> MdDocument`。
// ⇒ 可以**在脚本里直接跑真实解析器**，比较消化前后的**块结构**。
//   这比「逐字符论证」强得多：它是**机械的、全量的**。
//
// 🔑 判据：**能跑真实实现就不要靠推理** —— 尤其当「推理错」不会报错时。
//
// # 对比什么
//
// **只比结构，不比文本**（消化必然改变文本 —— 删了反斜杠）。
// 指纹里 `MdText` 只输出类型 `T`，不输出内容。
//
// | 消化前 | 消化后 | 判定 |
// |---|---|---|
// | `[P[T]]` | `[P[T]]` | ✅ 安全（结构不变）|
// | `[P[T]]` | `[P[Italic[T]]]` | 🔴 **造了语法** |
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/ast_diff.dart

import 'dart:convert';
import 'dart:io';

import 'package:gpt_markdown/plusparse/ast.dart';
import 'package:gpt_markdown/plusparse/plusparse.dart';

import '../lib/services/markdown_unescape.dart';

/// 结构指纹（**只含类型与结构属性，不含文本内容**）。
String fingerprint(MdNode n) {
  String kids(List<MdNode> c) => c.map(fingerprint).join(',');

  return switch (n) {
    MdHeading(:final level, :final children) => 'H$level(${kids(children)})',
    MdParagraph(:final children) => 'P(${kids(children)})',
    MdBlockQuote(:final children) => 'BQ(${kids(children)})',
    MdCodeBlock(:final language) => 'Code($language)',
    MdUnorderedList(:final items) =>
      'UL[${items.map((i) => kids(i.children)).join(';')}]',
    MdOrderedList(:final start, :final items) =>
      'OL$start[${items.map((i) => kids(i.children)).join(';')}]',
    MdCheckbox(:final checked, :final children) => 'CB$checked(${kids(children)})',
    MdRadio(:final selected, :final children) => 'RD$selected(${kids(children)})',
    MdTable() => 'Table',
    MdBlockLatex() => 'BlockTex',
    MdHorizontalRule() => 'HR',
    // 🔑 叶子：**只报类型**，不报内容（内容必然因消化而变）
    MdText() => 'T',
    MdInlineCode() => 'ICode',
    MdInlineLatex() => 'ITex',
    MdBold(:final children) => 'B(${kids(children)})',
    MdItalic(:final children) => 'I(${kids(children)})',
    MdStrike(:final children) => 'S(${kids(children)})',
    MdUnderline(:final children) => 'U(${kids(children)})',
    MdLink(:final children) => 'Link(${kids(children)})',
    MdImage() => 'Img',
    _ => '?${n.runtimeType}',
  };
}

String docFp(String md) =>
    Plusparse.parse(md).children.map(fingerprint).join('|');

void main() {
  final f = File('../scripts/trace_verify/fixtures/all_bodies.json');
  if (!f.existsSync()) {
    stderr.writeln('🔴 缺少 fixtures/all_bodies.json（先从生产导出）');
    exit(1);
  }
  final rows = jsonDecode(f.readAsStringSync(encoding: utf8)) as List;

  const junk = {2041, 2692}; // PDF 乱码，跳过（不是正常文本）
  var checked = 0, changed = 0;
  final samples = <String>[];

  for (final r in rows) {
    final id = r['id'] as int;
    if (junk.contains(id)) continue;
    final body = (r['body'] ?? '') as String;
    if (body.isEmpty || !body.contains(r'\')) continue;
    checked++;

    final out = unescapeRedundantMarkdown(markdown: body);
    final a = docFp(body);
    final b = docFp(out);
    if (a != b) {
      changed++;
      if (samples.length < 10) samples.add('id=$id\n   before: $a\n   after : $b');
    }
  }

  print('=' * 78);
  print('消化前后 AST 对比（跳过 $junk 两篇乱码）');
  print('=' * 78);
  print('  检查 $checked 篇（含反斜杠的）· **结构改变 $changed 篇**');
  print('');
  if (changed == 0) {
    print('  ✅ 零结构改变 —— 消化**没有造出任何语法**');
  } else {
    print('  🔴 消化改变了块结构（= 造了语法），样例：');
    for (final s in samples) {
      print('  ── $s');
    }
  }
}
