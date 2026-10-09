/// **记忆列表** —— 划过的都在这里：能看全文、能回原文、能改笔记、能删掉。
///
/// # 依据
/// 设计稿 `docs/design/visual-generic-card-2026-10-07.html` **§8**（界面锚点 + 交互表 + 边界表）。
/// 本页的**全部设计依据**都在那里，不在这里重复。
///
/// # 🔑 路由形态：顶层 `/highlights`（与 `/achievements` 同级）
///
/// 依据是项目既有的那条判据 —— **「它是不是某个 tab 的内容」**：
/// · **不是**：它是「我的」页的**二级信息页**（同「我的成就」「关于」）
/// · 且它跨**两种来源**（文章 + 书）⇒ 挂在任何一个 tab 下都不合适
/// ⇒ **顶层路由**，不带 tabbar。
/// （对照：收藏清单是 `/home/bookmarks` **子路由**，因为它是「阅读」tab 的内容。）
///
/// # 🔑 为什么「点一项 = 展开」而不是「跳详情页」
///
/// 列表里最常做的是「看看这段写了什么」—— 跳页再返回太重。
/// 展开态把**全文 + 笔记 + 三个动作**一次给出 ⇒ 大多数事一次点击解决。
/// ⚠️ **单条展开**（不是多条都能展开）：同屏展开两条会把别的挤下去，用户失去位置感；
/// 展开本来就是为了「专心看这一条」。
///
/// # 🔴 「来源已不可用」是真实状态（不是异常）
///
/// 划线只存 `sourceId`，**没存标题** ⇒ 标题要现查（文章查信息流 / 书查书架）。
/// 查不到时**给准确的话**（「原文已不在信息流里」），而不是空白或 id。
/// 🔑 而**那条划线本身不会消失** —— 这正是「`highlight` 存全文」的收益：
/// 来源没了，用户写过的笔记和划过的那段文字仍在。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/feed_item.dart';
import '../providers/book_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/highlight_provider.dart';
import '../providers/user_db_provider.dart';
import '../services/highlight_display.dart';
import '../services/highlight_repository.dart';
import '../services/highlight_id.dart' show highlightWordId;
import '../theme/clay.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/note_dialog.dart';

class HighlightsScreen extends ConsumerStatefulWidget {
  const HighlightsScreen({super.key});

  @override
  ConsumerState<HighlightsScreen> createState() => _HighlightsScreenState();
}

class _HighlightsScreenState extends ConsumerState<HighlightsScreen> {
  /// 当前**展开**的那一条（`null` = 全部收起）。见类文档。
  String? _expandedId;

  // ─────────────────────────────────────────────────────────────────────
  // 动作（三个：改笔记 / 删除 / 打开原文）
  // ─────────────────────────────────────────────────────────────────────

  /// 改 / 清空笔记（走 §7 那一个 `NoteDialog` —— 三个入口共用同一份实现）。
  Future<void> _editNote(Highlight h) async {
    final r = await NoteDialog.show(context, excerpt: h.text, initial: h.note);
    if (r == null || !mounted) return; // 取消 ⇒ 什么都不做

    try {
      final db = await ref.read(userDbProvider.future);
      await HighlightRepository(db).setNote(h.id, r.note);
      // 🔑 写库成功之后才 bump（顺序反了 ⇒ 读端在写入完成前重查旧值，且不会再刷新）
      ref.read(userDbRevisionProvider.notifier).bump();
      if (!mounted) return;
      _snack(r.isClearing ? '笔记已删除' : '笔记已保存');
    } catch (e, st) {
      debugPrint('[highlights] 笔记保存失败：$e\n$st');
      if (!mounted) return;
      _snack('笔记没存上，请再试一次');
    }
  }

