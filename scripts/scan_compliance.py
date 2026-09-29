#!/usr/bin/env python3
"""内容合规扫描 —— 涉主权 / 涉政 / 涉黄暴 / 涉歧视 / 涉恐

## 为什么必须存在

词库是**交付给用户的内容**。预制库的卡我们**逐轮核查过** —— 曾查出 `taiwan` / `tibet`
释义的涉主权错误，**已于 2026-09-26 修正**（全库 **P0 归零**）；但
**动态生成（LLM 兜底制卡）没有人工环节** —— 一旦这条路打开，风险就直接暴露给用户。

→ 所以这个扫描器是「按需生长」路线的**前置闸门**，必须自动化、可复跑、可挂 CI。

## 三条判据铁律（首版踩坑后固化）

### 铁律 1：必须按**词边界**匹配，不能用裸子串

首版用裸子串 → 误报爆炸：

| 误报 | 原因 |
|---|---|
| `grape` / `scraped` / `drapery` 命中 `rape` | **子串**（g**rape**、sc**rape**d、d**rape**ry） |
| `schooner` 命中 `coon` | 子串（s**coon**er） |
| `japs` 命中 `jap` | 无边界 |

全是**正常词汇**。→ 一律用 `(?<![a-z])term(?![a-z])`。

### 铁律 2：**敏感词条 ≠ 违规内容**

收录 `nigger` / `retard` 作为词条是**合理的**（学习者可能查到）。
关键是**内容怎么处理它**：

- ✅ **正确**：`nigger` 的例句写 "The word nigger is a racial slur." —— **明确标注冒犯性**
- ✅ **正确**：`retard` 的例句写 "The cold weather retarded the growth of the crops." —— 用的是「延缓」正常义
- 🔴 **违规**：把贬义词当**中性词**介绍，不标注，或用于正常语境

→ 所以：**若内容明确标注了冒犯性**（slur/offensive/贬称/蔑称…）→ 跳过；
**若该词另有正常义**（delay/slow/延缓…）→ 降为 P2 待人工确认。

这与 `data-noise-classification` skill 的「**自述型措辞 > 描述型措辞**」同源 ——
**要看它怎么被描述，而不只是出现了什么词**。

### 铁律 3：核心是**组合判定**，不是关键词

`independent` 单见完全正常（"an independent researcher"）。
只有当**敏感主体 × 主权类措辞同现**才升级：

    地名/主体（taiwan、tibet、xinjiang…） + 主权词（self-governing / independent /
    sovereign / de facto / kingdom / separatist）= 🔴 P0

### 铁律 4：**「独立王国」本身不是错的，只有针对中国领土才错**

`independent kingdom/country/nation` 若**同字段内没有中国领土主体** → 不报。
（「India became an independent nation in 1947」「Hanover was once an independent
kingdom」都是史实）。详见 `HARD_BLOCK_WITH_SUBJECT` 处注释。

### 铁律 5：**官方行政区划名 ≠ 主权主张**

「自治区」是中国的**正式行政区划名称**（Tibet / Inner Mongolia / Xinjiang /
Guangxi / Ningxia **Autonomous Region**）。说「西藏是中国的一个自治区」
**恰是正确表述** → `autonomous region` **不得进主权措辞表**。
详见 `SOVEREIGN_CLAIM_WORDS` 处注释。

> 🔑 **加词前先问：这个词出现在「正确表述」里，会不会触发？** 会，就不能加。

## 分级

| 级 | 含义 | 处置 |
|---|---|---|
| **P0** | 明确违规（涉主权错误 / 歧视未标注） | 🔴 **必须修，不可上线** |
| **P1** | 高风险，需人工复核 | 🟠 复核后决定 |
| **P2** | 提示（可能误报，如词有正常义） | 🟡 记录，不阻塞 |

## 用法

    python3 scripts/scan_compliance.py                    # 扫 data/word.db
    python3 scripts/scan_compliance.py --json out.json     # 输出 JSON
    python3 scripts/scan_compliance.py --level P0          # 只看 P0

退出码：**有 P0 → 1**（可挂 CI 阻断）；否则 0。

## 词表在哪 / 怎么共用

🔑 词表**不在本文件**，在 `backend/prompts/compliance_terms.json` ——
**离线扫描（本文件）与在线制卡闸门（`api_server/src/compliance.rs`）读同一份**。
本文件的规则引擎是 `scan_parts(parts, spelling)`；Rust 侧同义函数在 `compliance.rs`。
两边一致性由 **共享用例** 保证：`backend/prompts/compliance_cases.json`
+ `scripts/verify_compliance_parity.py`（Python 端跑）+ `cargo test`（Rust 端跑同一份）。
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(ROOT, 'data', 'word.db')


#: 🔴 词表/规则的**单一来源** —— Python 与 Rust（`api_server/src/compliance.rs`）都读它。
#:    内联两份 → 迟早分叉（改了一边忘另一边）。
TERMS_PATH = os.path.join(ROOT, 'backend', 'prompts', 'compliance_terms.json')


def load_terms(path=TERMS_PATH):
    """读共用词表。

    🔴 文件缺失 / 键缺失 / 正则编译失败 → **直接抛错**。
       合规闸门**不允许静默降级**成「没有词表 → 全部放行」——
       那正是「静默失效 = 主要敌人」的教科书案例。
    """
    with open(path, encoding='utf-8') as f:
        raw = json.load(f)

    def _need(key):
        if key not in raw:
            raise KeyError('compliance_terms.json 缺键: {}'.format(key))
        return raw[key]

    return {
        'sovereign_subjects': _need('sovereign_subjects'),
        'sovereign_claim_words': _need('sovereign_claim_words'),
        'strong_claim_words': set(_need('strong_claim_words')),
        'hard_block_with_subject': [(re.compile(d['pattern'], re.I), d['why'])
                                    for d in _need('hard_block_with_subject')],
        'hard_block_always': [(re.compile(d['pattern'], re.I), d['why'])
                              for d in _need('hard_block_always')],
        'political_subjects': _need('political_subjects'),
        'political_claim_words': _need('political_claim_words'),
        'violence_sex_terms': _need('violence_sex_terms'),
        'discrimination_terms': _need('discrimination_terms'),
        'slur_ack_terms': _need('slur_ack_terms'),
        'neutral_sense_terms': _need('neutral_sense_terms'),
    }


_T = load_terms()


# ── 以下 11 个名字是「规则引擎」直接引用的接口（Rust 侧同义）──
SOVEREIGN_SUBJECTS = _T['sovereign_subjects']
SOVEREIGN_CLAIM_WORDS = _T['sovereign_claim_words']
_STRONG_CLAIM = _T['strong_claim_words']
HARD_BLOCK_WITH_SUBJECT = _T['hard_block_with_subject']
HARD_BLOCK_ALWAYS = _T['hard_block_always']
POLITICAL_SUBJECTS = _T['political_subjects']
POLITICAL_CLAIM_WORDS = _T['political_claim_words']
VIOLENCE_SEX_TERMS = _T['violence_sex_terms']
DISCRIMINATION_TERMS = _T['discrimination_terms']
_SLUR_ACK_TERMS = _T['slur_ack_terms']
_NEUTRAL_SENSE_TERMS = _T['neutral_sense_terms']


# ─────────────────────────────────────────────────────────────
# 判据工具
# ─────────────────────────────────────────────────────────────
_BOUNDARY_CACHE = {}


def _bounded(term):
    """把词条编译成**带词边界**的正则（缓存）。

    🔴 铁律 1：必须用边界 —— 裸子串会命中 g**rape**/s**coon**er 这类正常词。
    """
    if term not in _BOUNDARY_CACHE:
        t = term.strip()
        if ' ' in t:
            pat = r'\b' + r'\s+'.join(re.escape(p) for p in t.split()) + r'\b'
        else:
            pat = r'(?<![a-z])' + re.escape(t) + r'(?![a-z])'
        _BOUNDARY_CACHE[term] = re.compile(pat, re.I)
    return _BOUNDARY_CACHE[term]


def _first_hit(text, terms):
    """返回第一个在词边界处命中的词（含位置），无则 None。"""
    for t in terms:
        m = _bounded(t).search(text)
        if m:
            return t, m.start()
    return None


def _all_hits(text, terms):
    out = []
    for t in terms:
        m = _bounded(t).search(text)
        if m:
            out.append((t, m.start()))
    return out


def _build_scan_text(rec):
    """把一张卡的所有可读文本拆成 (字段名, 文本)。"""
    parts = []
    if rec.get('spelling'):
        parts.append(('spelling', rec['spelling']))
    if rec.get('etymology_text'):
        parts.append(('etymology_text', rec['etymology_text']))
    card = rec.get('card')
    if isinstance(card, dict):
        for i, s in enumerate(card.get('sections') or []):
            t = s.get('type') or f'section{i}'
            for key in ('en', 'zh', 'text', 'source'):
                v = s.get(key)
                if isinstance(v, str) and v.strip():
                    parts.append((f'{t}.{key}', v))
    return parts


def _snip(text, pos, width=95):
    a = max(0, pos - 32)
    return text[a:a + width].replace('\n', ' ').strip()


def scan_parts(parts, spelling):
    """**规则引擎** —— 对 (字段名, 文本) 列表跑 5 条铁律。

    🔑 与 Rust 侧 `compliance.rs::scan_parts` 是**同一套规则**；
       两边共用 `backend/prompts/compliance_terms.json` 的词表。
       跨语言一致性由共享用例保证：
       `backend/prompts/compliance_cases.json` + `scripts/verify_compliance_parity.py`。

    返回：[ (level, category, field, snippet, reason) ]
    """
    findings = []
    spelling = (spelling or '').strip().lower()
    joined = ' '.join(t for _, t in parts)
    acknowledged = _first_hit(joined, _SLUR_ACK_TERMS) is not None
    neutral = _first_hit(joined, _NEUTRAL_SENSE_TERMS) is not None

    # ── ①a 无条件硬阻断（任何字段）──
    for label, text in parts:
        for pat, why in HARD_BLOCK_ALWAYS:
            m = pat.search(text)
            if m:
                findings.append(('P0', '涉主权', label, _snip(text, m.start()), why))

    # ── ①b 需主体触发的硬阻断（🔴 铁律 4：同字段内必须出现中国领土主体）──
    for label, text in parts:
        if not _first_hit(text, SOVEREIGN_SUBJECTS):
            continue
        for pat, why in HARD_BLOCK_WITH_SUBJECT:
            m = pat.search(text)
            if m:
                findings.append(('P0', '涉主权', label, _snip(text, m.start()), why))

    # ── ② 敏感主体 × 主权类措辞（同字段内组合）──
    for label, text in parts:
        subj = _first_hit(text, SOVEREIGN_SUBJECTS)
        if not subj:
            continue
        claim = _first_hit(text, SOVEREIGN_CLAIM_WORDS)
        if not claim:
            continue
        w = claim[0]
        findings.append(
            ('P0' if w in _STRONG_CLAIM else 'P1', '涉主权', label,
             _snip(text, claim[1]),
             f'领土主体「{subj[0]}」与「{w}」同现'))

    # ── ③ 涉政 ──
    for label, text in parts:
        subj = _first_hit(text, POLITICAL_SUBJECTS)
        if not subj:
            continue
        cls = _first_hit(text, POLITICAL_CLAIM_WORDS)
        findings.append(
            ('P0' if cls else 'P1', '涉政', label, _snip(text, subj[1]),
             f'政治主体「{subj[0]}」'
             + (f' + 定性词「{cls[0]}」' if cls else '（需人工复核）')))

    # ── ④ 涉黄暴 / 涉恐（只扫用户直接看到的释义与例句）──
    #   🔴 铁律 2c：**词条本身就是该敏感词 → 跳过**。
    #   `massacre`/`rape`/`terrorist`/`prostitution`/`narcotics` 的例句
    #   正是在**解释这个词本身**（"She was a victim of rape."）—— 正确行为，不是违规。
    #   只有**敏感词与词条无关**时才报（例：中性词的例句里蹦出色情词）。
    for label, text in parts:
        if label.endswith(('.en', '.zh', '.text')):
            for w, pos in _all_hits(text, VIOLENCE_SEX_TERMS):
                if w.lower() == spelling:
                    continue
                findings.append(('P1', '涉黄暴/涉恐', label, _snip(text, pos),
                                 f'敏感词「{w}」（词条非该词）'))

    # ── ⑤ 涉歧视 ──
    for label, text in parts:
        for w, pos in _all_hits(text, DISCRIMINATION_TERMS):
            same_word = (spelling == w.lower())
            # 🔑 铁律 2a：词条即该敏感词 + **明确标注冒犯性** → 正确的词典行为，不报
            if same_word and acknowledged:
                continue
            # 🔑 铁律 2b：该词另有正常义（retard=延缓）→ P2 待确认
            if neutral:
                findings.append(('P2', '涉歧视', label, _snip(text, pos),
                                 f'「{w}」—— 但该词另有正常义，需人工确认语境'))
                continue
            # 🔑 铁律 2d：词条即该词、但**未标注冒犯性** → P1（收录正当，缺标注是缺陷）
            #    实例：`cripple` 释义「使跛足」无标注 → 建议补 "(dated/offensive)"
            if same_word:
                findings.append(('P1', '涉歧视', label, _snip(text, pos),
                                 f'「{w}」为敏感词但**未标注冒犯性** → 建议补标注'))
                continue
            # 其余：敏感词出现在**别的词**的内容里且无标注 → P0
            findings.append(('P0', '涉歧视', label, _snip(text, pos),
                             f'歧视性词汇「{w}」出现在非该词的内容中且未标注'))

    # 去重：**同一字段的同一类别**只留一条（取最严重级别，原因合并）
    #   实例：`tibet` 的定义同时命中「historically an independent」+「independent kingdom」
    #   +「主体与 independent 同现」—— 同一个问题被 3 条规则描述，应合并为 1 条。
    #   ⚠️ 首版用 `snip[:60]` 做键**不可靠**：`_snip` 从命中位置往前 32 字符起算，
    #      不同命中位置 → snip 不同 → 同一句话也会被当成多条（实测 tibet 报了 3 条）。
    #   → 正确做法是按 `(类别, 字段)` 聚合（合规场景下「一段有问题就该整段重写」，
    #      不需要逐条列规则命中）。
    _rank = {'P0': 0, 'P1': 1, 'P2': 2}
    best = {}
    for lvl, cat, field, snip, reason in findings:
        key = (cat, field)
        if key not in best:
            best[key] = [lvl, cat, field, snip, [reason]]
            continue
        cur = best[key]
        if _rank[lvl] < _rank[cur[0]]:
            cur[0] = lvl
        if reason not in cur[4]:
            cur[4].append(reason)
    return [(v[0], v[1], v[2], v[3], ' + '.join(v[4])) for v in best.values()]


def scan_record(rec):
    """扫描一条**词库记录**（`word` + `card`）→ 发现列表。"""
    return scan_parts(_build_scan_text(rec), rec.get('spelling'))


def load_records(con):
    con.row_factory = sqlite3.Row
    rows = con.execute("""
        SELECT w.id, w.spelling, w.entry_type, w.etymology_text, c.content
        FROM word w LEFT JOIN card c ON c.word_id = w.id""").fetchall()
    out = []
    for r in rows:
        card = None
        if r['content']:
            try:
                card = json.loads(r['content'])
            except Exception:
                card = None
        out.append({'id': r['id'], 'spelling': r['spelling'],
                    'entry_type': r['entry_type'],
                    'etymology_text': r['etymology_text'], 'card': card})
    return out


def main():
    ap = argparse.ArgumentParser(description='内容合规扫描')
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--json', dest='json_out', help='把结果写成 JSON')
    ap.add_argument('--level', help='只显示该级别（P0/P1/P2）')
    ap.add_argument('--limit', type=int, default=0, help='每级最多显示条数（0=全部）')
    ap.add_argument('--quiet', action='store_true', help='只打印汇总')
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f'找不到词库 {args.db}')

    con = sqlite3.connect(args.db)
    recs = load_records(con)
    con.close()
    print(f'扫描 {args.db}')
    print(f'词条 {len(recs):,}')

    allf = []
    for r in recs:
        for lvl, cat, field, snip, reason in scan_record(r):
            allf.append((r['id'], r['spelling'], lvl, cat, field, snip, reason))

    by_level = Counter(f[2] for f in allf)
    by_cat = Counter(f[3] for f in allf)

    print()
    print('═══ 结果 ═══')
    print(f'  P0（必须修）: {by_level.get("P0", 0):>4}')
    print(f'  P1（需复核）: {by_level.get("P1", 0):>4}')
    print(f'  P2（提示）  : {by_level.get("P2", 0):>4}')
    print(f'  合计        : {len(allf):>4} 处 · 涉及 {len({f[1] for f in allf})} 个词')
    if by_cat:
        print()
        print('  按类别：')
        for k, v in by_cat.most_common():
            print(f'    {k:14s} {v:>4}')

    if not args.quiet:
        for lvl in ([args.level] if args.level else ['P0', 'P1', 'P2']):
            items = [f for f in allf if f[2] == lvl]
            if not items:
                continue
            print()
            print(f'═══ {lvl} 明细（{len(items)} 处）═══')
            shown = items if not args.limit else items[:args.limit]
            for wid, sp, _, cat, field, snip, reason in shown:
                print(f'  [{cat}] {sp}  ({field})')
                print(f'      {reason}')
                print(f'      「{snip}」')
            if args.limit and len(items) > args.limit:
                print(f'  … 另有 {len(items) - args.limit} 处')

    if args.json_out:
        with open(args.json_out, 'w', encoding='utf-8') as f:
            json.dump([{'word_id': w, 'spelling': s, 'level': l, 'category': c,
                        'field': fl, 'snippet': sn, 'reason': rn}
                       for w, s, l, c, fl, sn, rn in allf],
                      f, ensure_ascii=False, indent=1)
        print(f'\n已写 {args.json_out}')

    print()
    if by_level.get('P0'):
        print(f'🔴 有 {by_level["P0"]} 处 P0 违规 —— 不可上线，必须修')
        sys.exit(1)
    print('✅ 无 P0 违规')
    sys.exit(0)


if __name__ == '__main__':
    main()
