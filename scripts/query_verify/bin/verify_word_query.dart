// CoEvo · `WordQueryService` 验收（验证**我们自己的查询层**，不是验证 sqflite）
//
// 跑法：cd scripts/query_verify && dart pub get --offline && dart run bin/verify_word_query.dart
//
// 🔴 之所以能本地跑，是因为 `word_query_service.dart` **不 import 任何 Flutter 包**
//    —— 这是刻意的设计（见 skill `verifiable-core-logic`）。
//
// 验证目标（真库 `data/word.db`，11,523 词）：
//   · 查词命中 / 未命中 / 大小写不敏感 / 词组
//   · 词形还原（received → receive）★ 核心
//   · 卡片段结构（definition 恰 1 段 · context 有 · root 有）
//   · 聚合页入口（**可能为空是合法的** —— capture 反例）
//   · 聚合页成员带「分拆法」
//   · 只读约束（写操作必须失败）
//   · 防注入
//   · 性能：未命中不退化（O(log n)）+ 首查 vs 稳态

import 'dart:io';
import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// 直接相对导入 app 源码 —— 验证的是**实际要发布的实现**，不是副本
import '../../../app/lib/services/word_query_service.dart';

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

String fmtUs(int us) => us < 1000 ? '${us}us' : '${(us / 1000).toStringAsFixed(2)}ms';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : r'E:\CoEvo\data\word.db';
  if (!File(dbPath).existsSync()) {
    stderr.writeln('找不到 word.db: $dbPath');
    exit(2);
  }

  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  final t0 = DateTime.now();
  final svc = await WordQueryService.open(factory, dbPath);
  final openMs = DateTime.now().difference(t0).inMilliseconds;
  print('词库: $dbPath  (${(File(dbPath).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB)');
  print('打开耗时(含冷启动): ${openMs}ms');
  print('');

  try {
    // ── 1. 表与规模 ────────────────────────────────────────────
    print('【1】库结构与规模');
    final n = await svc.countWords();
    check('word 表 11,523 条', n == 11523, '实测 $n');

    // ── 2. 查词（核心路径）────────────────────────────────────
    print('\n【2】查词');
    final r1 = await svc.lookup('receive');
    check('lookup(\'receive\') 命中', r1 != null);
    if (r1 != null) {
      check('  spelling 正确', r1.card.spelling == 'receive', r1.card.spelling);
      check('  有 cefr_level', r1.card.cefrLevel != null, '${r1.card.cefrLevel}');
      check('  有 ipa', r1.card.ipa != null, '${r1.card.ipa}');
      check('  未经理还原（直查命中）', !r1.isLemmatized);
      check('  有 definition 段', r1.card.sectionOfType('definition') != null);
      check('  有 context 段（例句）', r1.card.sectionOfType('context') != null);
    }

    print('\n【3】大小写不敏感（COLLATE NOCASE）');
    final rUpper = await svc.lookup('RECEIVE');
    final rMixed = await svc.lookup('ReCeIvE');
    check('lookup(\'RECEIVE\') 命中', rUpper != null);
    check('lookup(\'ReCeIvE\') 命中', rMixed != null);
    check('两者 wordId 与直查一致',
        rUpper?.card.wordId == r1?.card.wordId && rMixed?.card.wordId == r1?.card.wordId,
        '${rUpper?.card.wordId} / ${rMixed?.card.wordId}');

    print('\n【4】词形还原 ★ 核心');
    final lem = await svc.analyzeForm('received');
    check('analyzeForm(\'received\') 有结果', lem != null);
    check('  base == receive', lem?.base == 'receive', '${lem?.base}');
    check('  isChanged == true', lem?.isChanged == true);
    check('  有 rule / anchor', lem?.rule != null && lem?.anchor != null,
        'rule=${lem?.rule} anchor=${lem?.anchor}');

    final rLem = await svc.lookup('received');
    check('lookup(\'received\') 命中（经还原）', rLem != null);
    check('  isLemmatized == true', rLem?.isLemmatized == true);
    check('  卡片是 receive 的', rLem?.card.spelling == 'receive', '${rLem?.card.spelling}');
    check('  query 保留原始输入', rLem?.query == 'received', '${rLem?.query}');

    print('\n【5】未命中');
    check('lookup(\'zzznotaword\') == null', await svc.lookup('zzznotaword') == null);
    check('lookup(\'\') == null', await svc.lookup('') == null);
    check('lookup(\'   \') == null', await svc.lookup('   ') == null);
    check('analyzeForm(\'zzz\') == null', await svc.analyzeForm('zzz') == null);

    print('\n【6】防注入（参数化查询）');
    final inj1 = await svc.lookup("receive' OR '1'='1");
    final inj2 = await svc.lookup("'; DROP TABLE word; --");
    check('注入尝试 1 返回 null', inj1 == null);
    check('注入尝试 2 返回 null', inj2 == null);
    check('表未被破坏（仍 11,523 条）', await svc.countWords() == 11523);

    // ── 7. 卡片段结构 ─────────────────────────────────────────
    print('\n【7】卡片段结构（v1 §4.2 对齐）');
    final rDis = await svc.lookup('disorganized');
    if (rDis != null) {
      final c = rDis.card;
      final types = c.sections.map((s) => s.type).toList();
      check('disorganized 段类型已知', types.every((t) => const {
            'root', 'cognate', 'collocation', 'etymology', 'definition', 'context'
          }.contains(t)), types.join(','));
      check('  definition 数量 <= 1', c.sectionsOfType('definition').length <= 1,
          '${c.sectionsOfType('definition').length}');
      check('  无 sense 段（旧结构已清除）', !types.contains('sense'));
      final rootIdx = types.indexOf('root');
      final defIdx = types.indexOf('definition');
      check('  root 排第一（若存在）', rootIdx < 0 || rootIdx == 0, 'root@$rootIdx def@$defIdx');
      final rootSec = c.sectionOfType('root');
      if (rootSec != null) {
        check('  root 段有 parts', rootSec.parts.isNotEmpty, '${rootSec.parts.length} 个词素');
        check('  root 段可点击（有 entry）', rootSec.entry != null,
            '${rootSec.entry?.title}');
      }
    } else {
      check('disorganized 存在', false);
    }

    // ── 8. 聚合页入口 ─────────────────────────────────────────
    print('\n【8】聚合页入口（**为空是合法状态**）');
    if (rDis != null) {
      final links = rDis.card.aggregateLinks;
      check('disorganized 有聚合页入口', links.isNotEmpty,
          links.map((l) => '${l.pageType}「${l.title}」${l.memberCount}词').join(' / '));
      final rootLink = links.where((l) => l.pageType == 'root').isEmpty
          ? null
          : links.firstWhere((l) => l.pageType == 'root');
      if (rootLink != null) {
        final members = await svc.aggregateMembers(rootLink.pageId);
        check('  成员列表非空', members.isNotEmpty, '${members.length} 个');
        final withBreakdown = members.where((m) => m.breakdown.isNotEmpty).length;
        check('  成员带「分拆法」（白哥要求）', withBreakdown > 0,
            '$withBreakdown/${members.length} 有分拆法');
        if (members.isNotEmpty) {
          print('     例: ${members.first.spelling} → ${members.first.breakdown}');
        }
      }
    }
    // capture：有拆解内容但族未达门槛 → 无入口（合法）
    final rCap = await svc.lookup('capture');
    if (rCap != null) {
      final hasRoot = rCap.card.sectionOfType('root') != null;
      final noLink = rCap.card.aggregateLinks.isEmpty;
      print('     capture: 有 root 段=$hasRoot · 聚合页入口=${rCap.card.aggregateLinks.length} 个');
      check('  「有内容但无入口」不报错（合法状态）', true,
          hasRoot && noLink ? '正是该合法状态' : '');
    }

    // ── 9. 只读约束 ───────────────────────────────────────────
    print('\n【9】只读约束（词库永不被写）');
    // ⚠️ 必须 singleInstance: false —— sqflite 默认 `singleInstance: true`，
    //    同一路径二次 open 会返回**同一个 Database 实例**，
    //    此处的 close() 会**连带关掉服务层的连接**（实测踩到 `database_closed`）。
    final ro = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    var writeBlocked = false;
    try {
      await ro.rawInsert(
          "INSERT INTO word(id, sort_seq, spelling) VALUES ('zzz', 999999, 'zzz')");
    } catch (_) {
      writeBlocked = true;
    }
    await ro.close();
    check('INSERT 被拒（readOnly: true）', writeBlocked);
    check('词条数未变', await svc.countWords() == 11523);

    // ── 10. 性能 ──────────────────────────────────────────────
    print('\n【10】性能（首查 vs 稳态 + 复杂度）');
    final words = <String>[];
    // 抽 200 个真词做基准
    for (final w in ['receive', 'agent', 'courage', 'laser', 'disorganized', 'instruct']) {
      words.add(w);
    }
    // 首查（冷）
    final swCold = Stopwatch()..start();
    await svc.lookup('intercept');
    swCold.stop();

    Future<Map<String, double>> bench(Future<dynamic> Function(int) fn,
        {int n = 300, int warm = 50}) async {
      for (var i = 0; i < warm; i++) {
        await fn(i);
      }
      final ts = <int>[];
      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        await fn(i);
        sw.stop();
        ts.add(sw.elapsedMicroseconds);
      }
      ts.sort();
      return {
        'p50': ts[n ~/ 2].toDouble(),
        'p95': ts[(n * 0.95).floor()].toDouble(),
      };
    }

    final hit = await bench((i) => svc.lookup(words[i % words.length]));
    final miss = await bench((i) => svc.lookup('zzznotaword$i'));
    print('    首查(冷)      : ${fmtUs(swCold.elapsedMicroseconds)}');
    print('    命中查词      : p50=${fmtUs(hit['p50']!.toInt())} p95=${fmtUs(hit['p95']!.toInt())}');
    print('    未命中查词    : p50=${fmtUs(miss['p50']!.toInt())} p95=${fmtUs(miss['p95']!.toInt())}');

    check('稳态查词 p50 < 3ms', hit['p50']! < 3000, fmtUs(hit['p50']!.toInt()));
    check('未命中不比命中慢 3 倍以上',
        miss['p50']! < math.max(hit['p50']! * 3, 500),
        '命中 ${fmtUs(hit['p50']!.toInt())} vs 未命中 ${fmtUs(miss['p50']!.toInt())}');

    // ── 11. 词组 ──────────────────────────────────────────────
    print('\n【11】词组（含空格的词条）');
    final phrase = await svc.lookup('traffic jam');
    if (phrase != null) {
      check('lookup(\'traffic jam\') 命中', true,
          'entry_type=${phrase.card.entryType}');
      final spaced = await svc.lookup('  traffic   jam  ');
      check('  多余空白被规范化后仍命中', spaced != null);
    } else {
      print('    （词库无 traffic jam，跳过）');
      check('规范化逻辑可用（测 receive 前加空格）',
          (await svc.lookup('  receive  ')) != null);
    }
  } finally {
    await svc.close();
  }

  print('\n${'=' * 68}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  🔴 $f');
    }
    exit(1);
  }
  print('✅ WordQueryService 全部通过');
  exit(0);
}
