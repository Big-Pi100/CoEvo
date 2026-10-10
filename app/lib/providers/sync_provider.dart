// 云端同步的 Riverpod 接线 —— 把「真实的 db / token / prefs / device_id」
// 接进纯逻辑层（`services/sync_service.dart`）。
//
// 🔑 分层理由（同 `device_id_provider.dart` 的说明）：
//    `services/sync_service.dart` **零 Flutter 依赖**（HTTP 与游标读写都用回调注入）
//    ⇒ 整条编排链能在纯 Dart 断言脚本里跑（假 client + 内存库，见
//      `scripts/query_verify/bin/verify_sync_service.dart`）。
//    本文件是**唯一** import Flutter 的地方。
//
// # 🔴 为什么是「按需构造」而不是一个缓存 provider
//
// `SyncService` 需要 **token**，而 token 在 `authProvider` 里。
// 若做成 `FutureProvider` 并 `watch(authProvider)`，就会形成
// **`authProvider` ←→ `syncProvider` 循环依赖**。
// ⇒ 改成普通函数：谁要用谁调，token 由调用方传入。
//   好处：没有缓存失效问题（token 变了自然用新的），也没有循环。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../api/sync_client.dart';
import '../services/sync_service.dart';
import '../services/tts_service.dart' show ttsServiceProvider;
import 'auth_provider.dart';
import 'book_cloud_provider.dart' show kickBookUpload, bookUploadQueueProvider;
import 'book_provider.dart';
import 'device_id_provider.dart';
import 'sync_status_provider.dart';
import 'user_db_provider.dart';
import 'word_db_provider.dart' show wordQueryProvider, WordDbReady;

/// 🔴 **已废弃（v11 起）**：pull 游标原先在 `SharedPreferences` 里的键前缀
/// （实际键 = 本前缀 + `userId`）。
///
/// # 为什么废弃（2026-10-10）
///
/// 游标已搬进 `user.db` 的 `sync_cursor` 单行表 —— 因为**游标必须与数据同生命周期**。
/// 存 prefs 时，一旦出现「**库被重建、而 prefs 还在**」（迁移异常重建 / 库文件损坏 /
/// 手动清库），游标就会停在一个**很新的时间点**，而历史数据已经没了
/// ⇒ 此后 pull 只取增量 ⇒ **历史永远拉不回来，且全程不报错**。
///
/// ⚠️ **本常量只剩一个用途**：清掉升级前遗留的旧键
///    （见 [clearLegacySyncCursorPrefs]）。**新代码不得再读写它**。
///
/// # 留档：当年为什么选「键带 userId」而不是「登出时清」
///
/// 游标是**账号维度**的状态。若只用一个固定键，换账号后会带着**上一个账号的游标**
/// 去拉数据 ⇒ 新账号在此之前的全部数据**都拉不到**，而用户看到的是
/// 「同步正常，只是生词本少了很多」，**没有任何报错**。
///
/// | 方案 | 换账号 | 注销后重注册 | 同账号再登录 |
/// |---|---|---|---|
/// | 固定键 + 登出时清 | ✅ | ✅ | ⚠️ 白丢增量（要全量重拉）|
/// | **键带 userId** | ✅ 天然隔离 | ✅ 新 userId = 新键 | ✅ **保留增量** |
///
/// 📌 而同族判据「**用结构隔离**优于『用流程清理』」在 v11 被推到了更强的一层：
///    **让游标活在与数据同一个库里** —— 连「隔离」都不需要，因为它与数据**同生共死**。
///    （旧方案仍需一条「换账号时记得清」的流程；新方案**没有这个漏点**。）
///
/// 📄 依据：`docs/review/device-sync-and-profile-failure-2026-10-10.md` §四 D
const String kLegacySyncCursorPrefsKeyPrefix = 'coevo_sync_since.';

