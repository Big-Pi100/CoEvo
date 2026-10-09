// CoEvo · **书签**（位置标记）—— 模型与纯逻辑（零 Flutter 依赖 ⇒ 本机可断言）
//
// # 🔴 书签 vs 进度 vs 划线（混一个语义就烂）
//
// | | 谁产生 | 几条 | 目的 | 进复习吗 |
// |---|---|---|---|---|
// | **进度** | 系统自动 | 一本**一条**（覆盖式）| 下次回到原处 | ❌ |
// | **书签**（本文件）| 用户点一下 | **任意多条** | **回头找**某处 | ❌ **不进队列** |
// | **划线** | 用户选一段 | 任意多条 | **记住**这段 | ✅ 进队列（默写）|
//
// 一句话：进度 = 系统说「你读到这了」· 书签 = 你说「**这里我要回来**」·
// 划线 = 你说「**这段我要记住**」。
//
// ⚠️ 本文件与 `highlight_*` **不共用任何表或类型** —— 书签**没有选中的文字**，
//    硬塞进 `highlight` 要造一堆空字段（且会让复习取卡多一种要排除的行）。
//    两者是「同一个词挂在不同对象上」的反面例子：**不同的东西就该是两个东西**。

/// 两条书签可视为「同一位置」的容差（`scroll_ratio` 的差值）。
///
/// # 🔴 为什么要有容差、且**不交给 DB 的唯一索引**
///
/// `scroll_ratio` 是 **REAL** ⇒ 浮点相等比较不可靠。
/// 若用 `UNIQUE(chapter_idx, scroll_ratio)`，用户在同一次滚动里点两次
/// （比例差一个字节）就会**多出一条几乎重合的记录**，而界面上看不出来。
///
/// 🔑 取 `0.01`（章内 1%）的理由：**一次滚动停止**两次得到的比例通常完全相同或极近；
///    而 1% 的章内距离在手机上大约只有几行 —— 用户不会认为那是「两个地方」。
///    ⚠️ 代价：真在 1% 以内标两处会**合并成一条**（几乎不可能，且合并是安全的：
///    用户点第二次的意图本来就是「取消」）。
const double kBookmarkSamePositionTolerance = 0.01;

/// 浮点比较的**极小**余量（不是「容差」的一部分，是「表示误差的余量」）。
///
/// # 🔴 为什么必须有它（实测，不是理论担忧）
///
/// `(0.5 - 0.51).abs()` 在 IEEE 754 下算出来是 **`0.010000000000000009`** ——
/// 比 `0.01` **大** ⇒ 朴素写成 `diff <= tolerance` 会判「**不同位置**」。
/// 而它在**数学上正好等于容差** ⇒ 用户期望「≤ 1% 算同处」。
///
/// ⇒ 后果是**边界值反向判定**：差 1% 反而算两处（而差 0.9% 算同处）——
///   这种「99% 的情况对、边界上反着来」最容易在真机上被当成偶发怪象。
///
/// 📌 判据：**浮点容差比较必须留表示误差的余量** —— 否则 `<=` 在边界上不可靠。
/// ⚠️ 但**不要**用它去掩盖真实的精度问题（如该用整数比较的地方用浮点）——
///    它只解决「数学上相等、表示上差一点」这一种情形。
const double kBookmarkFpEpsilon = 1e-9;

/// 判断两个章内比例是否可视为**同一位置**。
///
/// ⚠️ `NaN` 一律**不相等**（`NaN != NaN` 是 IEEE 语义，这里显式写出来是因为
/// 上游可能传进一个坏值，而「NaN 被当成同一位置」会让「打书签」永远变成「取消」）。
bool isSameBookmarkPosition(
  double a,
  double b, {
  double tolerance = kBookmarkSamePositionTolerance,
}) {
  if (a.isNaN || b.isNaN) return false;
  return (a - b).abs() <= tolerance + kBookmarkFpEpsilon;
}

/// 摘录的**最少**字符数 —— 短于此不按句末截断。
///
/// 🔑 防的是「取到一句 `Hi.`」这种没有信息量的摘录。
const int kBookmarkMinExcerptChars = 12;

/// 句末标点 —— 用它找「句子起点」。
///
/// # 🔴 中文与英文的判据**不同**（实测踩到）
///
/// 首版写的是 `[.!?。！？]\s`（要求句末后跟空白）—— 探针实测发现：
/// **中文正文里 `。` 后面通常没有空格** ⇒ 那个正则**匹配不到任何中文句子边界**
/// ⇒ 摘录永远从「估算位置」硬切，取到半句甚至垃圾。
///
/// ⇒ 分开判：
/// · 中文句末（`。！？`）⇒ **不要求**后跟空白（它们本身就是句子终止符）
/// · 英文句末（`.!?`）⇒ **要求**后跟空白 —— 否则 `a.m.` / `Dr.` / `66.4%` 会被切碎
///
/// 📌 判据：**同一个字符在不同语言里的语法约束不同** —— 别用一条正则同时管两边。
final RegExp _kSentenceEnd = RegExp(r'(?:[。！？]|[.!?](?=\s))');

