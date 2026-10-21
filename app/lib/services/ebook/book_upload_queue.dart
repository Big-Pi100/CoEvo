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

/// 🆕 2026-10-10：**上传成功后写回本地状态**的钩子（真实实现 =
/// `CloudBookRepository.markUploadedBlob` + `bookDbRevisionProvider.bump()`）。
///
/// # 🔴 为什么需要它（此前**没人写回** ⇒ 两个后果都是静默的）
/// `presenceByHash` 与 `pendingUploadHashes` **都只认 `blob_size > 0`**：
/// · 不写回 ⇒ 这本书**永远被判为「云端没有」**⇒ 每次 kick 都**重传同一份文件**
/// · 书架**永远不显示「已上云」**⇒ 用户以为没传成功
///
/// ⚠️ 放在队列里（而不是让 `upload` 自己顺手写）：写回是**本队列的语义后果**
///    （「传成功了 ⇒ 本地要知道」），而 `upload` 只负责网络那一下。
typedef BlobUploadedHook = Future<void> Function(
  String contentHash,
  int blobSize,
);

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
    this.tooLargeThisRun = 0,
  });

  /// 正在上传的书的 `content_hash`；`null` = 空闲。
  final String? uploadingHash;
  final int doneThisRun;
  final int failedThisRun;

  /// 跳过（没有原始文件）—— **不是失败**，但要让用户知道「这本传不了」。
  final int skippedNoRaw;

  /// 🆕 2026-10-21：跳过（**这一本超过服务端单本上限**）。
  ///
  /// 与 [failedThisRun] 分开计：它不是网络/服务故障，重试也不会成功，
  /// 用户能做的是「换一本 / 去掉图片重做」。混进「失败 N 本」会让用户
  /// 反复点重试而永远失败。
  final int tooLargeThisRun;

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
    required this.rawDirOf,
    required this.upload,
    this.onUploaded,
    this.onUploadedError,
    this.onStateChanged,
  });

  /// 原始文件目录 —— 🔴 **回调，不是值**（2026-10-10 修）。
  ///
  /// # 为什么必须是回调（这条链此前**从未跑通过一次**）
  ///
  /// 原先这里是 `final String rawDir`，由 `bookUploadQueueProvider` 在**构造时**同步取：
  /// ```dart
  /// final rawDir = ref.watch(bookRawDirProvider).valueOrNull ?? '';   // ← 首次必为 null
  /// ```
  /// 而那个 provider **全库只有 1 处读取**（`book_import_flow` 的「导入后上传」）
  /// ⇒ **它第一次被构造，就是「要上传」的那一刻** —— 此时 FutureProvider 还没完成
  /// ⇒ `valueOrNull == null` ⇒ `rawDir = ''`
  /// ⇒ `readRawBook(rawDir: '')` = `File('/<hash>.epub')`（**不抛异常**，只 `exists()`）
  /// ⇒ 每本都判「原始文件缺失」而跳过 ⇒ **一个 HTTP 请求都不发**。
  ///
  /// 📌 实测证据（2026-10-10）：nginx access log 近一个月里
  ///    `POST /api/books/blob` 的 **App 请求 = 0 次**，且服务端**连 blob 目录都不存在**。
  ///
  /// 📌 判据：**「惰性 provider + 首次读 = 使用时刻」这个组合会稳定地拿到空值**
  ///    —— 越是「只在最后一步读一次」的 provider 越容易踩。
  ///    必需配置要在 `run()` 时 `await`，**不要**在 `Provider` 构造时同步取值。
  ///
  /// ⚠️ 一轮**只取一次**（放在 `run()` 开头，不在循环里逐本 await）——
  ///    目录在单轮内不会变，逐本取只是多几次 platform channel 往返。
  final Future<String> Function() rawDirOf;

  /// 注入的上传动作。
  final BlobUploader upload;

  /// 🆕 上传成功后写回本地状态（可空 —— 只推不写回的场景不需要）。
  final BlobUploadedHook? onUploaded;

  /// 🆕 写回失败的上报出口。
  ///
  /// 🔴 **不许静默**：写回失败本身不影响本次上传结论，但它会让这本书**下一轮又被重传**
  ///    （`pendingUploadHashes` 只看 `blob_size`）⇒ 必须留下痕迹。
  /// ⚠️ 用回调而不是 `debugPrint`：本文件刻意不依赖 `flutter/foundation`
  ///    （它的价值就是「能被 `dart run` 验」，见文件头）。
  final void Function(String contentHash, Object error)? onUploadedError;

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

    // 🔴 2026-10-22：计数与目录都提到 try **外面** —— 下面要用 `finally` 兜底。
    var done = 0, failed = 0, noRaw = 0, tooLarge = 0;
    late final String rawDir;

    try {
      // 🔴 **目录在本轮开始时取一次**（回调形态，根因见 `rawDirOf` 的长说明）。
      //    这是「上传真的会发请求」的前提 —— 取到空串的旧写法会让整轮**静默跳过**。
      //
      // ⚠️ 它自己也可能抛（回调里读 provider / 拼路径）⇒ 必须在 try 内。
      rawDir = await rawDirOf();

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
        tooLargeThisRun: tooLarge,
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
        case BlobUploaded(:final blobSize):
          done++;
          _attempts.remove(c.contentHash);
          // 🔴 写回本地 `blob_size`（根因见 `onUploaded` 的长说明）。
          //    ⚠️ 失败**不改变本次结论**（网络那一下已经成功了）——
          //       只记日志：下一轮同步的 pull 会把服务端权威值带回来。
          if (onUploaded != null) {
            try {
              await onUploaded!(c.contentHash, blobSize);
            } catch (e) {
              onUploadedError?.call(c.contentHash, e);
            }
          }
        case BlobNeedLogin():
          // 未登录 ⇒ **整体停下**（后面的书同样传不了，继续只会刷一串 401）
          _cancelled = true;
        case BlobQuotaExceeded():
          // 配额满 ⇒ **整体停下**（再传也会被拒）—— 由 UI 提示「删书 / 订阅」
          failed++;
          _cancelled = true;
        case BlobTooLarge():
          // 🔴 2026-10-21：**只有这一本**太大 ⇒ 跳过它、继续传下一本。
          //
          // 原先这里和配额满走同一个分支（`_cancelled = true`）⇒ 一本 40 MB 的书
          // 会让**其余所有书**都传不上去，直到用户猜着把它删掉。
          // 📌 判据：「这本书不行」≠「这个人不行」。
          //
          // ⚠️ 仍要记 `_attempts`：否则每轮 kick 都会把这本重新读盘 + 传一遍
          //    （白耗流量与时间），而它**永远不会成功**。到 `kMaxUploadAttempts`
          //    后走上面的退避分支，不再尝试。
          tooLarge++;
          _attempts[c.contentHash] =
              (_attempts[c.contentHash] ?? 0) + 1;
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

    } finally {
      // 🔴🔴 2026-10-22：**无论怎么退出，都必须清掉「正在传」标记**。
      //
      // # 一个会让上传永久瘫痪的洞（白哥 2026-10-22 真机）
      //
      // 现场：某本书一直「未上云」，手动点同步没反应、重新导入也没反应，
      //       **后端日志里零条上传请求**（连 401 都没有）。
      //
      // 根因就在本函数的开头：`if (_state.isBusy) return;`
      // · `isBusy` ⇔ `_state.uploadingHash != null`
      // · 而 `uploadingHash` 只在**每轮结束时**那次 `_emit` 里被清掉
      // · 中途任何一步抛异常（`rawDirOf()` / `readRawBook` 的 IO /
      //   `upload` 的未捕获异常）⇒ **最后那次 `_emit` 永远不执行**
      // ⇒ `uploadingHash` 永久非 null ⇒ **之后每一次 kick 都在第一行返回**
      // ⇒ 队列静默瘫痪：不发请求、不报错、UI 上「未上云」永远挂着。
      //
      // 📌 判据：**「每轮结束」的清理必须写在 `finally` 里，不能写在正常路径末尾**。
      //    （同族：`sync_service` 的 push 循环也靠状态自清，那里同样脆弱。）
      // 🔑 为什么不是「catch 后重置」：`catch` 只覆盖异常，`return`/`break`
      //    的提前退出仍会漏；`finally` 是唯一覆盖全部出口的位置。
      _emit(UploadQueueState(
        // 🔑 **不传 `uploadingHash`** ⇒ 它回到 null ⇒ 队列解除 busy
        doneThisRun: done,
        failedThisRun: failed,
        skippedNoRaw: noRaw,
        tooLargeThisRun: tooLarge,
      ));
    }
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
