// CoEvo · `book.db` 的共享连接 + 书库读写
//
// 🔴 连接的所有权**唯一**（照 `user_db_provider.dart` 已验证的结论）：
//    `sqflite` 默认 `singleInstance: true` ⇒ 同路径第二次 `openDatabase` 返回**同一个对象**；
//    若两个 provider 各自 `onDispose(close)`，谁先销毁谁把**共用的那个**关掉
//    ⇒ 另一个继续用就 `database_closed`。本文件是**唯一所有者**。
//
// # ⚠️ 消费约定（与 `userDbProvider` 同一条硬约束）
//
// **不要把本 provider 当作「内容能不能渲染」的前置条件。**
//   · 信息流页的「我的书库」入口是**纯 UI**（不查库）⇒ 库打不开也照常显示、照常能点
//   · 只有**书库页自己**才 `await` 这个 provider —— 那是它的本职数据，等是应该的
// 🔑 判据（产品原则）：**除生词表上限外不验证登录态**——同理，
//    「库可用性」也不该成为「页面可见性」的开关。

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
// `Database` / `ConflictAlgorithm` 来自 `sqflite_common`（`sqflite` 是它的实现）——
// `book_db.dart` 只导出函数，不 re-export 类型（同 `user_db.dart` 的做法）。
import 'package:sqflite_common/sqlite_api.dart'
    show ConflictAlgorithm, Database;

import '../services/book_db.dart';

/// 已打开的 `book.db`（**全局唯一**）。
final bookDbProvider = FutureProvider<Database>((ref) async {
  try {
    // 🔑 DDL 由 Flutter 侧读入并注入 —— 连接层（`book_db.dart`）因此保持**纯 Dart**。
    final schema = await rootBundle.loadString(kBookDbSchemaAsset);

    // Application Support（**不是** Documents）—— 理由同 `user.db`：
    // 本库是**解析后的副本**，不是「用户的文档」（原文件在用户自己的「文件」App 里）
    // ⇒ 不该让用户在「文件」App 里看到它、也不该被当成用户数据来管理。
    //
    // ⚠️ **已知待办**（如实记录，未处理）：iOS 的 Application Support 默认**会进 iCloud 备份**。
    //    一本书解析后可达数 MB，几十本就会把备份撑大，且这类「可由用户重新导入而重建」的
    //    数据按 Apple 的存储指引**本不该被备份**。
    //    ⏳ 若真机发现备份体积异常 ⇒ 给库文件设 `isExcludedFromBackup = true`
    //      （`path_provider` 不直接暴露，需要走 `NSURL` 的 API，故留到需要时做）。
    final dir = await getApplicationSupportDirectory();
    final db = await openBookDb(
      factory: sqflite.databaseFactory,
      path: p.join(dir.path, kBookDbFileName),
      schemaSql: schema,
    );

    // 🔑 **唯一的释放点**（见文件头「所有权唯一」）——消费方不允许自己 close。
    ref.onDispose(() => db.close());

    return db;
  } catch (e, st) {
    // 🔴 **必须留痕**（从 `user_db_provider` 迁来的教训）：
    //    「刻意不 rethrow-catch」与「不打日志」是两件事 —— 前者语义正确，后者是遗漏。
    //    没有日志时，真机报「导入没反应」会**一行痕迹都没有**，只能靠读代码反推。
    debugPrint('[book_db] 打开失败：$e\n$st');
    rethrow;
  }
});

/// 书库列表项（`book` 表 + 阅读进度）。
///
/// 🔑 进度来自 `book_progress` 的 **LEFT JOIN**（不是 INNER）——
///    没打开过的书**没有** progress 行（见 `book_importer.dart` 末尾「有意不做的事 ①」），
///    用 INNER JOIN 会让「刚导入还没读」的书**从列表里消失**。
class BookSummary {
  const BookSummary({
    required this.id,
    required this.title,
    required this.author,
    required this.chapterCount,
    required this.chapterIdx,
    required this.scrollRatio,
  });

  final String id;
  final String title;
  final String? author;
  final int chapterCount;

  /// 已读到的章序（无进度时 0）。
  final int chapterIdx;

  /// 章内相对位置 0~1。
  final double scrollRatio;

  /// 全书进度 0~1 —— 用于列表上的进度显示。
  ///
  /// ⚠️ `chapterCount == 0` 时返回 0（防除零 —— 空书理论上进不来，但别让显示层崩）。
  double get progress {
    if (chapterCount <= 0) return 0;
    final v = (chapterIdx + scrollRatio) / chapterCount;
    return v.clamp(0.0, 1.0);
  }
}

