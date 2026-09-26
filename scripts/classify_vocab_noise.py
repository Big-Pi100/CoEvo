#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""词库噪声分类（Phase 1 #3 + #4 的前置：产出候选清单，不直接改库）

背景
----
文档记载两项清理任务：
  #3 剔除专有名词/缩写/姓氏地名（原记「501 条，pos 含 proper noun 196 条」）
  #4 清理 76 个污染短词（原记「ab/bw/zg 等，来自 brown_inferred_low 自动抽取」）

实测发现原判据不可靠：
  · 「长度 ≤2」→ 115 个，但其中大量是合法词（a/an/be/by/do/go/he/at/up…）
  · 「无元音」→ **无效判据** —— y 是半元音，可独立成音节
    （by / cry / dry / gym / hymn / myth / my / why / spy / try 全都"无元音"）

本脚本改用「可验证特征」而非粗粒度阈值：
  ① 解析残留   —— 含非字母字符（撇号 `'m` / 句号 `dr.`）
  ② 三连字母   —— `bbb` 类，绝不可能是英语词
  ③ 专有名词   —— pos 含 proper
  ④ 缩写       —— pos 含 abbr/acronym，**或** pron 是逐字母拼读
                  （/siː ˈdiː/ = CD、/ˌɛm piː ˈeɪtʃ/ = mph —— 强特征）
  ⑤ 元素符号   —— pron 是化学元素名（/ˈɪtərbiəm/ = 镱 Yb），且词长 ≤2
  ⑥ 功能词     —— 白名单（最高频功能词，必须保留）

输出
----
  data/curriculum/prebuilt/vocab_noise.json   分类清单
  终端报告                                     各类数量 + 样例 + 待确认项

**本脚本只读 DB、只写清单文件，不修改任何生产数据。**

用法
----
    python3 scripts/classify_vocab_noise.py
    python3 scripts/classify_vocab_noise.py --show abbr
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
CEFRJ = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'cefr_j', 'cefr_j_all.json')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'vocab_noise.json')


# ── 判据 ⑥：功能词白名单 ────────────────────────────────────────────
# 最高频功能词/核心词 —— 无论多短都必须保留（长度判据永远不能删它们）
FUNCTION_WORDS = {
    # 冠词 / 代词 / 限定词
    'a', 'an', 'the', 'i', 'me', 'my', 'mine', 'you', 'your', 'he', 'him', 'his',
    'she', 'her', 'it', 'its', 'we', 'us', 'our', 'they', 'them', 'their',
    'this', 'that', 'these', 'those', 'who', 'whom', 'whose', 'which', 'what',
    'all', 'any', 'each', 'every', 'both', 'some', 'such', 'no', 'nor', 'not',
    'one', 'two', 'own', 'same', 'so', 'than', 'too', 'very', 'just', 'only',
    # 介词 / 连词
    'at', 'by', 'for', 'from', 'in', 'into', 'of', 'off', 'on', 'onto', 'out',
    'over', 'to', 'up', 'upon', 'with', 'as', 'and', 'but', 'or', 'if', 'yet',
    'till', 'via', 'per', 'pro', 'vs',
    # be / do / have / 情态
    'be', 'am', 'is', 'are', 'was', 'were', 'do', 'did', 'have', 'has', 'had',
    'can', 'may', 'must', 'let', 'get', 'go', 'put', 'see', 'say', 'use',
    # 短但极高频的实义词
    'man', 'men', 'day', 'way', 'eye', 'ear', 'arm', 'leg', 'lip', 'hip', 'jaw',
    'job', 'kid', 'bit', 'box', 'boy', 'bus', 'car', 'cat', 'dog', 'fox', 'cow',
    'pig', 'rat', 'bat', 'bee', 'ant', 'owl', 'egg', 'oil', 'ice', 'sky', 'sun',
    'sea', 'air', 'war', 'law', 'tax', 'pay', 'buy', 'ask', 'say', 'run', 'ran',
    'eat', 'ate', 'sit', 'sat', 'hit', 'had', 'got', 'win', 'won', 'let',
    'cut', 'put', 'set', 'big', 'bad', 'sad', 'mad', 'fat', 'hot', 'wet',
    'dry', 'old', 'new', 'low', 'far', 'few', 'ill', 'odd',
    'raw', 'red', 'six', 'ten', 'two', 'you', 'yes', 'why', 'how', 'now', 'yet',
    'ok', 'hi', 'hey', 'oh', 'ah', 'aw', 'eh', 'uh', 'um', 'ow', 'ha',
}

