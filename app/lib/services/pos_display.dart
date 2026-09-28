/// 词性（`definition.pos`）的显示归一化 —— **零 Flutter 依赖**，可独立断言。
///
/// # 为什么需要它
/// 实测 `word.db` 里 `pos` 有 **47 种写法**，同一个词性最多三种写法：
///
/// | 写法 | 条数 | 例 |
/// |---|---|---|
/// | 带方括号缩写 | **84.4%** | `[n]` 5736 · `[adj]` 2270 · `[v]` 1222 |
/// | 纯缩写 | **14.7%** | `verb` 541 · `n` 452 · `noun` 337 |
/// | 其他（可数性 / 复合） | 0.9% | `[c, u]` · `[adj/adv]` · `[modal v]` · `[adj（phrase）]` |
///
/// → 不归一化，浮层上的词性会**时方括号时全称时带点**，同一个 App 里三种风格。
///
/// # 🔴 规则为什么必须放在「一处」
/// 这类映射的典型命运是**在渲染层就地写死一份**，然后第二个用到的地方再抄一份、
/// 加个特例、两处慢慢分叉（本项目已有多次同型事故，见 skill `verifiable-core-logic` 铁律六）。
/// 所以：**映射表只在本文件**，浮层/词卡/聚合页都调 [normalizePos]。
///
/// # 归一化目标：词典惯例缩写（带句点）
/// `n.` `adj.` `v.` `adv.` `prep.` … —— 用户在纸质词典里见惯了这套。
/// 不改成中文全称（「名词」「形容词」）：浮层空间小，且**缩写本身就是词典素养的一部分**。
///
/// # 三类输入的处理
///
/// | 输入 | 输出 | 说明 |
/// |---|---|---|
/// | `[n]` / `n` / `noun` | `n.` | 同一词性的三种写法 → 同一显示 |
/// | `[c, u]` / `[u, c]` / `[n pl]` | `n.` | 🔑 **`c`/`u` 是「可数/不可数」，不是词性** → 都归名词（去重后只剩 `n.`） |
/// | `[adj/adv]` | `adj. / adv.` | 复合词性保留两段 |
/// | `[adj（phrase）]` | `adj.` | 全角括号注释被剥掉 |
/// | `[modal verb]` | `modal v.` | 整串匹配优先于拆词 |
/// | 未知词 | **原样保留** | 🔑 **不猜** —— 猜错比不猜糟（用户会以为词库错了） |
library;

/// 标准缩写（带句点）—— 归一化的**唯一目标格式**。
///
/// 键一律**小写、无方括号、无尾句点**（清洗后的形态）。
/// ⚠️ 多词键（`modal v` / `prep phrase`）必须能**整串匹配** —— 否则会被拆成两段。
const Map<String, String> _posMap = {
  // ── 名词（含可数性标记：c/u/pl 是「名词的属性」而非独立词性）──
  'n': 'n.',
  'noun': 'n.',
  'c': 'n.', // countable
  'u': 'n.', // uncountable
  'pl': 'n.', // plural

  // ── 动词 ──
  'v': 'v.',
  'verb': 'v.',
  'vt': 'v.', // 及物
  'vi': 'v.', // 不及物
  'modal': 'modal v.',
  'modal v': 'modal v.',
  'modal verb': 'modal v.',

  // ── 形容词 / 副词 ──
  'adj': 'adj.',
  'adjective': 'adj.',
  'adv': 'adv.',
  'adverb': 'adv.',

  // ── 其他标准词性 ──
  'prep': 'prep.',
  'preposition': 'prep.',
  'pron': 'pron.',
  'pronoun': 'pron.',
  'conj': 'conj.',
  'conjunction': 'conj.',
  'interj': 'interj.',
  'interjection': 'interj.',
  'int': 'interj.', // 与 interj 同义（实测两种都出现）
  'num': 'num.',
  'numeral': 'num.',
  'det': 'det.',
  'determiner': 'det.',
  'art': 'art.',
  'article': 'art.',
  'abbr': 'abbr.',
  'abbreviation': 'abbr.',
  'ord': 'ord.',
  'ordinal': 'ord.',

  // ── 构词 / 短语 ──
  'prefix': 'prefix.',
  'pref': 'prefix.',
  'suffix': 'suffix.',
  'suf': 'suffix.',
  'phrase': 'phr.',
  'phr': 'phr.',
  'prep phrase': 'prep. phr.',
};

