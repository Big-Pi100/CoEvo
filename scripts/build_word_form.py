#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 #1 · 词形还原映射表生成（反向生成法）

方案依据：docs/design/cefrj-license-and-lemmatization-2026-09-25.md §2.2 / §2.4

核心思路 —— **反向生成，不是通用词形还原**：
    词表词 → 展开全部可能变形 → 建反查表（form → lemma）
    ⇒ 只映射到词表内的词，准确率 100%；运行时零依赖（一张 SQLite 表）

文档 §2.4 记录的三个坑（本脚本均按坑的结论实现）：
    坑 1  数据源必须用 cefr_j_all.json（含全部词性），不可用 flat 版
          （flat 版 851 个词的多个词性被合并 → study 只剩 noun → 生不出 studied）
    坑 2  门控不能无脑放行（会生 runed/studeist/changeing 等垃圾），
          也不能全靠词性门控（study 标 noun 时不生 studied → 漏）
    坑 3  不规则与规则必须互斥（run 同时在两表 → 都跑会生 runed/runing）

🔴 对坑 3 的一处实现修正：
    文档原文说「命中不规则表后直接返回，不再跑规则」。
    但**整体互斥会丢掉规则能正确生成的变形** —— 例如 run 的复数 runs 是规则的，
    若命中不规则表就 return，runs 就丢了。
    本脚本改为**按 (lemma, 规则类别) 精确互斥**：
        不规则表只覆盖「与规则推导结果不同的类别」（如 run 的 past=ran、ing=running），
        plural 等未被覆盖的类别照常走规则 ⇒ 既不生垃圾，也不丢正确变形。

三层门控策略：
    ① plural / past / ing            → 默认放行（不依赖词性）
    ② comparative / superlative / -ly → **仅当词性含 adjective 时**生成
    ③ 无词性信息的词（实测 47.7%）    → 只走 ①

🔴 实测缺口（2026-09-25）：目标词表 12,791 词中，仅 **6,691（52.3%）** 在 cefr_j 里有词性；
   剩余 **6,100（47.7%）** 无词性信息 —— 其中大量是专有名词（ben/anna/tom/lee...），
   正好是 Phase 1 #3 要剔除的对象。本脚本对它们只做默认放行项（不生成 -er/-est/-ly），
   避免给专有名词造出无意义变形。

用法：
    python3 scripts/build_word_form.py                # 生成 + 统计
    python3 scripts/build_word_form.py --verify       # 额外跑覆盖率验证
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CEFR_ALL = ROOT / 'data/curriculum/prebuilt/cefr_j/cefr_j_all.json'
DB = ROOT / 'data/coevo.db'
OUT_JSON = ROOT / 'data/curriculum/prebuilt/word_form.json'
OUT_DB = ROOT / 'data/curriculum/prebuilt/word_form.db'

# 变形类别
RULES = ('plural', 'past', 'past_participle', 'ing',
         'comparative', 'superlative', 'adverb')

