#!/usr/bin/env python3
"""只读：生产内容池的**分类分布 + 时效分布**。

用途：判断「按兴趣筛选」是否**有足够内容可筛** ——
若某类只有几条，用户勾了它会看到空列表（比没有筛选功能更糟）。

同时给出「近 N 天新增量」，用于判断「30 篇一页」够不够（一页覆盖几天）。
"""

import sqlite3
import sys

DB = "/opt/coevo/data/coevo.db"

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)

total = con.execute("SELECT COUNT(*) FROM content_pool").fetchone()[0]
print(f"content_pool 总量: {total}")

print()
print("=== ① 分类分布（全量）===")
print(f"{'category':<16}{'条数':>6}{'占比':>8}   {'有正文':>6}")
rows = list(
    con.execute(
        "SELECT COALESCE(category, '<NULL>') c, COUNT(*) n, "
        "SUM(CASE WHEN body IS NOT NULL AND body <> '' THEN 1 ELSE 0 END) wb "
        "FROM content_pool GROUP BY c ORDER BY n DESC"
    )
)
for c, n, wb in rows:
    print(f"  {c:<14}{n:>6}{100.0 * n / total:>7.1f}%   {wb:>6}")

print()
print("=== ② 时效：最近 7 天 / 14 天 / 30 天新增 ===")
for days in (1, 3, 7, 14, 30):
    n = con.execute(
        "SELECT COUNT(*) FROM content_pool "
        "WHERE COALESCE(published_at, fetched_at) >= datetime('now', ?1)",
        (f"-{days} days",),
    ).fetchone()[0]
    print(f"  近 {days:>2} 天: {n:>5} 条")

print()
print("=== ③ 单类「够不够一页」—— 按类看近 7 天 / 全量 ===")
print(f"  {'category':<16}{'全量':>6}{'近7天':>7}   判定")
for c, n, wb in rows:
    if c == "<NULL>":
        continue
    n7 = con.execute(
        "SELECT COUNT(*) FROM content_pool WHERE category = ?1 "
        "AND COALESCE(published_at, fetched_at) >= datetime('now', '-7 days')",
        (c,),
    ).fetchone()[0]
    # 判定：一页 30 条为参考
    if n7 >= 30:
        verdict = "✅ 近 7 天就够一页"
    elif n >= 30:
        verdict = "🟡 全量够，但近 7 天不足"
    elif n >= 10:
        verdict = "⚠️ 只有十几条（拖动就见底）"
    else:
        verdict = "🔴 太少（会像空列表）"
    print(f"  {c:<16}{n:>6}{n7:>7}   {verdict}")

print()
print("=== ④ 最老 / 最新条目时间 ===")
r = con.execute(
    "SELECT MIN(COALESCE(published_at, fetched_at)), MAX(COALESCE(published_at, fetched_at)) "
    "FROM content_pool"
).fetchone()
print(f"  最老: {r[0]}")
print(f"  最新: {r[1]}")

con.close()
