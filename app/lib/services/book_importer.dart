// CoEvo · 电子书导入 —— 解析 + 事务落库
//
// 🔴 设计约束：**本文件不 import 任何 Flutter 包**
//    只用 `dart:isolate` / `dart:typed_data` + `sqflite_common` 的**接口类型**
//    ⇒ 脚本可用 `sqflite_common_ffi` 驱动它独立验证（同 `book_db.dart` 的做法）。
//    ⚠️ 也正因如此，**id 生成器与时间戳由调用方注入**（见下）——
//       若在这里 `import 'package:uuid/uuid.dart'` 就破了这条约束。
//
// # 🔴 两条「不留半本书」的保证（设计文档 §9.5 要求）
//
// | 保证 | 怎么做到 |
// |---|---|
// | **解析失败 ⇒ 库里什么都没有** | 解析**完全在落库之前**；只有拿到 `BookDraft` 才开事务 |
// | **落库中途失败 ⇒ 一本都不留** | `book` 与全部 `book_chapter` 在**同一个事务**里（`db.transaction`）|
//
// 🔑 反例（不这么做会怎样）：先 `INSERT book` 再逐章插 —— 第 3 章出错时，
//    书库里就多了**一本只有 2 章的书**，而它看起来完全正常（用户不会知道少了 98 章）。
//    这类「看起来正常但内容是错的」比直接报错更难发现。
//
// # 为什么解析要走 Isolate
//
// 一本《战争与和平》约 3.3 MB —— 解压 + 解析 OPF + 分章在**主 isolate** 上跑
// 会让 UI 明显卡住（掉帧甚至 ANR）。
//
// 🔑 为什么**总是**走 Isolate（不做「小文件同步、大文件 isolate」的分支）：
//    · 导入是**低频**操作，用户点了就在等 ⇒ 几毫秒的 isolate 启动开销无所谓
//    · 而「分支」本身要维护一个阈值，还要**断言阈值两侧都对** —— 不划算
//    📌 判据：**当两条路的代价接近时，选「只有一条路」的那个**（少一个变量）。

import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';

import 'ebook/book_import_plan.dart';
import 'ebook/book_text.dart';
import 'ebook/epub_parser.dart';
import 'ebook/txt_parser.dart';

/// 导入结果 —— `sealed` 是为了让调用方的 `switch` **穷尽检查**
/// （用「返回 null + 另给 error 变量」的写法，靠的是调用方自觉）。
sealed class BookImportResult {
  const BookImportResult();
}

class BookImportSuccess extends BookImportResult {
  const BookImportSuccess({
    required this.bookId,
    required this.title,
    required this.chapterCount,
    required this.charCount,
  });

  /// 落库后的书 id（UI 用它跳转到阅读页）。
  final String bookId;
  final String title;
  final int chapterCount;
  final int charCount;
}

class BookImportFailure extends BookImportResult {
  const BookImportFailure(this.kind, this.detail);

  /// UI 据此给**不同的**文案（见 [EbookParseErrorKind] 的说明）。
  final EbookParseErrorKind kind;

  /// 供日志/排查（不直接展示给用户）。
  final String detail;
}

/// 按格式分派解析（**顶层函数** ⇒ 可作为 Isolate 的入口）。
///
/// ⚠️ 独立成顶层函数而不是内联在 `Isolate.run` 的闭包里：
///    闭包捕获哪些变量是**隐式**的，而顶层函数只接收显式参数
///    ⇒ 「跨 isolate 传了什么」一目了然（也只有两个可发送参数）。
EbookParseResult parseByFormat(Uint8List bytes, String fileName) {
  final format = pickFormat(fileName: fileName, bytes: bytes);
  return switch (format) {
    EbookFormat.epub => parseEpub(bytes, fileName: fileName),
    EbookFormat.txt => parseTxt(bytes, fileName: fileName),
  };
}

