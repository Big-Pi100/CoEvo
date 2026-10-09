/// 端侧翻译的**编排 + 契约**验收断言（纯 Dart · 零 Flutter · 零网络）。
///
/// # 为什么这些断言必须以「注入假实现」的方式跑
/// `translation_service.dart` 把四个外部能力都做成参数 ⇒ 每条分支都能**真跑**
/// （而不是靠真机点）。若当初写成直接 `ref.read(...)`，下面这些用例就只能靠手测
/// —— 那等于没有回归防线。
///
/// # 跑法
/// ```bash
/// cd scripts/query_verify && dart run bin/verify_translation_service.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import '../../../app/lib/services/ondevice_translate.dart';
import '../../../app/lib/services/translate_parse.dart';
import '../../../app/lib/services/translation_service.dart';

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

/// 列表的**深度**比较。
///
/// 🔴 为什么必须有它：Dart 的 `List` **不覆写 `==`**（是引用相等）⇒
///    两个内容完全相同的列表用 `eq` 比**必然假红**。
///    （踩过：`实得 [One., Two.] · 期望 [One., Two.]` 看着一模一样却不通过。）
void eqList(String label, List<String> actual, List<String> expected) {
  final ok = actual.length == expected.length &&
      List.generate(actual.length, (i) => actual[i] == expected[i]).every((x) => x);
  check(label, ok, ok ? '' : '实得 $actual · 期望 $expected');
}

/// 按**整行**剥掉注释行。
///
/// 🔑 项目判据：**「注释里提到」≠「代码里写了」** —— 计数类断言必须先剥注释，
///    否则自己写的解释性注释会把计数顶上去（踩过多次）。
String codeOnly(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// 切出 `from` 之后、`to` 之前的一段（找不到返回空串 ⇒ 由断言报红）。
String slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = s.indexOf(to, a + from.length);
  return b < 0 ? s.substring(a) : s.substring(a, b);
}

// ══════════════════════════════════════════════════════════════════════
// ① 预扣响应解析（纯函数）
// ══════════════════════════════════════════════════════════════════════

void _prepayParsing() {
  section('① parsePrepayBody：四种结局 + 边界');

  check('401 ⇒ 未登录（**不是**失败）', parsePrepayBody('', 401) is PrepayNeedLogin);

  final q403 = parsePrepayBody(
      jsonEncode({'error': '本月翻译额度已用完（10 次），下月 1 日重置'}), 403);
  check('403 ⇒ 额度用尽', q403 is PrepayQuotaExceeded);
  check('…文案**取服务端给的**（不自己拼）',
      q403 is PrepayQuotaExceeded && q403.message.contains('下月 1 日重置'),
      q403 is PrepayQuotaExceeded ? q403.message : '');

  final ok = parsePrepayBody(
      jsonEncode({
        'quota': {'used': 3, 'limit': 10, 'subscribed': false},
        'ticket': 'tk-abc',
      }),
      200);
  check('200 ⇒ PrepayOk', ok is PrepayOk);
  if (ok is PrepayOk) {
    eq('…ticket 取出', ok.ticket, 'tk-abc');
    eq('…used', ok.used, 3);
    eq('…limit', ok.limit, 10);
    eq('…subscribed', ok.subscribed, false);
  }

  final sub = parsePrepayBody(
      jsonEncode({
        'quota': {'used': 1, 'subscribed': true}
      }),
      200);
  check('订阅用户：limit 缺省 ⇒ null（**不是 0**）',
      sub is PrepayOk && sub.limit == null, sub is PrepayOk ? '${sub.limit}' : '');
  check('…ticket 可以缺席（订阅不需要）', sub is PrepayOk && sub.ticket == null);

  final emptyTicket = parsePrepayBody(
      jsonEncode({
        'quota': {'used': 0, 'limit': 10, 'subscribed': false},
        'ticket': '',
      }),
      200);
  check('🔴 空串 ticket 视为**没有**（免得把 "" 当有效凭据）',
      emptyTicket is PrepayOk && emptyTicket.ticket == null);

  check('500 ⇒ 失败', parsePrepayBody('boom', 500) is PrepayFailed);
  check('200 但畸形 JSON ⇒ 失败',
      parsePrepayBody('{not json', 200) is PrepayFailed);
  check('200 但不是对象 ⇒ 失败', parsePrepayBody('[1,2]', 200) is PrepayFailed);
}

// ══════════════════════════════════════════════════════════════════════
// ② 分句（纯函数）
// ══════════════════════════════════════════════════════════════════════

