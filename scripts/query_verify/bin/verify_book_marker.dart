// CoEvo · 书签验收（`book_marker` · 2026-10-07）
//
// 跑：cd scripts/query_verify && dart run bin/verify_book_marker.dart
// 🔴 退出码：0 = 全过，1 = 有失败。
//
// # 两条腿，各守一半
//
// | 组 | 守什么 |
// |---|---|
// | 【1】【2】**纯逻辑** | 摘录估算（近似值的边界）/ 「同一位置」的容差判定 |
// | 【3】–【6】**真库** | 表与索引、按**位置**排序、容差查询、软删、**级联删除** |
//
// # 🔴 为什么真库这一腿不能省
//
// 仓储里的 SQL 列名是**字符串字面量** —— 拼错一个字母 Dart 编译器**一声不吭**，
// 只有真跑才炸（`no such column`）。而且本表还有两条**只有真库能验**的性质：
// · **级联删除**（删书 ⇒ 书签跟着走）—— 依赖 `PRAGMA foreign_keys = ON`
//   （那是**连接级**设置，写在 `book_db.dart` 的 `onConfigure` 里；漏了它
//   删书会**静默留下孤儿书签**，而查列表时它们指向一本不存在的书）
// · **软删后 `findAt` 不能再命中**（否则「点一下 = 打/取消」会变成
//   「取消一条已取消的」—— 用户看到点了没反应）
//
// ⚠️ 本脚本**查不出**的：渲染与手势（需 Flutter 环境 + 真机）。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/book_db.dart';
import '../../../app/lib/services/ebook/book_marker.dart';
import '../../../app/lib/services/ebook/book_marker_repository.dart';

var _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void eq(String label, Object? actual, Object? expected) =>
    check(label, actual == expected, '实际=$actual 期望=$expected');

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

/// 一章用于测摘录估算的正文（含多句 + 中文标点）。
const _chapter = 'The first sentence ends here. '
    'The second one is a bit longer and it also ends. '
    '第三句话在这里结束。第四句话稍微长一点，也结束了。';