/// 组装一个 [SyncService]。
///
/// 返回 `null` 表示**不满足同步前提**（未登录 / `user.db` 打不开）
/// —— 调用方应静默跳过（同步是**可选能力**，不能阻塞主流程）。
/// ⚠️ 参数是 **`WidgetRef`** 而不是 `Ref` —— 两者**没有公共父类**
///    （同 `device_id_provider.dart` 的注释），而当前调用方全是 widget，
///    所以只暴露这一种。若将来 provider 层要用，**照 `deviceIdOrNull` 的做法**
///    再开一个入口（把「读」抽成闭包共用实现），**不要**试图统一类型。
Future<SyncService?> buildSyncService(
  WidgetRef ref, {
  required String token,
  required String userId,
}) async {
  if (token.isEmpty || userId.isEmpty) return null;

  final Database userDb;
  try {
    userDb = await ref.read(userDbProvider.future);
  } catch (e) {
    debugPrint('[sync] user.db 不可用，跳过同步：$e');
    return null;
  }

  // 电子书库**可空** —— 打不开只跳过电子书进度，其余四类照常
  Database? bookDb;
  try {
    bookDb = await ref.read(bookDbProvider.future);
  } catch (e) {
    debugPrint('[sync] book.db 不可用（跳过电子书进度）：$e');
  }

  // device_id 取不到不是致命问题：它只影响「服务端排除本设备」的精确度
  // （拿不到时传空 ⇒ 可能多拉回本设备自己的数据 ⇒ 冗余但**不会错**）
  var deviceId = '';
  try {
    deviceId = await ref.read(deviceIdProvider.future);
  } catch (e) {
    debugPrint('[sync] device_id 不可用（降级为空）：$e');
  }

  final prefs = await SharedPreferences.getInstance();
  final client = SyncClient();

  return SyncService(
    userDb: userDb,
    bookDb: bookDb,
    pushHttp: (body) => client.push(body, token: token),
    pullHttp: ({String? since, String? deviceId}) => client.pull(
      token: token,
      since: since,
      deviceId: deviceId,
    ),
    // 🔴 2026-10-10：游标**从 prefs 移进 `user.db`**（单行表 `sync_cursor`）。
    //
    // # 为什么必须搬（一个**不报错**的坑）
    //
    // 旧做法存 `SharedPreferences`（键 `coevo_sync_since.<userId>`），**数据**却在 `user.db`
    // ⇒ **两者生命周期不一致**：只要出现「库被重建、而 prefs 还在」
    //   （迁移异常重建 / 库文件损坏 / 手动清库），游标就会停在一个**很新的时间点**，
    //   而历史数据已经没了 ⇒ 此后 pull **只取增量** ⇒ **历史永远拉不回来，且全程不报错**
    //   （表现与「从没同步过」完全一样）。
    //
    // 🔑 现在：游标与数据同在 `user.db`，且 `sync_cursor` 属于 `kUserOwnedTables`
    //   ⇒ 换账号 / 清数据时**一起被清** —— 由**结构**保证，不依赖任何人「记得清」。
    //   📌 判据：**「用结构隔离」优于「用流程清理」**（同 `kSyncCursorPrefsKeyPrefix` 段里的取向）。
    //
    // 🔑 迁移语义（**有意**如此）：升级到 v11 时该表为空 ⇒ 下一次同步 `since == null`
    //   ⇒ **全量重拉**。这是幂等的（各表主键 + 合并口径），而且会**顺手补上**
    //    升级前就已经存在的空洞 —— 这正是**不把 prefs 老游标搬过来**的原因。
    // 📄 `docs/review/device-sync-and-profile-failure-2026-10-10.md` §四 D
    readCursor: () async {
      final rows =
          await userDb.rawQuery('SELECT since FROM sync_cursor WHERE id = 1');
      if (rows.isEmpty) return null;
      final v = rows.first['since'];
      // 空串视为「没有游标」⇒ 首次同步（拉全部）—— 与 `SyncPullHttp` 的约定一致
      // （`api/sync_client.dart` 里 `since` 为空则不传该参数）。
      return (v is String && v.isNotEmpty) ? v : null;
    },
    writeCursor: (since) async {
      // 单行表：`id` 有 `CHECK (id = 1)` ⇒ 只能有一个游标（写第二行会失败）。
      await userDb.rawInsert(
        'INSERT INTO sync_cursor (id, since) VALUES (1, ?) '
        'ON CONFLICT(id) DO UPDATE SET since = excluded.since',
        [since],
      );
    },
    deviceId: deviceId,
    log: (m) => debugPrint('[sync] $m'),
    // 🔑 拼写解析的第 ⑤ 级（正式词）要查 `word.db` —— 那是**另一个库**，
    //    `sync_service` 刻意不直接依赖它 ⇒ 在这里注入。
    //
    //    ⚠️ 词库可能**未就绪**（首次要落盘 31.4 MB）；取不到就返回 null ——
    //       解析器会据此**不写那一列**（而不是写个 ID 占位）。
    //       等下一轮同步 / 自愈时词库就绪了，自然能补上。
    wordSpellingLookup: (wordId) async {
      final svc = ref.read(wordQueryProvider).valueOrNull;
      if (svc is! WordDbReady) return null;
      return svc.service.spellingOfId(wordId);
    },
    onSpellingLog: (m) => debugPrint('[sync] $m'),
    // 🆕 2026-10-10：**设置同步**的两个 IO 注入（`SharedPreferences` 只在这里碰）。
    // 🔑 读：`prefs.get(key)` → `Object?`；**`null` = 这个键没设过** ⇒ 采集端会跳过它
    //    （否则会把「默认值」当成用户设置推给别端）。
    // 🔑 写：先 `jsonDecode`，再**按类型** set —— 类型必须保持：
    //    `int` 被写成 `double` 会让「下次采集」把它误判成「已变更」（回声）。
    readPrefSetting: (key) async => prefs.get(key),
    writePrefSetting: (key, value) => _writeSyncedSetting(prefs, key, value),
  );
}

