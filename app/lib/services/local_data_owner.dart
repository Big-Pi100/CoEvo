// CoEvo · 本地学习数据的**归属账号**（纯 Dart · 只依赖 sqflite API 与 `dart:io`）
//
// # 🔴 为什么需要它（一个真实缺口）
//
// 本地学习数据（`user.db` + `book.db`）一直是**设备维度**：
// 退出登录不清、注销也不清（注销弹窗明说「本机学习数据不受影响」）。
// 这在「一台设备 = 一个人」时没问题，但**换账号**时没人管，于是双向混合：
//
// | 方向 | 现象 |
// |---|---|
// | 本地 → 云端 | 旧账号**没推完**的改动（`pending_push = 1`）在换账号后被推到**新账号**名下 |
// | 云端 → 本地 | 新账号的云端数据**并集**进本地，与旧账号的数据混在一起（用户看到「多了很多不是我的词」） |
//
// ⇒ 现在把「**这份数据属于哪个账号**」显式记下来（`local_meta.owner_user_id`），
//    换账号时按它处置。
//
// # 三种处置（无一例外，都在 [localOwnerVerdict] 里，是**纯函数**）
//
// | 情形 | 判定 | 处置 | 为什么 |
// |---|---|---|---|
// | 本机**还没有**归属 | [LocalOwnerVerdict.claim] | **认领**：记下当前账号，**保留**数据 | 覆盖「先划词后登录」与「老库升级上来」——那时数据本来就该归这台设备的用户 |
// | 归属 == 当前账号 | [LocalOwnerVerdict.same] | 什么都不做 | 同账号重登 / 重启走这条 ⇒ 数据留着（这是最常见的情形）|
// | 归属 != 当前账号 | [LocalOwnerVerdict.switched] | **清空本机学习数据** | 见下 |
//
// # 🔴 为什么「清空」而不是「隔离」（逐条）
//
// | 方案 | 为什么没选 |
// |---|---|
// | 每个账号一个库文件 | **改动面最大**（所有 provider 都要跟着 `userId` 变），而且**未登录时的数据归属于谁**会立刻变成一个没有好答案的问题（今天「不登录也能用、登录后数据跟着走」是**要保留**的行为）|
// | 给每行加 `account_id` 列 | 所有查询都要多一个过滤条件 ⇒ **漏一处就是跨账号泄漏**，且它是静默的 |
// | **清空** ✅ | 与 `owner` 一起落在同一个事务里，判据只有一处；配合「登录后从云端拉回」→ 新账号看到的就是自己的数据 |
//
// ⚠️ **清空的代价（如实标注）**：旧账号**没同步到云端**的数据会**永久丢失**。
//    缓解措施（见调用方）：
//      · 登出时已经 `flushBeforeLogout()` 把待推数据送走（正常有网时不会有残留）
//      · **登出确认文案**写清「用其它账号登录会清空本机学习数据」（在用户的决策点告知）
//    📌 这是**有意接受**的取舍，不是疏漏 —— 详见报告。
//
// # 为什么 `owner` 读不出来时**不清**（\`null\` ⇒ claim）
//
// 读不到（表不存在 / 库打不开 / 值损坏）只能说明「**我们不知道**它属于谁」，
// 而**不知道 ≠ 别人的**。判据：**「拿不准时保留」** ——
// 反过来（拿不准就清）会用一次读失败换掉用户全部学习数据，属最坏的交换。
//
// ⚠️ 本文件不得 import 任何 Flutter 包（同 `sync_merge.dart` 的理由：
//    纯 Dart 才能被 `scripts/*_verify` 直接 import 做真库断言）。

import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';

/// 本机库的**元信息**表（单行键值）—— 与 `user_db_schema.sql` 的 DDL 同名。
const String kLocalMetaTable = 'local_meta';

/// 归属键：本机学习数据属于哪个账号（`users.id`）。
const String kOwnerUserIdKey = 'owner_user_id';

/// 归属判定的三种结果。
enum LocalOwnerVerdict {
  /// 本机还没记过归属 ⇒ **认领**（记录当前账号，**保留**数据）。
  claim,

  /// 就是同一个账号 ⇒ 什么都不做。
  same,

  /// **换账号** ⇒ 清空本机学习数据。
  switched,
}

/// 判定归属 —— **纯函数**（不碰 DB / 文件）⇒ 可以对所有组合穷举。
///
/// 🔴 `owner` 为 `null` / 空串 ⇒ [LocalOwnerVerdict.claim]，**不是** `switched`。
///    判据：**「不知道它属于谁」≠「它属于别人」** —— 见文件头那条。
LocalOwnerVerdict localOwnerVerdict({
  required String? owner,
  required String incoming,
}) {
  if (incoming.isEmpty) {
    // 空 userId 表示「未登录」—— 调用方不该走到这里（未登录不触发同步/归属）。
    // 断言拦住；release 下按「不动」处理（这是最保守的一侧）。
    assert(false, 'localOwnerVerdict 需要非空的 incoming userId');
    return LocalOwnerVerdict.same;
  }
  final o = owner?.trim() ?? '';
  if (o.isEmpty) return LocalOwnerVerdict.claim;
  return o == incoming ? LocalOwnerVerdict.same : LocalOwnerVerdict.switched;
}

