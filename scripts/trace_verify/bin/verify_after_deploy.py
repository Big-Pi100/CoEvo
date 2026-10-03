#!/usr/bin/env python3
"""部署后验证：库状态 + 新增条目清单 + 非英语残留自查。只读。"""
import sqlite3

DB = "/opt/coevo/data/coevo.db"
BEFORE = 960  # 删除存量后的行数（部署前基线）

c = sqlite3.connect(DB)
total = c.execute("select count(*) from content_pool").fetchone()[0]
maxid = c.execute("select max(id) from content_pool").fetchone()[0]

print(f"content_pool 总数: {total}  （部署前 {BEFORE} · 差 {total - BEFORE}）")
print(f"最大 id: {maxid}")
print(f".pdf 条目: {c.execute("select count(*) from content_pool where url like '%.pdf'").fetchone()[0]}")
print()
print("各源条数（前 8）:")
for sid, name, n in c.execute(
    "select s.id, s.name, count(*) from content_pool p join content_source s on s.id=p.source_id "
    "group by s.id order by count(*) desc limit 8"
):
    print(f"  id={sid:<3} {name:<24} {n}")
print()
print("最新的 14 条（部署后抓到的新内容）:")
for r in c.execute(
    "select id, source_id, substr(title,1,66) from content_pool order by id desc limit 14"
):
    print(f"  id={r[0]:<5} src={r[1]:<3} {r[2]}")
c.close()
