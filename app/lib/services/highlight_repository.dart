// CoEvo · 划线记忆（highlight）仓储 —— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `bookmark_repository.dart` 的理由）
//    ⇒ 纯 Dart 才能被脚本独立驱动验证。
//
// # 依据
// `docs/design/visual-generic-card-2026-10-07.html` v2（白哥定：划线任何长度 → 进记忆队列）
// 表定义见 `assets/sql/user_db_schema.sql` v1.7 的 `highlight`。
//
// # 🔑 它与别的仓储**最不一样的一点**：它不碰 FSRS
//
// 划线要进复习队列，靠的是**另外写一行 `card_review_state`**
// （`word_id = 'hl:<uuid>'`，见 `services/highlight_id.dart`）——
// 而那一步走**既有的** `ReviewListQuery.upsertState`。
//
// ⇒ 本仓储**只负责「划线本身」**（内容 / 位置 / 笔记 / 软删）。
//    「入队」是调用方的一个**组合动作**（写本表 + 写 `card_review_state`）——
//    分开的理由：**两张表各自的失败语义不同**（划线存不上 = 用户白划了；
//    队列状态写不上 = 划线还在、只是暂时不复习）⇒ 不该塞进一个「要么全成要么全败」里。
//
// # ✅ 2026-10-09：本表**已纳入跨设备同步**
//
// `pending()` / `markSynced()` 曾被标注为「无消费者」—— 那份缺失正是
// **「无主划线卡」**的根因（`review_log` 在同步、它引用的划线本体却从不上去）。
// 现在由 `sync_service` 的 push/pull 接线，合并口径在 `sync_merge.dart`：

import 'package:sqflite_common/sqlite_api.dart';

import 'bookmark_repository.dart' show kSqlNowUtc, parseUserDbUtc;
import 'highlight_id.dart' show highlightUuidOf;

/// 划线的来源类型。
///
/// 🔑 两者的**定位方式不同**：文章是单页（无章节）、书要带 `chapter_idx`。
/// 但**同一张表** —— 因为「复习怎么考」与「笔记」完全一样，分表只会造成两份实现。
enum HighlightSourceType {
  article,
  book;

  /// 存进 DB 的字面量（**与 DDL 的 `CHECK (source_type IN (...))` 必须逐字一致**）。
  String get wire => name;

  /// 从 DB 字面量解析（不认识就抛 —— 静默回落到 `article` 会让书的划线被当成文章的）。
  static HighlightSourceType parse(String raw) => HighlightSourceType.values
      .firstWhere((e) => e.wire == raw,
          orElse: () => throw FormatException('未知的划线来源类型："$raw"'));
}

/// 一条划线。
class Highlight {
  /// uuid v4（端侧生成）—— **同时也是复习队列里的 `hl:<uuid>` 的 uuid 部分**。
  final String id;

  final HighlightSourceType sourceType;

  /// 文章 id（整数的文本形式）或书的 uuid。
  final String sourceId;

  /// 章内下标 —— **只有书有**；文章是单页 ⇒ `null`。
  final int? chapterIdx;

  /// 章内字符 offset（半开区间 `[start, end)`）。
  final int startOffset;
  final int endOffset;

  /// 🔴 **选中的原文** —— 复习时的**标准答案**。
  ///
  /// 🔑 存全文而**不是**只存 offset：offset 依赖「同一份正文」这个前提，
  ///    而文章正文可能被重新抓取（内容源会更新）⇒ 正文一变，offset 就**指到别处**。
  ///    存全文后，即使定位偏了，**复习内容仍然是对的**。
  final String text;

  /// 用户的笔记。
  ///
  /// 🔴 **默写判定之前不得显示** —— 笔记是用户自己写的，很可能**就写着答案**（泄题）。
  ///    与「原文」同一条规则：**判定后才给**。
  final String? note;

  final DateTime createdAt;

  /// **最后一次改变该条状态的时刻**（改笔记 / 取消也要刷新）——
  /// 同步按「谁的时间戳更新谁赢」判定，不刷新会**丢弃这次变更**。
  /// （同 `bookmark.bookmarked_at` 的教训，见 `bookmark_repository.dart` 文件头 §④）
  final DateTime updatedAt;

