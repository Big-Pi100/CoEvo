#!/usr/bin/env python3
"""审计 `word_form` 的映射质量 —— 找出「form 映射到了错误的 base」（2026-09-29 · 白哥「确认」第 1 项）。

# 为什么需要

端侧 `analyzeForm()` 是 `WHERE form = ? LIMIT 1`，拿到 `base` 后**直接查该 base 的卡片**。
所以映射错了 = **用户划到 A 词，看到 B 词的卡片** —— 比「查不到」更糟：
> 「查不到」是*可见*的（有 LLM 兜底路径）；「查错」是*静默*的（用户不会怀疑）。

**实测样本**：`buried → buri` —— `buri` 是「贝叶棕」（B2 名词），
而 `buried` 是 `bury`（A2 动词「埋葬」）的过去式 → 用户划 `buried` 看到**贝叶棕**。

# 判据：**反推 form 的应有 base，检查当前 base 是否在其中**

对每个 form，用规则 + 不规则表**反推**它可能是哪些词的变形 → 得到候选集 `C`。
再过滤到「在 `word` 表里」的候选 `C∩库`。然后：

| 情形 | 判定 |
|---|---|
| `base ∈ C` | ✅ **映射自洽**（正常；若 `C∩库` 有 ≥2 个则另记「歧义」） |
| `base ∉ C` 且 `C∩库 ≠ ∅` | 🔴 **确凿错映射** —— 且**知道该改成谁** |
| `base ∉ C` 且 `C∩库 = ∅` | 🟠 可疑（可能是不规则形式，反推器覆盖不到） |

🔑 **为什么不用「rule × base 词性不匹配」**（试过，太粗）：实测 12,859 条不匹配，
但绝大多数是**旧规则表的垃圾**（`aaroned`/`abbeying`/`abdomened` —— 名词硬加 -ed/-ing），
不是「映射错」。反推法能自然区分：
· `buried → buri`：候选 = {`bury`}，当前 base ∉ 候选，而 `bury` 在库 → **确凿错**
· `leaves → leave`：候选 = {`leaf`, `leave`}，当前 base ∈ 候选 → **自洽**（是真歧义，不是错）
· `aaroned → aaron`：候选 = {`aaron`}，当前 base ∈ 候选 → **自洽**（垃圾，但映射没错）

# 用法

```bash
python scripts/audit_word_form_mappings.py              # 汇总
python scripts/audit_word_form_mappings.py --list       # 列出确凿错
python scripts/audit_word_form_mappings.py --json out.json
```
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fill_word_form_irregular as F  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORD_DB = os.path.join(ROOT, 'data', 'word.db')
CEFR = os.path.join(ROOT, 'backend', 'cefr_catalog.json')


# ─────────────────────────────────────────────────────────────
# 反推器：form → 它可能是哪些词的变形
# ─────────────────────────────────────────────────────────────
def build_irregular_reverse():
    """把 `IRREGULAR`（base → 形式）翻成**反表**（形式 → {base}）。"""
    rev = defaultdict(set)
    for base, cats in F.IRREGULAR.items():
        for _cat, val in cats.items():
            for form in ([val] if isinstance(val, str) else val):
                rev[form.lower()].add(base.lower())
    return rev


#: 后缀 → 还原方式（**产多个候选，宁可多不可漏** —— 反正后面要用「在库」过滤）
_SUFFIX_RULES = [
    ('ies', lambda s: s[:-3] + 'y'),        # studies → study
    ('ied', lambda s: s[:-3] + 'y'),        # buried → bury  ★ 关键
    ('ier', lambda s: s[:-3] + 'y'),
    ('iest', lambda s: s[:-3] + 'y'),
    ('ying', lambda s: s[:-4] + 'ie'),      # lying → lie
    ('ing', lambda s: s[:-3]),              # walking → walk
    ('ing', lambda s: s[:-3] + 'e'),        # making → make
    ('ing', lambda s: s[:-4]),              # running → run（去双写）
    ('ied', lambda s: s[:-2]),              # tried → tri（噪声，过滤）
    ('es', lambda s: s[:-2]),               # boxes → box
    ('es', lambda s: s[:-1]),               # leaves → leave
    ('ed', lambda s: s[:-2]),               # walked → walk
    ('ed', lambda s: s[:-1]),               # used → use
    ('ed', lambda s: s[:-3]),               # stopped → stop（去双写）
    ('d', lambda s: s[:-1]),
    ('est', lambda s: s[:-3]),
    ('er', lambda s: s[:-2]),
    ('s', lambda s: s[:-1]),                # leaves → leave ★
    ('ly', lambda s: s[:-2]),               # quickly → quick
    ('ly', lambda s: s[:-2] + 'e'),         # simply → simple
    ('ly', lambda s: s[:-3] + 'y'),         # happily → happy
    ('ness', lambda s: s[:-4]),
]


def candidates(form, irr_rev):
    """反推 `form` 可能的 base（**未过滤**，调用方用「在库」过滤）。"""
    f = form.lower()
    out = set(irr_rev.get(f, set()))
    # `-ves` → `-f` / `-fe`（leaves→leaf, knives→knife, wives→wife）
    if f.endswith('ves'):
        out.add(f[:-3] + 'f')
        out.add(f[:-3] + 'fe')
    for suf, fn in _SUFFIX_RULES:
        if f.endswith(suf) and len(f) > len(suf):
            c = fn(f)
            if len(c) >= 2:
                out.add(c)
    out.discard(f)
    return out


# 判据：**拼写反推 + 词性约束**，缺一不可
#
# 🔴 **只用拼写反推不够**（实测踩坑，2026-09-29）：
#    反推 `buried` 得到候选 {`bury`(ied→y), `buri`(去 -ed), ...} —— **`buri` 也在里面**
#    （`buri` + `ed` = `buried`，拼写上完全合法）→ 判据认为 `buried→buri` 「自洽」→ **漏报**。
#    `finer`/`hatred`/`his` 同理（反推给出 `fin`/`hat`/`hi` 这些**同在库的假候选**）。
#
# ✅ **加上词性约束就分开了**：`-ed`/`-ing` 只能加在**动词**上。
#    · `buri` 是**名词** → 不支持 `past`  ❌
#    · `bury` 是**动词** → 支持 `past`    ✅  → `bury` 胜出
#
# 于是三档：
# | 档 | 判据 | 处置 |
# |---|---|---|
# | **A 确凿错映射** | 当前 base 词性**不支持** rule，且候选中有**词性支持**的在库词 | 🔴 改 base |
# | **B 口径错/垃圾** | 当前 base 词性不支持 rule，但**没有**更好的候选 | 🟠 多为旧规则表垃圾（`aaroned→aaron`） |
# | **C 歧义** | 当前 base 支持 rule，但有 ≥2 个在库候选 | ⚠️ 需产品决策 |
#
# 🔑 出处：`buried → buri`（`buri` 是「贝叶棕」B2 名词，`buried` 是 `bury` 的过去式）
#    —— 用户划 `buried` 会看到**贝叶棕**的卡片。

#: 各 rule 对 base 词性的要求（`None` = 不约束）
RULE_POS = {
    'past': {'v'},
    'ing': {'v'},
    'ed': {'v'},
    'plural': {'n', 'v'},          # +s 既可是名词复数，也可是动词第三人称单数
    'comparative': {'adj', 'adv'},
    'superlative': {'adj', 'adv'},
    'adverb': None,                # -ly 派生，词性不定
}

_POS_ALIAS = {
    'n': 'n', 'noun': 'n', 'v': 'v', 'verb': 'v', 'vt': 'v', 'vi': 'v',
    'adj': 'adj', 'adjective': 'adj', 'adv': 'adv', 'adverb': 'adv',
    'pron': 'pron', 'pronoun': 'pron', 'prep': 'prep', 'preposition': 'prep',
    'conj': 'conj', 'conjunction': 'conj', 'num': 'num', 'numeral': 'num',
    'det': 'det', 'determiner': 'det', 'article': 'det',
    'phr': 'phr', 'phrase': 'phr', 'abbr': 'abbr',
    'int': 'int', 'interjection': 'int',
}


def norm_pos(s):
    """`[n]` / `n` / `verb` / `v./n.` → {'n'} / {'v'} …"""
    if not s:
        return set()
    out = set()
    for tok in re.split(r'[\s/,;.]+', (s or '').lower().strip('[]() ')):
        tok = tok.strip('[]()')
        if tok in _POS_ALIAS:
            out.add(_POS_ALIAS[tok])
    return out


def load_pos(con):
    """从**库内卡片**读词性（我们实际展示给用户的那个）。"""
    pos = {}
    for sp, ct in con.execute(
            'SELECT w.spelling, c.content FROM card c JOIN word w ON w.id = c.word_id'):
        try:
            d = json.loads(ct)
        except (ValueError, TypeError):
            continue
        tags = set()
        for s in d.get('sections') or []:
            if isinstance(s, dict) and s.get('type') == 'definition':
                tags |= norm_pos(s.get('pos'))
                break
        pos[sp.lower()] = tags
    return pos


def pos_supports(rule, tags):
    """该词性能否支持这条 rule（`None` = 不约束 → 恒 True）。"""
    need = RULE_POS.get(rule)
    if need is None:
        return True
    return bool(tags & need)


#: CEFR 等级 → 数字（越大越冷僻）
LEVEL_NUM = {'A1': 1, 'A2': 2, 'B1': 3, 'B2': 4, 'C1': 5, 'C2': 6}


def level_num(lv):
    """CEFR 等级 → 数字；未知返回 `None`。"""
    return LEVEL_NUM.get((lv or '').strip().upper())


# 判据：**拼写反推 + 词性约束 + 等级** —— 三条合取，缺一不可
#
# 🔴 **只用拼写反推不够**（实测踩坑之一）：反推 `buried` 得到 {`bury`(ied→y), `buri`(去 -ed)}
#    —— **`buri` 也在里面**（`buri`+`ed`=`buried`，拼写合法）→ 判据认为「自洽」→ **漏报**。
#    加了词性才分开（`-ed` 要求动词，`buri` 是名词）。
#
# 🔴 **只用「拼写 + 词性」还是不够**（实测踩坑之二）：174 条里绝大多数是**误报** ——
#    `taped→tape`（tape 明明可作动词「贴胶带」，卡片只标了 `n`）·
#    `viewed→view` · `banded→band` · `banged→bang` · `banked→bank` …
#    根因：**卡片的词性标注不全**（只标了主要义项的词性）→ 「词性不支持」判据大面积误报。
#
# ✅ **加第三条「等级」才收窄**：
#    · `buried`：当前 `buri` = **B2**（贝叶棕，专业名词）vs 候选 `bury` = **A2**（埋葬，高频）
#      → **当前 base 明显更冷僻** ✓ 判为错
#    · `viewed`：当前 `view` = **A2** vs 候选 `vie` = B2 → 当前**更常用** ✗ 不判错
#    · `taped`：当前 `tape` = B1 vs 候选 `tap` = B1 → 等级相同 ✗ 不判错
#
# 🔑 直觉：**高频词的变形更常见**。若一个「冷僻词」声称自己是某个「常见构词形」的原形，
#    多半是映射错了（真正的原形应该是那个更常见的词）。
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=WORD_DB)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--json', default='')
    args = ap.parse_args()

    con = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)
    words = {r[0].lower() for r in con.execute('SELECT spelling FROM word')}
    lv = {r[0].lower(): level_num(r[1]) for r in con.execute('SELECT spelling, cefr_level FROM word')}
    rows = con.execute('SELECT form, base, rule FROM word_form').fetchall()
    pos = load_pos(con)
    con.close()

    corpus = set()
    if os.path.exists(CEFR):
        corpus = {k.lower() for k in json.load(open(CEFR, encoding='utf-8'))}

    irr_rev = build_irregular_reverse()
    wrong, mismatch, ambiguous, weak, ok = [], [], [], [], 0
    for form, base, rule in rows:
        f, b = form.lower(), base.lower()
        cand = candidates(f, irr_rev)
        in_lib = sorted(c for c in cand if c in words)
        btags = pos.get(b, set())
        if rule is not None and btags and not pos_supports(rule, btags):
            # 当前 base 的**词性不支持**这条 rule
            better = [c for c in in_lib if pos_supports(rule, pos.get(c, set()))]
            # 第三条判据：**当前 base 的等级要比候选更冷僻**（数字更大）
            bl, ok_lv = lv.get(b), [lv.get(c) for c in better]
            colder = (bl is not None and any(x is not None and bl > x for x in ok_lv))
            rec = {'form': form, 'current': base, 'rule': rule, 'cur_pos': sorted(btags),
                   'cur_level': bl, 'should': better,
                   'should_levels': ok_lv, 'in_corpus': f in corpus}
            if better and colder:
                wrong.append(rec)
            else:
                mismatch.append({**rec, 'why_not_wrong': 'base 词性标注不全 或 等级不更冷僻'})
            continue
        if b in cand:
            ok += 1
            if len(in_lib) >= 2:
                ambiguous.append({'form': form, 'current': base, 'rule': rule,
                                  'cands': in_lib})
            continue
        # `base` 不在候选里，**但词性也说不出话** → 只记「弱可疑」，**不并入 A 档**。
        # 🔴 为什么不并入（实测 2026-09-29）：反推器**不可能穷尽**英语构词
        #    （`able→abler` 是 `+r`，`hatred` 是 `hate+red`，`his` 是 `he` 的所有格…）——
        #    第一版把这类全算 A 档 → **756 条里绝大多数是误报**。
        #    只有「**词性能说话**」时才算确凿（`buried→buri`：`-ed` 要求动词，`buri` 是名词）。
        weak.append({'form': form, 'current': base, 'rule': rule,
                     'cur_pos': sorted(btags), 'cands': in_lib,
                     'in_corpus': f in corpus})

    print('═' * 74)
    print('word_form 映射审计')
    print('═' * 74)
    print(f'  总映射              : {len(rows):,}')
    print(f'  ✅ 自洽              : {ok:,}')
    print(f'  🔴 A 确凿错映射      : {len(wrong):,}'
          f'  （base 词性不支持 + 候选中有词性支持的在库词 + **当前 base 等级更冷僻**）')
    print(f'  🟠 B 口径错/垃圾     : {len(mismatch):,}'
          f'  （base 词性不支持 rule，但无更好候选 → 多为旧规则表残留）')
    print(f'  ⚠️ C 歧义（多库内候选）: {len(ambiguous):,}'
          f'  （base 词性支持，但有 ≥2 个在库候选 → 需产品决策）')
    print(f'  · 弱可疑（base 不在候选，但词性说不出话）: {len(weak):,}'
          f'  （含反推器覆盖不到的真英语构词，**不作为确凿**）')

    if args.list:
        for title, items in (('🔴 A 确凿错映射', sorted(wrong, key=lambda x: x['form'])),
                             ('🟠 B 口径错/垃圾', sorted(mismatch, key=lambda x: x['form']))):
            print()
            print('─' * 74)
            print(f'{title}（{len(items)}）')
            print('─' * 74)
            print(f'  {"form":16s} {"现在 →":13s} {"应为":22s} 等级      词性      语料?')
            shown = items if title.startswith('🔴') else items[:50]
            for w in shown:
                lvs = '/'.join(str(x) for x in w.get('should_levels') or [])
                print(f'  {w["form"]:14s} → {w["current"]:11s} 应为 {",".join(w["should"])[:20]:20s} '
                      f'{w.get("cur_level")}/{lvs:8s} {",".join(w["cur_pos"]):8s} '
                      f'{"✓" if w["in_corpus"] else "-"}')
            if len(shown) < len(items):
                print(f'  … 其余 {len(items) - len(shown)} 条（见 --json）')

    if args.json:
        json.dump({'A_wrong': wrong, 'B_mismatch': mismatch, 'C_ambiguous': ambiguous,
                   'weak': weak},
                  open(args.json, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print(f'\n  已导出 → {args.json}')

    return 1 if wrong else 0


if __name__ == '__main__':
    sys.exit(main())
