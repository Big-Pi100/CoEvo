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

/// `HeaderChip(` 的**某一次调用**里是否带指定的 `label:`（**限距**，防跨调用误命中）。
///
/// 🔑 为什么不用 `contains("label: '导入'")`：那个字符串**假绿** ——
///    退回纯文字 `Text('导入')` 时它**照样在**。
///    ⇒ 必须锁「**在 `HeaderChip(` 的调用里**」这一形态。
/// ⚠️ 距离上限取 160 字符：够容纳 `label` + `count` + `onTap` 等挨着的参数，
///    又不至于跨到下一个 `HeaderChip(`（本文件的调用都在 10 行内）。
///    📌 判据：**能切片就切片**（这里是「限距切片」——比全文 `contains` 强、
///       比「解析 AST」便宜）。
bool _chipForLabel(String src, String label) => RegExp(
      "HeaderChip\\([\\s\\S]{0,160}?label: '" + label + "'",
    ).hasMatch(src);

/// 取 `from` 与 `to` 之间的片段（`from` 找不到 ⇒ 空串；`to` 找不到 ⇒ 切到文件尾）。
///
/// 🔴 **切片必须自带前提断言**（本文件里每个调用点都跟着一条 `切片有效` 检查）：
///    截不到时会退化成「切到文件尾」，而下游的 `contains` 断言可能因此**假绿**
///    —— 它检查的是「文件里某处有 X」，不是「这个函数里有 X」。
///    📌 同族实测：`verify_forgot_password` 曾用一个**被删掉的函数名**当 end marker，
///       `between` 静默退化成「切到文件尾」⇒ 断言失去意义。
String _between(String src, String from, String to) {
  final i = src.indexOf(from);
  if (i < 0) return '';
  final j = src.indexOf(to, i + from.length);
  return j < 0 ? src.substring(i) : src.substring(i, j);
}

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
    '标题集合 == {今日精选, 书架}',
    titles.length == 2 && titles.containsAll(const ['今日精选', '书架']),
    '$titles',
  );

  // 🔴 白哥定 2 字 —— 防回退到「我的书架」
  //
  // ⚠️ 2026-10-07：「书库」→「书架」（**合规称谓**：`书库` 读作「内容集合」，
  //    `书架` 指向「用户自己的东西」）。改称谓时**两处要分开看**：
  //      · **本条锁「长度」** ⇒ 对新称谓**同样成立**（`书架` 也是 2 字）⇒ **不必改**
  //      · **上一条锁「字面量」** ⇒ **必须同步改**，否则本脚本会红
  //    📌 这正是「断言锁语义形状、而不是锁拼写」的边界：
  //       能锁形状的（长度）就别锁拼写；**必须锁拼写的**（标题内容），
  //       就要接受「改名要连着改断言」这个代价（它换来的是「改名不会被漏掉」）。
  check('书架标题恰好 2 字', ReadingSection.books.title.length == 2,
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

    // 🔴 **语义式**（2026-10-10 换代：原写法锁「计数 == 2」）
    //
    //    原意图是「两段动作**都是** `HeaderChip` 药丸（同一行、同一形态）」，
    //    用「计数 == 2」当**代理**。问题是 —— **动作多一个就假红**：
    //    2026-10-10 书架加了第三枚「未上云」药丸（上云失败的重试入口，
    //    见 `docs/review/cloud-sync-ios-first-install-audit-2026-10-10.md`），
    //    它同样是 `HeaderChip`、同样合格，却把这条判据打红。
    //    📌 判据：**别锁「条数」这类易变维度**（本项目反复记过）——
    //    要锁**语义**：「**每个动作都用同一个组件**」，而不是「恰好有几个」。
    //    🔑 改法两半：
    //      ① **逐动作**锁「`HeaderChip(` 调用里带该 label」（退化成纯文字就断）
    //      ② 一条**反向**断言：文件里**不得自写药丸实现**（反向断言天然免疫数量腐坏）
    // 🔴 2026-10-22：第三枚改成「未同步」（白哥：用户视角是同步，不是上云）。
    for (final label in ['收藏', '导入', '未同步']) {
      check("🔴 「$label」动作用公共组件 HeaderChip（调用里带该 label）",
          _chipForLabel(container, label),
          "未见 HeaderChip(… label: '$label') —— 退回纯文字或自写药丸都会断");
    }
    final chipCalls = RegExp(r'HeaderChip\(').allMatches(container).length;
    check('🔴 且**没有自写的药丸实现**（一律走 HeaderChip —— 一处定义）',
        !RegExp(r'class _\w*Chip\b').hasMatch(container) &&
            !RegExp(r'class _\w*Pill\b').hasMatch(container),
        '实得 HeaderChip $chipCalls 处');
    // 锁「导入」那处的**特有形态**
    //
    // 🔴 **2026-10-05 白哥定改版**：**去掉加号、去掉忙碌态**。
    //    原断言守的是「有 `Icons.add`」+「`labelReserve: '导入中'` + `enabled: !_importing`」——
    //    那是**上一版的有意设计**，本条**随新意图更新**（不是放松）：
    check('🔴 导入药丸**不带图标**（与「收藏」的差异只在「有无数字」）',
        !container.contains('Icons.add'),
        '仍见到 Icons.add —— 白哥定：加号与「收藏」并排不协调');
    check('🔴 导入药丸**不传 labelReserve**（防内边距不对称回归）',
        !container.contains("labelReserve: '导入中'"),
        "仍见到 labelReserve: '导入中' —— 它会让左右内边距不对称（左 8 / 右 27）");
    // 🔑 逆否：没有 `reserve` ⇒ 内边距对称（与「收藏」同一套版式）
    check('  ↳ 且**确实**没有 reserve（内边距对称的前提）',
        !container.contains('labelReserve:'));

    // 🔴 防重入**移进流程内部**（容器退化为纯触发器 ⇒ 无忙碌态）
    final flow = _stripComments(
        _read('../../app/lib/services/ebook/book_import_flow.dart') ?? '');
    check('🔴 防重入在 `runBookImportFlow` 内部（`_busy` 守卫）',
        flow.contains('if (_busy)') && flow.contains('_busy = true'),
        '未见到 _busy 守卫 —— 没有它就会连开两个文件选择器');
    check('  ↳ 流程**不再**接受 `onBusy` 参数（无忙碌态）',
        !flow.contains('onBusy'));
    check('  ↳ 容器**不再**持有 `_importing` 状态',
        !container.contains('_importing'),
        '仍见到 _importing —— 白哥定：不要忙碌态');
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
  // ══════════════════════════════════════════════════════════════════════
  // 🆕 2026-10-05：**划词查词「一处定义」**（书库与信息流共用）
  //
  // 背景：书库原来**有意没做**划词（注释写着「不用 SelectionArea 是有意的」），
  // 白哥真机反馈「书库中的书籍划词不成功」⇒ 把查词逻辑与划词手势各抽一份出来，
  // 两页共用。本组守的就是「**别再退化成两份**」。
  // ══════════════════════════════════════════════════════════════════════
  {
    final widget =
        _stripComments(_read('../../app/lib/widgets/word_lookup_selection.dart') ?? '');
    final reader =
        _stripComments(_read('../../app/lib/screens/reader_screen.dart') ?? '');
    final bookReader = _stripComments(
        _read('../../app/lib/screens/book_reader_screen.dart') ?? '');

    check('划词组件存在', widget.isNotEmpty);
    check('🔴 信息流页用 `WordLookupSelection`', reader.contains('WordLookupSelection('));
    check('🔴 书库阅读页用 `WordLookupSelection`（**划词已接入**）',
        bookReader.contains('WordLookupSelection('));

    // 「一处定义」—— 用**计数**而不是「A 里有 X」（后者锁不到「多出一份」）
    check('🔴 `SelectionArea(` 只在公共组件里出现（两页不许自带一份）',
        widget.contains('SelectionArea(') &&
            !reader.contains('SelectionArea(') &&
            !bookReader.contains('SelectionArea('));

    // 🆕 2026-10-07 v2：**防抖整条链已删除** —— 「选择完成」的信号改由框架给
    //    （`contextMenuBuilder` 在长按结束 / 拖手柄松手时被 `_showToolbar()` 调用）。
    //
    // 🔴 这一组**替换**了原先那条「防抖时长只有一处定义（`kLookupDebounce`）」。
    //    那条锁的是一个**当时就已撤销的设计**（防抖）——
    //    留着它，实现一改对就**反而变红**，正是本项目记过的
    //    「**断言会保护错误**／假红会训练人忽略红灯」那一类。
    //    📌 判据：**断言跟「意图」走、不跟「旧实现」走**（改读取对象时，
    //       断言名与判据一个字都不该动）。
    check('🔴 划词已不再有防抖（`kLookupDebounce` / `Timer` 都不在组件里）',
        !widget.contains('kLookupDebounce') && !widget.contains('Timer('));

    // 菜单由 `contextMenuBuilder` 承载（不再是 `SizedBox.shrink()` 屏蔽系统菜单）
    check('🔴 划词菜单由 `contextMenuBuilder` 返回（不再屏蔽系统菜单）',
        widget.contains('contextMenuBuilder:') &&
            widget.contains('SelectionMenu('));

    // 判定只有一处权威：纯 Dart 的 `classifyPicked`
    // （它住 `services/picked_text.dart` ⇒ 本机可跑 `verify_picked_classify.dart`）
    check('🔴 选中形态判定用 `classifyPicked`（纯 Dart · 可本机独立验证）',
        widget.contains('classifyPicked('));

    // 复制走框架的 `copySelection` —— **不自己写剪贴板**（避免第二份实现）
    check('🔴 复制用框架的 `copySelection`，不自己写 `Clipboard`',
        widget.contains('copySelection(') && !widget.contains('Clipboard'));

    // 🔴 书库**显式**传 null（有意不记痕迹）—— 删掉这个实参就退化成「未提供」
    check('🔴 书库页**显式**传 `articleId: null`（有意不记痕迹，不是漏传）',
        bookReader.contains('articleId: null'));
    // 信息流页则**必须**传非空（痕迹的命根子）
    check('🔴 信息流页传 `articleId: widget.articleId`（非空）',
        reader.contains('articleId: widget.articleId'));

    // 查词逻辑也只有一份：`lookupWord(` 应恰好出现 **2** 次
    // （1 定义在 `word_lookup.dart` + 1 调用在公共组件里）
    final lw = _countInAppLib('lookupWord(');
    check('🔴 查词入口 `lookupWord(` 全项目恰好 2 处（1 定义 + 1 调用）', lw == 2,
        '实际 $lw 次 —— 多了就是「第二份实现」冒出来了');
  }

  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-09】订阅到期满 30 天 ⇒ 云端备份清理（白哥定）+ 「云端有没有」的口径统一
  //
  // 背景：白哥「云端备份应该在订阅到期后一个月后清除释放」。
  // 后端新增 `maintenance::purge_expired_blobs`；端侧**必须同时**把
  // 「云端有没有这本书」的判据从「`cloud_book` 有行」改成 **`blob_size > 0`**。
  //
  // # 🔴 为什么端侧那两处必须一起改（只改一处 = 静默失败，不报错）
  // · `presenceByHash` 不改 ⇒ 书架仍显示「云端有」⇒ 点下载 → `404 这本书在云端没有文件`
  // · `pendingUploadHashes` 不改 ⇒ 云端被清后，本地书**永远不再重新上传**
  //   ⇒ 用户重新订阅了，备份也再也回不来
  //
  // # 🔴 后端那条顺序约束（写反 = 文件永久残留，而配额看着是空的）
  // 必须**先删文件、再归零**：反过来的话中途失败会留下
  // 「blob_size = 0 + 文件还在」，而筛选条件 `blob_size > 0` **永远不再命中它**。
  //
  // # 🔴 归零还必须**推进 `received_at`**（= pull 的时间轴）
  // 这是本功能第一版**真实踩过的缺陷** —— 当时自写裸 `UPDATE ... SET blob_size = 0`，
  // 不碰 `received_at` ⇒ **其他设备永远不知道备份已被释放**（书架显示「云端」、
  // 点下载 404），且不报错、不掉断言。现在归零一律走
  // `book_blob_handler::zero_blob_sizes_for_user`（与 `set_blob_size` 同一条约束）。
  //
  // # 证伪方式
  // · 把 `presenceByHash` 的 `where: 'blob_size > 0'` 删掉 ⇒ ① 组必红
  // · 把 `pendingUploadHashes` 的 `AND c.blob_size > 0` 删掉 ⇒ ② 组必红
  // · 在后端把 `purge_user` 与 `zero_blob_sizes_for_user` **对调** ⇒ ③ 组必红
  // · 在后端把归零换回自写裸 UPDATE ⇒ 「走权威函数」与「不得自写」两条必红
  // · 在后端给那条 UPDATE 加上 `deleted = 1` ⇒ ④ 组必红（端侧会删用户的书）
  // ══════════════════════════════════════════════════════════════════════
  {
    // ── ① 端侧：书架「云端有」的判据 ──
    final cloudRepo = _stripComments(
        _read('../../app/lib/services/ebook/cloud_book_repository.dart') ?? '');
    check('端侧 cloud_book_repository 存在', cloudRepo.isNotEmpty);

    // 切片：确认「云端清单」那段查询确实带了 blob_size 过滤
    final presenceFn = _between(cloudRepo, 'presenceByHash(', 'pendingUploadHashes(');
    check('切片有效（`presenceByHash` 与 `pendingUploadHashes` 都找得到）',
        presenceFn.isNotEmpty, '切片长 ${presenceFn.length}');
    check('🔴 书架「云端有」按 `blob_size > 0` 判（不是「有行就算有」）',
        presenceFn.contains('blob_size > 0'),
        '否则云端文件被清后仍显示「云端有」⇒ 点下载 404（静默失败）');

    // ── ② 端侧：待上传的判据（同一口径，必须同源）──
    //
    // ⚠️ 起点用**完整签名**（`static Future<List<String>> pendingUploadHashes(`），
    //    终点用**代码行** `}`（该方法是文件最后一个成员）。
    //    🔴 这里踩过一次：初版终点用了 `/// 该用户云端占用的字节数`（**文档注释**），
    //       而 [_stripComments] 会把 `///` **整行删掉** ⇒ 终点找不到 ⇒ 退化成
    //       「切到文件尾」。那次没红是因为文件尾恰好**没有**别处出现 `c.blob_size > 0`；
    //       换一次文件布局就变假绿。
    //    📌 判据：**任何以文本为基准的定位（切片锚点 / 行号）都必须落在「剥注释后仍存在」的行上。**
    final pendingFn = _between(
        cloudRepo, 'static Future<List<String>> pendingUploadHashes(', '}');
    check('切片有效（截到了 `pendingUploadHashes` 函数体）',
        pendingFn.isNotEmpty, '切片长 ${pendingFn.length}');
    check('🔴 待上传判据也用 `blob_size > 0`（与书架同一口径）',
        pendingFn.contains('c.blob_size > 0'),
        '否则云端被清后本地书永远不再重传 ⇒ 重新订阅也回不来');
    check('切片未越界（没切到文件尾）', pendingFn.contains('FROM book b'),
        '若没有 `FROM book b`，说明锚点失效、切片跑偏了');

    // ── ③ 后端：清理函数的**语句顺序**（先删文件、后归零）──
    final maintRaw = _read('../../backend/crates/api_server/src/maintenance.rs');
    check('后端 maintenance.rs 存在', maintRaw != null);
    final maint = _stripComments(maintRaw ?? '');
    // ⚠️ 终点同样必须是**代码行**（`fn run_scheduler_inner(`）——
    //    文档注释会被剥掉，拿它当锚点就会静默退化成「切到文件尾」。
    final purgeFn = _between(maint, 'pub fn purge_expired_blobs(', '\nfn run_scheduler_inner(');
    check('切片有效（截到了 `purge_expired_blobs` 函数体）',
        purgeFn.isNotEmpty, '切片长 ${purgeFn.length}');
    check('切片未越界（没切到测试代码）', !purgeFn.contains('mod tests'),
        '越界了 ⇒ 下面的「不得出现 X」会被测试代码命中而假绿/假红');

    final iDelete = purgeFn.indexOf('purge_user(');
    final iZero = purgeFn.indexOf('zero_blob_sizes_for_user(');
    check('🔴 先删文件、再归零（顺序反了会导致文件永久残留）',
        iDelete >= 0 && iZero >= 0 && iDelete < iZero,
        '删文件 @$iDelete · 归零 @$iZero —— 归零在前 ⇒ 中途失败就再也不会被选中');

    // 🔴 归零**必须走权威函数**：`book_blob_handler::zero_blob_sizes_for_user`
    //    会一并推进 `received_at`（= **pull 的时间轴**）。
    //
    // ⚠️ 这条是 2026-10-09 补的 —— 当时 `purge_expired_blobs` **第一版自写了一条
    //    裸 `UPDATE ... SET blob_size = 0`**，不带 `received_at`，后果**完全静默**：
    //    用户的**其他设备**永远拉不到这次归零（pull 按 `received_at > since` 增量）
    //    ⇒ 书架仍显示「云端有」⇒ 点下载 **404**。只有换设备才看得见。
    check('🔴 归零走权威函数 `zero_blob_sizes_for_user`（口径只有一处）',
        purgeFn.contains('book_blob_handler::zero_blob_sizes_for_user'),
        '自写裸 UPDATE ⇒ 不推进 received_at ⇒ 其他设备书架仍显示「云端」、点下载 404');
    check('🔴 函数体内**不得**自写 `SET blob_size`（那会绕过 received_at 约束）',
        !purgeFn.contains('SET blob_size'),
        '写 blob_size 的 SQL 只允许出现在 book_blob_handler（set_blob_size / zero_blob_sizes_for_user）');

    // ── ④ 后端：**绝不能**动 `deleted` ──
    //
    // 🔴 `deleted = 1` 在端侧被读成「别端删了书」⇒ `mergeCloudBooks` 会
    //    **把用户本地的书删掉**。清理云端备份**不是**删用户的书。
    //
    // ⚠️ 本断言第一版写的是 `!purgeFn.contains('deleted')` —— **假红**：
    //    筛选 SQL 里的 `deleted_at IS NULL` 含子串 `deleted`（那是「软删账号」的列，
    //    与此无关）。于是**正确代码**被判违规。
    //    📌 又是「**子串断言要考虑被撞的车牌**」（同族：`token`/`tokens`、
    //       `title:`/`subtitle:`）。⇒ 改成精确到**赋值形态**。
    check('🔴 清理时不得改 `sync_book.deleted`（否则端侧会删用户本地的书）',
        !purgeFn.contains('SET deleted') &&
            !purgeFn.contains('deleted = 1') &&
            !purgeFn.contains('deleted=1'),
        '`deleted` 在端侧被读成「别端删了书」⇒ 会删掉用户本地的书');
    check('🔴 也不得删 `sync_book` 行（端侧还要靠它认书）',
        !purgeFn.contains('DELETE FROM sync_book'));

    // ── ⑤ 后端：保留期常量存在且为 30 天（白哥说「一个月」）──
    check('🔴 保留期常量 = 30 天（白哥定「到期后一个月」）',
        maint.contains('BLOB_RETENTION_DAYS_AFTER_EXPIRY: i64 = 30'));

    // ── ⑥ 后端：任务已接进调度器（防「写了没人跑」）──
    //
    // 🔴 本断言第一版写的是 `maint.contains('purge_expired_blobs(&conn')` ——
    //    **证伪时没变红**：那个字符串在**同文件的单元测试里还有 7 处调用**
    //    ⇒ 把调度器里那唯一一处删掉/改名，断言照样通过（**假绿**）。
    //    📌 又是判据「**子串断言锁不到「接线」**」：`contains` 只证明「文件某处有」，
    //       证明不了「**在这个函数里有**」。
    //    ✅ 改法：切出 `run_scheduler_inner` 的函数体，在**切片内**断言。
    final schedFn = _between(maint, 'fn run_scheduler_inner(', 'fn start_scheduler');
    check('切片有效（截到了 `run_scheduler_inner` 函数体）',
        schedFn.isNotEmpty, '切片长 ${schedFn.length}');
    check('切片未越界（没切到测试代码）', !schedFn.contains('mod tests'));
    check('🔴 清理任务已接进 `run_scheduler_inner`（防「写了没人跑」）',
        schedFn.contains('purge_expired_blobs('),
        '只在测试里调用不算接线 —— 必须真在每 5 分钟跑的那个函数里');
  }

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
