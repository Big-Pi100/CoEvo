// CoEvo · 生词本 / 查词记录的 provider
//
// 🔴 设计约束：连接从 `userDbProvider` 取（**不自己 open**）—— 见其文件头「为什么必须共享」。
//
// # 与 `bookmarkProvider` 的分工
// | | `bookmarkProvider` | 本文件 |
// |---|---|---|
// | 关注点 | 「**这篇**收藏了吗」（`Set<int>` · 高频单条判定） | 「**收进去** / 记一次查词」（写为主） |
// | 状态 | `AsyncNotifier<Set<int>>`（要驱动 UI 重绘） | **不暴露状态**，只暴露仓储 |
//
// # 🔑 为什么本 provider **不**做成 `AsyncNotifier`
// 「某词是否在生词本」是**查词那一刻**才问的（不是每帧渲染都要问），
// 所以不需要一个长期订阅的状态对象 —— 那会带来「什么时候刷新」的额外问题
// （而 `bookmarkProvider` 需要它，是因为书签按钮**在信息流每张卡上都在渲染**）。
// → 保持最小：`FutureProvider<UserWordRepository>`，用到时 `await` 一次。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/article.dart' show ArticleLookup;
import '../services/user_word_repository.dart';
import 'user_db_provider.dart';

/// 生词本仓储（**已就绪**才拿得到 —— `await ref.read(...future)` 或 `watch`）。
///
/// 用法：
/// ```dart
/// final repo = await ref.read(userWordProvider.future);
/// final r = await repo.add(wordId, spelling, sentence: sentence);
/// ```
///
/// ## ⚠️ 消费约定（同 `bookmarkProvider` 的硬约束）
/// **查词写入不得阻塞释义渲染** —— 写入失败只记日志，
/// 用户照常看到浮层（读词义是产品核心，不该因为写库失败而看不到）。
/// 见 `reader_screen._lookupWord` 的调用处。
final userWordProvider = FutureProvider<UserWordRepository>((ref) async {
  final db = await ref.watch(userDbProvider.future);
  return UserWordRepository(db);
});

// 🔴 本文件**曾经**有两个 provider，都已在 2026-09-28 删除 —— 记下来是为了
//    防止后来者把它们「接回去」（那会让已解决的问题复现）。
//
// ## ① `userWordListProvider`（生词本列表）—— 随 `/home/words` 独立页一起删
// 原因：**生词本就是复习页本身**（`ui-ux` §6.2，白哥原话：
// 「生词本就是复习管理……就不要移入移出了」）。复习列表的数据源是
// `card_review_state`（排序需要 FSRS 的 `next_review_at`）→ 见
// `providers/review_list_provider.dart` 的 `reviewListProvider`。
//
// ## ② `userWordCountProvider`（生词数，2026-09-28 下午）
// 它原本只服务首页标题栏的「生词 N」入口 —— 该入口**已取消**
// （复习本身就是底部 tab，再放按钮是把导航做第二遍）→ 零消费者。
// 🔑 删除判据：**零消费者 = 死代码**，即便它「看起来以后可能有用」。
//    留着会让下一个人以为「生词数在界面上某处显示着」，从而把它接回界面 ——
//    而那个数字**该不该显示、显示在哪**是个**产品问题**，不该由一个
//    遗留 provider 悄悄决定。
//
// ⚠️ 附带现状（**产品待定项，不是本文件的事**）：
//    `UserWordRepository.count()` **仍在用** —— `add()` 内部拿它判 200 词上限
//    （`kUserWordLimitFree`）。但该上限**目前在界面上完全不可见**：
//    超出时只有 `reader_screen` 里一行 `debugPrint`，用户毫无感知。
//    → 属于「静默失败 + 无出口」那一类，提示时机待产品定。
//
// 🔑 「删掉一个功能后要清理它的语义残留」的既定原则：注释里的旧概念
//    （如表名、字段名、这里的 provider 名）留着，后续开发会不断把它加回来。

/// **这篇文章里我查过的词**（+ 各自 FSRS 状态）—— **阅读页痕迹的数据源**。
///
/// # 🔑 为什么参数是 `articleId`
/// 痕迹的语义是「**我和这篇文章的关系**」（`coevo_tokens.dart` 原文）——
/// 若用全部生词，打开任何一篇文章都会显示同一批底色。
/// 详见 `UserWordRepository.lookupsForArticle` 的说明。
///
/// # ⚠️ `autoDispose` 是有意的
/// 读者翻过几十篇文章，每篇的痕迹表都留在内存里没有意义
/// （退出阅读页就该释放）。而它不是「切 tab 会回来」的那类状态 ——
/// 阅读页是**压栈进去**的（`context.push('/article/:id')`），出栈即销毁。
///
/// # 🔑 失败时**不抛**（`valueOrNull` → 空列表）
/// 痕迹是**增强**而不是内容本身：库读不到时，正文照常显示，只是没有底色。
/// 📌 判据：**「增强」不该有能力阻断「主体」** ——
///    若这里抛错，用户会因为「生词本读不出来」而**看不到文章**，
///    那是把次要功能放在了主路径上（同「登录态不该成为内容渲染的前置条件」）。
final articleLookupsProvider =
    FutureProvider.autoDispose.family<List<ArticleLookup>, int>((ref, articleId) async {
  final repo = await ref.watch(userWordProvider.future);
  return repo.lookupsForArticle(articleId);
});
