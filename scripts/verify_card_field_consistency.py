#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""卡片字段自洽性校验 —— 把「字段对不对」变成可复跑、有退出码的断言

# 为什么需要（2026-09-28 白哥指示）
「**词在库但内容错要修 —— 这个要全库扫描，排查错误并重新修正**」

触发：发现 `a` 的卡片 ipa/definition/context **三段是 `happy` 的**；
深入扫描又查出三类系统性错误（详见 `docs/design/card-field-contamination-2026-09-28.md`）。

🔑 **与 `verify_card_structure.py` 的分工**（两者互补，都要跑）：
| 脚本 | 管什么 | 能抓 `a` 的 `/ˈhæpi/` 吗 |
|---|---|---|
| `verify_card_structure.py` | **结构**（段类型、顺序、数量） | ❌ 结构完全合法 |
| **本脚本** | **字段内容的自洽**（ipa/释义/例句 与词是否匹配） | ✅ |

# 八类信号
| 信号 | 判据 | 精确率（实测） |
|---|---|---|
| **S1** `ipa` 残缺 | 没有任何一个**完整**的 `/…/` 段 | 高（`/ˈ` 这种只剩重音符） |
| **S2** `ipa` 截断 | 实质字符数 / 拼写字母数 < **0.45** | **100%**（18/18 全真错） |
| **S3a** 多词短语 `ipa` 撞车 | 两个**不同短语**的 ipa 完全相同 | **100%**（不同短语不可能同音） |
| **S3b** 单词 `ipa` 撞车 | ipa 与「字形**不**相似」的词相同 | 中（含真同音词干扰，须逐条判） |
| **S4** `context` 不含该词 | 例句里找不到该词**或其已知变形** | 中（不规则变形/缩写会误报） |
| 🆕 **S5a** 基词 ⊂ 词组 | 单词的 ipa = 它所在**词组**的 ipa | 🔴 **硬证据（逻辑必然）** —— 见下 |
| 🆕 **S5b** 派生词 ⊂ 词干 | 两词互为前缀/后缀 · 长度差 ≥ 2 · 同 ipa | 待测（含变体例外 `gram`/`gramme`） |
| 🆕 **S5c** 近形同 ipa | 两词互为前缀/后缀 · 长度差 = 1 · 同 ipa | 低（多为真同音，须逐条判） |

🔑 **S5a 是硬证据而非启发式**：设 `w ⊂ p`（`bus` ⊂ `bus stop`），
   则 `p` 的完整音标**必然包含** `w` 的音标（`/ˈbʌs ˌstɒp/` ⊃ `/bʌs/`）。
   所以「`w` 的 ipa 与 `p` 的 ipa **完全相同**」在数学上不可能同时成立
   → **必有 `w` 错**，不需要 LLM。

# 🔴 已知边界（如实标注，不要当成"没问题是"）
· **S3b 无法区分「真同音词」与「字段错位」** —— `right`/`rite`/`write` 都该是 `/raɪt/`（合理），
  而 `a`/`happy` 也是 `/ˈhæpi/`（错误）。两者机械上同形 → **必须逐条人工/LLM 判定**。
· **S5b/S5c 同理会含真同音干扰** —— `be`/`bee`（对）与 `tap`/`tape`（`tape` 错）同为「差 1」，
  机械分不开 → 需 LLM。**S5a 无此问题**（见上，逻辑必然）。
· 🆕 **S5 这一族是 2026-09-29 才补上的信号** —— 在此之前「基词 ⊂ 词组」整类
  （`police`/`police station` 等 22 对）与「派生词 ⊂ 词干」整类（78 对）
  **被 `similar_word()` 的前缀/后缀守卫整类放过，一条都没报**。
· **S4 的变形还原是启发式的** —— 不规则变形（`outgrown`/`underwent`/`seventieth`）仍会误报。
· 本脚本**只查「字段是否张冠李戴」**，**不查语义是否正确**
  （释义写得对不对、词源可不可信 → 需 LLM 判定，见报告 §六）。

