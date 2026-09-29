#!/usr/bin/env python3
"""把 `data/word.db`（源）同步到 `app/assets/word.db`（**打包进 App 的副本**）并校验一致。

# 为什么需要这个脚本

`word.db` 有**两份**：

| | 路径 | 角色 |
|---|---|---|
| 源 | `data/word.db` | 所有脚本改它 |
| 副本 | `app/assets/word.db` | **打包进 App，用户实际读的那份** |

历史上每次改源都会同步副本（`git log` 里 `d419fce`·`ccefb6a`·`b495718`·`7e88b84` 都是成对提交）
—— 但**有一轮漏了**（2026-09-29 发现）：那轮修的 68 条卡片**用户在 App 里看不到**。

🔑 **判据：「改了源数据」≠「交付物已更新」。**
   一份数据若有「源 + 副本」，改完源必须问：**「现在还有谁拿着它的旧拷贝？」**

# 🔴 校验不能用「比行数」

第一版只比了每表的 `COUNT(*)` → 只发现 `word_form` 差，
而 **`card` 表行数完全相同、内容却不同** → **漏判**。
✅ 正解：比 **`card.content_hash` 的集合**（能精确定位到「哪几条变了」）。

# 用法

```bash
python scripts/sync_word_db_asset.py --check    # 只比对（CI / 提交前用）
python scripts/sync_word_db_asset.py            # 同步 + 校验
python scripts/sync_word_db_asset.py --check --quiet   # 一致则静默（退出码 0）
```
退出码：0 = 一致（或同步成功）；1 = 不一致（`--check`）；2 = 出错
"""

import argparse
import hashlib
import os
import shutil
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'data', 'word.db')
DST = os.path.join(ROOT, 'app', 'assets', 'word.db')

#: 需要逐内容比对的表（比 `content_hash` 列 —— 行数相同也可能内容不同）
HASH_TABLES = ('card', 'aggregate_page')


def connect_ro(p):
    return sqlite3.connect(f'file:{p}?mode=ro', uri=True)


def snapshot(path):
    """取一份可比对快照：表集合 · 行数 · 内容 hash 集合 · integrity。"""
    if not os.path.exists(path):
        return None
    con = connect_ro(path)
    tables = sorted(r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
    counts = {}
    for t in tables:
        counts[t] = con.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
    hashes = {}
    for t in HASH_TABLES:
        if t in tables:
            col = 'content_hash' if t == 'card' else 'content'
            try:
                hashes[t] = {(r[0], hashlib.md5((r[1] or '').encode()).hexdigest())
                             for r in con.execute(f'SELECT rowid, {col} FROM "{t}"')}
            except sqlite3.OperationalError:
                pass
    integrity = con.execute('PRAGMA integrity_check').fetchone()[0]
    con.close()
    return {'tables': tables, 'counts': counts, 'hashes': hashes, 'integrity': integrity}


def diff(a, b):
    """返回 `(问题列表, 明细)`。"""
    problems = []
    if set(a['tables']) != set(b['tables']):
        problems.append(f'表集合不同: 源独有 {set(a["tables"]) - set(b["tables"])} · '
                        f'副本独有 {set(b["tables"]) - set(a["tables"])}')
    for t in sorted(set(a['counts']) & set(b['counts'])):
        if a['counts'][t] != b['counts'][t]:
            problems.append(f'{t}: 行数 {a["counts"][t]} → {b["counts"][t]}')
    detail = {}
    for t in sorted(set(a['hashes']) & set(b['hashes'])):
        d = a['hashes'][t] ^ b['hashes'][t]
        if d:
            problems.append(f'{t}: **{len(d)} 行的内容不同**（行数相同也查得出）')
            detail[t] = len(d)
    for name, s in (('源', a), ('副本', b)):
        if s['integrity'] != 'ok':
            problems.append(f'{name} integrity_check = {s["integrity"]}')
    return problems, detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='只比对，不改动')
    ap.add_argument('--quiet', action='store_true', help='一致时不打印')
    ap.add_argument('--src', default=SRC)
    ap.add_argument('--dst', default=DST)
    args = ap.parse_args()

    if not os.path.exists(args.src):
        sys.exit(f'🔴 源库不存在: {args.src}')
    if not os.path.exists(args.dst):
        print(f'⚠️ 副本不存在（首次同步）: {args.dst}')

    a = snapshot(args.src)
    b = snapshot(args.dst)
    if b is None:
        problems = ['副本不存在']
        detail = {}
    else:
        problems, detail = diff(a, b)

    if not problems:
        if not args.quiet:
            print(f'✅ 两份库一致（{len(a["counts"])} 表 · card '
                  f'{a["counts"].get("card", 0):,} · word_form {a["counts"].get("word_form", 0):,}）')
        return 0

    if not args.check:
        if not args.quiet:
            print(f'🔄 差异 {len(problems)} 项 → 从源同步到副本')
            for p in problems:
                print(f'   · {p}')
        shutil.copy2(args.src, args.dst)
        # 同步后必须**读回校验**
        b2 = snapshot(args.dst)
        probs2, _ = diff(a, b2)
        if probs2:
            print('🔴 同步后仍不一致:')
            for p in probs2:
                print(f'   · {p}')
            return 2
        print(f'✅ 已同步并校验一致: {args.dst}')
        return 0

    print(f'🔴 不一致（{len(problems)} 项）—— 副本落后于源。跑一次不带 --check 即可同步：')
    for p in problems:
        print(f'   · {p}')
    if detail:
        print('   提示：`--check` 只报数；具体是哪几条可对比 `card.content_hash` 集合。')
    return 1


if __name__ == '__main__':
    sys.exit(main())
