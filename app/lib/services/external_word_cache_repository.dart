// CoEvo · 词库外生词的**词卡缓存**仓储（`external_word_cache`）—— `user.db` 侧
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` 的理由）：
//   本地 `flutter analyze` 会崩，纯 Dart 才能独立验证。
//
// # 依据
// · L0 `v1-final-design-authoritative-2026-09-25.md` §3.2（表定义）
// · `docs/design/llm-card-online-path-2026-09-29.md` §21.3（五条已定裁决）
// · `docs/review/a2-and-worddb-convergence-checklist-2026-10-01.md` §四 阶段 2
//
// # 🔑 它在链条里的位置
// ```
// 用户划到词库外的词
//   → 查本表 ──命中──► 直接用（0 次网络）
//   → 未命中 → 调服务端 /api/generate-card → 写本表 → 再用
// ```
// 而**复习页**取卡时（`WordQueryService.cardById`）见到 `ext:` 前缀 → 也回落到本表
// —— 这是「词库外的词能被复习」的关键一环（没有它，那个词在复习页会「看得见、点不开」）。
//
// # ⚠️ 存的是**转换后**的形状（与服务端不同，别「顺手统一」）
// 本表存 `{front, ipa, entry_type, sections:[…]}`（= `word.db.card.content` 的形状），
// 而服务端 `generated_card_cache` 存 LLM **原始输出**。
// 理由见 `assets/sql/user_db_schema.sql` 里该表的注释（核心：收敛切换时形状不变）。
//
// # 与 `UserWordRepository` 的异同
// | | `user_word` | 本表 |
// |---|---|---|
// | 删除 | **软删**（带学习数据）| **硬删** —— 缓存是**可再生**的（重新调一次接口就有），同 `bookmark` 的理由 |
// | 主键 | 代理键 `id` + `UNIQUE(word_id)` | 代理键 `id` + `UNIQUE(spelling)` |
// | 覆盖语义 | 幂等（`alreadyExists` 什么都不改）| 🔴 **覆盖** —— 缓存的意义就是「以最新一份为准」|

import 'package:sqflite_common/sqlite_api.dart';

import 'bookmark_repository.dart' show parseUserDbUtc;
import 'external_word_id.dart';

/// 一条缓存记录。
class ExternalWordCacheEntry {
  final int id;

  /// 归一化后的拼写（同 `ext:` 里的那段）
  final String spelling;

  /// 🔴 **转换后的 `card.content` 形状**（`{front, ipa, entry_type, sections:[…]}`）
  final String cardContent;

  final DateTime fetchedAt;
  final bool pendingPush;

  const ExternalWordCacheEntry({
    required this.id,
    required this.spelling,
    required this.cardContent,
    required this.fetchedAt,
    required this.pendingPush,
  });

  @override
  bool operator ==(Object other) =>
      other is ExternalWordCacheEntry &&
      other.id == id &&
      other.spelling == spelling &&
      other.cardContent == cardContent &&
      other.fetchedAt == fetchedAt &&
      other.pendingPush == pendingPush;

  @override
  int get hashCode =>
      Object.hash(id, spelling, cardContent, fetchedAt, pendingPush);

  @override
  String toString() =>
      'ExternalWordCacheEntry(#$id "$spelling" ${cardContent.length}B'
      '${pendingPush ? ' · 待推' : ''})';
}

/// 词库外生词的词卡缓存仓储。
class ExternalWordCacheRepository {
  ExternalWordCacheRepository(this._db);

  final Database _db;

  // ───────────────────────────────────────────────────────────
  // 读
  // ───────────────────────────────────────────────────────────

