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
      '🔴 切片有效（截到了 `syncCloudOnTap` 函数体）',
      onTapBody.isNotEmpty && onTapBody.contains('syncStatusSummary'),
      '切片长 ${onTapBody.length} —— 哨兵用 `syncStatusSummary`（正常路径里才有）',
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

  _report();
}
