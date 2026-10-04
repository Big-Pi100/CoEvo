// 电子书导入 —— **失败文案**（零 import 纯 Dart）
//
// 🔑 为什么单独成文件、且不 import Flutter：
//    它是「**按失败类别给不同文案**」这条规则本身，可以被断言守住 ——
//    而「每个类别都有文案」与「不同类别文案不能一样」这两条
//    **一旦破了，UI 就退化成一个无用的通用错误**（判据：
//    「**静默失败 + 无出口**」比「报错」更糟 —— 通用错误就是「有出口的假象」）。
//
// ⚠️ 放进 `book_text.dart` 会更省一个文件，但那会让「解析结果类型」与「UI 文案」
//    耦合在一次 —— 文案是**展示层**的事，解析器不该知道怎么措辞。
//    独立文件也让断言能**只 import 文案**（不必连带解析器）。

import 'book_text.dart';

/// 给定失败类别，返回给**用户看**的一句话。
///
/// # 三条硬要求（都有断言守）
///
/// ① **穷尽**：`switch` 不写 `default` ⇒ 将来给 `EbookParseErrorKind`
///    加一个枚举值时，**编译期**就会在这里报错（而不是运行时显示空白）。
/// ② **可操作**：告诉用户**下一步做什么**，不只说「失败了」。
/// ③ **互不相同**：DRM 与「编码不识别」的**原因完全不同**，
///    文案必须不同 —— 否则用户会去折腾转码，而真正的问题是「这本书加密了」。
String bookImportFailureMessage(EbookParseErrorKind kind) => switch (kind) {
      // 🔴 最高频的一类：多数商业电子书都带 DRM。
      //    必须**解释原因 + 给替代来源** —— 只说「导入失败」用户会以为 App 坏了。
      EbookParseErrorKind.drmProtected =>
        '这本书受 DRM 保护，技术无法解析。\n'
            '请改用无 DRM 的 EPUB 文件（例如 Project Gutenberg 的公版书）。',

      EbookParseErrorKind.notEpub => '这不是有效的 EPUB 文件。\n'
          '请确认文件没有损坏，或者改用 TXT。',

      EbookParseErrorKind.brokenEpub => '这个 EPUB 的文件结构不完整，无法读取。',

      EbookParseErrorKind.empty => '文件里没有可读的正文。',

      // 体积 / 章节数两个上限合并一句 —— 对用户来说都是「太大了」，
      // 区分它们只有排查价值（细节在日志里）。
      EbookParseErrorKind.tooLarge => '文件太大，超出了可导入的上限。',

      // 🔑 给**可执行**的指引（转成 UTF-8），不是一句「编码错误」。
      EbookParseErrorKind.unknownEncoding =>
        '无法识别文件的文字编码。\n请用记事本把它另存为 UTF-8 编码后再导入。',

      EbookParseErrorKind.unknown => '导入失败，请稍后重试。',
    };
