// 翻译的**端侧缓存** —— 本机翻过的句子不再重复付费
//
// # 为什么缓存在端侧（而服务端刻意不做）
//
// 缓存的全部价值来自「**同一份结果被多人复用**」。词卡能摊薄，是因为 `attention`
// 会被成千上万人查；而翻译的单位是**句子** —— 每篇文章的每句话都唯一
// ⇒ 跨用户命中率 ≈ 0 ⇒ 服务端加缓存只是白付一层复杂度。
// 端侧则**有价值**：同一个用户会重复看同一句。
// 📌 判据：**能摊薄才有缓存价值**。
//
// # 🔴 本文件最重要的一处：`normalizeTranslationSource`
//
// 它是「**两句英文算不算同一句**」的**唯一**口径，而它错的表现是**静默多花钱**：
// · 归一化得**太松**（如把大小写也压平）⇒ `Apple` 与 `apple` 共用一份译文
//   ⇒ 用户看到**错误的译文**（专有名词被译成水果）。
// · 归一化得**太紧**（如不折叠空白）⇒ `"Hello world"` 与 `"Hello  world"`
//   是两行 ⇒ **同一句付两次钱**，而用户只觉得"好像翻过"。
//
// ⚠️ 所以这里**只做「排版差异」的归一**（空白 / 智能引号），
//    **绝不碰大小写与标点** —— 它们是内容差异，不是排版差异。
//
// # 零 Flutter 依赖
// 只依赖 `sqflite_common` 的 `Database` 接口 ⇒ 整条链可在纯 Dart 断言脚本里跑
// （真库用 `sqflite_common_ffi`，同 `verify_highlight_repo.dart`）。

import 'package:sqflite_common/sqlite_api.dart';

// 🔑 复用 `bookmark_repository` 的 UTC 时间口径（**SQL 侧生成**，毫秒精度）——
//    不是「顺手 import」，而是判据「**同一件事的口径只能一处权威**」：
//    若这里用 Dart 侧的 `toIso8601String()`，同一列会混出两种精度
//    （`.000Z` 与 `.123Z`），而 LRU 排序恰好依赖毫秒可区分。
//    ⚠️ 那个文件**零 Flutter 依赖**（只 import sqflite）⇒ 不破坏本文件的纯度。
import 'bookmark_repository.dart' show kSqlNowUtc;

/// 缓存条数上限。
///
/// 🔑 取值依据（不是拍脑袋）：单条最多约 **800 字符原文 + 约 1200 字符译文 ≈ 2 KB**
/// （服务端上限 2026-10-09 由 300 提到 800 ⇒ 本估算同步上调）
/// ⇒ 2000 条 ≈ **4 MB**。这是「离线也有得看」与「不占用户空间」之间的平衡点。
///
/// ⚠️ 条数**不动**：4 MB 对一个 App 的本地缓存仍属可接受，
///    而放宽长度后单条信息量更大 ⇒ **同样的条数覆盖更多内容**，此时缩减条数反而更亏。
/// ⚠️ 超限时按 **LRU**（最近最少使用）淘汰 —— 见 [TranslationCacheRepository.prune]。
const int kTranslationCacheMaxRows = 2000;

/// **规范化原文** —— 「两句算不算同一句」的唯一口径。
///
/// | 处理 | 为什么 |
/// |---|---|
/// | 折叠连续空白 / 首尾空白 | 选区常带多余空白 —— 那是**排版差异**，不是内容差异 |
/// | 智能引号 → ASCII（`’`→`'` · `“”`→`"`） | iOS 会把 `'` 打成 `’`；同一句话不该因此变两条 |
/// | 全角空格 → 半角 | 中文输入法的产物，同上 |
/// | 🔴 **不动大小写** | `Apple`（公司）与 `apple`（水果）**译文不同** ⇒ 压平会给出**错的译文** |
/// | 🔴 **不动标点** | `It's fine.` 与 `It's fine?` 语气不同 ⇒ 同样不该共用 |
String normalizeTranslationSource(String raw) {
  final buf = StringBuffer();
  var pendingSpace = false;
  for (final r in raw.runes) {
    var c = r;
    // 智能标点 → ASCII（与 `picked_text.dart` 的折叠同源，但**目的不同**：
    // 那边为了判定「是不是一个单词」，这边为了判定「是不是同一句」）
    if (c == 0x2019) c = 0x27; // ’ → '
    if (c == 0x2018) c = 0x27; // ‘ → '
    if (c == 0x201C || c == 0x201D) c = 0x22; // “ ” → "
    if (c == 0x3000) c = 0x20; // 全角空格

    final ch = String.fromCharCode(c);
    if (ch.trim().isEmpty) {
      // 空白（含换行/制表）→ 折叠成单个空格；**且不放在开头**
      pendingSpace = true;
      continue;
    }
    if (pendingSpace && buf.isNotEmpty) buf.write(' ');
    pendingSpace = false;
    buf.write(ch);
  }
  return buf.toString();
}

