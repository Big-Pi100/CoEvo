/// A3 · 制卡回流 —— **核心逻辑**（纯逻辑 + sqlite，不含 CLI）。
///
/// # 它做四件事（顺序固定）
/// ```
/// 导出 JSON ──▶ ① 形状转换 ──▶ ② 序列化成词库格式 ──▶ ③ 算 hash ──▶ ④ 幂等写库
///                toCardContent        pyJsonEncode       sha256[:32]     word + card
/// ```
///
/// # 🔴 为什么必须用 Dart（而不是 Python 写这一层）
/// ① 的**唯一实现**是 `app/lib/services/generated_card_adapter.dart::toCardContent`（Dart）。
/// 用 Python 重写 = **第二份转换实现** ⇒ 与 Dart 必然分叉，而分叉是**静默的**
/// （字段少一个 → 卡片少一段，只有用户看得见）。
/// ⇒ 本文件**不自己转换**，只 `import` 那个适配器。
/// （项目判据：**同一件事的口径只能一处权威**。）
///
/// # 🔴 ② 为什么还要「重新序列化」一次
/// `toCardContent` 返回的是 **Dart `jsonEncode` 的紧凑格式**：
/// ```
/// {"front":"x","ipa":"y"}        ← Dart jsonEncode（无空格）
/// ```
/// 而既有 `word.db.card.content`（11523 行）实测**全部**是 **Python `json.dumps` 风格**：
/// ```
/// {"front": "x", "ipa": "y"}     ← 逗号/冒号后**有空格**
/// ```
/// ⇒ 直接写紧凑格式会让词库**内部格式不统一**，并且让「重算 `content_hash` 的
///   Python 工具」（`apply_card_field_fixes.py` 等）**算出不同的 hash**。
///
/// ✅ 所以这里补一层 [pyJsonEncode]（复刻 Python `json.dumps(v, ensure_ascii=False)`），
///    **只调格式、不动形状**。
/// 🔑 它与既有 11523 行的一致性**是可断言的**（见 `verify_reflow.dart` ①）——
///    不是「我们相信它一致」，而是「逐字节验过」。
///
/// # ④ 幂等靠什么
/// 「`spelling` 已存在 ⇒ 跳过」（`COLLATE NOCASE`，与 `UNIQUE(spelling)` 同口径）
/// ⇒ 同一份导出跑两次，第二次**零插入**。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../app/lib/services/external_word_id.dart';
import '../../../app/lib/services/generated_card_adapter.dart';

// ══════════════════════════════════════════════════════════════════════
// ① Python 风格 JSON 序列化 —— 复刻 json.dumps(v, ensure_ascii=False)
// ══════════════════════════════════════════════════════════════════════

/// 与 Python `json.dumps(v, ensure_ascii=False)` **逐字节一致**的序列化。
///
/// # 为什么不能「用 jsonEncode 再正则插空格」
/// 因为 `,` 与 `:` 会出现在**字符串内容里**：
/// ```
/// "en": "the round fruit of a tree, ..."   ← 这个逗号**不能**变成 ", "
/// ```
/// ⇒ 只能**递归遍历结构**，在「结构位置」插空格，字符串一律走转义。
///
/// # 与 Python 的对齐点（逐条）
/// | 情形 | Python `json.dumps` | 本函数 |
/// |---|---|---|
/// | 分隔符 | `', '` / `': '`（**默认值**，带空格）| 同 |
/// | 非 ASCII | `ensure_ascii=False` ⇒ **原样输出**（不转 `\uXXXX`）| 同 |
/// | 控制字符 | `\b \f \n \r \t` 用短转义；其余 `< 0x20` 用 `\u00xx` | 同 |
/// | `/` | **不转义** | 同 |
/// | 整数 | 十进制 | 同 |
/// | 布尔 / null | `true` / `false` / `null` | 同 |
///
/// ⚠️ **本词库的叶子值只有 `String` 与 `int`**（2026-10-09 实测 341,746 str + 29,875 int，
///    **无 float / bool / null**）⇒ 数值分支只是防御性兜底，不参与实际转换。
String pyJsonEncode(Object? v) {
  final b = StringBuffer();
  _pyEnc(v, b);
  return b.toString();
}

