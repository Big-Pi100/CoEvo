// 内容源 API 客户端 —— 信息流（`/api/feed`）+ 文章详情（`/api/feed/{id}`）
//
// # 🔴 本客户端**不带 token**（不是遗漏）
//
// 产品原则：「除生词表上限外**不验证登录态**」——
// 「登录态是**能力限制开关**，不是**内容可见性开关**」。
// 读信息流 / 打开文章属**内容渲染**，若它需要登录，
// 则「登录服务一抖 → 整个信息流打不开」——**用易失败的外部依赖卡住内容**。
//
// 🔑 所以本文件**没有** `userToken` 字段、也不调 `ApiConfig.headers(token:)`。
//    将来若有人要加鉴权（如「已订阅才给读全文」），请先回看这条原则：
//    那种限制的正确位置是**能力层**（能否订阅/能否加词），不是内容读取层。
//
// # 分层
// 本层只做「HTTP + JSON → 模型」。**不含业务判断**（如「排序该用什么」）——
// 那些是调用方（provider / 页面）的事。

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../models/feed_item.dart';
import 'api_config.dart';

/// 一页信息流的返回。
///
/// 🔑 带上 `total` 是因为**端侧要判断「还有没有更多」**（分页）。
///    只给 items 的话，调用方无法区分「最后一页」与「本页恰好取满」。
class FeedPage {
  final List<FeedItem> items;
  final int total;
  final int limit;
  final int offset;

  const FeedPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  /// 是否还有下一页（按 offset+本页条数 < total 判断）。
  bool get hasMore => offset + items.length < total;

  static const FeedPage empty = FeedPage(items: [], total: 0, limit: 0, offset: 0);
}

/// 可渲染文本的**来源** —— 🔑 让「全文 vs 摘要」在**类型上**就分得开。
///
/// # 🔴 为什么要有这个枚举（真实事故 · 2026-10-02）
/// 原实现只提供一个 `String? readableText`：`body` 为空时**兜底到 `summary`**，
/// 但返回值把「全文」与「摘要」**压成了同一个东西** —— 调用方无从分辨。
///
/// 而它当时的注释**恰好写着**「退到 `summary` 时不要当成有正文」：
/// 🔴 **注释表达了要求，但返回类型没能力兑现它** → 调用方（阅读器）只能按
/// 「非空 = 有正文」处理 → 某篇的 `summary` 是**源站自己的报错**
/// （`Liquid syntax error: 'raw' tag was never closed`）时，
/// **那句报错被当正文渲染** → 用户看到的就是「只有半句话」。
///
/// 📌 判据：**当注释在叮嘱调用方「注意区分 A 和 B」，而返回类型里没有 A/B 的区别时，
///    那不是文档问题，是类型问题** —— 要靠类型兑现，不能靠注释。
enum ArticleTextSource {
  /// 真全文（后端抓到的 `body`）。
  body,

  /// **兜底**用的摘要（`summary`）—— ⚠️ **不是全文**。
  summary,
}

/// 文章详情（比列表多 `body` 全文）。
class ArticleDetail {
  final FeedItem item;
  /// 全文（**可能为 `null`** —— 见 [FeedItem.hasBody]）。
  final String? body;

  const ArticleDetail({required this.item, this.body});

  /// 可渲染文本 + **它是哪来的**（见 [ArticleTextSource]）。
  ///
  /// 🔴 **兜底顺序不能反**：优先 `body`（真全文），没有才退到 `summary`。
  ///    反过来的话，明明有全文却只显示摘要（用户会以为抓取失败）。
  ///
  /// 🔑 返回 `null` = **真的什么都没有** → 调用方走「这一篇还没有正文」那条正常分支。
  /// 🔑 返回 `source: summary` = **有内容，但不是全文** → 调用方必须**区别对待**
  ///    （不能当全文渲染：那正是「半句话」事故的成因）。
  ({String text, ArticleTextSource source})? get renderable {
    final b = body;
    if (b != null && b.trim().isNotEmpty) {
      return (text: b, source: ArticleTextSource.body);
    }
    final s = item.excerpt.trim();
    if (s.isEmpty) return null;
    return (text: s, source: ArticleTextSource.summary);
  }
}

/// 内容源接口客户端。
///
/// ⚠️ 所有方法**失败抛 `ContentApiException`**（不返回 null）——
///    调用方要能区分「没有内容」（正常空列表）与「拿不到」（错误），
///    两者的界面表达完全不同（空状态 vs 错误态 + 重试）。
class ContentApiClient {
  final String baseUrl;
  final http.Client _http;

  ContentApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? ApiConfig.baseUrl,
        _http = httpClient ?? http.Client();

