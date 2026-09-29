#!/usr/bin/env python3
"""修 `word_form` 里「词形配到了同形的另一个词」的错误映射（2026-09-29 · 白哥批准）。

# 背景

端侧 `analyzeForm()` 拿 `base` 后**直接查该 base 的卡片** —— 所以映射错了
= 用户划 A 词看到 B 词的卡片（**比「查不到」更糟：静默给错答案**）。

**两类来源**：
1. 机器审计（`audit_word_form_mappings.py`）筛出 48 条候选
2. **LLM 复核**（契约 v6 的 `derived_from` 字段）→ 只有 **7 条**确认

🔑 **48 → 7 说明机械判据误报 79%**（38 条 LLM 判定「现状是对的」：
`amped→amp` · `bearded→beard` · `seeded→seed` · `singled→single` · `jointed→joint` …
这些 base **本身就能作动词**，只是卡片只标了主要词性 `n`）。

**共同的病根**：`form` 被配到了**同形的另一个词**（不是「配到了错的原形」）——

| form | 现状（错） | 应为 | 病根 |
|---|---|---|---|
| `breathed`/`breathing` | `breath` n B1 | **`breathe` v A1** | `breath` 是 `breathe` 的同形近亲 |
| `buried` | `buri` n B2 | **`bury` v A2** | 「贝叶棕」vs「埋葬」 |
| `passed`/`passing` | `pas` n C1 | **`pass` v A2** | — |
| `pasted`/`pasting` | `past` adj B1 | **`paste` v A2** | — |

7/7 都是「**A1/A2 的高频动词，被配成了更冷僻的同形词**」——
同 `S3a/S3b` 的音标污染、以及 §17 的卡片字段污染是**同一类病**。

# 为什么必须改三列

`anchor == base` 是常态（23,525/24,140）· `anchor_id → base 的 word.id`。
只改 `base` 会让这三者**互相矛盾**（且 `incremental_clustering.remove_word()`
靠 `anchor_id` 联动删行 → 指错会**误删别的词的映射**）。

# 用法

```bash
python scripts/fix_word_form_mapping.py --dry-run     # 只报告
python scripts/fix_word_form_mapping.py               # 写入（含备份）
python scripts/fix_word_form_mapping.py --db <副本>    # 演练
```
"""

import argparse
import os
import shutil
import sqlite3
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORD_DB = os.path.join(ROOT, 'data', 'word.db')
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')

# ══════════════════════════════════════════════════════════════════════
# 人工核对 + LLM 复核确认的修正表（**只有这 7 行**，不做批量推断）
#
# 每行的证据：LLM 契约 v6 的 `derived_from` 字段（信度见 conf）
#   —— `derived_from` 正是「这个词形从哪个词来」，规则 2 明文举例 `ran → run`
#
# 🔴 **为什么不写「批量规则」**：48 条里 38 条是误报（base 本身就能作动词）。
#    能可靠分开这 7 条的，只有**语义判断**（LLM），不是机械规则。
# ══════════════════════════════════════════════════════════════════════
FIXES = [
    # (form, 现状 base, 应为 base, rule, LLM 信度)
    ('breathed', 'breath', 'breathe', 'past', 0.95),
    ('breathing', 'breath', 'breathe', 'ing', 0.95),
    ('buried',    'buri',   'bury',    'past', 0.95),
    ('passed',    'pas',    'pass',    'past', 0.95),
    ('passing',   'pas',    'pass',    'ing',  0.90),
    ('pasted',    'past',   'paste',   'past', 0.95),
    ('pasting',   'past',   'paste',   'ing',  0.90),
]

#: 改 `base` 时必须一起改的列（保持 `anchor == base` · `anchor_id → base 的 word.id` 不变式）
CASCADE = ('anchor', 'anchor_id')


def connect_checked(path):
    """连库 + 三断言（防「`sqlite3.connect()` 静默建空库」把路径错伪装成表不存在）。"""
    assert os.path.exists(path), f'🔴 文件不存在: {path}'
    assert os.path.getsize(path) > 1_000_000, f'🔴 文件太小，不像 word.db: {os.path.getsize(path)}'
    con = sqlite3.connect(path)
    con.execute('PRAGMA foreign_keys=ON')
    n = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='word'").fetchone()[0]
    assert n == 1, '🔴 连到的不是 word.db（没有 word 表）'
    return con


