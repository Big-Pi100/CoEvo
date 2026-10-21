// 订阅状态四态 —— **端 / 服 判据一致性**验收（纯 Dart · 零依赖 · 本机可跑）
//
// 跑：cd scripts/iap_verify && dart run bin/verify_subscription_state.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 这个脚本守的是哪件事
//
// 2026-10-21 审计发现「订阅已到期」有**两个判据权威**：
//   · 后端 `subscription::expires_state`（收口后：none / active / expired / invalid）
//   · 端侧 `subscriptionProvider.fetch` 原先只看一个布尔 `expired`
// 而那个布尔对 `subscription_expires IS NULL`（**从未订阅**）也是 `true`
// ⇒ 给所有免费用户准备了「你的会员已到期」这句话。
//
// # ⚠️ 为什么这里用**文本断言**而不是 import 后跑
//
// `subscription_provider.dart` 依赖 `flutter_riverpod`，`dart run` 在本机起不来
// （项目既有约束）。真正该做的是把判定下沉成纯函数 —— 那是更大的重构，
// 不在本次修复范围内。⇒ 退一步用文本断言，**但只锁「语义形状」**：
// 锁 `state` 的四个分支去向，不锁注释、不锁措辞。
//
// 🔴 文本断言的已知弱点（本项目已踩）：改个格式就假红、写个同义实现就假绿。
//    所以这里刻意锁「分支 → 目标枚举」这一对，而不是锁整行原文。

import 'dart:io';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail == null ? name : '$name —— $detail');
  }
}

File? _locate(String rel) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/$rel');
    if (f.existsSync()) return f;
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

String _read(String rel) {
  final f = _locate(rel);
  return f == null ? '' : f.readAsStringSync();
}

/// 去掉 `//` 行注释，避免断言被注释里的示例文字骗过（**只按整行剥**）。
String _stripLineComments(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  // ── ① 后端：四态判据存在且语义正确 ──
  final sub = _stripLineComments(_read('backend/crates/api_server/src/subscription.rs'));
  check('后端有 expires_state 纯函数', sub.contains('pub fn expires_state'));

  for (final state in ['"none"', '"active"', '"expired"', '"invalid"']) {
    check('后端判据里出现 $state', sub.contains(state));
  }

  // 🔴 核心不变式：没有到期日 = `none`（**不能**落到 expired）
  check(
    '后端：NULL / 空串 → "none"',
    sub.contains('None | Some("") => "none"'),
    '这是「从未订阅」与「已到期」分开的**唯一**支点',
  );

  // 「解析失败」必须单独一态，不许并入 expired 或 active
  check(
    '后端：解析不了 → "invalid"（不并进 expired/active）',
    sub.contains('None => "invalid"'),
  );

  // 边界口径必须与 is_subscription_active 一致（严格大于）
  check(
    '后端：边界用 `>`（恰等于当前秒算过期前一刻仍有效）',
    sub.contains('dt.timestamp() > now_ts'),
  );

  // ── ② 路由层：不许再有第二套归一 ──
  final routes = _stripLineComments(_read('backend/crates/api_server/src/routes.rs'));
  final handlerStart = routes.indexOf('async fn user_subscription_handler');
  check('路由里有 user_subscription_handler', handlerStart >= 0);
  if (handlerStart >= 0) {
    final body = routes.substring(
      handlerStart,
      (handlerStart + 2000).clamp(0, routes.length),
    );
    check(
      '路由改调 expires_state（单一权威）',
      body.contains('expires_state'),
    );
    check(
      '路由不再手写归一（无 format!("{}T00:00:00Z"…)）',
      !body.contains('T00:00:00Z'),
      '那正是与 parse_expires 口径分叉的源头（不认空格分隔）',
    );
    check(
      '路由不再用 unwrap_or(true) 静默判过期',
      !body.contains('unwrap_or(true)'),
    );
  }

  // ── ③ 端侧：四态映射到正确的枚举 ──
  final prov = _stripLineComments(
    _read('app/lib/providers/subscription_provider.dart'),
  );
  check(
    '端侧读 state 字段',
    prov.contains("data['state']"),
  );
  check(
    '端侧：none/invalid → required（未激活，不是「已到期」）',
    prov.contains("'none' || 'invalid' => SubscriptionStatus.required"),
    '映射成 expired 就等于继续对所有免费用户说「你的会员已到期」',
  );
  check(
    '端侧：expired → expired',
    prov.contains("'expired' => SubscriptionStatus.expired"),
  );
  check(
    '端侧：active → active',
    prov.contains("'active' => SubscriptionStatus.active"),
  );
  // 兼容旧服务端：没有 state 时必须退回旧口径，不能一律 unknown
  check(
    '端侧：无 state 时退回旧的 expired 布尔（新端 + 旧服务端可用）',
    prov.contains("'expired' => SubscriptionStatus.expired") &&
        prov.contains('expired'),
  );

  // ── ④ 覆盖层：必须用 lapsed 判据，不许用裸 isExpired ──
  final app = _stripLineComments(_read('app/lib/app.dart'));
  check('覆盖层用 subscriptionLapsed（曾订阅且已失效）', app.contains('subscriptionLapsed('));
  check(
    '覆盖层要求 backendHasRecord（到期日非空）',
    app.contains('backendHasRecord'),
    '少了这条，「从未订阅」会被算成「已到期」',
  );

  _report();
}

void _report() {
  final total = _pass + _fail;
  if (_failures.isNotEmpty) {
    print('\n🔴 失败 ${_failures.length} 项：');
    for (final f in _failures) {
      print('    · $f');
    }
  }
  print('\n通过 $_pass / $total');
  if (_fail == 0) {
    print('✅ 全部通过');
  }
  if (_fail > 0) {
    throw StateError('订阅四态一致性验收失败 $_fail 项');
  }
}
