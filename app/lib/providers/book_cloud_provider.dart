// CoEvo · **书架上云**的编排层（Flutter 侧）
//
// 这一层只做「组装 + 触发」：
//   · `BookBlobClient`（HTTP）
//   · `BookUploadQueue`（串行上传 · 状态回调）
//   · 下载「只有云端」的书 → **复用导入管线**落库
//   · 状态（三态映射 / 配额用量）供 UI 读
// 真正的规则都在零依赖层（`book_blob_parse` / `cloud_book_repository` /
// `book_upload_queue` / `book_raw_store`），那些能用 `dart run` 直接验。
//
// # 🔴 配额用量的口径（端侧算，不改后端）
//
// 后端**没有**「查配额」的端点（上传响应里只回 `usage` 那一次）。
// 但端侧的 `cloud_book` 是服务端书单的**整体替换副本** ⇒
// 对 `blob_size` 求和**就是**服务端的 `used`（同一口径）。
// ⚠️ 前提是「书单已同步过」；从未同步的账号算出来是 0 ⇒ 配额条**不显示**
//    （而不是显示「已用 0」—— 那是**假信息**，同翻译浮层额度的判据）。

import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/book_blob_client.dart';
import '../services/book_importer.dart';
import '../services/ebook/book_upload_queue.dart';
import '../services/ebook/cloud_book_repository.dart';

// 让 UI 层能直接用这些类型（它们定义在零依赖层）
export '../services/ebook/cloud_book_repository.dart' show CloudBook, CloudPresence;
import 'auth_provider.dart';
import 'book_provider.dart' show bookDbProvider, bookDbRevisionProvider;
import 'book_raw_dir_provider.dart';

/// HTTP 客户端（单例；`onDispose` 关连接池）。
final bookBlobClientProvider = Provider<BookBlobClient>((ref) {
  final c = BookBlobClient();
  ref.onDispose(c.dispose);
  return c;
});

/// 上传队列（单例）。
///
/// 🔑 装到一个 provider 里而不是每次 new：队列持有**失败次数**与**正在传的是哪本**
///    —— 每次 new 会让退避计数与「正在传」标记全部丢失（UI 会闪）。
final bookUploadQueueProvider = Provider<BookUploadQueue>((ref) {
  // ⚠️ 目录是异步拿的；这里同步取一次缓存值（导入流程启动时已 await 过一次）。
  //    拿不到就用空串 —— 队列会因「读不到原始文件」而跳过并计数，
  //    比抛异常好（本书仍可读）。
  final rawDir = ref.watch(bookRawDirProvider).valueOrNull ?? '';
  final client = ref.read(bookBlobClientProvider);

  return BookUploadQueue(
    rawDir: rawDir,
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async {
      final token = ref.read(authProvider).token ?? '';
      if (token.isEmpty) return const BlobNeedLogin();
      return client.upload(
        token: token,
        contentHash: contentHash,
        ext: ext,
        bytes: bytes,
        fileName: fileName,
      );
    },
  );
});

/// 书架页用的**三态映射**（`content_hash` → 本地/云端状态）。
///
/// `bookDbRevisionProvider` 一变就重算 —— 导入、同步、删书都会 bump 它。
final cloudPresenceProvider =
    FutureProvider<Map<String, CloudPresence>>((ref) async {
  ref.watch(bookDbRevisionProvider);
  final db = await ref.read(bookDbProvider.future);
  return CloudBookRepository.presenceByHash(db);
});

/// 云端用量（字节）。
///
/// ⚠️ 返回 `null` **不是错误**，而是「**不知道**」：
///    · 书单从未同步过 ⇒ `cloud_book` 是空的 ⇒ 算出来 0，但那**不代表用量是 0**
///    · 未登录 ⇒ 同样无从得知
///    ⇒ 调用方据此**不显示配额条**（而不是显示「已用 0 MB」）。
final cloudUsageProvider = FutureProvider<int?>((ref) async {
  ref.watch(bookDbRevisionProvider);
  final auth = ref.watch(authProvider);
  if ((auth.token ?? '').isEmpty) return null;
  final db = await ref.read(bookDbProvider.future);
  final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(blob_size), 0) AS n FROM cloud_book');
  final n = rows.first['n'];
  return n is int ? n : 0;
});

/// 云端书单（**整体替换副本**），按最近上云倒序。
///
/// ⚠️ 它包含**所有**云端书（含本地也有的）—— 书架要「只有云端」的那些时
///    需要与 `cloudPresenceProvider` 求差，见 `cloudOnlyBooksProvider`。
final cloudBookListProvider = FutureProvider<List<CloudBook>>((ref) async {
  ref.watch(bookDbRevisionProvider);
  final db = await ref.read(bookDbProvider.future);
  return CloudBookRepository.listCloudBooks(db);
});

