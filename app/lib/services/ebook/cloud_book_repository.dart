// CoEvo · **云端书单**的本地镜像 —— 书架上云的数据层
//
// 🔴 零 Flutter 依赖（同 `book_progress_sync.dart` / `sync_merge.dart`）⇒ **本机可验**。
//
// # 三个概念先分清（本文件存在的理由）
//
// | 表 | 键 | 角色 |
// |---|---|---|
// | `book` | `id`（端侧 uuid）| **本地**已导入的书（正文在 `book_chapter`）|
// | `cloud_book` | `content_hash` | **云端**有什么（服务端书单的**只读副本**）|
//
// 🔑 两张表用 **`content_hash`** 关联（不是 `book.id`）——
//    `book.id` 是端侧生成的 uuid ⇒ 同一本书在两台设备上是两个 id，
//    只有文件指纹能认出「这是同一本」（与进度同步同一套判据）。
//
// # 🔴 本文件只管「读」与「整体替换」，**不发网络请求**
//
// 拉取/上传是 `cloud_book_client.dart` 的事（那一层依赖 http ⇒ 本机验不了）。
// 这里保持纯净，于是「合并规则」可以被一行数据测到。
//
// # 🔴 「整体替换」的调用前提（这条最容易写错）
//
// [mergeCloudBooks] 是**增量**合并（upsert + 按 `deleted` 删除），不是整体替换。
// ⚠️ 因此**只能在「成功拿到响应」后调用**。
//    若在**失败**时也调用（传空列表），那一轮不写任何东西（不会误删）——
//    这正是增量语义的好处；但也意味着**失败会被静默吞掉**，
//    所以网络层仍必须用 sealed result 区分「成功但空」与「失败」。
// ⇒ 所以网络层要用 **sealed result**（成功 / 未登录 / 失败）表达结果，
//    **失败绝不能退化成「空列表」**。（同 `translate_parse.dart` 的 401 教训。）
//
// 📄 设计依据：`docs/design/visual-cloud-bookshelf-2026-10-07.html`

import 'package:sqflite_common/sqlite_api.dart';

/// 一本书在**云端**的元数据（`cloud_book` 的一行）。
class CloudBook {
  const CloudBook({
    required this.contentHash,
    required this.title,
    this.author,
    this.language,
    this.chapterCount = 0,
    this.blobSize = 0,
    this.sizeBytes = 0,
    required this.addedAt,
  });

  /// 跨设备身份（与服务端 `sync_book.content_hash` 同一个键）。
  final String contentHash;
  final String title;
  final String? author;
  final String? language;
  final int chapterCount;

  /// 云端**实际存储**字节数。`0` = 服务端没有文件（只有元数据）。
  final int blobSize;

  /// 原始文件大小（配额展示用）。
  final int sizeBytes;

  /// 首次上云时间（服务端口径，**原样保留**）。
  final String addedAt;

  /// 从服务端 JSON 构造。
  ///
  /// 🔑 这里对「缺字段」很宽容（默认 0 / null）而不是抛 ——
  ///    服务端加字段是常态，端侧为「多了个字段」而崩是不划算的。
  ///    ⚠️ **但 `contentHash` 与 `title` 缺失是硬错误**：没有它无法与本地关联
  ///    （拿错误指纹匹配会把用户带到错的书，比不同步更糟）。
  static CloudBook? fromJson(Map<String, Object?> j) {
    final h = j['content_hash'];
    final t = j['title'];
    if (h is! String || h.isEmpty) return null;
    if (t is! String || t.isEmpty) return null;
    return CloudBook(
      contentHash: h,
      title: t,
      author: j['author'] as String?,
      language: j['lang'] as String? ?? j['language'] as String?,
      chapterCount: _asInt(j['chapter_count']),
      blobSize: _asInt(j['blob_size']),
      sizeBytes: _asInt(j['size_bytes']),
      addedAt: (j['added_at'] as String?) ?? '',
    );
  }

  static int _asInt(Object? v) => switch (v) {
        int i => i,
        num n => n.toInt(),
        String s => int.tryParse(s) ?? 0,
        _ => 0,
      };
}

/// 一本书相对云端的**存在状态**（DB 层只有这三态）。
///
/// ⚠️ 「**正在传**」**不在这里** —— 它是**运行时**状态（上传队列里的），
///    不是持久状态：App 重启后队列会按 [CloudBookRepository.pendingUploadHashes]
///    重新算出来。把它塞进 DB 会制造「重启后卡在『正在传』」的脏状态。
enum CloudPresence {
  /// 本地有、云端没有 ⇒ **需要上传**（失败/还没传）。
  localOnly,

  /// 两边都有 ⇒ **默认态，界面不加任何标记**
  /// （设计稿：有标记的一定有原因，否则满屏噪声）。
  synced,

  /// 只有云端 ⇒ 界面给「云」图标，点开才下载。
  cloudOnly,
}

/// `cloud_book` 的读写。
///
/// 🔑 全是 `static` 方法 + 显式传 `Database`（不持连接、不做单例）——
///    与 `book_progress_sync.dart` 同一风格，这样验证脚本能塞一个临时库进来。
class CloudBookRepository {
  const CloudBookRepository._();