/// 把一个**同步设置**写回 prefs（`value` 是 `jsonEncode` 后的文本）。
///
/// 🔴 **必须按 JSON 解码后的类型写**（不是一律 `setString`）：
///    `reading_font_size` 的消费方读 `getInt`、`tts_enabled` 读 `getBool`——
///    写成 String 会让它们**静默回落到默认值**（读不到就是默认），
///    而「类型漂了」还会让下次采集误判为变更（回声）。
Future<void> _writeSyncedSetting(
  SharedPreferences prefs,
  String key,
  String value,
) async {
  final Object? decoded = jsonDecode(value);
  if (decoded is bool) {
    await prefs.setBool(key, decoded);
  } else if (decoded is int) {
    await prefs.setInt(key, decoded);
  } else if (decoded is double) {
    await prefs.setDouble(key, decoded);
  } else if (decoded is String) {
    await prefs.setString(key, decoded);
  } else if (decoded is List) {
    await prefs.setStringList(key, decoded.map((e) => '$e').toList());
  } else {
    // 不认识的值类型（JSON 里不会有，除非将来加新设置项）⇒ **留痕不抛**：
    // 抛出去会让整次同步报失败，而这条设置只是没写回去（其余数据都已落库）。
    debugPrint('[sync] 设置的值的类型不认识，跳过写回：$key = $value');
  }
}

