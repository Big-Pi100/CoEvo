// CoEvo · Markdown 转义消化验收（S4 反馈 · 2026-10-02）
//
// # 为什么需要本脚本
//
// 白哥真机报「转义没有正确消化」—— `DELETE\.` `\"QUERY\"` `\{…\}` 原样显示。
// 根因：**产出侧按 CommonMark 全量（且过度）转义，消费侧只反转义 `\|`**。
// 修复在 `app/lib/services/markdown_unescape.dart`（渲染前消化）。
//
// # 🔴 这条链上「做宽了」比「做窄了」更危险
//
// 消化=**删反斜杠**。删错会**制造新语法**：
//   · `\*text\*` → `*text*` = **开始强调**（内容被改）
//   · `\[a\](u)` → `[a](u)` = **变成链接**
//   · `1\. item` → `1. item` = **变成列表项**
// 而这类错误**不报错**，只是渲染结果变了 ⇒ 只能靠断言锁死。
//
// 🔑 本组最强的一条是【0】：**剥掉所有反斜杠后内容必须完全相同** ——
//    它一句覆盖「只吃反斜杠、不动别的字符」这整类风险。
//
// ⚠️ 本脚本**查不出**的（如实列出）：
//   · 消化后的 Markdown 在 `gpt_markdown` 里**渲染出来好不好看**（需真机）
//   · 「这样消化是否符合用户期待」—— 那是产品判断，不是文本判据
//
// 跑法：`cd scripts/trace_verify && dart run bin/verify_unescape.dart`
// 退出码：有失败 → 1

import 'dart:io';

import '../../../app/lib/services/markdown_unescape.dart';

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
      actual == expected ? '' : '实得 ${_show(actual)} · 期望 ${_show(expected)}',
    );

String _show(Object? v) =>
    v is String ? '"${v.length > 90 ? '${v.substring(0, 90)}…' : v}"' : '$v';

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

/// 便捷：只跑一次消化。
String u(String s) => unescapeRedundantMarkdown(markdown: s);

String _repoRoot() {
  var d = Directory.current;
  while (!Directory('${d.path}${Platform.pathSeparator}.git').existsSync()) {
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  return d.path;
}

void main() {
  print('CoEvo 转义消化验收 · 依据 docs/review/s4-device-feedback-findings-2026-10-02.md §4');

  groupInvariant();
  groupSymptomCases();
  groupMustPreserve();
  groupPositionRefined();
  groupBoundaries();
  groupRealFixtures();

  print('\n${'═' * 74}');
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('\n失败清单：');
    for (final f in _failures) {
      print('  · $f');
    }
  }
  print('═' * 74);
  if (_fail == 0) {
    print('\n✅ 转义消化符合「只吃多余反斜杠、不造新语法」');
    print('⚠️ 但本脚本**查不出**：渲染出来的观感（需真机），以及「这样消化是否符合期待」（产品判断）。');
  }
  exit(_fail == 0 ? 0 : 1);
}

