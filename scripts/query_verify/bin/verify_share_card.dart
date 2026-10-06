// 学习记录分享图 —— 断言（纯逻辑真跑 + 源级接线）
//
// # 怎么跑
// ```bash
// cd scripts/query_verify && dart run bin/verify_share_card.dart
// ```
//
// # 🔴 本脚本守的是什么
// 分享图是**对外触点**（用户会把它发到小红书/朋友圈）⇒ 两类错误代价特别高：
//
// | 类 | 例子 | 后果 |
// |---|---|---|
// | **对外泄露** | 图上带上用户 id / 邮箱 / 推荐码 | 用户数据外流（且他未必知道）|
// | **违规引流** | 图上带二维码 / 文案带链接 | 社交平台判营销 ⇒ **限流甚至封号**（规格 §5.7.3 原文）|
//
// ⇒ 所以本脚本对这两类**各设了独立断言**，而不是只验「功能能跑」。
//
// # ⚠️ 本脚本只读文件 + 跑纯函数，**不碰 Flutter**
// `share_card_data.dart` 是**零 import** 的纯逻辑（刻意的，见其文件头）⇒
// 本机（跑不了 flutter）也能完整验证其中的判定与文案。
// 渲染层（`share_card.dart` / `share_card_preview.dart`）只能用**源级断言**覆盖结构，
// ⚠️ **渲染效果仍需真机确认** —— 本脚本验不了「图长什么样」。
//
// # 🔴 证伪记录（改判据后应重跑一遍）
// | 注入的回归 | 应变红 |
// |---|---|
// | `milestoneReached` 用 `>=` 而非 `==` | 【1】多个用例 |
// | `shareText` 加回 `?ref=` 链接 | 【4】URL 一组 |
// | `shareText` 加回 `https://…` | 【4】 |
// | `fromMetrics` 不做里程碑判定（恒 regular） | 【2】 |
// | `group` 去掉千分位 | 【3】 |
// | `shareCardPreviewScale` 去掉下限 0.4 | 【6】 |
// | `stats_card` 换回 `Share.share` | 【7】 |
// | `stats_card` 加回 `referralCode` 参数 | 【7】 |
// | `share_card_preview` 把 `Transform` 放进 `RepaintBoundary` 内层 | 【8】顺序 |
// | `share_card` 硬编码 `Color(0xFFB4432C)` | 【9】 |
// | `profile_screen` 加回 `/api/referral/my-code` | 【10】 |
//
// ignore_for_file: avoid_print

import 'dart:io';

import '../../../app/lib/services/share_card_data.dart';

// ══════════════════════════════════════════════════════════════
// 断言骨架（与 scripts/ 下其它脚本同形）
// ══════════════════════════════════════════════════════════════

int _pass = 0;
final List<String> _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(detail.isEmpty ? label : '$label —— $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  [$detail]'}');
  }
}

void section(String title) {
  print('');
  print('═' * 74);
  print(title);
  print('═' * 74);
}

/// 读文本（相对 `scripts/query_verify/`）。
String read(String rel) => File(rel).readAsStringSync();

/// 剥掉**整行**注释。
///
/// 🔴 只按整行剥（`trimLeft().startsWith('//')`），**不切行内的 `//`** ——
///    因为切行内会把 URL 里的 `//` 也切掉（本项目已踩过：5 处同族实现里 3 处是错的）。
/// ⚠️ 代价如实说：**行尾注释不会被剥** ⇒ 若某行代码后面写着 `// 别用 referralCode`，
///    该断言仍会看到 `referralCode`。可接受（宁可假红，不要假绿）。
String stripComments(String src) {
  final out = <String>[];
  for (final line in src.split('\n')) {
    if (line.trimLeft().startsWith('//')) continue;
    out.add(line);
  }
  return out.join('\n');
}

// ══════════════════════════════════════════════════════════════