/// 书库列表（按导入时间倒序 —— 最近导入的在最上面）。
///
/// 🔑 依赖 [bookDbRevisionProvider]：导入/删书后 `bump()` 一次，**读端自动重算**
///    （反转依赖 —— 写端不必点名每个读端，见 `user_db_provider` 的论证）。
final bookListProvider = FutureProvider<List<BookSummary>>((ref) async {
  ref.watch(bookDbRevisionProvider);
  final db = await ref.watch(bookDbProvider.future);

  final rows = await db.rawQuery('''
    SELECT b.id, b.title, b.author, b.chapter_count,
           COALESCE(pr.chapter_idx, 0)   AS chapter_idx,
           COALESCE(pr.scroll_ratio, 0.0) AS scroll_ratio
    FROM book b
    LEFT JOIN book_progress pr ON pr.book_id = b.id
    ORDER BY b.added_at DESC
  ''');

  return rows
      .map((r) => BookSummary(
            id: r['id'] as String,
            title: r['title'] as String,
            author: r['author'] as String?,
            chapterCount: (r['chapter_count'] as int?) ?? 0,
            chapterIdx: (r['chapter_idx'] as num?)?.toInt() ?? 0,
            scrollRatio: (r['scroll_ratio'] as num?)?.toDouble() ?? 0.0,
          ))
      .toList();
});

/// 删一本书（`book_chapter` / `book_progress` 靠**外键 CASCADE** 连带删）。
///
/// 🔴 依赖 `PRAGMA foreign_keys = ON`（在 `book_db.dart` 的 `onConfigure` 里开）。
///    没开的话，删书会**静默留下孤儿章节** —— 占空间，且将来若按 `book_id` 反查
///    会读到「已删书的正文」（表现为「删了的书还能搜索到内容」）。
Future<void> deleteBook(Database db, String bookId) async {
  await db.delete('book', where: 'id = ?', whereArgs: [bookId]);
}

/// 一章的正文（含所属书的元信息）—— 阅读页直接消费。
class ChapterText {
  const ChapterText({
    required this.bookTitle,
    required this.chapterTitle,
    required this.text,
    required this.idx,
    required this.chapterCount,
  });

  final String bookTitle;

  /// 章标题（TXT 无章节标记时为 null ⇒ 阅读页据此不显示标题行）。
  final String? chapterTitle;

  final String text;

  /// 章序，0-based。
  final int idx;
  final int chapterCount;
}

/// 读一章（`book` + 当前 `book_chapter`）。
///
/// 🔑 **按章取，不整本载入** —— 大书可达数十万字符，整本进内存会 OOM。
///    这是 schema 设计时就定好的（`book_chapter` 一章一行、`idx` 定序）。
///
/// 返回 null 的两种情形（调用方要分开处理）：
///   · 书不存在（被删了 / id 传错）
///   · 该章不存在（`idx` 越界 —— 通常是章节数被改过）
Future<ChapterText?> loadChapter(
  Database db, {
  required String bookId,
  required int idx,
}) async {
  final books = await db.query('book',
      columns: ['title', 'chapter_count'],
      where: 'id = ?',
      whereArgs: [bookId],
      limit: 1);
  if (books.isEmpty) return null;
  final title = books.first['title'] as String;
  final count = (books.first['chapter_count'] as int?) ?? 0;

  final rows = await db.query('book_chapter',
      columns: ['title', 'text'],
      where: 'book_id = ? AND idx = ?',
      whereArgs: [bookId, idx],
      limit: 1);
  if (rows.isEmpty) return null;

  return ChapterText(
    bookTitle: title,
    chapterTitle: rows.first['title'] as String?,
    text: (rows.first['text'] as String?) ?? '',
    idx: idx,
    chapterCount: count,
  );
}

/// 记阅读进度（upsert —— `book_progress` 主键是 `book_id`，一本书一条）。
///
/// ⚠️ 调用方**不该 await 它**：记进度失败**不该阻止用户继续读**。
/// 判据同产品原则里的那条 —— **易失败的依赖别放在「渲染」的前置**。
Future<void> saveProgress(
  Database db, {
  required String bookId,
  required int chapterIdx,
}) async {
  await db.insert(
    'book_progress',
    {
      'book_id': bookId,
      'chapter_idx': chapterIdx,
      // 🔑 一期固定 0：**不做章内滚动位置跟踪**。
      //    存「绝对像素」本来就没意义（换字号/换设备就废 —— 见 schema 注释），
      //    要存得存「相对位置」，那需要稳定的定位锚点 ⇒ 留到需要时做。
      //    现在记「读到第几章」已经覆盖绝大多数续读需求。
      'scroll_ratio': 0.0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// 「书库数据变了」的单一信号源 —— 写端 `bump()` 一次，读端自动跟随。
///
/// 🔑 为什么需要：`bookListProvider` 是带缓存的 `FutureProvider`，
///    只有 `invalidate` / 失去监听者才重算。若靠「每个写端记得 invalidate」，
///    迟早漏一处（本项目已记：**靠人记的机制迟早会漏** ⇒ 反转依赖）。
class BookDbRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// 在**写库成功之后**调用（顺序重要：先写库再 bump —— 反过来的话，
  /// 读端可能在写入完成前就重查，然后再也不会自动刷新）。
  void bump() => state = state + 1;
}

final bookDbRevisionProvider =
    NotifierProvider<BookDbRevision, int>(BookDbRevision.new);
