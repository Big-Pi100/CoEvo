// CoEvo · 云端同步的**合并口径**（纯逻辑 · 零 import）
//
// 🔴 为什么单独一个文件、且**不得 import 任何 Flutter 包**：
//   本机 `flutter` 必崩（Windows 管道耗尽）→ 只有**纯 Dart** 才能在本地独立验证。
//   同 `reading_completion.dart` / `code_box_logic.dart` / `speech_chunks.dart` 的做法。
//   → 合并的每一条口径都能用 `scripts/query_verify/bin/verify_sync_merge.dart` 锁住，
//     而不是只能靠「两台真机各点一下看看」。
//
// # 口径来源
// 📄 `docs/design/sync-implementation-assessment-2026-10-04.md` §3.1.1 / §3.3 / §3.4
//
// # 🔑 核心判据：「合并」不是**一种**规则，是**一族**规则
//
// 逐字段问一句：**这个字段表达的是「最新意愿」还是「首次事实」？**
//
// | 字段 | 类别 | 口径 |
// |---|---|---|
// | `user_word.deleted` | 最新意愿 | 取**较新** |
// | `user_word.added_at` | 首次事实 | 取**较早** |
// | `user_word.source_sentence` | 首次事实（v1 §八 定死） | 取**较早**那端 |
// | `article_read.read_at` | 首次事实 | 取**较早** |
// | `bookmark.deleted` | 最新意愿 | 取**较新** |
// | `book_progress.*` | 最新意愿 | 取**较新** |
// | 🆕 `highlight.note` / `.paused` / `.deleted` | 最新意愿 | 取**较新** |
// | 🆕 `highlight.text` / offsets / `source_*` | 首次事实（**整组同端**） | 取**较早**那端 |
//
// ⇒ 用「整行新胜」会把「例句取首次」那条静态规则**静默推翻**（例句会跳动、干扰复习）。
//
// # 🔴🔴 时间戳必须**按语义比较**，不能比字符串
//
// 这两类列的时间戳**格式不同**：
//   · `bookmark.bookmarked_at` / `article_read.read_at` / `user_word.*_at`
//     —— 由 SQLite `strftime('%Y-%m-%dT%H:%M:%SZ','now')` 生成 ⇒ **无毫秒**（`…:00Z`）
//   · `ReviewEvent.reviewedAt` / 服务端 `received_at`
//     —— 由 Dart/chrono 的 ISO8601 生成 ⇒ **带毫秒**（`…:00.000Z`）
//
// 同一时刻的这两种写法，**字符串序是反的**：
// ```
// '.' = 0x2E   'Z' = 0x5A   ⇒  '.' < 'Z'
// '2026-10-06T09:00:00.000Z'  <  '2026-10-06T09:00:00Z'   ← 同一时刻！
// ```
// ⇒ 若用 `a.compareTo(b)`：「取较新」会认为**无毫秒的那个更新** ⇒ **选错行**，
//   而且**不报错**（静默给错结果 —— 本项目的主要敌人）。
//
// ✅ 正解：解析成 `DateTime` 再比（语义序 == 时间序，两种写法解析出**同一时刻**）。
//
// # 本文件**不处理** `review_log`
//
// 复习事件是「事件日志 + 重放」，其合并由 `FsrsService.merge()` / `replay()` 负责
// （那需要 fsrs 包 ⇒ 非纯逻辑，无法放本文件）。分工：
//   · `review_log`      → `fsrs_service.dart`（重放派生 `card_review_state`）
//   · 其余 5 张表       → **本文件**（字段级合并）
//
// # ⚠️ 关于 `pending_push`：**合并函数不产出它**（由调用方决定）
//
// 合并是「**两个值 → 一个权威值**」；`pending_push` 是「**这个值还需不需要推给服务端**」
// —— 后者取决于「本地原本有没有未推的改动」，与合并口径无关。
// ⇒ 职责分开，调用方（`sync_service`）用 [pendingPushAfterPull] 决定，理由见那里。
//
// 🔴 **为什么不能让合并结果一律标记待推**（一个会被误认为「更安全」的做法）：
//    pull 下来的数据是**服务端已经知道的**。若合并后一律标 `pending_push = 1`，
//    下一次 push 会把它们**整批推回服务端** ⇒ 三重代价：
//    ① 首次同步（全量）时最严重 —— 偏偏那是新设备最常见的场景
//    ② 每次 pull 后都多一轮「其实什么都不需要推」的请求
//    ③ 把「待推」这个信号的含义稀释了（它本应表示「有本地改动待上云」）