  /// 删除（**软删** —— 行仍在库里，只是不再显示 / 不再复习）。
  ///
  /// 🔑 设计稿 §8 定：**不加二次确认**（理由：软删可恢复、划线是低成本动作）。
  /// ⚠️ 但「删除」在界面上用**弱化色**（`ink3`）而不是朱砂 —— 不引导用户去点它。
  Future<void> _remove(Highlight h) async {
    try {
      final db = await ref.read(userDbProvider.future);
      await HighlightRepository(db).remove(h.id);
      ref.read(userDbRevisionProvider.notifier).bump();
      if (!mounted) return;
      // 🔑 删了就别留着一个「指向已消失条目」的展开态（否则列表重算后它会错位到别人身上）
      setState(() => _expandedId = null);
      _snack('已删除');
    } catch (e, st) {
      debugPrint('[highlights] 删除失败：$e\n$st');
      if (!mounted) return;
      _snack('没删掉，请再试一次');
    }
  }

  /// 恢复复习（划线卡）—— 与复习页那一行的「暂停」**对称**。
  ///
  /// 🔑 这是划线卡「暂停」的**唯一恢复出口**：
  ///    · 生词的恢复是**再次查词**（一个自然的、别处已经存在的动作）
  ///    · 划线**没有**那个动作 ⇒ 不给这个入口，用户暂停后就**永远找不回**
  ///      （表现为「列表里少了一条，不知道为什么、也不知道怎么办」）。
  ///    📌 判据：**有动作就必须有出口** ——「静默失败 + 无出口」比报错更糟。
  ///
  /// ⚠️ 传的是 `word_id`（`hl:<id>`）而不是裸 id —— 与复习页调用**同一形态**，
  ///    剥前缀的口径只留在 `highlight_id.dart` 一处。
  Future<void> _resume(Highlight h) async {
    try {
      final db = await ref.read(userDbProvider.future);
      final ok = await HighlightRepository(db).resume(highlightWordId(h.id));
      // 幂等：本来就没暂停 ⇒ 不刷界面、不提示（同 `review_screen._pause` 的处理）
      if (!ok) return;
      ref.read(userDbRevisionProvider.notifier).bump();
      if (!mounted) return;
      _snack('已恢复复习');
    } catch (e, st) {
      debugPrint('[highlights] 恢复失败 id=${h.id}：$e\n$st');
      if (!mounted) return;
      _snack('没恢复上，请再试一次');
    }
  }

