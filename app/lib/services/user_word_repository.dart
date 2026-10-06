// CoEvo · 生词本（`user_word`）+ 查词记录（`lookup_event`）仓储 —— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）：
//   本地 `flutter analyze` 会崩，纯 Dart 才能独立验证。
//
// # 依据
// `docs/design/v1-final-design-authoritative-2026-09-25.md` §3.2（表定义）· §八 / §九（写入时机）
// `docs/review/step3-4c-word-writeback-plan-2026-09-28.md` §〇（定案）§四（复用点）
//
// # 🔑 与 `BookmarkRepository` 的异同（**别照搬，有两处是反向的**）
//
// | | `bookmark` | `user_word`（本文件） |
// |---|---|---|
// | 删除 | **硬删**（`DELETE`）—— 收藏是可再生的用户意图 | 🔴 **软删**（`deleted = 1`）—— 生词带学习数据 |
// | 内存集合 | 用 `Set<int>`（读多写极少 + 单条判定） | 🔴 **不用** —— 要 `COUNT` + 列表 + 排序，集合不合适 |
// | 复用什么 | —— | `parseUserDbUtc` · 幂等写入 · `pending_push` 模式 · 值类型 `==` |
//
// # 🔑 生词产生的唯一路径
// **用户查词**（不是「导入」——导入的是内容不是词）。所以本仓储的 `add()` 只应被
// **查词链路**调用，没有 `importWords()` 这类方法（语义纯净靠接口形状保证）。

import 'package:sqflite_common/sqlite_api.dart';

import '../models/article.dart' show ArticleLookup;
import 'bookmark_repository.dart' show kSqlNowUtc, parseUserDbUtc;

/// 🔴 2026-10-06 改为**引用公共常量**（原来此处内联了同一表达式）。
///
/// # 为什么（两件事，都是「改一处漏一处」的教训）
///
/// ① **消除第二份实现**：这个表达式原先在 `bookmark_repository`（2 处）与本文件
///    各写一份 —— 我先改了 bookmark 那两处，才想起这里也有一份。
///    同族判据：**同一口径只能一处权威**（本项目已在 `parseUserDbUtc` 上做过同样收敛）。
///
/// ② **精度必须是毫秒**（原为 `%S`）：`user_word.updated_at` 是同步合并的判定依据
///    （服务端 `excluded.updated_at > sync_user_word.updated_at`，**严格大于**）。
///    秒精度下「加入生词本 → 立刻点暂停」会得到**相同时间戳** ⇒ 暂停不生效。
///    📄 完整失败链见 `bookmark_repository.dart` 的 `kSqlNowUtc` 注释。
///
/// （原注释保留其价值：「`UPDATE` 时 `DEFAULT` 不生效（只作用于 `INSERT`），
///   必须显式赋值」—— 这条仍然成立，只是表达式改为共用。）
const String _nowUtcSql = kSqlNowUtc;

/// 🔴 **本库没有「生词本上限」**（2026-10-01 白哥定：免费可全量使用，收费点另议）。
///
/// 历史上这里有 `const int kUserWordLimitFree = 200`（免费层上限），
/// 已于 2026-10-01 **取消** —— 连同 `add()` 的 `enforceLimit` 参数与
/// `AddWordResult.limitReached` 分支一并删除。
///
/// ⚠️ **别把它加回来。** 若将来要重新引入门槛，先读这三条：
///   1. 它是「**需要登录**」的**唯一**依据 —— `plan-and-progress-2026-09-26.md:2128`
///      原文：「生词本**新增**（超 200 词上限）｜✅ **只有这里**（需要登录）」
///      → 取消后**没有任何功能需要登录**；
///   2. 该上限**在界面上本来就完全不可见**（见 `user_word_provider.dart` 的说明）
///      → 它只是一道**静默拦截**：用户不会被告知「为什么加不进去」；
///   3. 「按**唯一 lemma 数**计数」这个**口径**本身仍是对的
///      （`COUNT(*) WHERE deleted = 0`）→ 将来做统计/成就照用，
///      但**不要**把它变回「限额」。
///
/// 📄 决策依据：`docs/review/free-tier-limit-removal-assessment-2026-10-01.md`

/// 一条生词记录。
class UserWord {
  final int id;
  final String wordId;

  /// 冗余列的拼写（来自 `word.db`，写入时同步）。
  final String spelling;

  final int? sourceArticleId;

  /// 🔑 **首次**查出的语境（**不随后续查词覆盖** —— 取 `MIN(looked_up_at)` 那条）。
  final String? sourceSentence;

  final DateTime addedAt;
  final DateTime updatedAt;

