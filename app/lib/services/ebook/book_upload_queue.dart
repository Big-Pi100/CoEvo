// CoEvo · 书籍**上传队列** —— 把本地书推到云端（书架上云的写入侧）
//
// 🔴 零 Flutter 依赖（HTTP 由**注入的 [BlobUploader]** 提供）⇒ 本机可验：
//    串行/退避/配额预检/跳过条件这些**逻辑**能被一行 mock 测到，
//    不需要真网络、也不需要真机。
//
// # 四条设计约束（每条都有理由）
//
// | # | 约束 | 不这么做会怎样 |
// |---|---|---|
// | ① | **串行**（一次一本）| 并行上传会同时通过配额检查 ⇒ 轻微超额；且移动网络下多路并发互相拖慢 |
// | ② | **不持字节**（每本现读磁盘）| 队列里存 `Uint8List` 时，排 5 本书就是 250 MB 常驻内存 |
// | ③ | **失败退避 + 上限** | 无限重试在网络差时变成「一直烧流量」；到上限要**停**并留痕 |
// | ④ | **退出登录时清空** | 队列里是「上一个账号的书」——跨账号继续传会传到**别人的云端** |
//
// # 🔴 与 `pendingUploadHashes` 的关系（为什么不用持久队列表）
//
// 「该传哪些」是**派生值**（本地有、云端没有）⇒ 由 `CloudBookRepository` 现算。
// 好处：App 被杀后不会留下「卡在队列里的脏状态」；重启后重算，条件仍成立的再传一次
// （幂等：服务端按 `content_hash` 覆盖同一份文件）。
// ⚠️ 但「**失败次数**」是运行时记忆 —— 重启就归零。这是**有意**的：
//    用户重启 App 的意图通常就是「再试一次」。
//
// 📄 设计依据：`docs/design/visual-cloud-bookshelf-2026-10-07.html`

import 'dart:typed_data';

import 'book_blob_parse.dart';
import 'book_raw_store.dart';

/// 注入的上传动作（真实实现 = `BookBlobClient.upload`）。
typedef BlobUploader = Future<BlobResult> Function({
  required String contentHash,
  required String ext,
  required Uint8List bytes,
  required String fileName,
});

/// 单本的失败上限（超过就**停**，等用户手动重试 / 下次启动）。
const int kMaxUploadAttempts = 3;

/// 上传过程中的**可观察状态**（供 UI 显示「正在传」）。
///
/// ⚠️ 用回调而不是 `ValueNotifier`：后者属于 `flutter/foundation`，
///    会把本文件拖进 Flutter 依赖（而它的价值恰恰是「能被 dart run 验」）。
class UploadQueueState {
  const UploadQueueState({
    this.uploadingHash,
    this.doneThisRun = 0,
    this.failedThisRun = 0,
    this.skippedNoRaw = 0,
  });

  /// 正在上传的书的 `content_hash`；`null` = 空闲。
  final String? uploadingHash;
  final int doneThisRun;
  final int failedThisRun;

  /// 跳过（没有原始文件）—— **不是失败**，但要让用户知道「这本传不了」。
  final int skippedNoRaw;

  bool get isBusy => uploadingHash != null;
}

/// 一条待上传记录（由调用方从 `book` 表 + `cloud_book` 算出）。
class UploadCandidate {
  const UploadCandidate({
    required this.contentHash,
    required this.ext,
    required this.fileName,
  });

  final String contentHash;

  /// `epub` / `txt`（与 `book.source_format`、后端白名单一致）。
  final String ext;

  /// 传给 multipart 的文件名（服务端只用于日志）。
  final String fileName;
}

/// 上传队列。
class BookUploadQueue {
  BookUploadQueue({
    required this.rawDir,
    required this.upload,
    this.onStateChanged,
  });

  /// 原始文件目录（`book_raw_dir_provider.dart` 是唯一权威来源）。
  final String rawDir;

  /// 注入的上传动作。
  final BlobUploader upload;

  /// 状态变化回调（UI 用它显示「正在传」）。
  final void Function(UploadQueueState)? onStateChanged;

  UploadQueueState _state = const UploadQueueState();
  final Map<String, int> _attempts = {};

