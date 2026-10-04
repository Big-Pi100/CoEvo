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

import 'user_db.dart' show executeSqlScript;

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
/// | 版本 | 内容 |
/// |---|---|
/// | **1** | 初版：`book` · `book_chapter` · `book_progress` |
///
/// ⚠️ 本库是**新增的库**（真机上尚不存在）⇒ `onCreate` 一定会走，
///    首版**不需要**写迁移分支。
const int kBookDbVersion = 1;

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
        // ⚠️ 别把 `oldVersion` 丢掉 —— 它是将来写列变更分支的依据
        final _ = oldVersion;
        await executeSqlScript(db, schemaSql);
      },
    ),
  );
}
