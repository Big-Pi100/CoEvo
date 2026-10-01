/// 词库外生词的**合成 id** —— 前缀常量与构造/解析的**唯一出处**。
///
/// # 🔑 它解决什么
/// 产品要求「用户查了词库里没有的词，那个词也要能进生词本、能被复习」。
/// 但 `user_word.word_id` 指向 `word.db` 的 `word.id` —— **词库外的词没有 id**。
///
/// 而**实测**（`docs/review/a2-and-worddb-convergence-checklist-2026-10-01.md` §二）：
/// 真正的堵点**不是 `word_id NOT NULL`**，而是「复习页取卡时，那张卡的内容从哪来」。
/// → 所以不必改表结构，**给词库外的词造一个 key 就行**：
///
/// | 词的来源 | `word_id` 形态 |
/// |---|---|
/// | 词库内 | `w0xxxxx`（真主键）|
/// | **词库外** | **`ext:brainstorm`**（本文件产出的合成 id）|
///
/// 🔑 于是 **200 上限口径、复习队列、JOIN 全部照常工作**，一行表结构都不用改。
///    取卡时 `WordQueryService.cardById` 见到 `ext:` 前缀 → 回落到端侧缓存
///    （`external_word_cache`，见 `assets/sql/user_db_schema.sql`）。
///
/// # 🔴🔴 归一化是**必须的**，不是顺手做的
/// `word_id` 在本库是**字符串主键**（`UNIQUE(word_id)`），**不经过任何 collation 归一**。
/// ⇒ 若不做归一化，`ext:Brainstorm` 与 `ext:brainstorm` 是**两个不同的 id** →
/// **同一个词在生词本里出现两行**，而且 🔴 **`UNIQUE(word_id)` 拦不住**
/// （它约束的是「同一个 id 只能一行」，而这是两个 id）。
///
/// 归一化口径与服务端 `llm_card::normalize` **保持一致**（`trim` + `to_lowercase`）：
/// 服务端用它做缓存主键、端侧用它做合成 id ——
/// 两边不同的话，同一用户查 `Brainstorm` 会在服务端命中缓存、却在端侧存成第二行。
///
/// ⚠️ 注意与 `WordQueryService._normalize` **不同**：那里只做「trim + 压缩空白」
///    （不做大小写转换），因为那边交给 SQLite 的 `COLLATE NOCASE` 处理。
///    本文件**不能**这么办 —— `ext:` 值是**拼接出来的字符串**，不落任何被 collation
///    覆盖的列，必须自己折好。
library;

/// 合成 id 的前缀。
///
/// 🔑 选 `ext:` 的理由（当初的三个候选里）：
/// - **短**（4 字符，拼进 id 不臃肿）
/// - **一眼可辨**（看到就知道「这不是词库里的词」）
/// - **与真 id 天然隔离**：真 id 是 `w` 开头，永不冲突
const String kExternalWordIdPrefix = 'ext:';

/// 🔑 **归一化**：`trim` + 折叠内部空白 + 转小写。
///
/// ⚠️ 这不是「格式化」而是**判等的一部分** —— 见文件头的说明。
///    两处拼写（`ext:` 的构造侧与解析侧）必须走**同一个**函数，
///    否则 `ext:a b` 与 `ext:a  b` 会分裂成两行。
String normalizeExternalSpelling(String spelling) =>
    spelling.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// 把词库外词的拼写 → 合成 id（如 `brainstorm` → `ext:brainstorm`）。
///
/// ⚠️ **只接受非空输入**。空串会产出 `ext:`（前缀本身）—— 那是一个**合法但无意义**的 id，
///    存进去就再也查不出是哪个词了。这里直接断言拦掉（调用方本不该传空）。
String externalWordId(String spelling) {
  final s = normalizeExternalSpelling(spelling);
  assert(s.isNotEmpty, '词库外词的拼写不能为空（会产出无意义的 `$kExternalWordIdPrefix`）');
  return '$kExternalWordIdPrefix$s';
}

/// 是不是合成 id（词库外的词）。
///
/// 🔑 **凡是要对 `word_id` 做「形态判断」的地方都必须先问这一句** ——
///    典型误用：`id.startsWith('w')` 假设 id 只有词库一种来源。
bool isExternalWordId(String wordId) =>
    wordId.startsWith(kExternalWordIdPrefix);

/// 合成 id → 拼写（**不是合成 id 时返回 `null`**）。
///
/// 🔑 这是**发版收敛的桥**：收敛时拿这个拼写去**新** `word.db` 里查
///    `SELECT id FROM word WHERE spelling = ? COLLATE NOCASE` ——
///    查得到就说明该词已回流，可以把它从 `ext:` 收敛为真 id
///    （见清单 §2.2「不需要 mapping 文件」）。
String? externalSpellingOf(String wordId) {
  if (!isExternalWordId(wordId)) return null;
  final s = wordId.substring(kExternalWordIdPrefix.length);
  return s.isEmpty ? null : s;
}
