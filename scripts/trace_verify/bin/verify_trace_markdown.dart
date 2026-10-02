// CoEvo · 痕迹标记注入验收（S4 · Markdown 渲染路径）
//
// 为什么需要本脚本：S4 把正文渲染换成 Markdown 后，痕迹改走「**源里插标记**」——
// 这条路上有一类**只会静默出错**的 bug：
//   · 往**代码块**里插了控制字符 → 代码内容被污染（代码块本该原样呈现）
//   · 往**链接 URL** 里插了 → 🔴 **链接直接失效**（而且不报错，只是点不开）
//   · 重复调用 → 双层标记
// 这些都不会抛异常，肉眼也难发现 —— 所以必须由断言锁死。
//
// 🔑 本组最强的一条是【0】：**剥掉控制字符后必须与原文完全相同** ——
//    它一句就覆盖了「只加不清、不改内容」这整类风险。
//
// ⚠️ 本脚本**查不出**的（如实列出）：
//   · `gpt_markdown` 是否真的把标记渲染成带样式的 span（需 Flutter 环境）
//   · 痕迹在两档下的**视觉可辨性**（肉眼 —— 文本断言验不到「好看」）
//
// 跑法：`cd scripts/trace_verify && dart run bin/verify_trace_markdown.dart`
// 退出码：有失败 → 1

import 'dart:io';

import '../../../app/lib/services/trace_markdown_source.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = [];

