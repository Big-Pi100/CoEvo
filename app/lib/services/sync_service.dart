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

import 'achievement_service.dart';
import 'article_read_repository.dart';
import 'bookmark_repository.dart';
import 'ebook/book_marker_sync.dart';
import 'ebook/book_progress_sync.dart';
import 'ebook/cloud_book_repository.dart';
import 'fsrs_service.dart';
import 'highlight_repository.dart';
import 'review_list_query.dart';
import 'review_spelling.dart';
import 'settings_sync.dart';
import 'sync_merge.dart' as m;
import 'user_word_repository.dart';

/// 单次 push 里**每张表**的最大条数。
///
/// 🔴 必须与后端 `sync_handlers.rs` 的 `MAX_ITEMS_PER_TABLE` **一致** ——
///    超了服务端会**明确回 400**（设计如此，不是静默截断）。
///    ⚠️ 因此 `pushOnce` 必须**分批循环**：老库升级后 `lookup_event` 可能有数千条
///       待推（`pending_push` 默认 1），一次全推 ⇒ 400 ⇒ **整批都推不上去**
///       （review / word / bookmark … 全被连累）。
///    📌 判据：**一个请求里的多张表是「同生共死」的** ⇒ 任何一张超限都会拖垮其余。
const int kMaxItemsPerTable = 1000;

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

  /// 🆕 2026-10-09：划线记忆（`highlight`）。**必须计入 [pushedTotal]/[pulledTotal]** ——
  ///    否则「本轮只同步了笔记」会被判成「什么都没做」⇒ 不 bump ⇒ 界面不刷新
  ///    （同 `pulledBooks` 那条注释里记的坑）。
  int pushedHighlights = 0;

  /// 🆕 2026-10-10：同步覆盖面补齐（审计报告 §五）。
  /// 🔑 每一项都**必须计入 [pushedTotal]/[pulledTotal]** —— 漏一项 ⇒「本轮只同步了那一项」
  ///    会被判成「什么都没做」⇒ 不 bump ⇒ **界面不刷新**（静默，本项目最忌）。
  int pushedLookupEvents = 0;
  int pushedBookMarkers = 0;
  int pushedAchievementUnlocks = 0;
  int pushedSettings = 0;

  /// 本次**认领**（把「别端的电子书进度」应用到本地已导入的书）的本数。
  ///
  /// 🔑 单列而不是并进 `pulledBookProgress`：后者是「交换区写入数」，
  ///    这个是「**真正生效**的书数」。两者不等是正常的（书还没导入时后者 > 0、前者 = 0）。
  int claimedBooks = 0;

  /// 🆕 2026-10-10：本次**认领**（把「待认领书签」写进本地已导入的书）的**条**数。
  ///
  /// ⚠️ 与 [claimedBooks] 分开：那个是「认领的**书**数」，这个是「认领的书签**条**数」——
  ///    混在一起会让日志撒谎（一本书可以有几十条书签）。
  int claimedBookMarkers = 0;

  /// 本次**拉回来并写入本地**的条数（按表分）。
  int pulledReviewEvents = 0;
  int pulledUserWords = 0;
  int pulledArticleReads = 0;
  int pulledBookmarks = 0;
  int pulledBookProgress = 0;

  /// 🆕 2026-10-09：划线记忆（`highlight`）。
  int pulledHighlights = 0;

  /// 🆕 2026-10-10：同步覆盖面补齐。
  int pulledLookupEvents = 0;
  int pulledBookMarkers = 0;
  int pulledAchievementUnlocks = 0;
  /// 🔑 这个不是「写了几行」，而是**真正改变了 prefs 的键数** ——
  ///    它才是「要不要刷新读数 provider」的依据（写表不算）。
  int pulledSettings = 0;

  /// 🆕 书架上云：本轮**合并进 `cloud_book`** 的条数（含删除）。
  int pulledBooks = 0;

  /// 是否成功。`false` 时 [error] 一定有值。
  bool ok = true;
  String? error;

  int get pushedTotal =>
      pushedReviewEvents +
      pushedUserWords +
      pushedArticleReads +
      pushedBookmarks +
      pushedHighlights +
      pushedBookProgress +
      // 🆕 2026-10-10
      pushedLookupEvents +
      pushedBookMarkers +
      pushedAchievementUnlocks +
      pushedSettings;

  /// 🔴 2026-10-09 修正：原先**漏了 `pulledBooks` 与 `claimedBooks`** ——
  ///    它们是「书架上云」之后新加的两项，而这个 getter 没跟着更新。
  ///    后果是**静默的**：
  ///    · `isEmpty` 会把「本轮只拉回了书单变更」判成「**什么都没做**」
  ///      ⇒ 日志不打（`_say('sync.pull: …')`）、调用方跳过 UI 提示；
  ///    · 「拉回书单但没拉回别的」正是**云端备份清理**生效时的样子
  ///      （`blob_size → 0` 只有 `pulledBooks` 计到）⇒ 会被整条漏掉。
  ///    ⚠️ `sync_status_provider` 原先写的是 `pulledTotal + claimedBooks`
  ///      —— 那是**调用方打的补丁**；补全本 getter 后**必须撤掉**，否则**双计**。
  ///    📌 判据：**补丁 ≠ 修法** —— 判据有洞时要先问「还有哪些地方在补这个洞」，
  ///       再一次性改全（同族：`isEmpty` / 日志 / 状态显示三处都受影响）。
  int get pulledTotal =>
      pulledReviewEvents +
      pulledUserWords +
      pulledArticleReads +
      pulledBookmarks +
      pulledHighlights +
      pulledBookProgress +
      pulledBooks +
      claimedBooks +
      // 🆕 2026-10-10
      pulledLookupEvents +
      pulledBookMarkers +
      pulledAchievementUnlocks +
      pulledSettings +
      claimedBookMarkers;

  /// 本次**什么都没做**（无待推 + 无新拉）。
  ///
  /// 🔑 存在的理由：调用方可据此**跳过日志与 UI 提示** ——
  ///    「同步了 0 条」不值得打扰用户，但「同步了 12 条」可能值得（或值得记一行）。
  bool get isEmpty => pushedTotal == 0 && pulledTotal == 0;

  @override
  String toString() => ok
      ? 'SyncReport(推 $pushedTotal: 复习$pushedReviewEvents 词$pushedUserWords '
          '读$pushedArticleReads 藏$pushedBookmarks 划线$pushedHighlights '
          '书$pushedBookProgress 查词$pushedLookupEvents 书签$pushedBookMarkers '
          '成就$pushedAchievementUnlocks 设置$pushedSettings | '
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
    /// 查词库（`word.db`）拿拼写 —— 见 [_spellingFor] 的说明。
    /// 不传也能工作（少一级来源：正式词解析不出来就返回 `null`，不写坏数据）。
    WordSpellingLookup? wordSpellingLookup,
    /// 拼写解析的诊断输出（可选）。**本文件不 import flutter**（保持纯 Dart），
    /// 所以由调用方把 `debugPrint` 传进来。
    void Function(String message)? onSpellingLog,
    /// 🆕 2026-10-10：**设置同步**的两个 IO 注入（`SharedPreferences` 读写）。
    /// 两者**都不传** ⇒ 跳过设置同步（其余数据照常）—— 与 `bookDb` 可空同一取向。
    /// ⚠️ 本文件不 import `shared_preferences`（那是 Flutter 插件）⇒ 只能注入。
    PrefsRead? readPrefSetting,
    PrefsWrite? writePrefSetting,
  })  : _userDb = userDb,
        _readPrefSetting = readPrefSetting,
        _writePrefSetting = writePrefSetting,
        _bookDb = bookDb,
        _pushHttp = pushHttp,
        _pullHttp = pullHttp,
        _readCursor = readCursor,
        _writeCursor = writeCursor,
        _deviceId = deviceId,
        _log = log,
        _fsrs = fsrs ?? FsrsService(),
        _spellingResolver = ReviewSpellingResolver(
          userDb,
          wordLookup: wordSpellingLookup,
          onLog: onSpellingLog,
        );

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

  /// 🆕 2026-10-10：设置同步的 IO 注入（见构造参数说明）。
  final PrefsRead? _readPrefSetting;
  final PrefsWrite? _writePrefSetting;

  /// `word_id` → 真拼写的**唯一解析处**（`review_spelling.dart`）。
  ///
  /// ⚠️ 由构造参数构建（不是每次现 new）—— 解析器持有 `userDb` 与注入的词库查询，
  ///    每行重建一次是浪费。
  final ReviewSpellingResolver _spellingResolver;

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
    // 🔴 **逐字段复制 —— 这里漏一个字段 = 该字段的计数在 `syncNow()` 之后归零**
    //    ⇒ `pulledTotal` 变小 ⇒ 调用方（`sync_provider`）判「什么都没拉回」⇒ **不 bump**
    //    ⇒「数据同步了、界面不刷新」（静默）。本项目的判据：
    //    **「写端逐个通知读端」是必漏结构** —— 这里的「逐个复制」是同一种病。
    //    ⚠️ 2026-10-10 实测发现**已漏两处**（`pushedHighlights` / `pulledHighlights`
    //       与 `pulledBooks`）—— 已补。守护断言见 `verify_sync_service.dart`。
    return SyncReport()
      ..pushedReviewEvents = pushReport.pushedReviewEvents
      ..pushedUserWords = pushReport.pushedUserWords
      ..pushedArticleReads = pushReport.pushedArticleReads
      ..pushedBookmarks = pushReport.pushedBookmarks
      ..pushedHighlights = pushReport.pushedHighlights
      ..pushedBookProgress = pushReport.pushedBookProgress
      ..pushedLookupEvents = pushReport.pushedLookupEvents
      ..pushedBookMarkers = pushReport.pushedBookMarkers
      ..pushedAchievementUnlocks = pushReport.pushedAchievementUnlocks
      ..pushedSettings = pushReport.pushedSettings
      ..pulledReviewEvents = pullReport.pulledReviewEvents
      ..pulledUserWords = pullReport.pulledUserWords
      ..pulledArticleReads = pullReport.pulledArticleReads
      ..pulledBookmarks = pullReport.pulledBookmarks
      ..pulledHighlights = pullReport.pulledHighlights
      ..pulledBookProgress = pullReport.pulledBookProgress
      ..pulledBooks = pullReport.pulledBooks
      ..pulledLookupEvents = pullReport.pulledLookupEvents
      ..pulledBookMarkers = pullReport.pulledBookMarkers
      ..pulledAchievementUnlocks = pullReport.pulledAchievementUnlocks
      ..pulledSettings = pullReport.pulledSettings
      ..claimedBooks = pullReport.claimedBooks
      ..claimedBookMarkers = pullReport.claimedBookMarkers
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
  ///
  /// # 🔴 分批循环（2026-10-10 加）
  ///
  /// 一次请求里**多张表是同生共死**的 ⇒ 任何一张超过服务端 `MAX_ITEMS_PER_TABLE`(1000)
  /// 都会让**整批回 400**（其余表的待推数据也一起推不上去）。
  /// 老库升级后 `lookup_event` 的 `pending_push` 默认 1 ⇒ 可能有**数千条**待推 ⇒ 必然触发。
  /// ⇒ 每轮每表最多取 [kMaxItemsPerTable] 条，推成功并标记后再取下一批。
  ///
  /// ## 两类表的处理**不同**（循环里最容易写错的一处）
  /// | 类 | 表 | 每轮 |
  /// |---|---|---|
  /// | **有 `pending_push` 标记** | review/word/read/bookmark/highlight/lookup/achievement/setting | 逐轮取到空 |
  /// | **全量推**（无标记） | `book_progress` / `books` / `book_markers` | 🔴 **只在第一轮带** |
  /// ⇒ 若让全量表也参与循环，它会**每轮都带同样的内容** ⇒ **永不终止**。
  ///
  /// ## 🔴 终止条件
  /// 「本轮**没有任何一张有标记的表取满**」⇒ 已推完。
  /// ⚠️ **不能**只靠「批量为 0」—— 若设置采集异常导致其每轮都返回非空，就会死循环。
  Future<SyncReport> pushOnce() async {
    final r = SyncReport();
    try {
      final q = ReviewListQuery(_userDb);
      final uw = UserWordRepository(_userDb);
      final ar = ArticleReadRepository(_userDb);
      final bm = BookmarkRepository(_userDb);
      final hl = HighlightRepository(_userDb);
      final ach = AchievementService(_userDb);

      // 🔴🔴 查词记录的 `uid` **必须先回填** —— 空 `uid` 的行推上去会让服务端
      //     PK `(user_id, uid)` 把它们**互相覆盖**（只剩最后一条），**且不报错**。
      await uw.backfillLookupUids();

      var firstRound = true;
      while (true) {
        final reviews = await q.pendingReviews(limit: kMaxItemsPerTable);
        final words = await uw.pending(limit: kMaxItemsPerTable);
        final reads = await ar.pending(limit: kMaxItemsPerTable);
        final marks = await bm.pending(limit: kMaxItemsPerTable);
        final highlights = await hl.pending(limit: kMaxItemsPerTable);
        final lookups = await uw.pendingLookups(limit: kMaxItemsPerTable);
        final unlocks = await ach.pendingUnlocks(limit: kMaxItemsPerTable);
        final settings = await _pendingSettings();

        // 🔑 全量推的表**只在第一轮**带（否则每轮重复 ⇒ 永不终止）
        final progress = firstRound
            ? await _pendingBookProgress()
            : const <Map<String, Object?>>[];
        final books =
            firstRound ? await _pendingBooks() : const <Map<String, Object?>>[];
        final markers = firstRound
            ? await _pendingBookMarkers()
            : const <Map<String, Object?>>[];

        final batchTotal = reviews.length +
            words.length +
            reads.length +
            marks.length +
            highlights.length +
            lookups.length +
            unlocks.length +
            settings.length +
            progress.length +
            books.length +
            markers.length;
        // 🔑 **空批次不发请求** —— 一次网络往返有成本（电量/流量/延迟），
        //    而「什么都没变」是最常见的情形（用户刚打开 App）。
        if (batchTotal == 0) {
          if (firstRound) _say('sync.push: 无待推数据，跳过');
          break;
        }

        await _pushHttp(_buildPushBody(
          reviews: reviews.map((e) => e.event).toList(),
          words: words,
          reads: reads,
          marks: marks,
          highlights: highlights,
          lookups:
              lookups.map((l) => m.lookupEventToPushJson(l.toPushRow())).toList(),
          progress: progress,
          // 🆕 书架上云：书单**先到**（服务端上传文件时会校验书单行存在）
          books: books,
          bookMarkers: markers,
          achievementUnlocks: unlocks,
          settings: settings,
        ));

        // ── 只有 **push 成功** 才标记（失败则不标记 ⇒ 下次重试）──
        await q.markReviewsSynced(reviews.map((e) => e.rowId));
        await uw.markSynced(words.map((w) => w.id));
        await ar.markSynced(reads.map((e) => e.articleId));
        await bm.markSynced(marks.map((b) => b.contentId));
        await hl.markSynced(highlights.map((h) => h.id));
        await uw.markLookupsSynced(lookups.map((l) => l.uid ?? ''));
        await ach.markUnlocksSynced(unlocks.map((u) => u['key'] as String? ?? ''));
        if (settings.isNotEmpty) {
          await markSettingsSynced(
              _userDb, settings.map((s) => s['key'] as String? ?? ''));
        }
        // ⚠️ `book_progress` / `books` / `book_markers` **没有待推标记** ⇒ 全量带上。
        //    代价可忽略（行数少）+ 服务端 UPSERT 的 `WHERE` 保证
        //    「值没变就不刷新 received_at」⇒ **不会产生回声**。

        r.pushedReviewEvents += reviews.length;
        r.pushedUserWords += words.length;
        r.pushedArticleReads += reads.length;
        r.pushedBookmarks += marks.length;
        r.pushedHighlights += highlights.length;
        r.pushedLookupEvents += lookups.length;
        r.pushedAchievementUnlocks += unlocks.length;
        r.pushedSettings += settings.length;
        r.pushedBookProgress += progress.length;
        r.pushedBookMarkers += markers.length;

        // 🔴 终止：**没有任何一张「有标记的表」取满** ⇒ 已推完（见方法头说明）
        final anyMarkedTableFull = reviews.length >= kMaxItemsPerTable ||
            words.length >= kMaxItemsPerTable ||
            reads.length >= kMaxItemsPerTable ||
            marks.length >= kMaxItemsPerTable ||
            highlights.length >= kMaxItemsPerTable ||
            lookups.length >= kMaxItemsPerTable ||
            unlocks.length >= kMaxItemsPerTable;
        firstRound = false;
        if (!anyMarkedTableFull) break;
      }

      if (r.pushedTotal > 0) _say('sync.push: ${r.pushedTotal} 条');
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
    required List<Highlight> highlights,
    /// 🆕 2026-10-10：查词记录（已转成推送 JSON 形状）。
    required List<Map<String, Object?>> lookups,
    required List<Map<String, Object?>> progress,
    required List<Map<String, Object?>> books,
    /// 🆕 2026-10-10：书本内书签（已带 `content_hash` —— 跨设备书身份）。
    required List<Map<String, Object?>> bookMarkers,
    /// 🆕 2026-10-10：成就解锁记录。
    required List<Map<String, Object?>> achievementUnlocks,
    /// 🆕 2026-10-10：应用设置。
    required List<Map<String, Object?>> settings,
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
      // 🆕 2026-10-09 划线记忆。⚠️ 位置**与后端 `PushInput` 的字段顺序一致**
      //    （`bookmarks` 与 `book_progress` 之间）—— 顺序无功能意义，
      //    但它让「两张清单逐条对照」变成可能（漏一张表时一眼看得出）。
      'highlights': [
        for (final h in highlights) m.highlightToPushJson(h.toPushRow())
      ],
      'book_progress': [
        for (final p in progress) m.bookProgressToPushJson(p)
      ],
      // 🆕 书单（书架上云）。⚠️ 它必须**先于文件上传**到达服务端，
      //    否则上传会被 400 拒（「这本书还没在书单里」）。
      'books': books,
      // 🆕 2026-10-10：同步覆盖面补齐的 4 类。
      // ⚠️ 键名与字段顺序**必须与后端 `PushInput` 一致**（错了是**静默传空**：
      //    serde 忽略未知字段、两端都不报错）。
      'lookup_events': lookups,
      'book_markers': bookMarkers,
      'achievement_unlocks': achievementUnlocks,
      'settings': settings,
    };
  }

  /// 书单的待推行（本地 `book` 表**全量**）。
  ///
  /// 🔑 为什么全量而不是增量：书的元数据**很少变**（导入后就是固定的），
  ///    而且服务端的 `sync_book` 是 upsert ⇒ 全量推是幂等的、代价也小。
  ///    ⚠️ 与 `book_progress_pending`（只推变化）的取舍不同：
  ///       那边是**高频写**（每次翻章都变），这边是**一次性**。
  ///
  /// ⚠️ `size_bytes` 传 0：配额看的是服务端的 `blob_size`（权威），
  ///    这个字段只用于端侧展示，而当前 UI 并不显示它。
  ///    ⇒ 不为此在 push 时去 `stat` 每个原始文件（书多时是 N 次磁盘 I/O）。
  Future<List<Map<String, Object?>>> _pendingBooks() async {
    final db = _bookDb;
    if (db == null) return const [];
    try {
      final rows = await db.query('book');
      final out = <Map<String, Object?>>[];
      for (final r in rows) {
        final h = r['content_hash'];
        // ⚠️ 无指纹 ⇒ **不参与同步**（同进度同步的判据：
        //    拿一个错误的身份去匹配比不同步更糟）
        if (h is! String || h.isEmpty) continue;
        final at = (r['added_at'] as String?) ?? '';
        out.add({
          'content_hash': h,
          'title': (r['title'] as String?) ?? '',
          'author': (r['author'] as String?) ?? '',
          'lang': (r['language'] as String?) ?? '',
          'chapter_count': (r['chapter_count'] as int?) ?? 0,
          'size_bytes': 0,
          'added_at': at,
          // 🔑 书导入后元数据不变 ⇒ 用 `added_at` 当 `updated_at`
          //    （服务端按它做「较新者赢」的合并）
          'updated_at': at,
          'deleted': 0,
        });
      }
      return out;
    } catch (e) {
      _say('sync.push: 读书单失败（跳过书单）: $e');
      return const [];
    }
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

  /// 🆕 2026-10-10：书本内书签的待推行（**全量** —— 与书单同一取舍）。
  ///
  /// 🔴 `book_marker.book_id` 是**端侧 uuid** ⇒ 必须 `JOIN book` 拿 `content_hash`
  ///    （**书**的跨设备身份）。不 join 就推 `book_id` 的话，别端根本无法把书签
  ///    对到「同一本书」上（同一本书在两台设备上是两个 uuid）。
  /// ⚠️ 没有指纹的书签**不参与**（同 `_pendingBooks` 的判据：
  ///    拿一个错误的身份去匹配比不同步更糟）。
  ///
  /// 🔑 为什么走**全量**而不是增量：书签是用户手动标的，**低频**且**行数少**，
  ///    而 `book_marker` 表**没有 `pending_push` 列**（见其 schema）——
  ///    为它加列要再走一次迁移，收益不抵成本。服务端 UPSERT 的 `WHERE` 保证
  ///    「值没变就不刷新 `received_at`」⇒ 全量推不会产生回声。
  Future<List<Map<String, Object?>>> _pendingBookMarkers() async {
    final db = _bookDb;
    if (db == null) return const [];
    try {
      final rows = await db.rawQuery('''
        SELECT m.id, b.content_hash, m.chapter_idx, m.scroll_ratio, m.excerpt,
               m.created_at, m.deleted
          FROM book_marker m
          JOIN book b ON b.id = m.book_id
         WHERE b.content_hash IS NOT NULL AND b.content_hash <> ''
      ''');
      return rows.map((r) => <String, Object?>{...r}).toList();
    } catch (e) {
      _say('sync.push: 读书签失败（跳过书签）: $e');
      return const [];
    }
  }

  /// 🆕 2026-10-10：设置类的待推行。
  ///
  /// 🔴 走「**采集式**」：读 prefs 现值与 `setting_sync` 表比对，变了才标脏 ——
  ///    这样**不必改动每一个设置项的 setter**（漏一处就会让那项永不同步，且静默）。
  ///    口径在 `settings_sync.dart`（唯一一处）。
  /// ⚠️ 未注入 prefs 读写（`_readPrefSetting == null`）⇒ 返回空，**跳过设置同步**，
  ///    其余数据照常（与 `bookDb` 可空同一取向）。
  Future<List<Map<String, Object?>>> _pendingSettings() async {
    final read = _readPrefSetting;
    if (read == null) return const [];
    try {
      return await collectSettings(_userDb, readPref: read);
    } catch (e) {
      _say('sync.push: 采集设置失败（跳过设置）: $e');
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
      final highlights = _listOf(resp, 'highlights');
      final progress = _listOf(resp, 'book_progress');
      final books = _listOf(resp, 'books');
      // 🆕 2026-10-10：同步覆盖面补齐的 4 类
      final lookups = _listOf(resp, 'lookup_events');
      final markers = _listOf(resp, 'book_markers');
      final unlocks = _listOf(resp, 'achievement_unlocks');
      final settings = _listOf(resp, 'settings');

      // 🔴 **这两行的顺序有语义**（2026-10-09 修）：`user_words` 必须**先**落库。
      //
      //    理由：`_applyReviewEvents` 要为每个 word_id **解析拼写**，而它的
      //    第 ② 级 fallback 正是 `user_word.spelling`。原先它排在前面 ⇒
      //    **同一次 pull 里那份正确的拼写还没写进去** ⇒ 解析必然失败 ⇒
      //    退回 `word_id` 占位（而那个占位会被持久化成列表标题，见
      //    `review_spelling.dart` 文件头）。
      //
      //    📌 判据：**「谁依赖谁」的顺序不能靠巧合** —— 被依赖的那步排在前面。
      r.pulledUserWords = await _applyUserWords(words);
      // 🔴 划线必须**排在 `_applyReviewEvents` 之前**（同 `user_words` 的理由，2026-10-09）。
      //
      //    `ReviewSpellingResolver` 解析 `hl:<uuid>` 的第 ③ 级正是**同一个库**的
      //    `highlight.text` ⇒ 若划线还没落库，这一步必然解析失败 ⇒ 只能退到
      //    「保留原值」（见 `review_spelling.dart`）⇒ 用户在新设备上先看到一张
      //    标题还是 `hl:<uuid>` 的卡，直到下一次启动的自愈才修好。
      //    📌 判据同 `user_words` 那条：**「谁依赖谁」的顺序不能靠巧合**。
      r.pulledHighlights = await _applyHighlights(highlights);
      r.pulledReviewEvents = await _applyReviewEvents(events);
      r.pulledArticleReads = await _applyArticleReads(reads);
      r.pulledBookmarks = await _applyBookmarks(marks);
      r.pulledBookProgress = await _applyBookProgress(progress);
      r.pulledBooks = await _applyCloudBooks(books);
      // 🆕 2026-10-10：4 类新数据。
      // 🔑 `lookup_events` / `achievement_unlocks` / `settings` 都是「并集 / LWW」，
      //    彼此**无依赖顺序**；`book_markers` 依赖本地 `book` 表（已导入的书）——
      //    没有的书先进 `book_marker_pending`，由下面的认领兜底。
      r.pulledLookupEvents = await _applyLookupEvents(lookups);
      r.pulledBookMarkers = await _applyBookMarkers(markers);
      r.pulledAchievementUnlocks = await _applyAchievementUnlocks(unlocks);
      r.pulledSettings = await _applySettings(settings);

      // 🔴🔴 **pull 之后必须认领一次** —— 否则对**已导入**的书，
      //    别端刚推来的进度会被写进交换区却**永远不被应用**
      //    （用户在新设备上仍看到旧章节，且**没有任何提示**）。
      //
      // 🔑 与「导入后认领」（`book_importer`）是**两条互补的线**：
      //    导入后 → 覆盖「书还没导入时那段窗口」；pull 后 → 覆盖「书已导入」的情形。
      //    设计文档 §3.4.3 只画了前者 ⇒ 后者是实测时才发现的缺口。
      r.claimedBooks = await _claimBookProgress();
      // 🆕 2026-10-10：书签的认领（同 `book_progress` 的两条线）。
      // ⚠️ 它**不并入 claimedBooks** —— 那个计数是「认领的**书**数」，
      //    而这里是「认领的书签**条**数」，语义不同（混一起会让日志撒谎）。
      r.claimedBookMarkers = await _claimBookMarkers();

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

  /// 把 pull 来的书单**增量合并**进 `cloud_book`。
  ///
  /// 🔑 两条路：`deleted=1` 的进 [CloudBookRepository.mergeCloudBooks] 的删除列表，
  ///    其余进 upsert 列表 —— 这样「别端删了书」在本端也会消失
  ///    （否则本地会一直显示一本云端已不存在的书，点开下载必然 404）。
  ///
  /// ⚠️ `CloudBook.fromJson` 对缺字段宽容、但**缺 `content_hash` / `title` 就返回 null**
  ///    ⇒ 这里静默跳过那种行（服务端给不出身份的书没法用，猜一个更糟）。
  Future<int> _applyCloudBooks(List<Map<String, dynamic>> rows) async {
    final db = _bookDb;
    if (db == null || rows.isEmpty) return 0;
    try {
      final upserts = <CloudBook>[];
      final deleted = <String>[];
      for (final r in rows) {
        final b = CloudBook.fromJson(r);
        if (b == null) continue;
        final d = r['deleted'];
        final isDeleted = (d is num && d.toInt() == 1) || d == true;
        if (isDeleted) {
          deleted.add(b.contentHash);
        } else {
          upserts.add(b);
        }
      }
      return await CloudBookRepository.mergeCloudBooks(
        db,
        upserts,
        deletedHashes: deleted,
      );
    } catch (e) {
      // 书单合并失败**不连累其余五类**（各表独立）
      _say('sync.pull: 合并书单失败: $e');
      return 0;
    }
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
      //
      // 🔴 **拼写：解析不出就保留原值**（2026-10-09 修）。
      //    原实现是 `spelling: await _spellingFor(wordId)`，而 `_spellingFor`
      //    两级都查不到时**返回 `word_id` 当占位**。`upsertState` 是
      //    `INSERT OR REPLACE`（整行覆盖）⇒ 那个占位被**持久写进表里**，
      //    而复习列表的标题读的正是这一列 ⇒ 用户看到 `w000129` / `hl:<uuid>`。
      //    ⇒ 现在：解析不出 ⇒ 沿用表里现有的值（**不动那一列**，留给自愈）。
      //    ⚠️ 连行都没有时才退到 `word_id`（`NOT NULL` 约束下唯一可用值）——
      //       这是极端情况（既不在 state、也不在 user_word、非 hl:/ext:、
      //       词库也查不到），下一轮同步或自愈会再试。
      final currentRow = await q.stateOf(wordId);
      final resolved = await _spellingFor(wordId);
      await q.upsertState(
        wordId: wordId,
        spelling: resolved ?? currentRow?.spelling ?? wordId,
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

  /// `word_id` → 真拼写；**解析不出来返回 `null`**（调用方据此**不动那一列**）。
  ///
  /// 🔴 2026-10-09：原实现自己查两级，**兜底 `return wordId`** ——
  ///    那个占位会被 `INSERT OR REPLACE` **持久化成列表标题**（用户看到 `w000129`）。
  ///    现在**委托给唯一的解析器** `ReviewSpellingResolver`：
  ///    它多两级来源（`hl:` 划线原文——**同一个库**可取 / `ext:` id 自带拼写 / 词库），
  ///    并且**拿不到就返回 `null`**，由调用方保留原值。
  ///
  ///    📌 判据：**「解析拼写」这件事只能有一处口径** —— 两处各写一份，
  ///       规则必然漂移，而漂移是静默的（这一轮缺陷就是这么来的）。
  ///
  /// ⚠️ 为什么解析器**不直接查 `word.db`**：那是另一个库，本文件的其余部分
  ///    刻意不依赖它（不想把「另一个库不可用」的风险引进同步主流程）。
  ///    ⇒ 词库那一级由 `buildSyncService` **注入**（见构造参数 `wordSpellingLookup`）。
  Future<String?> _spellingFor(String wordId) =>
      _spellingResolver.resolve(wordId);

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

  /// 🆕 2026-10-09：拉回来的划线 → **合并**写进本地 `highlight`。
  ///
  /// 🔴 写的是 `highlight` 表（**不是** `card_review_state`）——
  ///    后者是 `review_log` 的**派生态**，由 `_applyReviewEvents` 的重放负责。
  ///    本方法只对齐「划线本体」：正文 / 位置 / 笔记 / 暂停 / 软删。
  ///
  /// ## 🔴 为什么走「直写」而不是 `HighlightRepository.add()`
  ///
  /// `add()` 带业务语义（「**用户刚刚划了这条**」）：它会把 `deleted` 与 `paused`
  /// **归零**。用它做同步的后果很具体：
  ///   ① 别端**取消**的划线，在本地**复活**；
  ///   ② 别端**暂停**的笔记，在本地**恢复排期**。
  /// ⇒ 同步路径只对齐数据，**不借用业务方法**（同 `_upsertUserWord` 的判据）。
  ///
  /// ## 🔴 `pending_push` 由 [m.pendingPushAfterPull] 决定
  ///
  /// pull 下来的是**服务端已经知道的**数据 ⇒ 若一律标待推，下次 push 会把它们
  /// 整批推回去（回声），且在首次同步（全量）时最严重。同其余四张表。
  Future<int> _applyHighlights(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final remote = m.highlightFromPullJson(j);
      final id = remote['id'] as String? ?? '';
      if (id.isEmpty) continue;

      // ⚠️ 取**整行**（不是只取几列）：`mergeHighlight` 的「首次事实」那一组
      //    （正文 / offsets / 来源）都要读本地值 —— 少取一列会让合并**静默**
      //    用 `null` 覆盖真值（`Map` 取不存在的键返回 null，不报错）。
      final existing = await _userDb
          .query('highlight', where: 'id = ?', whereArgs: [id], limit: 1);
      final Map<String, Object?>? localRow =
          existing.isEmpty ? null : {...existing.first};
      final Map<String, Object?> merged =
          localRow != null ? m.mergeHighlight(localRow, remote) : {...remote};
      merged['pending_push'] = m.pendingPushAfterPull(
        localExisted: localRow != null,
        localWasPending:
            localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
      )
          ? 1
          : 0;
      await _upsertHighlight(merged);
      n++;
    }
    return n;
  }

  /// 按 `id` upsert 一行划线（**直写**，不经仓储的业务方法）。
  ///
  /// ⚠️ 列名**显式列出**（不依赖表的物理列顺序）——
  ///    `paused` 是 v1.9 用 `ALTER TABLE ADD COLUMN` 追加的，
  ///    而新建库是 `CREATE TABLE` 一次成型 ⇒ **两边的列顺序不同**。
  ///    显式列名让这个差异与本次写入无关（同 `bookmark.deleted` 那条教训）。
  Future<void> _upsertHighlight(Map<String, Object?> row) async {
    await _userDb.rawInsert(
      'INSERT INTO highlight '
      '(id, source_type, source_id, chapter_idx, start_offset, end_offset, '
      ' text, note, created_at, updated_at, deleted, pending_push, paused) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT (id) DO UPDATE SET '
      '  source_type  = excluded.source_type, '
      '  source_id    = excluded.source_id, '
      '  chapter_idx  = excluded.chapter_idx, '
      '  start_offset = excluded.start_offset, '
      '  end_offset   = excluded.end_offset, '
      '  text         = excluded.text, '
      '  note         = excluded.note, '
      '  created_at   = excluded.created_at, '
      '  updated_at   = excluded.updated_at, '
      '  deleted      = excluded.deleted, '
      '  pending_push = excluded.pending_push, '
      '  paused       = excluded.paused',
      [
        row['id'],
        row['source_type'],
        row['source_id'],
        row['chapter_idx'],
        row['start_offset'],
        row['end_offset'],
        row['text'],
        row['note'],
        row['created_at'],
        row['updated_at'],
        row['deleted'] ?? 0,
        row['pending_push'] ?? 0,
        row['paused'] ?? 0,
      ],
    );
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

  // ════════════════════════════════════════════════════════════
  // 🆕 2026-10-10：同步覆盖面补齐的 4 类（pull 侧）
  // ════════════════════════════════════════════════════════════

  /// 查词记录 → `lookup_event`（**日志，按 `uid` 幂等**）。
  ///
  /// 🔑 `INSERT OR IGNORE`（与 `review_log` 同一形态：事件不可变，PK 相同即重复）。
  /// ⚠️ `pending_push = 0` —— 拉回来的是**服务端已经知道的** ⇒ 不再推回去（防回声）。
  /// ⚠️ 显式列名（不依赖表的物理列顺序 —— `uid` / `pending_push` 是 `ALTER` 追加的）。
  Future<int> _applyLookupEvents(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final merged = m.lookupEventFromPullJson(j);
      final uid = merged['uid'] as String? ?? '';
      if (uid.isEmpty) continue;
      final changed = await _userDb.rawUpdate(
        'INSERT OR IGNORE INTO lookup_event '
        '(uid, word_id, spelling, article_id, sentence, position, looked_up_at, pending_push) '
        'VALUES (?,?,?,?,?,?,?,0)',
        [
          uid,
          merged['word_id'],
          merged['spelling'] ?? '',
          merged['article_id'],
          merged['sentence'],
          merged['position'],
          merged['looked_up_at'],
        ],
      );
      // `INSERT OR IGNORE` 被忽略时 affected = 0 ⇒ 不计数（幂等，不虚报）
      n += changed;
    }
    return n;
  }

  /// 书本内书签 → `book_marker`（本地有这本书）**或** `book_marker_pending`（还没有）。
  ///
  /// # 🔴 为什么分两条路
  /// `book_marker` 有 `FK → book(id) ON DELETE CASCADE` ⇒ 本地**没导入**那本书时
  /// 直接写会 **FK 失败**。而用户的真实流程是「新设备 → 同步 → 导入书 → 打开」，
  /// 同步往往**早于**导入 ⇒ 若丢弃，书签**永久丢失**（同 `book_progress` 的判据）。
  /// ⇒ 没有这本书时先按 `content_hash` 接住，等导入后由 [_claimBookMarkers] 认领。
  ///
  /// 🔑 合并用 [m.mergeBookMarker]（`deleted` 取 **OR** —— 本表没有 `updated_at`，
  ///    「谁更新谁赢」没有判据；而「取消书签」是终局意愿）。详见 `sync_merge.dart`。
  Future<int> _applyBookMarkers(List<Map<String, dynamic>> rows) async {
    final db = _bookDb;
    if (db == null || rows.isEmpty) return 0;
    var n = 0;
    try {
      for (final j in rows) {
        final remote = m.bookMarkerFromPullJson(j);
        final id = remote['id'] as String? ?? '';
        final hash = remote['content_hash'] as String? ?? '';
        if (id.isEmpty || hash.isEmpty) continue;

        final local = await db.query('book',
            columns: ['id'],
            where: 'content_hash = ?',
            whereArgs: [hash],
            limit: 1);
        if (local.isEmpty) {
          // 🔴 本地还没导入这本书 ⇒ 先接住（等导入后认领）
          await db.insert(
            'book_marker_pending',
            {
              'id': id,
              'content_hash': hash,
              'chapter_idx': remote['chapter_idx'],
              'scroll_ratio': remote['scroll_ratio'],
              'excerpt': remote['excerpt'],
              'created_at': remote['created_at'],
              'deleted': remote['deleted'] ?? 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          n++;
          continue;
        }

        final bookId = local.first['id'] as String;
        // ⚠️ 取**整行**（`mergeBookMarker` 的「首次事实」那组要读本地值 ——
        //    少取一列会让 `Map` 取不存在的键返回 `null`，**静默**覆盖真值）。
        final existing = await db
            .query('book_marker', where: 'id = ?', whereArgs: [id], limit: 1);
        final Map<String, Object?>? localRow =
            existing.isEmpty ? null : {...existing.first};
        // 🔑 本地行没有 `content_hash`（它在 `book` 表）⇒ 补上再合并，
        //    这样 [m.mergeBookMarker] 的两侧形状一致（它按 `created_at` 取较早端）。
        final merged = localRow != null
            ? m.mergeBookMarker({...localRow, 'content_hash': hash}, remote)
            : {...remote};
        await upsertMarkerRow(db, bookId: bookId, row: merged);
        n++;
      }
    } catch (e) {
      _say('sync.pull: 书签写入失败（跳过）: $e');
    }
    return n;
  }

  /// 把「本地已有这本书」的待认领书签写进 `book_marker`，并删掉 pending 行。
  ///
  /// 🔑 实现委托给 `book_marker_sync.dart::claimAllPendingMarkers`（**口径一处**）——
  ///    它与「导入后认领」（`book_importer`）**共用同一份实现**，差别只在筛选范围。
  /// ⚠️ 失败**不抛**（同步是后台行为）：pending 行仍在 ⇒ 下次 pull 会再试（自愈）。
  Future<int> _claimBookMarkers() async {
    final db = _bookDb;
    if (db == null) return 0;
    try {
      final n = await claimAllPendingMarkers(db);
      if (n > 0) _say('sync.pull: 认领书签 $n 条');
      return n;
    } catch (e) {
      _say('sync.pull: 认领书签失败（下次重试）: $e');
      return 0;
    }
  }

  /// 成就解锁 → `achievement_unlock`（`unlocked_at` 取**较早**）。
  Future<int> _applyAchievementUnlocks(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    var n = 0;
    for (final j in rows) {
      final remote = m.achievementUnlockFromPullJson(j);
      final key = remote['key'] as String? ?? '';
      if (key.isEmpty) continue;
      final existing = await _userDb.query('achievement_unlock',
          where: 'key = ?', whereArgs: [key], limit: 1);
      final Map<String, Object?>? localRow =
          existing.isEmpty ? null : {...existing.first};
      final merged =
          localRow != null ? m.mergeAchievementUnlock(localRow, remote) : {...remote};
      final pending = m.pendingPushAfterPull(
        localExisted: localRow != null,
        localWasPending:
            localRow != null && (localRow['pending_push'] as num?)?.toInt() == 1,
      );
      await _userDb.rawInsert(
        'INSERT INTO achievement_unlock (key, unlocked_at, pending_push) '
        'VALUES (?,?,?) '
        'ON CONFLICT (key) DO UPDATE SET '
        '  unlocked_at = excluded.unlocked_at, pending_push = excluded.pending_push',
        [key, merged['unlocked_at'], pending ? 1 : 0],
      );
      n++;
    }
    return n;
  }

  /// 应用设置 → `setting_sync` 表（LWW）+ **写回 prefs**。
  ///
  /// 🔑 返回的是**真正改变了 prefs 的键数** —— 它才是「要不要刷新读数 provider」的依据
  ///    （只写表不算：用户看到的是 prefs 驱动的设置项）。
  /// ⚠️ `_writePrefSetting == null`（未注入）⇒ 跳过，其余数据照常。
  ///
  /// ⚠️ 口径在 `settings_sync.dart::applySettings`（唯一一处）。
  Future<int> _applySettings(List<Map<String, dynamic>> rows) async {
    final write = _writePrefSetting;
    if (write == null || rows.isEmpty) return 0;
    try {
      final changed = await applySettings(_userDb, rows, writePref: write);
      return changed.length;
    } catch (e) {
      _say('sync.pull: 应用设置失败（跳过）: $e');
      return 0;
    }
  }
}
