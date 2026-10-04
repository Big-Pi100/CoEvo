// 电子书导入 —— **落库计划**（零 import 纯 Dart）
//
// # 🔑 为什么把「落库」拆成「计划 + 执行」两步
//
// | 层 | 内容 | 能否本机验证 |
// |---|---|---|
// | **计划**（本文件） | `BookDraft` → 各表的**行数据** | ✅ **纯 Dart**，`dart run` 直接跑 |
// | 执行（`book_importer.dart`） | 把计划写进 `book.db`（事务） | ❌ 需 sqflite / 真机 |
//
// 判据：**把可验证的核心抽成零依赖**（本项目已记的方法论）。
// 落库正确性的**大头是我的映射逻辑**（字段对错了、章节序号断号了、计数不一致），
// 而「sqflite 的事务能不能提交」是**库的行为**、不是我的 —— 后者不该拖累前者可验证。
//
// ⚠️ 另有一条现实约束：本地 `flutter pub get` 不可用（Windows 管道耗尽），
//    若计划逻辑写在碰 sqflite 的文件里，**本机就完全验不了**。
//
// # 依赖注入：id 与时间戳都由调用方给
//
// 🔑 这样本文件才能**零 import**：
//   · 端侧传真实现（uuid v4 / `DateTime.now().toUtc()`）
//   · 断言传确定性实现（递增计数 / 固定时刻）⇒ **结果可逐字段比对**
// ⚠️ 若在这里自己调 `Uuid()`，就必须 import `uuid` ⇒ 本机验证立刻失去。

import 'dart:typed_data';

import 'book_text.dart';

/// 支持的输入格式。
///
/// ⚠️ `name` 恰好等于 `book.source_format` 的 CHECK 约束值（`'epub'` / `'txt'`）
///    —— 这是**有意**的：落库时直接用 `format.name`，不另做一层映射表
///    （多一层映射就多一个漂移点）。
enum EbookFormat { epub, txt }

/// 判定 zip 文件头（`PK\x03\x04`）。
///
/// 🔑 只查前两字节 `PK` 就够 —— 我们自己解压（`archive`），不依赖更细的版本号；
///    且**多查反而更脆**（空 zip / zip64 的头不一样，但都该交给 epub 解析器去报具体错）。
const int _kZipMagic0 = 0x50; // 'P'
const int _kZipMagic1 = 0x4B; // 'K'

/// 判断该按哪种格式解析。
///
/// # 🔑 判定优先级：**魔数 > 扩展名**（不是反过来）
///
/// | 情形 | 判定 | 为什么 |
/// |---|---|---|
/// | 前两字节是 `PK` | **epub** | 魔数不会骗人；扩展名会被用户改 |
/// | 不是 zip，但扩展名 `.epub` | **epub** | 让 epub 解析器报「这不是有效的 EPUB」—— **比当 txt 解析更贴用户预期**（用户以为是 epub） |
/// | 扩展名 `.txt` | txt | |
/// | 其它（含无扩展名） | **txt** | ✅ 兜底选 txt 而非报错：TXT 解析器有编码探测，**能兜住更多真实输入**（从「用 CoEvo 打开」来的文件常常没有扩展名） |
///
/// ⚠️ **返回 null 的情形不存在** —— 永远给出一个可尝试的格式。
///    理由：报错要**具体**（哪一步失败、为什么），而不是在门口就拒绝
///    （判据：**「静默失败 + 无出口」比「报错」更糟** —— 门口拒绝也是一种「无出口」）。
EbookFormat pickFormat({required String fileName, required Uint8List bytes}) {
  if (bytes.length >= 2 &&
      bytes[0] == _kZipMagic0 &&
      bytes[1] == _kZipMagic1) {
    return EbookFormat.epub;
  }

  final ext = fileExtension(fileName);
  if (ext == 'epub') return EbookFormat.epub;
  return EbookFormat.txt;
}

