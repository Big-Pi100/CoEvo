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
import '../../../app/lib/services/ebook/book_raw_store.dart';
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
  check('上传 400 且文案为「超过单本上限」⇒ 也归到配额',
      parseUploadResponse(400, '{"error":"这本书超过单本上限（50 MB）"}')
          is BlobQuotaExceeded);
  check('上传 400 且文案为「书单里没有」⇒ **普通失败**（内部顺序问题，不是用户能解的）',
      parseUploadResponse(400, '{"error":"这本书还没在书单里，请先同步书单再上传"}')
          is BlobFailed);
  check('上传 413 ⇒ 也认作配额（后端将来若改用规范码）',
      parseUploadResponse(413, '') is BlobQuotaExceeded);

  check('下载 404 ⇒ NotFound（确定的状态，不是失败）',
      parseDownloadResponse(404, Uint8List(0), null) is BlobNotFound);
  check('下载 200 但 0 字节 ⇒ Failed（空文件不是合法书）',
      parseDownloadResponse(
              200, Uint8List(0), 'application/epub+zip') is
          BlobFailed);
  final dl = parseDownloadResponse(
      200, Uint8List.fromList([1, 2, 3]), 'application/epub+zip');
  check('下载 200 ⇒ 原样拿到字节（**不是**按 UTF-8 解码后的）',
      dl is BlobDownloaded && dl.bytes.length == 3 && dl.bytes[0] == 1);

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
    rawDir: rawDir,
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
    rawDir: rawDir,
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
    rawDir: rawDir,
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

  // buildCandidates 的跳过语义
  final c = buildCandidates(
    pendingHashes: ['a', 'b'],
    formatOf: (h) => h == 'a' ? (ext: 'epub', fileName: 'a.epub') : null,
  );
  check('🔑 `formatOf` 返回 null ⇒ 跳过（书已删 / 无指纹 —— 不猜、不传）',
      c.length == 1 && c.first.contentHash == 'a');

  await db.close();
  await dir.delete(recursive: true);

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
