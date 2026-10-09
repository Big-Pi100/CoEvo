// CoEvo · 电子书导入的**交互流程**（选文件 → 导入 → 反馈）
//
// # 🔴 为什么把它抽出来（而不是留在书库页里）
//
// 书库改成了「阅读」tab 内的一个**平级视图**（2026-10-04 白哥定案，见
// `screens/reading_section.dart`）⇒ 页面不再自带标题栏。而「导入」按钮
// 在**标题栏右上角**、由容器 `reading_tab_screen.dart` 绘制 ——
// 也就是说：**按钮在容器里，书库视图在下面**。
//
// 两条路可走：
//   · 把 `_pickAndImport` 留在书库视图、容器绕着拿它的回调 → 需要 GlobalKey / 回调透传，
//     且「空态里那个『导入文件』按钮」也要再传一遍 ⇒ 同一个动作会出现**两个入口、两处调用**；
//   · **抽成这个函数** ⇒ 容器与书库视图都调它，**只有一处实现**。
//
// 🔑 判据同 `HeaderChip` / `CoDialog` / `GroupQrcodeDialog`：
//    **「行为一致」最可靠的实现方式 = 只有一处定义。**
//
// # 分工
// | 层 | 文件 | 是否碰 Flutter |
// |---|---|---|
// | 解析 | `book_text.dart` / `book_import_plan.dart` | ❌ 纯 Dart（本机可断言）|
// | 落库 | `book_importer.dart` | ❌ 只碰 sqflite 接口 |
// | **交互** | **本文件** | ✅（要弹层 / 选文件 / toast）|
// | 摆放 | `reading_tab_screen.dart` / `book_library_screen.dart` | ✅ |
//
// ⚠️ **本文件本机不可验证**（import Flutter）—— 靠 CI 的 `flutter analyze` 兜。

import 'dart:async';
import '../../providers/book_cloud_provider.dart';
import '../../providers/book_raw_dir_provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/auth_provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../providers/book_provider.dart';
import '../../theme/coevo_tokens.dart';
import '../../theme/tokens_ext.dart';
import '../../widgets/clay_button.dart';
import '../../widgets/co_dialog.dart';
import '../../widgets/group_qrcode_dialog.dart';
// ⚠️ `book_importer.dart` 在 `services/`（不是 `services/ebook/`）——
//    它碰 `sqflite`，与「纯解析层」分开放（见该文件的头注释）。
import '../book_importer.dart';
import 'book_import_messages.dart';
import 'book_text.dart';

/// 接受的文件类型。
///
/// 🔑 `extensions` 是**给系统文件选择器的提示**（iOS 会据此过滤），
///    但**不能当验证用** —— 用户仍可能选到别的（或从「最近」里选）。
///    ⇒ 真正的判定在 `pickFormat`（看魔数），见 `book_import_plan.dart`。
///    判据：**UI 的过滤是便利，不是安全边界**。
/// 🔴 2026-10-07 **iOS 真机修复**：必须补 `uniformTypeIdentifiers`。
///
/// 原因：`file_selector` 的过滤参数**按平台分化**（官方支持矩阵）：
///   · `extensions`             → Android / 桌面 / Web ✅ · **iOS ❌ 不支持**
///   · `uniformTypeIdentifiers` → **仅 iOS / macOS** ✅
///
/// 而 `file_selector_ios` 源码（`_allowedUtiListFromTypeGroups`）写死了逻辑：
///   若某类型组的 `uniformTypeIdentifiers` 为空、且不是 `allowsAny`
///   ⇒ **抛 `ArgumentError`**
///
/// ⇒ 之前只写 `extensions`，在 **iOS 上必然抛错** → 被 `catch (e)` 兜住
///   → 用户看到「导入失败」。**这是确定性 bug，不是偶发。**
///   （Android 上一直正常，因为 Android 读的正是 `extensions`。）
///
/// 📌 判据：**跨平台插件要逐平台核对参数支持矩阵** ——
///    「Android 跑通」≠「参数写对了」，另一个平台可能直接抛异常。
/// 🔑 强信号：官方 pub 页有「参数支持矩阵」表格 ⇒ **先查表，再写代码**。
///
/// ⚠️ 这里的过滤只是**便利**（不是安全边界）——真正的格式判定看魔数，
///    见 `book_import_plan.dart`。判据：**UI 的过滤是便利，不是安全边界**。
const _kEbookTypeGroup = XTypeGroup(
  label: '电子书',
  extensions: <String>['epub', 'txt'],
  // UTI 与 `ios/Runner/Info.plist` 的 `CFBundleDocumentTypes` **保持一致** ——
  // 两处若不同，会出现「能选到文件但系统不从别的 App 把文件交给我们」这类不一致。
  uniformTypeIdentifiers: <String>[
    'org.idpf.epub-container', // EPUB
    'public.plain-text', // TXT
  ],
);

