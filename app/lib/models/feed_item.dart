import 'package:flutter/foundation.dart' show debugPrint;

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
///
/// # 🆕 2026-09-29：字段与后端 `/api/feed` **对齐完毕**
///
/// 本文件此前写着「后端 feed 接口尚未实现 —— 字段名是端侧的暂定约定，
/// 接口定案后需回来对齐」。现在接口已定，对齐情况：
///
/// | 端侧 | 后端 `content_pool` / 接口字段 | 说明 |
/// |---|---|---|
/// | `id` | `id` | = `content_pool.id`（后端用 `AUTOINCREMENT` → **id 不复用**，见下） |
/// | `category` | `category` | 受控词表（**源配置**，不是 RSS 的自由标签） |
/// | `title` | `title` | |
/// | `excerpt` | **`summary`** | 🔑 名字不同：端侧叫 excerpt（卡片上的摘录），后端叫 summary |
/// | `source` | `source` | 源名（如 `NPR News`） |
/// | `minutes` | **`word_count`** | 🔑 **不是字段直传** —— 由 `word_count` 在端侧换算（见 [minutes]） |
/// | — | `url` | 原文链接（**`redistributable` / 跳原文**用） |
/// | — | `author` | 作者（`dc:creator`） |
/// | — | `published_at` | 发布时刻（**UTC ISO8601 带 `Z`**） |
/// | — | `has_body` | 是否已拿到全文 → 决定阅读器能不能读 |
class FeedItem {
  /// 内容 id —— = 后端 `content_pool.id`，也是端侧 `bookmark.content_id` 与
  /// `article_read.article_id` 的取值。
  ///
  /// 🔑 后端那张表用 `AUTOINCREMENT`（而不是普通 `INTEGER PRIMARY KEY`）——
  /// 普通主键在**删除后会复用** id，若内容池做保留期清理，
  /// 被清理文章的 id 会被新文章占用 → 端侧那条「已读」记录会**静默指向另一篇文章**。
  final int id;

  /// 分类 key（`news` / `tech` / `science` / `culture` / `business` / `life`）。
  ///
  /// ⚠️ 存的是**后端原始 key**（小写），**不是显示文案** ——
  /// 显示走 [categoryLabel]（见那里的说明：口径只定义一处）。
  final String category;

  /// 预计阅读时长（分钟）—— 卡片元信息的后半。
  ///
  /// 🔑 **由 `wordCount` 换算，不是后端字段**。理由同 `Article.lookups` 存 `reps`
  /// 不存样式：「**数据层存事实（词数），渲染层算表现（几分钟）**」。
  /// 阅读速度是**展示口径** → 将来若要按用户水平调整，只改这一处。
  final int minutes;

  final String title;

  /// 摘要。列表卡片最多 3 行（设计稿 `-webkit-line-clamp: 3`）。
  final String excerpt;

  /// 来源（`NPR News`）—— 卡片上**不显示**，阅读界面「来源行」用。
  final String source;

  /// 原文链接。空串 = 后端没给（理论上不会 —— `url` 是入库的幂等键，NOT NULL）。
  final String url;

  /// 作者。`null` = 该源没提供（如 ECNS 没有 `dc:creator`）。
  final String? author;

  /// 发布时刻（**UTC ISO8601 带 `Z`**）。`null` = 该源没提供。
  final String? publishedAt;

  // 🔴 2026-10-03 已删除 `score` / `comments` 两字段 ——
  //    它们只有 HN 会填，而**后端已放弃 HN**（适配器删除 + 两列 DROP）。
  //    📌 删除前实测：全 `app/lib` **零消费者**（`grep '\.score'` 无命中）
  //       ⇒ 属死代码，删除无行为影响。
  //    ⚠️ 老客户端（未升级的包）仍会读 `json['score']` —— 后端不返回该键时
  //       它解析为 `null`，**不会崩**（`(json['score'] as num?)?.toInt()`）。

  /// 是否已拿到全文。
  ///
  /// 🔴 **决定阅读器是「可读」还是「正文还没准备好」** ——
  /// 实测各源差异很大：Ars Technica 的 feed 自带全文（20/20 有），
  /// 而 NPR / ECNS / Dev.to 只给摘要（0 有，需要抓原网页，**该步未实现**）。
  final bool hasBody;

  const FeedItem({
    required this.id,
    required this.category,
    required this.minutes,
    required this.title,
    required this.excerpt,
    required this.source,
    this.url = '',
    this.author,
    this.publishedAt,
    this.hasBody = false,
  });

  /// 卡片与收藏清单共用的元信息行 —— 格式取自设计稿原文：`Science · 4 min`。
  ///
  /// 🔑 放在模型上而不是各页面各拼一次：卡片和收藏清单是**同一套组件**
  /// （设计稿 §03 ②「不做新的列表样式」），格式必须只定义一次。
  String get meta => '$categoryLabel · $minutes min';

  /// 分类显示文案（后端 key → 界面文字）。
  ///
  /// 🔑 **只在这里定义一次** —— 卡片、收藏清单、阅读器顶部都读它。
  /// 各页面各写一份映射，就是「同一个口径多个出处」（必然漂移）。
  ///
  /// ⚠️ 目前是**英文**（`Science` / `Tech`）—— 依据是 **L1 界面锚点**
  /// `visual-feed-bookmark-2026-09-25.html` 的卡片原文就是 `Science · 4 min`。
  /// 若要改中文，**只改本 map**（不要在页面里覆盖）。
  String get categoryLabel => kCategoryLabels[category.toLowerCase()] ?? _unknownCategory;

