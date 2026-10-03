// CoEvo · **信息流 / 阅读页接线验收**
//   ① 信息流从 `/api/feed` 取数（**不再有 mock**）—— 防「退回 mock」
//   ② 三态齐全（加载 / 失败可重试 / 空）—— 防「静默失败 + 无出口」
//   ③ 阅读页从 `/api/feed/{id}` 取正文 + 痕迹来自端侧 `lookup_event`
//   ④ 后端 `/api/feed` 支持 `ids`（收藏清单用）且 `parse_ids` 不能被绕过
//   ⑤ 分类词表**跨语言一致**（后端 `CONTENT_CATEGORIES` ↔ 端侧 `kCategoryLabels`）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_feed_wiring.dart
//
// # 为什么需要它（2026-09-29 的真实背景）
//
// 端侧信息流此前是 `mockFeedItems`（设计稿原文三篇，硬编码在端侧）。
// 本期改为从服务端内容池取数 —— 这类「换数据源」的改动有个典型回归：
// **某个入口忘了换**（本次真实发生：收藏清单也在用 mock 反查卡片，
// 差一点漏掉）。而它**不报错** —— 只是那个页面一直显示旧的三篇。
//
// 🔑 这类问题的形状是「**改了 A 端，B 端还在用旧数据**」——
//    · analyzer 不报（旧代码仍然合法）
//    · 后端测试不报（接口本身是好的）
//    → 只有结构断言能守住。
//
// # 🔴 本脚本的证伪方式（改断言后应跑一遍）
// 把 `home_screen.dart` 的 `ref.watch(feedProvider(''))` 改回
// `ListView.separated(itemCount: mockFeedItems.length, ...)`
// → 本脚本【1】必须变红。

import 'dart:io';

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

/// 剥掉行注释（`//` 开头到行尾）。
///
/// 🔑 **必须剥**：本项目的注释里大量引用类型名与函数名
/// （如「曾经的 `mockFeedItems`」），不剥就会把**说明**当**实现**。
/// ⚠️ 但**不剥** `///` 之外的块注释（本文件不处理 `/* */`）——
///    项目里 Dart 侧 Doxygen 风格是 `///`，够用。
String stripComments(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i >= 0 ? l.substring(0, i) : l;
    })
    .join('\n');

String read(String rel) => File(rel).readAsStringSync();
String readNoComment(String rel) => stripComments(read(rel));