  /// 打开原文 —— ⚠️ **只跳到「那篇 / 那本」，不精确定位到划线处**（设计稿 §8 已如实标注）。
  ///
  /// ⚠️ 来源已不可用时**不在这里拦**：跳过去由目标页给准确的话
  /// （`reader_screen` 有「找不到这篇文章」分支，`book_reader_screen` 有错误态）。
  /// 📌 判据：**「打不开」的判定归目标页** —— 两处各判一次会漂。
  void _openSource(Highlight h) {
    switch (h.sourceType) {
      case HighlightSourceType.article:
        context.push('/article/${h.sourceId}');
      case HighlightSourceType.book:
        context.push('/books/${h.sourceId}');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  // ─────────────────────────────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    final listAsync = ref.watch(highlightListProvider);
    final items = highlightListOf(listAsync);
    // 🔑 「打不开」与「空」要分开 —— 前者给准确提示，后者给引导文案。
    //    两者在 `highlightListOf` 里都是空列表 ⇒ 必须再看一眼 `isReady`。
    final ready = !listAsync.hasError;

    // ── 来源标题：两个 `watch` 都在 build 顶层（Riverpod 要求无条件执行）──
    //
    // 🔴 为什么不放进 `if (items.isEmpty)` 之类的分支里：
    //    「上一次 build 订阅了、这一次没订阅」会让状态漂移，
    //    表现为「有时候不刷新」且**不报错**（同 `bookmark_list_screen` 的教训）。
    final articleIds = <int>[];
    for (final h in items) {
      if (h.sourceType == HighlightSourceType.article) {
        final id = int.tryParse(h.sourceId);
        if (id != null) articleIds.add(id);
      }
    }
    // 🔑 排序后 join → key 稳定（同一批 id 任何顺序都命中同一缓存）
    articleIds.sort();
    final articleTitles =
        ref.watch(feedByIdsProvider(articleIds.join(','))).valueOrNull ??
            const <int, FeedItem>{};
    final books =
        ref.watch(bookListProvider).valueOrNull ?? const <BookSummary>[];
    final bookTitles = {for (final b in books) b.id: b.title};

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        // 🆕 本页现在是「复习」tab 内的视图 ⇒ 底部由 shell 的 tabbar 处理
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: !ready
                  ? _Unavailable(t: t)
                  : items.isEmpty
                      ? _EmptyState(t: t)
                      : _list(t, items, articleTitles, bookTitles),
            ),
          ],
        ),
      ),
    );
  }

  // 🆕 2026-10-08：本页的**标题栏整体删除** ——
  //    白哥定案：「把『我的划线』移动到复习页面，名称改为『笔记』与『复习』同级」。
  //    ⇒ 标题「笔记」由容器 `ReviewTabScreen` 的标题行给出（与「复习」平级）。
  //
  // 🔴 **「返回」按钮为什么不需要了**（那条教训仍然有效）：
  //    本页原来是**顶层路由** `/highlights`，用户 push 进来后必须有可见的返回入口
  //    （项目踩过「清单页没有返回入口」：`bookmark_list_screen` 的文件头记着那次）。
  //    现在它是**「复习」tab 内的一个视图** ⇒ 出口是**切 tab / 点底部 tabbar**，
  //    与「阅读」tab 的书架段完全一样 —— 那里也没有返回按钮。
  //    📌 判据没变，变的是**这一页在哪一层**：判据是「用户有没有出口」，
  //       不是「有没有返回按钮」。

  Widget _list(
    CoEvoTokens t,
    List<Highlight> items,
    Map<int, FeedItem> articleTitles,
    Map<String, String> bookTitles,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final h = items[i];
        return _HighlightTile(
          t: t,
          highlight: h,
          expanded: _expandedId == h.id,
          sourceLabel: highlightSourceLabel(
            type: h.sourceType,
            chapterIdx: h.chapterIdx,
            articleTitle: h.sourceType == HighlightSourceType.article
                ? articleTitles[int.tryParse(h.sourceId)]?.title
                : null,
            bookTitle: h.sourceType == HighlightSourceType.book
                ? bookTitles[h.sourceId]
                : null,
          ),
          timeLabel: highlightTimeLabel(h.createdAt),
          onTap: () => setState(
            () => _expandedId = _expandedId == h.id ? null : h.id,
          ),
          onOpenSource: () => _openSource(h),
          onEditNote: () => _editNote(h),
          onRemove: () => _remove(h),
          onResume: () => _resume(h),
        );
      },
    );
  }
}

/// 一条划线（收起 = 摘录两行；展开 = 全文 + 笔记 + 三个动作）。
class _HighlightTile extends StatelessWidget {
  const _HighlightTile({
    required this.t,
    required this.highlight,
    required this.expanded,
    required this.sourceLabel,
    required this.timeLabel,
    required this.onTap,
    required this.onOpenSource,
    required this.onEditNote,
    required this.onRemove,
    required this.onResume,
  });

  final CoEvoTokens t;
  final Highlight highlight;
  final bool expanded;
  final String sourceLabel;
  final String timeLabel;
  final VoidCallback onTap;
  final VoidCallback onOpenSource;
  final VoidCallback onEditNote;
  final VoidCallback onRemove;

  /// 🆕 2026-10-08：恢复复习（**只在 [Highlight.paused] 为真时**才被渲染出来）。
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final note = highlight.note;
    final hasNote = note != null && note.trim().isNotEmpty;

