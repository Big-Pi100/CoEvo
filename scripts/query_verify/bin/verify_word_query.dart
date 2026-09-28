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

        // 🆕 聚合页**页头 + 成员**（`aggregatePageOf`）—— 2026-09-28 补
        //    🔴 关键：它**不该自己再查一遍成员**（复用 `aggregateMembers`）
        //    —— 我第一版正是这么错的（重复实现，见该方法的文档）。
        final page = await svc.aggregatePageOf(rootLink.pageId);
        check('  聚合页可打开（aggregatePageOf）', page != null);
        if (page != null) {
          check('  页头有标题（front）', page.front.isNotEmpty, page.front);
          check(
              '  页头有词根本体（source.form）—— 设计稿的「大字」',
              (page.source?.form ?? '').isNotEmpty,
              '${page.source?.form} / ${page.source?.origin} / ${page.source?.meaning}');
          check('  成员与 aggregateMembers 一致（复用，不是重查）',
              page.members.length == members.length,
              '${page.members.length} vs ${members.length}');
          check('  成员带中文释义（设计稿的成员行要显示）',
              page.glosses.isNotEmpty, '${page.glosses.length} 条');
          // 释义要能按 wordId 取到（UI 就是这样用的）
          if (members.isNotEmpty) {
            final w0 = members.first.wordId;
            check('  释义可按 wordId 取（UI 的取法）',
                (page.glosses[w0] ?? '').isNotEmpty,
                '$w0 → ${page.glosses[w0]}');
          }
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

    // ── 11. 卡片槽位解析（白哥 2026-09-28 报的第 1、3 条）──────────
    //
    // 🔑 这是**纯逻辑**，不依赖词库数据 → 造对象直接测（不必查库）。
    //    它守护的是「哪些记忆法类型**能上卡**」这条产品规则。
    print('\n【12】卡片槽位 CardSlots.resolve（排除 context / cognate + 补位）');

    WordSection secOf(String t) => WordSection({'type': t});
    WordCard cardOf(List<String> types) => WordCard(
          wordId: 'w1',
          spelling: 'test',
          sections: [for (final t in types) secOf(t)],
        );
    WordMnemonicProfile profOf(String pri, [List<String> sec = const []]) =>
        WordMnemonicProfile(wordId: 'w1', primaryCode: pri, secondaryCodes: sec);

    // ① ``context`` 不能上卡 —— 它是 ④ 的固定位置，上卡就**重复显示**
    //    实测：**1,410 词**的 `primary_code` 是它（achieve / begin / close …）
    {
      final s = CardSlots.resolve(
        card: cardOf(['etymology', 'definition', 'context']),
        profile: profOf('context'),
      );
      check('🔴 排除 context（它是 ④ 固定段 → 上卡会与 ④ 重复显示）',
          !s.any((x) => x.code == 'context'), s.map((x) => x.code).join(','));
      check('  且**补位**到实际存在的段（不是留空）',
          s.isNotEmpty && s.first.code == 'etymology',
          s.map((x) => x.code).join(','));
    }

    // ② ``cognate`` 不能上卡 —— 它是聚合页（白哥原话）
    //    ⚠️ 2026-09-28：它已**整层摘除**（`mnemonic_type` 行 / `profile` / 2,988 个卡片段 /
    //    渲染分支全清）。`offCard` 里**保留**它纯属**防御纵深** ——
    //    万一哪天有人把 `cognate` 塞回数据，这里仍会挡住它。
    {
      final s = CardSlots.resolve(
        card: cardOf(['root', 'cognate', 'etymology', 'definition', 'context']),
        profile: profOf('cognate', ['root', 'etymology']),
      );
      check('🔴 排除 cognate（它是聚合页，不铺在卡上；已摘除，保留为防御纵深）',
          !s.any((x) => x.code == 'cognate'), s.map((x) => x.code).join(','));
      check('  profile 给的候选**顺序仍被尊重**（root 在前）',
          s.isNotEmpty && s.first.code == 'root',
          s.map((x) => x.code).join(','));
    }

    // ③ 补位顺序 + 上限
    //
    // 🔄 **2026-09-28 19:3x 再次反转**：白哥定「**词源优先**」→ `etymology` 3 / `collocation` 4
    //    （09-28 18:2x 曾改为 collocation 3，现已改回）→ 断言期望值**必须同步反转**。
    //    🔑 不反转的代价是双向的：它会一直报红；更糟的是有人为了让绿**把 order 改回去**。
    //    📌 这是 3/4 级当天第二次反转 —— 反转型断言**每次改口都要翻一次**。
    {
      final s = CardSlots.resolve(
        card: cardOf(['collocation', 'etymology', 'definition', 'context']),
        profile: profOf('context', ['context']),
      );
      check('  最多两个槽位（设计稿「卡片只显示四样」）',
          s.length <= CardSlots.maxSlots, '${s.length}');
      check('  补位按 mnemonic_type.priority（**etymology 先于 collocation** —— 词源优先）',
          s.map((x) => x.code).join(',') == 'etymology,collocation',
          s.map((x) => x.code).join(','));
    }

    // ③b 🔑 `order` 必须与库表 `mnemonic_type.priority` **逐项一致**
    //     🔴 这是本轮最重要的新断言：修复前实测 **859 词的 ① 放错**（`order` 是 09-27 的旧序）。
    //     判据：**两边都是从「同一个概念」推出的两份拷贝 → 必须断言相等**，否则必然漂移。
    //
    // ⚠️ 用**自己的只读连接**查库（而不是给 `WordQueryService` 加公开 `db` getter）——
    //    那会鼓励调用方绕过服务层。断言脚本自己开库是既有做法。
    {
      final raw = await factory.openDatabase(dbPath,
          options: OpenDatabaseOptions(readOnly: true));
      try {
        final dbRows = await raw.rawQuery(
            "SELECT code FROM mnemonic_type WHERE code NOT IN ('context','cognate') "
            'ORDER BY priority');
        final dbOrder = dbRows.map((r) => r['code'] as String).toList();
        check('🔴 CardSlots.order 与 mnemonic_type.priority 一致（防两处漂移）',
            dbOrder.join(',') == CardSlots.order.join(','),
            'db=${dbOrder.join(",")} code=${CardSlots.order.join(",")}');

        final cog = (await raw.rawQuery(
                "SELECT count(*) AS n FROM mnemonic_type WHERE code='cognate'"))
            .first['n'] as int;
        check('🔴 库表里已无 cognate（记忆法层共 5 类）', cog == 0);

        // ③c 🔴 `profile` 必须与 `priority` 一致（v1 §4.1：「制卡时按 priority 选主/次」）
        //     🔑 修复前这里是**不成立**的（`load_llm_results` 直接用 LLM 的 primary，
        //        `CardSlots.resolve` 也不排序）。2026-09-28 已治本
        //        （存量数据重判 + 写端调用 `priority_redo.apply_order`）。
        //
        // ⚠️ **判据必须用 `word_morpheme`，不能用 `card.content LIKE '%"root"%'`** ——
        //    首版就是后者，报了 **2,731 条假阳性**：`"root"` 还出现在
        //    `etymology` 段的 `etyma[].role` 里（`{"form":"gratum",…,"role":"root"}`）
        //    → 文本匹配**被同名字段骗了**。实测两者口径：`word_morpheme` 词数 =
        //    「root 段且 `parts` 非空」词数 = **5,484**（差集 0）。
        //    🔑 判据：**在 JSON 里做文本匹配，必须确认该串只可能出现在你要找的位置**。
        final bad = (await raw.rawQuery('''
          SELECT count(*) AS n FROM word_mnemonic_profile p
          WHERE p.primary_code NOT IN ('root','context')
            AND p.word_id IN (SELECT DISTINCT word_id FROM word_morpheme)'''))
            .first['n'] as int;
        check('🔴 有词素的词，primary 必须是 root（违反 priority 的 = 0）',
            bad == 0, '违反 $bad 条');

        final cogProf = (await raw.rawQuery(
                "SELECT count(*) AS n FROM word_mnemonic_profile "
                "WHERE primary_code='cognate' OR secondary_codes LIKE '%cognate%'"))
            .first['n'] as int;
        check('🔴 profile 里已无 cognate（primary 与 secondary）', cogProf == 0);

        final cogCard = (await raw.rawQuery(
                "SELECT count(*) AS n FROM card WHERE content LIKE '%\"cognate\"%'"))
            .first['n'] as int;
        check('🔴 card 段里已无 cognate（2,988 个冗余段已删）', cogCard == 0);
      } finally {
        await raw.close();
      }
    }

    // ④ 段不存在 → **不留空槽位**（设计稿 §03）
    {
      final s = CardSlots.resolve(
        card: cardOf(['etymology', 'definition', 'context']),
        profile: profOf('image', ['cognate']),
      );
      check('  候选都取不到时不报错、不留空槽位',
          s.every((x) => x.code == 'etymology'), s.map((x) => x.code).join(','));
    }

    // ⑤ `profile == null`（罕见）→ 仍按 priority 补位，而不是整段消失
    {
      final s = CardSlots.resolve(
        card: cardOf(['root', 'etymology', 'definition']),
        profile: null,
      );
      check('  profile=null 时按 priority 补位（不是① ② 都不显示）',
          s.length == 2, s.map((x) => x.code).join(','));
    }

    // ⑥ `offCard` 是**排除法的正确性**而非巧合
    //
    // 🔄 2026-09-28：`cognate` 已从数据层整层摘除，但 `offCard` **保留**它 ——
    //    🔑 这是**有意的防御纵深**：万一有人把 `cognate` 塞回数据里，这里仍会挡住它。
    //    → 断言从「恰好 2 个」改为「**必须含这两类**」（不再锁死数量，
    //      将来若要新增 offCard 类型不必改断言）。
    {
      check('  offCard 含 context（④ 固定段，必须挡）',
          CardSlots.offCard.contains('context'), CardSlots.offCard.join(','));
      check('  offCard **保留** cognate（已摘除，但留作防御纵深）',
          CardSlots.offCard.contains('cognate'), CardSlots.offCard.join(','));
      check('  order 不含被排除的两类（否则补位又会把它们加回来）',
          !CardSlots.order.any((c) => CardSlots.offCard.contains(c)),
          CardSlots.order.join(','));
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