void _splitting() {
  section('② splitSentences：分句边界');

  eqList('空串 ⇒ []', splitSentences('   '), <String>[]);
  eqList('无句末标点 ⇒ 整段一句', splitSentences('hello world'), ['hello world']);
  eqList('两句', splitSentences('One. Two.'), ['One.', 'Two.']);
  eqList('问号感叹号也断', splitSentences('Really? Yes!'), ['Really?', 'Yes!']);

  // 🔴 最重要的一条：缩写不能被从**中间**切断（`a.m.` / `U.S.` 内部不能断）
  eqList('🔴 `a.m.` 内部不被切断', splitSentences('I woke at 7 a.m. It was cold.'),
      ['I woke at 7 a.m.', 'It was cold.']);

  // ⚠️ 下面这条锁的是**已知局限**，不是「正确行为」——
  //    缩写**后面**的点会被当句末 ⇒ 切出更碎的一行对照。
  //    不改的原因：完美分句需要 NLP（缩写词典 + 上下文），而端侧只是**加速层**
  //    （服务端 LLM 分段没有这个问题）。
  //    🔑 若将来引入缩写白名单，**请连带更新这条断言** ——
  //      否则它会变成「保护一个已经修掉的行为」的反向假红。
  eqList('⚠️ 已知局限：`U.S.` **后**的点被当句末（会切碎一行）',
      splitSentences('The U.S. is large.'), ['The U.S.', 'is large.']);

  eqList('连续标点算一句结束', splitSentences('Wait?! Now.'), ['Wait?!', 'Now.']);
  eqList('收尾引号并入前一句', splitSentences('He said "go." Then left.'),
      ['He said "go."', 'Then left.']);
  eqList('中文全角标点', splitSentences('你好。你好吗？'), ['你好。', '你好吗？']);
  eqList('末尾无标点也收尾', splitSentences('One. Two'), ['One.', 'Two']);

  // 段数上限
  final many = List.generate(300, (i) => 'S$i.').join(' ');
  final capped = splitSentences(many);
  check('段数被压到上限（不爆炸）', capped.length <= kMaxOnDeviceSegments,
      '${capped.length}');
  check('…合并后的最后一段仍含内容', capped.last.contains('S299'));
}

// ══════════════════════════════════════════════════════════════════════
// ③ 编排：每条分支都真跑
// ══════════════════════════════════════════════════════════════════════

/// 一次编排跑下来的「事实记录」——用它断言**调了什么、没调什么**。
class _Probe {
  final calls = <String>[];
  String? ticketSeen;
  bool prepayCalled = false;
  bool onDeviceCalled = false;
  bool serverCalled = false;
}

Future<({TranslatePathOutcome out, _Probe p})> _run({
  required OnDeviceTranslateStatus status,
  required PrepayResult Function() prepay,
  List<String>? onDeviceResult,
  int? onDeviceOnlyFirstN,
  TranslateResult? serverResult,
}) async {
  final p = _Probe();
  final out = await translateWithFallback(
    text: 'One. Two.',
    probeOnDevice: () async {
      p.calls.add('probe');
      return status;
    },
    prepay: (t) async {
      p.calls.add('prepay');
      p.prepayCalled = true;
      return prepay();
    },
    translateOnDevice: (texts) async {
      p.calls.add('ondevice');
      p.onDeviceCalled = true;
      if (onDeviceResult == null) return null;
      final n = onDeviceOnlyFirstN ?? texts.length;
      return onDeviceResult.take(n).toList();
    },
    translateViaServer: (t, {String? ticket}) async {
      p.calls.add('server');
      p.serverCalled = true;
      p.ticketSeen = ticket;
      return serverResult ??
          const TranslateReady(
            segments: [TransSegment(src: 'x', dst: 'y')],
            used: 1,
            limit: 10,
            subscribed: false,
          );
    },
  );
  return (out: out, p: p);
}

