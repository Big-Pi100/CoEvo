// CoEvo · **文章正文分段**验收（纯函数 · 零 IO）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_article_text.dart
//
// # 为什么这层值得单独断言
// 「把一坨纯文本切成段落」看着简单，但它决定**阅读界面能不能读**：
// · 段边界丢了 → 整篇挤成一堵字墙（不好看，更**读不下去**）
// · 段切太碎 → 每句话都成一段，段落间距满屏
// 两者都**不报错**（页面照样渲染），只有断言能锁住。
//
// 🔴 与后端的分工（口径只有一处）：
//   后端 `content_rss::strip_html_block` 已按 **`\n\n`** 分好段 →
//   本层**只切不猜**（不按句号、不按字数）。若这里也做「智能分段」，
//   就出现两处段落口径，必然不一致。

import 'dart:io';

import '../../../app/lib/services/article_text.dart';

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

void main() {
  print('─' * 74);
  print('【1】基本分段（`\\n\\n` = 段边界）');
  print('─' * 74);
  check('两段', splitParagraphs('第一段\n\n第二段').length == 2);
  check('段内容正确',
      splitParagraphs('第一段\n\n第二段').join('|') == '第一段|第二段');
  check('三段', splitParagraphs('a\n\nb\n\nc').length == 3);

  print('');
  print('─' * 74);
  print('【2】段内软折行 → 合并成空格（**不是**新段）');
  print('─' * 74);
  // 🔑 源里常见「为了排版在 80 列处换行」→ 那不是段落
  check('单换行不切段',
      splitParagraphs('同一段的\n软折行').length == 1);
  check('且合并成一个空格',
      splitParagraphs('同一段的\n软折行').first == '同一段的 软折行');
  check('多行也合并', splitParagraphs('a\nb\nc').first == 'a b c');

  print('');
  print('─' * 74);
  print('【3】空行与空白**不该**产生空段');
  print('─' * 74);
  check('连续三连空行 → 仍只两段',
      splitParagraphs('a\n\n\n\nb').length == 2,
      '${splitParagraphs('a\n\n\n\nb')}');
  check('空行里带空格也算空行',
      splitParagraphs('a\n \n\t\nb').length == 2,
      '${splitParagraphs('a\n \n\t\nb')}');
  check('段首尾空白被 trim',
      splitParagraphs('   a   \n\n   b   ').join('|') == 'a|b');
  check('🔴 段内空行残留不会产生空段',
      splitParagraphs('a\n\n\n\nb').every((p) => p.isNotEmpty));

  print('');
  print('─' * 74);
  print('【4】空 / null 输入');
  print('─' * 74);
  check('null → 空列表', splitParagraphs(null).isEmpty);
  check('空串 → 空列表', splitParagraphs('').isEmpty);
  check('**仅空白** → 空列表（不是一段空白）', splitParagraphs('  \n\n  ').isEmpty);

  print('');
  print('─' * 74);
  print('【5】`hasReadableBody`：**不设「至少 N 段」门槛**');
  print('─' * 74);
  check('空 → false', !hasReadableBody(const []));
  // 🔴 关键：一段也算有正文 —— 一篇一句话的短讯是**合法内容**
  //    （HN 的 Ask HN 常常就一段）。设门槛会造出「内容存在但被判未就绪」
  //    这种用户无法理解的状态。
  check('🔴 **一段也算**有正文（短讯是合法内容）',
      hasReadableBody(const ['就一句话。']));
  check('多段 → true', hasReadableBody(const ['a', 'b']));

  print('');
  print('─' * 74);
  print('【6】真实形状：后端 `strip_html_block` 的产出（`\\n\\n` 分隔）');
  print('─' * 74);
  // 模拟后端产出（`strip_html_block` 已把 `</p>` 换成 `\n\n`）
  const backendOutput = 'In news that should surprise very few, connected cars remain a '
      'complete privacy nightmare.\n\nBut now we have a better idea of the scope.\n\n'
      'The Mozilla Foundation looked at 25 car brands.';
  final paras = splitParagraphs(backendOutput);
  check('🔴 真实形状切成 3 段', paras.length == 3, '${paras.length}');
  check('🔴 每段都不含换行（渲染层可直接当单行文本用）',
      paras.every((p) => !p.contains('\n')));
  check('🔴 首段内容完整（没被切断）',
      paras.first.startsWith('In news that should surprise'));

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
