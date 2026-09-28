import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

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
  WordQueryService._(this._db, this.path);

  final Database _db;

  /// 打开的库路径（诊断用）
  final String path;

  /// 打开**只读**词库。
  ///
  /// ⚠️ 工厂由调用方注入，这是本层「可在纯 Dart 下验证」的关键：
  /// - App：`WordQueryService.open(databaseFactory, path)`
  /// - 验证脚本：`WordQueryService.open(databaseFactoryFfi, r'...\data\word.db')`
  static Future<WordQueryService> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    return WordQueryService._(db, path);
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
  Future<LemmaResult?> analyzeForm(String rawText) async {
    final form = _normalize(rawText);
    if (form.isEmpty) return null;

    final rows = await _db.rawQuery(
      'SELECT form, base, rule, kind, anchor, depth, in_vocab, action '
      'FROM word_form WHERE form = ? LIMIT 1',
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

  /// 按 `word.id` 取词条卡片 —— **复习页用**（那里只有 `word_id`，没有拼写）。
  ///
  /// 与 [_cardBySpelling] 的差别只在 `WHERE` 列；解析逻辑共用 [_cardFromRow]。
  Future<WordCard?> cardById(String wordId) async {
    final rows = await _db.rawQuery(
      'SELECT w.id, w.spelling, w.cefr_level, w.entry_type, w.etymology_text, w.sort_seq, '
      '       c.content, c.content_hash, c.template_code '
      'FROM word w LEFT JOIN card c ON c.word_id = w.id '
      'WHERE w.id = ? LIMIT 1',
      [wordId],
    );
    if (rows.isEmpty) return null;
    return _cardFromRow(rows.first);
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

  /// `cognate` 段的**词群标签**（如「organ 词根族（Greek）」）。
  ///
  /// 🔴 为什么要专门加这个访问器（2026-09-28）：
  /// `cognate` 段**没有故事文本** —— 它只有 `payload{group_id,label,size,origin}`
  /// （同源族的成员与「分拆法 + 释义」都在**聚合页**，设计稿明确「不铺在卡上」）。
  /// 而卡片要显示 ② 就必须有东西可显示 → 标签是它唯一的文本内容。
  ///
  /// ⚠️ **不要把 `etymology.text` 拿来填 `cognate`** —— 那是**另一类**的内容
  /// （词源故事 ≠ 同源串记），混用会让卡片显示与槽位标注不符的信息。
  ///
  /// 返回 `null` = 无标签（调用方走兜底文案）。
  String? get cognateLabel {
    final payload = _asMap(raw['payload']);
    final label = (payload?['label'] as String?)?.trim();
    if (label == null || label.isEmpty) return null;
    final origin = (payload?['origin'] as String?)?.trim();
    final size = payload?['size'];
    final buf = StringBuffer(label);
    if (origin != null && origin.isNotEmpty) buf.write('（$origin）');
    if (size is int && size > 0) buf.write(' · $size 词');
    return buf.toString();
  }

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
/// | `cognate` | 2 | 同源串记 |
/// | `etymology` | 3 | 词源故事 |
/// | `collocation` | 4 | 搭配整记 |
/// | `image` | 5 | 联想图像 |
/// | `context` | 6 | 语境原句（默认附加） |
///
/// ⚠️ 设计稿 HTML 写的是 `…collocation(3) → etymology(4)`，**与库表相反**。
///    本实现以库为准（数据 > 手绘稿），且因为直接用本表的分配结果，
///    **不经过优先级排序** → 绕开了这处矛盾。
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

/// 聚合页入口（内嵌在卡片段里）
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
