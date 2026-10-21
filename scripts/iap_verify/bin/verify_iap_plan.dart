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
import '../../../app/lib/services/sync_status.dart';

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

  check('600 分 → ¥6', formatYuan(600) == '¥6', formatYuan(600));
  check('5800 分 → ¥58', formatYuan(5800) == '¥58', formatYuan(5800));
  check('483 分 → ¥4.83（年付折算成「每月」时有小数）', formatYuan(483) == '¥4.83', formatYuan(483));
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

  // 月 6 × 12 = 72；年 58 → 省 14 → 14/72 = 19.4% → 四舍五入 19
  final pct = yearlyDiscountPercent(monthlyFen: 600, yearlyFen: 5800);
  check('月 ¥6 / 年 ¥58 → 折扣可算', pct != null, '$pct');
  // 🔴 锁**精确值**、不锁区间 —— 它由兜底价完全确定，是确定值；
  //    区间断言会让「差一点」也过（2026-10-11 改价 9.9/78 → 6/58 时，
  //    这里原本断言「33–35%」，**必须手动改**才不至于静默失效）。
  check('折扣 = 19%（¥6×12 = 72 → ¥58 ⇒ 省 19.4%）', pct == 19, '$pct%');

  // 🔑 与 UI **同源**：`subscribe_screen._yearlyDiscount()` 用的正是 `defaultPlans()`
  //    的兜底价 ⇒ 这里直接对「UI 会算出的那个数」下断言（而不是只测函数本身）。
  final uiBase = defaultPlans();
  check(
      'UI 角标（由 defaultPlans 兜底价算出）也是 19%',
      yearlyDiscountPercent(
            monthlyFen: uiBase[0].fallbackFen,
            yearlyFen: uiBase[1].fallbackFen,
          ) ==
          19);

  // 🔑 「没有折扣」必须返回 null（而不是 0）—— 否则 UI 会显示「省 0%」
  check('年付不比月付划算 → null（不显示角标）',
      yearlyDiscountPercent(monthlyFen: 600, yearlyFen: 12000) == null);
  check('年付更贵 → null', yearlyDiscountPercent(monthlyFen: 600, yearlyFen: 99999) == null);
  check('零价 → null（防除零）', yearlyDiscountPercent(monthlyFen: 0, yearlyFen: 0) == null);
  check('负价 → null', yearlyDiscountPercent(monthlyFen: -1, yearlyFen: -1) == null);

  // ────────────────────────────────────────────────────────────────
  // ④ 展示模型：价格来源优先级
  // ────────────────────────────────────────────────────────────────
  print('\n[④] 展示模型（StoreKit 价格优先于本地兜底）');

  final noStore = defaultPlans();
  check('无 StoreKit 价 → 用兜底 600（¥6）', noStore[0].fallbackFen == 600, '${noStore[0].fallbackFen}');
  check('无 StoreKit 价 → 用兜底 5800（¥58）', noStore[1].fallbackFen == 5800, '${noStore[1].fallbackFen}');
  check('无 StoreKit 价 → 标记 usingFallbackPrice', noStore[0].usingFallbackPrice);
  check('无 StoreKit 价 → 显示兜底串 ¥6', noStore[0].priceLabel == '¥6', noStore[0].priceLabel);

  final withStore = defaultPlans(monthlyStorePrice: '¥6.00', yearlyStorePrice: '¥58.00');
  check('有 StoreKit 价 → 优先显示它', withStore[0].priceLabel == '¥6.00', withStore[0].priceLabel);
  check('有 StoreKit 价 → 不再标记兜底', !withStore[0].usingFallbackPrice);
  // 🔑 关键：有 StoreKit 价时，**不能**再显示本地兜底价（两个价并存会误导用户）
  check('有 StoreKit 价 → 不显示本地价', withStore[1].priceLabel != '¥58', withStore[1].priceLabel);

  check('两档产品 ID 正确', noStore[0].productId == kProductMonthly && noStore[1].productId == kProductYearly);
  check('时长标签：1 个月', noStore[0].durationLabel == '1 个月', noStore[0].durationLabel);
  check('时长标签：1 年', noStore[1].durationLabel == '1 年', noStore[1].durationLabel);

  // ────────────────────────────────────────────────────────────────
  // ⑤ 🔴 法定要件文案（Apple 3.1.2 —— 缺了会被拒审）
  // ────────────────────────────────────────────────────────────────
  print('\n[⑤] 法定要件文案');

  final notice = SubscriptionLegalText.autoRenewNotice(
    title: '记住一切 专业版',
    durationLabel: '1 个月',
    priceLabel: '¥6',
  );
  // 🔑 断言「关键词存在」而不是「整句相等」—— 文案可以润色，
  //    但**法定要素不能丢**。这是「锁语义形状、不锁拼写」的用法。
  check('含标题', notice.contains('记住一切 专业版'));
  check('含时长', notice.contains('1 个月'));
  check('含价格', notice.contains('¥6'));
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

  // ── 🆕 2026-10-09：对照表（取代原来的「免费版包含」清单 + 「权益」清单两套）──
  //
  // 🔴 为什么把两条清单合成**一张表**：同一件事有**两个来源**时（`benefits` 与
  //    `freeIncludes`），改一处漏一处不报错 —— 只会让订阅页**少说一条权益**。
  //    `subscription-value-assessment-2026-10-07` §四 已把对比形态定为三列。
  final cmp = SubscriptionLegalText.comparison;
  check('「订阅权益」对照表非空', cmp.isNotEmpty);
  check(
    '🔴 对照表两段由 `exclusive` 划分（共同享有 + 订阅版专享），不另写清单',
    SubscriptionLegalText.sharedBenefits.isNotEmpty &&
        SubscriptionLegalText.benefits.isNotEmpty &&
        SubscriptionLegalText.sharedBenefits.length +
                SubscriptionLegalText.benefits.length ==
            cmp.length,
    '共同 ${SubscriptionLegalText.sharedBenefits.length} + 专享 ${SubscriptionLegalText.benefits.length}'
        ' / 共 ${cmp.length} 行',
  );
  check(
    '🔴 `benefits` 与对照表**同源**（每个专享权益都能在表里找到 exclusive 行）',
    SubscriptionLegalText.benefits.every((label) =>
        cmp.any((r) => r.exclusive && r.label == label)),
    SubscriptionLegalText.benefits.join('｜'),
  );
  check(
    '🔴 专享行必须写出**两栏差异**（整段翻译：免费版有额度、订阅版不限）',
    cmp.any((r) =>
        r.label.contains('整段翻译') && r.free.contains('10') && r.sub.contains('不限')),
    '若两栏都写 ✓，对照表就白做了（§4.2：差为正才有力）',
  );
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
  //    去算人民币会自相矛盾（「价格 $99.99，下面写 ≈ ¥4.83/月」）
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
  // 🔴 2026-10-12 **语义修正**（沙盒首测实测）：
  //    「读不到到期时间」**不等于**「已过期」。
  //    旧断言锁的是 `expired` ⇒ 端侧权益判定恒为「已到期」⇒
  //    「订阅已到期」覆盖层对所有买过的用户必弹（这正是白哥报到的那条 bug）。
  //    ⇒ 现在 fail-open：与 `_parseExpiry` 注释里「足以让 UI 先解锁」的**原始意图**一致。
  //    📌 判据再现：**断言会保护错误** —— 改对了反而会红。
  check(
    '🆕 无到期时间但有购买史 → active（fail-open，不是 expired）',
    resolveEntitlement(expiresAtUtc: null, hasAnyPurchase: true, nowUtc: now) ==
        IapEntitlementStatus.active,
    '「不知道」≠「已过期」：买了的人被误报过期，比没买的人多看一眼严重得多',
  );
  // 🔴 边界：**恰好等于** now —— 不算有效（用 isAfter 而非 isAtSameMomentAs）
  check(
    '到期时刻恰好 == now → 不算 active',
    resolveEntitlement(expiresAtUtc: now, hasAnyPurchase: true, nowUtc: now) !=
        IapEntitlementStatus.active,
    '边界必须偏保守：不能多送一瞬',
  );
  // ⚠️ 反向：真正的「已过期」**仍须**判 expired —— 防止上面那条把语义整体放宽成
  //    「永远 active」（那会变成漏收，比误弹更贵）。
  check(
    '🔴 真正的过期仍判 expired（反向锁：别把 fail-open 扩成永远 active）',
    resolveEntitlement(
          expiresAtUtc: now.subtract(const Duration(seconds: 1)),
          hasAnyPurchase: true,
          nowUtc: now,
        ) ==
        IapEntitlementStatus.expired,
  );

  // 🆕 2026-10-12：StoreKit 到期时间解析（单位差 1000 倍会偏到 1970 / 5 万年）
  print('\n[⑥-b] StoreKit 到期时间解析');
  check(
    '毫秒字符串 → UTC DateTime（单位必须是毫秒）',
    parseStoreKitExpiryMillis('1791887855000')?.toUtc() ==
        DateTime.utc(2026, 10, 13, 10, 37, 35),
    '${parseStoreKitExpiryMillis('1791887855000')?.toUtc()}',
  );
  check(
    '🔴 若被当成秒解析会偏到 1970 —— 用毫秒值反查不可等于 1970',
    parseStoreKitExpiryMillis('1791887855000')?.toUtc().year != 1970,
  );
  check('null → null', parseStoreKitExpiryMillis(null) == null);
  check('空串 → null', parseStoreKitExpiryMillis('') == null);
  check('空白串 → null', parseStoreKitExpiryMillis('   ') == null);
  check('非数字 → null', parseStoreKitExpiryMillis('not-a-number') == null);
  check('0 / 负数 → null（无效时间戳）',
      parseStoreKitExpiryMillis('0') == null &&
          parseStoreKitExpiryMillis('-1') == null);
  check(
    '前导空格也能解析（StoreKit 偶尔带空白）',
    parseStoreKitExpiryMillis(' 1791887855000 ')?.toUtc() ==
        DateTime.utc(2026, 10, 13, 10, 37, 35),
  );

  // ────────────────────────────────────────────────────────────────
  // ⑦ 降级文案与实现一致
  // ────────────────────────────────────────────────────────────────
  print('\n[⑦] 降级文案（须与「保留全部资产」的实现一致）');

  final down = downgradeNotice();
  check('含「保留」', down.contains('保留'));
  // 🔴 反向断言：不能说「生词本已锁定」—— 实现是「保留全部资产」
  check('🔴 不含「锁定」字样（与实现不符）', !down.contains('锁定'), down);

  // ══════════════════════════════════════════════════════════════════════
  // 🔴🔴 2026-10-05 **反转两条断言** —— 它们原本是**正向**的，锁住了已废止的事实
  // ══════════════════════════════════════════════════════════════════════
  // 原文是：
  //   check('提到 200 词上限', down.contains('200'));
  //   check('提到文章朗读受限', down.contains('文章朗读'));
  //
  // 那是**「断言保护了错误」**（比「断言太松」更严重）：
  //   · 不仅**没发现**文案过时，还**要求它保持过时** ⇒ 门禁成了错误事实的守卫者；
  //   · ⇒ 有人把文案改对时 CI 会红 ⇒ 下一次「修红」会把错误**再改回来**。
  //     （这正是「假红消耗门禁可信度 ⇒ 训练人忽略红灯」的最坏形态。）
  //
  // 📌 判据：**断言要跟「当前已定案的事实」走** —— 事实废止时，
  //    指着它的**正向断言必须同步反转**，否则它会**持续把错误拉回来**。
  // 🔑 反向断言**天然免疫**这类腐坏（它不会「要求」某个过时事实存在）。
  check('🔴 不得含「200 词上限」（该上限 2026-10-01 已废止）', !down.contains('200'),
      down);
  check('🔴 不得说「文章朗读需要续订」（朗读已免费全量）', !down.contains('文章朗读'),
      down);

  // 🔑 补两条**语义**正向断言 —— 锁「说了什么」，不锁具体字词：
  //    降级提示存在的唯一目的 = 安抚「你的资产还在」，所以必须点明**保了什么**。
  //    ⚠️ 刻意**不**锁整句（那会变成「锁拼写」⇒ 将来改一个字就假红）。
  check(
      '🔑 点明保留三类资产（生词 / 学习记录 / 电子书）',
      down.contains('生词') && down.contains('学习记录') && down.contains('电子书'),
      down);
  check('🔑 说明仍可「查看」与「复习」（不只是说『保留』）',
      down.contains('查看') && down.contains('复习'), down);

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
    // 🔴 2026-10-21：判据从 `.restore()` 放宽到 `.restore(`——
    //    `restore` 现在带命名参数（`restore(alreadyActive: …)`），
    //    精确匹配 `()` 会**假红**。
    //    📌 判据：**断言锁「意图」（调了恢复），不锁「拼写」（括号里有什么）**。
    check('🔴 订阅页有恢复购买调用', subscribeCode.contains('.restore('));

    // 🔴 2026-10-12 晚**修正断言目标**（同 2026-10-04 抽 `LegalLinkRow` 那次）。
    //
    // 旧断言要求 `subscribe_screen.dart` 里出现 `RestoreOutcome.restored` /
    // `.notFound` 两个字面量 —— 那是「文案内联在 UI 里」时代的形状。
    // 现在文案下沉到 `iap_plan.restoreOutcomeMessage`（**可断言**）⇒ 那两个
    // 字面量在 UI 文件里**故意不存在了** ⇒ 旧断言必然**假红**。
    //
    // ⚠️ 但**不能**只把目标换成「UI 里有 `restoreOutcomeMessage(` 这个拼写」——
    //    那锁的是拼写、不是语义。真正要保证的是：
    //    **两种结果给出「不同」的提示**（否则用户分不清成功了还是没找到）。
    check(
      '🔴 订阅页的恢复提示走唯一文案函数（不再内联 switch）',
      subscribeCode.contains('restoreOutcomeMessage('),
    );
    check(
      '🔴 恢复结果分「已恢复 / 未找到」两种**不同**提示（锁语义，不锁拼写）',
      restoreOutcomeMessage(RestoreOutcome.restored) !=
              restoreOutcomeMessage(RestoreOutcome.notFound) &&
          restoreOutcomeMessage(RestoreOutcome.restored).isNotEmpty &&
          restoreOutcomeMessage(RestoreOutcome.notFound).isNotEmpty,
      '「成功了」与「没找到」必须能区分 —— 它决定用户下一步该做什么',
    );

    // ── §4.4.4 管理订阅 + 降级说明 ──
    check(
      '有「管理订阅」（跳 Apple 订阅管理）',
      subscribeCode.contains('kAppleManageSubscriptionsUrl'),
    );
    check('有降级说明（不没收用户资产）', subscribeCode.contains('downgradeNotice('));

    // ── 🆕 2026-10-09：整页**没有折叠**，两块内容**常驻**（白哥定）──
    //
    // # 🔴 证伪方式
    // · 把 `_benefitsSection(t)` 换回 `_detailFold(t)` ⇒ 「无折叠控件」必红。
    // · 把 `_activeChildren` 里加回 `_benefitsSection(t)` ⇒ 「受众」那条必红。
    check(
      '🔴 订阅页**不再有折叠控件**（`AnimatedCrossFade` / `_detailOpen` 不得复活）',
      !subscribeCode.contains('AnimatedCrossFade') &&
          !subscribeCode.contains('_detailOpen') &&
          !subscribeCode.contains('_detailFold'),
      '折叠版的问题：看不见 = 白做 —— 对照表是这页的说服材料',
    );
    check(
      '🔴 有「订阅权益」常驻区块（标题就是这四个字）',
      subscribeCode.contains("'订阅权益'"),
    );
    check(
      '🔴 有「订阅到期后」常驻区块',
      subscribeCode.contains("'订阅到期后'"),
    );
    check(
      '🔴 对照表渲染自**唯一事实源** `SubscriptionLegalText.comparison`',
      subscribeCode.contains('SubscriptionLegalText.comparison'),
      '行数据若在 UI 里另写一份，改 `comparison` 不会反映到页面',
    );
    check(
      '🔴 「会员已到期」只在**真·已到期**时出现（不再对所有人显示）',
      subscribeCode.contains('lapsed: subscriptionLapsedNow(ref, snap)'),
      '对从未订阅的人说「会员已到期」是错误陈述',
    );

    // 🔑 受众判据（白哥：「已经订阅了的人有什么好看的」）——
    //    切片**自带前提断言**（截不到就红），否则「取不到 ⇒ 下面的反向断言假绿」。
    final activeBody =
        RegExp(r'List<Widget> _activeChildren\([^)]*\) =>\s*\[(.*?)\];',
                dotAll: true)
            .firstMatch(subscribeCode)
            ?.group(1) ??
        '';
    check(
      '🔴 已订阅态**不渲染**「订阅权益」「订阅到期后」（受众不是已订阅的人）',
      activeBody.isNotEmpty &&
          !activeBody.contains('_benefitsSection') &&
          !activeBody.contains('_expirySection'),
      activeBody.isEmpty ? '切片失败（前提断言）—— 函数签名变了？' : '',
    );

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
  // 🆕 2026-10-05：「token 反查 uid」的实现搬到了 `auth.rs`（见下面那条断言）
  final authSrc = codeOnly(readRepo('backend/crates/api_server/src/auth.rs'));

  check('后端注销路由已注册', routesSrc.contains('/api/user/me/delete'));
  check(
    '后端路由用 POST（不是 GET/DELETE）',
    RegExp(r'"/api/user/me/delete",\s*post\(').hasMatch(routesSrc),
  );

  // 🔴 **协议层安全**：注销只能删自己 ⇒ uid 必须来自 token，不能是客户端参数。
  //
  // 🔴 2026-10-05 **读取对象转移**：「从 token 反查 uid」的实现
  //    从 `user_purge.rs` **搬到了 `auth.rs` 的 `uid_by_token`** ——
  //    因为「修改密码」也要用它，且要知道**当前 token 本身**（保留当前会话）。
  //    要守的**意图一字未改**：uid 必须来自 token，协议上无法指定他人。
  //    📌 判据：**断言跟着「意图」走，不跟着「文件」走**。
  //    🔑 而且强度**提高了**：拆成两条 ——
  //      ① 唯一实现存在（含那条 SQL，**只许有一处**）
  //      ② 注销路径**确实**调它（接线），而不是自己另写一份
  //    （判据「一处定义」用**计数**：实现只有一处 + 调用点存在）
  final uidImplCount =
      RegExp(r'SELECT user_id FROM tokens WHERE token = \?1').allMatches(authSrc).length;
  check(
    '🔴 「token 反查 uid」在 `auth.rs` 有唯一实现（`uid_by_token`）',
    authSrc.contains('pub fn uid_by_token') && uidImplCount == 1,
    '该 SQL 在 auth.rs 出现 $uidImplCount 次（应为 1）',
  );
  check(
    '🔴 注销路径**确实**调它（协议上无法指定他人）',
    purgeSrc.contains('crate::auth::uid_by_token'),
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

  // ────────────────────────────────────────────────────────────────
  // ⑩ 🆕 2026-10-09 订阅到期覆盖层（白哥真机：点了「查看订阅」不跳转）
  // ────────────────────────────────────────────────────────────────
  //
  // # 🔴 事故：`MaterialApp.builder` 的上下文在 **Navigator 之上**
  //
  // 覆盖层挂在 `MaterialApp.router` 的 `builder:` 里，而 `builder(context, child)`
  // 的 `child` **就是 Router 本身**（Flutter `widgets/app.dart`）⇒ 那个 `context`
  // 在 Router/Navigator **上面**；而 go_router 的 `InheritedGoRouter` 是包在
  // **Navigator 周围**的（`go_router/src/router.dart` 的 `builderWithNav`）
  // ⇒ 在 builder 上下文里 `GoRouter.of(context)` **必然抛**
  //   （debug 断言失败；release 剥掉 assert 后是空值崩溃）。
  //
  // 而旧代码的执行顺序是「先 `setState(关弹窗)`，再 `context.push(...)`」
  // ⇒ **弹窗关掉了、导航从未发生**（真机现象逐字如此）。
  //
  // 🔑 判据（本组要守的那条）：
  //    **`MaterialApp.builder` 的上下文里不能做需要 Navigator / GoRouter 的事** ——
  //    要导航必须**持实例**（`goRouter` / `navigatorKey`），不能靠 `context`。
  //
  // # 🔴 本组的证伪方式
  // · 把覆盖层按钮改回 `context.push('/subscribe')` ⇒ 「用 goRouter 直调」必须变红。
  // · 把判据改回 `startsWith('trial_')` ⇒ 「试用判据 = isRegistered」必须变红。
  // · 把 `DialogOverlay` 包回 `builder` 里 ⇒ 「builder 里无全局弹窗队列」必须变红。
  print('\n[⑩] 订阅到期覆盖层（导航 / 试用判据 / 勿复活死代码）');

  final appSrc = codeOnly(readApp('app.dart'));

  // 🆕 切片：只取 `_buildSubExpiredOverlay` 这个方法的实现。
  //    🔑 **必须切片** —— 「app.dart 全文件不得出现 `context.push(`」会**假红**：
  //       该文件里将来完全可能有**位于 Router 之下**的 widget（如 `_ShellScaffold`）
  //       正当使用 `context.push`。口径要精确到「**这个覆盖层**里不许用」。
  final overlaySrc =
      RegExp(r'Widget _buildSubExpiredOverlay\(\)[\s\S]*?\n  \}')
              .firstMatch(appSrc)
              ?.group(0) ??
          '';
  check('🔴 截到了 `_buildSubExpiredOverlay` 的实现（断言前提成立）',
      overlaySrc.isNotEmpty, '截不到 ⇒ 下面的反向断言会**假绿**');

  check('🔴 「查看订阅」用 `goRouter` **直调**（不经 context）',
      overlaySrc.contains("goRouter.push('/subscribe')"));
  check('🔴 覆盖层里**不得**用 `context.push`（builder 上下文拿不到 GoRouter）',
      overlaySrc.isNotEmpty && !overlaySrc.contains('context.push('),
      '改回 context.push ⇒ 真机表现：弹窗关了、不跳转');

  // ── 试用判据：全库只能有一种口径（`!isRegistered`，不是 `trial_` 前缀）──
  check('🔴 订阅弹窗的试用判据 = `!auth.isRegistered`（与 `auth_provider` 同口径）',
      appSrc.contains('!auth.isRegistered'));
  check('🔴 `app.dart` 不再用 `trial_` 前缀猜账号类型（已废止的判据）',
      !appSrc.contains("startsWith('trial_')"));

  // ── 死代码不得复活：`DialogOverlay` 是「零消费者 + 建在已退役概念上」的陷阱 ──
  check('🔴 `dialog_overlay.dart` 已删除（其内部在 builder 上下文里 showDialog）',
      !File('../../app/lib/widgets/dialog_overlay.dart').existsSync());
  check('🔴 `dialog_queue_provider.dart` 已删除（`enqueue` 全库零调用方）',
      !File('../../app/lib/providers/dialog_queue_provider.dart').existsSync());
  check('🔴 `MaterialApp.builder` 里不再包 `DialogOverlay`',
      !appSrc.contains('DialogOverlay'));

  // ────────────────────────────────────────────────────────────────
  // ⑪ 🆕 2026-10-09 订阅判据：端侧**或**服务端（+「已到期」≠「从未订阅」）
  // ────────────────────────────────────────────────────────────────
  //
  // # 🔴 事故：服务端明明开好了订阅，App 里还是「未订阅」
  //
  // 两处订阅 UI 都只读端侧 IAP（`iapSnapshotOf(ref).isActive`），
  // 而安卓验证机上没有 StoreKit ⇒ `entitlement` 永远 `none`
  // ⇒ **服务端的订阅在无商店的载体上完全不可见**（白哥 2026-10-09 真机）。
  //
  // 🔑 判据修正：**「端侧权威」不等于「端侧独占」** ——
  //    权威说的是「谁说了算」，不是「只能听谁」；端侧**答不上来的场合**必须有人兜底。
  //
  // # 🔴 证伪方式
  // · `subscriptionActive` 改成 `iapActive && backendActive` ⇒ 前两条必红。
  // · `subscriptionLapsed` 改成 `!backendActive` 之类「取反」写法
  //   ⇒ 「从未订阅不算已到期」必红（那正是「给所有免费用户显示会员已到期」的形状）。
  // · 订阅页把判据改回 `iapSnapshotOf(ref).isActive` ⇒ 接线断言必红。
  print('\n[⑪] 订阅判据（端侧权威 + 服务端兜底）');
  {
    check(
      '任一来源有效 ⇒ 有效（端侧 OR 服务端）',
      subscriptionActive(iapActive: true, backendActive: false) &&
          subscriptionActive(iapActive: false, backendActive: true) &&
          subscriptionActive(iapActive: true, backendActive: true),
    );
    check(
      '🔴 两端都无效 ⇒ 无效（否则订阅页会白送权益）',
      !subscriptionActive(iapActive: false, backendActive: false),
    );

    // 🔴 本组最重要的一条：把「从未订阅」与「已到期」分开
    check(
      '🔴 从未订阅（服务端无记录）**不算**已到期',
      !subscriptionLapsed(
          iapExpired: false, backendHasRecord: false, backendExpired: true),
      '服务端的 expired 把 NULL 也算 true ⇒ 不能拿「不有效」当「已到期」',
    );
    check(
      '端侧「有购买记录但已过期」⇒ 已到期',
      subscriptionLapsed(
          iapExpired: true, backendHasRecord: false, backendExpired: false),
    );
    check(
      '服务端有有效期记录且已过期 ⇒ 已到期',
      subscriptionLapsed(
          iapExpired: false, backendHasRecord: true, backendExpired: true),
    );
    check(
      '服务端有记录但未过期 ⇒ 不算已到期',
      !subscriptionLapsed(
          iapExpired: false, backendHasRecord: true, backendExpired: false),
    );

    // 到期日换算（全库唯一换算点）
    check(
      '到期日：端侧精确时刻**优先**，统一成 YYYY-MM-DD',
      subscriptionExpiryLabel(
            iapExpiresAtUtc: DateTime.utc(2027, 3, 5, 12),
            backendExpiresAt: '2027-01-01',
          ) ==
          '2027-03-05',
    );
    check(
      '到期日：端侧给不出（安卓）⇒ 退回服务端对账值',
      subscriptionExpiryLabel(
            iapExpiresAtUtc: null,
            backendExpiresAt: '2027-10-09',
          ) ==
          '2027-10-09',
    );
    check(
      '🔴 两处都没有 ⇒ null（**不编一个日期**，也不返回空串）',
      subscriptionExpiryLabel(iapExpiresAtUtc: null, backendExpiresAt: null) ==
              null &&
          subscriptionExpiryLabel(iapExpiresAtUtc: null, backendExpiresAt: '  ') ==
              null,
    );

    // ── 接线：两处订阅 UI 必须走**同一处**判据 ──
    final subScreen = codeOnly(readApp('screens/subscribe_screen.dart'));
    final profScreen = codeOnly(readApp('screens/profile_screen.dart'));
    for (final e in {'subscribe_screen': subScreen, 'profile_screen': profScreen}.entries) {
      check(
        '🔴 ${e.key} 用唯一判据 `subscriptionActiveNow`',
        e.value.contains('subscriptionActiveNow('),
      );
      check(
        '🔴 ${e.key} 不再单独用 `iapSnapshotOf(ref).isActive` 当权益判据',
        !e.value.contains('iapSnapshotOf(ref).isActive'),
        '纯端侧 ⇒ 安卓/后台授予的订阅永远显示未订阅',
      );
    }
    // 🔴 对账必须**无条件**发生，否则 iOS 上服务端那一侧永远是 unknown ⇒ 兜底形同虚设
    check(
      '🔴 `app.dart` 对账不再以「IAP 不可用」为前提（否则兜底没有数据）',
      RegExp(r'if \(auth\.isAuthenticated && auth\.userId != null\) \{\s*'
              r'ref\.fetchSubscription\(\)')
          .hasMatch(appSrc),
    );

    // ── 短标语与权益清单**同源**（防「另写一套」—— 2026-10-04 那次事故的形状）──
    final pitch = SubscriptionLegalText.shortPitch();
    final allBenefits = SubscriptionLegalText.benefits.join('｜');
    check(
      '🔴 未订阅短标语的每一项都能在权益清单里找到',
      pitch.split(' · ').every(allBenefits.contains),
      '短标语=「$pitch」',
    );
    check(
      '🔴 「我的」页订阅卡不再硬编码**已废止**的能力',
      !profScreen.contains('无限生词本') && !profScreen.contains('文章朗读'),
      '「无限生词本 · 文章朗读」曾写在那里 —— 两个能力早已免费，说成订阅权益是虚假陈述',
    );
  }

  // ────────────────────────────────────────────────────────────────
  // ⑫ 🆕 2026-10-09 云端同步状态（相对时间换算 + 单写入方 + 云朵标）
  // ────────────────────────────────────────────────────────────────
  //
  // 白哥：「没有看到云端同步的状态」⇒ 加**云朵图标**（不加新页面）。
  // 🔑 图标放不下「上次同步 10:32」，所以换算逻辑必须**可穷举**（纯函数）。
  //
  // # 🔴 证伪方式
  // · `relativeSyncLabel` 改成按「小时差」算 ⇒ 「跨自然日」那条必红。
  // · 把 `finishSkipped` 去掉、未登录也标失败 ⇒ 「没跑 ≠ 失败」失守（见下条）。
  print('\n[⑫] 云端同步状态');
  {
    check(
      '相对时间：同一天 ⇒ 「今天 HH:MM」',
      relativeSyncLabel(DateTime(2026, 10, 9, 10, 32), DateTime(2026, 10, 9, 23, 59)) ==
          '今天 10:32',
    );
    check(
      '🔴 按**自然日**算：23:59 同步、00:01 查看 ⇒ 「昨天」（不是「0 小时前」）',
      relativeSyncLabel(DateTime(2026, 10, 8, 23, 59), DateTime(2026, 10, 9, 0, 1)) ==
          '昨天 23:59',
    );
    check(
      '2~6 天 ⇒ 「N 天前」',
      relativeSyncLabel(DateTime(2026, 10, 5, 8, 0), DateTime(2026, 10, 9, 8, 0)) ==
          '4 天前',
    );
    check(
      '≥7 天 ⇒ 直接给日期（相对天数已无意义）',
      relativeSyncLabel(DateTime(2026, 9, 1, 8, 0), DateTime(2026, 10, 9, 8, 0)) ==
          '2026-09-01',
    );
    check(
      '🔴 时钟回拨（同步时间在「未来」）⇒ 归「今天」，不得输出负数天',
      relativeSyncLabel(DateTime(2026, 10, 10, 8, 0), DateTime(2026, 10, 9, 8, 0)) ==
          '今天 08:00',
    );

    final now9 = DateTime(2026, 10, 9, 12, 0);
    check(
      'summary：成功 ⇒ 「已同步 · 今天 10:32」',
      syncStatusSummary(
            SyncStatus(phase: SyncPhase.ok, lastOkAt: DateTime(2026, 10, 9, 10, 32)),
            now9,
          ) ==
          '已同步 · 今天 10:32',
    );
    check(
      'summary：同步中 ⇒ 「正在同步…」',
      syncStatusSummary(const SyncStatus(phase: SyncPhase.syncing), now9) ==
          '正在同步…',
    );
    check(
      '🔴 summary：失败要带**上次成功时间**（否则用户以为从来没同步过）',
      (syncStatusSummary(
                SyncStatus(
                  phase: SyncPhase.failed,
                  lastError: '网络超时',
                  lastOkAt: DateTime(2026, 10, 8, 9, 0),
                ),
                now9,
              ) ??
              '')
          .contains('昨天 09:00'),
    );
    check(
      '🔴 summary：还没同步过 / 本轮没跑 ⇒ null（**不弹无意义提示**）',
      syncStatusSummary(const SyncStatus(), now9) == null &&
          syncStatusSummary(const SyncStatus(phase: SyncPhase.skipped), now9) ==
              null,
    );

    // ── 单写入方 + 单执行入口 ──
    final syncProv = codeOnly(readApp('providers/sync_provider.dart'));
    final runCount = RegExp(r'_runSync\(').allMatches(syncProv).length;
    check(
      '🔴 `_runSync` 是唯一同步执行入口（1 处定义 + 4 处调用：登录后/登出前/进后台/手动）',
      runCount >= 5,
      '实测 $runCount 处',
    );
    // 🔴 「单写入方」必须**全库**扫 —— 这个词的真实语义是「别处也不许写」。
    //
    // ⚠️ 本断言的第一版只扫了 `sync_provider.dart` 自己，结果**证伪失败**：
    //    把 `syncStatusProvider.notifier` 加进 `sync_cloud_badge.dart` 时，
    //    那个窄口径断言**照样绿**（实测）。📌 判据：
    //    **断言的作用域必须覆盖它声称的语义范围** —— 说「唯一」就得扫全库，
    //    只扫一个文件只能证明「这个文件里没写两次」。
    final syncWriters = <String>[];
    for (final f in Directory('../../app/lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (codeOnly(f.readAsStringSync()).contains('syncStatusProvider.notifier')) {
        syncWriters.add(f.uri.pathSegments.last);
      }
    }
    check(
      '🔴 同步状态全库**只有一个写入方**（`sync_provider.dart`）',
      syncWriters.length == 1 && syncWriters.first == 'sync_provider.dart',
      '实测 ${syncWriters.length} 个：$syncWriters',
    );

    // ── 云朵标（两种形态：图标 + 胶囊）──
    final badge = codeOnly(readApp('widgets/sync_cloud_badge.dart'));
    check(
      '云朵标五态图标齐全（未订阅/同步中/已同步/失败/未同步过）',
      badge.contains('cloud_sync') &&
          badge.contains('cloud_done') &&
          badge.contains('cloud_off') &&
          badge.contains('cloud_queue'),
    );
    check(
      '🔴 云朵标走唯一判据 `subscriptionActiveNow`（不是自己读端侧）',
      badge.contains('subscriptionActiveNow(') &&
          !badge.contains('iapSnapshotOf(ref).isActive'),
    );

    // 🔴 2026-10-09 **语义反转**（白哥：「云朵状态要一直显示……未同步显示灰色，
    //    这样没有订阅的用户才知道要订阅」）：
    //    原先两种形态都是「未订阅 ⇒ `SizedBox.shrink()`（零高藏起来）」。
    //    ⇒ 现在**必须一处都不再有**这个早退，否则未订阅用户根本看不到它。
    //
    //    ⚠️ 这条断言本身也演示了「断言会保护错误」：旧版本锁的是
    //       「未订阅自行隐藏」，新需求一来它就**锁住了错的行为**。
    //       所以改需求时**必须同时改断言**（而不是删掉它）。
    //
    //    🔑 判据用「**文件里根本没有 `SizedBox.shrink`**」而不是「某一行文本不存在」——
    //       后者一旦有人换个写法（`return const SizedBox.shrink();` 放在别的分支）
    //       就漏过去了。
    check(
      '🔴 两种形态都不再「藏起来」（文件里不得出现 `SizedBox.shrink`）',
      !badge.contains('SizedBox.shrink'),
      '未订阅时藏起来 ⇒ 用户根本不知道有同步这回事，也无从产生订阅动机',
    );
    // 未订阅态必须**真的画出来**：灰云 + 专门文案 + 点击进订阅页。
    check(
      '🔴 未订阅态在共用函数里有明确分支（返回灰云，不是靠调用方特判）',
      RegExp(r'if \(!subscribed\) \{').hasMatch(badge),
    );

    // 🔴 点击必须**在未订阅分支体内**跳订阅页 ——
    //    ⚠️ 不能只查「文件里有没有 `context.push('/subscribe')`」：
    //       那是个**子串判据**，把别的语句插在它前面（提前 `return`）照样通过（假绿）。
    //       ⇒ 必须取**分支体切片**再断言。
    //    ⚠️ 而且文件里有**两处** `if (!subscribed) {`（`syncCloudVisual` 里一处、
    //       `syncCloudOnTap` 里一处）⇒ 直接对全文取 `firstMatch` 会截到**错的那个**
    //       （本人第一次就踩了：切片 51 字符，正是"返回灰云"那一支）。
    //       ⇒ 先按**起止锚点**切出 `syncCloudOnTap` 的函数体，再在它内部取分支。
    //    ⚠️ 第二个坑：不能用 `\n\}` 当函数终点 —— 参数列表的收尾 `}) {` 里
    //       也有「换行 + `}`」⇒ 切片只有 109 字符（签名本身），同样会假绿。
    //       ⇒ 终点锚点用**下一个顶层声明** `class SyncCloudBadge`。
    final _onTapStart = badge.indexOf('void syncCloudOnTap(');
    final _onTapEnd = badge.indexOf('class SyncCloudBadge');
    final onTapBody = (_onTapStart >= 0 && _onTapEnd > _onTapStart)
        ? badge.substring(_onTapStart, _onTapEnd)
        : '';
    check(
      '🔴 切片有效（两个锚点都找到了：`void syncCloudOnTap(` → `class SyncCloudBadge`）',
      // 🔴 2026-10-11 修：原来哨兵用 `syncStatusSummary`（函数体里的一个**调用**）
      //    ⇒ 该调用被换成 `syncWithProgressDialog` 后**哨兵失效 ⇒ 假红**
      //    （实测：切片 270 字符**明明有效**，却判无效）。
      //    教训：**哨兵不能用「易变的内部调用」** —— 它会在实现演进时变成假红，
      //    而假红会训练人忽略红灯。改用**锚点存在性**（与全仓其余 ~20 处哨兵一致）。
      _onTapStart >= 0 && _onTapEnd > _onTapStart,
      '起点 $_onTapStart · 终点 $_onTapEnd · 切片长 ${onTapBody.length}',
    );
    final notSubscribedBranch =
        RegExp(r'if \(!subscribed\) \{([\s\S]*?)\n  \}').firstMatch(onTapBody)?.group(1) ??
            '';
    check(
      '🔴 切片有效（截到了「未订阅」分支体）',
      notSubscribedBranch.contains('return;'),
      '切片长 ${notSubscribedBranch.length} —— 哨兵用 `return;`（该分支必须有出口）',
    );
    check(
      '🔴 未订阅点击 ⇒ 跳订阅页（在分支体内，不是文件里随便哪一处）',
      notSubscribedBranch.contains("context.push('/subscribe')"),
      '「有动作、无出口」与静默失败同族',
    );
    // 🔑 还要**锁顺序**：分支里若先 `return;` 再 push，那行代码**永远不可达** ——
    //    而「字符串在分支体内」这条判据照样通过（又一层假绿）。
    //    ⇒ 判据 = 「跳转」必须排在「出口」之前（同族：本项目那几条顺序断言）。
    final _iPush = notSubscribedBranch.indexOf("context.push('/subscribe')");
    final _iReturn = notSubscribedBranch.indexOf('return;');
    check(
      '🔴 未订阅分支里**跳转在出口之前**（否则那行代码永远不可达）',
      _iPush >= 0 && _iReturn >= 0 && _iPush < _iReturn,
      'push @$_iPush · return @$_iReturn',
    );
    check(
      '🔴 未订阅文案走纯逻辑层（可穷举），不是散在组件里',
      badge.contains('syncUnsubscribedLabel()'),
    );
    // 🔴 「已同步」必须是**绿**（`success` token），不是中性灰 ——
    //    绿/灰的对比本身就是白哥要的那个信号。
    //    ⚠️ 正则对**空白/换行不敏感**（`[\s\S]{0,80}?`）—— 锁死单行写法的话，
    //       将来跑一次 `dart format` 就会**假红**（本项目踩过「锁拼写」那类）。
    check(
      '🔴 「已同步」用 `success` 绿（不是 ink3 灰）',
      RegExp(r'case SyncPhase\.ok:[\s\S]{0,80}?Icons\.cloud_done, color: success\)')
          .hasMatch(badge),
      '改成 ink3 会让「已同步」与「未同步」长得一样 ⇒ 信号消失',
    );
    check(
      '🔴 未订阅态用**灰**（`ink3`）不用红 —— 它不是用户做错了什么',
      RegExp(r'if \(!subscribed\)[\s\S]{0,60}?Icons\.cloud_queue, color: ink3\)')
          .hasMatch(badge),
    );
    check(
      '🔴 文字与图标共用同一个状态色（颜色只有一处口径）',
      badge.contains('final textColor = v.color;'),
      '若又长出 `s.phase == SyncPhase.failed ? … : …` 这类第二处判定，改一处会漏一处',
    );
    // 🆕 2026-10-09：两种形态，**一套口径**。
    //
    // 🔴 用**计数**而不是「存在性」：只看「定义在不在」是**假绿** ——
    //    在 `SyncCloudChip` 里另抄一份 `switch` 照样过。
    final visualSwitch =
        RegExp(r'switch \((s|status)\.phase\)').allMatches(badge).length;
    check(
      '🔴 状态 →（图标,颜色）的 `switch` 全库**只有一处**（两种形态共用）',
      visualSwitch == 1 &&
          badge.contains('syncCloudVisual(') &&
          badge.contains('syncCloudOnTap('),
      '实测 switch $visualSwitch 处 —— 两处各写一套 ⇒ 改一处漏一处，失败态容易只在一边处理',
    );
    check(
      '🔴 订阅页用**图标**、「我的」页用**独立胶囊**（且「我的」不再贴图标）',
      codeOnly(readApp('screens/subscribe_screen.dart')).contains('SyncCloudBadge(') &&
          codeOnly(readApp('screens/profile_screen.dart')).contains('SyncCloudChip(') &&
          !codeOnly(readApp('screens/profile_screen.dart')).contains('SyncCloudBadge('),
      '白哥：「还是在我的里弄个独立的胶囊吧」',
    );

    // ── 胶囊的常驻文案（纯逻辑，可穷举）──
    check(
      '胶囊文案：已同步 ⇒ 带时间「已同步 · 今天 10:32」',
      syncChipLabel(
            SyncStatus(phase: SyncPhase.ok, lastOkAt: DateTime(2026, 10, 9, 10, 32)),
            now9,
          ) ==
          '已同步 · 今天 10:32',
    );
    check(
      '🔴 胶囊文案：**未同步过也总有字**（空胶囊没有意义）⇒「尚未同步」',
      syncChipLabel(const SyncStatus(), now9) == '尚未同步',
    );
    check(
      '🔴 胶囊文案：本轮没跑但**曾成功过** ⇒ 仍说「已同步 …」（不倒退成「尚未同步」）',
      syncChipLabel(
            SyncStatus(phase: SyncPhase.skipped, lastOkAt: DateTime(2026, 10, 8, 9, 0)),
            now9,
          ) ==
          '已同步 · 昨天 09:00',
    );
    check(
      '胶囊文案：失败 ⇒「同步失败」；同步中 ⇒「正在同步…」',
      syncChipLabel(const SyncStatus(phase: SyncPhase.failed), now9) == '同步失败' &&
          syncChipLabel(const SyncStatus(phase: SyncPhase.syncing), now9) ==
              '正在同步…',
    );
  }

  // ────────────────────────────────────────────────────────────────
  // ⑬ 🆕 2026-10-09 账号级状态的生命周期：**登出必须复位订阅状态**
  // ────────────────────────────────────────────────────────────────
  //
  // # 🔴 事故（白哥真机）：「退出登录后，订阅状态没有发生变化」
  //
  // 根因：当天把 `subscriptionProvider` 加进订阅 UI 的判据
  //   （`subscriptionActiveNow` = 端侧 OR 服务端）—— 而它是**账号级**状态
  //   （读服务端 `users.subscription_expires`），**却没接管它的生命周期**
  //   ⇒ 登出后它保留上一个账号的 `active` ⇒ 下一个账号/未登录态看到「订阅版」。
  //
  // 🔑 判据：**「给判据加一个数据来源」与「接管它的生命周期」是同一件事的两半** ——
  //    只加来源不管生命周期，就是把**上一个账号的值**接进了新判据。
  //
  // # 🔴 证伪方式
  // · 删掉 `onLogout` 里那行 `reset()` ⇒ 「真的调了」必红。
  // · 在 `onLogout` 里顺手把端侧 IAP 也复位 ⇒ 「登出不碰 IAP」必红。
  print('\n[⑬] 订阅状态的生命周期（登出复位 / 别碰端侧）');
  {
    final authProv = codeOnly(readApp('providers/auth_provider.dart'));
    final subProv = codeOnly(readApp('providers/subscription_provider.dart'));
    check('🔴 `SubscriptionNotifier` 有 `reset()`（复位的实现）',
        subProv.contains('void reset()'));
    // ⚠️ 切片到**文件末尾**（`onLogout` 就在 auth_provider 的末尾附近）——
    //    用固定长度窗口会随注释增长而**假红**（本项目踩过「锁拼写/锁位置」那族）。
    final idx = authProv.indexOf('onLogout:');
    final onLogoutTail = idx < 0 ? '' : authProv.substring(idx);
    check('🔴 截到了 `onLogout` 块（断言前提成立）', onLogoutTail.isNotEmpty,
        '截不到 ⇒ 下面的断言会**假绿**');
    check('🔴 `onLogout` 里**真的**调了订阅状态复位（防「写了没人调」）',
        onLogoutTail.contains('subscriptionProvider.notifier).reset()'),
        '不调 ⇒ 登出后仍显示上一个账号的订阅状态（白哥真机实测）');
    check('🔴 登出**不**碰端侧 IAP（它是 Apple ID 级，不是 App 账号级）',
        !onLogoutTail.contains('iapServiceProvider'),
        '端侧 StoreKit 权益跟 Apple ID 走 —— 换 App 账号它本来就还在，复位它会误伤付费用户');
  }

  // ────────────────────────────────────────────────────────────────
  // ⑭ 法务文本的功能表必须与「权益唯一权威」一致
  // ────────────────────────────────────────────────────────────────
  //
  // 🔴 为什么补这一组（2026-10-11 实测踩到）：
  //    `terms-of-service.md` 的功能表里「**文章朗读** → **会员**」这条**一直是错的** ——
  //    朗读早在 2026-10-04 就已免费全量，而法务文本**没有任何断言覆盖**
  //    ⇒ 这个错误在**公网页面**（`api.keyievolution.fun/terms`）上挂了**一周多没人发现**。
  //    📌 判据：**没有断言覆盖的「对外事实」= 迟早漂移**；而法务文本是最贵的那一类对外事实
  //    （用户与审核员都会读到它）。
  //    🔑 权益的**唯一权威**是 `SubscriptionLegalText.comparison`（本文件已 import）——
  //    法务表只是它的**镜像** ⇒ 必须有一条断言把两者绑起来，而不是靠「记得同步」。
  print('\n[⑭] 法务文本的功能表（须与权益唯一权威一致）');

  final termsFile = File('../../docs/legal/terms-of-service.md');
  check('能读到 terms-of-service.md', termsFile.existsSync(), termsFile.path);
  if (termsFile.existsSync()) {
    final terms = termsFile.readAsStringSync();

    /// 取「表格里提到该功能的那一行」（`|` 开头，避免散文里的提及干扰）。
    String tableRowOf(String feature) => terms
        .split('\n')
        .where((l) => l.trimLeft().startsWith('|') && l.contains(feature))
        .join();

    // ① 🔴 反向断言：这些能力**已免费**，不得再标会员
    //    （「朗读」这类「曾经是订阅权益、后来免费」的项最容易残留 —— 本次就是它）
    //    ⚠️ 用 `contains('会员')` 而不是 `contains('**会员**')` ——
    //       写 `**会员**` 只能匹配「纯会员」那一格，任何变体（`**会员不限次**`…）都会漏。
    for (final free in ['文章朗读', '生词卡朗读', '生词本', '划词查词', '复习']) {
      final row = tableRowOf(free);
      check(
          '🔴 法务表里「$free」不得标为会员（它已免费）',
          row.isNotEmpty && !row.contains('会员'),
          row.isEmpty ? '**没找到该行**（改名了？这条会假绿）' : row.trim());
    }

    // ② 正向：三项**订阅专享**必须在表里、且提到会员
    //    （整段翻译是**部分专享** —— 免费每月 10 次、会员不限次 ⇒ 整格不是纯「会员」）
    for (final paid in ['跨设备同步', '云端书架', '整段翻译']) {
      final row = tableRowOf(paid);
      check('法务表里「$paid」存在且提到会员',
          row.isNotEmpty && row.contains('会员'), row.trim());
    }

    // ③ 与代码同源：专享权益的**关键词**必须能在法务表里找到
    //    （不逐字比 —— 法务用词允许不同，但「卖的是什么」必须对得上）
    for (final b in SubscriptionLegalText.benefits) {
      final key = b.contains('同步')
          ? '同步'
          : (b.contains('云端书架') ? '云端书架' : (b.contains('翻译') ? '翻译' : ''));
      check('法务表覆盖权益「$b」（关键词「$key」）', key.isEmpty || terms.contains(key),
          '切不到关键词 ⇒ 需人工核对');
    }

    // ④ 反向：已作废的「朗读属订阅权益」表述不得复活
    check('🔴 法务文本里没有「解锁**文章朗读**」这类表述',
        !terms.contains('解锁**文章朗读**'));
  }

  // ────────────────────────────────────────────────────────────────
  // ⑮ 隐私政策的数据清单必须与「实际会上传的类」一致
  // ────────────────────────────────────────────────────────────────
  //
  // 🔴 为什么补这一组（2026-10-11 实测踩到）：
  //    `privacy-policy.md` §2.1(一) 的标题写的是「**不上传到我们的服务器**」，
  //    而它把「**兴趣筛选偏好**」「**阅读字号**」列在里面 —— 两者**都会**随订阅同步
  //    （`settings_sync.dart` 的 `kSyncedSettingKeys`）。
  //    ⇒ 属「**声称不收集、实际在收集**」—— 隐私披露里最严重的一类。
  //    同一份文件的 §2.1(二) 又把同步清单写成 4 项，实际 **11 类**。
  //    📌 判据：**「对外声明的数据行为」必须有断言绑到实现上**（与 ⑭ 同族思路）。
  //    🔑 权威 = 后端 `schema.rs` 的 `CREATE TABLE IF NOT EXISTS sync_*`
  //       （「服务端到底会收什么」的唯一定义；已与生产库 `sqlite_master` 实测一致）。
  print('\n[⑮] 隐私政策的数据清单（须与实际同步的类一致）');

  final schemaFile = File('../../backend/crates/api_server/src/schema.rs');
  final privacyFile = File('../../docs/legal/privacy-policy.md');
  check('能读到 schema.rs', schemaFile.existsSync(), schemaFile.path);
  check('能读到 privacy-policy.md', privacyFile.existsSync(), privacyFile.path);

  if (schemaFile.existsSync() && privacyFile.existsSync()) {
    final syncTables = RegExp(r'CREATE TABLE IF NOT EXISTS (sync_[a-z_]+)')
        .allMatches(schemaFile.readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    final privacy = privacyFile.readAsStringSync();

    // ① 🔴 「从不外传」那一段里**不得**出现会同步的项
    //    （写法：截出 §2.1(一) 到 §2.1(二) 之间；截不到 ⇒ 显式报红，否则会假绿）
    final s1Start = privacy.indexOf('#### （一）');
    final s1End = privacy.indexOf('#### （二）');
    final sec1 =
        (s1Start >= 0 && s1End > s1Start) ? privacy.substring(s1Start, s1End) : '';
    check('截到了 §2.1(一)「从不上传」那一段', sec1.isNotEmpty,
        '切片长 ${sec1.length}（为 0 ⇒ 段边界锚点变了，下面的断言会假绿）');
    const neverUploaded = <String, String>{
      '兴趣筛选': 'interest_categories 会随订阅同步',
      '字号': 'reading_font_size 会随订阅同步',
      '痕迹': 'reading_trace_enabled 会随订阅同步',
      '朗读': 'tts_enabled / tts_speech_rate 会随订阅同步',
      '显示名': 'display_name 会随订阅同步',
    };
    for (final e in neverUploaded.entries) {
      check('🔴 §2.1(一) 的「从不」段里不得出现「${e.key}」（${e.value}）',
          sec1.isNotEmpty && !sec1.contains(e.key));
    }

    // ② 「同步类 → 用户可读词」映射：法务文本用的是人话，不是表名
    const keywords = <String, String>{
      'sync_user_word': '生词本',
      'sync_review_log': '复习记录',
      'sync_article_read': '阅读进度',
      'sync_bookmark': '收藏',
      'sync_highlight': '划线',
      'sync_book': '电子书',
      'sync_book_progress': '电子书阅读进度',
      'sync_book_marker': '书内书签',
      'sync_lookup_event': '划词历史',
      'sync_achievement_unlock': '成就解锁时间',
      'sync_setting': '应用设置',
    };
    // ③ 🔴 双向绑定：**多出一个同步类**就要先来改这里 + 改法务文本
    final unknown = syncTables.difference(keywords.keys.toSet());
    check('🔴 没有「未登记在法务清单里」的新同步类（新增同步类必须先加映射）',
        unknown.isEmpty, '多出来的：$unknown');
    final gone = keywords.keys.where((t) => !syncTables.contains(t)).toList();
    check('🔴 映射表里没有已删掉的同步类（残留会让断言维护错方向）',
        gone.isEmpty, '已不存在的：$gone');
    for (final e in keywords.entries) {
      check('§2.1(二) 覆盖「${e.value}」（${e.key}）', privacy.contains(e.value));
    }

    // ④ 必须明示「不订阅就完全不上传」—— 这既是卖点，也是用户的定心丸
    check('🔴 明示「不订阅就完全不上传」', privacy.contains('不订阅就完全不上传'));
    // ⑤ 电子书文件会上云，必须显式说出来（最容易漏的一条）
    check('🔴 明说「电子书文件本身会备份到云端」', privacy.contains('电子书文件本身会备份到云端'));
  }

  // ────────────────────────────────────────────────────────────────
  // ⑯ 🆕 2026-10-12 端侧权益的**账号归属**（换账号误显示那次事故）
  // ────────────────────────────────────────────────────────────────
  //
  // # 🔴 事故（白哥多账号真机）
  //
  // 换账号（`123@qq.com`）后「我的」页仍显示「订阅中 · 到期日 2026-10-13」，
  // 而同屏云朵胶囊写着「同步失败」—— nginx 显示同步接口反复 **403 未订阅**。
  //
  // 根因：`subscriptionActiveNow = 端侧.isActive || 服务端.isActive` 把**两层不同归属**的
  //   权益 OR 成一个布尔值：
  //     · 端侧 IAP 权益 → 属于 **Apple ID**（沙盒 Apple 账户）
  //     · 服务端订阅     → 属于**我们的 `user_id`**
  //   ⇒ 任一层为真就认为"有全部权益" ⇒ **一个不可用的能力被显示成可用**。
  //
  // 定案（白哥 2026-10-12）：**订阅只有一个口径 = App 账号**
  //   ⇒ 端侧那一侧必须经 `iapEntitlementBelongsToAccount` 过滤。
  //
  // 🔴🔴 同日**晚间**再收紧（白哥：「**订阅与账号一一绑定**」）：
  //   无绑定**一律不算**（含未登录态）—— 新口径下「无绑定」根本不该产生
  //   （购买前必须先登录，见 ⑰ 组）。详见 `iap_plan` 里该函数的文档。
  //
  // 🔑 与 ⑬ 组的关系：⑬ 说「登出**不**复位端侧 IAP（它是 Apple ID 级）」——
  //    本组**不冲突**：我们照样保留端侧状态，只是不把它**算给任何账号**。
  //
  // # 🔴 证伪方式
  // · 把 `iapEntitlementBelongsToAccount` 的第一行（`ownerUserId == null ⇒ false`）
  //   删掉 ⇒ 真值表里「无绑定」那两条必红。
  // · 把 provider 里那两处过滤删掉 ⇒ 「真的用了过滤」必红。
  print('\n[⑯] 端侧权益的账号归属（订阅只有一个口径 = App 账号）');
  {
    const me = 'u-me';
    const other = 'u-other';

    check(
        '有绑定且 == 当前账号 ⇒ 算',
        iapEntitlementBelongsToAccount(
            ownerUserId: me, currentUserId: me));
    check(
        '🔴 有绑定但 != 当前账号 ⇒ **不算**（换账号误显示的根因）',
        !iapEntitlementBelongsToAccount(
            ownerUserId: other, currentUserId: me),
        '不算 ⇒ 不会把"别人的订阅"显示成"你的"');
    check(
        '🔴 有绑定但当前**未登录** ⇒ 不算',
        !iapEntitlementBelongsToAccount(
            ownerUserId: me, currentUserId: null));
    check(
        '🔴🔴 无绑定 + 未登录 ⇒ **不算**（2026-10-12 晚定案：订阅必须登录）',
        !iapEntitlementBelongsToAccount(
            ownerUserId: null, currentUserId: null),
        '旧口径曾让它「算」（"本机权益"）—— 那条已随「必须先登录」作废');
    check(
        '🔴 无绑定 + **已登录** ⇒ 不算（交给服务端对账定归属）',
        !iapEntitlementBelongsToAccount(
            ownerUserId: null, currentUserId: me),
        '首测那笔交易 app_account_token=None ⇒ 任何账号登录都会看到"订阅中" ⇒ 必须从严');

    // ── 接线：防「函数写了没人调」（本项目已记判据「写了没人跑 = 迟早失效」）──
    final iapProv = codeOnly(readApp('providers/iap_provider.dart'));
    final used = 'iapEntitlementBelongsToAccount'.allMatches(iapProv).length;
    check('🔴 `subscriptionActiveNow` 真的用了归属过滤（防写了没人调）', used >= 1,
        '用了 $used 处');
    check('🔴 `subscriptionLapsedNow` 也用了（否则对从未订阅的人显示"续订"）', used >= 2,
        '用了 $used 处 —— 少于 2 说明只过滤了一处');

    // ── 快照要能携带归属（否则上面的过滤永远拿到 null ⇒ 已登录用户全被拒）──
    final iapSvc = codeOnly(readApp('services/iap_service.dart'));
    check('`IapSnapshot` 有 `ownerUserId` 字段', iapSvc.contains('ownerUserId'));
    check(
        '🔴 归属取自**交易自带**的 `appAccountToken`（不是"当前 userId"）',
        iapSvc.contains('pd.appAccountToken'),
        '用当前 userId 会把延迟投递的**别人的交易**标成你的（正是串号）');
    check(
        '`copyWith` 支持把归属**清回 null**（无绑定是真实状态，`??` 会写不掉）',
        iapSvc.contains('clearOwnerUserId'));
  }

  // ────────────────────────────────────────────────────────────────
  // ⑰ 🆕 2026-10-12 晚 「订阅必须先登录」—— 订阅与账号一一绑定
  // ────────────────────────────────────────────────────────────────
  //
  // # 白哥定案
  //
  //   原话：「**订阅肯定要先登录，才能保证用户的订阅跟着账号走，
  //   订阅与账号一一绑定**」⇒ 推翻了 2026-10-04 的「购买不需要登录」。
  //
  // # 三处落点（**缺一不可**：任一处漏 ⇒ 又能产生「无绑定的交易」）
  //
  // | # | 层 | 做什么 | 为什么不能只靠别处 |
  // |---|---|---|---|
  // | ① | UI 引导 | 订阅页 /「我的」页点购买·恢复 ⇒ 先弹登录 | 用户要有出口，不能点下去没反应 |
  // | ② | **服务层硬拦截** | `IapService.buy()` 未登录**直接拒绝** | 将来新增购买入口漏拦 UI 时，不变量仍成立 |
  // | ③ | 判定层 | 无绑定一律不算（⑯ 组已锁）| 旧数据/StoreKit 1 残留也不会给错人 |
  //
  // 🔑 还有一条**行为**要求：引导登录成功后**自动继续原动作**（购买/恢复），
  //    不要求用户再点一次 —— 否则流程断成「点了→弹登录→登完→还得找回按钮」。
  //
  // # 🔴 证伪方式
  //
  // · 删掉 `purchaseButtonState` 的「未登录」分支 ⇒ 文案真值表必红
  // · 删掉 `iap_service.buy()` 的未登录拦截 ⇒ 「服务层兜底」必红
  // · 删掉 `subscribe_screen` 的 `AuthDialog.show(` ⇒ 「UI 引导」必红
  print('\n[⑰] 订阅必须登录（订阅与账号一一绑定）');
  {
    // ── ① 按钮文案 / 可用性真值表（纯函数：**全分支覆盖**）──
    //
    // 🔑 为什么值得为文案下这么多断言：它是「必须先登录」在界面上**唯一的落点**，
    //    而 UI 层本机验不了（见文件头）⇒ 表述写错 = 用户预期与行为不一致。
    final notSignedIn = purchaseButtonState(
        busy: false, unavailable: false, priceLabel: '¥6', signedIn: false);
    check('未登录 ⇒ 文案含「登录」', notSignedIn.label.contains('登录'),
        notSignedIn.label);
    check('未登录 ⇒ 文案带价格（让用户知道要买哪一档）',
        notSignedIn.label.contains('¥6'), notSignedIn.label);
    check(
        '🔴 未登录 ⇒ 按钮**仍可点**',
        notSignedIn.enabled,
        '不可点=用户以为 app 坏了；可点⇒弹登录=有明确出口');

    final signedInOk = purchaseButtonState(
        busy: false, unavailable: false, priceLabel: '¥6', signedIn: true);
    check('已登录 ⇒ 「立即订阅 · ¥6」', signedInOk.label == '立即订阅 · ¥6',
        signedInOk.label);
    check('已登录 ⇒ 可点', signedInOk.enabled);

    // 🔑 优先级：**未选档位**必须压过「未登录」——
    //    否则用户点了按钮、登完录，仍然不知道自己买的是哪一档。
    final noPlan = purchaseButtonState(
        busy: false, unavailable: false, priceLabel: null, signedIn: false);
    check('未选档位 ⇒ 「请先选择订阅方式」（优先级高于登录引导）',
        noPlan.label == '请先选择订阅方式', noPlan.label);
    check('未选档位 ⇒ 不可点', !noPlan.enabled);

    final busyState = purchaseButtonState(
        busy: true, unavailable: false, priceLabel: '¥6', signedIn: true);
    check('购买中 ⇒ 「处理中…」且不可点',
        busyState.label == '处理中…' && !busyState.enabled, busyState.label);

    final unavailState = purchaseButtonState(
        busy: false, unavailable: true, priceLabel: '¥6', signedIn: true);
    check('商店不可用 ⇒ 明确告知且不可点',
        unavailState.label.contains('App Store') && !unavailState.enabled,
        unavailState.label);

    // ── ② UI 引导：**两处**购买入口都要能弹登录 ──
    final subUi = codeOnly(readApp('screens/subscribe_screen.dart'));
    final profUi = codeOnly(readApp('screens/profile_screen.dart'));
    check('🔴 订阅页用 `AuthDialog` 引导登录', subUi.contains('AuthDialog.show('));
    check('🔴 「我的」页的「恢复购买」也引导登录（两处必须一致）',
        profUi.contains('AuthDialog.show('));
    check('🔴 订阅页按钮走 `purchaseButtonState`（不再自己写分支）',
        subUi.contains('purchaseButtonState('));
    check(
        '🔴 订阅页不再出现「无需登录即可购买」旧措辞',
        !subUi.contains('无需登录即可购买'),
        '旧口径已作废 —— 留着会让用户以为不登录也能买，点下去却被要求登录');
    check(
        '🔴 订阅页说明改成「需先登录」口径',
        subUi.contains('订阅需先登录账号'));

    // ── ③ 服务层硬拦截（**关键不变量不能只靠 UI**）──
    final svc2 = codeOnly(readApp('services/iap_service.dart'));
    check(
        '🔴 `buy()` 未登录直接拒绝（防将来新增入口漏拦）',
        svc2.contains('请先登录账号后再订阅'),
        'UI 只是引导；「一一绑定」的不变量在这里兜住');

    // ── ④ 「恢复购买」的文案（2026-10-12 白哥定：「没找到」要能自己解决）──
    //
    // 🔑 背景：订阅与账号一一绑定后，「没找到」有两种成因 ——
    //    ① Apple ID 真没买过｜② **订阅在另一个 App 账号上**。
    //    旧文案只描述 ① ⇒ 用户在 ② 会以为「我的订阅丢了」（静默失败 + 无出口）。
    final restoredMsg = restoreOutcomeMessage(RestoreOutcome.restored);
    final notFoundMsg = restoreOutcomeMessage(RestoreOutcome.notFound);
    final failedMsg = restoreOutcomeMessage(RestoreOutcome.failed);
    final unavailMsg = restoreOutcomeMessage(RestoreOutcome.unavailable);
    check('四种恢复结果都有非空文案',
        [restoredMsg, notFoundMsg, failedMsg, unavailMsg]
            .every((m) => m.isNotEmpty));
    check('四种文案**互不相同**（否则用户分不清到底发生了什么）',
        {restoredMsg, notFoundMsg, failedMsg, unavailMsg}.length == 4);
    check(
        '🔴 `notFound` 文案必须**引导切回原账号**（订阅与账号一一绑定）',
        notFoundMsg.contains('账号'),
        '旧文案让用户以为订阅丢了：$notFoundMsg');
    check(
        '🔴 `notFound` 不再是干巴巴的「未找到订阅记录」',
        !notFoundMsg.contains('未找到订阅记录'));

    // ── 接线：两处调用点**都**必须走同一函数（防各写一份 switch 又漂）──
    final usedRestoreMsg =
        'restoreOutcomeMessage('.allMatches(subUi).length +
            'restoreOutcomeMessage('.allMatches(profUi).length;
    check('🔴 订阅页与「我的」页都走唯一文案函数（各写一份必然漂）',
        usedRestoreMsg >= 2, '共 $usedRestoreMsg 处');

    // ── ⑤ 🆕 2026-10-13：到期后的**同步口径**（后端 pull 已放行）──
    //
    // 🔴 后端白哥定案 B：`sync_pull` 改为「**只需登录**」⇒ 免费 / 到期用户
    //    **仍能把云端数据拉回本机**，只是不能再上传。
    //    文案若不跟着改，就会写成「同步**停止**」= **方向相反的错** ——
    //    用户以为云端数据取不回来（2026-10-13 实测正是这个误解吓到了白哥：
    //    258 行数据完好却全 403，他看到的是「数据全没了」）。
    //    📌 判据：**降级文案不能比实际更吓人**；且**后端口径变了，
    //       面向用户的表述必须同步** —— 否则迟早漂成假陈述。
    final expiryText = SubscriptionLegalText.afterExpiry.join(' | ');
    check('🔴 到期清单不得说「同步停止」（实际只停上传）',
        !expiryText.contains('同步停止'),
        '实际是 pull 放行、push 403 ⇒「停止」会误导用户以为数据取不回');
    check('🔴 到期清单要明说「云端数据仍可下载」',
        expiryText.contains('仍可下载'));
    final syncRow = SubscriptionLegalText.comparison
        .firstWhere((r) => r.label.contains('同步'));
    check('🔴 权益表里同步的「免费版」不得是「—」（可下载、只是不能上传）',
        syncRow.free != '—', '当前值：${syncRow.free}');
    check('权益表里同步的「订阅版」要说清是「双向」',
        syncRow.sub.contains('双向'), '当前值：${syncRow.sub}');
    check('🔴 降级说明也要提「云端可下载」', downgradeNotice().contains('下载'));
  }

  // ══════════════════════════════════════════════════════════════════════
  // ⑱ 🔴 「恢复购买」的结果判定必须与 UI 的「订阅中」**同源**
  // ══════════════════════════════════════════════════════════════════════
  //
  // 白哥 2026-10-13 实测：**注销账号 → 重新 Apple 登录** →
  // 点恢复购买**显示「已恢复」**，但订阅状态**仍是未订阅**。
  //
  // 根因：`restore()` 判 `_snapshot.entitlement == active`（**不过滤归属**），
  // 而 UI 走 `subscriptionActiveNow`（**过滤归属**）⇒ **两套口径**。
  // Apple 重放的交易上写着**已注销的旧 userId**（`appAccountToken` 由 Apple 签，改不掉）
  // ⇒ 「有交易、但不属于你」正好卡在两套口径之间。
  //
  // 🔴 证伪方式
  // · 把 `judgeRestoreOutcome` 里的归属过滤删掉 ⇒ ⑱-2 / ⑱-3 必红
  // · 把 `restore()` 改回内联判定 ⇒ ⑱-8 或 ⑱-9 必红
  {
    const me = 'u-me';
    const other = 'u-other';

    check(
        '⑱-1 有效 + 归属=当前账号 ⇒ restored',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.active,
              ownerUserId: me,
              currentUserId: me,
            ) ==
            RestoreOutcome.restored);

    check(
        '⑱-2 🔴 有效但归属=**另一个活跃账号** ⇒ notFound（不得谎报已恢复）',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.active,
              ownerUserId: other,
              currentUserId: me,
            ) ==
            RestoreOutcome.notFound,
        '这条正是「注销后重登」的形状：交易仍写着旧账号 ⇒ 提示必须与界面一致');

    check(
        '⑱-3 🔴 有效但归属=**已注销的旧账号** ⇒ notFound',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.active,
              ownerUserId: '5391ad37-8043-4d8e-91ec-01ea3286d9c5',
              currentUserId: me,
            ) ==
            RestoreOutcome.notFound,
        '⚠️ 端侧**无法**判断旧账号是否已注销 ⇒ 仍算 notFound；'
            '权益由**服务端认领后回传**（届时 applyServerExpiry 把归属改写成本账号）');

    check(
        '⑱-4 已过期 ⇒ notFound',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.expired,
              ownerUserId: me,
              currentUserId: me,
            ) ==
            RestoreOutcome.notFound);

    check(
        '⑱-5 从未购买 ⇒ notFound',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.none,
              ownerUserId: null,
              currentUserId: me,
            ) ==
            RestoreOutcome.notFound);

    check(
        '⑱-6 无绑定 + 已登录 ⇒ notFound（沿用「订阅必须登录」口径）',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.active,
              ownerUserId: null,
              currentUserId: me,
            ) ==
            RestoreOutcome.notFound);

    // ⚠️ 期望值**独立核对过** `iapEntitlementBelongsToAccount` 的实现：
    //    `ownerUserId == null ⇒ false`（无绑定一律不算，2026-10-12 定案）
    //    —— 所以这里必须是 notFound，**不是** restored。（首版差点写反 ⇒ 假绿）
    check(
        '⑱-7 无绑定 + 未登录 ⇒ notFound（与 ⑯ 组真值表一致）',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.active,
              ownerUserId: null,
              currentUserId: null,
            ) ==
            RestoreOutcome.notFound,
        '2026-10-12 定案「订阅必须登录」后，本机权益那一格已作废');

    // ── 接线：防「函数写了没人调」──
    final iapSvcSrc = codeOnly(readApp('services/iap_service.dart'));
    check('⑱-8 🔴 `restore()` 必须走 `judgeRestoreOutcome`（唯一判据）',
        iapSvcSrc.contains('judgeRestoreOutcome('),
        '不接 ⇒ 口径又变回两套');
    check(
        '⑱-9 🔴 旧的内联判定**不得复活**（反向断言，对重构免疫）',
        !iapSvcSrc.contains(
            'return _snapshot.entitlement == IapEntitlementStatus.active'),
        '复活 ⇒ 「提示已恢复 + 显示未订阅」会再次出现');

    // ── ⑳ 已订阅时点「恢复购买」不能否认事实（2026-10-21 真机）──
    //
    // 现场：页面顶部「订阅中 · 到期日 2026-11-20」，点恢复却弹
    // 「当前账号未找到订阅」。根因是两者口径不同：
    //   状态 = `subscriptionActiveNow`（端侧 OR 服务端）
    //   恢复 = 只看端侧 `currentEntitlements`
    // ⇒ 服务端有效、端侧查不到（Apple 沙盒续期用尽 / 人工开通）时必然矛盾。
    check(
        '⑳-1 已有效(idle) ⇒ alreadyActive（**不许**再报 notFound）',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.expired,
              ownerUserId: null,
              currentUserId: me,
              alreadyActive: true,
            ) ==
            RestoreOutcome.alreadyActive,
        '这条红 ⇒ 已订阅用户点恢复又会被说「未找到订阅」');

    check(
        '⑳-2 🔴 反向：未有效时**不得**谎报 alreadyActive（别把漏洞开成默认）',
        judgeRestoreOutcome(
              entitlement: IapEntitlementStatus.expired,
              ownerUserId: null,
              currentUserId: me,
              alreadyActive: false,
            ) ==
            RestoreOutcome.notFound,
        '反向断言：放松判据时最容易顺手把所有情况都放行');

    final alreadyMsg = restoreOutcomeMessage(RestoreOutcome.alreadyActive);
    check('⑳-3 alreadyActive 的文案不得与 notFound 相同',
        alreadyMsg != restoreOutcomeMessage(RestoreOutcome.notFound));
    check('⑳-4 alreadyActive 的文案要说清「已是订阅」，不能只说「失败/未找到」',
        alreadyMsg.contains('已是订阅'), alreadyMsg);

    // ── ㉒ 购买必须防重入（storekit_duplicate_product_object）──
    //
    // 白哥 2026-10-22 真机：支付一次后又弹第二次支付，取消时报
    // `storekit_duplicate_product_object`。根因是 `buy()` 无防重入，
    // 只靠 UI 把按钮变灰（`_emit` → 重建 → 变灰，中间隔一帧）。
    check(
        '㉒-1 🔴 `buy()` 必须有基于 purchasing 的防重入 guard',
        iapSvcSrc.contains('if (_snapshot.purchasing)'),
        '没有 ⇒ 一帧内二次触发就调两次 buyNonConsumable ⇒ StoreKit 报 duplicate');

    check(
        '⑳-5 🔴 两个入口都要把 alreadyActive 传进去（改一处漏一处就会一真一假）',
        codeOnly(readApp('screens/profile_screen.dart'))
                .contains('restore(alreadyActive: alreadyActive)') &&
            codeOnly(readApp('screens/subscribe_screen.dart'))
                .contains('restore(alreadyActive: alreadyActive)'),
        '「我的」页与订阅页必须同一套行为（项目既有判据）');
  }

  // ══════════════════════════════════════════════════════════════════════
  // ⑲ 服务端「孤儿放行」判据必须**两处都有**（防「修了一处漏一处」）
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 由来（2026-10-13）：只修了 **B1'（绑定层）** 就以为完事 —— 本地 307 项单测全绿，
  // 但**端到端**上报仍被 **B2'（归属层）** 以「该交易已归属其他账号」挡回 409。
  // ⇒ 判据：**补丁 ≠ 修法**；且「单测覆盖我改的地方」≠「覆盖完整链路」。
  // ⇒ 本组把「两处都用同一判据」变成**断言**，下次漏一处就会红。
  {
    final rust = File('../../backend/crates/api_server/src/iap_handlers.rs');
    final src = rust.existsSync() ? rust.readAsStringSync() : '';

    final uses = 'account_id_exists('.allMatches(src).length;
    check(
        '⑲-1 🔴 孤儿判据 `account_id_exists` 至少 3 次出现（定义 1 + 调用 2）',
        uses >= 3,
        '实际 $uses 次 —— 少于 3 说明 B1\'（绑定层）或 B2\'（归属层）漏了一处');

    check(
        '⑲-2 孤儿重新认领必须**显式**改写 user_id（UPSERT 的 SET 里故意没有它）',
        src.contains('UPDATE iap_transactions SET user_id'),
        '不显式改写 ⇒ 判了 Claimed 但归属仍留在已注销账号上');

    check(
        '⑲-3 🔴 防串号防线不得被删（「活跃账号 ⇒ Conflict」仍在）',
        src.contains('return Ok(Ownership::Conflict'),
        '删了它 ⇒ 任何账号都能抢别人的交易');
  }

  // ══════════════════════════════════════════════════════════════════════
  // ⑳ 到期日「只向前推进」+ 到期弹窗不得退回手搓白板（2026-10-20）
  //
  // 🔴 事故：StoreKit **乱序重放 9 笔**历史交易 ⇒ 一笔旧的（10-18）把 10-21
  //    **回退**掉 ⇒ 服务端判「未订阅」⇒ 同步 403 + 误弹「订阅已到期」，
  //    而端侧 StoreKit 仍有效到 10-21 ⇒ 用户看到「订阅中 · 同步失败」。
  // 📌 判据：**幂等写入 ≠ 可以乱序到达**（顺序不该由客户端保证）。
  // ══════════════════════════════════════════════════════════════════════
  {
    final handlers = File('../../backend/crates/api_server/src/iap_handlers.rs');
    final rs = handlers.existsSync() ? handlers.readAsStringSync() : '';
    final sub = File('../../backend/crates/api_server/src/subscription.rs');
    final subSrc = sub.existsSync() ? sub.readAsStringSync() : '';
    final appSrc = codeOnly(readApp('app.dart'));

    check(
        '⑳-1 🔴 IAP 上报用 `set_expires_if_later`（只向前推进）',
        rs.contains('subscription::set_expires_if_later('),
        '用无条件版 ⇒ 乱序重放时到期日被旧交易回退');

    check(
        '⑳-2 🔴 无条件版 `set_expires(` **不得**再出现在 IAP handler（反向断言）',
        !rs.contains('subscription::set_expires('),
        '它保留给退款/管理端；IAP 用它 ⇒ 事故复发');

    check(
        '⑳-3 单调条件必须在 **SQL 里**（不在 Rust 里读-改-写，避免并发窗口）',
        RegExp(r'datetime\(subscription_expires\)\s*<\s*datetime\(\?1\)')
            .hasMatch(subSrc),
        '缺这个 WHERE 条件 ⇒ 等于没改');

    check(
        '⑳-4 响应 `expiresAt` 必须是**库里生效值**（不是本次交易值）',
        rs.contains('"expiresAt": effective_expires'),
        '乱序时两者不同 ⇒ 客户端会把权益判错');

    check(
        '⑳-5 无条件版仍保留（退款 / 人工撤销依赖它，别"顺手也改成单调"）',
        subSrc.contains('pub fn set_expires('),
        '删了它 ⇒ 退款无法收回权益');

    check(
        '⑳-6 🔴 `unknown` 不得触发到期判定（只认 `unavailable`）',
        appSrc.contains('iap.availability == IapAvailability.unavailable'),
        'unknown = 还没查；拿服务端值冒充 ⇒ 启动瞬间误弹');

    check(
        '⑳-7 🔴 不得再用 `!= available` 做回退判据（反向断言）',
        !appSrc.contains('iap.availability != IapAvailability.available'),
        '它把 unknown 也算成「端侧不行」');

    // 切出 `_buildSubExpiredOverlay` 的方法体 —— 只对这一段断言，
    // 避免「app.dart 全文件不得有 Colors.white」那种**假红**（别处合法使用）。
    final start = appSrc.indexOf('Widget _buildSubExpiredOverlay()');
    final end = start < 0 ? -1 : appSrc.indexOf('\n  @override', start);
    final overlay =
        (start >= 0 && end > start) ? appSrc.substring(start, end) : '';

    // 🔑 先证明切片有效 —— 否则下面几条会因为 `overlay` 是空串而**假绿**
    check(
        '⑳-8 能切出「订阅已到期」覆盖层的方法体（切片失败会让 ⑳-9~11 假绿）',
        overlay.isNotEmpty,
        '找不到 `Widget _buildSubExpiredOverlay()` 或方法边界变了');

    check(
        '⑳-9 🔴 弹窗必须复用 `CoDialogSurface`（外观只有一处定义）',
        overlay.contains('CoDialogSurface('),
        '手搓一套 ⇒ 深色主题变成白板（白哥：「丑陋的很，不符合设计规范」）');

    check(
        '⑳-10 🔴 不得退回硬编码白底 / Material 控件（反向断言）',
        !overlay.contains('Colors.white') &&
            !overlay.contains('Icons.lock') &&
            !overlay.contains('FilledButton'),
        '这些在三档主题（墨/格/夜）里必然失控');

    final clayButtons = 'ClayButton('.allMatches(overlay).length;
    check(
        '⑳-11 两个按钮都是粘土按钮（主 + 次）',
        clayButtons >= 2,
        '实际 $clayButtons 个 —— 少一个说明有按钮退回了 Material');
  }

  // ══════════════════════════════════════════════════════════════════════
  // ㉑ `subscription_expires` 格式收口（2026-10-21 方案 A）
  //
  // 📄 docs/design/subscription-expires-format-unification-2026-10-21.md
  // 事故背景：同一字段有**三种规避手法并存**（手写补 T00:00:00Z / SQL datetime() /
  // substr 取前 10 位），任何新读法忘记归一就会**静默算错**。
  // 方案 A 把「解析」和「写入」各收口到一处。
  // ══════════════════════════════════════════════════════════════════════
  {
    final subFile = File('../../backend/crates/api_server/src/subscription.rs');
    final subSrc = subFile.existsSync() ? subFile.readAsStringSync() : '';
    final schemaFile = File('../../backend/crates/api_server/src/schema.rs');
    final schemaSrc = schemaFile.existsSync() ? schemaFile.readAsStringSync() : '';

    check('㉑-1 存在唯一解析入口 `parse_expires`',
        subSrc.contains('pub fn parse_expires('),
        '没有它 ⇒ 每个读点都要自己归一');

    check('㉑-2 🔴 `is_subscription_active` 走统一解析（`parsed_expires`）',
        subSrc.contains('parsed_expires(conn, user_id)'),
        '自己手写归一 ⇒ 遇到 `+08:00` 之类会静默判「未订阅」');

    check('㉑-3 🔴 不得再手写 `T00:00:00Z` 补纯日期（反向断言）',
        !subSrc.contains('format!("{}T00:00:00Z", expires)'),
        '那是旧实现的归一手法，已被 parse_expires 取代');

    // 两处调用都是 `let canonical = canonicalize_expires(expires).ok_or_else(...)`
    final canonCalls = '= canonicalize_expires(expires)'.allMatches(subSrc).length;
    check('㉑-4 两个写入口（`set_expires` / `_if_later`）都规范化',
        canonCalls >= 2,
        '实际 $canonCalls 处 —— 少一处说明有写入口仍会存下第二种形态');

    check('㉑-5 🔴 `extend_subscription` 不得再输出纯日期（反向断言）',
        !subSrc.contains('new_date.format("%Y-%m-%d")'),
        '旧写法既产纯日期、又配套了「字符串比较 + 解析失败退今天」的丢权益 bug');

    check('㉑-6 🔴 不得再「解析失败就静默用今天」（反向断言）',
        !subSrc.contains('unwrap_or_else(|_| chrono::Utc::now().date_naive())'),
        '那会把用户已付费的剩余天数清零');

    check('㉑-7 schema 有幂等的格式迁移（**任何**可解析形态都拉成 RFC3339）',
        schemaSrc.contains("strftime('%Y-%m-%dT%H:%M:%SZ', subscription_expires)"),
        '只认纯日期会漏掉 `2026-10-21 14:04:22` 这种空格形态（预演时抓到的）');

    check('㉑-8 错名 `activate_subscription` 零命中',
        !subSrc.contains('activate_subscription'),
        '函数真名是 `extend_subscription`（错名会让排查时搜不到）');
  }

  _report();
}
