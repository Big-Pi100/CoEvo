// CoEvo · 云端同步的**编排层** —— pull / push 一次到底发生了什么
//
// 🔴 设计约束：本文件**不 import 任何 Flutter 包**。
//   理由（同 `sync_merge.dart` / `reading_completion.dart`）：
//   本机 `flutter` 跑不起来 ⇒ 只有**纯 Dart** 才能在本地独立验证。
//   ⇒ 于是 HTTP 与「游标读写」都**依赖注入**（见下面的 typedef），
//     测试可以塞一个**假 client**（记录收到的 body、返回构造好的响应）
//     + 一个**内存 sqlite 库**，把整条编排链跑一遍。
//   📌 这是 skill `verifiable-core-logic` 的直接应用：**把 IO 推到边界，逻辑留在中间**。
//
// # 它负责什么（以及**不**负责什么）
//
// | 层 | 文件 | 职责 |
// |---|---|---|
// | HTTP | `api/sync_client.dart` | 拼 URL / header / 解 JSON（**有 Flutter 依赖**，不在这里）|
// | **编排** | **本文件** | 收集待推 → 调 client → 合并 → 写库 → 推进游标 |
// | 合并口径 | `sync_merge.dart` | 「两个值 → 一个权威值」（纯函数）|
// | 数据层 | 各 repository | 表的读写 |
//
// # 🔴 三张表的分工（这是理解本文件的关键）
//
// | 表 | 同步角色 |
// |---|---|
// | `review_log` | **唯一真相源**（事件流）⇒ push 它、pull 它 |
// | `card_review_state` | **派生值**（重放 `review_log` 得到）⇒ **不参与同步**，由本文件在 pull 后**重算** |
// | `user_word` / `article_read` / `bookmark` / `book_progress` | 资产 ⇒ 字段级合并 |
//
// 🔑 为什么 `card_review_state` 不直接同步：它是 `review_log` 的函数值。
//    直接同步它会在冲突时**丢一次复习** —— 而那次复习的记忆增益**永久消失**
//    （设计 §三 原话）。⇒ 同步事件、派生状态。
//    ⚠️ 连带推论：`card_review_state.pending_push` **不是 push 的依据** ——
//       push 的依据是 `review_log.synced`。本文件写 state 时恒置 0（且已核实
//       UI 层**无人读**该列，它是 Step 3 时代的遗留设计）。
//
// # 🔴 顺序：先 push 再 pull（不是反过来）
//
// | 顺序 | 结果 |
// |---|---|
// | **push → pull** ✅ | 先把本地改动送上去，再取别端的 ⇒ 结束时本地是**权威值且无待推** |
// | pull → push ❌ | 合并后的行可能带「待推」⇒ 紧接着要再 push 一次（多一轮） |
//
// 两者最终都收敛，但前者少一轮往返、且中间态更干净。
//
// # ⚠️ 失败处理：**不抛异常给 UI**
//
// 同步是**后台行为** —— 失败不能打断用户正在做的事（读文章 / 复习）。
// ⇒ 所有失败收敛成 `SyncReport(ok: false, error: ...)`，由调用方决定
//   「记日志 / 下次重试」，**不抛**。
// ⚠️ 与「静默失败」的区别：本文件**如实留下 error 与计数**，
//    不是吞掉 —— 吞掉才是静默失败（本项目的主要敌人）。
//
// 📄 设计依据：`docs/design/sync-implementation-assessment-2026-10-04.md` §3 / §4.5

import 'package:sqflite_common/sqlite_api.dart';

import 'article_read_repository.dart';
import 'bookmark_repository.dart';
import 'ebook/book_progress_sync.dart';
import 'fsrs_service.dart';
import 'review_list_query.dart';
import 'sync_merge.dart' as m;
import 'user_word_repository.dart';

/// 推送（**依赖注入** —— 让本文件能脱离 `http` 包独立验证）。
typedef SyncPushHttp = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> body);

