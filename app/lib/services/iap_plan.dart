// ════════════════════════════════════════════════════════════════════════
// IAP 订阅 · **纯逻辑层**（零 import）
// ════════════════════════════════════════════════════════════════════════════
//
// 🔴 为什么单独一个文件、且**零 import**：
//    本机 `flutter analyze` / `flutter test` **不可用**（`CreateFile failed 231`
//    —— 建不了子进程）。而零 import 的纯 Dart 可以用 `dart run` 跑**完整类型检查**
//    与断言 ⇒ **这一层能被真正验证**，UI 层只能靠 CI。
//    ⇒ 判据：**把能验证的尽量下沉到纯逻辑层**，别让「不可验证的 UI」承担正确性。
//
// 🔴 Product ID 的「三处一致」（改任一处必须同步另外两处）：
//    ① 本文件  ② `backend/crates/api_server/src/iap_handlers.rs` 的 PRODUCT_*
//    ③ App Store Connect 里建的产品 ID
//    📌 本项目判据：**同一件事的口径只能一处权威 + 写明参照系**。
//       这里权威是 **App Store Connect**（产品 ID 由它定义、且**保存后不可改**），
//       代码两处是「引用」。断言见 `checkProductIdsMatchBackend()`。

/// App Bundle ID —— 与 `app/ios/Runner.xcodeproj` 的 `PRODUCT_BUNDLE_IDENTIFIER` 一致。
const String kBundleId = 'com.coevo.coevoApp';

/// 订阅产品 ID（🔴 与 ASC / 后端逐字一致，大小写敏感）。
const String kProductMonthly = 'com.coevo.coevoApp.pro.monthly';
const String kProductYearly = 'com.coevo.coevoApp.pro.yearly';

/// 全部已知产品 ID。
const List<String> kKnownProductIds = [kProductMonthly, kProductYearly];

/// 该产品 ID 是否是我们认得的。
bool isKnownProductId(String productId) => kKnownProductIds.contains(productId);

/// 产品 ID 与后端的**一致性自检**（后端 `iap_handlers.rs` 的常量）。
///
/// 返回不一致的原因列表（空 = 一致）。
///
/// 🔑 为什么要这个函数：产品 ID 是**跨端契约**，而它**只在运行时**才暴露不一致 ——
///    表现是「买完了但服务端说未知产品」。把契约写成**可断言的函数**，
///    就能在 CI 里提前发现（而不是等沙盒联调）。
List<String> checkProductIdsMatchBackend({
  required String backendMonthly,
  required String backendYearly,
}) {
  final problems = <String>[];
  if (backendMonthly != kProductMonthly) {
    problems.add('月度产品 ID 不一致：前端=$kProductMonthly 后端=$backendMonthly');
  }
  if (backendYearly != kProductYearly) {
    problems.add('年度产品 ID 不一致：前端=$kProductYearly 后端=$backendYearly');
  }
  return problems;
}

// ════════════════════════════════════════════════════════════════════════
// 价格格式化
// ════════════════════════════════════════════════════════════════════════

/// 分 → `¥9.9` / `¥78` / `¥78.00` 风格。
///
/// 🔑 规则：整数元**不显示**小数（`¥78` 而不是 `¥78.00`）——
///    这是国内定价的通行写法，也让「¥9.9 vs ¥78」的对比更干净。
String formatYuan(int fen) {
  if (fen < 0) return '¥0';
  final yuan = fen ~/ 100;
  final cents = fen % 100;
  if (cents == 0) return '¥$yuan';
  if (cents % 10 == 0) return '¥$yuan.${cents ~/ 10}';
  return '¥$yuan.${cents.toString().padLeft(2, '0')}';
}

// ════════════════════════════════════════════════════════════════════════
// 展示模型
// ════════════════════════════════════════════════════════════════════════

/// 一个订阅档位的**展示信息**。
///
/// 🔑 价格有**两个来源**，分工必须清楚：
///    · `storePrice` —— 来自 StoreKit（**权威**，Apple 已本地化好货币与格式）
///    · `fallbackFen` —— 本地兜底（**仅当 StoreKit 还没返回时**用来占位）
///    ⇒ 展示时**优先 `storePrice`**；有它就不该显示本地价格。
class IapPlanDisplay {
  final String productId;
  final String title;
  final int months;
  final String durationLabel;
  final int fallbackFen;
  final String? storePrice;

