// ════════════════════════════════════════════════════════════════════════
// IAP providers —— 把 `IapService` 接入 Riverpod，并接线「登录 → 上报」
// ════════════════════════════════════════════════════════════════════════
//
// # 三条接线（都在 [iapServiceProvider] 里做完）
//
// | # | 接线 | 为什么 |
// |---|---|---|
// | ① | **绑定上报器**（已登录才绑）| 未登录时上报器为 null ⇒ 交易进入「待补报」，**不丢** |
// | ② | **登录后补报** | 覆盖「未登录时购买」—— 只报积压，**不自动 restore**（理由见 `iap_service` 的 `reportEntitlementsIfSignedIn`）|
// | ③ | **启动商店监听** | 商店可能在**启动瞬间**投递上次未完成的事务；晚监听 = 漏掉它们 |
//
// # 🔴 权益判定：端侧**权威** + 服务端**兜底**（2026-10-09 更正口径）
//
// `iapSnapshotProvider` 仍然是**权威**（StoreKit 说有效就是有效，离线也判得了）。
// 但「权威」≠「独占」：**端侧答不上来的场合必须有人兜底** ——
// 安卓验证机没有 StoreKit、后台授予/优惠赠送端侧无从知道 ⇒ 只看端侧会出现
// 「权益明明有，界面显示未订阅」（2026-10-09 白哥真机踩到）。
// ⇒ 判据统一走 [subscriptionActiveNow]（端侧 OR 服务端），**不要各处自己写**。
// ⚠️ 上报失败**仍不得**影响解锁 —— 否则「网络差就白买了」。
//
// # ⚠️ 本 provider 是**懒加载**的
//
// 必须在 App 启动时 `ref.read` 一次预热（点在 `CoEvoApp.initState`）。
// 不预热的话，用户若从不打开订阅页/我的页，启动瞬间那次事务投递就漏了。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';
import '../services/iap_plan.dart';
import '../services/iap_service.dart';
import 'auth_provider.dart';
import 'subscription_provider.dart';

