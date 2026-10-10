// CoEvo · 「本地数据归属账号」验收（纯判定穷举 + **真 sqlite** 行为断言）
//
// 跑：cd scripts/query_verify && dart run bin/verify_local_owner.dart
// 🔴 退出码：0 = 全过，1 = 有失败（**直读，别接 `| tail`**）。
//
// # 为什么需要它（2026-10-09）
//
// 本地学习数据（`user.db` + `book.db`）此前是**设备维度**：退出/注销都不清。
// 于是**换账号**时双向混合：
//   ① 旧账号没推完的改动会被推到**新账号**名下
//   ② 新账号的云端数据并集进本地，与旧账号数据混在一起
// ⇒ 现在用 `local_meta.owner_user_id` 记归属，换账号时清空本机数据。
//
// # 🔴 本脚本最重要的一条（【2】的反向断言）
//
// **两个 schema 里的每张用户表都必须在清空清单里。**
// 少了这条，「将来加一张表、忘了加进清单」会**静默**把那张表的数据留给**下一个账号**
// ——而这正是本次要修的那个缺口换张皮回来。
//
// # 用的是**真库**
// 走 `assets/sql/*.sql` 的真 schema（真 NOT NULL / CHECK / 外键），
// 而不是手搭简化表 —— 后者会把「表名写错、约束不满足」这类问题放过去。

import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/local_data_owner.dart';
import '../../../app/lib/services/user_db.dart';
import '_repo_paths.dart';

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

/// ⚠️ 必须 `singleInstance: false`（否则同路径的内存库是**同一个** —— 见 `verify_sync_service`）。
Future<Database> _open(String schemaPath) async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await executeSqlScript(db, File(schemaPath).readAsStringSync());
  return db;
}

/// schema 文本里的所有表名。
Set<String> _tablesIn(String schemaSql) {
  final re = RegExp(r'CREATE TABLE IF NOT EXISTS\s+([a-z_]+)', multiLine: true);
  return {for (final m in re.allMatches(schemaSql)) m.group(1)!};
}

