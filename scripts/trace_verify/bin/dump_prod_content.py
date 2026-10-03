#!/usr/bin/env python3
"""🔴 只读导出 VPS 生产库的 content_pool 全量内容（供本地用**生产实现**复跑闸门）。

用法（在 VPS 上跑，stdout 是 JSON，stderr 是诊断）：

    ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" \
        < scripts/trace_verify/bin/dump_prod_content.py \
        > scripts/trace_verify/fixtures/prod_content_all.json

设计约束：
- **只读**：不建表、不写入、不 VACUUM；不做任何 DDL/DML。
- 输出每个字段都退化为 `""`（`None` → `""`），避免 JSON 里出现 null 让 Rust 侧解析变复杂。
- stderr 打印**库路径 / 行数 / 列名 / 分布摘要**，便于确认「导的是哪一个库」——
  📌 判据：跨机器取数据必须能证明「这份数据来自我以为是的那张表」。
"""

import json
import sqlite3
import sys

DB = "/opt/coevo/data/coevo.db"

con = sqlite3.connect(DB)
cur = con.execute(
    "select name from sqlite_master where type='table' and name='content_pool'"
)
if cur.fetchone() is None:
    print(f"🔴 {DB} 里没有 content_pool 表", file=sys.stderr)
    sys.exit(1)

cols = [r[1] for r in con.execute("PRAGMA table_info(content_pool)")]
print(f"db={DB}", file=sys.stderr)
print(f"cols={cols}", file=sys.stderr)

need = ["id", "source_id", "title", "summary", "body", "url"]
missing = [c for c in need if c not in cols]
if missing:
    print(f"🔴 缺列: {missing} —— 表结构与预期不符，停止", file=sys.stderr)
    sys.exit(1)

rows = con.execute(
    "select id, source_id, title, summary, body, url from content_pool order by id"
)
out = []
for r in rows:
    out.append(
        {
            "id": r[0],
            "src": r[1] if r[1] is not None else 0,
            "title": r[2] or "",
            "summary": r[3] or "",
            "body": r[4] or "",
            "url": r[5] or "",
        }
    )

print(f"rows={len(out)}", file=sys.stderr)
with_body = sum(1 for x in out if x["body"].strip())
print(f"has_body={with_body}  body_empty={len(out) - with_body}", file=sys.stderr)

json.dump(out, sys.stdout, ensure_ascii=False)
