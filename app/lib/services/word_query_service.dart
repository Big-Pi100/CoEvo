import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'external_word_id.dart';
import 'generated_card_adapter.dart';

/// 🆕 **词库外词的卡片来源** —— 给定拼写，返回已转换的 `card.content` JSON
/// （`null` = 该词没有缓存）。
///
/// 🔑 抽成 typedef 而不是依赖 `Database`：本层要保持「纯 Dart + 单一数据源」，
///    见 `WordQueryService._externalCardLoader` 的说明。
typedef ExternalCardLoader = Future<String?> Function(String spelling);

/// 词库只读查询层 —— **纯 Dart，不 import Flutter**。
///
/// ## 为什么单独成层
///
/// v1 §2.1 明确「查词（词库内）离线可用」→ 查词是**端侧**能力，与后端无关。
/// 本层把「查词 / 词形还原 / 取卡片 / 聚合页入口」从界面里剥出来，好处是：
///
/// 1. **能用真库跑断言** —— 只要注入 `databaseFactoryFfi`（`sqflite_common_ffi`），
///    无需 Flutter 即可在本地验证（见 `scripts/sqflite_probe/`）
/// 2. **界面接入时不必再想查询逻辑** —— Step 3 的划词浮层、Step 4 的复习列表共用本层
///
/// ## 数据来源（只读）
///
/// 全部来自预制库 `word.db`（**从不写入** —— 打开时即 `readOnly: true`）：
///
/// | 表 | 用途 |
/// |---|---|
/// | `word` | 词条（spelling / cefr_level / entry_type / etymology_text） |
/// | `card` | 卡片内容（`content` 是 JSON，含 `sections`） |
/// | `word_form` | 词形 → 词元（链式：form → base → anchor） |
/// | `aggregate_page_word` + `aggregate_page` | 聚合页入口（词根族 / 词源族） |
///
/// 用户数据（复习状态 / 生词本）在 `user.db`，见 `ReviewListQuery`。
class WordQueryService {
  WordQueryService._(this._db, this.path, {ExternalCardLoader? externalCardLoader})
      : _externalCardLoader = externalCardLoader;

  final Database _db;

  /// 🆕 词库外词的卡片来源（`ext:` 前缀的回落）—— **可选**。
  ///
  /// 🔑 为什么是**回调**而不是「传一个 `user.db` 的 `Database`」：
  ///   本层是「`word.db` 只读查询」，一旦直接依赖 `user.db`，
  ///   就变成**跨库耦合**，且**无法再脱离真实环境断言**（要造两个库）。
  ///   注入一个 `Future<String?> Function(String)` 则：
  ///   · App 侧传「读 `external_word_cache` 的实现」（一行闭包）
  ///   · 断言脚本传假值 → 本层仍可在**纯 Dart** 下验证
  ///   （同 `word_db_bootstrap` 把 IO 抽成注入接口的惯例。）
  ///
  /// ⚠️ `null`（默认）表示「本环境不支持词库外生词」→ `cardById` 对 `ext:` 返回 `null`，
  ///    语义与「词库外的词查不到」一致，调用方不需要额外分支。
  final ExternalCardLoader? _externalCardLoader;

  /// 打开的库路径（诊断用）
  final String path;

  /// 打开**只读**词库。
  ///
  /// ⚠️ 工厂由调用方注入，这是本层「可在纯 Dart 下验证」的关键：
  /// - App：`WordQueryService.open(databaseFactory, path)`
  /// - 验证脚本：`WordQueryService.open(databaseFactoryFfi, r'...\data\word.db')`
  static Future<WordQueryService> open(
    DatabaseFactory factory,
    String path, {
    ExternalCardLoader? externalCardLoader,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    return WordQueryService._(db, path, externalCardLoader: externalCardLoader);
  }

  Future<void> close() => _db.close();

  // ─────────────────────────────────────────────────────────────
  // 对外接口
  // ─────────────────────────────────────────────────────────────

  /// 查词 —— 划词与复习列表的主入口。
  ///
  /// 流程（对应 v1 §九「用户查词流程」的「查本地 word 表」分支）：
  ///
  /// ```
  /// 1. 直接查 spelling（COLLATE NOCASE，大小写不敏感）
  ///    ├── 命中 → 返回卡片
  ///    └── 未命中 → 2
  /// 2. 用 word_form 做词形还原（received → receive）
  ///    ├── 还原命中 → 返回词元的卡片
  ///    └── 仍无 → null（调用方走「词库外」流程：external_word_cache 或 LLM 制卡）
  /// ```
  ///
  /// 返回的卡片带 `isLemmatized == true` 时，说明是**变形查到的词元**——
  /// 界面据此决定是否提示「received 是 receive 的变形」。
  Future<WordLookupResult?> lookup(String rawText) async {
    final text = _normalize(rawText);
    if (text.isEmpty) return null;

    // ① 直查
    final direct = await _cardBySpelling(text);
    if (direct != null) {
      return WordLookupResult(card: direct, query: text);
    }

    // ② 词形还原
    final lemma = await analyzeForm(text);
    if (lemma != null && lemma.base.toLowerCase() != text.toLowerCase()) {
      final card = await _cardBySpelling(lemma.base);
      if (card != null) {
        return WordLookupResult(card: card, query: text, lemma: lemma);
      }
    }

    return null;
  }

  /// 词形还原：任意变形 → 词元。
  ///
  /// 返回 `null` 表示该拼写不在 `word_form` 里（可能是词库外的新词）。
  ///
  /// 🔑 **`ORDER BY base` 不是多余的**（2026-09-29 加）：
  /// `word_form` 的主键是 **`(form, base)`** —— 设计上允许**一个词形映射到多个词元**
  /// （`leaves` 既是 `leaf`「树叶」的复数，也是 `leave`「离开」的第三人称单数）。
  /// 没有 `ORDER BY` 时，`LIMIT 1` 取哪一行**由查询计划决定**，SQL 层面**无任何保证**
  /// （实测：走 PK 索引时恰好返回 `base` 字母序最小的，但索引一变顺序就变）。
  ///
  /// 加上 `ORDER BY base` 后行为**确定**：多映射时稳定取**字母序最小**的 base。
  ///
  /// ⚠️ 注意这只是**确定化**，不是**消歧** —— 「多映射时该取哪个」仍需语义判断，
  ///    属未决问题（见 `docs/design/llm-card-online-path-2026-09-29.md` §18.1）。
  ///    当前词库实测 **0 个 form 有多映射**，所以这条只作**健壮性保障**。
  Future<LemmaResult?> analyzeForm(String rawText) async {
    final form = _normalize(rawText);
    if (form.isEmpty) return null;

    final rows = await _db.rawQuery(
      'SELECT form, base, rule, kind, anchor, depth, in_vocab, action '
      'FROM word_form WHERE form = ? ORDER BY base LIMIT 1',
      [form],
    );
    if (rows.isEmpty) return null;

    final r = rows.first;
    return LemmaResult(
      form: r['form']! as String,
      base: r['base']! as String,
      rule: r['rule'] as String?,
      kind: r['kind'] as String?,
      anchor: r['anchor'] as String?,
      depth: r['depth'] as int?,
      inVocab: (r['in_vocab'] as int?) == 1,
      action: r['action'] as String?,
    );
  }

  /// 该词的聚合页入口（① 词根族 / ② 词源族）。
  ///
  /// ⚠️ **可能为空** —— 族规模未达门槛（≥3）时不建页。
  /// 所以「有拆解内容但无聚合页」是**合法状态**（例：`capture` 的 `capt` 族只有 2 词）。
  Future<List<AggregateLink>> aggregateLinks(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT a.id, a.page_type, a.front, a.member_count '
      'FROM aggregate_page_word w JOIN aggregate_page a ON a.id = w.page_id '
      'WHERE w.word_id = ? ORDER BY a.page_type',
      [wordId],
    );
    return rows
        .map((r) => AggregateLink(
              pageId: r['id'] as int,
              pageType: r['page_type']! as String,
              title: r['front']! as String,
              memberCount: r['member_count']! as int,
            ))
        .toList();
  }

