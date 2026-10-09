// 「忘记密码」（找回密码自助重置）验收 —— 后端契约 + 前端接线 + 6 格纯逻辑
//
// 跑：cd scripts/query_verify && dart run bin/verify_forgot_password.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail` —
//    管道会让 `$?` 取到 `tail` 的退出码 = 0，这是本项目记过的
//    「Dart main 返回值 ≠ 退出码」同族陷阱）。
//
// # 为什么需要它
//
// 「忘记密码」横跨**四层**：Rust 后端（表/端点/安全约束）→ HTTP 契约 →
// Dart provider → 弹层 UI → 6 格纯逻辑。任何一层断了，**其余层都不会报错**：
//   · 表没登记进迁移列表 ⇒ 新装的有、**已上线的库没有**（生产才炸）
//   · 端点没注册 ⇒ 前端 404，但 `cargo test` 全绿
//   · 入口没接上 ⇒ 「有实现、无入口」（本项目踩过，analyzer 与后端测试都发现不了）
//   · 「保留当前会话」抄错成改密码的语义 ⇒ 重置后攻击者会话仍在（**安全漏洞**）
//
// # 🔴 本脚本的证伪方式（每次改断言都该跑一遍）
//
// | 改这里 | 应该变红的是 |
// |---|---|
// | `main.rs` 删掉 `password_reset` 迁移 | 「两处都有」（表升级断链）|
// | `reset_password` 的删 token 改成 `token != ?1` | 「删**全部**会话」|
// | `auth.rs` 把「该邮箱尚未注册」改回含糊文案 | 「未注册明说」|
// | `auth_dialog` 删掉「忘记密码？」 | 「入口 A」|
// | `forgot_password_dialog` 的冷却常量改成 30 | 「前后端冷却同值」|
// | `code_box_logic` 的 `focusAfterInput` 去掉越界钳制 | 纯逻辑那组 |
//
// # ⚠️ 口径（如实标注）
//
// · 文本断言**先剥整行注释**（否则注释里的说明会造成假红；
//   ⚠️ 只能按**整行**剥 —— 切 `//` 会把 `https://` 切掉，本项目已踩）。
// · Rust 文件**先切掉 `#[cfg(test)]`**（测试会**复述**实现里的字符串 ⇒ 否则假绿）。
// · 它能锁「契约与接线」，**不能**替代真机走一遍（渲染 + 真收一封邮件）。

import 'dart:io';

import '../../../app/lib/services/code_box_logic.dart' as L;

int _pass = 0;
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