Future<void> _orchestration() async {
  section('③ translateWithFallback：分支');

  // ── 端侧不可用 / 未下载 ⇒ 走服务端，**完全不碰预扣** ──
  for (final s in [
    OnDeviceTranslateStatus.unavailable,
    OnDeviceTranslateStatus.unsupported,
    OnDeviceTranslateStatus.supported, // 🟡 语言包没下载 ⇒ 不等下载
  ]) {
    final r = await _run(status: s, prepay: () => const PrepayFailed(message: 'x'));
    eq('端侧 $s ⇒ 走服务端', r.p.serverCalled, true);
    eq('🔴 …且**没有**预扣（不会白扣一次）', r.p.prepayCalled, false);
    eq('…也没调端侧', r.p.onDeviceCalled, false);
  }

  // ── 预扣的三种「不成功」⇒ 都不翻 ──
  final login = await _run(status: OnDeviceTranslateStatus.installed, prepay: () => const PrepayNeedLogin());
  check('预扣 401 ⇒ TranslateNeedLogin', login.out.result is TranslateNeedLogin);
  eq('🔴 …**不调端侧**（没额度还想翻 = 架空闸门）', login.p.onDeviceCalled, false);

  final quota = await _run(
      status: OnDeviceTranslateStatus.installed,
      prepay: () => const PrepayQuotaExceeded(message: '本月翻译额度已用完'));
  check('预扣 403 ⇒ TranslateQuotaExceeded', quota.out.result is TranslateQuotaExceeded);
  eq('…不调端侧', quota.p.onDeviceCalled, false);

  final prepayFail = await _run(
      status: OnDeviceTranslateStatus.installed,
      prepay: () => const PrepayFailed(message: '连不上服务'));
  eq('🔑 预扣失败 ⇒ **回落服务端**（不是直接失败）', prepayFail.p.serverCalled, true);
  check('…且**不冒充额度用尽**（网络问题不该被伪造成业务结论）',
      prepayFail.out.result is! TranslateQuotaExceeded);
  eq('🔴 …**不调端侧**（没拿到服务端放行就不该本地翻）', prepayFail.p.onDeviceCalled, false);
  eq('…回落时**不带凭据**（本来就没有）', prepayFail.p.ticketSeen, null);

  // ── 预扣成功 + 端侧成功 ──
  final happy = await _run(
    status: OnDeviceTranslateStatus.installed,
    prepay: () => const PrepayOk(ticket: 'tk-1', used: 1, limit: 10, subscribed: false),
    onDeviceResult: ['一。', '二。'],
  );
  check('端侧成功 ⇒ TranslateReady', happy.out.result is TranslateReady);
  eq('…标记走了端侧', happy.out.onDevice, true);
  if (happy.out.result is TranslateReady) {
    final r = happy.out.result as TranslateReady;
    eq('…段数 = 原文句数', r.segments.length, 2);
    eq('…第 1 段 src 是切好的句子', r.segments[0].src, 'One.');
    eq('…第 1 段 dst 是端侧译文', r.segments[0].dst, '一。');
    eq('…额度回显取自预扣（used）', r.used, 1);
    eq('…limit 取自预扣', r.limit, 10);
  }
  eq('…没走服务端', happy.p.serverCalled, false);

  // ── 预扣成功 + 端侧失败 ⇒ 回落，且**带凭据** ──
  final fallback = await _run(
    status: OnDeviceTranslateStatus.installed,
    prepay: () => const PrepayOk(ticket: 'tk-9', used: 1, limit: 10, subscribed: false),
    onDeviceResult: null,
  );
  eq('端侧失败 ⇒ 走服务端', fallback.p.serverCalled, true);
  eq('🔴 **回落时带上了凭据**（服务端据此不再扣额）', fallback.p.ticketSeen, 'tk-9');
  eq('…结果来自服务端', fallback.out.onDevice, false);

  // ── 端侧返回条数不匹配 ⇒ 也算失败 ⇒ 回落 ──
  final mismatch = await _run(
    status: OnDeviceTranslateStatus.installed,
    prepay: () => const PrepayOk(ticket: 'tk-8', used: 1, limit: 10, subscribed: false),
    onDeviceResult: ['只有一段'],
  );
  eq('🔴 条数不匹配 ⇒ 回落（错位比失败更糟）', mismatch.p.serverCalled, true);
  eq('…同样带凭据', mismatch.p.ticketSeen, 'tk-8');

  // ── 订阅用户：ticket 为 null ⇒ 回落时也不带 ──
  final sub = await _run(
    status: OnDeviceTranslateStatus.installed,
    prepay: () => const PrepayOk(ticket: null, used: 5, limit: null, subscribed: true),
    onDeviceResult: null,
  );
  eq('订阅用户回落：ticket 为 null', sub.p.ticketSeen, null);
  check('…结果来自服务端', sub.p.serverCalled);
}

// ══════════════════════════════════════════════════════════════════════
// ④ 调用顺序
// ══════════════════════════════════════════════════════════════════════

