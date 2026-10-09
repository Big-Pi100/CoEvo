// CoEvo · 记忆列表的**显示规则**（来源标签 / 时间标签）—— 纯逻辑 ⇒ 本机可断言
//
// # 🔑 为什么单独一层
//
// 这两个函数里有**分支**（来源已不可用 / 跨年 / 今天昨天前天），
// 而它们都在**列表页**里被调用 —— 页面 import Flutter ⇒ 本机验不了。
// ⇒ 把带分支的部分抽出来（同 `reading_settings` / `highlight_grader` 的做法）。
//
// # 🔴 「来源已不可用」是真实且常见的状态，不是异常
//
// 划线只存了 `sourceId`（文章 id / 书的 uuid），**没存标题** —— 标题要现查：
// · 文章：可能在信息流里被下架 / 换源 / 翻页翻不到
// · 书：用户可能已经把它从书架删了
//
// ⇒ 查不到时**必须给准确的话**（不能显示空、也不能显示 id）。
// 🔑 而**那条划线本身不会消失** —— 这正是「`highlight` 存全文而不只存 offset」的收益：
//    来源没了，用户写过的笔记和划过的那段文字仍在。

import 'highlight_repository.dart' show HighlightSourceType;

/// 列表项上的**来源标签**。
///
/// [articleTitle] / [bookTitle] 由调用方查好传进来（`null` = 查不到）。
///
/// ⚠️ 刻意**不在这里查库**：本函数要保持纯函数（可断言），
///    查询是调用方的事（它才知道有哪些 provider）。
String highlightSourceLabel({
  required HighlightSourceType type,
  int? chapterIdx,
  String? articleTitle,
  String? bookTitle,
}) {
  switch (type) {
    case HighlightSourceType.article:
      final t = articleTitle?.trim() ?? '';
      // 🔑 说「不在信息流里」而不是「已删除」——我们**不知道**它是不是被删了，
      //    只知道「现在翻不到」（可能是换源、可能是文章被平台下架）。
      //    📌 判据：**说清「我知道什么」，不要说「我猜什么」。**
      return t.isEmpty ? '原文已不在信息流里' : t;
    case HighlightSourceType.book:
      final t = bookTitle?.trim() ?? '';
      if (t.isEmpty) return '这本书已不在书架里';
      // ⚠️ `chapterIdx` 是**章内下标（0 起）**，给人看要 +1。
      //    `null` = 入库时没记（理论上不会，但别让显示层崩）。
      final ch = chapterIdx == null ? '' : ' · 第 ${chapterIdx + 1} 章';
      return '《$t》$ch';
  }
}

/// 列表项上的**时间标签**。
///
/// | 距今 | 显示 |
/// |---|---|
/// | 今天（含未来 —— 时钟偏差）| `今天` |
/// | 1 天 | `昨天` |
/// | 2 天 | `前天` |
/// | 今年内 | `MM-DD` |
/// | 跨年 | `YYYY-MM-DD` |
///
/// 🔴 **必须 `toLocal()`**：`created_at` 存的是 **UTC**（`kSqlNowUtc`，带 `Z`）。
///    不转本地时区的话，晚上 8 点之后划的线会被算成「明天」⇒
///    显示成**未来**（用户看到「今天划的显示 -1 天」这种怪象）。
///    📌 与「同一件事的口径只能一处权威」同族：时区转换也是一处口径 —— 在这里转一次。
///
/// [now] 只为断言注入（生产不传）。
String highlightTimeLabel(DateTime when, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toLocal();
  final w = when.toLocal();
  // 🔑 按**日历日**比，不是按 24 小时差 —— 昨晚 23:00 划的，今天 01:00 看应显示「昨天」
  //    （按小时差算只有 2 小时 ⇒ 会显示「今天」，用户会觉得错）。
  final today = DateTime(n.year, n.month, n.day);
  final that = DateTime(w.year, w.month, w.day);
  final days = today.difference(that).inDays;

  if (days <= 0) return '今天'; // ⚠️ 含负数：时钟偏差/未来时间，当今天（别显示「-1 天」）
  if (days == 1) return '昨天';
  if (days == 2) return '前天';
  if (w.year == n.year) return '${_two(w.month)}-${_two(w.day)}';
  return '${w.year}-${_two(w.month)}-${_two(w.day)}';
}

String _two(int v) => v < 10 ? '0$v' : '$v';
