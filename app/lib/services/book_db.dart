// CoEvo · 端侧电子书库 `book.db` 的连接层
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**
//    —— 理由与 `user_db.dart` 完全一致：纯 Dart 才能在本机独立验证
//    （本地 `flutter` 命令建不了子进程，见 `docs/review/flutter-run-blocker-2026-09-27.md`）。
//
// # 两处刻意的设计（照搬 `user_db.dart` 已验证的结论，不重新发明）
//
// ## ① DDL 由调用方注入，本层不读 assets
//    读 assets 要用 `rootBundle`（Flutter API）⇒ 一旦在本层调用就无法纯 Dart 验证。
//    ⇒ Flutter 侧 `rootBundle.loadString`，验证脚本 `File(...).readAsStringSync()`。
//
// ## ② 建表脚本复用 `user_db.dart` 的拆分器
//    `sqflite` 的 `execute()` 一次只能跑一条语句，而 schema 是整段脚本。
//    🔑 拆分器**只该有一份** —— 两套实现迟早漂移（本项目已记过这类教训）。
//    ⇒ 直接复用 `executeSqlScript` / `splitSqlStatements`，不再抄一遍。
//
// # 为什么要有 `book.db`（第三个库）
// 见 `assets/sql/book_db_schema.sql` 顶部：`user.db` 是「学习状态」，
// 本库是「**用户导入的内容**」—— 删书不该碰学习数据。

import 'package:sqflite_common/sqlite_api.dart';

import 'user_db.dart' show addColumnIfMissing, executeSqlScript;

/// `book.db` 的文件名（调用方拼路径用）。
const String kBookDbFileName = 'book.db';

/// schema 脚本的 asset 路径。
///
/// ⚠️ 它必须落在 `pubspec.yaml` 已声明的目录内 —— 目前声明的是
///    `- assets/sql/`（**目录**，不是单文件）⇒ 新增本文件**自动进包**，不必改 pubspec。
///    （对照：`assets/word.db` 是**逐文件**声明，同目录新增文件不会连带打包 —— 那条坑已踩过。）
const String kBookDbSchemaAsset = 'assets/sql/book_db_schema.sql';

/// `book.db` 的 schema 版本。
///
/// ## 版本历史
/// | 版本 | 内容 | 变更类型 |
/// |---|---|---|
/// | **1** | 初版：`book` · `book_chapter` · `book_progress` | — |
/// | **2** | 🆕 `book.content_hash`（内容指纹）· 🆕 `book_progress_pending`（待认领进度）| **加列** + 新增表 |
/// | **3** | 🆕 `book_marker`（书签 · 位置标记）| **新增表** |
///
/// ⚠️ 本库是**新增的库**（真机上尚不存在）⇒ `onCreate` 一定会走。
///
/// 🔑 **但仍然写迁移分支**（v2），两条理由：
///   ① 若有测试机已经建过 v1 库，`onCreate` **不会再走**（只走 `onUpgrade`）
///   ② 本次两处变更性质**不同**：
///      · `book_progress_pending` = **新增表** ⇒ 重跑全量幂等脚本**能**覆盖
///      · `book.content_hash` = **加列** ⇒ 重跑脚本**不能**覆盖（`IF NOT EXISTS` 见表就跳过）
///   ⇒ 只测「全新库」会**假绿**（全新的当然有这一列，因为建表语句里写了）。
///   📌 判据：**「新建库跑通」≠「老库能升级」**。
///
/// 🔑 **v3 只是「新增表」** ⇒ `onUpgrade` 重跑全量幂等脚本**就够**（不需要列级迁移分支）。
///    但 `verify_bookdb_migration` 仍要**真跑一次 v2 → v3**：只验「全新库有这张表」
///    会假绿（同 v2 那条教训）。
///
/// 🔑 **v4（2026-10-08）同样只是「新增表」**（`cloud_book` = 云端书单的本地镜像）
///    ⇒ 同样**不需要**列级迁移分支。
///
/// 🔴 **但版本号必须升** —— 这正是 `user.db` 上刚踩过的坑（`highlight` 表）：
///    加表却忘了升版本 ⇒ 老库（`version == 目标版本`）**不触发 `onUpgrade`**
///    ⇒ 表**永远建不出来**，而且 `IF NOT EXISTS` 一句都不会执行 ⇒ **静默失败**
///    （界面上表现为「功能点了没反应」，不会是报错）。
///
/// ⚠️ 因此 `verify_bookdb_migration` **必须有 `fromVersion: 3` 这条路径**
///    （= 「真机此刻所处的版本」）。只测 v1/v2 → v4 会**假绿** ——
///    那些路径的版本都在变 ⇒ `onUpgrade` 一定触发 ⇒ 新表一定建出来。
///    🔑 判据：**测试要覆盖「用户此刻真实所处的状态」**，不只是历史版本。
///
/// ## 🆕 v5（2026-10-10）：`book_marker` 纳入跨设备同步 ⇒ 新增 `book_marker_pending`
///
/// | 变更 | 类型 |
/// |---|---|
/// | 🆕 `book_marker_pending`（待认领的远端书签）| 🟢 纯新增表 ⇒ 重跑全量幂等脚本即覆盖 |
///
/// 🔴 **但仍必须升版本号** —— 这正是 `user.db` 上踩过两次的坑（`highlight` / `local_meta`）：
///    加表却忘升版本 ⇒ 老库（`version == 目标版本`）**不触发 `onUpgrade`** ⇒ 表**永远建不出来**
///    （`IF NOT EXISTS` 一句都不会执行）⇒ **静默失败**。
/// ⚠️ 因此 `verify_bookdb_migration` **必须补 `fromVersion: 4`**（真机此刻所处的版本）。
const int kBookDbVersion = 5;

