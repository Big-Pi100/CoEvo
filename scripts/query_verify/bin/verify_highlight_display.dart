// CoEvo · 记忆列表**显示规则**验收（来源标签 / 时间标签 · 2026-10-07）
//
// # 为什么需要本脚本
//
// 这两个函数都在**列表页**里被调用，而页面 import Flutter ⇒ 本机验不了。
// 它们的分支又恰好都是**静默出错**的那类：
//   · 来源查不到 ⇒ 显示空白 / 显示一串 uuid（用户看不懂，但**不报错**）
//   · 时间忘了 `toLocal()` ⇒ 晚上划的线显示成**明天**（用户看到「-1 天」）
//   · 按「24 小时差」而不是「日历日」⇒ 昨晚 23:00 划的，今早看显示「今天」
//
// 🔑 本组最要紧的两条：
//   【2】**时区无关**地证明「按本地日算」（否则断言本身会在 CI（UTC）上飘）
//   【1】「来源已不可用」的**措辞**（不能说「已删除」——我们并不知道）
//
// 跑法：`cd scripts/query_verify && dart run bin/verify_highlight_display.dart`
// 退出码：有失败 → 1

import 'dart:io';

import '../../../app/lib/services/highlight_display.dart';
import '../../../app/lib/services/highlight_repository.dart'
    show HighlightSourceType;

int _pass = 0;
int _fail = 0;
final List<String> _failures = [];

void check(String desc, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $desc${detail.isEmpty ? '' : '   [$detail]'}');
  } else {
    _fail++;
    _failures.add(desc);
    print('  🔴 $desc${detail.isEmpty ? '' : '   [$detail]'}');
  }
}

void eq(String desc, Object? actual, Object? expected) =>
    check(desc, actual == expected, '实际=$actual 期望=$expected');

void section(String title) {
  print('\n${'─' * 74}\n$title\n${'─' * 74}');
}

