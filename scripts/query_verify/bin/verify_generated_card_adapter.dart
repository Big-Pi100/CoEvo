// CoEvo · 在线制卡的两块纯逻辑验收：
//   ① `external_word_id.dart` —— `ext:` 合成 id 的构造/解析/**归一化**
//   ② `generated_card_adapter.dart` —— 契约 v6 → `card.content` 形状
//
// 跑法：cd scripts/query_verify && dart run bin/verify_generated_card_adapter.dart
// 退出码：0 = 全通过；1 = 有失败
//
// # 🔴 为什么这两块值得单独验
// | 块 | 坏了会怎样（**都不报错**） |
// |---|---|
// | `ext:` 归一化 | 同一词**两行**（`ext:Brainstorm` ≠ `ext:brainstorm`）→ 生词本出现重复项，而 `UNIQUE(word_id)` **拦不住**（是两个不同 id）|
// | 适配器映射 | 卡片**少段/空段**（如 `definition` 没映射过去）→ 用户看到一张没有释义的卡 |
//
// # 🔑 本脚本的最强一条：**round-trip**
// 拿**真实** `word.db` 里的一条卡 → 反拆成 LLM 形状 → 过适配器 →
// 断言产出与原卡的 `sections` **逐段一致**。
// 这直接钉住适配器的设计目标：**产出与 `word.db` 同构**
// （收敛切换要做到无缝，全靠这条）。
//
// ⚠️ 样例来源说明（**别用错版本**）：
//   `data/curriculum/prebuilt/fullrun/results.jsonl` 是 **契约 v5** 的产物
//   （实测无 `ipa` / `definition` / `context` —— 这三个是 **v6 新增**的，
//    见 `docs/design/a1b-compliance-gate-and-retired-cleanup-2026-09-29.md:63`）
//   → **不能**直接当 v6 样例用。本脚本的样例照 `backend/prompts/wordlib_contract.md`
//     的 v6 schema 手工构造，并符合服务端 `gate()` 的全部要求
//     （ipa 完整 / definition.en+zh 非空 / context 含该词 / entry_type 非空）。

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/external_word_id.dart';
import '../../../app/lib/services/generated_card_adapter.dart';
import '../../../app/lib/services/word_query_service.dart';

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

/// 一份**符合契约 v6** 的样例（照 `wordlib_contract.md` 的 schema）。
///
/// 🔑 用真实词 `incredible`（它的内容取自 `word.db` 里同词的真值）——
///    这样样例不是凭空编的，且能与 round-trip 那组对上。
const String _v6Sample = '''
{
  "word": "incredible",
  "entry_type": "word",
  "is_own_entry": true,
  "derived_from": null,
  "reason": "难以置信的",
  "morphology": {
    "analyzable": true,
    "relation": "derivation",
    "parts": [
      {"form": "in-", "type": "prefix", "meaning": "不", "origin": "Latin"},
      {"form": "cred", "type": "root", "meaning": "相信", "origin": "Latin"},
      {"form": "-ible", "type": "suffix", "meaning": "可…的", "origin": "Latin"}
    ]
  },
  "etymology": {
    "text": "拉丁 credere（相信）→ 不可相信的",
    "etyma": [
      {"form": "credere", "form_ascii": "credere", "language": "Latin",
       "meaning": "相信", "role": "root", "parent": ""}
    ]
  },
  "ipa": "/ɪnˈkredəbl/",
  "definition": {"pos": "[adj]", "en": "impossible or very hard to believe", "zh": "难以置信的"},
  "context": "It seems incredible that no one noticed the mistake.",
  "collocations": [{"phrase": "an incredible story", "zh": "一个难以置信的故事"}],
  "mnemonic": {"primary": "root", "secondary": ["context"], "rationale": "in(不)+cred(相信)+ible(可…的)"},
  "confidence": 0.9
}
''';