// ───────────────────────── 时间戳工具 ─────────────────────────

/// 解析 UTC ISO8601（**必须尾随 `Z`**），失败或格式不合规返回 `null`。
///
/// 🔴 要求尾随 `Z`：`DateTime.parse('2026-10-06T10:00:00')`（无 Z）会**按本地时区**
/// 解释且**不报错** ⇒ 同一串在两个时区的设备上代表不同时刻。
/// 同 `bookmark_repository.dart` 的 `parseUserDbUtc`（那里的判据在此同样适用）。
DateTime? parseSyncTs(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  if (s.isEmpty || !s.endsWith('Z')) return null;
  return DateTime.tryParse(s)?.toUtc();
}

/// `a` 是否**严格新于** `b`（按语义时间）。任一方不可解析 ⇒ `false`。
///
/// 🔑 用 `DateTime.isAfter` 而非字符串比较 —— 见文件头「时间戳必须按语义比较」。
bool isNewer(Object? a, Object? b) {
  final ta = parseSyncTs(a);
  final tb = parseSyncTs(b);
  if (ta == null || tb == null) return false;
  return ta.isAfter(tb);
}

/// `a` 是否**严格早于** `b`。
bool isEarlier(Object? a, Object? b) => isNewer(b, a);

/// 取较**早**的时间戳原串。
String _pickEarlierTs(Object? a, Object? b) {
  final ta = parseSyncTs(a);
  final tb = parseSyncTs(b);
  if (ta != null && tb != null) return (ta.isBefore(tb) ? a : b) as String;
  if (ta != null) return a as String;
  if (tb != null) return b as String;
  return (a ?? b ?? '') as String;
}

/// 从两行中选出「`key` 更早」的那一行（= **首次事实**那一端）。
///
/// 都不可解析时返回 `a`（保持确定性 —— 同一对输入永远同一输出）。
Map<String, Object?> _earlierSideBy(
  Map<String, Object?> a,
  Map<String, Object?> b,
  String key,
) {
  final ta = parseSyncTs(a[key]);
  final tb = parseSyncTs(b[key]);
  if (ta != null && tb != null) {
    if (ta.isBefore(tb)) return a;
    if (tb.isBefore(ta)) return b;
    return a; // 同一时刻 ⇒ 两侧等价
  }
  if (ta != null) return a;
  if (tb != null) return b;
  return a;
}

/// 从两行中选出「`added_at` 更早」的那一行（= **首次加入生词本**的那次）。
Map<String, Object?> _earlierAddedSide(
  Map<String, Object?> a,
  Map<String, Object?> b,
) =>
    _earlierSideBy(a, b, 'added_at');

/// 从两行中选出「`updated_at` 更**新**」的那一行（= **最新意愿**）。
Map<String, Object?> _latestUpdatedSide(
  Map<String, Object?> a,
  Map<String, Object?> b,
) {
  final ta = parseSyncTs(a['updated_at']);
  final tb = parseSyncTs(b['updated_at']);
  if (ta != null && tb != null) {
    if (ta.isAfter(tb)) return a;
    if (tb.isAfter(ta)) return b;
    return a;
  }
  if (ta != null) return a;
  if (tb != null) return b;
  return a;
}

// ───────────────────────── 通用并集 ─────────────────────────

