#!/usr/bin/env python3
"""删除 6 条非英语存量内容（白哥 2026-10-03 批准）。

按 `safe-bulk-deletion` 规范：
  ① VACUUM INTO 备份（WAL 安全 —— **不能**用 `cp`，未 checkpoint 的数据会丢）
  ② 存档删除清单（id / source_id / title / url），供事后核查
  ③ **副本演练**：在备份副本上跑同一条 SQL，确认影响行数 = 6、残留 = 0
  ④ 才对**生产**执行，并做正反双验证
  ⑤ VACUUM 回收空间

🔑 为什么先演练：DELETE 的 WHERE 一旦写错（比如 id 类型/范围），
   影响的是**不可逆**的生产内容。副本上跑一遍的成本几乎为零。
"""

import os
import shutil
import sqlite3
import sys
import datetime

DB = "/opt/coevo/data/coevo.db"
STAMP = "20261003"
BAK = f"/opt/coevo/data/backup-before-del-nonenglish-{STAMP}.db"
DRILL = f"/opt/coevo/data/drill-del-nonenglish-{STAMP}.db"
LIST = f"/opt/coevo/data/deleted-nonenglish-{STAMP}.txt"

IDS = (8, 737, 1021, 1645, 2032, 4260)
IN = ",".join(str(i) for i in IDS)
SQL = f"DELETE FROM content_pool WHERE id IN ({IN})"


def conn(p):
    # isolation_level=None ⇒ 手动管事务（默认的自动事务会让显式 BEGIN 报错）
    c = sqlite3.connect(p, timeout=10, isolation_level=None)
    c.execute("PRAGMA busy_timeout=8000")
    return c


def count(c, where=""):
    return c.execute(f"select count(*) from content_pool {where}").fetchone()[0]


# ── ① 备份（VACUUM INTO 是 WAL 模式下唯一安全的整库备份方式）──
if os.path.exists(BAK):
    print(f"⚠️ 备份已存在，跳过备份：{BAK}")
else:
    c = conn(DB)
    c.execute(f"VACUUM INTO '{BAK}'")
    c.close()
    print(f"① 备份完成：{BAK}  ({os.path.getsize(BAK)} bytes)")

# ── ② 存档删除清单（**从备份里读** ⇒ 记录的是删除前的真实内容）──
c = conn(BAK)
rows = list(
    c.execute(
        f"select id, source_id, title, url from content_pool where id in ({IN}) order by id"
    )
)
c.close()
with open(LIST, "w", encoding="utf-8", newline="\n") as f:
    f.write(f"# 非英语内容删除清单 · {datetime.datetime.now().isoformat()}\n")
    f.write("# 判据：英语功能词密度 < 8%（或英语字符 < 90%）· 见 docs/review/non-english-gate-*\n")
    f.write(f"# 备份：{BAK}\n\n")
    for r in rows:
        f.write("\t".join(str(x) for x in r) + "\n")
print(f"② 清单已存档：{LIST}（{len(rows)} 条 —— 应为 6）")
if len(rows) != 6:
    print("🔴 删除清单条数 ≠ 6 ⇒ 停止（可能 id 写错或已被删过）")
    sys.exit(1)

# ── ③ 副本演练 ──
shutil.copy(BAK, DRILL)
d = conn(DRILL)
before = count(d)
d.execute("BEGIN")
d.execute(SQL)
n = d.total_changes
d.execute("COMMIT")
after = count(d)
left = count(d, f"where id in ({IN})")
d.close()
print(f"③ 副本演练：before={before}  after={after}  影响={n} 行  残留={left}")
if n != 6 or left != 0:
    print("🔴 演练不符合预期（期望影响 6 行 / 残留 0）⇒ **不动生产**")
    sys.exit(1)

# ── ④ 生产执行 ──
c = conn(DB)
before = count(c)
c.execute("BEGIN")
c.execute(SQL)
n = c.total_changes
c.execute("COMMIT")
after = count(c)
left = count(c, f"where id in ({IN})")
print(f"④ 生产执行：before={before}  after={after}  影响={n} 行  残留={left}")

# 正反双验证
ok = True
if n != 6 or left != 0 or before - after != 6:
    print("🔴 生产结果不符合预期")
    ok = False
# 反向：同源内容**没有被误删大量**（Dev.to / NPR 仍有内容）
print("   反向验证 · 各源剩余条数（前 8）：")
for sid, cnt in c.execute(
    "select source_id, count(*) from content_pool group by source_id order by count(*) desc limit 8"
):
    print(f"     source_id={sid}: {cnt}")

c.close()

if not ok:
    sys.exit(1)

# ── ⑤ VACUUM ──
c = conn(DB)
sz_before = os.path.getsize(DB)
c.execute("VACUUM")
c.close()
sz_after = os.path.getsize(DB)
print(f"⑤ VACUUM：{sz_before} → {sz_after} bytes")
print("✅ 全部完成")