void main() {
  print('CoEvo · 学习记录分享图 · 断言');

  // ══════════════════════════════════════════════════════════
  section('【1】里程碑判定（恰好命中档位才算，`==` 不是 `>=`）');
  // ══════════════════════════════════════════════════════════
  check('  档位常量 = 7 / 30 / 100 / 365（规格 §5.7.3）',
      kMilestoneDays.length == 4 &&
          kMilestoneDays.contains(7) &&
          kMilestoneDays.contains(30) &&
          kMilestoneDays.contains(100) &&
          kMilestoneDays.contains(365),
      '$kMilestoneDays');

  for (final d in kMilestoneDays) {
    check('  连续 $d 天 ⇒ 命中', milestoneReached(d) == d, '$d');
  }

  // 🔴 这一组是「`>=` 会挂」的证据：过一天就不该再算里程碑
  for (final d in <int>[0, 1, 6, 8, 29, 31, 99, 101, 364, 366, 1000]) {
    check('  连续 $d 天 ⇒ 不算里程碑', milestoneReached(d) == null,
        '实测 ${milestoneReached(d)}');
  }
  check('  负数 ⇒ 不算', milestoneReached(-1) == null);

  // ══════════════════════════════════════════════════════════
  section('【2】fromMetrics：自动判定形态');
  // ══════════════════════════════════════════════════════════
  final at100 = ShareCardData.fromMetrics(
      streakDays: 100, matureCards: 1203, articlesRead: 86);
  check('  100 天 ⇒ 里程碑版', at100.kind == ShareCardKind.milestone, '${at100.kind}');
  check('  且 milestoneDay == 100', at100.milestoneDay == 100, '${at100.milestoneDay}');

  final at99 = ShareCardData.fromMetrics(
      streakDays: 99, matureCards: 1203, articlesRead: 86);
  check('  99 天 ⇒ 常规版', at99.kind == ShareCardKind.regular, '${at99.kind}');
  check('  且 milestoneDay == null', at99.milestoneDay == null);

  final at0 = ShareCardData.fromMetrics(
      streakDays: 0, matureCards: 0, articlesRead: 0);
  check('  0 天 ⇒ 常规版（不崩）', at0.kind == ShareCardKind.regular);
  check('  三个数字原样保留（0 也是合法的）',
      at0.streakDays == 0 && at0.matureCards == 0 && at0.articlesRead == 0);

  // ══════════════════════════════════════════════════════════
  section('【3】千分位（四位以上可读性）');
  // ══════════════════════════════════════════════════════════
  check('  0 ⇒ 0', ShareCardData.group(0) == '0', ShareCardData.group(0));
  check('  123 ⇒ 123', ShareCardData.group(123) == '123', ShareCardData.group(123));
  check('  1234 ⇒ 1,234', ShareCardData.group(1234) == '1,234', ShareCardData.group(1234));
  check('  12345 ⇒ 12,345',
      ShareCardData.group(12345) == '12,345', ShareCardData.group(12345));
  check('  1234567 ⇒ 1,234,567',
      ShareCardData.group(1234567) == '1,234,567', ShareCardData.group(1234567));

  // ══════════════════════════════════════════════════════════
  section('【4】🔴🔴 shareText 不得含任何 URL（规格 §5.7.3 · 违规引流）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔑 为什么单列一节：这里曾是 `?ref=<推荐码>`（K12 分销残留），
  //    是**从旧实现改回来的** —— 不加断言，很容易在某次「顺手加个链接方便用户找到」
  //    时被改回去，而后果是**用户被平台限流**（本人未必知道原因）。
  final texts = <String>[
    shareText(at100),
    shareText(at99),
    shareText(at0),
  ];
  for (final t in texts) {
    final label = t.length > 26 ? '${t.substring(0, 26)}…' : t;
    check('  「$label」不含 http', !t.contains('http'));
    check('  「$label」不含 ://', !t.contains('://'));
    check('  「$label」不含 ref=', !t.contains('ref='));
    check('  「$label」不含 .fun / .com 域名尾巴',
        !t.contains('.fun') && !t.contains('.com'));
  }
  check('  含品牌名（规格：「只放品牌名，让用户主动搜索」）',
      texts.every((t) => t.contains(kShareCardBrand)), kShareCardBrand);
  check('  里程碑版用**档位**（不是当前天数）',
      shareText(at100).contains('100'), shareText(at100));
  check('  常规版用**当前天数**',
      shareText(at99).contains('99'), shareText(at99));

  // ══════════════════════════════════════════════════════════
  section('【5】文件名 + 尺寸常量');
  // ══════════════════════════════════════════════════════════
  check('  文件名格式 coevo_stats_yyyyMMdd.png',
      shareFileName(DateTime(2026, 10, 6)) == 'coevo_stats_20261006.png',
      shareFileName(DateTime(2026, 10, 6)));
  check('  月份/日期补零',
      shareFileName(DateTime(2026, 1, 9)) == 'coevo_stats_20260109.png',
      shareFileName(DateTime(2026, 1, 9)));

  check('  比例常量 = 3:4（规格：「竖版 3:4」）',
      kShareCardAspectW * kShareCardHeight == kShareCardAspectH * kShareCardWidth,
      '$kShareCardAspectW:$kShareCardAspectH vs $kShareCardWidth×$kShareCardHeight');
  check('  逻辑尺寸 = 360×480',
      kShareCardWidth == 360 && kShareCardHeight == 480,
      '$kShareCardWidth×$kShareCardHeight');
  check('  导出宽 = 1080（360 × 3.0）',
      (kShareCardWidth * kShareCardPixelRatio).round() == 1080,
      '${kShareCardWidth * kShareCardPixelRatio}');

  // ══════════════════════════════════════════════════════════
  section('【6】预览缩放（小屏能放下 · 大屏不放大）');
  // ══════════════════════════════════════════════════════════
  final big = shareCardPreviewScale(screenW: 1200, screenH: 2000);
  check('  大屏 ⇒ 1.0（不放大，放大会糊）', big == 1.0, '$big');

  final mid = shareCardPreviewScale(screenW: 390, screenH: 844);
  check('  常见手机（390×844）⇒ 0.4–1.0 之间', mid >= 0.4 && mid <= 1.0, '$mid');
  check('  且宽度够放（390 - 64 = 326 ≥ 360×$mid）',
      360 * mid <= 390 - 64 + 0.01, '${360 * mid}');

  final tiny = shareCardPreviewScale(screenW: 200, screenH: 300);
  check('  极小屏 ⇒ 不低于 0.4（再小等于没显示）', tiny >= 0.4, '$tiny');

  // ══════════════════════════════════════════════════════════
  section('【7】源级：stats_card 接线（换掉文字分享 · 去掉推荐码）');
  // ══════════════════════════════════════════════════════════
  final stats = read('../../app/lib/widgets/stats_card.dart');
  final statsCode = stripComments(stats);

  check('  调用了 showShareCardPreview', statsCode.contains('showShareCardPreview('));
  check('  🔴 不再直接 Share.share（纯文字）', !statsCode.contains('Share.share'));
  check('  🔴 不再 import share_plus', !statsCode.contains('share_plus'));
  check('  🔴 无 referralCode 参数', !statsCode.contains('referralCode'));
  check('  用 ShareCardData.fromMetrics 构造数据',
      statsCode.contains('ShareCardData.fromMetrics('));

  // ══════════════════════════════════════════════════════════
  section('【8】源级：渲染管线（尺寸恒定 是关键）');
  // ══════════════════════════════════════════════════════════
  final prev = read('../../app/lib/widgets/share_card_preview.dart');
  final prevCode = stripComments(prev);

  check('  用 RepaintBoundary 取图', prevCode.contains('RepaintBoundary('));
  check('  用 toImage 渲染', prevCode.contains('.toImage('));
  check('  传了 kShareCardPixelRatio（导出尺寸恒定）',
      prevCode.contains('pixelRatio: kShareCardPixelRatio'));
  check('  用 exportPngBytes 分享（原生唯一可行路径）',
      prevCode.contains('exportPngBytes('));
  check('  文件名/文案都走纯逻辑层',
      prevCode.contains('shareFileName(') && prevCode.contains('shareText('));
  check('  toByteData 指定 PNG 格式',
      prevCode.contains('ImageByteFormat.png'));

  // 🔴🔴 缩放必须用 `FittedBox`，**不能**用 `Transform.scale`（2026-10-06 真机踩过）
  //
  // 为什么：`Transform` **不改变布局约束** —— 它把父给的 `tight(360*scale, …)`
  // 原样传给 child ⇒ 里面 `SizedBox(360,480)` 被**压成** `360*scale`
  // ⇒ `RepaintBoundary.size` 变小 ⇒ `toImage` 出的图**随屏幕变化**
  //    （正好废掉「导出尺寸恒定」这个保证，而**当时没有任何断言能发现**）。
  // ✅ `FittedBox` 给 child 无界约束 ⇒ child 按 360×480 布局，再缩放显示 ✓
  //    🔑 **源码依据**（`rendering/proxy_box.dart` · `RenderFittedBox.performLayout`）：
  //    ```dart
  //    child!.layout(const BoxConstraints(), parentUsesSize: true);   // ← 全无界
  //    ...
  //    size = constraints.constrainSizeAndAttemptToPreserveAspectRatio(child!.size);
  //    ```
  //    ⇒ child 拿到 `BoxConstraints()`（min/max 全无界）⇒ `SizedBox(360,480)` 取自身尺寸
  //      ⇒ `RepaintBoundary.size` **恒为 360×480** ⇒ `toImage(3.0)` 恒得 1080×1440 ✓
  check('  🔴 用 FittedBox 缩放（不是 Transform.scale）',
      prevCode.contains('FittedBox('), '缺 FittedBox');
  check('  🔴 **不得**出现 Transform.scale（会把卡片压小 ⇒ 导出尺寸随屏幕变）',
      !prevCode.contains('Transform.scale'), '用了 Transform.scale');

  // 🔴 `ByteData` 来自 `dart:typed_data`（**不是** `dart:ui`）
  //    2026-10-06 真机编译报 `'ByteData' isn't a type`（本机跑不了 flutter ⇒ 只在真机暴露）
  //
  // ⚠️ **两条都必须用 `prevCode`（剥了注释的）** ——
  //    因为本文件对应的**注释里就写着**「不得写 `ui.ByteData`」这句话，
  //    用原文查会**假红**（断言把"说明文字"当成了"代码"）。
  //    第一版就是这么错的，被自己的注释绊倒。
  check('  🔴 导入了 dart:typed_data（ByteData 的来源）',
      prevCode.contains("import 'dart:typed_data';"), '缺 dart:typed_data');
  check('  🔴 **不得**写 ui.ByteData（不存在 ⇒ 编译报 `isn\'t a type`）',
      !prevCode.contains('ui.ByteData'), '写了 ui.ByteData');

  // ══════════════════════════════════════════════════════════
  section('【9】源级：share_card 用 token（不另写一套色）');
  // ══════════════════════════════════════════════════════════
  final card = read('../../app/lib/widgets/share_card.dart');
  final cardCode = stripComments(card);

  check('  用了 tokens.accent', cardCode.contains('tokens.accent'));
  check('  用了 tokens.ink', cardCode.contains('tokens.ink'));
  check('  用了 tokens.page（paper 版底色）', cardCode.contains('tokens.page'));
  check('  🔴 无硬编码 hex（防「另写一套色」⇒ 改主题时分享图留在旧色）',
      !RegExp(r'0x[0-9A-Fa-f]{8}').hasMatch(cardCode) &&
          !RegExp(r'#[0-9A-Fa-f]{6}').hasMatch(cardCode));
  check('  字体用 CoFonts 常量（不写裸字符串）',
      cardCode.contains('CoFonts.') && !cardCode.contains("fontFamily: '"));
  check('  用的是纯逻辑层常量（比例/品牌/副标）',
      cardCode.contains('kShareCardWidth') &&
          cardCode.contains('kShareCardBrand') &&
          cardCode.contains('kShareCardTagline'));

  // ══════════════════════════════════════════════════════════
  section('【10】🔴 反向：分享图**不得**含二维码（规格 §5.7.3）');
  // ══════════════════════════════════════════════════════════
  //
  // 规格原文：「小红书/微信对图片中的二维码会判定为站外引流，限流甚至封号」
  // ⇒ 图上只能有品牌名。
  for (final q in <String>['QrImage', 'QrCode', 'qr_flutter', 'QRCode', 'qrcode']) {
    check('  share_card.dart 不含 $q', !cardCode.contains(q));
    check('  share_card_preview.dart 不含 $q', !prevCode.contains(q));
  }

  // ══════════════════════════════════════════════════════════
  section('【11】源级：profile 已清掉 K12 分销端点');
  // ══════════════════════════════════════════════════════════
  final prof = read('../../app/lib/screens/profile_screen.dart');
  final profCode = stripComments(prof);

  check('  🔴 不再调 /api/referral/my-code',
      !profCode.contains('/api/referral/my-code'));
  check('  🔴 无 _loadReferralCode', !profCode.contains('_loadReferralCode'));
  check('  🔴 无 _referralCode 字段', !profCode.contains('_referralCode'));
  check('  StatsCard 用无参构造', profCode.contains('StatsCard()'));

  // ══════════════════════════════════════════════════════════
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    exitCode = 1;
  }
}
