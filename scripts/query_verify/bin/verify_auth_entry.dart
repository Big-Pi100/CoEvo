// CoEvo · 「我的」页 UI 接线验收
//   ① **登录入口接线** —— 防「有实现、无入口」（analyzer 与后端测试都发现不了）
//   ② **弹层形态统一** —— 防「半统一」复发（新加一个 Material 弹窗即变红）
//   ③ 🔴 **启动不弹窗 + 未登录是一等状态**（2026-10-09 重写）
//      —— 试用账号机制退役 ⇒ 启动**不得**有任何自动弹窗或自动建号；
//         「未登录」时账号组那一整行**就是**登录入口（唯一入口，必须常驻）
//   ④ 🆕 **账号组形态**（2026-10-08 · 第二批）—— 第一栏 = **状态**（点击下拉），
//      「修改邮箱」= **四个字的动作名**；同时防两个反向：
//      「整行点击被改回改昵称」与「改昵称能力被静默删掉」
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
// ⚠️ 2026-10-09：该弹窗已改名 `AuthDialog`（文件 `auth_dialog.dart`）——
//    「Claim（认领）」那个概念随试用账号机制一起删除，
//    名字不改的话那个已消失的概念会从命名里渗回来。
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

// 🔑 **纯 Dart** 判据（不 import Flutter）⇒ 本脚本可以直接把它当普通函数调用。
//    ⚠️ 2026-10-09：`shouldPromptLoginOnLaunch` 已删（启动不再弹窗）；
//       本文件现在只剩 `emailFromStoredLoginId` 一条判定。
import '../../../app/lib/services/auth_session_policy.dart';

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
  print('# 登录入口接线 —— 「我的」页 / 启动流程 ↔ AuthDialog ↔ login()');
  print('#' * 74);

  final profile =
      stripComments(File('../../app/lib/screens/profile_screen.dart').readAsStringSync());
  final home =
      stripComments(File('../../app/lib/screens/home_screen.dart').readAsStringSync());
  final dialog =
      stripComments(File('../../app/lib/widgets/auth_dialog.dart').readAsStringSync());
  final field =
      stripComments(File('../../app/lib/widgets/clay_field.dart').readAsStringSync());
  final button = stripComments(
      File('../../app/lib/widgets/clay_button.dart').readAsStringSync());
  final coDialog = stripComments(
      File('../../app/lib/widgets/co_dialog.dart').readAsStringSync());
  // 🔴 2026-10-04 修：原读 `widgets/subscribe_panel.dart`（订阅**弹层**）——
  //    该文件已在「订阅页重做」时**删除**（订阅改成独立页 `/subscribe`）。
  //    ✅ 2026-10-10 更正：当时这里写着「本脚本**不在 CI 里**」—— **该事实已过时**：
  //       它现在**就在 CI 里**（`ci.yml` 的 `Run dart run bin/verify_auth_entry.dart`）。
  //       📌 判据：**注释里的「事实」也会过期** —— 而它比代码更容易骗人
  //          （代码错了会红，注释错了只会让人做出错误判断）。
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
  //    ⚠️ 而本脚本当时**不在 CI 里** ⇒ 那次改动既没被它拦住、也没人发现它已经变红。
  //       （2026-10-10 更正：它**现在在 CI 里** —— 见上方 `subscribe_panel` 旁的说明。）
  //    ⇒ 判据：**断言要锁「用户还能不能登录」，不锁「有几个入口」**。
  final wired = countOccurrences(profile, 'onTap: _showLoginDialog');
  check('🔴 登录入口仍挂在 `_showLoginDialog`（「登录 / 注册」行）',
      wired >= 1, '实测 $wired 处 —— **0 处意味着登录能力整条消失**');
  // 🔑 配套：把「订阅卡改跳订阅页」这个**新事实**也锁住，
  //    防有人改回「引导登录」却忘了这条（那样两边会各说各话）。
  check('订阅卡入口指向订阅页（与「引导登录」的分工变更已固化）',
      profile.contains("context.push('/subscribe')"));

  // ── ③b 🔴 「我的」页**不得**因后端接口失败而整页失败（2026-10-10 真机踩到）──
  //
  // 症状：`getProfile()`（**需要登录**）返回 401 ⇒ 整页被替换成「加载失败」
  //   ⇒ 同页的 `StatsCard()`（学习记录，**纯端侧、零网络**）与所有入口**一起消失**
  //   ⇒ 用户以为「数据没同步/丢了」，而数据一直在本机。
  // 📄 `docs/review/device-sync-and-profile-failure-2026-10-10.md` §一.6/§一.7
  //
  // 🔑 判据（该文件 `_buildTopBar` 里早就写着）：**数据在后端 → 必须登录；
  //    数据在端侧 → 不需要** ⇒ **一个页面里不同数据源的失败必须分层降级**。
  check('🔴 已删掉「整页错误视图」（`_buildErrorView`）——'
      '否则一个需登录的接口失败会连带抹掉**纯端侧**的学习记录',
      !profile.contains('_buildErrorView'));
  check('🔴 `body:` **不再**按「取资料失败」三选一（不得出现 `_error != null ?` 式整页分叉）',
      !RegExp(r'body:\s*_isLoading[\s\S]{0,120}?_error\s*!=\s*null').hasMatch(profile),
      '分层降级：账号资料失败只影响它自己那一块');
  check('🔑 学习记录卡 `StatsCard()` 仍在页面内容里（端侧数据不受登录态影响）',
      profile.contains('StatsCard()'));

  // 🔴 **401 必须有出口** —— 旧实现只给「重试」，而 401 是**终态**：
  //    重试复用 `authProvider` 里**同一个**失效 token ⇒ **必然再 401**
  //    ⇒ 用户被卡死，唯一出路是杀 App 重开（真机复现）。
  check('🔴 有 401 的出口函数 `_reloginAfterTokenInvalid`',
      RegExp(r'Future<void> _reloginAfterTokenInvalid\(\)').hasMatch(profile));
  check('🔴 该出口调 `tryRestore()`（它会**在服务端校验** token，失效则清凭据）',
      RegExp(r'_reloginAfterTokenInvalid[\s\S]{0,700}?tryRestore\(\)')
          .hasMatch(profile));
  // 🔑 判别**必须用类型**，不能用 `e.toString().contains('401')` ——
  //    后者是「用字符串当类型」：改一次文案就静默失去出口，且不报错。
  check('🔴 401 的判别用**类型**（`isUnauthorized`），不是字符串匹配',
      profile.contains('isUnauthorized') &&
          !RegExp(r"contains\(\s*'401'\s*\)").hasMatch(profile));
  final userApi =
      stripComments(File('../../app/lib/api/user_api_client.dart').readAsStringSync());
  check('🔴 `getProfile()` 抛出**带状态码**的类型（`ApiStatusException`）',
      userApi.contains('class ApiStatusException') &&
          userApi.contains('throw ApiStatusException(resp.statusCode, path)'),
      '否则调用方只能靠字符串识别 401 —— 改文案即静默失效');

  // ── ④ 🔴 启动流程**不得**再自动弹窗、也不得再自动建号（2026-10-09）──
  //
  // 白哥：「不需要试用账号，未登录状态不是可以直接用吗？试用账号没有任何存在意义」。
  // 退役后启动路径上**什么都不做** —— 这条断言守的是「别把它加回来」：
  //   · 加回自动弹窗 ⇒ 新用户一打开就被拦一道「请登录」（而他本来就能用）
  //   · 加回自动建号 ⇒ 又会出现「匿名账号 + 1 小时假订阅」那套东西
  check('🔴 `home_screen` 不再调 `AuthDialog.show(`（启动不弹窗）',
      !home.contains('AuthDialog.show('));
  check('🔴 `home_screen` 已无 `_showAuthDialog` / `_initAuth`（启动无副作用）',
      !home.contains('_showAuthDialog') && !home.contains('_initAuth'));
  check('🔴 `home_screen` 不再引用 `authProvider`（它已不关心登录态）',
      !home.contains('authProvider'));

  // ── ⑤ 🔴 登录能力可达：`login()` 真的被调用 ──
  // 防「有实现、无入口」——这正是本脚本存在的理由。
  check('🔴 `auth_dialog` 里调用了 `login(`（登录能力可达）',
      dialog.contains('login('));
  check('🔴 `auth_dialog` 里调用了 `register(`（注册能力可达）',
      dialog.contains('notifier.register('));

  // ── ⑤b 🔴 试用账号机制**不得**复活（端侧全库扫）──
  //
  // 🔴 扫的是**整个 app/lib**（不是某一个文件）：
  //    「还有没有别处在调 `/api/trial/`」这个问题，只扫一个文件答不了
  //    —— 这正是本文件里 `sync_cloud_badge` 那次「只扫一个文件 ⇒ 假绿」的教训。
  final allDart = <File>[];
  for (final e in Directory('../../app/lib').listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) allDart.add(e);
  }
  final trialHits = <String>[];
  for (final f in allDart) {
    final src = stripComments(f.readAsStringSync());
    if (src.contains('/api/trial/') ||
        src.contains('trialStart(') ||
        src.contains('trialClaim(') ||
        src.contains('hasUsedTrial(')) {
      trialHits.add(f.uri.pathSegments.last);
    }
  }
  check('🔴 端侧**没有任何**文件再碰试用账号（`/api/trial/` · trialStart · trialClaim · hasUsedTrial）',
      trialHits.isEmpty,
      trialHits.isEmpty ? '' : '实测命中：$trialHits');

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

  // ── ⑥c 🔴 注册路径：只有 `register` 一条（认领那条已删）──
  //
  // 历史（值得留着）：`trialClaim` 内部用 `state.userId!` / `state.token!`，
  // 未登录时是 null → 抛 `Null check operator used on a null value`，
  // 而 `_friendlyError` 映射不到这种字符串 → **用户看到一句英文机器话**。
  // 2026-10-09 起试用账号机制退役 ⇒ 那条路**从结构上不存在了**。
  check('🔴 注册走 `notifier.register(`（防「英文机器话」崩溃回归）',
      dialog.contains('notifier.register('));
  // 🔴 反向：认领路径**不得**复活（它是试用账号机制的另一半）。
  check('🔴 认领路径不得复活（`trialClaim` 在弹窗里必须为零）',
      !dialog.contains('trialClaim'));

  // ── ⑥e 「是否已注册」的判据 = 邮箱非空（不是靠 username 前缀猜）──
  final provider = stripComments(
      File('../../app/lib/providers/auth_provider.dart').readAsStringSync());
  check('🔴 `AuthState.isRegistered` 以邮箱为判据',
      provider.contains('bool get isRegistered') && provider.contains('email != null'));
  check('🔴 已删 `isTrialAccount`（靠 `trial_` 前缀猜，改用户名即失效）',
      !provider.contains('bool isTrialAccount('));
  // 🔴 反向：端侧不得再有「已用过试用」标记（它是自动建号那套的配套）。
  check('🔴 端侧不得再读写 `coevo_trial_used`（试用名额概念已删）',
      !provider.contains('coevo_trial_used'));

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

  // ══════════════════════════════════════════════════════════════════════
  // ══════════════════════════════════════════════════════════════════════
  // 【2026-10-09】启动**不弹窗** + 「未登录」时入口**常驻**
  //
  // 背景（两段）：
  // · 2026-10-08：白哥真机报「已登录状态还是会弹出登录弹窗」——
  //   根因是测试机的会话是**匿名试用账号**（`users.email` 为 NULL）
  //   ⇒ 旧判据「已登录但没有邮箱 ⇒ 引导注册」**每次启动都成立**。
  //   当时的修法是「判据换成真实登录态」，抽成纯函数 `shouldPromptLoginOnLaunch`。
  // · 🔴 2026-10-09：白哥直接否掉了**前提本身** ——
  //   「不需要试用账号，未登录状态不是可以直接用吗？试用账号没有任何存在意义」。
  //   ⇒ 试用账号机制整体退役；`shouldPromptLoginOnLaunch` 的两个输入都失去意义
  //     （没有「试用名额」这回事；「未登录」是一等状态，不该被拦）
  //   ⇒ **启动时不再有任何自动弹窗**。
  //
  // # 🔴 本组要防的三件事（都是一改就静默坏掉）
  //   ① 启动又被加上自动弹窗 / 自动建号；
  //   ② 「未登录」那一行入口被删 ⇒ 登录能力整条消失（**本脚本存在的理由**）；
  //   ③ `verifyToken` 的宽容兜底把已注册账号降级成未注册。
  //
  // # 🔴 证伪方式
  // · 在 `home_screen` 里加回 `AuthDialog.show(context)` ⇒ 「启动不弹窗」必须变红。
  // · 把 `profile` 里未登录分支的 `onTap: _showLoginDialog` 删掉 ⇒ 入口断言必须变红。
  // · 把 `emailFromStoredLoginId` 改成 `return v;` ⇒ `trial_*` 那条必须变红。
  // ══════════════════════════════════════════════════════════════════════
  {
    // ── ① 「未登录」时账号组那一整行**就是**登录入口（且是全库唯一）──
    //
    // 🔴 为什么这条是全脚本的核心：账号入口一旦不可达，
    //    登录 / 注册 / 找回订阅 / 跨设备同步**全部**一起消失，
    //    而 analyzer 与后端测试**都发现不了**（见文件头「有实现、无入口」）。
    final loginEntries = countOccurrences(profile, 'onTap: _showLoginDialog');
    check('🔴 登录入口**只有一处**（未登录时账号组那一行）',
        loginEntries == 1,
        '实测 $loginEntries 处 —— 0 处 = 登录能力整条消失；>1 处 = 多出未经设计的入口');
    check('🔴 它是**未登录分支**里的整行入口（`if (!auth.isAuthenticated)`）',
        profile.contains('if (!auth.isAuthenticated)'));

    // 🔴 反向：给「未完成注册的已登录账号」额外挂入口那一段（`if (trial)`）
    //    **不得**复活 —— 那是试用账号时代的补丁，前提已不存在。
    check('🔴 `if (trial)` 那段补丁不得复活（试用账号机制已删）',
        !profile.contains('if (trial)'));
    // 🔴 反向：已登录态不得再显示「试用账号」字样。
    check('🔴 「已登录 · 试用账号」文案不得复活',
        !profile.contains('试用账号'));

    // ── ② 兜底：`verifyToken` 宽容兜底丢 email ⇒ 不能把已注册账号降级成未注册 ──
    //
    // 🔴 为什么仍要有这组：`AuthClient.verifyToken` 在网络失败时返回
    //    `{'valid': true}`（**刻意宽容**：不该因一次网络抖动把用户登出），
    //    但它**带不回 `email`** ⇒ `isRegistered` 从 true 掉成 false
    //    ⇒ 界面少显示一次邮箱，且**存量账号的订阅覆盖层放行判断**会漂。
    check('🔴 本地已存的登录标识可回填邮箱（`a@b.com` → 原样返回）',
        emailFromStoredLoginId('a@b.com') == 'a@b.com');
    check('🔴 存量匿名账号的 `trial_*` 标识**不得**被当成邮箱（否则反向误判）',
        emailFromStoredLoginId('trial_1133f074') == null);
    check('空白 / null 标识 ⇒ null（不留空串 —— 空串也会让 `isRegistered` 误判）',
        emailFromStoredLoginId(null) == null &&
            emailFromStoredLoginId('') == null &&
            emailFromStoredLoginId('   ') == null);
    check('🔴 `tryRestore` 真的用了它兜底（防「写了没人调」）',
        provider.contains('emailFromStoredLoginId('));

    // ── ③ 后端：两个 trial 路由**不得**复活 ──
    final routesRs = implOnly(stripComments(
        File('../../backend/crates/api_server/src/routes.rs').readAsStringSync()));
    check('🔴 后端不再注册 `/api/trial/` 路由（`start` / `claim` 均已删）',
        !routesRs.contains('/api/trial/'),
        '复活它 = 又给未登录用户造匿名账号');
    check('🔴 后端注册入口只有 `auth/register`（认领路径已删）',
        routesRs.contains('/api/auth/register') &&
            !routesRs.contains('trial_handler'));
  }

  // 【2026-10-08 · 第二批】账号组形态：第一栏 = **状态**，点击**下拉**
  //
  // 白哥原话：「账号下第一个栏目 —— 账号登录状态，**现在不需要修改昵称**，
  //   点击**下拉**修改密码、退出账号、修改邮箱等。」
  // 外加：「『修改邮箱』的文字说明不合适，**只要这四个字**」。
  //
  // 🔴 本组要防的两个方向（都是一改就静默坏掉的东西）：
  //    ① **整行点击**若被改回 `_editName` ⇒ 与白哥的指令相反（下拉没了）；
  //    ② 反过来若「改昵称」被顺手删掉 ⇒ 能力静默消失（编译器不报）。
  //    ⇒ 所以**两个都要断言**，缺一个就只防住一半。
  //
  // # 🔴 证伪方式
  // · 把第一行的 `onTap` 改回 `_editName` ⇒ 「点击目标是展开 / 收起」必须变红。
  // · 删掉下拉里的「修改昵称」项 ⇒ 「改昵称能力没被删」必须变红。
  // · 把 `bool _accountExpanded = false` 改成 `= true` ⇒ 「默认收起」必须变红。
  // · 把 `title: '修改邮箱'` 改回 `title: auth.email` ⇒ 动作名断言必须变红。
  // 【2026-10-09 追加】
  // · 把「注销账号」那行 `onTap:` 删掉 ⇒ 「只有一处」变 0 ⇒ 必须变红。
  // · 在页尾**再加一份** `onTap: _showDeleteAccountDialog` ⇒ 计数变 2 ⇒ 必须变红。
  // · 把「退出账号」与「注销账号」对调 ⇒ 顺序断言必须变红。
  // ══════════════════════════════════════════════════════════════════════
  {
    check('🔴 账号组**默认收起**（`bool _accountExpanded = false;` —— 形态成立的默认值）',
        RegExp(r'bool _accountExpanded = false;').hasMatch(profile));
    check('🔴 第一行点击 = **展开 / 收起**（「点击下拉」的字面落实）',
        profile.contains('_accountExpanded = !_accountExpanded'));
    // 🔑 正向：改昵称**没被删**，只是搬进了下拉区 —— 它若零调用方就是死代码，
    //    而「零调用方」**不是编译错误** ⇒ 只有断言能守。
    check('🔴 改昵称能力未消失（`onTap: _editName` 仍有调用点）',
        countOccurrences(profile, 'onTap: _editName') >= 1,
        '实测 ${countOccurrences(profile, 'onTap: _editName')} 处');
    // 🔑 「点击下拉」= **就地展开**，不是跳一个新页面/弹层。
    check('🔴 下拉是**就地展开**（`AnimatedSize`，与兴趣筛选同一交互语汇）',
        profile.contains('AnimatedSize('));

    // ── 「修改邮箱」= **四个字的动作名**（白哥：文字说明不合适）──
    check('🔴 下拉项是动作名「修改邮箱」',
        profile.contains("title: '修改邮箱'"));
    // 🔴 反向两条：**旧写法不得复活**。
    //    · `title: auth.email` —— 把邮箱**地址**当条目名（那是「显示」，不是「动作」）
    //    · 「未绑定邮箱」  —— 同一个旧形态的空态文案
    //    · 「登录账号 · 找回账号靠它」—— 那条被点名的**说明**文案
    //    📌 反向断言对实现更换天然免疫，正适合守「**别改回去**」这类要求。
    //
    // 🔴🔴 2026-10-09 修：这条原写作 `!profile.contains('title: auth.email')` ——
    //    **它会假红**。同批把第一行的副标题改成 `subtitle: auth.email ?? '已登录'`
    //    （那是**正确**的：副标题该显示邮箱），而 `subtitle: auth.email`
    //    这串里**含有**子串 `title: auth.email` ⇒ 正确代码被判违规。
    //    📌 判据：**子串断言必须考虑「被撞的车牌」** —— `X` 与 `subX` 的包含关系
    //       在本项目已踩过多次（`token`/`tokens`、`<b>`/`<b class>`）。
    //    ✅ 改法：按**行首**判定（`title:` 是 `_navTile` 的**命名参数**，必在行首缩进后），
    //       这样 `subtitle:` 永远不会被误判成 `title:`。
    check('🔴 邮箱地址不再当条目名（`title: auth.email` 不得复活）',
        !profile.split('\n').any((l) => l.trimLeft().startsWith('title: auth.email')));
    check('🔴 旧空态文案「未绑定邮箱」不得复活', !profile.contains('未绑定邮箱'));
    check('🔴 被点名的说明文案「登录账号 · 找回账号靠它」已删且不得复活',
        !profile.contains('登录账号 · 找回账号靠它'));

    // ── 「注销账号」也在下拉区（2026-10-09 白哥：「注销账号也应该放进去」）──
    //
    // 🔑 用**计数 == 1** 一次锁住两件事：
    //    ① 能力还在（0 处 ⇒ 违反 Apple 5.1.1(v) 的「App 内可自助注销」）
    //    ② **搬迁要搬净**（2 处 ⇒ 页尾那份没删 ⇒ 同一动作两个入口）
    //    —— 与本文件里 `_buildContactCard` 那条「搬迁要搬净，不是复制一份」同一口径。
    check('🔴 「注销账号」在下拉区且**只有一处**（搬迁要搬净）',
        countOccurrences(profile, 'onTap: _showDeleteAccountDialog') == 1,
        '实测 ${countOccurrences(profile, 'onTap: _showDeleteAccountDialog')} 处');
    check('🔴 注销弹层仍在（能力不因搬位置而消失）',
        profile.contains('Future<void> _showDeleteAccountDialog()'));
    // 🔴 顺序：**不可逆的在最末**（列表从上往下扫 ⇒ 离日常项最远）。
    //    ⚠️ 「顺序断言」在本项目的另一族里是禁忌（`f(g(x))` 的**文本顺序 ≠ 求值顺序**），
    //       但这里成立且必要：**children 列表的字面顺序就是渲染顺序**，
    //       两者之间没有求值过程。⇒ 「文本顺序 ≠ 求值顺序」只在**表达式内**适用。
    final iSignOut = profile.indexOf("title: '退出账号'");
    final iDelete = profile.indexOf("title: '注销账号'");
    check('🔴 「退出账号」在「注销账号」**之前**（不可逆的放最末）',
        iSignOut > 0 && iDelete > iSignOut,
        '退出 @$iSignOut · 注销 @$iDelete');
    // 🔑 配套：入口上删掉了说明 ⇒ 必须确认**提示被接住了**（否则等于悄悄降级警示）。
    //    旧页尾那行的说明「永久删除账号与云端数据」已删（下拉项只有动作名），
    //    风险改由**二次确认弹窗**承担 —— 所以这里正向锁弹窗那三条。
    check('🔴 旧页尾那行的说明「永久删除账号与云端数据」已删（下拉项只有动作名）',
        !profile.contains('永久删除账号与云端数据'));
    check('🔴 风险提示被确认弹窗接住（永久删除 / 本机数据保留 / 不影响订阅 三条都在）',
        profile.contains('无法恢复') &&
            profile.contains('不会被删除') &&
            profile.contains('不会自动取消订阅'),
        '入口上不留说明 ⇒ 弹窗里必须有');
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