void _pyEnc(Object? v, StringBuffer b) {
  if (v == null) {
    b.write('null');
  } else if (v is String) {
    b.write(_pyEncString(v));
  } else if (v is bool) {
    b.write(v ? 'true' : 'false');
  } else if (v is int) {
    b.write(v.toString());
  } else if (v is num) {
    b.write(_pyEncNum(v));
  } else if (v is Map) {
    b.write('{');
    var first = true;
    v.forEach((k, val) {
      if (!first) b.write(', ');
      first = false;
      b.write(_pyEncString(k is String ? k : k.toString()));
      b.write(': ');
      _pyEnc(val, b);
    });
    b.write('}');
  } else if (v is List) {
    b.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) b.write(', ');
      _pyEnc(v[i], b);
    }
    b.write(']');
  } else {
    // 兜底：既有数据不该走到这里（只有 str/int）——按字符串处理而不是抛错
    b.write(_pyEncString(v.toString()));
  }
}

/// Python `json.dumps` 的字符串转义（`ensure_ascii=False`）。
///
/// 用 `runes` 迭代以正确跨过**代理对**（emoji 等 U+10000+ 字符），
/// 否则会按半个代理遍历、产出坏字符串。
String _pyEncString(String s) {
  const shortEsc = <int, String>{
    0x08: r'\b',
    0x09: r'\t',
    0x0a: r'\n',
    0x0c: r'\f',
    0x0d: r'\r',
    0x22: r'\"',
    0x5c: r'\\',
  };
  final b = StringBuffer('"');
  for (final r in s.runes) {
    final e = shortEsc[r];
    if (e != null) {
      b.write(e);
    } else if (r < 0x20) {
      b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
    } else {
      // ✅ 非 ASCII **原样**（ensure_ascii=False）；`/` 不转义
      b.write(String.fromCharCode(r));
    }
  }
  b.write('"');
  return b.toString();
}

/// 数值：整数走 [int] 分支；浮点只在**没有整数表示**时才出现（本库无浮点）。
String _pyEncNum(num v) {
  if (v is double) {
    if (v.isNaN) return 'NaN'; // Python 同（非标准 JSON，但保持一致）
    if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
    if (v == v.truncateToDouble() && v.abs() < 1e16) return '${v.toInt()}.0';
  }
  return v.toString();
}

// ══════════════════════════════════════════════════════════════════════
// ② content_hash —— 与既有落库链**同一算法**
// ══════════════════════════════════════════════════════════════════════

/// `content_hash` = `sha256(content + 各 card_extra 段的 JSON).hexdigest()[:32]`。
///
/// 口径出处：`scripts/load_llm_results.py`（`apply_card_field_fixes.py` 的注释亦声明
/// 「与 `load_llm_results.py` 完全一致的算法（否则 hash 失去意义）」）。
///
/// 🔑 **回流词没有 `card_extra`**（那是既有词库的附加段）⇒ [extras] 为空
/// ⇒ 实际就是 `sha256(content)[:32]`。
/// ⚠️ 参数保留是为了**算法只有一处实现** —— 将来若回流也产 extra 段，不必再写第二份。
String contentHashOf(String content, [List<Object?> extras = const []]) {
  final buf = StringBuffer(content);
  for (final e in extras) {
    buf.write(pyJsonEncode(e));
  }
  return sha256.convert(utf8.encode(buf.toString())).toString().substring(0, 32);
}

// ══════════════════════════════════════════════════════════════════════
// ③ 回流
// ══════════════════════════════════════════════════════════════════════

/// 一个候选（来自导出 JSON）。
class ReflowCandidate {
  const ReflowCandidate({
    required this.spelling,
    required this.rawCard,
    required this.contractVersion,
    this.hitCount = 0,
    this.distinctUserCount = 0,
  });

  final String spelling;

  /// **LLM 原始输出**形状（平铺字段），即 `toCardContent` 的输入。
  final Map<String, Object?> rawCard;
  final String contractVersion;
  final int hitCount;
  final int distinctUserCount;

  factory ReflowCandidate.fromJson(Map<String, Object?> j) => ReflowCandidate(
        spelling: (j['spelling'] ?? '') as String,
        rawCard: ((j['raw_card'] ?? const <String, Object?>{}) as Map)
            .cast<String, Object?>(),
        contractVersion: (j['contract_version'] ?? '') as String,
        hitCount: (j['hit_count'] ?? 0) as int,
        distinctUserCount: (j['distinct_user_count'] ?? 0) as int,
      );
}

/// 跳过原因（**穷举**，不用自由文本 —— 便于按原因计数与断言）。
enum ReflowSkip {
  /// 拼写归一化后为空（数据坏了）
  emptySpelling,

  /// `word` 表里已有同拼写（**幂等的实现**）
  alreadyInWordDb,

  /// 契约版本不是端侧认识的那个 ⇒ 不猜字段
  contractMismatch,

