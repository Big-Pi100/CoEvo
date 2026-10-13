// ════════════════════════════════════════════════════════════════════════
// IAP 服务层 —— 封装 `in_app_purchase`，把「商店事件」翻译成「我们的状态」
// ════════════════════════════════════════════════════════════════════════
//
// ⚠️ 本文件 import Flutter 插件 ⇒ **本机无法验证**（`flutter` 命令不可用）。
//    所以本文件**只做接线**，所有能判断的逻辑都下沉到 `iap_plan.dart`（已验收）。
//    📌 判据：**把能验证的尽量下沉**，别让不可验证的层承担正确性。
//
// # 架构位置
//     StoreKit ──事件──▶ IapService ──状态──▶ IapNotifier ──▶ UI
//                            │
//                            └──上报──▶ 后端 /api/iap/verify（失败不影响解锁）
//
// # 🔴 三条硬规则（都来自 Apple 文档，违反的后果不对称）
//
// ① **必须调 `completePurchase`**。否则 iOS 的事务**滞留在未完成队列**：
//    每次启动重复投递、同一商品再次购买直接报「重复事务待处理」；
//    Android 则是 **3 天后退款**。⇒ 这是**静默失效**型陷阱（不调也不报错）。
//
// ② **端侧权威**：购买/恢复成功后**立刻解锁**，不等服务端。
//    ⚠️ 前提是**交易带绑定**（`appAccountToken` = 购买时登录的账号）——
//       端侧只在 `iapEntitlementBelongsToAccount` 通过时才算这份权益；
//       **无绑定 ⇒ 端侧不认领**，交给服务端对账（见 `iap_plan.dart`）。
//    服务端只做对账（详见后端 `iap_handlers.rs` 模块文档）。
//    ⇒ 上报失败**不得**影响解锁 —— 否则「网络差就白买了」。
//
// ③ 🔴🔴 **购买需要登录**（2026-10-12 晚间 白哥定案：「**订阅与账号一一绑定**」）。
//    购买/恢复前必须先登录 ⇒ `buy()` 里 `applicationUserName` 必非 null
//    ⇒ 每笔交易都带 `appAccountToken` ⇒ 归属唯一确定、不靠猜。
//    ⚠️ 这一条**改写了** 2026-10-04 的「购买不需要登录」—— 那条已作废。
//    上报这一半不变：未登录/上报失败 ⇒ 交易进 `_pendingReports` 待补报
//    （见 `reportEntitlementsIfSignedIn`）。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
// 🔴 2026-10-12：显式依赖 `in_app_purchase_storekit`，只为了用它的两个字段
//    （`SK2PurchaseDetails.expirationDate` / `.appAccountToken`）——
//    它们**不在**通用接口 `PurchaseDetails` 上。理由见 `pubspec.yaml` 注释。
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart'
    show SK2PurchaseDetails;

import 'iap_plan.dart';

/// 上报回调的签名 —— 由调用方注入，使服务层**不依赖 auth / http**。
///
/// 🔑 为什么用回调而不是直接在服务里读 userId + 发请求：
///    ① 服务层与 `authProvider` / `ApiConfig` **解耦**（少一层耦合，多一层可测）
///    ② 上报失败的处理策略由调用方决定（服务层只负责「告诉它有事发生」）
///    ③ **可 mock** —— 测试时注入一个只记录调用的假实现
///
/// 🔴 2026-10-12：**返回值改为服务端确认的到期时间**（可为 null）。
///    起因：`_parseExpiry` 曾经恒返回 null ⇒ 端侧永远不知道到期日 ⇒ 权益判定恒为
///    「已到期」。现在端侧能从 StoreKit 读（见 `parseStoreKitExpiryMillis`），
///    服务端回填是**第二处来源**（也是权威 —— 它拿的是 Apple 验签后的值）。
///    📌 判据：**注释承诺的机制必须真的有实现** —— 原注释写「端侧在收到服务端响应后
///       更新」，但 `report()` 只查了 statusCode、**没解析响应体** ⇒ 承诺落空。
typedef IapVerifyReporter = Future<DateTime?> Function({
  required String transactionId,
  required String productId,
});

