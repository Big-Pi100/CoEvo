// CoEvo · `word_id` → **真拼写**的唯一解析处
//
// # 🔴 为什么需要它（2026-10-09 线上缺陷的根因）
//
// 复习列表的标题读的是 `card_review_state.spelling`（冗余列，
// 见 `review_list_query.dart` 的 `SELECT crs.spelling`）。而 pull 复习事件时，
// `sync_service._applyReviewEvents` 会为**每个 word_id** 重算拼写并写回 ——
// 用的是 `INSERT OR REPLACE`（**整行覆盖**）。
//
// 原实现 `_spellingFor` 只查两处，**都查不到就 `return wordId` 当占位**。
// 于是 `w000129` / `hl:<uuid>` / `ext:fixtures` 这些**内部 ID 被持久写进了表里**，
// 列表就把 ID 当标题显示。而它的注释以为「下次会被覆盖」—— 实际不会
//（同一次 pull 里 `user_word` 还没落库；两步顺序在 `sync_service` 里是反的）。
//
// ⇒ 本文件的判据：**解析不出来就返回 `null`，绝不返回 `word_id`。**
//    「宁可这一列保持原值 / 留待下次修复，也不要写一个假值进去。」
//    📌 一次性的显示问题，不该被升级成**持久化的数据污染**。
//
// # 为什么是「多级 fallback」而不是只查一处
//
// 每种 `word_id` 形态的**真拼写在哪儿**不一样，而且**全都不用跨库**（除最后一个）：
//
// | 形态 | 真拼写位置 | 成本 |
// |---|---|---|
// | `hl:<uuid>` | **同一个库**的 `highlight.text`（划线原文）| 一次主键查询 |
// | `ext:<拼写>` | **id 里自带**（去前缀即词形）| 零查询 |
// | `w0xxxxx` | `user_word.spelling` → 否则**词库**（跨库，**由调用方注入**）| 见 [wordLookup] |
//
// # 零 Flutter 依赖
//
// 本文件**不 import `package:flutter/**`**（连 `debugPrint` 也不用）——
// 否则 `scripts/*_verify`（纯 `dart run`）无法 import 它。
// 需要诊断输出时用可选的 [onLog]。

import 'package:sqflite_common/sqlite_api.dart';

import 'external_word_id.dart' show kExternalWordIdPrefix;
import 'highlight_id.dart' show highlightUuidOf, isHighlightWordId;
import 'highlight_repository.dart';
import 'review_list_query.dart' show ReviewListQuery;
import 'user_word_repository.dart';

/// 查词库（`word.db`）拿拼写 —— **由调用方注入**。
///
/// 🔑 为什么注入而不是直接查：`word.db` 与 `user.db` 是**两个库**。
///    本文件被 `sync_service` 依赖，而 `sync_service` 的其余部分
///    **刻意不依赖 `word.db`**（理由：不想把「另一个库不可用」的风险
///    引进同步主流程）。注入让「谁来查、查不到怎么办」留在调用方。
typedef WordSpellingLookup = Future<String?> Function(String wordId);

/// `word_id` → 真拼写（复习列表标题要显示的那个值）。
class ReviewSpellingResolver {
  ReviewSpellingResolver(
    this._userDb, {
    WordSpellingLookup? wordLookup,
    void Function(String message)? onLog,
  })  : _wordLookup = wordLookup,
        _onLog = onLog;

  final Database _userDb;
  final WordSpellingLookup? _wordLookup;
  final void Function(String message)? _onLog;