  const IapPlanDisplay({
    required this.productId,
    required this.title,
    required this.months,
    required this.durationLabel,
    required this.fallbackFen,
    this.storePrice,
  });

  /// 最终展示的价格串。
  String get priceLabel => storePrice ?? formatYuan(fallbackFen);

  /// 是否在用本地兜底价（UI 可据此加「以 App Store 为准」的说明）。
  bool get usingFallbackPrice => storePrice == null;
}

/// 内置的两档（StoreKit 返回商品前也能渲染骨架屏）。
List<IapPlanDisplay> defaultPlans(
        {String? monthlyStorePrice, String? yearlyStorePrice}) =>
    [
      IapPlanDisplay(
        productId: kProductMonthly,
        title: 'CoEvo 专业版',
        months: 1,
        durationLabel: '1 个月',
        // 🔴 与后端 seed（`subscription_plans.price`）一致：990 分
        fallbackFen: 990,
        storePrice: monthlyStorePrice,
      ),
      IapPlanDisplay(
        productId: kProductYearly,
        title: 'CoEvo 专业版',
        months: 12,
        durationLabel: '1 年',
        fallbackFen: 7800,
        storePrice: yearlyStorePrice,
      ),
    ];

/// 年付相对月付的折扣百分比（用于「省 X%」角标）。
///
/// 返回 null 表示**不该显示**折扣（年付不比月付划算，或数据不足）。
///
/// 🔑 为什么返回 null 而不是 0/负数：**「没有折扣」和「折扣是 0%」在 UI 上不同** ——
///    前者不该出现角标，后者会显示「省 0%」。用一个可为空的值把它们分开。
int? yearlyDiscountPercent({required int monthlyFen, required int yearlyFen}) {
  if (monthlyFen <= 0 || yearlyFen <= 0) return null;
  final fullYear = monthlyFen * 12;
  if (yearlyFen >= fullYear) return null;
  final saved = fullYear - yearlyFen;
  // 四舍五入到整数百分比
  final pct = ((saved * 100) / fullYear).round();
  return pct > 0 ? pct : null;
}

// ════════════════════════════════════════════════════════════════════════
// 🔴 法定要件文案（Apple 对订阅页的硬要求）
// ════════════════════════════════════════════════════════════════════════

/// 订阅页**必须**让用户在购买前看到：名称 / 时长 / 价格 / **自动续费说明**。
///
/// 🔴 这不是文案偏好 —— App Store 审核指南 3.1.2 明确要求订阅页说明
///    「会自动续期」以及「如何取消」。缺了会被拒。
///
/// 📌 单独做成函数（而不是写在 Widget 里）的原因：
///    **文案可被断言** ⇒ 改 UI 时不会不小心把它删掉。
class SubscriptionLegalText {
  /// 自动续费说明（订阅页主文案）。
  static String autoRenewNotice({
    required String title,
    required String durationLabel,
    required String priceLabel,
  }) =>
      '$title，$durationLabel，$priceLabel。'
      '订阅将自动续期，除非在当前订阅期结束前至少 24 小时关闭自动续期。';

  /// **未选档位时**的通用续费说明。
  ///
  /// 🔑 为什么需要它：`ui-ux §4.4.2` 要求「**接受服务前**」就显著提示自动续费 ——
  ///    即**用户还没点选任何档位时**，页面上就得有续费说明。
  ///    ⇒ 不能等到「选中了才有说明」（那就成了「选完才告知」）。
  static String autoRenewNoticeGeneric() =>
      '订阅按月或按年自动续期，除非在当前订阅期结束前至少 24 小时关闭自动续期。';

  /// 续费扣款说明。
  static String renewalCharge() => '系统会在当前订阅期结束前 24 小时内从你的 Apple 账户扣取下一期费用。';

