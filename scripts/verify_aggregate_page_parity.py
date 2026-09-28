#!/usr/bin/env python3
"""聚合页**跨路一致性 + 下游可读性**验收。

# 这个脚本存在的原因（一条新判据）

> 🔑 **「组件自测通过」≠「与下游能对接」**

`incremental_clustering.py` 当时**34 项验收全过**、源库指纹未改动，被规格列为「已就绪」。
但它写出的聚合页 content 格式与 `load_llm_results` **完全不同**（`{'members':[…]}` vs
`{'front':…,'sections':[…]}`）→ 端侧读不出来，**且不报错**。

**它的 34 项里，没有一项验「下游能不能读出来」。** 本脚本补的正是这一层。

# 验的三件事

| # | 断言 | 怎么验 |
|---|---|---|
| **①** | **两条路产出的 content 逐字节一致** | 取现网 1,777 个页，用 `_rebuild_page_members` 在**副本**上重建，与**现网原值**比对 |
| **②** | **下游（端侧）能读出来** | 按端侧逻辑 `aggregate_page_content.read_back()` 读，断言 `front`/`source`/`glosses` 都有值 |
| **③** | **反向：旧格式读不出来**（证明 ② 的断言真的有效） | 故意造一个旧格式 content，断言 `read_back` 读不到 `source` |

> ③ 是必须的 —— 否则 ② 可能只是「恒真」。
> （判据：「**断言要能变红**」；对照式断言最容易写成恒真。）

# 跑法

```bash
python scripts/verify_aggregate_page_parity.py           # 全量 1,777 页
python scripts/verify_aggregate_page_parity.py --limit 50
```
🔴 **在副本上跑** —— 不碰 `data/word.db`（脚本自己拷一份到临时目录）。
"""

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate_page_content as apc  # noqa: E402
import incremental_clustering as ic  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')

_passed = 0
_failed = 0


def check(label, cond, detail=''):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f'  ✅ {label}')
    else:
        _failed += 1
        print(f'  🔴 {label}' + (f'\n       {detail}' if detail else ''))


def hr(t):
    print(f'\n{"─" * 78}\n{t}\n{"─" * 78}')


