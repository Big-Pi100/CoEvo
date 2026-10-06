// 「电子书进度 · 跨设备续读」验收 —— 认领 / 镜像 / pull 后生效
//
// 跑：cd scripts/query_verify && dart run bin/verify_book_progress_sync.dart
// 🔴 退出码：0 = 全过，1 = 有失败（直读，别接 `| tail`）。
//
// # 为什么需要它
//
// 电子书进度跨设备是**本项目最绕的一条链**：
//   `book_id` 是端侧 uuid ⇒ 同一本书两台设备两个 id ⇒ 必须靠**文件指纹**认亲。
// 于是有三张表、三个动作：
// ```
//   book            （有 content_hash —— 跨设备身份）
//   book_progress   （本地权威进度，键 = book_id）
//   book_progress_pending（交换区，键 = content_hash）
//   认领：交换区 → 本地权威     镜像：本地权威 → 交换区
// ```
//
// 这一层的错误**全是静默的**：
//   · 认领后忘了删 pending ⇒ 陈旧进度会「复活」（删书重导时突然跳回旧章）
//   · 镜像无条件覆盖 ⇒ 把别端**更新的**进度冲掉，然后上传旧的（两端都不报错）
//   · 认领只在「导入后」做 ⇒ 对**已导入**的书，pull 来的进度**永远不生效**
//   · 书没有指纹却硬要同步 ⇒ 拿错指纹匹配 ⇒ **把用户带到错的书**（比不同步更糟）
//
// # 🔴 证伪方式
//
// | 改这里 | 应变红的是 |
// |---|---|
// | `_claimOne` 里删掉「删 pending 行」 | 【2】陈旧进度会复活 |
// | `_claimOne` 去掉 `isNewer` 判断（无条件覆盖）| 【3】本地新进度被旧覆盖 |
// | `_claimOne` 在「本地更新」分支**不删** pending | 【4】 |
// | `mirrorProgress` 去掉「取较新」判断 | 【6】把别端新进度冲掉 |
// | `_contentHashOf` 允许空串通过 | 【5】拿空指纹匹配 ⇒ 错书 |
// | `sync_service.pullOnce` 去掉 `_claimBookProgress` | 【9】pull 后不生效 |
// | `book_importer` 去掉 `claimPendingForBook` | 【10】导入后不认领 |
// | `book_provider.saveProgress` 去掉 `mirrorProgress` | 【11】进度不上传 |
//
// # ⚠️ 口径（如实标注）
// · 用**真 sqlite 内存库** + **真 schema 文件** ⇒ FK / 列名 / 约束都真实。
// · 🔴 **必须 `singleInstance: false`** —— 否则所有「新库」是同一个库
//   （`sqflite` 默认单例；本项目已踩过一次，见 `verify_sync_service.dart` 的长注释）。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/ebook/book_progress_sync.dart';
import '../../../app/lib/services/user_db.dart' show executeSqlScript;

int _pass = 0;
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

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String readFile(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

Future<Database> _openBookDb() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await executeSqlScript(
      db, File('../../app/assets/sql/book_db_schema.sql').readAsStringSync());
  return db;
}

const t1 = '2026-10-01T00:00:00.000Z';
const t2 = '2026-10-05T00:00:00.000Z';
const t3 = '2026-10-09T00:00:00.000Z';
const t4 = '2026-10-10T00:00:00.000Z';

/// 造一本书。`hash` 传 `null` 模拟「算不出指纹」。
Future<void> seedBook(Database db, String id, {String? hash}) async {
  await db.insert('book', {
    'id': id,
    'title': 'Pride and Prejudice',
    'source_format': 'epub',
    'added_at': t1,
    'content_hash': hash,
  });
}