/// 按 [keyOf] 把两份行列表并成一份；同键的两行用 [mergeTwo] 合并。
///
/// 「并集」的语义：任一端有这行 ⇒ 结果有这行（**只增不减**）。
/// 这是生词本 / 收藏 / 阅读记录 / 电子书进度的共同基座 ——
/// 它们的差别只在 [mergeTwo]（字段级口径）。
///
/// ⚠️ 返回顺序**不保证**（`Map` 的迭代序 = 键的插入序：先 `local` 后新出现的 `remote`）。
///    调用方若要稳定输出，自己排序。
List<Map<String, Object?>> mergeRowList({
  required List<Map<String, Object?>> local,
  required List<Map<String, Object?>> remote,
  required String Function(Map<String, Object?>) keyOf,
  required Map<String, Object?> Function(Map<String, Object?>, Map<String, Object?>)
      mergeTwo,
}) {
  final byKey = <String, Map<String, Object?>>{};
  for (final r in local) {
    byKey[keyOf(r)] = r;
  }
  for (final r in remote) {
    final k = keyOf(r);
    final cur = byKey[k];
    // 🔑 参数顺序固定为 `(local, remote)` —— 合并函数都**对称**，
    //    只有「时间戳都不可解析」这一异常分支才看顺序（那时按 `local` 兜底）。
    byKey[k] = cur == null ? r : mergeTwo(cur, r);
  }
  return byKey.values.toList();
}

// ───────────────────────── ① user_word（生词本）─────────────────────────

/// `user_word` 的合并键：`word_id`（按 lemma 唯一 ⇒ 同一词只有一行）。
String userWordKey(Map<String, Object?> r) => r['word_id'] as String? ?? '';

/// 生词本一行 → 待推送的 JSON（字段名与后端 `UserWordInput` **逐字一致**）。
///
/// 🔴 字段名写错**不会报错**（对端 serde 默认忽略未知字段 ⇒ 静默传空）
/// ⇒ 由 `verify_sync_merge.dart` 锁「这些键与后端结构一致」。
Map<String, Object?> userWordToPushJson(Map<String, Object?> r) => {
      'word_id': r['word_id'],
      'spelling': r['spelling'],
      'source_article_id': r['source_article_id'],
      'source_sentence': r['source_sentence'],
      'added_at': r['added_at'],
      'updated_at': r['updated_at'],
      'deleted': r['deleted'] ?? 0,
    };

/// 服务端 `UserWordOut` → 本地行（可**直接**喂给 `mergeUserWord` 或 INSERT）。
///
/// 注意：**不产生** `pending_push` —— 那是「同步标记」不是「合并口径」，
/// 由调用方用 [pendingPushAfterPull] 决定（理由见文件头）。
Map<String, Object?> userWordFromPullJson(Map<String, dynamic> j) => {
      'word_id': j['word_id'],
      'spelling': j['spelling'],
      'source_article_id': j['source_article_id'],
      'source_sentence': j['source_sentence'],
      'added_at': j['added_at'],
      'updated_at': j['updated_at'],
      'deleted': j['deleted'] ?? 0,
    };

/// 把已经**合并好的一对**（或单独一行）转成「可直接写库并标记待推」的行。
String? _strOrNull(Object? v) => v is String && v.isNotEmpty ? v : null;

/// 🔴 **生词本的合并是字段级的**，不是「整行取较新」。
///
/// | 字段 | 口径 | 为什么 |
/// |---|---|---|
/// | `deleted` / `updated_at` | 取**较新**（按 `updated_at`） | 表达「最后一次的意愿」 |
/// | `added_at` | 取**较早** | 「首次加入生词本的时刻」 |
/// | `source_sentence` / `source_article_id` | 取**较早那端** | v1 §八：例句取**首次**语境，用最新覆盖会让例句**跳动**、干扰复习 |
/// | `spelling` | 取非空（同一 `word_id` 拼写不变） | 词库 id 一旦分配永久不变 |
///
/// ⚠️ 例句有一处**刻意的宽松**：若「较早那端」的例句为 `null` 而另一侧非空，
///    取非空的那个。理由：`null` 表示**这一端没有这份信息**，不是「信息是空」；
///    坚持取 null 会让例句永久丢失（不可恢复）。这是「取较早**的非空值**」。
Map<String, Object?> mergeUserWord(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) {
  final latest = _latestUpdatedSide(local, remote);
  final first = _earlierAddedSide(local, remote);

  // 例句：优先「首次那端」，但那一端为空时退到另一端（理由见上）
  var sentence = first['source_sentence'];
  var articleId = first['source_article_id'];
  if (_strOrNull(sentence) == null) {
    sentence ??= latest['source_sentence'];
  }
  if (articleId == null) {
    articleId = latest['source_article_id'];
  }

  return {
    'word_id': local['word_id'] ?? remote['word_id'],
    'spelling': _strOrNull(local['spelling']) ?? _strOrNull(remote['spelling']) ?? '',
    'source_article_id': articleId,
    'source_sentence': sentence,
    'added_at': _pickEarlierTs(local['added_at'], remote['added_at']),
    'updated_at': latest['updated_at'],
    'deleted': latest['deleted'] ?? 0,
  };
}

