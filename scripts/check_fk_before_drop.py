#!/usr/bin/env python3
"""执行前关键检查：保留表 → 待删表 的外键（只读）

🔴 为什么必须查（2026-09-28）：
后端启用了 `PRAGMA foreign_keys = ON`（`db_pool.rs:29`）。
若删掉被引用的表（如 `prebuilt_cards`），而**保留表**（如 `user_cards`）还有
`FOREIGN KEY (prebuilt_card_id) REFERENCES prebuilt_cards(id)`，
那么之后对 user_cards 的 **INSERT/UPDATE 会报 `FOREIGN KEY constraint failed`**。
→ 表删了，**保留表却写不进去了** —— 这是个比"接口静默降级"更严重的后果。

本脚本用 `PRAGMA foreign_key_list` 列出**全部跨表外键**，标出「保留表 → 待删表」的那些。
"""
import os
import sqlite3

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 白哥 2026-09-28 确认：
#   删 = 词卡内容 + K12 课程；留 = 用户学习状态 + 现役业务
DROP = {
    # 词卡内容
    'prebuilt_cards', 'prebuilt_language_cards', 'prebuilt_science_cards',
    'prebuilt_literature_cards', 'prebuilt_humanities_cards',
    # K12 课程
    'prebuilt_plans', 'prebuilt_stages', 'prebuilt_tasks', 'plan_runs',
    'user_plan_progress', 'k12_quiz_attempts', 'k12_quiz_bank', 'guardian_assignments',
}

for p in ('backend/data/coevo.db', 'data/coevo.db'):
    db = os.path.join(ROOT, p)
    if not os.path.exists(db):
        print(f'✗ 缺 {p}')
        continue
    con = sqlite3.connect(db)
    cur = con.cursor()
    tables = [r[0] for r in cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    print()
    print('═' * 78)
    print(f'{p}   表数={len(tables)}')
    print('═' * 78)

    cross, danger = [], []
    for t in tables:
        try:
            fks = cur.execute(f'PRAGMA foreign_key_list("{t}")').fetchall()
        except Exception:
            continue
        for fk in fks:
            # fk = (id, seq, table, from, to, on_update, on_delete, match)
            ref = fk[2]
            if ref != t:
                cross.append((t, fk[3], ref, fk[4]))
                if t not in DROP and ref in DROP:
                    danger.append((t, fk[3], ref))
    con.close()

    print(f'跨表外键共 {len(cross)} 条')
    if danger:
        print(f'🔴 其中「保留表 → 待删表」= {len(danger)} 条 —— **必须一并去掉，否则插入会失败**：')
        for t, col, ref in danger:
            print(f'     {t}.{col}  →  {ref}')
    else:
        print('✅ 无「保留表 → 待删表」的外键')

    print()
    print('  ── 全部跨表外键（供核对）──')
    for t, col, ref, to in sorted(cross):
        tag = ''
        if t in DROP and ref in DROP:
            tag = '（两边都删 → 无影响）'
        elif t in DROP:
            tag = '（引用方也删 → 无影响）'
        elif ref in DROP:
            tag = '🔴 保留表引用了待删表'
        print(f'     {t:<28}.{col:<18} → {ref:<26}{tag}')
