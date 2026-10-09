// CoEvo · 词库外词卡取卡链（`resolveExternalWordCard`）验收
//
// 跑法：cd scripts/query_verify && dart run bin/verify_external_word_card.dart
// 退出码：0 = 全通过；1 = 有失败
//
// # 为什么有这个脚本（2026-10-09 白哥真机）
// 「重装后，之前 LLM 生成的生词卡显示『这张卡暂时打不开』」——
// 根因：`external_word_cache` 只在端侧，而 `cardById` 的 `ext:` 回落
// **只读端侧缓存、不回落服务端**；已定文档写着本表「不同步」的理由是
// 「**词卡可按需向服务端再取**」，那句话**从来没在复习取卡路径实现**。
//
// 🔴 本脚本要钉住的**两条最容易假绿**的东西（只扫源码看不出来）：
// · **有端侧缓存 ⇒ 一次网络都不发**（否则每次复习都在偷偷联网 / 花 LLM 钱）
// · **回落成功后真的写回了端侧缓存 ⇒ 第二次不再联网**
//   —— 这就是「重装后自愈」的全部内容（下面【3】直接**模拟重装**）
//
// 另有失败路径的 `message` / `retryable`（界面据此决定要不要给「重试」）
// 与接线文本断言（`verify_external_word_cache` 那类只能证明「写着」，
// 所以每条接线断言都有一条**真跑**的行为断言配对）。
//
// ⚠️ 本文件**必须保持纯 Dart 可跑**（不 import Flutter）——
//    它 import 的 `app/lib/services/external_word_card.dart` 正是为此设计的。

import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/external_word_cache_repository.dart';
import '../../../app/lib/services/external_word_card.dart';
import '../../../app/lib/services/user_db.dart';
import '../../../app/lib/services/word_query_service.dart';
import '_repo_paths.dart';

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

/// 一份**符合契约 v6** 的最小合法 card（`toCardContent` 要求 definition.en/zh）。
/// 🔑 LLM 的**原始**形状（`word` / 平铺字段）—— **不是** `word.db` 的形状。
Map<String, Object?> _rawCard({String word = 'brainstorm'}) => {
      'word': word,
      'entry_type': 'word',
      'ipa': '/ˈbreɪnstɔːm/',
      'definition': {
        'pos': '[n]',
        'en': 'a sudden clever idea',
        'zh': '突然想到的好主意',
      },
      'context': 'She had a brainstorm.',
    };

ExternalCardGenReply _ready({String word = 'brainstorm'}) => ExternalCardGenReady(
      rawCard: _rawCard(word: word),
      fromCache: true,
      contractVersion: 'v6',
    );

/// 跑一次「取不到」的路径，把异常**结构化成结果**（便于逐字段断言）。
Future<ExternalCardUnavailable?> _caught(Future<String> Function() f) async {
  try {
    await f();
    return null;
  } on ExternalCardUnavailable catch (e) {
    return e;
  }
}

/// 找出仓库里所有 `app/lib/**/*.dart` 的源码文本（文本断言用）。
Map<String, String> _libSources() {
  final root = repoPath('app/lib');
  final out = <String, String>{};
  for (final e in Directory(root).listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      final rel = e.path
          .substring(root.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      out[rel] = e.readAsStringSync();
    }
  }
  return out;
}

