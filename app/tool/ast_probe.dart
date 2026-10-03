// CoEvo · **扩白名单的受控实验**（诊断脚本 · 恒退出 0）
//
// # 为什么要有这个脚本（以及它经历的三次「假绿」）
//
// 扩 `kUnescapablePunct` 白名单的风险是**「造语法」**：
// 消掉反斜杠后，原本是字面标点的字符可能**变成 Markdown 语法**。
//
// 我写这个实验时**连续三次得出「全部安全」的假结论**，每次原因都不同：
//
// | 版本 | 错在哪 | 表现 |
// |---|---|---|
// | v1 | 用例太弱（`\* mid \*` 有空格，不构成强调）| 「全部安全」 |
// | v2 | 测的是「**当前代码**会不会消化」（`+` 不在白名单⇒不动）| 「全部安全」 |
// | v3 | 用例**手写时漏了反斜杠**（`r'# Head'` 本意是 `r'\# Head'`）| 「全部安全」 |
//
// ✅ v4（本版）的三道防线：
// 1. **阳性对照** —— 先证明「不转义时这些确实造语法」，否则检测器无区分力
// 2. **用例动态构造** —— `模板.replaceAll('XT', '\\$c')`，**不可能漏反斜杠**
// 3. **前置断言** —— 每对用例必须满足 `escaped != plain`，否则计入 selfCheckFail
//
// 📌 判据：**「无差异」是最容易假绿的结论** —— 必须先用阳性样本证明
//    「若真有差异，检测器会报出来」。
//
// # 检测能力的边界
//
// plusparse 的语法集**比 CommonMark 小**，实测（见阳性对照）：
// · ✅ 支持：`*` `**` `~~` `` ` `` `#` `>` `+` `-` `[t](u)` 表格
// · ❌ **不支持**：`_` 强调、`<...>` 自动链接
// ⇒ `\_` `\<` `\>` 消化后不造语法 —— 不是「碰巧安全」，是**没有那个语法**。
//
// ⚠️ **局限（如实标注）**：本实验用 `plusparse`（纯 Dart 解析器），
//    实际渲染是 `GptMarkdown`，它可能在解析器**之上**还有 autolink 等处理。
//    ⇒ 「`\<` 安全」对渲染层是否成立，**需真机复核**。
//
// 跑法：cd app && /d/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/ast_probe.dart

import 'package:gpt_markdown/plusparse/ast.dart';
import 'package:gpt_markdown/plusparse/plusparse.dart';

String fp(String md) => Plusparse.parse(md).children.map(_n).join('|');

String _n(MdNode n) {
  String kids(List<MdNode> c) => c.map(_n).join(',');
  return switch (n) {
    MdHeading(:final level, :final children) => 'H$level(${kids(children)})',
    MdParagraph(:final children) => 'P(${kids(children)})',
    MdBlockQuote(:final children) => 'BQ(${kids(children)})',
    MdCodeBlock() => 'Code',
    MdUnorderedList(:final items) =>
      'UL[${items.map((i) => kids(i.children)).join(';')}]',
    MdOrderedList(:final start, :final items) =>
      'OL$start[${items.map((i) => kids(i.children)).join(';')}]',
    MdCheckbox() => 'CB',
    MdRadio() => 'RD',
    MdTable() => 'Table',
    MdBlockLatex() => 'BlockTex',
    MdHorizontalRule() => 'HR',
    MdText() => 'T',
    MdInlineCode() => 'ICode',
    MdInlineLatex() => 'ITex',
    MdBold(:final children) => 'B(${kids(children)})',
    MdItalic(:final children) => 'I(${kids(children)})',
    MdStrike(:final children) => 'S(${kids(children)})',
    MdUnderline(:final children) => 'U(${kids(children)})',
    MdLink(:final children) => 'Link(${kids(children)})',
    MdImage() => 'Img',
    _ => '?',
  };
}

int pass = 0, fail = 0;
void ctrl(String desc, bool ok, String detail) {
  if (ok) {
    pass++;
    print('  ✅ $desc   [$detail]');
  } else {
    fail++;
    print('  🔴 $desc   [$detail]');
  }
}