  /// `toCardContent` 显式失败（缺 `definition` / 空拼写等）
  conversionFailed,
}

extension ReflowSkipLabel on ReflowSkip {
  String get label => switch (this) {
        ReflowSkip.emptySpelling => '拼写为空',
        ReflowSkip.alreadyInWordDb => '词库已有',
        ReflowSkip.contractMismatch => '契约版本不符',
        ReflowSkip.conversionFailed => '转换失败',
      };
}

/// 成功写入一条。
class ReflowInserted {
  const ReflowInserted({
    required this.spelling,
    required this.wordId,
    required this.contentHash,
    required this.contentBytes,
    required this.sectionCount,
  });
  final String spelling;
  final String wordId;
  final String contentHash;
  final int contentBytes;
  final int sectionCount;
}

/// 跳过一条（带原因与可选细节）。
class ReflowSkipped {
  const ReflowSkipped(this.spelling, this.reason, [this.detail = '']);
  final String spelling;
  final ReflowSkip reason;
  final String detail;
}

/// 回流结果报告。
class ReflowReport {
  ReflowReport({
    required this.inserted,
    required this.skipped,
    required this.firstWordId,
    required this.dryRun,
  });

  final List<ReflowInserted> inserted;
  final List<ReflowSkipped> skipped;
  final String? firstWordId;
  final bool dryRun;

  int countOf(ReflowSkip r) => skipped.where((s) => s.reason == r).length;

  /// 人类可读摘要（CLI 直接打印）。
  String summary() {
    final b = StringBuffer()
      ..writeln('${dryRun ? '【干跑】' : '【已写入】'} '
          '插入 ${inserted.length} 条 / 跳过 ${skipped.length} 条');
    if (inserted.isNotEmpty) {
      b.writeln('  首条 id = ${inserted.first.wordId}，末条 id = ${inserted.last.wordId}');
    }
    for (final r in ReflowSkip.values) {
      final n = countOf(r);
      if (n > 0) b.writeln('  跳过 · ${r.label}：$n');
    }
    for (final s in skipped) {
      final shown = s.spelling.trim().isEmpty ? '<空白>' : s.spelling;
      b.writeln('    - $shown（${s.reason.label}'
          '${s.detail.isEmpty ? '' : '：${s.detail}'}）');
    }
    return b.toString();
  }
}

/// `w011523` / `w000001` 形态的 id。
String wordIdOfSeq(int seq) => 'w${seq.toString().padLeft(6, '0')}';

/// 从 id 反推序号（`w011523` → 11523）。非预期形态返回 `0`（由调用方判定异常）。
int seqOfWordId(String id) {
  final digits = id.replaceAll(RegExp(r'[^0-9]'), '');
  return int.tryParse(digits) ?? 0;
}