/// 拉取。`since == null` = 首次同步（拉全部）。
typedef SyncPullHttp = Future<Map<String, dynamic>> Function({
  String? since,
  String? deviceId,
});

/// 日志出口（注入 —— 避免 import `dart:developer` 之外的任何东西）。
typedef SyncLog = void Function(String message);

/// 一次同步（push 或 pull）的结果。
///
/// 🔑 **计数而不是布尔**：出问题时第一个想知道的是「推到哪一步了」
///    （0 条 vs 800 条，含义完全不同）。布尔会把这两个情形说成同一句话。
class SyncReport {
  SyncReport();

  /// 本次成功**推上去**的条数（按表分）。
  int pushedReviewEvents = 0;
  int pushedUserWords = 0;
  int pushedArticleReads = 0;
  int pushedBookmarks = 0;
  int pushedBookProgress = 0;

  /// 本次**认领**（把「别端的电子书进度」应用到本地已导入的书）的本数。
  ///
  /// 🔑 单列而不是并进 `pulledBookProgress`：后者是「交换区写入数」，
  ///    这个是「**真正生效**的书数」。两者不等是正常的（书还没导入时后者 > 0、前者 = 0）。
  int claimedBooks = 0;

  /// 本次**拉回来并写入本地**的条数（按表分）。
  int pulledReviewEvents = 0;
  int pulledUserWords = 0;
  int pulledArticleReads = 0;
  int pulledBookmarks = 0;
  int pulledBookProgress = 0;

  /// 是否成功。`false` 时 [error] 一定有值。
  bool ok = true;
  String? error;

  int get pushedTotal =>
      pushedReviewEvents +
      pushedUserWords +
      pushedArticleReads +
      pushedBookmarks +
      pushedBookProgress;

  int get pulledTotal =>
      pulledReviewEvents +
      pulledUserWords +
      pulledArticleReads +
      pulledBookmarks +
      pulledBookProgress;

  /// 本次**什么都没做**（无待推 + 无新拉）。
  ///
  /// 🔑 存在的理由：调用方可据此**跳过日志与 UI 提示** ——
  ///    「同步了 0 条」不值得打扰用户，但「同步了 12 条」可能值得（或值得记一行）。
  bool get isEmpty => pushedTotal == 0 && pulledTotal == 0;

  @override
  String toString() => ok
      ? 'SyncReport(推 $pushedTotal: 复习$pushedReviewEvents 词$pushedUserWords '
          '读$pushedArticleReads 藏$pushedBookmarks 书$pushedBookProgress | '
          '拉 $pulledTotal${claimedBooks > 0 ? ' 认领书$claimedBooks' : ''})'
      : 'SyncReport(失败: $error)';
}

/// 同步编排器。
///
/// 用法（UI 层）：
/// ```dart
/// final sync = SyncService(
///   userDb: await ref.read(userDbProvider.future),
///   bookDb: bookDbOrNull,
///   pushHttp: (body) => client.push(body, token: token),
///   pullHttp: ({since, deviceId}) => client.pull(token: token, since: since, deviceId: deviceId),
///   readCursor: () async => prefs.getString('sync_since'),
///   writeCursor: (s) async => prefs.setString('sync_since', s),
///   deviceId: await DeviceId.get(),
/// );
/// final report = await sync.syncNow();
/// ```
class SyncService {
  SyncService({
    required Database userDb,
    Database? bookDb,
    required SyncPushHttp pushHttp,
    required SyncPullHttp pullHttp,
    required Future<String?> Function() readCursor,
    required Future<void> Function(String since) writeCursor,
    required String deviceId,
    SyncLog? log,
    FsrsService? fsrs,
  })  : _userDb = userDb,
        _bookDb = bookDb,
        _pushHttp = pushHttp,
        _pullHttp = pullHttp,
        _readCursor = readCursor,
        _writeCursor = writeCursor,
        _deviceId = deviceId,
        _log = log,
        _fsrs = fsrs ?? FsrsService();