# ─────────────────────────────────────────────────────────────
# 不规则表：**只列「与规则推导结果不同」的类别**
#   - 未列出的类别 = 规则能正确生成（如 run 的 plural=runs 走规则）
#   - 这是对文档「整体互斥」的修正，避免丢正确变形
# ─────────────────────────────────────────────────────────────
IRREGULAR: dict[str, dict[str, object]] = {
    # ── 高频动词（past / past_participle / ing / present）──
    # 注：值可以是 str 或 list[str]（如 be 的过去式有 was/were，现在时有 is/are/am）
    #
    # `present` 只列**不规则**的第三人称单数 —— 规则变化（+s / +es / -y→ies）
    # 与 `plural` 规则同形（watch→watches / study→studies / run→runs），已由后者覆盖。
    # 补齐理由（白哥 2026-09-25 批复）：`is`/`are`/`am`/`has` 是**最高频词**，
    # 缺映射会导致划词划到它们查不到 `be`/`have`。
    'be':            {'past': ['was', 'were'], 'past_participle': 'been', 'ing': 'being',
                      'present': ['is', 'are', 'am']},
    'have':          {'past': 'had',       'past_participle': 'had',   'present': 'has'},
    'do':            {'past': 'did',       'past_participle': 'done',  'present': 'does'},
    'go':            {'past': 'went',      'past_participle': 'gone',  'present': 'goes'},
    'say':           {'past': 'said',      'past_participle': 'said'},
    'get':           {'past': 'got',       'past_participle': 'gotten',  'ing': 'getting'},
    'make':          {'past': 'made',      'past_participle': 'made',    'ing': 'making'},
    'know':          {'past': 'knew',      'past_participle': 'known'},
    'think':         {'past': 'thought',   'past_participle': 'thought'},
    'take':          {'past': 'took',      'past_participle': 'taken',   'ing': 'taking'},
    'see':           {'past': 'saw',       'past_participle': 'seen'},
    'come':          {'past': 'came',      'past_participle': 'come',    'ing': 'coming'},
    'give':          {'past': 'gave',      'past_participle': 'given',   'ing': 'giving'},
    'find':          {'past': 'found',     'past_participle': 'found'},
    'tell':          {'past': 'told',      'past_participle': 'told'},
    'become':        {'past': 'became',    'past_participle': 'become',  'ing': 'becoming'},
    'leave':         {'past': 'left',      'past_participle': 'left',    'ing': 'leaving'},
    'feel':          {'past': 'felt',      'past_participle': 'felt'},
    'put':           {'past': 'put',       'past_participle': 'put',     'ing': 'putting'},
    'bring':         {'past': 'brought',   'past_participle': 'brought'},
    'begin':         {'past': 'began',     'past_participle': 'begun',   'ing': 'beginning'},
    'keep':          {'past': 'kept',      'past_participle': 'kept'},
    'hold':          {'past': 'held',      'past_participle': 'held'},
    'write':         {'past': 'wrote',     'past_participle': 'written', 'ing': 'writing'},
    'stand':         {'past': 'stood',     'past_participle': 'stood'},
    'hear':          {'past': 'heard',     'past_participle': 'heard'},
    'let':           {'past': 'let',       'past_participle': 'let',     'ing': 'letting'},
    'mean':          {'past': 'meant',     'past_participle': 'meant'},
    'set':           {'past': 'set',       'past_participle': 'set',     'ing': 'setting'},
    'meet':          {'past': 'met',       'past_participle': 'met'},
    'run':           {'past': 'ran',       'past_participle': 'run',     'ing': 'running'},
    'pay':           {'past': 'paid',      'past_participle': 'paid'},
    'sit':           {'past': 'sat',       'past_participle': 'sat',     'ing': 'sitting'},
    'speak':         {'past': 'spoke',     'past_participle': 'spoken',  'ing': 'speaking'},
    'lie':           {'past': 'lay',       'past_participle': 'lain',    'ing': 'lying'},
    'lead':          {'past': 'led',       'past_participle': 'led'},
    # ── 情态动词（2026-09-25 补：`could`/`should`/`would` 是最高频词，此前完全无映射）──
    #    注：没有过去分词与 -ing 形式
    'can':           {'past': 'could'},
    'may':           {'past': 'might'},
    'shall':         {'past': 'should'},
    'will':          {'past': 'would'},
    'read':          {'past': 'read',      'past_participle': 'read'},
    'grow':          {'past': 'grew',      'past_participle': 'grown'},
    'lose':          {'past': 'lost',      'past_participle': 'lost',    'ing': 'losing'},
    'fall':          {'past': 'fell',      'past_participle': 'fallen'},
    'send':          {'past': 'sent',      'past_participle': 'sent'},
    'build':         {'past': 'built',     'past_participle': 'built'},
    'understand':    {'past': 'understood','past_participle': 'understood'},
    'draw':          {'past': 'drew',      'past_participle': 'drawn'},
    'break':         {'past': 'broke',     'past_participle': 'broken',  'ing': 'breaking'},
    'spend':         {'past': 'spent',     'past_participle': 'spent'},
    'cut':           {'past': 'cut',       'past_participle': 'cut',     'ing': 'cutting'},
    'rise':          {'past': 'rose',      'past_participle': 'risen',   'ing': 'rising'},
    'drive':         {'past': 'drove',     'past_participle': 'driven',  'ing': 'driving'},
    'buy':           {'past': 'bought',    'past_participle': 'bought'},
    'wear':          {'past': 'wore',      'past_participle': 'worn'},
    'choose':        {'past': 'chose',     'past_participle': 'chosen',  'ing': 'choosing'},
    'seek':          {'past': 'sought',    'past_participle': 'sought'},
    'throw':         {'past': 'threw',     'past_participle': 'thrown'},
    'catch':         {'past': 'caught',    'past_participle': 'caught'},
    'deal':          {'past': 'dealt',     'past_participle': 'dealt'},
    'win':           {'past': 'won',       'past_participle': 'won',     'ing': 'winning'},
    'forget':        {'past': 'forgot',    'past_participle': 'forgotten','ing': 'forgetting'},
    'eat':           {'past': 'ate',       'past_participle': 'eaten',   'ing': 'eating'},
    'drink':         {'past': 'drank',     'past_participle': 'drunk'},
    'sing':          {'past': 'sang',      'past_participle': 'sung'},
    'swim':          {'past': 'swam',      'past_participle': 'swum',    'ing': 'swimming'},
    'fly':           {'past': 'flew',      'past_participle': 'flown'},
    'hide':          {'past': 'hid',       'past_participle': 'hidden',  'ing': 'hiding'},
    'ride':          {'past': 'rode',      'past_participle': 'ridden',  'ing': 'riding'},
    'sell':          {'past': 'sold',      'past_participle': 'sold'},
    'teach':         {'past': 'taught',    'past_participle': 'taught'},
    'fight':         {'past': 'fought',    'past_participle': 'fought'},
    'blow':          {'past': 'blew',      'past_participle': 'blown'},
    'shine':         {'past': 'shone',     'past_participle': 'shone',   'ing': 'shining'},
    'shoot':         {'past': 'shot',      'past_participle': 'shot'},
    'sink':          {'past': 'sank',      'past_participle': 'sunk'},
    'steal':         {'past': 'stole',     'past_participle': 'stolen',  'ing': 'stealing'},
    'strike':        {'past': 'struck',    'past_participle': 'struck'},
    'sweep':         {'past': 'swept',     'past_participle': 'swept'},
    'swear':         {'past': 'swore',     'past_participle': 'sworn'},
    'tear':          {'past': 'tore',      'past_participle': 'torn'},
    'wake':          {'past': 'woke',      'past_participle': 'woken',   'ing': 'waking'},
    'bite':          {'past': 'bit',       'past_participle': 'bitten',  'ing': 'biting'},
    'freeze':        {'past': 'froze',     'past_participle': 'frozen',  'ing': 'freezing'},
    'hang':          {'past': 'hung',      'past_participle': 'hung'},
    'shake':         {'past': 'shook',     'past_participle': 'shaken',  'ing': 'shaking'},
    'shut':          {'past': 'shut',      'past_participle': 'shut',    'ing': 'shutting'},
    'spread':        {'past': 'spread',    'past_participle': 'spread'},
    'stick':         {'past': 'stuck',     'past_participle': 'stuck'},
    'sting':         {'past': 'stung',     'past_participle': 'stung'},
    'seek':          {'past': 'sought',    'past_participle': 'sought'},
    'bend':          {'past': 'bent',      'past_participle': 'bent'},
    'bind':          {'past': 'bound',     'past_participle': 'bound'},
    'bleed':         {'past': 'bled',      'past_participle': 'bled'},
    'breed':         {'past': 'bred',      'past_participle': 'bred'},
    'burst':         {'past': 'burst',     'past_participle': 'burst'},
    'cast':          {'past': 'cast',      'past_participle': 'cast'},
    'cling':         {'past': 'clung',     'past_participle': 'clung'},
    'creep':         {'past': 'crept',     'past_participle': 'crept'},
    'dig':           {'past': 'dug',       'past_participle': 'dug',     'ing': 'digging'},
    'feed':          {'past': 'fed',       'past_participle': 'fed'},
    'flee':          {'past': 'fled',      'past_participle': 'fled',    'ing': 'fleeing'},
    'grind':         {'past': 'ground',    'past_participle': 'ground'},
    'hit':           {'past': 'hit',       'past_participle': 'hit',     'ing': 'hitting'},
    'hurt':          {'past': 'hurt',      'past_participle': 'hurt'},
    'kneel':         {'past': 'knelt',     'past_participle': 'knelt'},
    'lay':           {'past': 'laid',      'past_participle': 'laid'},
    'lend':          {'past': 'lent',      'past_participle': 'lent'},
    'light':         {'past': 'lit',       'past_participle': 'lit'},
    'mistake':       {'past': 'mistook',   'past_participle': 'mistaken','ing': 'mistaking'},
    'quit':          {'past': 'quit',      'past_participle': 'quit',    'ing': 'quitting'},
    'seek':          {'past': 'sought',    'past_participle': 'sought'},
    'shed':          {'past': 'shed',      'past_participle': 'shed',    'ing': 'shedding'},
    'slide':         {'past': 'slid',      'past_participle': 'slid',    'ing': 'sliding'},
    'spin':          {'past': 'spun',      'past_participle': 'spun',    'ing': 'spinning'},
    'spit':          {'past': 'spat',      'past_participle': 'spat',    'ing': 'spitting'},
    'split':         {'past': 'split',     'past_participle': 'split',   'ing': 'splitting'},
    'spring':        {'past': 'sprang',    'past_participle': 'sprung'},
    'stink':         {'past': 'stank',     'past_participle': 'stunk'},
    'swing':         {'past': 'swung',     'past_participle': 'swung'},
    'weep':          {'past': 'wept',      'past_participle': 'wept'},
    'wind':          {'past': 'wound',     'past_participle': 'wound'},
    'weave':         {'past': 'wove',      'past_participle': 'woven',   'ing': 'weaving'},
    'shine':         {'past': 'shone',     'past_participle': 'shone',   'ing': 'shining'},
    'foresee':       {'past': 'foresaw',   'past_participle': 'foreseen'},
    'forgive':       {'past': 'forgave',   'past_participle': 'forgiven','ing': 'forgiving'},
    'overcome':      {'past': 'overcame',  'past_participle': 'overcome'},
    'undertake':     {'past': 'undertook', 'past_participle': 'undertaken'},
    'arise':         {'past': 'arose',     'past_participle': 'arisen',  'ing': 'arising'},
    'awake':         {'past': 'awoke',     'past_participle': 'awoken',  'ing': 'awaking'},
    'bear':          {'past': 'bore',      'past_participle': 'borne',   'ing': 'bearing'},
    'beat':          {'past': 'beat',      'past_participle': 'beaten',  'ing': 'beating'},
    'forbid':        {'past': 'forbade',   'past_participle': 'forbidden','ing': 'forbidding'},
    'foresee':       {'past': 'foresaw',   'past_participle': 'foreseen'},
    'freeze':        {'past': 'froze',     'past_participle': 'frozen',  'ing': 'freezing'},
}

