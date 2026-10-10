// CoEvo · `user.db` **迁移验收**（★ 端侧最容易被漏掉的一类保护）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_userdb_migration.dart
//
// # 🔴🔴 为什么必须单独有这一个脚本
//
// 其他 `user.db` 验收（`verify_bookmark` / `verify_review_list` / …）
// 都跑在**新建的临时库**上 → 走的是 `onCreate` → **天然覆盖不到升级路径**。
//
// 而真机上的情况**完全不同**：
//   · 白哥已验过收藏 → 设备上早有 `user.db`（`user_version = 1`）
//   · 后来又验过生词本 → 可能已升到 **2**
//   → 加了新表之后：`onCreate` **不重跑**，**只有 `onUpgrade`** 会触发。
//
// → 若 `onUpgrade` 坏了，**新表根本不会创建**，而**所有其他验收照样全绿**
//   → 一个「在错条件下验证」的完美盲区。
//
// 🔑 判据：**「验收环境的初始状态」必须与「生产的初始状态」一致**。
//    这里的差异不是平台，而是**初始状态**（新库 vs 老库）—— 更隐蔽，
//    因为跑在同一台机器、同一个命令上，只差前置数据。
//
// # 本脚本的升级路径（2026-09-29 起）
// | 起始 | 快照 | 场景 |
// |---|---|---|
// | **v1** | `_v1Schema` | 最早装机的用户（只有 3 表） |
// | **v2** | `_v2Schema` | 验过生词本的用户（5 表） |
// | **v3** | `_v3Schema` | 验过成就的用户（6 表） |
// → 三条都要能升到当前版本，且**旧数据完好**。
//
// # 🔑 自动覆盖「将来新增的表」
// §【4】从 `user_db_schema.sql` **直接提取全部建表语句**，断言升级后**全都在**
// → 以后再加表**不用改本脚本**也能被覆盖（防「加了表忘了加断言」）。
//
// # 🔑 本脚本自身的证伪方式
// 把 `user_db.dart` 的 `kUserDbVersion` 改回 **2** → 本脚本**必须变红**
// （version 不变 → 不触发 `onUpgrade` → `achievement_unlock` 不会建 → §【3】失败）。
// 已实测过一次（见方案 §七 实施记录）。
// 🆕 加 `article_read` 后同理：把 `kUserDbVersion` 改回 **3** → §【6b】必须变红。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/user_db.dart';

var _pass = 0;
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

void section(String t) {
  print('');
  print('─' * 74);
  print(t);
  print('─' * 74);
}

/// **v1 的 schema**（2026-09-27 时点的样子）—— 有意**不含** `user_word` / `lookup_event`。
///
/// 🔑 为什么在这里**复制一份**而不是引用现文件：本脚本要的是**历史快照**。
///    若引用当前 `user_db_schema.sql`，那它永远等于「最新 schema」→
///    「老库」就不再是老的 → 这个脚本会**永远绿**（正是它要防的那种假保护）。
///    ⚠️ 所以这份 DDL **只增不改**：它描述「v1 长什么样」，是契约，不是实现。
const String _v1Schema = '''
CREATE TABLE IF NOT EXISTS card_review_state (
  word_id        TEXT    PRIMARY KEY,
  spelling       TEXT    NOT NULL COLLATE NOCASE,
  state          INTEGER NOT NULL DEFAULT 0 CHECK (state BETWEEN 0 AND 3),
  step           INTEGER,
  stability      REAL,
  difficulty     REAL,
  reps           INTEGER NOT NULL DEFAULT 0,
  lapses         INTEGER NOT NULL DEFAULT 0,
  last_review_at TEXT,
  next_review_at TEXT    NOT NULL,
  pending_push   INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1)),
  updated_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS review_log (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id     TEXT    NOT NULL,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
  duration_ms INTEGER,
  reviewed_at TEXT    NOT NULL,
  utc_day     TEXT    NOT NULL,
  device_id   TEXT    NOT NULL DEFAULT '',
  synced      INTEGER NOT NULL DEFAULT 0 CHECK (synced IN (0, 1)),
  UNIQUE (word_id, reviewed_at, device_id)
);
CREATE TABLE IF NOT EXISTS bookmark (
  content_id    INTEGER PRIMARY KEY,
  bookmarked_at TEXT    NOT NULL
                DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push  INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_bm_time ON bookmark (bookmarked_at DESC);
CREATE INDEX IF NOT EXISTS idx_bm_pending ON bookmark (pending_push)
  WHERE pending_push = 1;
''';

/// **v2 的 schema**（2026-09-28 时点的样子）= v1 + `user_word` + `lookup_event`。
///
/// 🔑 同样是**历史快照**，只增不改（理由见 `_v1Schema`）。
const String _v2Schema = '''
$_v1Schema
CREATE TABLE IF NOT EXISTS user_word (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id           TEXT    NOT NULL,
  spelling          TEXT    NOT NULL COLLATE NOCASE,
  source_article_id INTEGER,
  source_sentence   TEXT,
  added_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at        TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  deleted           INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  pending_push      INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1)),
  UNIQUE (word_id)
);
CREATE TABLE IF NOT EXISTS lookup_event (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  word_id      TEXT,
  spelling     TEXT    NOT NULL COLLATE NOCASE,
  article_id   INTEGER,
  sentence     TEXT,
  position     INTEGER,
  looked_up_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_le_word ON lookup_event (word_id, looked_up_at);
''';

/// **v3 的 schema**（2026-09-29 时点的样子）= v2 + `achievement_unlock`。
///
/// 🔑 同样是**历史快照**，只增不改（理由见 `_v1Schema`）。
/// 🆕 它对应「白哥已验过成就」的设备状态 —— 那时 `user.db` 的 `user_version = 3`。
const String _v3Schema = '''
$_v2Schema
CREATE TABLE IF NOT EXISTS achievement_unlock (
  key         TEXT PRIMARY KEY,
  unlocked_at TEXT NOT NULL
              DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
''';

/// 🆕 **v4 的 schema**（2026-09-29 晚时点的样子）= v3 + `article_read`。
///
/// 🔑 **历史快照**，只增不改（理由见 `_v1Schema`）。
/// 它对应「白哥已验过『我的』页统计」的设备状态 —— 那时 `user_version = 4`。
///
/// ⚠️ `article_read` 的 DDL 抄自 v1.5 时点的 `user_db_schema.sql`
/// （**当时的样子**，不是现在的 —— 现在文件里还有 `external_word_cache`，
///  那是 **v5** 才加的，**不能**出现在 v4 快照里，否则就不是「老库」了）。
const String _v4Schema = '''
$_v3Schema
CREATE TABLE IF NOT EXISTS article_read (
  article_id   INTEGER PRIMARY KEY,
  read_at      TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_ar_pending ON article_read (pending_push)
  WHERE pending_push = 1;
''';

