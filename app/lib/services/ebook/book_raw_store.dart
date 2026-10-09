// CoEvo · 电子书**原始文件**的落盘（书架上云与「换机复用解析器」的前提）
//
// 🔴 零 Flutter 依赖 —— 目录由调用方传入（Flutter 侧用 `path_provider`），
//    这样本层能被 `dart:io` 直接测（同 `book_importer` / `book_progress_sync` 的分层）。
//
// # 为什么必须存原始文件（2026-10-08 补的缺口）
//
// 导入管线原本**只落库**（`book` + `book_chapter` = 解析后的章节），**原始文件丢弃**。
// 这带来两个不可解的问题：
//   ① **无法上传** —— 云端要的是原始 epub/txt（设计稿：「存原始文件，不存解析后的章节」），
//      解析后的章节再拼不回一个合法 epub（zip 结构、manifest、spine 都丢了）。
//   ② **换机后无法「复用端侧解析器」** —— 下载回来的文件仍要重新解析，
//      而解析器要的输入正是原始字节。
//
// # 路径规则（唯一权威）
//
// ```
//   {rawDir}/{content_hash}.{ext}
// ```
//
// 🔑 用 `content_hash`（不是 `book.id`）：
//   · 它与云端的对象键**同一个键** ⇒ 下载回来的文件天然对得上，不需要再映射一次
//   · `book.id` 是端侧 uuid ⇒ 换机后不同（见 `book_progress_sync` 的同款理由）
//
// ⚠️ **不额外加数据库列**：路径是**确定性地算得出来**的 ⇒
//    加一列「raw_path」只会多一个可能与规则不一致的副本。
//    📌 判据：**能算出来的东西不要存**。

import 'dart:io';
import 'dart:typed_data';

/// 原始文件的路径（不保证存在）。
File rawBookFile(String rawDir, String contentHash, String ext) =>
    File('$rawDir${Platform.pathSeparator}$contentHash.$ext');

/// 保存原始文件（覆盖式；父目录不存在则创建）。
///
/// ⚠️ **先写临时文件再 rename** —— 与后端 `LocalDiskStore` 同一个理由：
///    直接写目标路径时，进程被杀会留下一个**半截文件**，
///    而它长得和正常文件一样（下次读它的人只会觉得「文件坏了」）。
///    rename 在同一分区是原子的 ⇒ 要么是完整的旧版，要么是完整的新版。
///
/// 返回落盘后的 [File]；失败抛异常（调用方决定是否影响主流程）。
Future<File> saveRawBook({
  required String rawDir,
  required String contentHash,
  required String ext,
  required Uint8List bytes,
}) async {
  final dir = Directory(rawDir);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final target = rawBookFile(rawDir, contentHash, ext);
  final tmp = File('${target.path}.tmp-upload');
  await tmp.writeAsBytes(bytes, flush: true);
  return tmp.rename(target.path);
}

/// 读原始文件。
///
/// 🔑 返回 `null` 表示**「没有这份原始文件」**（老书 / 导入时保存失败），
///    而不是抛异常 —— 调用方要据此**跳过上传**并给出可解释的提示
///    （本项目判据：「静默失败 + 无出口」比报错更糟）。
Future<Uint8List?> readRawBook({
  required String rawDir,
  required String contentHash,
  required String ext,
}) async {
  final f = rawBookFile(rawDir, contentHash, ext);
  if (!await f.exists()) return null;
  return f.readAsBytes();
}

/// 删除原始文件（删书时调用；不存在 ⇒ 静默）。
Future<void> deleteRawBook({
  required String rawDir,
  required String contentHash,
  required String ext,
}) async {
  final f = rawBookFile(rawDir, contentHash, ext);
  if (await f.exists()) await f.delete();
}

/// 该目录下所有原始文件的**总字节数**（诊断用；配额看的是云端不是本地）。
Future<int> rawBooksBytes(String rawDir) async {
  final dir = Directory(rawDir);
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final e in dir.list()) {
    if (e is File) {
      // ⚠️ 临时文件不计（它是传输中间态）
      if (e.path.endsWith('.tmp-upload')) continue;
      total += await e.length();
    }
  }
  return total;
}