  final Database _userDb;

  /// 电子书库。**可空** —— 打不开时只跳过电子书进度，其余四类照常同步
  /// （同 `bookmark_provider` 的既有约定：库不可用**不阻塞**其它功能）。
  final Database? _bookDb;

  final SyncPushHttp _pushHttp;
  final SyncPullHttp _pullHttp;
  final Future<String?> Function() _readCursor;
  final Future<void> Function(String since) _writeCursor;
  final String _deviceId;
  final SyncLog? _log;
  final FsrsService _fsrs;

  void _say(String msg) => _log?.call(msg);

  // ════════════════════════════════════════════════════════════
  // 对外入口
  // ════════════════════════════════════════════════════════════

  /// **一次完整同步**：先 push（送本地改动上去），再 pull（取别端改动）。
  ///
  /// 用于：登录成功 · 手动同步 · 启动时。
  ///
  /// ⚠️ **不抛异常**（见文件头「失败处理」）。两个阶段各自独立记 ok，
  ///    最终 `ok` = 两个都成功；但**一个失败不影响另一个执行**
  ///    （push 失败仍要 pull —— 那能拿到别端数据，对用户是有价值的一半）。
  Future<SyncReport> syncNow() async {
    final pushReport = await pushOnce();
    final pullReport = await pullOnce();
    return SyncReport()
      ..pushedReviewEvents = pushReport.pushedReviewEvents
      ..pushedUserWords = pushReport.pushedUserWords
      ..pushedArticleReads = pushReport.pushedArticleReads
      ..pushedBookmarks = pushReport.pushedBookmarks
      ..pushedBookProgress = pushReport.pushedBookProgress
      ..pulledReviewEvents = pullReport.pulledReviewEvents
      ..pulledUserWords = pullReport.pulledUserWords
      ..pulledArticleReads = pullReport.pulledArticleReads
      ..pulledBookmarks = pullReport.pulledBookmarks
      ..pulledBookProgress = pullReport.pulledBookProgress
      ..claimedBooks = pullReport.claimedBooks
      ..ok = pushReport.ok && pullReport.ok
      ..error = pushReport.error ?? pullReport.error;
  }

  /// **退出登录前**调用：把待推数据送上去。
  ///
  /// 🔴 **必须在清凭据之前**（设计 §4.5 原话）——
  ///    否则「本地写了但没推」的那批数据要等**下次登录**才上去，
  ///    而用户可能永远不再登录（或换账号 ⇒ 那批数据**永久留在本地**）。
  ///    ⚠️ 这也是本方法**只 push 不 pull** 的原因：登出前的最后一件事是
  ///       「别丢东西」，不是「取新东西」（取新的登录后马上会做）。
  ///
  /// ⚠️ 调用方**不要**因为失败就阻止登出 —— 那会把用户**困在账号里**
  ///    （比丢几个待推数据更糟）。如实记日志即可。
  Future<SyncReport> flushBeforeLogout() => pushOnce();

  // ════════════════════════════════════════════════════════════
  // push
  // ════════════════════════════════════════════════════════════

