// CoEvo · 「读过的文章」仓储 —— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）
//    → 纯 Dart 才能本地独立验证（见 `scripts/query_verify/bin/verify_article_read.dart`）。
//
// # 它为什么存在（此前**完全没有数据源**）
//
// 「我的」页要显示「阅读篇数」，但实测：`user.db` 的 6 张表里
// **没有任何一张记录「读过哪篇文章」** —— `reader_screen.dart` 只在
// **划词查词**时写 `lookup_event`，**打开 / 读完文章不产生任何记录**。
// → 这不是「加个统计数字」，而是**新建数据源**。
// 📄 决策：`docs/design/profile-redesign-plan-2026-09-29.md` §七（白哥定口径**乙**）
//
// # 🔑 与 `BookmarkRepository` 的关系：**平行，且互补**
//
// `bookmark_repository.dart` 的类文档里有一条**刻意**的约束：
// > 「本仓储**只提供**『用户点了一下』这一个入口（`add` / `remove` / `toggle`）。
// >  **没有 `markRead`**、`autoBookmark`、`recordReadingTime` 之类的方法，
// >  也不接受『阅读进度』参数。**语义纯净靠接口形状保证，不靠注释提醒。**」
//
// 而设计稿那句是：「⚠️ **收藏 ≠ 已读标记**。收藏是用户主动的意图（「我还要再读」），
// 不是系统状态。」→ 两者是**不同的语义**，所以：
// | | 收藏 | 读过 |
// |---|---|---|
// | 语义 | 用户意图（**可撤销**：取消收藏） | 系统状态（**单调不可逆**：读过就是读过） |
// | 表 | `bookmark` | `article_read` |
// | 仓储 | `BookmarkRepository` | **本文件** |
// 🔑 **本仓储刻意没有 `unmarkRead` / `toggle`** —— 「取消读完」没有产品含义
//    （用户不可能「变回没读过」）。**这是有意为之，不是遗漏。**
//
// # 🔴 口径（白哥定「乙」）：**读完**才计数
// | 项 | 规则 |
// |---|---|
// | 判定 | **滚到底**（`extentAfter` ≤ 阈值）**且** 停留 ≥ 3s |
// | 去重 | `article_id` 去重（同一篇读两次算 1 篇）→ 主键天然去重 |
//
// ⚠️ **「滚到底」单条件不够** —— **短文章一屏就到底**，打开即「读完」。
//    所以那个「停留 ≥3s」是**必须的**，不是保险。
//    🔑 判定本身**不在本文件**（它在阅读页，且抽成了纯函数便于单测）；
//    本文件只负责「判定为真之后，把这件事实记下来」。

import 'package:sqflite_common/sqlite_api.dart';

/// 「读过的文章」仓储。
///
/// ## 与 `BookmarkRepository` 的一处**刻意不同**：不缓存到内存
///
/// `BookmarkRepository` 用了「全量载入 `Set<int>`」—— 因为它的读取形态是
/// **「这篇收藏了吗」× 每张卡片**（列表滚动时反复问），且要实时显示计数。
///
/// 本仓储的读取形态**完全不同**：
/// | 问题 | 频率 |
/// |---|---|
/// | 「读过几篇」 | **进「我的」页时一次**（且已由 `AchievementService.collectMetrics()` 统一采集） |
/// | 「这篇读过吗」 | **当前无此需求**（不做「已读」标记 —— 见下） |
///
/// → 缓存只会带来「跨写入点失效」的风险（`bookmark` 的类文档已如实记下这条代价），
///   而这里**没有任何高频读**需要它换。
///   🔑 判据：**按访问形态选数据结构**，不是「跟别的仓储保持一致」。
///
/// ## 🔴 有意**不做**「已读标记」（与设计稿一致）
/// 首页/列表**不显示**「已读 / 未读」→ 所以本仓储**不需要**「批量取已读集合」这类方法。
/// （`feed_card.dart` 注释也记着：已读未读标签「已在设计稿里作废」。）
/// → 若将来真要做，再加 `readIds()`；现在加就是**没有消费者的代码**。
class ArticleReadRepository {
  ArticleReadRepository(this._db);

  final Database _db;