  /// **增量合并**云端书单（pull 用）。
  ///
  /// 🔴 为什么**不是「整体替换」**（我第一版写成整体替换，是错的）：
  ///    pull 返回的是**增量**（服务端按 `received_at > since` 过滤）——
  ///    整体替换会把「本次增量里没出现的旧书」**全部删掉**，
  ///    用户会看到云端书架**一次少一批**，而下一次 pull 又补回来（像随机闪烁）。
  ///    📌 判据：**端侧的表能不能整体替换，取决于服务端给的是「全集」还是「增量」** ——
  ///       这两个前提必须在同一处对齐，不能一边假设全集一边发增量。
  ///
  /// [deletedHashes] 里的书会被删掉（别端删了书）。
  /// 🔑 **删除也必须走增量** —— 否则「别端删了书」这件事端侧永远不知道，
  ///    本地会一直显示一本云端已经不存在的书（点开下载必然 404）。
  ///
  /// 返回写入（含删除）的条数。
  static Future<int> mergeCloudBooks(
    Database db,
    List<CloudBook> upserts, {
    List<String> deletedHashes = const [],
  }) async {
    if (upserts.isEmpty && deletedHashes.isEmpty) return 0;
    return db.transaction<int>((txn) async {
      for (final h in deletedHashes) {
        await txn.delete('cloud_book',
            where: 'content_hash = ?', whereArgs: [h]);
      }
      for (final b in upserts) {
        await txn.insert(
          'cloud_book',
          {
            'content_hash': b.contentHash,
            'title': b.title,
            'author': b.author,
            'language': b.language,
            'chapter_count': b.chapterCount,
            'blob_size': b.blobSize,
            'size_bytes': b.sizeBytes,
            'added_at': b.addedAt,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      return upserts.length + deletedHashes.length;
    });
  }

  /// 云端书单（按 `added_at` 倒序 = 最近上云的在前）。
  static Future<List<CloudBook>> listCloudBooks(Database db) async {
    final rows = await db.query('cloud_book', orderBy: 'added_at DESC');
    return [
      for (final r in rows)
        CloudBook(
          contentHash: r['content_hash'] as String,
          title: r['title'] as String,
          author: r['author'] as String?,
          language: r['language'] as String?,
          chapterCount: (r['chapter_count'] as int?) ?? 0,
          blobSize: (r['blob_size'] as int?) ?? 0,
          sizeBytes: (r['size_bytes'] as int?) ?? 0,
          addedAt: (r['added_at'] as String?) ?? '',
        ),
    ];
  }

  /// 每本书（按 `content_hash`）相对云端的状态 —— 供书架页**批量**标注。
  ///
  /// 🔑 一次算完，而不是「每本书查一次」：
  ///    书架一屏可能有几十本，N+1 次查询在真机上是可感的卡顿。
  ///    这里只有 **2 次**查询（云端清单 + 本地书的指纹），与书数无关。
  ///
  /// ⚠️ 没有 `content_hash` 的本地书**不进结果**（算不出跨设备身份 ⇒ 无法判断）——
  ///    调用方查不到 key 时应**按「不显示标记」处理**（而不是当成 localOnly 去催上传，
  ///    那会给一本注定传不了的书反复挂「待上传」标记）。
  ///
  /// # 🔴 2026-10-09：判据由「`cloud_book` 有行」改为 **`blob_size > 0`**
  ///
  /// 后端 `sync_handlers::BookOut` 的文档早就写着：
  /// > 「`blob_size` 是端侧判断「**云端有没有这本书**」的**唯一依据**：
  /// >   `> 0` ⇒ 云端有 ⇒ 本地没有时可显示「云端」并允许下载。」
  ///
  /// 而**实现没跟上**（这里是按「行存在」判的）。原本看不出差别 ——
  /// 因为「有行」与「有文件」此前一直同步。2026-10-09 起不再同步了：
  /// 订阅到期满 30 天后，服务端会**清掉云端文件并把 `blob_size` 归零，但保留行**
  /// （行是「云端记录」，端侧还要靠它认书）。
  ///
  /// ⇒ 若仍按「行存在」判，会出现**静默失败**：
  ///    书架照旧显示「云备份」标记 → 点下载 → `404 这本书在云端没有文件`
  ///    （用户看到「云端有」却下不下来，且没有任何地方报错）。
  /// 📄 `docs/review/blob-retention-after-expiry-2026-10-09.md` ·
  ///    后端 `maintenance::purge_expired_blobs`
  static Future<Map<String, CloudPresence>> presenceByHash(
    Database db,
  ) async {
    final out = <String, CloudPresence>{};

    // ① 云端清单：**只认 `blob_size > 0`**（= 云端真的有文件），先记为「只有云端」
    //    ⚠️ `blob_size = 0` 的行**不是**「云端没有这本书」——它仍是云端记录，
    //       只是文件已被清理（或从未上传成功）。
    for (final r in await db.query(
      'cloud_book',
      columns: ['content_hash'],
      where: 'blob_size > 0',
    )) {
      final h = r['content_hash'];
      if (h is String && h.isNotEmpty) out[h] = CloudPresence.cloudOnly;
    }

    // ② 本地书覆盖：本地也有 ⇒ 两边都有（synced）；本地独有 ⇒ localOnly
    final localRows = await db.query(
      'book',
      columns: ['content_hash'],
      where: 'content_hash IS NOT NULL',
    );
    for (final r in localRows) {
      final h = r['content_hash'];
      if (h is! String || h.isEmpty) continue;
      out[h] = out.containsKey(h) ? CloudPresence.synced : CloudPresence.localOnly;
    }
    return out;
  }

  /// **待上传**的本地书指纹（本地有、云端没有）。
  ///
  /// 🔑 它是**派生值**（由两张表现算），不是持久队列 ——
  ///    所以 App 被杀后不会有「卡在队列里的脏状态」；
  ///    重启后重算，条件仍成立的会被再传一次（幂等：服务端按 `content_hash` 存，
  ///    重复上传只是覆盖同一份文件）。
  ///
  /// ⚠️ 需要配额判断（订阅 2 GB）由**上传队列**负责，不在本层。
  ///
  /// # 🔴 2026-10-09：「云端有没有」同样必须看 `blob_size > 0`
  ///
  /// 与 [presenceByHash] 是**同一件事的同一个口径**，两处必须一起改
  /// （只改一处 ⇒ 两处对「云端有没有」的判断会分叉，且**都不会报错**）。
  ///
  /// ⇒ 这里若仍按「行存在」判，后果是：云端文件被清（`blob_size = 0`、行还在）
  ///    之后，这本本地书**永远不会重新进入待上传** ⇒ 用户重新订阅了，
  ///    备份也**再也回不来**（而界面上什么都不显示）。
  static Future<List<String>> pendingUploadHashes(Database db) async {
    final rows = await db.rawQuery('''
      SELECT b.content_hash AS h
        FROM book b
        LEFT JOIN cloud_book c
               ON c.content_hash = b.content_hash
              AND c.blob_size > 0
       WHERE b.content_hash IS NOT NULL
         AND b.content_hash <> ''
         AND c.content_hash IS NULL
    ''');
    return [
      for (final r in rows)
        if (r['h'] is String && (r['h'] as String).isNotEmpty) r['h'] as String,
    ];
  }

  /// 🆕 2026-10-10：**上传成功后把 `blob_size` 写回本地 `cloud_book`**。
  ///
  /// # 🔴 为什么必须写回（此前没人写 ⇒ 两个后果都是静默的）
  ///
  /// [presenceByHash] 与 [pendingUploadHashes] **都只认 `blob_size > 0`**。
  /// 上传成功后不写回，这本书会**永远被判为「云端没有」**：
  /// · 每次 kick / 每次同步都**重传同一份文件** ⇒ 白耗流量与服务端配额时间
  /// · 书架**永远不显示「已上云」** ⇒ 用户以为没传成功，也看不到进度
  ///
  /// ⚠️ **不用「等下一次 pull」来兜**：那是**一次网络往返之后**的事，
  ///    而中间任何一次 kick 都会先重传一遍；且用户当场看不到任何变化。
  ///
  /// 🔑 元数据自**本地 `book` 表**取（与 `_pendingBooks` 同一来源）——
  ///    上传成功的书**必然本地有** ⇒ 字段齐全，不需要猜。
  /// ⚠️ 行**已存在**时**只更新 `blob_size`**：`added_at` 是**服务端口径**
  ///    （见 `book_db_schema.sql` 的注释：原样保留，否则云端排序会随
  ///     每台设备同步的时刻漂移）。
  /// ⚠️ `size_bytes` 同样传 0（与 `_pendingBooks` 的取舍一致：配额看服务端的
  ///    `blob_size`，本地这个字段只用于展示，且当前 UI 不显示它）。
  static Future<void> markUploadedBlob(
    Database db, {
    required String contentHash,
    required int blobSize,
  }) async {
    if (contentHash.isEmpty) return;
    final existing = await db.query(
      'cloud_book',
      columns: ['content_hash'],
      where: 'content_hash = ?',
      whereArgs: [contentHash],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await db.update(
        'cloud_book',
        {'blob_size': blobSize},
        where: 'content_hash = ?',
        whereArgs: [contentHash],
      );
      return;
    }
    final rows = await db.query(
      'book',
      where: 'content_hash = ?',
      whereArgs: [contentHash],
      limit: 1,
    );
    final b = rows.isEmpty ? null : rows.first;
    await db.insert(
      'cloud_book',
      {
        'content_hash': contentHash,
        // `title` 是 NOT NULL ⇒ 取不到时退到指纹本身（宁可显示一串哈希，
        // 也不让这条**已上云**的事实因为没有标题而丢失）
        'title': (b?['title'] as String?) ?? contentHash,
        'author': b?['author'],
        'language': b?['language'],
        'chapter_count': (b?['chapter_count'] as num?)?.toInt() ?? 0,
        'blob_size': blobSize,
        'size_bytes': 0,
        'added_at': (b?['added_at'] as String?) ??
            DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
}