  /// 🔑 **软删标记**：`true` = 用户已移出生词本，**但学习数据保留**。
  final bool deleted;

  final bool pendingPush;

  const UserWord({
    required this.id,
    required this.wordId,
    required this.spelling,
    this.sourceArticleId,
    this.sourceSentence,
    required this.addedAt,
    required this.updatedAt,
    required this.deleted,
    required this.pendingPush,
  });

  @override
  bool operator ==(Object other) =>
      other is UserWord &&
      other.id == id &&
      other.wordId == wordId &&
      other.spelling == spelling &&
      other.sourceArticleId == sourceArticleId &&
      other.sourceSentence == sourceSentence &&
      other.addedAt == addedAt &&
      other.updatedAt == updatedAt &&
      other.deleted == deleted &&
      other.pendingPush == pendingPush;

  @override
  int get hashCode => Object.hash(id, wordId, spelling, sourceArticleId,
      sourceSentence, addedAt, updatedAt, deleted, pendingPush);

  @override
  String toString() => 'UserWord(#$id $wordId "$spelling"'
      '${deleted ? ' · 已移出' : ''}${pendingPush ? ' · 待同步' : ''})';

  /// 转成**与 `user_word` 表列名一致**的 `Map`（供同步用）。
  ///
  /// 🔑 为什么要有它（而不是让 `sync_service` 自己拼）：
  ///    · 列名只在这一个类里出现 ⇒ 改名时只改一处（同 `ReviewState.toRow()` 的理由）
  ///    · `sync_merge` 的合并函数吃 `Map<String, Object?>`（**row 形状**）⇒
  ///      本方法是「强类型对象 → row 形状」的**唯一转换点**
  ///
  /// ⚠️ 时间用 `toUtc().toIso8601String()`：库里存的是毫秒精度（`%f`），
  ///    而 Dart 的 `toIso8601String()` 对「整毫秒」也输出 3 位小数
  ///    ⇒ **两种表示逐字相同**（断言 `verify_sync_merge.dart`【1】锁了这一点）。
  ///
  /// ⚠️ **不含 `pending_push`** —— 那是同步标记，由 `sync_merge`/`sync_service`
  ///    按各自的口径决定（见 `sync_merge.pendingPushAfterPull`）。
  Map<String, Object?> toPushRow() => {
        'word_id': wordId,
        'spelling': spelling,
        'source_article_id': sourceArticleId,
        'source_sentence': sourceSentence,
        'added_at': addedAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'deleted': deleted ? 1 : 0,
      };
}

/// 一条查词记录（`lookup_event`）。
///
/// 🔑 **这是「语境记录」，不是「生词」** —— 同一个词可有多条（在不同句子被查）。
class LookupEvent {
  final int id;
  final String? wordId;
  final String spelling;
  final int? articleId;
  final String? sentence;
  final int? position;
  final DateTime lookedUpAt;

  const LookupEvent({
    required this.id,
    this.wordId,
    required this.spelling,
    this.articleId,
    this.sentence,
    this.position,
    required this.lookedUpAt,
  });

  @override
  bool operator ==(Object other) =>
      other is LookupEvent &&
      other.id == id &&
      other.wordId == wordId &&
      other.spelling == spelling &&
      other.articleId == articleId &&
      other.sentence == sentence &&
      other.position == position &&
      other.lookedUpAt == lookedUpAt;

  @override
  int get hashCode => Object.hash(
      id, wordId, spelling, articleId, sentence, position, lookedUpAt);

  @override
  String toString() => 'LookupEvent(#$id "$spelling"'
      '${wordId == null ? ' · 未命中' : ' → $wordId'})';
}

/// `add()` 的结果 —— 调用方据此决定 UI 提示。
///
/// 🔑 **用枚举而非 `bool`**：`false` 无法区分「已在生词本」与「曾移出被复活」，
///    而这两种情况给用户的反馈不同（前者「已在生词本」；后者应被当作**真的加进来了** ——
///    复习页会重新看到它）。用 bool 会迫使调用方再查一次库。
///
/// ⚠️ 历史上还有第 4 个值 `limitReached`（免费层 200 词上限）——
///    2026-10-01 取消上限时**一并删除**。**别加回来**，理由见文件头。
enum AddWordResult {
  /// 本次真的新增了。
  added,

  /// 这个词**已在生词本**（未删除）—— 幂等，什么都没做。
  alreadyExists,

  /// 用户之前移出过，**本次复活**了（`deleted` 1→0）。
  revived,
}

/// 生词本 + 查词记录仓储。
class UserWordRepository {
  UserWordRepository(this._db);

  final Database _db;