/// 一条缓存记录。
class CachedTranslation {
  const CachedTranslation({required this.srcText, required this.segmentsJson});

  /// **规范化后**的原文（就是主键）。
  final String srcText;

  /// 与接口 `segments` **同一形状**的 JSON 字符串（不在此层解析 —— 见文件头「零业务判断」）。
  final String segmentsJson;
}

/// 翻译缓存仓储。
///
/// 🔑 与 `HighlightRepository` 同一条分层：本层只做「读写 + 淘汰」，
///    **不含业务判断**（要不要调接口、要不要计费是调用方的事）。
class TranslationCacheRepository {
  TranslationCacheRepository(this._db);

  final Database _db;

  /// 取一条（**命中时会顺带刷新 `used_at`**）。
  ///
  /// 🔑 为什么 `get` 要写库：`used_at` 是 LRU 的依据，而「读到了」正是「被使用」的定义。
  ///    若不刷新，**最常看的那句话反而会先被淘汰**（它的 `used_at` 停在第一次）。
  Future<CachedTranslation?> get(String rawSource) async {
    final key = normalizeTranslationSource(rawSource);
    if (key.isEmpty) return null;

    final rows = await _db.query(
      'translation_cache',
      columns: ['src_text', 'segments'],
      where: 'src_text = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    await touch(key);
    return CachedTranslation(
      srcText: (rows.first['src_text'] as String?) ?? key,
      segmentsJson: (rows.first['segments'] as String?) ?? '',
    );
  }

  /// 写入（**覆盖式**：同一句再翻一次就更新它，不新增行）。
  ///
  /// 🔴 **`created_at` 要保留原值**：`INSERT OR REPLACE` 是「先删后插」语义
  ///    ⇒ 若每次都让 DEFAULT 重新生成，`created_at` 会退化成「最后一次写入时间」，
  ///    「这句是什么时候第一次翻的」就丢了。这里显式带上原值。
  ///
  /// ⚠️ 时间一律用 `kSqlNowUtc`（**SQL 侧**生成）—— 理由见 import 处的说明。
  Future<void> put(String rawSource, String segmentsJson) async {
    final key = normalizeTranslationSource(rawSource);
    // 🔴 规范化后为空的输入**不写** —— 否则会留下一行以 `''` 为主键的垃圾，
    //    而所有「空输入」都会命中它（把一次错误变成**永久的错误答案**）。
    if (key.isEmpty) return;

    final existing = await _db.query(
      'translation_cache',
      columns: ['created_at'],
      where: 'src_text = ?',
      whereArgs: [key],
      limit: 1,
    );

    if (existing.isEmpty) {
      await _db.rawInsert(
        'INSERT OR REPLACE INTO translation_cache (src_text, segments, created_at, used_at) '
        'VALUES (?, ?, $kSqlNowUtc, $kSqlNowUtc)',
        [key, segmentsJson],
      );
    } else {
      await _db.rawInsert(
        'INSERT OR REPLACE INTO translation_cache (src_text, segments, created_at, used_at) '
        'VALUES (?, ?, ?, $kSqlNowUtc)',
        [key, segmentsJson, existing.first['created_at']],
      );
    }
  }

  /// 刷新最近使用时间（LRU 用）。
  Future<void> touch(String normalizedKey) async {
    await _db.rawUpdate(
      'UPDATE translation_cache SET used_at = $kSqlNowUtc WHERE src_text = ?',
      [normalizedKey],
    );
  }

  /// **LRU 淘汰**：只保留最近使用的 [keep] 条。
  ///
  /// 返回删掉的行数（0 = 没超限）。
  Future<int> prune({int keep = kTranslationCacheMaxRows}) async {
    final n = await count();
    if (n <= keep) return 0;
    return _db.rawDelete(
      'DELETE FROM translation_cache WHERE src_text IN ('
      '  SELECT src_text FROM translation_cache ORDER BY used_at ASC LIMIT ?'
      ')',
      [n - keep],
    );
  }

  Future<int> count() async {
    final rows =
        await _db.rawQuery('SELECT count(*) AS n FROM translation_cache');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 清空（**退出登录时必须调** —— 见 schema 注释）。
  Future<void> clear() async {
    await _db.delete('translation_cache');
  }
}
