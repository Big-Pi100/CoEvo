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
import 'package:uuid/uuid.dart';

import '../providers/book_provider.dart';
import '../providers/book_cloud_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/book_raw_dir_provider.dart';
import '../services/ebook/book_blob_parse.dart' show kCloudQuotaBytes;
import '../services/ebook/book_upload_queue.dart' show UploadOneResult;
import '../theme/clay.dart';
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
  /// 🔑 **空态里那个「导入文件」按钮与标题栏右上角的「导入」药丸是同一个动作** ——
  ///    两处都调这一个回调，不各写一遍（判据：一处权威）。
  ///
  /// ⚠️ **本视图不再有 `importing` 参数**（2026-10-05 白哥定「不要忙碌态」）——
  ///    防重入改由 `runBookImportFlow` 内部负责（它才是「是否正在导入」的所有者）。
  ///    ⇒ 两个入口都不需要知道「是否在导入」，各自只是**触发器**。
  final VoidCallback onImport;

  @override
  ConsumerState<BookLibraryScreen> createState() => _BookLibraryScreenState();
}

class _BookLibraryScreenState extends ConsumerState<BookLibraryScreen> {
  /// 正在**手动上传**的那一本（`null` = 空闲）。
  ///
  /// 🔑 只用于「这一本」的图标转圈 —— 不复用队列的 `state.uploadingHash`：
  ///    那是**全局**状态，用它会让所有未同步的书一起转（误导）。
  String? _uploadingHash;