  /// 收集各类待推数据 → 推上去 → **成功后**标记已同步。
  Future<SyncReport> pushOnce() async {
    final r = SyncReport();
    try {
      final q = ReviewListQuery(_userDb);
      final uw = UserWordRepository(_userDb);
      final ar = ArticleReadRepository(_userDb);
      final bm = BookmarkRepository(_userDb);

      final reviews = await q.pendingReviews();
      final words = await uw.pending();
      final reads = await ar.pending();
      final marks = await bm.pending();
      final progress = await _pendingBookProgress();

      r.pushedReviewEvents = reviews.length;
      r.pushedUserWords = words.length;
      r.pushedArticleReads = reads.length;
      r.pushedBookmarks = marks.length;
      r.pushedBookProgress = progress.length;

      // 🔑 **空批次不发请求** —— 一次网络往返有成本（电量/流量/延迟），
      //    而「什么都没变」是最常见的情形（用户刚打开 App）。
      if (r.pushedTotal == 0) {
        _say('sync.push: 无待推数据，跳过');
        return r;
      }

      await _pushHttp(_buildPushBody(
        reviews: reviews.map((e) => e.event).toList(),
        words: words,
        reads: reads,
        marks: marks,
        progress: progress,
      ));

      // ── 只有 **push 成功** 才标记（失败则不标记 ⇒ 下次重试）──
      await q.markReviewsSynced(reviews.map((e) => e.rowId));
      await uw.markSynced(words.map((w) => w.id));
      await ar.markSynced(reads.map((e) => e.articleId));
      await bm.markSynced(marks.map((b) => b.contentId));
      // ⚠️ `book_progress_pending` **没有待推标记** ⇒ 每次全量带上。
      //    代价可忽略（一本书一行）+ 服务端 UPSERT 的 `WHERE` 保证
      //    「值没变就不刷新 received_at」⇒ **不会产生回声**。

      _say('sync.push: ${r.pushedTotal} 条');
    } catch (e) {
      r.ok = false;
      r.error = '$e';
      _say('sync.push 失败: $e');
    }
    return r;
  }

  /// 组装 push 请求体。
  ///
  /// 🔴 键名必须与后端 `sync_handlers.rs` 的 `PushInput` / `*Input` 逐字一致 ——
  ///    错了是**静默传空**（serde 忽略未知字段，两端都不报错）。
  ///    断言：`scripts/query_verify/bin/verify_sync_merge.dart`【8】核对
  ///    契约表 `kPushJsonContract`，而**本方法用的就是那份契约的字段**。
  Map<String, dynamic> _buildPushBody({
    required List<ReviewEvent> reviews,
    required List<UserWord> words,
    required List<({int articleId, String readAt})> reads,
    required List<Bookmark> marks,
    required List<Map<String, Object?>> progress,
  }) {
    return {
      'device_id': _deviceId,
      'review_events': [
        for (final e in reviews)
          {
            'word_id': e.wordId,
            'rating': e.rating.value,
            'duration_ms': e.durationMs,
            'reviewed_at': e.reviewedAt.toUtc().toIso8601String(),
          }
      ],
      'user_words': [for (final w in words) m.userWordToPushJson(w.toPushRow())],
      'article_reads': [
        for (final e in reads) {'article_id': e.articleId, 'read_at': e.readAt}
      ],
      'bookmarks': [
        for (final b in marks)
          {
            'content_id': b.contentId,
            'bookmarked_at': b.bookmarkedAt.toUtc().toIso8601String(),
            'deleted': b.deleted ? 1 : 0,
          }
      ],
      'book_progress': [
        for (final p in progress) m.bookProgressToPushJson(p)
      ],
    };
  }

  /// 电子书进度的待推行（`book_progress_pending` 全量）。
  Future<List<Map<String, Object?>>> _pendingBookProgress() async {
    final db = _bookDb;
    if (db == null) return const [];
    try {
      final rows = await db.query('book_progress_pending');
      return rows.map((r) => <String, Object?>{...r}).toList();
    } catch (e) {
      // 表不存在（老库未迁移）⇒ 不做电子书同步，但不连累其余四类
      _say('sync.push: 读 book_progress_pending 失败（跳过电子书进度）: $e');
      return const [];
    }
  }

  // ════════════════════════════════════════════════════════════
  // pull
  // ════════════════════════════════════════════════════════════