/// 🗑 2026-10-10：**本函数已改名 + 改语义** —— 原为 `clearSyncCursorFor`（删 prefs 里
/// **这个账号**的 pull 游标）。
///
/// # 为什么不再需要「删游标」了（v11 起）
///
/// 游标已从 `SharedPreferences` 搬进 `user.db` 的 `sync_cursor` 表
/// （见 [buildSyncService] 里 `readCursor` 的说明），而该表属于
/// `kUserOwnedTables` ⇒ **换账号清数据时它已经被一起清掉了**
/// （`local_data_owner` 的 `clearUserOwnedData`）。⇒ 这里**没有事要做**。
///
/// 🔑 这正是一直在追求的那条：**「用结构保证」取代「用流程清理」** ——
///    旧写法的风险不是「清得不干净」，而是**将来新增一条清数据的路径时忘了调它**。
///
/// # 保留本函数的唯一理由：清掉**升级前遗留**的 prefs 键
///
/// v11 之前装的版本会在 `SharedPreferences` 里留下 `coevo_sync_since.<userId>`。
/// 它**已不再被读取**（新代码只认 `sync_cursor` 表），但留着会误导后来的人
/// （grep 到它以为「游标还在 prefs 里」）。⇒ 顺手删掉。
///
/// ⚠️ **不是**「删游标」：删它**不会**影响增量（真正的游标在库里）。
///    所以本函数失败**也不影响正确性** —— 调用方可以只记日志。
Future<void> clearLegacySyncCursorPrefs(WidgetRef ref, String userId) async {
  if (userId.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  // 只删旧键：`coevo_sync_since.<userId>`（新代码再也不读它）
  final legacyKey = '${kLegacySyncCursorPrefsKeyPrefix}$userId';
  if (prefs.containsKey(legacyKey)) {
    await prefs.remove(legacyKey);
  }
}

/// **登录成功后**触发一次同步（`void` —— 调用方不必 await，见下）。
///
/// 🔴 **刻意不返回 `Future`**：调用点在 `ref.listen` 的回调里（widget build 期间），
///    不能 await（会让 build 阻塞在网络上）。
///    返回 `void` + 内部 `Future.microtask` ⇒ 调用点没有「忘了 await」的隐患，
///    也不会触发 `unawaited_futures` 之类的 lint。
///
/// ⚠️ 失败**只记日志**：同步是后台行为，绝不能因为它失败而影响「登录成功」这件事
///    （用户已经登录了 —— 凭据已存 —— 同步失败只是数据晚点到）。
void runSyncAfterLogin(WidgetRef ref) {
  Future.microtask(() => _runSync(ref, tag: '登录后', pushOnly: false));
}

/// **退出登录前**把待推数据送上去。
///
/// 🔴 **必须在清凭据之前调**（设计 §4.5）——
///    否则「本地写了但没推」的那批数据要等下次登录才上去，
///    而用户可能永远不再登录（或换账号 ⇒ 那批数据**永久留在本地**）。
///
/// ⚠️ 返回 `Future`（与 [runSyncAfterLogin] 不同）—— 调用方**需要**等它完成
///    才能继续登出。但调用方**不应因为失败而阻止登出**：
///    把用户困在账号里比丢几个待推数据更糟。
Future<void> flushBeforeLogout(WidgetRef ref) =>
    _runSync(ref, tag: '登出前 flush', pushOnly: true);

/// **App 进入后台时**触发一次 push（只推不拉）。
///
/// # 🔑 为什么用「进后台」而不是「退出复习页」
///
/// | 时机 | 覆盖面 | 生命周期 |
/// |---|---|---|
/// | 退出复习页（`dispose`）| 只有复习数据 | 🔴 **widget 的 `dispose` 里不能安全用 `ref`**（Riverpod 会拒绝）|
/// | **App 进后台** ✅ | **所有**本地改动（复习/生词/收藏/阅读/电子书）| ✅ 根 widget，生命周期 = App |
///
/// ⇒ 进后台**既更全面、又更安全**。且它天然是「用户要离开」的时刻 ——
///   正是把数据送上去的好时机（不用担心打断他正在做的事）。
///
/// ⚠️ 只处理 `paused`（**不处理 `inactive`**）：
///    `inactive` 会在「来电 / 拉控制中心 / 切 App 切换器」时触发 ⇒ **过于频繁**；
///    而 `paused` 才是「真的退到后台」。
///
/// ⚠️ 不发请求的情形：**没有任何本地改动**时 `pushOnce` 直接返回
///    （`pushedTotal == 0` ⇒ 空批次不发请求）⇒ 这个钩子**平时是零成本**的。
void pushWhenAppPaused(WidgetRef ref) {
  Future.microtask(() => _runSync(ref, tag: '进后台', pushOnly: true));
}

/// 🆕 2026-10-10：**回到前台时拉一次**（**完整同步**：push + pull）。
///
/// # 🔴 为什么必须有它（真机：两端状态**永远**不一致）
///
/// 在此之前，自动同步只有 3 个时机，而其中**两个是「只推不拉」**：
///
/// | 时机 | push | pull |
/// |---|---|---|
/// | 登录后 | ✅ | ✅ |
/// | 登出前 flush | ✅ | ❌ |
/// | **进后台** | ✅ | ❌ |
/// | 手动点云朵 | ✅ | ✅ |
///
/// ⇒ **日常里最频繁的时机（切来切去）只推不拉**：
///   A 端复习 → 切到 B 端看 ⇒ B 端**从不 pull** ⇒ **永远看不到 A 的改动**。
///
/// 🔴 实测（服务端日志）：`23:04:01 push review=2`（复习事件**确实推上去了**）
///    —— 但那两次都**只有 push、没有 pull**。
///    而用户报告「**重开 App 就对了**」：重开恰好会走「登录后同步」
///    —— 那是**唯一会拉的自动时机**。⇒ 症状与机制完全吻合。
///
/// 🔑 判据：**「回到前台」是「另一端可能改过」的最强信号** ——
///   用户切回来就是想看最新的，此处**必须 pull**。
/// ⚠️ 与「进后台」刻意不同：进后台只推（要快，不要拖住退出），
///   回前台**拉 + 推都做**（`pushOnly: false`）。
void syncWhenAppResumed(WidgetRef ref) {
  Future.microtask(() => _runSync(ref, tag: '回前台', pushOnly: false));
}

/// 🆕 2026-10-09：供 UI **手动**触发（云朵图标点击 / 失败后重试）。
///
/// 🔑 它与上面三处走**同一个入口** —— 手动与自动的差别只有 `pushOnly`，
///    不该有两套实现（否则「手动能拉、自动只推」这类差异会静默存在）。
Future<void> syncNowFromUi(WidgetRef ref) =>
    _runSync(ref, tag: '手动', pushOnly: false);

/// 同步执行的**唯一入口** —— 三处自动时机 + 一次手动，全部走这里。
///
/// 🔴 它同时承担**状态上报**（`syncStatusProvider`）：这是全库**唯一**写同步状态的地方。
///    若每个调用点各自上报，迟早在某条路径上漏写，而「漏写」的表现是
///    **图标永远停在旧状态、不报错**（本项目最忌的静默失效）。
///
/// [pushOnly] `false` = 先推后拉（`syncNow`）；`true` = 只推（登出前 / 进后台）。
Future<void> _runSync(
  WidgetRef ref, {
  required String tag,
  required bool pushOnly,
}) async {
  final status = ref.read(syncStatusProvider.notifier);
  status.begin();
  try {
    final auth = ref.read(authProvider);
    final svc = await buildSyncService(
      ref,
      token: auth.token ?? '',
      userId: auth.userId ?? '',
    );
    // 未登录 / user.db 不可用 ⇒ 静默跳过（同步是**可选能力**）。
    // ⚠️ 这**不是失败**（见 `SyncPhase.skipped` 的说明）—— 标成失败会让
    //    未登录用户看到一个「同步失败」的红云朵，而其实什么都没发生。
    if (svc == null) {
      status.finishSkipped();
      return;
    }
    final report = pushOnly ? await svc.pushOnce() : await svc.syncNow();
    // 只在「真的动了数据」或「失败了」时打日志 —— 平时安静（否则日志会被刷屏）
    if (!report.isEmpty || !report.ok) {
      debugPrint('[sync] $tag：$report');
    }
    if (report.ok) {
      status.finishOk(report);
    } else {
      // 🆕 2026-10-10：把「凭据失效」这个语义一路带到 UI（[SyncReport.authExpired]）
      // ⇒ 胶囊显示「登录已失效 · 需重新登录」而不是含糊的「同步失败」。
      status.finishFailed(
        report.error ?? '未知原因',
        needsRelogin: report.authExpired,
      );
    }

    // 🔴🔴 **写端通知读端** —— pull 改了本地库 ⇒ 读端必须重算。
    //
    // 此前（直到 2026-10-09）**没有任何地方**在同步之后 bump，后果是
    // 「变更**写进了库，界面却不刷新**」：
    //   · 云端备份被清理（`blob_size → 0`）⇒ 书架仍显示「云端有」⇒ 点下载 **404**
    //   · 别端新增/改动的生词、复习记录 ⇒ 生词本与复习页要等**别的动作**触发 bump
    //     （下载书 / 删书 / 划线 / 查词…）才会出现 —— 而这些动作与同步无关
    // ⇒ 表现为「同步明明成功了，数据就是不出来」，且**不报错**。
    //
    // 🔑 这正是本项目那条判据的实例：**「写端逐个通知读端」是必漏结构，
    //    要反过来让读端 watch 一个 revision**（`bump()` 已经存在，只是没人调）。
    //
    // ⚠️ 两个 revision 都要 bump：pull 会同时写 `user.db`（生词/复习/划线/阅读记录）
    //    与 `book.db`（书单 `cloud_book` / 书进度）⇒ 两个读端族都要重算。
    // ⚠️ 只在**真的拉回东西**时 bump（`pulledTotal > 0`）：否则每次后台同步都会
    //    白让「书列表 / 云端 presence / 云端用量」这几个 FutureProvider 重算。
    //    （轻，但没有理由。）
    // ⚠️ `pushOnly`（登出前 flush / App 进后台）**只推不拉** ⇒ 不需要 bump。
    // ⚠️ 不判 `report.ok`：`pulledTotal > 0` 本身就说明「**已经有数据落库**」
    //    ⇒ 与整轮是否 100% 成功无关，界面都该反映已落库的那部分。
    if (!pushOnly && report.pulledTotal > 0) {
      ref.read(userDbRevisionProvider.notifier).bump();
      ref.read(bookDbRevisionProvider.notifier).bump();
    }

    // 🆕 2026-10-10：**设置**被写回 prefs ⇒ 通知读数端重算。
    //
    // ⚠️ 判据用 `pulledSettings`（= **真正改变了 prefs 的键数**）而不是 `pulledTotal`：
    //    只拉回一条书签不该让「字号 / 兴趣 / TTS」的 provider 白重算一遍。
    // ⚠️ `pushOnly`（登出前 flush / 进后台）只推不拉 ⇒ 不涉及。
    //
    // 🔑 两条通知路径（为什么不能合成一条）：
    //    · 字号 / 兴趣 —— 是 **provider**，它们 `watch(settingsRevisionProvider)`
    //      ⇒ bump 即重算（反转依赖）。
    //    · **TTS** —— 是 `ChangeNotifier`（服务对象是 method channel，不是 widget 树），
    //      没有可 `watch` 的 provider 形态 ⇒ 只能**显式**调它的重读方法。
    //      📌 这是本批唯一一处「点名叫读端」—— 理由已写进 `TtsService.reloadSyncedSettings`。
    //    ⚠️ TTS 重读是 IO（prefs）⇒ `unawaited`：不该让同步等它（同步是后台行为）。
    if (!pushOnly && report.pulledSettings > 0) {
      ref.read(settingsRevisionProvider.notifier).bump();
      unawaited(
        ref.read(ttsServiceProvider).reloadSyncedSettings().catchError((e) {
          debugPrint('[sync] TTS 重读设置失败（不影响同步结论）：$e');
        }),
      );
    }

    // 🆕 2026-10-10：**「书单同步后」补一次上传尝试**（`kickBookUpload` 文档承诺的触发点 ②）。
    //
    //    🔴 此前只有「导入后」一个触发点 ⇒ 下面三种情形**永远不会重试**：
    //       · 导入时未登录（`buildSyncService` 返回 null / token 为空）
    //       · 目录取不到（`rawDir` 空串那个 bug —— 一次都没发出去）
    //       · 网络失败（退避到上限后停住）
    //    而注释里写着「调用时机：① 导入成功后 ② 书单同步后 ③ 用户手动重试」——
    //    **承诺了但没实现**，正是本项目那条「写了没人跑 / 只写了一半」。
    //
    //    ⚠️ 只在 `!pushOnly`（登录后同步 / 手动同步）时做：登出前 flush 与进后台
    //       是「只推」的时机，在那里传文件会让用户等一个不该等的东西。
    //    ⚠️ 没有任何待传书目时 `kickBookUpload` 直接返回（**不发请求**）⇒ 平时零成本。
    //    ⚠️ 失败只记日志：上传是后台行为，绝不能影响同步本身的结论。
    if (!pushOnly) {
      await _kickUploadIfNeeded(ref);
    }
  } catch (e) {
    debugPrint('[sync] $tag 失败（不影响用户）：$e');
    // 🆕 2026-10-10：401 单独标记 —— 「需重新登录」与「同步失败」是**不同出口**。
    status.finishFailed(
      _friendlySyncError(e),
      needsRelogin: e is SyncUnauthorized,
    );
  }
}

/// 同步之后**补一次上传尝试**（`kickBookUpload` 承诺的触发点 ②，2026-10-10 补上）。
///
/// 🔑 与「导入后上传」**共用同一份实现**（`kickBookUpload`）——
///    口径只有一处；这里只负责「什么时候再试一次」。
/// ⚠️ 待传为空时它**不发任何请求**（`kickBookUpload` 内部提前返回）⇒ 平时零成本。
Future<void> _kickUploadIfNeeded(WidgetRef ref) async {
  try {
    final db = await ref.read(bookDbProvider.future);
    await kickBookUpload(
      db: db,
      queue: ref.read(bookUploadQueueProvider),
    );
  } catch (e) {
    debugPrint('[sync] 同步后补传失败（不影响同步结论）：$e');
  }
}

/// 把同步异常翻成**用户能读懂的一句话**。
///
/// 🔑 它是状态里 `lastError` 的**唯一出口** —— 映射不到就**原样透传**，
///    于是云朵图标下会挂着 `SocketException: ... (OS Error: errno = 111)` 这类机器话
///    （同 `auth_provider._friendlyError` 的判据：最该给人话的地方别漏）。
String _friendlySyncError(Object e) {
  // 403「跨设备同步是订阅权益」—— `SyncNotSubscribed` 自带可直接展示的文案
  if (e is SyncNotSubscribed) return e.message;
  // 🆕 2026-10-10 · **401（登录态失效）**：
  //    🔴 它与下面那些「稍后会自动重试」的网络错误**性质相反** ——
  //       token 已被服务端清掉 ⇒ **重试永远不会成功**。
  //    ⇒ 文案必须给出**唯一有效的动作**（重新登录），并把原因说清
  //      （用户最常见的场景就是「在另一台设备上登录了」）。
  //    ⚠️ 不要写成「同步失败，请重试」——那是在骗用户反复点一个不可能成功的按钮。
  if (e is SyncUnauthorized) {
    return '登录状态已失效（可能在本账号的其它设备上登录过），请重新登录后再同步';
  }
  final raw = e.toString();
  if (raw.contains('TimeoutException')) return '网络超时，稍后会自动重试';
  if (raw.contains('SocketException') ||
      raw.contains('Connection refused') ||
      raw.contains('Failed host lookup')) {
    return '连不上服务器，稍后会自动重试';
  }
  return raw;
}

/// 两种「只 push」时机的共用实现（**口径只有一处**）。
/// 🗑 2026-10-09：原 `_pushOnly` 已并入 [_runSync]（加了状态上报后，
///    「执行」与「上报」必须同源 —— 分开写就会出现「跑过但没上报」的路径）。