/// 选文件 → 导入 → 反馈。**书库页内所有「导入」入口都调这一个函数。**
///
/// # 🔴 防重入由**本函数**负责（2026-10-05 改）
///
/// 原设计是「调用方用 `onBusy` 驱动按钮禁用」——但那带来两个问题（白哥真机反馈）：
/// ① 标题栏药丸为了容纳「导入中…」要传 `labelReserve`，而那个参数**本是为「文字居中」
///    设计的**（复习页筛选药丸）⇒ 副作用是**左右内边距不对称**，与「收藏」并排很难看；
/// ② 空态按钮也要跟着禁用 ⇒ 同一个「忙碌」状态被两处 UI 读取，改一处忘一处。
///
/// 现在改为：**流程自己防重入**（模块级 `_busy`）。
/// 📌 判据：**「防重入」应放在「状态的唯一所有者」上** ——
///    而本流程就是「是否正在导入」这件事的唯一所有者（调用方只是触发者）。
///    ⇒ 调用方不再需要持有任何导入状态，UI 也不需要忙碌态。
///
/// ⚠️ `_busy` 是**模块级**（全 App 一份）—— 符合事实：同一时刻只可能有一个系统文件选择器。
Future<void> runBookImportFlow({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  if (_busy) {
    debugPrint('[book] 导入已在进行中，忽略重复触发');
    return;
  }
  _busy = true;
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
      // 🆕 同时保存**原始文件** —— 上传云端与「换机复用解析器」都要它。
      //    ⚠️ 目录口径唯一来源：`book_raw_dir_provider.dart`。
      //    拿不到目录也不影响导入（书已能读）⇒ 传 null。
      rawDir: await _safeRawDir(),
    );

    if (!context.mounted) return;

    switch (result) {
      case BookImportSuccess(:final bookId, :final title):
        // 🔑 写库成功**之后**才 bump（顺序反了会让读端在写入完成前重查）
        ref.read(bookDbRevisionProvider.notifier).bump();

        // 🆕 书架上云：导入完成后**后台**触发上传。
        //    🔴 三条都重要：
        //      ① **不 await** —— 上传 50 MB 要几十秒，阻塞导入会让 toast 迟迟不出现
        //      ② **失败不影响导入** —— 书已经能读了（见 `_kickBookUpload` 的兜底）
        //      ③ 必须**先推书单** —— 服务端上传时会校验书单行存在，
        //         而 push 由同步流程负责 ⇒ 这里先 `pushOnce()`（幂等）
        unawaited(_kickBookUpload(ref));
        _toast(context, '已导入《$title》', action: '打开', onAction: () {
          if (context.mounted) context.push('/books/$bookId');
        });
      case BookImportFailure(:final kind, :final detail):
        // 🔴 上报细节到日志，但**给用户看的是 kind 对应的文案**
        //    （`detail` 里有堆栈/字节数这类用户看不懂的东西）
        debugPrint('[book] 导入失败（$kind）：$detail');
        await _showImportFailure(context, kind);
    }
  } catch (e) {
    if (!context.mounted) return;
    debugPrint('[book] 导入异常：$e');
    await _showImportFailure(context, EbookParseErrorKind.unknown);
  } finally {
    _busy = false;
  }
}

/// 「是否正在导入」—— 由 [runBookImportFlow] 独占读写（见其文档）。
bool _busy = false;