  /// 取消方式（Apple 要求说明「在哪里取消」）。
  static String howToCancel() => '可在「设置 → Apple 账户 → 订阅」中随时管理或取消订阅。取消后，'
      '当前订阅期结束前仍可使用会员功能。';

  /// 会员权益（与我们产品实际提供的对齐 —— **不能写未实现的能力**）。
  static const List<String> benefits = [
    '无限生词本（免费版上限 200 词）',
    '文章朗读',
    '电子书导入',
  ];

  /// 免费版说明（让用户理解「为什么订阅」）。
  static String freeTierNote() => '免费版可无限使用阅读、划词查词、生词本（上限 200 词）与词卡朗读。';
}

// ════════════════════════════════════════════════════════════════════════
// 订阅状态（端侧判定 + 与后端对账）
// ════════════════════════════════════════════════════════════════════════

/// 端侧能观察到的订阅状态。
///
/// 🔑 **端侧是权威**（StoreKit 的 `currentEntitlements`）——
///    后端的 `subscription_expires` 只作**对账/留档**，不决定权益。
///    ⇒ 所以这个枚举**不包含**「后端说有效」这种状态：那不该影响 UI。
enum IapEntitlementStatus {
  /// 还没查（启动瞬间）
  unknown,

  /// 有有效订阅
  active,

  /// 曾订阅、现已过期
  expired,

  /// 从未订阅
  none,
}

/// 判定：给定到期时间与「是否曾购买过」，得出状态。
///
/// [expiresAtUtc] 为 null 表示 StoreKit 没给出到期时间（如非续期型购买 —— 我们不用）。
/// [hasAnyPurchase] 表示这个 Apple ID 在本 App 下**有过**交易（用于区分 expired / none）。
IapEntitlementStatus resolveEntitlement({
  required DateTime? expiresAtUtc,
  required bool hasAnyPurchase,
  required DateTime nowUtc,
}) {
  if (expiresAtUtc != null && expiresAtUtc.isAfter(nowUtc)) {
    return IapEntitlementStatus.active;
  }
  if (hasAnyPurchase) return IapEntitlementStatus.expired;
  return IapEntitlementStatus.none;
}

/// 降级提示（订阅到期后展示）。
///
/// 🔴 与规格一致：**保留全部生词（可读/可复习/可发音），仅冻结新增**。
///    所以文案**不能**说「生词本已锁定」——那与实现不符（属虚假陈述）。
String downgradeNotice() => '会员已到期。你的生词、学习记录与已导入的电子书都已保留，'
    '仍可正常查看与复习；新增生词（超过 200 词上限）与文章朗读需要续订。';

/// 「我的」页的版本标签。
String versionLabel(bool isActive) => isActive ? '订阅版' : '免费版';

// ════════════════════════════════════════════════════════════════════════
// 外部链接（订阅页 / 关于页共用）
// ════════════════════════════════════════════════════════════════════════

/// 🔴 Apple **订阅管理**页 —— 固定的官方地址。
///
/// 用途：`ui-ux §4.4.4` 要求「已订阅 → 提供**管理订阅**（跳 Apple 订阅管理）」。
/// ⚠️ 取消订阅由 Apple 提供（我们不自建），但**必须在页面上说明路径** ——
///    判例：「不是发了就行，要**看得见、找得到、关得掉**」。
/// ⚠️ 若 Apple 调整该地址，改这一处即可（全 App 只此一个定义）。
const String kAppleManageSubscriptionsUrl =
    'https://apps.apple.com/account/subscriptions';

/// 隐私政策 URL —— ✅ **2026-10-04 已上线**。
///
/// 部署方式见 `scripts/legal/publish_legal_pages.sh`（幂等 · nginx 直接给静态文件）。
/// ⚠️ 若将来换域名（如改用根域 `keyievolution.fun`），只需改这两处常量 ——
///    订阅页与「关于」页都从它们取值（经由 `widgets/legal_link_row.dart`）。
const String? kPrivacyPolicyUrl = 'https://api.keyievolution.fun/privacy';

/// 用户协议 URL —— 同上。
const String? kTermsOfServiceUrl = 'https://api.keyievolution.fun/terms';