  /// 软删（`deleted = 1`）。
  ///
  /// 🔑 软删而**不是**硬删：并集同步下硬删会被别端**并回来**（`bookmark` 已踩过）。
  ///    而且「取消划线」≠「内容没用了」—— 那上面可能还挂着一条笔记。
  final bool deleted;

  /// 🆕 v1.9（2026-10-08）**暂停复习** —— 复习页那一行的「暂停」动作对划线卡的落点。
  ///
  /// 🔴 与 [deleted] 是**两个语义**（见 `user_db_schema.sql` 该列的说明）：
  ///    · `deleted` = 这条划线不要了（正文的下划线消失 · 笔记页不再列它）
  ///    · `paused`  = 划线**还在**，只是**不参与复习排期**（离开复习列表的视野）
  ///    ⚠️ 笔记页**照常列** `paused` 的条目 —— 它是「我记过什么」的清单，
  ///       不是「待复习队列」；**恢复入口也在那里**（见 `highlights_screen`）。
  final bool paused;

  /// 🆕 v1.12（2026-10-11）**该划线片段的中文译文** —— 复习时的**提示之一**。
  ///
  /// 🔑 与首字母骨架**同时显示**（白哥定 · **不是替换关系**）：译文考「用英文表达
  ///    这个意思」（产出），骨架考「回忆原文措辞」（记忆）—— 两者考察的能力不同。
  ///
  /// ⚠️ **`null` / 空串 = 合法常态**（还没翻译/补译过）⇒ 复习页只显示骨架。
  /// ⚠️ 与 [note] 不同：笔记**判定前不得显示**（可能写着答案），而译文**必须一开始就给** ——
  ///    它就是提示本身。
  final String? translation;

  final bool pendingPush;

  const Highlight({
    required this.id,
    required this.sourceType,
    required this.sourceId,
    this.chapterIdx,
    required this.startOffset,
    required this.endOffset,
    required this.text,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.paused = false,
    this.translation,
    required this.pendingPush,
  });

  /// 给列表用的一行摘录（单行、截断到 60 字符）。
  String get excerpt {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 60)}…';
  }

  /// 带笔记的副本（不可变模型 —— 改笔记走这里而不是原地改）。
  ///
  /// 🔴 **复制时必须带上每一个字段** —— 漏一个就是「改笔记把那个字段静默清空」。
  ///    （本项目已踩过同类：`syncNow()` 逐字段复制漏 3 个计数 ⇒ 界面不刷新。）
  Highlight withNote(String? newNote) => Highlight(
        id: id,
        sourceType: sourceType,
        sourceId: sourceId,
        chapterIdx: chapterIdx,
        startOffset: startOffset,
        endOffset: endOffset,
        text: text,
        note: newNote,
        createdAt: createdAt,
        updatedAt: updatedAt,
        deleted: deleted,
        paused: paused,
        translation: translation,
        pendingPush: pendingPush,
      );

  /// 待推送的行（字段名与后端 `HighlightInput` **逐字一致**）。
  ///
  /// 🔴 字段名写错**不会报错** —— 对端 serde 默认忽略未知字段 ⇒ 那一列**静默传空**。
  ///    由 `verify_sync_merge.dart`【8】核对契约表（读 Rust 源码比对结构体字段）。
  ///
  /// 🔑 时间戳统一 `toUtc().toIso8601String()`（与 `UserWord.toPushRow` 同一形态，
  ///    毫秒精度）—— 服务端的合并判据依赖「字典序 == 时间序」。
  /// ⚠️ `chapter_idx` 传 `null`（文章没有章节号），**不传 0** ——
  ///    `0` 会被读成「第 0 章」，与「不适用」是两件事。
  Map<String, Object?> toPushRow() => {
        'id': id,
        'source_type': sourceType.wire,
        'source_id': sourceId,
        'chapter_idx': chapterIdx,
        'start_offset': startOffset,
        'end_offset': endOffset,
        'text': text,
        'note': note,
        'paused': paused ? 1 : 0,
        'deleted': deleted ? 1 : 0,
        'translation': translation,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  @override
  String toString() =>
      'Highlight($id · ${sourceType.wire}:$sourceId'
      '${chapterIdx == null ? '' : '#$chapterIdx'}@$startOffset-$endOffset'
      '${deleted ? ' · 已取消' : ''}${paused ? ' · 已暂停' : ''}'
      '${note == null ? '' : ' · 有笔记'}'
      '${translation == null ? '' : ' · 有译文'})';
}

