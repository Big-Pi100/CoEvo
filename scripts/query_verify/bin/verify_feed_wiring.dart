// CoEvo · **信息流 / 阅读页接线验收**
//   ① 信息流从 `/api/feed` 取数（**不再有 mock**）—— 防「退回 mock」
//   ② 三态齐全（加载 / 失败可重试 / 空）—— 防「静默失败 + 无出口」
//   ③ 阅读页从 `/api/feed/{id}` 取正文 + 痕迹来自端侧 `lookup_event`
//   ④ 后端 `/api/feed` 支持 `ids`（收藏清单用）且 `parse_ids` 不能被绕过
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

  // ══════════════════════════════════════════════════════════
  section('【1】信息流：从服务端取数（不再有 mock）');
  // ══════════════════════════════════════════════════════════
  //
  // 🔴 断言用的是**完整表达式** `ref.watch(feedProvider('')).when(`，不是裸的
  //    `feedProvider`。原因（**受控实验抓到的**）：
  //    裸名字在 `error:` 回调里也出现（`ref.invalidate(feedProvider(''))`），
  //    所以只匹配裸名时，「把 watch 换成 mock」这个回归**不会让它变红** ——
  //    断言看着在守，实际是**假绿**。
  //    → 锁「取数 + 三态分派」这个完整形状，才真的守得住。
  //    📌 同族判据：**断言要覆盖到「形状」，不只是一个名字的出现**。
  const feedWatch = "ref.watch(feedProvider('')).when(";
  check('🔴 信息流是 `ref.watch(feedProvider(...)).when(...)`（完整形状）',
      home.contains(feedWatch));
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
  check('🔴 分类显示映射**只有一处**（`_categoryLabels`）',
      feedItem.contains('_categoryLabels') && feedItem.contains('categoryLabel'));
  check('未登记分类有兜底文案（不留空、不漏内部 key）',
      feedItem.contains('_unknownCategory'));
  check('🔴 热帖字段是 `Option`（只有 HN 有，其余源为 null）',
      feedItem.contains('int? score') && feedItem.contains('int? comments'));
  check('`has_body` 映射到 `hasBody`', feedItem.contains('has_body'));

  // ══════════════════════════════════════════════════════════
  section('【8】provider 层约定');
  // ══════════════════════════════════════════════════════════
  check('🆕 `feedByIdsProvider` 用**字符串 key**（List 的 `==` 是引用比较）',
      feedProvider.contains('FutureProvider.family<Map<int, FeedItem>, String>'));
  check('🔴 详情用 `autoDispose`（读完释放全文，防积内存）',
      feedProvider.contains('autoDispose.family<ArticleDetail'));
  check('信息流列表**不** autoDispose（切 tab 回来不该重拉）',
      feedProvider.contains('final feedProvider =\n    FutureProvider.family<FeedPage, String>'));

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