/// 打开（必要时创建）`book.db`。
///
/// - [factory]：Flutter 侧传 `databaseFactory`；验证脚本传 `databaseFactoryFfi`
/// - [path]：库文件路径
/// - [schemaSql]：**完整 schema 脚本**（调用方从 [kBookDbSchemaAsset] 读入）
///
/// 幂等：已存在则只打开并做连接级设置，**不重复建表**
/// （schema 里全部是 `CREATE TABLE IF NOT EXISTS`，即使重跑也安全）。
Future<Database> openBookDb({
  required DatabaseFactory factory,
  required String path,
  required String schemaSql,
}) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: kBookDbVersion,
      // 🔴🔴 **连接级设置全部在这里做，不写在 schema 脚本里**
      //    （`user_db.dart` 已记录原因：schema 逐条 `execute()`，而 `onCreate` 在事务内
      //     ⇒ per-connection 的 PRAGMA 写在那里会空转或直接失败。）
      onConfigure: (db) async {
        // ① 外键开关 —— 🔑 **本库比 `user.db` 更依赖它**：
        //    删一本书必须连带清掉它的章节与进度（`ON DELETE CASCADE`）
        //    ⇒ 没开这个开关，删书会**静默留下孤儿章节**（占空间且可能被误读为「另一本书」）。
        await db.execute('PRAGMA foreign_keys = ON');

        // ② WAL —— **必须用 `rawQuery`，不能用 `execute`**（同 `user.db` 踩过的坑：
        //    `PRAGMA journal_mode = WAL` 有返回值行，Android 的 execSQL 不接受）。
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: (db, version) => executeSqlScript(db, schemaSql),
      // 🔴 **升级 = 重跑全量幂等 schema**（与 `user.db` 同一策略）
      //
      // ## 为什么可以这样做
      // 本库的 DDL 全部是 `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
      // ⇒ 重跑 = **已有的表原样不动，缺的自动补上**。
      // 🔑 于是**不需要维护「增量 DDL」与「全量 DDL」两套** —— 后者是经典漂移源。
      //
      // ## ⚠️ 能力边界（如实标注）
      // 本实现**只覆盖「新增表 / 新增索引」**。
      // 将来若需改已有表的列（`ALTER TABLE` / 改类型 / 加 `NOT NULL` 列）：
      // · `IF NOT EXISTS` 对**已存在的表是空操作** ⇒ 替代不了列变更
      // · 必须在本分支里**按 `oldVersion` 写专门处理**
      // → 判据：**「这条变更对已存在的表要做点什么吗？」** 答「不用」→ 本实现够。
      onUpgrade: (db, oldVersion, newVersion) async {
        // ── ① v2：**先**给已存在的 `book` 表补 `content_hash` 列 ──
        //
        // 🔴🔴 **顺序不能反！**（2026-10-05 实测踩到、由本文件的断言脚本抓到）
        //
        // 我先写成「先重跑全量脚本、后加列」，结果**直接崩溃**：
        // ```
        // no such column: content_hash
        // Causing statement: CREATE INDEX IF NOT EXISTS idx_book_hash ON book(content_hash)
        // ```
        // 📌 原因：schema 脚本里**有引用新列的索引**（`idx_book_hash`）——
        //    「先跑脚本」会在**列还不存在**时去建那个索引 ⇒ `no such column`。
        // 🔑 判据：**加列必须排在「重跑全量脚本」之前** ——
        //    因为脚本里任何**引用新列的索引**都要求列先存在。
        //    （同族：skill `sqlite-schema-migration` 的「索引必须在新表改名之后建」。）
        //
        // 🔑 加列本身**必须**单独做：`CREATE TABLE IF NOT EXISTS book (...)` 对已存在的表
        //    整条跳过（不比对结构）⇒ 建表语句里那一列对老库永远加不上。
        // ⚠️ 可空（不带 DEFAULT）—— 理由见 `book_db_schema.sql` 的该列注释
        //    （「算不出哈希」必须是 NULL，不能拿哨兵值伪装成「有一个哈希」）。
        // ✅ `addColumnIfMissing` 自带「表不存在 / 列已存在 ⇒ 跳过」两道判断
        //    ⇒ 对全新库、重复升级都无害（幂等）。
        if (oldVersion < 2) {
          await addColumnIfMissing(
            db,
            table: 'book',
            column: 'content_hash',
            ddl: 'TEXT',
          );
        }

        // ── ② **再**重跑全量幂等脚本：建出缺失的表 / 索引 ──
        // （含 v2 的 `book_progress_pending` + `idx_book_hash` · v3 的 `book_marker`
        //   · v4 的 `cloud_book` + `idx_cloud_book_added`）
        await executeSqlScript(db, schemaSql);
      },
    ),
  );
}