  /// 拉取别端改动 → 合并写库 → 推进游标。
  Future<SyncReport> pullOnce() async {
    final r = SyncReport();
    try {
      final since = await _readCursor();
      final resp = await _pullHttp(since: since, deviceId: _deviceId);

      final events = _listOf(resp, 'review_events');
      final words = _listOf(resp, 'user_words');
      final reads = _listOf(resp, 'article_reads');
      final marks = _listOf(resp, 'bookmarks');
      final progress = _listOf(resp, 'book_progress');

      r.pulledReviewEvents = await _applyReviewEvents(events);
      r.pulledUserWords = await _applyUserWords(words);
      r.pulledArticleReads = await _applyArticleReads(reads);
      r.pulledBookmarks = await _applyBookmarks(marks);
      r.pulledBookProgress = await _applyBookProgress(progress);

      // 🔴🔴 **pull 之后必须认领一次** —— 否则对**已导入**的书，
      //    别端刚推来的进度会被写进交换区却**永远不被应用**
      //    （用户在新设备上仍看到旧章节，且**没有任何提示**）。
      //
      // 🔑 与「导入后认领」（`book_importer`）是**两条互补的线**：
      //    导入后 → 覆盖「书还没导入时那段窗口」；pull 后 → 覆盖「书已导入」的情形。
      //    设计文档 §3.4.3 只画了前者 ⇒ 后者是实测时才发现的缺口。
      r.claimedBooks = await _claimBookProgress();

      // 🔴 **推进游标用服务端返回的 `server_time`**，不是「当前时间」：
      //    它 = 本次数据里最大的 `received_at`。若用当前时间，
      //    在「pull 完成」到「取时间」之间写入的记录会被**永久跳过**
      //    （时间轴断层 —— 服务端 `sync_handlers.rs` 的注释已写明）。
      final serverTime = resp['server_time'];
      if (serverTime is String && serverTime.isNotEmpty) {
        await _writeCursor(serverTime);
      } else {
        // ⚠️ 缺 `server_time` = 协议被破坏。**不推进游标**（宁可下次重复拉，
        //    也不能跳过一个未知区间 —— 重复拉是幂等的）。
        r.ok = false;
        r.error = '响应缺少 server_time（游标未推进）';
        _say('sync.pull: $r.error');
      }

      _say('sync.pull: ${r.pulledTotal} 条（since=$since → $serverTime）');
    } catch (e) {
      r.ok = false;
      r.error = '$e';
      _say('sync.pull 失败: $e');
    }
    return r;
  }