void main() {
  bool has(String md, String m) => fp(md).contains(m);

  print('=' * 88);
  print('① 检测器自检（阳性对照：不转义时**必须**造出语法，否则方法无区分力）');
  print('=' * 88);
  ctrl('`*x*` → 强调', has('a *x* b', 'I('), fp('a *x* b'));
  ctrl('`**x**` → 加粗', has('a **x** b', 'B('), fp('a **x** b'));
  ctrl('`~~x~~` → 删除线', has('a ~~x~~ b', 'S('), fp('a ~~x~~ b'));
  ctrl('`` `x` `` → 行内代码', has('a `x` b', 'ICode'), fp('a `x` b'));
  ctrl('`# x` → 标题', has('# x', 'H1('), fp('# x'));
  ctrl('`> x` → 引用', has('> x', 'BQ('), fp('> x'));
  ctrl('`+ x` → 无序列表', has('+ x', 'UL'), fp('+ x'));
  ctrl('`- x` → 无序列表', has('- x', 'UL'), fp('- x'));
  ctrl('`[t](u)` → 链接', has('a [t](http://u.com) b', 'Link'),
      fp('a [t](http://u.com) b'));
  ctrl('`|a|b|` → 表格', has('|a|b|\n|-|-|\n|1|2|', 'Table'), '（表格块）');
  print('  → $pass 通过 / $fail 失败');
  print('  ⚠️ 以下为**反例对照**（plusparse 不支持该语法 ⇒ 消化这些字符不造语法）:');
  ctrl('`_x_` 不成强调', !has('a _x_ b', 'I('), fp('a _x_ b'));
  ctrl('`<http://x>` 不成链接', !has('a <http://x.com> b', 'Link'),
      fp('a <http://x.com> b'));

  print('');
  print('=' * 88);
  print('② 逐字符：「若消化该字符，结构会不会变」（比较 parse(转义) vs parse(消化)）');
  print('=' * 88);

  // 🔑 用例模板：`XT` 是占位符，分别替换成 `\X` 与 `X`
  //    ⇒ 转义形态**必然**比消化形态多一个反斜杠（不可能手写漏）
  const templates = <String, String>{
    '行首': 'XT item text',
    '行首无空格': 'XTitem',
    '行首两个': 'XTXT item text',
    '行内': 'alpha XT beta',
    '成对紧贴': 'alpha XTbold XT beta',
    '成对词中': 'alphaXTbetaXTgamma',
    '单个': 'alpha XT beta',
    '前接数字': 'value 1XT 2',
    '前接反斜杠': 'path XT\\XT file',
    // 🔴 「连续两个」形态 —— 我前三版都漏了它，导致 `\*\*` `\~\~` 的风险被完全掩盖
    //    （`\*\*bold\*\*` 消化后变 **加粗**、`\~\~del\~\~` 变 ~~删除线~~）
    //    📌 判据：**模板要覆盖「成对/连续」形态** —— 单字符模板测不出 `**` `~~` 这类两字符语法。
    '连续两个': 'alpha XTXTbold XTXT beta',
    '连续三个': 'alpha XTXTXTbold beta',
  };

  // 候选 = 实测残留里出现过的（按计数排序）+ 几个语法相关字符作对照
  const candidates = ['+', '_', '#', '<', '>', '*', '`', '~', '}', '[', '|', '-', '!'];

  final safe = <String>[];
  final unsafe = <String, List<String>>{};
  var selfCheckFail = 0;

  for (final c in candidates) {
    final issues = <String>[];
    for (final t in templates.entries) {
      final escaped = t.value.replaceAll('XT', '\\$c');
      final plain = t.value.replaceAll('XT', c);

      // 🔑 前置断言：两形态必须真的不同（否则该用例无效 → 会假绿）
      if (escaped == plain) {
        selfCheckFail++;
        issues.add('${t.key}: 🔴 用例构造失败（escaped == plain）');
        continue;
      }

      final before = fp(escaped);
      final after = fp(plain);
      if (before != after) {
        issues.add('${t.key}:  `$escaped`  $before  →  `$plain`  $after');
      }
    }

    if (issues.isEmpty) {
      safe.add(c);
      print('  ✅ `\\$c`   10 种位置结构均不变');
    } else {
      unsafe[c] = issues;
      print('  🔴 `\\$c`   造语法：');
      for (final i in issues) {
        print('        $i');
      }
    }
  }

  print('');
  print('=' * 88);
  print('结论');
  print('=' * 88);
  if (selfCheckFail > 0) {
    print('  🔴🔴 有用例构造失败 $selfCheckFail 处 ⇒ 下面的「安全」**不可信**，先修用例');
  }
  print('  ✅ 结构不变（可直接纳入白名单）: ${safe.map((c) => '`\\$c`').join(' ')}');
  print('  🔴 会造语法（需加保护条件或排除）: ${unsafe.keys.map((c) => '`\\$c`').join(' ')}');
  print('');
  print('  ⚠️ 本实验用 plusparse（解析器层）；渲染层（GptMarkdown）可能有额外处理，');
  print('     ⇒ 结论需真机复核（见文件头「局限」）。');
}
