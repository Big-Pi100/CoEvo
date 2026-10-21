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

/// 分 → `¥6` / `¥58` / `¥4.83` 风格。
///
/// 🔑 规则：整数元**不显示**小数（`¥58` 而不是 `¥58.00`）——
///    这是国内定价的通行写法，也让「¥6 vs ¥58」的对比更干净。
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

  /// 价格下方的小字说明（周期）。
  ///
  /// # 🔑 年付为什么折算成「≈ ¥X / 月」
  ///
  /// 把两档拉到**同一量纲**，用户才能直接比。
  /// 「¥58 / 年」与「¥6 / 月」不是同一单位 —— 要心算才知道差多少；
  /// 「≈ ¥4.83 / 月」则一眼可比。这正是 §4.4.1 判据 4 要「并列展示」的用意。
  ///
  /// # ⚠️ 一个刻意的限制：只在**价格也来自本地兜底**时才做换算
  ///
  /// `storePrice` 是 StoreKit 给的**已本地化字符串**（可能是 `$` / `€`…），
  /// 而折算用的是 `fallbackFen`（人民币）。
  /// 若两者混用，会出现「价格显示 $9.99，下面写 ≈ ¥4.83/月」这种**自相矛盾**。
  /// ⇒ 非兜底价时退化为中性的「每年自动续期」（不撒谎，也不误导）。
  String get periodLabel {
    if (months <= 1) return '每月自动续期';
    if (!usingFallbackPrice) return '每年自动续期';
    return '≈ ${formatYuan(fallbackFen ~/ months)} / 月';
  }
}

/// 内置的两档（StoreKit 返回商品前也能渲染骨架屏）。
List<IapPlanDisplay> defaultPlans(
        {String? monthlyStorePrice, String? yearlyStorePrice}) =>
    [
      IapPlanDisplay(
        productId: kProductMonthly,
        title: '记住一切 专业版',
        months: 1,
        durationLabel: '1 个月',
        // 🔴 与后端 seed（`subscription_plans.price`）一致：600 分
        //    ⚠️ 2026-10-11 由 990 改 600（ASC 只给固定价位，白哥选 ¥6）。
        //    📌 改这个数要**同时**改：后端 seed / 法务文本价格表 / ASC 产品价 —— 共四处。
        fallbackFen: 600,
        storePrice: monthlyStorePrice,
      ),
      IapPlanDisplay(
        productId: kProductYearly,
        title: '记住一切 专业版',
        months: 12,
        durationLabel: '1 年',
        fallbackFen: 5800,
        storePrice: yearlyStorePrice,
      ),
    ];

/// 年付相对月付的折扣百分比（用于「省 X%」角标）。
///
/// 返回 null 表示**不该显示**折扣（年付不比月付划算，或数据不足）。
///
/// 🔑 为什么返回 null 而不是 0/负数：**「没有折扣」和「折扣是 0%」在 UI 上不同** ——
///    前者不该出现角标，后者会显示「省 0%」。用一个可为空的值把它们分开。
///
/// ⚠️ 调用方（`subscribe_screen._yearlyDiscount`）传的是**兜底价** `fallbackFen`
///    （StoreKit 给的是已本地化的**字符串**，无法参与运算）
///    ⇒ **「省 X%」正确的前提是 `fallbackFen` 与 ASC 里的实际价一致**。
///    改价时只改 ASC 不改这里 ⇒ 价格会被 StoreKit 自动更新，而**这个百分比不会**
///    ⇒ **静默显示一个错的折扣**（不报错、也没人会发现）。
///    （2026-10-11：¥9.9/¥78 → ¥6/¥58 ⇒ 34% → 19%，就是靠改 `fallbackFen` 兜住的）
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

/// 对照表（`订阅权益` 区块）的**一行** —— `功能 | 免费版 | 订阅版` 三列。
///
/// 🔑 依据 `docs/review/subscription-value-assessment-2026-10-07.md` §四「对照表设计」：
///    形态就是三列；§4.2 的写法是**合并共同项、突出专享项**。
///    ⇒ [exclusive] 为 true 的行落在「订阅版专享」段，其余落在「共同享有」段。
class BenefitRow {
  const BenefitRow(
    this.label, {
    this.free = '✓',
    this.sub = '✓',
    this.exclusive = false,
  });

  /// 功能名（第一列）。
  final String label;

  /// 免费版列的文案。`✓` = 可用；`—` = 不可用；也可以是额度（如「每月 10 次」）。
  final String free;

  /// 订阅版列的文案。
  final String sub;