  static List<Map<String, dynamic>> _listOf(
      Map<String, dynamic> resp, String key) {
    final v = resp[key];
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) e.cast<String, dynamic>()
    ];
  }

  /// **复习事件**：写进 `review_log`（`synced = 1`）后**重放**派生状态。
  ///
  /// 🔑 为什么「写事件 + 重放」而不是「直接用远端算好的状态」：
  ///    状态是事件的函数值，而两端各自重放才能保证**同一份事件算出同一个状态**
  ///    （`FsrsService` 是纯函数，任一设备算出同一结果）。
  Future<int> _applyReviewEvents(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return 0;
    final q = ReviewListQuery(_userDb);

    // 按词分组（同一词的多个事件要**一起**重放，否则中间态会写进库）
    final byWord = <String, List<ReviewEvent>>{};
    for (final j in events) {
      final e = _eventFromPullJson(j);
      if (e == null) continue;
      byWord.putIfAbsent(e.wordId, () => []).add(e);
    }

    var n = 0;
    for (final entry in byWord.entries) {
      final wordId = entry.key;
      final remote = entry.value;

      // ① 落库。`INSERT OR IGNORE` ⇒ 已存在的事件**不重复写**（幂等）；
      //    `synced: 1` ⇒ 服务端已知，**不要**被下一轮 push 推回去（回声）。
      for (final e in remote) {
        await q.logReview(e, synced: 1);
        n++;
      }

      // ② 重放**本地全部事件**（已含刚写入的远端事件）⇒ 权威状态。
      //    🔑 用 `replay`（单流）而不是 `merge`（双流）：事件已经合并到一处了，
      //       再分两流只会多一次去重（且去重键依赖 deviceId，多此一举）。
      final all = await q.eventsOf(wordId);
      if (all.isEmpty) continue;
      final state = _fsrs.replay(wordId, all);

      // ③ 写回派生状态。
      //    🔴 `pending_push: 0` —— `card_review_state` **不参与同步**
      //       （推的依据是 `review_log.synced`）。已核实 UI 层无人读该列。
      await q.upsertState(
        wordId: wordId,
        spelling: await _spellingFor(wordId),
        state: state.state,
        step: state.step,
        stability: state.stability,
        difficulty: state.difficulty,
        reps: state.reps,
        lapses: state.lapses,
        lastReviewAt: state.lastReviewAt,
        nextReviewAt: state.nextReviewAt,
        pendingPush: 0,
      );
    }
    return n;
  }

  /// `word_id` → 拼写（`card_review_state.spelling` 是 `NOT NULL`）。
  ///
  /// 🔑 顺序：**本地已有状态 → 生词本 → `word_id` 本身**。
  ///    · 前两者能命中时拿到的是**真拼写**
  ///    · 都命中不了（首次同步且这个词不在生词本里）⇒ 用 `word_id` 兜底
  ///      ⚠️ 那是个**难看的占位**（列表会显示 `w008732` 而不是单词），
  ///         但**比崩掉好**，且下次该词进生词本 / 本地查词后会被覆盖。
  ///    📌 为什么不查 `word.db`：那是**另一个库**，跨库 JOIN 会把
  ///       「库不可用」的风险引进来（本文件的其余部分都不依赖 word.db）。
  Future<String> _spellingFor(String wordId) async {
    final st = await ReviewListQuery(_userDb).stateOf(wordId);
    if (st != null && st.spelling.isNotEmpty) return st.spelling;
    final uw = await UserWordRepository(_userDb).findByWordId(wordId);
    if (uw != null && uw.spelling.isNotEmpty) return uw.spelling;
    return wordId;
  }

  ReviewEvent? _eventFromPullJson(Map<String, dynamic> j) {
    final wordId = j['word_id'];
    final rating = j['rating'];
    final reviewedAt = j['reviewed_at'];
    if (wordId is! String || rating is! num || reviewedAt is! String) return null;
    final at = DateTime.tryParse(reviewedAt);
    // ⚠️ 档位必须在 1–4（`ReviewRating.fromValue` 会抛）—— 服务端有 CHECK，
    //    但这是**跨进程输入**，坏一条不该让整次同步崩掉 ⇒ 跳过它。
    if (at == null || rating.toInt() < 1 || rating.toInt() > 4) return null;
    return ReviewEvent(
      wordId: wordId,
      rating: ReviewRating.fromValue(rating.toInt()),
      reviewedAt: at.toUtc(),
      durationMs: (j['duration_ms'] as num?)?.toInt(),
      deviceId: j['device_id'] as String?,
      synced: 1,
    );
  }

  /// 生词本：字段级合并后**只写需要的**。
  Future<int> _applyUserWords(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final remote = m.userWordFromPullJson(j);
      final wordId = remote['word_id'] as String? ?? '';
      if (wordId.isEmpty) continue;

      // ⚠️ `pendingPushAfterPull` 返回 **bool**，而 SQLite 参数**不接受 bool**
      //    （会抛 `Invalid sql argument type 'bool'`）⇒ 必须在这里转成 `0/1`。
      //    📌 这是「改完必须复跑」的又一例：把常量 `0` 换成函数调用后，
      //      类型从 `int` 变成 `bool`，**编译期不报错**（`Map<String, Object?>` 装得下）。
      //
      // 🔑 **两条路径都走同一个判定函数**（证伪时实测发现的修正）：
      //    原先「本地不存在」分支**硬编码** `pending_push: 0`，
      //    于是 `pendingPushAfterPull` 的 `localExisted: false` 分支**永远是死代码**
      //    —— 而它恰好承载「首次同步不回声」这条最关键的语义。
      //    ⇒ 统一成一次调用：**口径只有一处**（本项目的反复教训）。
      final localRow = await _userWordRow(wordId);
      final Map<String, Object?> merged =
          localRow != null ? m.mergeUserWord(localRow, remote) : {...remote};
      merged['pending_push'] = m.pendingPushAfterPull(
        localExisted: localRow != null,
        localWasPending:
            localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
      ) ? 1 : 0;
      await _upsertUserWord(merged);
      n++;
    }
    return n;
  }

  Future<Map<String, Object?>?> _userWordRow(String wordId) async {
    final rows = await _userDb
        .query('user_word', where: 'word_id = ?', whereArgs: [wordId], limit: 1);
    return rows.isEmpty ? null : {...rows.first};
  }

  /// 按 `word_id` upsert（**已存在则更新同步字段**）。
  ///
  /// ⚠️ 不用 `Repository.add()` —— 它带业务语义（「用户主动加入」：
  ///    会写 `lookup_event`、会设 `source_sentence`）。同步只是**对齐数据**，
  ///    必须走「直写」路径，否则会把远端数据伪装成本地操作。
  Future<void> _upsertUserWord(Map<String, Object?> row) async {
    await _userDb.rawInsert(
      'INSERT INTO user_word '
      '(word_id, spelling, source_article_id, source_sentence, added_at, '
      ' updated_at, deleted, pending_push) '
      'VALUES (?,?,?,?,?,?,?,?) '
      'ON CONFLICT (word_id) DO UPDATE SET '
      '  spelling          = excluded.spelling, '
      '  source_article_id = excluded.source_article_id, '
      '  source_sentence   = excluded.source_sentence, '
      '  added_at          = excluded.added_at, '
      '  updated_at        = excluded.updated_at, '
      '  deleted           = excluded.deleted, '
      '  pending_push      = excluded.pending_push',
      [
        row['word_id'],
        row['spelling'],
        row['source_article_id'],
        row['source_sentence'],
        row['added_at'],
        row['updated_at'],
        row['deleted'] ?? 0,
        row['pending_push'] ?? 0,
      ],
    );
  }

  Future<int> _applyArticleReads(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final remote = m.articleReadFromPullJson(j);
      final id = (remote['article_id'] as num?)?.toInt();
      if (id == null) continue;
      final existing = await _userDb.query('article_read',
          columns: ['read_at', 'pending_push'],
          where: 'article_id = ?',
          whereArgs: [id],
          limit: 1);
      final Map<String, Object?>? localRow =
          existing.isEmpty ? null : {...existing.first};
      final Map<String, Object?> merged =
          localRow != null ? m.mergeArticleRead(localRow, remote) : {...remote};
      merged['pending_push'] = m.pendingPushAfterPull(
        localExisted: localRow != null,
        localWasPending:
            localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
      ) ? 1 : 0;
      await _userDb.rawInsert(
        'INSERT INTO article_read (article_id, read_at, pending_push) '
        'VALUES (?,?,?) '
        'ON CONFLICT (article_id) DO UPDATE SET '
        '  read_at = excluded.read_at, pending_push = excluded.pending_push',
        [id, merged['read_at'], merged['pending_push'] ?? 0],
      );
      n++;
    }
    return n;
  }

  Future<int> _applyBookmarks(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final remote = m.bookmarkFromPullJson(j);
      final id = (remote['content_id'] as num?)?.toInt();
      if (id == null) continue;
      final existing = await _userDb.query('bookmark',
          columns: ['bookmarked_at', 'deleted', 'pending_push'],
          where: 'content_id = ?',
          whereArgs: [id],
          limit: 1);
      final Map<String, Object?>? localRow =
          existing.isEmpty ? null : {...existing.first};
      final Map<String, Object?> merged =
          localRow != null ? m.mergeBookmark(localRow, remote) : {...remote};
      merged['pending_push'] = m.pendingPushAfterPull(
        localExisted: localRow != null,
        localWasPending:
            localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
      ) ? 1 : 0;
      await _userDb.rawInsert(
        'INSERT INTO bookmark (content_id, bookmarked_at, deleted, pending_push) '
        'VALUES (?,?,?,?) '
        'ON CONFLICT (content_id) DO UPDATE SET '
        '  bookmarked_at = excluded.bookmarked_at, '
        '  deleted       = excluded.deleted, '
        '  pending_push  = excluded.pending_push',
        [
          id,
          merged['bookmarked_at'],
          merged['deleted'] ?? 0,
          merged['pending_push'] ?? 0,
        ],
      );
      n++;
    }
    return n;
  }

  /// 把交换区里「本地已有这本书」的进度**认领**进 `book_progress`。
  ///
  /// 失败**不抛**（同步是后台行为）：认领失败时 `pending` 行仍在
  /// ⇒ 下次 pull 会再试（自愈）⇒ 如实记日志即可。
  Future<int> _claimBookProgress() async {
    final db = _bookDb;
    if (db == null) return 0;
    try {
      final result = await claimAllPending(db);
      if (result.didSomething) {
        _say('sync.pull: 认领电子书进度 $result');
      }
      return result.claimed;
    } catch (e) {
      _say('sync.pull: 认领电子书进度失败（下次重试）: $e');
      return 0;
    }
  }

  /// **电子书进度** → `book_progress_pending`（按**指纹**，不需要本地有书）。
  ///
  /// 🔑 为什么写「待认领」表而不是 `book_progress`：
  ///    `book_progress.book_id` 是**端侧 uuid**，而 `book_progress` 有
  ///    `FK → book(id)` —— 本地没导入这本书时**插不进去**（FK 失败）。
  ///    待认领表按 `content_hash` 存 ⇒ 无需 FK，等用户导入同一本书时「认领」
  ///    （设计 §3.4.3）。
  /// ✅ **认领已实现**（2026-10-06 · `ebook/book_progress_sync.dart`），两条线：
  ///    · 导入后 —— `book_importer._persistBook` 调 `claimPendingForBook`
  ///    · **pull 后** —— 本文件紧接着调 `_claimBookProgress`（批量）
  ///    ⇒ 写进交换区的进度**一定会被应用**（书没导入时先存着，导入后用上）。
  Future<int> _applyBookProgress(List<Map<String, dynamic>> rows) async {
    final db = _bookDb;
    if (db == null || rows.isEmpty) return 0;
    var n = 0;
    try {
      for (final j in rows) {
        final remote = m.bookProgressFromPullJson(j);
        final hash = m.bookProgressKey(remote);
        if (hash.isEmpty) continue;
        final existing = await db.query('book_progress_pending',
            columns: ['updated_at'],
            where: 'content_hash = ?',
            whereArgs: [hash],
            limit: 1);
        // 已是较新的本地进度 ⇒ 不回退（同 `mergeBookProgress` 的口径）
        if (existing.isNotEmpty &&
            !m.isNewer(remote['updated_at'], existing.first['updated_at'])) {
          continue;
        }
        await db.rawInsert(
          'INSERT INTO book_progress_pending '
          '(content_hash, chapter_idx, scroll_ratio, updated_at) VALUES (?,?,?,?) '
          'ON CONFLICT (content_hash) DO UPDATE SET '
          '  chapter_idx = excluded.chapter_idx, '
          '  scroll_ratio = excluded.scroll_ratio, '
          '  updated_at = excluded.updated_at',
          [
            hash,
            remote['chapter_idx'],
            remote['scroll_ratio'],
            remote['updated_at'],
          ],
        );
        n++;
      }
    } catch (e) {
      _say('sync.pull: 电子书进度写入失败（跳过）: $e');
    }
    return n;
  }
}