/// `user.db` 里**属于用户**的表（换账号时清空）。
///
/// ⚠️ **不含 `local_meta`** —— 它是「这份数据属于谁」的记录本身，
///    由调用方在清空后**紧接着**写成新账号（同一事务，见 [clearUserOwnedData]）。
///    漏掉这条会把归属一起删掉 ⇒ 下次登录又走 `claim`（静默地把 B 的数据认成 C 的）。
const List<String> kUserOwnedTables = [
  'card_review_state', // 复习排期（`review_log` 的派生态，但独立存 ⇒ 要一起清）
  'review_log', // 复习流水
  'user_word', // 生词本
  'lookup_event', // 查词记录
  'bookmark', // 收藏
  'article_read', // 阅读记录
  'highlight', // 划线 + 笔记
  'external_word_cache', // 词库外词的词卡缓存（由用户查词产生）
  'achievement_unlock', // 成就解锁
  'translation_cache', // 翻过的句子（行为数据）
  'setting_sync', // 🆕 v10：应用设置的同步载体（账号数据，换账号要清）
];

/// `book.db` 里**属于用户**的表（换账号时清空）。
///
/// 🔑 电子书也算账号数据：`sync_book` 按 `user_id` 存，而且 `book` 表会被
///    **全量推**上去（`_pendingBooks`）⇒ 不清的话旧账号的书名会进新账号的云端书架。
const List<String> kBookOwnedTables = [
  'book_progress_pending', // 待认领的进度（要先清，它引用 `content_hash`）
  'book_marker_pending', // 🆕 v5：待认领的远端书签（同族，先清）
  'book_progress', // 阅读进度
  'book_marker', // 书本内的痕迹
  'book_chapter', // 解析出的章节（`book` 的子表）
  'book', // 书单
  'cloud_book', // 云端书单映射
];

/// 读归属。**表不存在 / 库异常 ⇒ `null`**（= 认领，保留数据 —— 见文件头）。
Future<String?> readLocalOwner(Database db) async {
  try {
    final rows = await db.query(
      kLocalMetaTable,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [kOwnerUserIdKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final v = rows.first['value'];
    return (v is String && v.trim().isNotEmpty) ? v : null;
  } catch (_) {
    // 老库没升上来（表不存在）或库打不开 ⇒ 当作「还没有归属」。
    // ⚠️ 这里**不能**返回一个"失败"信号让调用方去清 —— 见文件头判据。
    return null;
  }
}

/// 写归属（upsert）。空 userId 直接忽略（不能把归属写成空）。
///
/// ⚠️ 表结构是 `(key, value)` 两列 —— 别把 [kOwnerUserIdKey] 当成**列名**
///    （它是 `key` 列里的**值**；写错会报 `table local_meta has no column named …`，
///     本脚本的【6】就是为这条存在的）。
Future<void> writeLocalOwner(Database db, String userId) async {
  if (userId.trim().isEmpty) return;
  await db.insert(
    kLocalMetaTable,
    {'key': kOwnerUserIdKey, 'value': userId},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// 清空 `user.db` 的用户数据（**不动 `local_meta`**）。
///
/// 返回**删除的总行数**（供日志 —— 「清了多少」是可验证的证据，
/// 而「清了」只是一个声明）。
///
/// 🔑 用**事务**：要么全清、要么不清。半清状态比不清更糟 ——
///    用户会看到「生词没了但收藏还在」这种说不出所以然的残缺。
Future<int> clearUserOwnedData(Database db) =>
    _clearTables(db, kUserOwnedTables);

/// 清空 `book.db` 的用户数据。语义同 [clearUserOwnedData]。
Future<int> clearBookOwnedData(Database db) =>
    _clearTables(db, kBookOwnedTables);

/// [clearUserOwnedData] / [clearBookOwnedData] 的唯一实现（一处口径）。
///
/// 🔴 **不吞异常**（刻意）：若某张表不存在（表名写错 / 库没升上来），这里会**抛**。
///    看起来「更不健壮」，但吞掉才是真的危险 ——
///    **吞掉 = 那张表的数据留在了「新账号」名下**，且全程不报错（本项目最忌的静默失败）。
///    ⇒ 拼写层由**静态断言**拦（`verify_local_owner.dart` 逐表核对两个 schema 文件：
///      「清单里的每个名字都存在」+「schema 里的每张用户表都在清单里」），
///      运行时保持严格 ⇒ 两种失败都不会溜过去。
Future<int> _clearTables(Database db, List<String> tables) async {
  var total = 0;
  await db.transaction((txn) async {
    for (final t in tables) {
      total += await txn.rawDelete('DELETE FROM $t');
    }
  });
  return total;
}

/// 删掉电子书**原始文件**目录下的所有文件（目录不存在 ⇒ 返回 0）。
///
/// 🔴 必须与 [clearBookOwnedData] 一起做：只清表不删文件 ⇒
///    用户看不见那些书，但**磁盘上还占着**（几十 MB 级），且没有任何入口能收回。
///    而保留文件也不构成「数据还在」—— 没有 `book` 行就再也读不出它们。
///
/// ⚠️ 只删**文件**，不删目录本身（目录由 `path_provider` 管理，删了下次要重建）。
/// ⚠️ `.tmp-upload`（传输中间态）一起删 —— 它同样是这个账号的残留。
Future<int> clearRawBookFiles(String rawDir) async {
  if (rawDir.trim().isEmpty) return 0;
  final dir = Directory(rawDir);
  if (!await dir.exists()) return 0;
  var n = 0;
  await for (final e in dir.list()) {
    if (e is! File) continue;
    try {
      await e.delete();
      n++;
    } catch (_) {
      // 单个文件删不掉（被占用等）**不中断**其余删除；
      // 残留一个孤儿文件不影响正确性（它再也读不出来）。
    }
  }
  return n;
}
