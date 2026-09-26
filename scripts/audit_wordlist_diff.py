#!/usr/bin/env python3
"""cefr_catalog.json（旧后端词表）vs word.db（新端侧词库）差异核查

回答的问题
----------
1. 两份表差在哪？（41,574 vs 11,523）
2. 「少了的那 3 万个」是什么？
3. 其中有**真正查不到**的词吗？（= 用户划词会失败的词）

为什么要用 cefr_catalog 当"真实性"过滤器
----------------------------------------
`cefr_catalog.json` 的关键性质：**它是从语料（Brown Corpus + CEFR-J）抽出的
表面词形清单** —— 只收录**实际在语料中出现过**的拼写。

因此它天然是一个判据：若某个形式出现在该表里，说明**真实英语中用过它**；
若某条旧 `word_form` 映射（规则生成）对应的形式不在该表里，
说明那是**规则误加的假形式**（如 `abolitioning` / `absolutelying`）。

用法
----
    python3 scripts/audit_wordlist_diff.py
"""

import json
import os
import sqlite3
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CEFR = os.path.join(ROOT, 'backend', 'cefr_catalog.json')
WORDDB = os.path.join(ROOT, 'data', 'word.db')
OLD_FORM = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_form.json')


def hr(t):
    print()
    print('═' * 72)
    print(t)
    print('═' * 72)


def main():
    if not os.path.exists(WORDDB):
        sys.exit(f'找不到 {WORDDB}（本脚本需要真词库）')

    cefr = json.load(open(CEFR, encoding='utf-8'))
    cefr_l = {k.lower(): v for k, v in cefr.items()}
    con = sqlite3.connect(WORDDB)
    wd = {r[0] for r in con.execute('select spelling from word')}
    wd_l = {s.lower() for s in wd}
    new_forms = {r[0].lower() for r in con.execute('select form from word_form')}

    # ─────────────────────────────────────────────────────────
    hr('① 集合规模')
    print(f'  cefr_catalog.json（旧后端词表）: {len(cefr):>8,}   ← 表面词形')
    print(f'  word.db.word      （新端侧词库）: {len(wd):>8,}   ← 词元 lemma')
    print(f'  word.db.word_form （词形映射）  : {len(new_forms):>8,}')

    both = {k for k in cefr_l if k in wd_l}
    only_cefr = {k for k in cefr_l if k not in wd_l}
    only_wd = wd_l - set(cefr_l)
    print()
    print(f'  交集（两边都有）        : {len(both):>8,}')
    print(f'  只在旧表（word.db 没有）: {len(only_cefr):>8,}')
    print(f'  只在新库（旧表没有）    : {len(only_wd):>8,}')

    # ─────────────────────────────────────────────────────────
    hr('② 「只在旧表」的构成 —— 是丢失还是归一？')
    inf = [w for w in only_cefr if w in new_forms]
    miss = [w for w in only_cefr if w not in new_forms]
    print(f'  ① 变形已被归一（在 word_form 里有映射）: {len(inf):>8,}  {100*len(inf)/len(only_cefr):5.1f}%')
    print('       → ✅ 不算丢失：查它会被还原到原形，例：'
          + ', '.join(f'{w}→{con.execute("select base from word_form where lower(form)=?", (w,)).fetchone()[0]}'
                      for w in ['is', 'was', 'said', 'men', 'years'] if w in new_forms))
    print(f'  ② 无映射 → 需进一步判断             : {len(miss):>8,}  {100*len(miss)/len(only_cefr):5.1f}%')

    # 用「旧映射表」判断这些词原本挂在哪
    oldmap = {}
    if os.path.exists(OLD_FORM):
        for e in json.load(open(OLD_FORM, encoding='utf-8')):
            oldmap.setdefault(e['form'].lower(), e)

    has_old = [w for w in miss if w in oldmap]
    no_old = [w for w in miss if w not in oldmap]
    print(f'      · 旧映射表里有（原为某词元的变形）: {len(has_old):>8,}')
    print(f'      · 旧映射表里也没有（词元本身不在库）: {len(no_old):>8,}')

    # ─────────────────────────────────────────────────────────
    hr('③ 🔴 关键：word_form 映射缺口（旧表有、新表无、且原形在新库里）')
    if oldmap:
        new_wf = new_forms
        cand = {f: e for f, e in oldmap.items()
                if f not in new_wf and e['lemma'].lower() in wd_l}
        real = {f: e for f, e in cand.items() if f in cefr_l}      # 语料出现过
        ghost = {f: e for f, e in cand.items() if f not in cefr_l}  # 规则误加
        print(f'  旧有新无 且 原形在 word.db        : {len(cand):>8,}')
        print(f'    ├─ ✅ 语料从未出现 → 规则误加（新表**正确**排除）: {len(ghost):>8,}  {100*len(ghost)/len(cand):5.1f}%')
        print(f'    └─ 🟠 语料出现过   → **真·遗漏**            : {len(real):>8,}  {100*len(real)/len(cand):5.1f}%')
        print()
        print('  规则误加样例（新表正确地没收）：')
        print('    ' + ', '.join(sorted(ghost)[:12]))

        own = {f: e for f, e in real.items() if f in wd_l}     # 本身已独立成条
        gap = {f: e for f, e in real.items() if f not in wd_l}  # 真查不到
        print()
        print(f'  真·遗漏 {len(real):,} 再分：')
        print(f'    ├─ ✅ 本身已独立收录（直查可命中）: {len(own):>8,}  {100*len(own)/len(real):5.1f}%')
        print(f'    └─ 🔴 **真·查不到**（词元无 + 映射无）: {len(gap):>8,}  {100*len(gap)/len(real):5.1f}%')

        hr('④ 🔴 真·查不到：按类型与频次')
        byrule = Counter(e['rule'] for e in gap.values())
        for k, n in byrule.most_common():
            print(f'  {k:16s} {n:>7,}')
        bfs = sorted(((cefr_l[f].get('brown_freq') or 0), f, e['lemma'], e['rule'])
                     for f, e in gap.items())
        print()
        for th in (1, 5, 20, 50, 100):
            print(f'  语料频次 >= {th:>3}: {sum(1 for x in bfs if x[0] >= th):>6,}')
        print()
        print('  语料频次最高的 30 个（最该补）：')
        for freq, f, lem, rule in sorted(bfs, reverse=True)[:30]:
            print(f'    {f:20s} → {lem:16s} {rule:12s} freq={freq}')

    # ─────────────────────────────────────────────────────────
    hr('⑤ 「只在新库」的是什么（旧表没有）')
    ex = sorted(only_wd)
    print(f'  共 {len(ex):,} 个，样例：')
    print('    ' + ', '.join(ex[:36]))

    hr('⑥ 结论')
    print('  · 两份表**不是同一份的大小版本**，而是**不同抽象层级**：')
    print('      旧表 = 表面词形（语料抽词，未归一）')
    print('      新库 = 词元（已归一 + 清洗 + LLM 补内容）')
    print('  · 「少了 3 万」中大部分是**归一**与**未达收录标准**，不是丢失：')
    print('      变形 → 进 word_form；语料生僻词/专名/古语 → 未收录')
    print('  · 旧表反而含大量**规则误加的假形式**（新表正确排除）')
    print('  · 🔴 但新表有**真·遗漏**：见 ④ —— 这些词用户划词会失败')


if __name__ == '__main__':
    main()
