// CoEvo · 书架上云端侧验收 —— 解析层 / 数据层 / 上传队列
//
// 跑法：cd scripts/query_verify && dart run bin/verify_book_cloud.dart
// 🔴 退出码：0 = 全过，1 = 有失败（用 `; echo $?` 直读，别接 `| tail`）。
//
// # 为什么值得单独一个脚本
//
// 这一层的三个部分**都最容易「看起来对」**：
//   ① **状态码映射**：`400` 同时承载「配额满 / 单本超限 / 书单未同步」三种语义
//      （后端实现如此）⇒ 端侧靠**文案前缀**区分，写错了只有真机会发现
//   ② **增量合并**：写错成「整体替换」会让云端书架一次少一批（下次又回来 = 像闪烁）
//   ③ **上传队列**：串行/退避/跳过三类分支在真机上很难逐个构造
//
// ⇒ 全部做成**可注入依赖**的纯逻辑（HTTP 用 mock、目录用临时目录）⇒ 本机全测。
//
// 🔴 本脚本自身的证伪方式（改断言后应各跑一遍）：
//   · 把 `precheckUpload` 的 `>` 改成 `>=` ⇒ 「恰好填满应允许」变红
//   · 把 `mergeCloudBooks` 换成「先 delete 全部」⇒ 增量合并那组变红
//   · 把 `parseUploadResponse` 里「云端空间不足」的分支删掉 ⇒ 配额那组变红

import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/book_db.dart';
import '../../../app/lib/services/ebook/book_blob_parse.dart';
import '../../../app/lib/services/ebook/book_import_plan.dart';
import '../../../app/lib/services/ebook/book_raw_store.dart';
import '../../../app/lib/services/ebook/book_text.dart';
import '../../../app/lib/services/ebook/book_upload_queue.dart';
import '../../../app/lib/services/ebook/cloud_book_repository.dart';
import '_repo_paths.dart';

var _pass = 0;
final _failures = <String>[];

