#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""清除 coevo.db 的「旧学习链」残余表（白哥 2026-09-29 批准）

# 背景
2026-09-29 完成了第一轮清除（词卡内容 5 表 + K12 课程 8 表）。
本轮是**阶段一**：清除「旧学习链」剩下的 14 张表 ——
这些表背后是**后端一整套已退役的旧模块**（`card_engine` crate · `growth_engine` crate ·
`achievement_engine` · `plan_handler` · `review_handler` · `ws.rs` · `curriculum_admin` 等）。

# 清什么 / 留什么
| 组 | 表 | 处置 | 理由 |
|---|---|---|---|
| **AI 对话** | `conversations` · `conversation_turns` · `defer_queue` | 🔴 删 | 只被 `chat_client` 用，而 chat **无 UI 入口** |
| **旧学习状态** | `user_cards` · `card_memory` · `review_log` · `card_relations` | 🔴 删 | 学习状态**已整体迁端侧**（`user.db`） |
| **域子表** | `user_{language,science,literature,humanities}_cards` | 🔴 删 | 同上（死链） |
| **调试** | `debug_logs` · `debug_trackers` | 🔴 删 | 只服务 admin 调试面板 |
| **成就** | `achievements` | 🔴 删 | 成就方向定「**甲：端侧算**」→ 后端这份退役 |
| **现役业务** | `users` · `tokens` · `payment_orders` · `subscription_*` · `referral_clicks` · `distribution_*` · `user_notifications` · `marketing_campaigns` … | ✅ **留** | app 现役调用 |

# 🔑 与上一轮的关键差异（2026-09-29 实测）
上一轮不能直接 DROP（`user_cards` 有数据引用 `prebuilt_cards`，SQLite 报外键错），必须重建表。
**本轮实测：没有任何「保留表 → 待删表」的外键** → ✅ **可直接按依赖倒序 DROP，无需重建任何表**。
（待删表之间的外键只需按倒序删：子表先删。）

# 执行流程（六步）
1. `PRAGMA foreign_keys = OFF`
2. **按依赖倒序 DROP** 14 张表
3. `PRAGMA foreign_keys = ON`
4. 🔴 **`VACUUM`**（`DROP TABLE` 只标记页为空闲，**文件不会缩小**，反而可能略增）
5. `PRAGMA foreign_key_check` 校验无悬挂引用
6. `PRAGMA integrity_check` 校验库完整

用法：
    python3 scripts/purge_coevo_legacy_chain.py --db <path> --dry-run   # 只报告
    python3 scripts/purge_coevo_legacy_chain.py --db <path>             # 执行（自动备份）
    python3 scripts/purge_coevo_legacy_chain.py --db <path> --verify    # 只校验
