// CoEvo · 成就体系 —— **纯规则层**（零 Flutter · 零 DB · 零 IO）
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包或 sqflite**
//   理由同 `user_db.dart` / `fsrs_service.dart`：本地 `flutter analyze` 会崩，
//   纯 Dart 才能独立验证。本文件是成就体系里**最该被断言的部分** ——
//   它决定「什么算解锁」，一旦错就是**静默给错成就**。
//
// # 依据
// · `docs/design/achievement-redesign-2026-09-29.md`（本方案的清单与口径）
// · `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §4.2/§6.1（成就并入「我的」页顶部）
// · `app/assets/sql/user_db_schema.sql`（端侧 5 表的权威定义）
//
// # 🔴🔴 三个口径决策（都**不是**照搬旧体系，各有理由 —— 别当成笔误改掉）
//
// ## ① 准确率 = `rating >= 2`（**不是** `rating >= 3`）
// 端侧 `review_log.rating`：1 忘了 / 2 困难 / 3 记得 / 4 熟练（FSRS 四档）。
// · 旧方案草稿写的是 `>= 3` —— 实施时**修正为 `>= 2`**。
// · 理由：**SRS 行业惯例**（Anki）的 accuracy = 「非 Again 占比」；
//   「困难」也是**成功回忆**，只是吃力。若按 `>= 3`，「困难」永远不算对 →
//   用户评「困难」时准确率反降，**与直觉相反**，且与 FSRS 的 lapse 语义不一致。
// · 📌 若将来想要更严格的「轻松回忆率」，应**另立一个指标**，不要改这个。
//
// ## ② 连续天数 / 时段统计用**本地时间**（**不是** `utc_day`）
// 🔴 `review_log.utc_day` 是 **UTC 日历日**，它是**多端同步的稳定键**（设计如此，不该改）。
// 但用它算 streak 会**错位**：北京 00:00–08:00 学习 → UTC 还在前一天 16:00–24:00
// → `utc_day` 记成**前一天** → streak 与实际体感不符。
// · 「连续天数」是**用户体感**概念（今晚学了就算今天）→ 必须按**本地日**。
// · 做法：读 `reviewed_at`（UTC ISO8601 带 `Z`）→ `toLocal()` → 取本地日。
// · `utc_day` **保持原用途不动**（同步幂等键）。
//
// ## ③ mature（掌握）判定 = `stability >= 21` 天
// FSRS 社区惯例：`stability`（稳定度，单位天）= 记忆保持 90% 的时长；
// 21 天是 SRS 界通用的「mature」门槛（Anki 同口径）。
// · 备选 `state == 2`（进入 review 阶段）**更宽松** —— 刚进 review 的卡也算「掌握」，
//   会虚高。已选 `stability`。

/// **图标名常量**（Material Icons 的名称）。
///
/// # 🔴 为什么要有这一层（不能直接在成就里写字符串）
/// `icon` 字段里写 `'whatshot'`，而 Flutter 侧 `achievement_icons.dart` 要把它映射成
/// `Icons.whatshot`。若把字符串**散落在各处**：
/// · 拼错一个字母（`'whatsot'`）→ 映射表查不到 → **静默显示默认图标**（不报错）
/// · 新增成就时忘记在映射表里加 → 同上
///
/// → 提到这里做**唯一来源**：
/// ① 本层（纯 Dart）可断言「每个成就的 icon 都在 `all` 里」
/// ② Flutter 侧的映射表可直接对着 `all` 写，并可断言「全覆盖」
///
/// ⚠️ **`all` 必须与 `achievement_icons.dart` 的映射键一一对应** ——
///    守护断言见 `scripts/query_verify/bin/verify_achievement_rules.dart`【6】。
abstract final class AchievementIcons {
  // 坚持
  static const String whatshot = 'whatshot';
  static const String fireDepartment = 'local_fire_department';
  static const String selfImprovement = 'self_improvement';
  static const String trendingUp = 'trending_up';
  // 阅读
  static const String search = 'search';
  static const String autoStories = 'auto_stories';
  static const String libraryBooks = 'library_books';
  static const String bolt = 'bolt';
  // 生词
  static const String bookmarkAdd = 'bookmark_add';
  static const String collectionsBookmark = 'collections_bookmark';
  static const String accountBalance = 'account_balance';
  // 复习
  static const String checkCircle = 'check_circle';
  static const String replay = 'replay';
  static const String allInclusive = 'all_inclusive';
  static const String nature = 'nature';
  static const String school = 'school';
  static const String verified = 'verified';
  // 特殊
  static const String nightlight = 'nightlight';
  static const String wbSunny = 'wb_sunny';
  static const String restartAlt = 'restart_alt';
  // 分类
  static const String menuBook = 'menu_book';
  static const String taskAlt = 'task_alt';
  static const String autoAwesome = 'auto_awesome';