void main() {
  final home = readNoComment('../../app/lib/screens/home_screen.dart');
  final bookmark = readNoComment('../../app/lib/screens/bookmark_list_screen.dart');
  final reader = readNoComment('../../app/lib/screens/reader_screen.dart');
  final feedProvider = readNoComment('../../app/lib/providers/feed_provider.dart');
  final client = readNoComment('../../app/lib/api/content_client.dart');
  final feedItem = readNoComment('../../app/lib/models/feed_item.dart');
  final repo = readNoComment('../../app/lib/services/user_word_repository.dart');
  final handler = readNoComment('../../backend/crates/api_server/src/content_handler.rs');
  final schema = readNoComment('../../backend/crates/api_server/src/schema.rs');
  final profile = readNoComment('../../app/lib/screens/profile_screen.dart');

  // ══════════════════════════════════════════════════════════
  section('【1】信息流：从服务端取数（不再有 mock）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 断言要锁「**取数 + 三态分派**」这个形状，但**不能写死标识符拼写**。
  //
  // 两端都踩过（都是真实事故）：
  //   · **写太松 ⇒ 假绿**（受控实验抓到的）：只匹配裸名 `feedProvider` 时，
  //     那名字在 `error:` 回调里也出现（`ref.invalidate(feedProvider(…))`），
  //     所以「把 watch 换成 mock」这个回归**不会让它变红**。
  //   · **写太死 ⇒ 假红**（2026-10-03 实际发生）：原断言写死
  //     `ref.watch(feedProvider('')).when(`，而实现把硬编码 `''` 提成了常量
  //     `_kFeedCategory` —— 那是**纯重构（语义没变）**，却让断言变红。
  //     ⚠️ 危害不只是「误报」：**一条合理改动就报警的断言，会训练人忽略红灯**
  //        ⇒ 真回归来了也一起被忽略。
  //
  // ✅ 解法：**锁语义形状，不锁拼写** —— 正则允许参数是任意表达式（含常量名）。
  // 📌 判据：断言要**覆盖到形状**，同时**对无关重构免疫**；
  //    两难时优先用**正则匹配结构**，而不是 `contains` 匹配字面量。
  final feedWatch =
      RegExp(r'ref\.watch\(\s*feedProvider\([^)]*\)\s*\)\s*\.when\(');
  check('🔴 信息流是 `ref.watch(feedProvider(…)).when(…)`（形状 · 参数名不限）',
      feedWatch.hasMatch(home));
  check('🔴 信息流**不再**引用 `mockFeedItems`', !home.contains('mockFeedItems'));

  // 🔴 mock 文件必须已删除 —— 留着就是「随时可以被接回去」的死代码
  for (final f in ['mock_feed.dart', 'mock_articles.dart']) {
    check('🔴 `$f` 已删除（零消费者 = 死代码）',
        !File('../../app/lib/data/$f').existsSync());
  }
  check('阅读页**不再**引用 `mockArticleById`', !reader.contains('mockArticleById'));
  check('收藏清单**不再**引用 `mockFeedItems`', !bookmark.contains('mockFeedItems'));

  // ══════════════════════════════════════════════════════════
  section('【2】三态齐全（防「静默失败 + 无出口」）');
  // ══════════════════════════════════════════════════════════
  check('信息流有加载态（`.when(loading:` 或 `AsyncLoading`)',
      home.contains('.when(') && home.contains('loading:'));
  check('信息流有失败态（`error:`）', home.contains('error:'));
  check('🔴 失败态**有重试出口**（`ref.invalidate`）',
      home.contains('invalidate(feedProvider'));
  check('信息流有空态（与服务不可用**分开**）', home.contains('_FeedEmpty'));
  check('🔴 空态与失败态是**两个**组件（不共用一个）',
      home.contains('_FeedError') && home.contains('_FeedEmpty'));

  check('阅读页有加载态', reader.contains('.when(') && reader.contains('loading:'));
  check('🔴 阅读页失败态**区分 404 与非 404**（`isNotFound`）',
      reader.contains('isNotFound'));
  check('🔴 阅读页重试只在**可能好起来**时给（`onRetry` 可为 null）',
      reader.contains('onRetry'));

  // ══════════════════════════════════════════════════════════
  section('【3】阅读页：正文来自接口 + 痕迹来自端侧查词');
  // ══════════════════════════════════════════════════════════
  check('阅读页 watch 了 `articleDetailProvider`',
      reader.contains('articleDetailProvider(widget.articleId)'));
  check('🔴 正文分段走纯函数 `splitParagraphs`（不就地拆字符串）',
      reader.contains('splitParagraphs('));
  check('🔴 正文为空走 `hasReadableBody` 判断（不自己判 length）',
      reader.contains('hasReadableBody('));
  check('🆕 痕迹 watch 了 `articleLookupsProvider`（数据源是 `lookup_event`）',
      reader.contains('articleLookupsProvider('));
  check('🔴 仓储有 `lookupsForArticle`（按文章查，不是全部生词）',
      repo.contains('lookupsForArticle'));
  check('🔴 该查询**按 `article_id` 过滤**（否则每篇显示同一批底色）',
      repo.contains('le.article_id = ?1'));
  check('🔴 该查询用 `LEFT JOIN` + `COALESCE` 兜住「未命中的词」',
      repo.contains('LEFT JOIN card_review_state') && repo.contains('COALESCE(MAX(crs.reps)'));

  // 🔑 痕迹失败**不该**阻断正文 —— 判据写在 provider 的文档里，这里锁代码形状
  check('🔴 痕迹取不到时用空列表兜底（`?? const <ArticleLookup>[]`）',
      reader.contains('lookupsAsync.valueOrNull ?? const <ArticleLookup>[]'));

  // ══════════════════════════════════════════════════════════
  section('【4】收藏清单：内容也来自接口（本次差点漏掉的连带点）');
  // ══════════════════════════════════════════════════════════
  check('收藏清单 watch 了 `feedByIdsProvider`', bookmark.contains('feedByIdsProvider'));
  check('🔴 参数是**排序后** join 的 key（否则同一批 id 会命中不同缓存）',
      bookmark.contains('sort()') && bookmark.contains('join(\',\')'));
  check('🔴 按**收藏顺序**重排（不依赖响应顺序）',
      bookmark.contains('for (final b in bookmarks)'));
  check('收藏清单的失败态**说清「收藏还在」**（不谎报成没有收藏）',
      bookmark.contains('你的收藏还在'));

  // ══════════════════════════════════════════════════════════
  section('【5】客户端：内容接口**不带 token**（产品原则）');
  // ══════════════════════════════════════════════════════════
  check('🔴 `content_client` 不引用 token / Authorization',
      !client.contains('Authorization') && !client.contains('token'));
  check('🔴 列表不返回 `body`（全文按需取，不塞进列表）',
      !handler.contains('"body":') || handler.contains('feed_detail'));
  check('🔴 详情返回 `body`', handler.contains('"body":'));

  // ══════════════════════════════════════════════════════════
  section('【6】后端 `/api/feed` 的 `ids` 支持（收藏清单用）');
  // ══════════════════════════════════════════════════════════
  check('`FeedQuery` 有 `ids` 字段', handler.contains('pub ids: Option<String>'));
  check('有 `feed_by_ids` 实现', handler.contains('fn feed_by_ids('));
  check('🔴 `parse_ids` 解析成整数（**不把字符串拼进 SQL**）',
      handler.contains('fn parse_ids(') && handler.contains('parse::<i64>()'));
  check('🔴 占位符**按解析后的数量生成**（无注入面）',
      handler.contains('vec!["?"; ids.len()].join(",")'));
  check('🔴 单条坏 id **丢弃而不报错**（一条坏 id 不该让整页打不开）',
      handler.contains('if let Ok(v) = part.trim().parse::<i64>()'));
  check('🆕 列表与批量都返回 `word_count`（卡片要显示「N min」）',
      '"word_count"'.allMatches(handler).length >= 2 &&
          handler.contains('p.word_count'));

  // ══════════════════════════════════════════════════════════
  section('【7】模型：字段与后端对齐');
  // ══════════════════════════════════════════════════════════
  check('🔴 `excerpt` 取自后端 `summary`（字段名不同，必须有映射）',
      feedItem.contains("json['summary']"));
  check('🔴 `minutes` 由 `word_count` 换算（不是后端字段）',
      feedItem.contains('minutesFromWordCount') && feedItem.contains('word_count'));
  check('🔴 分类显示映射**只有一处**（`kCategoryLabels`）',
      feedItem.contains('kCategoryLabels') && feedItem.contains('categoryLabel'));
  check('未登记分类有兜底文案（不留空、不漏内部 key）',
      feedItem.contains('_unknownCategory'));
  // 🔴 **反向断言**（2026-10-03 改）：原断言是「`int? score` 存在」（正向）。
  //    但 HN 弃用 ⇒ 后端 `content_pool.score` 列已删 ⇒ 「热帖排序」不复存在
  //    ⇒ 端侧也**必须**同步删掉这两个字段。
  //    留着就是**语义残留** —— 表里没有的列、模型里还留着 ⇒
  //    后来人会以为「这个字段还能用」而把它接回某处（本项目已多次踩这个形状）。
  //    📌 判据：**删功能要连带清理语义残留**，并把断言**翻成反向**防它回来。
  check('🔴 模型**已删** `score` / `comments`（HN 弃用 ⇒ 后端列已删）',
      !feedItem.contains('int? score') && !feedItem.contains('int? comments'));
  // ⚠️ **不要**去断言「注释里保留了兼容说明」——
  //    本文件第 72 行用的是 `readNoComment(...)`（**剥掉注释再断言**），
  //    那是**刻意**的：注释不是契约，若把它也纳入断言，
  //    改一句措辞就会红 ⇒ 又是一种假红（正是本轮在修的病）。
  //    ⇒ 「删字段 ≠ 删文档」这条知识留在**代码注释**里即可，**不进断言**。
  //    📌 判据：**断言锁行为/形状，不锁注释文本**。
  check('`has_body` 映射到 `hasBody`', feedItem.contains('has_body'));

  // ══════════════════════════════════════════════════════════
  section('【8】provider 层约定');
  // ══════════════════════════════════════════════════════════
  check('🆕 `feedByIdsProvider` 用**字符串 key**（List 的 `==` 是引用比较）',
      feedProvider.contains('FutureProvider.family<Map<int, FeedItem>, String>'));
  check('🔴 详情用 `autoDispose`（读完释放全文，防积内存）',
      feedProvider.contains('autoDispose.family<ArticleDetail'));

  // 🔴 「信息流列表**不** autoDispose」这条约定**没变**，但**断言写法要改**
  //    （2026-10-03）：原断言写死
  //      `final feedProvider =\n    FutureProvider.family<FeedPage, String>`
  //    —— 而实现已从 `FutureProvider` 换成 `AsyncNotifierProvider`
  //    （分页需要累积状态 ⇒ `FutureProvider` 是「一次算完」的语义，做不到），
  //    类型名一改，写死的正向断言就**假红**，而约定本身**完全没变**。
  //
  //    ✅ 改成两步，都**锁语义不锁拼写**：
  //      ① 正向（弱）：确认它**确实是 family**（否则「provider 被删掉」也会绿）
  //      ② 反向（强）：确认声明块里**没有** `autoDispose`
  //         —— 「不该有的东西不存在」对实现更换**天然免疫**，且更贴近约定本身
  //    ⚠️ 必须**先截出 `feedProvider` 自己的声明块**，不能对整个文件做反向断言：
  //       同文件里 `articleDetailProvider` **是** autoDispose（那是刻意的），
  //       对整个文件断言会误判。
  final feedFeedDecl = RegExp(r'final feedProvider\s*=\s*[\s\S]*?\);')
          .firstMatch(feedProvider)
          ?.group(0) ??
      '';
  check('🔴 截到了 `feedProvider` 的声明块（断言前提成立）',
      feedFeedDecl.isNotEmpty, '截不到 ⇒ 下面的反向断言会假绿');
  check('🔴 `feedProvider` 是 **family**（参数 = 分类 key）',
      feedFeedDecl.contains('.family<') && feedFeedDecl.contains('String'));
  check('🔴 信息流列表**不** autoDispose（切 tab 回来不该重拉）',
      feedFeedDecl.isNotEmpty && !feedFeedDecl.contains('autoDispose'));

  // ══════════════════════════════════════════════════════════
  section('【9】分类词表：后端与端侧**逐字一致**（跨语言漂移是无症状的）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 为什么需要这条（2026-10-02）：
  //    分类词表**同时存在于两种语言**里 ——
  //      后端 `schema.rs` 的 `CONTENT_CATEGORIES`（源配置 + CHECK 用它）
  //      端侧 `feed_item.dart` 的 `kCategoryLabels`（卡片显示用它）
  //    后端加了新类而端侧没跟上时：**不报错**，只是卡片显示兜底词 `Reading`
  //    （`_unknownCategory`）—— 用户看到的是「分类名变成了 Reading」，
  //    而没有任何一处会红。⇒ 只能靠源级断言守住。
  //
  // ⚠️ 反向也要守：端侧有、后端没有的 key，说明端侧残留了已删的分类
  //    （`life` 就是这样被删掉的 —— 它必须**从两边同时消失**）。
  final backendCats = <String>{};
  final catBlock = RegExp(r'pub const CONTENT_CATEGORIES[^=]*=\s*&\[([^\]]*)\]',
          multiLine: true)
      .firstMatch(schema);
  if (catBlock != null) {
    for (final m in RegExp(r'"([a-z_]+)"').allMatches(catBlock.group(1)!)) {
      backendCats.add(m.group(1)!);
    }
  }
  check('后端 `CONTENT_CATEGORIES` 可解析（唯一权威定义处）',
      backendCats.isNotEmpty, '实得 ${backendCats.length} 个');

  final dartCats = <String>{};
  final mapBlock = RegExp(r"kCategoryLabels\s*=\s*\{([^}]*)\}", multiLine: true)
      .firstMatch(feedItem);
  if (mapBlock != null) {
    for (final m in RegExp(r"'([a-z_]+)'\s*:").allMatches(mapBlock.group(1)!)) {
      dartCats.add(m.group(1)!);
    }
  }
  check('端侧 `kCategoryLabels` 可解析', dartCats.isNotEmpty, '实得 ${dartCats.length} 个');

  check('🔴 两边**集合相等**（不是「包含」—— 多一个也是漂移）',
      backendCats.length == dartCats.length &&
          backendCats.difference(dartCats).isEmpty &&
          dartCats.difference(backendCats).isEmpty,
      '后端缺 ${dartCats.difference(backendCats)} · 端侧缺 ${backendCats.difference(dartCats)}');

  // 🔑 定稿的 7 类必须都在（`implementation-plan-v2` §10.3.1）
  for (final must in [
    'tech',
    'business',
    'science',
    'sports',
    'culture',
    'entertainment',
    'health'
  ]) {
    check('定稿 7 类里有 `$must`（§10.3.1）', backendCats.contains(must));
  }
  // `news` 是白哥追加的第 8 类（定稿没有它 —— 所以单独断言，说明它是有意保留的）
  check('🆕 `news` 保留为第 8 类（白哥附加决定，非定稿）', backendCats.contains('news'));
  // 🔴 定稿要求删掉的 `life`：**必须彻底消失**（否则语义残留会把它带回来）
  check('🔴 `life` 已从两边删除（定稿：「生活太糊」）',
      !backendCats.contains('life') && !dartCats.contains('life'));

  // ══════════════════════════════════════════════════════════
  section('【9b】🔴 跨模块常量的**定义位置**（2026-10-03 真实编译失败）');
  // ══════════════════════════════════════════════════════════
  //
  // # 事故
  // `kCategoryLabels` 原名 `_categoryLabels`，是 **`FeedItem` 的私有静态成员**。
  // 兴趣界面要复用它 ⇒ 改名 `kCategoryLabels`（去私有）、**但位置没动**。
  // 而 `k` 前缀在本项目是**顶层常量**惯例（`kFeedPageSize` / `kInterestPrefsKey` …）
  // ⇒ 调用方**按惯例裸写** `kCategoryLabels` ⇒ **解析不到** ⇒ `flutter build` 失败：
  //     "The getter 'kCategoryLabels' isn't defined for the type '_ProfileScreenState'"
  //
  // 🔑 **为什么本脚本没能提前拦住**：原断言只查「字符串存在」
  //    （`feedItem.contains('kCategoryLabels')`）⇒ 它**报了 ✅**。
  //    「字符串存在」≠「引用可解析」—— 这类错**语法检查也查不出**（`dart format` 通过）。
  //
  // 📌 判据：**跨模块共享的标识符，断言要锁「定义位置（顶层 / 类内）」**，
  //    而不只是「它存在」。位置决定调用方能不能裸名引用。
  final defMatch = RegExp(
    r'^(?<indent>[ \t]*)(?:static )?const Map<String, String> kCategoryLabels',
    multiLine: true,
  ).firstMatch(feedItem);
  check('🔴 `kCategoryLabels` 有定义（前提）', defMatch != null,
      '截不到 ⇒ 下面会假绿');
  check('🔴 它定义在**顶层**（缩进为空 ⇒ 外部可裸名引用）',
      defMatch != null && defMatch.namedGroup('indent')!.isEmpty,
      '缩进非空 ⇒ 是**类静态成员** ⇒ 外部裸名引用**会解析失败**（build 会报 not defined）');
  check('🔴 兴趣界面用**裸名**引用它（与上面「顶层」配套）',
      profile.contains('kCategoryLabels.entries'));
  check('不出现 `FeedItem.kCategoryLabels`（那是「定义在类内」的写法，与顶层矛盾）',
      !profile.contains('FeedItem.kCategoryLabels'));
  // 源配置的 CHECK 必须与常量同步（否则改了一边另一边还在放行）
  check('`content_source.category` 的 CHECK 与常量同步（8 个值）',
      RegExp(r"CHECK \(category IN \('news','tech','business','science','sports',")
          .hasMatch(schema));

  // ══════════════════════════════════════════════════════════
  // 汇总
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
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