# 用法
    python3 scripts/verify_card_field_consistency.py               # 汇总
    python3 scripts/verify_card_field_consistency.py --list        # 列出全部候选
    python3 scripts/verify_card_field_consistency.py --json out.json   # 导出（供 LLM 复核）
    python3 scripts/verify_card_field_consistency.py --word a      # 只查某个词（生成后校验用）
退出码：0 = 无命中；1 = 有命中（**可用于 CI / 生成后闸门**）
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(ROOT, 'data', 'word.db')

# S2 的阈值：IPA 实质字符数 / 拼写字母数
# 实测：真错的一批在 0.23~0.44；正常词最低也有 0.5 以上 → 取 0.45 留余量
RATIO_MIN = 0.45

#: 信号顺序（输出用）—— S5a/S5b/S5c 是 2026-09-29 新增：
#: 专抓「被 `similar_word()` 的前缀/后缀守卫放过」的同 ipa 对（见 `_s5_tier` 说明）。
SIGNALS = ('S1', 'S2', 'S3a', 'S3b', 'S4', 'S5a', 'S5b', 'S5c')

# S4 的轻量还原（补 `word_form` 的覆盖缺口 —— `committing`/`cancelled`/`outgrown` 都不在表里）
_SUFFIXES = ('s', 'es', 'ed', 'd', 'ing', 'ly')


def fold(s: str) -> str:
    """去变音符：Phèdre → phedre · café → cafe

    🔴 必需 —— 正则 `[a-z]` 遇到 `è` 会**断开**（`Phèdre` 被切成 `ph`+`dre`），
       造成「例句不含该词」的假阳性（实测：`phedre` 就是这么误报的）。
    """
    return ''.join(c for c in unicodedata.normalize('NFKD', (s or '').lower())
                   if not unicodedata.combining(c))


def tokens(text: str) -> set:
    """分词（已 fold）。额外产出所有格 / 连字符的等价形式以降低误报。"""
    out = set()
    for m in re.finditer(r"[a-z]+(?:['\-][a-z]+)*", fold(text)):
        tok = m.group(0)
        out.add(tok)
        out.add(tok.replace("'s", '').replace("'", ''))
        for part in re.split(r"['\-]", tok):
            if part:
                out.add(part)
    return out


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a or not b:
        return len(a) or len(b)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def ipa_segments(ipa: str) -> list:
    """提取所有完整的 /…/ 段"""
    return re.findall(r'/[^/]*/', ipa or '')


# 英美/拼写变体的常见差异（用于判断「两个条目是不是同一个词的两种写法」）
_VARIANT_PAIRS = [('our', 'or'), ('ise', 'ize'), ('re', 'er'), ('ogue', 'og'),
                  ('ll', 'l'), ('mme', 'm'), ('ae', 'e'), ('oe', 'e')]


def _norm_phrase(s: str) -> str:
    """归一化短语：去空格/连字符 + 折叠常见英美变体差异

    `face to face` → `facetoface` · `face-to-face` → `facetoface`（相等 → 是同一个词）
    `sports centre` → `sportscener`（保留差异，交给编辑距离判定）
    """
    t = re.sub(r"[\s\-']", '', fold(s))
    for a, b in _VARIANT_PAIRS:
        t = t.replace(a, b)
    return t


def ipa_core_len(ipa: str) -> int:
    """IPA 实质字符数（去掉 / [ ] 重音 ˌˈ 音节点 . 与空白）"""
    return len(re.sub(r"[/\[\]ˌˈ\.\s]", '', ipa or ''))


