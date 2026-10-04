// CoEvo · 「阅读」tab 的两段（**零 import 纯 Dart** ⇒ 本机可断言、可进 CI）
//
// # 这是什么
//
// 导航第一个 tab 是「阅读」，它内部有**两个平级视图**：
//
// | 段 | 标题 | 右侧动作 |
// |---|---|---|
// | [ReadingSection.feed] | `今日精选`（信息流）| 「收藏 N」药丸 |
// | [ReadingSection.books] | `书库` | 「导入」 |
//
// 🔴 **2026-10-04 白哥定案**（原话）：
// > 「书库与今日精选是**平级的页面**，入口不是一个下方的按钮而是与『今日精选』
// >  **title 平级**，你应该给我设计稿再做，而不是直接做」
//
// 上一版把入口做成了标题栏**下方**的一条淡色按钮 —— 层级读作「标题的下属」，
// 且白占信息流一行。⇒ 改为**标题级双 Tab**（设计稿
// `docs/design/book-library-entry-placement-2026-10-04.html` 方案 A）。
//
// # 🔑 为什么标题文案（而不是像素）放在这里、并让它可断言
//
// 「标题用『书库』还是『我的书库』」是**产品决定**，不是布局细节 ——
// 白哥 2026-10-04 定为 **2 字「书库」**：4 字标题与「今日精选」并排时，
// 两个 23px 标题会挤满一行，右侧动作没有落脚处。
//
// 这类「决定过的事实」最容易在后续迭代里被悄悄改回去（改的人不一定知道它定过）。
// 而纯 Dart 定义**能被断言守住**（`scripts/ebook_verify/bin/verify_reading_tab.dart`）：
//   ① 两段的标题必须**恰好**是 {`今日精选`, `书库`}（集合相等，不是「包含」）
//   ② `books` 的标题长度 = 2（防回退到「我的书库」）
// ⇒ 📌 判据：**能落成常量的产品决定，就别让它散在 UI 代码的字符串字面量里。**
//
// ⚠️ 本文件**不 import Flutter**，也不放任何 Widget ——
//    布局归 `reading_tab_screen.dart`（那要 import Flutter，本机验不了，靠 CI）。
//    这与 `services/ebook/book_import_plan.dart` 的分层同一条判据：
//    **把「可独立验证的核心」抽成零依赖，Widget 只做摆放。**

/// 「阅读」tab 内的两个平级视图。
///
/// ⚠️ 声明顺序 = 屏幕上从左到右的顺序，也是 [ReadingSectionX.index] 的依据
///    （`Enum.index` 内建，按声明顺序 0-based）—— **不要重排**：
///    `IndexedStack` 靠它选孩子，重排会让「点书库却显示信息流」。
enum ReadingSection {
  /// 信息流（默认段）。
  feed,

  /// 书库（用户导入的 EPUB / TXT）。
  books,
}

/// [ReadingSection] 的展示属性。
extension ReadingSectionX on ReadingSection {
  /// 标题栏上显示的文案 —— **23px 标题级的那个字**。
  ///
  /// 🔑 与「屏幕上说给用户听的名字」一致：`feed` 段沿用 `今日精选`（原设计稿
  /// `visual-feed-bookmark` 的 `.feed-hd h2`），`books` 段用 **2 字** `书库`。
  String get title => switch (this) {
        ReadingSection.feed => '今日精选',
        ReadingSection.books => '书库',
      };

  /// 供 `IndexedStack` 用的下标 —— **等价于 `Enum.index`**，此处只是显式化意图
  /// （避免将来有人以为「按 title 排序」之类）。
  int get stackIndex => switch (this) {
        ReadingSection.feed => 0,
        ReadingSection.books => 1,
      };

  /// 另一段 —— 用于「切换」。
  ReadingSection get other => switch (this) {
        ReadingSection.feed => ReadingSection.books,
        ReadingSection.books => ReadingSection.feed,
      };
}