  /// 标记「读完了这篇」。**幂等** —— 已记过则什么都不做。
  ///
  /// 返回 `true` = **本次真的新增了**（首次读完）。
  ///
  /// 🔑 **幂等而不是「刷新时间戳」** —— 与 `BookmarkRepository.add` 同一理由：
  /// `read_at` 表达「我什么时候**第一次**读完的」，重读不该把它改成「我什么时候又读了一遍」。
  /// 那会让这个字段的语义在两种含义间漂移（「首次」还是「最近」？）——**一处口径只能有一种含义**。
  ///
  /// ⚠️ 时间戳**由 DDL 的 DEFAULT 生成**（数据库时钟），不在 Dart 侧生成 ——
  /// 同 `bookmark`：避免「客户端时钟 / UTC 格式化写错时区」这类静默失真。
  ///
  /// # 🔴 为什么用**事务 + 显式查询**，而不是「看 `insert` 的返回值」
  ///
  /// 我**最初**写的是后者，依据是「`OR IGNORE` 冲突时 `insert` 返回 0」——
  /// **实测发现这个依据不成立**（见 `verify_article_read.dart` §【6】）：
  /// ```
  /// markRead(0)  → 插入**成功**，但 insert 返回 0（因为主键值就是 0）
  ///                → 被判成「不是新增」→ 🔴 误报
  /// markRead(42) → 冲突被忽略，insert 也返回 0
  ///                → 两种**完全不同**的情况无法区分
  /// ```
  /// 🔑 根因是**哨兵值冲突**：拿 `0` 当「失败」标记，而 `0` 是合法的 `article_id`。
  ///    （`article_id` 会不会是 0，取决于将来的真实数据源 —— **不该赌它不会**。）
  ///
  /// 也**不能**用 `SELECT changes()`：它是**连接级**的，并发交错时会读到**别人的**结果
  /// （A 插入成功 → B 插入被忽略 → A 读到 `changes()=0`）。
  ///
  /// → 用**写事务**：sqflite 对同一 `Database` 的 `transaction()` 是**串行**的，
  ///   所以「查 → 插」之间不会插入别人的写 → **既无 TOCTOU，也不依赖任何哨兵值**。
  ///   代价：每次多一条 `SELECT`。而本方法是**低频**的（读完一篇文章才一次）→ 可忽略。
  Future<bool> markRead(int articleId) async {
    return _db.transaction((txn) async {
      final exists = await txn.query(
        'article_read',
        columns: ['article_id'],
        where: 'article_id = ?',
        whereArgs: [articleId],
        limit: 1,
      );
      if (exists.isNotEmpty) return false;
      await txn.insert('article_read', {
        'article_id': articleId,
        // 不传 `read_at` / `pending_push` —— 由 DDL 的 DEFAULT 生成。
      });
      return true;
    });
  }

  /// 读过的篇数（= 「阅读篇数」的唯一口径）。
  ///
  /// 🔑 用 `COUNT(*)` 而不是维护一个计数字段：单用户量级极小（同 `bookmark` §四 ⑤），
  ///    而多加一个计数字段就多一处**可能与真实行数不一致**的状态。
  Future<int> countRead() async {
    final rows = await _db.rawQuery('SELECT count(*) AS n FROM article_read');
    return (rows.first['n'] as num).toInt();
  }

  /// 这篇文章是否**已记录为读完**。
  ///
  /// ⚠️ 当前**无调用方**（不做「已读」标记）。保留它是因为：
  /// ① 它是 `markRead` 的**对称读**，验证脚本要靠它断言幂等性；
  /// ② 它让「本仓储能回答关于单篇文章的问题」这一职责完整。
  /// 📌 若最终确认永不需要，应删掉（**零消费者的方法 = 死代码**）。
  Future<bool> hasRead(int articleId) async {
    final rows = await _db.query(
      'article_read',
      columns: ['article_id'],
      where: 'article_id = ?',
      whereArgs: [articleId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ───────────────────────────────────────────────────────────
  // 跨设备同步（2026-10-06 · 云端同步阶段 3）
  // ───────────────────────────────────────────────────────────

  /// 待同步的阅读记录（`pending_push = 1`），按 `read_at` 升序。
  ///
  /// 🔑 返回 **record** 而不是新造一个类：调用方（`sync_service`）只需要
  /// 「有什么要推」，而这个形状（id + 时间）恰好与后端 `ArticleReadInput` 同构
  /// ⇒ 不必为它维护一个只有两个字段的类（同 `fsrs_service.review()` 用 record 的理由）。
  Future<List<({int articleId, String readAt})>> pending() async {
    final rows = await _db.query(
      'article_read',
      columns: ['article_id', 'read_at'],
      where: 'pending_push = 1',
      orderBy: 'read_at ASC', // 按**发生顺序**推，便于服务端时间轴单调
    );
    return rows
        .map((r) => (
              articleId: (r['article_id'] as num).toInt(),
              readAt: r['read_at'] as String,
            ))
        .toList();
  }

  /// 标记已同步（push 成功后调用）。
  ///
  /// ⚠️ **只在 push 真正成功后才调** —— 否则「标记了但没推上去」= 数据永久不同步
  /// （且本地看不出来）。调用方 `sync_service` 把「成功」与「标记」绑在同一段里。
  Future<void> markSynced(Iterable<int> articleIds) async {
    final ids = articleIds.toList();
    if (ids.isEmpty) return;
    final ph = List.filled(ids.length, '?').join(',');
    await _db.update(
      'article_read',
      {'pending_push': 0},
      where: 'article_id IN ($ph)',
      whereArgs: ids,
    );
  }
}