/// 🆕 **v5 的 schema**（2026-10-01 时点的样子）= v4 + `external_word_cache`。
///
/// 🔑 **历史快照**，只增不改（理由见 `_v1Schema`）。
/// 它对应「A2（热词缓存 + LLM 制卡）上线后」的设备状态 —— 那时 `user_version = 5`。
///
/// 🔴 **这一条是最重要的升级路径** —— 理由：
///    真机上**最可能存在的版本就是 v5**（白哥 2026-10-05 刚测过的包 = v5）。
///    在加它之前，脚本只跑 v1~v4 → 当前版本 ⇒ **「v5 → v6」根本没被覆盖**。
///    ⚠️ 而 v6 恰恰是**第一次「给已有表加列」**的版本 ⇒ 风险最高的那一次变更。
/// 📌 判据：**升级路径要覆盖「真实存在的起点」** —— 补历史快照时，
///    优先补**最老的可能起点**与**最新的现状版本**，而不是凑数量。
const String _v5Schema = '''
$_v4Schema
CREATE TABLE IF NOT EXISTS external_word_cache (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  spelling     TEXT    NOT NULL COLLATE NOCASE,
  card_content TEXT    NOT NULL,
  fetched_at   TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  pending_push INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1)),
  UNIQUE (spelling)
);
CREATE INDEX IF NOT EXISTS idx_ewc_pending ON external_word_cache (pending_push)
  WHERE pending_push = 1;
''';

/// **v6 的 schema 快照**（2026-10-05 · 跨设备同步）。
///
/// 🔴 **它存在的唯一理由是补一条盲区**：真机上的 `user.db` 此刻**恰好就是 v6**
///    ⇒ 「**v6 → 当前版本**」是**最真实的那条升级路径**，而它**此前从未被测过**。
///
/// 为什么此前一直没被发现（见 `user_db.dart::kUserDbVersion` 的 v7 说明）：
/// 本脚本的起点原本只有 **v1–v5**，那些路径**版本都在变** ⇒ `onUpgrade` 一定触发
/// ⇒ 每次都能建出新表 ⇒ **全绿** —— 于是「v1.7 加表时忘了升版本号」这个缺陷
/// 一路活到了 2026-10-08。
///
/// ⚠️ v6 的变更是**给已有表加列**（`bookmark.deleted`），而 `ADD COLUMN`
///    不在 schema 脚本里（它在 `onUpgrade` 的分支里）⇒ 这里**显式模拟那次变更**，
///    让「v6 老库」的结构与真机一致（`bookmark` **有** `deleted`）。
///
/// 📌 判据：**测试路径要覆盖「用户此刻真实所处的状态」**，而不只是「历史版本」。
///    「最新的那个版本」恰恰是最容易被漏掉的一条 —— 因为它看起来「已经是新的了」。
const String _v6Schema = '''
$_v5Schema
ALTER TABLE bookmark ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1));
''';

/// **v8 的 schema 快照**（2026-10-08 · `highlight.paused`）。
///
/// 🔴 与 `_v7Schema` **同一条理由**：真机上的 `user.db` 此刻**恰好就是 v8**
///    ⇒ 「**v8 → 当前版本**」是**最真实的那条升级路径**。
///
/// ⚠️ v9 的变更是**新增一张表**（`local_meta`），它**在 schema 脚本里**
///    ⇒ 本快照**不含**它（否则「升级后它存在」那条断言就失去意义）。
///
/// 📌 判据（同 v6/v7）：**测试路径要覆盖「用户此刻真实所处的状态」**。
///    这一条在 2026-10-08 已经用真金白银验证过两次了 ——
///    v6（漏升版本号 ⇒ `highlight` 建不出来）与 v7（同上）**都是「最新那版」被漏掉**。
const String _v8Schema = '''
$_v7Schema
ALTER TABLE highlight ADD COLUMN paused INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1));
''';

/// **v9 的 schema 快照**（2026-10-09 时点的样子）= v8 + `local_meta`。
///
/// 🔴 与 `_v8Schema` **同一条理由**：真机上的 `user.db` 此刻**恰好就是 v9**
///    （10-09 出的包把版本升到了 9）⇒「**v9 → 当前版本**」是**最真实的那条升级路径**。
///
/// ⚠️ v10 的变更里混着**两类**，本快照两样都不能含：
///    · **加列**：`lookup_event.uid` / `lookup_event.pending_push` /
///      `achievement_unlock.pending_push` —— `ADD COLUMN` 不在 schema 脚本里
///      （它在 `onUpgrade` 的 ①c 分支里）⇒ 本快照必须**不含这些列**，
///      否则「升级后它们存在」那条断言就失去意义（本来就存在）。
///    · **加表**：`setting_sync` ⇒ 本快照也**不含**它。
///    📌 判据：「前提类断言」的粒度必须等于被测变更的粒度（加表查表、加列查列）。
const String _v9Schema = '''
$_v8Schema
CREATE TABLE IF NOT EXISTS local_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

/// **v10 的 schema 快照**（2026-10-10 · 同步覆盖面补齐）。
///
/// 🔴 与 `_v9Schema` 的取舍**方向相反**，别照抄：
///    · `_v9Schema` 要「**不含** v10 的变更」（它是被测变更之前的状态）；
///    · `_v10Schema` 是「**v10 发布出去之后**的真实样子」⇒ 必须**如实包含**
///      v10 加的那两列 + 那张表，否则它就不是 v10。
///
/// ⚠️ 为什么非要如实：本脚本有几条断言是**无条件**的
///    （如「`lookup_event.uid` 列已存在」）。若 v10 快照缺了 `uid`，
///    那么「v10 → v11」这条路径里 `oldVersion < 10` 为假 ⇒ `ALTER` 不会跑
///    ⇒ 升级后 `uid` 仍然不存在 ⇒ **那条断言会红，而红的是快照、不是实现**。
///    📌 判据（同上）：**前提类断言的粒度 = 被测变更的粒度**。
///
/// 🔑 写法上：v10 的三处列变更**本来就是 `ALTER`**（见 `user_db.dart` 的
///    `oldVersion < 10` 分支）⇒ 这里也用 `ALTER` 复现，与实现同形。
///    （只用 `CREATE TABLE IF NOT EXISTS` 是**盖不掉**已有表的，所以必须 `ALTER`。）
///
/// ⚠️ v11 的变更只有一处**纯新增表**（`sync_cursor`）⇒ 本快照**不含**它。
const String _v10Schema = '''
$_v9Schema
ALTER TABLE lookup_event ADD COLUMN uid TEXT;
ALTER TABLE lookup_event ADD COLUMN pending_push INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1));
ALTER TABLE achievement_unlock ADD COLUMN pending_push INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1));
CREATE TABLE IF NOT EXISTS setting_sync (
  key          TEXT    PRIMARY KEY,
  value        TEXT    NOT NULL,
  updated_at   TEXT    NOT NULL,
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0, 1))
);
CREATE INDEX IF NOT EXISTS idx_setting_pending ON setting_sync (pending_push)
  WHERE pending_push = 1;
