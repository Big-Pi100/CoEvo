#!/usr/bin/env python3
"""只读导出生产库的 `content_source` 全表（供本地用**真实值**做迁移演练）。

用法：
    ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" \
        < scripts/trace_verify/bin/dump_prod_sources.py \
        > scripts/trace_verify/fixtures/prod_sources.json

只读：不做任何 DDL/DML。stderr 打印库路径/行数/启用数，便于确认导的是哪张表。
"""

import json
import sqlite3
import sys

DB = "/opt/coevo/data/coevo.db"

con = sqlite3.connect(DB)
cols = [r[1] for r in con.execute("PRAGMA table_info(content_source)")]
print(f"db={DB}", file=sys.stderr)
print(f"cols={cols}", file=sys.stderr)

rows = list(
    con.execute(
        "select id, name, url, kind, category, cefr_hint, license, redistributable, "
        "tz_offset_min, fetch_interval_min, enabled, last_fetch_at, fail_count, "
        "created_at, updated_at from content_source order by id"
    )
)
out = []
for r in rows:
    out.append(
        {
            "id": r[0], "name": r[1], "url": r[2], "kind": r[3], "category": r[4],
            "cefr_hint": r[5], "license": r[6], "redistributable": r[7],
            "tz_offset_min": r[8], "fetch_interval_min": r[9], "enabled": r[10],
            "last_fetch_at": r[11], "fail_count": r[12],
            "created_at": r[13], "updated_at": r[14],
        }
    )

enabled = [x["id"] for x in out if x["enabled"] == 1]
print(f"rows={len(out)}  enabled={len(enabled)} → ids {enabled}", file=sys.stderr)
hn = [x for x in out if "hacker-news" in x["url"]]
print(f"HN 行: {[(x['id'], x['name'], x['enabled']) for x in hn]}", file=sys.stderr)

json.dump(out, sys.stdout, ensure_ascii=False)