  /// 全部图标名（成就 + 分类）—— Flutter 侧映射表必须覆盖它。
  static const List<String> all = [
    whatshot, fireDepartment, selfImprovement, trendingUp,
    search, autoStories, libraryBooks, bolt,
    bookmarkAdd, collectionsBookmark, accountBalance,
    checkCircle, replay, allInclusive, nature, school, verified,
    nightlight, wbSunny, restartAlt,
    menuBook, taskAlt, autoAwesome,
  ];
}

/// 成就分类（决定「成就墙」上的分组）。
enum AchievementCategory {
  /// 🔥 坚持 —— 连续学习
  streak,

  /// 📖 阅读 —— 划词查词（**本产品的核心行为**，旧体系没有这一组）
  reading,

  /// 📚 生词 —— 生词本积累
  words,

  /// 🎯 复习 —— 复习量 / 掌握度 / 准确率
  review,

  /// ⭐ 特殊 —— 隐藏触发（时段 / 归来）
  special,
}

/// 分类的展示信息（名称 + 图标名）。
///
/// 🔑 图标只存**字符串名**，由 UI 层映射成 `IconData` ——
/// 本文件因此不依赖 Flutter（见文件头约束）。
class CategoryMeta {
  final AchievementCategory category;
  final String label;
  final String icon;

  const CategoryMeta({
    required this.category,
    required this.label,
    required this.icon,
  });
}

const List<CategoryMeta> kCategoryMeta = [
  CategoryMeta(category: AchievementCategory.streak, label: '坚持', icon: AchievementIcons.fireDepartment),
  CategoryMeta(category: AchievementCategory.reading, label: '阅读', icon: AchievementIcons.menuBook),
  CategoryMeta(category: AchievementCategory.words, label: '生词', icon: AchievementIcons.collectionsBookmark),
  CategoryMeta(category: AchievementCategory.review, label: '复习', icon: AchievementIcons.taskAlt),
  CategoryMeta(category: AchievementCategory.special, label: '特殊', icon: AchievementIcons.autoAwesome),
];

/// 成就档位（决定徽章的色环）。
enum AchievementTier { bronze, silver, gold, platinum, diamond }

/// 一个成就的定义。
///
/// 🔑 条件只有一个维度（`metric` + `threshold`），不做 AND/OR 表达式 ——
/// 旧体系的 TOML 支持多条件组合，但**实际用到的组合只有 1 处**，
/// 为它维护一个条件引擎不值得（「没有依据的复杂度」）。
class AchievementDef {
  /// 稳定标识 —— **一旦发布不可改**（它是解锁表的主键，改了 = 用户记录对不上）。
  final String key;

  /// 中文名（本产品仅中文界面，不做 i18n）。
  final String name;

  /// 一句话描述（说明「怎么达成」）。
  final String description;

  final AchievementCategory category;
  final AchievementTier tier;

  /// Material Icons 名称（由 UI 层映射）。
  final String icon;

  /// 指标键 —— 见 `AchievementMetrics` 的常量。
  final String metric;

  /// 阈值：`metric >= threshold` 即解锁。
  final num threshold;

