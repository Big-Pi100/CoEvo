// CoEvo · 阅读器设置验收（纯逻辑 + 接线）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_reading_settings.dart
// 🔴 退出码：0 = 全过，1 = 有失败（**直读**，别接 `| tail` —— 管道会让 `$?` 取到 tail 的）。
//
// # 它守什么
//
// ① **规则层**（真跑 `clampReadingFontSize`）—— 字号的区间与边界。
//    🔴 这一层的错误**不报错**：字号 0 ⇒ 正文不可见，用户以为「文章是空的」。
//
// ② **默认值**（锁 17 而不是 spec 写的 18）——
//    白哥 2026-09-27 显式定的 17。若有人照 spec 改回 18，
//    会**静默改掉用户已在用的观感**（属「撤回已定案」）⇒ 必须锁。
//
// ③ **键名唯一**（`ReadingPrefKeys`）—— 写端/读端必须同一个字符串。
//    写错**不报错**：读回默认值 ⇒ 表现为「设置不生效」。
//
// ④ **接线**（源级）—— 若只做完 `services/reading_settings.dart` 而没接进
//    `reader_screen`，那这个功能**等于不存在**，且**任何测试都不会红**。
//    这正是本项目反复踩的「**写了没人跑 = 迟早失效**」。
//
// # 🔴 已证伪（改断言后应重跑一遍）
//
// | 注入的回归 | 应变红 |
// |---|---|
// | `clampReadingFontSize` 去掉下界判断 | 【1】负数/0 → 15 |
// | `kReadingFontSizeDefault` 改回 18 | 【2】默认值 = 17 |
// | `ReadingPrefKeys.fontSize` 改一个字符 | 下条「键名与 provider 一致」 |
// | `reader_screen` 字号改回硬编码 17 | 【4】不得硬编码 |
// | `reader_screen` 不传 `traceEnabled` | 【5】必须传 |
// | `TraceMarkdown.traceEnabled` 默认改 false | 【6】默认 true |
//
// # ⚠️ 口径（如实标注）
// · **只 import `dart:io` + 零 import 的 `app/lib/services/reading_settings.dart`**
//   ⇒ 不需要 Flutter / 真库，**本机完整可跑**。
// · 它是**源级断言**：只证明「代码是这么写的」，**不**证明「真机上字号真的变了」。
//   ⚠️ 本轮**未做**真机验证（本项目工具的已知边界：AI 终端跑不了 flutter）。
//   📌 真机要验三件：① 字号 −/+ 生效 ② 痕迹开关真的不标 ③ 面板能打开。

import 'dart:io';

import '../../../app/lib/services/reading_settings.dart';

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

void section(String s) {
  print('');
  print('─' * 74);
  print(s);
  print('─' * 74);
}

/// 剥掉**整行**注释。
///
/// 🔴 必须整行 —— 「每行切 `//`」会把代码里的 `//`（URL/正则）当注释起点
/// ⇒ 后半段消失 ⇒ **反向断言假绿**（本项目已踩过：5 处里 3 处是错的）。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String readNoComment(String rel) => stripComments(File(rel).readAsStringSync());
String read(String rel) => File(rel).readAsStringSync();

