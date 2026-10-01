// CoEvo · 词库外词卡缓存（`external_word_cache`）验收 —— **跑真库**
//
// 跑法：cd scripts/query_verify && dart run bin/verify_external_word_cache.dart
//
// # 验什么
// · 读写、**覆盖**语义（与 `user_word` 的幂等**相反**）、硬删
// · 🔴 **拼写归一化** —— 存 `Brainstorm` 查 `brainstorm` 必须命中
//   （不归一化 → 缓存明明写了却读不到 → 每次都重新联网，**静默浪费**）
// · 时间列带 `Z`（本库硬约束 1）
// · 表结构（防有人改回去）

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/bookmark_repository.dart' show parseUserDbUtc;
import '../../../app/lib/services/external_word_cache_repository.dart';
import '../../../app/lib/services/external_word_id.dart';
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

void eq(String label, Object? actual, Object? expected) => check(label,
    actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

/// 一份「转换后」的缓存内容（形状与 `word.db.card.content` 一致）。
const String _contentA = '{"front":"brainstorm","ipa":"/ˈbreɪnstɔːm/",'
    '"entry_type":"word","sections":[{"type":"definition","order":1,'
    '"pos":"[n]","en":"a sudden clever idea","zh":"突然想到的好主意"}]}';
const String _contentB = '{"front":"brainstorm","ipa":"/x/","entry_type":"word",'
    '"sections":[{"type":"definition","order":1,"pos":"[n]","en":"v2","zh":"第二版"}]}';

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final dir = await Directory.systemTemp.createTemp('coevo_ewc_');
  final path = '${dir.path}/user.db';
  final schema =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();

  final db = await openUserDb(factory: factory, path: path, schemaSql: schema);
  final repo = ExternalWordCacheRepository(db);

  section('【1】写 / 读 / 存在性');
  eq('初始为空', await repo.count(), 0);
  check('初始 contentOf → null', await repo.contentOf('brainstorm') == null);

  await repo.put('brainstorm', _contentA);
  eq('写完 count = 1', await repo.count(), 1);
  eq('读回内容一致', await repo.contentOf('brainstorm'), _contentA);
  check('contains → true', await repo.contains('brainstorm'));

  section('【2】🔴 归一化（不归一化 = 缓存写了却读不到）');
  eq('🔴 大写查询命中同一行', await repo.contentOf('Brainstorm'), _contentA);
  eq('🔴 前后空白也能命中', await repo.contentOf('  brainstorm  '), _contentA);
  eq('归一化后仍是 1 行（没写出第二行）', await repo.count(), 1);
  await repo.put('BRAINSTORM', _contentB);
  eq('🔴 大写写入 → 覆盖同一行（仍 1 行）', await repo.count(), 1);

  section('【3】🔴 覆盖语义（与 user_word 的幂等**相反**）');
  eq('第二次 put → 内容被替换成最新一份', await repo.contentOf('brainstorm'),
      _contentB);
  final e = await repo.find('brainstorm');
  check('find 能取到元数据', e != null);
  check('🔴 时间列带 Z（本库硬约束 1，无 Z 会被本地时区静默解释）',
      parseUserDbUtc(e!.fetchedAt.toIso8601String().replaceFirst('+00:00', 'Z'))
          .isUtc);
  check('pending_push 默认 true（同 bookmark 形态）', e.pendingPush);
  eq('find 的拼写是归一化后的', e.spelling, 'brainstorm');

  section('【4】多条与遍历');
  await repo.put('traffic jam', _contentA);
  await repo.put('e-mail', _contentA);
  eq('count = 3', await repo.count(), 3);
  final all = await repo.allSpellings();
  eq('allSpellings 条数', all.length, 3);
  check('含 `traffic jam`（内部空格保留、没被压掉）', all.contains('traffic jam'));
  check('含 `e-mail`（连字符词不被破坏）', all.contains('e-mail'));

  section('【5】硬删（缓存可再生 —— 与 user_word 的软删相反）');
  check('remove 返回 true（真的删了）', await repo.remove('e-mail'));
  eq('count = 2', await repo.count(), 2);
  check('再删同一个 → false（幂等）', !(await repo.remove('e-mail')));
  eq('已删的读不到', await repo.contentOf('e-mail'), null);

  section('【6】🔑 与 ext: 合成 id 配合（**收敛的桥**）');
  //    ⚠️ 注意 brainstorm 已被【3】覆盖成 `_contentB`
  for (final pair in [('brainstorm', _contentB), ('traffic jam', _contentA)]) {
    final sp = pair.$1;
    final id = externalWordId(sp);
    check('合成 id 前缀正确：$id', isExternalWordId(id));
    eq('从合成 id 解析回拼写 → 能查到缓存（收敛就靠这条）',
        await repo.contentOf(externalSpellingOf(id)!), pair.$2);
  }

  section('【7】表结构（防有人改回去）');
  final ti = await db.rawQuery('PRAGMA table_info(external_word_cache)');
  final cols = {for (final r in ti) r['name'] as String: r};
  check('有 external_word_cache 表且列齐全',
      const {'id', 'spelling', 'card_content', 'fetched_at', 'pending_push'}
          .difference(cols.keys.toSet())
          .isEmpty,
      '${cols.keys.toList()}');
  check('spelling NOT NULL', (cols['spelling']!['notnull'] as int) == 1);
  check('card_content NOT NULL', (cols['card_content']!['notnull'] as int) == 1);

  final sql = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name='external_word_cache'"))
      .first['sql'] as String;
  check('🔴 有 UNIQUE(spelling)（一词一行）', sql.contains('UNIQUE'));
  check('🔴 有 COLLATE NOCASE（大写折叠）',
      sql.toUpperCase().contains('COLLATE NOCASE'));
  check('🔴 时间列用 strftime(...Z)（不是 datetime(\'now\')）',
      sql.contains("strftime('%Y-%m-%dT%H:%M:%SZ'") &&
          !sql.contains("datetime('now')"));
  check('pending_push 有 CHECK (IN (0,1))',
      sql.replaceAll(' ', '').contains('CHECK(pending_pushIN(0,1))'));

  await db.close();

  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
  }
  print('═' * 72);
  exit(_failures.isEmpty ? 0 : 1);
}
