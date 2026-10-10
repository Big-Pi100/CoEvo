// CoEvo · 生词本（`user_word`）+ 查词记录（`lookup_event`）验收
//
// 跑法：cd scripts/query_verify && dart run bin/verify_user_word.dart
//
// 验证目标：
//   · `UserWordRepository` 的三种写入分支（新增 / 已存在 / **复活**）
//   · 🔴 **软删语义**（与 `bookmark` 的硬删相反）：`deleted=1` 后数据仍在
//   · 🔴 **没有 200 上限**（2026-10-01 取消）：连加超过 250 个也全部成功
//     ——历史上这里验的是「第 201 个返回 limitReached」，现已**反向**验证
//   · 🔑 **`source_sentence` 取首次**，不被后续查词覆盖
//   · `lookup_event`：命中写 word_id、**未命中留 NULL**（白哥定「都记」）
//   · 时间列 UTC ISO8601 带 `Z`（复用 `parseUserDbUtc`，无 `Z` 会抛错）

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/user_db.dart';
import '../../../app/lib/services/user_word_repository.dart';

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

void eq(String label, Object? actual, Object? expected) => check(
    label, actual == expected, '实得 $actual · 期望 $expected');

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final dir = await Directory.systemTemp.createTemp('coevo_uw_');
  final path = '${dir.path}/user.db';
  final schema =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  final db = await openUserDb(factory: factory, path: path, schemaSql: schema);
  final repo = UserWordRepository(db);

  print('\n【1】新增（第一次查词 → 自动进生词本，v1 §八/§九）');
  eq('全新词 → added',
      await repo.add('w000001', 'abandon',
          sentence: 'He decided to abandon the plan.', articleId: 7),
      AddWordResult.added);
  eq('生词数 = 1', await repo.count(), 1);
  final uw = await repo.findByWordId('w000001');
  check('spelling 已写入', uw?.spelling == 'abandon');
  check('source_sentence 已写入',
      uw?.sourceSentence == 'He decided to abandon the plan.');
  check('source_article_id 已写入', uw?.sourceArticleId == 7);
  check('deleted = false（默认）', uw?.deleted == false);
  check('pending_push = true（默认）', uw?.pendingPush == true);
  check('added_at 带 Z（UTC ISO8601 硬约束）',
      (uw?.addedAt.isUtc ?? false), '${uw?.addedAt}');

  print('\n【2】幂等：同一词再查一次');
  eq('已存在 → alreadyExists', await repo.add('w000001', 'abandon'),
      AddWordResult.alreadyExists);
  eq('生词数仍是 1（未重复插入）', await repo.count(), 1);
  final uw2 = await repo.findByWordId('w000001');
  check('🔑 added_at **未被刷新**（表达「第一次收它」）',
      uw2?.addedAt == uw?.addedAt);
  check('🔑 source_sentence **未被覆盖**（取首次）',
      uw2?.sourceSentence == 'He decided to abandon the plan.');

  print('\n【3】🔴 软删（与 bookmark 的硬删相反）');
  check('移出成功', await repo.remove('w000001'));
  eq('生词数变 0（deleted=0 口径）', await repo.count(), 0);
  final afterRemove = await repo.findByWordId('w000001');
  check('🔴 **数据仍在**（不是 DELETE）', afterRemove != null);
  check('deleted = true', afterRemove?.deleted == true);
  check('🔴 source_sentence 也还在（学习数据保留）',
      afterRemove?.sourceSentence == 'He decided to abandon the plan.');
  eq('list() 不含已移出的', (await repo.list()).length, 0);
  eq('listAll() 仍含（1 条）', (await repo.listAll()).length, 1);
  check('重复 remove 返回 false（幂等）', !await repo.remove('w000001'));

  print('\n【3b】🔴 `updated_at` 在 UPDATE 后必须是**真时间串**，不是 SQL 文本');
  // 本项由**首跑抓到真 bug** 而来：`remove()` 曾把 `strftime(...)` 当**值**传给
  // `update()` 的 map → 字面量被写进列 → 读取时 `parseUserDbUtc` 抛 FormatException。
  // ⚠️ 写入时不报错、只在读取时炸（静默污染、延迟暴露）。
  // → 这里**直接查原始列值**（不经 `_fromRow`，否则异常会中断脚本而不是给出可读的失败）
  final rawUpdatedAt = (await db.rawQuery(
          "SELECT updated_at FROM user_word WHERE word_id = 'w000001'"))
      .first['updated_at'] as String;
  check('updated_at 不以 strftime( 开头（未被当成字面量写入）',
      !rawUpdatedAt.startsWith('strftime'), rawUpdatedAt);
  check('updated_at 是合法 UTC ISO8601（带 Z）',
      parseUserDbUtcSafe(rawUpdatedAt), rawUpdatedAt);

  print('\n【4】🔑 复活（白哥定 Q3-A：删除是「先不学」，不是「永远别出现」）');
  eq('曾移出的词再查 → revived',
      await repo.add('w000001', 'abandon', sentence: '另一句不该覆盖首次'), AddWordResult.revived);
  eq('生词数回到 1', await repo.count(), 1);
  final revived = await repo.findByWordId('w000001');
  check('deleted 已翻回 false', revived?.deleted == false);
  check('🔴 added_at 仍是**最初那次**（复活不改「第一次收」）',
      revived?.addedAt == uw?.addedAt);
  check('🔑 source_sentence **不被新句子覆盖**（仍是最早那句）',
      revived?.sourceSentence == 'He decided to abandon the plan.');

  print('\n【5】🔴 **没有 200 上限**（2026-10-01 取消）—— 加多少都进');
  // 先清空，再灌到**超过历史上限**（250 > 200）
  for (final w in await repo.listAll()) {
    await repo.remove(w.wordId);
  }
  eq('清空后 count = 0', await repo.count(), 0);
  var allAdded = true;
  for (var i = 0; i < 250; i++) {
    final r = await repo.add('w1${i.toString().padLeft(5, '0')}', 'word$i');
    if (r != AddWordResult.added) {
      check('第 $i 个应能加入（无上限）', false, '$r');
      allAdded = false;
      break;
    }
  }
  check('🔴 连加 250 个全部 added（历史上第 201 个会 limitReached）', allAdded);
  eq('生词数 = 250（**不再有 200 这个天花板**）', await repo.count(), 250);
  eq('第 251 个仍能加入（无上限）',
      await repo.add('w199999', 'overflow'), AddWordResult.added);
  eq('生词数 = 251', await repo.count(), 251);

  print('\n【6】🔑 软删仍只影响计数；被移出的词再查 → **复活**（与上限无关）');
  final beforeRemove = await repo.count();
  final victim = (await repo.list()).first.wordId;
  await repo.remove(victim);
  eq('移出一个后 count 减 1（未移出的才算）', await repo.count(),
      beforeRemove - 1);
  eq('再查被移出的词 → revived（不是新增）',
      await repo.add(victim, 'restored'), AddWordResult.revived);
  eq('复活后 count 回到原值', await repo.count(), beforeRemove);

  print('\n【7】lookup_event：命中与未命中**都记**（白哥定 Q2）');
  await repo.recordLookup(
      wordId: 'w000001', spelling: 'abandon', articleId: 7, sentence: 'S1');
  await repo.recordLookup(
      wordId: 'w000001', spelling: 'abandon', articleId: 9, sentence: 'S2');
  await repo.recordLookup(spelling: 'nonexistentword'); // 🔴 未命中：word_id 留 NULL
  eq('共 3 条查词记录', await repo.lookupCount(), 3);
  final first = await repo.firstLookupOf('w000001');
  check('首查语境取到最早那条（S1）', first?.sentence == 'S1', '${first?.sentence}');
  eq('该词共 2 条记录（同词不同句 → 不去重）',
      (await repo.lookupsOf('w000001')).length, 2);
  final missRows = await db
      .rawQuery('SELECT * FROM lookup_event WHERE word_id IS NULL');
  eq('🔴 未命中那条 word_id 为 NULL', missRows.length, 1);
  check('未命中那条 spelling 仍有值',
      missRows.first['spelling'] == 'nonexistentword');
  check('lookup_event 有 looked_up_at（带 Z）',
      parseUserDbUtcSafe(missRows.first['looked_up_at'] as String));

  print('\n【8】🔑 source_sentence 与 lookup_event 首条**一致**（防两处漂移）');
  // ⚠️ §5/§6 把表灌到了 251 条 → 这里先腾空，让后续断言从**干净前提**开始。
  //    （不再有「上限挡路」那类问题 —— 200 上限已于 2026-10-01 取消；
  //     但**显式腾空**仍是对的：让每小节的前提自明，不依赖上一节的副作用。）
  for (final w in await repo.listAll()) {
    await repo.remove(w.wordId);
  }
  eq('腾空后 count = 0（前提）', await repo.count(), 0);
  // 造一个新词，先记查词再入生词本，验证两者对齐
  await repo.recordLookup(
      wordId: 'w000777', spelling: 'glimmer', sentence: 'A glimmer of hope.');
  await repo.recordLookup(
      wordId: 'w000777', spelling: 'glimmer', sentence: '不该被采用的那句');
  final firstOf777 = await repo.firstLookupOf('w000777');
  final r777 = await repo.add('w000777', 'glimmer',
      sentence: firstOf777?.sentence, articleId: firstOf777?.articleId);
  eq('（前提）新词能加入', r777, AddWordResult.added);
  final uw777 = await repo.findByWordId('w000777');
  check('user_word.source_sentence == lookup_event 最早那条的 sentence',
      uw777?.sourceSentence == 'A glimmer of hope.', '${uw777?.sourceSentence}');
  check('🔴 且**不是**后面那句（没被最后一次覆盖）',
      uw777?.sourceSentence != '不该被采用的那句');

  print('\n【9】表约束与列规格（防有人改回去）');
  final uwSql = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name='user_word'"))
      .first['sql'] as String;
  check('user_word.word_id 是 TEXT（v1 原文写 INTEGER，须已适配）',
      RegExp(r'word_id\s+TEXT').hasMatch(uwSql));
  check('user_word 有 UNIQUE(word_id)（按 lemma 唯一）',
      uwSql.contains('UNIQUE (word_id)'));
  check('user_word 用软删（有 deleted 列）', uwSql.contains('deleted'));
  check('deleted 有 CHECK (IN (0,1))',
      RegExp(r'deleted[^,]*CHECK \(deleted IN \(0, 1\)\)').hasMatch(uwSql));
  check('🔴 表定义里没有 datetime(\'now\')（现库硬约束：时间列须带 Z）',
      !uwSql.contains("datetime('now')"));
  final leSql = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name='lookup_event'"))
      .first['sql'] as String;
  check('lookup_event.word_id **可空**（未命中留痕的前提）',
      RegExp(r'word_id\s+TEXT\s*,').hasMatch(leSql));
  // 🔴🆕 2026-10-10：**口径已变** —— 本条原先断言「无 pending_push（纯日志，照 v1）」。
  //
  // 为什么改：`lookup_event` 已**纳入跨设备同步**（审计报告 §五 P0）—— 它驱动成就
  //   `lookupCount`（查词总次数）。不同步 ⇒ 换设备后查词次数归零、成就要重查够次数才重新亮。
  //   ⇒ 现在它**有** `pending_push`（+ `uid` 跨设备身份）。
  //
  // ⚠️ 这正是「**断言会保护错误**」的教科书例子：旧断言把「v1 的取舍」钉死了，
  //    而业务需要已经变了 ⇒ 改对了反而变红。
  //    📌 判据：**「判据已记」≠「已执行」** —— 口径变更时必须回来改断言（而不是绕开它）。
  // 🔑 顺带把 `uid` 也锁上（同步的跨设备身份，漏了它就推不出去）。
  check('🔴 lookup_event **有** `pending_push`（v10 起纳入同步 —— 口径已变，别再改回去）',
      leSql.contains('pending_push'));
  check('🔴 lookup_event **有** `uid`（跨设备身份；自增 id 在两台设备上必撞）',
      leSql.contains('uid'));
  check('🔴 lookup_event.uid 有 UNIQUE 索引（`INSERT OR IGNORE` 幂等的前提）',
      schema.contains('UNIQUE INDEX IF NOT EXISTS idx_le_uid'));

  print('\n【10】schema 里不得出现 PRAGMA（Android 上会炸 · 已踩过）');
  // 🔴🔴 **必须先滤注释行** —— schema 里有大段注释**解释「为什么不能用 PRAGMA」**，
  //    直接搜文本会把那些说明算成「违规」→ **假红**。
  //    （首跑就是栽在这里：47 过 / 1 红，红的那条其实是断言写错了。）
  // 🔑 这是本项目的老坑（`verifiable-core-logic` skill 有专条）：
  //    **扫源码文本的断言必须先滤注释行**。
  final codeOnly = schema
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n');
  check('schema 无 PRAGMA（连接级设置归 onConfigure）',
      !codeOnly.contains('PRAGMA'));
  check('（对照）说明「为何不能用 PRAGMA」的注释确实存在（证明上面那条不是空过）',
      schema.contains('PRAGMA'));

  await db.close();
  await dir.delete(recursive: true);

  print('\n${'═' * 62}');
  if (_failures.isEmpty) {
    print('通过 $_pass 项，失败 0 项');
    print('\n✅ 生词本三种写入分支 + 软删 + **无 200 上限** + 查词记录均符合设计');
  } else {
    print('通过 $_pass 项，**失败 ${_failures.length} 项**');
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exitCode = 1;
  }
}

/// 只在「能解析」时返回 true —— 用于断言时间串合法（不抛错）。
bool parseUserDbUtcSafe(String raw) {
  try {
    return raw.endsWith('Z') && DateTime.parse(raw).isUtc;
  } catch (_) {
    return false;
  }
}
