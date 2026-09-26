import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 导出 PNG 字节到系统（写临时文件 → 唤起系统分享面板）。
///
/// ## 为什么叫 export 而不是 download
///
/// 原实现（3 处）都用 **web-only** 的 `html.Blob` + `html.AnchorElement.click()`
/// 触发浏览器**下载** —— `dart:html` 在 iOS/Android 不存在，原生直接编不过
/// （见 `docs/design/ui-ux-refactor-assessment-2026-09-25.md` §1.2 映射表）。
///
/// 原生平台**没有「下载到本机」这个概念** —— 最接近的心智模型是
/// **「存到『文件』App / 分享给其他 App」**，即系统分享面板。
/// 故统一改为 `share_plus`。
///
/// ## 为什么落盘而不是直接用内存字节
///
/// `XFile.fromData(...)` 在原生平台**没有真实路径**，而 `share_plus` 的
/// iOS/Android 实现需要读文件路径 → 会失败。故必须先用 `path_provider`
/// 写临时文件，再以路径构造 `XFile`。
///
/// - Parameters:
///   - bytes: PNG 字节
///   - fileName: 落盘文件名（含扩展名），如 `coevo_qr.png`
///   - shareText: 分享时附带的文案
/// - Returns: `null` 表示成功；否则返回错误描述（可直接展示给用户）
Future<String?> exportPngBytes(
  Uint8List bytes, {
  required String fileName,
  String? shareText,
}) async {
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(file.path)], text: shareText);
    return null;
  } catch (e) {
    return '$e';
  }
}