  const AchievementDef({
    required this.key,
    required this.name,
    required this.description,
    required this.category,
    required this.tier,
    required this.icon,
    required this.metric,
    required this.threshold,
  });
}

/// 指标键常量。
///
/// 🔑 用常量而不是字符串字面量：**采集端（SQL）与判定端（规则）必须同名**，
/// 拼错一个字就是「指标恒为 0 → 成就永远不解锁」的**静默失败**。
abstract final class AchievementMetrics {
  /// 连续学习天数（**本地日**口径 · 见文件头 ②）。
  static const String streakDays = 'streak_days';

  /// 历史最长中断天数（相邻学习日的最大间隔）—— 供「重拾」用。
  static const String maxGapDays = 'max_gap_days';

  /// 累计查词次数（`lookup_event` 行数）。
  static const String lookupCount = 'lookup_count';

  /// **1 小时内最多查了多少个不同的词**（滑动窗口）。
  static const String lookupsIn1h = 'lookups_in_1h';

  /// 生词本词数（`user_word WHERE deleted = 0`）。
  static const String totalWords = 'total_words';

  /// 累计复习次数（`review_log` 行数）。
  static const String totalReviews = 'total_reviews';

  /// 已掌握词数（`card_review_state.stability >= 21`）。
  static const String matureCards = 'mature_cards';

  /// 🆕 读过的文章数（`article_read` 行数 —— 「阅读篇数」的数据源）。
  ///
  /// # 🔑 它**不驱动任何成就**（有意如此）
  ///
  /// 加进本类是因为：本类实际是「**用户统计指标**」的集合 ——
  /// 成就只是它的**一个**消费者（`AchievementSection` 与分享文案也读它）。
  /// 「我的」页顶部三个数字（连续天数 / 掌握词数 / 阅读篇数）**同源**于此，
  /// 从一次 `collectMetrics()` 拿 → 避免「两次查询、两个数据源」的分叉。
  ///
  /// ⚠️ 若将来真要给它挂成就（如「读完 50 篇」），直接加条目即可 ——
  /// `verify_achievement_rules.dart` 的断言是**单向**的（成就 → `all`），
  /// 所以「`all` 里有未被引用的指标」**不会**让断言失败。
  ///
  /// 口径：**读完**（滚到底 **且** 停留 ≥3s）· `article_id` 去重
  /// → 判定在阅读页（纯函数），记录在 `ArticleReadRepository`。
  static const String articlesRead = 'articles_read';

  /// 最近 50 次复习的准确率（百分数 · `rating >= 2` 占比 · 见文件头 ①）。
  ///
  /// ⚠️ 复习不足 50 次时 = 按**已有次数**算占比（不是 0）——
  /// 否则新用户永远看不到进度。由采集端负责（`_accuracyRecent`）。
  static const String recentAccuracy50 = 'recent_accuracy_50';

  /// 22:00–02:00（**本地时间**）的复习次数。
  static const String nightSessions = 'night_sessions';

  /// 06:00–08:00（**本地时间**）的复习次数。
  static const String earlySessions = 'early_sessions';

  /// 全部指标键（供断言「采集端与规则端同名」用）。
  static const List<String> all = [
    streakDays, maxGapDays, lookupCount, lookupsIn1h, totalWords,
    totalReviews, matureCards, articlesRead, recentAccuracy50,
    nightSessions, earlySessions,
  ];
}