Future<void> _ordering() async {
  section('④ 调用顺序：先判可用 → 再预扣 → 再端侧翻');

  final r = await _run(
    status: OnDeviceTranslateStatus.installed,
    prepay: () => const PrepayOk(ticket: 't', used: 1, limit: 10, subscribed: false),
    onDeviceResult: ['一。', '二。'],
  );
  eq('调用序列', r.p.calls.join(' → '), 'probe → prepay → ondevice');

  final skip = await _run(
    status: OnDeviceTranslateStatus.unavailable,
    prepay: () => const PrepayFailed(message: 'x'),
  );
  eq('端侧不可用时：只剩 probe → server', skip.p.calls.join(' → '), 'probe → server');
}

// ══════════════════════════════════════════════════════════════════════
// ⑤ 源码级：口径只有一处 / 无第二份实现
// ══════════════════════════════════════════════════════════════════════

void _sourceLevel() {
  section('⑤ 源码级');

  final binDir = File.fromUri(Platform.script).parent;
  final repoRoot = binDir.parent.parent.parent;
  String src(String rel) => File('${repoRoot.path}/$rel').readAsStringSync();

  final svc = src('app/lib/services/translation_service.dart');
  final dev = src('app/lib/services/ondevice_translate.dart');
  final cli = src('app/lib/api/ondevice_translate_client.dart');
  final app = src('app/lib/api/translate_client.dart');

  check('编排层**不含** Flutter 依赖（可被本脚本直接 import）',
      !svc.contains("package:flutter") && !dev.contains("package:flutter"));
  eq('分句器只有一处定义',
      RegExp(r'^List<String> splitSentences\(', multiLine: true).allMatches(dev).length,
      1);
  eq('平台通道名只有一处定义',
      RegExp(r"coevo/ondevice_translate").allMatches(cli).length, 1);
  check('🔴 通道名与 Swift 侧一致（照抄同一字面量）', cli.contains("'coevo/ondevice_translate'"));

  // ⚠️ 必须**剥注释**再数 —— 我自己的文档注释里也写到了这个路径
  eq('预扣接口路径在**代码**里只有一处',
      RegExp(r'/api/translate/quota').allMatches(codeOnly(app)).length, 1);

  // 🔑 用**切片**证明「预扣」与「翻译」走两个不同端点。
  //    ⚠️ 不能只查 `contains('/api/translate')` —— 它是 quota 路径的**前缀**，恒真。
  // ⚠️ 用 `codeOnly` 切片 —— 否则会把 prepayQuota 的**文档注释**（里面同样写着
  //    这个路径）一起框进来 ⇒ 假红（踩过）。
  final appCode = codeOnly(app);
  final prepaySeg = slice(appCode, 'Future<PrepayResult> prepayQuota', 'void dispose()');
  final transSeg = slice(
      appCode, 'Future<TranslateResult> translate(', 'Future<PrepayResult> prepayQuota');
  check('…能切出两个方法的片段（下面断言的前提）',
      prepaySeg.isNotEmpty && transSeg.isNotEmpty);
  check('🔑 预扣走 `/api/translate/quota`', prepaySeg.contains('/api/translate/quota'));
  check('🔑 翻译走 `/api/translate`（且**不带** quota 后缀）',
      transSeg.contains('/api/translate') && !transSeg.contains('/api/translate/quota'));

  // 🔴 上线顺序的守护：预扣失败必须**回落**，不能直接返回失败。
  //    否则「新 App + 旧服务端（没有 quota 路由 ⇒ 404）」会让 iOS 18+ 用户
  //    **连翻译都用不了**（其余用户反而正常）。
  final svcCode = codeOnly(svc);
  final prepayFailSeg = slice(svcCode, 'case PrepayFailed():', 'case PrepayOk(');
  check('…能切出 PrepayFailed 分支（下面断言的前提）', prepayFailSeg.isNotEmpty);
  check('🔴 预扣失败走 `translateViaServer`（回落），而不是直接返回失败',
      prepayFailSeg.contains('translateViaServer(text)'));

  // 🔴 服务端侧：预扣与正常翻译必须共用一个额度函数（口径只有一处）
  final rs = src('backend/crates/api_server/src/translation.rs');
  check('Rust：预扣里调用的是同一个 try_consume_quota',
      rs.contains('consume_quota_on_conn') &&
          RegExp(r'try_consume_quota\(').allMatches(rs).length >= 2);
  check('Rust：凭据是**消费即删**（take_ticket 里有 remove）',
      RegExp(r'fn take_ticket').hasMatch(rs) && rs.contains('m.remove(ticket)'));
}

// ══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  _prepayParsing();
  _splitting();
  await _orchestration();
  await _ordering();
  _sourceLevel();

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
