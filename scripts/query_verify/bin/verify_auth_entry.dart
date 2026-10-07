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
//
// 把 `app/lib/screens/profile_screen.dart` 里那一处
//     `onTap: _showLoginDialog,`
// 删掉（或改成任何不调用它的东西）
// → 本脚本**必须变红**（第 ③ 条「登录入口仍挂在 `_showLoginDialog`」）。
//
// ⚠️ 2026-10-07：原证伪方式是「改回 `onTap: () => _comingSoon('登录'),`」——
//    但 `_comingSoon` 辅助函数**已在同日删除**（改邮箱接入真实现后它成了死代码）
//    ⇒ 那个写法现在**编译不过**，已不是有效的证伪手段。
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
/// 剥掉**整行注释**（注释前可有空白）。
///
/// # 🔴 为什么是「整行」而不是「行内切 `//`」（2026-10-04 修 · 实测踩到）
///
/// 原实现是「每行找 `//`、切掉后半」—— 它有一个**方向相反**的故障：
/// **代码行里含 `//` 时会被当成注释起点切掉**，于是注释之后的正文**整段消失**。
/// 实测形态：
/// ```dart
/// final _dup = NetworkImage('https://x/api/public/qrcode');   // ← 是代码，不是注释
/// ```
/// 这行里 `https://` 含 `//` ⇒ 被切掉 ⇒ 拿 `public/qrcode` 去查会**查不到**
/// （若是**反向**断言「不得含 X」，则是**假绿**）。
/// 📌 判据：**「剥注释」这个动作本身会改变被检查的文本** ——
///    它修好了「注释里的说明造成假红」，却可能引入「URL / 字符串里的 `//` 造成漏检」。
///    ⇒ 剥注释**只能在「整行注释」这一粒度上做**。
/// ⚠️ 代价（如实记录）：**行尾注释不被剥** —— 若有人把被禁的写法写进行尾注释，
///    本脚本会误报。已知盲区，不假装没有。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');


