// 翻译响应解析的验收 —— **纯函数 · 零外部依赖**
//
// 跑法：`cd scripts/query_verify && dart run bin/verify_translate_parse.dart`
//
// # 为什么这些分支必须被覆盖
//
// 「服务返回什么形状」是这个功能**最容易错**、又**最难在真机上复现**的部分 ——
// 要真机覆盖 401 / 403 / 缺字段 / 非 JSON / 空数组，得各造一次真实响应。
// ⇒ 解析被做成纯函数（`services/translate_parse.dart`），这些分支用**一行字符串**就能全测。
//
// 🔴 其中最该守住的一条：**401 不能混进「失败」**。
//    端侧收到 401 的标准处理是「清凭据 → 跳登录」；若提示成「翻译失败」，
//    用户会反复重试一个**永远不会成功**的动作。

import '../../../app/lib/services/translate_parse.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(label);
    print('  ❌ $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void section(String t) {
  print('');
  print('─' * 72);
  print(t);
  print('─' * 72);
}

Future<void> main() async {
  // ══════════════════════════════════════════════════════════════════
  section('【1】200 · 正常形状');
  // ══════════════════════════════════════════════════════════════════

  const oneOk = '{"segments":[{"src":"Hello.","dst":"你好。"}],'
      '"quota":{"used":3,"limit":10,"subscribed":false}}';
  final r1 = parseTranslateBody(oneOk, 200);
  check('单句 ⇒ TranslateReady', r1 is TranslateReady);
  if (r1 is TranslateReady) {
    check('🔴 `segments` 长度 1（**永远是数组** ⇒ 渲染层只需一条路径）',
        r1.segments.length == 1);
    check('src/dst 解析正确', r1.segments.first.src == 'Hello.');
    check('dst 解析正确', r1.segments.first.dst == '你好。');
    check('used 解析正确', r1.used == 3);
    check('limit 解析正确', r1.limit == 10);
    check('subscribed=false', r1.subscribed == false);
  }

  const multi = '{"segments":['
      '{"src":"A.","dst":"甲。"},{"src":"B.","dst":"乙。"},'
      '{"src":"C.","dst":"丙。"}],"quota":{"used":1,"limit":10,"subscribed":false}}';
  final r2 = parseTranslateBody(multi, 200);
  check('多句 ⇒ 三段', r2 is TranslateReady && r2.segments.length == 3);

  // ── quota 的边界 ──
  section('【1b】quota 字段的边界');
  const subOk = '{"segments":[{"src":"A.","dst":"甲。"}],'
      '"quota":{"used":99,"subscribed":true}}';
  final r3 = parseTranslateBody(subOk, 200);
  check('🔴 订阅用户 `limit` 缺省 ⇒ **null**（不限），不是 0',
      r3 is TranslateReady && r3.limit == null, '${r3 is TranslateReady ? r3.limit : "-"}');
  check('subscribed=true', r3 is TranslateReady && r3.subscribed == true);

  const noQuota = '{"segments":[{"src":"A.","dst":"甲。"}]}';
  final r4 = parseTranslateBody(noQuota, 200);
  check('完全没有 quota 字段 ⇒ 仍能出译文（quota 不是必需）', r4 is TranslateReady);
  check('此时 used 落默认 0', r4 is TranslateReady && r4.used == 0);

  // ══════════════════════════════════════════════════════════════════
  section('【2】200 · 形状异常（都不能静默出空浮层）');
  // ══════════════════════════════════════════════════════════════════

  check('缺 segments 字段 ⇒ Failed',
      parseTranslateBody('{"ok":true}', 200) is TranslateFailed);
  check('segments 是空数组 ⇒ Failed',
      parseTranslateBody('{"segments":[]}', 200) is TranslateFailed);
  check('segments 不是数组 ⇒ Failed',
      parseTranslateBody('{"segments":"x"}', 200) is TranslateFailed);
  check('整个 body 不是对象 ⇒ Failed',
      parseTranslateBody('[1,2,3]', 200) is TranslateFailed);
  check('body 不是 JSON ⇒ Failed（网关错误页/HTML 会走到这里）',
      parseTranslateBody('<html>502</html>', 200) is TranslateFailed);

  // 段内字段缺失 ⇒ 丢掉坏条目，但**好的要留下**
  const partlyBad = '{"segments":['
      '{"src":"A.","dst":"甲。"},'
      '{"src":"B."},' // 缺 dst
      '{"src":"C.","dst":"   "},' // 空译文
      '{"dst":"丁。"}' // 缺 src
      ']}';
  final r5 = parseTranslateBody(partlyBad, 200);
  check('🔴 部分坏条目 ⇒ 只留好的（1 段）',
      r5 is TranslateReady && r5.segments.length == 1);

  const allBad = '{"segments":[{"src":"A."},{"src":"B."}]}';
  check('🔴 全部坏条目 ⇒ Failed（**不返回空浮层** —— 那像"翻出来是空的"）',
      parseTranslateBody(allBad, 200) is TranslateFailed);

  // ══════════════════════════════════════════════════════════════════
  section('【3】鉴权与额度的分支（这三者必须分开）');
  // ══════════════════════════════════════════════════════════════════

  check('🔴 401 ⇒ **NeedLogin**（不是 Failed —— 反应完全不同：去登录 vs 重试）',
      parseTranslateBody('{"error":"登录已过期"}', 401) is TranslateNeedLogin);

  final q = parseTranslateBody('{"error":"本月翻译额度已用完（10 次），下月 1 日重置"}', 403);
  check('403 ⇒ QuotaExceeded', q is TranslateQuotaExceeded);
  check('🔴 文案**取自服务端**（含"下月 1 日重置"这种具体信息）',
      q is TranslateQuotaExceeded && q.message.contains('下月 1 日重置'),
      '${q is TranslateQuotaExceeded ? q.message : "-"}');

  final f500 = parseTranslateBody('{"error":"翻译服务异常"}', 500);
  check('500 ⇒ Failed 且带状态码',
      f500 is TranslateFailed && f500.statusCode == 500);

  final fBody = parseTranslateBody('<html>nginx</html>', 502);
  check('502 非 JSON 错误体 ⇒ Failed（有兜底文案，不抛异常）',
      fBody is TranslateFailed && fBody.message.isNotEmpty);

  // ══════════════════════════════════════════════════════════════════
  section('【4】错误文案的兜底');
  // ══════════════════════════════════════════════════════════════════

  check('有 `error` 字段 ⇒ 用它',
      errorMessageOf('{"error":"具体原因"}') == '具体原因');
  check('`error` 是空白 ⇒ 用兜底文案',
      errorMessageOf('{"error":"   "}').contains('翻译失败'));
  check('无 `error` 字段 ⇒ 用兜底文案',
      errorMessageOf('{"msg":"x"}').contains('翻译失败'));
  check('非 JSON ⇒ 用兜底文案（**不抛**）',
      errorMessageOf('not json').contains('翻译失败'));

  print('');
  print('═' * 72);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('❌ 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('   · $f');
    }
  }
  print('═' * 72);
  if (_failures.isNotEmpty) {
    throw StateError('有未通过项');
  }
}
