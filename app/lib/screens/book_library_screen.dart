// CoEvo · 我的书库
//
// # 🔴 本页现在是「阅读」tab 内的一个**平级视图**（2026-10-04 白哥定案）
//
// 白哥原话：「书库与今日精选是**平级的页面**，入口不是一个下方的按钮
// 而是与『今日精选』**title 平级**，你应该给我设计稿再做，而不是直接做」。
//
// ⇒ 改为**标题级双 Tab**（设计稿 `book-library-entry-placement-2026-10-04.html` 方案 A）：
//
// | | 谁提供 |
// |---|---|
// | 页面骨架（`Scaffold` / `SafeArea` / 底部留白）| `ReadingTabScreen`（容器）|
// | 标题栏（`今日精选 ｜ 书库` 双标题 + 右侧动作）| `ReadingTabScreen` |
// | **本视图** | 只剩「列表 / 空态 / 错误态」 |
//
// ⚠️ 所以本文件**不再有** `Scaffold`、`SafeArea`、标题栏 ——
//    它们是**容器**的职责；本视图自带一套就会出现两层骨架（且标题栏重复）。
//    🔑 同理：**「导入」按钮在容器的标题栏里**（右上角），
//    本视图通过 [onImport] 回调触发同一段流程
//    （实现见 `services/ebook/book_import_flow.dart`，**只有一处**）。
//
// 🔴 **不再有返回键**（白哥 2026-10-04 定）：
//    原先它是 `push` 进来的顶层页（`/books`），需要返回；
//    现在是**同一屏内切换的一段** ⇒ 点「今日精选」即可回去，
//    再放一个返回箭头是**同一目的的第二个出口**（同「生词」按钮被删的理由）。
//
// # 与「阅读页」的分工
//
// | 页 | 职责 |
// |---|---|
// | 本视图（阅读 tab 第二段） | **管理**：导入、看进度、删书 |
// | 阅读页（`/books/:id`） | **阅读**：取章、划词、朗读、记进度 |
//
// # 🔴 三个刻意的取舍
//
// ① **不解析封面图**（设计文档 §4.2）—— 用**标题首字**做封面占位。
//    解析封面要把依赖从「纯文本」扩到「图片解码」，而它只影响列表观感。
// ② **删书要二次确认**（`Dismissible.confirmDismiss`）——
//    滑动删除太容易误触，而书**删了就没了**（正文是我们解析的副本，
//    用户的原文件虽有，但要重新导入一遍）⇒ 必须确认。
// ③ **导入成功不自动跳阅读页**，而是给一个带「打开」动作的提示 ——
//    自动跳会让「连导好几本」变得很难受；而带动作的提示两种场景都照顾到。
//    📌 判据：**别替用户决定下一步**（他要读就点「打开」，要继续导就忽略提示）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/book_provider.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/clay_button.dart';
import '../widgets/co_dialog.dart';
import '../widgets/group_qrcode_dialog.dart';

class BookLibraryScreen extends ConsumerStatefulWidget {
  const BookLibraryScreen({super.key, required this.onImport});

  /// 触发导入 —— 实现由 `services/ebook/book_import_flow.dart` 提供，
  /// 由容器（`ReadingTabScreen`）传入。
  ///
  /// 🔑 **空态里那个「导入文件」按钮与标题栏右上角的「导入」是同一个动作** ——
  ///    两处都调这一个回调，不各写一遍（判据：一处权威）。
  final VoidCallback onImport;

  @override
  ConsumerState<BookLibraryScreen> createState() => _BookLibraryScreenState();
}

