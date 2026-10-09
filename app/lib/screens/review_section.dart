// CoEvo · 「复习」tab 的两段（**零 import 纯 Dart** ⇒ 本机可断言、可进 CI）
//
// # 这是什么（2026-10-08 白哥定案）
//
// 导航第二个 tab 是「复习」，它内部现在有**两个平级视图**：
//
// | 段 | 标题 | 内容 |
// |---|---|---|
// | [ReviewSection.review] | `复习` | 待复习列表（原「复习」页）|
// | [ReviewSection.notes] | `笔记` | 我的划线（**原顶层路由 `/highlights`**）|
//
// 白哥原话：
// > 「把『我的划线』移动到复习页面，名称改为『笔记』与『复习』同级，
// >  就像阅读页面有『今日精选』和『书架』两个同级页面一样」
//
// 🔴 **这不是新发明的形态** —— 它与「阅读」tab 的 `ReadingSection` 是**同一个模式**
//    （见 `reading_section.dart`：标题级双 Tab + `IndexedStack`）。
//    ⇒ 两个 tab 的段定义刻意保持同构，`verify_review_tab.dart` 会交叉核对这一点。
//
// # 🔴 为什么「笔记」而不是「我的划线」
//
// 「我的划线」是**实现视角**（我们存的是高亮区间）；用户做的事是**记笔记**
// （划线只是他记账的方式）。同一件事的措辞应当描述**用户的动作**，不是**我们的存储**。
// ⚠️ 技术标识（表名 `highlight` / 路由参数 / 文件名）**不改** ——
//    那只影响内部，改它的成本远大于收益（同「书库→书架」那次）。
//
// # 顺序为什么是「复习」在前
//
// 🔑 与阅读 tab 同一条规则：**默认段写在最前**（那是点进这个 tab 时想做的事）。
//    阅读 tab 默认「今日精选」（内容），复习 tab 默认「复习」（这个 tab 的职责）。
//
// ⚠️ 本文件**不 import Flutter**、不放任何 Widget —— 布局归 `review_tab_screen.dart`。
//    同 `reading_section.dart` 的判据：**把「可独立验证的核心」抽成零依赖。**

/// 「复习」tab 内的两个平级视图。
///
/// ⚠️ 声明顺序 = 屏幕上从左到右的顺序，也是 [ReviewSectionX.stackIndex] 的依据
///    （`Enum.index` 内建，按声明顺序 0-based）—— **不要重排**：
///    `IndexedStack` 靠它选孩子，重排会让「点笔记却显示复习」。
enum ReviewSection {
  /// 待复习列表（默认段）。
  review,

  /// 笔记（我的划线）。
  notes,
}

/// [ReviewSection] 的展示属性。
extension ReviewSectionX on ReviewSection {
  /// 标题栏上显示的文案 —— **23px 标题级的那个字**。
  ///
  /// 🔴 改这里**必须同步改** `verify_review_tab.dart` 的集合断言 ——
  ///    否则 CI 会红（断言锁着这两个字面量，这正是它存在的意义）。
  String get title => switch (this) {
        ReviewSection.review => '复习',
        ReviewSection.notes => '笔记',
      };

  /// 供 `IndexedStack` 用的下标 —— 等价于 `Enum.index`，此处只是显式化意图。
  int get stackIndex => switch (this) {
        ReviewSection.review => 0,
        ReviewSection.notes => 1,
      };

  /// 另一段 —— 用于「切换」。
  ReviewSection get other => switch (this) {
        ReviewSection.review => ReviewSection.notes,
        ReviewSection.notes => ReviewSection.review,
      };
}
