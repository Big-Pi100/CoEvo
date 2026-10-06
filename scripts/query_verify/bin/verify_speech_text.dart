// 「朗读用纯文本」验收 —— Markdown → 能听的文本
//
// 跑：cd scripts/query_verify && dart run bin/verify_speech_text.dart
// 🔴 退出码：0 = 全过，1 = 有失败（直读，别接 `| tail`）。
//
// # 为什么需要它
//
// 信息流正文是 **Markdown 原文**，而 TTS 拿到的是**原始字符串**
// ⇒ 不剥标记就会听到「hash hash hash link h-t-t-p-s colon slash slash …」。
//
// 这一层的错误**全是静默的**（用户听得出来，但我们测不出来）：
//   · URL 没去掉 ⇒ 每次朗读都念一长串网址（**最严重**，本文件的主要目的）
//   · `_` 处理过宽 ⇒ `snake_case` 被念成 `snakecase`（**内容被破坏**，比留符号更糟）
//   · 转义没保护 ⇒ `\*` 被当强调标记 ⇒ 正文被吃掉一段
//
// # 🔴 证伪方式
//
// | 改这里 | 应变红的是 |
// |---|---|
// | `_linkRe` 的替换用 `''`（丢掉文字）| 【1】链接**保留文字** |
// | 去掉 `_bareUrlRe` 那一行 | 【3】裸 URL 被删 |
// | `_italicUnderscoreRe` 去掉词边界 | 【8】`snake_case` 不被破坏 |
// | `_stripInline` 挪到 `_hideEscapes` **之前** | 【15】`\*` 不当强调 |
// | 去掉 `_tableDividerRe` | 【12】表格分隔行 |
// | `speechParagraphsFromMarkdown` 改成整篇一段 | 【19】段落切分 |
//
// # ⚠️ 口径（如实标注）
// · 纯逻辑、零 Flutter 依赖 ⇒ **本机完整可跑**（不是「查文本」式的断言，是真跑函数）。
// · 用例含**生产库的真实正文片段**（NPR 源，2026-10-06 SSH 直读取样）。
// · 它**不能**验证「真人听着是否自然」（那要真机外放）——
//   只保证「不会念出标记与 URL」这一层。

import 'dart:io';

import '../../../app/lib/services/speech_text.dart';

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

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

/// 断言「结果里**不含**某个不该出现的东西」，失败时把结果打出来便于定位。
void notContain(String label, String out, String bad) {
  check(label, !out.contains(bad), out.contains(bad) ? '结果里出现了「$bad」' : '');
}

/// 生产库真实正文（NPR · 2026-10-06 取样的**原样**片段）。
const realNpr = '''
**Supreme Court case centers on battle over liability for climate change harms** **The Supreme Court heard its first argument of the new term: a case about how much power local governments have to recover the costs of responding to the effects of climate change\\.**

### [Law](https://www.npr.org/sections/law/)

October 5, 20265:31 PM ET

#### Supreme Court case centers on battle over liability for climate change harm

- [Download](https://ondemand.npr.org/anon.npr-mp3/npr/atc/2026/10/20261005_atc_x.mp3)
''';