// ───────────────────────── ② article_read（阅读记录）─────────────────────────

/// `article_read` 的合并键：`article_id`（一篇文章只算一次）。
String articleReadKey(Map<String, Object?> r) =>
    (r['article_id'] ?? '').toString();

Map<String, Object?> articleReadToPushJson(Map<String, Object?> r) => {
      'article_id': r['article_id'],
      'read_at': r['read_at'],
    };

Map<String, Object?> articleReadFromPullJson(Map<String, dynamic> j) => {
      'article_id': j['article_id'],
      'read_at': j['read_at'],
    };

/// `article_read` 合并：`read_at` 取**较早**。
///
/// 语义 = 「**首次读完**的时刻」（本库用 `INSERT OR IGNORE` 幂等写入，
/// 第二次读完不覆盖 ⇒ 本地口径就是 `min`，服务端必须与之一致）。
Map<String, Object?> mergeArticleRead(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) =>
    {
      'article_id': local['article_id'] ?? remote['article_id'],
      'read_at': _pickEarlierTs(local['read_at'], remote['read_at']),
      };

// ───────────────────────── ③ bookmark（收藏）─────────────────────────

/// `bookmark` 的合并键：`content_id`（一篇文章只收藏一次）。
String bookmarkKey(Map<String, Object?> r) => (r['content_id'] ?? '').toString();

Map<String, Object?> bookmarkToPushJson(Map<String, Object?> r) => {
      'content_id': r['content_id'],
      'bookmarked_at': r['bookmarked_at'],
      'deleted': r['deleted'] ?? 0,
    };

Map<String, Object?> bookmarkFromPullJson(Map<String, dynamic> j) => {
      'content_id': j['content_id'],
      'bookmarked_at': j['bookmarked_at'],
      'deleted': j['deleted'] ?? 0,
    };

/// `bookmark` 合并：整行取**较新**（按 `bookmarked_at`）。
///
/// 🔴 前提：`bookmarked_at` 是「**最后一次改变收藏状态的时刻**」——
///    **收藏与取消都必须刷新它**（`bookmark_repository.remove()` 已如此）。
///    若取消不刷新，取消与收藏**同值** ⇒ 这里会判定为「无变化」
///    ⇒ 服务端丢弃取消 ⇒ **「取消了的收藏又自己回来」**。
///    📄 详见 `user_db_schema.sql` 里该列的注释（那里记了完整的失败链）。
Map<String, Object?> mergeBookmark(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) {
  final winner = isNewer(remote['bookmarked_at'], local['bookmarked_at'])
      ? remote
      : (isNewer(local['bookmarked_at'], remote['bookmarked_at']) ? local : local);
  return {
    'content_id': local['content_id'] ?? remote['content_id'],
    'bookmarked_at': winner['bookmarked_at'],
    'deleted': winner['deleted'] ?? 0,
  };
}

// ───────────────────────── ③b highlight（划线记忆）─────────────────────────
//
// 🔑 为什么排在 `bookmark` 之后：两者**同族** —— 资产型 + 软删 + 新意愿取较新。
//    差别只在它多一组「**首次事实**」（正文 / offsets / 来源）。
//
// 🔴 这张表是 2026-10-09 才纳入同步的，它补的是一个**真实缺口**：
//    此前 `review_log`（复习事件）同步而划线本体不同步 ⇒ 重装 / 换机的设备
//    会拿到「**无主划线卡**」（标题是 `hl:<uuid>`、点暂停静默无反应）。
//    📌 判据：**同步的粒度必须覆盖「引用关系」**。

