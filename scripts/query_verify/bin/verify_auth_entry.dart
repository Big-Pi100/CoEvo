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
  final subscribePanel = stripComments(
      File('../../app/lib/widgets/subscribe_panel.dart').readAsStringSync());

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

  // ── ③ 🔴 三个真实入口都挂上了 ──
  final wired = countOccurrences(profile, 'onTap: _showLoginDialog');
  check('🔴 「我的」页 ≥3 处入口挂在 `_showLoginDialog`（账号行 / 订阅卡 / 查看按钮）',
      wired >= 3, '实测 $wired 处');

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

  // ── ⑫ 订阅弹层的**内容**也统一了（外壳改了、内容没改 = 还是半统一）──
  check('🔴 `SubscribePanel` 不再有 Material `FilledButton`',
      !subscribePanel.contains('FilledButton('));
  check('`SubscribePanel` 用了 `ClayButton`',
      subscribePanel.contains('ClayButton('));

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