/// 分词用的分隔符（`/` 与 `,` 是词性分隔；空格是 token 分隔）。
final RegExp _splitter = RegExp(r'[/,]\s*');

/// 全角/半角括号及其内容（如 `adj（phrase）` → `adj`）。
final RegExp _paren = RegExp(r'[（(][^）)]*[）)]');

/// 尾句点（一个或多个）。
final RegExp _trailingDot = RegExp(r'\.+\s*$');

/// 查表前的 token 清洗 —— **必须唯一**。
///
/// 🔴 曾经的 bug：只剥「整串」的尾句点，没剥**每段**的。
/// 于是 `[det./pron.]` 拆开后变成 `det.`（带点）→ 表里没有这个键 →
/// 走「原样保留」兜底 → **输出看起来是对的**（`det. / pron.`）→ 手写断言**假通过**。
/// 直到用真库跑全量 + `isPosRecognized` 才暴露。
/// → 🔑 **「原样保留」这条兜底规则会让「漏映射」伪装成「正确」**，
///    所以凡有兜底的地方，必须**另有一条断言独立判「是否识别」**。
String _tokenKey(String w) => w.replaceAll(_trailingDot, '').toLowerCase();

/// 把库里的 `pos` 归一化为**词典惯例缩写**。
///
/// 空输入 → `''`（调用方据此决定不显示词性那一行）。
String normalizePos(String? raw) {
  if (raw == null) return '';
  var s = raw.trim();
  if (s.isEmpty) return '';

  // ① 剥掉括号注释（全角/半角都剥）
  s = s.replaceAll(_paren, '');
  // ② 剥方括号（`[n]` → `n`）
  s = s.replaceAll('[', '').replaceAll(']', '').trim();
  // ③ 剥尾句点（`[n.]` → `n`）—— 统一由映射表补回
  s = s.replaceAll(_trailingDot, '').trim();
  if (s.isEmpty) return '';

  // ④ 🔑 整串优先 —— `modal v` / `prep phrase` 拆开就散了
  final whole = _posMap[s.toLowerCase()];
  if (whole != null) return whole;

  // ⑤ 按分隔符拆，逐段映射
  final parts = s.split(_splitter);
  final out = <String>[];
  for (final part in parts) {
    final t = part.trim();
    if (t.isEmpty) continue;
    // 段内还可能含空格（如 `n pl`）→ 再按空格拆
    for (final w in t.split(RegExp(r'\s+'))) {
      if (w.isEmpty) continue;
      final mapped = _posMap[_tokenKey(w)];
      // 🔑 未知词**原样保留**（不猜）—— 猜错会让用户以为词库错了
      final v = mapped ?? w;
      if (!out.contains(v)) out.add(v); // 去重：`[c, u]` → `n.` / `n.` → `n.`
    }
  }

  return out.join(' / ');
}

/// 归一化结果**是否可信**（`false` = 含未识别的写法）。
///
/// 供验收脚本统计「词库有多少种写法没被映射表覆盖」——
/// 🔑 让「映射表的缺口」是**可观测**的，而不是等用户看到 `xyz.` 才发现。
bool isPosRecognized(String? raw) {
  if (raw == null || raw.trim().isEmpty) return true;
  var s = raw.trim().replaceAll(_paren, '').replaceAll('[', '').replaceAll(']', '');
  s = s.replaceAll(_trailingDot, '').trim();
  if (s.isEmpty) return true;
  if (_posMap.containsKey(_tokenKey(s))) return true;
  for (final part in s.split(_splitter)) {
    for (final w in part.trim().split(RegExp(r'\s+'))) {
      if (w.isEmpty) continue;
      if (!_posMap.containsKey(_tokenKey(w))) return false;
    }
  }
  return true;
}

/// 映射表规模（供验收脚本核对 —— 改表会被断言看见）。
int get posMapSize => _posMap.length;

/// 映射表的全部键（供验收脚本逐项断言）。
Iterable<String> get posMapKeys => _posMap.keys;
