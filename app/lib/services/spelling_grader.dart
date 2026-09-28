// CoEvo · 拼写判定 —— 「看释义拼词」的对错判断
//
// 🔴 设计约束：**本文件不得 import 任何 Flutter 包**（同 `user_db.dart` /
//    `review_list_query.dart` 的理由）→ 纯 Dart 才能本地独立验证
//    （见 `scripts/query_verify/bin/verify_spelling_grader.dart`）。
//
// # 依据（白哥 2026-09-28 定）
// > 「这四个按钮没有用，还是要用**考试**（单纯的拼写考核即可）」
//
// 于是 FSRS 的**评分输入**从「用户自评四档」改为「**拼写对错**」：
//   拼对 → `good`（记得）｜拼错 → `again`（忘了）
//
// 🔑 为什么这是**升级**而不是「换一种做法」：
//   自评**不可验证**（用户觉得「记得」可能根本没记住）；
//   拼写结果是**事实** → 喂给 FSRS 的信号质量更高。
//   而 FSRS 本身（官方 `fsrs 2.0.1`，FSRS-6）不变 —— 只是输入更可靠了。
//
// # ⚠️ 与项目既有约定的关系（我核实过，不是推测）
// | 文档 | 说法 |
// |---|---|
// | `v1-final-design-authoritative`（**L0**） | 🔴 **完全没提评分方式**（搜「考核/验证/测试/自评/评分/出题/答题」均 0 命中） |
// | `visual-word-card-target`（**L1**） | 「翻卡 → **自评四档** → 自动下一张」← 本次决策**取代**它（已在设计稿加修正标注） |
//
// → 所以本改动**不违反 L0**；L1 的设计稿已同步标注。

import 'fsrs_service.dart' show ReviewRating;

/// 归一化拼写输入 —— **只处理「输入卫生」，不碰「拼写内容」**。
///
/// # 这里做的三件事，为什么都不算「放宽判定」
/// | 处理 | 为什么不算放宽 |
/// |---|---|
/// | 去首尾空白 | 用户不该因为**多按一个空格**被判错 —— 那不是拼写能力 |
/// | 统一小写 | 🔑 **词库自身就是 `COLLATE NOCASE`**（`word.spelling` / `card_review_state.spelling` 同）→ 大小写**本来就不参与词的同一性**；且 `USA` vs `usa` 不是「会不会这个词」的判据 |
/// | 全角→半角 | 🔴 **目标用户是中文母语者**：中文输入法下极易打出全角 `ａ` `．` `－` 与全角空格 `U+3000`。那些是**输入法变体**，不是另一种拼法 —— 不归一化会让中文用户被**系统性误判**（用户明明会，却被记成「忘了」→ **污染 FSRS 数据**） |
///
/// # 🔴 这里**不做**的事（白哥选了「严格」，以下一律**不宽容**）
/// · 连字符 ↔ 空格（`bad-tempered` ≠ `bad tempered`）
/// · 句点可省（`a.m.` ≠ `am`）← 词库里就是这样区分的
/// · 重音符可省（`café` ≠ `cafe`）
/// · 内部多余空格（`according  to` 两个空格 → 判错）
///
/// ⚠️ **实测后果（`verify_spelling_grader.dart` 用真库全量跑）**：
///    词库里 **218 个词**含空格/连字符/句点/撇号，**3 个**含非 ASCII。
///    严格规则下这些词必须一字不差 —— 这是**白哥明确选择的后果**，
///    不是 bug。若日后发现误判代价太高，改这一个函数即可（全库只有这一处判定）。
String normalizeSpelling(String s) {
  final buf = StringBuffer();
  for (final r in s.trim().runes) {
    var c = r;
    // 全角 ASCII（U+FF01–U+FF5E）→ 半角（U+0021–U+007E）：偏移 0xFEE0
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    // 全角空格 U+3000 → 半角空格
    if (c == 0x3000) c = 0x20;
    buf.writeCharCode(c);
  }
  return buf.toString().toLowerCase();
}

/// 判定一次拼写：`input` 是用户输入，`expected` 是词条的权威拼写。
bool gradeSpelling(String input, String expected) =>
    normalizeSpelling(input) == normalizeSpelling(expected);

/// **判定结果 → FSRS 档位**（白哥 2026-09-28 定：2 档）。
///
/// | 结果 | 档位 | 语义 |
/// |---|---|---|
/// | 拼对 | [ReviewRating.good] | 「记得」—— `good` 会让下次间隔按稳定度增长 |
/// | 拼错 | [ReviewRating.again] | 「忘了」—— `again` 会掉进 `relearning` 重学步 |
///
/// # 🔴 为什么只有两档（`hard` / `easy` 用不到）
/// 拼写只有「对 / 错」两种客观结果 —— 没有可靠的第三方信号能区分
/// 「拼得又快又好」与「勉强拼对」。
///
/// ⚠️ **已知影响（如实标注）**：`hard` / `easy` 两个分支在数据上
/// **永远不会被走到** → FSRS 的对应权重不参与更新。
/// 🔑 这**不影响算法正确性**（FSRS 支持只使用部分档位），
///    但意味着「间隔增长曲线」会比四档用法**更保守**
///    （缺少 `easy` 带来的加速）。
///    若日后要恢复「快 → easy」，信号来源应是**答题用时**，
///    而不是回头让用户自评 —— 那会退回本次要解决的问题。
ReviewRating ratingForSpelling({required bool correct}) =>
    correct ? ReviewRating.good : ReviewRating.again;