# 不规则复数（只列不规则的；规则复数走规则函数）
IRREGULAR_PLURAL: dict[str, str] = {
    'child': 'children', 'foot': 'feet', 'tooth': 'teeth', 'goose': 'geese',
    'man': 'men', 'woman': 'women', 'mouse': 'mice', 'louse': 'lice',
    'ox': 'oxen', 'person': 'people', 'die': 'dice', 'penny': 'pence',
    # 指示代词（2026-09-25 补：`those`/`these` 是最高频词，此前无映射）
    'this': 'these', 'that': 'those',
    # 单复数同形
    'sheep': 'sheep', 'fish': 'fish', 'deer': 'deer', 'series': 'series',
    'species': 'species', 'aircraft': 'aircraft', 'means': 'means',
    'offspring': 'offspring', 'salmon': 'salmon', 'trout': 'trout',
    'swine': 'swine', 'moose': 'moose', 'bison': 'bison',
}

# 不规则比较级/最高级（只列不规则的）
IRREGULAR_DEGREE: dict[str, dict[str, str]] = {
    'good': {'comparative': 'better', 'superlative': 'best'},
    'bad': {'comparative': 'worse', 'superlative': 'worst'},
    'far': {'comparative': 'further', 'superlative': 'furthest'},
    'little': {'comparative': 'less', 'superlative': 'least'},
    'much': {'comparative': 'more', 'superlative': 'most'},
    'many': {'comparative': 'more', 'superlative': 'most'},
    'old': {'comparative': 'elder', 'superlative': 'eldest'},
    'well': {'comparative': 'better', 'superlative': 'best'},
}

