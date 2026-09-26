#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 #6 拼写变体映射 + #5 词族聚合候选清单

#6 拼写变体（英美拼写差异）
---------------------------
`aluminium`/`aluminum`、`colour`/`color`、`centre`/`center` ——
用户划到英式拼写时，应能查到词表里的美式条目（或反之）。

做法：对词表里每个词按**规则生成英美变体**，若变体也在词表 → 建映射。
**零 LLM 成本**，纯规则。

#5 词族聚合候选（**需白哥做语义判断**）
---------------------------------------
词表有「屈折重复立卡」：`running` 既是独立卡片，又是 `run` 的屈折形。
`word_form` 已用 `in_vocab` 标记出 **1,384 条**这类 form。

要定的是：**哪些屈折形该保留独立卡片**？
  · `building`（n. 建筑物）← 有独立语义 → **保留**
  · `running`（run 的 -ing）← 纯屈折 → **合并到 run**

本脚本**自动预分组**（不是自动决策）：
  · 组 A「明确纯屈折」——释义里自称 `plural of X` / `past tense of X` 等 → 建议合并
  · 组 B「明确有独立义」——pos 与 lemma 不同且释义无屈折自述 → 建议保留
  · 组 C「灰区」——**交白哥判断**

用法
----
    python3 scripts/build_variants_and_families.py
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
WORD_FORM = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_form.json')
OUT_VARIANT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'spelling_variant.json')
OUT_FAMILY = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_family_candidates.json')

CJK = re.compile(r'[\u4e00-\u9fff]')

# ── #6 英美拼写变体规则（英式→美式，双向推导）─────────────
VARIANT_RULES: list[tuple[str, str, str]] = [
    # (说明, 正则, 替换)  —— 生成「另一个变体」
    # ⚠️ 规则都要求**前面有足够长的词干** —— 否则会把基础词误连：
    #    `-our` 规则无约束时 → `four`↔`for`、`our`↔`or`（完全无关）
    #    `-ae-` 规则无约束时 → `mae`↔`me`
    ('-our ↔ -or',         r'(?<=[a-z]{2})our\b',    'or'),
    ('-re ↔ -er',          r'(?<=[a-z]{3})tre\b',    'ter'),
    ('-ise ↔ -ize',        r'(?<=[a-z]{2})ise\b',    'ize'),
    ('-isation ↔ -ization', r'(?<=[a-z]{3})isation\b', 'ization'),
    ('-yse ↔ -yze',        r'(?<=[a-z]{2})yse\b',    'yze'),
    ('-ogue ↔ -og',        r'(?<=[a-z]{3})ogue\b',   'og'),
    ('-ll- ↔ -l-',         r'([aeiou])ll(ed|ing|er|ers)\b', r'\1l\2'),
    ('-ae- ↔ -e-',         r'(?<=[a-z]{3})ae',       'e'),
    # ⚠️ 不设通用 `-oe-→-e-` 规则 —— 实测会把 `boeing` 连到 `being`（波音≠being）
]
# 显式成对表（规则覆盖不到的高频差异）
EXPLICIT_PAIRS: list[tuple[str, str]] = [
    ('aluminium', 'aluminum'), ('grey', 'gray'), ('metre', 'meter'),
    ('litre', 'liter'), ('theatre', 'theater'), ('centre', 'center'),
    ('defence', 'defense'), ('licence', 'license'), ('practise', 'practice'),
    ('cheque', 'check'), ('programme', 'program'), ('catalogue', 'catalog'),
    ('dialogue', 'dialog'), ('jewellery', 'jewelry'), ('plough', 'plow'),
    ('mould', 'mold'), ('smoulder', 'smolder'), ('sulphur', 'sulfur'),
    ('tyre', 'tire'), ('kerb', 'curb'), ('draught', 'draft'),
    ('storey', 'story'), ('moustache', 'mustache'), ('aeroplane', 'airplane'),
    ('kilometre', 'kilometer'), ('behaviour', 'behavior'), ('favour', 'favor'),
    ('honour', 'honor'), ('labour', 'labor'), ('neighbour', 'neighbor'),
    ('rumour', 'rumor'), ('splendour', 'splendor'), ('humour', 'humor'),
    ('vapour', 'vapor'), ('vigour', 'vigor'), ('armour', 'armor'),
    # `-oe-` 类只能逐个列（通用规则会误伤）
    ('oestrogen', 'estrogen'), ('foetus', 'fetus'), ('diarrhoea', 'diarrhea'),
    ('oedema', 'edema'), ('manoeuvre', 'maneuver'), ('oesophagus', 'esophagus'),
]