  /// 是否「订阅版专享」（决定它落在表的哪一段，并进入 [SubscriptionLegalText.benefits]）。
  final bool exclusive;
}

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

  /// 「订阅权益」对照表 —— 权益与免费能力的**唯一事实清单**（三列：功能 | 免费版 | 订阅版）。
  ///
  /// # 🔴 为什么是**一张表**而不是两份清单
  ///
  /// 2026-10-09 之前这里是两条平行清单（`benefits` + `freeIncludes`），各自维护
  /// ⇒ 同一件事有**两个来源**（改一处漏一处，且「共同能力」还得在两边各写一遍）。
  /// 而 `subscription-value-assessment-2026-10-07` §四 已把对比**形态**定为
  /// `功能 | 免费 | 订阅` 三列（§4.2：**合并共同项、突出专享项**）。
  /// ⇒ 现在**只有这一张表**：专享权益与共同能力都从它派生
  ///   （见 [benefits] / [sharedBenefits]），UI 也直接渲染它。
  ///
  /// # 🔴 每一行都必须与「**已实现的能力**」逐一对应
  ///
  /// 写未实现的能力 = **虚假宣传**（2026-10-04 那版踩过）；漏写已实现的 = **价值说不清**。
  /// 依据 = 后端订阅闸门 `is_subscription_active()` 的**三个消费点**
  /// （它们就是「订阅到底买到了什么」的事实清单）：
  ///
  /// | 行 | 免费版 | 订阅版 | 证据 |
  /// |---|---|---|---|
  /// | 学习记录跨设备同步 | **仅可下载**（pull 放行 · push 403） | 双向同步 | `sync_handlers.rs` 的 `sync_pull` / `sync_push` |
  /// | 云端书架（电子书备份） | 不可**上传** | ✓ | `book_blob_handler.rs:157`（写）· `:329`（读，仅登录）|
  /// | 整段翻译 | 每月 **10** 次 | 不限次数 | `translation.rs:59 / 375` |
  ///
  /// ⚠️ 第 2 行的「**下载不设闸门**」是**查过代码**的（`:329` 只验登录）
  ///    ⇒ 所以「订阅到期后」写的是「仍可下载、不能再上传」，
  ///    **不是**「云端书架不可用」—— 方向相反的错同样是错。
  ///
  /// # ⚠️ 已作废、**不得**回到表里的能力（断言里都反锁着）
  ///
  /// | 旧权益 | 为什么不能写 |
  /// |---|---|
  /// | 「无限生词本（免费版上限 200 词）」 | 🔴 **免费版已无上限**（2026-10-01 白哥定「免费全量」），代码已彻底删 |
  /// | 「文章朗读」 | ✅ 朗读**已免费全量**（词卡 / 电子书整章）—— 说它是订阅权益属**方向相反**的错 |
  /// | 「电子书导入」 | ✅ 白哥定为**免费**（本地导入不触发 NPPA） |
  /// | 「语音包」 | 2026-09-26 已取消 |
  static const List<BenefitRow> comparison = [
    BenefitRow('阅读信息流全部内容'),
    BenefitRow('划词查词'),
    BenefitRow('生词本 · 无数量限制'),
    BenefitRow('词卡朗读与复习'),
    // 🔴 2026-10-13：本行由 `free: '—'`（= 完全不可用）改为「仅可下载」。
    //    原因是后端改了（白哥定案 B）：`sync_pull` 现在**只验登录**
    //    ⇒ 免费/到期用户**仍能把云端数据拉回本机**，只是不能再上传。
    //    ⚠️ 继续写「—」是**方向相反的错**（说成完全不可用），
    //       与「不会丢失或锁定任何已积累的内容」直接冲突。
    BenefitRow('学习记录跨设备同步', free: '仅可下载', sub: '双向同步', exclusive: true),
    BenefitRow('云端书架（电子书备份）', free: '—', exclusive: true),
    BenefitRow('整段翻译', free: '每月 10 次', sub: '不限次数', exclusive: true),
  ];

  /// 订阅版**专享**权益 —— 从 [comparison] 派生（**单一来源**，不另写一份）。
  ///
  /// ⚠️ 它曾经是独立的 `const` 清单 —— 那正是「同一件事两个来源」的形状：
  ///    往 `comparison` 加一行、忘了改这里，订阅页就会**少说一条**（而且不报错）。
  static List<String> get benefits => comparison
      .where((r) => r.exclusive)
      .map((r) => r.label)
      .toList(growable: false);

  /// 免费版与订阅版**共同享有**的能力（对照表上半段）—— 同样从 [comparison] 派生。
  static List<String> get sharedBenefits => comparison
      .where((r) => !r.exclusive)
      .map((r) => r.label)
      .toList(growable: false);

  /// 未订阅态的**一行价值主张**（放不下三条的长副标题位置用它）。
  ///
  /// 🔑 **必须与 [benefits] 同源**：每一项都要能在权益清单里找到对应
  ///    （断言锁着）。**不要**在这里另编一句「无限生词本 · 文章朗读」——
  ///    那两个能力**早已免费**，说成订阅权益就是虚假陈述
  ///    （`profile_screen` 的订阅卡曾真的这么写，2026-10-09 一并修正）。
  static String shortPitch() => '跨设备同步 · 云端书架';

  /// 未订阅态的**主标题**（一句话）。
  ///
  /// 🔑 为什么不再用 `benefits.join(' · ')` 当标题：三条权益连起来是**一段话**
  ///    （每条约 15 字），做 16px 标题会变成「文字墙」—— 标题只该说**一句话**。
  ///    详情交给下方常驻的「订阅权益」对照表（它才是逐条对比的地方）。
  ///    📌 判据（§5.2）：**权重靠位置与色彩，不靠把内容塞进标题**。
  static String headline() => '订阅后，学习记录可在多设备间同步';

  /// 免费版说明（让用户理解「为什么订阅」）。
  ///
  /// # 🔴 2026-10-04 修正：原文写「生词本（上限 200 词）」—— 上限**已取消**
  ///
  /// 那句是**已作废的规格**。现在如实描述免费版**没有**任何数量限制。
  /// 📌 这不是「示弱」，而是「免费层如实展示」（`ui-ux §4.4.1` 判据 2：
  ///    明确写「免费可用」，**不用「试用」「限时」话术**）——
  ///    如实说明免费能做什么，反而比夸大订阅更可信。
  static String freeTierNote() => '免费版可无限使用阅读、划词查词、生词本、词卡朗读与复习；'
      '整段翻译每月 10 次。除翻译额度外不设任何数量限制。';

  /// 订阅到期后会怎样（「订阅到期后」区块的清单）。
  ///
  /// 🔑 这一块**对未订阅 / 已到期的人是关键信息**（白哥 2026-10-09：
  ///    「没订阅、订阅到期的人看到才是关键」）—— 它回答「我订了再退会怎样」，
  ///    决策权重高 ⇒ 与「订阅权益」一样**常驻**，不折叠。
  ///    对已订阅的人则无意义（他自己不需要被说服）⇒ 已订阅态不渲染这一块。
  ///
  /// 🔑 核心信息是「**不没收用户资产**」（`ui-ux §4.4.4` 的原则：
  ///    「全部词保留可读/可复习 · **不锁词**」「已导入的电子书必须保留」）。
  ///
  /// 🔴 2026-10-09：按**后端闸门的实际行为**补三条具体影响
  ///    （原版只有一句「回到免费版能力」，用户看不出**到底少什么**）。
  ///    ⚠️ 其中「已备份的仍可下载」是**查过代码**的（下载端点只验登录、不查订阅，
  ///       `book_blob_handler.rs:329`）—— **不要**写成「云端书架全部不可用」
  ///       （那与实现不符，属虚假陈述，方向相反但同样是错）。
  static const List<String> afterExpiry = [
    '端侧学习数据（生词、复习进度、已导入的电子书）全部保留',
    // 🔴 2026-10-13 改写：原为「跨设备同步**停止** —— 两台设备不再互相更新」。
    //
    //    后端实际是**只拦上传、不拦下载**（`sync_pull` 现在只验登录，
    //    与「云端书架」的「下载放行、上传需订阅」**完全同构**）
    //    ⇒ 「停止」一词会让用户以为**云端数据取不回来**。
    //    ⚠️ 那不是假设 —— 实测到了：白哥 `690861018` 账号订阅被清空后，
    //      云端 **258 行**数据完好却一律 403，他看到的正是「**数据全没了**」。
    //    📌 判据：**降级文案不能比实际更吓人** —— 用户会据此决定要不要续订、
    //       甚至据此投诉。
    '云端数据仍可下载到本机，但本机新改动不再上传',
    '云端已备份的电子书仍可下载恢复，但不能再上传新书',
    '整段翻译回到免费额度（每月 10 次）',
    '不会丢失或锁定任何已积累的内容',
  ];
}

