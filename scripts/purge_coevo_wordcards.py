#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""清除 coevo.db 的词卡库 + K12 课程表（白哥 2026-09-28 批准）

# 删什么 / 留什么
| 组 | 表 | 处置 |
|---|---|---|
| **词卡内容** | `prebuilt_cards` + 4 张域子表（language/science/literature/humanities） | 🔴 删 |
| **K12 课程** | `prebuilt_plans` · `prebuilt_stages` · `prebuilt_tasks` · `plan_runs` · `user_plan_progress` · `k12_quiz_attempts` · `k12_quiz_bank` · `guardian_assignments` | 🔴 删 |
| **用户学习状态** | `user_cards` · `card_memory` · `review_log` · `card_relations` · `user_*_cards` | ✅ **留**（用户数据） |
| **现役业务** | `users` · `tokens` · `payment_orders` · `subscription_*` · `referral_clicks` · `user_notifications` … | ✅ 留 |

# 🔴 为什么不能直接 DROP（2026-09-28 实测教训）
后端启用 `PRAGMA foreign_keys = ON`（`db_pool.rs:29`），而
`user_cards.prebuilt_card_id` 有外键指向 `prebuilt_cards`，且 **user_cards 里有真实数据引用它**
→ **`DROP TABLE prebuilt_cards` 直接报 `FOREIGN KEY constraint failed`**（实测确认）

→ 必须先把 `user_cards` 的外键**去掉**。
   而 SQLite **不支持 `ALTER TABLE ... DROP CONSTRAINT`** → 只能**重建表**。

# 执行流程（七步）
1. `PRAGMA foreign_keys=OFF`（临时关闭，否则重建/删表都会被拦）
2. **重建 `user_cards`**：新定义去掉 `prebuilt_cards` 外键，搬运全部数据，改名回 `user_cards`
3. **按依赖倒序 DROP** 13 张表（子表先删）
4. `PRAGMA foreign_keys=ON` 恢复
5. 🔴 **`VACUUM`** —— 回收空间（见下）
6. `PRAGMA foreign_key_check` 校验无悬挂引用
7. `PRAGMA integrity_check` 校验库完整

# 🔴 第 5 步 VACUUM 为什么必做（2026-09-28 实测）
`DROP TABLE` **只把这些页标记为空闲**，文件**不会缩小**，反而可能略增：
```
backend/data/coevo.db   20.1 MB --DROP--> 21.4 MB --VACUUM--> 3.3 MB   （省 17.3 MB）
data/coevo.db           17.6 MB --DROP--> 17.6 MB --VACUUM--> 426 KB   （省 16.4 MB）
```
→ 没有 VACUUM 就交付，等于「清空了内容但文件没瘦」——**白做一半**。

用法：
    python3 scripts/purge_coevo_wordcards.py --db <path> --dry-run   # 只报告
    python3 scripts/purge_coevo_wordcards.py --db <path>             # 执行（自动备份）
    python3 scripts/purge_coevo_wordcards.py --db <path> --verify    # 只校验
