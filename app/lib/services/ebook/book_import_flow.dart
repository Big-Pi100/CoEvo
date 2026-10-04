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
const _kEbookTypeGroup = XTypeGroup(
  label: '电子书',
  extensions: <String>['epub', 'txt'],
);

/// 选文件 → 导入 → 反馈。**书库页内所有「导入」入口都调这一个函数。**
///
/// [onBusy] 由调用方用来驱动「按钮转圈 / 禁用」（容器自己不持有导入状态，
/// 状态归页面的所有者 —— 同「防重入放在状态的所有者那里」这条判据）。
///
/// ⚠️ **不做防重入**：调用方需在 `onBusy(true)` 期间自行禁用入口
///    （容器把「导入」按钮换成转圈、书库空态按钮交给同一状态）。
Future<void> runBookImportFlow({
  required BuildContext context,
  required WidgetRef ref,
  required ValueChanged<bool> onBusy,
}) async {
  onBusy(true);
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

    if (!context.mounted) return;

    switch (result) {
      case BookImportSuccess(:final bookId, :final title):
        // 🔑 写库成功**之后**才 bump（顺序反了会让读端在写入完成前重查）
        ref.read(bookDbRevisionProvider.notifier).bump();
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
    onBusy(false);
  }
}

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
      action: action == null
          ? null
          : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ),
  );
}