/// `highlight` 的合并键：`id`（端侧生成的 uuid v4）。
///
/// 🔴 **不能是自增 rowid** —— 两台设备各自从 1 开始必撞（见 `highlight_id.dart`）。
String highlightKey(Map<String, Object?> r) => r['id'] as String? ?? '';

/// 划线一行 → 待推送的 JSON（字段名与后端 `HighlightInput` **逐字一致**）。
Map<String, Object?> highlightToPushJson(Map<String, Object?> r) => {
      'id': r['id'],
      'source_type': r['source_type'],
      'source_id': r['source_id'],
      'chapter_idx': r['chapter_idx'],
      'start_offset': r['start_offset'],
      'end_offset': r['end_offset'],
      'text': r['text'],
      'note': r['note'],
      'paused': r['paused'] ?? 0,
      'deleted': r['deleted'] ?? 0,
      'created_at': r['created_at'],
      'updated_at': r['updated_at'],
    };

/// 服务端 `HighlightOut` → 本地行（可直接喂给 [mergeHighlight] 或 INSERT）。
Map<String, Object?> highlightFromPullJson(Map<String, dynamic> j) => {
      'id': j['id'],
      'source_type': j['source_type'],
      'source_id': j['source_id'],
      'chapter_idx': j['chapter_idx'],
      'start_offset': j['start_offset'],
      'end_offset': j['end_offset'],
      'text': j['text'],
      'note': j['note'],
      'paused': j['paused'] ?? 0,
      'deleted': j['deleted'] ?? 0,
      'created_at': j['created_at'],
      'updated_at': j['updated_at'],
    };

/// 🔴 划线合并是**字段级**的，与 [mergeUserWord] 同一形状。
///
/// | 字段 | 类别 | 口径 |
/// |---|---|---|
/// | `note` / `paused` / `deleted` | 最新意愿 | 取**较新**（按 `updated_at`）|
/// | `text` / `start_offset` / `end_offset` / `source_type` / `source_id` / `chapter_idx` | 首次事实 | 取**较早**（按 `created_at`）|
///
/// ## 🔑 为什么 `text` / offsets / 来源**必须整组来自同一端**
///
/// 它们是一组**耦合**字段（「划的是**哪段**文字」）—— 若逐字段各取所需，
/// 会拼出 `text = "the quick fox"` 配 `start_offset = 999` 这种**不存在的组合**
/// （同 [mergeBookProgress] 那条：三个字段要一起来自同一端）。
/// 所以这里用**同一端**（`_earlierSideBy(…, 'created_at')`）整体取值，不做逐字段宽松。
///
/// ⚠️ 唯一的例外是 `chapter_idx`（**可空**：文章是单页 ⇒ 没有章节号）——
///    沿用 [mergeUserWord] 对 `source_sentence` 的宽松口径：较早那端为 `null` 时
///    退到另一端。理由同：`null` 表示「这一端没有这份信息」，不是「信息是空」。
///
/// ## ⚠️ `note` 取较新时**连 `null` 一起取**
///
/// `note` 是**可空的意愿型**字段，而「清空笔记」是一个**真实意图**
/// ⇒ 不能写成「取非空」（那样笔记**永远清不掉**：清空会被当成「没带这个字段」）。
/// 服务端那条 upsert 用的是同一条判据（见 `sync_handlers.rs` 的 `sync_highlight` 段）。
Map<String, Object?> mergeHighlight(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) {
  final latest = _latestUpdatedSide(local, remote); // 最新意愿
  final first = _earlierSideBy(local, remote, 'created_at'); // 首次事实（整组）

  var chapterIdx = first['chapter_idx'];
  if (chapterIdx == null) chapterIdx = latest['chapter_idx'];

  return {
    'id': local['id'] ?? remote['id'],
    // ── 首次事实（整组来自同一端）──
    'source_type': first['source_type'] ?? local['source_type'] ?? remote['source_type'],
    'source_id': first['source_id'] ?? local['source_id'] ?? remote['source_id'],
    'chapter_idx': chapterIdx,
    'start_offset': first['start_offset'],
    'end_offset': first['end_offset'],
    'text': first['text'],
    'created_at': _pickEarlierTs(local['created_at'], remote['created_at']),
    // ── 最新意愿 ──
    'note': latest['note'],
    'paused': latest['paused'] ?? 0,
    'deleted': latest['deleted'] ?? 0,
    'updated_at': latest['updated_at'],
  };
}