/// 把候选**幂等**写进 `word` + `card` 两表。
///
/// # 只写两张表（**有意为之**）
/// `aggregate_page` / `cognate_group` / `etymon` / `collocation` / `word_form`
/// 都来自**全量语料分析**，**单张卡推不出来** ⇒ 回流词没有它们
/// （端侧表现：没有聚合页入口 / 同源词 / 词根族 / 搭配网 / 词形链，只能精确拼写命中）。
/// ⚠️ 这是**已知且接受的**边界，不是遗漏。
///
/// # [dryRun]
/// 走**完全相同**的转换与校验，但**不写**（也不开事务）——
/// 于是「干跑通过」才真正意味着「写进去会是这些行」。
Future<ReflowReport> reflowIntoWordDb(
  Database db,
  List<ReflowCandidate> candidates, {
  bool dryRun = false,
}) async {
  final head = await db.rawQuery(
      'SELECT id, sort_seq FROM word ORDER BY sort_seq DESC LIMIT 1');

  var nextSeq = 1;
  if (head.isNotEmpty) {
    final lastId = head.first['id'] as String;
    final lastSort = (head.first['sort_seq'] as num).toInt();
    final seqFromId = seqOfWordId(lastId);
    if (seqFromId != lastSort) {
      // 🔴 不静默续号：id 与排序号不同步时续号可能**撞已有 id**
      throw StateError(
        '词库主键与排序号不同步：末行 id=$lastId（推出 $seqFromId）vs sort_seq=$lastSort '
        '⇒ 拒绝续号（否则可能生成重复 id）',
      );
    }
    nextSeq = lastSort + 1;
  }

  final inserted = <ReflowInserted>[];
  final skipped = <ReflowSkipped>[];

  Future<void> work(DatabaseExecutor exec) async {
    for (final c in candidates) {
      final normalized = normalizeExternalSpelling(c.spelling);
      if (normalized.isEmpty) {
        skipped.add(ReflowSkipped(c.spelling, ReflowSkip.emptySpelling));
        continue;
      }

      // ── 幂等的实现：同拼写已在词库 ⇒ 跳过（与 UNIQUE(spelling) 同口径）──
      final exists = await exec.rawQuery(
          'SELECT id FROM word WHERE spelling = ? COLLATE NOCASE LIMIT 1',
          [normalized]);
      if (exists.isNotEmpty) {
        skipped.add(ReflowSkipped(
            normalized, ReflowSkip.alreadyInWordDb, exists.first['id'] as String));
        continue;
      }

      // ── 契约不符 ⇒ 不猜字段（与端侧同策略）──
      if (c.contractVersion != kKnownContractVersion) {
        skipped.add(ReflowSkipped(normalized, ReflowSkip.contractMismatch,
            '${c.contractVersion} != $kKnownContractVersion'));
        continue;
      }

      // ── ① 形状转换（**唯一实现**在适配器里）+ ② 序列化成词库格式 ──
      String content;
      final Map<String, Object?> contentMap;
      try {
        final compact = toCardContent(
          c.rawCard,
          spelling: normalized,
          contractVersion: c.contractVersion,
        );
        contentMap = (jsonDecode(compact) as Map).cast<String, Object?>();
        content = pyJsonEncode(contentMap);
      } on GeneratedCardException catch (e) {
        // 🔴 转换失败 ⇒ **不写库**（绝不留半张卡）
        skipped.add(
            ReflowSkipped(normalized, ReflowSkip.conversionFailed, e.message));
        continue;
      }

      // ── ③ hash（与既有落库链同算法；回流无 card_extra ⇒ extras 为空）──
      final hash = contentHashOf(content);

      // ── 从**已转换的 content** 取 word 表的列（口径只有一处：toCardContent 已判定）──
      final entryType = _entryTypeOf(contentMap);
      final etymologyText = _etymologyTextOf(contentMap);
      final sections =
          contentMap['sections'] is List ? (contentMap['sections'] as List) : const [];

      final id = wordIdOfSeq(nextSeq);
      nextSeq++;

      if (!dryRun) {
        await exec.insert('word', {
          'id': id,
          'sort_seq': seqOfWordId(id),
          // 🔑 归一化后写入：发版收敛用 `WHERE spelling = ? COLLATE NOCASE` 反查，
          //    而归一化与 `ext:` 的构造侧**是同一个函数** ⇒ 必然命中
          'spelling': normalized,
          // ⚠️ LLM 契约里**没有** cefr_level（2026-10-09 核对）⇒ 留空。
          //    留空是**如实**（不知道就是不写），不是「忘了填」。
          'cefr_level': null,
          'entry_type': entryType,
          'etymology_text': etymologyText,
        });
        await exec.insert('card', {
          'word_id': id,
          'content': content,
          'content_hash': hash,
          // 既有词库里该列全为 NULL ⇒ 保持同形
          'template_code': null,
        });
      }

      inserted.add(ReflowInserted(
        spelling: normalized,
        wordId: id,
        contentHash: hash,
        contentBytes: utf8.encode(content).length,
        sectionCount: sections.length,
      ));
    }
  }

  if (dryRun) {
    await work(db);
  } else {
    await db.transaction(work);
  }

  return ReflowReport(
    inserted: inserted,
    skipped: skipped,
    firstWordId: inserted.isEmpty ? null : inserted.first.wordId,
    dryRun: dryRun,
  );
}

/// `content.entry_type`（`toCardContent` 已把空值折成 `word`）—— 直接取权威结果。
String _entryTypeOf(Map<String, Object?> contentMap) {
  final v = contentMap['entry_type'];
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? 'word' : s;
}

/// `word.etymology_text` = `content.sections` 里 `type == 'etymology'` 的 `text`。
///
/// 🔑 **从 content 取而不是从 raw_card 取**：`toCardContent` 已经做过「空则不出该段」的
/// 判定 ⇒ 从它取保证「词表列」与「卡片段」**永远同进同出**（不会出现「有词源文本但没有词源段」）。
String? _etymologyTextOf(Map<String, Object?> contentMap) {
  final sections = contentMap['sections'];
  if (sections is! List) return null;
  for (final s in sections) {
    if (s is Map && s['type'] == 'etymology') {
      final t = s['text'];
      if (t is String && t.trim().isNotEmpty) return t;
      return null;
    }
  }
  return null;
}