/// **成就清单**（本方案的唯一真理源）。
///
/// 设计原则（见方案 §三）：
/// ① 只挂**产品真实存在**的行为（阅读 → 划词 → 生词 → 复习）
/// ② 指标**端侧可算**（不依赖后端 —— 后端旧学习链已退役）
/// ③ 每个分类**有明确终局**（不让用户永远看不到头）
///
/// ⚠️ **不要**把「已退役功能」的成就加回来（对话 / K12 plan / 多学科领域）——
/// 那些行为在本产品里不存在（见方案 §二）。
const List<AchievementDef> kAchievements = [
  // ── 🔥 坚持 ──────────────────────────────────────────────
  AchievementDef(
    key: 'streak_3',
    name: '起步',
    description: '连续 3 天学习',
    category: AchievementCategory.streak,
    tier: AchievementTier.bronze,
    icon: AchievementIcons.whatshot,
    metric: AchievementMetrics.streakDays,
    threshold: 3,
  ),
  AchievementDef(
    key: 'streak_7',
    name: '一周达人',
    description: '连续 7 天学习',
    category: AchievementCategory.streak,
    tier: AchievementTier.silver,
    icon: AchievementIcons.fireDepartment,
    metric: AchievementMetrics.streakDays,
    threshold: 7,
  ),
  AchievementDef(
    key: 'streak_30',
    name: '月度学者',
    description: '连续 30 天学习',
    category: AchievementCategory.streak,
    tier: AchievementTier.gold,
    icon: AchievementIcons.selfImprovement,
    metric: AchievementMetrics.streakDays,
    threshold: 30,
  ),
  AchievementDef(
    key: 'streak_100',
    name: '百日毅力',
    description: '连续 100 天学习',
    category: AchievementCategory.streak,
    tier: AchievementTier.platinum,
    icon: AchievementIcons.trendingUp,
    metric: AchievementMetrics.streakDays,
    threshold: 100,
  ),

  // ── 📖 阅读（划词 = 本产品的核心行为）────────────────────
  AchievementDef(
    key: 'first_lookup',
    name: '初次划词',
    description: '查第一个词',
    category: AchievementCategory.reading,
    tier: AchievementTier.bronze,
    icon: AchievementIcons.search,
    metric: AchievementMetrics.lookupCount,
    threshold: 1,
  ),
  AchievementDef(
    key: 'lookup_100',
    name: '常读者',
    description: '累计查词 100 次',
    category: AchievementCategory.reading,
    tier: AchievementTier.silver,
    icon: AchievementIcons.autoStories,
    metric: AchievementMetrics.lookupCount,
    threshold: 100,
  ),
  AchievementDef(
    key: 'lookup_1000',
    name: '博览',
    description: '累计查词 1000 次',
    category: AchievementCategory.reading,
    tier: AchievementTier.gold,
    icon: AchievementIcons.libraryBooks,
    metric: AchievementMetrics.lookupCount,
    threshold: 1000,
  ),
  AchievementDef(
    key: 'immersive_20',
    name: '沉浸阅读',
    description: '1 小时内查 20 个词',
    category: AchievementCategory.reading,
    tier: AchievementTier.silver,
    icon: AchievementIcons.bolt,
    metric: AchievementMetrics.lookupsIn1h,
    threshold: 20,
  ),

  // ── 📚 生词 ──────────────────────────────────────────────
  AchievementDef(
    key: 'words_10',
    name: '开始积累',
    description: '生词本达到 10 词',
    category: AchievementCategory.words,
    tier: AchievementTier.bronze,
    icon: AchievementIcons.bookmarkAdd,
    metric: AchievementMetrics.totalWords,
    threshold: 10,
  ),
  AchievementDef(
    key: 'words_50',
    name: '小词库',
    description: '生词本达到 50 词',
    category: AchievementCategory.words,
    tier: AchievementTier.silver,
    icon: AchievementIcons.collectionsBookmark,
    metric: AchievementMetrics.totalWords,
    threshold: 50,
  ),
  AchievementDef(
    key: 'words_200',
    name: '满额',
    description: '生词本达到 200 词（免费层上限）',
    category: AchievementCategory.words,
    tier: AchievementTier.gold,
    icon: AchievementIcons.accountBalance,
    metric: AchievementMetrics.totalWords,
    threshold: 200,
  ),

  // ── 🎯 复习 ──────────────────────────────────────────────
  AchievementDef(
    key: 'first_review',
    name: '首次复习',
    description: '完成第一次复习',
    category: AchievementCategory.review,
    tier: AchievementTier.bronze,
    icon: AchievementIcons.checkCircle,
    metric: AchievementMetrics.totalReviews,
    threshold: 1,
  ),
  AchievementDef(
    key: 'reviews_100',
    name: '百炼',
    description: '累计复习 100 次',
    category: AchievementCategory.review,
    tier: AchievementTier.silver,
    icon: AchievementIcons.replay,
    metric: AchievementMetrics.totalReviews,
    threshold: 100,
  ),
  AchievementDef(
    key: 'reviews_1000',
    name: '千锤',
    description: '累计复习 1000 次',
    category: AchievementCategory.review,
    tier: AchievementTier.gold,
    icon: AchievementIcons.allInclusive,
    metric: AchievementMetrics.totalReviews,
    threshold: 1000,
  ),
  AchievementDef(
    key: 'mature_50',
    name: '掌握 50 词',
    description: '50 个词进入长期记忆',
    category: AchievementCategory.review,
    tier: AchievementTier.gold,
    icon: AchievementIcons.nature,
    metric: AchievementMetrics.matureCards,
    threshold: 50,
  ),
  AchievementDef(
    key: 'mature_200',
    name: '掌握 200 词',
    description: '200 个词进入长期记忆',
    category: AchievementCategory.review,
    tier: AchievementTier.platinum,
    icon: AchievementIcons.school,
    metric: AchievementMetrics.matureCards,
    threshold: 200,
  ),
  AchievementDef(
    key: 'accuracy_90',
    name: '精准',
    description: '最近 50 次复习准确率 ≥ 90%',
    category: AchievementCategory.review,
    tier: AchievementTier.gold,
    icon: AchievementIcons.verified,
    metric: AchievementMetrics.recentAccuracy50,
    threshold: 90,
  ),

  // ── ⭐ 特殊 ──────────────────────────────────────────────
  AchievementDef(
    key: 'night_owl',
    name: '深夜灯',
    description: '22:00–02:00 学习 5 次',
    category: AchievementCategory.special,
    tier: AchievementTier.silver,
    icon: AchievementIcons.nightlight,
    metric: AchievementMetrics.nightSessions,
    threshold: 5,
  ),
  AchievementDef(
    key: 'early_bird',
    name: '早起鸟',
    description: '06:00–08:00 学习 5 次',
    category: AchievementCategory.special,
    tier: AchievementTier.silver,
    icon: AchievementIcons.wbSunny,
    metric: AchievementMetrics.earlySessions,
    threshold: 5,
  ),
  AchievementDef(
    key: 'comeback',
    name: '重拾',
    description: '中断 30 天后重新开始学习',
    category: AchievementCategory.special,
    tier: AchievementTier.gold,
    icon: AchievementIcons.restartAlt,
    metric: AchievementMetrics.maxGapDays,
    threshold: 30,
  ),
];

