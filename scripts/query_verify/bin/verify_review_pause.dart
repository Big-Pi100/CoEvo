// CoEvo · 复习页「暂停」的验收 —— **划线卡 与 生词卡 的两条写路径**
//
//   ① 纯函数（真跑）：分派 + 文案（两套，不共用）
//   ② 读端结构：三处共用同一判据（不许各写一份）
//   ③ 写端结构：刷 `updated_at` + `pending_push`（否则同步会丢这次变更）
//   ④ 界面接线：复习页分派 / 笔记页恢复入口（**两个界面都要接上**）
//
// 跑法：cd scripts/query_verify && dart run bin/verify_review_pause.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么需要它（2026-10-08 白哥报的 bug）
//
// 「复习页的『暂停』对划线卡**无效**」。根因是**只实现了生词那一条写路径**：
//
// | 卡片 | id | 暂停该落在哪 |
// |---|---|---|
// | 生词 | `w…` | `user_word.deleted = 1` |
// | 划线 | `hl:<uuid>` | `highlight.paused = 1` |
//
// 旧实现无条件写 `user_word` ⇒ 对 `hl:` 影响 **0 行** ⇒ 仓储返回 `false`
// ⇒ 页面 `if (!changed) return;` ⇒ **静默、连提示都没有**。
//
// 🔴 这一类缺陷的可怕之处：**每一个环节单独看都对** ——
//    写端没错（它只对生词负责）、分派没错（那时没有第二种卡）、
//    页面没错（`changed == false` 时确实不该刷新）。
//    **错的只有「没人负责第二张卡」这一件事**，而它没有任何编译期信号。
//    ⇒ 只能靠断言把「**两张卡都得有路**」钉住。
//
// # 🔴 本脚本自身的证伪方式（改断言后必须各跑一次）
//
// · 把 `review_pause.dart` 的 `pauseReviewCard` 改成无条件调 `pauseWord(...)`
//   → ①-2 必须变红
// · 把 `pausedMessage` 的两支改成同一句 → ①-5 必须变红
// · 把 `review_list_query.dart` 的 `count` 改回硬编码 `COALESCE(uw.deleted, 0) = 0`
//   → ②-2 必须变红
// · 把 `highlight_repository.dart` 的 `_setPaused` 里 `updated_at` 那一段删掉
//   → ③-2 必须变红
// · 把 `highlights_screen.dart` 的 `_resume` 整个删掉 → ④-2 必须变红
// · 🆕 把 `review_list_query.dart` 的 `_visibilityWheres` 里
//   `OR h.id IS NOT NULL` 那段删掉 → ②-10 必须变红
//   （并且 `verify_review_list.dart`【14】的「无主卡不在列表」组必须一起变红 ——
//     那组是**真跑**的行为断言，两者是同一改动的两道防线）
//
// # ⚠️ 口径（如实标注）
//
// · ① 是**真跑**（纯 Dart，直接 import 实现）；②③④ 是**词法级**扫描
//   （剥整行注释 + 括号配对取块）⇒ 能锁「结构与接线的存在性」，
//   **不能**替代真机点一次（渲染层本机验不了）。
// · 剥注释只到「行首 `//`」与「行内 `//`（前面无引号）」两级 —— 够用，
//   不处理块注释（本项目不用那种风格）。

import 'dart:io';

import '../../../app/lib/services/review_pause.dart';

import '_repo_paths.dart';

int _pass = 0;
final List<String> _failures = [];

void check(String label, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('  ✅ $label');
  } else {
    _failures.add(detail == null ? label : '$label —— $detail');
    print('  ❌ $label${detail == null ? '' : ' —— $detail'}');
  }
}

