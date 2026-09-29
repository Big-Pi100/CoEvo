// 内容源 provider —— 信息流列表 / 文章详情 / 按 id 批量
//
// # 数据源
// 后端 `/api/feed`（服务端共享内容池）—— 不是 mock、不是端侧库。
// 🔴 **本 provider 不依赖登录态**（见 `content_client.dart` 文件头的说明）。
//
// # 与 `bookmarkProvider` 的分工
// | | `bookmarkProvider` | 本文件 |
// |---|---|---|
// | 数据源 | 端侧 `user.db` | 后端 `/api/feed` |
// | 是否需登录 | ❌ | ❌ |
// | 是否可能长时间不可用 | 库未就绪（短） | **网络/服务不可用（可能长时间）** |
// → 🔑 正因为它**依赖网络**，三态（加载/失败/空）必须都有出口 ——
//   这是本项目反复的教训：「**静默失败 + 无出口**」比报错更糟。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/content_client.dart';
import '../models/feed_item.dart';

/// 内容源客户端（单例 —— `http.Client` 复用连接池）。
final contentClientProvider = Provider<ContentApiClient>((ref) {
  final client = ContentApiClient();
  ref.onDispose(client.dispose);
  return client;
});

/// 信息流列表（**未来可加分类筛选** —— 参数已就位）。
///
/// 用 `FutureProvider.family` 而不是普通 `FutureProvider`：
/// 「分类筛选」是本路由的**既定下一步**（后端 `/api/feed?category=` 已支持），
/// 提前用 family 就不必在那时把整棵树改一遍。
///
/// ⚠️ 约定：参数用 **key 字符串**（`''` = 全部）而不是 `null` ——
/// `family` 的参数参与相等性比较，用 `null` 会让「未筛选」有多个等价写法。
final feedProvider =
    FutureProvider.family<FeedPage, String>((ref, categoryKey) async {
  final client = ref.watch(contentClientProvider);
  return client.fetchFeed(
    category: categoryKey.isEmpty ? null : categoryKey,
    limit: 30,
  );
});

/// 按 id 批量取（收藏清单）。
///
/// 🔑 参数是**排好序的 id 列表**，但返回的是 `Map<id, item>` ——
///    因为后端响应顺序**不保证**等于请求顺序（它按 `published_at DESC`）。
///    调用方拿映射后**按自己的顺序取**（收藏清单的顺序是收藏时间倒序，
///    那是端侧 `bookmark` 表的顺序，不是后端能知道的）。
///
/// ⚠️ `family` 的参数参与相等性：`List` 的默认 `==` 是**引用比较** ——
///    传一个新建的 list 每次都会重新请求。所以调用方应传**稳定**的列表
///    （如直接来自 provider 的 state），或改用 `join(',')` 后的字符串。
///    → 这里用**字符串 key**（逗号分隔，已排序），天然值相等 ✅
final feedByIdsProvider =
    FutureProvider.family<Map<int, FeedItem>, String>((ref, idsKey) async {
  final ids = idsKey
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toList();
  if (ids.isEmpty) return const {};
  final client = ref.watch(contentClientProvider);
  final items = await client.fetchByIds(ids);
  return {for (final it in items) it.id: it};
});

/// 单篇详情（阅读器用）。
///
/// ⚠️ `autoDispose`：读完退出后释放 —— 全文可能几 KB，
///    读者翻过几十篇都不释放会积在内存里。
///    而信息流列表（上面那个）**不** autoDispose（切 tab 回来不该重新拉）。
final articleDetailProvider =
    FutureProvider.autoDispose.family<ArticleDetail, int>((ref, id) async {
  final client = ref.watch(contentClientProvider);
  return client.fetchArticle(id);
});
