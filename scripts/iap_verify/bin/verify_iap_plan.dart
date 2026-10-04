// ════════════════════════════════════════════════════════════════════════
// CoEvo · IAP 订阅纯逻辑验收
// ════════════════════════════════════════════════════════════════════════
//
// 跑法：cd scripts/iap_verify && dart run bin/verify_iap_plan.dart
//
// # 为什么需要它
// 本机 **`flutter analyze` / `flutter test` 不可用**
// （`CreateFile failed 231：所有的管道范例都在使用中`）⇒ UI 层无法本地验证。
// 但 IAP 的正确性**大部分不在 UI**：产品 ID 契约、价格换算、法定文案、状态判定
// 都是纯逻辑 ⇒ 把它们下沉到零 import 的 `iap_plan.dart`，这里用 `dart run` 验。
//
// # 🔴 本脚本的证伪方式（**必须做过才敢说它有效**）
// · 把 `app/lib/services/iap_plan.dart` 的 `kProductMonthly` 改一个字符
//   → 「三处一致」必须变红
// · 把 `SubscriptionLegalText.autoRenewNotice` 里的「自动续期」删掉
//   → 「法定要件」必须变红
//
// # 期望值来源（**独立**于被测代码）
// 产品 ID 的「后端值」是**从 `iap_handlers.rs` 文件里读出来的**，
// 不是在本脚本里再手写一遍 —— 否则只是「抄了两遍」而非交叉验证。

import 'dart:io';

import '../../../app/lib/services/iap_plan.dart';

var _pass = 0;
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

void _report() {
  print('');
  print('─' * 74);
  if (_failures.isEmpty) {
    print('🎉 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 共 ${_pass + _failures.length} 项');
    for (final f in _failures) {
      print('    · $f');
    }
    exitCode = 1;
  }
}

/// 从后端 `iap_handlers.rs` 里**读**某个常量的值。
///
/// 🔑 为什么读文件而不是 import：后端是 **Rust**，Dart 无法 import。
///    ⇒ 只能解析源码。这是**跨语言契约**唯一可行的交叉验证方式。
String? _readRustConst(String source, String constName) {
  final m = RegExp(
    'pub const $constName:\\s*&str\\s*=\\s*"([^"]+)"',
  ).firstMatch(source);
  return m?.group(1);
}