''';

/// **v7 的 schema 快照**（2026-10-08 · 划线 + 翻译缓存）。
///
/// 🔴 与 `_v6Schema` **同一条理由**：真机上的 `user.db` 此刻**恰好就是 v7**
///    ⇒ 「**v7 → 当前版本**」是**最真实的那条升级路径**。
///
/// ⚠️ v8 的变更是**给已有表加列**（`highlight.paused`），而 `ADD COLUMN`
///    不在 schema 脚本里（它在 `onUpgrade` 的 ①b 分支里）⇒ **本快照必须不含 `paused`**
///    （否则「升级后它存在」那条断言就失去意义 —— 它本来就存在）。
///
/// 📌 判据（同 v6）：**测试路径要覆盖「用户此刻真实所处的状态」**，不只是历史版本。
const String _v7Schema = '''
$_v6Schema
CREATE TABLE IF NOT EXISTS highlight (
  id           TEXT    PRIMARY KEY,
  source_type  TEXT    NOT NULL
               CHECK (source_type IN ('article', 'book')),
  source_id    TEXT    NOT NULL,
  chapter_idx  INTEGER,
  start_offset INTEGER NOT NULL,
  end_offset   INTEGER NOT NULL,
  text         TEXT    NOT NULL,
  note         TEXT,
  created_at   TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at   TEXT    NOT NULL
               DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted      INTEGER NOT NULL DEFAULT 0
               CHECK (deleted IN (0, 1)),
  pending_push INTEGER NOT NULL DEFAULT 1
               CHECK (pending_push IN (0, 1))
);;

CREATE INDEX IF NOT EXISTS idx_hl_alive ON highlight (deleted) WHERE deleted = 0;

CREATE INDEX IF NOT EXISTS idx_hl_source ON highlight (source_type, source_id, start_offset) WHERE deleted = 0;