def similar_word(x: str, y: str, forms_of) -> bool:
    """字形是否相似（相似 → 撞车合理，应排除）

    🔴 **不能用「互为子串」**（实测教训 2026-09-28）：
      · `'it' in 'with'`  → True（巧合）→ `with`/`it` 的污染被放过
      · `'a'  in 'happy'` → True（单字母是任何词的子串）→ `a`/`happy` 的污染被放过
    ✅ 改为「前缀/后缀」+「编辑距离 ≤2 **且** 长度差 ≤1」
      · `be`/`bee` 前缀 ✅ · `en`/`ellen` 后缀 ✅（⚠️ 这条会漏报 `en`，已知边界）
      · `it`/`with` 既非前后缀，距离 2 但长度差 2 → **正确判为不相似**
    """
    if x == y:
        return True
    if x.startswith(y) or y.startswith(x):
        return True
    if x.endswith(y) or y.endswith(x):
        return True
    if levenshtein(x, y) <= 2 and abs(len(x) - len(y)) <= 1:
        return True
    if forms_of(x) & forms_of(y):
        return True
    return False


# ── 🆕 S5 用：识别「被字形相似守卫放过」的同 ipa 对 ──────────────────
# 🔑 `similar_word()` 的「前缀/后缀 → 相似」分支本意是放过 `be`/`bee` 这类
#    **真同音近形词**，但它同时**整类放过了**两种真错（实测 2026-09-29，共 100 对）：
#      · 基词 ⊂ 它的词组  → `police` 挂着 `police station` 的音标（22 对）
#      · 派生词 ⊂ 词干    → `bullet` 挂着 `bull` 的 · `logo` 挂着 `log` 的（78 对）
#    这 100 对**全部没进 196 候选** —— 信号完全看不见它们。
#: ipa 归一化替换 —— **只为消除「写法差异」，不改变读音**
_IPA_FOLD = (('ɡ', 'g'), ('ɛ', 'e'), ('əʊ', 'oʊ'), ('ɝ', 'ɜ'), ('ɜːr', 'ɜː'))


def ipa_core_set(ipa: str) -> set:
    """把 ipa 压成「音素串集合」—— 判「两种写法是不是同一个读音」用。

    🔴 **为什么 S5 必须用它分组，而不是用原始字符串**（2026-09-29 踩坑）：
       `capital` 的 ipa 是 `/ˈkæpɪtl ˈlɛtər/`（就是 `capital letter` 的旧值），
       而 `capital letter` 已在上一步被修成 `/ˌkæpɪtl ˈletə/ (UK) or /ˌkæpɪtl ˈletər/ (US)`。
       两者**读音完全相同**，但**原始字符串不同** → 用原始串分组就配不上对
       → `capital` / `debit` / `secondary` 这类**全被漏掉**。
    归一化：抽 `/…/` 段 · 去重音/分隔/弱读央元音 · 统一 `ɡ/g`·`ɛ/e`·`əʊ/oʊ` · 去词尾 `r`。
    """
    out = set()
    for seg in (ipa_segments(ipa) or [ipa.strip('/')]):
        c = seg.lower()
        for a, b in _IPA_FOLD:
            c = c.replace(a, b)
        c = re.sub(r"[ˈˌ.\s(),;]", '', c)
        c = re.sub(r'[əɚ]', '', c)
        c = re.sub(r'r+$', '', c)
        if c:
            out.add(c)
    return out


def ipa_spoken_segments(ipa: str) -> int:
    """ipa 里**实际覆盖了几个词** —— 按空白分词，不是数 `/…/` 段数。

    🔴 踩坑（2026-09-29）：一开始写成 `len(ipa_segments(...))`，而
       `/pəˈliːs ˌsteɪʃən/` 只是**一段**（只有一对斜杠）→ 判成「只覆盖 1 个词」
       → `police station` 被判「未覆盖全」，S5a 全部漏报（应为 22，实测 0）。
    """
    body = ' '.join(ipa_segments(ipa)).strip('/')
    return len([x for x in re.split(r'\s+', body) if x])


def _word_in_phrase(w: str, p: str) -> bool:
    """单词 `w` 是否是词组 `p` 的**一个词段**（`police` ⊂ `police station`）。"""
    if ' ' not in p:
        return False
    return w in re.split(r'[\s\-]+', p)


