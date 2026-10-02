// CoEvo · 端侧用户库 `user.db` 的连接层
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**。
//   理由同 `services/fsrs_service.dart` / `services/trace_markdown_source.dart`：
//   本地 Flutter 是鸿蒙定制版、`flutter analyze` 会因 Windows 管道耗尽崩溃 ——
//   纯 Dart 才能本地独立验证（见 `scripts/query_verify/bin/verify_bookmark.dart`）。
//
// # 本层解决什么
//
// 2026-09-27 核实：`sqflite` 早已在依赖里、`assets/sql/user_db_schema.sql` 早已声明进包，
// 但**没有任何代码去打开 user.db 或建表** ——
// `WordQueryService` / `ReviewListQuery` 只接受**注入的 `Database`**，
// 而「谁来创建这个 Database」一直是空的。本文件补上这一环。
//
// # 两处刻意的设计
//
// ## ① DDL 由调用方注入，本层不读 assets
// Flutter 侧读 assets 要用 `rootBundle`（**那是 Flutter API**）→ 一旦在本层调用，
// 本层就无法在纯 Dart 下验证。
// 所以：**调用方把 DDL 字符串读进来传进去**。Flutter 侧一行 `rootBundle.loadString`，
// 验证脚本则直接 `File(...).readAsStringSync()` —— 同一份 DDL，两条路都能跑。
// 🔑 这也同时保证了「文档一套、代码一套」不会发生：**只有一份 .sql 文件**。
//
// ## ② 建表脚本要**自己拆语句**
// `sqflite` 的 `execute()` **一次只能执行一条语句**，而 schema 文件是
// 「注释 + 多条 CREATE + 多条 CREATE INDEX + PRAGMA」的整段脚本。
// → 需要一个拆分器。它是**纯逻辑**，所以放进本文件（可断言）而不是渲染层。

import 'package:sqflite_common/sqlite_api.dart';

/// `user.db` 的 schema 版本。
///
/// ## 版本历史
/// | 版本 | 内容 |
/// |---|---|
/// | **1** | 初版：`card_review_state` · `review_log` · `bookmark` |
/// | **2** | Step 3.4c：+ `user_word`（生词本）· `lookup_event`（查词记录） |
/// | **3** | Step 3.8：+ `achievement_unlock`（成就解锁记录 —— 成就改为端侧计算） |
/// | **4** | 「我的」页统计：+ `article_read`（读过的文章 —— 「阅读篇数」的数据源） |
/// | **5** | A2：+ `external_word_cache`（词库外生词的词卡缓存 —— 让词库外的词能进生词本/复习） |
///
/// ## 🔴🔴 为什么必须递增（2026-09-28 发现）
/// 此前本文件写着「**本库从未在任何端创建**」→ 所以 version 停在 1、`onUpgrade` 直接抛错。
///
/// **但这个前提已经不成立**：白哥已真机验证过收藏功能，而收藏写 `bookmark` 表
/// → **`user.db` 必然已在设备上存在，且 `user_version = 1`**。
///
/// 于是「只把两张表加进 schema」**不会生效**：
/// · `onCreate` **只在新建库时跑**（不是新库 → 跳过）
/// · `onUpgrade` 不触发（version 没变）
/// → 新表根本没被创建 → 运行时 `no such table: user_word`
///
/// 🔑 **而且验收脚本验不出来**：脚本用**临时新库** → `onCreate` 会跑 → 全过。
///    这是「**在错条件下验证**」的又一种形态 —— 差异不是平台，而是**初始状态**。
///    → 守护见 `scripts/query_verify/bin/verify_userdb_migration.dart`（专测「老库升级」）。
///
/// 🆕 v3（2026-09-29）同理：真机上现存的库是 **v2**（或更早的 v1）
/// → 必须靠 `onUpgrade` 建出 `achievement_unlock`。
///
/// 🆕 v4（2026-09-29 同日）：+ `article_read`。**同理**——
/// 真机上的库此刻是 **v3**（若白哥跑过带成就的版本）或更早 →
/// 必须靠 `onUpgrade` 建出 `article_read`，否则「阅读篇数」永远读不到表。
///
/// 🆕 v5（2026-10-01）：+ `external_word_cache`。**同理** ——
/// 真机上的库此刻是 **v4** 或更早 → 必须靠 `onUpgrade` 建出。
/// ⚠️ 但它比前几次**更严重**：这张表缺失时，**词库外的词查完就丢**
///   （缓存写不进去 → 复习页取卡回落失败 → 那个词从生词本里「看得见、点不开」）。
///   ✅ 幸好本库的 `onUpgrade` 是「重跑全量幂等脚本」，纯新增表**自动覆盖**。
const int kUserDbVersion = 5;