# 不规则副词（形容词 → 副词 不走 -ly）
IRREGULAR_ADVERB: dict[str, str] = {
    'good': 'well', 'fast': 'fast', 'hard': 'hard', 'late': 'late',
    'early': 'early', 'high': 'high', 'low': 'low', 'long': 'long',
    'near': 'near', 'far': 'far', 'little': 'little', 'much': 'much',
    'straight': 'straight', 'wrong': 'wrong', 'right': 'right',
}

VOWELS = set('aeiou')
SKIP_RE = re.compile(r"['\-]")           # 含撇号/连字符 → 跳过
ALPHA_RE = re.compile(r'^[a-z]+$')       # 只处理纯字母

# -er/-est 的长度上限（超过则用 more/most）
#   careful(7) → 不加 -er；happy(5)/simple(6)/narrow(6) → 加
MAX_DEGREE_LEN = 6

# 已是比较级/最高级的形式（不再作为 base 叠加 -er/-est）
_DEGREE_FORMS = set()
for _d in IRREGULAR_DEGREE.values():
    _DEGREE_FORMS.update(_d.values())
_DEGREE_FORMS.update({'better', 'best', 'worse', 'worst', 'more', 'most',
                      'less', 'least', 'further', 'furthest', 'farther',
                      'farthest', 'elder', 'eldest'})