/// 只取**实现部分** —— 切掉 `#[cfg(test)]` 之后的测试代码。
///
/// # 🔴 为什么必须切（证伪时实测踩到）
///
/// 本组断言查的是「**实现**里有没有 X」，而 Rust 源文件里**同时包含 tests mod** ——
/// 测试代码会**复述**实现里的字符串。实测：
/// ```rust
/// // 实现
/// return Err("该账号尚未设置密码，请先完成注册".to_string());
/// // 测试（同一个文件里）
/// assert!(e.contains("尚未设置密码"));
/// ```
/// ⇒ 把**实现**的报错文案改掉后，断言查 `authRs.contains('尚未设置密码')`
///    **仍然通过**（被测试里那句命中）⇒ **假绿**，而 `change_password`
///    的实际行为已经变了。
///
/// 📌 判据：**断言作用的切片范围必须等于「被测对象」** ——
///    这里被测对象是「实现」，就**必须排除测试**。
///    （同族：本文件另一条「只查裸字符串会假绿」——都是「口径要精确到对象」。）
String implOnly(String src) {
  final i = src.indexOf('#[cfg(test)]');
  return i < 0 ? src : src.substring(0, i);
}
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

  // 🔴 **2026-10-07 反转**（原断言是「`_comingSoon` 仍保留（供「绑定邮箱」用）」）
  //
  // 那条锁的是**当时的实现状态** —— 而「绑定邮箱」那一行现已接上真实现
  // （`_showChangeEmailDialog`；后端 `/api/auth/change-email/code` + `/change-email`
  //  两步端点）⇒ `_comingSoon` 变成**零调用方的死代码**，本次删除它。
  //
  // 📌 这是判据「**断言会保护错误**（锁住已废止事实 ⇒ 改对了反红）」的又一实例。
  //    修法照旧：**断言改锁「意图」，不锁「某个辅助函数还在不在」** ——
  //    意图是「界面上不得有『即将开放』式占位入口」。
  //    ⚠️ 反向断言天然免疫这类漂移（配上第 ② 条的正向前提 ⇒ 不会退化成恒假）。
  check('🔴 「我的」页不再有 `_comingSoon` 占位辅助（所有入口都已接真实现）',
      !profile.contains('void _comingSoon('));

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

  // 🆕 **2026-10-04 平移（第二次）**：二维码弹层已抽到**公共组件**
  //    `widgets/group_qrcode_dialog.dart`（**唯一实现**）—— 因为**书库空态**与
  //    **导入失败（DRM）**也要用它（判据同 `HeaderChip`：「外观一致 = 只有一处定义」）。
  //    ⇒ 本组断言的**读取对象**随之改到「关于页 + 公共弹层」**两处**，
  //      而**意图一字未变**：①「关于」页有共读群入口 ② 点它能出二维码。
  //    🔑 强度是**提高**了的（分工见下面两条）：
  //       · 关于页侧：「**作为 label 传的**是那个公共常量」（仍精确到对象）
  //       · 弹层侧：「常量的**值**确实是那个名字」+「二维码地址确实在弹层里」
  //    ⚠️ 若只查 about 里含 `GroupQrcodeDialog`，就锁不住「常量值被改坏」——
  //       那种情况下入口与弹窗会**同步变成错名字**，而断言照样通过（假绿）。
  final qrDialog = stripComments(
      File('../../app/lib/widgets/group_qrcode_dialog.dart').readAsStringSync());

  // 🔴 **口径要精确到「对象」**：只查裸字符串 `'加入英文原著共读群'` 会**假绿** ——
  //    弹窗的 `title:` 也是这个名字 ⇒ 「入口 label 被改回旧名」也照样通过。
  //    （实测踩到：注入回归时正向断言没红，就是这个原因。
  //      与 `check-prototype.js` 那条「『某处不该有 X』的『某处』要精确到对象」同族。）
  check('🔴 「关于」页有「加入英文原著共读群」入口（label 取自公共常量）',
      about.contains('label: GroupQrcodeDialog.kTitle'));
  // 🔴 常量的**值**必须独立核对 —— 否则「把 kTitle 改成别的字」会**假绿**。
  check('🔴 入口/弹窗文案常量 = 「加入英文原著共读群」',
      qrDialog.contains("kTitle = '加入英文原著共读群'"));
  check('🔴 「关于」页承载群二维码弹窗（走公共组件 `GroupQrcodeDialog.show`）',
      about.contains('GroupQrcodeDialog.show(context)'));
  check('🔴 二维码地址在公共弹层里（`public/qrcode`）',
      qrDialog.contains('public/qrcode'));
  // 🔴 反向：旧入口名不得复活（`stripComments` 已剥注释，注释里的改名记载不会误伤）
  check('🔴 「关于」页已无旧入口名「联系工作人员」',
      !about.contains("'联系工作人员'"));
  // 🔴 反向：旧方法名不得复活（同上，`_showContactDialog` 只应留在改名说明的注释里）
  check('🔴 已无旧方法名 `_showContactDialog`', !about.contains('_showContactDialog'));

  check('🔴 「我的」页**不再**有该入口（搬迁要搬净，不是复制一份）',
      !profile.contains('联系工作人员') && !profile.contains('加入英文原著共读群'));
  check('🔴 「我的」页已删 `_buildContactCard` / `_showContactDialog`',
      !profile.contains('_buildContactCard') && !profile.contains('_showContactDialog'));


  // ══════════════════════════════════════════════════════════════════════
  // 【改密码】2026-10-05 —— 「修改密码」全链路（后端 + 前端）
  //
  // 为什么要它：「修改密码」是三条**安全约束**的复合体，任何一条被删掉，
  // 功能仍「能用」、测试也未必报 —— 但会变成真漏洞：
  //   ① 不验原密码 ⇒ 拿到已解锁设备的人可静默改密码，主人**再也登不回来**
  //   ② 不失效其他会话 ⇒ 账号被盗后主人改密码，**攻击者会话仍然有效**
  //   ③ 不查新旧相同 ⇒ 「修改」成空操作，而用户以为改成功了
  // 前端同理：3 个字段 · 每框一个显隐切换 · 副作用**事先**告知。
  // ══════════════════════════════════════════════════════════════════════
  {
    // 🔴 必须 `implOnly` —— 否则会被 tests mod 里的同名字符串命中而**假绿**
    //    （见 `implOnly` 文档：实测「改掉报错文案但断言仍通过」）
    final authRs = implOnly(stripComments(
        File('../../backend/crates/api_server/src/auth.rs').readAsStringSync()));
    final routesRs = implOnly(stripComments(
        File('../../backend/crates/api_server/src/routes.rs').readAsStringSync()));
    final profile = stripComments(
        File('../../app/lib/screens/profile_screen.dart').readAsStringSync());
    final dlg = stripComments(
        File('../../app/lib/widgets/change_password_dialog.dart')
            .readAsStringSync());
    final client = stripComments(
        File('../../app/lib/api/auth_client.dart').readAsStringSync());

    // ── 后端 ①：密码规则**只有一处定义**（注册与改密码共用）──
    check('后端有 `validate_password_strength`（密码规则的唯一权威）',
        authRs.contains('pub fn validate_password_strength('));
    check('🔴 `register` 调它（不再自己写一套）',
        authRs.contains('validate_password_strength(&req.password)?'));
    // 🔴 反向：**不得**回退成按字节数判长度
    //    （旧实现 `password.len() < 6` —— UTF-8 字节数，与前端「字符数」口径不同；
    //     实测 `"a1密码"` 旧实现放行，而它在用户眼里只有 4 个字符）
    check('🔴 不得回退成 `password.len() < 6`（那是**字节数**，与前端口径不一致）',
        !authRs.contains('password.len() < 6'));
    check('🔴 用 `chars().count()` 数**字符**（与前端口径对齐）',
        authRs.contains('password.chars().count() < 6'));

    // ── 后端 ②：三个安全约束 ──
    check('🔴 ① 验原密码（`verify_password(&req.old_password`）',
        authRs.contains('verify_password(&req.old_password'));
    check('🔴 ② 失效**其他**会话、保留当前（`token != ?2`）',
        authRs.contains('DELETE FROM tokens WHERE user_id = ?1 AND token != ?2'));
    check('🔴 ③ 新旧相同要拒（`new_password == req.old_password`）',
        authRs.contains('req.new_password == req.old_password'));
    check('匿名账号（无密码）给**明确**报错，而不是含糊的「原密码不正确」',
        authRs.contains('尚未设置密码'));

    // ── 后端 ③：路由 + 鉴权面 ──
    check('路由 `/api/auth/change-password` 已注册',
        routesRs.contains('/api/auth/change-password'));
    // 🔴 改谁的密码**只能由 token 决定** —— 若允许 body 传 user_id，
    //    就等于开了「改别人密码」的口子（与 delete_me 同一条判据）
    final cpInput =
        RegExp(r'struct ChangePasswordInput\s*\{[^}]*\}').firstMatch(routesRs);
    check('🔴 `ChangePasswordInput` **只有** old/new 两个字段（无 user_id）',
        cpInput != null && !cpInput.group(0)!.contains('user_id'),
        '若接受 user_id，就是「改别人密码」的口子');

    // ── 前端 ④：入口 + 弹层形态 ──
    check('「我的」页有「修改密码」入口行', profile.contains("title: '修改密码'"));
    // 🔴🔴 **接线断言**（证伪时发现前一条**锁不住**这件事）：
    //    只查 `title: '修改密码'` —— 行在，但把 `onTap` 换回
    //    `() => _comingSoon('修改密码')` 时**照样通过**。
    //    ⇒ 这正是判据「**子串断言锁不到「接线」**」的又一次实例：
    //      「有这一行」≠「点它能打开」。
    //    ✅ 修法：锁**实参**（`onTap:` 后面跟的是哪个方法），不是锁标题字符串。
    check('🔴 入口 `onTap` **真的**指向弹层方法（不是占位）',
        profile.contains('onTap: _showChangePasswordDialog'));
    check('弹层 `show` 可被调起（`ChangePasswordDialog.show`）',
        profile.contains('ChangePasswordDialog.show(context)'));
    check('弹层用 `CoDialog`（与登录/注册同一套观感）', dlg.contains('CoDialog('));
    // 🔑 用**计数**锁「3 个字段」——「A 里有 X」锁不到「少了一个」
    final fieldCount = RegExp(r'ClayField\(').allMatches(dlg).length;
    check('🔴 弹层有 **3** 个凹陷字段（原/新/确认）', fieldCount == 3,
        '实际 $fieldCount 个');
    // 🔑 每框一个显隐切换（白哥选「每框一个」而不是总开关）
    final eyeCount = RegExp(r'_eye\(').allMatches(dlg).length;
    check('🔴 显隐切换每框一个（共 3 处调用）', eyeCount >= 3, '实际 $eyeCount 处');

    // ── 前端 ⑤：副作用告知 + 错误文案同位置 + 网络层 ──
    check('🔴 弹层说明「其他设备需要重新登录」（副作用**事先**告知）',
        dlg.contains('其他设备需要重新登录'));
    check('客户端校验与服务端错误在**同一位置**显示', dlg.contains('_error ?? '));
    check('`auth_client` 用 `Authorization: Bearer`（鉴权只认 token）',
        client.contains("'Authorization': 'Bearer "));

    // ── 前端 ⑥：反向（不得出现的东西）──
    check('弹层不得用 Material `AlertDialog`（要走 CoDialog）',
        !dlg.contains('AlertDialog('));
    check('弹层不得用 `IconButton`（48px 最小点击区 + 水波纹，会撑高凹陷框）',
        !dlg.contains('IconButton('));
    check('`ClayField.trailing` 是**通用**参数（不得叫 obscureToggle 之类业务名）',
        !stripComments(
                File('../../app/lib/widgets/clay_field.dart').readAsStringSync())
            .contains('obscureToggle'));
  }

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