  /// 未登记分类的兜底显示。
  ///
  /// 🔴 **不用空串、也不用原始 key**：
  /// · 空串 → 卡片元信息行变成 ` · 4 min`（看着像 bug）
  /// · 原始 key → 可能漏出内部词（`life`）
  /// → 用一个中性的通用词。⚠️ 出现它说明**后端加了新分类而这里没同步**，
  ///   所以同时 `debugPrint` 一条（见 [FeedItem.fromJson]），别让它静默。
  static const String _unknownCategory = 'Reading';

  /// 分类显示表（后端 key → 界面文字）。
  ///
  /// ⚠️ **key 必须与后端受控词表逐字一致** ——
  ///    后端定义处：`backend/crates/api_server/src/schema.rs` 的
  ///    **`CONTENT_CATEGORIES`**（唯一权威）。改这里必须同步改那里（反之亦然）。
  ///    这条一致性由 `scripts/query_verify/bin/verify_feed_wiring.dart`
  ///    的【9】组断言锁住（它读这个 map 的 key 与那份清单比对）。
  ///
  /// # 🔑 这 8 个值的来历（**照定稿收敛**，2026-10-02 白哥批准）
  /// 定稿 → `implementation-plan-v2` §10.3.1「扩到 **7** 个 category，**删掉 `life`**」：
  /// `tech | business | science | sports | culture | entertainment | health`
  /// （理由：兴趣标签**用户可见**，粒度决定「按我兴趣推」的感知强度；
  ///   且「生活」太糊 —— 睡眠算健康还是生活？会让抓取时分类不稳定）。
  ///
  /// 🆕 **`news` 是第 8 个值**（白哥追加）—— 定稿两版都没有它：
  /// 它是**实现期**为 NPR / ECNS 临时加的，而「综合 / 国际新闻」
  /// 确实不属于任何兴趣类 ⇒ 保留，卡片显示 `News`。
  ///
  /// 🆕 **2026-10-02 三轮扩到 12 类**（白哥「不能归类可以增加新分类」）：
  ///    新增 `education` / `history` / `law` / `family` 四类。
  ///    ⇒ 每个类**都有源覆盖**（后端断言：分类集合 ≡ `CONTENT_CATEGORIES`）。
  ///
  ///    ⚠️ 后端新增「跨类编辑栏目」**不接**（`Opinion`/`Analysis`/`Perspective`/
  ///       `Obituaries`/`Race`/`On Disabilities`）—— 它们的内容分属各类，
  ///       建类会让分类自相矛盾。详见 `schema.rs` 的 `CONTENT_CATEGORIES` 注释。
  ///
  ///    ⚠️ **12 个已是上限**（兴趣标签用户可见，定稿 §10.3.1）——
  ///       再加就该先合并（`law`→`news`、`family`→`health`）。
  ///
  ///    后端锁定处：`content_fetch::tests::test_seed_sources_are_loaded` ①b
  ///    （断言 `content_source` 的分类集合 **≡** `CONTENT_CATEGORIES`）。
  static const Map<String, String> kCategoryLabels = {
    'news': 'News',
    'tech': 'Tech',
    'business': 'Business',
    'science': 'Science',
    'sports': 'Sports',
    'culture': 'Culture',
    'entertainment': 'Entertainment',
    'health': 'Health',
    // ── 🆕 2026-10-02 三轮新增 ──
    'education': 'Education',
    'history': 'History',
    'law': 'Law',
    'family': 'Family',
  };

  /// 阅读速度（词/分钟）—— 用于把 `word_count` 换算成「N min」。
  ///
  /// # 为什么是 150（不是母语者的 ~230）
  /// 本产品的用户是**中文母语者读英文** —— 按母语者的速度估会**系统性低估**
  /// 实际耗时（用户读到一半发现「说好 4 分钟」）。宁估长不估短。
  /// 📌 这是**展示口径**，改这一个数即可全站生效（`minutes` 是唯一的消费者）。
  static const int _wordsPerMinute = 150;

  /// 词数 → 分钟（**至少 1**）。
  ///
  /// 🔑 「至少 1」不是凑数：显示 `0 min` 会让卡片看起来是坏的；
  ///    而一篇短讯（< 150 词）确实也占用户一次「阅读动作」。
  static int minutesFromWordCount(int wordCount) {
    if (wordCount <= 0) return 1;
    final m = (wordCount / _wordsPerMinute).ceil();
    return m < 1 ? 1 : m;
  }

  /// 从 `/api/feed` 的 item 构造。
  ///
  /// 🔑 **容忍字段缺失**（不抛）：后端加字段 / 某源没给某字段都不该让整页崩。
  ///    但**分类未登记**会留一条日志（见 [_unknownCategory]）——
  ///    「容忍」不等于「静默」。
  factory FeedItem.fromJson(Map<String, dynamic> json) {
    final category = (json['category'] as String?) ?? '';
    final wordCount = (json['word_count'] as num?)?.toInt() ?? 0;
    // ⚠️ 未登记分类 → 兜底文案 + 一条日志（别让它静默）
    if (category.isNotEmpty && !kCategoryLabels.containsKey(category.toLowerCase())) {
      debugPrint('[FeedItem] 未登记的分类 `$category`（后端加了新分类？）→ 显示 $_unknownCategory');
    }
    return FeedItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      category: category,
      minutes: minutesFromWordCount(wordCount),
      title: (json['title'] as String?) ?? '',
      // 后端字段名是 `summary` —— 端侧语义名是 excerpt（卡片摘录）
      excerpt: (json['summary'] as String?) ?? '',
      source: (json['source'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      author: json['author'] as String?,
      publishedAt: json['published_at'] as String?,
      hasBody: json['has_body'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'word_count': minutes * _wordsPerMinute,
        'title': title,
        'summary': excerpt,
        'source': source,
        'url': url,
        'author': author,
        'published_at': publishedAt,
        'has_body': hasBody,
      };
}