  /// 取消标志（退出登录 / 用户手动取消）。
  ///
  /// ⚠️ 只置位不打断**正在飞的那一次请求** —— 上传是幂等的（覆盖同一份文件），
  ///    强行中断反而可能留下半个文件（后端 `put` 用临时文件 + rename，其实也安全）。
  bool _cancelled = false;

  UploadQueueState get state => _state;

  void _emit(UploadQueueState s) {
    _state = s;
    onStateChanged?.call(s);
  }

  /// 清空（**退出登录时必须调** —— 理由见文件头 ④）。
  void cancelAndReset() {
    _cancelled = true;
    _attempts.clear();
    _emit(const UploadQueueState());
  }

  /// 跑一轮上传。
  ///
  /// 🔑 **幂等**：已经在跑时直接返回（不排队、不叠加）——
  ///    否则「导入后触发一次 + 用户下拉刷新再触发一次」会让同一本书被传两遍。
  ///
  /// [candidates] 由调用方从 `pendingUploadHashes` + `book` 表组装
  /// （本层不认识 SQL，保持可测）。
  Future<void> run(List<UploadCandidate> candidates) async {
    if (_state.isBusy) return;
    _cancelled = false;

    var done = 0, failed = 0, noRaw = 0;

    for (final c in candidates) {
      if (_cancelled) break;

      // ① 退避上限：这一本已经失败够多次 ⇒ 跳过（保留在 pending 里，下次启动再算）
      if ((_attempts[c.contentHash] ?? 0) >= kMaxUploadAttempts) {
        failed++;
        continue;
      }

      _emit(UploadQueueState(
        uploadingHash: c.contentHash,
        doneThisRun: done,
        failedThisRun: failed,
        skippedNoRaw: noRaw,
      ));

      // ② 现读磁盘（不持字节 —— 见约束 ②）
      final bytes = await readRawBook(
        rawDir: rawDir,
        contentHash: c.contentHash,
        ext: c.ext,
      );
      if (bytes == null) {
        // 🔴 **不是失败**：老书（导入管线保存原始文件之前导入的）就是这种情况。
        //    要**跳过并计数**，让 UI 能说「有 N 本因缺少原始文件无法上传」
        //    —— 不给出口的静默跳过会让用户以为「同步坏了」。
        noRaw++;
        continue;
      }

      final r = await upload(
        contentHash: c.contentHash,
        ext: c.ext,
        bytes: bytes,
        fileName: c.fileName,
      );

      switch (r) {
        case BlobUploaded():
          done++;
          _attempts.remove(c.contentHash);
        case BlobNeedLogin():
          // 未登录 ⇒ **整体停下**（后面的书同样传不了，继续只会刷一串 401）
          _cancelled = true;
        case BlobQuotaExceeded():
          // 配额满 ⇒ **整体停下**（再传也会被拒）—— 由 UI 提示「删书 / 订阅」
          failed++;
          _cancelled = true;
        case BlobFailed():
          failed++;
          _attempts[c.contentHash] = (_attempts[c.contentHash] ?? 0) + 1;
        case BlobDeleted():
        case BlobNotFound():
        case BlobDownloaded():
          // 不会出现在上传路径上；归到失败（避免静默吞掉意外结果）
          failed++;
      }
    }

    _emit(UploadQueueState(
      doneThisRun: done,
      failedThisRun: failed,
      skippedNoRaw: noRaw,
    ));
  }
}

/// 组装待上传列表：**须由调用方喂数据**（本层不认 SQL）。
///
/// [pendingHashes] = `CloudBookRepository.pendingUploadHashes(db)`
/// [formatOf] = 给定 hash 返回 `(ext, fileName)`；返回 `null` ⇒ 跳过
///   （书已被删 / 指纹为空 —— 不该上传一本已经不在书架上的书）。
List<UploadCandidate> buildCandidates({
  required List<String> pendingHashes,
  required ({String ext, String fileName})? Function(String hash) formatOf,
}) {
  final out = <UploadCandidate>[];
  for (final h in pendingHashes) {
    final f = formatOf(h);
    if (f == null) continue; // 见上：不猜、不传
    out.add(UploadCandidate(
      contentHash: h,
      ext: f.ext,
      fileName: f.fileName,
    ));
  }
  return out;
}