  /// 解析 `word_id` → 拼写；**解析不出来返回 `null`**（调用方据此**不动那一列**）。
  Future<String?> resolve(String wordId) async {
    if (wordId.isEmpty) return null;

    // ① 本地复习状态里的冗余列 —— 最贴近「列表原本显示的那个值」。
    //
    // 🔴 **必须排除「已经是 ID 形态」的旧值**：否则一条脏值会**自我固化**
    //    （查到自己 ⇒ 返回自己 ⇒ 永远修不掉）。这正是本轮缺陷能一直存在的原因之一。
    final st = await ReviewListQuery(_userDb).stateOf(wordId);
    if (st != null && _usable(st.spelling)) return st.spelling;

    // ② 生词本的冗余列（同样要排除脏值）。
    final uw = await UserWordRepository(_userDb).findByWordId(wordId);
    if (uw != null && _usable(uw.spelling)) return uw.spelling;

    // ③ 划线卡：原文就在**同一个库**的 `highlight` 表里（零跨库成本）。
    if (isHighlightWordId(wordId)) {
      final uuid = highlightUuidOf(wordId);
      if (uuid != null) {
        try {
          final h = await HighlightRepository(_userDb).byId(uuid);
          final text = h?.text.trim() ?? '';
          if (text.isNotEmpty) return text;
        } catch (e) {
          // 读失败不是「没有」—— 让它继续往下走，最后返回 null（**不改那一列**）
          _log('resolve: 读划线原文失败 wordId=$wordId err=$e');
        }
      }
    }

    // ④ 词库外词：`ext:<拼写>` 的 id **自带拼写**，去掉前缀就是词形。
    if (wordId.startsWith(kExternalWordIdPrefix)) {
      final s = wordId.substring(kExternalWordIdPrefix.length).trim();
      if (s.isNotEmpty) return s;
    }

    // ⑤ 正式词：查词库（跨库 ⇒ 由调用方注入）。
    final lookup = _wordLookup;
    if (lookup != null) {
      try {
        final s = await lookup(wordId);
        if (s != null && s.trim().isNotEmpty) return s.trim();
      } catch (e) {
        _log('resolve: 词库查询失败 wordId=$wordId err=$e');
      }
    }

    // ⑥ 解析不出来 ⇒ `null`。
    //
    // 🔴🔴 **这里绝不能 `return wordId`** —— 那正是把显示问题变成数据污染的那一步。
    //      调用方拿到 null 时**不动 `spelling` 列**，本次修复留给下一轮 / 自愈。
    _log('resolve: 解析不出拼写 wordId=$wordId（保持原值，不写占位）');
    return null;
  }

  /// 【自愈】把已经被写成 ID 的 `card_review_state.spelling` 修回真拼写。
  ///
  /// 返回修好的行数。**幂等**：已正确的行不会被重复写。
  ///
  /// # 时机（为什么是「词库就绪后」）
  /// ⑤ 那一级要查 `word.db`。词库没就绪时解析不出正式词的拼写 ——
  /// 若在启动早期跑，会把「本来能修好的」都漏掉。⇒ 由调用方在**词库就绪后**调用
  /// （`word_db_provider` 已有一条同类流程 `_convergeExternalWordIds`）。
  ///
  /// # 代价
  /// 候选 = 全表扫一次 `card_review_state`（单用户几百行，纯本地）。
  /// **候选为 0 时直接返回，连事务都不开** —— 与既有收敛同一种性质。
  Future<int> repairAll() async {
    final rows = await _userDb.query(
      'card_review_state',
      columns: ['word_id', 'spelling'],
    );

    // 🔑 先在**事务外**把所有目标值解析好：解析要读别的表（highlight / 词库），
    //    放进事务里会拖长持锁时间、且嵌套查询要用 txn 句柄。
    final fixes = <String, String>{};
    for (final r in rows) {
      final wordId = (r['word_id'] as String?) ?? '';
      final spelling = (r['spelling'] as String?) ?? '';
      if (wordId.isEmpty || !isWordIdShaped(spelling)) continue;
      final good = await resolve(wordId);
      if (good != null && good != spelling) fixes[wordId] = good;
    }
    if (fixes.isEmpty) return 0;

    await _userDb.transaction((txn) async {
      for (final e in fixes.entries) {
        await txn.update(
          'card_review_state',
          {'spelling': e.value},
          where: 'word_id = ?',
          whereArgs: [e.key],
        );
      }
    });
    _log('repairAll: 修好 ${fixes.length} 行（候选 ${rows.length}）');
    return fixes.length;
  }

  /// 这个值是「**ID 形态**」而不是拼写吗？
  ///
  /// 🔑 它是「停止自我固化」的那个判据，也是自愈的**候选筛子**。
  ///
  /// | 形态 | 判据 | 为什么安全 |
  /// |---|---|---|
  /// | `hl:<uuid>` | 前缀 | `hl:` 不可能是英文单词 |
  /// | `ext:<拼写>` | 前缀 | 同上 |
  /// | `w0xxxxx` | `^w\d{6}$` | 词库 id 恒为 `w` + 6 位数字 |
  ///
  /// ⚠️ `w` + 数字那条特意写成**定长 6 位**而不是 `^w\d+$`：
  ///    后者会把形如 `w2`（如果将来有这种词）误判。宁可漏判（少修一行），
  ///    不可误判（把真拼写当脏值去「修」）。
  static bool isWordIdShaped(String s) {
    if (s.startsWith(kExternalWordIdPrefix)) return true;
    if (s.startsWith('hl:')) return true;
    return RegExp(r'^w\d{6}$').hasMatch(s);
  }

  /// 一个 `spelling` 值能不能直接采信为「真拼写」。
  bool _usable(String s) => s.trim().isNotEmpty && !isWordIdShaped(s);

  void _log(String message) {
    final f = _onLog;
    if (f != null) f(message);
  }
}
