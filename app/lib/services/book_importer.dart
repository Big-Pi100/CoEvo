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

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'ebook/book_raw_store.dart';

import 'ebook/book_import_plan.dart';
import 'ebook/book_progress_sync.dart';
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
  /// 🆕 原始文件的保存目录（`null` ⇒ 不保存）。
  ///
  /// 🔴 为什么要保存：**上传云端需要原始文件**，而解析后的章节**拼不回去**
  ///    （epub 的 zip 结构 / manifest / spine 都在解析时丢了）；
  ///    设计稿的「换机后复用端侧解析器」同样需要它。
  ///    📄 理由与路径规则见 `book_raw_store.dart`。
  ///
  /// ⚠️ 目录由**调用方**提供（Flutter 侧用 `path_provider`）——
  ///    本文件是零 Flutter 依赖的，不能自己去问平台要目录。
  String? rawDir,
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

  // ── ② 解析 + 内容指纹（**合并进同一个 Isolate**）──
  //
  // 🔑 为什么把两者合在一个 `Isolate.run` 里：它们都要读 `bytes` ——
  //    分两次调用会让一个 50 MB 的 `Uint8List` **跨 isolate 拷贝两次**
  //    （`Isolate.run` 的入参按值传递）。合并后只拷一次，
  //    返回值只是个 record（`parsed` + 一个 64 字符的 hex）⇒ 几乎无成本。
  //
  // 🔑 指纹**必须**在 isolate 里算：50 MB 的 sha256 约 **100–200 ms**，
  //    放主 isolate 会卡住 UI（导入虽是用户主动触发，卡顿仍不可接受）。
  //
  // ⚠️ 指纹是**跨设备身份**，**不是**「重复导入去重」——
  //    两者的判据**相反**（身份要「同文件必同值」，去重要「不同书必不同值」），
  //    见 `ebook/book_import_plan.dart` 文件尾那一节。
  final ({EbookParseResult parsed, String hash}) work;
  try {
    work = await Isolate.run(() => (
          parsed: parseByFormat(bytes, fileName),
          hash: sha256.convert(bytes).toString(),
        ));
  } catch (e) {
    // 解析器设计上**不抛异常**（用返回值表达失败）⇒ 走到这里说明是**意料之外**的错误
    // （OOM / 解析器 bug）。如实归到 `unknown` 并保留原始信息便于排查。
    return BookImportFailure(EbookParseErrorKind.unknown, '解析时抛出异常：$e');
  }
  final parsed = work.parsed;

  final result = switch (parsed) {
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
        contentHash: work.hash,
      ),
  };

  // 🆕 落库**成功之后**才保存原始文件 —— 顺序理由：
  //    先存文件再落库，落库失败会留下一份「没有书对应它」的孤儿文件；
  //    反过来最坏只是「有书、没原始文件」，而那**能自愈**
  //    （重新导入同一本书会把它补上，`content_hash` 相同 ⇒ 覆盖同一路径）。
  //
  // ⚠️ **失败静默**：书已经能读了；没有原始文件只影响「能不能上传 / 换机复用」，
  //    由**上传队列**在真正需要时给出可解释的提示 —— 在导入这一步报错会打扰用户，
  //    而他此刻并不能做什么（重导一次大概率还是同样的结果）。
  if (result is BookImportSuccess && rawDir != null && parsed is EbookParseSuccess) {
    try {
      await saveRawBook(
        rawDir: rawDir,
        contentHash: work.hash,
        // 🔑 用解析出来的 `sourceFormat`（'epub'/'txt'）而不是文件名后缀 ——
        //    它与 `book.source_format` 同源，也与后端的 `is_valid_ext` 白名单一致。
        ext: parsed.book.sourceFormat,
        bytes: bytes,
      );
    } catch (_) {
      // 见上：静默（由上传队列在需要时提示）
    }
  }

  return result;
}

/// 拿到 `BookDraft` 之后：检查章节数上限 → 生成计划 → 事务落库。
Future<BookImportResult> _persistBook({
  required Database db,
  required BookDraft draft,
  required String fileName,
  required String Function() newId,
  required String addedAt,
  /// 🆕 内容指纹（见 `importBook` 里算它的那段注释）。
  required String contentHash,
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
    contentHash: contentHash,
  );

  try {
    await _writePlan(db, plan);
  } catch (e) {
    return BookImportFailure(EbookParseErrorKind.unknown, '写库失败：$e');
  }

  // 🆕 2026-10-06 · 跨设备续读：**认领**这本书的待认领进度。
  //
  // 场景：在另一台设备读到第 9 章 ⇒ 那台的进度已推到服务端 ⇒ 本机 pull 时
  // 按**指纹**存进 `book_progress_pending`（那时本机还没这本书）⇒ 现在导入
  // 同一本书（指纹相同）⇒ 把进度取过来，用户直接续读。
  //
  // 🔑 放在这个函数里（而不是「导入流程的调用方」）：
  //    它是**唯一的落库出口** ⇒ 不会漏（本项目已多次踩「多入口 ⇒ 漏一处」）。
  //
  // ⚠️ **失败可以静默**（不是「吞掉问题」）：
  //    书已经落库成功（本函数的主要职责已完成）；认领失败**什么都不丢**
  //    —— `pending` 行还在，下次 pull 后的批量认领会再试一次（自愈）。
  //    而本文件**零 Flutter 依赖**（不能用 `debugPrint`）⇒ 不在这里记日志。
  try {
    await claimPendingForBook(db, bookId: plan.bookId);
  } catch (_) {
    // 见上：失败自愈（pending 行未删，下次 pull 重试）
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
      // 🆕 内容指纹 —— ⚠️ 与 schema 的**列顺序一致**（它在末尾）
      'content_hash': plan.contentHash,
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
