#!/usr/bin/env python3
"""`word.db` 的 **id ↔ spelling 映射快照** —— 检查「只增不改」。

# 为什么需要它

L0（`v1-final-design-authoritative-2026-09-25.md` §3.1.1）有一条关键约束：

> **`word_id` 一旦分配，永久不变。** 预制库升级时新词追加，旧词不删不改 id。

🔴 **但实测：这个约束目前是「口头约定」，没有任何机制守护。**

| 查项 | 实测（2026-10-01）|
|---|---|
| `word.id` 形态 | `w{sort_seq:06d}` —— **id 数字 == sort_seq，11,523 条 0 例外** |
| 排序依据 | 🔴 **不是字母序**，是**录入序**（头 5 条 `absurd/achieve/alsop/agent/agree`）|
| 生成处 | `load_llm_results.py:368`（`sort_seq` 从 0 递增，按输入 json **行序**）· `incremental_clustering.py:120`（`MAX(sort_seq)+1` 追加）|

⇒ **两个脚本语义相反**：前者是**全量重建**（`os.remove(db)` → 从 1 重排），后者是增量追加。
   而 `llm-card-online-path` §11.5 说回流要「**复用 `load_llm_results.py`**」——
   🔴 **若照字面执行，每次回流都会重排全部 id**，那不只是新词，
   **连老用户的全部复习记录都会指向错的词**。

# 它守的是什么

`word_id` 是**端侧学习数据的唯一外键**（`user_word` / `card_review_state` / `review_log`
三张表都存它）。所以 id 稳定 = 用户数据有效。

| 变更 | 判定 | 后果 |
|---|---|---|
| **新增 id** | ✅ 允许 | 正常（本轮就是它）|
| **删除 id** | 🔴 **硬错** | 老用户的记录指向不存在的词 |
| **改某 id 的 spelling** | 🟠 **警告** | 端侧**冗余**了 `spelling`（`user_word` / `card_review_state`）→ 会与词库不一致；且**发版收敛**（`ext:<拼写>` → `w…`）靠拼写当桥，订正会改变收敛结果 → **须配套迁移**，不能悄悄改 |

# 用法

```bash
python scripts/word_db_id_snapshot.py --check    # 与基准比对（改库后 / CI 必跑）
python scripts/word_db_id_snapshot.py --write    # 确认无破坏性变更后，更新基准
```

退出码：0 = 无破坏性变更；1 = 有删除/改写；2 = 出错
"""

import argparse
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')
SNAPSHOT = os.path.join(ROOT, 'data', 'word_db_id_snapshot.json')


def current_map(db_path):
    """`{word_id: spelling}` —— 🔑 只取这两列：它们构成「id 稳定」这条约束的全部内容。"""
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    try:
        return {r[0]: r[1] for r in con.execute('SELECT id, spelling FROM word')}
    finally:
        con.close()


def compare(base, cur):
    """返回 `(removed, changed, added)`。三类分开 —— 它们的严重性与处置都不同。"""
    removed = sorted(set(base) - set(cur))
    added = sorted(set(cur) - set(base))
    changed = sorted(k for k in (set(base) & set(cur)) if base[k] != cur[k])
    return removed, changed, added


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=SRC_DB)
    ap.add_argument('--snapshot', default=SNAPSHOT)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f'🔴 词库不存在: {args.db}')
    cur = current_map(args.db)

    if args.write:
        payload = {
            'note': 'word.db 的 id↔spelling 映射快照 —— 守护 L0「word_id 永久不变」约束。'
                    '由 scripts/word_db_id_snapshot.py 生成；请与 word.db 一起提交。',
            'count': len(cur),
            'map': dict(sorted(cur.items())),
        }
        with open(args.snapshot, 'w', encoding='utf-8', newline='\n') as f:
            json.dump(payload, f, ensure_ascii=False, indent=1, sort_keys=False)
            f.write('\n')
        if not args.quiet:
            print(f'✅ 已写入快照 {args.snapshot}（{len(cur):,} 条）')
            print('   ⚠️ 请确认本次变更是**纯新增**（--check 已过）后再提交')
        return 0

    if not os.path.exists(args.snapshot):
        sys.exit(f'🔴 快照不存在: {args.snapshot}\n'
                 f'   → 首次使用跑一次 --write 建立基准')

    with open(args.snapshot, encoding='utf-8') as f:
        base = json.load(f)['map']

    removed, changed, added = compare(base, cur)
    ok = not removed and not changed

    if not args.quiet:
        print(f'基准 {len(base):,} 条 → 当前 {len(cur):,} 条')
        if added:
            print(f'  ✅ 新增 {len(added)} 条（允许）'
                  + (f'，例：{", ".join(added[:5])}' if len(added) <= 20 else ''))
        if removed:
            print(f'  🔴 删除 {len(removed)} 条 —— **违反「id 永久不变」**：')
            for k in removed[:10]:
                print(f'       {k} = {base[k]}')
            if len(removed) > 10:
                print(f'       …还有 {len(removed) - 10} 条')
            print('     → 老用户的 user_word / card_review_state / review_log 会指向不存在的词。')
        if changed:
            print(f'  🟠 改写 {len(changed)} 条 spelling（端侧冗余值会与词库脱节）：')
            for k in changed[:10]:
                print(f'       {k}: {base[k]!r} → {cur[k]!r}')
            if len(changed) > 10:
                print(f'       …还有 {len(changed) - 10} 条')
            print('     → 收敛靠拼写当桥，订正会改变收敛结果 → 须配套迁移，别悄悄改。')
        if ok and not added:
            print('  ✅ 无变化')
        elif ok:
            print('  ✅ 无破坏性变更（只有新增）')

    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