void main() {
  print('');
  print('#' * 74);
  print('# 朗读用纯文本验收（Markdown → 能听的文本）');
  print('#' * 74);

  // ═══════════════════════════════════════════════════════════
  section('【1】🔴🔴 链接：**保留文字、去掉 URL**（本文件存在的首要理由）');
  {
    final out = speechTextFromMarkdown(
        'See [the ruling](https://example.com/a/b?c=1) for details.');
    check('**保留可见文字**', out.contains('the ruling'), out);
    notContain('🔴 URL 必须消失', out, 'https');
    notContain('🔴 且不留方括号', out, '[');
    notContain('🔴 且不留圆括号', out, ')');
    check('  句子其余部分完好', out.contains('See') && out.contains('for details.'), out);
  }

  // ═══════════════════════════════════════════════════════════
  section('【2】图片：保留 alt、去掉 URL');
  {
    final out = speechTextFromMarkdown('Text before ![alt text](https://x.com/i.png) after.');
    check('保留 alt 文字', out.contains('alt text'), out);
    notContain('URL 消失', out, 'x.com');
    check('前后文完好', out.contains('Text before') && out.contains('after.'));
    // alt 为空（装饰图）⇒ 只剩空白，不该留 `![](...)` 残渣
    final empty = speechTextFromMarkdown('a ![](https://x.com/i.png) b');
    notContain('空 alt 不留残渣', empty, '![');
    notContain('  也不留 URL', empty, 'x.com');
  }

  // ═══════════════════════════════════════════════════════════
  section('【3】🔴 裸 URL / 自动链接 / HTML 标签');
  {
    final bare = speechTextFromMarkdown('Visit https://example.com/path now.');
    notContain('🔴 裸 URL 被删', bare, 'example.com');
    check('  句子保留', bare.contains('Visit') && bare.contains('now.'), bare);

    final auto = speechTextFromMarkdown('See <https://example.com/x> here.');
    notContain('自动链接被删', auto, 'example.com');
    check('  且不留尖括号', !auto.contains('<'), auto);

    final html = speechTextFromMarkdown('<p>Hello <b>world</b></p>');
    notContain('HTML 标签被删', html, '<');
    check('  文字保留', html.contains('Hello') && html.contains('world'), html);

    // 链接**文字本身是 URL**（少见）⇒ 剥链接后剩 URL，再被「裸 URL」规则删掉
    // ⇒ **结果为空**。（我初版断言写成「非空」= **写反了**，被这条红抓出来。）
    final nested = speechTextFromMarkdown('[https://a.com](https://a.com)');
    check('🔑 链接文字本身是 URL ⇒ 也被删干净（两条规则叠加）', nested.isEmpty, nested);
  }

  // ═══════════════════════════════════════════════════════════
  section('【4】标题 / 引用 / 列表：去标记、留文字');
  {
    for (final h in ['#', '##', '###', '####', '#####', '######']) {
      final out = speechTextFromMarkdown('$h Heading text');
      check('`$h` 去标记留文字',
          out == 'Heading text', '实得 ${out.replaceAll('\n', r'\n')}');
    }
    check('引用去 `>`', speechTextFromMarkdown('> quoted line') == 'quoted line');
    check('无序列表去 `-`', speechTextFromMarkdown('- item one') == 'item one');
    check('无序列表去 `*`', speechTextFromMarkdown('* item two') == 'item two');
    check('无序列表去 `+`', speechTextFromMarkdown('+ item three') == 'item three');
    check('有序列表去 `1.`', speechTextFromMarkdown('1. first') == 'first');
    check('有序列表去 `2)`', speechTextFromMarkdown('2) second') == 'second');
    check('🔑 多级列表标记也去掉（`  - x`）',
        speechTextFromMarkdown('  - indented') == 'indented');
    check('缩进不留（行 trim）', speechTextFromMarkdown('    plain') == 'plain');
  }

  // ═══════════════════════════════════════════════════════════
  section('【5】强调 / 删除线 / 行内代码');
  {
    check('`**bold**` → bold',
        speechTextFromMarkdown('a **bold** b') == 'a bold b');
    check('🔑 `__bold__`（无空格）**保留** —— 与 `__init__` 无法区分，宁可不动',
        speechTextFromMarkdown('a __bold__ b') == 'a __bold__ b',
        speechTextFromMarkdown('a __bold__ b'));
    check('`*italic*` → italic',
        speechTextFromMarkdown('a *italic* b') == 'a italic b');
    // 🔴 **下划线强调只在「含空格」时剥**（判据见 `speech_text.dart` 的注释）：
    //    `_italic_` 也可能是标识符（`_private`）⇒ 宁可留两个下划线。
    //    ⚠️ 这与星号**刻意不一致**：`*` 不是标识符字符，可以放心剥。
    check('🔑 `_italic_`（单词）**原样保留** —— 可能是标识符，不冒破坏风险',
        speechTextFromMarkdown('a _italic_ b') == 'a _italic_ b',
        speechTextFromMarkdown('a _italic_ b'));
    check('🔑 但**含空格**的 `_multi word_` 是确定强调 ⇒ 剥',
        speechTextFromMarkdown('a _multi word_ b') == 'a multi word b',
        speechTextFromMarkdown('a _multi word_ b'));
    check('🔑 含空格的 `__bold text__` 也剥',
        speechTextFromMarkdown('a __bold text__ b') == 'a bold text b',
        speechTextFromMarkdown('a __bold text__ b'));
    check('`~~strike~~` → strike',
        speechTextFromMarkdown('a ~~strike~~ b') == 'a strike b');
    check('行内代码去反引号留内容',
        speechTextFromMarkdown('run `flutter build` now') == 'run flutter build now');
    check('🔑 双星先剥（不留单星残渣）',
        !speechTextFromMarkdown('a **b** c').contains('*'));
    check('  且紧邻的 `**x**` 也对',
        speechTextFromMarkdown('**x**') == 'x', speechTextFromMarkdown('**x**'));
  }

  // ═══════════════════════════════════════════════════════════
  section('【6】🔴🔴 `_` 的词边界 —— `snake_case` 不能被破坏');
  {
    // 这是最容易做错的一条：`_` 既是强调标记，也是**标识符的一部分**
    check('🔴🔴 `my_var_name` **原样保留**',
        speechTextFromMarkdown('my_var_name') == 'my_var_name',
        speechTextFromMarkdown('my_var_name'));
    check('🔴 `snake_case` 不被改写',
        speechTextFromMarkdown('use snake_case here') == 'use snake_case here');
    check('🔴 `__init__` 原样（Python 双下划线方法名）',
        speechTextFromMarkdown('call __init__ method') == 'call __init__ method');
    check('🔑 单词下划线强调**保留**（同上判据）',
        speechTextFromMarkdown('an _emphasized_ word') == 'an _emphasized_ word',
        speechTextFromMarkdown('an _emphasized_ word'));
    check('🔑 星号强调**不受此限**（`*` 不是标识符字符）',
        speechTextFromMarkdown('an *emphasized* word') == 'an emphasized word',
        speechTextFromMarkdown('an *emphasized* word'));
    check('🔑 下划线紧贴单词时不算强调',
        speechTextFromMarkdown('a_b_c') == 'a_b_c');
  }

  // ═══════════════════════════════════════════════════════════
  section('【7】围栏代码块：去围栏、留内容');
  {
    const src = 'Before\n\n```dart\nfinal x = 1;\n```\n\nAfter';
    final out = speechTextFromMarkdown(src);
    notContain('围栏标记已去', out, '```');
    check('代码内容保留', out.contains('final x = 1;'), out);
    check('前后文保留', out.contains('Before') && out.contains('After'), out);
    // 围栏内的 `*` 不该被当强调（那可能是代码语法）
    //
    // 🔴 **必须用「成对」的 `*`** —— 本人踩过一次：初版用例是 `int * p = 0;`
    //    （只有**一个** `*`），而强调规则要求成对 ⇒ 它**本来就不会触发**
    //    ⇒ 无论有没有围栏保护，断言都绿 = **这条断言当时什么都没测**。
    //    📌 判据：**断言的有效性依赖测试数据**（「测试数据也是断言的一部分」同族）。
    const code = '```\nchar *a *b;\n```';
    check('🔑 围栏内的**成对** `*` 不动（代码语义，不是强调）',
        speechTextFromMarkdown(code).contains('*'), speechTextFromMarkdown(code));
    check('  且整段内容未被吞（`a` 与 `b` 都在）',
        speechTextFromMarkdown(code).contains('a') &&
            speechTextFromMarkdown(code).contains('b'));
  }

  // ═══════════════════════════════════════════════════════════
  section('【8】纯语法行：整行删（无内容可读）');
  {
    final table = speechTextFromMarkdown('| a | b |\n|---|---|\n| 1 | 2 |');
    notContain('表格分隔行被删', table, '|---|');
    check('  但**数据行保留**', table.contains('a') && table.contains('1'), table);
    final hr = speechTextFromMarkdown('Above\n\n---\n\nBelow');
    notContain('水平线（`---`）被删', hr, '---');
    check('  前后文保留', hr.contains('Above') && hr.contains('Below'), hr);
    notContain('水平线（`***`）被删', speechTextFromMarkdown('a\n\n***\n\nb'), '***');
    notContain('水平线（`___`）被删', speechTextFromMarkdown('a\n\n___\n\nb'), '___');
  }

  // ═══════════════════════════════════════════════════════════
  section('【9】🔴 转义保护：`\\*` 不是强调标记');
  {
    // 🔴 若先反转义再剥标记，`\*` 会变成 `*` ⇒ 与相邻的 `*` 配成强调 ⇒ **吃掉正文**
    final out = speechTextFromMarkdown(r'a \* b \* c');
    check('🔴 `\\*` 不参与强调配对（文字全保留）',
        out.contains('a') && out.contains('b') && out.contains('c'),
        out.replaceAll('\n', r'\n'));
    notContain('  且反斜杠不残留（朗读场景要一个都不留）', out, r'\');

    final dot = speechTextFromMarkdown(r'It ended\.');
    check('`\\.` → `.`（反转义）', dot == 'It ended.', dot);
    notContain('  且反斜杠消失', dot, r'\');

    // ⚠️ 与显示侧的口径差异：`\|` 这里**要**处理（gpt_markdown 那侧交给它自己）
    final pipe = speechTextFromMarkdown(r'a \| b');
    check('🔑 `\\|` 也消化（**与显示侧口径不同** —— 朗读不经过 gpt_markdown）',
        pipe == 'a | b', pipe);
  }

  // ═══════════════════════════════════════════════════════════
  section('【10】边界：空输入 / 纯文本 / 空白归一');
  {
    check('空串 → 空串', speechTextFromMarkdown('') == '');
    check('纯空白 → 空串', speechTextFromMarkdown('   \n\n  ') == '');
    check('🔑 纯文本**原样返回**（幂等）',
        speechTextFromMarkdown('Just a plain sentence.') == 'Just a plain sentence.');
    check('  已是纯文本时再处理一次不变（幂等）',
        speechTextFromMarkdown(speechTextFromMarkdown('Plain **text** here.')) ==
            'Plain text here.');
    // 连续空行压缩（影响 TTS 停顿长度）
    final many = speechTextFromMarkdown('a\n\n\n\n\nb');
    check('3+ 连续换行压缩为 2', many == 'a\n\nb', many.replaceAll('\n', r'\n'));
    check('行尾空格去掉', speechTextFromMarkdown('a   \nb') == 'a\nb');
    final padded = speechTextFromMarkdown('\n\n  x  \n\n');
    check('首尾空白去掉', padded == 'x', padded.replaceAll('\n', r'\n'));
    check('单个换行**保留**（段内软折行由下游决定）',
        speechTextFromMarkdown('a\nb') == 'a\nb');
  }

  // ═══════════════════════════════════════════════════════════
  section('【11】🔴🔴 真实生产样本（NPR 源 · 端到端）');
  {
    final out = speechTextFromMarkdown(realNpr);

    notContain('🔴🔴 **不含任何 URL**（最关键）', out, 'http');
    notContain('🔴 不含 npr.org', out, 'npr.org');
    notContain('🔴 不含强调标记', out, '**');
    notContain('🔴 不含标题标记', out, '###');
    notContain('🔴 不含列表符号 `- [\'', out, '- [');
    notContain('🔴 不含残留反斜杠', out, r'\');
    notContain('🔴 不含 mp3 链接残渣', out, 'mp3');
    notContain('🔴 不含方括号', out, '[');

    check('✅ 保留正文首句', out.contains('Supreme Court case centers on battle'), '');
    check('✅ 链接文字 `Law` 保留（只去 URL）', out.contains('Law'));
    check('✅ 链接文字 `Download` 保留', out.contains('Download'));
    check('✅ 日期行保留（那是内容，不是标记）', out.contains('October 5, 2026'));
    check('✅ 结果非空且长度合理', out.length > 150, '${out.length} 字符');
  }

  // ═══════════════════════════════════════════════════════════
  section('【12】段落切分（段间留停顿）');
  {
    final ps = speechParagraphsFromMarkdown(
        'First para.\n\nSecond **para** with [link](https://x.com).\n\nThird.');
    check('切成 3 段', ps.length == 3, '$ps');
    check('  首段干净', ps[0] == 'First para.', ps[0]);
    check('🔴 次段的 URL 已去、强调已去',
        ps[1] == 'Second para with link.', ps[1]);
    check('  末段', ps[2] == 'Third.');
    check('空输入 → 空列表', speechParagraphsFromMarkdown('').isEmpty);
    check('只有标记没有文字 → 空列表',
        speechParagraphsFromMarkdown('---\n\n---').isEmpty,
        '${speechParagraphsFromMarkdown('---\n\n---')}');

    final npr = speechParagraphsFromMarkdown(realNpr);
    check('真实样本切成多段', npr.length >= 3, '${npr.length} 段');
    check('🔴 且每段都不含 URL',
        npr.every((p) => !p.contains('http')), '');
  }

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因（这一层用户听得出来、我们测不出来）：');
    print('   · URL 没去掉 ⇒ 每次朗读念一长串网址');
    print('   · `_` 处理过宽 ⇒ `snake_case` 被念成 `snakecase`（**内容被破坏**）');
    print('   · 转义没保护 ⇒ `\\*` 被当强调 ⇒ 正文被吃掉一段');
    print('   · 顺序错：先反转义再剥标记 ⇒ `\\*` 与邻居配成强调');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