// ══════════════════════════════════════════════════════════════
// 纯计算（**无 DB · 无 IO** —— 这几条是断言的重点）
// ══════════════════════════════════════════════════════════════

/// 从「有学习记录的本地日」列表算出**当前连续天数**。
///
/// [localDays]：复习发生的**本地日期**（可重复、可乱序 —— 本函数自己去重排序）。
/// [nowLocal]：当前**本地时间**（用于判断「今天/昨天有没有学」）。
///
/// # 口径（三条，都会在断言里锁住）
/// ① **只算到「今天」或「昨天」为止**：今天还没学但昨天学了 → 连续**未断**（仍显示 N）；
///    若最后一天早于昨天 → 已断 → 返回 **0**。
///    （理由：用户晚上看 streak 时不该因为「今天还没开始学」就清零 —— 那会让激励变成惩罚。）
/// ② 同日多次只算一天（按日去重）。
/// ③ 从最后一天往前逐日回溯，遇到缺口即停。
int computeStreakDays(List<DateTime> localDays, DateTime nowLocal) {
  if (localDays.isEmpty) return 0;

  // 归一到「日」（丢弃时分秒）并去重
  final days = localDays.map(_dayOnly).toSet().toList()..sort();
  final today = _dayOnly(nowLocal);
  final last = days.last;

  // ① 最后学习日必须是「今天」或「昨天」，否则已断
  final gapFromToday = today.difference(last).inDays;
  if (gapFromToday > 1) return 0;

  var streak = 1;
  for (var i = days.length - 1; i > 0; i--) {
    final diff = days[i].difference(days[i - 1]).inDays;
    if (diff == 1) {
      streak++;
    } else {
      break; // 缺口 → 连续中断，停止回溯
    }
  }
  return streak;
}