/// `user.db` 的文件名（调用方拼路径用）。
const String kUserDbFileName = 'user.db';

/// schema 脚本的 asset 路径。
///
/// 🔑 放在这里而不是各调用点 —— 「DDL 在哪个 asset」是连接层的事，
/// 而且它必须与 `pubspec.yaml` 的 `assets:` 声明**一致**（漏声明不会编译报错、只在运行时炸，
/// 2026-09-26 已踩过一次）。
const String kUserDbSchemaAsset = 'assets/sql/user_db_schema.sql';

/// 打开（必要时创建）`user.db`。
///
/// - [factory]：Flutter 侧传 `databaseFactory`；验证脚本传 `databaseFactoryFfi`
/// - [path]：库文件路径
/// - [schemaSql]：**完整 schema 脚本**（调用方从 `assets/sql/user_db_schema.sql` 读入）
///
/// 幂等：已存在则只打开并跑 `onOpen` 的外键开关，**不重复建表**
/// （schema 里全部是 `CREATE TABLE IF NOT EXISTS`，即使重跑也安全）。
Future<Database> openUserDb({
  required DatabaseFactory factory,
  required String path,
  required String schemaSql,
}) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: kUserDbVersion,
      // 🔴🔴 **连接级设置全部在这里做，不写在 schema 脚本里**（2026-09-27 修正）
      //
      // schema 由 `executeSqlScript` 逐条 `db.execute()` 执行，而 `onCreate` **在事务内**
      // → 写在那里要么空转、要么直接失败（详见 `user_db_schema.sql` 顶部说明）。
      // 🔑 原则：**DDL 描述「库长什么样」，连接设置描述「这次连接怎么工作」** ——
      //    前者持久化一次，后者**每次连接都要重做**。
      onConfigure: (db) async {
        // ① 外键开关。
        //    ✅ `PRAGMA foreign_keys = ON` 是**设置语法、不返回结果行** → `execute` 安全。
        await db.execute('PRAGMA foreign_keys = ON');

        // ② 🔴 WAL 日志模式 —— **必须用 `rawQuery`，不能用 `execute`**。
        //
        //    原因（源码级）：`db.execute()` 在 Android 上落到
        //      `sqflite_android` → `SQLiteDatabase.execSQL()`
        //                      → `SQLiteStatement.executeUpdateDelete()`
        //    而那个方法**只接受不返回数据的语句**（INSERT / UPDATE / DELETE）。
        //    偏偏 `PRAGMA journal_mode = WAL` 按 SQLite 语义**返回新的日志模式**
        //    （有结果行）→ 违反前提。Android 官方 javadoc 明文：per-connection 的
        //    PRAGMA 不该用 `execSQL`，应用 `execPerConnectionSQL`。
        //
        //    ⚠️ 这个错误**在 `sqflite_common_ffi` 下暴露不出来** —— FFI 直调 sqlite3
        //    C API，没有 Android `execSQL` 那层限制 → 验收脚本 49 项全过。
        //    只有真机才会暴露（表现为 `openUserDb` 抛异常 → 收藏按钮永久禁用）。
        //    守护断言见 `scripts/query_verify/bin/verify_bookmark.dart`【2】。
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: (db, version) => executeSqlScript(db, schemaSql),
      // 🔴🔴 **升级 = 重跑全量幂等 schema**（2026-09-28 改 · 白哥定「方案 A」）
      //
      // ## 为什么可以这样做
      // 本库的 DDL **全部**是 `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
      // → 重跑一遍 = **已有的表原样不动，缺的自动补上**。
      // 🔑 于是**不需要维护「增量 DDL」与「全量 DDL」两套** ——
      //    后者是经典漂移源（改了一处忘了另一处，升级出来的库与新建的库不一样）。
      //
      // ## 之前为什么是「无条件抛错」
      // 那时注释断言「本库从未在任何端创建」→ 升级路径不可达 → 抛错是为了
      // 「schema 改了但没写迁移」能当场暴露，而不是表现成「运行时某个列不存在」。
      // 🔑 **那个断言现已不成立**（见 `kUserDbVersion` 的文档）→ 必须换成真的迁移。
      //
      // ## ⚠️ 能力边界（**如实标注**）
      // 本实现**只覆盖「新增表 / 新增索引」**。
      // 将来若需**改已有表的列**（`ALTER TABLE` / 改类型 / 加 `NOT NULL` 列）：
      // · `IF NOT EXISTS` 对**已存在的表是空操作** → 替代不了列变更
      // · 必须在本分支里**按 `oldVersion` 写专门处理**，且
      //   `NOT NULL` 加列**必须给默认值或回填**（SQLite 的已知限制）
      // → 判据：**「这条变更对已存在的表要做点什么吗？」**
      //   答「不用」（纯新增）→ 本实现就够；答「要」→ 必须写专门分支。
      onUpgrade: (db, oldVersion, newVersion) async {
        // ⚠️ 别把 `oldVersion` 丢掉 —— 它是将来写列变更分支的依据
        //    （本文件用 `_` 前缀显式声明「暂未使用」，而不是删掉参数）
        final _ = oldVersion;
        await executeSqlScript(db, schemaSql);
      },
    ),
  );
}