/// **只有云端**的书（本地没有）—— 书架要给它们单独渲染（点开才下载）。
///
/// 🔑 从 [cloudBookListProvider] 与 [cloudPresenceProvider] 求差得到：
///    状态映射里是 `cloudOnly` 的就是「云端有、本地没有」。
///    📌 不重新查一次库（两个 provider 已经有结果了）。
final cloudOnlyBooksProvider = FutureProvider<List<CloudBook>>((ref) async {
  final all = await ref.watch(cloudBookListProvider.future);
  final presence = await ref.watch(cloudPresenceProvider.future);
  return [
    for (final b in all)
      if (presence[b.contentHash] == CloudPresence.cloudOnly) b,
  ];
});

/// 触发一轮上传（**幂等**：队列已在跑就直接返回）。
///
/// 调用时机：① 导入成功后 ② 书单同步后 ③ 用户手动重试。
Future<void> kickBookUpload({
  required Database db,
  required BookUploadQueue queue,
}) async {
  final pending = await CloudBookRepository.pendingUploadHashes(db);

  // 组装候选：需要每本的 `ext` 与文件名 —— 都从**本地** `book` 表拿
  // （要上传的书必然本地有，所以 `source_format` / `source_name` 一定在）。
  final rows = await db.query(
    'book',
    columns: ['content_hash', 'source_format', 'source_name', 'title'],
  );
  final meta = <String, ({String ext, String fileName})>{};
  for (final r in rows) {
    final h = r['content_hash'];
    if (h is! String || h.isEmpty) continue;
    final fmt = (r['source_format'] as String?) ?? 'epub';
    final name = (r['source_name'] as String?) ??
        '${(r['title'] as String?) ?? 'book'}.$fmt';
    meta[h] = (ext: fmt, fileName: name);
  }

  final candidates = buildCandidates(
    pendingHashes: pending,
    formatOf: (h) => meta[h],
  );
  if (candidates.isEmpty) return;

  await queue.run(candidates);
}

/// 下载一本「只有云端」的书并落库。
///
/// 🔑 **复用导入管线**（`importBook`）而不是另写一条落库路径 ——
///    章节切分、指纹、进度认领、事务边界全在那边，重写一遍必然漂。
///
/// ⚠️ 扩展名未知（后端书单没有 ext）⇒ 用 [BookBlobClient.downloadAuto]
///    依次试 epub / txt。
Future<BookDownloadOutcome> downloadCloudBook({
  required String token,
  required BookBlobClient client,
  required Database db,
  required String? rawDir,
  required String newId,
  required CloudBook book,
}) async {
  if (token.isEmpty) return const BookDownloadNeedLogin();

  final r = await client.downloadAuto(
    token: token,
    contentHash: book.contentHash,
  );

  switch (r) {
    case BlobNeedLogin():
      return const BookDownloadNeedLogin();
    case BlobNotFound():
      return const BookDownloadNotFound();
    case BlobFailed(:final message):
      return BookDownloadFailed(message);
    case BlobUploaded():
    case BlobDeleted():
    case BlobQuotaExceeded():
      // 不会出现在下载路径上；归到失败而不是静默吞掉（同 `book_upload_queue` 的处理）
      return const BookDownloadFailed('意外的响应类型');
    case BlobDownloaded(:final bytes):
      // 🔑 先落**原始文件**：即使接下来的导入失败，这份文件也能让「上传」与
      //    「重试导入」省掉一次下载。⚠️ 但 `importBook` 自己也会存一次
      //    （同一路径、覆盖式）—— 这里显式先存是为了**导入失败也不丢下载结果**。
      final result = await importBook(
        db: db,
        bytes: bytes,
        fileName: '${book.title}.${_guessExt(book)}',
        newId: () => newId,
        addedAt: DateTime.now().toUtc().toIso8601String(),
        rawDir: rawDir,
      );
      switch (result) {
        case BookImportSuccess(:final bookId, :final title):
          // ⚠️ `bump()` 由**调用方**做（本函数已不持 ref）——
          //    调用方拿到结果后本来就要刷新 UI，顺手 bump 最自然。
          return BookDownloadSuccess(bookId: bookId, title: title);
        case BookImportFailure(:final kind, :final detail):
          return BookDownloadFailed('解析失败（$kind）：$detail');
      }
  }
}

/// 下载结果。
sealed class BookDownloadOutcome {
  const BookDownloadOutcome();
}

class BookDownloadSuccess extends BookDownloadOutcome {
  const BookDownloadSuccess({required this.bookId, required this.title});
  final String bookId;
  final String title;
}

class BookDownloadNeedLogin extends BookDownloadOutcome {
  const BookDownloadNeedLogin();
}

/// 云端没有这个文件（**确定的状态**，不是失败）—— 可能是「上传过元数据但文件没传上」。
class BookDownloadNotFound extends BookDownloadOutcome {
  const BookDownloadNotFound();
}

class BookDownloadFailed extends BookDownloadOutcome {
  const BookDownloadFailed(this.message);
  final String message;
}

/// 猜扩展名（**只用于生成一个像样的文件名**；真正的格式判定在解析层看魔数）。
String _guessExt(CloudBook b) => 'epub';