/// 商店可用性。
enum IapAvailability {
  /// 还没查
  unknown,

  /// 可用（能买）
  available,

  /// 不可用（如设备禁止内购、非 iOS 上未接入的商店）
  unavailable,
}

// 🔴 2026-10-12 晚：原在这里的 `enum RestoreOutcome` **已移到 `iap_plan.dart`** ——
//    它现在要驱动文案映射（`restoreOutcomeMessage`），而**文案必须可断言**；
//    本文件 import 了 Flutter 插件 ⇒ 本机验不了（见文件头）。
//    📌 判据：**把能验证的尽量下沉**。
//    ⚠️ 本文件仍可照常使用 `RestoreOutcome` —— 上面已 `import 'iap_plan.dart'`。

/// 服务层对外暴露的一段订阅状态（**端侧权威**）。
@immutable
class IapSnapshot {
  final IapAvailability availability;
  final IapEntitlementStatus entitlement;
  final DateTime? expiresAtUtc;

  /// 🆕 2026-10-12：这份端侧权益**属于哪个 App 账号**。
  ///
  /// 取自交易自带的 **`appAccountToken`** —— 端侧购买时用
  /// `PurchaseParam.applicationUserName` 写入（= 当时的登录 `userId`），
  /// **Apple 原样签进 JWS**，所以我们读到的不是"自己记的账"，而是**权威依据**。
  ///
  /// | 值 | 含义 |
  /// |---|---|
  /// | 某个 `userId` | 这笔是**那个账号**买的 |
  /// | `null` | **无绑定** —— 未登录时买的 / StoreKit 1 / 旧交易 |
  ///
  /// 🔑 它不决定端侧状态，只供 [iapEntitlementBelongsToAccount] 判断
  ///    「这份权益算不算**当前**登录账号的」—— 详见该函数的推导（换账号误显示那次事故）。
  final String? ownerUserId;

  /// StoreKit 返回的商品（用于展示**权威价格**）。
  final List<IapPlanDisplay> plans;

  /// 正在进行某笔购买（UI 转圈用）。
  final bool purchasing;

  /// 最近一次错误（给用户看的一句话）。
  final String? lastError;

  const IapSnapshot({
    this.availability = IapAvailability.unknown,
    this.entitlement = IapEntitlementStatus.unknown,
    this.expiresAtUtc,
    this.ownerUserId,
    this.plans = const [],
    this.purchasing = false,
    this.lastError,
  });

  bool get isActive => entitlement == IapEntitlementStatus.active;

  IapSnapshot copyWith({
    IapAvailability? availability,
    IapEntitlementStatus? entitlement,
    DateTime? expiresAtUtc,
    String? ownerUserId,
    List<IapPlanDisplay>? plans,
    bool? purchasing,
    String? lastError,
    bool clearError = false,
    /// ⚠️ 必须能**清回 null**：「无绑定」（未登录购买）是一种真实状态，
    ///    而 `ownerUserId ?? this.ownerUserId` 会让它**永远改不掉**（同 `clearError` 的理由）。
    bool clearOwnerUserId = false,
  }) =>
      IapSnapshot(
        availability: availability ?? this.availability,
        entitlement: entitlement ?? this.entitlement,
        expiresAtUtc: expiresAtUtc ?? this.expiresAtUtc,
        ownerUserId:
            clearOwnerUserId ? null : (ownerUserId ?? this.ownerUserId),
        plans: plans ?? this.plans,
        purchasing: purchasing ?? this.purchasing,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );
}

/// IAP 服务 —— 商店事件的唯一入口。
class IapService {
  IapService({IapVerifyReporter? reporter}) : _reporter = reporter;

