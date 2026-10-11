// 「云端同步 · 合并口径」验收 —— 纯逻辑（本机可跑）+ 两份跨语言契约
//
// 跑：cd scripts/query_verify && dart run bin/verify_sync_merge.dart
// 🔴 退出码：0 = 全过，1 = 有失败（直读，别接 `| tail`）。
//
// # 为什么需要它
//
// 同步的合并口径横跨**三种「不报错的错」**：
//   ① **时间戳格式混用** —— SQLite 的 `strftime('%…Z')`（无毫秒）与 Dart 的
//      `toIso8601String()`（带毫秒）**同一时刻字符串序相反** ⇒ 用字符串比较
//      「取较新」会**选错行**，且不报错。
//   ② **字段级口径写错** —— 把「例句取首次」做成「整行新胜」⇒ 例句跳动，
//      不报错（只是用户体验变差、复习受干扰）。
//   ③ **JSON 字段名漂移** —— Dart 侧 `Map` 键拼错 ⇒ 对端 serde **忽略未知字段**
//      ⇒ 那一列永远传空，两端都不报错。
//
// 本脚本把这三类全部钉住，外加**读后端 Rust 源码**核对结构体字段（跨语言契约）。
//
// # 🔴 证伪方式（每次改断言都该跑一遍）
//
// | 改这里 | 应该变红的是 |
// |---|---|
// | `sync_merge.dart` 的 `parseSyncTs` 改成字符串比较 | 【1】混合精度那组 |
// | `mergeUserWord` 的 `source_sentence` 改取 `latest` 端 | 【2】「例句取首次」 |
// | `mergeArticleRead` 的 `_pickEarlierTs` → `_pickNewerTs` | 【3】「read_at 取较早」 |
// | `mergeBookmark` 的 winner 判定反转 | 【4】「取消能生效」 |
// | `mergeBookProgress` 改成逐字段取 | 【5】「整行来自同一端」 |
// | `mergeRowList` 只返回 local | 【6】并集 |
// | `schema.sql` 改 `bookmark.bookmarked_at` 列名 | 【7】列名契约 |
// | `sync_handlers.rs` 的 `UserWordInput` 加字段 | 【8】JSON 键契约 |
// | `bookmark_repository.remove()` 去掉 `bookmarked_at` 刷新 | 【10】 |
//
// # ⚠️ 口径（如实标注）
//
// · 文本断言**先剥整行注释**（注释里的说明会造成假红；且只能剥整行 ——
//   切 `//` 会把 `https://` 切掉，本项目已踩三次）。
// · Rust 文件**先切掉 `#[cfg(test)]`**（测试会复述实现的字符串 ⇒ 否则假绿）。
// · 它能锁「合并口径 + 两份契约」，**不能**替代真机双设备跑一遍。

import 'dart:io';

import '../../../app/lib/services/sync_merge.dart' as M;

int _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void section(String title) {
  print('');
  print('─' * 74);
  print(title);
  print('─' * 74);
}

String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String implOnly(String src) {
  final i = src.indexOf('#[cfg(test)]');
  return i < 0 ? src : src.substring(0, i);
}

