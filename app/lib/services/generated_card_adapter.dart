/// 在线制卡的**契约转换** —— 服务端 `card` JSON（LLM 输出形状）→ **端侧渲染形状**。
///
/// # 🔴 为什么必须有这一层（两层形状**不一样**，实测）
/// | | 形状 | 谁定的 |
/// |---|---|---|
/// | 服务端返回的 `card` | LLM 输出 schema：**平铺字段** `{word, ipa, entry_type, morphology, etymology, definition, context, collocations, …}` | `backend/prompts/wordlib_contract.md` |
/// | 端侧渲染要的 | `{front, ipa, entry_type, sections:[{type, …}]}` | `word.db.card.content`（由 `WordSection` 的访问器读） |
///
/// ⚠️ 两者**不是一回事**。`llm_card.rs` 里那句「与 `word.db` 的 `card.content` **同构**」
/// 指的是「**语义同构**（信息量一致，可转换）」而**非形状相同** ——
/// 我 2026-10-01 实测时才确认这一点（`GenResult.card` 就是 `serde_json::from_str(reply)`，
/// **没有任何形状转换**）。⇒ 转换**必须**由端侧做。
///
/// # 🔑 本文件为什么是「纯函数」（零 IO、零框架）
/// 它是**契约的唯一落点** —— 服务端改 prompt/契约会在这里表现为「字段对不上」，
/// 而那正是最该被自动化守住的地方。抽成纯函数才能用真实 JSON 直接断言
/// （见 `scripts/query_tests/...` / `scripts/query_verify/bin/verify_generated_card_adapter.dart`）。
///
/// # 🔴 产出**严格对齐 `word.db.card.content`**（有意为之，别「顺手多带字段」）
/// | LLM 有 | 产出 | 为什么 |
/// |---|---|---|
/// | `morphology.parts[].origin` | ❌ **丢弃** | `word.db` 的 `payload.parts[]` 只有 `{form,type,meaning,relation}` |
/// | `morphology.relation`（**顶层**）| ✅ 复制进**每个** part | 落库链（`load_llm_results.py`）就是这么做的 —— `word_morpheme.relation` 取的是顶层值 |
/// | `etymology.etyma[].form_ascii` / `.parent` | ❌ **丢弃** | `word.db` 的 `etyma[]` 只有 `{form,language,meaning,role}` |
/// | `entry`（聚合页入口）| ❌ **不产出** | 词库外的词**没有聚合页**（那是按全库算的族）→ 卡片上不显示箭头、不可点。⚠️ 这是**正确**状态，不是缺失 |
/// | `mnemonic` / `confidence` / `reason` / `is_own_entry` … | ❌ **丢弃** | 服务端内部字段，端侧不渲染 |
///
/// 🔑 **为什么要严格对齐**：词被回流后（`ext:brainstorm` → `w011524`），端侧只是
///    **换了取卡来源**（缓存 → `word.db`）。形状一致 ⇒ **收敛切换真正做到无缝**，
///    且渲染层的每条路径都已被词库内词验证过。
///
/// # ⚠️ 边界（如实标注）
/// · **不校验**内容质量 —— 那是服务端两道闸门（合规 + 格式）的职责，端侧只做形状转换
/// · `contractVersion` 只负责**透传与告警**，不做版本分支 —— 目前只有 v6 一种；
///   真要升级且不兼容时，应在这里**显式失败**（而不是静默产出空卡）
library;

import 'dart:convert';

import 'external_word_id.dart';

/// 转换失败的**唯一**异常类型。
///
/// 🔑 用异常而不是「返回 null」：调用方必须**显式处理**（写日志 / 提示用户），
///    而 `null` 容易被当成「这个词没有卡」——两者语义完全不同。
class GeneratedCardException implements Exception {
  const GeneratedCardException(this.message);
  final String message;
  @override
  String toString() => 'GeneratedCardException: $message';
}

/// LLM 契约版本（端侧认识的版本）。
///
/// ⚠️ 不认识时要**显式失败**（见 [toCardContent]）—— 宁可报错，也不要静默出一张空卡。
const String kKnownContractVersion = 'v6';