def diff_kind(old_json, new_json):
    """归类差异原因 —— 便于一眼看出是「排序」「gloss」还是「结构」。"""
    try:
        o, n = json.loads(old_json), json.loads(new_json)
    except (ValueError, TypeError):
        return '解析失败'
    if not isinstance(o, dict) or not isinstance(n, dict):
        return '非对象'
    if set(o.keys()) != set(n.keys()):
        return f'顶层键不同 {sorted(o.keys())} vs {sorted(n.keys())}'
    os_, ns_ = o.get('sections'), n.get('sections')
    if not (isinstance(os_, list) and isinstance(ns_, list) and os_ and ns_):
        return 'sections 结构不同'
    if os_[0].get('type') != ns_[0].get('type'):
        return 'section.type 不同'
    if os_[0].get('source') != ns_[0].get('source'):
        so, sn = os_[0].get('source'), ns_[0].get('source')
        if isinstance(so, dict) and isinstance(sn, dict) and set(so) == set(sn):
            return 'source 值不同'
        return 'source 形状不同'
    io_, in_ = os_[0].get('items') or [], ns_[0].get('items') or []
    if len(io_) != len(in_):
        return f'items 数量不同 {len(io_)} vs {len(in_)}'
    wo = [x.get('word') for x in io_]
    wn = [x.get('word') for x in in_]
    if wo != wn:
        return 'items 顺序不同'
    go = [x.get('gloss') for x in io_]
    gn = [x.get('gloss') for x in in_]
    if go != gn:
        n_diff = sum(1 for a, b in zip(go, gn) if a != b)
        return f'items.gloss 不同（{n_diff}/{len(go)} 项）'
    return '未知差异'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0, help='只验前 N 个页（0=全部）')
    ap.add_argument('--show', type=int, default=5, help='最多打印几条差异样例')
    args = ap.parse_args()

    if not os.path.exists(SRC_DB):
        sys.exit(f'🔴 找不到 {SRC_DB}')

    tmpdir = tempfile.mkdtemp(prefix='agg_parity_')
    db = os.path.join(tmpdir, 'word.db')
    shutil.copy(SRC_DB, db)
    print(f'副本库: {db}')

    try:
        con = sqlite3.connect(db)
        cur = con.cursor()

        # ══════════════════════════════════════════════════════════
        hr('【0】前置：源库未被本脚本改动（拷贝前后指纹比对）')
        # ══════════════════════════════════════════════════════════
        import hashlib
        h_src = hashlib.md5(open(SRC_DB, 'rb').read()).hexdigest()
        check('源库 md5 已记录（跑完再核对）', len(h_src) == 32, h_src)

        # ══════════════════════════════════════════════════════════
        hr('【1】两条路产出的 content 是否逐字节一致')
        # ══════════════════════════════════════════════════════════
        # 做法：取现网每个页的**原 content**（由 load_llm_results 写），
        #      再用 incremental_clustering 的 `_rebuild_page_members` **重建**它。
        #      两者相同 ⟹ 两条路产出同一个库。
        q = ('SELECT id, page_type, group_id, etymon_id, front, content, member_count '
             'FROM aggregate_page ORDER BY id')
        pages = cur.execute(q).fetchall()
        if args.limit:
            pages = pages[:args.limit]
        print(f'页数: {len(pages)}')

        same = 0
        diffs = []            # (page_id, kind, old, new)
        for pid, ptype, gid, eid, front, content, mc in pages:
            target = gid if ptype == 'root' else eid
            if target is None:
                diffs.append((pid, '归属 id 为空', content, ''))
                continue
            ic._rebuild_page_members(con, pid, target, ptype)
            new = cur.execute('SELECT content FROM aggregate_page WHERE id=?',
                              (pid,)).fetchone()[0]
            if new == content:
                same += 1
            else:
                diffs.append((pid, diff_kind(content, new), content, new))

        check(f'全部 {len(pages)} 页重建后与现网**逐字节一致**',
              not diffs,
              f'一致 {same} / {len(pages)}，差异 {len(diffs)} 条')

        if diffs:
            kinds = Counter(k for _, k, _, _ in diffs)
            print('       差异归类：')
            for k, n in kinds.most_common():
                print(f'         {k:<34} {n:>5}')
            print(f'       样例（前 {args.show} 条）：')
            for pid, k, o, n in diffs[:args.show]:
                print(f'         #{pid} [{k}]')
                print(f'           现网: {o[:150]}')
                print(f'           重建: {n[:150]}')

        # ══════════════════════════════════════════════════════════
        hr('【2】下游（端侧）能读出来吗 —— 按端侧逻辑逐页读取')
        # ══════════════════════════════════════════════════════════
        no_front = no_source = no_gloss = ok = 0
        bad_samples = []
        for pid, ptype, gid, eid, front, content, mc in pages:
            f, source, glosses = apc.read_back(content)
            if not f:
                no_front += 1
                bad_samples.append((pid, 'front 读不到'))
                continue
            if source is None:
                no_source += 1
                bad_samples.append((pid, 'source 读不到（页头大字/语种会空）'))
                continue
            # glosses 允许为空（有些成员卡里没 definition 段）—— 但**整体全空**要报
            if mc > 0 and not glosses:
                no_gloss += 1
                bad_samples.append((pid, f'{mc} 个成员但一条 gloss 都读不到'))
                continue
            ok += 1

        check('每页的 `front` 都读得到', no_front == 0, f'{no_front} 页读不到')
        check('每页的 `source` 都读得到（页头大字/语种/含义）', no_source == 0,
              f'{no_source} 页读不到')
        check('每页的 `items[].gloss` 至少读到一条（成员行释义）', no_gloss == 0,
              f'{no_gloss} 页全空')
        print(f'       完整可读: {ok} / {len(pages)}')
        for pid, why in bad_samples[:args.show]:
            print(f'         #{pid}: {why}')

        # ══════════════════════════════════════════════════════════
        hr('【3】反向测试：旧格式（`{"members":…}`）应当**读不出来**')
        # ══════════════════════════════════════════════════════════
        # 🔑 必须做 —— 否则【2】可能只是「恒真」（判据：断言要能变红）
        legacy = json.dumps({'members': [{'word': 'x', 'word_id': 'w1', 'gloss': '测'}]},
                            ensure_ascii=False)
        f2, s2, g2 = apc.read_back(legacy)
        check('🔴 旧格式的 `source` **读不到**（证明【2】的断言真的有效）', s2 is None)
        check('🔴 旧格式的 `items[].gloss` **读不到**', not g2)
        check('旧格式仍能读到 `front`（= 空串，不崩）', f2 == '')

        # 再看「新格式但 source 缺失」也应能被识别为读不到
        half = json.dumps({'front': 'x', 'sections': [{'type': 'cognate_list',
                                                       'items': [{'word': 'a',
                                                                  'word_id': 'w1',
                                                                  'gloss': 'z'}]}]},
                          ensure_ascii=False)
        _, s3, g3 = apc.read_back(half)
        check('🟠 有 items 但无 source → source 读不到（兜底重算的触发条件）', s3 is None)
        check('🟠 但 items[].gloss 仍读得到（成员行不受影响）', bool(g3))

        # ══════════════════════════════════════════════════════════
        hr('【4】`aggregate_page_word.ord` 是否与 content.items 同序')
        # ══════════════════════════════════════════════════════════
        # 现网 ord 实测是**字母序**（load 用排序后的 items 枚举）→ 两条路都要跟它。
        mis = 0
        for pid, _, _, _, _, content, _ in pages:
            try:
                d = json.loads(content)
                items = (d.get('sections') or [{}])[0].get('items') or []
            except (ValueError, TypeError):
                continue
            if len(items) < 2:
                continue
            from_items = [x.get('word_id') for x in items]
            from_ord = [r[0] for r in cur.execute(
                'SELECT word_id FROM aggregate_page_word WHERE page_id=? ORDER BY ord',
                (pid,)).fetchall()]
            if from_items != from_ord:
                mis += 1
        check('每页的 `ord` 顺序 == `content.items` 顺序（同为字母序）', mis == 0,
              f'{mis} 页不一致')

        con.close()

        # ══════════════════════════════════════════════════════════
        hr('【5】源库未被改动')
        # ══════════════════════════════════════════════════════════
        h_src2 = hashlib.md5(open(SRC_DB, 'rb').read()).hexdigest()
        check('源库 md5 未变（本脚本只在副本上改）', h_src == h_src2)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    hr('汇总')
    print(f'  通过 {_passed} 项，失败 {_failed} 项')
    if _failed:
        print('  🔴 有失败项')
    sys.exit(0 if _failed == 0 else 1)


if __name__ == '__main__':
    main()