# ── 判据 ④：逐字母拼读的音节（缩写强特征）─────────────────────────
SPELLED_LETTER_SYL = re.compile(
    r'(biː|diː|siː|piː|tiː|viː|juː|ziː|keɪ|dʒeɪ|aɪ|əʊ|waɪ|'
    r'ɛf|ɛl|ɛm|ɛn|ɛs|ɛks|eks|ɑːr|ɑr|dʌbəljuː|dʌbəl|'
    r'bi|di|si|pi|ti|vi|ef|el|em|en|es|ar)'
)

# 化学元素名后缀（判据 ⑤）
ELEMENT_SUFFIX = re.compile(r'(ium|ine|ium|on|ic|ogen|argon|neon|iron|zinc|lead|gold|silver)$', re.I)

# 判据 ①：解析残留（非纯字母）
NON_ALPHA = re.compile(r'[^a-z]')

# 判据 ②：三连相同字母
TRIPLE = re.compile(r'(.)\1\1')

# ── 判据 ⑨（新增，最强）：从 definitions 措辞反推词的性质 ──────────
# 实测发现 definitions 会直接写明性质，例如：
#   abe  → "a nickname for Abraham, especially Abraham Lincoln."
#   ada  → "a female given name."
#   zg   → "(abbreviation) zero gravity"
#   nam  → "(informal, chiefly US) short for Vietnam"
# 这比「长度 ≤2」「无元音」这类粗粒度阈值可靠得多。
DEF_PROPER = re.compile(
    # 人名：直接自述（不要求后接大写，因为常独立成句）
    r'(nickname for |'
    r'\b(?:a|an) (?:male|female) (?:given |first )?name\b|'
    r'\ba (?:given|first|last|family|common|English|Scottish|Irish|Welsh|'
    r'American|French|German|Italian|Spanish) (?:sur)?name\b|'
    r'\ba surname\b|'
    r'\bshort for [A-Z]|'
    # 人名 + 国籍/职业（`Benjamin Britten, English composer`）
    r'\b[A-Z][a-z]+(?: [A-Z][a-z]+)+,\s*(?:English|American|British|French|'
    r'German|Italian|Spanish|Russian|Irish|Scottish|Welsh|Canadian|Australian|'
    r'Indian|Chinese|Japanese|Greek|Roman)\b|'
    # 某国国民 / 居民（`natives or inhabitants of Greece`）
    r'\b(?:natives?|inhabitants?|citizens?|people) (?:or inhabitants )?of [A-Z]|'
    # 城市 / 州 / 国家：**允许并列词**（`a city and port in ...`）
    r'(?:the )?capital (?:city )?of (?:the )?[A-Z]|'
    r'\b(?:a|an|the) (?:city|town|village|state|province|county|country|island|'
    r'island territory|territory|region|peninsula|district|republic|kingdom)'
    r'(?:\s+(?:and|or)\s+\w+)?\s+(?:in|of|on|near) (?:the )?[A-Z]|'
    r'\b(?:a|an) (?:island|river|mountain|lake|sea|desert|gulf|strait)'
    r'(?:\s+(?:and|or)\s+\w+)?\s+(?:in|of|on|near|between) (?:the )?[A-Z]|'
    r'\bthe (?:House of )?[A-Z][a-z]+ (?:dynasty|Empire|Kingdom|Republic)\b|'
    r'\bwhich ruled [A-Z]|'
    # 公司 / 品牌（`a multinational corporation` / `a brand of ...`）
    r'\b(?:multi)?national (?:corporation|company|airline)\b|'
    r'\ba (?:brand|division|subsidiary|manufacturer) of\b|'
    r'\b(?:a |an )?[A-Z][a-z]+ (?:Inc\.|Corp\.|Corporation|Company|Motors)\b)',
)