  /// 聚合页的成员（用于「词根族 15 词」展开后的列表）。
  ///
  /// 按白哥要求返回**分拆法 + 释义**，而不是单纯列单词 ——
  /// 只列单词是「N 个不相干的词」，带分拆法才是「一个词根 × N 种前缀」。
  Future<List<AggregateMember>> aggregateMembers(int pageId, {int limit = 100}) async {
    final rows = await _db.rawQuery(
      'SELECT w.id, w.spelling, w.cefr_level, w.sort_seq '
      'FROM aggregate_page_word p JOIN word w ON w.id = p.word_id '
      'WHERE p.page_id = ? ORDER BY w.sort_seq LIMIT ?',
      [pageId, limit],
    );
    final members = <AggregateMember>[];
    for (final r in rows) {
      final id = r['id']! as String;
      members.add(AggregateMember(
        wordId: id,
        spelling: r['spelling']! as String,
        cefrLevel: r['cefr_level'] as String?,
        morphology: await _morphologyOf(id),
      ));
    }
    return members;
  }

  /// 取某词的词素拆分（供聚合页成员显示「分拆法」）。
  Future<List<MorphPart>> morphologyOf(String wordId) => _morphologyOf(wordId);

  /// 词总数（诊断 / 验收用）。
  Future<int> countWords() async {
    final r = await _db.rawQuery('SELECT count(*) AS n FROM word');
    return (r.first['n'] as int?) ?? 0;
  }

  // ─────────────────────────────────────────────────────────────
  // 内部实现
  // ─────────────────────────────────────────────────────────────

  Future<WordCard?> _cardBySpelling(String spelling) async {
    final rows = await _db.rawQuery(
      'SELECT w.id, w.spelling, w.cefr_level, w.entry_type, w.etymology_text, w.sort_seq, '
      '       c.content, c.content_hash, c.template_code '
      'FROM word w LEFT JOIN card c ON c.word_id = w.id '
      'WHERE w.spelling = ? LIMIT 1',
      [spelling],
    );
    if (rows.isEmpty) return null;

    final id = rows.first['id']! as String;
    return _cardFromRow(rows.first, links: await aggregateLinks(id));
  }

