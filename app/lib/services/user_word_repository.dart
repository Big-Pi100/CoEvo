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

import 'bookmark_repository.dart' show parseUserDbUtc;

/// `updated_at` 用的 SQL 表达式 —— 与 DDL 的 `DEFAULT` **同一个表达式**。
///
/// 🔑 为什么要常量共用：`UPDATE` 时 `DEFAULT` **不生效**（只作用于 `INSERT`），
/// 必须显式赋值。若这里手写一份格式串，就与 DDL 有**两处定义** →
/// 改一处忘一处会让「INSERT 生成的时间」与「UPDATE 生成的时间」格式不同
/// （一个带 `Z` 一个不带 → `parseUserDbUtc` 会对后者抛错，且只在 UPDATE 路径上）。
const String _nowUtcSql = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')";

/// 生词本**上限**（免费层）。
///
/// 🔑 口径 = **`COUNT(*) WHERE deleted = 0`**（唯一 lemma 数）——
/// 与「来源 / 查了几次」无关 → **天然防绕过**（这是产品设计，不是限制手段）。
/// 已软删的**不占额度**（用户明确不要了，不该继续占位）。
const int kUserWordLimitFree = 200;

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

/// `add()` 的结果 —— 调用方据此决定 UI 提示与是否要引导订阅。
///
/// 🔑 **用枚举而非 `bool`**：`false` 无法区分「已存在」与「已达上限」，
///    而这两种情况要给**完全不同的**用户反馈（一个是「已在生词本」、
///    另一个是「要订阅」）。用 bool 会迫使调用方再查一次库。
enum AddWordResult {
  /// 本次真的新增了。
  added,

  /// 这个词**已在生词本**（未删除）—— 幂等，什么都没做。
  alreadyExists,

  /// 用户之前移出过，**本次复活**了（`deleted` 1→0）。
  revived,

  /// 🔴 **已达免费层上限**（且这是个新词）→ 未写入。
  /// 调用方应提示 + 引导订阅（白哥定 Q1-A：**不打断阅读**，浮层照常显示）。
  limitReached,
}

/// 生词本 + 查词记录仓储。
class UserWordRepository {
  UserWordRepository(this._db);

  final Database _db;

  // ───────────────────────────────────────────────────────────
  // 生词本：读
  // ───────────────────────────────────────────────────────────

  /// 生词数（**只算未移出的** —— 就是 200 上限的口径）。
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
  /// 3. **全新** → 检查上限 → [AddWordResult.added] 或 [AddWordResult.limitReached]
  ///
  /// ## `source_sentence` 只在**首次**写入
  /// ⚠️ 分支 2 复活时**不覆盖** `source_sentence` —— 记忆里的明确决策：
  ///    「不用『最后一次查词语境』覆盖例句」→ 取首次。
  ///    （断言锁「与 `lookup_event` 里该词最早一条一致」，见 `verify_user_word.dart`）
  ///
  /// [enforceLimit] 传 `false` 可绕过上限（仅供测试与将来的付费用户）。
  Future<AddWordResult> add(
    String wordId,
    String spelling, {
    String? sentence,
    int? articleId,
    bool enforceLimit = true,
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

    // 全新：先判上限（免费层）
    if (enforceLimit && await count() >= kUserWordLimitFree) {
      return AddWordResult.limitReached;
    }

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
