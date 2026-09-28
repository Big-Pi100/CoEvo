import '../models/article.dart';

/// 🔴 **临时 mock 正文** —— 只在后端内容抓取（Phase 3）落地前使用。
///
/// # 为什么只有第一篇有正文
/// 设计稿 `docs/design/visual-feed-bookmark-2026-09-25.html` 的「阅读界面」一格
/// **只给了第一篇文章的完整正文**（三段），另外两篇全文在文档里不存在。
///
/// 🔑 所以我**没有自行编写**后两篇 —— 与 `mock_feed.dart` 同一条原则：
/// 自己编内容等于换一把尺子。后两篇保持 `paragraphs: []`，
/// 阅读器对「正文未就绪」给出明确占位（**这本身也是一条要验证的路径**：
/// 不能白屏 —— 白屏用户只会以为 App 坏了）。
///
/// # 痕迹（`lookups`）的取值依据
/// 逐条对应设计稿正文里的 `<span class="tk tk-*">`：
///
/// | 词 | 设计稿的类 | reps | 渲染结果 |
/// |---|---|---|---|
/// | `produces` | `tk-d`（已掌握） | 5 | 🔴 **不标记**（2026-09-27 白哥定） |
/// | `Instead` | `tk-m`（复习中） | 1 | 复习中样式 |
/// | `liquid` | `tk-m`（复习中） | 2 | 复习中样式 |
/// | `vertical` | `tk-n`（刚查过） | 0 | 刚查过样式 |
/// | `traditional` | `tk-d`（已掌握） | 4 | 🔴 **不标记** |
/// | `kilometres` | `tk-d`（已掌握） | 3 | 🔴 **不标记** |
///
/// ⚠️ 注意 `produces` / `traditional` / `kilometres` **仍在 lookups 里** ——
/// 它们是**事实**（用户确实查过、已掌握），只是渲染层不产生标记。
/// 数据与表现分离：将来若要统计「已掌握词数」，这几个不能丢。
///
/// 何时删：Phase 3 内容抓取起来后，`reader_screen` 改为按 id 取正文，本文件整体删除。
const List<Article> mockArticles = [
  Article(
    id: 1,
    category: 'Science',
    title: 'A New Way to Grow Food in Cities',
    source: 'VOA Learning English',
    paragraphs: [
      'In the middle of Singapore, a tall glass building produces more than '
          '800 tons of vegetables every year. It has no soil, no sunlight, and '
          'almost no water. Instead, the plants grow in a special liquid, and '
          'pink lights help them grow faster.',
      'This type of farming is called vertical farming. It uses 95% less water '
          'than traditional farms, and because the building is in the city, '
          'the food travels only a few kilometres to reach shops.',
      'Shoppers say the vegetables taste better than those shipped from far '
          'away.',
    ],
    lookups: [
      ArticleLookup('produces', reps: 5), // 已掌握 → 不标识
      ArticleLookup('Instead', reps: 1),
      ArticleLookup('liquid', reps: 2),
      ArticleLookup('vertical', reps: 0),
      ArticleLookup('traditional', reps: 4), // 已掌握 → 不标识
      ArticleLookup('kilometres', reps: 3), // 已掌握 → 不标识
    ],
  ),

  // 后两篇：全文在设计稿里不存在 → 正文未就绪（阅读器显示占位）
  Article(
    id: 2,
    category: 'Culture',
    title: 'Why We Sing Together',
    source: 'VOA Learning English',
  ),
  Article(
    id: 3,
    category: 'Business',
    title: 'Why Small Shops Are Coming Back',
    source: 'VOA Learning English',
  ),
];

/// 按 id 取文章（信息流卡片 → 阅读器）。
///
/// 返回 `null` = 该 id 没有正文 —— 调用方据此决定「进阅读器」还是「提示不可读」。
/// 🔑 刻意不返回一个「空文章」对象：那会让调用方分不清
/// 「文章存在但没有正文」与「这个 id 根本不存在」。
Article? mockArticleById(int id) {
  for (final a in mockArticles) {
    if (a.id == id) return a;
  }
  return null;
}