  static List<WordSection> _parseSections(Map<String, Object?> content) {
    final raw = content['sections'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => WordSection(m.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// 🆕 **按拼写取 `word.id`**（只查 id，不读卡片内容）—— **发版收敛用**。
  ///
  /// # 为什么单独一个方法（而不是复用 `_cardBySpelling`）
  /// 收敛要为**每个候选词**问一次「这个词进词库了吗」——
  /// 而 `_cardBySpelling` 会连带读 `card.content`（~1.2 KB/词）**并算聚合页入口**
  /// （另一次 JOIN）。收敛只要一个 id → 多读的东西纯属浪费。
  ///
  /// 🔑 这也正是收敛「**不需要 mapping 文件**」的落点：
  ///    `ext:<拼写>` 里的拼写**就是桥** —— 拿它来查这张表，
  ///    查得到就说明该词已回流（见清单 §2.2）。
  ///
  /// ⚠️ 用 `COLLATE NOCASE` 显式指定 —— 与表上的索引口径一致
  ///    （虽然 `word.spelling` 实测全小写，但收敛的输入来自 `ext:` 归一化值，
  ///      显式声明可以避免将来有人改归一化规则时**静默查不到**）。
  Future<String?> idOfSpelling(String spelling) async {
    final rows = await _db.rawQuery(
      'SELECT id FROM word WHERE spelling = ? COLLATE NOCASE LIMIT 1',
      [spelling],
    );
    return rows.isEmpty ? null : rows.first['id'] as String?;
  }

  /// 按 `word.id` 取**拼写** —— [idOfSpelling] 的反向，**只读一列**。
  ///
  /// 🔑 用途：`card_review_state.spelling` 曾被写成内部 ID（`w000129` …），
  ///    修复时要把它换回真拼写（见 `review_spelling.dart` 的解析器 ⑤ 级）。
  ///
  /// ⚠️ 不要用 [cardById] 代替：那个会 `LEFT JOIN card` 读 `content`
  ///    （~1.2 KB/词）**并算聚合页入口** —— 修复场景只需要一个词形。
  ///    （同 [idOfSpelling] 文档里对 `_cardBySpelling` 的那条说明。）
  Future<String?> spellingOfId(String id) async {
    final rows = await _db.rawQuery(
      'SELECT spelling FROM word WHERE id = ? LIMIT 1',
      [id],
    );
    return rows.isEmpty ? null : rows.first['spelling'] as String?;
  }

  /// 按 `word.id` 取词条卡片 —— **复习页用**（那里只有 `word_id`，没有拼写）。
  ///
  /// 与 [_cardBySpelling] 的差别只在 `WHERE` 列；解析逻辑共用 [_cardFromRow]。
  ///
  /// # 🆕 `ext:` 回落（2026-10-01 · A2）
  /// `word.db` 查不到 **且** id 是合成 id（`ext:<拼写>`，词库外的词）时，
  /// 回落读端侧缓存（`external_word_cache`）。
  ///
  /// 🔴 **没有这一层会怎样**：词库外的词在生词本里**看得见**（`user_word` 有行），
  ///    点开却**取不到卡** → 复习页出现「点不开的空条目」——
  ///    正是本产品一直避免的「**静默失败 + 无出口**」。
  ///
  /// ⚠️ 回落只在**真查不到**时发生（`rows.isEmpty`）——
  ///    若将来某个真 id 恰好以 `ext:` 开头（不会发生：真 id 是 `w…`），这里仍然安全。
  Future<WordCard?> cardById(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT w.id, w.spelling, w.cefr_level, w.entry_type, w.etymology_text, w.sort_seq, '
      '       c.content, c.content_hash, c.template_code '
      'FROM word w LEFT JOIN card c ON c.word_id = w.id '
      'WHERE w.id = ? LIMIT 1',
      [wordId],
    );
    if (rows.isNotEmpty) return _cardFromRow(rows.first);

    // ── 词库外（合成 id）→ 端侧缓存 ──
    final spelling = externalSpellingOf(wordId);
    final loader = _externalCardLoader;
    if (spelling == null || loader == null) return null;

    final raw = await loader(spelling);
    if (raw == null || raw.isEmpty) return null;

    // 🔑 复用**同一个**解析器（`parseCardContent`）—— 别在这里另写一份 JSON 解析：
    //    缓存里的形状与 `word.db.card.content` **刻意一致**（见适配器文件头），
    //    所以这里只是「换了个数据源」，字段口径完全一样。
    final c = parseCardContent(raw);
    if (c.sections.isEmpty) return null;   // 空卡 = 取不到卡（比返回半张卡诚实）

    return WordCard(
      wordId: wordId,
      // ⚠️ `front` 理论上不会空（适配器写入时已归一化）；真空了退回合成 id 的拼写，
      //    至少让界面能显示「查的是哪个词」，而不是一个空白标题。
      spelling: c.front.isEmpty ? spelling : c.front,
      ipa: c.ipa.isEmpty ? null : c.ipa,
      entryType: c.entryType.isEmpty ? null : c.entryType,
      sections: c.sections.map(WordSection.new).toList(growable: false),
      // `cefrLevel` / `sortSeq` / `contentHash` / `templateCode` / `aggregateLinks`
      // 一律不填 —— 它们是**词库侧**的元数据，词库外的词本来就没有。
      // 🔑 尤其 `aggregateLinks` 为空是**正确**状态：聚合页按全库算族，词库外的词没有族页。
    );
  }

  /// 取某词的**记忆法槽位分配**（`word_mnemonic_profile`，11,523 词全有）。
  ///
  /// # 🔴 为什么不自己按 `mnemonic_type.priority` 排一遍（2026-09-28 核实）
  /// 那张表是**制卡时**的配置，而**每个词的分配结果早已算好并存下来**：
  /// · `primary_code`   → 卡片 **①**
  /// · `secondary_codes` → 卡片 **②**（JSON 数组；可能为空）
  /// · `confidence` / `rationale` → 为什么这么分配
  ///
  /// → 运行时按 priority 重排 = **把已经算好的结果再猜一遍**，
  ///   而且会与制卡结果**不一致**（`secondary_codes` 是有抑制规则的：
  ///   设计稿 §06「② 对可拆词 78.3% 与 ① 重复」→ 那些词的 ② 被刻意留空）。
  ///
  /// ⚠️ 且**设计稿 HTML 与库表优先级不一致**：
  ///   HTML 写 `root→cognate→collocation(3)→etymology(4)`，
  ///   库表 `mnemonic_type` 权威值是 `root(1) cognate(2) etymology(3) collocation(4)`。
  ///   🔑 **以库为准**（数据 > 手绘稿）；用它就等于绕开了这个矛盾。
  Future<WordMnemonicProfile?> profileOf(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT word_id, primary_code, secondary_codes, confidence, rationale '
      'FROM word_mnemonic_profile WHERE word_id = ? LIMIT 1',
      [wordId],
    );
    return rows.isEmpty ? null : WordMnemonicProfile.fromRow(rows.first);
  }

  /// 复习一张卡所需的**全部数据**（词条 + 槽位分配）—— 一次调用取齐。
  ///
  /// 🔑 合成一个方法而不是让调用方查两次：两者**总是同时需要**
  ///   （卡片没有 profile 就不知道该把哪两段放 ①②），
  ///   分两次调用只会让「忘了查 profile」变成一个静默的半成品状态。
  Future<({WordCard card, WordMnemonicProfile? profile})?> reviewCardOf(
      String wordId) async {
    final card = await cardById(wordId);
    if (card == null) return null;
    return (card: card, profile: await profileOf(wordId));
  }

  /// **聚合页**（词根族 / 词源族）—— 点卡片 ① / ② 打开的那一页。
  ///
  /// # 🔴 本方法**只补页头**；成员列表**复用 [aggregateMembers]**
  /// `aggregateMembers` **先前就已存在**（自带「分拆法」，且有验收覆盖），
  /// 卡片上的入口（`AggregateLink`）也一直用它给的 `pageId`。
  /// → 这里若再查一遍成员，就是**同一件事两处实现**（本项目已多次踩过）。
  ///   ⚠️ 我 2026-09-28 第一次写这段时**正是这么错的**：没先搜既有 API，
  ///      重复定义了一个 `AggregateMember` 类、又自己查了一遍成员表。
  ///
  /// 所以现在只查三样：**标题 / 词根本体 / 语种含义**（都只在 `aggregate_page` 里）。
  ///
  /// ## 为什么还需要 `source`（词根本体）
  /// 设计稿的页头是 `cept` 大字 + `Latin · 拿取 · 22 个同族词` ——
  /// 这个「大字 + 语种/含义」取自 `content.sections[0].source`，
  /// 而 `AggregateLink`（卡片入口用的）只有 title / memberCount，**没有它**。
  Future<AggregatePage?> aggregatePageOf(int pageId) async {
    final rows = await _db.rawQuery(
      'SELECT id, page_type, front, content, member_count '
      'FROM aggregate_page WHERE id = ?',
      [pageId],
    );
    if (rows.isEmpty) return null;

    final r = rows.first;
    final contentRaw = r['content'] as String?;
    var front = (r['front'] as String?) ?? '';
    AggregateSource? source;
    final glosses = <String, String>{};

    if (contentRaw != null && contentRaw.isNotEmpty) {
      try {
        final d = (jsonDecode(contentRaw) as Map).cast<String, Object?>();
        final f = d['front'] as String?;
        if (f != null && f.isNotEmpty) front = f;
        final sections = d['sections'];
        if (sections is List && sections.isNotEmpty) {
          final s0 = (sections.first as Map);
          source = AggregateSource.fromMap(s0['source']);
          // 成员释义（设计稿的成员行要显示）—— 顺手收成一张表
          final items = s0['items'];
          if (items is List) {
            for (final it in items.whereType<Map>()) {
              final wid = it['word_id'];
              final g = it['gloss'];
              if (wid is String && g is String && g.isNotEmpty) {
                glosses[wid] = g;
              }
            }
          }
        }
      } catch (_) {
        // 🔑 坏 JSON 不让整页打不开 —— 至少还能显示标题。
        //    ⚠️ 这里**故意不写日志**：本层是**纯 Dart**（零 Flutter 依赖，
        //       这是「验证脚本能 import 真源码」的前提）→ 用不了 `debugPrint`。
        //       与 `WordMnemonicProfile._parseCodes` 同一原则：
        //       「一条坏数据不该让整个界面渲染不出来」。
      }
    }

    return AggregatePage(
      pageId: r['id']! as int,
      pageType: (r['page_type'] as String?) ?? '',
      front: front.trim(),
      memberCount: (r['member_count'] as int?) ?? 0,
      source: source,
      // 🔑 成员走**既有实现**（自带分拆法）
      members: await aggregateMembers(pageId),
      glosses: glosses,
    );
  }

  /// 记忆法类型的**显示名**（`mnemonic_type.name`：`root` → 「词根词缀」…）。
  ///
  /// # 🔴 为什么从库里读而不在 UI 层硬编码
  /// 这 6 个名字**词库里就有权威定义**（`mnemonic_type.name`）。
  /// 硬编码一份 = 两处定义 → 改了一处忘另一处（本项目已多次踩过）。
  ///
  /// ⚠️ **懒加载 + 缓存**：表只有 6 行、且进程内不变 → 读一次即可。
  ///    缓存字段挂在 service 实例上（service 本身是长生命周期单例）。
  Future<Map<String, String>> mnemonicTypeNames() async {
    final cached = _typeNames;
    if (cached != null) return cached;
    final rows =
        await _db.rawQuery('SELECT code, name FROM mnemonic_type');
    final m = <String, String>{
      for (final r in rows) (r['code']! as String): (r['name']! as String),
    };
    _typeNames = m;
    return m;
  }

  Map<String, String>? _typeNames;

  WordCard _cardFromRow(
    Map<String, Object?> r, {
    List<AggregateLink> links = const [],
  }) {
    final id = r['id']! as String;
    final contentRaw = r['content'] as String?;
    final content = contentRaw == null
        ? const <String, Object?>{}
        : (jsonDecode(contentRaw) as Map).cast<String, Object?>();

    return WordCard(
      wordId: id,
      spelling: r['spelling']! as String,
      ipa: content['ipa'] as String?,
      cefrLevel: r['cefr_level'] as String?,
      entryType: r['entry_type'] as String?,
      etymologyText: r['etymology_text'] as String?,
      sortSeq: (r['sort_seq'] as int?) ?? 0,
      templateCode: r['template_code'] as String?,
      contentHash: (r['content_hash'] as String?) ?? '',
      sections: _parseSections(content),
      aggregateLinks: links,
    );
  }

  /// 批量取**首义的中文释义** —— 复习列表项要显示释义。
  ///
  /// 依据 `docs/design/visual-word-card-target-2026-09-26.html` §02：
  /// 「**列表项 = 单词 + 释义 + 熟练度三点 + 下次到期时间**」。
  ///
  /// # 🔑 为什么是「批量」而不是逐条查
  /// 列表 200 条逐条查 = 200 次 SQL 往返；一次 `IN (...)` 就够。
  /// （单词条查询 ~43 µs 是**单次**成本，乘上条数与往返开销就不再是小事。）
  ///
  /// # 🔑 为什么只取**首义**（`order` 最小）
  /// 列表一行放不下多个义项；且「**按首义判定**」是本项目既定判据
  /// （同 `data-noise-classification` skill 的铁律）。
  /// **词卡上才显示全部义项** —— 那是「记这个词」的场合。
  ///
  /// # 返回值语义（调用方要注意）
  /// `wordId → 中文释义`。**没有释义的词不出现在 Map 里** ——
  /// 故意**不用空串占位**：空串会让「有词条但无释义」与「词条不存在」
  /// 在调用方混成一种情况，而两者该有不同处理。
  Future<Map<String, String>> firstDefinitionsOf(List<String> wordIds) async {
    if (wordIds.isEmpty) return const {};
    // ⚠️ 占位符个数 = 列表长度（本方法只服务分页后的列表，≤200，远低于
    //    SQLite 的变量上限；若将来要传几千个，须分批）
    final ph = List.filled(wordIds.length, '?').join(',');
    final rows = await _db.rawQuery(
      'SELECT word_id, content FROM card WHERE word_id IN ($ph)',
      wordIds,
    );
    final out = <String, String>{};
    for (final r in rows) {
      final raw = r['content'] as String?;
      if (raw == null) continue;
      final zh = _firstDefinitionZh(raw);
      if (zh != null && zh.isNotEmpty) {
        out[r['word_id']! as String] = zh;
      }
    }
    return out;
  }

  /// 从 `card.content` 的 JSON 里取出**首义**（`order` 最小的 `definition.zh`）。
  ///
  /// ⚠️ 坏 JSON / 缺段 / 缺字段一律返回 `null` **而不是抛**：
  ///    列表里一条坏数据不该炸掉整页（同「库级只回答可不可以」的容错取向）。
  ///    🔑 代价是「静默跳过」—— 所以返回值用 `null` 而非空串，
  ///      让调用方**能区分**「没释义」与「取到了空」。
  static String? _firstDefinitionZh(String contentJson) {
    Object? decoded;
    try {
      decoded = jsonDecode(contentJson);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final secs = decoded['sections'];
    if (secs is! List) return null;

    Map<String, Object?>? best;
    var bestOrder = 1 << 30;
    for (final s in secs.whereType<Map>()) {
      if (s['type'] != 'definition') continue;
      final o = (s['order'] as int?) ?? 0;
      if (o < bestOrder) {
        bestOrder = o;
        best = s.cast<String, Object?>();
      }
    }
    return (best?['zh'] as String?)?.trim();
  }

  Future<List<MorphPart>> _morphologyOf(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT position, type, surface, gloss, relation '
      'FROM word_morpheme WHERE word_id = ? ORDER BY position',
      [wordId],
    );
    return rows
        .map((r) => MorphPart(
              position: (r['position'] as int?) ?? 0,
              type: r['type']! as String,
              surface: (r['surface'] as String?) ?? '',
              gloss: r['gloss'] as String?,
              relation: r['relation'] as String?,
            ))
        .toList();
  }

  /// 规范化输入：去首尾空白、压缩内部空白（词组形如 `traffic jam`）。
  ///
  /// **不做大小写转换** —— `word.spelling` 与 `word_form.form` 都带
  /// `COLLATE NOCASE`（只折叠 ASCII，正好覆盖英文），交给 SQLite 处理更可靠。
  static String _normalize(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ');
}

// ─────────────────────────────────────────────────────────────
// 结果模型
// ─────────────────────────────────────────────────────────────

/// 查词结果 —— 含「是否经词形还原得到」。
class WordLookupResult {
  WordLookupResult({required this.card, required this.query, this.lemma});

  /// 命中词条的卡片
  final WordCard card;

  /// 用户实际查的文本（可能是变形）
  final String query;

  /// 非空表示「输入是变形，已还原到词元」
  final LemmaResult? lemma;

  /// 是否经词形还原命中（界面据此提示「received 是 receive 的变形」）
  bool get isLemmatized => lemma != null;
}

/// 词条卡片 —— `word` 行 + `card.content` 解析结果 + 聚合页入口。
class WordCard {
  WordCard({
    required this.wordId,
    required this.spelling,
    this.ipa,
    this.cefrLevel,
    this.entryType,
    this.etymologyText,
    this.templateCode,
    this.contentHash = '',
    this.sortSeq = 0,
    this.sections = const [],
    this.aggregateLinks = const [],
  });

  final String wordId;
  final String spelling;
  final String? ipa;
  final String? cefrLevel;
  final String? entryType;
  final String? etymologyText;
  final String? templateCode;
  final String contentHash;
  final int sortSeq;

  /// 卡片段（**素材池**：含全部可用素材，渲染层再选）
  final List<WordSection> sections;

  /// 聚合页入口（可能为空 —— 未达门槛是合法状态）
  final List<AggregateLink> aggregateLinks;

  /// 取指定类型的段（可能有多个，如多个 `definition` 之外的场景）
  List<WordSection> sectionsOfType(String type) =>
      sections.where((s) => s.type == type).toList(growable: false);

  /// 首个指定类型的段
  WordSection? sectionOfType(String type) {
    for (final s in sections) {
      if (s.type == type) return s;
    }
    return null;
  }
}

/// 卡片段。`raw` 保留原始 JSON —— 不同类型形状不同，用下面的访问器取值。
class WordSection {  WordSection(this.raw);

  final Map<String, Object?> raw;

  String get type => (raw['type'] as String?) ?? '';

  /// 聚合页入口（`root` / `cognate` / `etymology` 三种段带 `entry`）。
  ///
  /// 这是「卡片上显示当前词的内容，**点击才展开聚合页**」的落点 ——
  /// 入口内嵌在段里，不单独成段（v1 §8.5 的取代项）。
  AggregateLink? get entry {
    final e = _asMap(raw['entry']) ?? _asMap(_asMap(raw['payload'])?['entry']);
    if (e == null) return null;
    final pageId = e['page_id'];
    if (pageId is! int) return null;
    return AggregateLink(
      pageId: pageId,
      pageType: (e['page_type'] as String?) ?? '',
      title: (e['label'] as String?) ?? '',
      memberCount: (e['size'] as int?) ?? 0,
    );
  }

  /// `root` 段：词素拆分
  List<MorphPart> get parts {
    final payload = _asMap(raw['payload']);
    final list = payload?['parts'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) {
      final mm = m.cast<String, Object?>();
      return MorphPart(
        position: (mm['position'] as int?) ?? 0,
        type: (mm['type'] as String?) ?? '',
        surface: (mm['form'] as String?) ?? (mm['surface'] as String?) ?? '',
        gloss: (mm['meaning'] as String?) ?? (mm['gloss'] as String?),
        relation: mm['relation'] as String?,
      );
    }).toList(growable: false);
  }

  /// `collocation` 段
  List<CollocationItem> get collocations {
    final list = raw['items'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((m) {
      final mm = m.cast<String, Object?>();
      return CollocationItem(
        phrase: (mm['phrase'] as String?) ?? '',
        zh: (mm['zh'] as String?) ?? '',
      );
    }).toList(growable: false);
  }

  /// `etymology` 段 / `context` 段的正文
  String? get text => raw['text'] as String?;

  /// `definition` 段
  String? get en => raw['en'] as String?;
  String? get zh => raw['zh'] as String?;
  String? get pos => raw['pos'] as String?;

  /// ⚠️ `cognate` 段的访问器（`cognateLabel`）已于 2026-09-28 **删除** ——
  /// 它唯一的消费者是 `word_card.dart` 里那个**不可达**的 `case 'cognate'`
  /// （`CardSlots.offCard` 永远拦住该类型）→ 一对自封闭的死代码，一并清掉。
  /// 且 `cognate` 已从数据层整层摘除（`mnemonic_type` / `profile` / `card.sections` 全部清零）。

  static Map<String, Object?>? _asMap(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;
}

/// 记忆法**槽位分配**（`word_mnemonic_profile`，11,523 词全有）。
///
/// 这是**制卡时算好的结果**，运行时不重算 —— 见 `WordQueryService.profileOf`。
///
/// ## 权威优先级（以库表 `mnemonic_type` 为准）
/// | code | priority | 显示名 |
/// |---|---|---|
/// | `root` | 1 | 词根词缀 |
/// | `collocation` | 3 | 搭配整记 |
/// | `etymology` | 4 | 词源故事 |
/// | `image` | 5 | 联想图像 |
/// | `context` | 6 | 语境原句（默认附加） |
///
/// 🔴 **2026-09-28：`cognate` 已从记忆法层整层摘除**（白哥：「**同源串记是聚合页，
///    现在还总是把这个放在记忆法里**」）。它原本是 priority 2，但**它不是卡上记忆法** ——
///    它的 `card.sections` 段 100% 无文本（只有族标签）、且与同词 `root` 段**指向同一个
///    `aggregate_page`**（实测 2,988 段全部如此）→ 它是**聚合页入口的冗余副本**。
///    现已：删 `mnemonic_type` 行 · `profile` 清空 · 删 2,988 个段 · 删本文件与
///    `word_card.dart` 的渲染分支。**不要再把它加回来**。
///
/// ⚠️ 3/4 级的往复（**别再来回改**）：
/// · v1 §4.1（L0 原文）= `collocation` 3 / `etymology` 4
/// · 2026-09-27 白哥批准**交换**为 `etymology` 3 / `collocation` 4 ——
///   理由：`collocation` 的条件「有 ≥1 条搭配」实测 **99.3% 的词都满足（几乎恒真）**，
///   排在前会把「不可拆词」全吃掉 → `etymology` 只剩 0.5%（形同虚设）。
///   📄 `docs/review/mnemonic-slot-priority-conflict-2026-09-27.md`
/// · 🔄 **2026-09-28 白哥改回 v1 顺序**（「以 v1 为准」）—— **在知悉后果后**仍定：
///   实测会回到 `collocation` 51.7% / `etymology` 0.5%（见 `scripts/priority_redo.py` 文件头）。
/// → 所以现在库里就是 `collocation` 3 / `etymology` 4，**与 v1 §4.1 一致**。
///
/// # 🔴 但「分配结果」≠「能上卡的类型」 —— 见 `resolveCardSlots`
/// 上表把 `cognate` / `context` 也列为**合法记忆法类型**，于是
/// `primary_code` 里真的出现了它们（实测：`context` **1,410 词**、
/// `cognate` **195 词**）。但这两类**不该出现在卡片上**：
/// · `context` —— 它是卡片 **④ 的固定位置**（`applicable_when` 写着「默认附加」）
///   → 进 ① 就会与 ④ **重复显示**（白哥 2026-09-28 报的就是这个）
/// · `cognate` —— 白哥原话（`mnemonic-layer-separation-2026-09-26.md` §188）：
///   > 「**同源串记是个聚合页面不应该直接显示在卡片上**，卡片上应该显示的是
///   >   『词源故事』而点击词源故事展开同源串记聚合页；**词根词缀也是一样**。」
///   · 数据侧佐证：`cognate` 段**只有族标签**（`group_id`/`label`/`size`/`origin`），
///     **没有故事文本** → 它天然只是**聚合页入口信息**，不是一段可读的内容
class WordMnemonicProfile {
  WordMnemonicProfile({
    required this.wordId,
    required this.primaryCode,
    this.secondaryCodes = const [],
    this.confidence = 0,
    this.rationale,
  });

  final String wordId;

  /// 卡片 **①** 用哪一类记忆法
  final String primaryCode;

  /// 卡片 **②** 用哪一类（**可能为空** —— 设计稿 §06：
  /// 「② 对可拆词 78.3% 与 ① 重复」→ 那些词的 ② 被刻意留空）
  final List<String> secondaryCodes;

  final double confidence;

  /// 为什么这么分配（制卡时的理由，可用于排查）
  final String? rationale;

  /// ② 的首选 code（`null` = 不该显示 ②）。
  ///
  /// ⚠️ **必须过滤掉 `context`** —— 它在表里也会出现在 `secondary_codes` 里
  /// （如 `primary_code='etymology', secondary_codes=['context']`），
  /// 但 `context` 是卡片 **④** 的固定位置（`mnemonic_type.applicable_when`
  /// 写着「默认附加」）→ 不能又在 ② 显示一次。
  String? get secondaryCode {
    for (final c in secondaryCodes) {
      if (c != 'context') return c;
    }
    return null;
  }

  static WordMnemonicProfile fromRow(Map<String, Object?> r) =>
      WordMnemonicProfile(
        wordId: r['word_id']! as String,
        primaryCode: (r['primary_code'] as String?) ?? '',
        secondaryCodes: _parseCodes(r['secondary_codes']),
        confidence: (r['confidence'] as num?)?.toDouble() ?? 0,
        rationale: r['rationale'] as String?,
      );

  /// `secondary_codes` 在库里是 **JSON 数组字符串**（如 `["context"]`）。
  ///
  /// ⚠️ 坏 JSON / 非数组一律当空 —— 一条坏数据不该让卡片整张渲染不出来。
  static List<String> _parseCodes(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      return d.whereType<String>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

/// 卡片上的**一个记忆法槽位**（渲染用）—— 已经过「哪些类型能上卡」的过滤。
///
/// 🔑 与 `WordMnemonicProfile` 的分工必须分清（这是本组 bug 的根子）：
/// | | 表达什么 | 谁决定 |
/// |---|---|---|
/// | `WordMnemonicProfile` | 制卡时**判定的记忆法优先级**（数据） | **按 `mnemonic_type.priority` 算**（2026-09-28 起），存库 |
/// | `CardSlot` | **这张卡上实际显示哪两段**（展示） | 产品规则，运行时 |
///
/// 把两者混为一谈，就会出现「库说 `primary=cognate` → 卡片真的铺出同源串记」
/// （那个 bug 的两半现都已消除：`cognate` 整层摘除 · `profile` 改为按 priority 计算）。
class CardSlot {
  const CardSlot({required this.code, required this.section});

  /// `root` / `collocation` / `etymology` / `image`（**不会是** `context` / `cognate`）
  final String code;

  final WordSection section;

  /// 聚合页入口（`null` = 该段没有族页 → 卡片上**不给箭头、不可点**）。
  AggregateLink? get entry => section.entry;
}

/// 卡片槽位解析 —— 从「profile 判定」得到「实际能铺在卡上的两段」。
///
/// # 🔴 排除两类
/// ```dart
/// const kMnemonicOffCard = {'context', 'cognate'};
/// ```
/// | code | 为什么不能上卡 |
/// |---|---|
/// | `context` | 它是 **④ 的固定位置**（`applicable_when`=「默认附加」）→ 上 ① 就与 ④ **重复显示**。实测 **1,410 词**的 `primary_code` 曾是它（如 `achieve` / `begin` / `close`） |
/// | `cognate` | 它是**聚合页**，不是卡上记忆法。🔴 **2026-09-28 已整层摘除** —— `mnemonic_type` 行删除、`profile` 清空、2,988 个卡片段删除、渲染分支删除。**保留本条只为「防御纵深」**（万一哪天有人又把 `cognate` 塞回数据里，这里仍会挡住它） |
///
/// # 🔑 为什么要「补位」而不是「过滤后留空」
/// 排除上述类型后，那些词的 ① 会空掉 → 卡片少一段记忆法。
/// 而白哥的原话是「**从记忆法排序抓取中去掉**」——
/// 「抓取」本身就是**按优先级依次取**的过程，去掉某类自然抓到下一个。
/// → 过滤后若不足两个，按 [order] 从**该词实际有的段**里补位。
///
/// # ⚠️ 补位只看「段是否存在」，不看「质量好不好」
/// 这是有意的：判断「这个词源故事值不值得显示」需要看内容，
/// 而**内容已经在库里**（制卡时 `sections` 就是筛过的）→
/// 段存在即表示制卡时认为它可用。运行时不再重新评价。
class CardSlots {
  CardSlots._();

  /// 不上卡的类型（理由见类文档）。
  static const Set<String> offCard = {'context', 'cognate'};

  /// 补位顺序 —— **必须与库表 `mnemonic_type.priority` 一致**
  /// （已排除 [offCard] 两类）。由 `scripts/query_verify` 的断言守护一致性。
  ///
  /// 🔄 **2026-09-28 19:3x：回到「词源优先」**（白哥定）——
  /// `etymology`(3) 排在 `collocation`(4) **之前**，与 `mnemonic_type.priority` 逐项一致：
  /// 1 root · 3 etymology · 4 collocation · 5 image。
  ///
  /// 📜 **3/4 级当天改了两次**（如实记录，别再绕回来）：
  /// | 时间 | 顺序 | 结果 |
  /// |---|---|---|
  /// | 09-27 14:08 | etymology 3 / collocation 4 | 词源上卡 51.4% |
  /// | 09-28 18:2x | 改回 v1（collocation 3） | 搭配上卡 99.3%，**词源只剩 51.4%** |
  /// | 09-28 19:3x | **再改回词源优先**（本行） | 见下 |
  ///
  /// 🔑 **判据（两次改口的真正依据）**：当初说「`collocation` 条件恒真（99.3%）所以不该排前」——
  /// 但实测 **`etymology` 同样恒真（11,407 / 11,523 = 99.0%）** → 那条理由
  /// **对两者等效、不能裁决**。3/4 级只能靠产品判断：
  /// 卡片第二段给「**怎么用它**」（搭配）还是「**它从哪来**」（词源）。
  /// 📄 `docs/design/card-aggregate-plan-2026-09-28.html` §四
  static const List<String> order = [
    'root', // 1 词根词缀
    'etymology', // 3 词源故事
    'collocation', // 4 搭配整记
    'image', // 5 联想图像
  ];

  /// 最多两个槽位（设计稿 §03：「卡片只显示四样」，其中 ①② 是记忆法）。
  static const int maxSlots = 2;

  /// 解析出卡片上要渲染的记忆法槽位（**顺序即渲染顺序**）。
  ///
  /// 两轮：
  /// 1. 按 `profile` 给的顺序取（`primary` → `secondary_codes`）
  /// 2. 不足 [maxSlots] 时，按 [order] 从卡片实际段里**补位**
  ///
  /// 🔑 **2026-09-28 之后两轮等价**：`profile` 已改为**按 `priority` 算出**的
  /// （见 `scripts/priority_redo.py`），所以第一轮拿到的顺序就是 [order] 的顺序 ——
  /// 这正是 v1 §4.1 要求的「按 priority 选主/次」。
  /// ⚠️ 但**两轮都保留**：第一轮是「该词的判定结果」（可被重新判定覆盖），
  /// 第二轮是「无论判定如何，都按 priority 兜住」→ 双保险。
  static List<CardSlot> resolve({
    required WordCard card,
    required WordMnemonicProfile? profile,
  }) {
    final out = <CardSlot>[];
    final used = <String>{};

    void take(String code) {
      if (out.length >= maxSlots) return;
      if (offCard.contains(code)) return;
      if (!used.add(code)) return; // 同一个 code 只占一个槽位
      final s = card.sectionOfType(code);
      if (s == null) return; // 段不存在 → 跳过（不留空段）
      out.add(CardSlot(code: code, section: s));
    }

    // ① 尊重 profile 的判定顺序
    if (profile != null) {
      take(profile.primaryCode);
      for (final c in profile.secondaryCodes) {
        take(c);
      }
    }

    // ② 补位
    for (final c in order) {
      take(c);
    }

    return out;
  }
}

class AggregateLink {
  AggregateLink({
    required this.pageId,
    required this.pageType,
    required this.title,
    required this.memberCount,
  });

  final int pageId;

  /// `root`（词根族）或 `etymon`（词源族）
  final String pageType;

  /// 展示名（如「ag 词根族（Latin）」）
  final String title;

  final int memberCount;
}

// ─────────────────────────────────────────────────────────────
// 聚合页（词根族 / 词源族）
// ─────────────────────────────────────────────────────────────

/// 聚合页的**来源词根/词源**（`content.sections[0].source`）。
///
/// 用于两件事：
/// 1. 页头那行 `Latin · 拿取 · 22 个同族词`（语种 / 含义 / 规模）
/// 2. 🔑 **标出共享词根** —— 成员的分拆法里，`surface` 等于 [form] 的那一段
///    用强调色（设计稿：「共享词根用强调色标出」，是「一眼看出同一族」的钩子）
class AggregateSource {
  const AggregateSource({this.form, this.type, this.origin, this.meaning});

  /// 词根/词源的形式（如 `organ` / `capere`）
  final String? form;

  /// `root` / `etymon`
  final String? type;

  /// 语种（`Greek` / `Latin` / `Old English` …）
  final String? origin;

  final String? meaning;

  static AggregateSource? fromMap(Object? v) {
    if (v is! Map) return null;
    final m = v.cast<String, Object?>();
    return AggregateSource(
      form: m['form'] as String?,
      type: m['type'] as String?,
      origin: m['origin'] as String?,
      meaning: m['meaning'] as String?,
    );
  }
}

/// 聚合页的**页头 + 成员**。
class AggregatePage {
  const AggregatePage({
    required this.pageId,
    required this.pageType,
    required this.front,
    required this.memberCount,
    this.source,
    this.members = const [],
    this.glosses = const {},
  });

  final int pageId;

  /// `root`（词根族）/ `etymon`（词源族）
  final String pageType;

  /// 页头标题（如「organ 词根族（Greek）」）
  final String front;

  final int memberCount;
  final AggregateSource? source;

  /// 成员列表（**来自既有的 `aggregateMembers`** —— 自带「分拆法」）
  final List<AggregateMember> members;

  /// `word_id → 中文释义`（设计稿的成员行是「词 + 释义 + 分拆法」）。
  ///
  /// # 🔑 为什么不给 `AggregateMember` 加 `gloss` 字段
  /// `AggregateMember` 是**既有模型**（`aggregateMembers` 在用，有验收覆盖），
  /// 为一个展示需求改它的签名会牵动那条既有链路。
  /// 而释义**本来就在** `aggregate_page.content` 里（制卡时已预渲染）——
  /// 本方法顺手把它收成一张表，UI 按 `wordId` 取即可。
  /// 🔑 判据：**能在不扩散改动面的前提下满足需求，就不动既有结构**。
  final Map<String, String> glosses;
}

/// 聚合页成员 —— 带**分拆法**（白哥要求：不是单纯列单词）
class AggregateMember {
  AggregateMember({
    required this.wordId,
    required this.spelling,
    this.cefrLevel,
    this.morphology = const [],
  });

  final String wordId;
  final String spelling;
  final String? cefrLevel;
  final List<MorphPart> morphology;

  /// 「分拆法」渲染用：`dis-（不）+ organ（器官）+ -ized（使…化）`
  String get breakdown => morphology.isEmpty
      ? ''
      : morphology
          .map((p) => p.gloss == null || p.gloss!.isEmpty
              ? p.surface
              : '${p.surface}（${p.gloss}）')
          .join(' + ');
}

/// 词素（来自 `word_morpheme`，或 `root` 段的 `parts`）
class MorphPart {
  MorphPart({
    this.position = 0,
    required this.type,
    required this.surface,
    this.gloss,
    this.relation,
  });

  final int position;

  /// `root` / `prefix` / `suffix`
  final String type;

  /// 表面形（如 `dis-`、`organ`）
  final String surface;

  /// 中文释义（如「不」「器官」）
  final String? gloss;

  final String? relation;
}

/// 搭配项
class CollocationItem {
  CollocationItem({required this.phrase, required this.zh});

  final String phrase;
  final String zh;
}

/// 词形还原结果（来自 `word_form` 的链式表）
class LemmaResult {
  LemmaResult({
    required this.form,
    required this.base,
    this.rule,
    this.kind,
    this.anchor,
    this.depth,
    this.inVocab = false,
    this.action,
  });

  /// 输入形（如 `received`）
  final String form;

  /// 词元（如 `receive`）
  final String base;

  /// 变形规则（如 `past`、`plural`、`ing`）
  final String? rule;

  /// 变形类别
  final String? kind;

  /// 链式锚点（上溯终点，通常是词源锚）
  final String? anchor;

  /// 距锚点的层数
  final int? depth;

  /// 该 `form` **本身是否也是词表词条**（如 `running` 若在词表中则为 true）
  final bool inVocab;

  /// 路由动作（用于区分「直接映射」与「需跳转」）
  final String? action;

  /// 是否发生了实际还原（输入 ≠ 词元）
  bool get isChanged => form.toLowerCase() != base.toLowerCase();
}
