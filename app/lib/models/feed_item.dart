/// 信息流文章 —— 一篇文章 = 一张卡片 + 一个阅读对象。
///
/// 目标态见 `docs/design/visual-feed-bookmark-2026-09-25.html`：
/// 卡片上**只有四个元素** —— 分类·时长 / 标题 / 摘要 / 收藏。
/// 「N 个生词」与「已读 / 未读」已作废（设计稿 §02：
/// 「数字会和痕迹抢角色。去掉数字之后，**痕迹成了唯一的进度表达**」）。
///
/// 🔴 因此本模型**刻意没有** `newWordCount` / `isRead` / `progress` 这类字段 ——
/// 进度只存在于阅读界面的痕迹（`tk-n` / `tk-m` / `tk-d`）里。
/// 「一个概念，一个表达」；多加一个计数字段就是给同一个概念造第二个表达。
class FeedItem {
  /// 内容 id —— 与后端 `content` 主键、端侧 `bookmark.content_id` 同源。
  final int id;

  /// 分类（`Science` / `Culture` / `Business`…）—— 卡片元信息的前半。
  final String category;

  /// 预计阅读时长（分钟）—— 卡片元信息的后半。
  final int minutes;

  final String title;

  /// 摘要。列表卡片最多 3 行（设计稿 `-webkit-line-clamp: 3`）。
  final String excerpt;

  /// 来源（`VOA Learning English`）—— 卡片上**不显示**，阅读界面「来源行」用。
  final String source;

  const FeedItem({
    required this.id,
    required this.category,
    required this.minutes,
    required this.title,
    required this.excerpt,
    required this.source,
  });

  /// 卡片与收藏清单共用的元信息行 —— 格式取自设计稿原文：`Science · 4 min`。
  ///
  /// 🔑 放在模型上而不是各页面各拼一次：卡片和收藏清单是**同一套组件**
  /// （设计稿 §03 ②「不做新的列表样式」），格式必须只定义一次。
  String get meta => '$category · $minutes min';

  /// 后端 feed 接口（Phase 3）尚未实现 —— 字段名是端侧的暂定约定，
  /// 接口定案后需回来对齐（`toJson` 同理）。
  factory FeedItem.fromJson(Map<String, dynamic> json) => FeedItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        category: json['category'] as String? ?? '',
        minutes: (json['minutes'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        excerpt: json['excerpt'] as String? ?? '',
        source: json['source'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'minutes': minutes,
        'title': title,
        'excerpt': excerpt,
        'source': source,
      };
}
