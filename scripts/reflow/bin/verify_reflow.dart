/// A3 · 制卡回流的验收断言。
///
/// # 断言分两层（重要性递减）
/// | 层 | 用什么数据 | 断言什么 |
/// |---|---|---|
/// | ① **序列化对齐** | **真实的 `data/word.db`（11523 行只读）** | `pyJsonEncode(jsonDecode(content)) == content` **逐字节** |
/// | ②~⑩ 回流行为 | 内存库 + 最小 schema | 幂等 · 只写两表 · 续号 · 契约过滤 · 转换失败不写 · 归一化 · hash 自洽 |
///
/// # 🔑 ① 为什么是全篇最重要的一条
/// 回流把 `toCardContent`（Dart 紧凑格式）的产物写进 `word.db`，而既有 11523 行
/// **全部**是 Python `json.dumps` 风格。若格式不一致：
/// · 词库内部出现**两种格式**（工程债，且让「重算 hash 的 Python 工具」算出不同 hash）
/// ⇒ 这是个**静默**问题（不报错、不影响解析，只在下一次用 Python 工具时炸）。
///
/// 靠人眼「我觉得一样」是不可靠的 ⇒ 本断言把「跨实现序列化一致」变成**可验证**的。
/// ⚠️ 它同时是**回归防线**：谁改了 [pyJsonEncode]，先在这里炸。
///
/// # 运行
/// ```bash
/// cd scripts/reflow && dart run bin/verify_reflow.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/reflow.dart';

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

void eq(String label, Object? actual, Object? expected) => check(label,
    actual == expected, actual == expected ? '' : '实得 $actual · 期望 $expected');

void section(String t) => print('\n${'─' * 72}\n$t\n${'─' * 72}');

// ══════════════════════════════════════════════════════════════════════
// 测试用：符合契约 v6 的最小合法 LLM 原始卡
// ══════════════════════════════════════════════════════════════════════

Map<String, Object?> _rawCard({
  required String word,
  bool withDefinition = true,
  bool withEtymology = true,
  String entryType = 'word',
}) =>
    {
      'word': word,
      'entry_type': entryType,
      'ipa': '/ˈbreɪnstɔːm/',
      'is_own_entry': true,
      'confidence': 0.9,
      'reason': 'internal field, must be dropped',
      'morphology': {
        'analyzable': true,
        'relation': 'compound',
        'parts': [
          {'form': 'brain', 'type': 'root', 'meaning': '大脑', 'origin': 'OE'},
          {'form': 'storm', 'type': 'root', 'meaning': '风暴', 'origin': 'OE'},
        ],
      },
      if (withEtymology)
        'etymology': {
          'text': 'brain + storm，原义「脑中风」',
          'etyma': [
            {
              'form': 'bregen',
              'language': 'Old English',
              'meaning': '大脑',
              'role': 'whole',
              'form_ascii': 'bregen',
              'parent': 'x',
            },
          ],
        },
      if (withDefinition)
        'definition': {'pos': '[v]', 'en': 'to have a sudden idea', 'zh': '灵光一现'},
      'context': 'I brainstormed a plan, then forgot it.',
      'collocations': [
        {'phrase': 'brainstorm ideas', 'zh': '头脑风暴想法'},
        {'phrase': '', 'zh': '空词组应被丢弃'},
      ],
    };

/// 最小 schema —— **与 `data/word.db` 的真实 DDL 逐字一致**（只去掉与回流无关的表）。
///
/// 🔑 必须用真实 DDL：若这里"简化"了（比如漏掉 `UNIQUE(spelling)`），
///    断言就会在**与生产不同**的表上通过（假绿）。
const _minSchema = '''
CREATE TABLE word (
  id TEXT PRIMARY KEY, sort_seq INTEGER NOT NULL UNIQUE,
  spelling TEXT NOT NULL COLLATE NOCASE, cefr_level TEXT, entry_type TEXT,
  etymology_text TEXT, created_at TEXT DEFAULT (datetime('now')), UNIQUE (spelling));
CREATE TABLE card (
  word_id TEXT PRIMARY KEY, content TEXT NOT NULL, content_hash TEXT,
  template_code TEXT, updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (word_id) REFERENCES word(id));
-- 哨兵表：回流**不该**碰它们（§ ④ 用表级行数差核对）
CREATE TABLE card_extra (
  id INTEGER PRIMARY KEY AUTOINCREMENT, word_id TEXT NOT NULL,
  section TEXT NOT NULL, ord INTEGER);
CREATE TABLE aggregate_page (id TEXT PRIMARY KEY, x TEXT);
CREATE TABLE word_form (form TEXT, base TEXT);
''';