def _benign_pair(xl: str, yl: str) -> str:
    """这一对是否属**已知正确**的形态（屈折 / 缩写点 / 英美变体）。返回理由，或 ''。

    🔑 为什么需要：`S5b/S5c` 的桶里混着大量**本来就对**的对 ——
       `nazi`/`nazis`（屈折）· `dr`/`dr.`（缩写点）· `enrol`/`enroll`（英美变体）。
       它们同 ipa 是**正常的**。标出来才能把「真错」与「噪声」分开看。

    🔴 **`+'e'` 绝不能算 benign**（2026-09-29 踩坑）：词尾加 `e` 是 **magic e** ——
       `tap` `/tæp/` → `tape` `/teɪp/`（元音**变了**）· `hat`→`hate` · `not`→`note`。
       第一版把 `+'e'` 当「词尾差异」→ `tap`/`tape` 被标成「大概率本就正确」，
       **正好放过了真错**。而 `blond`/`blonde` · `for`/`fore` 这类确实同音 →
       机械分不开（试过 CVCe 判据，`for`/`how` 会误判）→ **统一归「需复核」**，
       宁可多花几毛钱复核，不可放过真错。
    """
    short, long_ = (xl, yl) if len(xl) <= len(yl) else (yl, xl)
    if long_ in (short + 's', short + '.'):
        return '屈折/缩写点'
    if _norm_phrase(xl) == _norm_phrase(yl):
        return '英美变体拼写'
    return ''


def _s5_tier(sx: str, sy: str, px: bool, py: bool, ip: str,
             per_word, kx: str, ky: str):
    """把一对「相似 + 同 ipa」的词分档，返回 `(信号, 说明, 该归咎的 key 或 None)`。

    | 档 | 判据 | 强度 | 方向 |
    |---|---|---|---|
    | **S5a** | 一 word 一 phrase，且 phrase 的 ipa **覆盖了全部词** | 🔴 **硬证据** | **确定是 word 错**（phrase 是对的参照物） |
    | **S5b** | 两 word · 长度差 ≥ 2 | 🟠 需复核 | 不定 —— **至少一方错**（`bullet` 错 / `consider` 错，方向相反） |
    | **S5c** | 两 word · 长度差 = 1 | 🟡 多为真同音 | 不定 |

    🔑 **S5a 为什么是硬证据（不是启发式）**：设 `w ⊂ p`，则 `p` 的完整音标**必然包含**
       `w` 的音标作为一部分（`bus stop` = `/ˈbʌs ˌstɒp/` ⊃ `/bʌs/`）。
       所以「`w` 的 ipa 与 `p` 的 ipa **完全相同**」在数学上不可能同时成立
       → **必有 `w` 错**。（反过来的情形 —— phrase 的 ipa 只写了第一个词 ——
       会命中「ipa 未覆盖全词组」，由 S2 一侧负责，故此处先验 `covered`。）

    🔴 **S5b 不能预设「长词错」**（实测反例）：`bullet` 错（拿到 `bull` 的），
       但 `consider` 也错（**短词**拿到了 `consideration` 的音标）—— 方向相反。
       所以 S5b/S5c 只报「这一对可疑」，归咎哪一方留给人眼/LLM。
    """
    xl, yl = sx.lower(), sy.lower()
    if px or py:
        wkey, pkey = (kx, ky) if py else (ky, kx)
        w = per_word[wkey]['spelling']
        p = per_word[pkey]['spelling']
        covered = ipa_spoken_segments(per_word[pkey]['ipa']) >= len(p.split())
        if covered and _word_in_phrase(w.lower(), p.lower()):
            return 'S5a', (f'🔴 基词 {w!r} 的音标 = 词组 {p!r} 的完整音标: {ip}'
                           f'（词组音标必含单词音标 → 基词错）'), wkey
    d = abs(len(xl) - len(yl))
    benign = _benign_pair(xl, yl)
    tail = f'（{benign} → 大概率本就正确）' if benign else '（需复核，方向不定）'
    if d >= 2:
        return 'S5b', f'派生式同 ipa（长度差 {d}）: {sx!r} / {sy!r} —— {ip} {tail}', None
    return 'S5c', f'近形同 ipa（长度差 1）: {sx!r} / {sy!r} —— {ip} {tail}', None


