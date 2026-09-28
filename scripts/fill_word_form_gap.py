#!/usr/bin/env python3
"""补 `word_form` 的真·遗漏（2026-09-28 白哥批准 · 一次性数据修补）

背景
----
2026-09-26 的差异核查（`docs/design/word-list-diff-cefr-catalog-vs-worddb-2026-09-26.md`）
查出：换用新的 `word_form` 生成方式（规则穷举 → LLM 判定）**去掉了 9,401 条噪音**，
但也**漏掉了 1,509 条真变形**，其中 **1,233 条彻底查不到**（用户划词会失败）。

本脚本用**旧 `word_form.json`** 把这 1,233 条补回来。

🔑 为什么是「补 1,233」而不是「补全部 22,606」
-----------------------------------------------
「真·查不到」共 22,606 条，但其中 **21,362 条是布朗语料的生僻长尾**
（中位语料频次 1，大量 1961 年美国小镇名如 `barnumville`）——
补进来只会**稀释词库质量**（09-26 报告 §七结论）。
而 **1,233 条恰好是「旧规则表有映射、且原形在库」的那一批** —— 是**可以救回来**的。

判据（三条交集，缺一不可）
--------------------------
1. 该 form **在 `cefr_catalog.json` 里出现过** → 排除旧表的规则误加（`abolitioning` 类）
2. **旧 `word_form.json` 有该 form → lemma 的映射** → 有可靠的还原目标
3. **lemma 已在 `word.db` 的 `word` 表** → 还原后确实能拿到卡片

🔑 判据 1 是「语料实证」：`cefr_catalog` 只收录**真实在语料中出现过**的拼写。
   它同时承担了「去噪」与「保真」两个作用 —— 这不是启发式猜测。

字段口径（对齐现有 22,829 行）
------------------------------
| 列 | 取值 |
|---|---|
| `form` | 目标词形 |
| `base` | 词元（旧表 lemma） |
| `rule` | 沿用旧表（plural/past/ing/adverb/superlative/comparative） |
| `kind` | 屈折类 → `inflection`；`adverb`（-ly 派生）→ `derivation` |
| `anchor` | = `base`（现有行全部如此） |
| `anchor_id` | `word.id` |
| `depth` | `1`（22,214 / 22,829 为 1） |
| `in_vocab` | `0`（21,545 / 22,829 为 0） |
| `action` | `'keep'`（**全表 22,829 行统一是 keep**） |

⚠️ 幂等性说明（重要）
---------------------
`word_form` 的 PRIMARY KEY 是 **`(form, base)`** —— 不是 `form`。
因此**不能**用 `INSERT OR IGNORE` 来做到幂等：
若某个 `form` 已存在但映射到**另一个** `base`，`OR IGNORE` 会**照样插入**
→ 同一 form 出现两条映射 → 查询层 `LIMIT 1` 取到哪个不确定。

→ 本脚本**显式先查 `form` 是否已存在**，存在则跳过并计数。
   重复运行第二次时，`added` 必为 0 且 `skipped_existing` = 1,233（这就是幂等的证据）。

用法
----
    python3 scripts/fill_word_form_gap.py --dry-run    # 只报告，不写库
    python3 scripts/fill_word_form_gap.py              # 实际写入
    python3 scripts/fill_word_form_gap.py --db <path>  # 指定库（用于同步副本）
"""

import argparse
import json
import os
import shutil
import sqlite3
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CEFR = os.path.join(ROOT, 'backend', 'cefr_catalog.json')
OLD_FORM = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_form.json')
DEFAULT_DB = os.path.join(ROOT, 'data', 'word.db')

# rule → kind 映射（见模块文档「字段口径」）
INFLECTION_RULES = {'plural', 'past', 'ing', 'ed', 'superlative', 'comparative'}
DERIVATION_RULES = {'adverb'}

# ═══════════════════════════════════════════════════════════════════════
# 🔴 人工处置表（2026-09-28 逐条判定）
#
# 为什么需要它：旧 `word_form.json` 是**规则穷举**产物，含少量**假映射** ——
# form 其实是独立词，却被机械地归到某个变形原型上。
# 若照单全收，用户查 `herring` 会拿到 `her` 的卡片 → **静默给错答案**
# （比「查不到走 LLM 兜底」更糟：错的答案用户不会怀疑）。
#
# 🔑 判据：**宁可少补（走 LLM 兜底），不可补错。**
#    「查不到」是*可见*的（有兜底路径）；「查错」是*静默*的。
# ═══════════════════════════════════════════════════════════════════════

# ① 跳过：正确原型不在库，或 form 本身是独立词
SKIP: dict[str, str] = {
    'herring': '独立名词「鲱鱼」，不是 her 的 -ing 形式（her 是代词）',
    'hissed': '实为 hiss 的过去式；his 是代词。hiss 不在库 → 无法正确映射',
    'hissing': '实为 hiss 的 -ing 形式；his 是代词。hiss 不在库 → 无法正确映射',
    'theses': '实为 thesis 的复数；these 是限定词。thesis 不在库 → 无法正确映射',
}