  @override
  Widget build(BuildContext context) {
    final t = CoEvoTokensExt.of(context);

    // 🔴 全部在**顶层** watch（不写在 `.when` 的回调里）——
    //    条件式 watch 会让依赖随分支变化，容易出「有时更新有时不更新」的诡异行为。
    // ⚠️ 「只有云端」的书**不在** `book` 表里（它没有正文），所以列表要合并两个来源。
    final cloudOnly =
        ref.watch(cloudOnlyBooksProvider).valueOrNull ?? const <CloudBook>[];
    // 用量拿不到（未登录 / 书单从未同步）⇒ `null` ⇒ **不显示配额条**
    //   （显示「已用 0 MB」是**假信息**，同翻译浮层额度的判据）
    final usage = ref.watch(cloudUsageProvider).valueOrNull;

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
          data: (books) => (books.isEmpty && cloudOnly.isEmpty)
              ? _emptyState(t)
              : _list(t, books, cloudOnly, usage),
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
              // 🔑 无忙碌态（2026-10-05）—— 防重入在 `runBookImportFlow` 内部，
              //    所以这里不需要禁用；重复点击会被流程自己忽略。
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
                '书架打不开',
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

  /// 书库列表 —— 🔴 **2026-10-05：由「平坦行 + Divider」改为「每本书一张粘土卡」**
  ///
  /// 白哥真机反馈：「书库的目录清单应该也要统一设计语言」。
  ///
  /// # 改前的形态属于**哪一套都不是**
  ///
  /// 项目里已有两种「列表」语言：
  /// | 语言 | 形态 | 用在 |
  /// |---|---|---|
  /// | **卡片** | 一条内容 = 一张粘土卡（凸起、可点）| 信息流（`feed_card.dart` → `Clay`）|
  /// | **分组容器** | 一组 = 一个 `Clay` + 内部 `Divider` + 平坦行 | 「我的」页（`profile_screen` 的 `_navTile(bare:)`）|
  ///
  /// 而书库改前是**平坦行 + `Divider`、直接铺在 `page` 底色上、外面没有容器** ——
  /// 既不像卡片、也不像分组。表现是：从「今日精选」切到「书库」，
  /// **整页质感突然变平**（同屏切换、两种质感 ⇒ 像两个 App）。
  ///
  /// # 为什么选「卡片」而不是「分组容器」
  ///
  /// 🔑 判据：**列表里的每一项是什么** ——
  ///   · 是**内容**（可以打开来读）→ 卡片
  ///   · 是**同质设置项**（开关 / 跳转）→ 分组容器
  /// 书显然是前者（点进去是**读**），且本 tab 的两段**共处同一屏**、
  /// 切换时应当用**同一套卡片语言** ⇒ 卡片。
  ///
  /// 🔑 spec §〇 规则 1 也成立：每本书**可点** ⇒ 可以有体积。
  ///
  /// ⚠️ **间距必须一起改**：信息流是 `.fcards{gap:13px}`，
  ///    所以这里也用 **13**（+ 左右 16，同 `.feed{padding:0 16px}`）。
  ///    📌 判据：**「同一套卡片语言」不只是卡片长得一样，间距也是它的一部分** ——
  ///       只改卡片不改间距，切换时仍会有「疏密突变」。
  Widget _list(
    CoEvoTokens t,
    List<BookSummary> books,
    List<CloudBook> cloudOnly,
    int? usage,
  ) =>
      Column(
        children: [
          // 配额条**不常驻** —— 只有用量 > 80% 才出现（低频信息不占常驻位置）
          if (usage != null) _quotaBar(t, usage),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  16, 0, 16, CoSpacing.tabBarClearance),
              // 🔑 本地书在前、「只有云端」的在后 —— 一个列表两种来源，
              //    所以 index 要分段映射（不是两个 ListView 叠着）。
              itemCount: books.length + cloudOnly.length,
              separatorBuilder: (_, __) => const SizedBox(height: 13),
              itemBuilder: (_, i) => i < books.length
                  ? _bookCard(t, books[i])
                  : _cloudBookCard(t, cloudOnly[i - books.length]),
            ),
          ),
        ],
      );

  /// 云端配额条（**只在 > 80% 时出现**）。
  ///
  /// 🔑 措辞只说「**云端存储**」，绝不说「云端书库 / 这里可以找到书」——
  ///    私人云存储 ≠ 在线书库，那条分界最终就落在这些 UI 文案上。
  Widget _quotaBar(CoEvoTokens t, int used) {
    final ratio = used / kCloudQuotaBytes;
    if (ratio <= 0.8) return const SizedBox.shrink();
    final over = ratio >= 1.0;
    final pct = (ratio * 100).clamp(0, 999).toStringAsFixed(0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '云端存储已用 $pct%'
            '${over ? '（已满，新的上传会被拒绝）' : ''}',
            style: TextStyle(
              fontFamily: CoFonts.uiSans,
              fontSize: 11.5,
              color: Color(over ? t.accent.argb32 : t.ink3.argb32),
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Color(t.line.argb32),
              valueColor:
                  AlwaysStoppedAnimation<Color>(Color(t.accent.argb32)),
            ),
          ),
        ],
      ),
    );
  }

  /// 「**只有云端**」的书 —— 本地没有正文，点它才下载。
  ///
  /// 🔑 形状区分（不是颜色）：它用**云图标**占位 + 右侧云下载箭头，
  ///    与本地书的「封面占位 + ›」在**形状**上就不同 ⇒ 三个主题档下都认得出。
  ///    📌 设计稿：默认态（本地有）**不加任何标记** —— 有标记的一定有原因。
  Widget _cloudBookCard(CoEvoTokens t, CloudBook b) => Clay(
        onTap: () => _downloadCloud(t, b),
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 62,
              decoration: BoxDecoration(
                color: Color(t.page.argb32),
                borderRadius: BorderRadius.circular(t.clay.radius * 0.5),
              ),
              child: Icon(Icons.cloud_outlined,
                  size: 22, color: Color(t.ink3.argb32)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.latinSerif,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '云端 · 点按下载'
                    '${b.author == null || b.author!.isEmpty ? '' : ' · ${b.author}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 12.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.cloud_download_outlined,
                size: 20, color: Color(t.accent.argb32)),
          ],
        ),
      );

  /// 下载一本「只有云端」的书（复用导入管线落库）。
  Future<void> _downloadCloud(CoEvoTokens t, CloudBook b) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('正在下载《${b.title}》…')));

    final db = await ref.read(bookDbProvider.future);
    final r = await downloadCloudBook(
      token: ref.read(authProvider).token ?? '',
      client: ref.read(bookBlobClientProvider),
      db: db,
      // 🔴 2026-10-10：**在使用时 `await`**，不要用 `valueOrNull` 同步取。
      //    同类 bug 已经真实发生过一次：上传那条链用构造时的 `valueOrNull ?? ''`
      //    拿到空串 ⇒ 队列判「原始文件缺失」⇒ 一次请求都没发出去。
      //    下载这里虽然只是「可能拿到 null」，但同一个判据：
      //    **必需配置要在使用时取，不在构造/渲染时猜**。
      rawDir: await ref.read(bookRawDirProvider.future),
      // 🔴 2026-10-10：**必须传「生成器」而不是「一个 id 值」** ——
      //    `importBook` 会为**每一章**都调它一次（见 `buildImportPlan`）⇒
      //    传常量会让所有章节共用一个 id ⇒ `UNIQUE constraint failed: book_chapter.id`。
      //    ⚠️ 不加括号：`const Uuid().v4` 是**函数引用**（每次调用产生新 uuid）；
      //       `const Uuid().v4()` 是**先调一次、把结果当常量传**（正是原来的 bug）。
      newId: const Uuid().v4,
      book: b,
    );

    // 🔑 成功才 bump（顺序反了会让读端在写入完成前重查）
    if (r is BookDownloadSuccess) {
      ref.read(bookDbRevisionProvider.notifier).bump();
    }
    if (!mounted) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(switch (r) {
        BookDownloadSuccess(:final title) => '已下载《$title》',
        BookDownloadNeedLogin() => '登录后才能下载云端书籍',
        BookDownloadNotFound() => '云端没有这本书的文件（可能只同步了书名）',
        BookDownloadFailed(:final message) => '下载失败：$message',
      })));
  }

  /// 一本书 = 一张粘土卡（与信息流 `FeedCard` 同源）。
  ///
  /// 版式：`[封面占位 46×62] [标题 / 作者·进度 / 进度条] [›]`
  Widget _bookCard(CoEvoTokens t, BookSummary b) {
    // 🆕 2026-10-22：**显式上传入口**（白哥要求）。
    //
    // 🔴 为什么必须有：顶部「未同步 N」是**批量**入口，点了只知道数字变没变，
    //    不知道**为什么不传**。而传不上去有 6 种成因，处置完全不同
    //    （缺原始文件 / 太大 / 配额 / 未登录 / 网络 / 已到上限）。
    // ⇒ 每本书自己带一个「上传」图标，点完**直接说原因**。
    //
    // 🔑 与「只有云端」那张卡的云下载图标**形状对称**（一个下、一个上），
    //    三个主题档下都认得出，且不靠颜色区分。
    final presence = ref.watch(cloudPresenceProvider).value?[b.contentHash];
    final needsUpload = presence == CloudPresence.localOnly;
    final uploadingThis = _uploadingHash == b.contentHash;

    return Dismissible(
      key: ValueKey(b.id),
      direction: DismissDirection.endToStart,
      // 🔴 删书**不可逆**（正文是我们解析出来的副本，用户的原文件要重新导入）
      //    ⇒ 二次确认。滑动删除太容易误触。
      confirmDismiss: (_) => _confirmDelete(t, b),
      onDismissed: (_) => _deleteBook(b),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: CoSpacing.xl),
        child:
            Icon(Icons.delete_outline, size: 20, color: Color(t.accent.argb32)),
      ),
      child: Clay(
        onTap: () => context.push('/books/${b.id}'),
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: Row(
          children: [
            _coverPlaceholder(t, b),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      // 🔑 用**衬线体**（同信息流卡片标题）——
                      //    书库标题与信息流标题是同一类东西（内容标题），
                      //    字体也应当同源。中文字名由 fallback 链兜底。
                      fontFamily: CoFonts.latinSerif,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                      color: Color(t.ink.argb32),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _metaLabel(b),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: CoFonts.uiSans,
                      fontSize: 11.5,
                      color: Color(t.ink3.argb32),
                    ),
                  ),
                  const SizedBox(height: 9),
                  _progressBar(t, b),
                ],
              ),
            ),
            const SizedBox(width: CoSpacing.sm),
            if (needsUpload)
              // 🔑 独立可点区域（不能和整卡 onTap 撞）：点它 = 只传这一本
              InkWell(
                onTap: uploadingThis ? null : () => _uploadThis(t, b),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    uploadingThis
                        ? Icons.cloud_sync_outlined
                        : Icons.cloud_upload_outlined,
                    size: 20,
                    // 传输中给「弱化」而不是换颜色（同 token 体系）
                    color: Color(
                        (uploadingThis ? t.ink3 : t.accent).argb32),
                  ),
                ),
              ),
            Icon(Icons.chevron_right, size: 20, color: Color(t.accent.argb32)),
          ],
        ),
      ),
    );
  }

  /// 上传**这一本**，并把**具体原因**直接告诉用户。
  ///
  /// 🔑 结果映射放在这里而不是服务层：它是**文案**，且服务层要能被 `dart run` 验
  ///    （不依赖 Flutter）。→ 与 `restoreOutcomeMessage` 同一个分工。
  Future<void> _uploadThis(CoEvoTokens t, BookSummary b) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _uploadingHash = b.contentHash);
    try {
      final db = await ref.read(bookDbProvider.future);
      final r = await uploadOneBook(
        db: db,
        queue: ref.read(bookUploadQueueProvider),
        contentHash: b.contentHash,
      );
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_uploadResultMessage(r, b.title))));
    } finally {
      if (mounted) setState(() => _uploadingHash = null);
    }
  }

  /// 上传结果 → **用户能照着做**的一句话。
  ///
  /// 🔴 不能说「上传失败」就完事 —— 那等于把 6 种成因压成一句废话。
  String _uploadResultMessage(UploadOneResult r, String title) => switch (r) {
        UploadOneResult.uploaded => '《$title》已同步到云端',
        UploadOneResult.noRaw =>
          '《$title》缺少原始文件，无法上传。请重新导入这本书。',
        UploadOneResult.tooLarge => '《$title》超过单本上限（50 MB），无法上传。',
        UploadOneResult.quota => '云端空间不足，请先在书架里删除一些书。',
        UploadOneResult.needLogin => '请先登录账号再同步。',
        UploadOneResult.skipped => '《$title》已连续失败多次，请稍后再试。',
        UploadOneResult.failed => '《$title》同步失败，请检查网络后重试。',
      };

  /// 进度条（设计稿 `.bbar`：4px 高、圆角 2、槽 `sunken`、填充 `accent`）。
  ///
  /// 🔑 **为什么加它**：进度原本只有一行文字（「已读 42%」）。做成卡片后，
  ///    条能把「读到哪里」变成一个**可扫视的长度** —— 列表扫一眼就知道哪本在读。
  ///    ⚠️ **文字仍保留**（在 `_metaLabel` 里）：条表达「大概多少」，
  ///       文字表达「确切多少」，两者互补；只有条会在 0% / 未开始时说不清。
  ///
  /// # ⚠️ 实现上避开了两个「看起来对、实际会塌」的写法
  ///
  /// ① **不用 `Row` + `Expanded(flex: v*1000)`** —— `flex` 必须 > 0 才有弹性语义，
  ///    而进度极小（如 0.0004）时 `round()` 得 **0** ⇒ 落进 `RenderFlex` 的**非弹性**分支，
  ///    那条路径对「无 intrinsic 尺寸的色块」会算成 0 宽（不是 assert 失败，是**静默塌掉**）。
  /// ② **不用 `FractionallySizedBox(widthFactor: v)` + `ColoredBox`** ——
  ///    `ColoredBox` 没有 child 时 `computeDryLayout` 取 `constraints.smallest`
  ///    ⇒ **高度塌成 0**（条会整个消失）。
  ///
  /// ✅ 现在的写法：`Positioned(left/top/bottom + width)` —— 四个方向都定死，
  ///    高度铺满、宽度由 `LayoutBuilder` **实测**的可用宽 × 比例算出。
  ///    📌 判据（本项目已记）：**能用「让引擎实测」解决的，不要靠估算或假设固有尺寸。**
  Widget _progressBar(CoEvoTokens t, BookSummary b) {
    final v = b.progress.clamp(0.0, 1.0);
    final track = Color(t.sunken.argb32);
    final fill = Color(t.accent.argb32);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              // 槽：整宽铺满
              Positioned.fill(child: ColoredBox(color: track)),
              // 填充：按比例（v == 0 时不画，避免一个 0 宽的 Positioned）
              if (v > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: c.maxWidth * v,
                  child: ColoredBox(color: fill),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片第二行：`作者 · 进度`（任一侧为空则只显示另一侧）。
  ///
  /// 🔑 合并成一行而不是两行：卡片高度有限，而这两条都是**次要信息** ——
  ///    分成两行会把卡片撑高，与信息流卡片的疏密不一致。
  ///    ⚠️ 作者可能为 `null`（TXT 常无作者）⇒ 不能写死 `'${b.author} · ...'`。
  String _metaLabel(BookSummary b) {
    final parts = <String>[];
    final author = (b.author ?? '').trim();
    if (author.isNotEmpty) parts.add(author);
    parts.add(_progressLabel(b));
    return parts.join(' · ');
  }

  /// 封面占位 —— 标题首字（设计文档 §4.2：一期不解析封面图）。
  ///
  /// 🔑 用**首字**而不是一个通用书本图标：列表里每本书长得一样时，
  ///    用户只能靠读标题区分 ⇒ 首字给了他一个**扫视时的锚点**。
  ///
  /// # 🔴 2026-10-05：尺寸按设计稿放大，但**底改为平面**（偏离稿子，按 spec 修正）
  ///
  /// 设计稿里这一块画的是**凹陷**（`sunken` + 两个 inset）。实现时改成**平面**：
  /// 📌 依据 spec §〇 规则 1「**有体积的只可能是可点的东西**」——
  ///    封面占位**不可点**（点的是整张卡片）⇒ 给它凹陷会**读作「可以按」**，是误导。
  ///    （凹陷在本项目只有两种语义：① 输入框 ② 按下态 —— 都指向「可交互」。）
  /// ⇒ 保留原有的「强调色 10% 淡底 + 圆角」写法（平面），只把尺寸放大到 46×62。
  Widget _coverPlaceholder(CoEvoTokens t, BookSummary b) {
    final initial = b.title.trim().isEmpty
        ? '?'
        : String.fromCharCode(b.title.trim().runes.first);
    return Container(
      width: 46,
      height: 62,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(t.accent.argb32).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontFamily: CoFonts.latinSerif,
          fontSize: 22,
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
          '《${b.title}》会从书架移除。\n'
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
