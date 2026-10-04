// CoEvo · 「我的」页 UI 接线验收
//   ① **登录入口接线** —— 防「有实现、无入口」（analyzer 与后端测试都发现不了）
//   ② **弹层形态统一** —— 防「半统一」复发（新加一个 Material 弹窗即变红）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_auth_entry.dart
//
// # 为什么需要它（2026-09-29 的真实回归）
//
// 「我的」页重排时，`ClaimDialog`（登录/注册弹窗）被当作「trial 认领弹窗」
// 删掉了 —— 而**它同时是「用已有账号登录」的全库唯一入口**。
// 结果：`login()` 实现健在、后端接口健在，但**界面上没有任何地方能走到它**。
//
// 🔑 这类问题的形状是「**有实现、无入口**」——
//    · analyzer **不会报**（`login()` 仍是合法代码，只是没人调用）
//    · 后端测试**不会报**（接口本身是好的）
//    · 真机上表现为「点了提示『即将开放』」——**静默**，不报错
//    → 只有一条**结构断言**能守住它。
//
// # 🔴 本脚本自身的证伪方式（每次改断言都该跑一遍）
// 把 `app/lib/screens/profile_screen.dart` 里任意一处的
//     `onTap: _showLoginDialog,`
// 改回 `onTap: () => _comingSoon('登录'),`
// → 本脚本**必须变红**（第 2、3 条）。
//
// ⚠️ 口径说明：本脚本只做**词法级**扫描（按「构造函数调用形状」匹配，
//    并先剥掉行注释）。它能锁定「入口存在且不指向占位」，
//    **不能**替代真机走一遍「登录 → 退出」。

import 'dart:io';

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

/// 剥掉行注释。
///
/// 🔑 **必须剥** —— 否则「注释里提到 `TextButton`」会被当成「用了 `TextButton`」。
///
/// # 🔴 本脚本已踩的「口径差一层」（同族第 3 次 · 记下来免得再犯）
///
/// | 写法 | 漏掉的合法形式 | 后果 |
/// |---|---|---|
/// | `token` | `tokens`（另一个东西） | **假红**（误报） |
/// | `<b>` | `<b class="…">` | 假红 |
/// | `CoDialog.show(` | `CoDialog.show<String>(`（**泛型插在名字与括号之间**） | **假红** |
///
/// 🔑 **判据**：断言一个「函数被调用」时，**不要**把紧邻的左括号写进模式 ——
///    泛型实参（`show<T>(`）与可选泛型会插在那里。
///    正解：匹配 `名字` + `可选空白` + `[<(]`，或干脆只匹配名字。
///    同理，**开 / 闭标签的正则本就不该对称**（开可能带属性）。
String stripComments(String src) => src
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

int countOccurrences(String src, String pattern) =>
    pattern.allMatches(src).length;

