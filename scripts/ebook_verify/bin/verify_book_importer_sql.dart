// 电子书导入 —— 落库 SQL 与 schema 的一致性验收（纯 Dart · 零依赖 · 本机可跑 · 可进 CI）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_book_importer_sql.dart
//
// # 🔴 为什么需要它（这类错编译期完全不报）
//
// `book_importer.dart` 里的 INSERT 列名是**字符串字面量**：
//
//     await txn.insert('book', {'id': ..., 'source_format': ...});
//                                        ↑ 写错一个字母，Dart 编译器一声不吭
//
// 后果是**运行时**才炸（`no such column: source_fromat`），而且只在那本书导入时炸
// ⇒ 走得通的路径全绿、走不通的路径炸在用户手上。
//
// 🔑 判据：**「字符串存在」≠「引用可解析」** —— Dart 的符号解析（`codestatic`）
//    也救不了字符串键，**只有源级比对能守**。
//
// # 为什么用「集合相等」而不是「包含」
//
// | 断言方式 | 漏掉的情形 |
// |---|---|
// | `insert` 的列 ⊆ schema 的列 | 🔴 漏列（少写一列 → 那列落 NULL，而 schema 若允许 NULL 就不报错）|
// | **集合相等**（本文件） | ✅ 多列、少列**都**当场红 |
//
// 📌 判据：**「集合相等」> 「包含 + 下限」**（本项目已记）。

import 'dart:io';

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

/// 从 `CREATE TABLE` 块里取出**列名**（跳过约束行）。
///
/// 约束行（`FOREIGN KEY` / `UNIQUE` / `PRIMARY KEY` / `CHECK`）不是列定义 ——
/// 不排除它们会多出「FOREIGN」「UNIQUE」这类假列名。
Set<String> columnsOf(String schemaSql, String table) {
  final block = RegExp(
    'CREATE TABLE IF NOT EXISTS\\s+$table\\s*\\((.*?)\\n\\s*\\)',
    dotAll: true,
  ).firstMatch(schemaSql);
  if (block == null) return {};

  const skip = {'FOREIGN', 'UNIQUE', 'PRIMARY', 'CHECK', 'CONSTRAINT'};
  final cols = <String>{};
  for (final line in block.group(1)!.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('--')) continue;
    final m = RegExp(r'^(\w+)\s').firstMatch(t);
    if (m == null) continue;
    final name = m.group(1)!;
    if (skip.contains(name.toUpperCase())) continue;
    cols.add(name);
  }
  return cols;
}