/// 服务端 `card` JSON → **`word.db.card.content` 形状**的 JSON 字符串。
///
/// 产出可直接：
/// · 存进 `external_word_cache.card_content`
/// · 喂给 `WordSection` / `WordCard`
///
/// 🔴 返回**字符串**而不是 `Map`：因为它的两个消费点（写库 / 解析）都要字符串，
///    在此处序列化可避免「忘了序列化」这类错（且 JSON 编码失败只可能在这里发生）。
String toCardContent(
  Map<String, Object?> card, {
  required String spelling,
  String contractVersion = '',
}) {
  // 🔴 版本不匹配 → **显式失败**，不猜字段
  //    理由：契约升级通常伴随字段改名/改形，静默转换会产出**结构合法但内容为空**的卡
  //    —— 那种错最难发现（不报错、只显示空释义）。
  if (contractVersion.isNotEmpty && contractVersion != kKnownContractVersion) {
    throw GeneratedCardException(
      '服务端契约 $contractVersion 与端侧认识的 $kKnownContractVersion 不一致，'
      '已停止转换（避免静默出空卡）',
    );
  }

  final normalized = normalizeExternalSpelling(spelling);
  if (normalized.isEmpty) {
    throw const GeneratedCardException('拼写为空');
  }

  final sections = <Map<String, Object?>>[];

  // ── ① root（词根词缀拆分）—— 仅当可拆 ──
  final morphology = _map(card['morphology']);
  final parts = _rootsParts(morphology);
  if (parts.isNotEmpty) {
    sections.add({
      'type': 'root',
      'payload': {
        'parts': parts,
        'relation': _str(morphology?['relation']),
      },
      // ⚠️ 无 `entry` —— 词库外的词没有聚合页（见文件头表格）
    });
  }

  // ── ② collocation（搭配整记）──
  final colls = _collocations(card['collocations']);
  if (colls.isNotEmpty) {
    sections.add({'type': 'collocation', 'items': colls});
  }

  // ── ③ etymology（词源故事）──
  final etText = _str(_map(card['etymology'])?['text']).trim();
  if (etText.isNotEmpty) {
    sections.add({
      'type': 'etymology',
      'text': etText,
      'etyma': _etyma(_map(card['etymology'])?['etyma']),
    });
  }

  // ── ④ definition（释义）—— 必须有 ──
  final def = _map(card['definition']);
  if (def == null) {
    // 服务端的格式闸门已保证 `definition.en` / `.zh` 非空（`gate()`），
    // 所以走到这里说明**响应形状与预期不符** → 显式失败，不要产出无释义的卡
    throw const GeneratedCardException('响应缺 definition（服务端闸门本应拦住）');
  }
  sections.add({
    'type': 'definition',
    'order': 1,
    'pos': _str(def['pos']),
    'en': _str(def['en']),
    'zh': _str(def['zh']),
  });

  // ── ⑤ context（语境原句，= 卡片 ④ 的固定位置）──
  final ctx = _str(card['context']).trim();
  if (ctx.isNotEmpty) {
    sections.add({'type': 'context', 'text': ctx});
  }

  final content = <String, Object?>{
    // 🔑 `front` 是 `card.content` 的词头字段名（不是 LLM 的 `word`）
    'front': normalized,
    'ipa': _str(card['ipa']).trim(),
    'entry_type': _str(card['entry_type']).trim().isEmpty
        ? 'word'
        : _str(card['entry_type']).trim(),
    'sections': sections,
  };

  return jsonEncode(content);
}

/// 从已转换的 `card.content` JSON 取 `sections`（供 `WordCard` 构造）。
///
/// 🔑 与 [toCardContent] 配对：一个负责「LLM → 存储形状」，一个负责「存储形状 → 渲染」。
///    `cardById` 的 `ext:` 回落分支用它。
///
/// ⚠️ 坏 JSON / 无 sections 一律返回**空列表**（不是抛错）——
///    缓存里的一条坏数据不该让整张卡渲染不出来（同 `WordMnemonicProfile._parseCodes` 的原则：
///    「一条坏数据不该让卡片整张渲染不出来」）。
///    👉 但**转换期**（[toCardContent]）是**严格**的：那里出错要显式失败，
///       因为那是「刚拿到的数据」，静默吞掉等于把问题存进库里。
({String front, String ipa, String entryType, List<Map<String, Object?>> sections})
    parseCardContent(String rawJson) {
  try {
    final d = jsonDecode(rawJson);
    if (d is! Map) return _emptyContent;
    final m = d.cast<String, Object?>();
    final raw = m['sections'];
    final secs = <Map<String, Object?>>[];
    if (raw is List) {
      for (final s in raw) {
        if (s is Map) secs.add(s.cast<String, Object?>());
      }
    }
    return (
      front: _str(m['front']),
      ipa: _str(m['ipa']),
      entryType: _str(m['entry_type']),
      sections: secs,
    );
  } catch (_) {
    return _emptyContent;
  }
}

const _emptyContent = (
  front: '',
  ipa: '',
  entryType: '',
  sections: <Map<String, Object?>>[],
);