"""

import argparse
import datetime
import os
import shutil
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── 待删清单（按依赖倒序：引用别人的先删）──
DROP_ORDER = [
    # AI 对话（conversation_turns 引用 conversations）
    'conversation_turns',
    'conversations',
    'defer_queue',
    # 旧学习状态（以下 4 张域子表 + card_memory/review_log 都引用 user_cards）
    'user_language_cards',
    'user_science_cards',
    'user_literature_cards',
    'user_humanities_cards',
    'card_memory',
    'review_log',
    'card_relations',
    'user_cards',
    # 成就（方向已定「端侧算」）
    'achievements',
    # 调试
    'debug_logs',
    'debug_trackers',
]

# 保留表（用于「行数不变」自检）—— 现役业务表
KEEP_CHECK = [
    'users', 'tokens', 'payment_orders', 'subscription_plans', 'subscription_requests',
    'user_notifications', 'user_preferences', 'referral_clicks', 'marketing_campaigns',
    'distribution_commissions', 'admin_users', 'app_config',
]


def hr(t):
    print()
    print('═' * 74)
    print(t)
    print('═' * 74)


def table_exists(cur, t):
    return cur.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (t,)).fetchone() is not None


def snapshot(cur, tabs):
    out = {}
    for t in tabs:
        if table_exists(cur, t):
            out[t] = cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
    return out


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
        left = [t for t in DROP_ORDER if table_exists(cur, t)]
        print(f'  待删表中仍存在的: {left or "无 ✅"}')
        fk = cur.execute('PRAGMA foreign_key_check').fetchall()
        print(f'  foreign_key_check: {"✅ 无悬挂引用" if not fk else f"🔴 {len(fk)} 条"}')
        print(f'  integrity_check  : {cur.execute("PRAGMA integrity_check").fetchone()[0]}')
        con.close()
        return 0

    # ── 现状 ──
    hr('① 现状')
    present = [t for t in DROP_ORDER if table_exists(cur, t)]
    print(f'  待删表存在: {len(present)}/{len(DROP_ORDER)}')
    if not present:
        print('  ✅ 已全部清除（幂等，无需操作）')
        con.close()
        return 0
    total_rows = 0
    for t in present:
        n = cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        total_rows += n
        print(f'    {t:<26} {n:>8,} 行')
    print(f'  {"合计":<26} {total_rows:>8,} 行')

    # 🔴 删除前风险检查：保留表是否引用待删表
    hr('② 删除前风险检查')
    all_tabs = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    risks = []
    for t in all_tabs:
        if t in DROP_ORDER:
            continue
        for fk in cur.execute(f'PRAGMA foreign_key_list("{t}")'):
            if fk[2] in DROP_ORDER:
                risks.append((t, fk[3], fk[2]))
    if risks:
        for t, col, ref in risks:
            print(f'  🔴 保留表 {t}.{col} → 待删表 {ref}.id')
        sys.exit('  🔴 存在「保留表 → 待删表」外键 —— 直接 DROP 会失败，需先重建该保留表')
    print('  ✅ 无「保留表 → 待删表」外键 → 可直接按倒序 DROP')
    fk_off = '（PRAGMA foreign_keys 当前为 OFF，本脚本执行时临时关闭）'
    print(f'  {fk_off}')

    keep_before = snapshot(cur, KEEP_CHECK)
    print(f'  保留表基线: {sum(keep_before.values()):,} 行（{len(keep_before)} 张）')

    if args.dry_run:
        hr('🟡 --dry-run：未做任何修改')
        print(f'  将 DROP {len(present)} 张表，共 {total_rows:,} 行')
        con.close()
        return 0

    # ── 自动备份 ──
    if not args.no_backup:
        ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        bak = f'{db}.bak-before-legacy-purge-{ts}'
        shutil.copy(db, bak)
        hr('③ 备份')
        print(f'  ✅ {bak}  ({os.path.getsize(bak):,} 字节)')

    # ── 执行 ──
    hr('④ 执行')
    try:
        cur.execute('PRAGMA foreign_keys = OFF')
        print('  PRAGMA foreign_keys=OFF ✅')
        dropped = []
        for t in DROP_ORDER:
            if table_exists(cur, t):
                cur.execute(f'DROP TABLE "{t}"')
                dropped.append(t)
                print(f'  DROP {t} ✅')
        con.commit()
        cur.execute('PRAGMA foreign_keys = ON')
        print('  PRAGMA foreign_keys=ON ✅')

        # 🔴 VACUUM 必做：DROP TABLE 只标记页为空闲，文件不会缩小（上一轮实测 20.1→21.4 MB）
        size_before_vacuum = os.path.getsize(db)
        cur.execute('VACUUM')
        print('  VACUUM ✅')
        # ⚠️ 此处**不能** os.path.getsize —— 连接未关闭时读到的是旧值，
        #    实测会误报「省 0.0 MB」（而真实是 3.3 MB → 614 KB）。真实大小在 con.close() 后测。
    except Exception as e:
        con.rollback()
        try:
            cur.execute('PRAGMA foreign_keys = ON')
        except Exception:
            pass
        sys.exit(f'🔴 执行失败（已回滚）: {type(e).__name__}: {e}')

    # ── 自检 ──
    hr('⑤ 自检')
    checks = []
    left = [t for t in DROP_ORDER if table_exists(cur, t)]
    checks.append((f'全部待删表已清除（{len(dropped)} 张）', not left))
    fk = cur.execute('PRAGMA foreign_key_check').fetchall()
    checks.append(('foreign_key_check 无悬挂引用', not fk))
    checks.append(('integrity_check == ok',
                   cur.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'))
    keep_after = snapshot(cur, KEEP_CHECK)
    same = keep_before == keep_after
    checks.append((f'保留表行数不变（{sum(keep_before.values()):,}）', same))
    # 保留表必须仍存在
    missing = [t for t in KEEP_CHECK if not table_exists(cur, t)]
    checks.append(('保留表全部健在', not missing))

    ok = True
    for name, passed in checks:
        print(f'  {"✅" if passed else "🔴"} {name}')
        ok &= passed
    if not same:
        print(f'     基线 {keep_before}')
        print(f'     现在 {keep_after}')

    con.close()
    # 🔑 VACUUM 的真实效果只能在**连接关闭后**测量（见上方注释）
    size_after = os.path.getsize(db)
    saved = (size_before_vacuum - size_after) / 1024 / 1024
    print(f'  ✅ VACUUM 回收: {size_before_vacuum:,} → {size_after:,} 字节（省 {saved:.1f} MB）')

    if not ok:
        sys.exit('🔴 自检未全过 —— 请用备份回滚')
    print('\n✅ 清除完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