def contains_word(text: str, spelling: str, forms_of) -> bool:
    """text 里是否出现该词（或其已知变形）"""
    t = tokens(text)
    s = fold(spelling)
    if not s:
        return True
    if s in t:
        return True
    if ' ' in s and s in fold(text):
        return True
    known = forms_of(s)
    if t & known:
        return True
    if t & light_forms(s):
        return True
    for tok in t:
        if s in light_forms(tok):
            return True
    return False


def light_forms(w: str) -> set:
    """轻量还原规则（补 `word_form` 覆盖不到的）"""
    out = set()
    for suf in _SUFFIXES:
        if w.endswith(suf) and len(w) - len(suf) >= 2:
            stem = w[:-len(suf)]
            out.add(stem)
            if len(stem) >= 3 and stem[-1] == stem[-2]:
                out.add(stem[:-1])          # committ → commit
            out.add(stem + 'e')             # achiev → achieve
    for suf in _SUFFIXES:
        out.add(w + suf)
    out.add(w + 'ed')
    out.add(w + 'd')
    out.add(w + 's')
    if len(w) >= 2:
        for suf in ('s', 'ed', 'ing'):
            out.add(w + w[-1] + suf)        # commit → committing
    return out


def load(db):
    con = sqlite3.connect(db)
    forms = defaultdict(set)
    for (f, b) in con.execute('SELECT form, base FROM word_form'):
        forms[fold(b)].add(fold(f))

    def forms_of(w):
        return forms.get(w, set())

    cards = []
    for (wid, sp, et, ct) in con.execute(
            'SELECT w.id, w.spelling, w.entry_type, c.content '
            'FROM word w JOIN card c ON c.word_id = w.id'):
        cards.append((wid, sp, et, json.loads(ct) if ct else {}))
    con.close()
    return cards, forms_of


