// 「阅读」tab 的双段结构 + 群入口「一处定义」—— 验收（纯 Dart · 可进 CI）
//
// 跑：cd scripts/ebook_verify && dart run bin/verify_reading_tab.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail` —— 本项目已踩过）。
//
// # 这批断言守的是什么
//
// 2026-10-04 白哥定案：书库从「信息流页下方的一条入口」改为**与「今日精选」平级的标题**；
// 同时把「群二维码弹层」抽成公共组件（书库空态 + 导入失败要用它）。这两件事里有
// **四类错编译器全都抓不到**：
//
// | # | 会静默走偏的事 | 靠什么守 |
// |---|---|---|
// | ① | 标题被改回「我的书库」（4 字 23px 与「今日精选」并排，右侧没落脚处）| ① 组 |
// | ② | 有人又给书库视图加回**返回键** / 自带骨架（页内切换不需要它）| ② 组 |
// | ③ | 群二维码弹层**又长出一份**（换图/改标题时只改一处）| ③ 组（**计数式**）|
// | ④ | 引导文案把群说成「资源群」（**群规明令禁传电子书**）| ④ 组 |
//
// ⚠️ 本机 `flutter analyze` 不可用（鸿蒙定制 SDK · `CreateFile failed 231`）⇒
//    **UI 的渲染本机验不了**。但「结构与文案」是**文本事实** ⇒ 可以在这里守。
//    渲染 / lint 仍以 CI 的 `frontend` job 为准。
//
// # 🔑 两条防假绿的写法（本文件刻意如此）
//
// 1. **「不再有 X」类断言，必须在「剥掉注释」的文本上做** ——
//    注释里写「本文件不再有 `Scaffold`」是正确的留档，若直接在原文上断言就会**假红**。
// 2. **「一处定义」用计数（`_countInAppLib`），不用包含** ——
//    「about 页里有 `GroupQrcodeDialog.show`」这种**包含式**断言，
//    在两份实现并存时**照样通过**（新的那份也在）⇒ 假绿。
//    只有「全项目只出现一次」才真正锁住它。

import 'dart:io';

import '../../../app/lib/screens/reading_section.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail == null ? name : '$name —— $detail');
  }
}

/// `app/lib` —— 脚本的 cwd 是 `scripts/ebook_verify`（CI 与本地一致）。
///
/// 🔴 必须**先断言它存在**：否则路径写错时会「扫了 0 个文件」然后**全绿**
///    （判据：报「0 处」时必须说清**扫了哪些文件**）。
final Directory _appLib = Directory('../../app/lib');