// ───────────────────────── ④ book_progress（电子书进度）─────────────────────────

/// `book_progress` 的合并键：**`content_hash`**（不是端侧 `book_id`）。
///
/// 🔴 书 id 是端侧生成的 uuid ⇒ 同一本书在两台设备是**两个 id**
/// ⇒ 必须有「跨设备身份」。用 `sha256(文件原始字节)` 做指纹（`book.content_hash`）。
String bookProgressKey(Map<String, Object?> r) =>
    r['content_hash'] as String? ?? '';

Map<String, Object?> bookProgressToPushJson(Map<String, Object?> r) => {
      'content_hash': r['content_hash'],
      'chapter_idx': r['chapter_idx'],
      'scroll_ratio': r['scroll_ratio'],
      'updated_at': r['updated_at'],
    };

Map<String, Object?> bookProgressFromPullJson(Map<String, dynamic> j) => {
      'content_hash': j['content_hash'],
      'chapter_idx': j['chapter_idx'],
      'scroll_ratio': j['scroll_ratio'],
      'updated_at': j['updated_at'],
    };

/// 电子书进度合并：**整行取较新**（按 `updated_at`）。
///
/// 进度是「读到哪」的**最新意愿** ⇒ 三个字段要**一起**来自同一端，
/// 不能逐字段取（否则会出现「第 9 章的 20% 位置」这种**不存在的组合**）。
Map<String, Object?> mergeBookProgress(
  Map<String, Object?> local,
  Map<String, Object?> remote,
) {
  final winner = _latestUpdatedSide(local, remote);
  return {
    'content_hash': local['content_hash'] ?? remote['content_hash'],
    'chapter_idx': winner['chapter_idx'],
    'scroll_ratio': winner['scroll_ratio'],
    'updated_at': winner['updated_at'],
  };
}

// ───────────────────────── 合并后的同步标记 ─────────────────────────

/// **pull 并合并之后**，这一行是否还需要推给服务端？
///
/// # 规则（一句话）
///
/// ```
/// 本地原本就有未推的改动  ⇒ 需要推（1）
/// 否则                    ⇒ 不需要（0）
/// ```
///
/// # 为什么是这个规则（逐种情形过一遍）
///
/// | 情形 | 结果 | 为什么 |
/// |---|---|---|
/// | 本地**没有**这一行（首次同步拉下来的）| **0** | 数据来自服务端，**它已经知道** —— 推回去是纯浪费 |
/// | 本地有，且 `pending_push = 1`（有本地改动没推上去）| **1** | 合并结果**含有本地改动** ⇒ 必须推，否则本地改动永远上不了云 |
/// | 本地有，且 `pending_push = 0`（已与服务端一致）| **0** | 无需再推 |
///
/// 🔑 **关键洞察**：合并后的值是「权威值」，它**可能包含本地改动** ——
///    所以不能一概置 0（会丢本地改动），也不能一概置 1（会把服务端已知的数据推回去）。
///    判据恰好是「**本地原本有没有未推的改动**」——一个二元信息，无需逐字段比较
///    （逐字段比较要正确处理 `null` / `double` / `int` vs `double`，是自找的复杂度）。
///
/// ⚠️ 一个**刻意接受**的边界：若本地那一行**已推但服务端后来变了**，
///    合并结果取的是权威值，而 `pending_push = 0` ⇒ 我们不会把合并结果推回去。
///    这是**对的**（两端都由服务端的那份驱动，本地没有「新事实」需要上云）。
///
/// 📌 泛化：**「需不需要同步」是「有没有本地改动」，不是「值变没变」** ——
///    后者要比较，前者只要一个标志位（且该标志位本来就存在）。
bool pendingPushAfterPull({
  required bool localExisted,
  required bool localWasPending,
}) =>
    localExisted && localWasPending;