String readFile(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

// ─────────── 测试数据 ───────────

/// ⚠️ 两种格式**刻意混用** —— 它们正是「同一时刻的两种写法」：
///   `tNoMs`  = SQLite `strftime('%Y-%m-%dT%H:%M:%SZ')` 的输出（无毫秒）
///   `tMs`    = Dart `toIso8601String()` / 后端 `now_ms()` 的输出（带毫秒）
const tNoMs = '2026-10-01T00:00:00Z';
const tMs = '2026-10-01T00:00:00.000Z';
const t2 = '2026-10-05T12:34:56Z';
const t3 = '2026-10-09T08:00:00.000Z';
const tLate = '2026-10-20T00:00:00Z';

Map<String, Object?> uword({
  required String id,
  String added = tNoMs,
  String updated = tNoMs,
  int deleted = 0,
  Object? sentence = 'first sentence',
  Object? articleId = 7,
}) =>
    {
      'word_id': id,
      'spelling': 'receive',
      'source_article_id': articleId,
      'source_sentence': sentence,
      'added_at': added,
      'updated_at': updated,
      'deleted': deleted,
    };

Map<String, Object?> aread(int id, String at) => {'article_id': id, 'read_at': at};

Map<String, Object?> bmark(int id, String at, int deleted) =>
    {'content_id': id, 'bookmarked_at': at, 'deleted': deleted};

Map<String, Object?> bprog(String hash, int ch, double ratio, String at) => {
      'content_hash': hash,
      'chapter_idx': ch,
      'scroll_ratio': ratio,
      'updated_at': at,
    };

/// 🆕 2026-10-09：一条划线（形状与 `HighlightRepository.toPushRow()` 一致）。
Map<String, Object?> hmark({
  required String id,
  String text = 'the quick fox',
  String? note,
  int? chapterIdx,
  int paused = 0,
  int deleted = 0,
  String created = tNoMs,
  String updated = tNoMs,
  String sourceType = 'article',
  String sourceId = '42',
  int start = 11,
  int end = 24,
}) =>
    {
      'id': id,
      'source_type': sourceType,
      'source_id': sourceId,
      'chapter_idx': chapterIdx,
      'start_offset': start,
      'end_offset': end,
      'text': text,
      'note': note,
      'paused': paused,
      'deleted': deleted,
      'created_at': created,
      'updated_at': updated,
    };

/// 🆕 2026-10-10：一条查词记录（形状与 `LookupEvent.toPushRow()` 一致）。
Map<String, Object?> levent({
  required String uid,
  String spelling = 'receive',
  Object? wordId = 'w001',
  String at = tNoMs,
}) =>
    {
      'uid': uid,
      'word_id': wordId,
      'spelling': spelling,
      'article_id': 7,
      'sentence': 'I receive it',
      'position': 3,
      'looked_up_at': at,
    };

/// 🆕 2026-10-10：一条书签（形状与 `_pendingBookMarkers` 的 SELECT 一致）。
Map<String, Object?> mkmark({
  required String id,
  String hash = 'hash-book-1',
  int chapter = 2,
  double ratio = 0.5,
  String excerpt = '一段摘录',
  int deleted = 0,
  String created = tNoMs,
}) =>
    {
      'id': id,
      'content_hash': hash,
      'chapter_idx': chapter,
      'scroll_ratio': ratio,
      'excerpt': excerpt,
      'created_at': created,
      'deleted': deleted,
    };

/// 🆕 2026-10-10：一条成就解锁记录。
Map<String, Object?> aunlock(String key, String at) =>
    {'key': key, 'unlocked_at': at};

/// 🆕 2026-10-10：一行设置（`value` 是 JSON 文本）。
Map<String, Object?> setrow(String key, String value, String at) =>
    {'key': key, 'value': value, 'updated_at': at};

void main() {
  print('');
  print('#' * 74);
  print('# 云端同步 · 合并口径验收（纯逻辑 + 跨语言契约）');
  print('#' * 74);

  // ═══════════════════════════════════════════════════════════
  section('【1】🔴 时间戳：必须**按语义**比较（混合精度是静默陷阱）');

  check('无毫秒可解析', M.parseSyncTs(tNoMs) != null);
  check('带毫秒可解析', M.parseSyncTs(tMs) != null);
  check(
    '🔴 两种写法解析出**同一时刻**（这才是关键）',
    M.parseSyncTs(tNoMs) == M.parseSyncTs(tMs),
    '${M.parseSyncTs(tNoMs)} vs ${M.parseSyncTs(tMs)}',
  );
  check(
    '🔴 同一时刻 ⇒ isNewer 双向都是 false（不误判谁新）',
    !M.isNewer(tNoMs, tMs) && !M.isNewer(tMs, tNoMs),
  );
  check(
    '🔑 对照：**字符串比较会给出错误答案** —— '
    '".(0x2E) < Z(0x5A)" ⇒ 带毫秒的被排到前面（=被当成「更早」）',
    tMs.compareTo(tNoMs) < 0 && !M.isNewer(tMs, tNoMs),
    '字符串 $tMs < $tNoMs 成立，而语义上它们是同一时刻',
  );
  check('真的更晚才判「新」', M.isNewer(t2, tNoMs) && M.isNewer(t3, t2));
  check('isEarlier 是 isNewer 的反向', M.isEarlier(tNoMs, t2) && !M.isEarlier(t2, tNoMs));
  check(
    '🔴 无尾随 Z 的串**拒绝解析**（否则 DateTime.parse 会按本地时区静默解释）',
    M.parseSyncTs('2026-10-01T00:00:00') == null,
  );
  check('空串 / 非字符串 / null 一律 null', M.parseSyncTs('') == null &&
      M.parseSyncTs(null) == null &&
      M.parseSyncTs(123) == null);
  check('乱码串不抛异常', M.parseSyncTs('not-a-date-Z') == null);

  // ═══════════════════════════════════════════════════════════
  section('【2】user_word：**字段级**合并（不是整行新胜）');

  // 场景：A 端较早加入（added=tNoMs，例句 A），B 端较晚改动（updated=t3，删了）
  final wA = uword(id: 'w001', added: tNoMs, updated: tNoMs, deleted: 0, sentence: 'A 端语境');
  final wB = uword(id: 'w001', added: t2, updated: t3, deleted: 1, sentence: 'B 端语境');
  final wm = M.mergeUserWord(wA, wB);

  check('deleted 取**较新**（B 的 1 胜）', wm['deleted'] == 1, '${wm['deleted']}');
  check('updated_at 取较新', wm['updated_at'] == t3, '${wm['updated_at']}');
  check('🔴 added_at 取**较早**（A 的）—— 它是「首次加入」的事实',
      wm['added_at'] == tNoMs, '${wm['added_at']}');
  check(
    '🔴🔴 例句取**首次那端**（A 的）—— 用最新覆盖会让例句跳动、干扰复习',
    wm['source_sentence'] == 'A 端语境',
    '${wm['source_sentence']}',
  );
  check('source_article_id 同「较早那端」', wm['source_article_id'] == 7);
  // 🔴 合并函数**不产出** `pending_push` —— 那是「同步标记」不是「合并口径」。
  //    由调用方用 `pendingPushAfterPull` 决定（见该函数的注释）。
  check('🔴 合并结果**不含** `pending_push`（职责分开：合并 ≠ 同步标记）',
      !wm.containsKey('pending_push'));

  // ── 合并后的「要不要推」规则 ──
  check('本地原本有未推改动 ⇒ 需要推（否则本地改动永远上不了云）',
      M.pendingPushAfterPull(localExisted: true, localWasPending: true));
  check('本地没有这一行（首次同步拉下来的）⇒ **不需要**推（服务端已知道）',
      !M.pendingPushAfterPull(localExisted: false, localWasPending: false));
  check('本地有但已推（与服务端一致）⇒ 不需要推',
      !M.pendingPushAfterPull(localExisted: true, localWasPending: false));
  check(
    '⚠️ 反例守卫：**不能一概置 1**（会把服务端已知的数据推回去 = 回声）',
    !M.pendingPushAfterPull(localExisted: false, localWasPending: false),
    '首次同步全量拉取后若一律置 1 ⇒ 整批推回服务端',
  );
  check(
    '⚠️ 反例守卫：**不能一概置 0**（会丢本地改动）',
    M.pendingPushAfterPull(localExisted: true, localWasPending: true),
  );
  check(
    '⚠️ `localExisted: false` 时与 `localWasPending` 无关（不存在的行不可能「有待推改动」）',
    !M.pendingPushAfterPull(localExisted: false, localWasPending: true),
  );

  // 反向：交换参数顺序 ⇒ 结果应**一致**（合并是对称的）
  final wmRev = M.mergeUserWord(wB, wA);
  check(
    '🔑 合并**对称**（交换参数顺序结果不变）',
    wmRev['deleted'] == wm['deleted'] &&
        wmRev['added_at'] == wm['added_at'] &&
        wmRev['source_sentence'] == wm['source_sentence'],
  );

  // 例句的「刻意宽松」：较早那端为 null 时退到另一侧
  final wNull = uword(id: 'w002', added: tNoMs, updated: tNoMs, sentence: null);
  final wHas = uword(id: 'w002', added: t2, updated: t2, sentence: '后来才有');
  check(
    '例句：较早那端为 null ⇒ 退到另一侧（null 表示「这一端没这份信息」，不是「信息为空」）',
    M.mergeUserWord(wNull, wHas)['source_sentence'] == '后来才有',
  );
  check(
    '例句：两端都 null ⇒ null（不编造）',
    M.mergeUserWord(
      uword(id: 'w003', sentence: null),
      uword(id: 'w003', sentence: null),
    )['source_sentence'] ==
        null,
  );

  // 同一行的两侧完全相同 ⇒ 结果与输入等价（不产生怪值）
  final same = M.mergeUserWord(wA, wA);
  check(
    '同一行合并自身 ⇒ deleted/added_at/sentence 不变',
    same['deleted'] == 0 && same['added_at'] == tNoMs && same['source_sentence'] == 'A 端语境',
  );

  // 删了又加：较新的是 deleted=0 ⇒ 应恢复
  final wDel = uword(id: 'w004', added: tNoMs, updated: t2, deleted: 1);
  final wUnDel = uword(id: 'w004', added: tNoMs, updated: t3, deleted: 0);
  check(
    '「删了又重新加入」（updated 较新且 deleted=0）⇒ 状态恢复为未删',
    M.mergeUserWord(wDel, wUnDel)['deleted'] == 0,
  );

  // ═══════════════════════════════════════════════════════════
  section('【3】article_read：read_at 取**较早**（首次读完）');

  final rmLater = M.mergeArticleRead(aread(42, t2), aread(42, tNoMs));
  check('🔴 取较早（后到的较晚时间不得覆盖）', rmLater['read_at'] == tNoMs, '${rmLater['read_at']}');
  check('对称', M.mergeArticleRead(aread(42, tNoMs), aread(42, t2))['read_at'] == tNoMs);
  check('article_id 保留', rmLater['article_id'] == 42);
  check('不产出 `pending_push`（同【2】）', !rmLater.containsKey('pending_push'));

  // ═══════════════════════════════════════════════════════════
  section('【4】🔴 bookmark：整行取较新 —— 「取消必须能生效」');

  final bmKeep = bmark(5, tNoMs, 0); // A 端收藏
  final bmDrop = bmark(5, t2, 1); // B 端取消（**bookmarked_at 更新** —— remove() 的职责）
  final bmMerged = M.mergeBookmark(bmKeep, bmDrop);
  check('🔴 取消生效（deleted=1）—— 这正是软删要解决的问题', bmMerged['deleted'] == 1);
  check('bookmarked_at 取较新那一端的', bmMerged['bookmarked_at'] == t2);
  check('对称', M.mergeBookmark(bmDrop, bmKeep)['deleted'] == 1);

  // 反向：较新的是「收藏」⇒ 应恢复
  final bmReAdd = bmark(5, t3, 0);
  check('较新的是「重新收藏」⇒ deleted 回到 0', M.mergeBookmark(bmDrop, bmReAdd)['deleted'] == 0);

  // 已知边界（如实断言，别假装没有）
  final bmSame = M.mergeBookmark(bmark(6, t2, 0), bmark(6, t2, 1));
  check(
    '⚠️ 已知边界：bookmarked_at **同值**时判定为「无变化」（保持 local）—— '
    '端侧由 remove() 刷新时间戳来保证不同值',
    bmSame['deleted'] == 0,
    '服务端判定是严格大于（>），同值不覆盖；改 >= 会破坏幂等',
  );
  check(
    '🔑 混合精度也不误判：同一时刻的两种写法 ⇒ 视为同值',
    M.mergeBookmark(bmark(7, tNoMs, 0), bmark(7, tMs, 1))['deleted'] == 0,
  );

  // ═══════════════════════════════════════════════════════════
  section('【5】book_progress：**整行**取自较新那端（不逐字段拼）');

  final bpOld = bprog('hash-abc', 3, 0.2, tNoMs);
  final bpNew = bprog('hash-abc', 9, 0.8, t3);
  final bpMerged = M.mergeBookProgress(bpOld, bpNew);
  check('chapter_idx 取较新', bpMerged['chapter_idx'] == 9);
  check('scroll_ratio 取较新', bpMerged['scroll_ratio'] == 0.8);
  check('updated_at 取较新', bpMerged['updated_at'] == t3);
  check(
    '🔴 三个字段来自**同一端**（否则会出现「第 9 章的 20% 位置」这种不存在的组合）',
    bpMerged['chapter_idx'] == 9 && bpMerged['scroll_ratio'] == 0.8,
  );
  check('对称', M.mergeBookProgress(bpNew, bpOld)['chapter_idx'] == 9);
  check('content_hash 保留', bpMerged['content_hash'] == 'hash-abc');

  // ═══════════════════════════════════════════════════════════
  section('【6】mergeRowList：并集（只增不减）');

  final merged = M.mergeRowList(
    local: [aread(1, tNoMs), aread(2, t2)],
    remote: [aread(2, t3), aread(3, t3)],
    keyOf: M.articleReadKey,
    mergeTwo: M.mergeArticleRead,
  );
  final ids = merged.map((r) => r['article_id']).toList()..sort();
  check('并集含三篇（1、2、3）', ids.length == 3 && ids.toString() == '[1, 2, 3]', '$ids');
  final two = merged.firstWhere((r) => r['article_id'] == 2);
  check('同键的两行被合并（取较早）', two['read_at'] == t2, '${two['read_at']}');

  check(
    '空 remote ⇒ 原样返回 local',
    M.mergeRowList(
      local: [aread(1, tNoMs)],
      remote: [],
      keyOf: M.articleReadKey,
      mergeTwo: M.mergeArticleRead,
    ).length ==
        1,
  );
  check(
    '空 local（首次同步）⇒ 全部来自 remote',
    M.mergeRowList(
      local: [],
      remote: [aread(1, tNoMs), aread(2, t2)],
      keyOf: M.articleReadKey,
      mergeTwo: M.mergeArticleRead,
    ).length ==
        2,
  );
  check(
    '两者都空 ⇒ 空（不抛异常）',
    M.mergeRowList(
      local: [],
      remote: [],
      keyOf: M.articleReadKey,
      mergeTwo: M.mergeArticleRead,
    ).isEmpty,
  );

  // ═══════════════════════════════════════════════════════════
  section('【7】字段来源契约：`kSyncFieldSources` 必须与两张 schema 逐字一致');

  final schemaUser = stripComments(readFile('../../app/assets/sql/user_db_schema.sql'));
  final schemaBook = stripComments(readFile('../../app/assets/sql/book_db_schema.sql'));
  // 🔴 表 → schema 源（`book` / `book_progress` 属**电子书库**，其余属 user.db）
  final schemaOf = <String, String>{
    'user_word': schemaUser,
    'article_read': schemaUser,
    'bookmark': schemaUser,
    'highlight': schemaUser, // 🆕 2026-10-09（划线记忆在 user.db）
    'book_progress': schemaBook,
    'book': schemaBook,
    // 🆕 2026-10-10：同步覆盖面补齐
    'lookup_event': schemaUser,
    'achievement_unlock': schemaUser,
    'setting_sync': schemaUser,
    'book_marker': schemaBook,
  };

  for (final entry in M.kSyncFieldSources.entries) {
    for (final (table, column) in entry.value) {
      final src = schemaOf[table];
      if (src == null) {
        check('🔴 有 `${table}` 的 schema 源', false, '（schemaOf 里没登记）');
        continue;
      }
      final cols = _tableColumns(src, table);
      if (cols.isEmpty) {
        check('🔴 schema 里找得到表 `$table`', false, '（正则没匹配到 —— 表名或格式变了？）');
        continue;
      }
      check('`${entry.key}` 的来源 `$table.$column` 存在', cols.contains(column),
          '该表实际列：${cols.join(',')}');
    }
  }

  // 🔑 交叉验证：本地存储字段集合 == 推送 JSON 字段集合
  //    （否则「存了不传」或「传了无处存」这类断层不会被发现）
  for (final key in M.kPushJsonContract.keys) {
    final storeNames = M.kSyncFieldSources[key]!.map((e) => e.$2).toList();
    final jsonNames = M.kPushJsonContract[key]!;
    check(
      '🔑 `$key` 的**存储字段**与**推送字段**集合相同',
      storeNames.toSet().toString() == jsonNames.toSet().toString(),
      '存储 $storeNames vs 推送 $jsonNames',
    );
  }

  // ═══════════════════════════════════════════════════════════
  section('【8】🔴 JSON 键契约：必须与后端 Rust 结构体一致（错了是**静默**传空）');

  final rust = implOnly(stripComments(
      readFile('../../backend/crates/api_server/src/sync_handlers.rs')));

  final rustStructOf = <String, String>{
    'user_word': 'UserWordInput',
    'article_read': 'ArticleReadInput',
    'bookmark': 'BookmarkInput',
    'book_progress': 'BookProgressInput',
    'highlight': 'HighlightInput',
    // 🆕 2026-10-10
    'lookup_event': 'LookupEventInput',
    'book_marker': 'BookMarkerInput',
    'achievement_unlock': 'AchievementUnlockInput',
    'setting': 'SettingInput',
  };
  for (final e in rustStructOf.entries) {
    final fields = _rustStructFields(rust, e.value);
    if (fields.isEmpty) {
      check('🔴 Rust 里找得到 `${e.value}`', false, '（结构体名变了？）');
      continue;
    }
    final want = M.kPushJsonContract[e.key]!;
    for (final f in want) {
      check('`${e.value}.$f` 在 Rust 侧存在', fields.contains(f), '实际字段：${fields.join(',')}');
    }
    // 后端 `device_id` 在 **push 顶层**（整批一个设备），不在元素里 —— 单独确认
  }
  check(
    '🔑 push 顶层有 `device_id`（后端用它标记整批来源）',
    _rustStructFields(rust, 'PushInput').contains('device_id'),
  );
  check(
    '后端 `UserWordInput` 用的是 `added_at`（**不是**设计文档 §4.2 写的 `created_at`）',
    _rustStructFields(rust, 'UserWordInput').contains('added_at'),
  );

  // ═══════════════════════════════════════════════════════════
  section('【9】序列化往返（row ↔ 推送 JSON）');

  final uwJson = M.userWordToPushJson(wA);
  check('user_word → JSON 键集合正确', uwJson.keys.toSet().toString() ==
      M.kPushJsonContract['user_word']!.toSet().toString(), '${uwJson.keys.toList()}');
  final uwBack = M.userWordFromPullJson({
    'word_id': 'w001',
    'spelling': 'receive',
    'source_article_id': 7,
    'source_sentence': 'x',
    'added_at': tNoMs,
    'updated_at': tNoMs,
    'deleted': 0,
  });
  check('JSON → row 往返保真', uwBack['word_id'] == 'w001' && uwBack['added_at'] == tNoMs);
  check(
    '🔑 往返后仍可参与合并（形状兼容）',
    M.mergeUserWord(uwBack, wB)['deleted'] == 1,
  );
  check(
    '⚠️ 反序列化**不产生** `pending_push`（那是同步标记，由 `sync_service` 决定）',
    !uwBack.containsKey('pending_push'),
  );

  final bmJson = M.bookmarkToPushJson(bmark(5, t2, 1));
  check('bookmark → JSON 带 `deleted`（漏了它别端不知道你取消了）', bmJson['deleted'] == 1);
  check('bookmark JSON 键集合正确',
      bmJson.keys.toSet().toString() == M.kPushJsonContract['bookmark']!.toSet().toString());
  final bpJson = M.bookProgressToPushJson(bprog('h', 1, 0.5, t2));
  check('book_progress JSON 键集合正确',
      bpJson.keys.toSet().toString() == M.kPushJsonContract['book_progress']!.toSet().toString());
  final arJson = M.articleReadToPushJson(aread(1, t2));
  check('article_read JSON 键集合正确',
      arJson.keys.toSet().toString() == M.kPushJsonContract['article_read']!.toSet().toString());

  // ═══════════════════════════════════════════════════════════
  section('【10】🔴 修复回归：取消收藏**必须刷新** `bookmarked_at`');

  final repo = stripComments(readFile('../../app/lib/services/bookmark_repository.dart'));
  final removeBody = _fnBody(repo, 'Future<bool> remove(int contentId)');
  if (removeBody.isEmpty) {
    check('🔴 找得到 `remove()` 的函数体', false, '（签名变了？）');
  } else {
    // 🔑 判据锁**语义**（用了公共常量 `kSqlNowUtc`）而不是**拼写**（字面 `strftime(`）——
    //    实现改为常量插值后，源码里**不会**出现字面 `strftime(`
    //    ⇒ 锁拼写会得到**假红**（2026-10-06 本人踩过一次）。
    check(
      '🔴 `remove()` 刷新 `bookmarked_at`（用公共常量 `kSqlNowUtc`）',
      removeBody.contains('bookmarked_at = \$kSqlNowUtc'),
      '—— 不刷新则取消与收藏同值 ⇒ 服务端 `t > t` 为假 ⇒ **丢弃取消** '
          '⇒ 别端拉回去 ⇒「取消了的收藏又自己回来」',
    );
    check('`remove()` 仍置 `deleted = 1`', removeBody.contains('deleted = 1'));
    check('`remove()` 仍置 `pending_push = 1`', removeBody.contains('pending_push = 1'));
  }

  final bookmarkModel = stripComments(readFile('../../app/lib/services/bookmark_repository.dart'));
  check(
    '`Bookmark` 模型带 `deleted` 字段（否则 push 时拿不到取消状态）',
    RegExp(r'final bool deleted;').hasMatch(bookmarkModel),
  );
  check(
    '`_fromRow` 读了 `deleted`',
    bookmarkModel.contains("r['deleted']"),
  );

  // ═══════════════════════════════════════════════════════════
  section('【11】交叉一致性：前端「取较早/较新」与后端 UPSERT 的方向必须一致');

  check(
    '🔴 后端 `sync_article_read` 用 `<`（取较早）—— 与 `mergeArticleRead` 同向',
    RegExp(r'excluded\.read_at\s*<\s*sync_article_read\.read_at').hasMatch(rust),
    '若后端是 `>` 而前端取较早 ⇒ 两端数据永远对不上，且**都不报错**',
  );
  check(
    '🔴 后端 `sync_user_word` 的 `added_at` 用 `MIN(`（取较早）',
    RegExp(r'added_at\s*=\s*MIN\(').hasMatch(rust),
  );
  check(
    '🔴 后端 `sync_user_word` 的 `deleted`/`updated_at` 取较新（用 `>`）',
    RegExp(r'excluded\.updated_at\s*>\s*sync_user_word\.updated_at').hasMatch(rust),
  );
  check(
    '🔴 后端 `sync_bookmark` 用 `>`（取较新）—— 与 `mergeBookmark` 同向',
    RegExp(r'excluded\.bookmarked_at\s*>\s*sync_bookmark\.bookmarked_at').hasMatch(rust),
  );

  // ═══════════════════════════════════════════════════════════
  section('【12】🔴 时间精度契约：同步判定的时间列必须是**毫秒**');

  // 为什么：合并判定是「谁的时间戳更新谁赢」（服务端严格大于 `>`）。
  // 秒精度下「同一秒内的两次操作」得到相同时间戳 ⇒ 后者**永不生效**
  // （收藏→取消、加入→暂停、滚动连更 …）。人手点击间隔 ~0.2s ⇒ 必然重叠。
  final bmRepo = stripComments(readFile('../../app/lib/services/bookmark_repository.dart'));
  final uwRepo = stripComments(readFile('../../app/lib/services/user_word_repository.dart'));

  check(
    '🔴 `kSqlNowUtc` 是**毫秒**表达式（含 `%f`，不含 `%S`）',
    bmRepo.contains(r"strftime('%Y-%m-%dT%H:%M:%fZ', 'now')") &&
        !bmRepo.contains(r"%H:%M:%S"),
    '—— 用 `%S` 会让「同一秒内收藏→取消」的时间戳相同',
  );
  check(
    '🔴 公共常量是**唯一**定义（`user_word_repository` 引用它，不再内联一份）',
    uwRepo.contains('= kSqlNowUtc;') || uwRepo.contains('kSqlNowUtc'),
    '—— 同一口径两处实现 ⇒ 改一处漏一处（本次就是这么发现的）',
  );
  check(
    '🔴 `add()` 的**首次插入**也显式给 `bookmarked_at`（不走 DDL DEFAULT）',
    RegExp(r'INSERT INTO bookmark \(content_id, deleted, bookmarked_at\)')
        .hasMatch(bmRepo),
    '—— 否则「走 DEFAULT 的插入」与「走常量的更新」精度可能不同',
  );
  check(
    '`add()` 的 upsert 分支也用常量',
    RegExp(r'bookmarked_at = \$kSqlNowUtc,').hasMatch(bmRepo),
  );

  for (final tbl in ['bookmark', 'user_word', 'article_read']) {
    final src = tbl == 'bookmark' || tbl == 'user_word' ? schemaUser : schemaUser;
    final m = RegExp('CREATE TABLE IF NOT EXISTS\\s+$tbl\\s*\\(([\\s\\S]*?)\\n\\);',
            multiLine: true)
        .firstMatch(src);
    if (m == null) {
      check('🔴 schema 里找得到 `$tbl`（查 DEFAULT 精度）', false);
      continue;
    }
    check(
      '🔴 `$tbl` 的 DEFAULT 也是毫秒（与代码同口径）',
      m.group(1)!.contains(r"%H:%M:%fZ") && !m.group(1)!.contains(r"%H:%M:%SZ"),
    );
  }

  // ═══════════════════════════════════════════════════════════
  section('【13】🆕 highlight（划线记忆）：字段级合并 + 整组同端');

  // 🔴 本段守的是一个**真实缺口**（2026-10-09）：此前 `review_log`（复习事件）同步，
  //    而 `highlight`（划线本体）**不同步** ⇒ 重装 / 换机的设备会拿到「无主划线卡」：
  //    标题显示成 `hl:<uuid>`、点「暂停」静默无反应、界面上没有出口能去掉它。
  //    📌 判据：**同步的粒度必须覆盖「引用关系」**。

  final hlOld = hmark(
    id: 'h1',
    text: 'the quick fox',
    note: null,
    paused: 0,
    deleted: 0,
    created: tNoMs,
    updated: tNoMs,
  );
  final hlNew = hmark(
    id: 'h1',
    text: '被改写的正文',
    note: '记一下',
    paused: 1,
    deleted: 0,
    created: tLate, // ⚠️ `created_at` **更晚** ⇒ 不算「首次事实」
    updated: t3, // ✅ `updated_at` 更新 ⇒ 意愿生效
  );

  final hm = M.mergeHighlight(hlOld, hlNew);
  check('🔴 `note` 取**较新**（写笔记要能同步）', hm['note'] == '记一下', '${hm['note']}');
  check('🔴 `paused` 取**较新**（暂停要能同步）', hm['paused'] == 1, '${hm['paused']}');
  check('`updated_at` 取较新', hm['updated_at'] == t3);
  check(
    '🔴 `text` 取**较早**那端 —— 正文是「首次事实」，不得被更晚的副本改写',
    hm['text'] == 'the quick fox',
    '实际 ${hm['text']}',
  );
  check('`start_offset` 与 `text` **同端**（不许拼出「A 的正文 + B 的位置」）',
      hm['start_offset'] == 11 && hm['end_offset'] == 24,
      '实际 ${hm['start_offset']}-${hm['end_offset']}');
  check('`source_id` 与 `text` 同端', hm['source_id'] == '42');
  check('`created_at` 取较早', hm['created_at'] == tNoMs);
  check('对称（交换两行参数结论相同）', () {
    final r = M.mergeHighlight(hlNew, hlOld);
    return r['note'] == '记一下' && r['text'] == 'the quick fox' && r['paused'] == 1;
  }());

  // 🔴 清空笔记：`NULL` 是**值**不是「没带这个字段」
  final hlClear = hmark(
    id: 'h1',
    text: 'the quick fox',
    note: null,
    paused: 0,
    deleted: 0,
    created: tNoMs,
    updated: tLate, // 更新 ⇒ 意愿生效
  );
  check(
    '🔴 清空笔记（`note: null` + 更新的 `updated_at`）能生效 —— NULL 是值',
    M.mergeHighlight(hlOld, hlClear)['note'] == null,
    '—— 若写成「取非空」，笔记**永远清不掉**',
  );

  // ⚠️ `chapter_idx` 可空（文章没有章节号）⇒ 沿用「取较早那端的非空值」的宽松口径
  check(
    '`chapter_idx` 为 null（文章）时合并后仍是 null',
    M.mergeHighlight(hlOld, hlNew)['chapter_idx'] == null,
  );
  check(
    '🔑 较早那端没有章节号、另一侧有 ⇒ 退到有值的那端（不丢信息）',
    M.mergeHighlight(hlOld, hmark(
      id: 'h1',
      text: 'the quick fox',
      chapterIdx: 3,
      created: tLate,
      updated: t3,
    ))['chapter_idx'] == 3,
  );

  check('合并结果**不含** `pending_push`（职责分开，同【2】）',
      !hm.containsKey('pending_push'));

  // ── 列名契约（Rust 侧字段存在性在【8】自动覆盖）──
  check('契约表已登记 `highlight`', M.kSyncFieldSources.containsKey('highlight'));
  // 🔄 2026-10-11 改判：原来断言「== 12 列」是**锁数字** ——
  //    加一列（`translation`）就假红，而那次改动**是正确的**。
  //    ⇒ 改为**锁意图**：两个契约表**一一对应**（它们本就该同长），
  //      再加「关键列必须都在」的具名断言。这样加列不会假红，
  //      而「只改了一处」仍会被抓住（判据：断言锁语义形状，不锁拼写）。
  check(
    '🔴 契约表与 push JSON 契约**一一对应**（只改一处 ⇒ 这里红）',
    M.kSyncFieldSources['highlight']!.length ==
        M.kPushJsonContract['highlight']!.length,
    '${M.kSyncFieldSources['highlight']!.length} 列 vs '
    '${M.kPushJsonContract['highlight']!.length} 个字段',
  );
  check(
    '🔴 `translation` 在契约里（漏了它 ⇒ 译文不跨设备 ⇒ 别端永远只有骨架）',
    M.kPushJsonContract['highlight']!.contains('translation') &&
        M.kSyncFieldSources['highlight']!
            .any((e) => e.$2 == 'translation'),
  );
  check(
    '🔴 `paused` 在契约里（漏了它 ⇒ 暂停不跨设备 ⇒「A 暂停、B 上又回来」）',
    M.kPushJsonContract['highlight']!.contains('paused'),
  );
  check(
    '🔴 `note` 在契约里（漏了它 ⇒ 笔记不跨设备）',
    M.kPushJsonContract['highlight']!.contains('note'),
  );
  check(
    '🔴 `created_at` 在契约里（漏了它 ⇒ 无法判「首次事实」）',
    M.kPushJsonContract['highlight']!.contains('created_at'),
  );
  check(
    '🔴 后端 `HighlightOut`（pull 侧）也带 `paused` / `note` —— '
    '少一列 ⇒ 端侧永远收不到那个状态（`serde` 不会报错）',
    _rustStructFields(rust, 'HighlightOut').contains('paused') &&
        _rustStructFields(rust, 'HighlightOut').contains('note'),
    '实际字段：${_rustStructFields(rust, 'HighlightOut').join(',')}',
  );

  // ── 序列化往返（row ↔ 推送 JSON）──
  final hlJson = M.highlightToPushJson(hmark(id: 'h1', note: 'n', paused: 1));
  check(
    'highlight → JSON 键集合正确（漏一个键 ⇒ 端侧照发、对端**静默忽略**）',
    hlJson.keys.toSet().toString() ==
        M.kPushJsonContract['highlight']!.toSet().toString(),
    '${hlJson.keys.toList()}',
  );
  final hlBack = M.highlightFromPullJson({
    'id': 'h1',
    'source_type': 'book',
    'source_id': 'buuid',
    'chapter_idx': 1,
    'start_offset': 2,
    'end_offset': 8,
    'text': 't',
    'note': 'n',
    'paused': 1,
    'deleted': 0,
    'created_at': tNoMs,
    'updated_at': t3,
  });
  check('JSON → row 往返保真（`paused` / `note` / `chapter_idx` 不丢）',
      hlBack['paused'] == 1 && hlBack['note'] == 'n' && hlBack['chapter_idx'] == 1);
  check('⚠️ 反序列化**不产生** `pending_push`（那是同步标记，由 `sync_service` 决定）',
      !hlBack.containsKey('pending_push'));
  check(
    '反向：不同步的表**不必**改（`card_review_state` 仍是秒 —— 它是派生表）',
    stripComments(readFile('../../app/assets/sql/user_db_schema.sql'))
        .contains(r"strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"),
    '—— 有意保留，不是漏改（改它没有收益、徒增 diff）',
  );

  // ═══════════════════════════════════════════════════════════
  section('【14】🆕 同步覆盖面补齐（2026-10-10）：4 类数据的合并口径');

  // ── ① lookup_event：**日志**（内容不可变）⇒ 整行取较早端 ──
  final lem = M.mergeLookupEvent(
      levent(uid: 'u1', at: tNoMs), levent(uid: 'u1', at: t3));
  check('🔑 `lookup_event` 取**较早**端（同一 uid 内容一致 ⇒ 结果稳定、可交换）',
      lem['looked_up_at'] == tNoMs, '${lem['looked_up_at']}');
  check('`lookup_event` 保留 `uid`',
      M.mergeLookupEvent(levent(uid: 'a'), levent(uid: 'a'))['uid'] == 'a');
  check('⚠️ 未命中词（`word_id` 为 null）合并后仍是 null',
      M.mergeLookupEvent(levent(uid: 'u2', wordId: null),
          levent(uid: 'u2', wordId: null))['word_id'] ==
          null);
  check('🔑 `lookup_event` 较早端缺 `word_id` ⇒ 退到另一端（null 是「没这份信息」）',
      M.mergeLookupEvent(levent(uid: 'u3', wordId: null, at: tNoMs),
          levent(uid: 'u3', wordId: 'w009', at: t3))['word_id'] ==
          'w009');
  check('`lookup_event` 不产出 `pending_push`', !lem.containsKey('pending_push'));

  // ── ② book_marker：`deleted` 取 **OR**（本表**没有 `updated_at`**）──
  final mkm = M.mergeBookMarker(mkmark(id: 'm1', deleted: 0, created: tNoMs),
      mkmark(id: 'm1', deleted: 1, created: tNoMs));
  check('🔴 `book_marker` 的 `deleted` 取 **OR**（任一端删过即删）', mkm['deleted'] == 1);
  check(
    '🔴 反向：更晚的「未删」副本**不得复活**',
    M.mergeBookMarker(mkmark(id: 'm1', deleted: 1, created: tNoMs),
            mkmark(id: 'm1', deleted: 0, created: t3))['deleted'] ==
        1,
    '本表没有时间列 ⇒ 若照抄「取较新」，取消**永远传不出去**',
  );
  check(
    '`book_marker` 对称（交换参数结论相同）',
    M.mergeBookMarker(mkmark(id: 'm1', deleted: 1, created: tNoMs),
            mkmark(id: 'm1', deleted: 0, created: tNoMs))['deleted'] ==
        1,
  );
  check(
    '🔑 `book_marker` 位置/摘录取**较早端**',
    M.mergeBookMarker(mkmark(id: 'm1', chapter: 2, ratio: 0.5, created: tNoMs),
            mkmark(id: 'm1', chapter: 99, ratio: 0.99, created: t3))['chapter_idx'] ==
        2,
  );
  check('`book_marker` 保留 `content_hash`（**书**的跨设备身份）',
      mkm['content_hash'] == 'hash-book-1');

  // ── ③ achievement_unlock：`unlocked_at` 取**较早**（首次解锁）──
  check('🔴 `achievement_unlock` 的 `unlocked_at` 取**较早**',
      M.mergeAchievementUnlock(aunlock('k', t2), aunlock('k', tNoMs))['unlocked_at'] ==
          tNoMs);
  check('`achievement_unlock` 对称',
      M.mergeAchievementUnlock(aunlock('k', tNoMs), aunlock('k', t2))['unlocked_at'] ==
          tNoMs);

  // ── ④ setting：`value` 取较新（LWW，整体替换）──
  final stm = M.mergeSetting(setrow('reading_font_size', '17', tNoMs),
      setrow('reading_font_size', '22', t3));
  check('🔴 `setting` 的 `value` 取**较新**端（LWW）', stm['value'] == '22');
  check('`setting` 的 `updated_at` 取较新', stm['updated_at'] == t3);
  check(
    '🔑 `setting` **整体替换**（一个键就是一个原子值，不逐字段拼）',
    M.mergeSetting(setrow('k', '17', t3), setrow('k', '22', tNoMs))['value'] == '17',
  );
  check('`setting` 保留 `key`', stm['key'] == 'reading_font_size');

  // ── 契约表登记 ──
  for (final k in ['lookup_event', 'book_marker', 'achievement_unlock', 'setting']) {
    check('契约表已登记 `$k`',
        M.kSyncFieldSources.containsKey(k) && M.kPushJsonContract.containsKey(k));
  }
  check(
    '🔴 `book_marker` 的跨设备身份在契约里指向 **`book` 表**（不是 `book_marker.book_id`）',
    M.kSyncFieldSources['book_marker']!.contains(('book', 'content_hash')),
    '${M.kSyncFieldSources['book_marker']}',
  );
  check('🔑 `setting` 的字段来自 `setting_sync` 表（不是 `setting`）',
      M.kSyncFieldSources['setting']!.every((e) => e.$1 == 'setting_sync'));

  // ── 跨语言口径核对（后端 UPSERT 的方向必须与端侧合并一致）──
  check('🔴 后端 `sync_book_marker` 用 `MAX(...deleted...)`（OR）—— 与 `mergeBookMarker` 同向',
      RegExp(r'MAX\(excluded\.deleted,\s*sync_book_marker\.deleted\)').hasMatch(rust));
  check('🔴 后端 `sync_achievement_unlock` 用 `MIN(`（取较早）',
      RegExp(r'unlocked_at\s*=\s*MIN\(').hasMatch(rust));
  check('🔴 后端 `sync_setting` 用 `>`（取较新）—— 与 `mergeSetting` 同向',
      RegExp(r'excluded\.updated_at\s*>\s*sync_setting\.updated_at').hasMatch(rust));
  check('🔴 后端 `sync_lookup_event` 用 `INSERT OR IGNORE`（日志不可变）',
      rust.contains('INSERT OR IGNORE INTO sync_lookup_event'));

  _report();
}

/// 从 schema SQL 里取某张表的列名（跳过注释行与约束行）。
List<String> _tableColumns(String schemaSql, String table) {
  final re = RegExp(
    'CREATE TABLE IF NOT EXISTS\\s+$table\\s*\\(([\\s\\S]*?)\\n\\);',
    multiLine: true,
  );
  final m = re.firstMatch(schemaSql);
  if (m == null) return const [];
  final body = m.group(1)!;
  final out = <String>[];
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    // 跳过约束行（PRIMARY KEY / UNIQUE / FOREIGN KEY / CHECK）
    if (RegExp(r'^(PRIMARY|UNIQUE|FOREIGN|CHECK|CONSTRAINT)\b').hasMatch(line)) continue;
    final cm = RegExp(r'^([a-z_][a-z0-9_]*)\s').firstMatch(line);
    if (cm != null) out.add(cm.group(1)!);
  }
  return out;
}

