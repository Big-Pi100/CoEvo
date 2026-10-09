// CoEvo · Markdown 渲染器的「inline 接线」验收 —— 🔴 守一类**完全静默**的失效
//
// 跑法：cd scripts/trace_verify && dart run bin/verify_markdown_inline_wiring.dart
// 🔴 退出码：0 = 全过，1 = 有失败。
//
// # 为什么需要它（2026-10-08 真机症状：**痕迹与划线在文章页全都不显示**）
//
// 文章页的痕迹 / 划线走的是 `gpt_markdown` 的「宿主自定义 inline 语法」。
// 1.3.0 提供了**两个**候选参数，而它们**不等价**：
//
// | 参数 | 包里是否被消费 | 语义 |
// |---|---|---|
// | `inlinePatterns` | ❌ **没有消费点**（只有声明 + `copyWith` 转发）| 在**解析之后**的纯文本 run 上匹配 |
// | `inlineDirectives` | ✅ 传给 `_normalizeMarkdownSource` + 有 `InlineDirectiveMd` | 在**解析之前**把区间整段抽出（base64 掩码）|
//
// ⇒ 用 `inlinePatterns` 的后果：**传了等于没传**，不报错、不警告、analyzer 完全沉默。
//    即使它被接线了，语义也不对 —— 标记区间里凡含 `**` / 反引号 / `[…](…)`
//    都会被 Markdown 先吃掉，正则**静默失败**（包文档原话：
//    「the parse has already happened … **the match silently fails**」）。
//
// 我们的标记区间就是**正文片段**（含这些语法是常态）⇒ 必须用 `inlineDirectives`。
//
// # 🔴 本脚本自身的证伪方式
// · 把 `inlineDirectives:` 改回 `inlinePatterns:` → ①② 必须变红
// · 把 `open:` 改成与注入端不一致的字符 → ③ 必须变红
//
// # ⚠️ 口径
// 只做**词法级**扫描（剥整行注释）——「消费点在不在包里」这件事**不能**在这里验
// （那要读 pub-cache 的包源码，路径脆弱）；本脚本守的是**我们这一侧的写法**，
// 而它恰好是出问题的那一侧。

import 'dart:io';

/// 仓库根 —— 含 `app/pubspec.yaml` 的那一层（从 cwd 逐级向上找）。
///
/// 🔑 判据同 `query_verify/_repo_paths.dart`：**向上找的依据是「特征文件」而不是「层数」**
///    —— 写死层数会在目录结构变化时静默失效。
String repoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${d.path}${Platform.pathSeparator}app'
            '${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      return d.path;
    }
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return Directory.current.path;
}

String repoPath(String relative) =>
    [repoRoot(), ...relative.split('/')].join(Platform.pathSeparator);

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(label + (detail.isEmpty ? '' : '  ($detail)'));
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    if (raw.trimLeft().startsWith('//')) continue;
    final i = raw.indexOf('//');
    out.add(i >= 0 ? raw.substring(0, i) : raw);
  }
  return out.join('\n');
}

void main() {
  final src = stripComments(
      File(repoPath('app/lib/widgets/trace_markdown.dart')).readAsStringSync());

  // ══════════════════════════════════════════════════════════════
  // 🔄 2026-10-08 修订：从「只许用 inlineDirectives」改为「**两条路都注册**」
  // ══════════════════════════════════════════════════════════════
  //
  // 原判据（只许 directive）建立在一条**错误结论**上：「`inlinePatterns` 没有消费点」。
  // 复查包源码发现它有**五处**消费点（`InlinePatternMd` 注册 · `maskInlinePatterns` ×3 ·
  // `expandInlinePatterns`）—— 当时 grep 漏了。
  //
  // 现在两条并存，理由是**失效条件正交**：
  //   · pattern   在**解析后**的文本上匹配 ⇒ 标记跨过 `**` / 反引号这类会拆节点的
  //     字符就匹配不上（探针实测）
  //   · directive 在**解析前**抽成 sentinel ⇒ 不怕拆节点，但**完全依赖 mask 成功**
  //     若 mask 被跳过 ⇒ sentinel 不存在 ⇒ 静默降级成不可见文本
  // ⇒ 任一条坏掉时另一条仍能兜住；且不会重复渲染（mask 先跑，标记已被换走）。
  //
  // ⚠️ 真机仍未显示痕迹（2026-10-08）⇒ 本文件守的是「**两种机制都还注册着**」，
  //    而不是「哪一种一定生效」—— 后者需要真机确认（见 `_kTraceDiagnostics` 诊断条）。
  print('① 两条路都必须注册（失效条件正交 ⇒ 互为保险）');
  check('①-0 找得到 `GptMarkdown(` 调用', src.contains('GptMarkdown('));
  check('①-1 传了 `inlineDirectives:`', src.contains('inlineDirectives:'));
  check('①-2 传了 `inlinePatterns:`（与 directive 互补的那条）',
      src.contains('inlinePatterns:'),
      '若红 ⇒ 只剩一条路，它的失效条件就没人兜');

  print('');
  print('② 两种标记都要注册（痕迹两档 + 划线），且两套机制都在');
  final directives = src.contains('_traceDirectiveOf(kTraceFreshOpen, 0)') &&
      src.contains('_traceDirectiveOf(kTraceReviewingOpen, 1)') &&
      src.contains('_highlightDirective()');
  final patterns = src.contains('_tracePattern()') && src.contains('_highlightPattern()');
  check('②-1 痕迹 fresh / reviewing 与划线**三个** directive 都在', directives);
  check('②-2 🆕 pattern 版（痕迹 + 划线）也都在', patterns,
      '若红 ⇒ 双注册只剩一半');
  check('②-3 `InlineDirective(` 与 `InlinePattern(` 两种构造都在',
      src.contains('InlineDirective(') && src.contains('InlinePattern('));

  print('');
  print('③ 定界符必须与**注入端**逐字一致（不一致 ⇒ 匹配不到 ⇒ 静默不渲染）');
  check('③-1 痕迹 open/close 用 `kTraceFreshOpen` / `kTraceReviewingOpen`',
      src.contains('open: marker') && src.contains('close: marker'));
  check('③-2 划线 open/close 用 `kHighlightOpen`',
      src.contains('open: kHighlightOpen') && src.contains('close: kHighlightOpen'));

  print('');
  print('═' * 70);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 症状对照：**痕迹与划线在文章页全都不显示**，而书架页正常');
    print('    （书架页走 `buildTextSegments` 纯文本切分，不经过 gpt_markdown）。');
  }
  print('═' * 70);
  if (_failures.isNotEmpty) exit(1);
}