Future<void> main() async {
  print('═' * 74);
  print('书签验收（book_marker）');
  print('═' * 74);

  // ══════════════════════════════════════════════════════════════════════
  section('【1】摘录估算 estimateBookmarkExcerpt（**近似值**的边界）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 它是**近似**（比例是像素关系、文字是字符关系）⇒ 断言**不验「准」**，
  //    只验**性质**：不空、不越界、是「像话的一段」、比例单调。

  eq('空正文 ⇒ 空串（不抛）',
      estimateBookmarkExcerpt(chapterText: '', scrollRatio: 0.5), '');
  check('ratio 0 ⇒ 有内容',
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: 0).isNotEmpty);
  check('ratio 1 ⇒ 有内容（且**不越界**）',
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: 1).isNotEmpty);
  check('🔴 ratio 越界（1.5）不抛、不越界',
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: 1.5).isNotEmpty);
  check('🔴 ratio 负数不抛',
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: -3).isNotEmpty);
  check('🔴 NaN ⇒ 当作 0（不抛、不空）',
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: double.nan)
          .isNotEmpty);

  // 摘录必须是**正文的子串**（它不是新造的文字）
  var allSubstring = true;
  for (final r in [0.0, 0.17, 0.35, 0.5, 0.72, 0.99, 1.0]) {
    final e = estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: r);
    if (e.isNotEmpty && !_chapter.contains(e)) allSubstring = false;
  }
  check('🔴 任意比例下摘录都是**正文的子串**（不新造、不拼接）', allSubstring);

  check('长度不超过 maxChars',
      estimateBookmarkExcerpt(
              chapterText: _chapter, scrollRatio: 0.3, maxChars: 30)
          .length <=
          30);
  eq('短正文（比 maxChars 短）⇒ 全文',
      estimateBookmarkExcerpt(chapterText: 'abc', scrollRatio: 0), 'abc');
  eq('没有句末标点 ⇒ 仍给出内容（不空）',
      estimateBookmarkExcerpt(
          chapterText: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', scrollRatio: 0),
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  // 🔴 「已够长才按句末截断」——防的是给出 `Hi.` 这种没信息量的摘录
  final shortFirst = estimateBookmarkExcerpt(
      chapterText: 'Hi. Then a much longer sentence follows right after this one.',
      scrollRatio: 0);
  check('🔴 首句过短（`Hi.`）⇒ **不**只在它那里截断（要够长才截）',
      shortFirst.length >= kBookmarkMinExcerptChars, '$shortFirst');

  // ══════════════════════════════════════════════════════════════════════
  // 🔴 下面两条锁住**实测发现的两个真 bug**（首版实现里它们都错了）
  // ══════════════════════════════════════════════════════════════════════

  // ① 中文句末 `。` **后面没有空格** —— 若正则要求「句末 + 空白」，
  //    就**匹配不到任何中文句子边界** ⇒ 摘录从估算位置硬切，取到半句。
  const cnChapter = '第一句话在这里结束。第二句话稍微长一点，也结束了。';
  final cnExcerpt =
      estimateBookmarkExcerpt(chapterText: cnChapter, scrollRatio: 0.6);
  check('🔴 中文句末（`。` 后无空格）能被识别 ⇒ 摘录从**句子起点**开始',
      cnExcerpt.startsWith('第二句话'), '$cnExcerpt');

  // ② 滚到底部（ratio = 1）⇒ 首版「向后找下一句」找不到 ⇒ 给出**「。」**（垃圾）
  final tailExcerpt =
      estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: 1.0);
  check('🔴 比例 = 1（滚到底）⇒ 摘录不是一个孤零零的标点',
      tailExcerpt.length >= kBookmarkMinExcerptChars, '「$tailExcerpt」');
  check('且它仍是正文的子串（不是拼出来的）',
      _chapter.contains(tailExcerpt), '$tailExcerpt');

  // 单调性：比例越大 ⇒ 摘录在正文里的**起始位置越靠后**（不要求严格，只要求不倒退）
  var mono = true;
  var lastIdx = -1;
  for (var i = 0; i <= 20; i++) {
    final r = i / 20;
    final e = estimateBookmarkExcerpt(chapterText: _chapter, scrollRatio: r);
    final idx = e.isEmpty ? -1 : _chapter.indexOf(e);
    if (idx >= 0 && lastIdx >= 0 && idx < lastIdx - 5) mono = false;
    if (idx >= 0) lastIdx = idx;
  }
  check('单调性：比例增大 ⇒ 摘录不倒退（允许小回退 —— 句子起点会对齐）', mono);

  // ══════════════════════════════════════════════════════════════════════
  section('【2】同一位置判定 isSameBookmarkPosition（容差）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔑 容差存在的原因：`scroll_ratio` 是 REAL，浮点相等不可靠。
  //    用户在同一次滚动里点两次，比例可能差一个字节 —— 若不判同处，
  //    会多出一条几乎重合的记录（界面上看不出来）。

  check('完全相同 ⇒ 同处', isSameBookmarkPosition(0.5, 0.5));
  check('差 0.005（容差 0.01 内）⇒ 同处', isSameBookmarkPosition(0.5, 0.505));
  check('差 0.01（正好在边界）⇒ 同处', isSameBookmarkPosition(0.5, 0.51));
  check('差 0.02（超容差）⇒ **不**同处', !isSameBookmarkPosition(0.5, 0.52));
  check('对称（a,b 与 b,a 一致）',
      isSameBookmarkPosition(0.3, 0.305) == isSameBookmarkPosition(0.305, 0.3));
  check('🔴 NaN 一律**不**同处（否则「打书签」会永远变成「取消」）',
      !isSameBookmarkPosition(double.nan, 0.5) &&
          !isSameBookmarkPosition(0.5, double.nan) &&
          !isSameBookmarkPosition(double.nan, double.nan));
  eq('容差默认值 == 0.01', kBookmarkSamePositionTolerance, 0.01);

  // ══════════════════════════════════════════════════════════════════════
  section('【3】真库：表 / 索引 / 列');
  // ══════════════════════════════════════════════════════════════════════
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final schemaSql =
      File('../../app/assets/sql/book_db_schema.sql').readAsStringSync();
  final dir = await Directory.systemTemp.createTemp('coevo_book_marker');
  final db = await openBookDb(
    factory: factory,
    path: '${dir.path}/book.db',
    schemaSql: schemaSql,
  );
  final repo = BookMarkerRepository(db);

  final tables = await db
      .rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
  final names = tables.map((r) => r['name'] as String).toList();
  check('🔴 `book_marker` 表存在', names.contains('book_marker'), names.join(','));
  final idxs = await db
      .rawQuery("SELECT name FROM sqlite_master WHERE type='index'");
  check('`idx_book_marker` 索引存在',
      idxs.map((r) => r['name']).contains('idx_book_marker'));

  final cols = await db.rawQuery('PRAGMA table_info(book_marker)');
  final colNames = cols.map((r) => r['name'] as String).toList();
  for (final c in [
    'id',
    'book_id',
    'chapter_idx',
    'scroll_ratio',
    'excerpt',
    'created_at',
    'deleted',
  ]) {
    check('列 `$c` 存在', colNames.contains(c), colNames.join(','));
  }
  eq('🔴 书签**没有** `text` / `note` 列（它不是划线）',
      colNames.where((c) => c == 'text' || c == 'note').join(','), '');
  // 外键（级联删除的前提）
  final fks = await db.rawQuery('PRAGMA foreign_key_list(book_marker)');
  check('🔴 外键指向 `book(id)`',
      fks.any((r) => r['table'] == 'book' && r['from'] == 'book_id'),
      fks.map((r) => '${r['table']}.${r['from']}').join(','));
  check('🔴 外键是 `ON DELETE CASCADE`（删书要连带删书签）',
      fks.any((r) => (r['on_delete'] as String?)?.toUpperCase() == 'CASCADE'),
      fks.map((r) => '${r['on_delete']}').join(','));

  // 建一本真书（FK 需要）
  await db.insert('book', {
    'id': 'b-1',
    'title': 'A Tale of Two Cities',
    'source_format': 'epub',
    'chapter_count': 3,
    'char_count': 3000,
    'added_at': '2026-10-07T00:00:00Z',
  });
  await db.insert('book', {
    'id': 'b-2',
    'title': 'Another Book',
    'source_format': 'txt',
    'chapter_count': 1,
    'char_count': 100,
    'added_at': '2026-10-07T00:00:00Z',
  });

  // ══════════════════════════════════════════════════════════════════════
  section('【4】写 / 读：按**位置**排序（不是按时间）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔑 故意**乱序写入 + 时间戳也乱序** ⇒ 若实现按时间排，本组会红。
  await repo.add(
      id: 'm-3',
      bookId: 'b-1',
      chapterIdx: 2,
      scrollRatio: 0.1,
      excerpt: '第三章开头',
      createdAt: DateTime.utc(2026, 10, 7, 3));
  await repo.add(
      id: 'm-1',
      bookId: 'b-1',
      chapterIdx: 0,
      scrollRatio: 0.9,
      excerpt: '第一章靠后',
      createdAt: DateTime.utc(2026, 10, 7, 1));
  await repo.add(
      id: 'm-2',
      bookId: 'b-1',
      chapterIdx: 0,
      scrollRatio: 0.2,
      excerpt: '第一章开头',
      createdAt: DateTime.utc(2026, 10, 7, 2));

  final list = await repo.listForBook('b-1');
  eq('3 条都能读回', list.length, 3);
  eq('🔴 按**位置**排序：第 0 章 0.2 在最前',
      list[0].id, 'm-2');
  eq('接着是第 0 章 0.9', list[1].id, 'm-1');
  eq('最后是第 2 章', list[2].id, 'm-3');
  eq('摘录保真', list[0].excerpt, '第一章开头');
  eq('比例保真', list[0].scrollRatio, 0.2);
  eq('章序保真', list[2].chapterIdx, 2);
  check('🔴 时间戳是 UTC（带 Z）—— 同库 `book.added_at` 的口径',
      (await db.query('book_marker',
                  columns: ['created_at'], where: 'id = ?', whereArgs: ['m-1']))
              .first['created_at']
              .toString()
              .endsWith('Z'));
  eq('另一本书读不到它的书签（隔离）',
      (await repo.listForBook('b-2')).length, 0);

  // ══════════════════════════════════════════════════════════════════════
  section('【5】findAt（容差查询）—— 「点一下 = 打/取消」的判据');
  // ══════════════════════════════════════════════════════════════════════
  final hit = await repo.findAt(bookId: 'b-1', chapterIdx: 0, scrollRatio: 0.2);
  check('精确命中', hit != null && hit.id == 'm-2', '${hit?.id}');
  final near = await repo.findAt(bookId: 'b-1', chapterIdx: 0, scrollRatio: 0.205);
  check('🔴 容差内（0.205 vs 0.2）⇒ 命中同一条', near != null && near.id == 'm-2',
      '${near?.id}');
  final far = await repo.findAt(bookId: 'b-1', chapterIdx: 0, scrollRatio: 0.5);
  check('🔴 容差外 ⇒ **不**命中（否则「打」会被误判成「取消」）', far == null);
  final otherChapter =
      await repo.findAt(bookId: 'b-1', chapterIdx: 1, scrollRatio: 0.2);
  check('🔴 同比例但**不同章** ⇒ 不命中（章序参与判定）', otherChapter == null);
  final otherBook =
      await repo.findAt(bookId: 'b-2', chapterIdx: 0, scrollRatio: 0.2);
  check('同章同比但**不同书** ⇒ 不命中', otherBook == null);
  check('NaN ⇒ 不命中（坏值不造奇怪匹配）',
      await repo.findAt(bookId: 'b-1', chapterIdx: 0, scrollRatio: double.nan) ==
          null);

  // ══════════════════════════════════════════════════════════════════════
  section('【6】软删 + 级联删除（两条只有真库能验的性质）');
  // ══════════════════════════════════════════════════════════════════════
  await repo.remove('m-2');
  eq('软删后列表少一条', (await repo.listForBook('b-1')).length, 2);
  eq('countForBook 同步减少', await repo.countForBook('b-1'), 2);
  final removed = await db.query('book_marker',
      where: 'id = ?', whereArgs: ['m-2'], limit: 1);
  check('🔴 行**仍在**（软删，不是 DELETE —— 硬删会被并集同步复活）',
      removed.isNotEmpty && removed.first['deleted'] == 1,
      '${removed.first['deleted']}');
  final afterRemove =
      await repo.findAt(bookId: 'b-1', chapterIdx: 0, scrollRatio: 0.2);
  check('🔴 软删后 `findAt` **不能**再命中（否则「点一下」变成取消一条已取消的）',
      afterRemove == null, '${afterRemove?.id}');

  // 级联：删书 ⇒ 书签跟着走（依赖 `PRAGMA foreign_keys = ON`）
  final before = await repo.countAll();
  await db.delete('book', where: 'id = ?', whereArgs: ['b-2']);
  eq('删一本**没有**书签的书 ⇒ 总数不变', await repo.countAll(), before);
  await db.delete('book', where: 'id = ?', whereArgs: ['b-1']);
  eq('🔴 删书 ⇒ 它的书签**全部**跟着删（级联生效）', await repo.countAll(), 0);
  eq('且是**物理删除**（级联不是软删 —— 书都没了，书签没有意义）',
      (await db.rawQuery('SELECT COUNT(*) AS c FROM book_marker')).first['c'], 0);

  await db.close();

  // ══════════════════════════════════════════════════════════════════════
  print('\n${'═' * 74}');
  if (_failures.isNotEmpty) {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「列/表」类失败 → 检查 `book_db_schema.sql` 与 `kBookDbVersion`；');
    print('  若「排序」失败 → 检查 `listForBook` 的 `orderBy`（应 chapter_idx → scroll_ratio）；');
    print('  若「级联」失败 → 检查 `book_db.dart` 的 `onConfigure` 里有没有'
        ' `PRAGMA foreign_keys = ON`。');
    exit(1);
  }
  print('✅ 全部通过：$_pass 项');
  print('═' * 74);
  print('');
  print('⚠️ 本脚本**查不出**的：渲染 / 手势 / 真机上的滚动比例是否合理。');
}