/// 从 `insert('<table>', { ... })` 的字面量里取出**键名集合**。
///
/// ⚠️ 不用 `non-greedy` 一路吃到 `})` —— 章节那个 map 里也有 `}`；
///    这里改用「先定位起点，再按**大括号配对**扫到终点」，避免正则回溯猜错边界。
Set<String> insertKeysOf(String dartSrc, String table) {
  final start = dartSrc.indexOf("insert('$table', {");
  if (start < 0) return {};

  var i = dartSrc.indexOf('{', start);
  var depth = 0;
  var end = -1;
  for (; i < dartSrc.length; i++) {
    final ch = dartSrc[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) return {};

  final body = dartSrc.substring(start, end);
  return RegExp(r"'(\w+)'\s*:")
      .allMatches(body)
      .map((m) => m.group(1)!)
      .toSet();
}

/// 仓库根 —— **从脚本自身位置推导，而不是相对 cwd**。
///
/// 🔴 为什么不用 `File('../../app/...')`（同目录其他脚本的写法）：
///    那种写法依赖**运行时的工作目录**，而 `dart run bin/x.dart`、IDE 里点运行、
///    从别的目录跑 —— 三种情况 cwd 不同 ⇒ 路径会静默错位（或直接崩）。
///
/// 🔴 **本轮实测踩到的坑（值得单记）**：我照抄同级脚本的层级写成
///    `File('../../../app/...')`（那是 **import** 的层级）⇒ `PathNotFoundException`。
///    根因：**`import` 相对「脚本文件」解析，而 `File()` 相对「进程 cwd」** ——
///    同一个文件里两者**层级不一样**（cwd 是 `scripts/ebook_verify`，比脚本少一层）。
///    📌 判据同族：「工具/写法错 → 静默假结论」（这次恰好是**报错**而非静默，算走运）。
///
/// ✅ 用 `Platform.script` 推导 ⇒ **换任何 cwd 都对**。
final _repoRoot = File.fromUri(Platform.script).parent.parent.parent.parent;

String _repoFile(String rel) => '${_repoRoot.path}/$rel';

void main() {
  final schemaSql =
      File(_repoFile('app/assets/sql/book_db_schema.sql')).readAsStringSync();
  final importerSrc =
      File(_repoFile('app/lib/services/book_importer.dart')).readAsStringSync();
  final planSrc = File(
          _repoFile('app/lib/services/ebook/book_import_plan.dart'))
      .readAsStringSync();

  // ── ① 先证「解析器本身有效」（否则后面全绿也可能是没解析到东西）──
  //    判据：**「检测为 0」时先证检测器有效** —— 用已知有值的样本做对照。
  final bookCols = columnsOf(schemaSql, 'book');
  final chapterCols = columnsOf(schemaSql, 'book_chapter');
  check('🔴 schema 解析器有效：book 解析出 9 列', bookCols.length == 9,
      '实际 ${bookCols.length}：${bookCols.join(',')}');
  check('🔴 schema 解析器有效：book_chapter 解析出 6 列',
      chapterCols.length == 6, '实际 ${chapterCols.length}：${chapterCols.join(',')}');

  final bookInsert = insertKeysOf(importerSrc, 'book');
  final chapterInsert = insertKeysOf(importerSrc, 'book_chapter');
  check('🔴 importer 解析器有效：找到 book 的 insert', bookInsert.isNotEmpty);
  check('🔴 importer 解析器有效：找到 book_chapter 的 insert',
      chapterInsert.isNotEmpty);

  // ── ② 🔴 集合相等（多列 / 少列都红）──
  final missingBook = bookCols.difference(bookInsert);
  final extraBook = bookInsert.difference(bookCols);
  check(
    '🔴 `book` 的 INSERT 列 == schema 列（缺失：$missingBook · 多余：$extraBook）',
    missingBook.isEmpty && extraBook.isEmpty,
    '缺 $missingBook / 多 $extraBook',
  );

  final missingCh = chapterCols.difference(chapterInsert);
  final extraCh = chapterInsert.difference(chapterCols);
  check(
    '🔴 `book_chapter` 的 INSERT 列 == schema 列（缺失：$missingCh · 多余：$extraCh）',
    missingCh.isEmpty && extraCh.isEmpty,
    '缺 $missingCh / 多 $extraCh',
  );

  // ── ③ 跨实现共享定义：`source_format` 的 CHECK 值 ↔ `EbookFormat` 的枚举名 ──
  //
  // 🔑 这两个值在**两处**存在（SQL 的 CHECK 约束、Dart 的 enum），
  //    而它们必须一致 —— 否则「解析器说 epub、库说不行」（症状：CHECK 失败，
  //    但报错信息完全不提枚举，排查要从头翻）。
  //    📌 判据：**跨实现「保持一致」须落到每个共享定义**。
  final checkValues = RegExp(r"source_format IN \(([^)]*)\)")
      .firstMatch(schemaSql)
      ?.group(1)
      ?.split(',')
      .map((s) => s.trim().replaceAll("'", ''))
      .toSet() ??
      {};
  check('🔴 schema 解析器有效：取到 source_format 的 CHECK 值 2 个',
      checkValues.length == 2, checkValues.join(','));
  check('🔴 CHECK 值 == EbookFormat 枚举名（epub / txt）',
      checkValues.length == 2 &&
          checkValues.containsAll({'epub', 'txt'}),
      'CHECK=$checkValues');
  // 反向：枚举里也不许多出第三种（多出来的那种落库必然违反 CHECK）
  //
  // 🔴 **写法上踩过一个坑（值得单记）**：最初写成
  //      `... .toSet() == {'epub', 'txt'}`
  //    结果**永远为 false** —— Dart 的 `Set` / `List` **默认是引用相等**，
  //    `{1,2} == {1,2}` 是 `false`（两个不同的实例）。
  //    ⇒ 集合比较必须**显式**写（`length` + `containsAll`），
  //      或用 `package:collection` 的 `setEquals`（本文件要保持零依赖 ⇒ 用前者）。
  //    📌 判据（本项目已记）：**「集合相等」>「包含 + 下限」** ——
  //      但「集合相等」的**实现**要用真的值比较，否则断言变成「永远红的装饰」。
  final enumNames = RegExp(r'enum EbookFormat \{([^}]*)\}')
          .firstMatch(planSrc)
          ?.group(1)
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet() ??
      <String>{};
  check(
    '🔴 枚举只有 epub / txt 两种',
    enumNames.length == 2 && enumNames.containsAll({'epub', 'txt'}),
    '实际：$enumNames',
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
  if (_fail == 0) {
    print('✅ 全部通过');
  }
  if (_fail > 0) {
    throw StateError('电子书落库 SQL 一致性验收失败 $_fail 项');
  }
}