def _is_degree_form(w: str) -> bool:
    """判断词本身是否已是比较级/最高级（避免 worstest 这类叠加）。"""
    return w in _DEGREE_FORMS


# 不规则表的全部 value —— 这些词本身已是某词的变形，**不应再作为 base**
# （否则 gone → goning、ran → rans 这类垃圾）
_IRREGULAR_FORMS: set[str] = set()
for _m in IRREGULAR.values():
    for _v in _m.values():
        if isinstance(_v, list):
            _IRREGULAR_FORMS.update(_v)
        else:
            _IRREGULAR_FORMS.add(_v)

# 🔴 关键修正（2026-09-25）：剔除「本身也是 lemma」的形式。
# 原因：`run` 的过去分词就是 `run`、`cut`/`put`/`set`/`let`/`hit`/`read` 同理 ——
#   这些词会因**自指**被加进本集合，进而在生成循环里被整条跳过，
#   导致 `running`/`ran`/`cutting` 等最高频词形**完全没有映射**。
#   （实测：`running` / `ran` 在映射表中 0 条记录）
_IRREGULAR_FORMS -= set(IRREGULAR)

# 不生成复数的词（be → bes 是垃圾；he/she/it 等因长度门控自然跳过）
NO_PLURAL = {'be'}

# 长度门控豁免：这些短词是真实高频实义动词，虽 ≤2 字母但必须生成变形
# 🔴 2026-09-25 修正：原先「长度<3 一律跳过」会整体过滤掉 be/do/go
#    → went/going/goes/was/being/did/does 全部无映射（英语最高频词形！）
SHORT_BUT_REAL = {'be', 'do', 'go'}


def _is_polluted(w: str) -> bool:
    """污染短词检测（文档 §2.4「清理 76 个污染短词 ab/bw/zg」）。

    启发式：无元音、或长度 ≤2、或三连相同字母 —— 这些不是真实英语词。
    正式清理见 Phase 1 #4；此处只做兜底，避免给非词生成变形。

    ⚠️ 必须豁免 SHORT_BUT_REAL —— 否则 be/do/go 会被判为「长度≤2 污染词」而整体过滤。
    """
    if w in SHORT_BUT_REAL:
        return False
    if len(w) <= 2:
        return True
    if not any(c in VOWELS for c in w) and not (w.endswith('y') and len(w) > 1):
        return True                        # bbb / bw / zg 无元音
    if re.search(r'(.)\1\1', w):
        return True                        # bbb 三连
    return False


# ─────────────────────────────────────────────────────────────
# 规则变形函数
# ─────────────────────────────────────────────────────────────

def _should_double(word: str) -> bool:
    """CVC 模式且为单音节 → 双写末位辅音（stop→stopped, run→running）。

    简化判定：长度 ≤ 4 且「辅-元-辅」结尾。
    长词（多音节）不双写 —— 少数例外（prefer→preferred）由覆盖率验证兜底。
    """
    if len(word) < 3 or len(word) > 4:
        return False
    a, b, c = word[-3], word[-2], word[-1]
    return (a not in VOWELS and b in VOWELS and c not in VOWELS
            and c not in 'wxy')


def rule_plural(w: str) -> str | None:
    if w in NO_PLURAL:
        return None
    if w in IRREGULAR_PLURAL:
        return IRREGULAR_PLURAL[w]
    if w.endswith(('s', 'x', 'z', 'ch', 'sh')):
        return w + 'es'
    if w.endswith('y') and len(w) > 1 and w[-2] not in VOWELS:
        return w[:-1] + 'ies'
    if w.endswith('o') and len(w) > 1 and w[-2] not in VOWELS:
        return w + 'es'
    return w + 's'


def rule_past(w: str) -> str | list[str] | None:
    if w in IRREGULAR and 'past' in IRREGULAR[w]:
        return IRREGULAR[w]['past']          # str 或 list[str]
    if w.endswith('e'):
        return w + 'd'
    if w.endswith('y') and len(w) > 1 and w[-2] not in VOWELS:
        return w[:-1] + 'ied'
    if _should_double(w):
        return w + w[-1] + 'ed'
    return w + 'ed'


def rule_past_participle(w: str) -> str | list[str] | None:
    if w in IRREGULAR and 'past_participle' in IRREGULAR[w]:
        return IRREGULAR[w]['past_participle']
    return rule_past(w)


def rule_ing(w: str) -> str | None:
    if w in IRREGULAR and 'ing' in IRREGULAR[w]:
        return IRREGULAR[w]['ing']
    if w.endswith('ii'):
        return None                       # hawaii/pompeii/radii + ing 是垃圾
    if w.endswith('ie'):
        return w[:-2] + 'ying'
    if w.endswith('e') and not w.endswith('ee') and len(w) > 2:
        return w[:-1] + 'ing'
    if _should_double(w):
        return w + w[-1] + 'ing'
    return w + 'ing'