void main() {
  print('═' * 74);
  print('记忆列表显示规则验收');
  print('═' * 74);

  // ══════════════════════════════════════════════════════════════════════
  section('【1】来源标签 highlightSourceLabel');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 「来源已不可用」是**真实且常见**的状态（划线只存 sourceId，标题要现查）：
  //    · 文章可能被下架 / 换源 / 翻页翻不到
  //    · 书可能被用户从书架删了
  // ⇒ 查不到时必须给**准确的话**。

  eq('文章 + 有标题 ⇒ 原标题',
      highlightSourceLabel(
          type: HighlightSourceType.article, articleTitle: 'Why We Read Slowly'),
      'Why We Read Slowly');
  eq('文章 + 查不到 ⇒ 准确的话（不是空白、不是 id）',
      highlightSourceLabel(type: HighlightSourceType.article),
      '原文已不在信息流里');
  eq('文章 + 空串 ⇒ 同上',
      highlightSourceLabel(type: HighlightSourceType.article, articleTitle: ''),
      '原文已不在信息流里');
  eq('文章 + 全空白 ⇒ 同上（要 trim）',
      highlightSourceLabel(type: HighlightSourceType.article, articleTitle: '   '),
      '原文已不在信息流里');
  // 🔴 措辞：不能说「已删除」—— 我们只知道「现在翻不到」
  //    （判据：说清「我知道什么」，不说「我猜什么」）
  final notFound =
      highlightSourceLabel(type: HighlightSourceType.article);
  check('🔴 措辞不臆断（不含「删除」「丢失」这类我们并不知道的词）',
      !notFound.contains('删除') && !notFound.contains('丢失'), notFound);

  eq('书 + 书名 ⇒ 《书名》 · 第 N 章',
      highlightSourceLabel(
          type: HighlightSourceType.book, bookTitle: 'A Tale of Two Cities', chapterIdx: 0),
      '《A Tale of Two Cities》 · 第 1 章');
  // 🔴 章序 **+1**（库里 0 起，给人看要 1 起）—— 差一就变成「第 0 章」
  eq('🔴 chapterIdx 是 0 起 ⇒ 显示第 1 章（不是第 0 章）',
      highlightSourceLabel(
          type: HighlightSourceType.book, bookTitle: 'X', chapterIdx: 0),
      '《X》 · 第 1 章');
  eq('chapterIdx = 11 ⇒ 第 12 章',
      highlightSourceLabel(
          type: HighlightSourceType.book, bookTitle: 'X', chapterIdx: 11),
      '《X》 · 第 12 章');
  eq('书 + 没记章号 ⇒ 只给书名（不显示「第 1 章」猜一个）',
      highlightSourceLabel(type: HighlightSourceType.book, bookTitle: 'X'),
      '《X》');
  eq('书 + 查不到 ⇒ 准确的话',
      highlightSourceLabel(type: HighlightSourceType.book),
      '这本书已不在书架里');
  eq('书 + 空串 ⇒ 同上',
      highlightSourceLabel(type: HighlightSourceType.book, bookTitle: '  '),
      '这本书已不在书架里');

  // 类型隔离：两个标题**不能串用**（传错了会显示另一类来源的名字）
  eq('文章**忽略** bookTitle（类型隔离）',
      highlightSourceLabel(
          type: HighlightSourceType.article, bookTitle: '某本书'),
      '原文已不在信息流里');
  eq('书**忽略** articleTitle（类型隔离）',
      highlightSourceLabel(
          type: HighlightSourceType.book, articleTitle: '某篇文章'),
      '这本书已不在书架里');

  // ══════════════════════════════════════════════════════════════════════
  section('【2】时间标签 highlightTimeLabel');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔑 断言**不依赖运行环境时区**（CI 是 UTC，本机是 +8）——
  //    所以下面一律用「相对于 now 的构造」，并在【3】单独证明「按本地日算」。

  final now = DateTime(2026, 10, 7, 10, 0); // 本地时间（构造即本地）

  eq('同一时刻 ⇒ 今天',
      highlightTimeLabel(DateTime(2026, 10, 7, 9, 0), now: now), '今天');
  eq('同一天更早（凌晨）⇒ 今天',
      highlightTimeLabel(DateTime(2026, 10, 7, 0, 1), now: now), '今天');
  eq('昨天 23:50 ⇒ 昨天',
      highlightTimeLabel(DateTime(2026, 10, 6, 23, 50), now: now), '昨天');
  eq('前天 ⇒ 前天',
      highlightTimeLabel(DateTime(2026, 10, 5, 8, 0), now: now), '前天');
  eq('4 天前（同年）⇒ MM-DD',
      highlightTimeLabel(DateTime(2026, 10, 3, 8, 0), now: now), '10-03');
  eq('🔴 补零：1 月 5 日 ⇒ 01-05（不是 1-5）',
      highlightTimeLabel(DateTime(2026, 1, 5, 8, 0), now: now), '01-05');
  eq('🔴 跨年 ⇒ 带年份',
      highlightTimeLabel(DateTime(2025, 12, 31, 8, 0), now: now), '2025-12-31');
  eq('未来时间（时钟偏差）⇒ 今天（不显示负数天）',
      highlightTimeLabel(DateTime(2026, 10, 8, 3, 0), now: now), '今天');

  // 🔴 「按**日历日**比」而不是「24 小时差」——
  //    昨晚 23:00 划的，今天 01:00 看只有 2 小时差，但**跨了一个日历日** ⇒ 应显示「昨天」。
  //    ⚠️ 这条如果用「小时差」实现就会红。
  final lateNight = DateTime(2026, 10, 7, 1, 0);
  eq('🔴 昨晚 23:00 划的、今天 01:00 看 ⇒ 昨天（按日历日，不是按小时差）',
      highlightTimeLabel(DateTime(2026, 10, 6, 23, 0), now: lateNight), '昨天');

  // 奇数边界：月末 / 月初
  eq('跨月（10-01 看 09-30）⇒ 昨天',
      highlightTimeLabel(DateTime(2026, 9, 30, 12, 0),
          now: DateTime(2026, 10, 1, 9, 0)),
      '昨天');
  eq('跨月且同年 ⇒ MM-DD',
      highlightTimeLabel(DateTime(2026, 9, 20, 12, 0),
          now: DateTime(2026, 10, 7, 9, 0)),
      '09-20');

  // ══════════════════════════════════════════════════════════════════════
  section('【3】🔴 时区：必须按**本地日**算（UTC 入库 → 本地显示）');
  // ══════════════════════════════════════════════════════════════════════
  //
  // `created_at` 存的是 **UTC**（`kSqlNowUtc`，带 `Z`）。
  // 若忘了 `toLocal()`：晚上 8 点之后划的线会被算成「明天」⇒ 显示成**未来**。
  //
  // 🔑 **断言要时区无关**：不能写「UTC+8 时某值 → 今天」（CI 是 UTC，会飘）。
  //    ⇒ 改为证明**幂等/一致**：同一个物理时刻，
  //      「传 UTC」与「传它的本地表示」必须得到**同一个标签**。
  //      （若实现里少了 `toLocal()`，这两者就会不同 ⇒ 红。）
  final instants = <DateTime>[
    DateTime.utc(2026, 10, 7, 2, 0), // UTC 凌晨（+8 是当天 10:00）
    DateTime.utc(2026, 10, 6, 20, 0), // UTC 20:00（+8 是次日 04:00 ⇒**跨日**）
    DateTime.utc(2026, 1, 1, 3, 30), // 跨年附近
  ];
  var allSame = true;
  final detail = <String>[];
  for (final u in instants) {
    final a = highlightTimeLabel(u, now: now);
    final b = highlightTimeLabel(u.toLocal(), now: now);
    detail.add('${u.toIso8601String()}→$a / local→$b');
    if (a != b) allSame = false;
  }
  check('🔴 UTC 输入与「它的本地表示」得到**同一标签**（证明按本地日算）',
      allSame, detail.join(' | '));

  // 另一条更直接的：把「本地日」造出来，断言它按本地日归组。
  // 取一个「本地时间的今天 00:30」，它的 UTC 可能落在昨天 ——
  // 但标签必须仍是「今天」（因为我们关心的是**用户看到的那一天**）。
  final localEarlyToday = DateTime(now.year, now.month, now.day, 0, 30);
  eq('本地今天 00:30 ⇒ 今天（哪怕它的 UTC 落在昨天）',
      highlightTimeLabel(localEarlyToday, now: now), '今天');

  // 🔴 把「本地今天 00:30」**转成 UTC** 再传进去 —— 必须仍是「今天」。
  //    若实现里少了 `toLocal()`：`when` 会是「昨天的某个时刻」（在东八区）
  //    ⇒ 判成「昨天」⇒ 红。
  //
  // ⚠️⚠️ **本条在 UTC 时区的机器上无区分力**（CI 就是 UTC）：
  //    那时 `toLocal()` 是恒等变换，「有/没有」结果一样。
  //    ⇒ 它的**区分力来自本机时区（UTC+8）**，我在本机证伪过（去掉 `toLocal()` ⇒ 本条红）。
  //    📌 如实标注：**CI 绿不代表这条被验过** —— 这是本脚本的已知盲区。
  //       要让它无条件有区分力，得注入时区（Dart 的 `DateTime` 不支持随便改时区），
  //       成本远大于收益 ⇒ 留在本机验 + 把盲区写出来。
  eq('🔴 本地今天 00:30 **转成 UTC** 传入 ⇒ 仍是今天（少了 toLocal() 就会红）',
      highlightTimeLabel(localEarlyToday.toUtc(), now: now), '今天');

  // ══════════════════════════════════════════════════════════════════════
  print('\n${'═' * 74}');
  if (_fail > 0) {
    print('🔴 失败 $_fail 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 若【1】失败 → 检查措辞是否臆断（说「删除」而我们并不知道）；');
    print('  若【2】失败 → 检查是否用「小时差」而不是「日历日」比；');
    print('  若【3】失败 → 检查 `created_at` 读出后有没有 `toLocal()`。');
    exit(1);
  }
  print('✅ 全部通过：$_pass 项');
  print('═' * 74);
  print('');
  print('⚠️ 本脚本**查不出**的：页面的排版/截断/交互（需 Flutter 环境 + 真机）。');
}