# ② 指定 base：库中有多个候选，机械取字典序首个会**选错**
BASE_OVERRIDE: dict[str, tuple[str, str]] = {
    'historically': ('historical', 'historically = historical + -ly；'
                                   '取 historic 是错的（副词对应 -al 形容词）'),
    'paying': ('pay', 'paie 非英语词；paying = pay + -ing'),
}


def hr(t):
    print()
    print('═' * 72)
    print(t)
    print('═' * 72)


def load_targets():
    """算出待补集合：返回 [(form, base, rule, kind)] 与统计信息。"""
    for p in (CEFR, OLD_FORM):
        if not os.path.exists(p):
            sys.exit(f'✗ 找不到 {p}')

    cefr = json.load(open(CEFR, encoding='utf-8'))
    cefr_l = {k.lower() for k in cefr}
    old = json.load(open(OLD_FORM, encoding='utf-8'))

    # 旧表：form → set(lemma)，用于检出「一个 form 多个 lemma」的冲突
    old_map = {}
    for r in old:
        old_map.setdefault(r['form'].lower(), set()).add(r['lemma'].lower())
    # rule 也一并留存（同一 form 可能有多个 rule，取排序后首个，保证确定性）
    old_rule = {}
    for r in old:
        f = r['form'].lower()
        old_rule.setdefault(f, set()).add(r.get('rule'))

    return cefr_l, old_map, old_rule


