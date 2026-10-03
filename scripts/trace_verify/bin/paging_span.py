#!/usr/bin/env python3
"""只读：量化「30 篇一页」覆盖多长时间 —— 用真实数据算，不靠估计。"""
import sqlite3

con = sqlite3.connect("file:/opt/coevo/data/coevo.db?mode=ro", uri=True)
rows = list(con.execute(
    "SELECT id, COALESCE(published_at, fetched_at) t FROM content_pool "
    "ORDER BY COALESCE(published_at, fetched_at) DESC LIMIT 60"))
print("按时间倒序，第 N 条的时间戳：")
for n in (1, 10, 20, 30, 40, 50, 60):
    if n <= len(rows):
        print(f"  第 {n:>2} 条: {rows[n-1][1]}   (id={rows[n-1][0]})")
print()
print(f"  第 1 条 → 第 30 条 跨度: {rows[0][1]}  →  {rows[29][1]}")
print(f"  第 1 条 → 第 50 条 跨度: {rows[0][1]}  →  {rows[49][1]}")
print()
n_total = con.execute("SELECT COUNT(*) FROM content_pool").fetchone()[0]
print(f"  总量 {n_total} 条 ⇒ 30 篇一页 = 只看到 {100.0*30/n_total:.1f}%（剩下 {n_total-30} 条拿不到）")
con.close()