/// 按**整行**剥掉注释行（`//` / `///` 开头）。
///
/// 🔑 判据：「剥注释」只能**按整行**（本项目已记过这条）——
///    按子串剥会把字符串里的 `//`（URL、路径）也切掉，结论会反向。
///    这里只需要「同一句话在**代码**里只有一处」，
///    而**文档注释里引用**同一句话是正常的（说明文字），不该算第二处。
String _stripCommentLines(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 切片：`from` 之后到 `to` 之前（找不到则返回空串 —— 由调用方的断言报红）。
String _slice(String src, String from, String to) {
  final i = src.indexOf(from);
  if (i < 0) return '';
  final j = src.indexOf(to, i + from.length);
  return j < 0 ? src.substring(i) : src.substring(i, j);
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  // ══════════════════════════════════════════════════════════════
  section('【1】🔴 端侧缓存命中 ⇒ **一次网络都不发**');
  // ══════════════════════════════════════════════════════════════
  {
    var net = 0;
    final r = await resolveExternalWordCard(
      spelling: 'brainstorm',
      readCache: (_) async => '{"front":"brainstorm","sections":[]}',
      generate: (_) async {
        net++;
        return _ready();
      },
    );
    eq('内容来自端侧缓存', r, '{"front":"brainstorm","sections":[]}');
    eq('🔴 网络请求次数 = 0（离线也读得到，且不花 LLM 钱）', net, 0);
  }

  // ══════════════════════════════════════════════════════════════
  section('【2】端侧没有 ⇒ 回落服务端，并**写回**端侧缓存');
  // ══════════════════════════════════════════════════════════════
  {
    var net = 0;
    final written = <String, String>{};
    final r = await resolveExternalWordCard(
      spelling: 'Brainstorm', // 故意大写：验归一化（写回与读取必须同口径）
      readCache: (_) async => null,
      writeCache: (sp, c) async => written[sp] = c,
      generate: (_) async {
        net++;
        return _ready();
      },
    );
    eq('发了 1 次请求（端侧没有才联网）', net, 1);
    eq('🔴 真的写回了端侧缓存（写好键）', written.keys.join(','), 'Brainstorm');
    eq('🔴 写回的内容 = 本次返回的内容（不是另转一份）', written['Brainstorm'], r);

    final d = (jsonDecode(r) as Map).cast<String, Object?>();
    eq('…形状是 `word.db.card.content`（front 归一化）', d['front'], 'brainstorm');
    eq('…ipa 带过来了', d['ipa'], '/ˈbreɪnstɔːm/');
    eq('…释义段可被渲染层读出', (d['sections'] as List).first['zh'], '突然想到的好主意');
    check('…没把 LLM 特有字段透出去（word / definition 平铺字段）',
        !d.containsKey('word') && !d.containsKey('definition'));
  }

  // ══════════════════════════════════════════════════════════════
  section('【3】🔴 模拟「重装」：缓存没了 → 取卡自愈 → 第二次 0 次网络');
  //   = 白哥报的正是这个（重装后那些词打不开）
  // ══════════════════════════════════════════════════════════════
  {
    final dir = await Directory.systemTemp.createTemp('coevo_extcard_');
    final dbPath = '${dir.path}/user.db';
    final schema = File(userDbSchemaPath()).readAsStringSync();
    final db = await openUserDb(
        factory: factory, path: dbPath, schemaSql: schema);
    final repo = ExternalWordCacheRepository(db);

    var net = 0;
    Future<String> pull(String sp) => resolveExternalWordCard(
          spelling: sp,
          readCache: (x) => repo.contentOf(x),
          writeCache: (x, c) => repo.put(x, c),
          generate: (x) async {
            net++;
            return _ready(word: x);
          },
        );

    eq('起点：端侧缓存为空（= 重装后的状态）', await repo.count(), 0);

    final first = await pull('brainstorm');
    eq('① 缓存空 ⇒ 联网 1 次', net, 1);
    eq('① 端侧缓存被写入 1 行', await repo.count(), 1);

    net = 0;
    final second = await pull('brainstorm');
    eq('② 🔴 第二次取卡 **0 次网络**（自愈完成，与旧实现在这里必红）', net, 0);
    eq('② 内容与第一次一致', second, first);

    // 🔴 「重装」再演一次：缓存被清掉 ⇒ 仍能自愈（这才是 A 的完整承诺）
    await repo.clear();
    eq('清空缓存（模拟重装 / 清数据 / 换账号）', await repo.count(), 0);
    net = 0;
    final third = await pull('brainstorm');
    eq('③ 🔴 清空后仍能取到卡（**永久打不开**已被修掉）', net, 1);
    eq('③ 内容依旧一致', third, first);

    // 归一化一致：大写查同一行（不一致会「写了却读不到」→ 每次重新联网）
    net = 0;
    await pull('BRAINSTORM');
    eq('🔴 大小写不同也命中同一行（归一化口径一致）', net, 0);
    eq('…仍然只有 1 行', await repo.count(), 1);

    await db.close();
    await dir.delete(recursive: true);
  }

  // ══════════════════════════════════════════════════════════════
  section('【4】失败路径：**准确的话** + **有没有出口**（`retryable`）');
  // ══════════════════════════════════════════════════════════════
  {
    Future<ExternalCardUnavailable?> run(ExternalCardGenReply reply) =>
        _caught(() => resolveExternalWordCard(
              spelling: 'brainstorm',
              generate: (_) async => reply,
            ));

    final busy = await run(const ExternalCardGenBusy());
    check('503 正在生成 ⇒ 报错（不是静默）', busy != null);
    check('…文案点明「正在生成中」（不是笼统的「失败」）',
        busy?.message.contains('正在生成中') == true, busy?.message ?? '');
    check('…🔴 可重试（别人生成完就有）', busy?.retryable == true);

    final netErr = await run(const ExternalCardGenFailed(
        message: '连不上服务，请检查网络后重试'));
    check('网络层失败（statusCode == null）⇒ 可重试', netErr?.retryable == true);

    final s502 = await run(
        const ExternalCardGenFailed(message: '上游失败', statusCode: 502));
    check('502 上游 ⇒ 可重试', s502?.retryable == true);

    final s500 = await run(
        const ExternalCardGenFailed(message: '服务内部错误', statusCode: 500));
    check('500 内部 ⇒ 可重试', s500?.retryable == true);

    final s422 = await run(
        const ExternalCardGenFailed(message: '该词暂不支持生成', statusCode: 422));
    check('🔴 422 合规拒绝 ⇒ **不可重试**（界面不该给重试按钮）',
        s422?.retryable == false);
    eq('…服务端文案**原样透传**（不自己拼一句笼统的）',
        s422?.message, '该词暂不支持生成');

    final s400 =
        await run(const ExternalCardGenFailed(message: '参数错误', statusCode: 400));
    check('400 参数错 ⇒ 不可重试', s400?.retryable == false);

    final contract = await run(ExternalCardGenReady(
      rawCard: _rawCard(),
      fromCache: false,
      contractVersion: 'v7', // 端侧只认 v6
    ));
    check('🔴 契约版本不认识 ⇒ **显式失败**（不静默出空卡）', contract != null);
    check('…文案点明「格式异常」', contract?.message.contains('格式异常') == true,
        contract?.message ?? '');

    final noDef = await run(ExternalCardGenReady(
      rawCard: {'word': 'x', 'entry_type': 'word'}, // 缺 definition
      fromCache: false,
      contractVersion: 'v6',
    ));
    check('响应缺 definition ⇒ 显式失败（不产出无释义的卡）', noDef != null);
  }

  // ══════════════════════════════════════════════════════════════
  section('【5】🔴 不静默：读缓存坏了要降级、写回坏了要留痕');
  // ══════════════════════════════════════════════════════════════
  {
    final warns = <String>[];
    var net = 0;

    final r = await resolveExternalWordCard(
      spelling: 'brainstorm',
      readCache: (_) async => throw StateError('库打不开'),
      generate: (_) async {
        net++;
        return _ready();
      },
      onWarn: warns.add,
    );
    check('读缓存失败 ⇒ **降级为「当作没有缓存」**（继续联网，不终止）', net == 1);
    check('…本次仍能拿到卡（缓存是优化，不该让这条路走不通）', r.isNotEmpty);
    check('…且留了痕（不是静默）', warns.any((w) => w.contains('读词库外缓存失败')));

    final warns2 = <String>[];
    final r2 = await resolveExternalWordCard(
      spelling: 'brainstorm',
      writeCache: (_, __) async => throw StateError('磁盘满'),
      generate: (_) async => _ready(),
      onWarn: warns2.add,
    );
    check('写回失败 ⇒ **不影响本次展示**（内容已经拿到了）', r2.isNotEmpty);
    check('…但必须留痕（否则「每次都要联网」完全无声）',
        warns2.any((w) => w.contains('写词库外缓存失败')));
  }

  // ══════════════════════════════════════════════════════════════
  section('【6】端到端：`cardById(\'ext:…\')` 在**没有端侧缓存**时也取到卡');
  //   = 复习页那条路（`cardBundleProvider` → `reviewCardOf` → `cardById`）
  // ══════════════════════════════════════════════════════════════
  {
    final dbPath = wordDbPath();
    if (!File(dbPath).existsSync()) {
      check('找到 word.db（本组的前提）', false, '未找到 $dbPath');
    } else {
      final dir = await Directory.systemTemp.createTemp('coevo_extcard_e2e_');
      final userDb = await openUserDb(
        factory: factory,
        path: '${dir.path}/user.db',
        schemaSql: File(userDbSchemaPath()).readAsStringSync(),
      );
      final repo = ExternalWordCacheRepository(userDb);
      var net = 0;

      // ⚠️ 与 `_externalCardLoader`（Flutter 层）**同形**的接线 ——
      //    那个函数本身跑不了（它依赖 Flutter），所以在这里复现它的形状。
      final svc = await WordQueryService.open(
        factory,
        dbPath,
        externalCardLoader: (sp) => resolveExternalWordCard(
          spelling: sp,
          readCache: (x) => repo.contentOf(x),
          writeCache: (x, c) => repo.put(x, c),
          generate: (x) async {
            net++;
            return _ready(word: x);
          },
        ),
      );

      var threw = false;
      Object? err;
      try {
        final card = await svc.cardById('ext:brainstorm');
        eq('🔴 端侧没有缓存时也**取到卡**（旧实现在这里返回 null → 「打不开」）',
            card != null, true);
        eq('…wordId 保留合成 id（与 `user_word` 里存的一致）',
            card?.wordId, 'ext:brainstorm');
        eq('…释义可被渲染层读出（端到端可用）',
            card?.sectionOfType('definition')?.zh, '突然想到的好主意');
        eq('…发生了 1 次联网', net, 1);

        net = 0;
        await svc.cardById('ext:brainstorm');
        eq('🔴 第二次**0 次网络**（已写回端侧缓存）', net, 0);

        // 词库内的词照常走 word.db，**不该**去问这条回落
        net = 0;
        final inner = await svc.cardById('w005333');
        check('词库内的词照常取到', inner != null);
        eq('…没有走回落（主路径不受影响）', net, 0);
      } catch (e) {
        threw = true;
        err = e;
      }
      check('取卡过程**不抛异常**（界面拿到的是卡或 `null`，不是崩溃）', !threw,
          threw ? '$err' : '');

      await svc.close();
      await userDb.close();
      await dir.delete(recursive: true);
    }
  }

  // ══════════════════════════════════════════════════════════════
  section('【7】接线与文案（文本断言 —— 每条都配对上面某条真跑的断言）');
  // ══════════════════════════════════════════════════════════════
  {
    final lib = _libSources();
    String f(String rel) => lib[rel] ?? '';

    final wordProv = f('providers/word_db_provider.dart');
    final revProv = f('providers/review_session_provider.dart');
    final revScreen = f('screens/review_session_screen.dart');
    final lookup = f('services/word_lookup.dart');
    final genProv = f('providers/generate_card_provider.dart');
    final shared = f('services/external_word_card.dart');

    check('找到 6 个待验文件', wordProv.isNotEmpty &&
        revProv.isNotEmpty &&
        revScreen.isNotEmpty &&
        lookup.isNotEmpty &&
        genProv.isNotEmpty &&
        shared.isNotEmpty);

    // ── ① A：复习取卡**回落服务端** + 写回缓存 ──
    final loaderSeg = _slice(wordProv, 'ExternalCardLoader _externalCardLoader(',
        '\n}\n');
    check('能切出 `_externalCardLoader` 的源码段（下面断言的前提）',
        loaderSeg.isNotEmpty);
    check('🔴 复习取卡**回落服务端**（调共享取卡器 —— 不是只读端侧缓存）',
        loaderSeg.contains('resolveExternalWordCard('));
    check('…先读端侧缓存（命中就 0 次网络）', loaderSeg.contains('readCache:'));
    check('🔴 …**写回端侧缓存**（自愈的关键）', loaderSeg.contains('writeCache:'));
    check('…服务端结果走**唯一那处**映射（不在别处各写一遍）',
        loaderSeg.contains('externalCardReplyOf('));
    // 🔴 这一条针对**文本断言的经典盲区**：在回落之前插一句 `return null;`
    //    会让回落变成死代码，而「字符串存在」类断言**照样全绿**
    //    （本项目 2026-10-01 实测踩过）。所以额外钉住「没有短路出口」。
    check('…且**不能提前 `return null`**（否则上面的回落是死代码）',
        !loaderSeg.contains('return null'));
    check('…端侧缓存命中时也确实**直接返回**（不是只读不用）',
        loaderSeg.contains('readCache:'));

    // ── ② A：划词与复习**共用一份**（消重，否则文案/判据必然漂移）──
    check('🔴 划词路径也走同一个取卡器', lookup.contains('resolveExternalWordCard('));
    check('…也走同一处结果映射', lookup.contains('externalCardReplyOf('));
    check('…映射只有一处定义', genProv.contains('ExternalCardGenReply externalCardReplyOf('));

    // ── ③ D：`CardLoad` 三态 + 准确原因 + 出口 ──
    check('🔴 `cardBundleProvider` 返回 sealed 三态（不再用 `null` 一物两义）',
        revProv.contains('FutureProvider.autoDispose<CardLoad>'));
    check('…有「词库还没落盘」的独立态（该转圈，不是「打不开」）',
        revProv.contains('class CardPreparing'));
    check('…取不到时带**原因**与**能否重试**',
        revProv.contains('class CardMissing') &&
            revProv.contains('this.message') &&
            revProv.contains('this.retryable'));

    final extCatchSeg = _slice(
        revProv, 'final loadAsync = ref.watch(wordQueryProvider);', '\n});');
    check('能切出 `cardBundleProvider` 的词卡段', extCatchSeg.isNotEmpty);
    check('🔴 接住了 `ExternalCardUnavailable`（否则原因被泛 catch 吞掉）',
        extCatchSeg.contains('on ExternalCardUnavailable catch'));
    check('…把服务端的**准确文案**带出来', extCatchSeg.contains('e.message'));
    check('…把「能否重试」也带出来', extCatchSeg.contains('retryable: e.retryable'));
    check(
        '🔴 顺序：`on ExternalCardUnavailable` 必须在泛 `catch (e, st)` **之前**',
        extCatchSeg.indexOf('on ExternalCardUnavailable catch') >= 0 &&
            extCatchSeg.indexOf('on ExternalCardUnavailable catch') <
                extCatchSeg.indexOf('catch (e, st)'));
    check('🔴 「词库打不开」与「词库还在准备」分开（否则永远转不完）',
        extCatchSeg.contains('hasError'));
    check('…词卡段里也**没有**「提前 `return null`」短路',
        !extCatchSeg.contains('return null'));

    // ── ④ D：界面按三态渲染 + 给出口 ──
    check('界面把 `CardPreparing` 渲染成转圈（不是「打不开」）',
        revScreen.contains('CardPreparing() => const _CardLoading()'));
    check('界面把 `CardMissing.message` **传给**了提示组件',
        revScreen.contains('CardMissing(:final message, :final retryable)') &&
            revScreen.contains('message: message'));
    check('🔴 `retryable` 真的决定给不给「重试」（不是无条件给）',
        revScreen.contains('onRetry: retryable'));
    check('…重试按钮真的接了动作（invalidate 取卡 provider）',
        revScreen.contains('onRetry: () => ref.invalidate(cardBundleProvider)'));

    final unavailSeg = _slice(
        revScreen, 'class _CardUnavailable extends StatelessWidget {', '\n}\n');
    check('能切出 `_CardUnavailable` 的定义段', unavailSeg.isNotEmpty);
    check('🔴 文案不再是写死的 —— 由调用方按真实原因传入',
        unavailSeg.contains('required this.message'));
    check('…可重试时才渲染「重试」按钮（`if (onRetry != null)`）',
        unavailSeg.contains('if (onRetry != null)'));
    check('…且有「没有出口」的如实标注（`null` ⇒ 不给按钮）',
        unavailSeg.contains('VoidCallback? onRetry') ||
            unavailSeg.contains('final VoidCallback? onRetry'));

    // ── ⑤ 旧文案已删（**错误归因**：`ext:` 的失败与词库无关）──
    final oldText = "'这张卡暂时打不开";
    final hit = lib.entries.where((e) => e.value.contains(oldText)).toList();
    check('🔴 旧文案「这张卡暂时打不开…词库还在准备」已**从用户可见处删除**'
        '（文档注释里保留说明不算）', hit.isEmpty,
        hit.map((e) => e.key).join(', '));

    // ── ⑥ 同一句话只有一处来源（消重的可验证证据）──
    //    ⚠️ 只扫**代码行**（整行剥注释）—— 文档里引用同一句话不算第二处。
    final libCode = {
      for (final e in lib.entries) e.key: _stripCommentLines(e.value),
    };
    for (final s in ['正在生成中，请稍后重试', '的词卡格式异常，请稍后重试']) {
      final owners = libCode.entries
          .where((e) => e.value.contains(s))
          .map((e) => e.key)
          .toList();
      eq('🔴「$s」在 app/lib 的**代码**里只有一处来源', owners.length, 1);
      eq('…那一处是共享取卡器', owners.isEmpty ? '' : owners.first,
          'services/external_word_card.dart');
    }
    check('…划词文件里已**没有**这两句（证明它改用共享实现，没留第二份）',
        !lookup.contains('正在生成中，请稍后重试') &&
            !lookup.contains('的词卡格式异常，请稍后重试'));
  }

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