def rule_comparative(w: str) -> str | None:
    if w in IRREGULAR_DEGREE and 'comparative' in IRREGULAR_DEGREE[w]:
        return IRREGULAR_DEGREE[w]['comparative']
    if _is_degree_form(w):
        return None                       # best/worst 等已是最高级，不再叠加
    if len(w) > MAX_DEGREE_LEN:
        return None                       # 长词用 more —— careful/beautiful 不加 -er
    if w.endswith('e'):
        return w + 'r'
    if w.endswith('y') and len(w) > 1 and w[-2] not in VOWELS:
        return w[:-1] + 'ier'
    if _should_double(w):
        return w + w[-1] + 'er'
    return w + 'er'


def rule_superlative(w: str) -> str | None:
    if w in IRREGULAR_DEGREE and 'superlative' in IRREGULAR_DEGREE[w]:
        return IRREGULAR_DEGREE[w]['superlative']
    if _is_degree_form(w):
        return None
    if len(w) > MAX_DEGREE_LEN:
        return None
    if w.endswith('e'):
        return w + 'st'
    if w.endswith('y') and len(w) > 1 and w[-2] not in VOWELS:
        return w[:-1] + 'iest'
    if _should_double(w):
        return w + w[-1] + 'est'
    return w + 'est'


def rule_present(w: str) -> str | list[str] | None:
    """第三人称单数现在时。

    只显式处理**不规则**的（be/have/do/go）——
    规则变化（+s / +es / 辅音+y→ies）与 `plural` 规则**同形**，
    已被后者覆盖：watch→watches、study→studies、run→runs。
    若这里也生成，只会被 (form, lemma) 去重掉，徒增调用。
    """
    if w in IRREGULAR and 'present' in IRREGULAR[w]:
        return IRREGULAR[w]['present']
    return None


def rule_adverb(w: str) -> str | None:
    if w in IRREGULAR_ADVERB:
        return IRREGULAR_ADVERB[w]
    if w.endswith('ly'):
        return None                       # 已是副词，不叠加
    if w.endswith('ll'):
        return w + 'y'                    # dull→dully, full→fully（消一个 l）
    if w.endswith('y') and len(w) > 1 and w[-2] not in VOWELS:
        return w[:-1] + 'ily'
    if w.endswith('le') and len(w) > 2 and w[-3] not in VOWELS:
        return w[:-1] + 'y'               # simple → simply
    if w.endswith('ic'):
        return w + 'ally'
    return w + 'ly'


RULE_FUNCS = {
    'plural': rule_plural,
    'past': rule_past,
    'past_participle': rule_past_participle,
    'ing': rule_ing,
    'present': rule_present,
    'comparative': rule_comparative,
    'superlative': rule_superlative,
    'adverb': rule_adverb,
}

# 需要形容词词性的类别（坑 2 的精细化门控）
ADJ_ONLY = ('comparative', 'superlative', 'adverb')


# ─────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────

def load_targets() -> tuple[dict[str, set[str]], dict[str, int]]:
    """返回 (lemma → 词性集合, lemma → word_id)。

    目标词表 = prebuilt_cards 中 subject='english' AND card_type='vocabulary'。
    词性来自 cefr_j_all.json（坑 1：必须用 all 版）。
    """
    pos_map: dict[str, set[str]] = defaultdict(set)
    with open(CEFR_ALL, encoding='utf-8') as f:
        for row in json.load(f):
            hw = row['headword'].lower().strip()
            if hw:
                pos_map[hw].add(row['pos'].lower().strip())

    id_map: dict[str, int] = {}
    con = sqlite3.connect(DB)
    for cid, front in con.execute(
        "SELECT id, front FROM prebuilt_cards "
        "WHERE subject='english' AND card_type='vocabulary'"
    ):
        w = (front or '').lower().strip()
        if w:
            id_map[w] = cid
    con.close()
    return pos_map, id_map