def plan_fixes(con):
    """算出哪些行真需要改（幂等：已改过的会被跳过）。"""
    todo, skip, bad = [], [], []
    for form, old, new, rule, conf in FIXES:
        rows = con.execute(
            'SELECT rowid, base, rule, anchor, anchor_id FROM word_form WHERE form = ?',
            (form,)).fetchall()
        if not rows:
            bad.append((form, '该 form 不在 word_form 表里'))
            continue
        cur = rows[0]
        if len(rows) > 1:
            bad.append((form, f'该 form 有 {len(rows)} 行（预期 1）—— 拒绝改'))
            continue
        if cur[1].lower() == new:
            skip.append((form, old, new, rule, conf))          # 已经改过 → 幂等
            continue
        if cur[1].lower() != old:
            bad.append((form, f'现状 base={cur[1]!r}，与我记录的 {old!r} 不符 —— 拒绝改'))
            continue
        if cur[2] != rule:
            bad.append((form, f'rule={cur[2]!r}，与我记录的 {rule!r} 不符 —— 拒绝改'))
            continue
        tgt = con.execute('SELECT id FROM word WHERE spelling = ? COLLATE NOCASE', (new,)).fetchone()
        if not tgt:
            bad.append((form, f'目标 base {new!r} 不在 word 表 —— 拒绝改（还原后会查到空气）'))
            continue
        clash = con.execute('SELECT 1 FROM word_form WHERE form = ? AND base = ?', (form, new)).fetchone()
        if clash:
            bad.append((form, f'({form},{new}) 已存在 → 改 base 会撞主键 —— 拒绝改'))
            continue
        todo.append((form, old, new, rule, conf, cur[0], tgt[0]))
    return todo, skip, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=WORD_DB)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--no-backup', action='store_true')
    args = ap.parse_args()

    con = connect_checked(args.db)
    todo, skip, bad = plan_fixes(con)

    print('═' * 78)
    print('word_form 映射修正（`form` 被配到了同形的另一个词）')
    print('═' * 78)
    print(f'  修正表     : {len(FIXES)} 行')
    print(f'  ⏭️ 已是目标值（幂等跳过）: {len(skip)}')
    print(f'  ➕ 待改     : {len(todo)}')
    print(f'  🔴 拒绝改   : {len(bad)}')
    for f, why in bad:
        print(f'       {f}: {why}')

    if todo:
        print()
        print('  %-12s %-11s → %-10s %-6s %s' % ('form', '现状 base', '应为', 'rule', 'LLM信度'))
        for form, old, new, rule, conf, _rid, _wid in todo:
            print('    %-10s %-11s → %-10s %-6s %.2f' % (form, old, new, rule, conf))

    if bad:
        con.close()
        sys.exit('🔴 有拒绝改的项 —— 先查明（不写任何东西）')

    if not todo:
        con.close()
        print('\n（无待改项 → 幂等通过）')
        return 0

    if args.dry_run:
        con.close()
        print('\n（dry-run：没有写。去掉 --dry-run 才写入）')
        return 0

    # ── 备份 ──
    if args.no_backup:
        print('\n⚠️ --no-backup：跳过备份（不推荐）')
    else:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        bak = os.path.join(BACKUP_DIR, f'word.db.bak-wfmapping-{time.strftime("%Y%m%d-%H%M%S")}')
        shutil.copy2(args.db, bak)
        assert os.path.exists(bak) and os.path.getsize(bak) > 1_000_000
        print(f'\n✅ 备份: {bak}')

    n = 0
    with con:                                     # 事务：要么全成要么全回滚
        for form, old, new, rule, conf, rid, wid in todo:
            before = con.execute(
                'SELECT rule, kind, depth, in_vocab, action FROM word_form WHERE rowid = ?',
                (rid,)).fetchone()
            con.execute(
                'UPDATE word_form SET base = ?, anchor = ?, anchor_id = ? WHERE rowid = ?',
                (new, new, wid, rid))
            # 读回断言
            got = con.execute(
                'SELECT base, anchor, anchor_id, rule, kind, depth, in_vocab, action '
                'FROM word_form WHERE rowid = ?', (rid,)).fetchone()
            assert got[0].lower() == new and got[1].lower() == new and got[2] == wid, \
                f'🔴 {form} 读回不符: {got}'
            # 🔑 断言「非目标列逐字段未变」
            assert got[3:] == before, f'🔴 {form} 的其它列变了: {before} → {got[3:]}'
            n += 1
    con.close()

    # ── 终检：锚点完整性 ──
    #
    # 🔑 **统一不变式：`anchor_id` 指向 `anchor` 所指的词条**（源库 24,140/24,140 全满足）。
    #
    # 🔴 第一版断言写错了（演练时暴露）：我假设「所有行 `anchor == base`」，
    #    但实际有 **615 行 `anchor == form`**（链式形态：`acclaimed` 的 anchor 是 `acclaimed`
    #    自己，而 base 是 `acclaim`）→ 断言误报 615 条「不对齐」。
    #    → 正解：**按 `anchor` 校验，不按 `base`**。
    con = connect_checked(args.db)
    orphan = con.execute(
        'SELECT COUNT(*) FROM word_form f LEFT JOIN word w ON w.id = f.anchor_id '
        'WHERE w.id IS NULL').fetchone()[0]
    misaligned = con.execute(
        'SELECT COUNT(*) FROM word_form f JOIN word w ON w.id = f.anchor_id '
        'WHERE lower(w.spelling) <> lower(f.anchor)').fetchone()[0]
    tot = con.execute('SELECT COUNT(*) FROM word_form').fetchone()[0]
    integ = con.execute('PRAGMA integrity_check').fetchone()[0]
    con.close()
    if orphan or misaligned or integ != 'ok':
        print(f'🔴 终检失败: orphan={orphan} misaligned={misaligned} integrity={integ}')
        return 1
    print(f'✅ 改了 {n} 行 · word_form 共 {tot:,} 行 · '
          f'anchor_id 全部对齐 anchor（统一不变式）· integrity ok')
    print('   ⚠️ 交付物同步：跑 `python scripts/sync_word_db_asset.py`')
    return 0


if __name__ == '__main__':
    sys.exit(main())