/// 划线仓储。
class HighlightRepository {
  HighlightRepository(this._db);

  final Database _db;

  /// 新增一条划线。**幂等**：同 id 已存在（含**曾被软删**）则恢复它。
  ///
  /// 🔴 **不能用 `INSERT OR IGNORE`**（与 `bookmark.add` 同一个陷阱）：
  ///    若该 id 曾经被软删（`deleted = 1`），PK 冲突会让 `INSERT` 被**忽略**
  ///    ⇒ 那行仍是 `deleted = 1` ⇒ **划线不生效**，而界面看着「点了没反应」（**静默**）。
  /// ✅ 用 upsert：不存在则插；存在则**归零 `deleted` + 刷新 `updated_at`**。
  Future<void> add({
    required String id,
    required HighlightSourceType sourceType,
    required String sourceId,
    int? chapterIdx,
    required int startOffset,
    required int endOffset,
    required String text,
    String? note,
    /// 🆕 2026-10-11：这条划线的**中文译文**（可空）。
    ///
    /// 🔑 **归一化在 Dart 侧做**（与 [setTranslation] 同一口径：`trim().isEmpty` ⇒ `null`）——
    ///    于是下面的 SQL 只需 `COALESCE`，不必再写 `NULLIF(TRIM(...))`：
    ///    🔴 SQLite 的 `TRIM()` **只认 ASCII 空格**，而 Dart 的 `trim()` 认全套 Unicode 空白
    ///    ⇒ 口径只有落在**能表达完整语义的那一侧**（Dart）才不漂；
    ///    否则 `'\u00a0'`（不换行空格）会被 SQL 侧的 `TRIM` 放过、当成有效译文存下来。
    ///    📌 判据：**跨实现的「保持一致」必须落到每一个共享定义** ——
    ///    这里干脆把归一化**收在一处**，让 SQL 侧无口径可漂。
    String? translation,
  }) async {
    final tr = (translation == null || translation.trim().isEmpty)
        ? null
        : translation.trim();
    await _db.rawInsert(
      '''
      INSERT INTO highlight
        (id, source_type, source_id, chapter_idx, start_offset, end_offset,
         text, note, translation, created_at, updated_at, deleted, pending_push)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, $kSqlNowUtc, $kSqlNowUtc, 0, 1)
      ON CONFLICT (id) DO UPDATE SET
        source_type  = excluded.source_type,
        source_id    = excluded.source_id,
        chapter_idx  = excluded.chapter_idx,
        start_offset = excluded.start_offset,
        end_offset   = excluded.end_offset,
        text         = excluded.text,
        -- 🔴 **只在有值时覆盖**。若写成无条件 `translation = excluded.translation`：
        --    用户「划线（无译文）→ 批量补译（有译文）→ 又在正文里重划同一段」时
        --    （`ON CONFLICT` 正是「曾被软删的恢复」那条路径）会**把刚补的译文清空**，
        --    而且**不报错**（静默）。
        -- ✅ 与合并口径（`sync_merge._pickTranslation` 的「有值者胜」）**同一条规则**。
        translation  = COALESCE(excluded.translation, highlight.translation),
        deleted      = 0,
        paused       = 0,
        updated_at   = $kSqlNowUtc,
        pending_push = 1
      ''',
      [
        id,
        sourceType.wire,
        sourceId,
        chapterIdx,
        startOffset,
        endOffset,
        text,
        note,
        tr,
      ],
    );
  }