void check(String label, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('  ✅ $label${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _failures.add('$label  $detail');
    print('  🔴 $label${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void section(String s) {
  print('');
  print('─' * 74);
  print(s);
  print('─' * 74);
}

/// 只留**代码行**（滤掉整行注释）。
///
/// 🔴 **文本断言前必须过这一层** —— 本轮实测踩到：
///    我在 `book_cloud_provider.dart` 的注释里写了旧代码
///    `ref.watch(bookRawDirProvider).valueOrNull ?? ''`（用来解释根因），
///    于是「不得再用 valueOrNull」这条**反向断言会假红**。
///    📌 判据：「**注释里提到**」≠「代码里写了」（两个方向都会出错：
///       反向断言假红、正向断言假绿）。
String _codeOnly(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String _readLib(String rel) =>
    _codeOnly(File(repoPath('app/lib/$rel')).readAsStringSync());

Future<void> main() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final schemaSql =
      File(repoPath('app/assets/sql/book_db_schema.sql')).readAsStringSync();

  // ══════════════════════════════════════════════════════════
  section('【1】状态码映射：400 的三种语义要分得开');
  check('上传 401 ⇒ 未登录（不是「失败」—— 用户的下一步是去登录）',
      parseUploadResponse(401, '') is BlobNeedLogin);
  final ok = parseUploadResponse(
      200, '{"ok":true,"blob_size":123,"usage":456,"quota":789}');
  check('上传 200 ⇒ 解析出 blob_size / usage',
      ok is BlobUploaded && ok.blobSize == 123 && ok.usage == 456);
  check('上传 400 且文案为「云端空间不足」⇒ 归到配额（不是普通失败）',
      parseUploadResponse(400, '{"error":"云端空间不足（已用 1 MB / 共 2 MB）"}')
          is BlobQuotaExceeded);
  // 🔴 2026-10-21：「单本太大」与「配额满」**必须分开**
  //
  // 原先这两条断言锁的是**旧行为**（都归 BlobQuotaExceeded）。那个行为是有害的：
  // 队列对配额满的反应是 `_cancelled = true`（整队停下）⇒ 一本 40 MB 的书
  // 会让**其余所有书**都传不上去，提示还是「云端空间不足」。
  // 📌 判据：「这本书不行」≠「这个人不行」。所以断言也得跟着改成新契约。
  check('上传 400 且文案为「超过单本上限」⇒ BlobTooLarge（**不是**配额）',
      parseUploadResponse(400, '{"error":"这本书超过单本上限（50 MB）"}')
          is BlobTooLarge);
  check('上传 413 ⇒ BlobTooLarge（axum BodyLimit 超限 = 单本太大，不是配额）',
      parseUploadResponse(413, '') is BlobTooLarge);
  // 反向断言：两者**不能**再落回同一个桶（否则队列又会整队停摆）
  check('「单本上限」与「配额不足」是两个不同的结果类型',
      parseUploadResponse(400, '{"error":"超过单本上限"}') is BlobTooLarge &&
          parseUploadResponse(400, '{"error":"云端空间不足"}')
              is BlobQuotaExceeded);
  check('上传 400 且文案为「书单里没有」⇒ **普通失败**（内部顺序问题，不是用户能解的）',
      parseUploadResponse(400, '{"error":"这本书还没在书单里，请先同步书单再上传"}')
          is BlobFailed);

    check('下载 404 ⇒ NotFound（确定的状态，不是失败）',
        parseDownloadResponse(404, Uint8List(0), null, ext: 'epub')
            is BlobNotFound);
    check('下载 200 但 0 字节 ⇒ Failed（空文件不是合法书）',
        parseDownloadResponse(200, Uint8List(0), 'application/epub+zip',
            ext: 'epub') is BlobFailed);
    final dl = parseDownloadResponse(
        200, Uint8List.fromList([1, 2, 3]), 'application/epub+zip',
        ext: 'epub');
    check('下载 200 ⇒ 原样拿到字节（**不是**按 UTF-8 解码后的）',
        dl is BlobDownloaded && dl.bytes.length == 3 && dl.bytes[0] == 1);
    // 🆕 2026-10-10：成功结果必须**附带本次实际用的 ext**（根因见【6】）
    check('🔴 下载成功 ⇒ 带回实际命中的 ext（否则下游只能猜格式）',
        dl is BlobDownloaded && dl.ext == 'epub',
        dl is BlobDownloaded ? 'ext=${dl.ext}' : '$dl');

  check('删除 200 ⇒ 解析出 freed_bytes',
      parseDeleteResponse(200, '{"ok":true,"freed_bytes":900}') is BlobDeleted &&
          (parseDeleteResponse(200, '{"ok":true,"freed_bytes":900}')
                  as BlobDeleted)
              .freedBytes ==
              900);

  check('extFromName 认得 epub / txt',
      extFromName('a.EPUB') == 'epub' && extFromName('b.txt') == 'txt');
  check('extFromName 认不出 ⇒ **null 而不是猜一个**（猜错会被后端 400）',
      extFromName('c.pdf') == null);

  // ══════════════════════════════════════════════════════════
  section('【2】配额预检：与后端**同一口径**（净增量 · 恰好等于上限允许）');
  check('正常量 ⇒ 通过', precheckUpload(usedBytes: 100, incomingBytes: 100) is UploadOk);
  check('单本超 50 MB ⇒ TooLarge',
      precheckUpload(usedBytes: 0, incomingBytes: kMaxBookBytes + 1)
          is UploadTooLarge);
  check('恰好填满 ⇒ **允许**（与后端一样用 `>` 而不是 `>=`）',
      precheckUpload(usedBytes: kCloudQuotaBytes - 10, incomingBytes: 10)
          is UploadOk);
  check('超 1 字节 ⇒ 拒绝',
      precheckUpload(usedBytes: kCloudQuotaBytes - 10, incomingBytes: 11)
          is UploadQuotaShort);
  check('🔴 覆盖式上传不额外占额度（先减掉它自己）⇒ 已用满也能重传同一本',
      precheckUpload(
              usedBytes: kCloudQuotaBytes,
              incomingBytes: 5 * 1024 * 1024,
              isOverwrite: true,
              existingBytes: 5 * 1024 * 1024) is UploadOk);

  // ══════════════════════════════════════════════════════════
  section('【3】云端书单：**增量合并**（不是整体替换）');
  final dir = await Directory.systemTemp.createTemp('coevo_cloudbook');
  final db = await openBookDb(
    factory: factory,
    path: '${dir.path}${Platform.pathSeparator}book.db',
    schemaSql: schemaSql,
  );

  CloudBook cb(String h, String t, {int blob = 0}) => CloudBook(
        contentHash: h,
        title: t,
        addedAt: '2026-10-08T00:00:00Z',
        blobSize: blob,
      );

  await CloudBookRepository.mergeCloudBooks(db, [cb('h1', '书一', blob: 100)]);
  await CloudBookRepository.mergeCloudBooks(db, [cb('h2', '书二', blob: 200)]);
  var list = await CloudBookRepository.listCloudBooks(db);
  check('🔴 第二次合并**没有删掉** h1（这正是「增量」而不是「整体替换」的判据）',
      list.length == 2 && list.any((b) => b.contentHash == 'h1'),
      '共 ${list.length} 条');

  await CloudBookRepository.mergeCloudBooks(db, const [], deletedHashes: ['h1']);
  list = await CloudBookRepository.listCloudBooks(db);
  check('🔴 删除也必须走增量（deletedHashes）⇒ 别端删的书在本端消失',
      list.length == 1 && list.first.contentHash == 'h2');

  // 三态
  await db.insert('book', {
    'id': 'local-1',
    'title': '书二（本地也有）',
    'source_format': 'epub',
    'chapter_count': 1,
    'char_count': 1,
    'added_at': '2026-10-08T00:00:00Z',
    'content_hash': 'h2',
  });
  await db.insert('book', {
    'id': 'local-2',
    'title': '本书没上传',
    'source_format': 'txt',
    'chapter_count': 1,
    'char_count': 1,
    'added_at': '2026-10-08T00:00:00Z',
    'content_hash': 'h-local-only',
  });
  final presence = await CloudBookRepository.presenceByHash(db);
  check('两边都有 ⇒ synced（界面**不加任何标记**）',
      presence['h2'] == CloudPresence.synced);
  check('本地有、云端没有 ⇒ localOnly',
      presence['h-local-only'] == CloudPresence.localOnly);
  // 🔴 2026-10-09：**夹具必须显式给 `blob`** —— `cb()` 的默认值是 0，
  //    而 `presenceByHash` 自 2026-10-09 起**只认 `blob_size > 0`**
  //    （「云端有没有这本书」的**唯一依据**；配套后端「到期满 30 天清文件、**保留行**」）。
  //    ⇒ 漏传 `blob:` 会造出「行在、文件不在」的**假**云端书 ⇒ 断言必然红（**假红**）。
  //    📌 判据：**夹具也要跟「口径变更」走** —— 口径改了，夹具的默认值可能就失效了。
  await CloudBookRepository.mergeCloudBooks(
      db, [cb('h-cloud-only', '只在云端', blob: 300)]);
  final p2 = await CloudBookRepository.presenceByHash(db);
  check('只有云端 ⇒ cloudOnly（界面给云图标）',
      p2['h-cloud-only'] == CloudPresence.cloudOnly);

  final pending = await CloudBookRepository.pendingUploadHashes(db);
  check('待上传 = 本地有、云端没有 ⇒ 只有 h-local-only',
      pending.length == 1 && pending.first == 'h-local-only',
      pending.join(','));

  // ── 🆕🔴🔴 2026-10-09：**云端文件被清理**（`blob_size = 0`、行还在）────────────────
  //
  // 🔴 本节守的是那次口径改动的**唯一目的**，此前**一条断言都没有** ——
  //    即「改完等于没有防线」：出问题时**没有任何东西**会红。
  //
  // 实况：订阅到期满 30 天后，服务端清掉云端文件、把 `blob_size` 归零、**保留行**
  //      （行是「云端记录」，端侧还要靠它认书）。
  // 📄 `docs/review/blob-retention-after-expiry-2026-10-09.md`
  //      · 后端 `maintenance::purge_expired_blobs`
  //
  // 若仍按「行存在」判 ⇒ **静默失败**：书架照旧显示「云备份」→ 点下载 →
  //      `404 这本书在云端没有文件`（用户看到「云端有」却下不下来，**全程无报错**）。
  await db.insert('book', {
    'id': 'local-3',
    'title': '云端已被清理（本地还在）',
    'source_format': 'epub',
    'chapter_count': 1,
    'char_count': 1,
    'added_at': '2026-10-08T00:00:00Z',
    'content_hash': 'h-purged',
  });
  await CloudBookRepository.mergeCloudBooks(
      db, [cb('h-purged', '已被清理', blob: 0)]);
  final p3 = await CloudBookRepository.presenceByHash(db);
  check('🔴 `blob_size = 0`（文件已清、行还在）⇒ **不给云图标**（不是 synced / cloudOnly）',
      p3['h-purged'] == CloudPresence.localOnly,
      '实得 ${p3['h-purged']}');
  final pending2 = await CloudBookRepository.pendingUploadHashes(db);
  check('🔴 …且**重新进待上传**（否则用户续订后备份**再也回不来**）',
      pending2.contains('h-purged'), pending2.join(','));
  check('…原有待传项仍在（新增一条不影响既有判定）',
      pending2.contains('h-local-only'), pending2.join(','));

  // ══════════════════════════════════════════════════════════
  section('【4】上传队列：串行 · 退避 · 跳过（注入 mock，不碰网络）');

  final rawDir = '${dir.path}${Platform.pathSeparator}raw';
  await saveRawBook(
      rawDir: rawDir,
      contentHash: 'h-local-only',
      ext: 'txt',
      bytes: Uint8List.fromList([1, 2, 3]));

  var calls = <String>[];
  final q = BookUploadQueue(
    // 🔴 2026-10-10：目录改为**回调**（队列在 `run()` 时 await）——
    //    旧写法由 provider 在构造时同步取，首次必拿到空串 ⇒ 整轮静默跳过。
    //    断言见本节末尾那组「目录必须在使用时取」。
    rawDirOf: () async => rawDir,
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async {
      calls.add(contentHash);
      return const BlobUploaded(blobSize: 3, usage: 3);
    },
  );
  await q.run(buildCandidates(
    pendingHashes: ['h-local-only'],
    formatOf: (h) => (ext: 'txt', fileName: 'x.txt'),
  ));
  check('成功上传 1 本', calls.length == 1 && q.state.doneThisRun == 1);

  // 没有原始文件 ⇒ 跳过并**计数**（不是失败）
  final q2 = BookUploadQueue(
    rawDirOf: () async => rawDir,
    upload: ({required contentHash, required ext, required bytes, required fileName}) async {
      calls.add('不应被调用');
      return const BlobUploaded(blobSize: 0, usage: 0);
    },
  );
  await q2.run(buildCandidates(
    pendingHashes: ['h-no-raw-file'],
    formatOf: (h) => (ext: 'epub', fileName: 'y.epub'),
  ));
  check('没有原始文件 ⇒ 跳过且 skippedNoRaw=1（**不是失败** —— 老书就是这种情况）',
      q2.state.skippedNoRaw == 1 && q2.state.failedThisRun == 0);

  // 配额满 ⇒ 同一次 run 内**整体停下**（后面的候选不再尝试）
  //
  // ⚠️ 测法说明（我第一版写错了）：**不能**用「跑两次 run」来测 ——
  //    `run()` 每次开头都会把 `_cancelled` 复位，而**这是有意的**：
  //    用户删掉几本书之后重试，本来就该重新开始。
  //    ⇒ 只能**在一次 run 里放多个候选**，看后面的有没有被尝试。
  await saveRawBook(
      rawDir: rawDir,
      contentHash: 'h-q1',
      ext: 'txt',
      bytes: Uint8List.fromList([1]));
  await saveRawBook(
      rawDir: rawDir,
      contentHash: 'h-q2',
      ext: 'txt',
      bytes: Uint8List.fromList([1]));

  final seen = <String>[];
  final q3 = BookUploadQueue(
    rawDirOf: () async => rawDir,
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async {
      seen.add(contentHash);
      return const BlobQuotaExceeded('云端空间不足');
    },
  );
  await q3.run(buildCandidates(
    pendingHashes: const ['h-q1', 'h-q2'],
    formatOf: (h) => (ext: 'txt', fileName: '$h.txt'),
  ));
  check('配额满 ⇒ 计为失败', q3.state.failedThisRun == 1,
      '实际 ${q3.state.failedThisRun}');
  check('🔴 配额满后**同一次 run 内整体停下**（第二个候选根本没被尝试）',
      seen.length == 1 && seen.first == 'h-q1', seen.join(','));

  // 🔴 2026-10-21：**「单本太大」必须只跳过那一本，不能整队停**
  //
  // 出事场景（真实）：用户书架里有一本 40 MB 的图册（端侧导入放行），
  // 后端单本上限 32 MB（现已统一为 50 MB）⇒ 上传被拒 ⇒ 旧代码归成「配额满」
  // ⇒ `_cancelled = true` ⇒ **其余所有书都传不上去**，用户完全不知道原因。
  //
  // 📌 断言形状：故意让**第一本**太大，检查**第二本仍然被尝试**。
  //    ⚠️ 顺序不能反 —— 反了就测不出「停不停」（反正都不会再试）。
  final seenTooLarge = <String>[];
  final qTooLarge = BookUploadQueue(
    rawDirOf: () async => rawDir,
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async {
      seenTooLarge.add(contentHash);
      if (contentHash == 'h-q1') {
        return const BlobTooLarge('这本书超过单本上限（50 MB）');
      }
      return const BlobUploaded(blobSize: 1, usage: 1);
    },
  );
  await qTooLarge.run(buildCandidates(
    pendingHashes: const ['h-q1', 'h-q2'],
    formatOf: (h) => (ext: 'txt', fileName: '$h.txt'),
  ));
  check('单本太大 ⇒ 单独计数（不混进「失败」）',
      qTooLarge.state.tooLargeThisRun == 1 && qTooLarge.state.failedThisRun == 0,
      'tooLarge=${qTooLarge.state.tooLargeThisRun} failed=${qTooLarge.state.failedThisRun}');
  check('🔴 单本太大 ⇒ **继续传下一本**（不是整队停摆）',
      seenTooLarge.length == 2 && seenTooLarge.last == 'h-q2',
      seenTooLarge.join(','));
  check('…且那一本确实传成功了', qTooLarge.state.doneThisRun == 1);

  // buildCandidates 的跳过语义
  final c = buildCandidates(
    pendingHashes: ['a', 'b'],
    formatOf: (h) => h == 'a' ? (ext: 'epub', fileName: 'a.epub') : null,
  );
  check('🔑 `formatOf` 返回 null ⇒ 跳过（书已删 / 无指纹 —— 不猜、不传）',
      c.length == 1 && c.first.contentHash == 'a');

  // ══════════════════════════════════════════════════════════
  section('【5】上传闭环：目录在使用时取 · 成功后写回 blob_size · 触发点 ②③');

  // ── ① 目录必须**在使用时**取（回归防线：旧写法在构造时取 ⇒ 空串 ⇒ 0 请求）──
  var dirCalls = 0;
  final q4 = BookUploadQueue(
    rawDirOf: () async {
      dirCalls++;
      return rawDir;
    },
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async =>
        const BlobUploaded(blobSize: 5, usage: 5),
  );
  check('构造时**不**取目录（回调此时未被调用）', dirCalls == 0, '实得 $dirCalls');
  await saveRawBook(
      rawDir: rawDir,
      contentHash: 'h-dir',
      ext: 'txt',
      bytes: Uint8List.fromList([7]));
  await q4.run(buildCandidates(
    pendingHashes: ['h-dir'],
    formatOf: (h) => (ext: 'txt', fileName: 'd.txt'),
  ));
  check('🔴 `run()` 时才取目录（**恰好一次**），且真的发起了上传',
      dirCalls == 1 && q4.state.doneThisRun == 1,
      'dirCalls=$dirCalls done=${q4.state.doneThisRun}');

  // ── ② 目录为空串 ⇒ 判「缺原始文件」并计数（不崩、也不误报成功）──
  final q5 = BookUploadQueue(
    rawDirOf: () async => '',
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async =>
        const BlobUploaded(blobSize: 0, usage: 0),
  );
  await q5.run(buildCandidates(
    pendingHashes: ['h-local-only'],
    formatOf: (h) => (ext: 'txt', fileName: 'x.txt'),
  ));
  check('目录为空串 ⇒ 计 skippedNoRaw 且**不误报成功**',
      q5.state.skippedNoRaw == 1 && q5.state.doneThisRun == 0,
      'noRaw=${q5.state.skippedNoRaw} done=${q5.state.doneThisRun}');

  // ── ③ 上传成功必须**写回 `blob_size`**（否则永远重传 + 书架永远不显示已上云）──
  await db.insert('book', {
    'id': 'local-wb',
    'title': '写回测试书',
    'source_format': 'txt',
    'chapter_count': 1,
    'char_count': 1,
    'added_at': '2026-10-10T00:00:00Z',
    'content_hash': 'h-writeback',
  });
  await saveRawBook(
      rawDir: rawDir,
      contentHash: 'h-writeback',
      ext: 'txt',
      bytes: Uint8List.fromList([1, 2]));
  final wroteBack = <String>[];
  final q6 = BookUploadQueue(
    rawDirOf: () async => rawDir,
    upload: ({
      required String contentHash,
      required String ext,
      required Uint8List bytes,
      required String fileName,
    }) async =>
        const BlobUploaded(blobSize: 42, usage: 0),
    onUploaded: (hash, size) async {
      wroteBack.add('$hash=$size');
      await CloudBookRepository.markUploadedBlob(db,
          contentHash: hash, blobSize: size);
    },
  );
  await q6.run(buildCandidates(
    pendingHashes: ['h-writeback'],
    formatOf: (h) => (ext: 'txt', fileName: 'w.txt'),
  ));
  check('🔴 成功后调用写回钩子（且带上服务端算出的 blob_size）',
      wroteBack.length == 1 && wroteBack.first == 'h-writeback=42',
      wroteBack.join(','));
  final pendingAfter = await CloudBookRepository.pendingUploadHashes(db);
  check('🔴 写回后**不再**出现在待上传（否则每轮都重传同一份文件）',
      !pendingAfter.contains('h-writeback'), pendingAfter.join(','));
  final presAfter = await CloudBookRepository.presenceByHash(db);
  check('🔴 …且 presence 变成 `synced`（云端有文件 + 本地也有）',
      presAfter['h-writeback'] == CloudPresence.synced,
      '实得 ${presAfter['h-writeback']}');

  // ── ④ 接线与触发点（**锁调用点，不锁文件位置**）──
  final prov = _readLib('providers/book_cloud_provider.dart');
  check('🔴 provider 传 `rawDirOf:` **回调**（不在构造时同步取值）',
      prov.contains('rawDirOf:'));
  check('🔴 provider **不再**用 `bookRawDirProvider).valueOrNull` 同步取目录',
      !prov.contains('bookRawDirProvider).valueOrNull'));
  check('🔴 provider 接了 `onUploaded:`（上传成功 ⇒ 写回本地）',
      prov.contains('onUploaded:'));
  check('…且「未上云」计数与队列**同一口径**（`pendingUploadHashes`）',
      prov.contains('pendingUploadCountProvider') &&
          prov.contains('pendingUploadHashes'));

  final syncProv = _readLib('providers/sync_provider.dart');
  // 🔑 锁**调用处**（带实参），不锁方法名 —— 否则「把调用删了、只留定义」照样为绿
  //    （本项目「子串断言锁不到接线」那一族）。
  check('🔴 触发点 ②：同步之后**真的调了**补传（`await _kickUploadIfNeeded(ref)`）',
      syncProv.contains('await _kickUploadIfNeeded(ref)'));
  check('…且**只在非 pushOnly** 时做（登出前 flush / 进后台不该传文件）',
      syncProv.contains('if (!pushOnly)'));

  final tab = _readLib('screens/reading_tab_screen.dart');
  // 🔑 同理：锁「药丸把 `_retryUpload` 接到了 onTap」，而不是「这个名字存在」。
  check('🔴 触发点 ③：书架有**手动重试入口**（「未上云」药丸 → onTap: `_retryUpload`）',
      tab.contains("label: '未上云'") && tab.contains('onTap: _retryUpload'));
  check('…且计数走 `pendingUploadCountProvider`（**真的 watch**，不另算一套）',
      tab.contains('ref.watch(pendingUploadCountProvider)'));
  check('🔴 「没东西待传」时那枚药丸**不存在**（零常驻成本）',
      tab.contains('if (pending <= 0) return importChip;'));

  final shelf = _readLib('screens/book_library_screen.dart');
  check('🔴 下载路径也在**使用时** `await` 目录（同类 bug 一次修全）',
      shelf.contains('await ref.read(bookRawDirProvider.future)'));

  final bm = _readLib('providers/bookmark_provider.dart');
  check('🔴 收藏读端**订阅**了修订号（`bump` 的另一半 —— 否则要重开页面才刷）',
      bm.contains('ref.watch(userDbRevisionProvider)'));

  await db.close();
  await dir.delete(recursive: true);

  // ══════════════════════════════════════════════════════════════════════
  section('【6】下载链：真实 ext 必须带出来 · 章节 id 必须各不相同');
  // ══════════════════════════════════════════════════════════════════════
  //
  // 🔴 两个真实 bug（2026-10-10 · 真机实测）：
  //   A) `downloadAuto` 依次试 epub/txt，**却把命中的 ext 丢掉了** ⇒ 下游只能猜
  //      ⇒ txt 书被猜成 epub ⇒ `notEpub`（文件头不是 zip 签名）。
  //   B) `downloadCloudBook` 把 id **生成器**当成「一个 id 值」传给 `importBook`
  //      ⇒ 每一章拿到同一个 id ⇒ `UNIQUE constraint failed: book_chapter.id`。

  // ── A：下载方**不得**再「猜」格式 ──
  //
  // ⚠️ 这里必须**切片**：`ext: ext,` 在 `book_blob_client.dart` 里有**两处**
  //    （`download()` 里回传给解析器 + `downloadAuto()` 里传给 `download()`）
  //    ⇒ 整文件 `contains` 会被**另一处同名行兜住** = 假绿。
  //    📌 判据：**能切片就切片**；`ext: ext,` 这类短串尤其。
  final blobSrc = _readLib('api/book_blob_client.dart');
  final dlStart = blobSrc.indexOf('Future<BlobResult> download(');
  final dlEnd = blobSrc.indexOf('Future<BlobResult> delete(');
  final dlBody =
      (dlStart >= 0 && dlEnd > dlStart) ? blobSrc.substring(dlStart, dlEnd) : '';
  check('…能切出 `download()` 方法体（下面两条断言的前提）', dlBody.isNotEmpty);
  check('🔴 `download()` 把本次用的 ext 交给解析（否则 ext 会丢）',
      dlBody.contains('parseDownloadResponse(') && dlBody.contains('ext: ext,'));
  final provSrc = _readLib('providers/book_cloud_provider.dart');
  check('🔴 落库文件名用**真实 ext**（不再硬编码 epub）',
      provSrc.contains(r"'${book.title}.$ext'"));
  check('🔴 **不再有 `_guessExt`**（反向断言：猜扩展名的入口已删除）',
      !provSrc.contains('_guessExt'));

  // ── B-1：生成器 vs 常量（真跑，直接锁住 iOS 那条 UNIQUE 冲突的根因）──
  final dlDraft = BookDraft(
    title: 'T',
    author: null,
    language: 'en',
    sourceFormat: 'epub',
    chapters: [
      for (var i = 0; i < 3; i++) ChapterDraft(title: 'C$i', text: 't$i'),
    ],
  );
  final badPlan = buildImportPlan(
    draft: dlDraft,
    fileName: 'x.epub',
    addedAt: '2026-10-10T00:00:00Z',
    newId: () => 'same-id',
    contentHash: 'h',
  );
  check('🔴 常量生成器 ⇒ 书与各章 id **全部相同**（这正是真机那条 UNIQUE 冲突）',
      {badPlan.bookId, ...badPlan.chapters.map((c) => c.id)}.length == 1);
  var seq = 0;
  final goodPlan = buildImportPlan(
    draft: dlDraft,
    fileName: 'x.epub',
    addedAt: '2026-10-10T00:00:00Z',
    newId: () => 'id-${seq++}',
    contentHash: 'h',
  );
  check('✅ 生成器 ⇒ 书与各章 id **互不相同**（能成功落库）',
      {goodPlan.bookId, ...goodPlan.chapters.map((c) => c.id)}.length ==
          goodPlan.chapters.length + 1);

  // ── B-2：源码级 —— 下载路径必须**透传生成器** ──
  check('🔴 `downloadCloudBook` 的 newId 声明为**生成器**（不是 String）',
      provSrc.contains('required String Function() newId'));
  check('🔴 且**直接透传**（`newId: newId`，没有包成常量闭包）',
      provSrc.contains('newId: newId,') && !provSrc.contains('() => newId'));
  final libSrc = _readLib('screens/book_library_screen.dart');
  check('🔴 调用方传**函数引用**（`const Uuid().v4` 不带括号）',
      libSrc.contains('newId: const Uuid().v4,'));

  // ══════════════════════════════════════════════════════════
  print('');
  print('═' * 74);
  if (_failures.isEmpty) {
    print('✅ 全部通过：$_pass 项');
  } else {
    print('🔴 失败 ${_failures.length} 项 / 通过 $_pass 项：');
    for (final f in _failures) {
      print('    · $f');
    }
    print('');
    print('🔑 最可能的原因：');
    print('    · 【1】红 ⇒ 后端的状态码/文案变了 ⇒ **端侧按文案区分的分支要跟着改**');
    print('    · 【3】红 ⇒ 有人把增量合并改成了「整体替换」（会让云端书架像随机闪烁）');
    print('    · 【4】红 ⇒ 队列的跳过/停止条件被改动了');
  }
  print('═' * 74);
  if (_failures.isNotEmpty) exitCode = 1;
}
