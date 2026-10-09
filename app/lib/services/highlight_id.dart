// CoEvo · 划线记忆的**合成 id** —— 让一条划线直接进现有 FSRS 复习队列（纯 Dart · 零 import）
//
// # 🔑 它解决什么
// 划线要「进记忆队列」，而队列的主键是 `card_review_state.word_id`（TEXT）。
// 一条划线不是词 —— 但只要**给它一个稳定的 id**，它就能**复用整条既有链**：
//   `card_review_state` → `ReviewListQuery.list()` → FSRS 调度 → 复习页
// ⇒ **一行表结构都不用改**（与 `external_word_id.dart` 完全同一条思路）。
//
// | 来源 | `word_id` 形态 |
// |---|---|
// | 词库内 | `w0xxxxx`（真主键）|
// | 词库外 | `ext:brainstorm`（`external_word_id.dart`）|
// | 🆕 **划线** | **`hl:<uuid>`**（本文件）|
//
// 🔑 **前缀不冲突**：`w` / `ext:` / `hl:` 三者首字符/前缀天然隔离。
//    ⚠️ 所以**任何对 `word_id` 做形态判断的地方都必须先问本文件的 `isHighlightWordId`** ——
//    典型误用：`id.startsWith('w')` 假设 id 只有词库一种来源（`external_word_id` 已记过同类坑）。
//
// # 🔴🔴 为什么 id 是 **uuid** 而不是「本地自增 rowid」
//
// 「`hl:1` / `hl:2` …」在**单设备上**完全够用，但**同步一定会撞**：
// 两台设备各自从 1 开始 ⇒ 第二台推上来的 `hl:1` 会覆盖第一台。
//
// 🔴 而**修法代价是不可逆的**：`word_id` 会被**抄进两份用户数据** ——
//    `card_review_state`（复习进度）与 `review_log`（历史）——
//    将来改 id 形态意味着**迁移已存在的用户数据**。
//    📌 判据：**「将来要改的成本」要在选型时算，不能等撞上再说**。
//
// ⇒ 一开始就用**客户端生成的 uuid v4**（与 `book.id` 同一做法，见 `book_import_flow.dart`）。
//
// # 🔑 生成器**不由本文件提供**（与 `book_import_plan.dart` 同一条约束）
// 本文件**零 import** ⇒ 本机可独立验证。
// uuid 的生成在**调用方**（端侧 `const Uuid().v4`；断言传确定性计数）——
// 若在这里 `import 'package:uuid/uuid.dart'`，这条约束立刻失效。
//
// ⚠️ 本文件不得 import **任何东西**（含 `package:flutter`）。

/// 划线合成 id 的前缀。
///
/// 🔑 选 `hl:`（highlight）的理由与 `ext:` 同：**短**、**一眼可辨**、**与真 id 天然隔离**。
const String kHighlightIdPrefix = 'hl:';

/// 归一化作 uuid —— **只折叠大小写**。
///
/// 🔑 归一化在这里是**判等的一部分**，不是格式化：
/// `word_id` 在 `user.db` 是**字符串主键**（`UNIQUE(word_id)`），**不经过任何 collation 归一**。
/// ⇒ 若不做，`hl:AB12…` 与 `hl:ab12…` 会是**两个 id** ⇒
/// 同一条划线在队列里出现两行，而且 **`UNIQUE(word_id)` 拦不住**
/// （它约束的是「同一个 id 只能一行」，而这是两个不同 id）。
/// （同 `external_word_id.dart` 的说明。）
String normalizeHighlightUuid(String uuid) => uuid.trim().toLowerCase();

/// 一条划线的 uuid → 复习队列用的 `word_id`。
///
/// ⚠️ **只接受非空输入**：空串会产出 `hl:`（前缀本身）—— 一个**合法但无意义**的 id，
///    存进去就再也查不出是哪条划线了。断言拦掉（调用方本不该传空）。
String highlightWordId(String uuid) {
  final u = normalizeHighlightUuid(uuid);
  assert(u.isNotEmpty, '划线的 uuid 不能为空（会产出无意义的 `$kHighlightIdPrefix`）');
  return '$kHighlightIdPrefix$u';
}

/// 是不是划线卡的 id。
///
/// 🔑 **凡是要对 `word_id` 做「形态判断」的地方都必须先问这一句。**
bool isHighlightWordId(String wordId) =>
    wordId.startsWith(kHighlightIdPrefix);

/// 划线 id → uuid（**不是划线 id 时返回 `null`**）。
String? highlightUuidOf(String wordId) {
  if (!isHighlightWordId(wordId)) return null;
  final u = wordId.substring(kHighlightIdPrefix.length);
  return u.isEmpty ? null : u;
}