/// [IapService] 单例 + 全部接线。
final iapServiceProvider = Provider<IapService>((ref) {
  final service = IapService();

  /// 上报一笔交易到后端（`POST /api/iap/verify`），返回**服务端确认的到期时间**。
  ///
  /// 🔴 **失败必须抛**：service 层会把它记回「待补报」，下次登录/启动再试。
  ///    若吞掉不抛，这笔交易就**静默丢了**（服务端出现对账缺口，且无人知道）。
  ///    ⚠️ **唯一例外是 409**（归属冲突）—— 那不是"失败"，是服务端**永久拒绝**
  ///        （这笔交易属于别的账号）⇒ 返回 null 而**不抛**，让 service 层
  ///        把它从积压里移除，**不要无限重试**。
  Future<DateTime?> report({
    required String transactionId,
    required String productId,
  }) async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    // 兜底：service 层只在「上报器非 null」时调用，而 null 就是未登录
    if (userId == null) throw StateError('未登录，不该走到这里');

    final headers = <String, String>{'Content-Type': 'application/json'};
    if (auth.token != null) headers['Authorization'] = 'Bearer ${auth.token}';

    final resp = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/api/iap/verify'),
          headers: headers,
          body: jsonEncode({
            'transactionId': transactionId,
            'productId': productId,
            'user_id': userId,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 409) {
      // 🔴 这笔交易已归属其他账号（后端 `Ownership::Conflict`）。
      //    重试一万次也是 409 ⇒ **永久放弃**，且不要打扰用户
      //    （端侧权益已解锁；服务端把权益开给了真正的买家）。
      debugPrint('[IAP] 交易 $transactionId 已归属其他账号 ⇒ 放弃上报（不重试）');
      return null;
    }

    if (resp.statusCode != 200) {
      throw Exception('iap/verify HTTP ${resp.statusCode}');
    }

    // 对账成功 ⇒ 后端已写 `users.subscription_expires` → 刷新本地缓存的口径
    unawaited(ref
        .read(subscriptionProvider.notifier)
        .fetch(userId: userId, token: auth.token));

    // 🆕 2026-10-12（A1）：把服务端确认的到期日**回填给端侧**。
    //   🔴 原注释写着「端侧在收到服务端响应后更新」，但这里**从来没解析过响应体**
    //      ⇒ 承诺落空 ⇒ 端侧 `expiresAtUtc` 永远为空 ⇒ 权益判定恒为「已到期」。
    //   📌 判据：**注释承诺的机制要有实现**；这行代码就是那句注释的兑现。
    final raw = ((jsonDecode(resp.body) as Map<String, dynamic>)['expiresAt']
            as String?)
        ?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  void bindReporter() {
    final auth = ref.read(authProvider);
    final signedIn = auth.isAuthenticated && auth.userId != null;
    // 🔴 传 `accountKey`：让 service 能识别「换了账号」并丢弃不属于新账号的积压
    //    （否则 A 的交易会被 B 补报上去 ⇒ 串号）。见 `IapService.setReporter`。
    service.setReporter(signedIn ? report : null, accountKey: auth.userId);
  }

  bindReporter();

  // 登录 / 登出 / 换账号 ⇒ 重绑上报器；**登录后补报**积压交易
  ref.listen<AuthState>(authProvider, (prev, next) {
    bindReporter();
    if (next.isAuthenticated && prev?.userId != next.userId) {
      unawaited(service.reportEntitlementsIfSignedIn());
    }
  });

  // 尽早监听商店事件（理由见文件头 ③）
  unawaited(service.start());

  ref.onDispose(service.dispose);
  return service;
});

/// 端侧订阅快照 —— **UI 判权益 / 取商品价格**用。
///
/// 🔑 **先发当前值、再跟流**：
///    `service.stream` 是 broadcast 的、**不回放历史**，而 `start()` 是异步的 ——
///    若只跟流，首个 build 可能拿不到已就绪的状态（会闪一下「未订阅」）。
///
/// 🔴 **不能用 `Stream.value(x).followedBy(...)`** —— `followedBy` 是 **`Iterable`**
///    的方法，**`Stream` 没有它**（2026-10-04 实测：`codestatic` 报
///    「The method 'followedBy' isn't defined for the type 'Stream<...>'」）。
///    📌 教训：**API 名不能靠猜** —— 想当然的「应该有这么个方法」必须过一遍符号解析。
///    ✅ 正确写法是 `async*` 生成器：先 `yield` 当前值，再 `yield*` 跟流。
final iapSnapshotProvider = StreamProvider<IapSnapshot>((ref) {
  final service = ref.watch(iapServiceProvider);
  return _snapshotStream(service);
});

Stream<IapSnapshot> _snapshotStream(IapService service) async* {
  yield service.snapshot;
  yield* service.stream;
}

/// 便捷读取：当前快照（**UI 层用**）。
///
/// ⚠️ 参数是 `WidgetRef`（不是 `Ref`）—— Riverpod 2.x 里两者是**不同类型**，
///    不能互相传。`Ref` 给 provider 内部用，`WidgetRef` 给 widget 用。
///
/// 🔑 为什么不让调用方各自 `maybeWhen`：那会把「loading 时回落到什么」这个
///    决策散到每个页面。统一在这里回落到 `service.snapshot`（即最近一次已知值）。
IapSnapshot iapSnapshotOf(WidgetRef ref) {
  final async = ref.watch(iapSnapshotProvider);
  return async.maybeWhen(
    data: (s) => s,
    orElse: () => ref.read(iapServiceProvider).snapshot,
  );
}

/// 🆕 2026-10-09：**「当前订阅是否有效」的唯一判据**（端侧 OR 服务端对账值）。
///
/// # 为什么必须有一处统一的函数
///
/// 判据要读**两个**来源，而它们各自有「读不到」的情形
/// （端侧无 StoreKit / 后端还没 fetch 过）。若两处 UI 各写一遍 OR，
/// 迟早在某个页面上漏读一侧 —— 表现是「这个页面说订阅中、那个页面说免费版」
/// （`profile_screen` 的订阅卡与副标题**已经**踩过同类问题，那次是靠注释约定同源的）。
/// 📌 判据：**同一件事的口径只能一处权威** —— 这里就是那处。
///
/// ⚠️ 必须在 **build 期间**调用（它内部 `ref.watch`）——
///    回调里请改用 `ref.read(...)` 自己取两个值。
///
/// 🔑 服务端那一侧在**未登录**时必然为 false（`_checkSubscription` 不 fetch）
///    ⇒ 未登录用户显示「未订阅」—— 正确：他没有订阅。
bool subscriptionActiveNow(WidgetRef ref) {
  return subscriptionActive(
    iapActive: iapSnapshotOf(ref).isActive,
    backendActive: ref.watch(subscriptionProvider).isActive,
  );
}

/// 🆕 2026-10-09：**「曾经订阅过、现在已失效」的唯一判据**。
///
/// 🔴 它**不是** `!subscriptionActiveNow(ref)` —— 那是把「从未订阅」也算进「已到期」，
///    会给所有免费用户显示「你的会员已到期」。判据与理由见
///    [subscriptionLapsed] 的文档（服务端的 `expired` 含 NULL）。
///
/// ⚠️ 必须在 **build 期间**调用（内部 `ref.watch`）。
bool subscriptionLapsedNow(WidgetRef ref, IapSnapshot snap) {
  final backend = ref.watch(subscriptionProvider);
  return subscriptionLapsed(
    // 端侧语义已经是「有购买记录且已过期」（从未购买给的是 `none`）
    iapExpired: snap.entitlement == IapEntitlementStatus.expired,
    // 服务端「有过记录」= 有效期字段非空（NULL 才是「从未订阅」）
    backendHasRecord: (backend.expiresAt ?? '').trim().isNotEmpty,
    backendExpired: backend.isExpired,
  );
}