Future<Database> _memDb() async {
  // 🔴 必须 `singleInstance: false` —— 默认 true 时，同一路径（`:memory:`）
  //    会被**复用成同一个连接** ⇒ 第二次调用会撞上「table word already exists」。
  //    （踩过：第 ⑥ 段刚建库就崩在这里，看起来像「SQL 写错了」，其实是夹具问题。）
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  for (final stmt in _minSchema.split(';')) {
    final s = stmt.trim();
    if (s.isNotEmpty) await db.execute(s);
  }
  return db;
}

/// 基线：2 个已有词（`blanch` 用于测「已存在跳过」）。
Future<void> _seed(Database db) async {
  for (final (seq, sp) in [(1, 'sud'), (2, 'blanch')]) {
    final id = wordIdOfSeq(seq);
    await db.insert('word', {
      'id': id,
      'sort_seq': seq,
      'spelling': sp,
      'cefr_level': 'B1',
      'entry_type': 'word',
      'etymology_text': '种子 $sp',
    });
    final content = pyJsonEncode({
      'front': sp,
      'ipa': '/x/',
      'entry_type': 'word',
      'sections': [
        {'type': 'definition', 'order': 1, 'pos': '[n]', 'en': 'seed', 'zh': '种子'},
      ],
    });
    await db.insert('card', {
      'word_id': id,
      'content': content,
      'content_hash': contentHashOf(content),
      'template_code': null,
    });
  }
  // 哨兵表塞一行，确保"行数不变"是有意义的比较
  await db.insert('aggregate_page', {'id': 'a1', 'x': 'keep'});
  await db.insert('card_extra', {'word_id': 'w000001', 'section': '{}', 'ord': 0});
  await db.insert('word_form', {'form': 'suds', 'base': 'sud'});
}

Future<int> _count(Database db, String table) async =>
    (await db.rawQuery('SELECT count(*) AS c FROM $table')).first['c'] as int;

