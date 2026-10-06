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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqlite_api.dart' show Database;

import '../api/sync_client.dart';
import '../services/sync_service.dart';
import 'auth_provider.dart';
import 'book_provider.dart';
import 'device_id_provider.dart';
import 'user_db_provider.dart';

/// **pull 游标**在 `SharedPreferences` 里的键前缀（实际键带 `userId` 后缀）。
///
/// 🔑 为什么放偏好设置而不是 `user.db`：
///    它是**单机状态**（这台设备拉到哪了），不是用户资产 ⇒ 不该进同步。
///
/// # 🔴 为什么键里必须带 `userId`（而不是「登出时清掉」）
///
/// 游标是**账号维度**的状态。若只用一个固定键，换账号后会带着**上一个账号的游标**
/// 去拉数据（形如「从 2026-10-06T10:00 之后」）⇒ 新账号在此之前的全部数据
/// **都拉不到**，而用户看到的是「同步正常，只是生词本少了很多」，**没有任何报错**。
///
/// | 方案 | 换账号 | 注销后重注册 | 同账号再登录 |
/// |---|---|---|---|
/// | 固定键 + 登出时清 | ✅ | ✅ | ⚠️ 白丢增量（要全量重拉）|
/// | **键带 userId** ✅ | ✅ 天然隔离 | ✅ 新 userId = 新键 | ✅ **保留增量** |
///
/// ⇒ 带 `userId` **不需要任何清理逻辑**（少一个「忘了清」的漏点，也少一段死代码）。
/// 📌 同族判据：「**用结构隔离**优于「用流程清理」」——
///    前者不可能忘，后者一定有人忘（本项目已多次踩到「靠人记得」的机制）。
const String kSyncCursorPrefsKeyPrefix = 'coevo_sync_since.';

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
    // 🔑 键带 `userId` ⇒ 换账号天然隔离（见 `kSyncCursorPrefsKeyPrefix` 的说明）
    readCursor: () async =>
        prefs.getString('$kSyncCursorPrefsKeyPrefix$userId'),
    writeCursor: (since) async =>
        prefs.setString('$kSyncCursorPrefsKeyPrefix$userId', since),
    deviceId: deviceId,
    log: (m) => debugPrint('[sync] $m'),
  );
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
  Future.microtask(() async {
    try {
      final auth = ref.read(authProvider);
      final svc = await buildSyncService(
        ref,
        token: auth.token ?? '',
        userId: auth.userId ?? '',
      );
      if (svc == null) return;
      final report = await svc.syncNow();
      if (!report.isEmpty || !report.ok) {
        debugPrint('[sync] 登录后同步：$report');
      }
    } catch (e) {
      // 含 SyncNotSubscribed（未订阅 —— 预期内，不是故障）
      debugPrint('[sync] 登录后同步失败（不影响登录）：$e');
    }
  });
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
Future<void> flushBeforeLogout(WidgetRef ref) => _pushOnly(ref, '登出前 flush');

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
  Future.microtask(() => _pushOnly(ref, '进后台'));
}

/// 两种「只 push」时机的共用实现（**口径只有一处**）。
Future<void> _pushOnly(WidgetRef ref, String tag) async {
  try {
    final auth = ref.read(authProvider);
    final svc = await buildSyncService(
      ref,
      token: auth.token ?? '',
      userId: auth.userId ?? '',
    );
    if (svc == null) return; // 未登录 / user.db 不可用 ⇒ 静默跳过（同步是可选能力）
    final report = await svc.pushOnce();
    // 只在「真的推了东西」或「失败了」时打日志 —— 平时安静（否则日志会被刷屏）
    if (!report.isEmpty || !report.ok) {
      debugPrint('[sync] $tag：$report');
    }
  } catch (e) {
    debugPrint('[sync] $tag 失败（不影响用户）：$e');
  }
}