    return Clay(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 摘录（收起时 2 行截断；展开时给全文）──
            Text(
              // 🔑 收起用 `excerpt`（已折行 + 截断 60 字），展开用 `text` 全文
              expanded ? highlight.text : highlight.excerpt,
              maxLines: expanded ? null : 2,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: CoFonts.latinSerif,
                fontSize: 13.5,
                height: 1.6,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: 8),

            // ── 来源 + 时间 ──
            Row(
              children: [
                Expanded(
                  child: Text(
                    sourceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .05 * 10,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 🆕 已暂停标记（2026-10-08）—— **收起态就能看见**：
                //    它是一条「为什么这条不在复习里」的解释，藏起来用户只会困惑。
                //    ⚠️ 用 `ink2` 而不是 accent：它是**状态**不是动作
                //    （同「删除用弱化色」的取向：颜色表达语义，别让状态去争注意力）。
                if (highlight.paused) ...[
                  Text(
                    '已暂停',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .05 * 10,
                      color: Color(t.ink2.argb32),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  timeLabel,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .05 * 10,
                    color: Color(t.accent.argb32),
                  ),
                ),
              ],
            ),

            // ── 🔴 展开态：笔记 + 三个动作 ──
            //
            // ⚠️ 笔记**只在展开时**显示 —— 收起态挤两行笔记会把列表变成一团。
            //    （与复习页的「判定前不显示笔记」是两件事：那里是**泄题**，
            //      这里是**密度**。同一个元素的两种取舍理由不同，不要混。）
            if (expanded) ...[
              if (hasNote) ...[
                const SizedBox(height: 11),
                Divider(height: 1, thickness: 1, color: Color(t.line.argb32)),
                const SizedBox(height: 10),
                Text(
                  note,
                  style: TextStyle(
                    fontFamily: CoFonts.uiSans,
                    fontSize: 12,
                    height: 1.65,
                    color: Color(t.ink2.argb32),
                  ),
                ),
              ],
              const SizedBox(height: 11),
              Row(
                children: [
                  _action(t, '打开原文', onOpenSource, accent: true),
                  const SizedBox(width: 16),
                  _action(t, hasNote ? '改笔记' : '写笔记', onEditNote),
                  const SizedBox(width: 16),
                  // 🆕 恢复复习 —— 🔴 **只在已暂停时出现**（不常驻 ⇒ 不挤，
                  //    也不会让「没暂停过」的用户去想「这是干嘛的」）。
                  //    ⚠️ 用 accent（与「打开原文」同为**正向**动作）；
                  //       「删除」保持弱化 —— 颜色在这里表达的是**语义**，不是优先级。
                  if (highlight.paused) ...[
                    _action(t, '恢复复习', onResume, accent: true),
                    const SizedBox(width: 16),
                  ],
                  // 🔴 删除用弱化色（不引导用户去点）
                  _action(t, '删除', onRemove),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _action(CoEvoTokens t, String label, VoidCallback onTap,
          {bool accent = false}) =>
      GestureDetector(
        onTap: onTap,
        // `opaque`：整块可点（文字本身小，对已举起的手指不友好）
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Color((accent ? t.accent : t.ink3).argb32),
            ),
          ),
        ),
      );
}

/// 空态 —— **教会用户「划线在哪」**，而不是只说「没有内容」。
///
/// 🔑 同收藏清单的取向（那里的设计稿原话：「空状态要教会用户书签在哪」）。
/// 本页是新功能，用户很可能**还不知道划线能干什么** ⇒ 空态要示范一次。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.t});

  final CoEvoTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 60),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 粘土凹陷圆环（与收藏清单空态同一形态）
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(t.sunken.argb32),
              ),
              child: Icon(Icons.draw_outlined,
                  size: 26, color: Color(t.ink3.argb32)),
            ),
            const SizedBox(height: 18),
            Text(
              '还没有划过线',
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(t.ink.argb32),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '在文章或书里长按选中一段，点菜单里的「划线」——\n'
              '划过的内容会出现在这里，也会进复习。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CoFonts.uiSans,
                fontSize: 12.5,
                height: 1.7,
                color: Color(t.ink3.argb32),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 库打不开 —— **给准确的话**，而不是让页面变成空白 / 报错页。
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.t});

  final CoEvoTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 60),
        child: Text(
          '暂时读不到划线记录。\n若一直这样，请重启 App 再试。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.7,
            color: Color(t.ink3.argb32),
          ),
        ),
      ),
    );
  }
}