// ════════════════════════════════════════════════════════════════
void groupInvariant() {
  section('【0】🔑 核心不变量：剥掉反斜杠后内容完全相同（只吃反斜杠、不动别的字符）');

  const cases = [
    r'Most developers know GET, POST, and DELETE\.',
    r'The \"QUERY\" method sends \{ \"a\": 1 \}',
    r'\(66\.4%\) and \($0\.10 vs\. $0\.20\)',
    r'```' '\n' r'curl -X POST \"https://x\"' '\n' r'```',
    r'Text with \*literal asterisks\* and \_underscores\_',
    r'1\. first item',
    r'\[block latex\]',
    'mixed \\. \" \\[ \\] 中文内容 \\.',
  ];
  for (final src in cases) {
    final out = u(src);
    final same = src.replaceAll(r'\', '') == out.replaceAll(r'\', '');
    check('不变量：${_show(src)}', same, same ? '' : '实得 ${_show(out)}');
  }

  // 长度只能「不变或变短」（消化 = 删字符；变长说明加了东西 = 实现有 bug）
  for (final src in cases) {
    check('长度不增长：${_show(src)}', u(src).length <= src.length);
  }
}

// ════════════════════════════════════════════════════════════════
void groupSymptomCases() {
  section('【1】🔴 白哥报的具体症状 → 必须被消化');

  eq('句点转义：`DELETE\\.` → `DELETE.`',
      u(r'GET, POST, PUT, PATCH, and DELETE\.'), 'GET, POST, PUT, PATCH, and DELETE.');

  eq('引号转义：`\\"QUERY\\"` → `"QUERY"`',
      u(r'The \"QUERY\" method'), 'The "QUERY" method');

  eq('花括号转义（JSON）：`\\{ … \\}` → `{ … }`',
      u(r'\{ \"city\": \"Noida\" \}'), '{ "city": "Noida" }');

  eq('普通圆括号被转义：`\\(66\\.4%\\)` → `(66.4%)`',
      u(r'leads at 58\.9% \(66\.4%\)'), 'leads at 58.9% (66.4%)');

  eq('行内 JSON 数组（方括号被转义）：`\\["IN", "US"\\]` → `["IN", "US"]`',
      u(r'\"country\": \[\"IN\", \"US\"\],'), '"country": ["IN", "US"],');

  eq('逗号/分号/冒号',
      u(r'a\, b\; c\: d'), 'a, b; c: d');
}

// ════════════════════════════════════════════════════════════════
/// 🆕 2026-10-03：**按位置细化** —— 同一个字符，行内消化 / 行首保留。
///
/// # 为什么单独成组
///
/// 这组断言锁的是「**位置判据**」本身：`+ - # > * _ <` 这 7 个字符**离开了行首就该消化**。
/// 若只测「行首保留」（上一组），则「干脆全不消化」的实现也能全绿 ⇒ **假绿**。
///
/// 📌 判据：**保护类判据必须配「不该保护时确实放行」的断言** —— 否则退化实现测不出来。
///
/// 实测依据：`app/tool/ast_probe.dart`（阳性对照 10/10 通过）。
void groupPositionRefined() {
  section('【3】🆕 按位置细化：**行内**这些字符要**消化**（行首才保留）');

  // 行内的块标记字符 —— 实测消化后**不会**造语法（`+ item` 才成列表，`4,000+` 不会）
  eq('行内 `\\+` 消化（**表格内**，实测不成列表）',
      u(r'| 4,000\+ plugins |'), '| 4,000+ plugins |');
  eq('行内 `\\#` 消化（`\\#Hacktoberfest` 实测不成标题）',
      u(r'## Hacktoberfest \#OpenSource'), '## Hacktoberfest #OpenSource');
  eq('行内 `\\-` 消化', u(r'a \- b plain'), 'a - b plain');
  eq('行内 `\\>` 消化', u(r'a \> b plain'), 'a > b plain');
  eq('句末 `\\*` 消化（无配对）', u(r'note: see above \*'), 'note: see above *');

  // `_` `<` —— 实测**无条件**安全（plusparse 不支持 `_` 强调 / `<…>` 自动链接）
  eq('`\\_` 消化（🔴 实测 plusparse **不支持** `_` 强调 ⇒ 无条件安全）',
      u(r'var \_x\_ = 1'), 'var _x_ = 1');
  eq('`\\_` 词中消化（`foo\\_bar` 这类）', u(r'foo\_bar\_baz'), 'foo_bar_baz');
  eq('`\\<` `\\>` 消化（🔴 实测**不成**自动链接）',
      u(r'a \<http://x.com\> b'), 'a <http://x.com> b');
  eq('`\\<` 标签样消化（不成 HTML）', u(r'use \<div\> here'), 'use <div> here');

  // 边界：4 空格缩进 = CommonMark 的**代码块**，不是列表 ⇒ 不该按「行首块标记」保护
  // ⚠️ 但我们的判据取「≤3 空格才算行首」⇒ 4 空格**不保护** ⇒ 消化。
  //    （消化后 `    + item` 是缩进代码块 —— 这属于「边界上的取舍」，如实记录：
  //     原文 `    \+ item` 若被当代码块，消化后仍是代码块 ⇒ **结构不变** ⇒ 安全）
  eq('4 空格缩进的 `\\+` 消化（>3 空格不算行首）',
      u(r'    \+ item'), '    + item');
}

// ════════════════════════════════════════════════════════════════
void groupMustPreserve() {
  section('【2】🔴 必须**保留**的（消掉会制造新语法 / 破坏内容）');

  // ⚠️ 2026-10-03：本组原为「按『也许危险』写的**过宽保护**」，已按**实测**收窄。
  //    实测方法：`app/tool/ast_probe.dart`（用真实解析器 plusparse 比较消化前后结构，
  //    且含**阳性对照**证明检测器有区分力）。
  //    收窄的两条依据：
  //      · `\_` 消掉**不会**成强调 —— plusparse **不支持 `_` 强调**（阳性对照已验证）
  //      · `\#` `\+` 只在**行首**才危险 —— 原用例 `| 4,000\+ plugins |` 在**表格内**，本可消化
  //    ⇒ 移出本组、加入下面的「按位置细化」组。

  eq('`\\*` 行内**成对**保留（消掉会变强调/加粗）',
      u(r'a \*literal\* b'), r'a \*literal\* b');
  eq('`\\*\\*` 成对保留（消掉会变**加粗**）',
      u(r'alpha \*\*bold \*\* beta'), r'alpha \*\*bold \*\* beta');
  eq('`\\`` 保留（行内代码）', u(r'mix \`\` quoted'), r'mix \`\` quoted');

  eq('行首 `\\[` 保留（块级 LaTeX）',
      u('\\[ x^2 + y^2 = z^2 \\]'), '\\[ x^2 + y^2 = z^2 \\]');

  eq('含 LaTeX 命令的 `\\(…\\)` 保留（公式）',
      u(r'\(\frac{a}{b}\) and \(\alpha\)'), r'\(\frac{a}{b}\) and \(\alpha\)');

  // 🆕 行首块标记（按位置细化 —— 行首保留、行内消化）
  eq('行首 `\\#` 保留（防变标题）', u(r'\# Head'), r'\# Head');
  eq('行首 `\\#\\#` 保留（防变 H2）', u(r'\#\# Head'), r'\#\# Head');
  eq('行首 `\\+` 保留（防变列表）', u(r'\+ item'), r'\+ item');
  eq('行首 `\\-` 保留（防变列表）', u(r'\- item'), r'\- item');
  eq('行首 `\\>` 保留（防变引用；⚠️ 无空格也成）', u(r'\>quote'), r'\>quote');
  eq('行首 `\\*` 保留（防变列表）', u(r'\* item'), r'\* item');
  eq('缩进 3 空格的行首 `\\#` 仍保留', u(r'   \# Head'), r'   \# Head');

  eq('`\\|` 保留（表格 —— gpt_markdown 自己会反转义）',
      u(r'| a \| b | c |'), r'| a \| b | c |');

  eq('反斜杠+字母保留（CommonMark 规定；实测是正则/代码内容）',
      u(r'''NUMBER := "\d+"; WS := "\s+"'''),
      r'''NUMBER := "\d+"; WS := "\s+"''');

  eq('`\\\\` 保留（转义反斜杠 / LaTeX 换行，无法无上下文区分）',
      u(r'a \\ b'), r'a \\ b');
}

// ════════════════════════════════════════════════════════════════
void groupBoundaries() {
  section('【3】边界与保护条件');

  // 围栏代码块：里面的反斜杠**一律不动**（代码内容原样）
  const fenced = '```\ncurl -X POST \\"https://x\\"\nNUMBER := "\\d+"\n```';
  eq('围栏代码块内不消化', u(fenced), fenced);

  const tildeFence = '~~~\nJSON \\{ \\}\n~~~';
  eq('`~~~` 围栏内不消化', u(tildeFence), tildeFence);

  // 行内代码
  eq('行内代码内不消化', u(r'use `\"quoted\"` here'), r'use `\"quoted\"` here');

  // URL：改写会让链接失效
  const urlCase = r'[x](https://a.com/a\_b%20c)';
  eq('链接 URL 内不消化（`_` `%` 等有语义）', u(urlCase), urlCase);

  // 有序列表保护：行首 `1\.` 保留（消掉会变列表）
  eq('行首 `1\\. item` 保留（防变列表）', u(r'1\. first'), r'1\. first');
  eq('带 3 空格缩进的 `1\\.` 保留', u('   123\\. item'), '   123\\. item');

  // 🔴 但**行内**的 `1\.` 必须消化（实测修正：初版把行内也判成列表，残留 61 处）
  eq('行内 `row 1\\. If` 消化（不是列表）', u(r'headers in row 1\. If'), 'headers in row 1. If');
  eq('标题里的 `## 1\\.` 消化（不是列表）',
      u(r'## 1\. The number is evidence'), '## 1. The number is evidence');
  eq('小数 `66\\.4%` 消化（不是列表）', u(r'at 66\.4% now'), 'at 66.4% now');

  // `\!` 防变图片
  eq('`\\![` 保留（防变图片语法）', u(r'see \![x](u)'), r'see \![x](u)');
  eq('普通 `\\!` 消化', u(r'Wow\! Nice'), 'Wow! Nice');

  // LaTeX 换行 `\\[1em]` 不能被误判成块级 LaTeX 开始
  eq('`\\\\[1em]` 不被误判（保留两个反斜杠）',
      u('p = q \\\\[1em] r'), 'p = q \\\\[1em] r');

  // 幂等
  const src = r'a\. b \"c\" \(66\.4%\) 1\. item';
  eq('幂等：跑两次 === 跑一次', u(u(src)), u(src));

  // 空 / 无反斜杠
  eq('空文本 → 原样', u(''), '');
  eq('无反斜杠 → 原样（且走快速返回）', u('plain text'), 'plain text');
}

// ════════════════════════════════════════════════════════════════
void groupRealFixtures() {
  section('【4】🔑 生产库真实正文（白哥报的那篇 + 一篇长文）');

  final root = _repoRoot();
  final sep = Platform.pathSeparator;

  for (final name in ['http_query_id1444.md', 'benchmarks_id1452.md']) {
    final f = File('$root$sep'
        'scripts${sep}trace_verify${sep}fixtures$sep$name');
    if (!f.existsSync()) {
      check('fixture 存在：$name', false, '缺文件');
      continue;
    }
    final src = f.readAsStringSync();
    final out = u(src);
    final before = RegExp(r'\\').allMatches(src).length;
    final after = RegExp(r'\\').allMatches(out).length;

    check('$name：核心不变量（剥反斜杠后相同）',
        src.replaceAll(r'\', '') == out.replaceAll(r'\', ''),
        '$before → $after 个反斜杠');
    check('$name：反斜杠确实被大幅消化（≥ 60%）',
        after <= before * 0.4, '$before → $after');
    check('$name：长度未增长', out.length <= src.length);
  }

  // id=1444 的具体症状必须消失
  final q = File('$root$sep'
      'scripts${sep}trace_verify${sep}fixtures${sep}http_query_id1444.md');
  if (q.existsSync()) {
    final out = u(q.readAsStringSync());
    check('1444：`DELETE\\.` 已消化', out.contains('DELETE.'));
    check('1444：`\\"QUERY\\"` 已消化', out.contains('"QUERY"') && !out.contains(r'\"QUERY\"'));
    check('1444：全文**零残留反斜杠**（该篇无代码块/LaTeX）',
        !out.contains(r'\'), '残留 ${RegExp(r'\\').allMatches(out).length} 处');
  }
}
