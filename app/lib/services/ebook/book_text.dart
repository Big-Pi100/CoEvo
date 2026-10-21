// 电子书导入 —— 解析层的共享模型与结果类型
//
// 🔴 **本文件零 import**（除 `dart:typed_data`）。
//   理由：本地 `flutter` 命令建不了子进程（Windows 管道耗尽），
//   但 `dart run` 可用 ⇒ **零 import 才能写本机真断言**
//   （与 `services/iap_plan.dart` 同一套既已验证的做法）。
//
// # 为什么「解析结果」是一个显式类型而不是抛异常
//
// 导入失败**不是异常情况，是常态**（实测：多数商业电子书带 DRM、用户可能选错文件）。
// 而且不同失败原因要给**完全不同的提示**：
//   · DRM     → 「这本书受 DRM 保护」（并引导去公版书站）
//   · 不是 zip → 「这不是有效的 EPUB 文件」
//   · 编码     → 「请把文件转成 UTF-8」
// ⇒ 若只抛一个 `Exception('解析失败')`，UI 层就只能显示一句无用的通用错误
//   —— 这违反项目已记的判据：「**「静默失败 + 无出口」比「报错」更糟**」。

/// 解析失败的类别。**每一类都要有对应的、可操作的 UI 文案**。
enum EbookParseErrorKind {
  /// 不是有效的 EPUB（不是 zip / zip 损坏）。
  notEpub,

  /// 是 zip，但 EPUB 结构不完整（缺 `META-INF/container.xml` 或 OPF）。
  brokenEpub,

  /// 🔴 **受 DRM 保护** —— 实测中**最高频**的失败原因。
  ///
  /// 绝大多数商业付费电子书都带 DRM（Adobe ADEPT / Apple FairPlay / Kindle 等），
  /// **技术上无法解析**。单列一类是因为它的 UI 必须是「解释原因 + 给替代来源」，
  /// 而不是「导入失败」—— 后者会让用户以为 App 坏了。
  drmProtected,

  /// 解析出来没有任何正文（空文件 / 全空白）。
  empty,

  /// 体积超限（见 `kMaxEbookBytes`）。
  tooLarge,

  /// 编码无法识别（当前只支持 UTF-8；检测到 GBK 等会走到这里）。
  unknownEncoding,

  /// 其它未归类的异常（兜底 —— 保留原始信息便于排查）。
  unknown,
}

/// 一本书的「草稿」—— 解析产出、尚未落库。
///
/// 🔑 为什么叫 Draft：它**没有 id**（id 由落库层生成），
///    且**不持有 DB 连接** ⇒ 纯数据，可跨 Isolate 传递。
class BookDraft {
  const BookDraft({
    required this.title,
    required this.author,
    required this.language,
    required this.sourceFormat,
    required this.chapters,
  });

  final String title;
  final String? author;
  final String? language;

  /// `'epub'` | `'txt'`（与 `book.source_format` 的 CHECK 约束一致）。
  final String sourceFormat;

  /// 章节列表，**顺序即阅读顺序**（EPUB 按 spine；TXT 按解析顺序）。
  final List<ChapterDraft> chapters;

  /// 全书字符数（落库时写入 `book.char_count`）。
  int get charCount => chapters.fold(0, (a, c) => a + c.charCount);
}

/// 一章的草稿。
class ChapterDraft {
  const ChapterDraft({required this.title, required this.text});

  /// 章节标题。可能为 null（TXT 无章节标记且未识别出小标题时）。
  final String? title;

  final String text;

  int get charCount => text.length;
}

/// 解析结果（成功 / 失败二选一）。
///
/// 用 `sealed` 而不是「返回 null + 另给一个 error 变量」：
/// 前者能让 `switch` **穷尽检查**，后者靠调用方自觉。
sealed class EbookParseResult {
  const EbookParseResult();
}

class EbookParseSuccess extends EbookParseResult {
  const EbookParseSuccess(this.book);
  final BookDraft book;
}

class EbookParseFailure extends EbookParseResult {
  const EbookParseFailure(this.kind, this.detail);

  final EbookParseErrorKind kind;

  /// 供**日志/排查**用的细节（不直接展示给用户 —— 用户看得懂的是 [kind] 对应的文案）。
  final String detail;
}

/// 单文件体积上限。
///
/// 🔑 依据：正常英文小说 < 5 MB（*War and Peace* 约 3.3 MB）；
///    **图片版 / 扫描版 / 漫画** EPUB 常在 30–80 MB ⇒ 取 50 MB。
///    再大就视为异常输入（防止用户误选视频/压缩包导致 OOM）。
///
/// 🔴 **必须与后端 `MAX_BOOK_BYTES` 同值**（2026-10-21 由 32 MB 提到 50 MB）。
///    端侧大于后端 ⇒ 书能导入却**永远传不上去**，且报错方向是错的（见
///    `book_blob_parse.dart::kMaxBookBytes` 的长说明）。
///    📌 断言：`scripts/ebook_verify/bin/verify_book_limits.dart`
const int kMaxEbookBytes = 50 * 1024 * 1024;

/// 单个文件的章节数上限（中文长篇小说极端情况）。
const int kMaxEbookChapters = 2000;

/// TXT 无章节标记时的切片大小（字符数）。
///
/// 🔑 为什么是 8000：约等于 1300 英文词 / 4000 汉字 ——
///    单章滚动长度适中（不至于一屏就到底，也不至于滚不到头）。
///    切片**尽量落在段落边界**（见 `txt_parser.dart`）。
const int kTxtFallbackChapterChars = 8000;