/// 剥注释：整行 `//` 一律去掉；行尾 `//` 在「前面没有引号」时截断。
///
/// 🔑 **必须剥**：本项目注释里大量引用实现细节（如「`updated_at` 要刷」），
///    不剥会把注释当成实现（**假绿**）。
String stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    if (raw.trimLeft().startsWith('//')) continue;
    final i = raw.indexOf('//');
    if (i >= 0 &&
        !raw.substring(0, i).contains("'") &&
        !raw.substring(0, i).contains('"')) {
      out.add(raw.substring(0, i));
    } else {
      out.add(raw);
    }
  }
  return out.join('\n');
}

/// 从 [signature] 出现处开始，取**函数体**（含配对的大括号）。
///
/// 🔴 必须**先跨过参数列表**再找函数体的 `{` —— 否则遇到带命名参数的签名
///    （`Future<int> count({String? search, ...})`）会把**参数列表的 `{`**
///    当成函数体起点 ⇒ 取到的块里根本没有实现 ⇒ 断言**假红**
///    （我第一版就是这么写的，②-2/②-3 因此误报）。
///    📌 判据：**「取一块代码」这类辅助函数，必须显式处理参数列表** ——
///       形如 `f(x) {` 与 `f({y: 1}) {` 的「第一个 `{`」不是同一个东西。
String? blockAt(String src, String signature) {
  final at = src.indexOf(signature);
  if (at < 0) return null;

  // ① 跨过参数列表：从签名后的第一个 `(` 配对到它的 `)`
  final p = src.indexOf('(', at);
  if (p < 0) return null;
  var pd = 0;
  var i = p;
  for (; i < src.length; i++) {
    final c = src[i];
    if (c == '(') {
      pd++;
    } else if (c == ')') {
      pd--;
      if (pd == 0) break;
    }
  }

  // ② 再从 `)` 之后找函数体的 `{`，配对到结束
  final open = src.indexOf('{', i);
  if (open < 0) return null;
  var depth = 0;
  for (var k = open; k < src.length; k++) {
    final c = src[k];
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, k + 1);
    }
  }
  return null;
}

int countOf(String src, String needle) {
  var n = 0;
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    n++;
    from = i + needle.length;
  }
  return n;
}

String read(String relative) => stripComments(File(repoPath(relative)).readAsStringSync());