CREATE INDEX IF NOT EXISTS idx_hl_time ON highlight (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_hl_pending ON highlight (pending_push) WHERE pending_push = 1;

CREATE TABLE IF NOT EXISTS translation_cache (
  src_text   TEXT PRIMARY KEY,
  segments   TEXT NOT NULL,
  created_at TEXT NOT NULL
             DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  used_at    TEXT NOT NULL
             DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
''';

/// 从 schema 文件里提取**全部建表语句的表名**。
///
/// 🔑 这样本脚本**不需要**维护一份「应该有哪张表」的清单 ——
///    将来新增表会自动纳入断言范围（防「加了表忘了加断言」）。
List<String> tableNamesInSchema(String sql) {
  final re = RegExp(r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([a-z_]+)',
      caseSensitive: false);
  // ⚠️ 先剥掉注释 —— 否则「注释里举例的建表语句」也会被数进去
  final noComment = splitSqlStatements(sql).join('\n');
  return re
      .allMatches(noComment)
      .map((m) => m.group(1)!)
      .toSet()
      .toList()
    ..sort();
}

Future<List<String>> tableNames(Database db) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
  return rows.map((r) => r['name'] as String).toList();
}

int firstInt(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) return -1;
  final v = rows.first.values.first;
  return v is num ? v.toInt() : -1;
}

/// 跑一条升级路径：建 `fromVersion` 老库 → 写数据 → 用当前实现打开 → 断言。
Future<void> runUpgradeCase({
  required DatabaseFactory factory,
  required String schemaSql,
  required int fromVersion,
  required String oldSchema,
  required List<String> expectedTables,
}) async {
  print('');
  print('═' * 74);
  print('▶ 升级路径：v$fromVersion → v$kUserDbVersion');
  print('═' * 74);

  final dir = await Directory.systemTemp.createTemp('coevo_migrate_v$fromVersion');
  final path = '${dir.path}/user.db';

  section('【1】构造真实的「v$fromVersion 老库」（模拟用户设备上已有的 user.db）');
  final old = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: fromVersion,
      onCreate: (db, _) async {
        for (final s in splitSqlStatements(oldSchema)) {
          await db.execute(s);
        }
      },
    ),
  );
  // 真实数据（旧数据必须在升级后**完好无损**）
  await old.insert('bookmark', {'content_id': 42});
  await old.insert('bookmark', {'content_id': 99});
  await old.insert('card_review_state', {
    'word_id': 'w000001',
    'spelling': 'abandon',
    'next_review_at': '2026-09-28T00:00:00Z',
  });
  if (fromVersion >= 2) {
    await old.insert('user_word', {'word_id': 'w000002', 'spelling': 'benefit'});
  }
  if (fromVersion >= 3) {
    // ⚠️ 🔴 **key 必须与 §【6】插入的那个不同** —— 否则 §【6】会撞唯一约束而**崩溃**
    //    （崩溃比「干净报红」糟：后面的断言一条都不跑、汇总也不打印，容易被误读成环境问题）。
    //    用 `streak_3` 而不是 `first_review`：既避开冲突，又能顺带验「成就记录升级后完好」。
    await old.insert('achievement_unlock', {'key': 'streak_3'});
  }
  if (fromVersion >= 4) {
    // ⚠️ `article_id` 用 **77**（§【6c】那组用的是 7 / 8）—— 避开冲突。
    await old.insert('article_read', {'article_id': 77});
  }

  final oldVer = firstInt(await old.rawQuery('PRAGMA user_version'));
  final oldTables = await tableNames(old);
  check('老库已建立且 user_version = $fromVersion', oldVer == fromVersion, '$oldVer');
  // 🔴 前提：**该老库还不该有「本次要新建的表」** —— 否则「升级后它存在」
  //    这条断言就失去了意义（它本来就存在）。
  //    ⚠️ 这个前提**随 fromVersion 变**（和上面的写入分支同一个道理）：
  //       · v1/v2/v3 老库：都**不含** article_read（v4 才加）
  //       · **v4 老库：含 article_read**（那正是 v4 的内容）→ 必须排除，否则**假红**
  //    📌 判据：**「前提类断言」也要随输入维度变化** —— 写死一个会被自己的路径否掉。
  if (fromVersion < 4) {
    check('🔴 前提成立：v$fromVersion 老库**不含** article_read',
        !oldTables.contains('article_read'));
  } else {
    check('🔴 前提成立：v$fromVersion 老库**含** article_read（v4 的内容）',
        oldTables.contains('article_read'));
  }
  if (fromVersion < 5) {
    check('🔴 前提成立：v$fromVersion 老库**不含** external_word_cache（v5 才加）',
        !oldTables.contains('external_word_cache'));
  } else {
    check('🔴 前提成立：v$fromVersion 老库**含** external_word_cache（v5 的内容）',
        oldTables.contains('external_word_cache'));
  }

  // 🔴🆕 **v6 的前提（本次新增，最关键的一条）**：老库的 `bookmark` **不含 `deleted` 列**
  //    —— 否则「升级后它有 deleted」这条断言就失去意义（它本来就存在）。
  //    ⚠️ 必须查**列**、不是查表：本次变更是**加列**。
  //    📌 判据：「前提类断言」的检查粒度必须**等于被测变更的粒度**
  //       （上一条查表是因为那些版本加的是**表**；本条查列是因为加的是**列**）。
  final oldBmCols = <String>[
    for (final r in await old.rawQuery('PRAGMA table_info(bookmark)'))
      r['name'] as String,
  ];
  // ⚠️ **必须条件式**：v6 的老库**有**那一列（它正是 v6 的内容）——
  //    写死「不含」会让 `fromVersion: 6` 这条路径**假红**。
  if (fromVersion < 6) {
    check('🔴 前提成立：v$fromVersion 老库的 bookmark **不含** deleted 列（v6 才加）',
        !oldBmCols.contains('deleted'), oldBmCols.join(','));
  } else {
    check('🔴 前提成立：v$fromVersion 老库的 bookmark **含** deleted 列（v6 的内容）',
        oldBmCols.contains('deleted'), oldBmCols.join(','));
  }
  check('  （同时确认老库确实有 bookmark 表 —— 否则上面那条是空过）',
      oldBmCols.isNotEmpty);

  // 🔴🆕 **v7 的前提（2026-10-08 新增，本条是「修 bug」的守护）**：
  //    所有老库（v1–v6）都**不含** `highlight` 与 `translation_cache`。
  //    · `highlight` 是 v1.7 加的，但**当时忘了升版本号** ⇒ 真机（v6）拿不到它；
  //      v7 补上了这个升级路径 ⇒ 本断言在 v6 起点的路径上**必须**先确认它不存在
  //      （否则「升级后它存在」就没意义 —— 它本来就存在）。
  //    · `translation_cache` 是 v1.8（本次）新增。
  if (fromVersion < 7) {
    check('🔴 前提成立：v$fromVersion 老库**不含** highlight（v7 才补上升级路径）',
        !oldTables.contains('highlight'));
    check('🔴 前提成立：v$fromVersion 老库**不含** translation_cache（v1.8 才加）',
        !oldTables.contains('translation_cache'));
  }

  // 🔴🆕 **v8 的前提（2026-10-08 新增）**：老库的 `highlight` **不含 `paused` 列**
  //    —— 否则「升级后它有 paused」这条断言就失去意义（它本来就存在）。
  //    ⚠️ 与 v6 那条**同族**（都是「加列」）⇒ **必须查列**，不是查表。
  //    ⚠️ 但比 v6 多一层：v1–v6 的老库**根本没有 `highlight` 表**（v7 才建出它）
  //       ⇒ 表不存在时「不含该列」天然成立，用空列表表达即可。
  //    📌 判据：「前提类断言」的**检查粒度**必须等于被测变更的粒度。
  final oldHlCols = oldTables.contains('highlight')
      ? <String>[
          for (final r in await old.rawQuery('PRAGMA table_info(highlight)'))
            r['name'] as String,
        ]
      : <String>[];
  if (fromVersion < 8) {
    check('🔴 前提成立：v$fromVersion 老库的 highlight **不含** paused 列（v8 才加）',
        !oldHlCols.contains('paused'),
        oldHlCols.isEmpty ? '（表不存在 ⇒ 天然成立）' : oldHlCols.join(','));
  }
  // 🔴🆕 **v9 的前提（2026-10-09）**：老库**不含 `local_meta`**（v9 才加）。
  //    ⚠️ 这次是「加表」（同 v7）⇒ 查**表**，不是查列。
  //    📌 判据：「前提类断言」的检查粒度必须等于被测变更的粒度（加表查表、加列查列）。
  if (fromVersion < 9) {
    check('🔴 前提成立：v$fromVersion 老库**不含** local_meta（v9 才加）',
        !oldTables.contains('local_meta'));
  }

  // 🔴🆕 **v10 的前提（2026-10-10）** —— 三类变更混在同一版本，**粒度分开查**：
  //    · `lookup_event` **不含** `uid` / `pending_push`（加列）
  //    · `achievement_unlock` **不含** `pending_push`（加列）
  //    · **不含** `setting_sync`（加表）
  //    📌 同 v8/v9 的判据：加列查列、加表查表。
  final oldLeCols = oldTables.contains('lookup_event')
      ? <String>[
          for (final r in await old.rawQuery('PRAGMA table_info(lookup_event)'))
            r['name'] as String,
        ]
      : <String>[];
  final oldAchCols = oldTables.contains('achievement_unlock')
      ? <String>[
          for (final r
              in await old.rawQuery('PRAGMA table_info(achievement_unlock)'))
            r['name'] as String,
        ]
      : <String>[];
  if (fromVersion < 10) {
    check('🔴 前提成立：v$fromVersion 老库的 lookup_event **不含** uid 列（v10 才加）',
        !oldLeCols.contains('uid'),
        oldLeCols.isEmpty ? '（表不存在 ⇒ 天然成立）' : oldLeCols.join(','));
    check('🔴 前提成立：v$fromVersion 老库的 lookup_event **不含** pending_push 列（v10）',
        !oldLeCols.contains('pending_push'),
        oldLeCols.isEmpty ? '（表不存在 ⇒ 天然成立）' : oldLeCols.join(','));
    check('🔴 前提成立：v$fromVersion 老库的 achievement_unlock **不含** pending_push 列',
        !oldAchCols.contains('pending_push'),
        oldAchCols.isEmpty ? '（表不存在 ⇒ 天然成立）' : oldAchCols.join(','));
    check('🔴 前提成立：v$fromVersion 老库**不含** setting_sync（v10 才加）',
        !oldTables.contains('setting_sync'));
  }
  if (fromVersion < 11) {
    // 🆕 v11（2026-10-10）：游标表。**纯新增表** ⇒ 前提只查「表在不在」。
    check('🔴 前提成立：v$fromVersion 老库**不含** sync_cursor（v11 才加）',
        !oldTables.contains('sync_cursor'));
  }

  check('老库已有 bookmark 数据（2 条）',
      firstInt(await old.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  await old.close();

  section('【2】用「当前实现」（version=$kUserDbVersion + 全量 schema）重新打开 → 触发升级');
  final db =
      await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  final tables = await tableNames(db);
  final ver = firstInt(await db.rawQuery('PRAGMA user_version'));

  section('【3】升级结果 —— 🔴 核心断言');
  check('被断言的前提：kUserDbVersion > $fromVersion（否则不触发 onUpgrade）',
      kUserDbVersion > fromVersion, '当前 $kUserDbVersion');
  check('🔴 achievement_unlock 已创建（老库升级拿到了新表）',
      tables.contains('achievement_unlock'));
  check('🔴 article_read 已创建（v1.5 新表）', tables.contains('article_read'));
  // 🆕 v7（2026-10-08）：这两张是**本次修复/新增**的表
  check('🔴 highlight 已创建（v1.7 加的表 —— v7 补上了「老库拿不到它」的升级路径）',
      tables.contains('highlight'));
  check('🔴 translation_cache 已创建（v1.8 新表）',
      tables.contains('translation_cache'));
  // 🆕 v8（2026-10-08）：`highlight.paused` —— **「加列」的守护**（与上面两条「加表」不同）
  final hlCols = <String>[
    for (final r in await db.rawQuery('PRAGMA table_info(highlight)'))
      r['name'] as String,
  ];
  check('🔴 highlight.paused 列已存在（v8 的 ALTER 生效）',
      hlCols.contains('paused'), hlCols.join(','));
  // 🔑 列顺序：`paused` 必须是**最后一列**。
  //    `ALTER TABLE ADD COLUMN` 只能追加到末尾，而 schema 文件里它也写在末尾
  //    ⇒ 「新建的库」与「升级出来的库」列顺序**一致**。
  //    ⚠️ 少了这条，将来有人在 schema 里把它插到中间 ⇒ 两类库错位 ⇒
  //       按**下标**取值的代码在两种库上读到不同列（**静默值错位**）。
  check('🔴 paused 是 highlight 的最后一列（新旧库列顺序一致）',
      hlCols.isNotEmpty && hlCols.last == 'paused', hlCols.join(','));
  // 🆕 v9（2026-10-09）：`local_meta` —— **「加表」的守护**（与 v7 同族）。
  //    它是「本地数据归属账号」的判据表：建不出来 ⇒ 归属读不到 ⇒
  //    换账号时**不清空**（静默地把上一个账号的数据留在新账号名下）。
  check('🔴 local_meta 已创建（v1.9 新表 —— 「本地数据归属账号」的判据）',
      tables.contains('local_meta'));
  // 🆕 v10（2026-10-10）：同步覆盖面补齐 —— **两处「加列」+ 一处「加表」**。
  //    🔴 这是本版本最容易漏的一类（加列靠 `ALTER`，重跑全量脚本**覆盖不了**）。
  final leCols = <String>[
    for (final r in await db.rawQuery('PRAGMA table_info(lookup_event)'))
      r['name'] as String,
  ];
  check('🔴 lookup_event.uid 列已存在（v10 的 ALTER 生效 —— 同步的跨设备身份）',
      leCols.contains('uid'), leCols.join(','));
  check('🔴 lookup_event.pending_push 列已存在（v10 的 ALTER 生效）',
      leCols.contains('pending_push'), leCols.join(','));
  // 🔑 列顺序：新列必须是**最后两列**（`ALTER` 只能追加末尾 + schema 里也写在末尾
  //    ⇒ 「新建的库」与「升级出来的库」列顺序一致，按位置取值的代码不会错位）。
  check('🔑 lookup_event 末两列是 uid / pending_push（新旧库列顺序一致）',
      leCols.length >= 2 &&
          leCols[leCols.length - 2] == 'uid' &&
          leCols.last == 'pending_push',
      leCols.join(','));
  final achCols = <String>[
    for (final r in await db.rawQuery('PRAGMA table_info(achievement_unlock)'))
      r['name'] as String,
  ];
  check('🔴 achievement_unlock.pending_push 列已存在（v10 的 ALTER 生效）',
      achCols.contains('pending_push'), achCols.join(','));
  check('🔴 setting_sync 已创建（v1.10 新表 —— 设置同步的载体）',
      tables.contains('setting_sync'));
  // 🆕 v11（2026-10-10）：`sync_cursor` —— **「加表」的守护**（与 v7/v9 同族）。
  //    🔴 它建不出来的后果是**静默**的：游标写不进库 ⇒ 每次同步都被当成「首次」
  //       ⇒ 每轮都**全量重拉**（功能不坏，但流量与耗时白涨，且没人会发现）。
  //    另一半守护在 `verify_local_owner`（该表必须 ∈ `kUserOwnedTables`）。
  check('🔴 sync_cursor 已创建（v1.11 新表 —— 增量同步游标，与数据同生命周期）',
      tables.contains('sync_cursor'));
  check('user_version 已升到 $kUserDbVersion', ver == kUserDbVersion, '$ver');

  section('【4】🔑 全量表清单（从 schema 自动提取 → 将来加表自动覆盖）');
  final missing = expectedTables.where((t) => !tables.contains(t)).toList();
  check('schema 里声明的 ${expectedTables.length} 张表**升级后全都在**',
      missing.isEmpty, missing.isEmpty ? '' : '缺: ${missing.join(", ")}');

  section('【5】旧数据完好（升级不能丢数据）');
  check('bookmark 旧数据仍是 2 条',
      firstInt(await db.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check(
      'bookmark 内容未被改动',
      (await db.query('bookmark', columns: ['content_id'], orderBy: 'content_id'))
              .map((r) => r['content_id'])
              .toList()
              .toString() ==
          '[42, 99]');
  check('card_review_state 旧数据仍是 1 条',
      firstInt(await db
              .rawQuery('SELECT count(*) AS n FROM card_review_state')) ==
          1);
  check('card_review_state 的 spelling 未丢',
      (await db.query('card_review_state', columns: ['spelling']))
              .first['spelling'] ==
          'abandon');
  if (fromVersion >= 2) {
    check('user_word 旧数据仍是 1 条（v2 库特有）',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM user_word')) == 1);
  }
  if (fromVersion >= 3) {
    check('achievement_unlock 旧数据仍是 1 条（v3 库特有）',
        firstInt(await db
                .rawQuery('SELECT count(*) AS n FROM achievement_unlock')) ==
            1);
    check('🔴 成就解锁记录未被改动（key 仍是 streak_3）',
        (await db.query('achievement_unlock', columns: ['key']))
                .first['key'] ==
            'streak_3');
  }
  if (fromVersion >= 4) {
    check('🆕 article_read 旧数据仍是 1 条（v4 库特有）',
        firstInt(await db.rawQuery('SELECT count(*) AS n FROM article_read')) == 1);
    check('🔴 阅读记录未被改动（article_id 仍是 77）',
        (await db.query('article_read', columns: ['article_id']))
                .first['article_id'] ==
            77);
  }

  // ══════════════════════════════════════════════════════════════════════════
  section('【5b】🔴🆕 v6 加列：`bookmark.deleted`（跨设备同步 · 收藏改软删）');
  // ══════════════════════════════════════════════════════════════════════════
  //
  // 这是本库**第一次「给已有表加列」** —— 与前几版「纯新增表」是**两种性质**：
  // 新增表能被「重跑全量幂等脚本」覆盖，**加列不能**（`IF NOT EXISTS` 见表就跳过）
  // ⇒ 必须靠 `onUpgrade` 里的 `ALTER`。这几条断言就是守住它。
  final bmColsAfter = <String>[
    for (final r in await db.rawQuery('PRAGMA table_info(bookmark)'))
      r['name'] as String,
  ];
  final hasDeleted = bmColsAfter.contains('deleted');
  check('🔴 `bookmark` 有 `deleted` 列 —— 加列**只能**靠 ALTER（全量脚本覆盖不了）',
      hasDeleted, bmColsAfter.join(','));

  // 🔴🔴 **下面两条必须包在 `if (hasDeleted)` 里**（2026-10-05 证伪时实测踩到）
  //
  // 它们会 **查询 `deleted` 列** —— 若该列不存在，SQLite 直接抛
  // `no such column: deleted` ⇒ **整个脚本崩溃**（退出码 255）。
  // ⚠️ 崩溃比「干净报红」糟得多：**后面的断言一条都不跑、汇总也不打印**，
  //    容易被误读成「环境问题 / 脚本坏了」，而不是「迁移漏了加列」。
  //    （本脚本 §241 的注释早就记过这一族坑，这次是它在**断言自身**上复发。）
  //
  // 📌 判据：**「依赖某前提的断言」在前提不成立时要跳过，而不是让它把脚本炸掉**。
  //    门禁的正确形态是「红 + 指出原因」，不是「崩 + 什么都不说」。
  //    ✅ 前提不足时跳过**不会**削弱门禁：上面那条已经红了，门禁已经是红的。
  if (hasDeleted) {
    // 🔴 默认值必须是 **0**：老库已有的收藏**不能**被当成「已删除」
    //    （否则用户升级后**收藏全部消失** —— 静默数据事故，且用户无从解释、我们无从复现）
    check('🔴 老收藏的 `deleted` 默认值是 **0**（不是 1）—— 否则升级后收藏全没了',
        firstInt(await db
                .rawQuery('SELECT count(*) AS n FROM bookmark WHERE deleted = 0')) ==
            2);
    check('  且没有一行的 deleted = 1（老数据不该凭空变成「已删」）',
        firstInt(await db
                .rawQuery('SELECT count(*) AS n FROM bookmark WHERE deleted = 1')) ==
            0);

    // 🔴 **CHECK 必须真的生效** —— 这才是「加列时带上 CHECK」的目的。
    //    ⚠️ 若 `onUpgrade` 的 ddl 漏写成 `INTEGER NOT NULL DEFAULT 0`
    //       （不带 CHECK），老库就能写进 `deleted = 2`，而**新建的库会拒绝**
    //       ⇒ 两种库的约束漂移，同步逻辑（把 deleted 当布尔）行为不同，且**不报错**。
    var checkEnforced = false;
    try {
      await db.insert('bookmark', {'content_id': 777, 'deleted': 2});
    } catch (_) {
      checkEnforced = true;
    }
    check('🔴 CHECK(deleted IN (0,1)) 在**升级出来的**库上也生效（写 2 必须报错）',
        checkEnforced);
    if (!checkEnforced) {
      // CHECK 没生效时那一行**真的插进去了** ⇒ 清掉，避免污染后续断言
      await db.delete('bookmark', where: 'content_id = ?', whereArgs: [777]);
    }
  }

  // 🔑 直接读 `sqlite_master` 的 DDL，确认**升级出来的表**定义里也带 CHECK
  //    （`ALTER TABLE ADD COLUMN` 会**重写** sqlite_master 里的 CREATE TABLE 语句 ⇒ 可以这样验）
  //    📌 这是「加列」场景下唯一能证明「两种库定义一致」的判据。
  final bmDdl = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'bookmark'"))
      .first['sql'] as String;
  check('🔑 升级后的 bookmark DDL 同时含 `deleted` 与 `CHECK (deleted IN (0, 1))`'
      '（与新建库**同一份定义**）',
      bmDdl.contains('deleted') && bmDdl.contains('CHECK (deleted IN (0, 1))'));

  section('【6】新表**可正常使用**（不只是「存在」）');
  // 🔴 前置守卫：若 §3 判定「新表没建出来」，继续 INSERT 会**直接抛异常** →
  //    脚本崩溃、后面的断言一条都不跑、汇总也不打印。
  //    ⚠️ 崩溃比「干净报红」糟：容易被误读成「环境问题」，
  //       而这里要表达的恰恰是「**迁移逻辑错了**」。
  if (!tables.contains('achievement_unlock')) {
    print('  ⏭  跳过：achievement_unlock 未创建 → 后续插入必然抛异常');
    print('      （**这是预期行为** —— §3 的报红已定位到根因，不必再往下跑）');
  } else {
    await db.insert('achievement_unlock', {'key': 'first_review'});
    // 🔴 **不要断言 `count(*) == 1`** —— 那依赖「表原本是空的」这个**未声明前提**，
    //    而它随 `fromVersion` 变化（v3 老库已带 `streak_3` → 会是 2 条）。
    //    实测踩过：v1/v2 绿、v3 红，报的是「可写入、可读回」失败 —— 假红。
    //    → 断言要锁定**本次插入的那一行**，而不是表的总量。
    check('可写入、可读回',
        (await db.query('achievement_unlock',
                where: 'key = ?', whereArgs: ['first_review']))
            .length ==
            1);
    // 🔑 DEFAULT 生效（插入时不提供 unlocked_at）
    final row = (await db.query('achievement_unlock')).first;
    check('🔴 unlocked_at 有 DEFAULT（未显式提供也写入）',
        (row['unlocked_at'] as String?)?.isNotEmpty == true,
        '${row['unlocked_at']}');
    check('🔴 unlocked_at 是 UTC ISO8601 带 Z（本库硬约束 1）',
        (row['unlocked_at'] as String).endsWith('Z'),
        '${row['unlocked_at']}');

    section('【7】约束真的生效');
    var dupRejected = false;
    try {
      await db.insert('achievement_unlock', {'key': 'first_review'});
    } catch (_) {
      dupRejected = true;
    }
    check('🔴 PRIMARY KEY(key) 生效（同一成就不会重复解锁）', dupRejected);
  }

  // 🆕 v1.5 新表：`article_read`（「阅读篇数」的数据源）
  section('【6b】新表 `article_read` **可正常使用**（v1.5）');
  if (!tables.contains('article_read')) {
    print('  ⏭  跳过：article_read 未创建（§3 已报红，根因在那里）');
  } else {
    await db.insert('article_read', {'article_id': 7});
    await db.insert('article_read', {'article_id': 8});
    // 同样**不**断言绝对总数（理由见 §【6】）—— 锁定本次插入的那两行。
    check('可写入、可读回',
        (await db.query('article_read', where: 'article_id IN (7, 8)'))
                .length ==
            2);

    final row = (await db.query('article_read', where: 'article_id = ?', whereArgs: [7])).first;
    check('🔴 read_at 有 DEFAULT（未显式提供也写入）',
        (row['read_at'] as String?)?.isNotEmpty == true, '${row['read_at']}');
    check('🔴 read_at 是 UTC ISO8601 带 Z（本库硬约束 1）',
        (row['read_at'] as String).endsWith('Z'), '${row['read_at']}');
    check('🔴 pending_push 默认 1（与 bookmark 同模式）',
        (row['pending_push'] as num).toInt() == 1);

    section('【7b】`article_read` 约束真的生效');
    // 🔴 PRIMARY KEY = 去重（同一篇读两次算 1 篇 —— 口径「乙」的核心前提）
    var dupReadRejected = false;
    try {
      await db.insert('article_read', {'article_id': 7});
    } catch (_) {
      dupReadRejected = true;
    }
    check('🔴 PRIMARY KEY(article_id) 生效（同一篇不会重复计数）', dupReadRejected);

    // 🔑 `INSERT OR IGNORE` 是**幂等写入路径**（repository 会这么写）——
    //    不抛异常、也不破坏已有行（`read_at` 保持**首次**时刻）
    final before = (await db.query('article_read', where: 'article_id = ?', whereArgs: [7])).first;
    final nBefore = firstInt(await db.rawQuery('SELECT count(*) AS n FROM article_read'));
    await db.insert('article_read', {'article_id': 7},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final after = (await db.query('article_read', where: 'article_id = ?', whereArgs: [7])).first;
    final nAfter = firstInt(await db.rawQuery('SELECT count(*) AS n FROM article_read'));
    // 用「前后差」而不是绝对数 —— 同样为了不依赖表的初始状态
    check('🔴 INSERT OR IGNORE 幂等：行数未增', nAfter == nBefore, '$nBefore → $nAfter');
    check('🔴 INSERT OR IGNORE 幂等：read_at 未被覆盖（保持首次时刻）',
        after['read_at'] == before['read_at'], '${after['read_at']}');

    // 统计口径（「阅读篇数」的查询就是这一句）
    // ⚠️ **不能用绝对数**（本脚本 §【6】开头已立此判据）——
    //    v4 老库自带一条 `article_id=77` → 绝对数会随 `fromVersion` 变
    //    （实测踩过：v1/v2/v3 绿、**v4 红**）。改为「锁定本次插入的那批」。
    check('统计查询可用（包含本次插入的 7 / 8）',
        firstInt(await db.rawQuery(
                'SELECT count(*) AS n FROM article_read WHERE article_id IN (7, 8)')) ==
            2);
  }

  // ── 【6c】🆕 `external_word_cache` 可正常使用（v5 · A2）──
  section('【6c】🆕 新表 `external_word_cache` **可正常使用**（v5 · A2）');
  if (!expectedTables.contains('external_word_cache')) {
    print('  ⏭  跳过：external_word_cache 未创建（§3 已报红，根因在那里）');
  } else if (!(await tableNames(db)).contains('external_word_cache')) {
    print('  ⏭  跳过：本路径的老库升级后没有该表（§3 已报红）');
  } else {
    // 🔑 这一组验的是「**词库外的词**能不能被存住」——
    //    它是 A2 的核心：缓存写不进 = 那个词查完就丢（复习页「看得见、点不开」）。
    await db.insert('external_word_cache', {
      'spelling': 'brainstorm',
      'card_content': '{"front":"brainstorm","entry_type":"word","sections":[]}',
    });
    final r = (await db.query('external_word_cache', where: 'spelling = ?',
            whereArgs: ['brainstorm']))
        .first;
    check('可写入、可读回', (r['card_content'] as String).isNotEmpty);

    check('🔴 fetched_at 有 DEFAULT（未显式提供也写入）',
        (r['fetched_at'] as String?)?.isNotEmpty == true, '${r['fetched_at']}');
    check('🔴 fetched_at 是 UTC ISO8601 带 Z（本库硬约束 1）',
        (r['fetched_at'] as String).endsWith('Z'), '${r['fetched_at']}');
    check('🔴 pending_push 默认 1（与 bookmark 同模式）',
        (r['pending_push'] as num).toInt() == 1);

    section('【7c】`external_word_cache` 约束真的生效');
    // 🔴 UNIQUE(spelling) 是「一词一行」的保证 —— 缓存覆盖靠它
    var dupRejected = false;
    try {
      await db.insert('external_word_cache', {
        'spelling': 'brainstorm',
        'card_content': '{}',
      });
    } catch (_) {
      dupRejected = true;
    }
    check('🔴 UNIQUE(spelling) 生效（同一个词不会有两份缓存）', dupRejected);

    // 🔑 `COLLATE NOCASE` —— 存 `brainstorm` 用 `BRAINSTORM` 也要能查到。
    //    ⚠️ 这条若失效，表现为「缓存明明写了却读不到」→ **每次查都重新联网**（静默浪费）。
    check('🔴 COLLATE NOCASE 生效（大写也能查到同一行）',
        (await db.query('external_word_cache',
                where: 'spelling = ?', whereArgs: ['BRAINSTORM']))
            .isNotEmpty);

    // 🔑 `INSERT OR REPLACE`（repository 的 `put` 用它）→ 内容被**刷新**
    await db.insert(
        'external_word_cache',
        {'spelling': 'brainstorm', 'card_content': '{"front":"v2"}'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    check('🔴 `put` 是**覆盖**语义（与 user_word 的幂等相反）',
        (await db.query('external_word_cache',
                where: 'spelling = ?', whereArgs: ['brainstorm']))
            .first['card_content'] ==
            '{"front":"v2"}');
    check('🔴 覆盖后**仍只有一行**（UNIQUE 没被绕过）',
        firstInt(await db.rawQuery(
                "SELECT count(*) AS n FROM external_word_cache WHERE spelling='brainstorm'")) ==
            1);
  }

  section('【8】幂等：再次打开不应报错、不应重复建表（App 每次启动都会走）');
  await db.close();
  final again =
      await openUserDb(factory: factory, path: path, schemaSql: schemaSql);
  check('二次打开成功（schema 全为 IF NOT EXISTS → 重跑安全）', true);
  final againTables = await tableNames(again);
  check('二次打开后全部表仍在',
      expectedTables.every(againTables.contains));
  check('二次打开后旧数据仍在（未误删）',
      firstInt(await again.rawQuery('SELECT count(*) AS n FROM bookmark')) == 2);
  check('二次打开后 user_version 仍为 $kUserDbVersion',
      firstInt(await again.rawQuery('PRAGMA user_version')) == kUserDbVersion);
  await again.close();

  await dir.delete(recursive: true);
}

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  // 当前 schema —— 与 App 侧 `rootBundle.loadString(kUserDbSchemaAsset)` 读的是**同一份文件**
  final schemaSql =
      File('../../app/assets/sql/user_db_schema.sql').readAsStringSync();
  final expectedTables = tableNamesInSchema(schemaSql);

  print('');
  print('#' * 74);
  print('# user.db 迁移验收 —— 起止版本 v1/v2/v3 → v$kUserDbVersion');
  print('# schema 声明的表：${expectedTables.join(", ")}');
  print('#' * 74);

  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 1,
    oldSchema: _v1Schema,
    expectedTables: expectedTables,
  );
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 2,
    oldSchema: _v2Schema,
    expectedTables: expectedTables,
  );
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 3,
    oldSchema: _v3Schema,
    expectedTables: expectedTables,
  );
  // 🆕 v5（2026-10-01 · A2）：真机上的库此刻可能是 v4
  //    （白哥跑过带「阅读篇数」的版本）→ 必须靠 onUpgrade 建出 `external_word_cache`。
  //    🔴 它缺失时比前几次更严重：**词库外的词查完就丢**
  //      （缓存写不进去 → 复习页取卡回落失败 → 那个词「看得见、点不开」）。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 4,
    oldSchema: _v4Schema,
    expectedTables: expectedTables,
  );
  // 🆕 **v6（2026-10-05 · 跨设备同步）：本次最重要的一条路径**
  //
  // 🔴 为什么它最重要：
  //    · 真机上的库此刻**很可能就是 v5**（白哥 2026-10-05 刚测过的包 = v5）
  //      ⇒ 这才是「真实用户升级」的主路径，不是 v1~v4 那些历史起点
  //    · v6 是**第一次「给已有表加列」**（`bookmark.deleted`）
  //      ⇒ **加列靠 `ALTER`，重跑全量脚本覆盖不了** —— 最容易漏的一类变更
  //    · 漏了是**静默的**：老库永远没有 `deleted` 列 ⇒ 收藏同步时
  //      「取消收藏」的删除**同步不出去**（另一台设备上收藏又回来），而不报任何错
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 5,
    oldSchema: _v5Schema,
    expectedTables: expectedTables,
  );

  // 🆕 **v6（2026-10-08 补）—— 这是「真机现状」，也是此前唯一的盲区**
  //
  // 🔴 为什么它是**最重要**的一条：真机上的 `user.db` 此刻**恰好就是 v6**。
  //    ⇒ 「v6 → v7」不是历史路径，**是白哥打开下一个包时真实会发生的事**。
  //
  // 🔑 而它此前恰恰没被测过 —— 因为 v1–v5 的路径**版本都在变**，
  //    `onUpgrade` 一定触发 ⇒ 每次都能建出新表 ⇒ 全绿。
  //    于是「**v1.7 加 `highlight` 时忘了升版本号**」这个缺陷一路活到 v7 才被发现：
  //    真机（v6）打开新版 app 时**版本没变** ⇒ `onUpgrade` **不触发**
  //    ⇒ `highlight` **永远建不出来** ⇒ 划线功能**静默失败**。
  //
  // 📌 判据：**测试要覆盖「用户此刻真实所处的状态」**，不只覆盖历史版本。
  //    「最新那个版本」最容易被漏 —— 它看起来「已经是新的了」。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 6,
    oldSchema: _v6Schema,
    expectedTables: expectedTables,
  );

  // ── 🆕 v7 起点（2026-10-08）—— **今天真机所处的版本** ──
  //
  // 🔴 为什么必须有这一条：v8 的变更是**给 `highlight` 加列**。
  //    `CREATE TABLE IF NOT EXISTS highlight (...)` 对**已存在的表整条跳过**
  //    ⇒ 若 `onUpgrade` 里漏了 ①b 那段 `ALTER`，**老库永远拿不到 `paused`**
  //    ⇒ 复习页的「暂停」对划线卡**继续静默无效**（正是本次修的那个 bug）。
  //    📌 判据（同 v6→v7 那次）：「最新那个版本」最容易被漏 ——
  //       它看起来「已经是新的了」，而**用户此刻恰好就在那儿**。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 7,
    oldSchema: _v7Schema,
    expectedTables: expectedTables,
  );

  // 🔴🆕 **v8 → 当前**（2026-10-09 加）：真机上此刻**恰好是 v8**的库最多
  //    （10-08 出的包把版本升到了 8 —— 详见 `kUserDbVersion` 注释），
  //    而 v9 是「加表」⇒ 必须靠 `onUpgrade` 建出 `local_meta`。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 8,
    oldSchema: _v8Schema,
    expectedTables: expectedTables,
  );

  // 🔴🆕 **v9 → 当前**（2026-10-10 加）：真机上此刻**恰好是 v9**的库最多
  //    （10-09 出的包把版本升到了 9 —— 详见 `kUserDbVersion` 注释）。
  //    v10 的变更是**两处加列 + 一处加表**：
  //      · 加列（`lookup_event.uid` / `.pending_push` / `achievement_unlock.pending_push`）
  //        靠 `ALTER`，**重跑全量脚本覆盖不了** ⇒ 漏了就是**静默失败**
  //        （查词记录推不上去 / 成就日期是假的 / 设置不同步）。
  //      · 加表（`setting_sync`）靠重跑脚本。
  //    📌 判据（同 v7/v9 那两次）：「最新那个版本」最容易被漏 ——
  //       它看起来「已经是新的了」，而**用户此刻恰好就在那儿**。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 9,
    oldSchema: _v9Schema,
    expectedTables: expectedTables,
  );

  // 🔴🆕 **v10 → 当前**（2026-10-10 加）：真机上此刻**恰好是 v10** 的库最多
  //    （10-10 出的包把版本升到了 10 —— 见 `kUserDbVersion` 注释）。
  //    v11 的变更只有**一处**：🆕 `sync_cursor`（**纯新增表**，靠重跑幂等脚本）。
  //    🔑 与 v10 不同，**没有加列** ⇒ 不需要 `ALTER` 分支 —— 而这条路径正是
  //       「**没有分支也应当能过**」的守护：若哪天有人误以为「必须写分支」
  //       而写了个错的，这里会红。
  //    📌 判据（同 v7/v9/v10）：「**最新那个版本**」最容易被漏 ——
  //       它看起来「已经是新的了」，而**用户此刻恰好就在那儿**。
  await runUpgradeCase(
    factory: factory,
    schemaSql: schemaSql,
    fromVersion: 10,
    oldSchema: _v10Schema,
    expectedTables: expectedTables,
  );

  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项（v1…v10 → v$kUserDbVersion 十条路径）');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若「新表已创建」失败 → 检查 `user_db.dart` 的');
    print('    `kUserDbVersion` 是否 > 起始版本、`onUpgrade` 是否真的重跑了 schema。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