  /// 取某个词的缓存内容（**已转换的 `card.content` 形状**）；没有则 `null`。
  ///
  /// ⚠️ 拼写会先归一化 —— 否则查 `Brainstorm` 与存 `brainstorm` 对不上，
  ///   表现为「缓存明明写了，却读不到」→ 每次都重新调接口（**静默浪费**）。
  Future<String?> contentOf(String spelling) async {
    final rows = await _db.query(
      'external_word_cache',
      columns: ['card_content'],
      where: 'spelling = ?',
      whereArgs: [normalizeExternalSpelling(spelling)],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['card_content'] as String?;
  }

  /// 是否有该词的缓存。
  Future<bool> contains(String spelling) async =>
      await contentOf(spelling) != null;

  /// 单行（含元数据）—— 收敛与调试用。
  Future<ExternalWordCacheEntry?> find(String spelling) async {
    final rows = await _db.query(
      'external_word_cache',
      where: 'spelling = ?',
      whereArgs: [normalizeExternalSpelling(spelling)],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// 缓存条数。走 `COUNT(*)` —— 单用户量级极小，不需要维护计数列（同 `bookmark` 的理由）。
  Future<int> count() async {
    final rows =
        await _db.rawQuery('SELECT count(*) AS n FROM external_word_cache');
    return (rows.first['n'] as num).toInt();
  }

  /// 全部拼写（收敛时**遍历候选**用）。
  Future<List<String>> allSpellings() async {
    final rows = await _db.query(
      'external_word_cache',
      columns: ['spelling'],
      orderBy: 'fetched_at DESC',
    );
    return rows.map((r) => r['spelling'] as String).toList(growable: false);
  }

  // ───────────────────────────────────────────────────────────
  // 写
  // ───────────────────────────────────────────────────────────

  /// 写入 / **覆盖**（同一个词再查一次 → 以最新一份为准）。
  ///
  /// 🔑 **用 `INSERT OR REPLACE`**（不是 `ConflictAlgorithm.ignore`）——
  ///    与 `user_word.add()` 的幂等语义**相反**，这是**有意的**：
  ///    · `user_word` 的 `added_at` 表达「我第一次收它是什么时候」→ **不能覆盖**
  ///    · 本表的 `fetched_at` 表达「这份缓存是什么时候取的」→ **就该被刷新**
  ///    （同 `bookmark` 用硬删、`user_word` 用软删 —— **同类东西的语义可以相反，
  ///      只要各自的语义是自洽的**。）
  ///
  /// ⚠️ `cardContent` 必须是**已转换的**形状（见文件头）——
  ///   本层不做转换（那是 `generated_card_adapter` 的职责，
  ///   因为它要能被**纯函数断言**，而本层依赖 DB）。
  Future<void> put(String spelling, String cardContent) async {
    assert(cardContent.isNotEmpty, '空缓存没有意义，且会让取卡回落返回一张空卡');
    await _db.insert(
      'external_word_cache',
      {
        'spelling': normalizeExternalSpelling(spelling),
        'card_content': cardContent,
        // 不传 `fetched_at` / `pending_push`
        // —— 由 DDL 的 DEFAULT 生成（用**数据库时钟**，同 `bookmark` 的理由）
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删除某个词的缓存（**硬删** —— 缓存可再生）。
  ///
  /// 🔑 **发版收敛**会用到它：词被回流进 `word.db` 后，缓存就没用了
  ///    （取卡会从 `word.db` 走真 id），删掉可收敛磁盘占用。
  ///    ⚠️ 顺序要求：**先改完三张表的 `word_id`，再删缓存** ——
  ///    反了且中途失败会「数据还指着 `ext:` 而缓存已没」→ **取不到卡**（比不收敛更糟）。
  Future<bool> remove(String spelling) async {
    final n = await _db.delete(
      'external_word_cache',
      where: 'spelling = ?',
      whereArgs: [normalizeExternalSpelling(spelling)],
    );
    return n > 0;
  }

  /// 清空（**仅供验收脚本与演练**；生产路径不要调 —— 那会让所有词库外的词失去缓存）。
  Future<int> clear() async =>
      await _db.delete('external_word_cache');

  static ExternalWordCacheEntry _fromRow(Map<String, Object?> r) =>
      ExternalWordCacheEntry(
        id: (r['id'] as num).toInt(),
        spelling: r['spelling']! as String,
        cardContent: r['card_content']! as String,
        // 🔑 复用 `parseUserDbUtc`（它会**校验**尾随 `Z`，缺了直接抛）
        //    ⚠️ 别写成 `DateTime.parse('$raw Z')` —— DDL 里已经带 `Z`，
        //       再补一次会得到 `...ZZ` → 抛 FormatException（本行初稿正是这么错的）
        fetchedAt: parseUserDbUtc(r['fetched_at']! as String).toUtc(),
        pendingPush: (r['pending_push'] as num).toInt() == 1,
      );
}