def build() -> tuple[list[dict], dict]:
    pos_map, id_map = load_targets()
    vocab = set(id_map)

    rows: list[dict] = []
    seen: set[tuple[str, str]] = set()
    stats = defaultdict(int)
    no_pos = 0

    for lemma in sorted(vocab):
        # ── 前置过滤 ──
        # 长度门控：<3 字母跳过（避免 a → abed/abest）
        #   🔴 但豁免 SHORT_BUT_REAL（be/do/go）—— 否则这三个最高频动词的
        #      全部变形会消失（went/going/goes/was/being/did/does）
        if len(lemma) < 3 and lemma not in SHORT_BUT_REAL:
            stats['skip_short'] += 1
            continue
        if not ALPHA_RE.match(lemma):
            stats['skip_non_alpha'] += 1
            continue
        if _is_polluted(lemma):
            stats['skip_polluted'] += 1
            continue
        # 本身已是某词的不规则变形 → 不再作为 base（gone→goning、ran→rans）
        if lemma in _IRREGULAR_FORMS:
            stats['skip_irregular_form'] += 1
            continue

        pos = pos_map.get(lemma, set())
        if not pos:
            no_pos += 1
        stats['lemmas'] += 1

        for rule, fn in RULE_FUNCS.items():
            # 门控 ②：形容词专属类别
            if rule in ADJ_ONLY and 'adjective' not in pos:
                stats[f'gate_{rule}'] += 1
                continue

            form_result = fn(lemma)
            if not form_result:
                continue

            # 不规则表的值可能是 list（如 be 的 past = was/were）
            candidate_forms = (form_result if isinstance(form_result, list)
                               else [form_result])

            for form in candidate_forms:
                if not form or form == lemma:
                    continue
                if not ALPHA_RE.match(form):
                    continue

                # 🔴 关键设计修正（2026-09-25）：
                # 文档 §2.4 原文写「生成的变形本身在词表里 → 不建立映射」，
                # 但实测发现：run/running/ran/better/made/went/written **全都在词表里**
                #   → 按原文实现会让这些最高频的词形全部无法还原（实测 7/14 关键测试词未命中）
                #
                # 根因：词表里存在 **838 条「屈折重复立卡」**（文档 §2.2 已记载），
                #   即 running 既作为独立卡片存在、又是 run 的屈折形式。
                #   文档原文举的例子 building 确实有独立语义，但 running/ran/better 不是。
                #
                # 修正：**无条件建立映射**，另加 in_vocab 标记交由 Phase 1 #5（词族聚合）
                #   决定哪些 form 应保留独立语义（如 building）、哪些应合并到 lemma。
                #   这样 #1 独立可用，#5 有决策依据，两条规则不再冲突。
                key = (form, lemma)
                if key in seen:
                    continue
                seen.add(key)

                in_vocab = form in vocab
                if in_vocab:
                    stats['form_in_vocab'] += 1

                rows.append({
                    'form': form,
                    'lemma': lemma,
                    'rule': rule,
                    'in_vocab': 1 if in_vocab else 0,
                    'word_id': id_map.get(lemma),
                })
                stats['rows'] += 1

    stats['no_pos_lemmas'] = no_pos
    stats['vocab_size'] = len(vocab)
    return rows, stats


def dump(rows: list[dict]) -> None:
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump(rows, f, ensure_ascii=False, separators=(',', ':'))

    if OUT_DB.exists():
        OUT_DB.unlink()
    con = sqlite3.connect(OUT_DB)
    con.execute("""
        CREATE TABLE word_form (
            form     TEXT NOT NULL,
            lemma    TEXT NOT NULL,
            rule     TEXT NOT NULL,
            in_vocab INTEGER DEFAULT 0,   -- 1 = 该 form 在词表里另有独立卡片，
                                          --     Phase 1 #5 词族聚合时据此判断是保留还是合并
            word_id  INTEGER,
            PRIMARY KEY (form, lemma)
        )
    """)
    con.execute("CREATE INDEX idx_form ON word_form (form)")
    con.execute("CREATE INDEX idx_lemma ON word_form (lemma)")
    con.executemany(
        "INSERT OR IGNORE INTO word_form "
        "(form, lemma, rule, in_vocab, word_id) "
        "VALUES (:form, :lemma, :rule, :in_vocab, :word_id)",
        rows,
    )
    con.commit()
    con.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--verify', action='store_true', help='额外跑覆盖率验证')
    args = ap.parse_args()

    print('Phase 1 #1 · 词形还原映射生成（反向生成法）')
    print('=' * 62)

    rows, stats = build()

    print(f"目标词表（english/vocabulary）: {stats['vocab_size']:,}")
    print(f"  其中无词性信息            : {stats['no_pos_lemmas']:,} "
          f"({stats['no_pos_lemmas']/max(stats['vocab_size'],1)*100:.1f}%)")
    print(f"  参与生成                  : {stats['lemmas']:,}")
    print(f"  跳过（长度<3，非豁免）      : {stats['skip_short']:,}")
    print(f"  跳过（含撇号/连字符）       : {stats['skip_non_alpha']:,}")
    print(f"  跳过（污染词）             : {stats['skip_polluted']:,}")
    print(f"  跳过（本身是不规则变形）    : {stats['skip_irregular_form']:,}")
    print()
    print(f"✅ 生成映射: {len(rows):,} 条")
    print(f"  其中 form 在词表里另有卡片  : {stats['form_in_vocab']:,} "
          f"（交给 #5 词族聚合决策）")
    gated = sum(v for k, v in stats.items() if k.startswith('gate_'))
    print(f"  门控拦截（非形容词）        : {gated:,}")

    # 按规则分布
    dist = defaultdict(int)
    for r in rows:
        dist[r['rule']] += 1
    print()
    print('  按规则分布:')
    for k in RULES:
        if dist.get(k):
            print(f"    {k:<18} {dist[k]:>7,}")

    dump(rows)
    print()
    print(f"已写出:\n  {OUT_JSON.relative_to(ROOT)}\n  {OUT_DB.relative_to(ROOT)}")

    if args.verify:
        verify(rows)
    return 0


