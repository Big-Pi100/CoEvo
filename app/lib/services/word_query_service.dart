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

    final r = rows.first;
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
      aggregateLinks: await aggregateLinks(id),
    );
  }

  static List<WordSection> _parseSections(Map<String, Object?> content) {
    final raw = content['sections'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => WordSection(m.cast<String, Object?>()))
        .toList(growable: false);
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
class WordSection {
  WordSection(this.raw);

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

  static Map<String, Object?>? _asMap(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;
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