void main() {
  print('');
  print('#' * 74);
  print('# 登录入口接线 —— 「我的」页 / 启动流程 ↔ ClaimDialog ↔ login()');
  print('#' * 74);

  final profile =
      stripComments(File('../../app/lib/screens/profile_screen.dart').readAsStringSync());
  final home =
      stripComments(File('../../app/lib/screens/home_screen.dart').readAsStringSync());
  final dialog =
      stripComments(File('../../app/lib/widgets/claim_dialog.dart').readAsStringSync());
  final field =
      stripComments(File('../../app/lib/widgets/clay_field.dart').readAsStringSync());
  final button = stripComments(
      File('../../app/lib/widgets/clay_button.dart').readAsStringSync());
  final coDialog = stripComments(
      File('../../app/lib/widgets/co_dialog.dart').readAsStringSync());
  // 🔴 2026-10-04 修：原读 `widgets/subscribe_panel.dart`（订阅**弹层**）——
  //    该文件已在「订阅页重做」时**删除**（订阅改成独立页 `/subscribe`）。
  //    ⚠️ 本脚本**不在 CI 里**，所以那次删除**没让它变红** ⇒ 也就没人发现它已经跑不起来 ——
  //       「写了没人跑 = 迟早失效」的又一个实例（讽刺的是 CI 注释里正写着这一族教训）。
  //    ⇒ 断言对象平移到 `screens/subscribe_screen.dart`，**意图不变**：
  //      订阅界面不得用 Material 按钮（防「外壳换了、内容没换」的半统一）。
  final subscribeScreen = stripComments(
      File('../../app/lib/screens/subscribe_screen.dart').readAsStringSync());

  // ── ① 入口函数存在 ──
  check('「我的」页有 `_showLoginDialog` 定义',
      RegExp(r'void _showLoginDialog\(\)').hasMatch(profile));

  // ── ② 🔴 核心：不得再出现「占位式登录入口」 ──
  // 这是本次回归的**原始形状**：入口指向 `_comingSoon`（点开只弹一句提示）。
  final placeholder = countOccurrences(profile, "_comingSoon('登录')");
  check('🔴 「我的」页不再有 `_comingSoon(\'登录\')`（防回归）',
      placeholder == 0, '出现 $placeholder 次');

  // `_comingSoon` 本身仍应存在（「绑定邮箱」还在用它），只是**不能用于登录**
  check('`_comingSoon` 仍保留（供「绑定邮箱」用）',
      profile.contains('void _comingSoon('));

  // ── ③ 🔴 登录入口仍然可达（**守意图，不守实现细节**）──
  //
  // 🔴 **2026-10-04 放宽**：原断言是「≥3 处（账号行 / 订阅卡 / 查看按钮）」——
  //    那是**当时的实现细节**，不是意图。
  //    「订阅页重做」时，订阅卡整行与「升级」按钮**有意改为跳订阅页**
  //    （`context.push('/subscribe')`，见 `profile_screen` 的 1310 / 1355 行）
  //    ⇒ 挂 `_showLoginDialog` 的地方自然只剩 1 处（「登录 / 注册」行）。
  //    ⚠️ 而本脚本**不在 CI 里** ⇒ 那次改动既没被它拦住、也没人发现它已经变红（存量问题）。
  //    ⇒ 判据：**断言要锁「用户还能不能登录」，不锁「有几个入口」**。
  final wired = countOccurrences(profile, 'onTap: _showLoginDialog');
  check('🔴 登录入口仍挂在 `_showLoginDialog`（「登录 / 注册」行）',
      wired >= 1, '实测 $wired 处 —— **0 处意味着登录能力整条消失**');
  // 🔑 配套：把「订阅卡改跳订阅页」这个**新事实**也锁住，
  //    防有人改回「引导登录」却忘了这条（那样两边会各说各话）。
  check('订阅卡入口指向订阅页（与「引导登录」的分工变更已固化）',
      profile.contains("context.push('/subscribe')"));

  // ── ④ 启动流程那条入口仍在（且走同一处弹出方式）──
  check('`home_screen` 调用 `ClaimDialog.show(`',
      home.contains('ClaimDialog.show('));

  // ── ⑤ 🔴 登录能力可达：`login()` 真的被调用 ──
  // 防「有实现、无入口」——这正是本次回归的本质。
  check('🔴 `claim_dialog` 里调用了 `login(`（登录能力可达）',
      dialog.contains('login('));
  check('`claim_dialog` 里调用了 `trialClaim(`（认领能力未被删）',
      dialog.contains('trialClaim('));

  // ── ⑥ 弹窗已粘土化：不得残留 Material 控件 ──
  // ⚠️ 用「构造函数调用形状」（带左括号）而不是裸类名 —— 见 [stripComments]。
  for (final cls in ['FilledButton', 'TextButton', 'AlertDialog', 'ElevatedButton']) {
    check('弹窗不残留 Material `$cls`',
        !dialog.contains('$cls('));
  }
  check('弹窗用了 `ClayButton`', dialog.contains('ClayButton('));
  check('弹窗用了 `ClayField`（输入框）', dialog.contains('ClayField('));

  // ── ⑥b 🆕 注册标识 = 邮箱（2026-09-29 白哥：「用邮箱注册+密码注册」）──
  check('🔴 弹窗用 `Validators.email`（标识 = 邮箱）',
      dialog.contains('Validators.email'));
  for (final gone in ['Validators.realName', 'Validators.phone', 'Validators.username']) {
    check('🔴 弹窗不再用已删校验器 `$gone`', !dialog.contains(gone));
  }
  check('邮箱输入框的 hint 是「邮箱」', dialog.contains("hintText: '邮箱'"));

  // ── ⑥c 🔴 「未登录点注册」必须走 `register`，不能走 `trialClaim` ──
  //
  // 这是**本轮修掉的一个真崩溃**：`trialClaim` 内部用 `state.userId!` /
  // `state.token!`，未登录时是 null → 抛
  // `Null check operator used on a null value`，而 `_friendlyError` 映射不到
  // 这种字符串 → **用户看到一句英文机器话**（不是闪退，但完全看不懂）。
  //
  // 判据：弹窗里**两条路都要在** —— 已登录 → 认领；未登录 → 直接注册。
  check('🔴 弹窗未登录分支走 `notifier.register(`（防「英文机器话」崩溃回归）',
      dialog.contains('notifier.register('));
  check('弹窗已登录分支仍走 `trialClaim(`（匿名账号认领能力保留）',
      dialog.contains('notifier.trialClaim('));

  // ── ⑥d 🔴 `trialClaim` 自身也必须有前置检查 ──
  // 双保险：调用方分流是「主防线」，provider 层的显式检查是「兜底」——
  // 万一将来有人从别处再调它，也不会再抛那句英文。
  final provider = stripComments(
      File('../../app/lib/providers/auth_provider.dart').readAsStringSync());
  check('🔴 `authProvider.trialClaim` 有「未登录」前置检查（兜底防英文报错）',
      provider.contains('trialClaim 需要已登录'));

  // ── ⑥e 「是否已注册」的判据 = 邮箱非空（不是靠 username 前缀猜）──
  check('🔴 `AuthState.isRegistered` 以邮箱为判据',
      provider.contains('bool get isRegistered') && provider.contains('email != null'));
  check('🔴 已删 `isTrialAccount`（靠 `trial_` 前缀猜，改用户名即失效）',
      !provider.contains('bool isTrialAccount('));
  check('「我的」页用 `isRegistered` 判断试用账号',
      profile.contains('!auth.isRegistered'));

  // ── ⑦ 输入框是**凹陷**（spec §3.6 / §6.2）──
  // 防「日后有人把它改成凸起」——凸起在语义上是「可点的粘土物件」，
  // 输入框不是（点击由内层 TextField 处理）。
  check('🔴 `ClayField` 用 `ClayState.pressed`（凹陷）',
      field.contains('ClayState.pressed'));
  check('🔴 `ClayField` 填充用 `sunken`（凹区比卡面暗）',
      field.contains('sunken'));
  check('`ClayField` **不**给 `Clay` 传 onTap（否则抢走点击、输入框无法聚焦）',
      !field.contains('onTap'));

  // ── ⑧ 按钮的禁用态走 `disabled`，不是「把 onTap 置空」──
  check('`ClayButton` 有 `enabled` 参数',
      RegExp(r'\bthis\.enabled\b').hasMatch(button));
  check('🔴 `ClayButton` 禁用时用 `ClayState.disabled`（不是 `selected`）',
      button.contains('ClayState.disabled'));

  // ── ⑨ 🔴 弹层形态统一：「我的」页不再有**另一套**弹层体系 ──
  // 🔑 断言「某个弹层改成了粘土」只能证明改过那一处；
  //    断言「**这一页已经没有 Material 弹层**」才能防住「新加一个 Material 弹窗」
  //    —— 后者才是「半统一」的复发路径。
  for (final cls in ['AlertDialog', 'SimpleDialog', 'SwitchListTile']) {
    check('🔴 「我的」页无 Material `$cls`', !profile.contains('$cls('));
  }
  check('🔴 「我的」页不直接调 `showDialog(`（弹出方式统一走 `CoDialog.show`）',
      !profile.contains('showDialog('));
  check('🔴 「我的」页调用了 `CoDialog.show(...)`（弹出方式统一）',
      RegExp(r'CoDialog\.show\s*[<(]').hasMatch(profile));

  // ── ⑩ 外壳是**平面**而非粘土（spec §〇 规则 1：有体积的只可能是**可点**的东西）──
  check('🔴 `CoDialog` 外壳不用 `Clay(`（弹窗不可点 → 应是平面卡）',
      !coDialog.contains('Clay('));
  check('`CoDialog` 外壳用卡面色 + 外阴影（平面卡）',
      coDialog.contains('card.argb32') && coDialog.contains('BoxShadow'));

  // ── ⑪ 按钮主 / 次变体：主 = 选中(accent) · 次 = 凸起(sunken) ──
  check('`ClayButton` 有 `secondary` 变体', button.contains('secondary'));
  check('🔴 次按钮用 `raised`（凸起）+ `sunken` 填充，不与主按钮撞脸',
      button.contains('ClayState.raised') && button.contains('sunken'));

  // ── ⑫ 订阅界面的**内容**也统一了（外壳改了、内容没改 = 还是半统一）──
  //
  // 🔑 2026-10-04：对象由「订阅弹层」改为「订阅**页**」（`subscribe_screen.dart`）——
  //    架构从弹层改成了独立页，但**这条守卫的意图不变**。
  check('🔴 订阅页不再有 Material `FilledButton`',
      !subscribeScreen.contains('FilledButton('));
  check('订阅页用了 `ClayButton`', subscribeScreen.contains('ClayButton('));

  // ── ⑨b 🆕 共读群入口在**关于页**，不在「我的」页（2026-09-29 白哥定）──
  //
  // 🔴 **为什么必须剥注释后再断言**：搬迁后「我的」页留了一条
  //    「已移到关于页」的分组注释，里面**含旧入口名** ——
  //    不剥注释就会把这条注释当成「入口还在」，得出**假红**。
  //    （这是本项目第 4 次踩「口径差一层」，见 stripComments 的说明。）
  //
  // 🔴 **2026-10-04 更新**：入口改名为「**加入英文原著共读群**」（白哥定）——
  //    它承载的是**群二维码**，不是客服个人微信。
  //    ⇒ 正向断言改用新名 / 新方法名；**另加两条反向断言**守旧名不得复活
  //      （改名后最常见的错法是「新名加上、旧名没删」）。
  final about = stripComments(
      File('../../app/lib/screens/about_screen.dart').readAsStringSync());

  // 🔴 **口径要精确到「对象」**：只查裸字符串 `'加入英文原著共读群'` 会**假绿** ——
  //    弹窗的 `title:` 也是这个名字 ⇒ 「入口 label 被改回旧名」也照样通过。
  //    （实测踩到：注入回归时正向断言没红，就是这个原因。
  //      与 `check-prototype.js` 那条「『某处不该有 X』的『某处』要精确到对象」同族。）
  check('🔴 「关于」页有「加入英文原著共读群」入口',
      about.contains("label: '加入英文原著共读群'"));
  check('🔴 「关于」页承载群二维码弹窗（`_showGroupQrcodeDialog` + `public/qrcode`）',
      about.contains('_showGroupQrcodeDialog') && about.contains('public/qrcode'));
  // 🔴 反向：旧入口名不得复活（`stripComments` 已剥注释，注释里的改名记载不会误伤）
  check('🔴 「关于」页已无旧入口名「联系工作人员」',
      !about.contains("'联系工作人员'"));
  // 🔴 反向：旧方法名不得复活（同上，`_showContactDialog` 只应留在改名说明的注释里）
  check('🔴 已无旧方法名 `_showContactDialog`', !about.contains('_showContactDialog'));

  check('🔴 「我的」页**不再**有该入口（搬迁要搬净，不是复制一份）',
      !profile.contains('联系工作人员') && !profile.contains('加入英文原著共读群'));
  check('🔴 「我的」页已删 `_buildContactCard` / `_showContactDialog`',
      !profile.contains('_buildContactCard') && !profile.contains('_showContactDialog'));

  _report();
}

void _report() {
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：有人把「我的」页的登录入口改回了占位');
    print('    （`() => _comingSoon(\'登录\')`）—— 那会让**登录能力整条消失**，');
    print('    而 analyzer 与后端测试都发现不了。见本文件头部说明。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