  // ───────────────────────────────────────────────────────────
  // 生词本：读
  // ───────────────────────────────────────────────────────────

  /// 生词数（**只算未移出的** —— 「生词本里现在有几个词」）。
  ///
  /// ⚠️ 它**不再是「额度检查」**（200 上限已于 2026-10-01 取消，见文件头）；
  /// 现在只服务统计与断言（`verify_user_word.dart`）。
  ///
  /// 走 `idx_uw_alive` 的部分索引。
  Future<int> count() async {
    final rows = await _db
        .rawQuery('SELECT count(*) AS n FROM user_word WHERE deleted = 0');
    return (rows.first['n'] as num).toInt();
  }

  /// 是否已在生词本（未移出）。
  Future<bool> contains(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT 1 FROM user_word WHERE word_id = ? AND deleted = 0 LIMIT 1',
      [wordId],
    );
    return rows.isNotEmpty;
  }

  /// 生词本列表（按加入时间**倒序** —— 「我刚收了什么」）。
  ///
  /// ⚠️ 只返回**未移出**的；要含已移出请用 [listAll]。
  Future<List<UserWord>> list({int? limit, int? offset}) async {
    final rows = await _db.query(
      'user_word',
      where: 'deleted = 0',
      orderBy: 'added_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// 含已移出的全部记录（调试 / 将来「恢复」功能用）。
  Future<List<UserWord>> listAll() async {
    final rows = await _db.query('user_word', orderBy: 'added_at DESC');
    return rows.map(_fromRow).toList();
  }

  /// 单个词的记录（含已移出的）—— 查词时判断「已在 / 复活 / 新增」用。
  Future<UserWord?> findByWordId(String wordId) async {
    final rows = await _db
        .query('user_word', where: 'word_id = ?', whereArgs: [wordId], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  // ───────────────────────────────────────────────────────────
  // 生词本：写
  // ───────────────────────────────────────────────────────────

  /// 加入生词本（**查词链路调用**）。
  ///
  /// ## 三种分支（由 [AddWordResult] 表达）
  /// 1. **已在**（`deleted = 0`）→ [AddWordResult.alreadyExists]，**什么都不改**
  ///    🔑 刻意**不刷新** `added_at` —— 它表达「我第一次收它是什么时候」，
  ///       重复查词不该把它改成「我什么时候又查了一次」（同 `bookmark` 的幂等理由）。
  /// 2. **曾移出**（`deleted = 1`）→ [AddWordResult.revived]，`deleted` 置 0
  ///    🔑 白哥定 Q3-A **复活**：删除是「这个我先不学了」，不是「永远别出现」——
  ///       用户重修时不该被自己的旧决定挡住。`added_at` 同样**不改**（保留最初那次）。
  /// 3. **全新** → 写入 → [AddWordResult.added]
  ///
  /// ## `source_sentence` 只在**首次**写入
  /// ⚠️ 分支 2 复活时**不覆盖** `source_sentence` —— 记忆里的明确决策：
  ///    「不用『最后一次查词语境』覆盖例句」→ 取首次。
  ///    （断言锁「与 `lookup_event` 里该词最早一条一致」，见 `verify_user_word.dart`）
  ///
  /// [enforceLimit] 已于 2026-10-01 **删除**（取消 200 上限，见文件头）。
  Future<AddWordResult> add(
    String wordId,
    String spelling, {
    String? sentence,
    int? articleId,
  }) async {
    final existing = await findByWordId(wordId);

    if (existing != null && !existing.deleted) {
      return AddWordResult.alreadyExists;
    }

    if (existing != null && existing.deleted) {
      // 复活：只翻标志位，**不动** `added_at` / `source_sentence`
      //
      // 🔴 `updated_at` 必须用 **`rawUpdate`** —— 不能走 `update()` 的 map：
      //    map 里的值会被**参数化绑定**（当作字面量），于是
      //    `'updated_at': "strftime(...)"` 会把**那串文本本身**写进列里，
      //    而不是执行它 → 列里出现 "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
      //    → 读取时 `parseUserDbUtc` 抛 FormatException。
      //    ⚠️ 而且它**写入时不报错**，只在**读取时**炸 —— 「静默污染、延迟暴露」。
      //    （同 `review_list_query.upsertState` 用 `rawInsert` 的理由。）
      await _db.rawUpdate(
        'UPDATE user_word SET deleted = 0, pending_push = 1, '
        "updated_at = $_nowUtcSql WHERE word_id = ?",
        [wordId],
      );
      return AddWordResult.revived;
    }

    // 🔴 全新 → **直接写入**。这里**没有上限**（2026-10-01 取消，见文件头）。
    await _db.insert(
      'user_word',
      {
        'word_id': wordId,
        'spelling': spelling,
        'source_article_id': articleId,
        'source_sentence': sentence,
        // 不传 `added_at` / `updated_at` / `deleted` / `pending_push`
        // —— 由 DDL 的 DEFAULT 生成（用**数据库时钟**，同 `bookmark` 的理由）
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return AddWordResult.added;
  }

  /// 移出生词本（🔴 **软删**：`deleted = 1`）。
  ///
  /// 🔑 与 `bookmark.remove()` 的**硬删**相反 —— 见文件头对照表。
  /// 返回 `true` = 本次真的改了状态。
  Future<bool> remove(String wordId) async {
    // ⚠️ 同 `add()` 的复活分支：`updated_at` 须用 `rawUpdate`（`update()` 的 map
    //    会把 SQL 表达式当字面量写入）→ 见那里的详细说明。
    final n = await _db.rawUpdate(
      'UPDATE user_word SET deleted = 1, pending_push = 1, '
      "updated_at = $_nowUtcSql WHERE word_id = ? AND deleted = 0",
      [wordId],
    );
    return n > 0;
  }

  /// **暂停** —— 复习页（单一列表）里那一行的动作。
  ///
  /// # 🔑 为什么是别名而不是新方法/新字段
  /// 复习页规格（`ui-ux` §6.2，白哥原话）：
  /// > 「一个词**离开视野**，不是『移出生词本』，而是它的 **FSRS 状态变了**
  /// >   （已掌握 / 暂停）」
  ///
  /// 而 `deleted` 这一列的**原始语义本来就是**「用户先不学这个词了，数据仍在」
  /// （见 `user_db_schema.sql` 的 `deleted` 注释）→ 它就是「暂停」，
  /// **只是 UI 上的说法不同**。
  ///
  /// 🔑 所以**不新增字段、不做迁移**：曾考虑给 `card_review_state` 加 `paused` 列
  /// （要 version 3 迁移），但那是**同一个语义的第二个出处** ——
  /// 而复习列表本来就要 JOIN `user_word`（拿暂停状态），复用它零成本。
  ///
  /// 撤销 = 再次查该词（[add] 的「复活」分支，`deleted` 1→0）。
  Future<bool> pause(String wordId) => remove(wordId);

  /// 待同步的生词（`pending_push = 1`）—— 供将来的增量 push 用。
  /// ⚠️ 当前**无调用方**（同步属 Phase 3）；放着是为了「表 + 索引 + 查询」齐备。
  Future<List<UserWord>> pending() async {
    final rows = await _db.query('user_word',
        where: 'pending_push = 1', orderBy: 'added_at ASC');
    return rows.map(_fromRow).toList();
  }

  /// 标记已同步（供将来的 push 成功后调用）。
  Future<void> markSynced(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final ph = List.filled(list.length, '?').join(',');
    await _db.update('user_word', {'pending_push': 0},
        where: 'id IN ($ph)', whereArgs: list);
  }

  // ───────────────────────────────────────────────────────────
  // 查词记录（lookup_event）
  // ───────────────────────────────────────────────────────────

  /// 记一次查词。
  ///
  /// 🔑 **命中与未命中都记**（白哥定 Q2：「都记」）——
  ///    `word_id` 可空正是为「查了但词库里没有」预留的（v1 原文即可空）。
  ///    也让「我查过哪些词」完整，将来能做「查词历史」。
  ///
  /// ⚠️ 本方法是**纯日志**：无 `pending_push`、不参与同步（照 v1）。
  Future<int> recordLookup({
    String? wordId,
    required String spelling,
    int? articleId,
    String? sentence,
    int? position,
  }) async {
    return _db.insert('lookup_event', {
      'word_id': wordId,
      'spelling': spelling,
      'article_id': articleId,
      'sentence': sentence,
      'position': position,
    });
  }

  /// 某词的**首次**语境（`MIN(looked_up_at)` 那条）—— 回填 `source_sentence` 用。
  Future<LookupEvent?> firstLookupOf(String wordId) async {
    final rows = await _db.query(
      'lookup_event',
      where: 'word_id = ?',
      whereArgs: [wordId],
      orderBy: 'looked_up_at ASC, id ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : _lookupFromRow(rows.first);
  }

  /// 某词的全部查词记录（按时间升序）。
  Future<List<LookupEvent>> lookupsOf(String wordId) async {
    final rows = await _db.query('lookup_event',
        where: 'word_id = ?',
        whereArgs: [wordId],
        orderBy: 'looked_up_at ASC, id ASC');
    return rows.map(_lookupFromRow).toList();
  }

  /// 查词总数（含未命中）。
  Future<int> lookupCount() async {
    final rows =
        await _db.rawQuery('SELECT count(*) AS n FROM lookup_event');
    return (rows.first['n'] as num).toInt();
  }

  /// **这篇文章里我查过哪些词**（+ 各自的 FSRS 状态）—— **痕迹的数据源**。
  ///
  /// # 🔴 为什么必须是「按文章」而不是「整个生词本」
  ///
  /// 设计稿把痕迹的语义定得很明确（`coevo_tokens.dart` 的原文）：
  /// > 「痕迹只表达『**我和这篇文章的关系**』」
  ///
  /// 若用全部生词（`user_word`），**打开任何一篇文章都会显示同一批底色** ——
  /// 那表达的就不是「我和这篇的关系」，而是「我有个生词本」。
  /// 而 `lookup_event.article_id` 正是为这个语义记的（「哪篇文章查的」）。
  ///
  /// # 🔑 未命中的词**也要留痕**（有意如此）
  /// `lookup_event.word_id` 可空 = 「查了但词库里没有」（白哥定 Q2：「都记」）。
  /// 这类词不在生词本里，但用户**确实查过它** → 应显示为「刚查过」（`reps = 0`）。
  /// → SQL 用 `LEFT JOIN`：JOIN 不到 → `reps = 0` → `forReps(0)` 给「刚查过」样式 ✅
  ///   **恰好好处**：不需要为「未命中」单独写一条分支。
  ///
  /// # 🔑 `MAX(...)` 的作用（不是随手写的）
  /// 同一个 spelling 可能在 `lookup_event` 里有多行（查了多次），
  /// 且其中可能有「先未命中（`word_id` 为 NULL，后来词库补上了）」与
  /// 「已命中（有 `word_id`）」两种。
  /// 按 `spelling` 分组后取 `MAX(crs.reps)` → 拿到**有状态的那一条**的值
  /// （未命中的那行 JOIN 不到，`reps` 为 NULL，`MAX` 会忽略 NULL）。
  ///
  /// # ⚠️ 不含「已掌握」的词 —— 不是筛掉，而是**留给渲染层**
  /// `reps >= 3 && lapses == 0` 的词仍会出现在结果里（它是**事实**），
  /// 由 `TraceTokens.forReps()` 返回 `null` → 不产生标记（白哥 2026-09-27 决策）。
  /// 🔑 **本层不筛**：筛选是表现层的判断，写在数据层会让「已掌握」这个词
  ///    在别处（如将来的「本文新词」统计）也用不到。
  Future<List<ArticleLookup>> lookupsForArticle(int articleId) async {
    final rows = await _db.rawQuery(
      'SELECT le.spelling AS spelling, '
      '       COALESCE(MAX(crs.reps), 0) AS reps, '
      '       COALESCE(MAX(crs.lapses), 0) AS lapses '
      'FROM lookup_event le '
      'LEFT JOIN card_review_state crs ON crs.word_id = le.word_id '
      'WHERE le.article_id = ?1 '
      'GROUP BY le.spelling',
      [articleId],
    );
    return rows
        .map((r) => ArticleLookup(
              (r['spelling'] as String?) ?? '',
              reps: (r['reps'] as num?)?.toInt() ?? 0,
              lapses: (r['lapses'] as num?)?.toInt() ?? 0,
            ))
        .where((l) => l.word.isNotEmpty)
        .toList();
  }

  // ───────────────────────────────────────────────────────────

  UserWord _fromRow(Map<String, Object?> r) => UserWord(
        id: (r['id'] as num).toInt(),
        wordId: r['word_id'] as String,
        spelling: r['spelling'] as String,
        sourceArticleId: (r['source_article_id'] as num?)?.toInt(),
        sourceSentence: r['source_sentence'] as String?,
        addedAt: parseUserDbUtc(r['added_at'] as String),
        updatedAt: parseUserDbUtc(r['updated_at'] as String),
        deleted: (r['deleted'] as num).toInt() == 1,
        pendingPush: (r['pending_push'] as num).toInt() == 1,
      );

  LookupEvent _lookupFromRow(Map<String, Object?> r) => LookupEvent(
        id: (r['id'] as num).toInt(),
        wordId: r['word_id'] as String?,
        spelling: r['spelling'] as String,
        articleId: (r['article_id'] as num?)?.toInt(),
        sentence: r['sentence'] as String?,
        position: (r['position'] as num?)?.toInt(),
        lookedUpAt: parseUserDbUtc(r['looked_up_at'] as String),
      );
}
