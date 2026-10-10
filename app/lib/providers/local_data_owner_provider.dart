// CoEvo · 「本地数据归属账号」的**接线层**
//
// 纯逻辑（判定 + 清哪些表 + 怎么清）在 `services/local_data_owner.dart`（可离线穷举）；
// 本文件只负责**把真依赖接上**：两个库、raw 目录、同步游标、界面 revision。
//
// # 🔴 调用点的顺序约束（唯一一处，写在这里以免被搬走）
//
// ```
//   userId 变化
//     → ① applyLocalOwnerPolicy(...)   ← 本文件（可能清空本地数据）
//     → ② runSyncAfterLogin(ref)       ← 之后才允许 push
// ```
//
// 🔴 **绝不能反过来**：`syncNow()` 会先 push 本地 `pending_push = 1` 的行 ——
//    如果那时旧账号的数据还在，它们会被推到**新登录的账号**名下（这正是要修的那个缺口）。
//    ⇒ 归属判定必须**排在同步之前**（`app.dart` 的监听里也是这个顺序）。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../services/local_data_owner.dart';
import '../services/settings_sync.dart' show resetSyncedSettingPrefs;
import 'book_provider.dart' show bookDbProvider, bookDbRevisionProvider;
import 'book_raw_dir_provider.dart';
import 'sync_provider.dart';
import 'user_db_provider.dart';

/// 按归属处置本机数据，返回**判定结果**（供调用方决定后续动作与日志）。
///
/// | 判定 | 动作 |
/// |---|---|
/// | [LocalOwnerVerdict.claim] | 记下归属，**保留**数据 |
/// | [LocalOwnerVerdict.same] | 什么都不做 |
/// | [LocalOwnerVerdict.switched] | 清空本机学习数据 + 删该账号游标 + 记下新归属 |
///
/// ⚠️ **失败不抛**：它跑在登录流程的后台路径上，抛出去会打断登录。
///    失败时如实记日志；下次登录会**再判一次**（判定是幂等的）。
Future<LocalOwnerVerdict> applyLocalOwnerPolicy(
  WidgetRef ref, {
  required String userId,
}) async {
  final Database userDb;
  try {
    userDb = await ref.read(userDbProvider.future);
  } catch (e) {
    debugPrint('[owner] user.db 不可用，跳过归属判定：$e');
    return LocalOwnerVerdict.same; // 不动 = 最保守（不清任何东西）
  }

  final owner = await readLocalOwner(userDb);
  final verdict = localOwnerVerdict(owner: owner, incoming: userId);

  switch (verdict) {
    case LocalOwnerVerdict.same:
      return verdict;

    case LocalOwnerVerdict.claim:
      // 首次登录 / 老库升级上来 ⇒ 认领（**保留**数据，补记归属）。
      try {
        await writeLocalOwner(userDb, userId);
        debugPrint('[owner] 认领本机数据 → $userId（数据保留）');
      } catch (e) {
        debugPrint('[owner] 认领写入失败（下次登录再试）：$e');
      }
      return verdict;

    case LocalOwnerVerdict.switched:
      debugPrint('[owner] 换账号：$owner → $userId ⇒ 清空本机学习数据');
      await _wipeForNewAccount(ref, userDb: userDb, userId: userId);
      return verdict;
  }
}

/// 换账号的实际处置 —— **顺序是判据的一部分**（逐条见下）。
Future<void> _wipeForNewAccount(
  WidgetRef ref, {
  required Database userDb,
  required String userId,
}) async {
  // ── ① 先清数据（user.db）──
  var rows = 0;
  try {
    rows = await clearUserOwnedData(userDb);
  } catch (e) {
    debugPrint('[owner] 清空 user.db 失败（**不清归属**，下次登录再试）：$e');
    // 🔴 失败就**不写归属** —— 否则「归属已换、数据还在」⇒ 新账号看到旧数据（静默）。
    //    留在旧归属上，下次登录会再判一次 switched（幂等）。
    return;
  }

  // ── ② book.db（可空：打不开就跳过，不影响 user.db 的清理结论）──
  var bookRows = 0;
  try {
    final bookDb = await ref.read(bookDbProvider.future);
    bookRows = await clearBookOwnedData(bookDb);
  } catch (e) {
    debugPrint('[owner] 清空 book.db 跳过：$e');
  }

  // ── ③ 电子书原始文件（只清表不删文件 ⇒ 磁盘留孤儿且无入口收回）──
  var files = 0;
  try {
    final rawDir = await ref.read(bookRawDirProvider.future);
    files = await clearRawBookFiles(rawDir);
  } catch (e) {
    debugPrint('[owner] 清电子书原始文件跳过：$e');
  }

  // ── ④ 🔴 删掉**这个新账号**的 pull 游标 ──
  //
  // 为什么必须删：游标是「这台设备已经拉到哪了」。本地数据刚被清空，
  // 若留着旧游标，新账号第一次 pull 只会拿到「游标之后」的增量
  // ⇒ **绝大多数数据永远拉不回来**，而用户看到的是「同步正常，只是东西少了很多」。
  // （游标本身是按 `userId` 分键的 ⇒ 删的是**同一个账号**上次留下的那个。）
  try {
    await clearSyncCursorFor(ref, userId);
    debugPrint('[owner] 已删 $userId 的 pull 游标（下次全量拉取）');
  } catch (e) {
    debugPrint('[owner] 删游标失败（下次全量拉取的保证会弱一点）：$e');
  }

  // ── ④b 🆕 2026-10-10：复位**同步过的设置 prefs** ──
  //
  // 🔴 为什么必须做（一个跨账号泄漏）：`setting_sync` 表在上面的 `clearUserOwnedData`
  //    里被清了，但**写回 prefs 的设置值不会**（prefs 不归 `local_meta` 管）。
  //    若不复位，新账号的「首次采集」会把**上一个账号的设置值**当成「本地用户设置」
  //    推上去 ⇒ 字号 / 兴趣 / **显示名**跑到别人账号，**且不报错**。
  // 🔑 复位 = **移除**这些键（不是写默认值 —— 写了会被采集端当成「用户设过」）。
  // 📌 与 ④（删游标）同一族的收尾动作，理由同：**用复位优于「靠人记得」**。
  try {
    final prefs = await SharedPreferences.getInstance();
    await resetSyncedSettingPrefs((key) async {
      await prefs.remove(key);
    });
    debugPrint('[owner] 已复位同步设置 prefs（换账号不残留）');
  } catch (e) {
    debugPrint('[owner] 复位同步设置 prefs 失败（可能残留上个账号的设置）：$e');
  }

  // ── ⑤ 最后写归属 ──
  //
  // 🔑 顺序：**先清数据、后写归属**。反过来的话中途失败会留下
  //    「归属=B、数据还是 A 的」⇒ 下次 B 登录判 `same` ⇒ **A 的数据永久留在 B 名下**（静默）。
  //    正序的失败形态是「归属还是 A、数据已空」⇒ 下次登录再判一次 `switched`（幂等）。
  try {
    await writeLocalOwner(userDb, userId);
  } catch (e) {
    debugPrint('[owner] 写归属失败（下次登录会再清一次）：$e');
  }

  // ── ⑥ 通知读端重算（不然界面还显示着已经删掉的数据）──
  ref.read(userDbRevisionProvider.notifier).bump();
  try {
    ref.read(bookDbRevisionProvider.notifier).bump();
  } catch (_) {
    // book.db 不可用时它本来也没读端
  }

  debugPrint('[owner] 清空完成：user.db $rows 行 · book.db $bookRows 行 · '
      '原始文件 $files 个');
}