// ══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  sqfliteFfiInit();

  final binDir = File.fromUri(Platform.script).parent; // …/scripts/reflow/bin
  final repoRoot = binDir.parent.parent.parent; // 仓库根
  final wordDb = File('${repoRoot.path}/data/word.db');

  // ════════════════════════════════════════════════════════════════
  section('① pyJsonEncode 与既有 word.db **逐字节**一致（最强断言）');
  // ════════════════════════════════════════════════════════════════
  if (!wordDb.existsSync()) {
    check('找到 data/word.db', false, wordDb.path);
  } else {
    final db = await databaseFactoryFfi.openDatabase(
      wordDb.absolute.path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    try {
      final rows = await db.rawQuery('SELECT word_id, content FROM card');
      var same = 0;
      var diff = 0;
      String firstBad = '';
      for (final r in rows) {
        final ct = r['content'] as String;
        Object? decoded;
        try {
          decoded = jsonDecode(ct);
        } catch (_) {
          diff++;
          if (firstBad.isEmpty) firstBad = '${r['word_id']} JSON 坏了';
          continue;
        }
        if (pyJsonEncode(decoded) == ct) {
          same++;
        } else {
          diff++;
          if (firstBad.isEmpty) {
            firstBad = '${r['word_id']}：原 `${ct.substring(0, ct.length > 60 ? 60 : ct.length)}`';
          }
        }
      }
      check('词库非空（断言有覆盖面）', rows.isNotEmpty, '${rows.length} 行');
      eq('🔑 **逐字节一致的行数** = 全部行数', diff, 0);
      check('…覆盖面：$same / ${rows.length} 行',
          same == rows.length && rows.isNotEmpty,
          diff == 0 ? '' : '首个不符：$firstBad');
    } finally {
      await db.close();
    }
  }

  // ════════════════════════════════════════════════════════════════
  section('② pyJsonEncode 的边界行为（单元级，锁住与 Python 的对齐点）');
  // ════════════════════════════════════════════════════════════════
  eq('🔴 字符串内部的 `,` `:` **不被加空格**（这是不能用正则替换的原因）',
      pyJsonEncode({'a': 'x, y', 'b': 'p: q'}), '{"a": "x, y", "b": "p: q"}');
  eq('结构位置的分隔符**带空格**', pyJsonEncode({'a': 1, 'b': 2}), '{"a": 1, "b": 2}');
  eq('list 分隔符带空格', pyJsonEncode([1, 2, 3]), '[1, 2, 3]');
  eq('非 ASCII **不转义**（ensure_ascii=False）',
      pyJsonEncode({'zh': '中文·测试'}), '{"zh": "中文·测试"}');
  eq('控制字符用短转义', pyJsonEncode('a\nb\tc'), '"a\\nb\\tc"');
  eq('其他控制字符用 \\u00xx', pyJsonEncode('a\u0001b'), '"a\\u0001b"');
  eq('引号与反斜杠被转义', pyJsonEncode('a"b\\c'), '"a\\"b\\\\c"');
  eq('`/` 不转义', pyJsonEncode('a/b'), '"a/b"');
  eq('空对象 / 空数组', pyJsonEncode({'a': {}, 'b': []}), '{"a": {}, "b": []}');
  eq('布尔与 null', pyJsonEncode({'a': true, 'b': false, 'c': null}),
      '{"a": true, "b": false, "c": null}');
  eq('emoji（代理对）原样', pyJsonEncode('🎉'), '"🎉"');

  // ════════════════════════════════════════════════════════════════
  section('③ 回流：一次跑全部结局（插入 1 · 跳过 4）');
  // ════════════════════════════════════════════════════════════════
  final db = await _memDb();
  await _seed(db);

  final candidates = [
    // 应插入（大写 → 归一化成小写）
    ReflowCandidate(
      spelling: 'BrainStorm',
      rawCard: _rawCard(word: 'BrainStorm'),
      contractVersion: 'v6',
      hitCount: 7,
      distinctUserCount: 4,
    ),
    // 应跳过：词库已有
    ReflowCandidate(
      spelling: 'blanch',
      rawCard: _rawCard(word: 'blanch'),
      contractVersion: 'v6',
    ),
    // 应跳过：契约版本不符
    ReflowCandidate(
      spelling: 'newword',
      rawCard: _rawCard(word: 'newword'),
      contractVersion: 'v7',
    ),
    // 应跳过：缺 definition（转换会显式失败）
    ReflowCandidate(
      spelling: 'nodef',
      rawCard: _rawCard(word: 'nodef', withDefinition: false),
      contractVersion: 'v6',
    ),
    // 应跳过：拼写为空
    ReflowCandidate(
      spelling: '   ',
      rawCard: _rawCard(word: 'blank'),
      contractVersion: 'v6',
    ),
  ];

  final before = {
    'word': await _count(db, 'word'),
    'card': await _count(db, 'card'),
    'card_extra': await _count(db, 'card_extra'),
    'aggregate_page': await _count(db, 'aggregate_page'),
    'word_form': await _count(db, 'word_form'),
  };

  final rep = await reflowIntoWordDb(db, candidates);
  print('  ${rep.summary().trimRight().replaceAll('\n', '\n  ')}');

  eq('插入 1 条', rep.inserted.length, 1);
  eq('跳过 4 条', rep.skipped.length, 4);
  eq('跳过原因 · 拼写为空', rep.countOf(ReflowSkip.emptySpelling), 1);
  eq('跳过原因 · 词库已有', rep.countOf(ReflowSkip.alreadyInWordDb), 1);
  eq('跳过原因 · 契约版本不符', rep.countOf(ReflowSkip.contractMismatch), 1);
  eq('跳过原因 · 转换失败', rep.countOf(ReflowSkip.conversionFailed), 1);

  final ins = rep.inserted.first;
  eq('🔑 从 max(sort_seq) 续号（2 → 3）', ins.wordId, 'w000003');
  eq('拼写**归一化**后写入（大写 → 小写）', ins.spelling, 'brainstorm');

  // ── word / card 两表的实际内容 ──
  final w = (await db.rawQuery(
          "SELECT * FROM word WHERE spelling = 'brainstorm' COLLATE NOCASE"))
      .first;
  final c = (await db.rawQuery('SELECT * FROM card WHERE word_id = ?', [ins.wordId]))
      .first;

  eq('word.sort_seq 同步', w['sort_seq'], 3);
  eq('word.entry_type 取自转换后的 content', w['entry_type'], 'word');
  eq('🔑 word.etymology_text 取自 content 的 etymology 段（同进同出）',
      w['etymology_text'], 'brain + storm，原义「脑中风」');
  check('word.cefr_level 为 NULL（LLM 契约里没有这个字段 ⇒ 如实留空）',
      w['cefr_level'] == null, '${w['cefr_level']}');
  check('card.template_code 为 NULL（与既有词库同形）', c['template_code'] == null);

  eq('🔑 content_hash = sha256(content)[:32]（回流无 card_extra ⇒ extras 为空）',
      c['content_hash'], contentHashOf(c['content'] as String));
  eq('content_hash 是 32 位十六进制', (c['content_hash'] as String).length, 32);

  final writtenContent = c['content'] as String;
  check('🔑 写入的 content 是 **Python 风格**（含 `": "` 与 `", "`）',
      writtenContent.contains('": "') && writtenContent.contains(', '));
  eq('🔑 content 与 pyJsonEncode 互逆（再解析再序列化逐字节相同）',
      pyJsonEncode(jsonDecode(writtenContent)), writtenContent);

  final decoded = jsonDecode(writtenContent) as Map<String, Object?>;
  final sections = decoded['sections'] as List;
  check('root 段保留（morphology 可拆）',
      sections.any((s) => (s as Map)['type'] == 'root'));
  check('collocation 段只保留有词组的条目（空 zh 的那条被丢）',
      sections.any((s) =>
          (s as Map)['type'] == 'collocation' &&
          (s['items'] as List).length == 1));
  check('🔴 服务端内部字段**未泄漏**进 content（confidence/reason/is_own_entry）',
      !writtenContent.contains('confidence') &&
          !writtenContent.contains('`reason`') &&
          !writtenContent.contains('is_own_entry') &&
          !writtenContent.contains('internal field'));
  check('etyma 丢掉了 form_ascii / parent（对齐词库形状）',
      !writtenContent.contains('form_ascii') && !writtenContent.contains('"parent"'));

  // ── ③-b 只写两表 ──
  final after = {
    'word': await _count(db, 'word'),
    'card': await _count(db, 'card'),
    'card_extra': await _count(db, 'card_extra'),
    'aggregate_page': await _count(db, 'aggregate_page'),
    'word_form': await _count(db, 'word_form'),
  };
  eq('word 表 +1', after['word']! - before['word']!, 1);
  eq('card 表 +1', after['card']! - before['card']!, 1);
  eq('🔴 card_extra **不变**（回流不产额外段）',
      after['card_extra'], before['card_extra']);
  eq('🔴 aggregate_page **不变**（单张卡推不出聚合页）',
      after['aggregate_page'], before['aggregate_page']);
  eq('🔴 word_form **不变**（词形链来自全量语料）',
      after['word_form'], before['word_form']);

  // ════════════════════════════════════════════════════════════════
  section('④ 幂等：同一批候选再跑一次 ⇒ 零插入');
  // ════════════════════════════════════════════════════════════════
  final rep2 = await reflowIntoWordDb(db, candidates);
  eq('第二次插入 0 条', rep2.inserted.length, 0);
  eq('第二次「词库已有」5 条中命中 2 条（brainstorm + blanch）',
      rep2.countOf(ReflowSkip.alreadyInWordDb), 2);
  eq('word 表行数不变', await _count(db, 'word'), after['word']);
  eq('card 表行数不变', await _count(db, 'card'), after['card']);
  eq('🔑 幂等不产生新 id（末行仍是 w000003）',
      (await db.rawQuery('SELECT id FROM word ORDER BY sort_seq DESC LIMIT 1'))
          .first['id'],
      'w000003');

  // ════════════════════════════════════════════════════════════════
  section('⑤ 干跑（dryRun）**不写任何东西**');
  // ════════════════════════════════════════════════════════════════
  final dry = await reflowIntoWordDb(db,
      [
        ReflowCandidate(
          spelling: 'dryrunword',
          rawCard: _rawCard(word: 'dryrunword'),
          contractVersion: 'v6',
        ),
      ],
      dryRun: true);
  eq('干跑报告插入 1 条（算出来了）', dry.inserted.length, 1);
  check('干跑标记为 dryRun', dry.dryRun);
  eq('🔴 但库里**没有**这个词',
      (await db.rawQuery(
              "SELECT count(*) AS c FROM word WHERE spelling = 'dryrunword'"))
          .first['c'],
      0);
  eq('word 行数不变', await _count(db, 'word'), after['word']);

  // ════════════════════════════════════════════════════════════════
  section('⑥ id / sort_seq 异常时**拒绝续号**（不静默）');
  // ════════════════════════════════════════════════════════════════
  final broken = await _memDb();
  await broken.insert('word', {
    'id': 'w000099', // id 说 99
    'sort_seq': 5, // 排序号说 5 ⇒ 不同步
    'spelling': 'x',
    'entry_type': 'word',
  });
  var threw = false;
  try {
    await reflowIntoWordDb(broken, [
      ReflowCandidate(
        spelling: 'whatever',
        rawCard: _rawCard(word: 'whatever'),
        contractVersion: 'v6',
      ),
    ]);
  } on StateError {
    threw = true;
  }
  check('🔴 id 与 sort_seq 不同步 ⇒ **抛错**（而不是续一个可能撞车的号）', threw);
  await broken.close();

  await db.close();

  // ════════════════════════════════════════════════════════════════
  section('⑦ 源码级：转换与序列化**各只有一处**（不许出现第二份实现）');
  // ════════════════════════════════════════════════════════════════
  final libSrc =
      File('${repoRoot.path}/scripts/reflow/lib/reflow.dart').readAsStringSync();
  final cliSrc = File('${repoRoot.path}/scripts/reflow/bin/reflow_into_word_db.dart')
      .readAsStringSync();
  final pySrc =
      File('${repoRoot.path}/scripts/reflow/export_candidates.py').readAsStringSync();

  eq('回流核心只 `toCardContent(` 调用一次（形状转换只有一处）',
      RegExp(r'toCardContent\(').allMatches(libSrc).length, 1);
  check('🔴 导出脚本（Python）**不自己转换形状**（不出现 front/sections 的拼装）',
      !pySrc.contains("'front'") && !pySrc.contains('"front"'));
  eq('pyJsonEncode 的**定义**只有一处',
      RegExp(r'^String pyJsonEncode\(', multiLine: true).allMatches(libSrc).length,
      1);
  eq('CLI 不自己写 SQL 插行（一律走 lib 的 reflowIntoWordDb）',
      RegExp(r"insert\('word'").allMatches(cliSrc).length, 0);
  check('CLI 引用的是 lib 的入口',
      cliSrc.contains('reflowIntoWordDb(db, candidates'));

  // ════════════════════════════════════════════════════════════════
  print('\n${'═' * 72}');
  print('通过 $_pass 项，失败 ${_failures.length} 项');
  if (_failures.isNotEmpty) {
    print('\n失败项：');
    for (final f in _failures) {
      print('  · $f');
    }
  }
  print('═' * 72);
  exit(_failures.isEmpty ? 0 : 1);
}
