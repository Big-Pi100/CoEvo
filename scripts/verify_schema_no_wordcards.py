#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证：用**当前 schema.rs** 在**全新空库**上初始化后，待删表**不会出现**

# 为什么必须验（2026-09-28）
「删表」只是治标 —— 后端 `init_database` 会在**新建库**时执行建表语句。
若 `schema.rs` 里还留着待删表的 `CREATE TABLE IF NOT EXISTS`，
那么**全新部署时那些空表会被重新建出来**（白做）。

本脚本**直接提取** `schema.rs` 里的 SQL 常量（与 Rust 侧同源，不另抄一份），
在**内存库**上按 `init_database` 的顺序执行，然后检查表清单。
→ 因此它能抓到「注释里的中文/符号破坏 SQL」这类问题（比只读代码强）。

⚠️ 它**不替代** `cargo check`（Rust 语法层面）——
   两者互补：`cargo check` 管 Rust 能不能编译，本脚本管 **SQL 执行后表对不对**。
"""
import os
import re
import sqlite3
import sys
import argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCHEMA_RS = os.path.join(ROOT, 'backend', 'crates', 'api_server', 'src', 'schema.rs')

ap = argparse.ArgumentParser()
ap.add_argument('--schema', default=DEFAULT_SCHEMA_RS,
                help='schema.rs 路径（默认后端那份；可指向副本做反向测试）')
args = ap.parse_args()
SCHEMA_RS = args.schema

if not os.path.exists(SCHEMA_RS):
    sys.exit(f'✗ 找不到 {SCHEMA_RS}')

# 待删表（与 purge 脚本一致）
DROPPED = [
    'prebuilt_cards', 'prebuilt_language_cards', 'prebuilt_science_cards',
    'prebuilt_literature_cards', 'prebuilt_humanities_cards',
    'prebuilt_plans', 'prebuilt_stages', 'prebuilt_tasks',
    'plan_runs', 'user_plan_progress', 'guardian_assignments',
]

src = open(SCHEMA_RS, encoding='utf-8').read()


def extract(const_name):
    """提取 `pub const X: &str = r#"..."#;` 的原始内容"""
    m = re.search(
        r'pub const ' + re.escape(const_name) + r':\s*&str\s*=\s*r#"(.*?)"#\s*;',
        src, re.S)
    if not m:
        return None
    return m.group(1)


con = sqlite3.connect(':memory:')
cur = con.cursor()

# init_database 的执行顺序（见 schema.rs 的 init_database）
order = ['SCHEMA_SQL', 'ADMIN_SCHEMA_SQL', 'DISTRIBUTION_SCHEMA_SQL', 'USER_PREFERENCES_SQL']
print('═' * 74)
print('按 init_database 的顺序执行 schema.rs 里的 SQL 常量')
print('═' * 74)
failed = False
for name in order:
    sql = extract(name)
    if sql is None:
        print(f'  ⚠️ {name}: 未找到常量（跳过）')
        continue
    try:
        # ⚠️ `executescript` 自己管事务（执行前会先 commit 活动事务）
        #    → **不要**手动 BEGIN/COMMIT，否则报 "no transaction is active"
        cur.executescript(sql)
        n = cur.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
        print(f'  ✅ {name}: 执行成功（累计 {n} 张表）')
    except Exception as e:
        failed = True
        print(f'  🔴 {name}: 执行失败 → {type(e).__name__}: {e}')

# init_database 里的附加索引（schema.rs 尾部的 execute_batch）
extra = """
CREATE INDEX IF NOT EXISTS idx_review_log_card_reviewed ON review_log(card_id, reviewed_at);
CREATE INDEX IF NOT EXISTS idx_conversation_turns_conv_created ON conversation_turns(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_cards_user_plan ON user_cards(user_id, plan_run_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user_deleted ON conversations(user_id, deleted_at);
"""
try:
    cur.executescript(extra)
    print('  ✅ 附加索引: 执行成功')
except Exception as e:
    failed = True
    print(f'  🔴 附加索引: 失败 → {e}')

tables = [r[0] for r in cur.execute(
    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]

print()
print('═' * 74)
print('🔴 核心检查：待删表是否**被重新建出来**')
print('═' * 74)
present = [t for t in DROPPED if t in tables]
if present:
    print(f'  🔴 仍会被建出来（{len(present)} 张）—— schema.rs 没改干净：')
    for t in present:
        print(f'      {t}')
    failed = True
else:
    print(f'  ✅ 11 张待删表**一张都没有** —— 全新库不会再建出它们')

# 保留表必须在
MUST_HAVE = ['users', 'user_cards', 'card_memory', 'review_log', 'tokens',
             'payment_orders', 'subscription_plans', 'user_notifications',
             'referral_clicks', 'marketing_campaigns', 'user_preferences']
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

# user_cards 是否还有 prebuilt 外键
fk = cur.execute('PRAGMA foreign_key_list(user_cards)').fetchall()
refs = {r[2] for r in fk}
print()
print('═' * 74)
print('user_cards 的外键')
print('═' * 74)
print(f'  {fk}')
if 'prebuilt_cards' in refs:
    print('  🔴 仍有 prebuilt_cards 外键 —— 未改干净')
    failed = True
else:
    print('  ✅ 已无 prebuilt_cards 外键')

print()
print(f'  最终表数: {len(tables)}')
con.close()
print()
print('🔴 验证未通过' if failed else '✅ 全部通过：全新库不会再建出待删表')
sys.exit(1 if failed else 0)