/// 历史**最长中断天数**（相邻学习日之间的最大间隔）。
///
/// 供「重拾」成就用 —— 语义是「曾经断过很久，后来回来了」。
/// · 少于 2 个学习日 → 0（没有间隔可言）
/// · 只统计**相邻两个学习日之间**的间隔，不看「从最后一天到今天」
///   （后者是「正在断」，不是「断了又回来」）
int computeMaxGapDays(List<DateTime> localDays) {
  if (localDays.length < 2) return 0;
  final days = localDays.map(_dayOnly).toSet().toList()..sort();
  var maxGap = 0;
  for (var i = 1; i < days.length; i++) {
    final gap = days[i].difference(days[i - 1]).inDays - 1; // 中间空了几整天
    if (gap > maxGap) maxGap = gap;
  }
  return maxGap;
}

/// 「1 小时内查了多少个**不同**的词」的最大值（滑动窗口）。
///
/// [lookupTimes]：每次查词的时间（**本地**）。
/// · 只数**不同词**（同一个词查 5 遍算 1 个）——「沉浸阅读」衡量的是阅读广度。
/// · 窗口为**左闭右开**的 1 小时：`[t, t + 1h)`。
int computeMaxLookupsIn1h(List<DateTime> lookupTimes) {
  if (lookupTimes.isEmpty) return 0;
  final times = [...lookupTimes]..sort();
  var best = 0;
  var left = 0;
  for (var right = 0; right < times.length; right++) {
    while (times[right].difference(times[left]).inMinutes >= 60) {
      left++;
    }
    final count = right - left + 1;
    if (count > best) best = count;
  }
  return best;
}

/// **判定：给定指标快照，返回已达成条件的成就 key 集合**（核心纯函数）。
///
/// · 输入缺失某个指标 → 该指标按 **0** 处理（缺 = 还没开始做）
/// · 只做机械比较 `metric >= threshold` —— **不查库、不读时间**
Set<String> evaluateAchievements(Map<String, num> metrics) {
  final unlocked = <String>{};
  for (final def in kAchievements) {
    final value = metrics[def.metric] ?? 0;
    if (value >= def.threshold) unlocked.add(def.key);
  }
  return unlocked;
}

/// 单个成就的**进度**（0.0 ~ 1.0），供进度条用。
double achievementProgress(AchievementDef def, Map<String, num> metrics) {
  final value = metrics[def.metric] ?? 0;
  if (def.threshold <= 0) return 1.0;
  final ratio = value / def.threshold;
  return ratio.clamp(0.0, 1.0).toDouble();
}

/// 进度文案（「3/7」这种），供成就墙显示。
String achievementProgressLabel(AchievementDef def, Map<String, num> metrics) {
  final value = (metrics[def.metric] ?? 0).toInt();
  final target = def.threshold.toInt();
  final shown = value > target ? target : value;
  return '$shown/$target';
}

/// 按分类分组（保留 `kAchievements` 的声明顺序，**不排序** —— 顺序即设计）。
List<AchievementDef> achievementsInCategory(AchievementCategory c) =>
    kAchievements.where((d) => d.category == c).toList(growable: false);

/// 丢掉时分秒，只留日期（本地）。
///
/// 🔑 必须用 `DateTime(y, m, d)` 构造而不是 `subtract(Duration)` ——
/// 后者按**绝对时长**运算，跨夏令时会得到「23 小时」这类结果，
/// 让 `difference(...).inDays` 变成 0 → streak 静默算错。
/// （中国无夏令时，但这条不该依赖地域假设。）
DateTime _dayOnly(DateTime t) => DateTime(t.year, t.month, t.day);
