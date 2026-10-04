// CoEvo · 我的书库
//
// 🔴 **入口位置（白哥 2026-10-04 定）**：信息流页「今日精选」标题栏**下方**一行
//    「我的书库 ›」→ 进本页。**导入按钮在本页右上角。**
//    （原设计把入口放「我的」页，见 `ebook-import-implementation` §六 —— 已改，理由记录在案。）
//
// # 本页与「阅读页」的分工
//
// | 页 | 职责 |
// |---|---|
// | 本页（`/books`） | **管理**：导入、看进度、删书 |
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

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../providers/book_provider.dart';
import '../services/book_importer.dart';
import '../services/ebook/book_import_messages.dart';
import '../services/ebook/book_text.dart';
import '../theme/co_spacing.dart';
import '../theme/coevo_tokens.dart';
import '../theme/tokens_ext.dart';
import '../widgets/clay_button.dart';
import '../widgets/co_dialog.dart';

/// 接受的文件类型。
///
/// 🔑 `extensions` 是**给系统文件选择器的提示**（iOS 会据此过滤），
///    但**不能当验证用** —— 用户仍可能选到别的（或从「最近」里选）。
///    ⇒ 真正的判定在 `pickFormat`（看魔数），见 `book_import_plan.dart`。
///    判据：**UI 的过滤是便利，不是安全边界**。
const _kEbookTypeGroup = XTypeGroup(
  label: '电子书',
  extensions: <String>['epub', 'txt'],
);

class BookLibraryScreen extends ConsumerStatefulWidget {
  const BookLibraryScreen({super.key});

  @override
  ConsumerState<BookLibraryScreen> createState() => _BookLibraryScreenState();
}

class _BookLibraryScreenState extends ConsumerState<BookLibraryScreen> {
  /// 正在导入 —— 用来**禁用按钮**（防止用户连点导致同一本书被导入多次）。
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    return Scaffold(
      backgroundColor: Color(t.page.argb32),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(t),
            Expanded(
              child: ref.watch(bookListProvider).when(
                    loading: () => const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    // 🔑 错误要**能重试**（一个干巴巴的错误页 = 「静默失败 + 无出口」）
                    error: (e, _) => _errorState(t, e),
                    data: (books) => books.isEmpty
                        ? _emptyState(t)
                        : _list(t, books),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏：**左返回 · 左标题 · 右导入**。
  ///
  /// 🔴 这里**偏离**了同项目其他二级页的范式（`about_screen` / `bookmark_list_screen`
  ///    都是「标题左 + 返回**右**」，照设计稿的 `space-between`）。
  ///    偏离的理由：白哥要求「**导入按钮在右上角**」——
  ///    右侧只能留一个主动作，否则「返回」和「导入」会挤在一起、主次不分。
  ///    ⇒ 返回移到左上（这恰好也是 iOS 的通行做法）。
  ///    ⚠️ 注意：返回仍有**两条路** —— 左上按钮 + 边缘右滑（转场自带，
  ///       见 `theme_builder` 的 `pageTransitionsTheme`），所以不存在「回不去」。
  Widget _header(CoEvoTokens t) {
    final accent = Color(t.accent.argb32);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 14, 14),
      child: Row(
        children: [
          // 返回：箭头图标（比文字省横向空间，把右侧留给「导入」）
          InkWell(
            onTap: () => context.pop(),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 6, 10, 6),
              child: Icon(Icons.arrow_back_ios_new, size: 17, color: accent),
            ),
          ),
          Text(
            '我的书库',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 23,
              fontWeight: FontWeight.w600,
              letterSpacing: 23 * -0.015,
              color: Color(t.ink.argb32),
            ),
          ),
          const Spacer(),
          // ── 🔴 右上角：导入 ──
          _importing
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : InkWell(
                  onTap: _pickAndImport,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Text(
                      '导入',
                      style: TextStyle(
                        fontFamily: CoFonts.uiSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  /// 空态 —— 🔑 **必须给「下一步做什么」**，不是一个空页面。
  Widget _emptyState(CoEvoTokens t) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CoSpacing.xxl),
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
              ClayButton(label: '导入文件', onTap: _pickAndImport),
            ],
          ),
        ),
      );

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
        child: Icon(Icons.delete_outline,
            size: 20, color: Color(t.accent.argb32)),
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

  /// 选文件 → 导入。
  Future<void> _pickAndImport() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final XFile? file =
          await openFile(acceptedTypeGroups: const [_kEbookTypeGroup]);
      // 🔑 用户取消 ⇒ **静默返回**（不是错误，不该弹任何提示）
      if (file == null) return;

      final bytes = await file.readAsBytes();
      final db = await ref.read(bookDbProvider.future);

      final result = await importBook(
        db: db,
        bytes: bytes,
        fileName: file.name,
        newId: const Uuid().v4,
        addedAt: DateTime.now().toUtc().toIso8601String(),
      );

      if (!mounted) return;

      switch (result) {
        case BookImportSuccess(:final bookId, :final title):
          ref.read(bookDbRevisionProvider.notifier).bump();
          _toast('已导入《$title》', action: '打开', onAction: () {
            if (mounted) context.push('/books/$bookId');
          });
        case BookImportFailure(:final kind, :final detail):
          // 🔴 上报细节到日志，但**给用户看的是 kind 对应的文案**
          //    （`detail` 里有堆栈/字节数这类用户看不懂的东西）
          debugPrint('[book] 导入失败（$kind）：$detail');
          _showFailure(kind);
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('[book] 导入异常：$e');
      _showFailure(EbookParseErrorKind.unknown);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _showFailure(EbookParseErrorKind kind) {
    final t = CoEvoTokensExt.of(context);
    CoDialog.show<void>(
      context,
      builder: (ctx) => CoDialog(
        title: '没能导入这本书',
        actions: [
          ClayButton(
            label: '知道了',
            variant: ClayButtonVariant.secondary,
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(),
          ),
        ],
        child: Text(
          bookImportFailureMessage(kind),
          style: TextStyle(
            fontFamily: CoFonts.uiSans,
            fontSize: 13,
            height: 1.6,
            color: Color(t.ink2.argb32),
          ),
        ),
      ),
    );
  }

  void _toast(String msg, {String? action, VoidCallback? onAction}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
  }
}