def check_card(sp, et, d, forms_of):
    """返回该卡命中的信号列表"""
    hits = []
    ipa = (d.get('ipa') or '').strip()
    key = fold(sp)
    letters = len(re.sub(r'[^a-z]', '', key))
    is_phrase = ' ' in sp.strip() or et == 'phrase'

    # ── S1 ipa 残缺：没有任何一个完整 /…/ 段 ──
    if ipa and not ipa_segments(ipa):
        hits.append(('S1', f'ipa 无完整 /…/ 段: {ipa!r}'))
    elif not ipa:
        hits.append(('S1', 'ipa 为空'))

    # ── S2 ipa 截断：实质字符 / 拼写字母 < 阈值 ──
    if ipa and ipa_segments(ipa) and letters >= 4:
        cl = ipa_core_len(ipa)
        r = cl / letters
        if r < RATIO_MIN:
            hits.append(('S2', f'ipa 疑截断 {ipa!r}（实质 {cl} / 字母 {letters} = {r:.2f}）'))

    # ── S4 context 不含该词 ──
    ctx = next((s.get('text') or '' for s in d.get('sections') or []
                if s.get('type') == 'context'), '')
    if ctx and not contains_word(ctx, sp, forms_of):
        hits.append(('S4', f'例句不含该词: {ctx[:70]!r}'))

    return hits, ipa, key, is_phrase


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--list', action='store_true', help='列出全部候选')
    ap.add_argument('--json', metavar='PATH', help='导出候选（供 LLM 复核）')
    ap.add_argument('--word', help='只查某个词（生成后校验用）')
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f'✗ {args.db} 不存在')

    cards, forms_of = load(args.db)
    if args.word:
        cards = [c for c in cards if fold(c[1]) == fold(args.word)]
        if not cards:
            sys.exit(f'✗ 库里没有 {args.word!r}')

    # ── 逐卡检查（S1/S2/S4）──
    per_word = {}
    for wid, sp, et, d in cards:
        hits, ipa, key, is_phrase = check_card(sp, et, d, forms_of)
        per_word[key] = {'spelling': sp, 'entry_type': et, 'ipa': ipa,
                         'hits': hits, 'phrase': is_phrase}

    # ── S3 ipa 撞车（需全库分组）──
    by_ipa = defaultdict(list)
    for key, v in per_word.items():
        segs = ipa_segments(v['ipa'])
        if segs:
            by_ipa[' '.join(segs)].append(key)
    for ip, keys in by_ipa.items():
        if len(keys) < 2:
            continue
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                x, y = keys[i], keys[j]
                if per_word[x]['phrase'] and per_word[y]['phrase']:
                    # S3a：两个**不同短语**同 ipa。
                    # 🔴 但要先排除「**同一个词的两种写法**」—— 它们的 ipa 相同是**正常的**：
                    #    · `face to face` ≡ `face-to-face`（连字符差异）
                    #    · `disc jockey` ≡ `disk jockey`（disc/disk 变体拼写）
                    #    · `sports center` ≡ `sports centre`（英美变体）
                    #    判据：归一化后相同，或编辑距离 ≤ 2。
                    nx, ny = _norm_phrase(x), _norm_phrase(y)
                    if nx == ny or levenshtein(nx, ny) <= 2:
                        continue
                    per_word[x]['hits'].append(('S3a', f'与短语 {per_word[y]["spelling"]!r} 的 ipa 相同: {ip}'))
                    per_word[y]['hits'].append(('S3a', f'与短语 {per_word[x]["spelling"]!r} 的 ipa 相同: {ip}'))
                elif not similar_word(x, y, forms_of):
                    per_word[x]['hits'].append(('S3b', f'与 {per_word[y]["spelling"]!r} 的 ipa 相同: {ip}'))
                    per_word[y]['hits'].append(('S3b', f'与 {per_word[x]["spelling"]!r} 的 ipa 相同: {ip}'))

    # ── S5 🆕：「字形相似」+ 同 ipa —— 被 `similar_word()` 守卫**整类放过**的那一批 ──
    #
    # 🔑 与 S3a/S3b **互补不重叠**（三支互斥，合起来覆盖全部同 ipa 对）：
    #      · 两个都是 phrase              → S3a
    #      · 非 both phrase 且 **不相似**  → S3b
    #      · 非 both phrase 且 **相似**    → **S5**（本段）
    #
    # 🔴 为什么必须单列：`similar_word()` 的「前缀/后缀」分支是为 `be`/`bee`
    #    这类**真同音近形词**加的，但它把两种**真错**也一起放过了：
    #      · 基词 ⊂ 它的词组 → `police` 的音标是 `police station` 的
    #      · 派生词 ⊂ 词干   → `bullet` 的音标是 `bull` 的 · `logo` 是 `log` 的
    #    实测（2026-09-29）：**100 对**，**全部没进 196 候选** —— 信号完全看不见。
    #
    # 🔑 **S5a 用归一化分组（`ipa_core_set`），S5b/S5c 用原始分组（`by_ipa`）** —— 实测结论：
    #    · 归一化让 S5a **多抓到 3 条**（`capital` / `debit` / `secondary`）—— 要的就是它。
    #      `by_ipa` 的键是**原始段字符串**，会把「同一读音的两种写法」分到不同组：
    #      `capital` 是 `/ˈkæpɪtl ˈlɛtər/`，而 `capital letter` 已被修成
    #      `/ˌkæpɪtl ˈletə/ (UK) or /ˌkæpɪtl ˈletər/ (US)` → 读音相同、字符串不同 → 配不上。
    #    · 但同一套宽松归一化用在 word-word 上会**过度配对**（312/338 vs 28/128），
    #      因为 `ipa_core_set` 会删弱读 `ə`、去词尾 `r`，把本该不同的读音也并到一起。
    #    → 各取所需：**跨「已修/未修」的写法差异**需要归一化，**同类型词之间**不需要。
    by_core = defaultdict(set)
    for k, v in per_word.items():
        for c in ipa_core_set(v['ipa']):
            by_core[c].add(k)
    seen_pairs = set()
    for _ip, keys in sorted((k, sorted(v)) for k, v in by_core.items() if len(v) > 1):
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                x, y = keys[i], keys[j]
                if (x, y) in seen_pairs:           # 一卡可属多个读音组 → 去重
                    continue
                seen_pairs.add((x, y))
                px, py = per_word[x]['phrase'], per_word[y]['phrase']
                if not (px ^ py):                  # 只处理「一 word 一 phrase」
                    continue
                if not similar_word(x, y, forms_of):
                    continue
                sig, note, blame = _s5_tier(per_word[x]['spelling'], per_word[y]['spelling'],
                                            px, py, _ip, per_word, x, y)
                if blame is None:
                    # 一 word 一 phrase 了，但不是「word ⊂ phrase」的形态
                    # （或 phrase 的 ipa 未覆盖全 → 那由 S2 一侧负责）→ 不在此报
                    continue
                per_word[blame]['hits'].append((sig, note))

    # ── S5b / S5c：word-word（用**原始**分组，理由见上）──
    for ip, keys in by_ipa.items():
        if len(keys) < 2:
            continue
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                x, y = keys[i], keys[j]
                if per_word[x]['phrase'] or per_word[y]['phrase']:
                    continue                       # word-phrase → 归 S3a / S5a
                if not similar_word(x, y, forms_of):
                    continue                       # → 已由 S3b 报出
                # 🔑 **只在「前缀/后缀」这一支上生效** —— 这才是守卫放过真错的那一支。
                #    `similar_word()` 另有「编辑距离 ≤2 且长度差 ≤1」分支，命中的是
                #    `be`/`bee` · `meat`/`meet` 这类**真同音词**（同 ipa 本就合理）
                #    → 属 S3b 的**已知边界**，不报（否则多出 178 对纯噪声）。
                affix = (x.startswith(y) or y.startswith(x)
                         or x.endswith(y) or y.endswith(x))
                if not affix:
                    continue
                sig, note, blame = _s5_tier(per_word[x]['spelling'], per_word[y]['spelling'],
                                            False, False, ip, per_word, x, y)
                per_word[x]['hits'].append((sig, note))
                per_word[y]['hits'].append((sig, note))

    flagged = {k: v for k, v in per_word.items() if v['hits']}

    # ── 输出 ──
    print('═' * 74)
    print('卡片字段自洽性校验')
    print('═' * 74)
    print(f'  检查卡片      : {len(cards):,}')
    print(f'  🔴 命中（可疑）: {len(flagged):,}'
          f'  ({len(flagged) / max(len(cards), 1) * 100:.1f}%)')
    print()
    by_sig = defaultdict(list)
    for k, v in flagged.items():
        for s, why in v['hits']:
            by_sig[s].append((v['spelling'], why))
    for s in SIGNALS:
        print(f'    {s:<4} : {len(by_sig[s]):>5}')

    # 🔴 `--word` 单查时 S3a/S3b/S5a/S5b/S5c **必然为 0** —— 它们靠**全库分组**才能配对，
    #    只有一个词时组内没有第二个成员。**必须显式说明**：否则「0 命中」会被
    #    误读成「这个词没问题」（静默失效比报错更糟）。
    if args.word:
        print()
        print(f'  ⚠️ 单查模式：S3a/S3b/S5a/S5b/S5c 需要**全库分组**才能配对，此处**必然为 0**，'
              f'不代表没命中。')
        print(f'     要查这几类，去掉 `--word` 跑全库，再在其中搜 `{args.word}`。')

    if args.list:
        for s in SIGNALS:
            print()
            print('─' * 74)
            print(f'{s}（{len(by_sig[s])} 条）')
            print('─' * 74)
            for sp, why in sorted(by_sig[s]):
                print(f'  {sp:<24} {why}')

    if args.json:
        out = [{'spelling': v['spelling'], 'entry_type': v['entry_type'],
                'ipa': v['ipa'], 'signals': sorted({s for s, _ in v['hits']}),
                'reasons': [w for _, w in v['hits']]}
               for v in sorted(flagged.values(), key=lambda x: x['spelling'])]
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f'\n  已导出 {len(out)} 条 → {args.json}')

    return 1 if flagged else 0


if __name__ == '__main__':
    sys.exit(main())
