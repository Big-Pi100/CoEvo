// CoEvo · 「word_id → 真拼写」解析器验收（真 sqlite 内存库）
//
// 跑：cd scripts/query_verify && dart run bin/verify_review_spelling.dart
// 🔴 退出码：0 = 全过，1 = 有失败（**直读，别接 `| tail`**）。
//
// # 为什么需要它（2026-10-09 线上缺陷）
//
// 复习列表的标题读 `card_review_state.spelling`，而同步 pull 会为每个
// `word_id` 重算拼写并**整行覆盖**写回（`INSERT OR REPLACE`）。
// 原实现查不到拼写时 **`return wordId` 占位** ⇒ 那个占位被**持久化** ⇒
// 用户在列表里看到 `w000129` / `hl:<uuid>` / `ext:fixtures`。
//
// 🔴 本脚本最重要的一条是【4】的反向断言：
//    **解析不出来必须返回 `null`，绝不能返回 `word_id`** ——
//    少了它，缺陷会以「看着能跑」的样子回来（那正是它当初能上线的原因）。
//
// # 用的是**真库**
// 建 `user.db` 的真 schema（`assets/sql/user_db_schema.sql`）⇒
// 走的是真表、真约束（`NOT NULL` / `COLLATE NOCASE`），
// 而不是「手搭一张简化表」——后者会把「列名写错」这类问题放过去。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/review_spelling.dart';
import '../../../app/lib/services/user_db.dart';

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

void section(String title) {
  print('');
  print('─' * 74);
  print(title);
  print('─' * 74);
}

/// ⚠️ 必须 `singleInstance: false` —— 否则每个「新库」其实是**同一个**内存库，
///    场景之间互相污染（同 `verify_sync_service` 的说明）。
Future<Database> _openUserDb() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await executeSqlScript(
      db, File('../../app/assets/sql/user_db_schema.sql').readAsStringSync());
  return db;
}

Future<void> _insHighlight(Database db, String uuid, String text) async {
  final now = DateTime.now().toUtc().toIso8601String();
  await db.insert('highlight', {
    'id': uuid,
    'source_type': 'article',
    'source_id': '1',
    'start_offset': 0,
    'end_offset': text.length,
    'text': text,
    'created_at': now,
    'updated_at': now,
  });
}

Future<void> _insUserWord(Database db, String wordId, String spelling) =>
    db.insert('user_word', {'word_id': wordId, 'spelling': spelling});

Future<void> _insState(Database db, String wordId, String spelling) =>
    db.insert('card_review_state', {
      'word_id': wordId,
      'spelling': spelling,
      'next_review_at': DateTime.now().toUtc().toIso8601String(),
    });