/// 导入一本书：解析 → 事务落库。
///
/// - [db]：已打开的 `book.db`（由 provider 提供，**本函数不负责开关连接**）
/// - [bytes]：文件原始字节
/// - [fileName]：原始文件名（落 `source_name`，也用于格式判定与兜底书名）
/// - [newId]：id 生成器 —— **注入**（端侧传 uuid v4；脚本传递增计数以便断言）
/// - [addedAt]：ISO8601 UTC 时刻 —— **注入**（同上）
///
/// 返回 [BookImportSuccess] / [BookImportFailure]，**不抛异常**：
/// 导入失败是**常态**（DRM、选错文件），不是异常情况 ——
/// 抛异常会逼调用方写 try/catch，而不同失败原因要给不同文案，
/// 那只能靠 `kind`（异常类型不适合承载 UI 文案）。
Future<BookImportResult> importBook({
  required Database db,
  required Uint8List bytes,
  required String fileName,
  required String Function() newId,
  required String addedAt,
}) async {
  // ── ① 入口体检（在解析之前）──
  //
  // 🔑 为什么体积检查放在**解析前**：把 50 MB 的垃圾送进 isolate 再发现超限，
  //    等于白付一次跨 isolate 拷贝 + 解压的代价。
  if (bytes.isEmpty) {
    return const BookImportFailure(EbookParseErrorKind.empty, '空文件（0 字节）');
  }
  if (bytes.length > kMaxEbookBytes) {
    return BookImportFailure(
      EbookParseErrorKind.tooLarge,
      '文件 ${bytes.length} 字节 > 上限 $kMaxEbookBytes',
    );
  }

  // ── ② 解析（走 Isolate）──
  final EbookParseResult parsed;
  try {
    parsed = await Isolate.run(() => parseByFormat(bytes, fileName));
  } catch (e) {
    // 解析器设计上**不抛异常**（用返回值表达失败）⇒ 走到这里说明是**意料之外**的错误
    // （OOM / 解析器 bug）。如实归到 `unknown` 并保留原始信息便于排查。
    return BookImportFailure(EbookParseErrorKind.unknown, '解析时抛出异常：$e');
  }

  return switch (parsed) {
    // 🔴 **必须是 `EbookParseFailure`（解析层的类型）**，不是本文件的 `BookImportFailure`。
    //    两者名字相近但完全不同：前者是「解析器报的失败」，后者是「导入的最终结果」。
    //    ⚠️ 初版就是写成了 `BookImportFailure(...)` —— 那是**本文件自己的类**，
    //      于是这个模式永远匹配不到 ⇒ 解析失败**掉进下面的成功分支**、
    //      然后拿一个没有 `book` 字段的对象去落库 ⇒ **解析失败被静默吞掉**。
    //    ✅ 抓到它的是 **Dart 的穷尽性检查**（`codestatic` 报「switch 不穷尽」）——
    //      这正是「用 `sealed` + `switch` 而不是「返回 null + 错误变量」」的价值：
    //      后者不会在**编译期**暴露这种错。
    EbookParseFailure(:final kind, :final detail) =>
      BookImportFailure(kind, detail),
    EbookParseSuccess(:final book) => await _persistBook(
        db: db,
        draft: book,
        fileName: fileName,
        newId: newId,
        addedAt: addedAt,
      ),
  };
}

/// 拿到 `BookDraft` 之后：检查章节数上限 → 生成计划 → 事务落库。
Future<BookImportResult> _persistBook({
  required Database db,
  required BookDraft draft,
  required String fileName,
  required String Function() newId,
  required String addedAt,
}) async {
  // 🔴 章节数上限：中文长篇极端情况能切出上万章 ⇒ 会让阅读页的章节列表爆炸。
  //    在**落库前**拦（同体积检查的理由）。
  if (draft.chapters.length > kMaxEbookChapters) {
    return BookImportFailure(
      EbookParseErrorKind.tooLarge,
      '章节数 ${draft.chapters.length} > 上限 $kMaxEbookChapters',
    );
  }

  final plan = buildImportPlan(
    draft: draft,
    fileName: fileName,
    addedAt: addedAt,
    newId: newId,
  );

  try {
    await _writePlan(db, plan);
  } catch (e) {
    return BookImportFailure(EbookParseErrorKind.unknown, '写库失败：$e');
  }

  return BookImportSuccess(
    bookId: plan.bookId,
    title: plan.title,
    chapterCount: plan.chapterCount,
    charCount: plan.charCount,
  );
}

/// 把计划写进库 —— **单事务**（见文件头「不留半本书」）。
///
/// ⚠️ 列名必须与 `assets/sql/book_db_schema.sql` **逐字一致**。
///    写错不会在编译期报错、只在运行时抛 `no such column` ⇒
///    由 `scripts/ebook_verify/bin/verify_book_importer_sql.dart` 做**源级比对**守住。
Future<void> _writePlan(Database db, BookImportPlan plan) async {
  await db.transaction((txn) async {
    await txn.insert('book', {
      'id': plan.bookId,
      'title': plan.title,
      'author': plan.author,
      'language': plan.language,
      'source_format': plan.sourceFormat,
      'source_name': plan.sourceName,
      'chapter_count': plan.chapterCount,
      'char_count': plan.charCount,
      'added_at': plan.addedAt,
    });

    // 🔑 用 `batch` 而不是 N 次 `insert`：sqflite 的 batch 把多条语句
    //    **合并成一次平台往返** —— 1000 章的书差别是「秒级 vs 毫秒级」。
    //    （仍在外层事务内 ⇒ 语义与逐条插完全相同。）
    final batch = txn.batch();
    for (final c in plan.chapters) {
      batch.insert('book_chapter', {
        'id': c.id,
        'book_id': plan.bookId,
        'idx': c.idx,
        'title': c.title,
        'text': c.text,
        'char_count': c.charCount,
      });
    }
    await batch.commit(noResult: true);
  });
}

// ══════════════════════════════════════════════════════════════════════════
// 本层**有意不做**的事（如实记录，避免后人以为漏了）
// ══════════════════════════════════════════════════════════════════════════
//
// ① **不写 `book_progress`** —— 进度在用户第一次打开书时才产生。
//    导入时预先插一条「第 0 章 0%」是**多条状态**（两个地方都说「进度在这」）。
//    阅读页用 `LEFT JOIN` / 缺行兜底即可。
// ② **不做重复导入拦截** —— 理由见 `book_import_plan.dart` 末尾那段（判据：
//    「误判」比「重复」更糟）。
// ③ **不解析封面图** —— 一期用标题首字占位（见设计文档 §4.2）。封面是图片，
//    解析它会把本层的依赖从「纯文本」扩到「图片解码」，不值。