/// 执行一段**多语句** SQL 脚本。
///
/// # 为什么需要它
/// `sqflite` 的 `execute()` 只接受**单条**语句；而 schema 是整段脚本。
///
/// # 拆分规则
/// | 输入 | 处理 |
/// |---|---|
/// | `-- 行注释` | **整行丢弃** |
/// | `/* 块注释 */` | 丢弃（含跨行） |
/// | 空语句（连续 `;`） | 丢弃（不调 execute，避免 SQLite 报 syntax error） |
/// | 其余 | 按 `;` 切开，逐条执行 |
///
/// ⚠️ **已知能力边界（如实说明）**：
/// 本拆分器**不理解字符串字面量** —— 若某条 SQL 里含 `;`（如 `DEFAULT 'a;b'`）
/// 或含 `--`（如 `DEFAULT '--x'`），会被错误切开。
/// - 本项目的 DDL **不需要**这些写法（已逐条检查 `user_db_schema.sql`）
/// - 真需要时再补一个「带引号状态的扫描器」；现在写它属于**没有依据的复杂度**
///   （同 `widgets/trace_markdown.dart` 那条「不做没依据的优化」：问题尚未被观察到）
/// - 断言里**显式锁住**这个边界（见 `scripts/query_verify/bin/verify_bookmark.dart` 与
///   `verify_userdb_migration.dart`），
///   这样将来有人引入这种写法时会当场失败，而不是静默拆错
Future<void> executeSqlScript(Database db, String sql) async {
  for (final stmt in splitSqlStatements(sql)) {
    await db.execute(stmt);
  }
}

/// 把多语句 SQL 脚本拆成**可逐条 `execute`** 的语句列表（已去注释、去空语句）。
///
/// 公开是为了**能被独立断言** —— 拆分是纯逻辑，不该只有「跑通了」这一种证据。
List<String> splitSqlStatements(String sql) {
  final out = <String>[];
  final buf = StringBuffer();

  var i = 0;
  final n = sql.length;
  // 状态：是否正在块注释里（`/* ... */`）
  var inBlockComment = false;
  // 状态：是否正在行注释里（`-- ...` 到行尾）
  var inLineComment = false;

  void flush() {
    final s = buf.toString().trim();
    if (s.isNotEmpty) out.add(s);
    buf.clear();
  }

  while (i < n) {
    final c = sql[i];
    final next = i + 1 < n ? sql[i + 1] : '';

    if (inLineComment) {
      // 行注释在换行处结束；换行本身**不写回缓冲**（语句之间的空白无意义）
      if (c == '\n') inLineComment = false;
      i++;
      continue;
    }

    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        i += 2;
        continue;
      }
      i++;
      continue;
    }

    // 块注释优先于行注释判断（`/*` 与 `--` 不重叠，但顺序明确更稳）
    if (c == '/' && next == '*') {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (c == '-' && next == '-') {
      inLineComment = true;
      i += 2;
      continue;
    }

    if (c == ';') {
      flush();
      i++;
      continue;
    }

    buf.write(c);
    i++;
  }

  // 脚本末尾允许没有分号
  flush();
  return out;
}