  /// 上报器（可为 null ⇒ 只解锁不上报，用于「未登录」场景）。
  IapVerifyReporter? _reporter;

  /// 当前上报器代表的**账号**（用于判断「换账号」）。
  String? _reporterAccountKey;

  /// 由调用方在登录状态变化时更新（登录后从 null 换成真实上报器）。
  ///
  /// # 🔴 2026-10-12：换账号必须**丢弃**积压交易
  ///
  /// `_pendingReports` 是**跨账号共享**的内存状态。原先登出/换账号都不清，
  /// 于是「A 账号未登录时买的交易」会在「B 账号登录后」被补报上去 ⇒
  /// 后端把这笔交易记成 B 的 ⇒ **A 的钱给 B 开了会员**。
  ///
  /// 沙盒首测实测到了同族现象（同一笔交易被以两个身份上报两次），
  /// 后端已加归属冲突拒绝（`Ownership::Conflict` ⇒ 409）作为**权威**防线；
  /// 这里是**端侧的第二道**：不属于当前账号的积压，根本不该由它上报。
  ///
  /// ⚠️ 代价（如实记录）：判据是 **`accountKey` 只要变化就清** ——
  ///    包括「登出（→null）→ 再登录同一账号」这条路径，那段时间的积压会丢，
  ///    服务端留一个对账缺口。
  ///
  ///    🔑 为什么**不**做更细的区分（2026-10-12 晚间复核，如实记录）：
  ///    ① 新口径下购买**必须先登录**（见 `buy()` 的硬拦截）⇒
  ///       **未登录期间根本产生不了交易** ⇒ `null → X` 这一格没有积压可保，
  ///       为它加分支**没有收益**；
  ///    ② 要真的区分「登出 → 重登同一账号」，得给每笔积压记**产生时的账号**，
  ///       而 `_pendingReports` 是**内存 Map**（App 重启即丢）——
  ///       为它加持久化不划算，那属于**服务端对账缺口**的既有范畴。
  ///    📌 判据：**「清得保守」与「报得完整」冲突时，选不会串号的那一侧。**
  ///
  /// [accountKey] 传当前登录用户的 id；未登录传 null。
  void setReporter(IapVerifyReporter? reporter, {String? accountKey}) {
    final switchedAccount = accountKey != _reporterAccountKey;
    if (switchedAccount && _pendingReports.isNotEmpty) {
      debugPrint(
        '[IAP] 账号变更（$_reporterAccountKey → $accountKey）'
        '⇒ 丢弃 ${_pendingReports.length} 笔不属于该账号的积压交易',
      );
      _pendingReports.clear();
    }
    _reporterAccountKey = accountKey;
    _reporter = reporter;
  }

  final _controller = StreamController<IapSnapshot>.broadcast();
  Stream<IapSnapshot> get stream => _controller.stream;

  IapSnapshot _snapshot = const IapSnapshot();
  IapSnapshot get snapshot => _snapshot;

  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// 记录「已解锁但还没上报成功」的交易，供登录后补报。
  ///
  /// 🔑 为什么需要它：未登录购买时**不能**把交易丢掉 ——
  ///    否则用户登录后服务端永远不知道这笔交易（对账缺口）。
  final Map<String, String> _pendingReports = {};

  /// 供测试观察「积压了多少待上报」。
  @visibleForTesting
  int get pendingReportCount => _pendingReports.length;

  void _emit(IapSnapshot next) {
    _snapshot = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// 启动：订阅商店事件流 + 查商品。
  ///
  /// ⚠️ 必须在 App 启动时**尽早**调用 —— 商店可能在启动瞬间投递未完成的事务
  ///    （上次没 `completePurchase` 的）。晚订阅 = 漏掉它们。
  Future<void> start() async {
    _sub ??= InAppPurchase.instance.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) {
        _emit(_snapshot.copyWith(
          purchasing: false,
          lastError: '商店连接异常，请稍后重试',
        ));
        debugPrint('[IAP] purchaseStream error: $e');
      },
    );