def load_data():
    con = sqlite3.connect(DB)
    rows = list(con.execute("""
        SELECT c.id, c.front, l.pos, l.definitions
        FROM prebuilt_cards c JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))
    con.close()
    vocab = {r[1].lower(): {'id': r[0], 'word': r[1], 'pos': r[2], 'defs': r[3]}
             for r in rows if r[1]}
    return vocab


def build_variants(vocab: dict) -> list[dict]:
    """生成英美拼写变体映射。"""
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()

    def add(a: str, b: str, how: str):
        al, bl = a.lower(), b.lower()
        if al not in vocab or bl not in vocab or al == bl:
            return
        key = tuple(sorted((al, bl)))
        if key in seen:
            return
        seen.add(key)
        out.append({'form': a, 'lemma': b, 'rule': 'spelling_variant',
                    'variant_of': b, 'how': how})

    # 显式对（双向）
    for a, b in EXPLICIT_PAIRS:
        add(a, b, 'explicit')
        add(b, a, 'explicit')

    # 规则推导（双向）
    for w in vocab:
        for desc, pat, rep in VARIANT_RULES:
            for cand in (re.sub(pat, rep, w),):
                if cand != w:
                    add(w, cand, desc)
                    add(cand, w, desc)
    return out


def build_family_candidates(vocab: dict) -> dict:
    """用 word_form 的 in_vocab 标记，产出 #5 候选并预分组。"""
    if not os.path.exists(WORD_FORM):
        return {'_meta': {'error': 'word_form.json 不存在，请先跑 build_word_form.py'}}

    with open(WORD_FORM, encoding='utf-8') as f:
        rows = json.load(f)

    # 只看 in_vocab=1（form 在词表里另有独立卡片）且 form ≠ lemma
    pairs = [r for r in rows
             if r.get('in_vocab') and r['form'].lower() != r['lemma'].lower()]

    # 释义自称屈折（`plural of X` / `past tense of X` …）
    INFLECT_SELF = re.compile(
        r"(?:plural|past tense|past participle|present participle|comparative|"
        r"superlative|third person|form of|-ing form)\b", re.I)

    groups = {'A_纯屈折_建议合并': [], 'B_有独立义_建议保留': [], 'C_灰区_待白哥判断': []}
    for r in pairs:
        form, lemma = r['form'], r['lemma']
        fv, lv = vocab.get(form.lower()), vocab.get(lemma.lower())
        if not fv or not lv:
            continue
        fdef = _flat(fv['defs'])
        rec = {
            'form': form, 'lemma': lemma, 'rule': r['rule'],
            'form_pos': fv['pos'], 'lemma_pos': lv['pos'],
            'form_def': fdef[:150], 'lemma_def': _flat(lv['defs'])[:150],
        }
        fpos = (fv['pos'] or '').lower()
        lpos = (lv['pos'] or '').lower()

        # 判据：**不是「pos 不同」就有独立义** ——
        #   `abandoned`(adj) ← `abandon`(v) 只是过去分词作形容词
        #   `abnormally`(adv) ← `abnormal`(adj) 只是派生副词
        PURE_INFLECT_POS = re.compile(
            r'plural|participle|past tense|present tense|third person|'
            r'\b(past|present|gerund)\b', re.I)
        DERIVED_ADV = (fpos == 'adverb' and lpos.startswith('adjective'))
        # 词性大类（用于判断是否真的换了类别）
        def cls(p):
            for k in ('noun', 'verb', 'adjective', 'adverb'):
                if k in p:
                    return k
            return p.strip()

        if INFLECT_SELF.search(fdef) or PURE_INFLECT_POS.search(fpos) or DERIVED_ADV:
            groups['A_纯屈折_建议合并'].append(rec)
        elif cls(fpos) != cls(lpos) and fdef and cls(fpos):
            # 真换了词性大类（如 building n. ← build v.）→ 很可能有独立义
            groups['B_有独立义_建议保留'].append(rec)
        else:
            groups['C_灰区_待白哥判断'].append(rec)

    return {'_meta': {
        'total_in_vocab_pairs': len(pairs),
        'A': len(groups['A_纯屈折_建议合并']),
        'B': len(groups['B_有独立义_建议保留']),
        'C': len(groups['C_灰区_待白哥判断']),
        'note': '这是**候选清单不是决策**；组 C 需人工语义判断',
    }, **groups}


def _flat(defs: str | None) -> str:
    if not defs:
        return ''
    try:
        items = json.loads(defs)
    except Exception:
        return defs
    if not isinstance(items, list):
        return str(items)
    return ' '.join(str(it.get('meaning', '')) for it in items
                    if isinstance(it, dict))


def main():
    vocab = load_data()
    print(f'词表: {len(vocab):,} 条')

    variants = build_variants(vocab)
    print(f'\n{"="*76}\n#6 拼写变体映射\n{"="*76}')
    print(f'  生成 {len(variants)} 条')
    by_how = defaultdict(int)
    for v in variants:
        by_how[v['how']] += 1
    for k, n in sorted(by_how.items(), key=lambda t: -t[1]):
        print(f'    {k:<24}{n:>5}')
    print(f'\n  样例:')
    for v in sorted(variants, key=lambda x: x['form'])[:14]:
        print(f"    {v['form']:<16} ↔ {v['lemma']:<16} ({v['how']})")
    with open(OUT_VARIANT, 'w', encoding='utf-8') as f:
        json.dump({'_meta': {'count': len(variants)}, 'variants': variants},
                  f, ensure_ascii=False, indent=2)

    fam = build_family_candidates(vocab)
    print(f'\n{"="*76}\n#5 词族聚合候选（⚠️ 需你判断）\n{"="*76}')
    meta = fam['_meta']
    print(f"  in_vocab 配对数: {meta.get('total_in_vocab_pairs', 0)}")
    print(f"    A 纯屈折（建议合并）: {meta.get('A', 0)}")
    print(f"    B 有独立义（建议保留）: {meta.get('B', 0)}")
    print(f"    C 灰区（待你判断）    : {meta.get('C', 0)}")

    print(f'\n  ── 组 A 样例（释义自称屈折 → 建议合并）──')
    for r in fam['A_纯屈折_建议合并'][:10]:
        print(f"    {r['form']:<15} ← {r['lemma']:<13} [{r['rule']}] {r['form_def'][:52]}")
    print(f'\n  ── 组 B 样例（pos 不同 → 建议保留独立卡）──')
    for r in fam['B_有独立义_建议保留'][:10]:
        print(f"    {r['form']:<15} ← {r['lemma']:<13} {r['form_pos']} vs {r['lemma_pos']}")
    print(f'\n  ── 组 C 样例（灰区，最需要你定）──')
    for r in fam['C_灰区_待白哥判断'][:12]:
        print(f"    {r['form']:<15} ← {r['lemma']:<13} {r['form_def'][:56]}")

    with open(OUT_FAMILY, 'w', encoding='utf-8') as f:
        json.dump(fam, f, ensure_ascii=False, indent=2)

    print(f'\n✅ {os.path.relpath(OUT_VARIANT, ROOT)}')
    print(f'✅ {os.path.relpath(OUT_FAMILY, ROOT)}')


if __name__ == '__main__':
    main()
