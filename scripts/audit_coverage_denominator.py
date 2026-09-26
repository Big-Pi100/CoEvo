#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
词库覆盖率口径核查 —— 回答「分母到底是多少 / 各口径覆盖率 / 数字之间能不能相减」。

起因（2026-09-26）：文档里 `etymology` 11,406 与 `context` 11,493 并排，
读者相减得 87 —— 但这两个数**分母不同、口径不同**，相减无意义。
本脚本把所有口径**各自的分母写清楚**，并把真实差额逐条列出。

用法：python3 scripts/audit_coverage_denominator.py
"""
import json
import os
import sqlite3
import sys
from collections import Counter

DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'data', 'word.db')
FULLRUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                       'data', 'curriculum', 'prebuilt', 'fullrun', 'results.jsonl')
INTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                     'data', 'curriculum', 'prebuilt', 'intermediate', 'results.jsonl')


def main() -> int:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    one = lambda s, *a: con.execute(s, a).fetchone()[0]

    total = one('select count(*) from word')
    print('=' * 68)
    print(f'【唯一分母】word 表 = card 表 = {total} 条')
    print('=' * 68)
    print()
    print('entry_type 分布（分母可以再细分，但不应混用）：')
    for r in con.execute('select entry_type, count(*) n from word group by entry_type order by n desc'):
        print(f'  {r["entry_type"] or "(null)":14s} {r["n"]:6d}   {100*r["n"]/total:6.2f}%')
    print()

    # ---------- 各口径 ----------
    print('=' * 68)
    print('各素材口径的覆盖（**每个数都写清分母**）')
    print('=' * 68)

    any_morph = {r[0] for r in con.execute("select distinct word_id from word_morpheme")}
    decomp = {r[0] for r in con.execute("select distinct word_id from word_morpheme where type='root'")}
    has_ety_text = {r[0] for r in con.execute(
        "select id from word where etymology_text is not null and trim(etymology_text)<>''")}
    has_etyma = {r[0] for r in con.execute("select distinct word_id from word_etymon")}
    has_ety_any = has_ety_text | has_etyma
    has_colloc = {r[0] for r in con.execute("select distinct word_id from word_collocation")}
    cog3 = {r[0] for r in con.execute(
        "select distinct m.word_id from cognate_group_member m join cognate_group g on g.id=m.group_id where g.size>=3")}
    root_page = {r[0] for r in con.execute(
        "select distinct p.word_id from aggregate_page_word p join aggregate_page a on a.id=p.page_id where a.page_type='root'")}
    ety_page = {r[0] for r in con.execute(
        "select distinct p.word_id from aggregate_page_word p join aggregate_page a on a.id=p.page_id where a.page_type='etymon'")}

    # 例句（任一条 sense 带 example）
    has_example = set()
    empty_secs = 0
    rows = con.execute('select word_id, content from card').fetchall()
    for r in rows:
        d = json.loads(r['content'])
        secs = d.get('sections') or []
        if not secs:
            empty_secs += 1
        if any(s.get('type') == 'sense' and (s.get('example') or '').strip() for s in secs):
            has_example.add(r['word_id'])

    table = [
        ('root 有任意词素记录（✅ 判据用这个）', any_morph),
        ('root 仅 type=\'root\'（🔴 漏 36 个希腊语词素）', decomp),
        ('cognate 族≥3', cog3),
        ('collocation 有记录', has_colloc),
        ('etymology：有 etymology_text', has_ety_text),
        ('etymology：有 etyma 记录（word_etymon）', has_etyma),
        ('etymology：任一素材（text ∪ etyma）✅ 判据用这个', has_ety_any),
        ('context 有例句', has_example),
    ]
    print(f'{"口径":44s} {"命中":>6s} / {"分母":>6s}   {"覆盖率":>7s}')
    print('-' * 68)
    for name, s in table:
        print(f'{name:44s} {len(s):6d} / {total:6d}   {100*len(s)/total:6.2f}%')
    print()
    n_word = one("select count(*) from word where entry_type='word'")
    n_word_ety = one("select count(*) from word where entry_type='word'"
                     " and etymology_text is not null and trim(etymology_text)<>''")
    print(f'  （细分：仅 entry_type=word 的分母 = {n_word}，该口径下 etymology_text 覆盖 '
          f'{n_word_ety}/{n_word} = {100*n_word_ety/n_word:.2f}%）')
    print(f'  空 sections 的 card：{empty_secs} 条')
    print()
    print('聚合页入口口径（门槛 ≥3，见文档 §3.5）：')
    print(f'  ① 词根词缀可点击（有 root 型页） : {len(root_page):6d} / {total}  = {100*len(root_page)/total:.2f}%')
    print(f'  ② 词源故事可点击（有 etymon 型页）: {len(ety_page):6d} / {total}  = {100*len(ety_page)/total:.2f}%')
    print()

    # ---------- 差额清单 ----------
    print('=' * 68)
    print('差额逐条（**两个不同口径的数不能相减**）')
    print('=' * 68)

    def dump(title, s):
        names = sorted(con.execute('select spelling from word where id=?', (x,)).fetchone()[0] for x in s)
        print(f'\n▸ {title}：{len(names)} 条')
        for i in range(0, len(names), 8):
            print('    ' + '  '.join(f'{w:20s}' for w in names[i:i + 8]))

    no_ety = {r[0] for r in con.execute(
        "select id from word where etymology_text is null or trim(etymology_text)=''")}
    no_ex = {r['word_id'] for r in rows if r['word_id'] not in has_example}
    print(f'\n对比：无词源 {len(no_ety)} 条  vs  无例句 {len(no_ex)} 条 —— **不同集合，勿相减**')
    print('  文档里的「87」= 11,493(有例句) - 11,406(有词源) → **假差**')
    print(f'  真实差额：{total} - {len(has_ety_text)} = **{total - len(has_ety_text)}**（无词源的词）')
    print(f'            {total} - {len(has_example)} = **{total - len(has_example)}**（无例句的词）')

    dump(f'无 etymology_text（{len(no_ety)} 条）', no_ety)
    print()
    print('  entry_type 分布：')
    for r in con.execute(
            "select entry_type, count(*) n from word where etymology_text is null or trim(etymology_text)=''"
            " group by entry_type order by n desc"):
        print(f'    {r["entry_type"] or "(null)":14s} {r["n"]:4d}')
    only_affix = {r[0] for r in con.execute(
        "select word_id from word_morpheme group by word_id having sum(type='root')=0")}
    nd = no_ety - decomp
    print(f'\n  不可拆且无词源（= 文档里的「116 词」口径）= {len(nd)} 条')
    print(f'  可拆但仍无词源 = {len(no_ety & decomp)} 条 → '
          f'{sorted(con.execute("select spelling from word where id=?", (x,)).fetchone()[0] for x in no_ety & decomp)}')
    print(f'  有 etyma 记录但 text 为空 = {len(no_ety & has_etyma)} 条 → '
          f'{sorted(con.execute("select spelling from word where id=?", (x,)).fetchone()[0] for x in no_ety & has_etyma)}'
          f'  ← 🔴 `etymology_text` 单字段判据漏了它')
    print(f'  （对照：仅词缀无 root 的词 = {len(only_affix)} 条，'
          f'如 biology=bio-+-logy / oxygen=oxy-+-gen —— **LLM 把希腊语词素标成了 prefix 而非 root**）')

    dump(f'无例句（{len(no_ex)} 条）', no_ex)

    # ---------- 与 116 词的关系 ----------
    print()
    print('=' * 68)
    print('与「116 词（记忆法全不可用）」的关系')
    print('=' * 68)
    print(f'  116 词口径 = 不可拆 AND 无 etymology_text')
    print(f'  117 词口径 = 无 etymology_text（不要求不可拆）')
    print(f'  差集 = {len(no_ety - (no_ety - decomp))} 条 → '
          f'{sorted(con.execute("select spelling from word where id=?", (x,)).fetchone()[0] for x in (no_ety - (no_ety - decomp)))}')
    print(f'  → 116 是 117 的子集，多出的那 1 个是「可拆但 LLM 没给词源」')

    # ---------- LLM 对这 117 词的 primary 判定 ----------
    print()
    print('=' * 68)
    print('LLM 对这 117 词的 mnemonic.primary 判定（说明「取最优」而非「按序第一个」）')
    print('=' * 68)
    sp2id = {r['spelling']: r['id'] for r in con.execute('select id, spelling from word')}
    targets = {con.execute('select spelling from word where id=?', (x,)).fetchone()[0] for x in no_ety}
    found = {}
    for p in (FULLRUN, INTER):
        if not os.path.exists(p):
            continue
        with open(p, encoding='utf-8') as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get('word') in targets and rec['word'] not in found:
                    found[rec['word']] = rec
    cnt = Counter(((r.get('data') or {}).get('mnemonic') or {}).get('primary') for r in found.values())
    for k, v in cnt.most_common():
        print(f'  {k:14s} {v:4d}')
    print(f'  （仅统计在 LLM 结果里找到的 {len(found)} 条）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