# ⚠️ `short for X` **不是**缩写标记 ——
#    advert(advertisement) / ammo(ammunition) / auto(automobile) / bio(biography)
#    缩略后已成为**独立合法英语词**，不能当缩写删。
#    真正的缩写是「不按词读音的字母串」：TV / CD / USA / NBC / mph。
#
# 🔴 也**不能**用 `stands? for` / `symbol for` —— 实测误伤严重：
#    rack  → "a framework or **stand for** holding things"
#    symbol→ "a thing that represents or **stands for** something"
#    delta → "the Greek letter ... used as a **symbol for** change"
#    eta   → 同 delta
#  → 只认「释义**明确自述**为缩写」的措辞。
DEF_ABBR = re.compile(
    r'(\((?:an? )?(?:abbreviation|abbr|acronym|initialism)[^)]*\)|'
    r'^\s*(?:an? )?(?:abbreviation|acronym|initialism) (?:for|of)\b|'
    r'\babbreviation for\b|'
    r'\bacronym for\b)',
    re.I,
)

# 逐字母拼读要配合「字母/缩写」语境才算 —— 否则 `ok`（读作 /əʊˈkeɪ/）
# 这类**本身就是词**的会被误判
LETTER_CTX = re.compile(r'\b(letter|alphabet|initial|spelled)\b', re.I)

# ── 判据 ⑫（新增）：化学元素符号 ──
ELEMENT_NAMES = re.compile(
    r'\b(ytterbium|yttrium|zinc|gadolinium|holmium|erbium|terbium|dysprosium|'
    r'thulium|scandium|ruthenium|rhodium|palladium|cadmium|cobalt|nickel|'
    r'copper|indium|tungsten|iron|ferrum|chromium|uranium|radium|barium|'
    r'calcium|potassium|sodium|magnesium|aluminium|aluminum|silicon|sulfur|'
    r'chlorine|argon|neon|helium|hydrogen|oxygen|nitrogen|carbon)\w*\b',
    re.I,
)
DEF_RARE = re.compile(r'\((archaic|obsolete|dialectal|dialect|rare|poetic|nonstandard)\b', re.I)


def _def_items(definitions: str | None) -> list[dict]:
    """把 definitions 拆成义项列表 [{meaning, chinese, is_proper}]。

    ⚠️ 必须按**义项**判断，不能看整条拼接文本 ——
    很多词是**兼类**：`billy` = 人名 + 警棍 + 公羊，`benjamin` = 人名 + 百元钞。
    只要**有一个义项不含专有特征**，这个词就有普通义，不该删。
    """
    if not definitions:
        return []
    try:
        raw = json.loads(definitions)
    except Exception:
        raw = [{'meaning': definitions}]
    if not isinstance(raw, list):
        raw = [raw]

    out = []
    for it in raw:
        if isinstance(it, dict):
            mean = str(it.get('meaning', ''))
            chin = str(it.get('chinese', ''))
        else:
            mean, chin = str(it), ''
        if not mean.strip():
            continue
        # 单个义项内部也可能并列多种性质（用分号/also 连接），
        # 故本义项「是否专有」= 是否**出现过**专有特征（从严）
        out.append({
            'meaning': mean,
            'chinese': chin,
            'is_proper': bool(DEF_PROPER.search(mean)),
        })
    return out


def _def_text(definitions: str | None) -> str:
    """扁平文本（用于缩写/生僻标记等整条判断）。"""
    items = _def_items(definitions)
    if not items:
        return definitions or ''
    return ' '.join(f"{i['meaning']} {i['chinese']}" for i in items)


def _has_chinese(definitions: str | None) -> bool:
    return bool(definitions and re.search(r'[\u4e00-\u9fff]', definitions))


