#!/usr/bin/env python3
"""刷新聚合页 content 里的**成员释义**（`items[].gloss`）。

# 为什么需要

`aggregate_page.content` 的 `items[].gloss` 是**成员词自己的卡**里的
`definition.zh`（见 `aggregate_page_content.zh_from_card_content`）。
所以只要改了某个词的 `definition`，**引用它的聚合页就过时了**。

实测（2026-09-29）：写库改了 `a` 的释义（`愉快```的，幸福的` → `一个，某个`）→
etymon 页 733 的成员行仍写着旧释义。

# 🔑 做法与约束

① **用共享产出模块重建**（`aggregate_page_content`）—— 不自己拼 json，
   否则就是又造一个分叉（content 格式/排序口径必须唯一）。
② **只重建 `items`**：`front`（页标题）与 `sections[0].source`（页头）从**现有 content 原样搬**，
   它们由 root/etymon 表决定，与本次变更无关。
③ **断言「除 gloss 外逐字节未变」** —— 防止刷新顺手改坏别的东西。

# 用法

```bash
python scripts/refresh_aggregate_pages.py --words a            # 只刷受影响页（dry-run）
python scripts/refresh_aggregate_pages.py --words a --apply
python scripts/refresh_aggregate_pages.py --all                # 全量核对（1,777 页，只报差异）
```
"""

import argparse
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate_page_content as A  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORD_DB = os.path.join(ROOT, 'data', 'word.db')


def affected_pages(con, words):
    if not words:
        return [r[0] for r in con.execute('SELECT id FROM aggregate_page ORDER BY id')]
    out = set()
    for w in words:
        rows = con.execute(
            'SELECT apw.page_id FROM aggregate_page_word apw JOIN word w ON w.id = apw.word_id '
            'WHERE w.spelling = ? COLLATE NOCASE', (w,)).fetchall()
        if not rows:
            print(f'  ⚠️ `{w}` 不在任何聚合页里（可能是单字功能词，正常）')
        out |= {r[0] for r in rows}
    return sorted(out)


def rebuild(con, page_id):
    """按共享口径重建该页 content；返回 `(旧串, 新串, front, source, items)`。"""
    old = con.execute('SELECT content FROM aggregate_page WHERE id=?', (page_id,)).fetchone()
    if not old:
        raise RuntimeError(f'🔴 聚合页 {page_id} 不存在')
    old = old[0]
    od = json.loads(old)
    osec = (od.get('sections') or [{}])[0]
    items = []
    rows = con.execute(
        'SELECT w.id, w.spelling, c.content FROM aggregate_page_word apw '
        'JOIN word w ON w.id = apw.word_id LEFT JOIN card c ON c.word_id = w.id '
        'WHERE apw.page_id = ?', (page_id,)).fetchall()
    if not rows:
        raise RuntimeError(f'🔴 聚合页 {page_id} 没有成员（拒绝重建出空页）')
    for wid, sp, ct in rows:
        items.append(A.make_item(sp, wid, A.zh_from_card_content(ct)))
    new = A.dump_content(od.get('front'), osec.get('source'), items)
    return old, new, od.get('front'), osec.get('source'), items


def gloss_diff_only(old, new):
    """断言：新旧内容**只在 gloss 上不同**（front/source/成员集合/顺序/键顺序都一致）。"""
    a, b = json.loads(old), json.loads(new)
    if a.get('front') != b.get('front'):
        return 'front 变了'
    sa, sb = (a.get('sections') or [{}])[0], (b.get('sections') or [{}])[0]
    if sa.get('source') != sb.get('source'):
        return 'source 变了'
    if sa.get('type') != sb.get('type'):
        return 'section type 变了'
    ia, ib = sa.get('items') or [], sb.get('items') or []
    if len(ia) != len(ib):
        return f'成员数变了 {len(ia)} → {len(ib)}'
    for x, y in zip(ia, ib):
        for k in ('word', 'word_id'):
            if x.get(k) != y.get(k):
                return f'成员 {k} 变了: {x.get(k)!r} → {y.get(k)!r}'
        if set(x) != set(y):
            return f'成员键集合变了: {set(x)} → {set(y)}'
    return ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--words', default='', help='受影响词（逗号分隔）')
    ap.add_argument('--all', action='store_true', help='全量核对 1,777 页')
    ap.add_argument('--apply', action='store_true')
    args = ap.parse_args()
    if not args.words and not args.all:
        sys.exit('🔴 给 `--words a,b` 或 `--all`')

    words = [x.strip() for x in args.words.split(',') if x.strip()]
    con = sqlite3.connect(WORD_DB)
    con.execute('PRAGMA foreign_keys=ON')
    pids = affected_pages(con, None if args.all else words)
    print(f'待核对聚合页: {len(pids)}（{"全量" if args.all else "受 " + ",".join(words) + " 影响"}）')

    changed, bad = [], []
    for pid in pids:
        old, new, front, _src, _items = rebuild(con, pid)
        if old == new:
            continue
        why = gloss_diff_only(old, new)
        if why:
            bad.append((pid, why))
        else:
            changed.append((pid, front, old, new))

    for pid, why in bad:
        print(f'  🔴 页 {pid} 差异超出 gloss：{why}（**不自动改**）')
    print(f'\n需要刷新: {len(changed)} 页 · 异常: {len(bad)} 页')
    for pid, front, old, new in changed[:20]:
        print(f'  页 {pid} 「{front}」')
        oi = {i['word']: i['gloss'] for i in json.loads(old)['sections'][0]['items']}
        ni = {i['word']: i['gloss'] for i in json.loads(new)['sections'][0]['items']}
        for k in oi:
            if oi[k] != ni[k]:
                print(f'      {k}: {oi[k]!r} → {ni[k]!r}')

    if not args.apply:
        con.close()
        print('\n（dry-run：没有写。加 --apply 才写入）')
        return 0
    if bad:
        con.close()
        sys.exit('🔴 有异常页 —— 先查明再写')

    with con:
        for pid, front, _o, new in changed:
            con.execute('UPDATE aggregate_page SET content=? WHERE id=?', (new, pid))
    # 读回断言
    fails = []
    for pid, front, _o, new in changed:
        got = con.execute('SELECT content FROM aggregate_page WHERE id=?', (pid,)).fetchone()[0]
        if got != new:
            fails.append(pid)
        f, s, g = A.read_back(got)
        if not f or s is None or not g or any(not v for v in g.values()):
            fails.append(pid)
    con.close()
    if fails:
        print(f'🔴 读回断言失败: {sorted(set(fails))}')
        return 1
    print(f'✅ 已刷新 {len(changed)} 页，且下游可读（read_back 全过）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