void main() {
  print('');
  print('#' * 74);
  print('# 阅读器设置验收 —— 字号规则 · 默认值 · 键名唯一 · 接线');
  print('#' * 74);

  // ══════════════════════════════════════════════════════════
  section('【1】字号规则：`clampReadingFontSize`（**真跑**，不是查文本）');
  // ══════════════════════════════════════════════════════════
  check('合法值不动：17 → 17', clampReadingFontSize(17) == 17);
  check('  下界：15 → 15', clampReadingFontSize(15) == 15);
  check('  上界：24 → 24', clampReadingFontSize(24) == 24);
  // 🔴 越界必须钳住 —— 这是本函数存在的唯一理由
  check('🔴 低于下界：0 → 15（**否则正文不可见**）',
      clampReadingFontSize(0) == kReadingFontSizeMin,
      '实际 ${clampReadingFontSize(0)}');
  check('🔴 低于下界：-3 → 15', clampReadingFontSize(-3) == kReadingFontSizeMin);
  check('🔴 高于上界：999 → 24', clampReadingFontSize(999) == kReadingFontSizeMax);
  check('  小数取整：17.6 → 18', clampReadingFontSize(17.6) == 18);
  check('  小数取整：17.4 → 17', clampReadingFontSize(17.4) == 17);
  check('🔴 NaN → 默认值（不是 0）',
      clampReadingFontSize(double.nan) == kReadingFontSizeDefault);
  check('  double 入参（来自 JSON/prefs 的常见形态）：20.0 → 20',
      clampReadingFontSize(20.0) == 20);

  // ══════════════════════════════════════════════════════════
  section('【2】边界判定（供 UI 禁用 −/+ 键）');
  // ══════════════════════════════════════════════════════════
  check('  15 处于下限', isReadingFontSizeAtMin(15));
  check('  16 不在下限', !isReadingFontSizeAtMin(16));
  check('🔴 越界值也算「在下限」（先钳再判）', isReadingFontSizeAtMin(0));
  check('  24 处于上限', isReadingFontSizeAtMax(24));
  check('  23 不在上限', !isReadingFontSizeAtMax(23));
  check('🔴 越界值也算「在上限」', isReadingFontSizeAtMax(999));

  // ══════════════════════════════════════════════════════════
  section('【3】规格链：默认值与区间');
  // ══════════════════════════════════════════════════════════
  check('🔴 区间 = spec §5.1 的 15–24',
      kReadingFontSizeMin == 15 && kReadingFontSizeMax == 24,
      '实测 $kReadingFontSizeMin–$kReadingFontSizeMax');
  check('🔴🔴 默认值 = **17**（白哥 2026-09-27 定），**不是 spec 的 18**',
      kReadingFontSizeDefault == 17,
      '若有人照 spec 改成 18 ⇒ 静默改掉用户已在用的观感');
  check('  默认值落在区间内', kReadingFontSizeDefault >= kReadingFontSizeMin &&
      kReadingFontSizeDefault <= kReadingFontSizeMax);
  check('🔴 痕迹默认**开启**（spec §5.1「默认开启」）', kTraceEnabledDefault);

  // ══════════════════════════════════════════════════════════
  section('【4】键名唯一（写端与读端必须同一字符串）');
  // ══════════════════════════════════════════════════════════
  check('  `fontSize` 键值非空', ReadingPrefKeys.fontSize.isNotEmpty,
      ReadingPrefKeys.fontSize);
  check('  `traceEnabled` 键值非空', ReadingPrefKeys.traceEnabled.isNotEmpty,
      ReadingPrefKeys.traceEnabled);
  check('🔴 两个键**不相同**（否则互相覆盖）',
      ReadingPrefKeys.fontSize != ReadingPrefKeys.traceEnabled);

  // 🔴🔴 **锁住键名的字面值** —— 这是「**对外契约**」，不是随便起的名字。
  //
  // 证伪时实测发现：把 `ReadingPrefKeys.fontSize` 改一个字符，**所有断言都是绿的** ——
  // 因为写端与读端**共用同一个常量**，一起改了 ⇒ 运行时依然自洽。
  // ⚠️ 但后果是**真实的**：磁盘上已存的用户设置用的是**旧键名** ⇒ 读不出来
  //   ⇒ 用户的字号/痕迹开关**被静默重置为默认值**（且不报错）。
  //
  // 📌 判据：**持久化的键名一旦发布就是对外契约**（同 UserDefaults / 数据库列名）。
  //    本项目已有同族教训（`sqlite-schema-migration` skill：老库里的数据不会自己跟着改）。
  // 🔑 当前状态：**尚未发布** ⇒ 现在改还来得及；**上架后改 = 丢用户设置**。
  check('🔴🔴 键名字面值＝契约（改它 = 已发布后丢用户设置）',
      ReadingPrefKeys.fontSize == 'reading_font_size' &&
          ReadingPrefKeys.traceEnabled == 'reading_trace_enabled',
      '实测 ${ReadingPrefKeys.fontSize} / ${ReadingPrefKeys.traceEnabled}');

  final providerSrc = readNoComment(
      '../../app/lib/providers/reading_settings_provider.dart');
  // 🔴 反向：provider **不得**自己写键名（必须引用 ReadingPrefKeys）
  check('🔴 provider 只经 `ReadingPrefKeys` 读写（不写死字符串）',
      providerSrc.contains('ReadingPrefKeys.fontSize') &&
          providerSrc.contains('ReadingPrefKeys.traceEnabled'),
      '写死 = 将来改键名必漏一处');
  final hardcoded = RegExp(r"'reading_font_size'|'reading_trace_enabled'")
      .allMatches(providerSrc)
      .length;
  check('  且 provider 里 0 处字面量键名', hardcoded == 0, '实测 $hardcoded 处');

  // ══════════════════════════════════════════════════════════
  section('【5】🔴 接线：阅读器真的用上了（否则功能等于不存在）');
  // ══════════════════════════════════════════════════════════
  final reader = readNoComment('../../app/lib/screens/reader_screen.dart');
  check('  reader import 了 provider',
      reader.contains("reading_settings_provider.dart"), '');
  check('  reader import 了面板',
      reader.contains("reading_settings_panel.dart"), '');
  check('🔴 reader `watch(readingSettingsProvider)`',
      reader.contains('readingSettingsProvider'), '');
  check('🔴 字号取自 provider（`rs.fontSize`）',
      reader.contains('rs.fontSize'), '');
  // 🔴 反向：不得再有硬编码字号常量（同一件事两处口径）
  //
  // ⚠️ **口径要窄** —— 本脚本第一版用了 `fontSize:\s*\d+`，
  //    结果命中 **9 处**（分类行 `fontSize: 12.5` · 标题 `fontSize: 21` … 全是**别的**字号），
  //    把「已修好」误报成红（**假红**）。
  //    📌 判据：**反向断言的范围要等于「被替换掉的那个东西」的范围** ——
  //      这里被替换的是「**正文字号**」，所以只看 `_bodyFontSize` 与 `bodyFontSize:`。
  final legacyConst = RegExp(r'_bodyFontSize').allMatches(reader).length;
  final hardcodedBody = RegExp(r'bodyFontSize:\s*\d').allMatches(reader).length;
  check('🔴 reader 里 **0 处**硬编码正文字号',
      legacyConst == 0 && hardcodedBody == 0,
      '常量残留 $legacyConst 处 · 字面量 $hardcodedBody 处 —— 硬编码会与设置打架');
  check('🔴 reader 把 `traceEnabled` 传给了 TraceMarkdown',
      reader.contains('traceEnabled:'), '');

  // ══════════════════════════════════════════════════════════
  section('【6】`TraceMarkdown` 的开关语义');
  // ══════════════════════════════════════════════════════════
  final traceSrc =
      readNoComment('../../app/lib/widgets/trace_markdown.dart');
  check('  有 `traceEnabled` 字段', traceSrc.contains('traceEnabled'));
  check('🔴 默认 `true`（既有调用方行为逐字不变）',
      RegExp(r'this\.traceEnabled\s*=\s*true').hasMatch(traceSrc),
      '默认改 false 会让**所有旧调用方**突然没痕迹');
  check('🔴 关掉时**传空 tiers**（而不是改样式）',
      traceSrc.contains('const <String, int>{}'),
      '「不注入」保证「已掌握与普通文字逐像素一致」；改透明可能残留');

  // ══════════════════════════════════════════════════════════
  section('【7】面板：常量引自规则层（不重复写数字）· 不用弃用参数');
  // ══════════════════════════════════════════════════════════
  final panel = readNoComment('../../app/lib/widgets/reading_settings_panel.dart');
  check('  面板 import 了规则层', panel.contains("reading_settings.dart"), '');
  check('🔴 面板用 `isReadingFontSizeAtMin/Max`（不自己写边界判断）',
      panel.contains('isReadingFontSizeAtMin') &&
          panel.contains('isReadingFontSizeAtMax'),
      '');
  // 🔴 `activeColor` 已在较新 Flutter 弃用 ⇒ 用了会 **deprecation warning**，
  //    而本项目 CI 是 `--no-fatal-infos`（**warning 致命**）⇒ 直接红。
  //    ✅ 正确做法：颜色交给主题层的 `SwitchThemeData`（`theme_builder.dart:271`）。
  check('🔴 面板里的 `Switch` **不传 `activeColor`**（已弃用 · warning 致命）',
      !RegExp(r'Switch\([\s\S]{0,200}?activeColor').hasMatch(panel),
      '');
  check('🔴 面板的 `Slider` **不传 `activeColor`**（同上）',
      !RegExp(r'Slider\([\s\S]{0,300}?activeColor').hasMatch(panel),
      '');
  check('  面板的语速与设置页**同一步长表达式**（0.1）',
      panel.contains('(kSpeechRateMax - kSpeechRateMin) / 0.1'),
      '两处入口必须同口径，否则「同一个值、两种粒度」');

  // ══════════════════════════════════════════════════════════
  section('【8】入口：单击正文 + 顶栏键（**两个**，且说清了为什么）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔑 断言「这些说明在」是有意义的：它们让**后来人**知道
  //    ① 单击正文这条**依赖手势竞技场**（从 SDK 源码推断，未真机验）
  //    ② 因此**故意**留了顶栏键做兜底
  //    —— 少了它们，后人可能"顺手删掉冗余入口"，或以为单击一定生效。
  //
  // ⚠️ **必须读「含注释」的原文** —— `readNoComment` 会把整行 `///` 剥掉，
  //    而这段说明**全在注释里** ⇒ 用它查必然**假红**（第一版就踩了）。
  //    📌 判据：**断言的范围必须等于被测对象的范围**（这里被测的就是「一句注释」）。
  //
  // 🔴 2026-10-06 二次修正：本条原本查的是「**临时入口**」——
  //    而白哥定案后入口变成**永久双入口**（单击 + 顶栏键），「临时」二字已过时。
  //    ⚠️ 危险在于：文件里 `_ReaderBar` 那行注释**还留着**「临时入口」⇒
  //    断言**照样绿**（这就是「**断言会保护过时事实**」）。
  //    ✅ 已把那处注释一并改掉，本条断言也换成新语义。
  //    📌 判据：**改了语义要连带改断言**，否则断言在守一个**已经不存在**的说法。
  final readerRaw = read('../../app/lib/screens/reader_screen.dart');
  check('🔴 写明了「单击正文」是 spec 原定入口',
      readerRaw.contains('单击屏幕中央') || readerRaw.contains('单击正文'),
      '');
  check('🔴 写明了为什么**保留顶栏键**（兜底：单击依赖手势竞技场）',
      readerRaw.contains('两个都留') || readerRaw.contains('兜底'),
      '');
  check('🔴 并写明了「未真机验证」这个前提',
      readerRaw.contains('真机'),
      '少了它，后人会以为单击已经验过');
  check('  **无**过时措辞「临时入口」',
      !readerRaw.contains('临时入口'),
      '入口已定为永久双入口，「临时」会误导后人');

  // ══════════════════════════════════════════════════════════
  section('【9】朗读卡搬迁：「我的」页 → 面板（2026-10-06 白哥定）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔑 搬的是**整卡**（语速 + 音色 + 试听）。断言要守两件：
  //    ① 面板**确实拿到了**这三样（否则「搬」等于「删」）
  //    ② 「我的」页**确实清干净了**（否则留下孤儿符号 ⇒ CI warning 致命）
  check('🔴 面板有音色选择（`DropdownButtonFormField`）',
      panel.contains('DropdownButtonFormField'), '');
  check('🔴 面板有试听（且用**固定短句**，不拿正文试听）',
      // 🔴 必须用**字面量正则** `'试听'`（带引号），不能用 `contains('试听')` ——
      //    证伪时实测踩到：把文案改成 `'试听X'` 后 `contains('试听')` **仍然匹配**
      //    ⇒ **假绿**。这正是「**子串断言锁不到接线**」的经典形态。
      //    📌 判据：断言「某个**值**存在」时要连**边界**一起锁（引号/词边界/结束符）。
      RegExp(r"'\s*试听\s*'").hasMatch(panel) &&
          panel.contains('_kPreviewText'),
      '拿正文试听会一点念几分钟');
  check('  面板持有音色的写入（`selectVoice`）',
      panel.contains('selectVoice'), '');

  final profile = readNoComment('../../app/lib/screens/profile_screen.dart');
  check('🔴 「我的」页**不再**有朗读卡定义',
      !profile.contains('_buildSpeechCard'),
      '只删调用、留定义 ⇒ 死代码（且 analyzer 会报未使用）');
  check('🔴 孤儿符号已清（`_previewNativeTts` / `_nativePreviewText`）',
      !profile.contains('_previewNativeTts') &&
          !profile.contains('_nativePreviewText'),
      '留下会成为 **unused_element** ⇒ CI 是 `--no-fatal-infos`（**warning 致命**）');
  check('🔴 且 `import tts_service` 已删（否则 unused_import 致命）',
      !profile.contains("services/tts_service.dart"),
      '');
  check('  但 profile 里的「已搬走」说明还在（供后人查）',
      read('../../app/lib/screens/profile_screen.dart').contains('已搬走'),
      '少了它，后人会以为那张卡是"不小心删掉的"');

  // ══════════════════════════════════════════════════════════
  section('【10】书库页也接面板（白哥：「书库没有同步设置面板」）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔑 这条守的是「**同一功能在两页都有**」——
  //    只接了信息流阅读器、书库漏掉，是典型的「改了 A 端，B 端没跟上」，
  //    而它**不报错**（书库页照常能用，只是没有设置）。
  final book = readNoComment('../../app/lib/screens/book_reader_screen.dart');
  check('🔴 书库 import 了设置 provider', book.contains('reading_settings_provider'), '');
  check('🔴 书库 import 了设置面板', book.contains('reading_settings_panel'), '');
  check('🔴 书库正文字号取自设置（不再是写死的 17）',
      book.contains('_bodyFontSize') &&
          RegExp(r'ref\.watch\(readingSettingsProvider\)').hasMatch(book),
      '');
  check('🔴 书库有设置入口（顶栏键）', book.contains('format_size'), '');
  check('🔴 书库支持「单击正文唤出」（onTap 传给 WordLookupSelection）',
      RegExp(r'WordLookupSelection\([\s\S]{0,400}?onTap:').hasMatch(book),
      '');
  // 🔑 书库**有意不记痕迹** ⇒ 面板必须传 `showTrace: false`，
  //    否则那个开关「拨了没反应」= 本项目大忌「静默失败 + 无出口」。
  //
  // 🔴🔴 **必须用「计数」而不是「存在」** —— 证伪时实测踩到：
  //    书库有**两处**入口（顶栏键 + 单击正文），我证伪时只替换了第一处，
  //    「存在一处带 showTrace」**仍为真** ⇒ 断言**照样绿**（假绿）。
  //    📌 判据：**同一件事有多个调用点时要数「是否每一处都对」**，
  //      只查「至少一处对」= 漏一个调用点发现不了。
  //      （同族：「一处定义用计数」——本项目既有手法。）
  final bookCallCount =
      RegExp(r'showReadingSettingsPanel\(').allMatches(book).length;
  final bookSafeCount =
      RegExp(r'showReadingSettingsPanel\(\s*context,\s*showTrace:\s*false')
          .allMatches(book)
          .length;
  check('🔴 书库**每一处**入口都传了 `showTrace: false`（共 $bookCallCount 处）',
      bookCallCount > 0 && bookCallCount == bookSafeCount,
      '有 ${bookCallCount - bookSafeCount} 处没传 ⇒ 那里拨开关没反应');
  // 🔴 反向：不得再有写死的**正文字号**（顶栏书名的 17 属 UI chrome，不算）
  final hardcodedBodyInBook =
      RegExp(r'fontSize:\s*17,\s*\n\s*height').allMatches(book).length;
  check('🔴 书库正文字号**无**硬编码（`fontSize: 17, height:` 形态）',
      hardcodedBodyInBook == 0,
      '实测 $hardcodedBodyInBook 处');
  // 章节标题要**跟随**正文（否则正文调大后标题层级反转）
  check('🔴 章节标题字号按正文推导（`_bodyFontSize + `）',
      RegExp(r'fontSize:\s*_bodyFontSize\s*\+').hasMatch(book),
      '写死标题字号 ⇒ 正文调到 24 时标题不突出（层级反转）');
  // 面板要支持隐藏痕迹项
  check('🔴 面板支持 `showTrace`（共享面板给不适用的场景留关闭口）',
      panel.contains('showTrace'), '');

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
    print('🔑 最可能的原因（这几条都**不报错**）：');
    print('   · 字号没钳 ⇒ 0/负数 ⇒ 正文不可见（用户以为文章是空的）');
    print('   · 默认值被改成 18 ⇒ 静默改掉用户已在用的观感');
    print('   · 键名不一致 ⇒ 设置写进去了但读不出来（表现为"不生效"）');
    print('   · 接线断了 ⇒ 功能已写好但用户用不到，且没有任何测试会红');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