/// 从**章内比例**估算一段摘录（给书签列表「认出这是哪段」用）。
///
/// # 🔴 它是**近似值**，这是如实标注的设计取舍
///
/// `scroll_ratio` 是**像素**关系，而文字是**字符**关系 —— 两者**不是线性**：
/// 段落长短不一、还有章节标题占位、图片/空行也占高度。
/// ⇒ 估算出的字符位置**可能差几十到一百多字**。
///
/// ✅ 但列表只需要「让用户认出这是哪段」⇒ 可接受（设计稿 §3 已定）。
/// ⚠️ **不要**把它当成「精确位置」用：跳转定位**不能**靠它
///    （那是另一件事，要「源偏移 → 块索引」的映射）。
///
/// # 算法（两步）
/// 1. 比例 × 章长度 ⇒ 估算 offset（钳到合法范围）
/// 2. **取「包含该 offset 的那个句子」** —— 即向前找最近的句末，从那之后开始
///    （找不到 ⇒ 从 0 开始）
/// 3. 从句子起点取最多 [maxChars] 字；若这段里较早处就有句末（且已够长）⇒ 收到那里
///
/// # ⚠️ 第 2 步**偏离了设计稿的字面描述**（如实标注）
///
/// 设计稿写的是「向**后**取第一个完整句子」。实现改成「取**所在**的句子」，两条理由：
///
/// | 理由 | 说明 |
/// |---|---|
/// | ① 区分度 | 「向后取」会让**一整句范围内**的所有比例产出**同一个**摘录 —— 实测：<br>正文 104 字、比例 0.30~0.75 全部给出同一句（因为下一句边界离得远）⇒ 列表里一堆条目看着一样 |
/// | ② 末尾不产出垃圾 | 「向后取」在**滚到底部**时后面没有句子 ⇒ 首版实测给出摘录 **「。」**（孤零零一个句号）—— 用户完全认不出这是哪段 |
///
/// 🔑 而「取所在的句子」更贴近这个摘录的**用途**：它是给「用户当时看的那一屏」做标记。
/// 📌 判据：**实现要服务用途，不是服务措辞** —— 偏离设计稿时**回标设计稿**（已标）。
String estimateBookmarkExcerpt({
  required String chapterText,
  required double scrollRatio,
  int maxChars = 60,
}) {
  if (chapterText.isEmpty) return '';
  final n = chapterText.length;

  // ① 估算 offset（NaN / 越界都钳 —— 上游可能传来坏值）
  final r = scrollRatio.isNaN ? 0.0 : scrollRatio.clamp(0.0, 1.0);
  var at = (r * n).floor();
  if (at >= n) at = n - 1;
  if (at < 0) at = 0;

  // ② 向前找 `at` **所在句子**的起点
  //
  // 🔑 条件写 `m.end > at` 而不是 `>=`：句末**恰在 at 处**时，`at` 就是下一句的开头
  //    （那时 start 应停在 at，不该再往前退一句）。
  var start = 0;
  for (final m in _kSentenceEnd.allMatches(chapterText)) {
    if (m.end > at) break;
    start = m.end;
  }
  while (start < n && _isSpace(chapterText[start])) {
    start++;
  }
  if (start >= n) start = at; // 极端：全空白尾部 ⇒ 退回估算位置

  // ③ 取一段（最多 maxChars）
  var end = start + maxChars;
  if (end > n) end = n;
  var piece = chapterText.substring(start, end);

  // 若这段里较早处就有句末，且已够长 ⇒ 收到那里（别把半句拖进下一句）
  final inner = _kSentenceEnd.firstMatch(piece);
  if (inner != null && inner.end >= kBookmarkMinExcerptChars) {
    piece = piece.substring(0, inner.end);
  }

  return piece.trim();
}

bool _isSpace(String c) => c == ' ' || c == '\n' || c == '\r' || c == '\t';

/// 一条书签。
///
/// ⚠️ 与 `Highlight`（`user.db`）**刻意不同型**：本类没有 `text`（选中的文字）
/// 与 `note`（笔记）—— 书签没有这两样。🔑 这不是「字段少」，是**语义不同**。
class BookMarker {
  const BookMarker({
    required this.id,
    required this.bookId,
    required this.chapterIdx,
    required this.scrollRatio,
    required this.excerpt,
    required this.createdAt,
  });

  /// uuid v4（端侧生成）—— 多设备同步时靠它去重。
  final String id;

  final String bookId;

  /// 章内下标（**0 起** —— 给人看要 +1，见 `highlight_display` 的同族处理）。
  final int chapterIdx;

  /// 章内相对位置 0~1（**与 `book_progress` 同一套** —— 不存绝对像素）。
  final double scrollRatio;

  /// 摘录（**近似值** —— 见 [estimateBookmarkExcerpt]）。
  final String excerpt;

  final DateTime createdAt;

  /// 按**位置**排序用的键（章 → 比例）。
  ///
  /// 🔑 排序按**位置**而不是时间：找地方是按顺序找，不是按「我什么时候标的」找。
  ///    ⚠️ 但用「时间」排序也不是错的 —— 只是与「回某处」这个用途不匹配。
  int get orderKey => chapterIdx;

  @override
  String toString() =>
      'BookMarker(${id.substring(0, 8)}… ch$chapterIdx @${scrollRatio.toStringAsFixed(3)})';
}