def load_source():
    if not os.path.exists(DB):
        sys.exit(f'!! 数据库不存在: {DB}')
    con = sqlite3.connect(DB)
    cur = con.cursor()

    cards = {
        r[0]: r[1]
        for r in cur.execute(
            "SELECT id, front FROM prebuilt_cards "
            "WHERE subject='english' AND card_type='vocabulary'"
        )
    }
    meta = {
        r[0]: (r[1], r[2], r[3])          # pos, pronunciation, definitions
        for r in cur.execute(
            'SELECT id, pos, pronunciation, definitions FROM prebuilt_language_cards'
        )
    }
    con.close()

    cefr = set()
    if os.path.exists(CEFRJ):
        with open(CEFRJ, encoding='utf-8') as f:
            cefr = {x['headword'].lower().strip() for x in json.load(f)}
    return cards, meta, cefr


INFLECT_SUFFIXES = ('s', 'es', 'ed', 'ing', 'ly', 'er', 'est', 'ies', 'd',
                    'ves', "s'", 'man', 'men')

# 释义「指代另一个词」的措辞，分两类 —— 判据不同
DEF_REF_SHORT = re.compile(          # 缩略关系（`short for X` / `abbreviation of X`）
    r"(?:abbreviation|abbr|acronym|short|short form|initialism)"
    r"\s+(?:for|of)\s*[‘'\"]([A-Za-z][\w\-]*(?:\s+[A-Za-z][\w\-]*)?)[’'\"]",
    re.I,
)
DEF_REF_INFLECT = re.compile(        # 词形变化关系（`plural of X` / `past tense of X`）
    r"(?:plural|past tense|past participle|present participle|comparative|"
    r"superlative|form|variant|spelling)\s+(?:for|of)\s*"
    r"[‘'\"]([A-Za-z][\w\-]*(?:\s+[A-Za-z][\w\-]*)?)[’'\"]",
    re.I,
)


def _similar(a: str, b: str) -> float:
    """两个词形的相似度（0–1）。"""
    from difflib import SequenceMatcher
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def _load_form_lemmas() -> dict[str, set[str]]:
    """读 `word_form.json` → {form: {lemma, ...}}。

    用于判断「释义指代的词是否是该词条的合理变形」——
    **字形相似度不适用于不规则变形**（better/good、was/be、caught/catch 字形完全不同），
    必须用词形映射表。
    """
    m: dict[str, set[str]] = defaultdict(set)
    path = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_form.json')
    if not os.path.exists(path):
        return m
    try:
        with open(path, encoding='utf-8') as f:
            for r in json.load(f):
                m[r['form'].lower()].add(r['lemma'].lower())
    except Exception:
        pass
    return m


def find_def_mismatch(cards: dict, meta: dict) -> dict[str, str]:
    """检测「释义讲的是另一个词」→ 该条释义不可信（不依赖源词是否还在库中）。

    🔴 为什么需要这个（2026-09-25 一次误删的教训）：
    「同释义组」检测**依赖源词存在** —— 当源词 `di`/`tr` 被删除后，
    受害词 `diffusing` / `transact` 变成组内唯一成员 → 检测失效 →
    其错误释义「(abbreviation) diameter」又让它被判为缩写 → **被误删**。

    🔴 判据不能用纯字形相似度（2026-09-25 第二次修正）：
    不规则变形的字形**本就不同** —— `better`/`good`、`was`/`be`、`caught`/`catch`
    相似度都 < 0.3，会被误判为「释义错误」。而它们的释义（"comparative of good"）
    **完全正确**。
    → 正确判据：字形相似 **或** 词形映射表能互推。

    🔴 两类指代要分开判（2026-09-25 第三次修正）：
      · **缩略**（`short for X`）—— `nano` = "short for nanotechnology" **是正确的**，
        判据应是**前缀/首字母**：`nano` ⊂ `nanotechnology` ✅；`transact` ⊄ `transitive` ❌
      · **词形变化**（`plural of X`）—— 用词形映射表验证 X 是否是该词的 lemma
    """
    form_lemmas = _load_form_lemmas()

    def _initials(s: str) -> str:
        return ''.join(w[0] for w in s.split() if w).lower()

    def short_ok(word: str, ref: str) -> bool:
        """缩略关系是否成立：词条应是原词的**前缀**或**首字母缩写**。"""
        w, r = word.lower(), ref.lower()
        return r.startswith(w) or _initials(r) == w

    def inflect_ok(word: str, ref: str) -> bool:
        """词形变化关系是否成立。"""
        w, r = word.lower(), ref.lower()
        if _similar(w, r) >= 0.6:
            return True
        return r in form_lemmas.get(w, ()) or w in form_lemmas.get(r, ())

    mismatched: dict[str, str] = {}
    for cid, word in cards.items():
        if not word:
            continue
        _, _, defs = meta.get(cid, (None, None, None))
        if not defs:
            continue
        for it in _def_items(defs):
            mean = it['meaning']
            for rx, check in ((DEF_REF_SHORT, short_ok),
                              (DEF_REF_INFLECT, inflect_ok)):
                m = rx.search(mean)
                if not m:
                    continue
                ref = m.group(1).strip()
                if not ref or check(word, ref):
                    continue
                mismatched[word.lower()] = ref
                break
            if word.lower() in mismatched:
                break
    return mismatched