class _BookLibraryScreenState extends ConsumerState<BookLibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return ref.watch(bookListProvider).when(
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          // 🔑 错误要**能重试**（一个干巴巴的错误页 = 「静默失败 + 无出口」）
          error: (e, _) => _errorState(t, e),
          data: (books) => books.isEmpty ? _emptyState(t) : _list(t, books),
        );
  }

  /// 空态 —— 🔑 **必须给「下一步做什么」**，不是一个空页面。
  ///
  /// 🆕 2026-10-04：加**进群引导卡**（设计稿形态③ · 白哥定）。
  ///    「书库为空」的常见根因是**不知道怎么弄到电子书**，而群正是
  ///    「教方法 + 陪读」（`docs/operations/wechat-study-group-plan-*` §3.1）
  ///    ⇒ 这里挂引导是**承接场景**，不是贴广告。
  Widget _emptyState(CoEvoTokens t) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
              horizontal: CoSpacing.xxl, vertical: CoSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 44, color: Color(t.ink3.argb32)),
              const SizedBox(height: CoSpacing.lg),
              Text(
                '还没有书',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(t.ink.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.sm),
              Text(
                '导入你自己的 EPUB 或 TXT，\n在这里读、划词、记生词。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 13,
                  height: 1.6,
                  color: Color(t.ink3.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.xl),
              ClayButton(label: '导入文件', onTap: widget.onImport),
              const SizedBox(height: CoSpacing.lg),
              _groupGuideCard(t),
            ],
          ),
        ),
      );

  /// 空态里的**进群引导卡**（设计稿 §A′ 形态③ · 淡色底）。
  ///
  /// # 为什么是这个形态（而不是按钮）
  ///
  /// 空态要**轻** —— 主动作是「导入文件」，进群是**次要出口**。
  /// 做成并列按钮会让用户停下来选（且读起来像「书库 = 导入 / 或去群里拿书」），
  /// 与群的定位（**不是资源群**）也不符。
  /// ⇒ 淡色卡：比裸文字醒目、能承载一行说明，又不像粘土按钮那样争主动作。
  ///
  /// # 🔴 文案不能把它写成「资源群」
  ///
  /// 群规**明令禁传电子书文件**（那是责任边界，不是形式）⇒
  /// 只能说「**一起找 / 教你怎么找**」，**不能说**「进群领书 / 免费下载 / 拿资源」。
  ///
  /// ⚠️ 图标用 Material 的 `groups_outlined` 而非设计稿里的 emoji：
  ///    空态上方那个大图标就是 Material 图标，同屏混两种语汇会更乱。
  Widget _groupGuideCard(CoEvoTokens t) {
    final accent = Color(t.accent.argb32);
    return InkWell(
      onTap: () => GroupQrcodeDialog.show(context),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(15, 14, 10, 14),
        decoration: BoxDecoration(
          // 淡色底：强调色的极低不透明度 —— 三档主题自动适配（不写裸色值）
          color: accent.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.groups_outlined, size: 18, color: accent),
            const SizedBox(width: CoSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '找不到电子书？',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  const SizedBox(height: CoSpacing.xs),
                  Text(
                    '加入英文原著共读群，一起找 Project Gutenberg 的公版原著。',
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      height: 1.6,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CoSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Icon(Icons.chevron_right, size: 18, color: accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorState(CoEvoTokens t, Object e) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CoSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '书库打不开',
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(t.ink.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.sm),
              Text(
                '请重试。若一直如此，重新打开 App 再看看。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: CoFonts.uiSans,
                  fontSize: 13,
                  height: 1.6,
                  color: Color(t.ink3.argb32),
                ),
              ),
              const SizedBox(height: CoSpacing.xl),
              ClayButton(
                label: '重试',
                onTap: () => ref.invalidate(bookListProvider),
              ),
            ],
          ),
        ),
      );

  Widget _list(CoEvoTokens t, List<BookSummary> books) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            CoSpacing.xxl, 0, CoSpacing.xxl, CoSpacing.tabBarClearance),
        itemCount: books.length,
        separatorBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(vertical: CoSpacing.sm),
          child: Divider(height: 1, color: Color(t.line.argb32)),
        ),
        itemBuilder: (_, i) => _bookRow(t, books[i]),
      );

  Widget _bookRow(CoEvoTokens t, BookSummary b) {
    return Dismissible(
      key: ValueKey(b.id),
      direction: DismissDirection.endToStart,
      // 🔴 删书**不可逆**（正文是我们解析出来的副本，用户的原文件要重新导入）
      //    ⇒ 二次确认。滑动删除太容易误触。
      confirmDismiss: (_) => _confirmDelete(t, b),
      onDismissed: (_) => _deleteBook(b),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: CoSpacing.lg),
        child:
            Icon(Icons.delete_outline, size: 20, color: Color(t.accent.argb32)),
      ),
      child: InkWell(
        onTap: () => context.push('/books/${b.id}'),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: CoSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _coverPlaceholder(t, b),
              const SizedBox(width: CoSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        color: Color(t.ink.argb32),
                      ),
                    ),
                    if ((b.author ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        b.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: CoFonts.uiSans,
                          fontSize: 12,
                          color: Color(t.ink3.argb32),
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      _progressLabel(b),
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 11.5,
                        color: Color(t.ink3.argb32),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: CoSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Icon(Icons.chevron_right,
                    size: 20, color: Color(t.accent.argb32)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面占位 —— 标题首字（设计文档 §4.2：一期不解析封面图）。
  ///
  /// 🔑 用**首字**而不是一个通用书本图标：列表里每本书长得一样时，
  ///    用户只能靠读标题区分 ⇒ 首字给了他一个**扫视时的锚点**。
  Widget _coverPlaceholder(CoEvoTokens t, BookSummary b) {
    final initial = b.title.trim().isEmpty
        ? '?'
        : String.fromCharCode(b.title.trim().runes.first);
    return Container(
      width: 40,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(t.accent.argb32).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: CoFonts.latinSerif,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: Color(t.accent.argb32),
        ),
      ),
    );
  }

  /// 进度文案。
  ///
  /// ⚠️ 三种态**必须可区分**（「未开始」与「0%」在观感上是一回事，
  ///    但前者能诱导用户去点，后者像「读了个寂寞」）：
  ///   · 没打开过 → 「未开始」
  ///   · 读到一半 → 「已读 37%」
  ///   · 读到底   → 「已读完」
  String _progressLabel(BookSummary b) {
    if (b.chapterCount <= 0) return '未开始';
    if (b.chapterIdx == 0 && b.scrollRatio == 0) return '未开始';
    final pct = (b.progress * 100).round();
    if (pct >= 100) return '已读完';
    // 🔑 至少显示 1%：刚翻开第一页时 `pct` 会四舍五入成 0，
    //    而「已读 0%」会让用户以为进度没记上。
    return '已读 ${pct < 1 ? 1 : pct}%';
  }

  Future<bool> _confirmDelete(CoEvoTokens t, BookSummary b) async {
    final ok = await CoDialog.show<bool>(
      context,
      builder: (ctx) => CoDialog(
        title: '删除这本书？',
        actions: [
          ClayButton(
            label: '取消',
            variant: ClayButtonVariant.secondary,
            onTap: () => Navigator.of(ctx).pop(false),
          ),
          ClayButton(
            label: '删除',
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
        child: Text(
          '《${b.title}》会从书库移除。\n'
          '你设备上的原文件不受影响，需要时可以重新导入。',
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.6,
            color: Color(t.ink2.argb32),
          ),
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> _deleteBook(BookSummary b) async {
    try {
      final db = await ref.read(bookDbProvider.future);
      await deleteBook(db, b.id);
      // 🔑 写库成功**之后**才 bump（顺序反了会让读端在写入完成前重查）
      ref.read(bookDbRevisionProvider.notifier).bump();
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败，请重试');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}