/// 剥掉**整行注释**（只剥整行 —— 理由见文件头）。
String stripComments(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 只取**实现部分** —— 切掉 `#[cfg(test)]` 之后的测试代码。
///
/// 🔴 必须切：Rust 源文件里测试与实现同处一室，测试会**复述**实现里的字符串
/// （如 `assert_eq!(err, "该邮箱尚未注册")`）⇒ 不切则改实现也不会红 = **假绿**。
String implOnly(String src) {
  final i = src.indexOf('#[cfg(test)]');
  return i < 0 ? src : src.substring(0, i);
}

/// 取 [a] 与 [b] 之间的切片（找不到边界时返回空串 —— **宁可空宁可红，不可静默全量**）。
///
/// 🔑 用途：同一文件里有**语义相反**的两段代码（`change_password` 保留当前会话、
///    `reset_password` 删全部会话）⇒ 若不断开切片，「不得含 X」会查到邻居身上。
String between(String src, String a, String b) {
  final i = src.indexOf(a);
  if (i < 0) return '';
  final j = src.indexOf(b, i + a.length);
  return j < 0 ? src.substring(i) : src.substring(i, j);
}

String readFile(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// 查「表名以完整标识符出现」—— **必须有词边界**。
///
/// # 🔴 这是证伪时实测抓到的假绿（2026-10-05）
///
/// 原写法是 `src.contains('CREATE TABLE IF NOT EXISTS password_reset')` ——
/// **子串匹配**。证伪时把 `main.rs` 里的表名改成 `password_reset_DISABLED`
/// （模拟「迁移被停用」），断言**仍然全绿** —— 因为
/// `'... password_reset_DISABLED'` **包含** `'... password_reset'`。
///
/// 📌 判据：**凡查标识符，都要排掉「更长标识符以它为前缀」这一情形**。
///    同一个坑本项目已记过两次（`tokens` 被 `token` 命中、`_repoFile(` 的后缀恰是 `File(`），
///    这次是**第三种形态：加后缀**（前两次是加前缀 / 后缀巧合）。
bool hasIdentifier(String src, String ident) =>
    RegExp('\\b${RegExp.escape(ident)}\\b').hasMatch(src);

void main() {
  print('');
  print('#' * 74);
  print('# 「忘记密码」验收 —— 后端契约 · 前端接线 · 6 格纯逻辑');
  print('#' * 74);

  // ── 后端 ──
  final schemaRs = stripComments(readFile('../../backend/crates/api_server/src/schema.rs'));
  final mainRs = stripComments(readFile('../../backend/src/main.rs'));
  final authRsImpl = implOnly(
      stripComments(readFile('../../backend/crates/api_server/src/auth.rs')));
  final routesImpl = implOnly(
      stripComments(readFile('../../backend/crates/api_server/src/routes.rs')));
  final purgeRs = stripComments(readFile('../../backend/crates/api_server/src/user_purge.rs'));
  final sesRs = stripComments(readFile('../../backend/crates/api_server/src/tencent_ses.rs'));
  final signRs = stripComments(readFile('../../backend/crates/api_server/src/tencent_sign.rs'));
  final asrRs = stripComments(readFile('../../backend/crates/api_server/src/tencent_asr.rs'));

  // ── 前端 ──
  final authDlg = stripComments(readFile('../../app/lib/widgets/auth_dialog.dart'));
  final changePwDlg =
      stripComments(readFile('../../app/lib/widgets/change_password_dialog.dart'));
  final forgotDlg = stripComments(readFile('../../app/lib/widgets/forgot_password_dialog.dart'));
  final codeInput = stripComments(readFile('../../app/lib/widgets/code_input.dart'));
  final codeLogicRaw = readFile('../../app/lib/services/code_box_logic.dart');
  final authClient = stripComments(readFile('../../app/lib/api/auth_client.dart'));
  final authProviderRaw = stripComments(readFile('../../app/lib/providers/auth_provider.dart'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ① 后端 · 表与迁移（🔴 两处必须都有）──');
  // ═══════════════════════════════════════════════════════════════════

  check('`schema.rs` 有 `password_reset` 建表',
      hasIdentifier(schemaRs, 'password_reset'));
  check(
      '🔴 `main.rs` 迁移列表也有（老库升级）—— 只改 `schema.rs` ⇒ 新装有、已上线的库没有',
      hasIdentifier(mainRs, 'password_reset'));
  check('表清单 `EXPECTED_TABLES` 已登记（否则门禁报「多出未登记的表」）',
      schemaRs.contains('"password_reset"'));
  check('注销清单 `DELETE_TARGETS` 已登记（否则门禁报「没进注销清单」）',
      purgeRs.contains('("password_reset", "user_id")'));
  check('`code_hash` 列存在（🔴 不存明文码）',
      schemaRs.contains('code_hash TEXT NOT NULL'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ② 后端 · 两个端点 ──');
  // ═══════════════════════════════════════════════════════════════════

  check('注册 `POST /api/auth/forgot-password`',
      routesImpl.contains('/api/auth/forgot-password'));
  check('注册 `POST /api/auth/reset-password`',
      routesImpl.contains('/api/auth/reset-password'));
  check('两个端点都**不需要 token**（用户此刻登不进来）',
      !between(routesImpl, 'async fn auth_forgot_password', 'async fn auth_reset_password')
          .contains('extract_bearer_token'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ③ 后端 · 安全约束（每条都对应一个真实后果）──');
  // ═══════════════════════════════════════════════════════════════════

  // 白哥 2026-10-05 定「明说」
  check('未注册邮箱**明说**「该邮箱尚未注册」（白哥定案 · 不是含糊）',
      authRsImpl.contains('该邮箱尚未注册'));
  check('两处（申请 / 重置）**同口径** —— 都明说',
      '该邮箱尚未注册'.allMatches(authRsImpl).length >= 2,
      '出现 ${'该邮箱尚未注册'.allMatches(authRsImpl).length} 次');
  check('验证码用 `hash_password`（bcrypt）落库，不是明文',
      authRsImpl.contains('code_hash') && authRsImpl.contains('hash_password(&code)'));

  final ttl = RegExp(r'RESET_CODE_TTL_SECS: i64 = (\d+)').firstMatch(authRsImpl);
  final cool = RegExp(r'RESET_CODE_COOLDOWN_SECS: i64 = (\d+)').firstMatch(authRsImpl);
  final maxTry = RegExp(r'RESET_CODE_MAX_ATTEMPTS: i64 = (\d+)').firstMatch(authRsImpl);
  check('验证码有效期 = 600 秒（10 分钟）', ttl?.group(1) == '600', '实得 ${ttl?.group(1)}');
  check('同邮箱冷却 = 60 秒', cool?.group(1) == '60', '实得 ${cool?.group(1)}');
  check('错误尝试上限 = 5 次', maxTry?.group(1) == '5', '实得 ${maxTry?.group(1)}');

  // 🔴 与「修改密码」的**语义相反**：这里必须删**全部**会话
  final resetFn = between(authRsImpl, 'pub fn reset_password', '\n#[');
  check('🔴 重置后删**全部**会话（`DELETE FROM tokens WHERE user_id`，**不带** `token !=`）',
      resetFn.contains('DELETE FROM tokens WHERE user_id = ?1') &&
          !resetFn.contains('token != ?'),
      resetFn.isEmpty ? '⚠️ 切片为空（函数名变了？）' : '');
  check('同上：改密码那条**必须保留**「除当前外」（两处语义不同，别互抄）',
      between(authRsImpl, 'pub fn change_password', 'pub fn uid_by_token')
          .contains('token != ?2'));
  check('改密码与验证码重置用**事务**（避免「码废了但密码没改」这种锁死）',
      resetFn.contains('unchecked_transaction'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ④ 后端 · 邮件通道（腾讯云 SES）──');
  // ═══════════════════════════════════════════════════════════════════

  check('SES 国内站版本号 = `2020-10-02`（🔴 网上多篇文章写 2019-03-18 = 国际站旧值）',
      sesRs.contains('"2020-10-02"'));
  check('`TemplateData` 由 `json!({...}).to_string()` 产生（**JSON 字符串**，不是嵌套对象）',
      sesRs.contains('serde_json::json!({ "code": code }).to_string()') ||
          RegExp(r'json!\(\s*\{\s*"code":\s*code\s*\}\s*\)\.to_string\(\)')
              .hasMatch(sesRs));
  check('密钥用**独立**的 `TENCENT_SES_*`（最小权限 · 白哥定案）',
      sesRs.contains('TENCENT_SES_SECRET_ID') && sesRs.contains('TENCENT_SES_SECRET_KEY'));
  check('`tencent_sign` 是 TC3 签名的**唯一实现**（ASR 与 SES 共用）',
      signRs.contains('pub async fn call') && asrRs.contains('crate::tencent_sign::call'));
  check('🔑 ASR 不再自带第二份签名实现（否则「改一处漏一处」）',
      !asrRs.contains('fn hmac_sha256'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ⑤ 前端 · 两处入口（白哥定案 A + B）──');
  // ═══════════════════════════════════════════════════════════════════

  check('入口 A：登录弹层有「忘记密码？」',
      authDlg.contains('忘记密码？'));
  check('入口 A：有打开流程的方法 `_openForgotPassword`',
      authDlg.contains('_openForgotPassword'));
  check('🔑 入口 A 只在**登录态**显示（注册态还没账号，「忘记密码」不成立）',
      RegExp(r'if \(_isLogin\) \.\.\.\[').hasMatch(authDlg));
  check('入口 A：重置成功要**连登录弹层一起关**（否则已登录还压着登录窗）',
      between(authDlg, 'Future<void> _openForgotPassword', '\n  @override')
          .contains('Navigator.of(context).pop(true)'));

  check('入口 B：修改密码弹层有「忘了原密码？找回密码」',
      changePwDlg.contains('忘了原密码？找回密码'));
  check('入口 B：次要链接放在 `child` 末尾，**不在 `actions`**（后者是横向平分按钮行）',
      changePwDlg.contains('忘了原密码？找回密码') &&
          !RegExp(r'actions: \[[^\]]*忘了原密码').hasMatch(changePwDlg));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ⑥ 前端 · 弹层与 6 格 ──');
  // ═══════════════════════════════════════════════════════════════════

  check('`forgot_password_dialog.dart` 存在', forgotDlg.isNotEmpty);
  check('三步分屏（`_step` 有 0 / 1 / 2）',
      forgotDlg.contains('int _step = 0') &&
          forgotDlg.contains('_step = 1') &&
          forgotDlg.contains('_step = 2'));
  check('🔴 冷却常量在**前端**也存在（否则用户以为能点、却被后端拒）',
      forgotDlg.contains('kResendCooldownSecs'));

  // 🔴 跨实现同值：前端冷却 == 后端冷却
  final feCool = RegExp(r'kResendCooldownSecs = (\d+)').firstMatch(forgotDlg);
  check(
      '🔴 前后端冷却**同值**（前端 ${feCool?.group(1)} vs 后端 ${cool?.group(1)}）—— '
      '前端更短会让用户「自以为可以」时吃到一次报错',
      feCool?.group(1) != null && feCool?.group(1) == cool?.group(1));

  check('`code_input.dart` 用 `kCodeBoxCount`（不硬编码 6）',
      codeInput.contains('kCodeBoxCount') && !codeInput.contains('i < 6'));
  check('🔑 6 格用「1 个隐藏输入框 + 6 个展示格」（避开「退格到空格不触发 onChanged」）',
      codeInput.contains('Positioned.fill') && codeInput.contains('showCursor: false'));

  check('`code_box_logic.dart` **零 import**（⇒ 本机 `dart run` 可验）',
      !RegExp(r"^\s*import\s", multiLine: true).hasMatch(codeLogicRaw),
      codeLogicRaw.isEmpty ? '⚠️ 文件读不到' : '');

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ⑦ 前端 · API 与 provider ──');
  // ═══════════════════════════════════════════════════════════════════

  check('`auth_client.forgotPassword` 存在', authClient.contains('Future<void> forgotPassword('));
  check('`auth_client.resetPassword` 存在且返回同 login 的响应体',
      authClient.contains('Future<Map<String, dynamic>> resetPassword('));
  check('两个接口都**不带** `Authorization`（无 token 场景）',
      !between(authClient, 'Future<void> forgotPassword', 'Future<Map<String, dynamic>> resetPassword')
          .contains('Authorization'));
  check('`auth_provider.forgotPassword` 存在',
      authProviderRaw.contains('Future<void> forgotPassword('));
  check('`auth_provider.resetPassword` 存在',
      authProviderRaw.contains('Future<void> resetPassword('));

  // 🔴 反向：resetPassword **不得**写 `state.error`（会污染页面级的 AuthDialog）
  //
  // ⚠️ **切片边界必须用「代码行」，不能用注释行** —— 本脚本第一次跑就栽在这里：
  //    上一版曾写 end marker = `'\n  /// 创建临时账户'`（那是 `trialStart` 的文档注释），
  //    而 `stripComments` **会把整行注释删掉** ⇒ 边界找不到 ⇒ `between` 退化成
  //    「切到文件尾」⇒ 把后面其它函数里的 `error: _friendlyError` 也算进来 ⇒ **假红**。
  //    📌 判据：**剥注释会改变被检查的文本** —— 所以**任何以这段文本为基准的定位
  //       （切片边界、锚点、行号）都必须落在「剥完之后仍然存在」的行上**。
  //    同族：本项目已因「剥注释」踩过两次（URL 里的 `//` 被误切、行内注释被当代码）。
  // 🔴 2026-10-09：end marker 由 `'Future<void> trialStart('` 改为
  //    `'Future<void> changeEmailCode('` —— `trialStart` 随试用账号机制一起删除，
  //    旧 marker 从此找不到 ⇒ `between` 会退化成「切到文件尾」⇒ **假红**。
  //    ⚠️ 这正是本项目那条判据的又一次实例：**切片边界必须落在「当时存在」的代码行上**，
  //       而任何一次「删掉某个函数」都会让以它为边界的断言**静默失效**。
  final feResetFn =
      between(authProviderRaw, 'Future<void> resetPassword(', 'Future<void> changeEmailCode(');
  check('切片边界有效（`resetPassword` 与 `changeEmailCode` 都找得到）',
      feResetFn.isNotEmpty, '切片长 ${feResetFn.length}');
  check('🔴 `resetPassword` **不碰** `state.error`（弹层自有 `_error`，写了会让登录弹窗挂一句错）',
      feResetFn.isNotEmpty && !feResetFn.contains('error: _friendlyError'),
      feResetFn.isEmpty ? '⚠️ 切片为空（函数名变了？）' : '');
  check('🔑 但**必须**写 `AuthState`（重置成功 = 已登录 —— 这是它和 forgotPassword 的区别）',
      feResetFn.contains('isAuthenticated: true'));

  // ═══════════════════════════════════════════════════════════════════
  print('\n── ⑧ 6 格纯逻辑（**真值断言**：直接调用函数，不是查文本）──');
  // ═══════════════════════════════════════════════════════════════════

  check('位数常量 = 6（与后端 `{:06}` 同值）', L.kCodeBoxCount == 6);
  check('清洗：从邮件正文里只取数字',
      L.cleanCodeInput('你的验证码是 482913，10 分钟内有效') == '482913');
  check('清洗：超长截断到 6 位', L.cleanCodeInput('1234567890') == '123456');
  check('清洗：无数字 → 空串', L.cleanCodeInput('abc') == '');
  check('跳格：0→1', L.focusAfterInput(0) == 1);
  check('跳格：**最后一格不越界**', L.focusAfterInput(5) == 5);
  check('跳格：负索引钳到 0', L.focusAfterInput(-1) == 0);
  check('退格：当前格非空 ⇒ 焦点不动', L.focusAfterBackspace(3, currentTextEmpty: false) == 3);
  check('退格：当前格为空 ⇒ 回上一格',
      L.focusAfterBackspace(3, currentTextEmpty: true) == 2);
  check('退格：第一格不越界', L.focusAfterBackspace(0, currentTextEmpty: true) == 0);
  check('拼接：按从左到右', L.joinCodeBoxes(['4', '8', '2', '9', '1', '3']) == '482913');
  check('完成判定：6 位真 / 5 位假',
      L.isCodeComplete('482913') && !L.isCodeComplete('48291'));
  check('缺位索引：全空 = 6 个', L.emptyBoxIndexes(['', '', '', '', '', '']).length == 6);
  check('缺位索引：缺第 1、3 格',
      L.emptyBoxIndexes(['1', '', '3', '', '5', '6']).toString() == '[1, 3]');
  check('粘贴分配：从第 0 格放 6 位', L.distributePasted('482913', 0).length == 6);
  check('粘贴分配：从第 4 格只能放 2 位（格子不够）',
      L.distributePasted('482913', 4).length == 2);
  check('粘贴分配：越界 → 空列表（不抛异常，否则是用户可见的崩溃）',
      L.distributePasted('123', 9).isEmpty);

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
    print('🔑 最可能的原因：有人把「忘记密码」的四层里某一层改了 ——');
    print('    表/迁移两处 · 端点注册 · 安全约束（明说/删全部会话）· 前端入口 A/B。');
    print('    见本文件头部「证伪方式」表。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