def find_def_collisions(cards: dict, meta: dict) -> dict[str, str]:
    """检测「释义串位」：两个不同词的 definitions **完全相同**。

    🔴 实测发现（2026-09-25）：这是比预想严重得多的生成缺陷 ——
    不只是多词短语，**单字母/双字母短词的释义会批量覆盖同前缀的后续词**：

        min   （分钟缩写）的释义 → ministrIES / mink / minneapolis 全拿到
        en    （字母 N）的释义   → enver / eugene 拿到
        ne    （内布拉斯加）     → neal 拿到
        ma    （妈妈）           → marvel 拿到
        tr    （及物）           → transact 拿到
        air force 的释义         → air conditioning 拿到
        cap 的释义               → capital letter 拿到

    → 这些「受害词」**多是合法词**（mink 水貂 / ministries 部门 / marvel 奇迹），
      只是释义被错填。**不该删，该重新生成释义**（归 Phase 1 #8）。

    判据：definitions 文本相同 + 一个是另一个的前缀 + 余部不是屈折后缀。
    """
    groups: dict[str, list[str]] = defaultdict(list)
    for cid, word in cards.items():
        if not word:
            continue
        _, _, defs = meta.get(cid, (None, None, None))
        if not defs or len(defs) < 12:      # 太短的释义无区分度
            continue
        groups[defs].append(word)

    collided: dict[str, str] = {}
    for defs, words in groups.items():
        if len(words) < 2:
            continue
        ws = sorted({w.lower() for w in words})
        # 若组内所有词都能用「屈折关系」解释（如 ad/ads）→ 不算串位
        src = ws[0]
        if all(w.startswith(src) and w[len(src):] in INFLECT_SUFFIXES for w in ws[1:]):
            continue
        # 🔴 组内**所有**词都标记为不可信 —— 不知道哪条才是正确释义，
        #    只标记非最短的，会让「最短的那个」带着错误释义继续参与后续判定
        for w in ws:
            collided[w] = f'与其他 {len(ws) - 1} 个词条共享完全相同释义'
    return collided


