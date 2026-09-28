import '../models/feed_item.dart';

/// 🔴 **临时 mock 数据** —— 只在后端 RSS 抓取（Phase 3）落地前使用。
///
/// 三条内容逐字取自设计稿 `docs/design/visual-feed-bookmark-2026-09-25.html`
/// （信息流四屏对比里的示例卡片），**故意不自行编写** ——
/// 界面验收的标准是「长得对不对」，用设计稿原文比对才有效；
/// 自己编内容等于换了一把尺子。
///
/// 何时删：Phase 3 起来后，`home_screen` 改为从 feed 接口取数，本文件整体删除。
/// ⚠️ 不得在这里加业务逻辑（排序、筛选、个性化）—— 那些属于数据层，不属于 mock。
const List<FeedItem> mockFeedItems = [
  FeedItem(
    id: 1,
    category: 'Science',
    minutes: 4,
    title: 'A New Way to Grow Food in Cities',
    excerpt: 'In the middle of Singapore, a tall glass building produces more '
        'than 800 tons of vegetables every year. It has no soil, no sunlight, '
        'and almost no water.',
    source: 'VOA Learning English',
  ),
  FeedItem(
    id: 2,
    category: 'Culture',
    minutes: 6,
    title: 'Why We Sing Together',
    excerpt: 'Every human culture has music, and almost every one of them '
        'sings in groups. Researchers think this is not a coincidence.',
    source: 'VOA Learning English',
  ),
  FeedItem(
    id: 3,
    category: 'Business',
    minutes: 5,
    title: 'Why Small Shops Are Coming Back',
    excerpt: 'After years of decline, small local shops are opening again in '
        'many cities. The reasons are partly about money, and partly about '
        'something harder to measure.',
    source: 'VOA Learning English',
  ),
];
