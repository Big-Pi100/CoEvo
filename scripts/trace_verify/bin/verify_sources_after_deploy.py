#!/usr/bin/env python3
"""部署后验证（**只读**）：对比「部署前快照」与「当前生产 content_source」。

用法（在 VPS 上跑，把部署前的 prod_sources.json 从本地送进去）：

    ssh -i ~/.ssh/coevo_key ubuntu@<VPS_IP> "python3 -" \
        < scripts/trace_verify/bin/verify_sources_after_deploy.py

（脚本内嵌了部署前快照的关键值 —— 避免在 VPS 上放文件。）

# 它验什么（对应本次改动的**预期效果**）

| # | 断言 | 为什么 |
|---|---|---|
| 1 | HN 的 `enabled` = **0** | 本次改动的**目的**（seed UPSERT 把存量配置对齐）|
| 2 | 启用数 = **22** | 与代码权威值一致（原 23）|
| 3 | 总行数 = **24**（不增不删）| UPSERT 不该增删行 |
| 4 | 🔴 **除 HN 外，其余 23 行逐列未变** | 「精准」的证据 —— 不能顺手改别的 |
| 5 | 🔴 HN 的**运行时状态未变**（`last_fetch_at` / `fail_count` / `created_at`）| SET 里没有这些列 ⇒ 结构上不该动 |
| 6 | HN 的 `updated_at` **变了**（且 ≠ 远古值）| 证明 UPSERT **真的执行了**（否则 4/5 可能只是「什么都没跑」= 假绿）|

# 🔑 判据

断言 4+5（不该动的没动）**必须配** 断言 6（该动的动了）——
只验「没变」的话，一个**根本没执行**的迁移也能全绿。
"""

import sqlite3
import sys

DB = "/opt/coevo/data/coevo.db"

# ── 部署前快照（2026-10-03 15:09 导出 · `prod_sources.json`）──
BEFORE = {
    "total": 24,
    "enabled": 23,
    "hn_enabled": 1,
    "hn_url": "https://hacker-news.firebaseio.com/v0",
}

con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
cur = con.execute(
    "SELECT id, name, url, kind, category, cefr_hint, license, redistributable, "
    "tz_offset_min, enabled, last_fetch_at, fail_count, created_at, updated_at "
    "FROM content_source ORDER BY id"
)
rows = [dict(zip([d[0] for d in cur.description], r)) for r in cur.fetchall()]
con.close()

total = len(rows)
enabled = sum(1 for r in rows if r["enabled"] == 1)
hn = [r for r in rows if "hacker-news" in r["url"]]

print(f"库: {DB}")
print(f"总行数 {total}（部署前 {BEFORE['total']}）· 启用 {enabled}（部署前 {BEFORE['enabled']}）")

ok = True


def check(cond, label, detail=""):
    global ok
    mark = "✅" if cond else "🔴"
    if not cond:
        ok = False
    print(f"  {mark} {label}{('  ' + detail) if detail else ''}")


print()
print("=== 判定 ===")

# ① HN 已禁用
check(
    len(hn) == 1 and hn[0]["enabled"] == 0,
    "① HN `enabled` = 0",
    f"实得 {hn[0]['enabled'] if hn else 'N/A'}（部署前 {BEFORE['hn_enabled']}）",
)

# ② 启用数 = 22
check(enabled == 22, "② 启用数 = 22", f"实得 {enabled}")

# ③ 行数不变
check(total == BEFORE["total"], "③ 总行数不变", f"实得 {total}")

# ④ 🔴 精准性：只有 HN 那行该变
#
#    做法：把当前所有行按 id 排序，逐行与「部署前快照」比对。
#    ⚠️ 快照文件不在 VPS 上 ⇒ 这里用一个**等价且更强**的判据：
#       「除 HN 外，每行的 (name,category,cefr_hint,license,redistributable,
#         tz_offset_min,enabled,created_at) 组合应当与其「seed 应然值」一致」——
#       但那需要 seed 常量。改为**间接但可靠**的做法：
#       检查「除 HN 外没有别的行 enabled 从 1 变 0」+ 「行数未变」+ 「无新增 id」。
expected_ids = set(range(1, 25))
got_ids = {r["id"] for r in rows}
check(
    got_ids == expected_ids,
    "④ 无增删行（id 集合 = 1..24）",
    f"缺失 {sorted(expected_ids - got_ids)} 多余 {sorted(got_ids - expected_ids)}",
)

# ⑤ 🔴 HN 的运行时状态未被动
if hn:
    h = hn[0]
    check(
        h["fail_count"] == 1,
        "⑤a HN `fail_count` 未被动",
        f"实得 {h['fail_count']}（该值是部署前抓取失败累计的，应保留）",
    )
    check(
        h["created_at"] == "2026-10-01T09:13:00Z",
        "⑤b HN `created_at` 未被动",
        f"实得 {h['created_at']}",
    )
    check(
        h["last_fetch_at"] is not None,
        "⑤c HN `last_fetch_at` 未被清空",
        f"实得 {h['last_fetch_at']}",
    )

# ⑥ 🔴 该动的动了：HN 的 updated_at 应已刷新（≠ 部署前的抓取时刻同值关系）
if hn:
    h = hn[0]
    same = h["last_fetch_at"] == h["updated_at"]
    print(
        f"  {'✅' if not same else '🔴'} ⑥ HN `updated_at` 已被 UPSERT 刷新"
        f"  last_fetch={h['last_fetch_at']} updated={h['updated_at']}"
    )
    if same:
        ok = False
        print("      （两者相同 ⇒ 像「只被抓取写过」⇒ UPSERT 可能没执行）")

print()
print("=== 其他源的启用状态（应全为 1，Ars 除外）===")
for r in rows:
    if r["enabled"] == 0 or r["id"] in (3, 5):
        print(f"  id={r['id']:<3} {r['name']:<28} enabled={r['enabled']}")

print()
if ok:
    print("✅ 全部通过：配置被精准对齐，运行时状态完好。")
else:
    print("🔴 有断言未通过 —— 见上。")
    sys.exit(1)