# ─────────────────────────────────────────────────────────────
# 覆盖率验证（用文档 §2.3 记录的测样思路）
# ─────────────────────────────────────────────────────────────

SAMPLES = {
    'VOA 科技': (
        "Scientists in the United States have developed a new method "
        "to study how storms form over the ocean. The researchers used "
        "satellites and computer models to track changes in temperature. "
        "They found that small changes can lead to big effects. "
        "The team published their findings last week. "
        "Experts say the work could help cities prepare for extreme weather."
    ),
    'BBC 教学': (
        "Learning a language takes time and effort. Many students believe "
        "that studying grammar rules is the most important part, but "
        "teachers say reading widely helps more. When you meet a new word, "
        "try to guess its meaning from the sentence. Adults often worry "
        "about making mistakes, yet children simply try again. "
        "The best learners read every day and review what they studied."
    ),
    '文化评论': (
        "Cities have always changed. The buildings we build today may be "
        "gone tomorrow, replaced by newer designs. People who live in "
        "cities often feel both excited and tired. They move quickly, "
        "work hard, and rarely stop. Yet the same streets hold memories. "
        "Writers have written about this tension for centuries, and their "
        "stories still speak to us."
    ),
    '商业新闻': (
        "The company reported strong results last quarter. Sales grew by "
        "twelve percent, and profits rose for the third year running. "
        "Executives said they would invest in new technology and hire "
        "more engineers. Analysts were pleased but warned that costs "
        "could increase. Shares rose after the announcement, though some "
        "investors remained cautious about future growth."
    ),
}

STOPWORDS = set("""
a an the and or but if while of to in on at by for with from as is are was
were be been being am do does did have has had it its this that these those
i you he she we they me him her us them my your his their our not no so
than then there here when where who whom which what how all both each few
more most other some such only own same too very can will just should now
""".split())


def verify(rows: list[dict]) -> None:
    print()
    print('=' * 62)
    print('覆盖率验证（文档 §2.3 口径：直接命中 + 变形还原 + 停用词）')
    print('=' * 62)

    pos_map, id_map = load_targets()
    vocab = set(id_map)
    form_map: dict[str, str] = {}
    for r in rows:
        form_map.setdefault(r['form'], r['lemma'])

    total_ok = 0
    for name, text in SAMPLES.items():
        words = re.findall(r"[a-z']+", text.lower())
        direct = morph = stop = miss = 0
        missed = []
        for w in words:
            if w in STOPWORDS:
                stop += 1
            elif w in vocab:
                direct += 1
            elif w in form_map and form_map[w] in vocab:
                morph += 1
            else:
                miss += 1
                missed.append(w)
        n = max(len(words), 1)
        cover = (direct + morph + stop) / n * 100
        total_ok += 1
        print(f"\n{name}  (共 {n} 词)")
        print(f"  直接命中 {direct/n*100:5.1f}%  "
              f"变形还原 {morph/n*100:5.1f}%  "
              f"停用词 {stop/n*100:5.1f}%  "
              f"未命中 {miss/n*100:5.1f}%")
        print(f"  → 总覆盖 {cover:.1f}%")
        if missed:
            print(f"  未命中词: {sorted(set(missed))[:12]}")

    print()
    print("⚠️ 与文档 §2.3 的 97.6% 对比时注意：测样文本不同、长度更短（几十词 vs 数百词），")
    print("   短文本的变形重复本来就少 → 变形还原占比会低于 26%，属正常。")


if __name__ == '__main__':
    sys.exit(main())