"""

import argparse
import os
import shutil
import sqlite3
import sys
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── 待删清单（按依赖倒序：先删引用别人的，再删被引用的）──
DROP_ORDER = [
    # K12 课程（plan_runs 引用 prebuilt_plans；tasks 引用 stages/plans）
    'user_plan_progress',
    'k12_quiz_attempts',
    'k12_quiz_bank',
    'guardian_assignments',
    'plan_runs',
    'prebuilt_tasks',
    'prebuilt_stages',
    'prebuilt_plans',
    # 词卡内容（域子表引用 prebuilt_cards）
    'prebuilt_humanities_cards',
    'prebuilt_literature_cards',
    'prebuilt_science_cards',
    'prebuilt_language_cards',
    'prebuilt_cards',
]

# user_cards 的新定义：**去掉 `FOREIGN KEY (prebuilt_card_id) REFERENCES prebuilt_cards(id)`**
# 其余字段**逐字照抄**原定义（含 user_id 外键、默认值），避免意外改变语义。
USER_CARDS_NEW_DDL = """
CREATE TABLE user_cards__new (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    plan_run_id TEXT DEFAULT '',
    prebuilt_card_id TEXT,
    domain TEXT NOT NULL,
    front TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    task_key TEXT,
    language TEXT,
    level TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
)
"""


def hr(t):
    print()
    print('═' * 74)
    print(t)
    print('═' * 74)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', required=True)
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--verify', action='store_true', help='只校验，不改')
    ap.add_argument('--no-backup', action='store_true', help='跳过自动备份（不推荐）')
    args = ap.parse_args()

    db = os.path.abspath(args.db)
    if not os.path.exists(db):
        sys.exit(f'✗ {db} 不存在')

    con = sqlite3.connect(db)
    cur = con.cursor()

    # ── 校验模式 ──
    if args.verify:
        hr('校验')
        left = [t for t in DROP_ORDER
                if cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                               (t,)).fetchone()]
        print(f'  待删表中仍存在的: {left or "无 ✅"}')
        fk = cur.execute('PRAGMA foreign_key_check').fetchall()
        print(f'  PRAGMA foreign_key_check: {"✅ 无悬挂引用" if not fk else f"🔴 {len(fk)} 条 {fk[:3]}"}')
        print(f'  PRAGMA integrity_check  : {cur.execute("PRAGMA integrity_check").fetchone()[0]}')
        uc = cur.execute("SELECT sql FROM sqlite_master WHERE name='user_cards'").fetchone()
        if uc:
            print(f'  user_cards 是否还引用 prebuilt_cards: {"🔴 是" if "prebuilt_cards" in uc[0] else "✅ 否"}')
        con.close()
        return 0

    # ── 现状 ──
    hr('① 现状')
    present = [t for t in DROP_ORDER
               if cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                              (t,)).fetchone()]
    print(f'  待删表存在: {len(present)}/{len(DROP_ORDER)}')
    if not present:
        print('  ✅ 已全部清除（幂等，无需操作）')
        con.close()
        return 0
    for t in present:
        n = cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        print(f'    {t:<28} {n:>8,} 行')
    uc_n = cur.execute('SELECT COUNT(*) FROM user_cards').fetchone()[0] if \
        cur.execute("SELECT 1 FROM sqlite_master WHERE name='user_cards'").fetchone() else 0
    print(f'  ✅ 保留 user_cards: {uc_n:,} 行（重建时会完整搬运）')

    ddl = cur.execute("SELECT sql FROM sqlite_master WHERE name='user_cards'").fetchone()
    needs_rebuild = bool(ddl) and 'prebuilt_cards' in ddl[0]
    print(f'  user_cards 需重建（去 prebuilt_cards 外键）: {"是" if needs_rebuild else "否（已是干净定义）"}')

    if args.dry_run:
        hr('🟡 --dry-run：未做任何修改')
        print(f'  将执行：重建 user_cards（{"需要" if needs_rebuild else "跳过"}）+ DROP {len(present)} 张表')
        con.close()
        return 0

    # ── 自动备份 ──
    if not args.no_backup:
        ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        bak = f'{db}.bak-before-purge-{ts}'
        shutil.copy(db, bak)
        hr('② 备份')
        print(f'  ✅ {bak}  ({os.path.getsize(bak):,} 字节)')

    # ── 执行 ──
    hr('③ 执行')
    try:
        cur.execute('PRAGMA foreign_keys = OFF')
        print('  PRAGMA foreign_keys=OFF ✅')

        if needs_rebuild:
            cur.execute('BEGIN')
            # 取原列顺序（防止列顺序与预期不同）
            cols = [r[1] for r in cur.execute('PRAGMA table_info(user_cards)')]
            cur.execute(USER_CARDS_NEW_DDL)
            collist = ', '.join(f'"{c}"' for c in cols)
            cur.execute(f'INSERT INTO user_cards__new ({collist}) SELECT {collist} FROM user_cards')
            moved = cur.execute('SELECT COUNT(*) FROM user_cards__new').fetchone()[0]
            cur.execute('DROP TABLE user_cards')
            cur.execute('ALTER TABLE user_cards__new RENAME TO user_cards')
            cur.execute('COMMIT')
            print(f'  user_cards 重建 ✅（搬运 {moved:,} 行 · 已去掉 prebuilt_cards 外键）')

        for t in DROP_ORDER:
            got = cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                              (t,)).fetchone()
            if got:
                cur.execute(f'DROP TABLE "{t}"')
                print(f'  DROP {t} ✅')
        cur.execute('PRAGMA foreign_keys = ON')
        print('  PRAGMA foreign_keys=ON ✅')

        # 🔴 VACUUM 必做（实测教训 2026-09-28）：
        #    `DROP TABLE` 只是**把这些页标记为空闲**，文件**不会缩小**，反而可能略增
        #    （实测 backend/data/coevo.db 20.1 MB → 21.4 MB）。
        #    VACUUM 后：21.4 MB → **3.3 MB**（省 17.3 MB）· data/coevo.db 17.6 MB → **426 KB**。
        before = os.path.getsize(db)
        cur.execute('VACUUM')
        after = os.path.getsize(db)
        print(f'  VACUUM ✅（{before:,} → {after:,} 字节，省 {(before - after) / 1024 / 1024:.1f} MB）')
    except Exception as e:
        con.rollback()
        try:
            cur.execute('PRAGMA foreign_keys = ON')
        except Exception:
            pass
        sys.exit(f'🔴 执行失败（已回滚）: {type(e).__name__}: {e}')

    # ── 自检 ──
    hr('④ 自检')
    checks = []
    left = [t for t in DROP_ORDER
            if cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                           (t,)).fetchone()]
    checks.append(('全部待删表已清除', not left))
    fk = cur.execute('PRAGMA foreign_key_check').fetchall()
    checks.append(('foreign_key_check 无悬挂引用', not fk))
    checks.append(('integrity_check == ok',
                   cur.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'))
    uc_now = cur.execute('SELECT COUNT(*) FROM user_cards').fetchone()[0]
    checks.append((f'user_cards 行数不变（{uc_n} → {uc_now}）', uc_now == uc_n))
    ddl2 = cur.execute("SELECT sql FROM sqlite_master WHERE name='user_cards'").fetchone()
    checks.append(('user_cards 已不引用 prebuilt_cards',
                   bool(ddl2) and 'prebuilt_cards' not in ddl2[0]))
    ok = True
    for name, passed in checks:
        print(f'  {"✅" if passed else "🔴"} {name}')
        ok &= passed
    con.close()
    if not ok:
        sys.exit('🔴 自检未全过 —— 请用备份回滚')
    print('\n✅ 清除完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