void main() {
  print('');
  print('#' * 74);
  print('# IAP 订阅 · 纯逻辑验收');
  print('#' * 74);

  // ────────────────────────────────────────────────────────────────
  // ① 产品 ID 三处一致（前端常量 ↔ 后端常量）
  // ────────────────────────────────────────────────────────────────
  print('\n[①] 产品 ID 契约（前端 ↔ 后端）');

  final rustFile = File('../../backend/crates/api_server/src/iap_handlers.rs');
  if (!rustFile.existsSync()) {
    check('能读到后端 iap_handlers.rs', false, rustFile.path);
    _report();
    return;
  }
  final rust = rustFile.readAsStringSync();

  final beMonthly = _readRustConst(rust, 'PRODUCT_MONTHLY');
  final beYearly = _readRustConst(rust, 'PRODUCT_YEARLY');
  final beBundle = _readRustConst(rust, 'BUNDLE_ID');

  check('后端 PRODUCT_MONTHLY 可解析', beMonthly != null, beMonthly ?? '解析失败');
  check('后端 PRODUCT_YEARLY 可解析', beYearly != null, beYearly ?? '解析失败');
  check('后端 BUNDLE_ID 可解析', beBundle != null, beBundle ?? '解析失败');

  if (beMonthly != null && beYearly != null) {
    final problems = checkProductIdsMatchBackend(
      backendMonthly: beMonthly,
      backendYearly: beYearly,
    );
    check('前端产品 ID 与后端一致', problems.isEmpty, problems.join(' / '));
  }

  if (beBundle != null) {
    check('前端 bundleId 与后端一致', kBundleId == beBundle, '$kBundleId vs $beBundle');
    // 🔑 产品 ID 必须**以 bundleId 为前缀** —— 这是 Apple 的命名惯例，
    //    也是「一眼能看出属于哪个 App」的保障。写死检查能防「手误打错前缀」。
    for (final p in kKnownProductIds) {
      check('产品 ID 以 bundleId 为前缀：$p', p.startsWith('$kBundleId.'), p);
    }
  }

  check('已知产品 ID 恰好 2 个', kKnownProductIds.length == 2, '${kKnownProductIds.length}');
  check('isKnownProductId 认得月度', isKnownProductId(kProductMonthly));
  check('isKnownProductId 认得年度', isKnownProductId(kProductYearly));
  // 反向：相似但不相同的串必须被拒（防「前缀匹配」式假通过）
  check('拒绝相似串（多的后缀）', !isKnownProductId('${kProductMonthly}.x'));
  check('拒绝相似串（截断）', !isKnownProductId('com.coevo.coevoApp.pro'));
  check('拒绝空串', !isKnownProductId(''));

  // ────────────────────────────────────────────────────────────────
  // ② 价格格式化
  // ────────────────────────────────────────────────────────────────
  print('\n[②] 价格格式化（分 → 显示串）');

  check('990 分 → ¥9.9', formatYuan(990) == '¥9.9', formatYuan(990));
  check('7800 分 → ¥78', formatYuan(7800) == '¥78', formatYuan(7800));
  check('128000 分 → ¥1280', formatYuan(128000) == '¥1280', formatYuan(128000));
  check('100 分 → ¥1', formatYuan(100) == '¥1', formatYuan(100));
  check('1005 分 → ¥10.05', formatYuan(1005) == '¥10.05', formatYuan(1005));
  check('0 分 → ¥0', formatYuan(0) == '¥0', formatYuan(0));
  // 🔴 负数不该出现 —— 断言被兜住，而不是输出「¥-1」
  check('负数兜底为 ¥0', formatYuan(-500) == '¥0', formatYuan(-500));

  // ────────────────────────────────────────────────────────────────
  // ③ 折扣计算
  // ────────────────────────────────────────────────────────────────
  print('\n[③] 年付折扣');

  // 月 9.9 × 12 = 118.8；年 78 → 省 40.8 → 34.3% → 34%
  final pct = yearlyDiscountPercent(monthlyFen: 990, yearlyFen: 7800);
  check('月 9.9 / 年 78 → 折扣可算', pct != null, '$pct');
  check('折扣落在 33–35% 区间（规格称 34%）', pct != null && pct >= 33 && pct <= 35, '$pct%');

  // 🔑 「没有折扣」必须返回 null（而不是 0）—— 否则 UI 会显示「省 0%」
  check('年付不比月付划算 → null（不显示角标）',
      yearlyDiscountPercent(monthlyFen: 990, yearlyFen: 12000) == null);
  check('年付更贵 → null', yearlyDiscountPercent(monthlyFen: 990, yearlyFen: 99999) == null);
  check('零价 → null（防除零）', yearlyDiscountPercent(monthlyFen: 0, yearlyFen: 0) == null);
  check('负价 → null', yearlyDiscountPercent(monthlyFen: -1, yearlyFen: -1) == null);

  // ────────────────────────────────────────────────────────────────
  // ④ 展示模型：价格来源优先级
  // ────────────────────────────────────────────────────────────────
  print('\n[④] 展示模型（StoreKit 价格优先于本地兜底）');

  final noStore = defaultPlans();
  check('无 StoreKit 价 → 用兜底 990', noStore[0].fallbackFen == 990, '${noStore[0].fallbackFen}');
  check('无 StoreKit 价 → 用兜底 7800', noStore[1].fallbackFen == 7800, '${noStore[1].fallbackFen}');
  check('无 StoreKit 价 → 标记 usingFallbackPrice', noStore[0].usingFallbackPrice);
  check('无 StoreKit 价 → 显示兜底串', noStore[0].priceLabel == '¥9.9', noStore[0].priceLabel);

  final withStore = defaultPlans(monthlyStorePrice: '¥9.90', yearlyStorePrice: '¥78.00');
  check('有 StoreKit 价 → 优先显示它', withStore[0].priceLabel == '¥9.90', withStore[0].priceLabel);
  check('有 StoreKit 价 → 不再标记兜底', !withStore[0].usingFallbackPrice);
  // 🔑 关键：有 StoreKit 价时，**不能**再显示本地兜底价（两个价并存会误导用户）
  check('有 StoreKit 价 → 不显示本地价', withStore[1].priceLabel != '¥78', withStore[1].priceLabel);

  check('两档产品 ID 正确', noStore[0].productId == kProductMonthly && noStore[1].productId == kProductYearly);
  check('时长标签：1 个月', noStore[0].durationLabel == '1 个月', noStore[0].durationLabel);
  check('时长标签：1 年', noStore[1].durationLabel == '1 年', noStore[1].durationLabel);

  // ────────────────────────────────────────────────────────────────
  // ⑤ 🔴 法定要件文案（Apple 3.1.2 —— 缺了会被拒审）
  // ────────────────────────────────────────────────────────────────
  print('\n[⑤] 法定要件文案');

  final notice = SubscriptionLegalText.autoRenewNotice(
    title: 'CoEvo 专业版',
    durationLabel: '1 个月',
    priceLabel: '¥9.9',
  );
  // 🔑 断言「关键词存在」而不是「整句相等」—— 文案可以润色，
  //    但**法定要素不能丢**。这是「锁语义形状、不锁拼写」的用法。
  check('含标题', notice.contains('CoEvo 专业版'));
  check('含时长', notice.contains('1 个月'));
  check('含价格', notice.contains('¥9.9'));
  check('🔴 含「自动续期」字样', notice.contains('自动续期'));
  check('🔴 含「24 小时」取消窗口', notice.contains('24 小时'));

  check('🔴 续费扣款说明非空且提 Apple 账户', SubscriptionLegalText.renewalCharge().contains('Apple'));
  check('🔴 取消方式提到「订阅」设置',
      SubscriptionLegalText.howToCancel().contains('订阅') &&
          SubscriptionLegalText.howToCancel().contains('取消'));

  // ── 权益必须与我们**实际实现的能力**一致（不能写未实现的能力）──────────
  //
  // 🔴🔴 2026-10-04 重大修正：这一组断言原来**在保护错误**。
  //
  //    原文断言「权益含无限生词本」「免费版说明含 200 词上限」——
  //    而这两件事都已在 **2026-10-01 作废**（白哥定：上限取消，免费全量使用）。
  //    ⇒ 后果很严重：**改了正确的事实反而变红** ⇒ 于是没人敢改，
  //      错误文案就被断言「合法化」了（订阅页上真的这么写了）。
  //    📌 判据（本轮新增）：**断言必须与被断言的「事实」同步演进**；
  //      事实作废后，断言要**反向** —— 从「断言它存在」改为「断言它不再出现」。
  //
  // 🔑 同时**不再锁「权益条数」** —— 太死（增减权益都要改断言 ⇒ 假红）。
  //    改为锁**语义**：非空 + 不得含已作废 / 未实现的能力。
  final b = SubscriptionLegalText.benefits;
  check('权益非空', b.isNotEmpty, '权益列表为空 —— 订阅页没有可说的价值主张');

  // 🔴 四条反向断言：这些**都不能**出现在权益里
  check(
    '🔴 不含「无限生词本」（免费版已无上限，2026-10-01 取消）',
    !b.any((e) => e.contains('无限生词本')),
    '它已不是「订阅才有」的能力 —— 写它就是虚假宣传',
  );
  check(
    '🔴 不含「文章朗读」（零实现，不得作权益宣传）',
    !b.any((e) => e.contains('文章朗读')),
    '阅读器里没有朗读入口（只有词卡的喇叭）⇒ 写它就是承诺未实现',
  );
  check(
    '🔴 不含「电子书导入」（已定为免费能力）',
    !b.any((e) => e.contains('电子书导入')),
  );
  check(
    '🔴 不含「语音包」（2026-09-26 已取消）',
    !b.any((e) => e.contains('语音包')),
  );

  // 🔴 免费版说明**不得**再提 200 词上限 —— 那个限制不存在了，说了就是假话
  check(
    '🔴 免费版说明不含「200」（上限已取消）',
    !SubscriptionLegalText.freeTierNote().contains('200'),
    SubscriptionLegalText.freeTierNote(),
  );
  check(
    '免费版说明点出「不设数量限制」（§4.4.1 判据 2：免费层如实展示）',
    SubscriptionLegalText.freeTierNote().contains('数量限制'),
  );

  // ── 折叠区（补充说明 · 非要点故可折叠）──────────────────────────────
  check('免费版包含清单非空', SubscriptionLegalText.freeIncludes.isNotEmpty);
  check('到期后行为清单非空', SubscriptionLegalText.afterExpiry.isNotEmpty);
  check(
    '🔴 到期后**不没收资产**（§4.4.4 原则：词可读可复习、电子书保留）',
    SubscriptionLegalText.afterExpiry.any((e) => e.contains('保留')),
  );

  // ── 价格周期标注（§5.2：把两档拉到**同一量纲**才可比）───────────────
  final plansForPeriod = defaultPlans();
  check(
    '月付标注「每月自动续期」',
    plansForPeriod[0].periodLabel.contains('每月'),
    plansForPeriod[0].periodLabel,
  );
  check(
    '年付折算成「≈ ¥X / 月」（同一量纲，一眼可比）',
    plansForPeriod[1].periodLabel.contains('/ 月'),
    plansForPeriod[1].periodLabel,
  );
  // 🔑 折算**只在本地兜底价**下做 —— 拿 StoreKit 的本地化串（可能是 $/€）
  //    去算人民币会自相矛盾（「价格 $99.99，下面写 ≈ ¥6.5/月」）
  check(
    '非兜底价的年付 → 不折算（避免货币自相矛盾）',
    defaultPlans(yearlyStorePrice: r'$99.99')[1].periodLabel == '每年自动续期',
    defaultPlans(yearlyStorePrice: r'$99.99')[1].periodLabel,
  );

  // ────────────────────────────────────────────────────────────────
  // ⑥ 订阅状态判定
  // ────────────────────────────────────────────────────────────────
  print('\n[⑥] 订阅状态判定');

  final now = DateTime.utc(2026, 10, 4, 12);

  check(
    '未来到期 → active',
    resolveEntitlement(
          expiresAtUtc: now.add(const Duration(days: 5)),
          hasAnyPurchase: true,
          nowUtc: now,
        ) ==
        IapEntitlementStatus.active,
  );
  check(
    '过去到期且有购买史 → expired',
    resolveEntitlement(
          expiresAtUtc: now.subtract(const Duration(days: 1)),
          hasAnyPurchase: true,
          nowUtc: now,
        ) ==
        IapEntitlementStatus.expired,
  );
  check(
    '无到期时间且无购买史 → none',
    resolveEntitlement(expiresAtUtc: null, hasAnyPurchase: false, nowUtc: now) ==
        IapEntitlementStatus.none,
  );
  check(
    '无到期时间但有购买史 → expired（不是 none）',
    resolveEntitlement(expiresAtUtc: null, hasAnyPurchase: true, nowUtc: now) ==
        IapEntitlementStatus.expired,
  );
  // 🔴 边界：**恰好等于** now —— 不算有效（用 isAfter 而非 isAtSameMomentAs）
  check(
    '到期时刻恰好 == now → 不算 active',
    resolveEntitlement(expiresAtUtc: now, hasAnyPurchase: true, nowUtc: now) !=
        IapEntitlementStatus.active,
    '边界必须偏保守：不能多送一瞬',
  );

  // ────────────────────────────────────────────────────────────────
  // ⑦ 降级文案与实现一致
  // ────────────────────────────────────────────────────────────────
  print('\n[⑦] 降级文案（须与「保留全部生词」的实现一致）');

  final down = downgradeNotice();
  check('含「保留」', down.contains('保留'));
  // 🔴 反向断言：不能说「生词本已锁定」—— 实现是「保留可读可复习，仅冻结新增」
  check('🔴 不含「锁定」字样（与实现不符）', !down.contains('锁定'), down);
  check('提到 200 词上限', down.contains('200'));
  check('提到文章朗读受限', down.contains('文章朗读'));

  check('有效 → 订阅版', versionLabel(true) == '订阅版');
  check('无效 → 免费版', versionLabel(false) == '免费版');

  // ────────────────────────────────────────────────────────────────
  // ⑧ 🔴 订阅页 / 「我的」页的**法定要件**（源级断言）
  // ────────────────────────────────────────────────────────────────
  //
  // ⚠️ 为什么这里用**源级检查**（而不是符号解析）：
  //    这几条守的是「**内容存在性**」—— 文案里有没有「自动续期」、
  //    有没有引用那两个法律链接常量。**符号解析看不到字符串内容**。
  //
  // 📌 边界如实说明（不夸大）：它只能证明「代码里出现了这个调用」，
  //    **不能**证明「运行时真的渲染出来了」（那需要 widget 测试，本项目暂无）。
  //    ⇒ 它的价值是：**谁删掉法定要件，CI 就红** —— 这正是要防的。
  //
  // 🔴 已证伪：把 `subscribe_screen.dart` 里 `autoRenewNotice` 这一处调用删掉
  //    → 本组对应断言变红、退出码 1。
  print('\n[⑧] 法定要件（订阅页 / 「我的」页）');

  String readApp(String rel) {
    final f = File('../../app/lib/$rel');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  /// 去掉**整行注释**后的源码。
  ///
  /// 🔴 为什么必须去注释再断言（否则两边都会错）：
  ///    · **正向**（如「有 autoRenewNotice」）会命中**注释里的提及** ⇒ **假绿** ——
  ///      本项目的历史说明大量写在整行 `///` 注释里（本轮改造正是如此）
  ///    · **反向**（如「无『请联系服务人员』」）会命中**注释里的引用** ⇒ **假红** ——
  ///      实际第一次跑就撞上了（注释在解释「这句已删掉」）
  ///    📌 判据：**注释里提到 ≠ 代码里写了**；且**断言的范围必须等于被测对象的范围**。
  ///
  /// ⚠️ 保守实现：只跳过「trimLeft 后以 `//` 开头」的行，**不处理行内注释**
  ///    （那需要完整词法分析，且会误伤字符串里的 `//`）。
  ///    对本用途足够 —— 本项目的历史说明都写在**整行**注释里。
  String codeOnly(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final subscribeCode = codeOnly(readApp('screens/subscribe_screen.dart'));
  check('订阅页文件存在', subscribeCode.isNotEmpty, 'screens/subscribe_screen.dart');

  if (subscribeCode.isNotEmpty) {
    // ── §4.4.2 自动续费披露（法定）──
    //
    // ⚠️ 断言都带 **`(`** —— 不带的话 `autoRenewNotice` 会被 `autoRenewNoticeX`
    //    前缀命中（**假绿**）。📌 判据：**断言锁「语义形状」不锁「拼写」，
    //    但也不能松到「一个更长的名字也满足」**。
    check(
      '🔴 有按档位的自动续费披露',
      subscribeCode.contains('SubscriptionLegalText.autoRenewNotice('),
    );
    check(
      '🔴 有「未选档位时」的通用续费说明（接受服务前就要提示）',
      subscribeCode.contains('autoRenewNoticeGeneric('),
    );
    check('🔴 有续费扣款说明', subscribeCode.contains('renewalCharge('));
    check('🔴 有取消路径说明（Apple ID 设置）', subscribeCode.contains('howToCancel('));
    check('🔴 有隐私政策链接', subscribeCode.contains('kPrivacyPolicyUrl'));
    check('🔴 有用户协议链接', subscribeCode.contains('kTermsOfServiceUrl'));
    // 🔑 「链接未就绪时不显示死链」—— 该逻辑现在在**共享组件**里
    //    （`widgets/legal_link_row.dart`：url 为空 → 「即将上线」不可点）。
    // ⚠️ 所以下面的断言目标**跟着搬了**：2026-10-04 抽组件后，
    //    订阅页源码里不再有「即将上线」字样 —— 断言若不跟着改会**假红**。
    //    📌 判据：**抽组件后，断言的目标文件要一起搬** —— 否则会误报。
    check(
      '订阅页用共享组件 LegalLinkRow（法律链接规则单点）',
      subscribeCode.contains('LegalLinkRow('),
    );

    // ── §4.4.3 恢复购买（Apple 强制）──
    check('🔴 订阅页有恢复购买调用', subscribeCode.contains('.restore()'));
    check(
      '🔴 恢复结果分「已恢复 / 未找到」两种提示',
      subscribeCode.contains('RestoreOutcome.restored') &&
          subscribeCode.contains('RestoreOutcome.notFound'),
    );

    // ── §4.4.4 管理订阅 + 降级说明 ──
    check(
      '有「管理订阅」（跳 Apple 订阅管理）',
      subscribeCode.contains('kAppleManageSubscriptionsUrl'),
    );
    check('有降级说明（不没收用户资产）', subscribeCode.contains('downgradeNotice('));

    // ── 🔴 法律链接**常量必须就绪**（2026-10-04 已部署）──
    //
    // 🔑 为什么断言「值」而不只是「被引用」：
    //    类型是 `String?` ⇒ 有人把它改回 `null` 时**编译不报错**，
    //    只是订阅页/关于页悄悄退回「即将上线」（**静默失效**）。
    //    而它是 **Apple 上架的硬要求** ⇒ 值得用断言锁住。
    check(
      '🔴 隐私政策 URL 已配置且为 https',
      kPrivacyPolicyUrl != null && kPrivacyPolicyUrl!.startsWith('https://'),
      '$kPrivacyPolicyUrl',
    );
    check(
      '🔴 用户协议 URL 已配置且为 https',
      kTermsOfServiceUrl != null && kTermsOfServiceUrl!.startsWith('https://'),
      '$kTermsOfServiceUrl',
    );

    // ── 🔴 「不放死链」规则在**共享组件**里（抽组件后断言跟着搬）──
    final linkRowCode = codeOnly(readApp('widgets/legal_link_row.dart'));
    check('共享组件 legal_link_row.dart 存在', linkRowCode.isNotEmpty);
    check(
      '🔴 组件在 url 为空时显示「即将上线」（不放死链）',
      linkRowCode.contains('即将上线') && linkRowCode.contains('target == null'),
    );
    check(
      '组件在被两个页面共用（订阅页 + 关于页）',
      subscribeCode.contains('LegalLinkRow(') &&
          codeOnly(readApp('screens/about_screen.dart')).contains('LegalLinkRow('),
    );
    // 🔴 反向：`hasLegalLinks` 已删（零引用 = 死代码，不该回来）
    check(
      '🔴 无 hasLegalLinks 残留（已删的零引用常量）',
      !codeOnly(readApp('services/iap_plan.dart')).contains('hasLegalLinks'),
    );

    // ── §4.4.2 「不得默认勾选」──
    // 🔑 断言「档位变量声明处**没有初值**」—— 这就是「不预选」在代码上的形状。
    //    ⚠️ 用正则而不是 contains：要区分「声明但没赋值」与「声明并赋了初值」。
    check(
      '🔴 档位不预选（_selectedProductId 声明处无初值）',
      RegExp(r'String\?\s+_selectedProductId\s*;').hasMatch(subscribeCode),
    );
  }

  // ── 「我的」页：§4.4.3 要求**两处**入口 ──
  final profileCode = codeOnly(readApp('screens/profile_screen.dart'));
  check(
    '🔴 「我的」页也有恢复购买（§4.4.3 要求两处）',
    profileCode.contains('_restorePurchases'),
  );
  check(
    '「我的」页有「管理订阅」（跳 Apple）',
    profileCode.contains('_openAppleSubscriptions'),
  );
  // 🔴 反向：微信时代的「找服务人员开通/续费」不得残留（**代码里**）
  check(
    '🔴 代码中无「请联系服务人员」残留（微信 Native 时代文案）',
    !profileCode.contains('请联系服务人员'),
  );

  // ── 🔴 反向：已删的微信支付链路不得复活 ──
  check(
    '🔴 pay_screen.dart 已删除（微信扫码支付页，IAP 无对应物）',
    !File('../../app/lib/screens/pay_screen.dart').existsSync(),
  );
  check(
    '🔴 subscribe_panel.dart 已删除（订阅已改独立页）',
    !File('../../app/lib/widgets/subscribe_panel.dart').existsSync(),
  );
  check('🔴 代码中无残留的 /api/pay/native 调用', !profileCode.contains('/api/pay/native'));

  // ────────────────────────────────────────────────────────────────
  // ⑨ 🔴 账号注销（Apple 5.1.1(v)：支持注册的 App **必须**能在 App 内注销）
  // ────────────────────────────────────────────────────────────────
  //
  // ⚠️ 边界同 §⑧：源级断言只证明「代码里有」，**不**证明运行时行为。
  //    运行时行为由后端 11 个单测守着（`user_purge::tests::*`）。
  //    📌 两层各有分工：这里防「入口/接口被删」，那边防「删得不干净」。
  print('\n[⑨] 账号注销（Apple 5.1.1(v)）');

  String readRepo(String rel) {
    final f = File('../../$rel');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  // ⚠️ `routesSrc` **也必须过 `codeOnly`** ——
  //    routes.rs 的注释里**提到了**这个路径（解释为什么用 `/me/` 而不是 `/{user_id}/`）
  //    ⇒ 不滤注释的话，「真路由被删、注释留着」会**假绿**。
  //    📌 这正是 §⑧ 记过的同一条判据：**注释里提到 ≠ 代码里写了**。
  final routesSrc = codeOnly(readRepo('backend/crates/api_server/src/routes.rs'));
  final purgeSrc = codeOnly(readRepo('backend/crates/api_server/src/user_purge.rs'));

  check('后端注销路由已注册', routesSrc.contains('/api/user/me/delete'));
  check(
    '后端路由用 POST（不是 GET/DELETE）',
    RegExp(r'"/api/user/me/delete",\s*post\(').hasMatch(routesSrc),
  );

  // 🔴 **协议层安全**：注销只能删自己 ⇒ uid 必须来自 token，不能是客户端参数。
  check(
    '🔴 后端从 token 反查 uid（协议上无法指定他人）',
    purgeSrc.contains('fn resolve_uid_from_token') &&
        purgeSrc.contains('SELECT user_id FROM tokens WHERE token = ?1'),
  );

  // Apple：「仅停用/禁用不够」⇒ 必须是 DELETE，不能是 UPDATE ... deleted_at
  check(
    '🔴 硬删（不是软删 —— Apple 明确「仅停用不够」）',
    purgeSrc.contains('DELETE FROM {} WHERE {} = ?1'),
  );
  check(
    '事务 + 失败回滚',
    purgeSrc.contains('BEGIN IMMEDIATE') && purgeSrc.contains('ROLLBACK'),
  );
  check(
    '🔴 临时关外键并**恢复**（否则该连接永久失去外键保护）',
    purgeSrc.contains('PRAGMA foreign_keys = OFF') &&
        purgeSrc.contains('PRAGMA foreign_keys = ON'),
  );
  check(
    '交易/审计**匿名化**而非删除（法定保存义务）',
    purgeSrc.contains('ANONYMIZE_TARGETS') && purgeSrc.contains('deleted:'),
  );
  check(
    '🔴 有「引用图覆盖」断言（防加表忘加注销 ⇒ 留孤儿）',
    purgeSrc.contains('purge_covers_all_user_refs'),
  );
  check(
    'trial_ip_log **不在**注销清单（它不含用户标识）',
    !purgeSrc.contains(r'"trial_ip_log"'),
  );

  check('前端「我的」页有注销入口', profileCode.contains('_showDeleteAccountDialog'));
  check('🔴 有二次确认（Apple 明确允许确认步骤）', profileCode.contains('CoDialog.show<bool>'));
  // 🔴 前端也不得传 uid —— 与后端「只认 token」相辅相成
  check(
    '🔴 前端注销请求只带 Authorization（不传 uid）',
    RegExp(
      r"api/user/me/delete'\),[\s\S]{0,160}?headers: \{'Authorization'",
    ).hasMatch(profileCode),
  );
  check(
    '🔴 失败文案明确「账号未被删除」（不留「删了一半」的疑惧）',
    profileCode.contains('账号未被删除'),
  );

  // 🔴 反向：隐私政策**不得**再写「通过邮箱提交申请」
  //    依据：Apple 5.1.1(v) 原文 —— 除高度监管行业，**不得**要求用户发邮件才能注销
  final privacyMd = readRepo('docs/legal/privacy-policy.md');
  check(
    '🔴 隐私政策写「应用内直接注销」（不再要求发邮件）',
    privacyMd.contains('直接注销') && !privacyMd.contains('提交申请'),
  );

  _report();
}