    final ok = await InAppPurchase.instance.isAvailable();
    _emit(_snapshot.copyWith(
      availability:
          ok ? IapAvailability.available : IapAvailability.unavailable,
    ));

    if (ok) await loadProducts();
  }

  /// 查商品（拿到 **StoreKit 的权威价格**）。
  Future<void> loadProducts() async {
    try {
      final resp = await InAppPurchase.instance
          .queryProductDetails(kKnownProductIds.toSet());

      if (resp.notFoundIDs.isNotEmpty) {
        // 🔴 这条**必须记日志**：productId 写错 / ASC 产品没建好
        //    都会表现为「某档消失」。不记就变成「用户说少了一档」的悬案。
        debugPrint('[IAP] 未找到的商品: ${resp.notFoundIDs}');
      }

      // 把 StoreKit 的价格映射到我们的展示模型。
      String? monthlyPrice;
      String? yearlyPrice;
      for (final p in resp.productDetails) {
        if (p.id == kProductMonthly) monthlyPrice = p.price;
        if (p.id == kProductYearly) yearlyPrice = p.price;
      }

      _emit(_snapshot.copyWith(
        plans: defaultPlans(
          monthlyStorePrice: monthlyPrice,
          yearlyStorePrice: yearlyPrice,
        ),
      ));
    } catch (e) {
      debugPrint('[IAP] 查商品失败: $e');
      // 查商品失败**不阻断** —— 用兜底价渲染，用户仍能点购买。
      _emit(_snapshot.copyWith(plans: defaultPlans()));
    }
  }

  /// 发起购买。
  ///
  /// 🔴 `buyNonConsumable` 是**订阅的正确入口** —— `in_app_purchase` 没有
  ///    单独的 `buySubscription`；订阅与「非消耗型」走同一个方法。
  ///    （分界线是「能否被消耗/重复购买」，订阅属不可重复购买 ⇒ non-consumable。）
  Future<void> buy(String productId) async {
    if (!isKnownProductId(productId)) {
      _emit(_snapshot.copyWith(lastError: '未知的订阅商品'));
      return;
    }

    // 🔴🔴 2026-10-12（白哥定案）：**订阅必须登录账号**。
    //
    // 这是「订阅与账号一一绑定」的**硬保证** —— UI 那层（订阅页按钮 → 弹登录）
    // 只是**引导**，真正的不变量在这里兜住：
    //   `_reporterAccountKey == null` ⇒ 未登录 ⇒ 下面 `applicationUserName` 会是 null
    //   ⇒ 交易落成 `appAccountToken = null` ⇒ **无绑定交易**（正是串号的土壤）。
    //   ⇒ 直接拒绝，**不产生任何交易**。
    // 📌 判据：**关键不变量要在服务层兜住，不能只靠 UI** ——
    //    将来若新增购买入口（如首页推荐位），漏拦 UI 也不会破坏归属。
    if (_reporterAccountKey == null) {
      _emit(_snapshot.copyWith(lastError: '请先登录账号后再订阅'));
      return;
    }

    _emit(_snapshot.copyWith(purchasing: true, clearError: true));

    try {
      final resp =
          await InAppPurchase.instance.queryProductDetails({productId});
      if (resp.productDetails.isEmpty) {
        _emit(_snapshot.copyWith(
          purchasing: false,
          lastError: '商品暂不可用，请稍后重试',
        ));
        return;
      }

      // 🆕 2026-10-12（B1）：把**购买时的账号**写进交易，供服务端校验归属。
      //
      // Apple 侧：iOS 上 `applicationUserName` 会落成 StoreKit 2 的
      //   `appAccountToken`（要求是 UUID —— 我们的 `userId` 正是 UUID）。
      //   实测首测那笔交易的 `app_account_token = None` ⇒ **完全没绑定**，
      //   这也是「同一笔交易能被另一个账号认领」的前提。
      //
      // ✅ 2026-10-12 晚间：走到这里 `_reporterAccountKey` **必定非 null**
      //    （未登录已在上面被拦下）⇒ **每一笔交易都带绑定** ——
      //    这就是「订阅与账号一一绑定」的落点，端侧 `iapEntitlementBelongsToAccount`
      //    与后端 `account_binding_conflict` 都建立在它之上。
      final param = PurchaseParam(
        productDetails: resp.productDetails.first,
        applicationUserName: _reporterAccountKey,
      );
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      // ⚠️ 到这里**还没结束** —— 结果从 `purchaseStream` 回来（见 `_onPurchases`）。
      //    ⇒ 不要在 await 之后立刻 emit「成功」。
    } catch (e) {
      _emit(_snapshot.copyWith(purchasing: false, lastError: '购买失败，请重试'));
      debugPrint('[IAP] buy 异常: $e');
    }
  }

  /// 「恢复购买」——Apple **硬性要求**（审核指南 3.1.1）。
  ///
  /// 🔴 恢复的是 **Apple ID 名下的交易**，**不依赖我们的账号**。
  ///    ⇒ 未登录也**必须能恢复**（这是「换设备后找回」的唯一途径）。
  ///
  /// # ⚠️ 为什么这里有一个「等 1.2 秒」
  ///
  /// **StoreKit 不提供「恢复已完成」的信号** —— `restorePurchases()` 返回后，
  /// 结果通过 `purchaseStream` **异步**投递；而该 Apple ID 名下**没有订阅**时，
  /// **一条事件都不会发**。⇒ 无法用「等条件成立」来判断结束（没有条件可等）。
  ///
  /// 🔑 所以用**固定窗口**：它**只影响提示文案**，**不影响权益** ——
  ///    权益由 `_deliver()` 独立更新，事件晚到也照样正确解锁；
  ///    最坏情况是先提示「未找到」、随后状态自动变成已订阅（且不再提示错误）。
  /// 📌 判据对照：项目反对「等猜的时长」是针对**可以用条件替代**的场景
  ///    （如 `showDialog` 的 builder 是否跑过）。此处无替代信号，如实记录理由。
  Future<RestoreOutcome> restore() async {
    if (_snapshot.availability != IapAvailability.available) {
      return RestoreOutcome.unavailable;
    }

    _emit(_snapshot.copyWith(purchasing: true, clearError: true));

    try {
      await InAppPurchase.instance.restorePurchases();
    } catch (e) {
      _emit(_snapshot.copyWith(
        purchasing: false,
        lastError: '恢复购买失败，请稍后重试',
      ));
      debugPrint('[IAP] restore 异常: $e');
      return RestoreOutcome.failed;
    }

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    _emit(_snapshot.copyWith(purchasing: false));

    // 🔴 2026-10-13：判定必须与 UI 的「订阅中」**同源**（含归属过滤）。
    //
    // 原先这里直接判 `_snapshot.entitlement == active` —— 而 UI 走
    // `subscriptionActiveNow`（带归属过滤）⇒ 只要「收到了交易但归属不是当前账号」，
    // 就会同时出现「提示已恢复」与「显示未订阅」（白哥 2026-10-13 实测：
    // 注销后重登，Apple 重放的交易仍写着已注销的旧 userId）。
    // ⇒ 判据下沉到 `iap_plan.judgeRestoreOutcome`（纯函数、可断言）。
    return judgeRestoreOutcome(
      entitlement: _snapshot.entitlement,
      ownerUserId: _snapshot.ownerUserId,
      // 归属过滤的「当前账号」用**上报绑定值** —— 与 `_deliver` / `applyServerExpiry`
      // 用的是同一个口径，避免出现「第三套账号来源」。
      currentUserId: _reporterAccountKey,
    );
  }

  /// 商店事件处理。
  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final pd in list) {
      switch (pd.status) {
        case PurchaseStatus.pending:
          _emit(_snapshot.copyWith(purchasing: true));
          break;

        case PurchaseStatus.error:
          _emit(_snapshot.copyWith(
            purchasing: false,
            lastError: _humanizeError(pd.error),
          ));
          await _complete(pd);
          break;

        case PurchaseStatus.canceled:
          // 用户主动取消 —— **不是错误**，不要显示红字。
          _emit(_snapshot.copyWith(purchasing: false));
          await _complete(pd);
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _deliver(pd);
          break;
      }
    }
  }

  /// 交付：**先解锁（端侧权威）→ 再完成事务 → 最后异步上报**。
  ///
  /// 🔴 顺序不能反：
  ///    · 若「等上报成功才解锁」⇒ 网络差时用户看到「买了没生效」（最糟体验）
  ///    · 若「忘了 completePurchase」⇒ 事务滞留（见文件头规则 ①）
  ///    · 上报放最后 ⇒ 它失败**不影响**前两步
  Future<void> _deliver(PurchaseDetails pd) async {
    // ① 端侧解锁
    final expires = _parseExpiry(pd);
    // 🆕 2026-10-12：记下**这份权益属于哪个 App 账号**（见 `IapSnapshot.ownerUserId`）。
    //    ⚠️ 必须取**交易自带**的 `appAccountToken`，**不能**用"当前登录 userId" ——
    //       交易可能延迟投递（重启重投 / 恢复购买），那时登录的可能已经是另一个账号，
    //       用当前账号会把**别人的交易**标成你的（这正是串号）。
    final owner = _parseOwnerUserId(pd);
    _emit(_snapshot.copyWith(
      purchasing: false,
      entitlement: resolveEntitlement(
        expiresAtUtc: expires,
        hasAnyPurchase: true,
        nowUtc: DateTime.now().toUtc(),
      ),
      expiresAtUtc: expires,
      ownerUserId: owner,
      // 无绑定也是一种明确状态 ⇒ 必须能把它写回去（`??` 会写不掉）
      clearOwnerUserId: owner == null,
      clearError: true,
    ));

    // ② 完成事务（**必须**）
    await _complete(pd);

    // ③ 上报（失败不影响①②）
    //    🆕 2026-10-12：服务端返回的到期日是**权威值**（Apple 验签后）⇒ 回填。
    final serverExpires = await _report(pd);
    if (serverExpires != null) {
      // ⚠️ 服务端的记录是**按上报者 user_id 记的** ⇒ 归属就是当时的登录账号。
      //    这里传 `_reporterAccountKey`（= 上报时绑定的账号），不是"再读一次当前账号"。
      applyServerExpiry(serverExpires, ownerUserId: _reporterAccountKey);
    }
  }

  /// 调 `completePurchase`，并**吞掉异常**。
  ///
  /// 🔑 为什么吞：`completePurchase` 失败时再抛会打断后面的循环，
  ///    导致**同一批里的其它交易处理不到** ⇒ 更大的事务滞留。
  ///    ⚠️ 但它**绝不是可以省略的** —— 见文件头规则 ①。
  Future<void> _complete(PurchaseDetails pd) async {
    if (!pd.pendingCompletePurchase) return;
    try {
      await InAppPurchase.instance.completePurchase(pd);
    } catch (e) {
      debugPrint('[IAP] completePurchase 失败（${pd.productID}）: $e');
    }
  }

  /// 上报到后端。返回**服务端确认的到期时间**（拿不到则 null）。
  ///
  /// 🔴 2026-10-12：`IapVerifyReporter` 现在有返回值。
  ///    ⚠️ 两个「返回 null 但不抛」是**不同**的语义，调用方别混：
  ///      · 未登录 / 无 transactionId / 未知商品 ⇒ 本轮**没上报**（也没人补报）
  ///      · **归属冲突（409）** ⇒ 上报过了，但服务端**永久拒绝** ⇒ 调用方会
  ///        `remove` 掉这笔积压（**不再重试**）。这不是错误，是"这笔交易不归你"。
  Future<DateTime?> _report(PurchaseDetails pd) async {
    final txId = pd.purchaseID;
    final productId = pd.productID;

    if (txId == null || txId.isEmpty) {
      // 没有 transactionId 就没法让服务端查证 —— 但**端侧已解锁**，不必打扰用户。
      debugPrint('[IAP] 无 purchaseID，跳过上报（${pd.productID}）');
      return null;
    }
    if (!isKnownProductId(productId)) return null;

    final reporter = _reporter;
    if (reporter == null) {
      // 未登录 ⇒ 记下来，登录后补报（见 `reportEntitlementsIfSignedIn`）
      _pendingReports[txId] = productId;
      debugPrint('[IAP] 未登录，交易 $txId 待补报');
      return null;
    }

    try {
      final serverExpires = await reporter(
        transactionId: txId,
        productId: productId,
      );
      _pendingReports.remove(txId);
      return serverExpires;
    } catch (e) {
      _pendingReports[txId] = productId;
      debugPrint('[IAP] 上报失败（已记待补报）: $e');
      return null;
    }
  }

  /// 登录后补报：把**积压的交易**补报给服务端。
  ///
  /// # 🔴 为什么**不**在这里调 `restorePurchases()`
  ///
  /// 初版实现让它顺带 `restorePurchases()`，理由是「覆盖未登录时购买的情况」。
  /// **那是错的**，两条独立理由：
  ///
  /// ① 🔴 **Apple 的设计意图是「恢复购买由用户主动触发」** ——
  ///    它对应一个**可见按钮**（审核指南 3.1.1 的要求就是「提供恢复入口」）。
  ///    每次启动/登录都自动调，会产生用户没要求的系统级交互。
  /// ② ✅ **积压机制已经覆盖了那个场景** —— 未登录购买时上报器为 null，
  ///    `_report()` 会把交易记进 `_pendingReports`（**不是丢掉**）
  ///    ⇒ 登录后这次补报就能覆盖，**根本不需要 restore**。
  ///
  /// 📌 而「换设备/重装」场景由**用户主动点「恢复购买」按钮**覆盖（`restore()`）——
  ///    那正是 Apple 期望的路径。
  Future<void> reportEntitlementsIfSignedIn() async {
    if (_reporter == null) return;

    final pending = Map<String, String>.from(_pendingReports);
    if (pending.isEmpty) return;

    debugPrint('[IAP] 登录后补报 ${pending.length} 笔积压交易');
    DateTime? latest;
    for (final entry in pending.entries) {
      try {
        final expires = await _reporter!(
          transactionId: entry.key,
          productId: entry.value,
        );
        _pendingReports.remove(entry.key);
        // 🆕 2026-10-12：顺手记下服务端确认的最新到期日（补报场景下用户
        //    可能从没在这次会话里见过自己的订阅期）。
        if (expires != null && (latest == null || expires.isAfter(latest))) {
          latest = expires;
        }
      } catch (_) {
        // 留着下次再试（不删 ⇒ 不会丢）
      }
    }
    // ⚠️ 归属取 `_reporterAccountKey`（= 本次补报所用的账号）——
    //    服务端是按上报者 `user_id` 记账的，所以那份记录就属于这个账号。
    if (latest != null) {
      applyServerExpiry(latest, ownerUserId: _reporterAccountKey);
    }
  }

  /// 从 StoreKit 的 `PurchaseDetails` 里取**订阅到期时间**。
  ///
  /// # 🔴 2026-10-12 修正：原实现是 `=> null`（硬编码）
  ///
  /// 旧注释写着「通用 API **不直接给**订阅到期时间 …… ⇒ 这里返回 null（=「不知道」），
  /// 交给 `resolveEntitlement` 判为『**有购买史**』……**足以让 UI 先解锁**」——
  /// **但那个"足以先解锁"从未成立**：`resolveEntitlement` 当时把「null + 有购买史」
  /// 判成 `expired`（已到期）⇒ **端侧权益判定恒为「已到期」** ⇒
  /// 「订阅已到期」覆盖层对所有买过的用户必弹（沙盒首测实测）。
  ///
  /// ✅ 事实是：**iOS/StoreKit 2 下插件已经给了到期时间** ——
  ///    `SK2PurchaseDetails.expirationDate`（毫秒时间戳字符串，见
  ///    `in_app_purchase_storekit` 的 `app_store_purchase_details.dart`）。
  ///    ⇒ 不需要解 JWS、不需要猜。
  ///
  /// 📌 判据：**「通用接口没有」≠「拿不到」** —— 要去看具体平台实现类
  ///    （`PurchaseDetails` 是抽象基类，`SK2PurchaseDetails` 是它的子类）。
  /// ⚠️ StoreKit 1 路径（`AppStorePurchaseDetails`）**确实没有**这个字段
  ///    ⇒ 回退 null，由 `resolveEntitlement` 按「不知道」处理（fail-open）。
  DateTime? _parseExpiry(PurchaseDetails pd) {
    if (pd is! SK2PurchaseDetails) return null;
    return parseStoreKitExpiryMillis(pd.expirationDate);
  }

  /// 从交易里取**归属账号**（`appAccountToken` = 购买时传入的 `applicationUserName`）。
  ///
  /// ⚠️ StoreKit 1（`AppStorePurchaseDetails`）**没有**这个字段 ⇒ 回退 null（无绑定）。
  /// 🔑 该值由 Apple **原样签进 JWS** ⇒ 是「这笔交易属于谁」的**权威依据**。
  String? _parseOwnerUserId(PurchaseDetails pd) {
    if (pd is! SK2PurchaseDetails) return null;
    final t = pd.appAccountToken?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// 用**服务端确认的**到期时间刷新端侧状态（对账成功的回填）。
  ///
  /// 🔑 为什么需要它：端侧从 StoreKit 读的值是"购买那一刻"的；
  ///    续期 / 退款 / 换设备等场景以**服务端（Apple 验签后）**的值为准。
  ///    📌 这正是原注释承诺而**未实现**的那一步（见 [IapVerifyReporter]）。
  ///
  /// ⚠️ 只允许**向后推进**（新值比已知的更晚才覆盖）：并发/乱序响应下，
  ///    不能让一个较旧的值把刚续期的到期时间**改回去**。
  ///
  /// [ownerUserId] = 这份权益归属的 App 账号（服务端是**按上报者 `user_id` 记账**的，
  ///    所以取上报时绑定的那个账号；见 `_deliver` 与 `reportEntitlementsIfSignedIn`）。
  void applyServerExpiry(DateTime expiresUtc, {required String? ownerUserId}) {
    final known = _snapshot.expiresAtUtc;
    if (known != null && !expiresUtc.isAfter(known)) return;

    _emit(_snapshot.copyWith(
      entitlement: resolveEntitlement(
        expiresAtUtc: expiresUtc,
        hasAnyPurchase: true,
        nowUtc: DateTime.now().toUtc(),
      ),
      expiresAtUtc: expiresUtc,
      ownerUserId: ownerUserId,
      clearOwnerUserId: ownerUserId == null,
    ));
  }

  String _humanizeError(IAPError? err) {
    final code = err?.code ?? '';
    // 🔴 用户主动取消在 iOS 上是 `paymentCancelled` —— 别报错
    if (code.contains('cancel')) return '';
    return '购买未完成，请稍后重试';
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _controller.close();
  }
}