/// 造一条「待认领进度」（模拟 pull 写入）。
Future<void> seedPending(
  Database db,
  String hash, {
  int chapter = 9,
  double ratio = 0.8,
  String at = t2,
}) async {
  await db.insert('book_progress_pending', {
    'content_hash': hash,
    'chapter_idx': chapter,
    'scroll_ratio': ratio,
    'updated_at': at,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<Map<String, Object?>?> progressOf(Database db, String bookId) async {
  final r = await db.query('book_progress',
      where: 'book_id = ?', whereArgs: [bookId], limit: 1);
  return r.isEmpty ? null : {...r.first};
}

Future<int> pendingCount(Database db) async =>
    (await db.rawQuery('SELECT count(*) AS n FROM book_progress_pending'))
        .first['n'] as int;

void main() async {
  sqfliteFfiInit();
  print('');
  print('#' * 74);
  print('# 电子书进度 · 跨设备续读验收（认领 / 镜像 / pull 后生效）');
  print('#' * 74);

  // ═══════════════════════════════════════════════════════════
  section('【1】认领：书还没导入时先存着，导入后用上');
  {
    final db = await _openBookDb();
    // 模拟：pull 先来了进度（那时本地没这本书）
    await seedPending(db, 'hash-abc', chapter: 9);
    check('前提：交换区有 1 条待认领', await pendingCount(db) == 1);

    // 之后用户导入了同一本书
    await seedBook(db, 'book-1', hash: 'hash-abc');
    final r = await claimPendingForBook(db, bookId: 'book-1');

    check('认领 1 本', r.claimed == 1, '$r');
    final p = await progressOf(db, 'book-1');
    check('🔑 `book_progress` 出现该行', p != null);
    check('  chapter_idx = 9（别端读到的章）', p?['chapter_idx'] == 9);
    check('  scroll_ratio = 0.8', p?['scroll_ratio'] == 0.8);
    check(
      '🔑 时间戳**用 pending 的**（= 别端读到的时刻），不是 now',
      p?['updated_at'] == t2,
      '实得 ${p?['updated_at']}',
    );
    check('🔴 `pending` 行**已删**（使命完成）', await pendingCount(db) == 0);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【2】🔴 陈旧进度不得「复活」——「本地更新」分支也要删 pending');
  {
    final db = await _openBookDb();
    await seedBook(db, 'book-1', hash: 'hash-abc');
    // 本地已读到第 12 章（**更新**）
    await db.insert('book_progress', {
      'book_id': 'book-1',
      'chapter_idx': 12,
      'scroll_ratio': 0.0,
      'updated_at': t3,
    });
    // 交换区里是**旧的**（第 9 章）
    await seedPending(db, 'hash-abc', chapter: 9, at: t2);

    final r = await claimPendingForBook(db, bookId: 'book-1');
    check('不覆盖本地更新的进度', r.claimed == 0 && r.skippedOlder == 1, '$r');
    check('  本地仍是第 12 章', (await progressOf(db, 'book-1'))?['chapter_idx'] == 12);
    check(
      '🔴🔴 `pending` 行**依然被删** —— 那份旧的永不该再被应用',
      await pendingCount(db) == 0,
      '—— 留着它：① 每次 pull 白比对 ② 删书重导会让**陈旧进度突然复活**',
    );
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【3】本地进度更旧 ⇒ 用交换区的覆盖（正常续读场景）');
  {
    final db = await _openBookDb();
    await seedBook(db, 'book-1', hash: 'hash-abc');
    await db.insert('book_progress', {
      'book_id': 'book-1',
      'chapter_idx': 3,
      'scroll_ratio': 0.0,
      'updated_at': t1, // 更旧
    });
    await seedPending(db, 'hash-abc', chapter: 9, at: t2);

    final r = await claimPendingForBook(db, bookId: 'book-1');
    check('认领成功', r.claimed == 1, '$r');
    check('  章节推进到 9（别端读得更远）',
        (await progressOf(db, 'book-1'))?['chapter_idx'] == 9);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【4】认领的边界：无指纹 / 指纹不匹配 / 无待认领 ⇒ 都不报错');
  {
    final db = await _openBookDb();
    // 无指纹的书
    await seedBook(db, 'no-hash', hash: null);
    await seedPending(db, 'hash-abc');
    final r1 = await claimPendingForBook(db, bookId: 'no-hash');
    check('🔴 书无 `content_hash` ⇒ 跳过（**不报错**）',
        r1.claimed == 0 && r1.skippedNoHash == 1, '$r1');
    check('  且**不动**交换区（那可能属于别的书）', await pendingCount(db) == 1);

    // 指纹不匹配
    await seedBook(db, 'other', hash: 'hash-xyz');
    final r2 = await claimPendingForBook(db, bookId: 'other');
    check('指纹不匹配 ⇒ 什么都不做', r2.total == 0, '$r2');
    check('  `book_progress` 仍为空',
        (await db.query('book_progress')).isEmpty);

    // 无待认领
    await seedBook(db, 'plain', hash: 'hash-none');
    final r3 = await claimPendingForBook(db, bookId: 'plain');
    check('无待认领 ⇒ 空结果（不报错）', r3.total == 0, '$r3');

    // 书不存在
    final r4 = await claimPendingForBook(db, bookId: 'nope');
    check('书不存在 ⇒ 也不报错', r4.total <= 1);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【5】空串指纹 = 无指纹（归一在一处）');
  {
    final db = await _openBookDb();
    // 空串（不是 NULL）—— 老库 / 异常中断可能留下这种值
    await db.insert('book', {
      'id': 'empty-hash',
      'title': 'x',
      'source_format': 'txt',
      'added_at': t1,
      'content_hash': '',
    });
    await db.insert('book_progress_pending', {
      'content_hash': '',
      'chapter_idx': 5,
      'scroll_ratio': 0.0,
      'updated_at': t2,
    });
    final r = await claimPendingForBook(db, bookId: 'empty-hash');
    check('🔴 空串指纹**不参与**认领（否则会按空串匹配到别的书）',
        r.claimed == 0 && r.skippedNoHash == 1, '$r');
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【6】镜像：本地读书 → 交换区（供上传）');
  {
    final db = await _openBookDb();
    await seedBook(db, 'book-1', hash: 'hash-abc');

    await mirrorProgress(db,
        bookId: 'book-1', chapterIdx: 4, scrollRatio: 0.0, updatedAt: t2);
    final rows = await db.query('book_progress_pending');
    check('写入交换区 1 条', rows.length == 1);
    check('  键是**指纹**（不是 book_id）', rows.first['content_hash'] == 'hash-abc');
    check('  chapter_idx = 4', rows.first['chapter_idx'] == 4);

    // 无指纹 ⇒ 静默跳过
    await seedBook(db, 'no-hash', hash: null);
    await mirrorProgress(db,
        bookId: 'no-hash', chapterIdx: 7, scrollRatio: 0.0, updatedAt: t3);
    check('🔴 无指纹的书**静默跳过**（不参与同步 ≠ 报错）',
        await pendingCount(db) == 1, '仍应为 1 条');
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【7】🔴🔴 镜像**不得**冲掉别端更新的进度（否则上传的是旧的）');
  {
    final db = await _openBookDb();
    await seedBook(db, 'book-1', hash: 'hash-abc');
    // 交换区里是别端推来的**新**进度（第 9 章，还没认领）
    await seedPending(db, 'hash-abc', chapter: 9, at: t3);

    // 本地读到第 4 章，但时间戳**更旧**（用户其实是在别端读得更远）
    await mirrorProgress(db,
        bookId: 'book-1', chapterIdx: 4, scrollRatio: 0.0, updatedAt: t2);

    final rows = await db.query('book_progress_pending');
    check(
      '🔴🔴 交换区仍是第 9 章（更旧的本地位**不覆盖**）',
      rows.first['chapter_idx'] == 9,
      '—— 若被覆盖成 4，下一次 push 会把「回到第 4 章」推给所有设备，且**不报错**',
    );

    // 本地确实更新 ⇒ 应覆盖
    // ⚠️ 用**合法**的 ISO8601（本人踩过一次：写成 `t3 + '1'` ⇒ `...000Z1`
    //    **不可解析** ⇒ `isNewer` 恒 false ⇒ 断言假红，看起来像实现坏了）。
    //    📌 判据：**测试数据本身要满足被测函数的格式前提**。
    await mirrorProgress(db,
        bookId: 'book-1', chapterIdx: 15, scrollRatio: 0.0, updatedAt: t4);
    final rows2 = await db.query('book_progress_pending');
    check('本地**更新**时正常覆盖（第 15 章）', rows2.first['chapter_idx'] == 15);
    check('  仍只有 1 条（按指纹唯一）', rows2.length == 1);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【8】`claimAllPending`：一次认领所有「本地已有」的书');
  {
    final db = await _openBookDb();
    // 本地有两本（其中一本没有待认领），交换区有三条（其中一条本地没有这本书）
    await seedBook(db, 'b1', hash: 'h1');
    await seedBook(db, 'b2', hash: 'h2');
    await seedPending(db, 'h1', chapter: 5, at: t2);
    await seedPending(db, 'h2', chapter: 6, at: t2);
    await seedPending(db, 'h3', chapter: 7, at: t2); // 本地没这本书 ⇒ 不该被认领

    final r = await claimAllPending(db);
    check('认领 2 本（本地已有的）', r.claimed == 2, '$r');
    check('  h1 → b1', (await progressOf(db, 'b1'))?['chapter_idx'] == 5);
    check('  h2 → b2', (await progressOf(db, 'b2'))?['chapter_idx'] == 6);
    check(
      '🔴 本地没这本书的那条**保留**（等导入时再认领）',
      await pendingCount(db) == 1,
    );
    final left = await db.query('book_progress_pending');
    check('  且保留的正是 h3', left.first['content_hash'] == 'h3');

    // 幂等：再认领一次什么都不发生
    final r2 = await claimAllPending(db);
    check('重复认领 ⇒ 无操作（幂等）', r2.claimed == 0 && await pendingCount(db) == 1);
    await db.close();
  }

  // ═══════════════════════════════════════════════════════════
  section('【9】🔴 接线：三条线都必须在（缺一条就有静默缺口）');
  {
    final importer = stripComments(readFile('../../app/lib/services/book_importer.dart'));
    final provider = stripComments(readFile('../../app/lib/providers/book_provider.dart'));
    final sync = stripComments(readFile('../../app/lib/services/sync_service.dart'));

    check(
      '🔴 **导入后**认领（`book_importer` 真的**调用**了）',
      importer.contains('await claimPendingForBook(db, bookId: plan.bookId);'),
      '覆盖「书还没导入时那段窗口」· 锁调用点（不是函数名出现）',
    );
    // 🔑 锁**调用点**（`r.claimedBooks = await _claimBookProgress();`）
    //    而不是「方法体里出现了 `claimAllPending`」——
    //    本人踩过一次：断言只查方法名 ⇒ 把调用点改成 `= 0` 后**仍然全绿**
    //    （方法还在、只是没人调它 = 最典型的「有实现、无入口」）。
    //    📌 判据：**接线断言必须锁「调用」，不能锁「定义」**。
    check(
      '🔴🔴 **pull 后**认领（`sync_service` 里真的**调用**了）',
      sync.contains('r.claimedBooks = await _claimBookProgress();'),
      '—— 缺这条：**已导入**的书的进度「永远不生效」，且不报错',
    );
    check('  （并确认它确实读了 `claimAllPending`）',
        sync.contains('final result = await claimAllPending(db);'));
    check(
      '🔴 **读书后**镜像（`book_provider` 真的**调用**了）',
      provider.contains('await mirrorProgress(') &&
          provider.contains('updatedAt: now,'),
      '—— 缺这条：本地进度**永远不上传**· 锁调用点+实参',
    );
    check(
      '🔑 镜像与本地写用的是**同一个时间戳**（否则合并判定会毫秒级漂移）',
      provider.contains('updatedAt: now') && provider.contains("'updated_at': now"),
    );
    check(
      '🔑 认领失败**不阻塞**导入（包在 try/catch 里）',
      importer.contains('claimPendingForBook') &&
          RegExp(r'try \{\s*await claimPendingForBook')
              .hasMatch(importer),
    );
    check(
      '🔑 镜像失败**不影响阅读**（包在 try/catch 里）',
      RegExp(r'try \{\s*await mirrorProgress').hasMatch(provider),
    );
    check(
      '`sync_service` 里认领失败也**不抛**（后台行为）',
      RegExp(r'try \{\s*final result = await claimAllPending').hasMatch(sync),
    );
    check(
      '🔑 `SyncReport` 单列 `claimedBooks`（≠ 交换区写入数）',
      sync.contains('int claimedBooks = 0;'),
    );
  }

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因（这一层全是**静默**错误）：');
    print('   · 认领后没删 pending ⇒ 陈旧进度会复活 · 每次 pull 白比对');
    print('   · 镜像无条件覆盖 ⇒ 把别端更新的进度冲掉，再上传旧的');
    print('   · 少了「pull 后认领」⇒ 已导入的书，别端进度永远不生效');
    print('   · 少了「读书后镜像」⇒ 本地进度永远不上传');
    print('   · 空指纹当成有效指纹 ⇒ 可能把用户带到**错的书**');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