// ───────────────────────── 列名契约（供断言核对）─────────────────────────

/// 同步字段 → **（来源表, 列名）**契约。
///
/// # 🔑 为什么需要它
///
/// Dart 的 `Map` 键写错**编译期不报、运行期不报**（只返回 `null`）
/// ⇒ 只能靠断言把「这份清单 == schema 的实际列」钉住。
///
/// # 🔴 为什么值是「表 + 列」而不是只写列
///
/// 前 3 张是 **1:1**（同步字段就是本表列），但 **`book_progress` 是复合来源**：
///   · `content_hash` 在 **`book`** 表（跨设备身份 —— `book_progress.book_id` 是端侧 uuid，
///     同一本书在两台设备上是**两个 id**）
///   · 其余 3 个字段在 `book_progress` 表
/// ⇒ 只写列名会让断言去错表找、得到**假红**（2026-10-06 本人踩过一次）。
///
/// ⚠️ 两张库的 schema 文件不同：`book` / `book_progress` 在 `book_db_schema.sql`，
///    其余在 `user_db_schema.sql`。
/// 📄 断言：`scripts/query_verify/bin/verify_sync_merge.dart`【7】
const Map<String, List<(String table, String column)>> kSyncFieldSources = {
  'user_word': [
    ('user_word', 'word_id'),
    ('user_word', 'spelling'),
    ('user_word', 'source_article_id'),
    ('user_word', 'source_sentence'),
    ('user_word', 'added_at'),
    ('user_word', 'updated_at'),
    ('user_word', 'deleted'),
  ],
  'article_read': [
    ('article_read', 'article_id'),
    ('article_read', 'read_at'),
  ],
  'bookmark': [
    ('bookmark', 'content_id'),
    ('bookmark', 'bookmarked_at'),
    ('bookmark', 'deleted'),
  ],
  // 🆕 2026-10-09：划线记忆（12 列，全部在 `user_db_schema.sql` 的 `highlight`）
  'highlight': [
    ('highlight', 'id'),
    ('highlight', 'source_type'),
    ('highlight', 'source_id'),
    ('highlight', 'chapter_idx'),
    ('highlight', 'start_offset'),
    ('highlight', 'end_offset'),
    ('highlight', 'text'),
    ('highlight', 'note'),
    ('highlight', 'paused'),
    ('highlight', 'deleted'),
    ('highlight', 'created_at'),
    ('highlight', 'updated_at'),
  ],
  'book_progress': [
    ('book', 'content_hash'), // 🔴 跨设备身份在 `book` 表，不在 `book_progress`
    ('book_progress', 'chapter_idx'),
    ('book_progress', 'scroll_ratio'),
    ('book_progress', 'updated_at'),
  ],
};

/// 推送 JSON 的键（**必须与后端 `sync_handlers.rs` 的 `*Input` 结构一致**）。
///
/// 🔴 不一致的后果是**静默**的：对端 serde 忽略未知字段 ⇒ 那一列永远传空。
/// 📄 断言：`verify_sync_merge.dart`【8】（读 Rust 源码核对结构体字段）
///
/// 🔑 与 [kSyncFieldSources] 的**字段名集合必须相同**（断言交叉验证）——
///    否则「本地存了但没传」或「传了但无处存」这类断层不会被发现。
const Map<String, List<String>> kPushJsonContract = {
  'user_word': [
    'word_id',
    'spelling',
    'source_article_id',
    'source_sentence',
    'added_at',
    'updated_at',
    'deleted',
  ],
  'article_read': ['article_id', 'read_at'],
  'bookmark': ['content_id', 'bookmarked_at', 'deleted'],
  // 🆕 2026-10-09：与后端 `HighlightInput` 的字段**逐字一致**
  'highlight': [
    'id',
    'source_type',
    'source_id',
    'chapter_idx',
    'start_offset',
    'end_offset',
    'text',
    'note',
    'paused',
    'deleted',
    'created_at',
    'updated_at',
  ],
  'book_progress': ['content_hash', 'chapter_idx', 'scroll_ratio', 'updated_at'],
};