void main() async {
  // ══════════════════════════════════════════════════════════════
  print('① 纯函数（**真跑**）：分派与文案');

  check('①-1 `hl:` 开头判为划线卡；`w…` / 空串不是',
      isHighlightCard('hl:abc-123') &&
          !isHighlightCard('w42') &&
          !isHighlightCard(''),
      'hl:abc-123=${isHighlightCard('hl:abc-123')} w42=${isHighlightCard('w42')}');

  // 分派：用两个假实现数「哪一支被调用」
  var wordCalls = 0;
  var hlCalls = 0;
  Future<bool> fakeWord(String id) async {
    wordCalls++;
    return true;
  }

  Future<bool> fakeHl(String id) async {
    hlCalls++;
    return true;
  }

  await pauseReviewCard(
      wordId: 'hl:x', pauseWord: fakeWord, pauseHighlight: fakeHl);
  check('①-2 划线卡走 `pauseHighlight`（**不是** word 那支）',
      hlCalls == 1 && wordCalls == 0, 'hl=$hlCalls word=$wordCalls');

  await pauseReviewCard(
      wordId: 'w1', pauseWord: fakeWord, pauseHighlight: fakeHl);
  check('①-3 生词卡走 `pauseWord`', wordCalls == 1 && hlCalls == 1,
      'hl=$hlCalls word=$wordCalls');

  final msgHl = pausedMessage(wordId: 'hl:x', spelling: 'whatever');
  final msgWord = pausedMessage(wordId: 'w1', spelling: 'abandon');
  check('①-4 两类卡的文案**不同**', msgHl != msgWord, '$msgHl / $msgWord');
  check('①-5 🔴 划线那句**不含「再次查词」**（划线没有那个动作）',
      !msgHl.contains('再次查词'), msgHl);
  check('①-6 划线那句**点名出口**（「笔记」）', msgHl.contains('笔记'), msgHl);
  check('①-7 生词那句保留原行为（「再次查词就会恢复」）',
      msgWord.contains('再次查词') && msgWord.contains('abandon'), msgWord);

  // ══════════════════════════════════════════════════════════════
  print('');
  print('② 读端：`ReviewListQuery` 三处**共用同一判据**（不许各写一份）');

  final q = read('app/lib/services/review_list_query.dart');
  check('②-0 找得到 `_visibilityWheres` 与 `_joins`',
      q.contains('_visibilityWheres') && q.contains('_joins'),
      '扫不到 ⇒ 下面的「全过」是空过');

  final listBody = blockAt(q, 'Future<List<ReviewListItem>> list(');
  final countBody = blockAt(q, 'Future<int> count(');
  final dueBody = blockAt(q, 'Future<int> dueCount(');
  check('②-1 三个方法体都取到了',
      listBody != null && countBody != null && dueBody != null);

  if (listBody != null && countBody != null && dueBody != null) {
    check('②-2 `list` 用了 `_visibilityWheres`（不是硬编码判据）',
        listBody.contains('_visibilityWheres'));
    check('②-3 `count` 用了 `_visibilityWheres`',
        countBody.contains('_visibilityWheres'));
    check('②-4 `dueCount` 用了 `_visibilityWheres`',
        dueBody.contains('_visibilityWheres'));
    check('②-5 三个方法都用了 `_joins`（JOIN 也只有一份）',
        listBody.contains('_joins') &&
            countBody.contains('_joins') &&
            dueBody.contains('_joins'));
  }

  // 反向：**不许**再出现裸的判据字面量（那说明有人另写了一份口径）
  final bareJudgement = countOf(q, "'COALESCE(uw.deleted, 0) = 0'");
  check('②-6 🔴 全文只剩**一处**该判据字面量（在 `_visibilityWheres` 里）',
      bareJudgement == 1, '实际 $bareJudgement 处 ⇒ 有人又写了一份口径');

  check('②-7 判据含划线那条 `h.paused`', q.contains("'COALESCE(h.paused, 0) = 0'"));
  check('②-8 判据含「已取消的划线也不显示」`h.deleted`',
      q.contains("'COALESCE(h.deleted, 0) = 0'"),
      '漏了它 ⇒ 取消过的划线仍留在复习列表（同一缺口的另一面）');
  check('②-9 JOIN 键用常量插值（不手写 `\'hl:\'`）',
      q.contains('kHighlightIdPrefix'), '手写前缀 ⇒ 前缀改口径时会漂');

  // ── 🆕 2026-10-09：**无主划线卡**（孤儿卡）不得显示 ──────────────
  //
  // 现象（白哥真机）：列表顶部一张标题显示成 `hl:<uuid>` 的卡，
  //   点「暂停」没反应（静默），界面也没有出口能去掉它。
  // 根因：`highlight` 本体**不参与同步**，而 `review_log` 参与
  //   ⇒ 重装/换机后 pull 重放出一行 `card_review_state`，而划线在本机不存在。
  //
  // 🔑 修在**判据层**（不是「暂停」按钮上）：成因对每个用户都会发生，
  //    必须一次性挡住；修在按钮上还要用户先找到并点它。
  //
  // 🔴 证伪：把 ④ 那条删掉 ⇒ ②-10 变红；把它改成 `AND h.id IS NULL`（方向反）
  //    ⇒ `verify_review_list.dart`【14】的「划线存在时卡片出现」变红。
  check('🆕 ②-10 判据含「无主划线卡不可见」（`OR h.id IS NOT NULL`）',
      q.contains('OR h.id IS NOT NULL'),
      '漏了它 ⇒ 重装/换机后出现一张标题是 `hl:<uuid>`、点暂停无反应的死卡');
  check('🔴 ②-11 无主卡只能靠「不显示」处理，**不得**删派生行',
      !RegExp(r'DELETE\s+FROM\s+card_review_state', caseSensitive: false)
          .hasMatch(q),
      '删了既留不住（`_applyReviewEvents` 重放会重建），'
      '又切断「划线同步回来 ⇒ 卡片自动恢复」这条路');

  // ══════════════════════════════════════════════════════════════
  print('');
  print('③ 写端：划线的 `pause` / `resume`');

  final hl = read('app/lib/services/highlight_repository.dart');
  check('③-0 找得到 `pause(` / `resume(` / `_setPaused(`',
      hl.contains('Future<bool> pause(String wordId)') &&
          hl.contains('Future<bool> resume(String wordId)') &&
          hl.contains('Future<bool> _setPaused('),
      '扫不到 ⇒ 下面的「全过」是空过');

  final setPaused = blockAt(hl, 'Future<bool> _setPaused(');
  check('③-1 `_setPaused` 的函数体取到了', setPaused != null);
  if (setPaused != null) {
    check('③-2 🔴 UPDATE 刷了 `updated_at`（同步的「谁更新谁赢」判据）',
        setPaused.contains('updated_at'));
    check('③-3 UPDATE 刷了 `pending_push = 1`', setPaused.contains('pending_push = 1'));
    check('③-4 UPDATE 带 `paused = ?`（幂等：本来就那个状态 ⇒ 0 行）',
        setPaused.contains('paused = ?'));
    check('③-5 UPDATE 带 `deleted = 0`（已取消的划线不该被暂停）',
        setPaused.contains('deleted = 0'));
    check('③-6 用 `highlightUuidOf` 剥前缀（不自己写 `substring`）',
        setPaused.contains('highlightUuidOf('));
  }
  check('③-7 `Highlight` 模型带 `paused` 字段（否则界面读不到状态）',
      hl.contains('final bool paused;'));
  check('③-8 `_fromRow` 映射了 `paused`', hl.contains("r['paused']"));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('④ 界面接线：复习页「分派」· 笔记页「恢复入口」');

  final rs = read('app/lib/screens/review_screen.dart');
  check('④-1 复习页用 `pauseReviewCard(`（不直接调某个仓储的 pause）',
      rs.contains('pauseReviewCard('),
      '直接调 user_word ⇒ 划线卡又回到「静默无效」');
  check('④-2 复习页文案用 `pausedMessage(`', rs.contains('pausedMessage('));

  final hs = read('app/lib/screens/highlights_screen.dart');
  check('④-3 🔴 笔记页有 `_resume`（**这是划线卡暂停后的唯一恢复出口**）',
      hs.contains('Future<void> _resume('),
      '没有它 ⇒ 用户暂停划线后永远找不回（有动作、无出口）');
  check('④-4 恢复走 `HighlightRepository(...).resume(`',
      hs.contains('.resume(') && hs.contains('HighlightRepository('));
  check('④-5 恢复用 `highlightWordId(`（与复习页同一 id 形态）',
      hs.contains('highlightWordId('));

  // 「恢复复习」与「已暂停」标记都必须**有条件**（只在 paused 时出现）
  check('④-6 🔴 「恢复复习」只在 `highlight.paused` 时渲染（不常驻）',
      hs.contains("if (highlight.paused) ...[\n                    _action(t, '恢复复习'"));
  check('④-7 收起态的「已暂停」标记也带条件',
      RegExp(r"if \(highlight\.paused\) \.\.\.\[\s*Text\(\s*'已暂停'").hasMatch(hs));

  // ══════════════════════════════════════════════════════════════
  print('');
  print('【6】🆕 暂停的二次确认（2026-10-08 · 白哥「很容易误点」）');
  // ══════════════════════════════════════════════════════════════
  //
  // 🔴 守两件：
  //   ① **确认文案与结果提示必须说同一件事**（后果 + 出口），
  //      且两类卡的出口**不同**（生词 = 再次查词 · 划线 = 「笔记」页）。
  //   ② 确认框必须排在**写库之前**，且「取消」**真的不写**。
  //      ⚠️ 它还必须在取 `ScaffoldMessenger` / `ref` **之前** ——
  //         那两个引用靠「在任何 await 之前先拿到」来防「await 期间页面销毁」，
  //         而确认框**本身就是一次 await**，排在后面会让那条防线失效。

  final wordBody = pauseConfirmBody(wordId: 'w123', spelling: 'ephemeral');
  final hlBody = pauseConfirmBody(wordId: 'hl:abc', spelling: '');

  check('6-1 生词卡的确认正文说明后果（离开复习列表）',
      wordBody.contains('离开复习列表'), wordBody);
  check('6-2 生词卡的确认正文点名出口「再次查」', wordBody.contains('再次查'), wordBody);
  check('6-3 划线卡的确认正文说明后果（离开复习列表）',
      hlBody.contains('离开复习列表'), hlBody);
  check('6-4 🔴 划线卡的出口是「笔记」且**不含**「再次查」（不能沿用生词那句）',
      hlBody.contains('笔记') && !hlBody.contains('再次查'), hlBody);
  check('6-5 🔴 两类卡的确认正文**不是同一句**（否则必有一类在说谎）',
      wordBody != hlBody);

  // 「确认」与「事后提示」的出口口径一致 —— 同一处权威的体现
  final wordDone = pausedMessage(wordId: 'w123', spelling: 'ephemeral');
  final hlDone = pausedMessage(wordId: 'hl:abc', spelling: '');
  check('6-6 生词：确认正文与 `pausedMessage` 的出口说法一致',
      wordDone.contains('再次查') == wordBody.contains('再次查'));
  check('6-7 划线：确认正文与 `pausedMessage` 的出口说法一致',
      hlDone.contains('笔记') == hlBody.contains('笔记'));

  // ── 结构级：接线的形状 ──
  // ⚠️ `rs` 已在本文件更早处声明（同一份源码）⇒ 这里**复用**，别再声明一次
  //    （第一版就撞了 `'rs' is already declared`）。
  final body = blockAt(rs, 'Future<void> _pause(');
  check('6-8 取到 `_pause` 的函数体', body != null);
  if (body != null) {
    check('6-9 🔴 `_pause` 里有确认弹窗（`CoDialog.show`）',
        body.contains('CoDialog.show'));
    final iDialog = body.indexOf('CoDialog.show');
    final iMessenger = body.indexOf('ScaffoldMessenger.of');
    final iRevision = body.indexOf('userDbRevisionProvider.notifier');
    check('6-10 🔴 确认框排在 `ScaffoldMessenger.of` **之前**（否则引用落在 await 之后）',
        iDialog >= 0 && iMessenger > iDialog, 'dialog=$iDialog messenger=$iMessenger');
    check('6-11 🔴 确认框排在 `revision` 取用**之前**（同理）',
        iDialog >= 0 && iRevision > iDialog, 'dialog=$iDialog revision=$iRevision');
    check('6-12 🔴 「取消」真的不写库（`if (confirmed != true) return;`）',
        RegExp(r'if \(confirmed != true\) return;').hasMatch(body));
    check('6-13 确认之后有 `!mounted` 检查（弹窗期间页面可能已销毁）',
        body.contains('if (!mounted) return;'));
    check('6-14 弹窗用了统一外壳 `CoDialog`（而不是自己写 `AlertDialog`）',
        body.contains('CoDialog(') && !body.contains('AlertDialog('));
  }

  // ══════════════════════════════════════════════════════════════
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
    print('🔑 最可能的原因：');
    print('    · 又出现了「只实现一种卡片」的形态 —— 复习列表里有**两种卡**，');
    print('      它们的暂停落在**两张表**上（生词 `user_word.deleted` · 划线 `highlight.paused`）。');
    print('    · 或判据被复制成两份（三处各写一遍）⇒ 会出现「列表 3 条但顶部写 5 个」。');
    print('    · 或恢复入口被删 ⇒ 用户暂停划线后再也找不回（有动作、无出口）。');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