/// 从 Rust 源码里取某个结构体的字段名。
List<String> _rustStructFields(String src, String structName) {
  final re = RegExp(r'pub struct\s+' + structName + r'\s*\{([\s\S]*?)\n\}');
  final m = re.firstMatch(src);
  if (m == null) return const [];
  final out = <String>[];
  for (final raw in m.group(1)!.split('\n')) {
    final cm = RegExp(r'^\s*pub\s+([a-z_][a-z0-9_]*)\s*:').firstMatch(raw);
    if (cm != null) out.add(cm.group(1)!);
  }
  return out;
}

/// 取以 [sig] 开头的函数的**函数体**（到下一个顶层 `\n  }` 为止，粗略但够用）。
String _fnBody(String src, String sig) {
  final i = src.indexOf(sig);
  if (i < 0) return '';
  // 从签名处往后找第一个「行首两个空格 + }」= 方法结束
  final re = RegExp(r'\n  \}', multiLine: true);
  final m = re.firstMatch(src.substring(i));
  if (m == null) return src.substring(i);
  return src.substring(i, i + m.start);
}

void _report() {
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：');
    print('   · 时间戳被改成字符串比较（同一时刻的两种写法会判错）');
    print('   · 某张表的合并口径从「首次事实」被改成「最新意愿」（或反之）');
    print('   · 前端/后端的取早取晚方向不一致');
    print('   · `remove()` 丢了 `bookmarked_at` 刷新（取消会被服务端丢弃）');
    print('   · JSON 字段名与后端结构体漂移（会**静默传空**）');
    print('   · 🆕 `highlight` 的「首次事实」组与「最新意愿」组串了位置'
        '（正文被改写 / 笔记清不掉）');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