/// 导入失败弹层。
///
/// # 🔴 DRM 那一类**必须多给一个出口**（2026-10-04 补）
///
/// `bookImportFailureMessage` 对 DRM 写的是：
/// > 「这本书受 DRM 保护，技术无法解析。请改用无 DRM 的 EPUB 文件
/// >  （例如 **Project Gutenberg** 的公版书）。」
///
/// 文案已经**指出**了替代来源 —— 但在此之前**没有任何地方能去**
/// （用户得自己记住这个名字、退出去、开浏览器、搜站点）。
/// 📌 判据：**「有提示、无出口」与「静默失败」是同一族的毛病** ——
///    前者甚至更隐蔽，因为它看起来已经说清楚了。
///
/// ⇒ DRM 时弹层给两个动作：「知道了」+「**加入共读群**」——
///    而群正好是「教怎么找公版书」的地方（`wechat-study-group-plan` §3.1）。
Future<void> _showImportFailure(
  BuildContext context,
  EbookParseErrorKind kind,
) async {
  final t = CoEvoTokensExt.of(context);
  final canJoinGroup = kind == EbookParseErrorKind.drmProtected;

  // 🔴 用**返回值**而不是「在弹层里再弹一个」——
  //    `showDialog` 的 builder 是懒执行的：「弹层里再弹」要等前一个关掉，
  //    直接嵌套调用会在前一个还在树上时就压栈，时序不确定
  //    （本项目已有「等条件成立 ＞ 等猜的时长」的教训）。
  final wantsGroup = await CoDialog.show<bool>(
    context,
    builder: (ctx) => CoDialog(
      title: '没能导入这本书',
      actions: [
        ClayButton(
          label: '知道了',
          variant: ClayButtonVariant.secondary,
          expanded: true,
          onTap: () => Navigator.of(ctx).pop(false),
        ),
        if (canJoinGroup)
          ClayButton(
            label: '加入共读群',
            expanded: true,
            onTap: () => Navigator.of(ctx).pop(true),
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

  if (wantsGroup == true) {
    // ⚠️ `await` 之后 context 可能已失效（页面被 pop）—— 必须查 `mounted`
    if (!context.mounted) return;
    await GroupQrcodeDialog.show(context);
  }
}

void _toast(
  BuildContext context,
  String msg, {
  String? action,
  VoidCallback? onAction,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      // 🔴 2026-10-07 真机修复（白哥反馈 #9）：**显式**给时长 + 关闭按钮。
      //
      // 现象：「已导入」提示一直在，不会自己消失。
      // ⚠️ 根因**未 100% 确定** —— 主题里没改 `duration`
      //    （`theme_builder.dart` 的 `SnackBarThemeData` 只有配色/形状/behavior），
      //    理论上默认 4s 应当自动消失。
      // ⇒ 因此**两头都补**：显式时长（自动）+ 关闭按钮（手动），
      //    无论默认值因何失效，用户都有确定的出口。
      // 📌 判据：**「能自动消失」不该依赖默认值** —— 默认会随框架/主题变化，
      //    关键行为必须显式声明。
      duration: const Duration(seconds: 4),
      showCloseIcon: true,
      action: action == null
          ? null
          : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ),
  );
}

/// 取原始文件目录；**失败返回 null**（导入不因它失败）。
///
/// 🔑 为什么不让异常冒出去：这个目录只影响「能不能上传 / 换机复用」，
///    而导入的**主要职责**是「让用户能读这本书」。
///    📌 判据：**次要依赖失败不该阻断主流程** —— 但要留痕（`debugPrint`），
///       否则将来「上传总是提示没有原始文件」会查不到源头。
Future<String?> _safeRawDir() async {
  try {
    return await rawBooksDir();
  } catch (e) {
    debugPrint('[book] 取原始文件目录失败（不影响导入，但该书无法上传）：$e');
    return null;
  }
}

/// 导入后**后台**上传这本书（书架上云）。
///
/// 🔴 顺序：**先推书单**再传文件 —— 服务端的 `book_upload_handler` 会校验
///    「这本书的 `sync_book` 行存在」，否则直接 400。
///    ⇒ 所以这里先 `pushOnce()`（幂等：失败会在下次同步重试）。
///
/// ⚠️ **整段失败都静默**（只留日志）：导入已经成功、书能读，
///    上传失败不该给用户报警 —— 真正的出口在书架页（那本书会显示为「未上云」，
///    用户可以下拉重试）。
Future<void> _kickBookUpload(WidgetRef ref) async {
  try {
    final db = await ref.read(bookDbProvider.future);
    // ① 先把书单推上去（含刚导入的这本）
    //    ⚠️ `buildSyncService` 返回 `null` = 不满足同步前提（未登录 / 库打不开）
    //    ⇒ 静默跳过（同步是**可选能力**，不能阻塞导入）
    final auth = ref.read(authProvider);
    final svc = await buildSyncService(
      ref,
      token: auth.token ?? '',
      userId: auth.userId ?? '',
    );
    await svc?.pushOnce();
    // ② 再把待上传的文件传上去
    await kickBookUpload(
      db: db,
      queue: ref.read(bookUploadQueueProvider),
    );
  } catch (e) {
    debugPrint('[book] 后台上传失败（不影响导入）：$e');
  }
}