void check(String desc, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $desc${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _fail++;
    _failures.add(desc);
    print('  🔴 $desc${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

void eq(String desc, Object? actual, Object? expected) => check(
      desc,
      actual == expected,
      actual == expected ? '' : '实得 ${_vis('$actual')} · 期望 ${_vis('$expected')}',
    );

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

/// 把控制字符显示成 `⟦1⟧` / `⟦2⟧`，便于读失败用例。
String _vis(String s) => s
    .replaceAll(kTraceFreshOpen, '⟦1⟧')
    .replaceAll(kTraceReviewingOpen, '⟦2⟧');

/// 剥掉所有痕迹控制字符。
String _strip(String s) =>
    s.replaceAll(kTraceFreshOpen, '').replaceAll(kTraceReviewingOpen, '');

/// 数一段文本里某档标记的**对数**。
int _countTier(String s, int tier) {
  final m = traceMarkerOf(tier);
  return s.split(m).length - 1; // 每对标记贡献 2 个字符
}

void main() {
  print('═' * 74);
  print('痕迹标记注入验收（S4 · Markdown 路径）');
  print('═' * 74);

  // ══════════════════════════════════════════════════════════════
  section('【0】🔑 核心不变量：只加控制字符，**不改动任何可见内容**');
  {
    final cases = <String, String>{
      '普通段落': 'A great achievement indeed, and a solid start.',
      '含 Markdown 语法': '## 标题\n\n正文有 **bold** 与 `code` 和 [link](http://a/b)。',
      '围栏代码块': '前文\n\n```dart\nvoid main() { start(); }\n```\n\n后文 start。',
      '行内代码': '看 `start` 这个 API，以及 start 这个词。',
      '链接': '点 [start here](http://x/start) 看看。',
      '列表与引用': '- 第一项 start\n- 第二项\n\n> 引用里有 start',
    };
    final tiers = {'start': 0, 'code': 1, 'achievement': 0};

    for (final e in cases.entries) {
      final out = injectTraceMarkers(markdown: e.value, tiers: tiers);
      check(
        '『${e.key}』剥掉控制字符后与原文**完全相同**',
        _strip(out) == e.value,
        _strip(out) == e.value ? '' : _vis(out),
      );
    }
  }

  // ══════════════════════════════════════════════════════════════
  section('【1】基本注入：词被包住，且档位正确');
  {
    final out = injectTraceMarkers(
      markdown: 'I met start and achievement today.',
      tiers: {'start': 0, 'achievement': 1},
    );
    eq('fresh 档用 \\u0001 包住', out.contains('${kTraceFreshOpen}start$kTraceFreshOpen'), true);
    eq(
      'reviewing 档用 \\u0002 包住',
      out.contains('${kTraceReviewingOpen}achievement$kTraceReviewingOpen'),
      true,
    );
    eq('两档各一对（共 4 个控制字符）', _countTier(out, 0) + _countTier(out, 1), 4);
  }

  // ══════════════════════════════════════════════════════════════
  section('【2】🔴 必须跳过：围栏代码块（否则代码内容被污染）');
  {
    const src = '说明文字 start。\n\n```dart\nfinal start = 1;\n```\n\n结尾 start。';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});

    // 正文里的两处 start 应被标；代码块里的那处**不该**
    eq('代码块外的两处被标（共 4 个控制字符）', _countTier(out, 0), 4);
    check(
      '🔴 代码块内的 `final start` **未被标**',
      out.contains('final start = 1;'),
      _vis(out),
    );
  }
  {
    // ~ 围栏也要跳（Markdown 另一种围栏写法）
    const src = '~~~\nstart inside\n~~~\n\nstart outside';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check('🔴 `~~~` 围栏同样跳过', out.contains('start inside'), _vis(out));
    check('围栏外的仍被标', out.contains('${kTraceFreshOpen}start$kTraceFreshOpen'));
  }
  {
    // 未闭合围栏 → 保守：剩下的都当代码（宁可少标）
    const src = 'before start\n\n```\nstart never closed';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check('未闭合围栏 → 保守跳过（不插控制字符）', out.contains('start never closed'), _vis(out));
  }
  {
    // 🔑🔑 **这条是证伪逼出来的**（2026-10-02）：
    //    单围栏块的用例**查不出**「围栏跳过被绕过」—— 因为 `_skipBacktick`
    //    会意外地把「``` 开头」当行内代码、一直跳到结尾的 ```，
    //    于是块内内容**碰巧**也没被标（依赖了一个巧合的等价行为）。
    //    **两个围栏块**时这个巧合断掉：第一块的开头会与第二块的开头「配对」，
    //    中间的内容就被暴露成普通文本 → 污染。
    //    📌 判据：**证伪时若「主断言没红」，说明用例不够狠，不是实现没问题。**
    const src = 'A start\n\n```\nstart one\n```\n\nB start\n\n```\nstart two\n```\n\nC start';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check(
      '🔴🔴 两个围栏块**内部**都未被标（块间也不该被暴露）',
      out.contains('start one') && out.contains('start two'),
      _vis(out),
    );
    eq('只有块外的 3 处被标（共 6 个控制字符）', _countTier(out, 0), 6);
  }

  // ══════════════════════════════════════════════════════════════
  section('【3】🔴 必须跳过：行内代码');
  {
    const src = '看 `start` 这个 API，以及 start 这个词。';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check('🔴 反引号内的 start 未被标', out.contains('`start`'), _vis(out));
    eq('反引号外的那处被标', _countTier(out, 0), 2);
  }
  {
    // 单个反引号（畸形）→ 只跳一个字符，不吞后半篇
    const src = 'a ` b start';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check(
      '未配对的反引号 → 不吞掉后续正文',
      out.contains('${kTraceFreshOpen}start$kTraceFreshOpen'),
      _vis(out),
    );
  }

  // ══════════════════════════════════════════════════════════════
  section('【4】🔴🔴 必须跳过：链接 URL（否则**链接失效**）');
  {
    const src = '点 [start here](http://example.com/start) 看看。';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check(
      '🔴 URL 内**没有**控制字符（链接不会坏）',
      out.contains('(http://example.com/start)'),
      _vis(out),
    );
    eq('链接文本里的 start 被标（1 对）', _countTier(out, 0), 2);
  }
  {
    // 图片：URL 同样要跳过
    const src = '![start](http://img/x.png)';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check('图片 URL 被跳过', out.contains('(http://img/x.png)'), _vis(out));
  }
  {
    // 嵌套括号的 URL 也应正确跳过
    const src = '[t](http://a/b_(c)/start) tail';
    final out = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    check('嵌套括号的 URL 被完整跳过', out.contains('(http://a/b_(c)/start)'), _vis(out));
  }

  // ══════════════════════════════════════════════════════════════
  section('【5】词边界与大小写（`\\b` 判据 · 唯一难点）');
  {
    final out = injectTraceMarkers(
      markdown: 'start and restart and started',
      tiers: {'start': 0},
    );
    eq('只标 `start` 本身（1 对）', _countTier(out, 0), 2);
    check('`restart` 未被标', out.contains('restart'), _vis(out));
    check('`started` 未被标', out.contains('started'), _vis(out));
  }
  {
    final out = injectTraceMarkers(markdown: 'India is big.', tiers: {'india': 0});
    check('大小写不敏感（小写词命中首字母大写）', out.contains('${kTraceFreshOpen}India$kTraceFreshOpen'));
  }

  // ══════════════════════════════════════════════════════════════
  section('【6】🔑 幂等：重复调用不产生双层标记');
  {
    const src = 'a start b `start` c [x](http://s/start)';
    final once = injectTraceMarkers(markdown: src, tiers: {'start': 0});
    final twice = injectTraceMarkers(markdown: once, tiers: {'start': 0});
    eq('跑两次 === 跑一次', twice, once);
    eq('控制字符数不翻倍', _countTier(twice, 0), _countTier(once, 0));
  }

  // ══════════════════════════════════════════════════════════════
  section('【7】边界：空输入 / 无词 / 无命中');
  {
    eq('空文本 → 原样', injectTraceMarkers(markdown: '', tiers: {'a': 0}), '');
    eq('空词表 → 原样', injectTraceMarkers(markdown: 'abc', tiers: {}), 'abc');
    eq(
      '无命中 → 原样',
      injectTraceMarkers(markdown: 'xyz', tiers: {'abc': 0}),
      'xyz',
    );
    eq('空词 → 跳过', injectTraceMarkers(markdown: 'abc', tiers: {'': 0}), 'abc');
  }

  // ══════════════════════════════════════════════════════════════
  section('【8】🔑 与渲染端一致：注入的标记能被 pattern 匹配回原文');
  {
    // 这是「两端约定」的断言：注入用 kTraceFreshOpen/kTraceReviewingOpen，
    // 渲染用 kTraceMarkerPattern + match.group(1)/group(2)。
    // 若两端对不齐（比如改了一个字符但没改另一个），痕迹会**静默消失**。
    const src = 'meet start and achievement';
    final out = injectTraceMarkers(
      markdown: src,
      tiers: {'start': 0, 'achievement': 1},
    );
    final matches = kTraceMarkerPattern.allMatches(out).toList();
    eq('pattern 匹配到 2 段', matches.length, 2);

    final pairs = <String, String>{};
    for (final m in matches) {
      pairs[m.group(2)!] = m.group(1)!;
    }
    eq('还原出的词与档位（start=fresh）', pairs['start'], kTraceFreshOpen);
    eq('还原出的词与档位（achievement=reviewing）', pairs['achievement'], kTraceReviewingOpen);

    // 半截标记（只有一个控制字符）**不该**被匹配（宁可少匹配也不吞内容）
    final half = kTraceMarkerPattern.allMatches('a${kTraceFreshOpen}b').length;
    eq('单个控制字符（畸形）→ 不匹配', half, 0);
  }

  // ══════════════════════════════════════════════════════════════
  section('【9】多词 + 词表顺序**不影响**结果');
  {
    const src = 'start and code and end';
    final a = injectTraceMarkers(markdown: src, tiers: {'start': 0, 'code': 1});
    // 换一个插入顺序（Map 字面量顺序不同）
    final b = injectTraceMarkers(
      markdown: src,
      tiers: Map.fromEntries([MapEntry('code', 1), MapEntry('start', 0)]),
    );
    // ⚠️ 我第一版断言「顺序不同 → 结果不同」—— **猜错了**。
    //    实际顺序无关：两个词不重叠，替换互不干扰；
    //    即使重叠（如 `start` 与 `art`），`\b` 边界也保证不会互相咬到。
    //    📌 又一次「期望值自己写错」——但这次错在**低估了实现的性质**。
    eq('🔑 词表顺序不同 → 结果**相同**（替换互不干扰）', a, b);
    check(
      '控制字符数量一致',
      _countTier(a, 0) + _countTier(a, 1) == _countTier(b, 0) + _countTier(b, 1),
      'a=${_countTier(a, 0)},${_countTier(a, 1)} b=${_countTier(b, 0)},${_countTier(b, 1)}',
    );
    check('剥掉控制字符后与原文一致', _strip(a) == src);
  }
  {
    // 🔑 重叠词的边界（`start` 与 `art`）—— 靠 `\b` 保证不会互相咬
    final out = injectTraceMarkers(
      markdown: 'start and art',
      tiers: {'start': 0, 'art': 1},
    );
    eq('`start` 被标 1 对', _countTier(out, 0), 2);
    eq('`art` 但**不**标 start 里的 art（1 对）', _countTier(out, 1), 2);
    check('可见内容不变', _strip(out) == 'start and art', _vis(out));
  }

  // ══════════════════════════════════════════════════════════════
  print('\n${'═' * 74}');
  if (_fail > 0) {
    print('🔴 失败 $_fail 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「跳过代码块 / URL」类失败 → 检查 `_nextSpecial` 与 `_skipFence`：');
    print('    这两处分区的边界判据是整条链的地基（漏一个就会污染正文）。');
    exit(1);
  }
  print('✅ 全部通过：$_pass 项');
  print('═' * 74);
  print('');
  print('⚠️ 本脚本**查不出**的：');
  print('   · gpt_markdown 是否真的把标记渲染成带样式的 span（需 Flutter 环境）');
  print('   · 痕迹两档的视觉可辨性（肉眼 —— 文本断言验不到「好看」；');
  print('     另：token 层三档两态的数值断言在 `tokens_verify`【4】，不在本脚本）');
}