String? _read(String relPath) {
  final f = File(relPath);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// 剥掉**整行注释**（注释前可有空白）。
///
/// # 🔴 为什么是「整行」而不是「行内切 `//`」（证伪时踩到的真坑）
///
/// 第一版写的是「每行找 `//`、切掉后半」—— 跑证伪时发现它**放过了真的第二份实现**：
/// ```
/// final _dup = 'https://x/api/public/qrcode';     // ← 代码，真实回归的形态
/// ```
/// 这行里的 `https://` 含 `//` ⇒ 被当成注释起点切掉 ⇒ 计数仍是 1 ⇒ **假绿**。
///
/// 📌 判据：**「剥注释」这个动作本身会改变被检查的文本** ——
///    它修好了「注释里的说明造成假红」，同时引入了「URL / 字符串里的 `//` 造成假绿」。
///    ⇒ 剥注释**必须只在「整个注释行」这一粒度上做**，不能对整行无脑切 `//`
///      （要正确处理行内注释就得写字符串字面量扫描器，成本远大于收益）。
///
/// ⚠️ 代价（如实记录）：**行尾注释不会被剥** —— 若有人把被禁的写法写进行尾注释，
///    本脚本会误报。已知盲区，不假装没有。
String _stripComments(String src) =>
    src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// 统计 `app/lib` 下所有 `.dart` 里 `needle` 的总出现次数（**剥掉整行注释后**）。
///
/// 🔴 剥注释的理由（第一次跑就被咬到）：实测裸 URL 出现 **4 次**，其中 3 次在注释里
///    ——而注释里写「由后端 `/api/public/qrcode` 托管」是**正确的留档**。
///    ⇒ 不剥，这条断言在**只有一份实现**时也会红 ⇒ 「假红训练人忽略红灯」。
///
/// ⚠️ 但剥法本身有讲究，见 [_stripComments] 的头注释
///    （行内切 `//` 会放过 `https://…` 形态的真回归 —— 证伪实测踩到）。
///    ⇒ 两个措施并用：**只剥整行注释** + **needle 取完整调用表达式**。
int _countInAppLib(String needle) {
  var n = 0;
  for (final e in _appLib.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    n += needle.allMatches(_stripComments(e.readAsStringSync())).length;
  }
  return n;
}

void main() {
  // ══════════════════════════════════════════════════════════════════════
  // ① 「阅读」tab 的两段定义（纯逻辑 · 零依赖）
  // ══════════════════════════════════════════════════════════════════════
  const sections = ReadingSection.values;

  check('恰好两段', sections.length == 2, '${sections.length}');

  // 🔴 **集合相等**（不是「包含」）：多一段、少一段、改名都要红
  final titles = sections.map((s) => s.title).toSet();
  check(
    '标题集合 == {今日精选, 书库}',
    titles.length == 2 && titles.containsAll(const ['今日精选', '书库']),
    '$titles',
  );

  // 🔴 白哥定「书库」二字 —— 防回退到「我的书库」
  check('书库标题恰好 2 字', ReadingSection.books.title.length == 2,
      '「${ReadingSection.books.title}」共 ${ReadingSection.books.title.length} 字');
  check('信息流标题沿用「今日精选」', ReadingSection.feed.title == '今日精选',
      ReadingSection.feed.title);

  // 🔑 `IndexedStack` 靠 `stackIndex` 选孩子 —— 必须与枚举声明顺序一一对应
  check(
    'stackIndex 与声明顺序一致（0,1）',
    sections.map((s) => s.stackIndex).join(',') == '0,1',
    sections.map((s) => '${s.name}:${s.stackIndex}').join(' '),
  );
  check('feed.stackIndex == 0', ReadingSection.feed.stackIndex == 0);
  check('books.stackIndex == 1', ReadingSection.books.stackIndex == 1);

  check('other 互换（feed→books）',
      ReadingSection.feed.other == ReadingSection.books);
  check('other 互换（books→feed）',
      ReadingSection.books.other == ReadingSection.feed);
  check('other 是自反逆（两次回到自身）',
      ReadingSection.books.other.other == ReadingSection.books);
  check('默认段是 feed（values.first）',
      ReadingSection.values.first == ReadingSection.feed);

  // ══════════════════════════════════════════════════════════════════════
  // ② 结构：容器存在的证据 + 若干「不再有」
  // ══════════════════════════════════════════════════════════════════════
  final libDirOk = _appLib.existsSync();
  check('app/lib 目录存在（否则下面全是假绿）', libDirOk, _appLib.path);

  final containerRaw = _read('../../app/lib/screens/reading_tab_screen.dart');
  check('容器文件存在', containerRaw != null);
  final container = _stripComments(containerRaw ?? '');
  if (containerRaw != null) {
    // 🔑 用 IndexedStack（两段都留在树上）而非 if 切换 —— 否则滚动位置 / 分页会丢
    check('容器用 IndexedStack（两段同时保活）', container.contains('IndexedStack'));
    check(
      '容器装了两段内容',
      container.contains('HomeScreen()') &&
          // 🔴 不能只断言 `BookLibraryScreen(onImport:` —— 证伪实测：
          //    把它换成 `BookLibraryScreen(onImport: () {})`（**接线断掉**）
          //    那种松断言**照样通过**（子串没变）⇒ 假绿。
          //    ⇒ 断言必须锁到「接的是**容器的方法**」这一层（`_import`）。
          //    ⚠️ 代价：`_import` 改名时本行要同步改 —— 这是有意接受的
          //       （换成更松的写法就守不住「接线断了」这个真回归）。
          container.contains('BookLibraryScreen(onImport: _import'),
      '未见到两段内容 / 导入接线',
    );
    // 标题必须取自 reading_section（在容器里写死字面量就守不住了）
    check(
      '容器标题取自 reading_section（不写死字面量）',
      container.contains('s.title') &&
          container.contains('ReadingSection.values'),
      '未见到 s.title / ReadingSection.values',
    );
    check('容器有 3px 下划线（选中态）', container.contains('_underlineHeight'));
    check('导入口在容器（状态所有者）里', container.contains('runBookImportFlow('));

    // ── 🆕 2026-10-05（白哥真机反馈 · `library-ui-unification`）──
    //
    // 白哥：「收藏按钮应该更靠右，其他页面的 title 按钮都是靠右的」。
    // 🔴 **反向断言**：标题行**不得**再用 `Flexible` —— 它只给「**内容宽**」，
    //    剩余空间没人占 ⇒ 右侧动作不贴屏幕右缘。
    //    （`review_screen` 用 `Expanded(Text)`、`bookmark_list_screen` 用 `spaceBetween`，
    //     两页本来就是对的 ⇒ 用 `Flexible` 的那页是**离群值**。）
    // ⚠️ 必须**剥注释**后再查：本次改动的说明文字里会出现 `Flexible(fit: FlexFit.tight)`
    //    这个词（用来解释 `Expanded` 是什么）⇒ 不剥就是**假红**。
    check('🔴 标题行不再用 Flexible（否则右侧动作不贴右）', !container.contains('Flexible('),
        '出现了 Flexible(');
    check('标题行用 Expanded 占满剩余宽度（右侧动作才能贴右）', container.contains('Expanded('));

    // 🔴 **计数式**：两段动作**都是 `HeaderChip` 药丸**（同一行、同一形态）。
    //    ⚠️ 用「包含」会**假绿** —— 「导入退回纯文字、只剩收藏一个」时照样通过。
    //    📌 判据：一处定义 / 数量约束 ⇒ 用**计数**，不用 `contains`。
    final chipCalls = RegExp(r'HeaderChip\(').allMatches(container).length;
    check('🔴 两段动作都用 HeaderChip（计数 = 2：收藏 + 导入）', chipCalls == 2,
        '实得 $chipCalls 处');
    // 锁「导入」那处的**特有形态**（＋ 图标，与「收藏」的书签图标区分）
    check('导入药丸用 ＋ 图标（与收藏的书签图标区分）', container.contains('Icons.add'));
    // 🔴 「导入中」也仍是**同一颗药丸**（形状不变 ⇒ 标题栏不跳），且有 `labelReserve` 定宽
    check(
        '🔴 「导入中」仍是药丸 + labelReserve 定宽（防切换时标题栏跳动）',
        container.contains("labelReserve: '导入中'") &&
            container.contains('enabled: !_importing'),
        '未见到 labelReserve / enabled 的配套用法');
  }

  // 🔴 书库视图**不该**再有返回键与自带骨架（那是容器的职责）
  final libraryRaw = _read('../../app/lib/screens/book_library_screen.dart');
  check('书库视图文件存在', libraryRaw != null);
  final library = _stripComments(libraryRaw ?? '');
  if (libraryRaw != null) {
    check('🔴 书库视图没有返回键（白哥定：页内切换不需要）', !library.contains('arrow_back_ios'),
        '出现了 arrow_back_ios');
    check('书库视图没有自带 Scaffold（骨架归容器）', !library.contains('Scaffold('),
        '出现了 Scaffold(');
    check('书库视图没有自带 SafeArea（同上）', !library.contains('SafeArea('));
    // 导入必须是**注入的回调**（容器传），不是自己选文件
    check('书库视图通过 widget.onImport 触发导入',
        library.contains('widget.onImport') && !library.contains('openFile('));
    // 空态里的进群出口（白哥定的形态③）
    check('书库空态挂了进群出口', library.contains('GroupQrcodeDialog.show(context)'));

    // ── 🆕 2026-10-05：清单改用**粘土卡**（白哥定：「书库的目录清单也要统一设计语言」）──
    //
    // 🔴 依据：项目里已有两种列表语言 ——
    //    · **卡片**（一条内容 = 一张 `Clay`）→ 信息流
    //    · **分组容器**（一组 = 一个 `Clay` + 内部 `Divider`）→ 「我的」页
    //    而书库改前是「**平坦行 + Divider、外面没有容器**」⇒ 两套都不是。
    //    书是**内容**（点进去是读）⇒ 归「卡片」这一套。
    check('🔴 书库清单用 Clay 卡（不再是平坦行）', library.contains('Clay('), '未见到 Clay(');
    // 🔴 **反向**：`Divider` 是「分组容器」语言的特征 ⇒ 卡片语言里不该有它。
    check('🔴 书库清单不再有 Divider（那是「分组容器」语言的特征）', !library.contains('Divider('),
        '出现了 Divider(');
    // 🔴 封面占位必须是**平面**（spec §〇 规则 1「有体积的只可能是**可点**的东西」）——
    //    封面不可点（点的是整张卡片）⇒ 给它凹陷/阴影会**读作「可以按」**，是误导。
    //    ⚠️ 这是**文件级**判据（本文件除封面外没有别的加阴影的地方；
    //       `Clay` 的阴影在 `clay.dart` 内部，不在本文件）—— 如实标注这个口径。
    check('🔴 封面占位是平面（文件内不得出现 BoxShadow ⇒ 不可点的不该有体积）',
        !library.contains('BoxShadow'));
  }

  // 🔑 间距必须与信息流**一致** —— 「同一套卡片语言」不只是卡片长得一样，
  //    **间距也是它的一部分**：只改卡片不改间距，切换时仍会有疏密突变。
  //    📌 跨文件一致性断言（两处都必须 = 13）。
  final homeForGap =
      _stripComments(_read('../../app/lib/screens/home_screen.dart') ?? '');
  check(
      '🔴 书库卡片间距与信息流一致（两处都是 13）',
      library.contains('SizedBox(height: 13)') &&
          homeForGap.contains('SizedBox(height: 13)'),
      '书库=${library.contains('SizedBox(height: 13)')} 信息流=${homeForGap.contains('SizedBox(height: 13)')}');

  // 🔴 信息流视图交出标题栏（标题栏只有一处定义）
  final home =
      _stripComments(_read('../../app/lib/screens/home_screen.dart') ?? '');
  check('🔴 信息流视图不再画「收藏 N」药丸', !home.contains('HeaderChip('));
  check('🔴 信息流视图不再挂旧的书库入口条', !home.contains('BookLibraryEntry(),'));

  // 🔴 旧入口组件已删除（入口已被标题级双 Tab 取代）
  check('widgets/book_library_entry.dart 已删除',
      !File('../../app/lib/widgets/book_library_entry.dart').existsSync());

  // 路由：/home 走容器；/books 顶层路由已删、阅读器仍在
  final app = _stripComments(_read('../../app/lib/app.dart') ?? '');
  check('🔴 /home 的 builder 是 ReadingTabScreen',
      app.contains('const ReadingTabScreen()'));
  // ⚠️ 精确匹配带引号与逗号：`path: '/books/:id',` 也含 `path: '/books` 前缀，
  //    不带逗号就会误判为「还在」（切片必须验边界）。
  check('🔴 /books 顶层路由已删除（书库不再是可 push 的页）', !app.contains("path: '/books',"),
      "仍存在 path: '/books',");
  check('✅ 阅读器 /books/:id 仍是顶层路由', app.contains("path: '/books/:id',"));
  check('app.dart 不再 import 书库页（改由容器承载）',
      !app.contains("import 'screens/book_library_screen.dart';"));

  // ══════════════════════════════════════════════════════════════════════
  // ③ 群二维码：**一处定义**（计数式断言）
  // ══════════════════════════════════════════════════════════════════════
  final qrRaw = _read('../../app/lib/widgets/group_qrcode_dialog.dart');
  check('公共弹层文件存在', qrRaw != null);
  final qr = _stripComments(qrRaw ?? '');
  if (qrRaw != null) {
    check('弹层对外暴露 show()', qr.contains('static Future<void> show('));
    check('弹层标题是常量（供入口复用，杜绝两处文案漂移）', qr.contains('static const String kTitle'));
    check('弹层有失败兜底（errorBuilder）', qr.contains('errorBuilder'));
  }

  // 🔴🔴 **计数式**：「二维码的**调用表达式**」在整个 app/lib 里**只允许出现一次**。
  //
  //  ⚠️ needle 取**完整调用**（不是裸 URL）：注释里会出现裸 URL 作为说明
  //     （如「由后端 `/api/public/qrcode` 托管」），拿裸 URL 去数会**假红**；
  //     而真实回归的形态是**复制那段 `NetworkImage(...)`** ⇒ 用完整表达式才抓得到。
  //     🔑 用 raw string：`$` 不插值，字面匹配 `${ApiConfig.baseUrl}`。
  const qrCall = r"NetworkImage('${ApiConfig.baseUrl}/api/public/qrcode')";
  final urlCount = libDirOk ? _countInAppLib(qrCall) : -1;
  check('🔴 二维码调用在 app/lib 全局只出现 1 次（一处定义）', urlCount == 1,
      '实际 $urlCount 次 —— 出现第二处即「两份实现」');

  // 使用方都走公共组件
  final about =
      _stripComments(_read('../../app/lib/screens/about_screen.dart') ?? '');
  check('「关于」页改用公共弹层', about.contains('GroupQrcodeDialog.show(context)'));
  check('「关于」页不再自带二维码地址', !about.contains('/api/public/qrcode'));
  // 🔑 入口文案也要取自常量 —— 否则「入口名」与「弹窗标题」两处文案会各自漂
  check('「关于」页入口文案取自 kTitle', about.contains('GroupQrcodeDialog.kTitle'));

  final flowRaw = _read('../../app/lib/services/ebook/book_import_flow.dart');
  check('导入流程文件存在', flowRaw != null);
  final flow = _stripComments(flowRaw ?? '');
  if (flowRaw != null) {
    check('导出唯一入口 runBookImportFlow',
        flow.contains('Future<void> runBookImportFlow('));
    check(
      '导入失败弹层里 DRM 有「加入共读群」出口',
      flow.contains('EbookParseErrorKind.drmProtected') &&
          flow.contains('GroupQrcodeDialog.show(context)'),
    );
    // 🔑 时序坑：必须「用返回值 → 再弹」，不能在 builder 里嵌套弹一个
    check(
      '失败弹层用「返回值 → 再弹」而非嵌套弹层',
      flow.contains('await CoDialog.show<bool>(') &&
          flow.contains('context.mounted'),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // ④ 文案约束：**不能把群写成「资源群」**（群规明令禁传电子书）
  // ══════════════════════════════════════════════════════════════════════
  const banned = ['领书', '免费下载', '拿资源', '资源群', '领取电子书'];
  for (final w in banned) {
    check('弹层文案不含「$w」', !qr.contains(w));
    check('书库引导文案不含「$w」', !library.contains(w));
  }
  // 正向：引导须落在「一起找 / 共读」这一侧
  check('书库引导文案落在「一起找 / 共读」这一侧',
      library.contains('一起找') || library.contains('共读群'));

  // ══════════════════════════════════════════════════════════════════════
  print('');
  print('═══ verify_reading_tab ═══');
  print('pass = $_pass · fail = $_fail');
  if (_failures.isNotEmpty) {
    print('');
    for (final f in _failures) {
      print('  ✗ $f');
    }
  }
  // 🔴 显式设置退出码（Dart 的 `main` 返回值**不是**退出码 ——
  //    `scripts/codestatic` 就踩过：脚本检测到 error 却仍返回 0，门禁完全失效）。
  exitCode = _fail == 0 ? 0 : 1;
}