def classify(word: str, pos: str, pron: str, definitions: str | None,
             in_cefr: bool, def_bad: bool = False) -> tuple[str, str]:
    """返回 (类别, 判定依据)。

    `def_bad=True` 表示**这条的释义不可信**（串位 / 讲的是别的词）→
    **跳过所有基于释义的判据**，只用 词形 / pos / CEFR-J 兜底。

    ⚠️ 设计要点一：**含空格 ≠ 解析残留**。
    词表里有合法的多词短语与连字符词 —— 是正常词条。真正的残留只有
    撇号开头的缩写碎片（`'m` / `'re` / `'s`）。

    ⚠️ 设计要点二：**「不在 CEFR-J」不是污染判据**。
    CEFR-J 只覆盖词库 52%，用它筛会把 `ace`/`apt`/`elm`/`ivy`/`zen` 全标出来。
    """
    w = word
    low = w.lower()
    p = (pos or '').lower()
    pr = pron or ''
    dt = _def_text(definitions)

    # ① 撇号开头的缩写碎片 —— 原词被拆断，不是独立词
    if low.startswith(("'", '’')):
        return 'apostrophe_residue', '撇号开头的缩写碎片（原形疑为 I\'m / we\'re / it\'s）'

    # ② 三连相同字母 —— 绝不可能是英语词
    if TRIPLE.search(low):
        return 'garbage', '三连相同字母'

    # ③ 专有名词（pos 标记）
    if 'proper' in p:
        return 'proper_noun', f'pos={pos!r}'

    # ④ 专有名词（definitions 措辞）—— pos 漏标时的兜底
    #    ⚠️ 必须按义项判断，区分「纯专有」与「兼类」：
    #      abe    → 仅 "nickname for Abraham"        → 纯专有，删
    #      billy  → 人名 + 警棍 + 公羊                → 兼类，**保留**
    #    ⚠️ `def_bad=True` 时**跳过** —— 释义不可信，不能据此判专有
    items = _def_items(definitions)
    if not def_bad and items and len(low) <= 14:
        proper_flags = [it['is_proper'] for it in items]
        if any(proper_flags):
            if all(proper_flags):
                return 'proper_by_def', f'全部义项均为专有（{len(items)} 条义项）'
            return 'proper_mixed', ('兼类：部分义项专有 / 部分普通 '
                                    f'({sum(proper_flags)}/{len(items)} 专有）')

    # ⑤ 化学元素符号 —— 只认「1–2 字母 + pron 或释义明确是元素名」
    if len(low) <= 2:
        em = ELEMENT_NAMES.search(pr) or (None if def_bad else ELEMENT_NAMES.search(dt))
        if em:
            return 'element_symbol', f'元素名（{em.group(0)}）'

    # ⑥ 多词短语（含空格）—— 不是脏数据，但**划词命中不了**，需产品判断
    if ' ' in w:
        return 'multiword_phrase', '含空格（多词短语）'

    # ⑦ 连字符词 / 变音符词 —— 合法词条，保留
    if '-' in w:
        return 'hyphenated', '含连字符（合法复合词）'
    if re.search(r'[^\x00-\x7f]', w):
        return 'accented', '含变音符（合法外来词）'

    # ⑧ 缩写 —— 按**首个义项**判断，区分「真缩写」与「兼类」
    #    gal → "informal term for a girl... 缩写 for gallon" → 首义是口语词 → 兼类，保留
    #    sec → "a very short time; second (informal)"          → 首义是名词   → 兼类，保留
    #    min → "(abbreviation) a minute"                      → 首义即缩写   → 真缩写
    first = items[0]['meaning'] if items else dt
    if not def_bad and DEF_ABBR.search(first):
        return 'abbreviation', '首义自述为缩写'
    if not def_bad and DEF_ABBR.search(dt) and any(DEF_ABBR.search(i['meaning']) for i in items):
        return 'abbr_mixed', '兼类：部分义项为缩写 / 部分为普通词'
    if '.' in w:
        return 'abbreviation', '含句点（缩写形式）'
    if re.search(r'abbr|acronym', p):
        return 'abbreviation', f'pos={pos!r}'
    # 逐字母拼读 —— 需配合「字母/缩写」语境（否则 `ok` 这类本身就是词会被误判）
    if pr and not def_bad and (DEF_ABBR.search(dt) or LETTER_CTX.search(dt)):
        parts = re.findall(r'([a-zɛɪʊɔæʌəɜɒː]+)', pr.lower())
        LETTER_NAMES = {
            'bi', 'biː', 'di', 'diː', 'si', 'siː', 'pi', 'piː', 'ti', 'tiː',
            'vi', 'viː', 'ju', 'juː', 'zi', 'ziː', 'ke', 'keɪ', 'dʒe', 'dʒeɪ',
            'aɪ', 'əʊ', 'waɪ', 'ɛf', 'ef', 'ɛl', 'el', 'ɛm', 'em', 'ɛn', 'en',
            'ɛs', 'es', 'eks', 'ɑːr', 'ar', 'dʌbəlju', 'dʌbəljuː', 'dʌbəl',
        }
        if len(parts) >= 2 and all(k in LETTER_NAMES for k in parts):
            return 'abbreviation', f'pron 逐字母拼读 {pr!r}'

    # ⑨ 功能词白名单 —— 无论多短都保留（长度判据永远不能删它们）
    if low in FUNCTION_WORDS:
        return 'function_word', '功能词白名单'

    # ⑩ 生僻短词（有 (archaic)/(obsolete)/(dialectal) 标记）
    if not def_bad and len(low) <= 4 and DEF_RARE.search(dt):
        m2 = DEF_RARE.search(dt)
        return 'rare_short', f'释义标注 {m2.group(0)}'

    # ⑪ 短词且**无中文释义** —— 这是**内容缺陷**（Phase 1 #8 补中文），
    #     **不是噪声**！实测该类 41 条里 act/ape/bay/end/fog/gum 全是合法词，
    #     只是 definitions 为空（内容未生成）。混进"待删"会误删正常词。
    if not def_bad and len(low) <= 3 and not _has_chinese(definitions):
        return 'content_gap', f'内容缺陷：无中文释义（长度≤{len(low)}）→ Phase 1 #8 补全'

    if in_cefr:
        return 'cefr_ok', '在 CEFR-J 官方词表内'
    return 'normal', '常规词条'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--show', default=None, help='只展示某类别明细')
    ap.add_argument('--max-list', type=int, default=40, help='每类展示条数')
    args = ap.parse_args()

    cards, meta, cefr = load_source()
    print(f'目标词表（english/vocabulary）: {len(cards):,} 条')
    print(f'CEFR-J 官方词表              : {len(cefr):,} 条\n')

    collisions = find_def_collisions(cards, meta)
    mismatches = find_def_mismatch(cards, meta)
    # 释义不可信的并集 —— 这些词的**释义类判据全部失效**
    def_bad = {**collisions, **{k: f'释义疑似在解释 {v!r}' for k, v in mismatches.items()}}
    print(f'检测到释义问题: 串位 {len(collisions)} 条 · 释义指代他词 {len(mismatches)} 条 '
          f'→ 合并 {len(def_bad)} 条释义不可信\n')

    buckets: dict[str, list[dict]] = defaultdict(list)
    for cid, word in cards.items():
        if not word:
            continue
        pos, pron, defs = meta.get(cid, (None, None, None))
        low = word.lower()
        is_bad = low in def_bad
        cls, why = classify(word, pos, pron, defs, low in cefr, def_bad=is_bad)

        # 释义不可信 → 归入 def_collision（除非已被更明确的结构性判据命中）
        if is_bad and cls in ('abbreviation', 'abbr_mixed', 'proper_by_def',
                              'element_symbol', 'rare_short', 'content_gap',
                              'cefr_ok', 'normal', 'def_collision'):
            cls, why = 'def_collision', def_bad[low]

        buckets[cls].append({
            'word': word, 'pos': pos, 'pron': pron, 'reason': why,
            'def': (_def_text(defs) or '')[:160],
        })

    # ── 报告 ──
    LABEL = {
        'apostrophe_residue': ('①  撇号残留碎片',    '🔴 建议删'),
        'garbage':            ('②  纯垃圾',          '🔴 建议删'),
        'proper_noun':        ('③  专有名词(pos)',   '🔴 建议删'),
        'proper_by_def':      ('④  纯专有(释义)',    '🔴 建议删'),
        'element_symbol':     ('⑤  化学元素符号',    '🔴 建议删'),
        'abbreviation':       ('⑥  缩写·真',         '🟠 按常用度处理'),
        'multiword_phrase':   ('⑦  多词短语',        '🟠 待确认'),
        'rare_short':         ('⑧  生僻短词',        '🟠 待确认'),
        'def_collision':      ('⑨  释义串位',        '📝 重生成释义(非噪声)'),
        'content_gap':        ('⑩  内容缺陷·无中文',  '📝 补全(非噪声)'),
        'abbr_mixed':         ('⑪  兼类(缩写+普通)',  '✅ 保留'),
        'proper_mixed':       ('⑫  兼类(专有+普通)',  '✅ 保留·可降级'),
        'hyphenated':         ('⑬  连字符词',        '✅ 保留'),
        'accented':           ('⑭  变音符词',        '✅ 保留'),
        'function_word':      ('⑮  功能词',          '✅ 保留'),
        'cefr_ok':            ('⑯  CEFR-J 内',       '✅ 保留'),
        'normal':             ('⑰  常规词条',        '✅ 保留'),
    }
    order = ['apostrophe_residue', 'garbage', 'proper_noun', 'proper_by_def',
             'element_symbol', 'abbreviation', 'multiword_phrase', 'rare_short',
             'def_collision', 'content_gap', 'abbr_mixed', 'proper_mixed',
             'hyphenated', 'accented', 'function_word', 'cefr_ok', 'normal']

    print('=' * 78)
    print('分类结果')
    print('=' * 78)
    print(f"{'类别':<24}{'数量':>7}  处理建议")
    print('-' * 78)
    for k in order:
        n = len(buckets.get(k, []))
        label, advice = LABEL[k]
        print(f'{label:<24}{n:>7}  {advice}')

    DEL_FLAG = ('apostrophe_residue', 'garbage', 'proper_noun',
                'proper_by_def', 'element_symbol')
    REVIEW = ('abbreviation', 'multiword_phrase', 'rare_short')
    KEEP = ('def_collision', 'content_gap', 'abbr_mixed', 'proper_mixed',
            'hyphenated', 'accented', 'function_word', 'cefr_ok', 'normal')
    total_flagged = sum(len(buckets.get(k, [])) for k in DEL_FLAG)
    total_review = sum(len(buckets.get(k, [])) for k in REVIEW)
    print('-' * 78)
    print(f'🔴 建议删（特征明确・无产品判断）: {total_flagged}')
    print(f'🟠 待确认（需产品判断）          : {total_review}')
    print(f'✅ 保留（合计）                  : {sum(len(buckets.get(k, [])) for k in KEEP)}')

    # ── 明细 ──
    show = [args.show] if args.show else [
        'apostrophe_residue', 'garbage', 'element_symbol',
        'proper_by_def', 'abbreviation', 'def_collision', 'abbr_mixed',
    ]
    for k in show:
        rows = buckets.get(k, [])
        if not rows:
            continue
        label, advice = LABEL[k]
        print(f'\n{"─" * 78}\n{label} · {len(rows)} 条 · {advice}\n{"─" * 78}')
        for r in sorted(rows, key=lambda x: x['word'])[:args.max_list]:
            print(f"  {r['word']:<14} {r['reason']}")
            if r['def']:
                print(f"      └ {r['def'][:110]}")
        if len(rows) > args.max_list:
            print(f"  … 另 {len(rows) - args.max_list} 条")

    # ── 写清单 ──
    payload = {
        '_meta': {
            'total_vocab': len(cards),
            'cefrj_size': len(cefr),
            'note': '本文件为候选清单，未修改任何生产数据；判定依据见 reason 字段',
            'counts': {LABEL[k][0]: len(buckets.get(k, [])) for k in order},
        },
        'flagged_delete': {k: buckets.get(k, []) for k in DEL_FLAG},
        'needs_review': {k: buckets.get(k, []) for k in REVIEW},
        'keep': {k: buckets.get(k, []) for k in KEEP},
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f'\n✅ 清单已写入 {os.path.relpath(OUT, ROOT)}')


if __name__ == '__main__':
    main()
