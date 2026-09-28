#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证：用**当前 schema.rs** 在**全新空库**上初始化后，待删表**不会出现**

# 为什么必须验（2026-09-28 起）
「删表」只是治标 —— 后端 `init_database` 会在**新建库**时执行建表语句。
若 `schema.rs` 里还留着待删表的 `CREATE TABLE IF NOT EXISTS`，
那么**全新部署时那些空表会被重新建出来**（白做）。
🔑 判据：**「删掉数据」与「让它不再产生」是两件事**。

✅ 2026-09-29 续：本轮又退役了「旧学习链」14 张表
（`conversations`/`conversation_turns`/`defer_queue`/`user_cards`/`card_memory`/`review_log`/
 `card_relations`/`user_*_cards`×4/`debug_logs`/`debug_trackers`/`achievements`），
本脚本的清单已合并两轮共 **25 张**。

本脚本**直接提取** `schema.rs` 里的 SQL 常量（与 Rust 侧同源，不另抄一份），
在**内存库**上按 `init_database` 的顺序执行，然后检查表清单。
→ 因此它能抓到「注释里的中文/符号破坏 SQL」这类问题（比只读代码强）。

⚠️ 它**不替代** `cargo check`（Rust 语法层面）——
   两者互补：`cargo check` 管 Rust 能不能编译，本脚本管 **SQL 执行后表对不对**。

用法：
    python3 scripts/verify_schema_no_wordcards.py                      # 验后端那份
    python3 scripts/verify_schema_no_wordcards.py --schema <副本路径>   # 反向测试用
"""
import argparse
import os
import re
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMA_RS = os.path.join(ROOT, 'backend', 'crates', 'api_server', 'src', 'schema.rs')

ap = argparse.ArgumentParser()
ap.add_argument('--schema', default=DEFAULT_SCHEMA_RS,
                help='schema.rs 路径（默认后端那份；可指向副本做反向测试）')
args = ap.parse_args()
SCHEMA_RS = args.schema

if not os.path.exists(SCHEMA_RS):
    sys.exit(f'✗ 找不到 {SCHEMA_RS}')

# ── 待删表（两轮合计 25 张）──
# 第一轮（2026-09-28）：词卡内容 + K12 课程
ROUND1 = [
    'prebuilt_cards', 'prebuilt_language_cards', 'prebuilt_science_cards',
    'prebuilt_literature_cards', 'prebuilt_humanities_cards',
    'prebuilt_plans', 'prebuilt_stages', 'prebuilt_tasks',
    'plan_runs', 'user_plan_progress', 'guardian_assignments',
]
# 第二轮（2026-09-29）：旧学习链（AI 对话 · 后端 FSRS 状态 · 调试 · 成就）
ROUND2 = [
    'conversations', 'conversation_turns', 'defer_queue',
    'user_cards', 'card_memory', 'review_log', 'card_relations',
    'user_language_cards', 'user_science_cards', 'user_literature_cards', 'user_humanities_cards',
    'debug_logs', 'debug_trackers', 'achievements',
]
DROPPED = ROUND1 + ROUND2

MUST_HAVE = ['users', 'tokens', 'payment_orders', 'subscription_plans',
             'subscription_requests', 'user_notifications', 'user_preferences',
             'referral_clicks', 'marketing_campaigns', 'distribution_commissions',
             'admin_users', 'app_config']

src = open(SCHEMA_RS, encoding='utf-8').read()


def extract(const_name):
    """提取 `pub const X: &str = r#"..."#;` 的原始内容"""
    m = re.search(
        r'pub const ' + re.escape(const_name) + r':\s*&str\s*=\s*r#"(.*?)"#\s*;',
        src, re.S)
    return m.group(1) if m else None


con = sqlite3.connect(':memory:')
cur = con.cursor()

print('═' * 74)
print('按 init_database 的顺序执行 schema.rs 里的 SQL 常量')
print('═' * 74)
failed = False
for name in ['SCHEMA_SQL', 'ADMIN_SCHEMA_SQL', 'DISTRIBUTION_SCHEMA_SQL', 'USER_PREFERENCES_SQL']:
    sql = extract(name)
    if sql is None:
        print(f'  ⚠️ {name}: 未找到常量（跳过）')
        continue
    try:
        # ⚠️ `executescript` 自己管事务（执行前会先 commit 活动事务）
        #    → **不要**手动 BEGIN/COMMIT，否则报 "no transaction is active"
        cur.executescript(sql)
        n = cur.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
        print(f'  ✅ {name}: 执行成功（累计 {n} 张表）')
    except Exception as e:
        failed = True
        print(f'  🔴 {name}: 执行失败 → {type(e).__name__}: {e}')

tables = [r[0] for r in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]

print()
print('═' * 74)
print(f'🔴 核心检查：{len(DROPPED)} 张待删表是否**被重新建出来**')
print('═' * 74)
present = [t for t in DROPPED if t in tables]
if present:
    print(f'  🔴 仍会被建出来（{len(present)} 张）—— schema.rs 没改干净：')
    for t in present:
        print(f'      {t}')
    failed = True
else:
    print(f'  ✅ {len(DROPPED)} 张待删表**一张都没有** —— 全新库不会再建出它们')

print()
print('═' * 74)
print('✅ 保留表是否都还在')
print('═' * 74)
missing = [t for t in MUST_HAVE if t not in tables]
if missing:
    print(f'  🔴 缺失（{len(missing)} 张）: {missing}')
    failed = True
else:
    print(f'  ✅ {len(MUST_HAVE)} 张保留表全部存在')

print()
print(f'  最终表数: {len(tables)}')
print(f'  表清单: {tables}')
con.close()
print()
print('🔴 验证未通过' if failed else '✅ 全部通过：全新库不会再建出待删表')
sys.exit(1 if failed else 0)