  /// 某一「来源」（文章 / 一本书）里的全部划线 —— 正文渲染时一次取全。
  ///
  /// 🔑 按 `start_offset` **升序**：正文渲染要按位置画，不需要再排一次。
  Future<List<Highlight>> listForSource({
    required HighlightSourceType sourceType,
    required String sourceId,
    int? chapterIdx,
  }) async {
    final rows = await _db.query(
      'highlight',
      where: 'deleted = 0 AND source_type = ? AND source_id = ?'
          '${chapterIdx == null ? '' : ' AND chapter_idx = ?'}',
      whereArgs: [
        sourceType.wire,
        sourceId,
        if (chapterIdx != null) chapterIdx,
      ],
      orderBy: 'start_offset ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 全部划线（按创建时间倒序 —— 「我刚划了什么」）。
  Future<List<Highlight>> listAll({int? limit, int? offset}) async {
    final rows = await _db.query(
      'highlight',
      where: 'deleted = 0',
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 按 id 取（复习取卡时要读 [Highlight.text] 作为标准答案）。
  ///
  /// ⚠️ **不过滤 `deleted`** —— 复习页可能正拿着一个刚被取消的 id，
  ///    此时应给出「已取消」的明确状态，而不是 `null`（`null` 会被当成「数据坏了」）。
  Future<Highlight?> byId(String id) async {
    final rows = await _db.query('highlight', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// 写 / 清笔记（`null` 或空白 = 清除）。
  ///
  /// 🔑 **必须刷新 `updated_at` + `pending_push`** —— 改笔记是一次真实的用户变更。
  Future<void> setNote(String id, String? note) async {
    final n = (note == null || note.trim().isEmpty) ? null : note.trim();
    await _db.rawUpdate(
      'UPDATE highlight SET note = ?, updated_at = $kSqlNowUtc, pending_push = 1 '
      'WHERE id = ?',
      [n, id],
    );
  }

  /// 写 / 清**译文**（`null` 或空白 = 清除）—— 🆕 v1.12（2026-10-11）。
  ///
  /// 🔑 **必须刷新 `updated_at` + `pending_push`**（与 [setNote] 同规矩，理由更要紧）：
  ///    服务端 UPSERT 的 `WHERE excluded.updated_at > sync_highlight.updated_at OR ...`
  ///    ⇒ **只写译文而不刷时间戳，这次更新会被整条跳过**
  ///    ⇒ 静默形态：**本地有译文、云端永远没有、别端永远拉不到**。
  Future<void> setTranslation(String id, String? translation) async {
    final v = (translation == null || translation.trim().isEmpty)
        ? null
        : translation.trim();
    await _db.rawUpdate(
      'UPDATE highlight SET translation = ?, updated_at = $kSqlNowUtc, pending_push = 1 '
      'WHERE id = ?',
      [v, id],
    );
  }

  /// 还**没有译文**的划线（供「批量补译」用）—— 🆕 v1.12。
  ///
  /// 判据：`translation IS NULL OR TRIM(translation) = ''` —— **空串也算缺**
  ///    （复习页对空串与 NULL 一视同仁，判据必须与消费点一致）。
  ///
  /// ⚠️ **只取 `deleted = 0`**：已取消的划线不再复习 ⇒ 补它的译文是**白花钱**。
  /// ⚠️ **`paused` 的要补** —— 它仍在笔记页列着（显示「暂停」），用户可能恢复
  ///    ⇒ 补了才有用。这与上面那条**一取一舍**，两条都是有意为之。
  Future<List<Highlight>> withoutTranslation({int? limit}) async {
    final rows = await _db.query(
      'highlight',
      where: "deleted = 0 AND (translation IS NULL OR TRIM(translation) = '')",
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 取消划线（**软删**）。
  ///
  /// 🔴 同样**必须刷新 `updated_at`**：同步按「谁的时间戳更新谁赢」判定，
  ///    不刷新 ⇒ 取消传上去的值与创建时**同值** ⇒ 服务端保留旧的 `deleted = 0`
  ///    ⇒ 别端拉回去 ⇒ **「取消了的划线又自己回来」**。
  ///    （这正是 `bookmark.remove` 2026-10-06 才补上的那条，见其注释。）
  Future<void> remove(String id) async {
    await _db.rawUpdate(
      'UPDATE highlight SET deleted = 1, updated_at = $kSqlNowUtc, pending_push = 1 '
      'WHERE id = ?',
      [id],
    );
  }

  /// **暂停复习** —— 复习页那一行的「暂停」动作（2026-10-08）。
  ///
  /// 入参是**复习卡上的 `word_id`**（`hl:<uuid>`，见 `highlight_id.dart`）——
  /// 与 `UserWordRepository.pause(wordId)` **对称**：调用方（复习页）手上拿到的就是它，
  /// 不必自己剥前缀（剥前缀的口径只能留在 `highlight_id.dart` 一处）。
  ///
  /// 🔴 与 [remove] **不是**一件事 —— 合并会把「暂停」变成「删除」：
  ///    · [remove] = 这条划线不要了 · [pause] = 划线还在，只是不参与排期
  ///
  /// 返回 `true` = 本次**真的**改了状态。`false` 有两种含义，都**不是**错误：
  /// ① 它本来就是暂停态（幂等）② 传进来的 id 不是划线卡（不归本仓储管）。
  Future<bool> pause(String wordId) => _setPaused(wordId, true);

  /// 恢复复习 —— 入口在「笔记」页那一条上（`highlights_screen`）。
  Future<bool> resume(String wordId) => _setPaused(wordId, false);

  /// [pause] / [resume] 的**唯一实现**（一处权威）。
  ///
  /// ⚠️ 与 [setNote] / [remove] **同一条规矩**：必须刷 `updated_at` + `pending_push`。
  ///    `updated_at` 是同步的「谁更新谁赢」判据 —— 不刷新 ⇒ 这次变更传上去时与
  ///    旧值**同一时间戳** ⇒ 服务端保留旧值 ⇒ 别端拉回去 ⇒ **「暂停了又自己恢复」**
  ///    （[remove] 的注释里记着同族的坑）。
  ///
  /// 🔑 `WHERE paused = ?`（取反）—— 让「本来就已经是那个状态」返回 0 行（幂等）。
  /// 🔑 `AND deleted = 0` —— 已取消的划线不该被暂停/恢复（它已经不在视野里）。
  Future<bool> _setPaused(String wordId, bool paused) async {
    final id = highlightUuidOf(wordId);
    if (id == null) return false; // 不是划线卡 ⇒ 不归本仓储管

    final n = await _db.rawUpdate(
      'UPDATE highlight SET paused = ?, updated_at = $kSqlNowUtc, pending_push = 1 '
      'WHERE id = ? AND paused = ? AND deleted = 0',
      [paused ? 1 : 0, id, paused ? 0 : 1],
    );
    return n > 0;
  }

  /// 未删的划线条数。
  Future<int> count() async {
    final rows = await _db
        .rawQuery('SELECT COUNT(*) AS n FROM highlight WHERE deleted = 0');
    return (rows.first['n'] as num).toInt();
  }

  /// 待同步的划线（`pending_push = 1`）。
  ///
  /// 🔑 消费方：`sync_service.pushOnce()`（2026-10-09 接入）——
  ///    在此之前它**没有调用方**（「表有了、索引有了、查询也有了」但没接线），
  ///    而正是那份缺失造成了「无主划线卡」：`review_log`（复习事件）在同步，
  ///    它引用的划线本体却**从不上去** ⇒ 重装 / 换机的设备拿不到划线本体。
  Future<List<Highlight>> pending({int? limit}) async {
    final rows = await _db.query('highlight',
        where: 'pending_push = 1', orderBy: 'updated_at ASC', limit: limit);
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 标记已同步（push 成功后由 `sync_service.pushOnce()` 调用）。
  Future<void> markSynced(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final placeholders = List.filled(list.length, '?').join(',');
    await _db.update(
      'highlight',
      {'pending_push': 0},
      where: 'id IN ($placeholders)',
      whereArgs: list,
    );
  }

  Highlight _fromRow(Map<String, Object?> r) => Highlight(
        id: r['id'] as String,
        sourceType: HighlightSourceType.parse(r['source_type'] as String),
        sourceId: r['source_id'] as String,
        // ⚠️ `as num?` 而非 `as num`：只 `SELECT` 了部分列时，缺失应**当作「无」**
        //    而不是抛 TypeError（同 `bookmark._fromRow` 的处理）。
        chapterIdx: (r['chapter_idx'] as num?)?.toInt(),
        startOffset: (r['start_offset'] as num).toInt(),
        endOffset: (r['end_offset'] as num).toInt(),
        text: r['text'] as String,
        note: r['note'] as String?,
        createdAt: parseUserDbUtc(r['created_at'] as String),
        updatedAt: parseUserDbUtc(r['updated_at'] as String),
        deleted: (r['deleted'] as num?)?.toInt() == 1,
        paused: (r['paused'] as num?)?.toInt() == 1,
        // ⚠️ `as String?`：老库的 `SELECT *` 可能尚未含该列（升级前的调用栈）
        translation: r['translation'] as String?,
        pendingPush: (r['pending_push'] as num).toInt() == 1,
      );
}