  /// `GET /api/feed` —— 信息流列表。
  ///
  /// [category] 空/null = 不筛（后端按 `(?1 IS NULL OR ...)` 处理）。
  /// [sort] `time`（默认）| `score`（热帖）。
  Future<FeedPage> fetchFeed({
    String? category,
    int limit = 20,
    int offset = 0,
    String? sort,
  }) async {
    final q = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (category != null && category.isNotEmpty) 'category': category,
      if (sort != null && sort.isNotEmpty) 'sort': sort,
    };
    final json = await _getJson('/api/feed', q);
    return _parsePage(json);
  }

  /// `GET /api/feed?ids=...` —— 按 id 批量取（**收藏清单**用）。
  ///
  /// # 🔑 为什么不逐条调 [fetchArticle]
  /// 收藏 50 条 = 50 次请求（50 次握手 + 50 次 DB 往返）。
  /// 批量一次解决，且与列表**同一套响应形状** → 只需一套解析代码。
  ///
  /// # ⚠️ 响应顺序**不保证**等于传入顺序
  /// 后端按 `published_at DESC` 返回，而收藏清单要的是「收藏时间倒序」
  /// （那是端侧 `bookmark` 表的顺序）。
  /// → 调用方应建 `{id: item}` 映射后**按自己的顺序取**，不要依赖响应顺序。
  ///
  /// # 找不到的 id **不在结果里**（不报错）
  /// 收藏的内容可能已被清理 → 调用方按「缺失 = 不可渲染」处理。
  Future<List<FeedItem>> fetchByIds(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final json = await _getJson('/api/feed', {'ids': ids.join(',')});
    return _parsePage(json).items;
  }

  /// `GET /api/feed/{id}` —— 单篇详情（**含 `body`**）。
  ///
  /// 不存在时抛 `ContentApiException(404)` —— 阅读器据此显示「找不到这篇文章」
  /// （与「正文未就绪」是**两种不同**的表达，不能合并）。
  Future<ArticleDetail> fetchArticle(int id) async {
    final json = await _getJson('/api/feed/$id', const {});
    final itemJson = json['item'];
    if (itemJson is! Map<String, dynamic>) {
      throw ContentApiException('响应缺少 item 字段', statusCode: 0);
    }
    final item = FeedItem.fromJson(itemJson);
    final body = itemJson['body'] as String?;
    return ArticleDetail(item: item, body: body);
  }

  /// 统一的 GET + 解 JSON + 错误包装。
  Future<Map<String, dynamic>> _getJson(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: query.isEmpty ? null : query,
    );
    http.Response resp;
    try {
      resp = await _http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(ApiConfig.requestTimeout);
    } catch (e) {
      // 网络层错误（超时 / DNS / 连接被拒）—— 与 HTTP 错误分层表达，
      // 因为对用户而言「网络不通」和「服务器说没有」是不同的事。
      debugPrint('[content] 请求失败 $uri：$e');
      throw ContentApiException('网络连接失败', statusCode: 0);
    }

    if (resp.statusCode != 200) {
      debugPrint('[content] HTTP ${resp.statusCode} @ $uri');
      throw ContentApiException(
        '服务返回 ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw ContentApiException('响应不是 JSON 对象', statusCode: 200);
      }
      // 后端成功时给 `{"ok": true, ...}`；`ok: false` 视为错误
      if (decoded['ok'] == false) {
        throw ContentApiException(
          (decoded['error'] as String?) ?? '未知错误',
          statusCode: resp.statusCode,
        );
      }
      return decoded;
    } on ContentApiException {
      rethrow;
    } catch (e) {
      debugPrint('[content] 解析响应失败 @ $uri：$e');
      throw ContentApiException('响应格式异常', statusCode: 200);
    }
  }

  /// 解析 `{items, total, limit, offset}`。
  ///
  /// 🔑 单个 item 解析失败 → **跳过该条**，不让整页失败。
  ///    理由：一条脏数据不该让用户看不到另外 19 条。
  ///    ⚠️ 但要 `debugPrint` —— 「跳过」不等于「静默」。
  FeedPage _parsePage(Map<String, dynamic> json) {
    final raw = json['items'];
    final items = <FeedItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            items.add(FeedItem.fromJson(e));
          } catch (err) {
            debugPrint('[content] 跳过无法解析的条目：$err');
          }
        }
      }
    }
    return FeedPage(
      items: items,
      total: (json['total'] as num?)?.toInt() ?? items.length,
      limit: (json['limit'] as num?)?.toInt() ?? items.length,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }

  void dispose() => _http.close();
}

/// 内容源接口失败。
///
/// [statusCode] = 0 表示**网络层**失败（没拿到响应）；其余为 HTTP 状态码。
/// 🔑 分开是因为界面表达不同：网络问题提示「检查网络 + 重试」，
///    而 404 说明「这篇确实不存在」（不该劝用户重试）。
class ContentApiException implements Exception {
  final String message;
  final int statusCode;

  const ContentApiException(this.message, {required this.statusCode});

  /// 是否「这篇不存在」（阅读器据此换文案，不劝重试）。
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'ContentApiException($statusCode): $message';
}
