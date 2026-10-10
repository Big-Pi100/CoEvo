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
///
/// ## 🆕 v6（2026-10-05 · 跨设备同步）：**本库第一次「改已有表的列」**
///
/// | 版本 | 内容 | 类型 |
/// |---|---|---|
/// | … | `user_word` · `lookup_event` · `article_read` · `achievement_unlock` | 🟢 纯**新增表** ⇒ 重跑全量脚本即覆盖 |
/// | **6** | `bookmark.deleted`（收藏改**软删**） | 🔴 **给已存在的表加列** ⇒ **重跑全量脚本覆盖不了！** |
///
/// 🔴 **为什么重跑全量脚本对「加列」无效**：
/// `CREATE TABLE IF NOT EXISTS bookmark (...)` 见到表已存在就**整条跳过**（不比对结构）
/// ⇒ 在 schema 文件里加的那一列，对**老库永远加不上**。
/// ⚠️ 这与「纯新增表」是**两种性质**的变更 —— 之前的版本能靠重跑覆盖，
///    **本版不能**，必须显式 `ALTER`。
///
/// ⇒ 所以 `onUpgrade` 里新增了 `oldVersion < 6` 分支（见下）。
/// 📌 判据（本 skill 反复出现）：**「重跑全量 DDL」≠「迁移」** ——
///    它只覆盖「新增」，**不覆盖「变更」**。
///
/// ⚠️ **列顺序**：`ALTER` 只能把新列追加到**末尾** ⇒ schema 文件里
///    `deleted` 也写在末尾，让「新库」与「升级库」列顺序一致
///    （否则按位置取值的代码会在两种库上读到不同列 —— **静默值错位**）。
///
/// ## 🆕 v7（2026-10-08）：**修一次「漏升版本号」的事故** + 翻译缓存
///
/// 🔴🔴 **v1.7（`highlight`）当时漏升版本号** —— `kUserDbVersion` 停在 **6**，
///    而 schema 文件里**已经加了 `highlight` 表**。
///
/// | 库的来源 | 走哪条路 | 结果 |
/// |---|---|---|
/// | **新装**（无库）| `onCreate` | ✅ 有 `highlight`（全量脚本）|
/// | **老库且 < v6** | `onUpgrade` | ✅ 有（重跑全量脚本）|
/// | **老库 == v6**（🔴 **真机现状**）| **什么都不走** | ❌ **没有 `highlight`** |
///
/// ⇒ 后果：真机上打开新版 app 后，**划线功能静默失败**
///    （写库时报 `no such table: highlight`）。
///
/// 🔑 **为什么既有断言没抓到**（这是本条最值得记的地方）：
///    `scripts/query_verify/bin/verify_userdb_migration.dart` 的起点是 **v1–v5**，
///    那些路径**版本都在变** ⇒ `onUpgrade` 一定触发 ⇒ 每次都能建出 `highlight` ⇒ **全绿**。
///    **「真机现状（v6 → v6）」那条路径从未被测过。**
///    📌 「在错条件下验证」的又一种形态 —— 差异不是平台，是**初始版本恰好等于目标版本**。
///    ⇒ 本次一并补上 `fromVersion: 6` 的断言路径。
///
/// ✅ **修复 = 升版本号**（顺带把 v1.8 的 `translation_cache` 一起带上，一次升级全拿到）。
///    ⚠️ 不需要新写 `onUpgrade` 分支 —— 两张都是**纯新增表**，重跑全量脚本即可覆盖。
///
/// ---
///
/// # 🔴 v1.9（2026-10-08）：`highlight.paused`（**加列**，与上面那条不同！）
///
/// 复习页的「暂停」对划线卡**完全无效**（白哥真机报）：写端
/// `UserWordRepository.pause` 更新的是 **`user_word`**，而划线卡的
/// `word_id = 'hl:<uuid>'` 在那张表里**没有行** ⇒ affected = 0 ⇒
/// `review_screen._pause` 里 `if (!changed) return;` ⇒ **静默、连提示都没有**。
/// ⇒ 划线自己需要一列「暂停」（语义与 `deleted` 分开，见 schema 注释）。
///
/// 🔴 **加列 ≠ 加表** —— 这一条是 v1.7/v1.8 那些教训的**反面**：
///    `CREATE TABLE IF NOT EXISTS highlight (...)` 对**已存在的表整条跳过**，
///    schema 里新加的列对老库**永远加不上** ⇒ **必须**在 `onUpgrade` 里写
///    `ALTER TABLE ... ADD COLUMN` 分支（已加，见下方 ①b）。
///    📌 判据：**「加表」靠重跑脚本，「加列」必须写 ALTER** ——
///       而两者都要问同一句：**老库怎么拿到它？**
///
/// 📌 另一条：**加表/加列之后必须问「老库怎么拿到它」**。
///    `onCreate` 只对**新库**生效；老库**只有 `onUpgrade`**，
///    而它**只在版本号变化时触发** —— 不升版本号 = 那条路根本不存在。
///
/// 🆕 v9（2026-10-09）：`local_meta`（本地数据**归属账号**）。
///    ⚠️ 与 v1.7 那次同一个坑的**第二次**：不动版本号 ⇒
///       真机上「恰好是 v8」的库不触发 `onUpgrade` ⇒ `local_meta` 建不出来
///       ⇒ 归属读不到 ⇒ **换账号判定失效**（而它失效是静默的：
///         只会表现成「数据没被清」）。守护断言见 `verify_userdb_migration.dart`。
///
/// ## 🆕 v10（2026-10-10）：同步覆盖面补齐（审计报告 §五）
///
/// | 变更 | 类型 |
/// |---|---|
/// | `lookup_event` + `uid`（跨设备身份）+ `pending_push` | 🔴 **加列** ⇒ 必须写 ALTER |
/// | `achievement_unlock` + `pending_push` | 🔴 **加列** ⇒ 必须写 ALTER |
/// | 🆕 `setting_sync`（应用设置的同步载体）| 🟢 纯新增表 ⇒ 重跑脚本即可 |
///
/// 🔴 **加列必须写 `onUpgrade` 分支**（`CREATE TABLE IF NOT EXISTS` 对已存在的表整条跳过）
///    —— 这是 v6/v8 已经写过两次的同一条教训。
/// ⚠️ **同时必须升版本号**：真机上此刻的库可能是 **v9** ⇒ 版本不变则不触发 `onUpgrade`
///    ⇒ 两列加不上、新表建不出（**静默**：界面上表现为「查词次数不涨 / 成就日期还是今天」）。
///    ✅ 守护断言：`verify_userdb_migration.dart` 的 `fromVersion: 9` 路径。
const int kUserDbVersion = 10;

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
        // ── ① v6：**先**给**已存在的** `bookmark` 表补 `deleted` 列 ──
        //
        // 🔴🔴 **顺序不能反**（2026-10-05 由 `book_db.dart` 的同族实现实测撞出来）：
        //    那边先写成了「先重跑全量脚本、后加列」，**直接崩溃**：
        // ```
        // no such column: content_hash
        // Causing statement: CREATE INDEX IF NOT EXISTS idx_book_hash ON book(content_hash)
        // ```
        // 📌 原因：schema 脚本里**可能含引用新列的索引** ⇒ 列还不存在时建那个索引会报
        //    `no such column`。本库当前**没有**引用 `deleted` 的索引，所以这条现在不咬人，
        //    但**一旦将来给 `deleted` 加索引**（如部分索引 `WHERE deleted = 0`）就会踩同一个坑。
        // 🔑 判据：**加列必须排在「重跑全量脚本」之前** —— 让脚本里任何引用新列的
        //    索引/视图在跑的那一刻列已经存在。
        //
        // ⚠️ 「老库可能是 v1/v2、那时 `bookmark` 表还不存在」（原注释的担忧）**依然成立**，
        //    但由 `addColumnIfMissing` 自己处理：它先查 `sqlite_master`，
        //    表不存在就**直接跳过**（随后由全量脚本建出**已含新列**的表）。
        //
        // 🔴 必须单独做：`CREATE TABLE IF NOT EXISTS bookmark (...)` 对已存在的表
        //    **整条跳过**（不比对结构）⇒ schema 文件里那一列对老库**永远加不上**。
        // 🔑 `addColumnIfMissing` 自带两道幂等/安全判断（表不存在 → 跳过；
        //    列已存在 → 跳过），所以本分支重复执行、或对全新库执行都无害。
        // 🔴 **ddl 必须与 `user_db_schema.sql` 里那一列的完整定义逐字一致**（含 CHECK）——
        //    否则「新建的库」有 CHECK、「升级出来的库」没有 ⇒ **两种库的约束漂移**。
        //    ⚠️ 后果是静默的：老库能写进 `deleted = 2` 这种非法值，而新库会拒绝
        //       ⇒ 同步逻辑（把 `deleted` 当布尔用）在两类设备上行为不同。
        // 📌 判据：**ALTER 的列定义与建表语句的列定义是「同一件事的两处描述」** ——
        //    两处必须一致（同族：同一件事的口径只能一处权威）。
        // 🔑 SQLite **允许** `ADD COLUMN` 带 `CHECK`（只禁止 PK / UNIQUE / 无默认值的 NOT NULL）。
        if (oldVersion < 6) {
          await addColumnIfMissing(
            db,
            table: 'bookmark',
            column: 'deleted',
            ddl: 'INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))',
          );
        }

        // ── ①b v8：给 `highlight` 补 `paused` 列（复习页「暂停」对划线卡的落点）──
        //
        // 🔴 与上一条同理：`CREATE TABLE IF NOT EXISTS highlight (...)` 对**已存在的表**
        //    **整条跳过** ⇒ schema 文件里那一列对老库**永远加不上** ⇒ 必须在这里 ALTER。
        //
        // 🔑 「老库 < v7、`highlight` 表还没建」由 `addColumnIfMissing` 自己处理：
        //    它先查 `sqlite_master`，表不存在就**跳过** —— 随后重跑的全量脚本建出的表
        //    **已含 `paused`** ✅
        //
        // 🔴 ddl 必须与 `user_db_schema.sql` 里那一列**逐字一致**（同 `bookmark.deleted`
        //    的理由）——否则「升级出来的库」与「新建的库」约束漂移，
        //    而后果是静默的（一类库拒非法值、另一类库放过）。
        if (oldVersion < 8) {
          await addColumnIfMissing(
            db,
            table: 'highlight',
            column: 'paused',
            ddl: 'INTEGER NOT NULL DEFAULT 0 CHECK (paused IN (0, 1))',
          );
        }

        // ── ①c v10：`lookup_event` 补 `uid` + `pending_push`；`achievement_unlock` 补 `pending_push` ──
        //
        // 🔴 与 v6/v8 同一个坑：`CREATE TABLE IF NOT EXISTS` 对**已存在的表整条跳过**
        //    ⇒ schema 里新加的列对老库**永远加不上** ⇒ 必须在这里 ALTER。
        // ⚠️ ddl 必须与 `user_db_schema.sql` 里那两列**逐字一致**（含 CHECK），
        //    否则「升级出来的库」与「新建的库」约束漂移（静默）。
        //
        // 🔴 `uid` **可空**（老行回填前为 NULL）—— 不能给 `NOT NULL`：
        //    ① 老数据没有 uuid，而 SQLite 的 DDL **无法生成** uuid；
        //    ② 回填由 `UserWordRepository.backfillLookupUids()` **惰性**完成
        //       （只在「真要 push」时才生成，避免为永不上云的设备白造 uuid）。
        //    ⚠️ 不加 DEFAULT —— `NULL` 正是「还没回填」的可辨识状态。
        //    🔴 后果提醒：**uid 为 NULL 的行绝不能直接 push** ——
        //       服务端 PK 是 `(user_id, uid)`，空串会让所有未回填行**互相覆盖**。
        //       所以 `sync_service.pushOnce` 必须先 `backfillLookupUids()`。
        //
        // 🔴 `pending_push` 对**老行**默认 1 ⇒ 升级后第一次同步会把历史查词记录
        //    全部推上去（**有意**：否则「查词次数」成就在新设备上缺了历史）。
        //    ⚠️ 因此提交端**必须分批**（可能有数千条，见 `sync_service` 的批量循环）。
        if (oldVersion < 10) {
          await addColumnIfMissing(
            db,
            table: 'lookup_event',
            column: 'uid',
            ddl: 'TEXT',
          );
          await addColumnIfMissing(
            db,
            table: 'lookup_event',
            column: 'pending_push',
            ddl: 'INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1))',
          );
          await addColumnIfMissing(
            db,
            table: 'achievement_unlock',
            column: 'pending_push',
            ddl: 'INTEGER NOT NULL DEFAULT 1 CHECK (pending_push IN (0, 1))',
          );
        }

        // ── ② **再**重跑全量幂等脚本：建出缺失的表 / 索引 ──
        // 🔑 位置在「补列」**之后**（理由见上）。
        //    它是纯新增的兜底：`CREATE TABLE/INDEX IF NOT EXISTS` ⇒ 已有的原样不动。
        // ⚠️ 别把它挪到前面 —— 那会让「脚本里引用新列的索引」先于列存在（见上）。
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
/// 给**已存在的表**补一列（幂等 + 安全）。
///
/// # 两道判断，各自防一种错
///
/// | 判断 | 防什么 |
/// |---|---|
/// | **表不存在 → 跳过** | 老库跨多个版本升级时，该表**可能还没建**（如 v1 库没有 `bookmark`）<br>此时直接 `ALTER` 会报 `no such table`。跳过是对的 —— 全量脚本随后建出的新表**已含该列** |
/// | **列已存在 → 跳过** | 幂等：重复升级、或该库已经补过这一列 |
///
/// 🔴 **为什么用 `PRAGMA table_info` 而不是「吞 `duplicate column` 错误」**：
/// 吞错版本会**连「列名拼错」一起放过** —— 拼错时 SQLite 报的是**别的**错，
/// 被 `catch` 一并吞掉 ⇒ 你以为加成功了，其实列根本没加（**静默失效**）。
/// 查 `table_info` 则列名拼错会直接暴露（该列永远查不到 ⇒ 断言会红）。
///
/// ⚠️ **新列只能追加到末尾**（SQLite 限制）⇒ 调用方在 schema 文件里也应把新列
///    写在末尾，让「新建的库」与「升级出来的库」**列顺序一致**。
///    否则 `SELECT *` + 按**下标**取值的代码会在两种库上读到不同的列（**静默值错位**）。
Future<void> addColumnIfMissing(
  Database db, {
  required String table,
  required String column,
  required String ddl,
}) async {
  // ① 表不存在 ⇒ 跳过（全量脚本会建出含该列的新表）
  final t = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    [table],
  );
  if (t.isEmpty) return;

  // ② 列已存在 ⇒ 跳过（幂等）
  // ⚠️ `table` 只由本仓库的常量传入（非用户输入）⇒ 这里的字符串插值无注入面。
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  if (cols.any((r) => r['name'] == column)) return;

  await db.execute('ALTER TABLE $table ADD COLUMN $column $ddl');
}

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