/// 往一张表里塞**一行合法数据**（列从 `PRAGMA table_info` 推出来 ⇒ 表结构变了也不假红）。
///
/// 🔑 只填「NOT NULL 且无默认值」的列（其余交给 DDL 默认值）——
///    这样断言不会被「某列新增了默认值」这种无关变化影响。
Future<void> _seedRow(
  Database db,
  String table, {
  Map<String, Object?> overrides = const {},
}) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  final row = <String, Object?>{};
  for (final c in info) {
    final name = c['name'] as String;
    if (overrides.containsKey(name)) {
      row[name] = overrides[name];
      continue;
    }
    final notNull = (c['notnull'] as num).toInt() == 1;
    final hasDefault = c['dflt_value'] != null;
    if (!notNull || hasDefault) continue;
    final type = (c['type'] as String).toUpperCase();
    row[name] = (type.contains('INT') || type.contains('REAL'))
        ? 1
        : '${table}_$name';
  }
  if (row.isEmpty) {
    // 所有列都有默认值 / 可空 ⇒ 用 `DEFAULT VALUES`（sqflite 的空 map 插入需要
    // `nullColumnHack`，用 SQL 更直白，也不依赖那列存在）。
    await db.rawInsert('INSERT INTO $table DEFAULT VALUES');
    return;
  }
  await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<int> _count(Database db, String table) async =>
    ((await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n'] as num)
        .toInt();

/// 每张表都塞一行 —— 返回成功塞入的表数（有表塞不进去会抛出，**不吞**）。
Future<void> _seedAll(
  Database db,
  List<String> tables,
  Map<String, Map<String, Object?>> overrides,
) async {
  for (final t in tables) {
    await _seedRow(db, t, overrides: overrides[t] ?? const {});
  }
}

Future<void> main() async {
  sqfliteFfiInit();
  print('');
  print('#' * 74);
  print('# 本地数据归属账号 · 验收');
  print('#' * 74);

  // ═══════════════════════════════════════════════════════════
  section('【1】归属判定：`localOwnerVerdict` 穷举（纯函数）');

  check('本机无归属（null）⇒ **认领**（保留数据）',
      localOwnerVerdict(owner: null, incoming: 'u1') == LocalOwnerVerdict.claim);
  check('本机无归属（空串）⇒ 认领', 
      localOwnerVerdict(owner: '', incoming: 'u1') == LocalOwnerVerdict.claim);
  check('本机无归属（仅空白）⇒ 认领',
      localOwnerVerdict(owner: '   ', incoming: 'u1') == LocalOwnerVerdict.claim);
  check('同一账号 ⇒ 不动（同账号重登 / 重启走这条）',
      localOwnerVerdict(owner: 'u1', incoming: 'u1') == LocalOwnerVerdict.same);
  check('🔴 不同账号 ⇒ **换账号**（清空）',
      localOwnerVerdict(owner: 'u1', incoming: 'u2') == LocalOwnerVerdict.switched);
  check('🔴 大小写不同算不同账号（id 是 uuid，不做 collation 归一）',
      localOwnerVerdict(owner: 'u1', incoming: 'U1') == LocalOwnerVerdict.switched);
  check('🔑 逐字节相同才判 same（前后空白会被 trim 后比）',
      localOwnerVerdict(owner: ' u1 ', incoming: 'u1') == LocalOwnerVerdict.same);

  // ═══════════════════════════════════════════════════════════
  section('【2】🔴 清空清单 vs 两个 schema（正反两向都要对）');

  final userSchema = File(userDbSchemaPath()).readAsStringSync();
  final bookSchema = File(bookDbSchemaPath()).readAsStringSync();
  final userTables = _tablesIn(userSchema);
  final bookTables = _tablesIn(bookSchema);

  check('读到两个 schema（user ${userTables.length} 张 / book ${bookTables.length} 张）',
      userTables.isNotEmpty && bookTables.isNotEmpty);

  // 正向：清单里的每个名字都真的存在（表名写错 ⇒ 清空时会抛，但那要等到运行时）
  for (final t in kUserOwnedTables) {
    check('user 清单里的 `$t` 存在于 schema', userTables.contains(t));
  }
  for (final t in kBookOwnedTables) {
    check('book 清单里的 `$t` 存在于 schema', bookTables.contains(t));
  }

  // 🔴 反向（**本脚本最重要的一组**）：schema 里的用户表**全都在**清单里。
  //    漏一张 ⇒ 那张表的数据会留给**下一个账号**，且**不报错**。
  final userOwned = {...kUserOwnedTables, kLocalMetaTable};
  final missingUser = userTables.difference(userOwned);
  check('🔴 user schema 里**没有**漏网的表（`kUserOwnedTables` ∪ `local_meta` 之外为空）',
      missingUser.isEmpty, '漏了：$missingUser');
  final missingBook = bookTables.difference(kBookOwnedTables.toSet());
  check('🔴 book schema 里**没有**漏网的表', missingBook.isEmpty, '漏了：$missingBook');

  // 🔴 `local_meta` **不得**出现在清空清单里（它是判据本身，清掉就再也判不出归属）
  check('🔴 `local_meta` 不在清空清单里（清了 ⇒ 归属丢失 ⇒ 下次静默认领）',
      !kUserOwnedTables.contains(kLocalMetaTable));

  // ═══════════════════════════════════════════════════════════
  section('【3】真库：清空 user.db 的「用户数据」，**保留归属**');

  final udb = await _open(userDbSchemaPath());
  await _seedAll(udb, kUserOwnedTables, {
    'review_log': {'rating': 3},
    'highlight': {'source_type': 'article'},
  });
  await writeLocalOwner(udb, 'u-old');

  var seeded = 0;
  for (final t in kUserOwnedTables) {
    if (await _count(udb, t) > 0) seeded++;
  }
  check('🔴 前置：每张用户表都造出了数据（否则下面的「清空」是空过）',
      seeded == kUserOwnedTables.length,
      '$seeded / ${kUserOwnedTables.length} 张有数据');

  final removed = await clearUserOwnedData(udb);
  check('clearUserOwnedData 返回删除行数 > 0', removed > 0, '$removed 行');

  var left = 0;
  for (final t in kUserOwnedTables) {
    final n = await _count(udb, t);
    if (n != 0) {
      left++;
      check('🔴 `$t` 已清空', false, '仍有 $n 行');
    }
  }
  // 🔑 文案用**动态表数**（写死「10 张」会在加表后变成一句假话 —— 而断言本身是对的）。
  check('🔴 ${kUserOwnedTables.length} 张用户表全部清空', left == 0, '还有 $left 张没清干净');

  check('🔴 归属**没被**清掉（它是判据，不是数据）',
      await readLocalOwner(udb) == 'u-old', '${await readLocalOwner(udb)}');

  // ═══════════════════════════════════════════════════════════
  section('【4】真库：清空 book.db 的「用户数据」');

  final bdb = await _open(bookDbSchemaPath());
  await bdb.execute('PRAGMA foreign_keys = OFF'); // 只测 DELETE，不测外键
  await _seedAll(bdb, kBookOwnedTables, const {
    // ⚠️ `book.source_format` 有 CHECK —— 造数据必须给合法枚举值
    'book': {'source_format': 'epub'},
  });
  var bSeeded = 0;
  for (final t in kBookOwnedTables) {
    if (await _count(bdb, t) > 0) bSeeded++;
  }
  check('🔴 前置：每张书库表都造出了数据',
      bSeeded == kBookOwnedTables.length,
      '$bSeeded / ${kBookOwnedTables.length} 张有数据');

  final bRemoved = await clearBookOwnedData(bdb);
  check('clearBookOwnedData 返回删除行数 > 0', bRemoved > 0, '$bRemoved 行');
  var bLeft = 0;
  for (final t in kBookOwnedTables) {
    if (await _count(bdb, t) != 0) bLeft++;
  }
  check('🔴 ${kBookOwnedTables.length} 张书库表全部清空', bLeft == 0, '还有 $bLeft 张没清干净');

  // ═══════════════════════════════════════════════════════════
  section('【5】老库（没有 `local_meta`）⇒ 读归属返回 null ⇒ **认领**（不清数据）');

  final legacy = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  // 只建一张表，**故意不含 `local_meta`**（模拟「版本没升上来的老库」）
  await legacy.execute('CREATE TABLE t (a TEXT)');
  check('🔴 缺表时 `readLocalOwner` 返回 null（不是抛、也不是"别人的"）',
      await readLocalOwner(legacy) == null);
  check('🔴 且据此判定为**认领**（保留数据）—— 不知道 ≠ 别人的',
      localOwnerVerdict(owner: await readLocalOwner(legacy), incoming: 'u1') ==
          LocalOwnerVerdict.claim);
  await legacy.close();

  // ═══════════════════════════════════════════════════════════
  section('【6】归属写 / 读往返');

  await writeLocalOwner(udb, 'u-new');
  check('写入后可读回', await readLocalOwner(udb) == 'u-new');
  await writeLocalOwner(udb, 'u-3rd');
  check('🔑 再写是**覆盖**（不是新增一行 —— 否则读数会随查询顺序漂）',
      await readLocalOwner(udb) == 'u-3rd');
  check('表里只有一行',
      await _count(udb, kLocalMetaTable) == 1,
      '${await _count(udb, kLocalMetaTable)} 行');
  await writeLocalOwner(udb, '   ');
  check('🔴 空 userId 不写（不能把归属写成空 —— 那会让下次判成"无归属"）',
      await readLocalOwner(udb) == 'u-3rd');
  await udb.close();
  await bdb.close();

  // ═══════════════════════════════════════════════════════════
  section('【7】电子书原始文件：清空（**目录保留**）');

  final tmp = Directory.systemTemp.createTempSync('coevo_rawbooks_');
  File('${tmp.path}${Platform.pathSeparator}a.epub').writeAsStringSync('x');
  File('${tmp.path}${Platform.pathSeparator}b.txt').writeAsStringSync('yy');
  File('${tmp.path}${Platform.pathSeparator}c.epub.tmp-upload')
      .writeAsStringSync('zzz');
  Directory('${tmp.path}${Platform.pathSeparator}sub').createSync();

  final files = await clearRawBookFiles(tmp.path);
  check('删掉 3 个文件（含 `.tmp-upload` 传输中间态）', files == 3, '$files 个');
  check('🔴 目录本身**保留**（删了下次要重建，且它是 path_provider 的地盘）',
      tmp.existsSync());
  check('空目录 / 不存在的目录 ⇒ 返回 0 不抛',
      await clearRawBookFiles(tmp.path) == 0 &&
          await clearRawBookFiles('') == 0 &&
          await clearRawBookFiles('${tmp.path}/does-not-exist') == 0);
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}

  // ═══════════════════════════════════════════════════════════
  section('【8】接线：判定必须**排在同步之前**（否则旧数据会被推到新账号）');

  final appDart = File(repoPath('app/lib/app.dart')).readAsStringSync();
  final iOwner = appDart.indexOf('applyLocalOwnerPolicy(ref, userId: next)');
  final iSync = appDart.indexOf('runSyncAfterLogin(ref)');
  check('🔴 找得到两处调用（否则下面的顺序断言是空过）',
      iOwner >= 0 && iSync >= 0, 'owner @$iOwner · sync @$iSync');
  check('🔴 `applyLocalOwnerPolicy` 排在 `runSyncAfterLogin` **之前**',
      iOwner >= 0 && iSync >= 0 && iOwner < iSync,
      '反了 ⇒ `syncNow` 会先 push 本地待推行 ⇒ 旧账号的数据进新账号');

  final ownerProv =
      File(repoPath('app/lib/providers/local_data_owner_provider.dart'))
          .readAsStringSync();
  // ⚠️ 必须在**换账号那条路**（`_wipeForNewAccount`）里找顺序 ——
  //    全文 `indexOf` 会命中 `claim` 分支里那句 `writeLocalOwner`（本人第一次就踩了：
  //    「清 @2389 · 写 @1785」——写的那处在前面，是**认领**分支的）。
  final wipeStart = ownerProv.indexOf('Future<void> _wipeForNewAccount(');
  final wipeBody = wipeStart >= 0 ? ownerProv.substring(wipeStart) : '';
  check('🔴 切片有效（截到了 `_wipeForNewAccount` 函数体）',
      wipeBody.isNotEmpty && wipeBody.contains('clearRawBookFiles'),
      '切片长 ${wipeBody.length}');
  final iClear = wipeBody.indexOf('clearUserOwnedData(userDb)');
  final iWrite = wipeBody.indexOf('writeLocalOwner(userDb, userId)');
  check('🔴 找得到清空与写归属（顺序断言的前提）', iClear >= 0 && iWrite >= 0);
  check('🔴 先清数据、**后**写归属（反了 ⇒ 中途失败会留下「归属已换、数据还在」）',
      iClear >= 0 && iWrite >= 0 && iClear < iWrite,
      '清 @$iClear · 写 @$iWrite');
  // ⚠️ 窗口要够宽：debugPrint 与 `return;` 之间隔着一整段「为什么」的注释。
  check('🔴 清空失败时**不写归属**（`return` 在 catch 里）',
      RegExp(r'清空 user\.db 失败[\s\S]{0,600}?return;').hasMatch(wipeBody),
      '否则「归属已换、数据还在」⇒ 新账号看到旧数据（静默）');
  // 🔴 2026-10-10（v11）：**游标已从 prefs 搬进 `user.db`**（`sync_cursor` 单行表）。
  //    判据随之**改口径**（但意图不变：换账号后游标必须失效）：
  //      · 旧：断言 owner provider 里**调用**了 `clearSyncCursorFor`（**一道流程**）
  //      · 新：断言 `sync_cursor` ∈ `kUserOwnedTables`（**结构保证**）
  //    🔑 新写法更强 —— 它不依赖「某处记得调」：`clearUserOwnedData` 会按清单清，
  //       将来**新增任何一条清数据路径**都自动覆盖。
  //    ⚠️ 旧写法正是那条判据的反例：「用流程清理」一定有人忘。
  check('🔴 游标表 `sync_cursor` ∈ `kUserOwnedTables`'
      '（⇒ 换账号/清数据时**随数据一起被清**，不靠「记得调」）',
      kUserOwnedTables.contains('sync_cursor'),
      '不在清单里 ⇒ 库被清而游标留存 ⇒ pull 只取增量 ⇒ 历史永远拉不回且不报错');
  check('🔴 换账号时仍清掉**旧版** prefs 游标键（v11 前遗留，留着会误导 grep）',
      ownerProv.contains('clearLegacySyncCursorPrefs(ref, userId)'));
  check('🔴 清空后 bump 两个 revision（否则界面还显示已删的数据）',
      ownerProv.contains('userDbRevisionProvider.notifier).bump()') &&
          ownerProv.contains('bookDbRevisionProvider.notifier).bump()'));

  final authProv =
      File(repoPath('app/lib/providers/auth_provider.dart')).readAsStringSync();
  check('🔴 登出**不清**归属（清了 ⇒ 换账号判定失去依据 ⇒ 静默认领）',
      !RegExp(r'onLogout[\s\S]{0,900}?(writeLocalOwner|DELETE FROM local_meta)')
          .hasMatch(authProv));

  final profile =
      File(repoPath('app/lib/screens/profile_screen.dart')).readAsStringSync();
  check('🔴 登出确认文案写明「换账号会清空本机学习数据」（决策点告知）',
      profile.contains('若改用其它账号登录，本机学习数据会被清空'));
  // 🔴 注销弹窗**也要**写 —— 否则用户会读到「本机数据不受影响」（这句在
  //    「归属账号」之前是完整的），注销后注册新号才发现数据没了。
  check('🔴 注销弹窗同样写明（否则「不会被删除」这句读起来像"永远安全"）',
      profile.contains('但若改用其它账号登录，本机学习数据会被清空'));

  final syncProv =
      File(repoPath('app/lib/providers/sync_provider.dart')).readAsStringSync();
  // 🔴 2026-10-10（v11）：旧断言是「游标键带 userId（换账号天然隔离）」——
  //    口径已变：游标进 `user.db` 后**连「带 userId」都不需要了**（库本身就按账号清）。
  //    ⇒ 新判据 = **旧 prefs 键只许删、不许读写**（否则「库里的游标」与「prefs 的游标」
  //      会成为两个真值源，迟早分叉，且**不报错**）。
  check('🔴 旧 prefs 游标键**只被删、不被读写**（否则两个真值源 ⇒ 迟早分叉）',
      !syncProv.contains(r"prefs.getString('$kLegacySyncCursorPrefsKeyPrefix") &&
          !syncProv.contains(r"prefs.setString('$kLegacySyncCursorPrefsKeyPrefix"),
      '游标的读写必须**只**走 `sync_cursor` 表');

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
    print('🔑 最可能的原因（这一层几乎都是**静默**错误）：');
    print('   · 归属判定把「不知道属于谁」也当成「属于别人」 ⇒ 无端清空数据');
    print('   · 清空清单漏了一张表 ⇒ 那张表的数据留给下一个账号');
    print('   · 清空与写归属的顺序反了 ⇒ 「归属已换、数据还在」');
    print('   · 判定排在同步之后 ⇒ 旧账号的待推数据被推到新账号');
    print('   · 清空后没删游标 ⇒ 新账号只拉到增量（数据少了很多且不报错）');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