/// 从 `sections` 里取**首义中文** —— `type == 'definition'` 中 `order` 最小那条的 `zh`。
///
/// # 🔑 为什么单独抽出来（2026-10-17 真机 bug）
///
/// 原先 `WordQueryService._firstDefinitionZh` **自己又写了一份 JSON 解析**
/// （先 `jsonDecode` → 找 `sections` → 找 `definition`），
/// 而 `cardById` 的注释明明白白写着「**别在这里另写一份 JSON 解析**」。
///
/// 更要命的是：**两份实现里只有一份跟上了 `ext:` 这个新来源** ——
/// 于是复习列表里 LLM 生成的词（`ext:<spelling>`）**没有释义**，而词库词有。
///
/// 📌 判据：**同一件事的口径只能有一处权威**。
///    ⇒ 现在：解析只有 [parseCardContent] 一处，**取首义只有本函数一处**；
///      `cardById`（卡片页 / 复习会话）与 `firstDefinitionsOf`（复习列表）**共用**。
///
/// ⚠️ 缺段 / 缺字段 / 类型不对一律返回 `null`（**不是空串**）——
///    让调用方能区分「没有释义」与「释义是空的」。
String? firstDefinitionZhOf(List<Map<String, Object?>> sections) {
  Map<String, Object?>? best;
  var bestOrder = 1 << 30;
  for (final s in sections) {
    if (s['type'] != 'definition') continue;
    final o = (s['order'] as int?) ?? 0;
    if (o < bestOrder) {
      bestOrder = o;
      best = s;
    }
  }
  final zh = best?['zh'];
  if (zh is! String) return null;
  final trimmed = zh.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ─────────────────────────────────────────────────────────────
// 内部取值助手 —— 一律**宽容读取、不抛错**
// ─────────────────────────────────────────────────────────────
// 🔑 与「转换期严格」并不矛盾：严格体现在**必须存在的字段**（`definition`）上；
//    可选段（root / collocation / etymology / context）缺了就少一段，
//    这是**合法**的（`word.db` 实测：3,000 条里 root 只有 1,191 条有）。

Map<String, Object?>? _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

String _str(Object? v) => v is String ? v : '';

List<Object?> _list(Object? v) => v is List ? v : const [];

/// `morphology.parts[]` → `payload.parts[]`（**只保留 word.db 里有的四个字段**）。
///
/// 🔴 三处要点：
/// ① `analyzable != true` → **空**（不可拆分就不产 root 段）
/// ② `relation` 取**顶层**的值、**逐 part 复制** —— 与落库链
///    （`load_llm_results.py`：`word_morpheme.relation = mo.get('relation')`）一致
/// ③ `form` 取 `form`；`meaning` 取 `meaning`（`WordSection.parts` 也认 `surface`/`gloss`
///    这两个别名，但 `word.db` 用的是 `form`/`meaning` → 产出同一套，别混用）
List<Map<String, Object?>> _rootsParts(Map<String, Object?>? m) {
  if (m == null || m['analyzable'] != true) return const [];
  final relation = _str(m['relation']);
  final out = <Map<String, Object?>>[];
  for (final p in _list(m['parts'])) {
    final pm = _map(p);
    if (pm == null) continue;
    final form = _str(pm['form']).trim();
    if (form.isEmpty) continue;
    out.add({
      'form': form,
      'type': _str(pm['type']).trim(),
      'meaning': _str(pm['meaning']).trim(),
      'relation': relation,
    });
  }
  return out;
}

/// `collocations[]` → `items[]`（`{phrase, zh}`）。
List<Map<String, Object?>> _collocations(Object? raw) {
  final out = <Map<String, Object?>>[];
  for (final c in _list(raw)) {
    final cm = _map(c);
    if (cm == null) continue;
    final phrase = _str(cm['phrase']).trim();
    if (phrase.isEmpty) continue;      // 只有中文没有词组的条目没有意义
    out.add({'phrase': phrase, 'zh': _str(cm['zh']).trim()});
  }
  return out;
}

/// `etymology.etyma[]` → `etyma[]`（**丢掉 `form_ascii` / `parent`**，见文件头表格）。
List<Map<String, Object?>> _etyma(Object? raw) {
  final out = <Map<String, Object?>>[];
  for (final e in _list(raw)) {
    final em = _map(e);
    if (em == null) continue;
    final form = _str(em['form']).trim();
    if (form.isEmpty) continue;
    out.add({
      'form': form,
      'language': _str(em['language']).trim(),
      'meaning': _str(em['meaning']).trim(),
      'role': _str(em['role']).trim(),
    });
  }
  return out;
}