def connect(db):
    """连接并断言是真库（🔑 不做断言会被 sqlite3 静默建空库）。"""
    if not os.path.exists(db):
        sys.exit(f'✗ {db} 不存在（拒绝连接 —— sqlite3.connect 会静默建空库）')
    con = sqlite3.connect(db)
    n = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='word_form'")
    if n.fetchone()[0] != 1:
        sys.exit(f'✗ {db} 里没有 word_form 表 —— 可能不是真词库，中止')
    return con


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=DEFAULT_DB, help='目标库（默认 data/word.db）')
    ap.add_argument('--dry-run', action='store_true', help='只报告，不写库')
    args = ap.parse_args()

    hr('① 载入三份数据')
    cefr_l, old_map, old_rule = load_targets()
    print(f'  cefr_catalog 词形 : {len(cefr_l):>8,}')
    print(f'  旧 word_form.json : {len(old_map):>8,} 个 form')
    print(f'  目标库            : {args.db}')

    con = connect(args.db)
    cur = con.cursor()
    wd_l = {r[0].lower() for r in cur.execute('select spelling from word')}
    existing_forms = {r[0].lower() for r in cur.execute('select form from word_form')}
    print(f'  word 词元         : {len(wd_l):>8,}')
    print(f'  word_form 现有    : {len(existing_forms):>8,} 个 form')

    hr('② 三类候选（逐步收紧）')
    # 条件 1+2：catalog 里有 且 旧表有映射
    c1 = [f for f in old_map if f in cefr_l]
    print(f'  条件①② catalog 有 + 旧表有映射        : {len(c1):>7,}')
    # 加条件 3：lemma 在库
    c2 = [f for f in c1 if old_map[f] & wd_l]
    print(f'  条件①②③ 且 lemma 在库               : {len(c2):>7,}')
    # 再去掉「直查 word 就能命中」的（那些不需要映射）
    c3 = [f for f in c2 if f not in wd_l]
    print(f'  再去掉「直查即命中」                  : {len(c3):>7,}')
    # 再去掉「word_form 里已有该 form」的（幂等：已补过）
    # 🔑 同时排除 SKIP（假映射）—— 否则它们在每次重跑时都残留为「待补」，
    #    导致 `if not todo` 提前返回失效、幂等报告不准（2026-09-28 实际踩到：
    #    重跑时 todo=4（正是那 4 条 SKIP），好在 rows 为空 → 实际没写坏数据）。
    todo = [f for f in c3 if f not in existing_forms and f not in SKIP]
    print(f'  再去掉「已有该 form」+ 假映射         : {len(todo):>7,}   ← 本次待补')

    if not todo:
        hr('✅ 无需补入（幂等：已全部补过）')
        print(f'  目标 form 已在库: {len(c3)}')
        print(f'  其中排除的假映射: {sorted(f for f in c3 if f in SKIP)}')
        con.close()
        return 0

    hr('③ 冲突与异常检查')
    # 一个 form 映射到多个 lemma（歧义）
    multi = {f: old_map[f] for f in todo if len(old_map[f]) > 1}
    print(f'  ⚠️ 一个 form 映射多个 lemma : {len(multi)}')
    for f, s in list(multi.items())[:10]:
        print(f'      {f} → {sorted(s)}')
    # rule 为空/未知
    bad_rule = Counter()
    for f in todo:
        rs = {r for r in old_rule.get(f, set()) if r}
        if not rs:
            bad_rule['(rule 为空)'] += 1
        elif not (rs & (INFLECTION_RULES | DERIVATION_RULES)):
            bad_rule[f'未知 rule: {sorted(rs)}'] += 1
    print(f'  ⚠️ rule 异常              : {sum(bad_rule.values())}')
    for k, v in bad_rule.items():
        print(f'      {k}  ×{v}')
    # 库中已有同 form（无需补 —— 这些不是冲突，是被 todo 过滤掉的部分）
    already = [f for f in c3 if f in existing_forms]
    print(f'  ℹ️ 库中已有同 form（无需补）: {len(already)}')
    # 🔴 真正要警惕的：库中已有该 form，但 base 与旧表**不同**
    real_conflict = []
    for f in already:
        got = {r[0].lower() for r in cur.execute('select base from word_form where form=?', (f,))}
        if not (got & old_map[f]):
            real_conflict.append((f, sorted(got), sorted(old_map[f])))
    print(f'  🔴 库中已有同 form 但 base **不同**: {len(real_conflict)}')
    for f, got, want in real_conflict[:10]:
        print(f'      {f}: 库中={got} 旧表={want}')

    # 🔴 人工处置表覆盖检查：todo 里所有「多候选」必须已被处置
    #    （否则 `sorted(cands)[0]` 会机械选错 —— 未来数据变了也能拦住）
    unhandled = [f for f in todo
                 if f not in SKIP and f not in BASE_OVERRIDE
                 and len(old_map[f] & wd_l) > 1]
    print(f'  🔴 多候选但**未在处置表**中 : {len(unhandled)}')
    for f in unhandled[:10]:
        print(f'      {f} → {sorted(old_map[f] & wd_l)}')
    if unhandled:
        sys.exit('\n🔴 存在未处置的多候选（机械取首个会选错）—— '
                 '请逐条判定后加入 BASE_OVERRIDE 或 SKIP，不要放行')

    hr('④ 待补明细')
    # 构造待插入行
    #   · SKIP 里的 → 排除（假映射）
    #   · BASE_OVERRIDE 里的 → 用指定 base
    #   · 其余 → 唯一在库候选（由上面的检查保证）
    rows = []
    skipped, overrode = [], []
    for f in sorted(todo):
        if f in SKIP:
            skipped.append(f)
            continue
        cands = sorted(old_map[f] & wd_l)
        if f in BASE_OVERRIDE:
            base = BASE_OVERRIDE[f][0]
            if base not in cands:
                sys.exit(f'✗ BASE_OVERRIDE[{f}]={base} 不在在库候选 {cands} 里')
            overrode.append((f, base))
        else:
            if len(cands) != 1:
                sys.exit(f'✗ {f} 的候选数 {len(cands)} ≠ 1（应在③被拦下）')
            base = cands[0]
        rs = sorted({r for r in old_rule.get(f, set()) if r})
        rule = rs[0] if rs else None
        kind = 'derivation' if rule in DERIVATION_RULES else 'inflection'
        wid = cur.execute('select id from word where spelling = ?', (base,)).fetchone()
        if wid is None:
            sys.exit(f'✗ {f}: base={base} 在 word 表取不到 id')
        rows.append((f, base, rule, kind, base, wid[0], 1, 0, 'keep'))

    print(f'  排除假映射 : {len(skipped)}  → {skipped}')
    print(f'  指定 base  : {len(overrode)}  → {overrode}')
    print(f'  实际构造行数: {len(rows):,}')
    print('\n  按 rule 分布:')
    for r, n in Counter(x[2] for x in rows).most_common():
        print(f'    {str(r):<14} {n:>6,}')
    print('\n  按 kind 分布:')
    for r, n in Counter(x[3] for x in rows).most_common():
        print(f'    {r:<14} {n:>6,}')
    print('\n  样例（前 8 条）:')
    for x in rows[:8]:
        print(f'    {x}')

    if args.dry_run:
        hr('🟡 --dry-run：未写入')
        print(f'  如无异常，去掉 --dry-run 即会写入 {len(rows):,} 行')
        con.close()
        return 0

    hr('⑤ 写入')
    before = cur.execute('select count(*) from word_form').fetchone()[0]
    cur.executemany(
        'INSERT INTO word_form (form, base, rule, kind, anchor, anchor_id, depth, in_vocab, action) '
        'VALUES (?,?,?,?,?,?,?,?,?)', rows)
    con.commit()
    after = cur.execute('select count(*) from word_form').fetchone()[0]
    print(f'  word_form: {before:,} → {after:,}  (+{after - before:,})')

    hr('⑥ 写后自检')
    checks = [
        ('行数增量 == 构造行数', after - before == len(rows)),
        ('PRAGMA integrity_check == ok',
         cur.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'),
        ('无 form 映射到多个 base',
         cur.execute('select count(*) from (select form from word_form '
                     'group by form having count(distinct base) > 1)').fetchone()[0] == 0),
        ('无孤儿 anchor_id',
         cur.execute('select count(*) from word_form f where anchor_id is not null '
                     'and not exists (select 1 from word w where w.id = f.anchor_id)')
         .fetchone()[0] == 0),
    ]
    ok = True
    for name, passed in checks:
        print(f'  {"✅" if passed else "🔴"} {name}')
        ok &= passed
    con.close()
    if not ok:
        sys.exit('🔴 自检未全过 —— 请从备份回滚')
    print('\n✅ 补漏完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