Future<String?> _spellingOf(Database db, String wordId) async {
  final rows = await db.query('card_review_state',
      columns: ['spelling'], where: 'word_id = ?', whereArgs: [wordId]);
  return rows.isEmpty ? null : rows.first['spelling'] as String?;
}

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  print('#' * 74);
  print('# 复习列表「拼写」解析器 —— word_id → 真拼写');
  print('#' * 74);

  // ══════════════════════════════════════════════════════════════════════
  section('【1】`isWordIdShaped` —— 什么算「ID 形态」（自愈的候选筛子）');
  // ══════════════════════════════════════════════════════════════════════
  {
    final f = ReviewSpellingResolver.isWordIdShaped;
    check('`ext:fixtures` ⇒ ID', f('ext:fixtures'));
    check('`hl:<uuid>` ⇒ ID', f('hl:8613b24d-deff-4284-bc70-b5bfe2efb6b6'));
    check('`w000129` ⇒ ID', f('w000129'));
    check('真拼写 ⇒ **不是** ID', !f('fixtures'));
    check('含数字的真拼写 ⇒ 不是 ID', !f('utf8') && !f('mp3') && !f('b2b'));
    check('🔴 `w` + 非 6 位数字 ⇒ 不是 ID（宁可漏判，不可误判）',
        !f('w2') && !f('w12345') && !f('w1234567'), '避免把真拼写当脏值去「修」');
    check('空串 ⇒ 不是 ID 形态（由 `_usable` 另行排除）', !f(''));
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【2】`ext:<拼写>` —— id 自带拼写，拆前缀即得（零查询）');
  // ══════════════════════════════════════════════════════════════════════
  {
    final db = await _openUserDb();
    final r = ReviewSpellingResolver(db);
    check('`ext:fixtures` → `fixtures`',
        await r.resolve('ext:fixtures') == 'fixtures');
    check('大小写原样保留（`ext:iPhone` → `iPhone`）',
        await r.resolve('ext:iPhone') == 'iPhone');
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【3】`hl:<uuid>` —— 划线原文在**同一个库**，直接取');
  // ══════════════════════════════════════════════════════════════════════
  {
    final db = await _openUserDb();
    const uuid = '8613b24d-deff-4284-bc70-b5bfe2efb6b6';
    await _insHighlight(db, uuid, 'The quick brown fox jumps over the lazy dog.');
    final r = ReviewSpellingResolver(db);
    final got = await r.resolve('hl:$uuid');
    check('取出划线原文', got == 'The quick brown fox jumps over the lazy dog.',
        'got=${got ?? "null"}');

    // 划线行不存在 ⇒ **不能**退化成 uuid
    final missing = await r.resolve('hl:00000000-0000-4000-8000-000000000000');
    check('🔴 划线行不存在 ⇒ 返回 null（**不是** `hl:<uuid>`）',
        missing == null, 'got=${missing ?? "null"}');
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【4】🔴🔴 核心反向断言：解析不出来**必须返回 null**，不能返回 word_id');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 这条就是本轮的根因：旧实现 `return wordId` ⇒ 占位被持久化为列表标题。
  {
    final db = await _openUserDb();
    final r = ReviewSpellingResolver(db);
    final got = await r.resolve('w009999');
    check('正式词、无任何本地信息、词库查询未注入 ⇒ **null**',
        got == null, 'got=${got ?? "null"}');

    final r2 = ReviewSpellingResolver(db,
        wordLookup: (id) async => null); // 注入了但查不到
    final got2 = await r2.resolve('w009999');
    check('注入了词库查询但查不到 ⇒ 仍 **null**', got2 == null,
        'got=${got2 ?? "null"}');

    check('空 wordId ⇒ null', await r.resolve('') == null);
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【5】等级顺序：本地状态[排除脏值] → 生词本 → …（**不自固化**）');
  // ══════════════════════════════════════════════════════════════════════
  {
    final db = await _openUserDb();

    // ① 本地 state 就是好值 ⇒ 直接采信
    await _insState(db, 'w000100', 'genuine');
    final r = ReviewSpellingResolver(db);
    check('state 是好值 ⇒ 直接返回', await r.resolve('w000100') == 'genuine');

    // ② 本地 state 是**脏值** ⇒ 必须跳过它、继续往下找（关键：不自固化）
    await _insState(db, 'w000129', 'w000129'); // 脏
    await _insUserWord(db, 'w000129', 'example'); // 生词本里有真值
    final got = await r.resolve('w000129');
    check('🔴 state 是 ID 形态 ⇒ 跳过它，用生词本的真拼写',
        got == 'example', 'got=${got ?? "null"}（返回 w000129 即「自我固化」）');

    // ③ 两处都是脏值 ⇒ 继续往下（此处无 hl:/ext:/词库）⇒ null
    await _insState(db, 'w000130', 'w000130');
    await _insUserWord(db, 'w000130', 'w000130');
    check('🔴 两处都是脏值 ⇒ null（**不返回脏值当作答案**）',
        await r.resolve('w000130') == null);
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【6】注入的词库查询（第 ⑤ 级）真的被用上');
  // ══════════════════════════════════════════════════════════════════════
  {
    final db = await _openUserDb();
    var calls = 0;
    final r = ReviewSpellingResolver(db, wordLookup: (id) async {
      calls++;
      return id == 'w000777' ? 'solar' : null;
    });
    check('命中 ⇒ 返回词库给的拼写', await r.resolve('w000777') == 'solar');

    // 词库查询抛异常 ⇒ 不能崩，且**仍不写坏**（返回 null）
    final r2 = ReviewSpellingResolver(db,
        wordLookup: (id) async => throw StateError('词库未就绪'));
    check('🔴 词库查询抛异常 ⇒ 吞掉并返回 null（不崩、不写坏）',
        await r2.resolve('w000777') == null);

    check('词库查询只在真需要时才调（前面几级命中就不调）', calls == 1,
        'calls=$calls');
    await db.close();
  }

  // ══════════════════════════════════════════════════════════════════════
  section('【7】`repairAll`：修好已脏的行 + 幂等 + 不动正确的行');
  // ══════════════════════════════════════════════════════════════════════
  {
    final db = await _openUserDb();
    const uuid = '11111111-2222-4333-8444-555555555555';

    await _insHighlight(db, uuid, 'A sentence the user highlighted.');
    await _insUserWord(db, 'w000129', 'example');
    await _insState(db, 'hl:$uuid', 'hl:$uuid'); // 脏
    await _insState(db, 'w000129', 'w000129'); // 脏
    await _insState(db, 'w000200', 'genuine'); // 已正确
    await _insState(db, 'w009999', 'w009999'); // 脏，但**修不了**（无信息来源）

    final r = ReviewSpellingResolver(db);
    final fixed = await r.repairAll();
    check('修好 2 行（划线卡 + 生词本可救的那条）', fixed == 2, 'fixed=$fixed');

    check('划线卡 → 划线原文',
        await _spellingOf(db, 'hl:$uuid') == 'A sentence the user highlighted.');
    check('正式词 → 生词本的拼写', await _spellingOf(db, 'w000129') == 'example');
    check('已正确的行**未被改动**', await _spellingOf(db, 'w000200') == 'genuine');
    check('🔴 无信息来源的行 ⇒ **保持原样**（留给下次），不被写成别的值',
        await _spellingOf(db, 'w009999') == 'w009999');

    final again = await r.repairAll();
    check('🔑 幂等：第二次修 0 行', again == 0, 'again=$again');

    // ext: 也能被修（自带拼写）
    await _insState(db, 'ext:fixtures', 'ext:fixtures');
    final n3 = await r.repairAll();
    check('`ext:` 脏行也能修（拆前缀）',
        n3 == 1 && await _spellingOf(db, 'ext:fixtures') == 'fixtures', 'n3=$n3');
    await db.close();
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
    print('🔑 最可能的原因：');
    print('   · `resolve` 在某级返回了 `word_id` 而不是 `null` ⇒ 缺陷会静默回来');
    print('   · `isWordIdShaped` 判据太松/太紧（误判真拼写 / 漏判脏值）');
    print('   · 等级顺序被改（本地脏值被采信 ⇒ 自我固化）');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exit(1);
}