/// 「订阅是否有效」的**唯一判据** —— 端侧 StoreKit **或** 服务端对账值。
///
/// # 🔴 2026-10-09：由「端侧唯一权威」改为「端侧权威 + 服务端兜底」
///
/// 原架构是「`iapSnapshotProvider` 是权益的唯一判据，后端的 `subscriptionProvider`
/// 只用于对账展示」。那个设计在 **iOS 真机**上没问题，但它有一个**必然缺口**：
///
/// | 场景 | 端侧能判吗 | 结果 |
/// |---|---|---|
/// | iOS 真购买 | ✅ StoreKit `currentEntitlements` | 正常 |
/// | **安卓验证机** | ❌ 没有 StoreKit ⇒ `entitlement` 永远 `none` | 🔴 服务端明明有效，界面显示「未订阅」 |
/// | **后台授予 / 优惠赠送 / 人工开通** | ❌ 端侧无从知道 | 🔴 同上 |
/// | 换设备（同 Apple ID） | 🟠 需 `restore` 才拿得到 | 可能短暂显示未订阅 |
///
/// ⇒ 判据取 **OR**，并**向下取安全的一侧**：
///    · 端侧说有效 ⇒ 有效（端侧是权威，这是原设计的正确部分）
///    · 服务端说有效而端侧不知道 ⇒ **也有效**（否则就是「权益明明有，界面说没有」）
///    · 两端都无效 ⇒ 无效
///    ⚠️ 只有「端侧已过期、服务端还有效」这一格是 OR 特有的 ——
///       而那正是**对账值的含义**（服务端记录着还没到期的有效期），不是漏洞。
///
/// 📌 判据：**「端侧权威」不等于「端侧独占」** —— 权威说的是**谁说了算**，
///    不是**只能听谁**。端侧说了算，但端侧**答不上来的场合**必须有人兜底。
bool subscriptionActive({
  required bool iapActive,
  required bool backendActive,
}) =>
    iapActive || backendActive;

