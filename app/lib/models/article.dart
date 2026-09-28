/// 一篇可阅读的文章 —— 正文 + 该文章里「我查过哪些词」。
///
/// # 与 `FeedItem` 的关系
/// 设计稿原话：「**一篇文章 = 一张卡片 + 一个阅读对象**」。
/// 卡片（[FeedItem]）只承载列表所需的四个元素（分类·时长 / 标题 / 摘要 / 收藏）；
/// 正文、痕迹所需的查词事实都在本模型里 —— **两者共用同一个 `id`**。
///
/// 🔴 刻意**不合并成一个类**：信息流列表要渲染上百张卡，
/// 若每张卡都拖着正文，列表会把整篇文章读进内存。
/// 「列表拿摘要、进详情才取正文」是分层的意义。
///
/// # 痕迹为什么存的是 `reps` 而不是样式
/// 🔑 **数据层存事实，渲染层算表现。**
/// `reps = 3` 是事实，「用哪档底色/线宽」是表现 ——
/// 表现随主题、随字号、随将来是否加动画而变，事实不变。
/// 所以这里只存 `reps` / `lapses`，样式由 `TraceTokens.forReps()` 在渲染时算。
/// （若把样式写进数据层，哪天改视觉就要重扫全库 —— 与「优先级是渲染层面的事」同一条原则。）
class Article {
  final int id;

  /// 分类（`Science`）—— 阅读器顶部栏显示。
  final String category;

  final String title;

  /// 来源（`VOA Learning English`）—— 阅读器「来源行」显示。
  final String source;

  /// 正文段落。**空列表 = 正文尚未就绪**（后端 RSS 抓取属 Phase 3），
  /// 阅读器会给一个明确的占位，而不是白屏。
  final List<String> paragraphs;

  /// 本篇文章里「用户查过的词」—— 痕迹的数据来源。
  ///
  /// 真实链路（Phase 3 后）：`lookup_event` 表（词 + 文章 + 位置 + 时间），
  /// 本字段将成为它的投影。
  final List<ArticleLookup> lookups;

  const Article({
    required this.id,
    required this.category,
    required this.title,
    required this.source,
    this.paragraphs = const [],
    this.lookups = const [],
  });

  /// 正文是否已就绪。
  bool get hasBody => paragraphs.isNotEmpty;
}

/// 一条「查词事实」：某个词在这篇文章里被查过、复习到什么程度。
///
/// ⚠️ 注意 `reps` 的语义与 FSRS 一致：
/// - `reps = 0` → 刚查过（`fresh`）
/// - `reps = 1..2` → 复习中（`reviewing`）
/// - `reps >= 3 && lapses == 0` → **已掌握** → `forReps` 返回 `null` → **不标记**
///
/// 🔑 最后一条是白哥 2026-09-27 的决策（「已掌握就应该不标识」）——
/// 所以「已掌握」的词**仍然出现在这个列表里**（它是事实），
/// 只是渲染时不产生任何标记。数据与表现分离的好处正在这里。
class ArticleLookup {
  /// 词形（小写比较，匹配时大小写不敏感）。
  final String word;

  /// 复习次数。
  final int reps;

  /// 遗忘次数（> 0 则不算掌握）。
  final int lapses;

  const ArticleLookup(this.word, {this.reps = 0, this.lapses = 0});
}