Future<void> main() async {
  print('═' * 72);
  print('CoEvo 在线制卡：ext: 合成 id + 契约适配器 验收');
  print('═' * 72);

  // ═══ 【1】`ext:` 合成 id ═══
  section('【1】ext: 合成 id（构造 / 解析 / 归一化）');
  {
    eq('构造', externalWordId('brainstorm'), 'ext:brainstorm');
    check('🔴 大写 → 折成小写（否则同一词两行，且 UNIQUE 拦不住）',
        externalWordId('Brainstorm') == 'ext:brainstorm',
        externalWordId('Brainstorm'));
    check('🔴 前后空白 + 内部多空白 → 归一化',
        externalWordId('  Traffic   Jam  ') == 'ext:traffic jam',
        externalWordId('  Traffic   Jam  '));
    check('🔑 与真 id 天然隔离（`w` 开头的不受影响）',
        !isExternalWordId('w005333') && !isExternalWordId('w000001'));
    check('isExternalWordId 正向', isExternalWordId('ext:brainstorm'));

    eq('解析：ext: 前缀的词', externalSpellingOf('ext:brainstorm'), 'brainstorm');
    check('解析：非 ext: → null（调用方据此区分「词库内/外」）',
        externalSpellingOf('w005333') == null);
    check('解析：`ext:` 后为空 → null（不是空串）',
        externalSpellingOf('ext:') == null);

    // 🔴 构造 → 解析 必须**回到同一个值**（这是收敛的桥，断了就收不了）
    for (final w in ['brainstorm', 'Traffic Jam', '  Café  ', 'T-Shirt']) {
      final back = externalSpellingOf(externalWordId(w));
      check('round-trip: "$w"', back == normalizeExternalSpelling(w), '$back');
    }

    // ⚠️ 归一化必须与 **user_word 的 COLLATE NOCASE** 口径一致（都是 ASCII 折叠）
    check('🔑 归一化后不含大写（与 COLLATE NOCASE 呼应）',
        !externalWordId('AbCd').substring(4).contains(RegExp('[A-Z]')));
  }

  // ═══ 【2】契约 v6 → sections（正例）═══
  section('【2】适配器：v6 → card.content 形状');
  {
    final card = jsonDecode(_v6Sample) as Map<String, Object?>;
    final raw = toCardContent(card, spelling: 'Incredible', contractVersion: 'v6');
    final d = jsonDecode(raw) as Map<String, Object?>;

    eq('顶层 front（注意：不是 LLM 的 `word`）', d['front'], 'incredible');
    eq('顶层 ipa', d['ipa'], '/ɪnˈkredəbl/');
    eq('顶层 entry_type', d['entry_type'], 'word');
    check('顶层**不该**带 LLM 特有字段（word/mnemonic/confidence/reason…）',
        !d.containsKey('word') &&
            !d.containsKey('mnemonic') &&
            !d.containsKey('confidence') &&
            !d.containsKey('reason'));

    final secs = (d['sections'] as List).cast<Map<String, Object?>>();
    eq('段数（root+collocation+etymology+definition+context）', secs.length, 5);
    eq('段顺序与 word.db 一致',
        secs.map((s) => s['type']).join(','),
        'root,collocation,etymology,definition,context');

    // ── root ──
    final root = secs.firstWhere((s) => s['type'] == 'root');
    final payload = root['payload'] as Map<String, Object?>;
    final parts = (payload['parts'] as List).cast<Map<String, Object?>>();
    eq('root.parts 条数', parts.length, 3);
    eq('part[0].form', parts[0]['form'], 'in-');
    eq('part[0].meaning', parts[0]['meaning'], '不');
    check('🔴 `relation` 从**顶层**复制进每个 part（与落库链 load_llm_results 一致）',
        parts.every((p) => p['relation'] == 'derivation'), '${parts[0]['relation']}');
    eq('payload.relation 也在（word.db 里有这份冗余）', payload['relation'], 'derivation');
    check('🔴 **不带 `origin`**（word.db 的 parts 没有这个字段）',
        !parts[0].containsKey('origin'));
    check('🔴 **无 `entry`**（词库外的词没有聚合页 —— 卡片不显示箭头）',
        !root.containsKey('entry') && !payload.containsKey('entry'));

    // ── definition ──
    final def = secs.firstWhere((s) => s['type'] == 'definition');
    eq('definition.zh', def['zh'], '难以置信的');
    eq('definition.en', def['en'], 'impossible or very hard to believe');
    eq('definition.pos', def['pos'], '[adj]');
    eq('definition.order', def['order'], 1);

    // ── context ──
    eq('context.text', secs.firstWhere((s) => s['type'] == 'context')['text'],
        'It seems incredible that no one noticed the mistake.');

    // ── etymology ──
    final et = secs.firstWhere((s) => s['type'] == 'etymology');
    check('etymology.text 有值', (et['text'] as String).isNotEmpty);
    final etyma = (et['etyma'] as List).cast<Map<String, Object?>>();
    eq('etyma 条数', etyma.length, 1);
    eq('etyma[0].form', etyma[0]['form'], 'credere');
    check('🔴 **丢掉 `form_ascii` / `parent`**（word.db 的 etyma 没有）',
        !etyma[0].containsKey('form_ascii') && !etyma[0].containsKey('parent'));

    // ── collocation ──
    final colls =
        (secs.firstWhere((s) => s['type'] == 'collocation')['items'] as List);
    eq('collocations 条数', colls.length, 1);

    // 🔑 能被**真实解析器**读出来（不只是形状对）
    final parsed = parseCardContent(raw);
    eq('parseCardContent.front', parsed.front, 'incredible');
    eq('parseCardContent.sections 条数', parsed.sections.length, 5);
    final ws = parsed.sections.map(WordSection.new).toList();
    check('🔑 WordSection 访问器能读出释义（端到端可用）',
        ws.firstWhere((s) => s.type == 'definition').zh == '难以置信的');
    check('🔑 WordSection 访问器能读出词素',
        ws.firstWhere((s) => s.type == 'root').parts.length == 3);
  }

  // ═══ 【3】边界与失败（**这些都不能静默**）═══
  section('【3】边界与失败路径');
  {
    // 不可拆分 → 不产 root 段（不是产一个空的）
    final flat = {
      'entry_type': 'word',
      'morphology': {'analyzable': false, 'relation': null, 'parts': []},
      'ipa': '/ˈhæpi/',
      'definition': {'pos': '[adj]', 'en': 'feeling pleasure', 'zh': '高兴的'},
      'context': 'I am happy to see you.',
    };
    final d1 = jsonDecode(toCardContent(flat, spelling: 'happy', contractVersion: 'v6'))
        as Map<String, Object?>;
    final t1 = (d1['sections'] as List).map((s) => s['type']).toList();
    check('🔴 `analyzable=false` → **不产 root 段**（而不是产空段）',
        !t1.contains('root'), '$t1');

    // 空搭配 / 空例句 → 不产对应段
    final sparse = {
      'entry_type': 'word',
      'ipa': '/x/',
      'definition': {'pos': '[n]', 'en': 'e', 'zh': '中'},
      'context': '',
      'collocations': [],
      'etymology': {'text': '', 'etyma': []},
    };
    final d2 = jsonDecode(toCardContent(sparse, spelling: 'x', contractVersion: 'v6'))
        as Map<String, Object?>;
    final t2 = (d2['sections'] as List).map((s) => s['type']).toList();
    check('空 context / collocations / etymology → 各自不产段',
        t2.length == 1 && t2.single == 'definition', '$t2');

    // 🔴 契约版本不认识 → 必须**显式失败**
    var threw = false;
    try {
      toCardContent(flat, spelling: 'happy', contractVersion: 'v99');
    } on GeneratedCardException {
      threw = true;
    }
    check('🔴 契约版本不认识 → 抛异常（**不静默出空卡**）', threw);

    // 🔴 缺 definition → 显式失败（服务端闸门本应拦住；走到这里说明响应形状不对）
    threw = false;
    try {
      toCardContent({'ipa': '/x/', 'entry_type': 'word'}, spelling: 'x',
          contractVersion: 'v6');
    } on GeneratedCardException {
      threw = true;
    }
    check('🔴 缺 definition → 抛异常（不产出无释义的卡）', threw);

    // 空拼写 → 显式失败
    threw = false;
    try {
      toCardContent(flat, spelling: '   ', contractVersion: 'v6');
    } on GeneratedCardException {
      threw = true;
    }
    check('空拼写 → 抛异常', threw);

    // 🔑 `parseCardContent` 反过来**必须宽容**（库里一条坏数据不该让整卡渲染不出来）
    check('坏 JSON → 空结果（不抛）',
        parseCardContent('{not json').sections.isEmpty);
    check('无 sections → 空结果（不抛）',
        parseCardContent('{"front":"x"}').sections.isEmpty);
  }

  // ═══ 【4】🔑 round-trip：用**真实 word.db** 验证「产出与词库同构」═══
  section('【4】round-trip（真实词库 · 钉住「产出与 word.db 同构」）');
  {
    sqfliteFfiInit();
    final dbPath = _findWordDb();
    if (dbPath == null) {
      check('找到 word.db（后续断言的**前提**）', false, '未找到，跳过本组');
    } else {
      final svc = await WordQueryService.open(databaseFactoryFfi, dbPath);

      // 🔑 **两个词都要测**：`w000001`=absurd（`analyzable=false`，**无 root 段**）、
      //    `w005333`=brainstorm（**可拆**，有 root 段）。
      //    ⚠️ 只测一个会留下盲区 —— 我第一版只测 absurd → `if (rootSec != null)`
      //       整块被跳过，**root 的 round-trip 从没跑过**（看着全绿）。
      //    📌 判据：**条件分支包裹的断言，要确认它真的进去过**。
      for (final wid in ['w000001', 'w005333']) {
        final card = await svc.cardById(wid);
        check('$wid：能从真实库取到卡', card != null);
        if (card == null) continue;

        final rootSec = card.sectionOfType('root');
        final etSec = card.sectionOfType('etymology');
        final collSec = card.sectionOfType('collocation');
        final defSec = card.sectionOfType('definition');
        final ctxSec = card.sectionOfType('context');

        final llmShape = <String, Object?>{
          'word': card.spelling,
          'entry_type': card.entryType ?? 'word',
          'ipa': card.ipa,
          'definition': {
            'pos': defSec?.pos ?? '',
            'en': defSec?.en ?? '',
            'zh': defSec?.zh ?? '',
          },
          'context': ctxSec?.text ?? '',
          'morphology': rootSec == null
              ? {'analyzable': false, 'relation': null, 'parts': []}
              : {
                  'analyzable': true,
                  'relation': (rootSec.raw['payload']
                      as Map<String, Object?>?)?['relation'],
                  'parts': [
                    for (final p in rootSec.parts)
                      {'form': p.surface, 'type': p.type, 'meaning': p.gloss ?? ''}
                  ],
                },
          'collocations': [
            for (final c in collSec?.collocations ?? const [])
              {'phrase': c.phrase, 'zh': c.zh}
          ],
          'etymology': etSec == null
              ? {'text': '', 'etyma': []}
              : {
                  'text': etSec.text ?? '',
                  'etyma': (etSec.raw['etyma'] as List?) ?? []
                },
        };

        final out = parseCardContent(toCardContent(llmShape,
            spelling: card.spelling, contractVersion: 'v6'));

        // 🔑 核心断言：**段类型集合一致**（同构的直接含义）
        final want = card.sections.map((s) => s.type).toSet();
        final got = out.sections.map((s) => s['type']).toSet();
        check('$wid（${card.spelling}）：🔑 段类型集合与真实卡**一致**',
            want.difference(got).isEmpty, '缺: ${want.difference(got)}');
        check('$wid：不多出段（词库外的卡也不该有词库没有的段型）',
            got.difference(want).isEmpty, '多: ${got.difference(want)}');

        final outDef = out.sections.firstWhere((s) => s['type'] == 'definition');
        eq('$wid round-trip: definition.zh', outDef['zh'], defSec?.zh ?? '');
        final outCtx = out.sections.firstWhere((s) => s['type'] == 'context',
            orElse: () => const {});
        eq('$wid round-trip: context.text', outCtx['text'], ctxSec?.text ?? '');

        // 🔑 root 段：**必须真的进这个分支一次**（见上面的说明）
        if (rootSec != null) {
          final outRoot = out.sections.firstWhere((s) => s['type'] == 'root',
              orElse: () => const {});
          final outParts =
              ((outRoot['payload'] as Map<String, Object?>?)?['parts'] as List?)
                      ?.cast<Map<String, Object?>>() ??
                  const [];
          eq('$wid round-trip: root.parts 条数', outParts.length,
              rootSec.parts.length);
          if (outParts.isNotEmpty) {
            eq('$wid round-trip: parts[0].form', outParts[0]['form'],
                rootSec.parts[0].surface);
            eq('$wid round-trip: parts[0].meaning', outParts[0]['meaning'],
                rootSec.parts[0].gloss ?? '');
            // 🔴 relation 的逐 part 复制是**适配器最容易漏的一处**
            eq('$wid round-trip: parts[0].relation',
                outParts[0]['relation'], rootSec.parts[0].relation ?? '');
          }
        }
      }

      await svc.close();
    }
  }

  // ═══ 【5】🔑 `cardById('ext:…')` 的**行为**断言（真跑，不是扫源码）═══
  //
  // 🔴 为什么必须有这一组（**这是本轮最重要的教训**）：
  //    `tokens_verify` §19 里那几条是**文本断言** —— 它们只能证明「代码写着」，
  //    **不能证明「会执行到」**。实测：在回落逻辑前插一句 `return null;`
  //    （整段变死代码），那些断言**照样全绿**。
  //    → 所以这里**真开库、真调用**，用行为把它钉住。
  //    📌 一般化：**接线类文本断言，必须配一条真跑的行为断言。**
  section('【5】🔑 `cardById` 的 ext: 回落（**真跑**，补文本断言的盲区）');
  {
    sqfliteFfiInit();
    final dbPath = _findWordDb();
    if (dbPath == null) {
      check('找到 word.db', false, '未找到');
    } else {
      // 一份合法的「缓存内容」（形状与 word.db.card.content 一致）
      const cached = '{"front":"brainstorm","ipa":"/ˈbreɪnstɔːm/",'
          '"entry_type":"word","sections":['
          '{"type":"definition","order":1,"pos":"[n]",'
          '"en":"a sudden clever idea","zh":"突然想到的好主意"},'
          '{"type":"context","text":"She had a brainstorm."}]}';

      var loaderCalls = 0;
      String? loaderArg;
      final svc = await WordQueryService.open(
        databaseFactoryFfi,
        dbPath,
        externalCardLoader: (sp) async {
          loaderCalls++;
          loaderArg = sp;
          return sp == 'brainstorm' ? cached : null;
        },
      );

      // ① 🔴 核心：**词库外的词真的取得回卡**（这条能抓到「路径被短路」）
      final extCard = await svc.cardById('ext:brainstorm');
      check('🔴 词库外的词取到了卡（回落**真的会执行**）', extCard != null);
      eq('…loader 被调用（说明走了回落，不是别处）', loaderCalls, 1);
      eq('…传给 loader 的是**拼写**（不是整个 ext: id）', loaderArg, 'brainstorm');
      eq('…wordId 保留合成 id（与 user_word 里存的一致）',
          extCard?.wordId, 'ext:brainstorm');
      eq('…spelling 取自缓存内容', extCard?.spelling, 'brainstorm');
      eq('…ipa 取自缓存内容', extCard?.ipa, '/ˈbreɪnstɔːm/');
      check('🔑 释义能被渲染层读出（端到端可用）',
          extCard?.sectionOfType('definition')?.zh == '突然想到的好主意');
      eq('…聚合页入口为空（词库外的词没有族页 —— 正确状态）',
          extCard?.aggregateLinks.length, 0);

      // ② 该词**没有**缓存 → 返回 null（不是抛错、不是空卡）
      loaderCalls = 0;
      check('无缓存 → null（诚实地说「取不到」，而不是给半张卡）',
          await svc.cardById('ext:nocache') == null);
      eq('…仍调用了 loader（确实去查了）', loaderCalls, 1);

      // ③ 词库**内**的词不受影响（走 word.db，不必问 loader）
      loaderCalls = 0;
      final inner = await svc.cardById('w005333');
      check('词库内的词照常取到（回落不干扰主路径）', inner != null);
      eq('…没有调用 loader（主路径不该去问缓存）', loaderCalls, 0);

      // ④ 🔴 不带 loader 时（如 web / 未接线）→ 返回 null，**不抛错**
      final bare = await WordQueryService.open(databaseFactoryFfi, dbPath);
      var threw = false;
      var r5 = null;
      try {
        r5 = await bare.cardById('ext:brainstorm');
      } catch (_) {
        threw = true;
      }
      check('🔴 未注入 loader → 返回 null 而**不是抛异常**（无 fallback 是合法降级）',
          !threw && r5 == null);
      await bare.close();

      // ⑤ 空内容 → null（不是空卡）—— 防「缓存里存了个空壳」这种情况
      final svc2 = await WordQueryService.open(
        databaseFactoryFfi,
        dbPath,
        externalCardLoader: (sp) async => '{"front":"x","sections":[]}',
      );
      check('缓存是空壳（无 sections）→ null（不给空卡）',
          await svc2.cardById('ext:anyword') == null);
      await svc2.close();

      await svc.close();
    }
  }

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

/// 找仓库里的 `data/word.db`（从本脚本位置往上找）。
String? _findWordDb() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final p = '${dir.path}${Platform.pathSeparator}data'
        '${Platform.pathSeparator}word.db';
    if (File(p).existsSync()) return p;
    dir = dir.parent;
  }
  return null;
}