/// 到期日的**显示文案**（`YYYY-MM-DD`）—— 🔑 全库唯一的换算点。
///
/// # 为什么需要这个函数（而不是各页自己写）
///
/// 「有效期」有两个来源，两个都可能缺：
/// | 来源 | 形状 | 什么情况下缺 |
/// |---|---|---|
/// | 端侧 StoreKit | 精确时刻（UTC）| 安卓 / 商店不可用 |
/// | 服务端对账值 | `YYYY-MM-DD` | 未登录 / 还没 fetch |
///
/// 各页自己写就会出现两种口径（一个显示 `2027-10-09T00:00:00.000Z`、
/// 一个显示 `2027-10-09`），甚至一个显示一个不显示。
///
/// 🔑 取法：**端侧优先**（它更精确），退回服务端（它更持久）；
///    两者都没有 ⇒ 返回 `null`，调用方**不显示日期** ——
///    **不要**退回「今天」或空串（那是在编造一个日期）。
String? subscriptionExpiryLabel({
  required DateTime? iapExpiresAtUtc,
  required String? backendExpiresAt,
}) {
  if (iapExpiresAtUtc != null) {
    final d = iapExpiresAtUtc.toLocal();
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }
  final b = backendExpiresAt?.trim();
  if (b != null && b.isNotEmpty) return b;
  return null;
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 「**曾经订阅过、现在已失效**」—— 必须与「**从未订阅**」分开。
///
/// # 🔴 为什么不能直接用「不有效」当「已到期」
///
/// 本项目的**从未订阅**与**已到期**在数据上极像，但在用户眼里是两件事：
///
/// | 情形 | 用户的感受 | 该说什么 |
/// |---|---|---|
/// | 从未订阅 | 「我还没买」 | 说**价值**（`shortPitch`）|
/// | 曾订阅、已过期 | 「我的会员没了」 | 说**续订**（「会员已到期 · 续订后继续」）|
///
/// 而两端的「过期」标志都**包含**从未订阅：
/// · 服务端 `user_subscription_handler` 把 `subscription_expires IS NULL` 也算 `expired = true`
///   （`routes.rs:1147`）—— 所以那个 `expired` 只能用来判「**不**有效」，不能判「过期了」。
/// · 端侧 `IapEntitlementStatus.expired` 的语义**恰好**是「有购买记录且已过期」
///   （见 `resolveEntitlement`：从未购买 → `none`）⇒ 端侧这一侧可以直接用。
///
/// 🔑 所以判「曾订阅过」要靠**服务端有没有有效期记录**（`backendHasRecord`），
///    而不是靠它说没说 expired。
///    📌 判据：**「没生效」与「失效了」是两个状态** —— 用「取反」把两者混起来，
///       会给所有免费用户显示「你的会员已到期」（本项目最忌的**错误陈述**）。
bool subscriptionLapsed({
  required bool iapExpired,
  required bool backendHasRecord,
  required bool backendExpired,
}) =>
    iapExpired || (backendHasRecord && backendExpired);

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
///
/// # 🔴 2026-10-12 修正：`null` 分支由 `expired` 改为 `active`（fail-open）
///
/// **起因**（沙盒首测实测）：[`IapService`] 的 `_parseExpiry` 曾**硬编码返回 null**
/// ⇒ 「null + 有购买史」落进 `expired` ⇒ **端侧权益判定恒为「已到期」** ⇒
///   ① 「订阅已到期」覆盖层对所有买过的用户**必弹**
///   ② 「端侧权威」设计原则**从未生效**（`isActive` 恒 false，一直靠服务端对账单腿走路）
///       ⇒ 未登录购买（我们明确支持）会「付了钱却看不到权益」
///
/// 🔑 那次 bug 的教训不是"null 判错了"，而是**注释与实现相反**：
///    `_parseExpiry` 的注释写着「判为『有购买史』……**足以让 UI 先解锁**」，
///    而实现判的是 `expired`（已到期）。**意图是 fail-open，实现是 fail-closed。**
///
/// 现在语义收敛为一句：**「不知道」不等于「已过期」** ——
///    · 读到到期日且在未来 ⇒ `active`
///    · 读到到期日且已过去 ⇒ `expired`（这才是真正的过期）
///    · **读不到**（异常分支）⇒ `active`（与上面注释的原始意图一致）
///      · 理由 1：**买了的人被误报"已过期"，比没买的人多看一眼内容严重得多**
///        （前者是付费用户的糟糕体验，后者服务端对账会纠正）
///      · 理由 2：符合本模块「购买/恢复成功后立刻解锁，不等服务端」的硬规则 ②
///      · ⚠️ 前提：正常路径下 [`parseStoreKitExpiryMillis`] 一定读得到日期，
///        所以这一支只在**解析失败**时才走到 —— 不是常规路径。
IapEntitlementStatus resolveEntitlement({
  required DateTime? expiresAtUtc,
  required bool hasAnyPurchase,
  required DateTime nowUtc,
}) {
  if (expiresAtUtc == null) {
    // 「不知道到期时间」：有购买史 ⇒ 倾向已购（fail-open）；没购买史 ⇒ 从未订阅。
    return hasAnyPurchase
        ? IapEntitlementStatus.active
        : IapEntitlementStatus.none;
  }
  return expiresAtUtc.isAfter(nowUtc)
      ? IapEntitlementStatus.active
      : IapEntitlementStatus.expired;
}

/// 解析 StoreKit 给的**订阅到期时间**（毫秒时间戳字符串）→ UTC `DateTime`。
///
/// # 为什么是纯函数（放在这里而不是 `iap_service.dart`）
///
/// `iap_service.dart` import 了 Flutter 插件 ⇒ **本机无法验证**（`flutter` 不可用）。
/// 而「字符串 → 时间」是**最容易写错的一类转换**（单位差 1000 倍 ⇒ 日期偏到 1970 或 5 万年），
/// 所以把它下沉到本文件，由 `iap_verify` 直接覆盖。
/// 📌 判据：**把能验证的尽量下沉**，别让不可验证的层承担正确性。
///
/// [millis] 来自 `SK2PurchaseDetails.expirationDate`（插件已把 Apple 的秒转成毫秒）。
/// 非订阅商品 / StoreKit 1 / 字段缺失 ⇒ 传 null ⇒ 返回 null（调用方按「不知道」处理）。
DateTime? parseStoreKitExpiryMillis(String? millis) {
  final s = millis?.trim();
  if (s == null || s.isEmpty) return null;
  final ms = int.tryParse(s);
  if (ms == null || ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// 这份**端侧权益**是否算作**当前 App 账号**的。
///
/// # 🔴 2026-10-12 为什么需要它（白哥多账号实测）
///
/// 换账号后（`123@qq.com`）「我的」页仍显示 **「订阅中 · 到期日 2026-10-13」**，
/// 而同屏云朵胶囊写着「同步失败」（服务端对同步接口回 **403 未订阅**）。
///
/// **根因**：「订阅」被一个布尔值表达了，但它其实有**两层不同归属**的权益：
///
/// | 层 | 归属 | 内容 |
/// |---|---|---|
/// | 端侧 IAP | **Apple ID**（沙盒 Apple 账户）| 本机的 StoreKit 购买 |
/// | 服务端订阅 | **我们的 `user_id`** | 跨设备同步 / 云端书架 / 翻译额度 |
///
/// 原判据 `subscriptionActiveNow = 端侧.isActive || 服务端.isActive` 把两层 OR 起来
/// ⇒ 只要任一层为真就认为「有全部权益」⇒ **一个不可用的能力被显示成可用**
/// （卡片说订阅中，同步却 403）。
///
/// # 🔴🔴 规则（2026-10-12 晚间 · 白哥定案：**订阅与账号一一绑定**）
///
/// > 白哥原话：「**订阅肯定要先登录，才能保证用户的订阅跟着账号走，
/// > 订阅与账号一一绑定**」。
///
/// 这**推翻**了本文件当天早些时候那版「不强制登录、靠服务端对账兜底」的口径：
///
/// | 版本 | 未登录能买吗 | 无绑定交易怎么算 |
/// |---|---|---|
/// | 早先（10-04 决策）| ✅ 能（StoreKit 走 Apple ID）| 未登录时算（"本机权益"）|
/// | **现在**（10-12 白哥定）| ❌ **不能**（购买/恢复前必须先登录）| **一律不算** |
///
/// ## 为什么「无绑定 ⇒ 一律不算」是**安全**的
///
/// 因为**新设计下「无绑定」根本不该产生**：购买前必须先登录 ⇒
/// `IapService.buy()` 里 `applicationUserName` 必非 null ⇒ 交易必带绑定
/// （`IapService.buy` 还有一条硬拦截，见那里）。
/// ⇒ 所以 `ownerUserId == null` 只可能是三种**异常残留**：
/// ① 旧版本未登录时买的（早先口径）｜② StoreKit 1 路径（无 `appAccountToken` 字段）
/// ｜③ 端侧解析失败。三者都**不该**给出权益 —— 由**服务端对账**决定归属。
///
/// ⚠️ 代价（如实记录）：StoreKit 1 / 解析失败的**正常已登录**购买，端侧会短暂不认领，
///    需等服务端回填（网络差时表现为「买完先显示未订阅，几秒后变成订阅中」）。
///    📌 取舍：**宁可慢一拍，也不能把付款权益给错人** —— 这正是白哥这次定的方向。
///
/// 📌 注意：本函数**不改变**端侧状态本身（`IapSnapshot` 照旧保留它的权益）——
///    它只在**消费点**决定"这份权益算不算你的"。
///    ⇒ 与既有判据「登出**不**复位端侧 IAP（它是 Apple ID 级）」**并不冲突**：
///       我们不复位它，只是不把它**算给任何账号**（直到有绑定为止）。
bool iapEntitlementBelongsToAccount({
  required String? ownerUserId,
  required String? currentUserId,
}) {
  /// 🔴 **无绑定 ⇒ 一律不算**（含未登录态）—— 见上面「为什么安全」。
  if (ownerUserId == null) return false;
  return ownerUserId == currentUserId;
}

/// 降级提示（订阅到期后展示）。
///
/// 🔴 与规格一致：**保留全部资产**（生词可读/可复习/可发音 · 学习记录 · 已导入电子书）。
///    所以文案**不能**说「生词本已锁定」——那与实现不符（属虚假陈述）。
///
/// # 🔴🔴 2026-10-05 修正：删掉末句两处**已废止的事实**
///
/// 原文末句是「…；**新增生词（超过 200 词上限）**与**文章朗读**需要续订」—— **两句都不成立**：
///
/// | 原文 | 为什么不成立 |
/// |---|---|
/// | 「新增生词（超过 **200 词上限**）需要续订」 | 该上限 **2026-10-01 已废止**（白哥定「免费全量」，`kUserWordLimitFree` / `enforceLimit` / `limitReached` 已全部删除）⇒ 免费版新增生词**没有上限**，与订不订阅无关 |
/// | 「**文章朗读**需要续订」 | 朗读**已免费全量**（含词卡、电子书整章）· 订阅权益 2026-10-04 已改**跨设备同步** |
///
/// ⚠️ **所以现在没有任何「需要续订」的功能**（如实标注，不编一句出来凑）：
///    唯一的订阅权益「跨设备同步」**后端尚未实现**
///    （见 `docs/design/sync-implementation-assessment-2026-10-04.md`）
///    ⇒ 此时写「XX 需要续订」**就是虚假陈述**。
///    📌 这是本文件 `benefits` 那条注释同一条判据的应用：
///       **文案必须与「已实现的能力」逐一对应。**
///    ⏳ 同步上线后，在这里补一句「跨设备同步需要续订」即可（届时**同改本函数 + 断言**）。
///
/// # 📌 这两处为什么能藏这么久（值得记）
///
/// 因为 `scripts/iap_verify` 里那两条断言当时是**正向**的：
/// ```dart
/// check('提到 200 词上限', down.contains('200'));            // ← 要求它保留过时事实
/// check('提到文章朗读受限', down.contains('文章朗读'));      // ← 同上
/// ```
/// ⇒ 这不是「断言太松」，而是**「断言保护了错误」**：门禁**主动要求**文案保持过时，
///   改对了反而会红 ⇒ 下一次「修红」会把错误**再改回来**。
/// ✅ 本次已把这两条**反转为反向断言**（不得出现这两个过时事实），
///   并补两条**语义**正向断言（锁「说了什么」，不锁具体字词）。
String downgradeNotice() => '会员已到期。你的生词、学习记录与已导入的电子书都已保留，'
    '仍可正常查看与复习；云端已同步的数据也仍可下载回本机。';

/// 「我的」页的版本标签。
String versionLabel(bool isActive) => isActive ? '订阅版' : '免费版';

/// 订阅页**购买按钮**的文案与可用性 —— 全库唯一判定点（UI 只负责画）。
///
/// # 🔴 为什么下沉成纯函数
///
/// 本文件零 import ⇒ 能跑完整类型检查与断言（见文件头）；而 `subscribe_screen.dart`
/// import 了 Flutter ⇒ **本机验不了**。而「未登录时按钮说什么、能不能点」恰恰是
/// 2026-10-12 白哥定案「**订阅必须先登录**」的**落点** ⇒ 必须可断言。
/// 📌 判据：**把能验证的尽量下沉** —— 关键判定不要留在不可验证的 UI 层。
///
/// # 优先级（自上而下，**先满足的先生效**）
///
/// | # | 条件 | 文案 | 可点 |
/// |---|---|---|---|
/// | ① | 购买中 | `处理中…` | ❌ |
/// | ② | 商店不可用 | `当前无法连接 App Store` | ❌ |
/// | ③ | 未选档位 | `请先选择订阅方式` | ❌ |
/// | ④ | **未登录** | `登录并订阅 · ¥X` | ✅（点了**先登录、再购买**）|
/// | ⑤ | 正常 | `立即订阅 · ¥X` | ✅ |
///
/// 🔑 ③ 在 ④ 之前：**先让用户把档位选出来**，否则登录完还要再选一次，
///    会有"点了个按钮却弹登录、登完不知道自己在买什么"的断裂感。
///    （§4.4.2「不得默认勾选」⇒ 未选时必须停在这里。）
///
/// 🔑 ④ 的按钮**是可点的**（不是 disabled）—— 若不可点，用户会以为
///    「这个 app 坏了/买不了」；可点 + 弹登录 = 有明确出口。
///    📌 判据：**「静默失败 + 无出口」比报错更糟**。
///
/// [priceLabel] 传 `null` 表示**还没选档位**（不是"价格未知"）。
({String label, bool enabled}) purchaseButtonState({
  required bool busy,
  required bool unavailable,
  required String? priceLabel,
  required bool signedIn,
}) {
  if (busy) return (label: '处理中…', enabled: false);
  if (unavailable) return (label: '当前无法连接 App Store', enabled: false);
  if (priceLabel == null) return (label: '请先选择订阅方式', enabled: false);
  if (!signedIn) return (label: '登录并订阅 · $priceLabel', enabled: true);
  return (label: '立即订阅 · $priceLabel', enabled: true);
}

/// 「恢复购买」的结果 —— 供 UI 决定提示文案。
///
/// 🔑 为什么要有这个枚举（而不是只更新状态）：`ui-ux §4.4.3` 明确要求
///    「成功则提示『已恢复』；**无记录则提示**（与成功**不同**的一句话）」——
///    而 StoreKit 不会告诉你「恢复结束了、但一条记录都没有」。
///
/// 🔴 2026-10-12 晚：**本枚举由 `iap_service.dart` 移到本文件** ——
///    它现在要驱动文案映射（见 [restoreOutcomeMessage]），而文案**必须可断言**
///    （`iap_service.dart` import 了 Flutter 插件 ⇒ 本机验不了，见文件头）。
///    它本来就与 [IapEntitlementStatus] 同族：**纯状态枚举、零依赖**。
///    📌 判据：**把能验证的尽量下沉**。
enum RestoreOutcome {
  /// 恢复到了有效订阅
  restored,

  /// 调用成功，但**当前账号**名下没有有效订阅
  notFound,

  /// 调用抛异常
  failed,

  /// 商店不可用（没连上 / 设备不支持）
  unavailable,

  /// 🆕 2026-10-21：**本账号当前已是订阅状态**（由服务端记录确认）⇒ 不需要恢复。
  ///
  /// # 🔴 为什么必须单独一态（白哥 2026-10-21 真机实测）
  ///
  /// 页面顶部明明写着「订阅中 · 到期日 2026-11-20」，点「恢复购买」却弹
  /// **「当前账号未找到订阅」** —— 两句话自相矛盾。
  ///
  /// 根因：**「有没有订阅」与「StoreKit 恢复到了什么」是两件不同的事**。
  /// · 页面用 `subscriptionActiveNow`（端侧 **OR** 服务端）
  /// · 恢复只看端侧 `currentEntitlements`（**服务端不算**）
  ///
  /// 而本项目确实存在「服务端有效、端侧查不到」的合法情形：
  /// Apple 沙盒订阅的自动续期**最多 6 次**，用尽后 StoreKit 里就没有有效项了，
  /// 但服务端记录仍然是 active（人工开通 / 后台调整同理）。
  ///
  /// 📌 判据：**给用户的结论不能互相打脸**。
  ///    「恢复购买」是给**没有权益**的人用的；已经有权益时应该直接告诉他已经有了，
  ///    而不是否认他屏幕上看到的事实。
  alreadyActive,
}

/// 「恢复购买」四种结果 → **用户可见文案** —— 全库唯一事实源。
///
/// # 🔴 为什么 `notFound` 不能只说「未找到订阅记录」（2026-10-12 白哥定）
///
/// 订阅**与账号一一绑定**（同日定案）⇒ 「没找到」有**两种成因**，
/// 而旧文案只描述了第一种：
///
/// | 成因 | 用户该做什么 | 旧文案够用吗 |
/// |---|---|---|
/// | ① 这个 Apple ID 名下确实没买过 | 无需操作 | ✅ |
/// | ② 订阅在**另一个 App 账号**上（同一设备、同一个 Apple ID） | **切回那个账号** | ❌ 用户会以为「我的订阅丢了」 |
///
/// 📌 判据：**「没找到」的原因，要说到用户能自己解决为止** ——
///    否则就是本项目最忌的「**静默失败 + 无出口**」。
///
/// 🔑 两处调用点（订阅页 / 「我的」页）**必须都走这个函数**：
///    同一句话在两处各写一遍必然漂 —— 此前正是各写了一份 `switch`。
String restoreOutcomeMessage(RestoreOutcome outcome) => switch (outcome) {
      RestoreOutcome.restored => '已恢复订阅',
      RestoreOutcome.notFound =>
        '当前账号未找到订阅。如果你曾在另一个账号订阅过，请切回该账号查看。',
      RestoreOutcome.failed => '恢复购买失败，请稍后重试',
      RestoreOutcome.unavailable => '当前无法连接 App Store',
      // 🔴 不能再说「未找到」—— 用户屏幕上正写着「订阅中」
      RestoreOutcome.alreadyActive => '你当前已是订阅状态，无需恢复。',
    };

/// 「恢复购买」结束时的**结果判定** —— 全库唯一判据。
///
/// # 🔴 为什么必须有它（2026-10-13 白哥实测：提示「已恢复」但仍是未订阅）
///
/// 原先 `IapService.restore()` 直接判 `_snapshot.entitlement == active`，
/// 而 UI 的「订阅中」走 `iapProvider.subscriptionActiveNow`（**带归属过滤** + 服务端侧）
/// ⇒ 只要出现「**收到了交易、但归属不是当前账号**」，就必然产出
/// **「提示已恢复」+「界面显示未订阅」**这一对自相矛盾的输出。
///
/// 典型触发场景：**注销账号后重新登录** —— Apple 重放/续期的交易上仍写着
/// **已注销的旧 userId**（`appAccountToken` 由 Apple 签，我们改不掉）。
///
/// ⇒ 本函数把**归属过滤**并进来，成为唯一判据：
///    只有「有效 **且** 属于当前账号」才算 [RestoreOutcome.restored]。
///
/// 📌 判据：**同一件事的口径只能有一处权威**。
///
/// ⚠️ 服务端那一侧（`subscriptionProvider.isActive`）不在此函数视野内
///    （service 层拿不到）—— 但服务端认领后会把**权威到期日**回传，
///    `IapService` 随即 `applyServerExpiry(..., ownerUserId: 当前账号)`
///    把归属**改写成当前账号** ⇒ 下一次判定自然为 `restored`。
///    （端侧因此**不需要**知道服务端状态，判据仍是单入口。）
///
/// ⚠️ 未登录（`currentUserId == null`）时沿用既有语义：
///    无绑定的交易算「本机权益」；有绑定的交易不算（交给服务端对账）。
RestoreOutcome judgeRestoreOutcome({
  required IapEntitlementStatus entitlement,
  required String? ownerUserId,
  required String? currentUserId,
  // 🆕 2026-10-21：调用方（UI）把「本账号当前是否已有效」传进来。
  //
  // 🔴 为什么由调用方传而不是本函数自己查：本函数是**纯函数**（零依赖、可断言），
  //    查订阅状态需要 Riverpod 容器 ⇒ 会把它拖进 Flutter 依赖（同文件头的取舍）。
  //    而「谁最适合算这个」有唯一答案：UI 上显示「订阅中/未订阅」的那一处
  //    （`subscriptionActiveNow`）——**同一个判据，不要算两遍**。
  bool alreadyActive = false,
}) {
  // 🔴 先判「已经是订阅状态」——
  //    否则会出现「页面写着订阅中、点恢复却说未找到」这种自相矛盾的输出
  //    （2026-10-21 白哥真机实测）。Apple 沙盒续期用尽后「服务端有效、端侧查不到」
  //    就是这种情形的标准样本。
  if (alreadyActive) return RestoreOutcome.alreadyActive;
  final usable = entitlement == IapEntitlementStatus.active &&
      iapEntitlementBelongsToAccount(
        ownerUserId: ownerUserId,
        currentUserId: currentUserId,
      );
  return usable ? RestoreOutcome.restored : RestoreOutcome.notFound;
}

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