/// 取小写扩展名（**不含点**）；无扩展名返回空串。
///
/// 处理三种常见形态：
///   · `a/b/foo.EPUB` → `epub`
///   · `foo`       → ``（无扩展名）
///   · `.gitignore` → ``（**前导点不算扩展名** —— 它不是「扩展名为 gitignore 的文件」）
String fileExtension(String fileName) {
  // 先剥目录（`/` 与 `\` 都要处理：iOS 路径用前者，Windows 拷贝过来可能是后者）
  final slash = fileName.lastIndexOf('/');
  final backslash = fileName.lastIndexOf(r'\');
  final cut = slash > backslash ? slash : backslash;
  final base = cut >= 0 ? fileName.substring(cut + 1) : fileName;

  final dot = base.lastIndexOf('.');
  // `dot <= 0`：无点，或点在第 0 位（隐藏文件，无扩展名）
  if (dot <= 0) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 一本书的落库计划 —— 直接对应 `book` 表的**一行**。
///
/// 🔑 字段与 `book_db_schema.sql` **逐一对齐**（列名一致、顺序一致）——
///    这样 `book_importer.dart` 只需把这里念一遍，不做二次加工。
class BookImportPlan {
  const BookImportPlan({
    required this.bookId,
    required this.title,
    required this.author,
    required this.language,
    required this.sourceFormat,
    required this.sourceName,
    required this.chapterCount,
    required this.charCount,
    required this.addedAt,
    required this.chapters,
  });

  final String bookId;
  final String title;

  /// 可为 null（TXT 通常没有作者信息）。
  final String? author;
  final String? language;

  /// `'epub'` | `'txt'` —— 取自 [EbookFormat.name]。
  final String sourceFormat;

  /// 原始文件名 —— 让用户在书库里认出「这是哪来的」。
  final String? sourceName;

  final int chapterCount;
  final int charCount;

  /// ISO8601 UTC。
  final String addedAt;

  final List<ChapterRow> chapters;
}

/// 一章的落库行 —— 对应 `book_chapter` 表的一行。
class ChapterRow {
  const ChapterRow({
    required this.id,
    required this.idx,
    required this.title,
    required this.text,
  });

  final String id;

  /// 章序，**0-based**（与 schema 注释一致）。
  final int idx;
  final String? title;
  final String text;

  /// 与 `book_chapter.char_count` 对齐。
  int get charCount => text.length;
}

/// 把解析产出转成落库计划（**纯函数**）。
///
/// - [draft]：解析器的产出（见 `book_text.dart`）
/// - [fileName]：原始文件名（落 `source_name`；空串/全空白 ⇒ 落 null）
/// - [addedAt]：ISO8601 UTC 时刻（**注入**，见文件头说明）
/// - [newId]：id 生成器（**注入**；端侧传 uuid v4，断言传递增计数）
///
/// # 三条一致性保证（都在断言里守着）
///
/// ① `chapters` 的 `idx` **必然是 0..n-1 连续**（不是「看起来连续」）——
///    阅读页靠 `idx` 取章 ⇒ 断号会让「下一章」跳到空白。
/// ② `chapterCount == chapters.length`，`charCount == 各章之和` ——
///    这两个值会被书库列表用来显示「多少章」，不一致就是**显示假数据**。
/// ③ 每章的 `charCount` 由 `text.length` 现算，**不由调用方传**
///    ⇒ 消掉「传进来的数」与「实际文本长度」对不上的可能。
BookImportPlan buildImportPlan({
  required BookDraft draft,
  required String fileName,
  required String addedAt,
  required String Function() newId,
}) {
  final rows = <ChapterRow>[];
  for (var i = 0; i < draft.chapters.length; i++) {
    final c = draft.chapters[i];
    rows.add(ChapterRow(
      id: newId(),
      // 🔑 用**循环下标**而不是「上一个的 idx + 1」——
      //    后者在首项上要先判空，且中间任何一次算错会**一路错到底**。
      idx: i,
      title: c.title,
      text: c.text,
    ));
  }

  final trimmedName = fileName.trim();

  return BookImportPlan(
    bookId: newId(),
    title: draft.title,
    author: draft.author,
    language: draft.language,
    sourceFormat: draft.sourceFormat,
    sourceName: trimmedName.isEmpty ? null : trimmedName,
    chapterCount: rows.length,
    charCount: rows.fold(0, (a, r) => a + r.charCount),
    addedAt: addedAt,
    chapters: rows,
  );
}

// ══════════════════════════════════════════════════════════════════════════
// 重复导入的判定 —— 🔴 **一期不做拦截**（刻意）
// ══════════════════════════════════════════════════════════════════════════
//
// 用户可能重复导入同一本书（点两次导入、或从两个入口各导一次）。
// 我们**不做去重**，理由：
//
// | 方案 | 代价 |
// |---|---|
// | 按内容 hash 去重 | 需引入 `crypto`；且**不同来源的同一本书 hash 必然不同** ⇒ 拦不住真正的情况 |
// | 按「书名 + 作者」去重 | 🔴 **会误判**：同名的不同译本 / 不同版本是**合法的两本书** ⇒ 用户会困惑「为什么导不进去」 |
// | **不拦（本方案）** | 列表里可能出现两本一样的书 ⇒ 用户**滑删**即可 |
//
// 🔑 判据：**「误判」比「重复」更糟** ——
//    重复是**可见且可自行修复**的（就在列表里，滑一下就删）；
//    误判是**不可见且无出口**的（用户不知道被拦了、也不知道怎么绕过）。
//    ⇒ 这与本项目那条「**「静默失败 + 无出口」比「报错」更糟**」同源。
//
// ⏳ 若真机试用后「重复」确实烦人，再加**非阻塞提示**
//    （不阻止落库，只在导入完成时提示「这本书可能已经导过了」）——
//    那时它是**信息**而不是**拦截**，不会产生上面的「无出口」问题。
