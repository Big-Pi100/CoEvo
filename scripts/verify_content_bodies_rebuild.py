#!/usr/bin/env python3
"""`content_bodies_rebuild.py` 的验收断言（构造库演练 · 零生产依赖）。

# 为什么要有它
那个脚本要动的是 **`content_pool` 的存量数据**（summary 置 NULL / 清抓取标记）。
「跑得通」不代表「判得对」—— 必须用**构造库**把每个动作的**边界**跑一遍：
· 该清的清了、**不该清的一条没动**（误杀比漏清更难发现）
· dry-run **真的什么都没写**
· 分批真的分批、且**可续跑**
· 重复跑**幂等**（第二次应当「无需清理」）

# 🔑 库结构从 `schema.rs` 提取（不是手抄）
手抄 DDL 会漂移 → 演练验的是「另一个结构」。
这里直接从 `schema.rs` 里提取 `content_pool` 的真实建表语句，
📌 判据：**演练环境必须与真实结构同源**，否则演练通过 ≠ 生产安全。

用法：`python3 scripts/verify_content_bodies_rebuild.py`
"""

import os
import re
import sqlite3
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "content_bodies_rebuild.py")
SCHEMA_RS = os.path.join(
    ROOT, "backend", "crates", "api_server", "src", "schema.rs"
)

_pass = 0
_fail = []


def check(label: str, ok: bool, detail: str = "") -> None:
    global _pass
    if ok:
        _pass += 1
        print(f"  ✅ {label}")
    else:
        _fail.append(label)
        print(f"  🔴 {label}" + (f"   [{detail}]" if detail else ""))


def section(title: str) -> None:
    print(f"\n【{title}】")


def extract_ddl(table: str) -> str:
    """从 schema.rs 提取某张表的建表语句 + 它自己的索引（**同源**，不手抄）。

    🔴 **为什么必须连 `content_source` 一起建**（2026-10-02 踩到）：
    本脚本第一版只建了 `content_pool`，而真实查询里有
    `LEFT JOIN content_source s ON s.id = p.source_id`（用来判 `redistributable`）
    → 构造库缺表 → SQL 直接 `no such table` → **脚本崩**（12 项失败）。
    📌 这正是「**演练环境必须与真实结构同源**」的实例：
       只建「我要改的那张表」不够 —— **查询里 JOIN 到的表也是「真实结构」的一部分**。
    """
    src = open(SCHEMA_RS, encoding="utf-8").read()
    m = re.search(
        rf"CREATE TABLE IF NOT EXISTS {table}\s*\(.*?\n\);", src, re.S
    )
    if not m:
        raise SystemExit(f"🔴 无法从 schema.rs 提取 {table} 的 DDL")
    ddl = m.group(0)
    # 该表的索引（同文件里，命名前缀区分：idx_cpool_ / idx_csrc_）
    prefix = {"content_pool": "idx_cpool_", "content_source": "idx_csrc_"}.get(table)
    if prefix:
        for m2 in re.finditer(
            rf"CREATE (?:UNIQUE )?INDEX IF NOT EXISTS {prefix}\w+[^;]*;", src
        ):
            ddl += "\n" + m2.group(0)
    return ddl


def build_db(path: str) -> None:
    """建库 + 灌入覆盖各边界的构造数据。

    ⚠️ 建**两张**表（`content_source` + `content_pool`）——
    真实查询 JOIN 了前者，缺它脚本会崩（见 [extract_ddl] 的说明）。
    """
    conn = sqlite3.connect(path)
    conn.executescript(extract_ddl("content_source"))
    conn.executescript(extract_ddl("content_pool"))

    T = "2026-10-01T00:00:00Z"
    # 两个源：src 1 = 可再分发（参与抓取）；src 2 = **不可**再分发（永不被挑中）
    conn.execute(
        "INSERT INTO content_source (id, name, url, kind, redistributable, "
        "tz_offset_min, created_at, updated_at) VALUES "
        "(1, '可再分发源', 'https://a.test/feed', 'rss', 1, 0, ?, ?), "
        "(2, '只存摘要源', 'https://b.test/feed', 'rss', 0, 0, ?, ?)",
        (T, T, T, T),
    )

    rows = [
        # (source_id, url, title, summary, body, attempted)
        # ① 实测真实案例：summary 是源站报错 → **该被清**
        (1, "https://dev.to/a", "OpenRive 那篇",
         "Liquid syntax error: 'raw' tag was never closed", None, T),
        # ② 同族指纹 → **该被清**
        (1, "https://dev.to/b", "模板报错",
         "Template render error: undefined method", None, T),
        # ③ 正常短摘要 → **不该动**
        (1, "https://npr.org/c", "正常新闻",
         "A short news brief about the economy and jobs.", "正文内容" * 40, T),
        # ④ 🔴 长文里出现报错字样 → **不该动**（互补信号：长度）
        (1, "https://dev.to/d", "讲调试的教程",
         "A long-form engineering write-up. In this post we walk through how we hit a "
         "syntax error while building our parser, why it took three days to find, and "
         "what we changed afterwards to make the failure loud instead of silent.",
         "正文" * 60, T),
        # ⑤ summary 本来就为 NULL → 不该被当成"脏的"
        (1, "https://hn.item/e", "HN 帖", None, "讨论内容" * 30, T),
        # ⑥ 没抓过正文的（attempted 为 NULL）→ reset **不该**碰它
        (1, "https://npr.org/f", "没抓过", "Some summary here.", None, None),
        # ⑦ 🔴 **不可再分发但试过** → reset **不该**碰它（它永远不会进候选池，
        #    重置标记只是一次无意义的状态变更）—— 这条守卫「重置条件与挑候选条件同源」
        (2, "https://b.test/1", "只存摘要的源",
         "Summary only for this source.", None, T),
    ]
    for sid, url, title, summ, body, att in rows:
        conn.execute(
            "INSERT INTO content_pool (source_id, title, summary, body, url, "
            "fetched_at, body_attempted_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (sid, title, summ, body, url, T, att),
        )
    conn.commit()
    conn.close()


def run(*args) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, SCRIPT, *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def q1(conn: sqlite3.Connection, sql: str, args=()) -> object:
    return conn.execute(sql, args).fetchone()[0]


#: 「重置口径」的计数 SQL —— ⚠️ 与脚本 `action_reset_attempted` 的 WHERE **完全一致**。
#: 不写成字面量重复，而是提出来复用，避免「断言用的口径」与「实现用的口径」漂移。
_ATTEMPTED = (
    "SELECT COUNT(*) FROM content_pool p "
    "LEFT JOIN content_source s ON s.id = p.source_id "
    "WHERE COALESCE(s.redistributable, 0) = 1 AND p.body_attempted_at IS NOT NULL"
)


def main() -> None:
    print("=" * 74)
    print("content_bodies_rebuild.py 验收（构造库演练）")
    print("=" * 74)
    print(f"DDL 来源: {os.path.relpath(SCHEMA_RS, ROOT)}（同源，非手抄）")

    tmpdir = tempfile.mkdtemp(prefix="coevo_rebuild_")
    db = os.path.join(tmpdir, "coevo.db")

    # ── 【1】判据自检（脚本启动即跑）──────────────────────────────
    section("1 · 判据自检（与 Rust 侧一致性）")
    build_db(db)
    r = run("--db", db, "--plan")
    check("脚本能跑（判据自检通过 —— 与 Rust 侧同一组样例）", r.returncode == 0,
          r.stdout[-300:] + r.stderr[-300:])

    # ── 【2】plan 只读 ───────────────────────────────────────────
    section("2 · plan 只读（不写任何东西）")
    before = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    n_sum_before = q1(before, "SELECT COUNT(*) FROM content_pool WHERE summary IS NOT NULL")
    n_att_before = q1(before, _ATTEMPTED)
    before.close()
    check("plan 报出正确的待清理数（2 篇：真案例 + 同族指纹）",
          "待清理的「源站报错」摘要 : 2 篇" in r.stdout, r.stdout[-400:])

    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    check("plan 后 summary 非空数未变", q1(conn, "SELECT COUNT(*) FROM content_pool WHERE summary IS NOT NULL") == n_sum_before)
    check("plan 后 attempted 数未变", q1(conn, _ATTEMPTED) == n_att_before)
    conn.close()

    # ── 【3】clean-summary dry-run 必须"什么都没写" ────────────────
    section("3 · clean-summary 的 DRY-RUN（关键：真的不写）")
    r = run("--db", db, "--clean-summary")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    check("dry-run 后脏 summary **仍在**（没写库）",
          q1(conn, "SELECT COUNT(*) FROM content_pool WHERE summary LIKE '%Liquid%'") == 1)
    conn.close()
    check("dry-run 有明确提示（不写就该说清）", "DRY-RUN" in r.stdout)

    # ── 【4】clean-summary --apply：该清的清、不该动的不动 ────────
    section("4 · clean-summary --apply（清脏 · 不误杀）")
    r = run("--db", db, "--clean-summary", "--apply")
    conn = sqlite3.connect(db)
    check("真案例被清（Liquid 那条 → NULL）",
          q1(conn, "SELECT COUNT(*) FROM content_pool WHERE summary LIKE '%Liquid%'") == 0)
    check("同族指纹被清（Template render error 那条 → NULL）",
          q1(conn, "SELECT COUNT(*) FROM content_pool WHERE summary LIKE '%Template render%'") == 0)
    check("🔴 正常短摘要**原样保留**（没被误杀）",
          q1(conn, "SELECT summary FROM content_pool WHERE url='https://npr.org/c'")
          == "A short news brief about the economy and jobs.")
    check("🔴 长文摘要**原样保留**（互补信号：长度让它免于误杀）",
          "syntax error" in (q1(conn, "SELECT summary FROM content_pool WHERE url='https://dev.to/d'") or ""))
    check("原本为 NULL 的仍是 NULL", q1(conn, "SELECT summary FROM content_pool WHERE url='https://hn.item/e'") is None)
    conn.close()
    check("apply 输出报告了清理条数", "已清理 2 篇" in r.stdout, r.stdout[-300:])

    # ── 【5】幂等：再跑一次应当"无需清理" ─────────────────────────
    section("5 · 幂等（重复跑不该再动数据）")
    r2 = run("--db", db, "--clean-summary", "--apply")
    check("第二次跑：报「无需清理」", "无需清理" in r2.stdout, r2.stdout[-200:])

    # ── 【6】reset-attempted 分批 + dry-run ──────────────────────
    section("6 · reset-attempted（分批 + dry-run + 可续跑）")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    att_total = q1(conn, _ATTEMPTED)
    conn.close()
    check("构造数据里 5 篇「可抓取且试过」", att_total == 5, f"实得 {att_total}")

    r = run("--db", db, "--reset-attempted", "--batch", "2")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    check("dry-run 后 attempted 数**未变**",
          q1(conn, _ATTEMPTED) == att_total)
    conn.close()

    r = run("--db", db, "--reset-attempted", "--batch", "2", "--apply")
    conn = sqlite3.connect(db)
    left = q1(conn, _ATTEMPTED)
    conn.close()
    check("🔑 只清了 2 篇（**分批**生效）", left == att_total - 2, f"剩余 {left}")
    check("提示还有剩余（可续跑）", "剩余" in r.stdout)

    r = run("--db", db, "--reset-attempted", "--batch", "2", "--apply")
    conn = sqlite3.connect(db)
    left2 = q1(conn, _ATTEMPTED)
    conn.close()
    check("续跑再清 2 篇", left2 == left - 2, f"剩余 {left2}")

    # ── 【7】不碰"从未抓过"的条目 ─────────────────────────────────
    section("7 · 不越界：从未抓过的不该被 reset 影响")
    # ⚠️ 到这一步还剩 1 篇（5 - 2 - 2），batch=10 正好把它清完
    r = run("--db", db, "--reset-attempted", "--batch", "10", "--apply")
    conn = sqlite3.connect(db)
    att_left = q1(conn, _ATTEMPTED)
    untouched = q1(
        conn,
        "SELECT COUNT(*) FROM content_pool WHERE url='https://npr.org/f' AND body_attempted_at IS NULL",
    )
    conn.close()
    check("最后一篇清完 → attempted 归零", att_left == 0, f"剩余 {att_left}")
    check("从未抓过的条目仍是 NULL（它本来就该被抓，不是「重置」的对象）", untouched == 1)

    # 🔑 **再跑一次**才该报「无需重置」—— 这一条不写就对不上（我第一次就写错了：
    #    batch=10 那轮其实清掉了最后 1 篇，输出是「已重置 1 篇」）
    r = run("--db", db, "--reset-attempted", "--batch", "10", "--apply")
    check("全部清完后**再跑**报「无需重置」", "无需重置" in r.stdout, r.stdout[-200:])

    # ── 【7b】🔴 不可再分发的源：重置它没有意义，**不该动** ────────
    section("7b · 不越界：`redistributable = 0` 的条目标记不该被清")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    r0_still_tried = q1(
        conn,
        "SELECT COUNT(*) FROM content_pool p "
        "LEFT JOIN content_source s ON s.id = p.source_id "
        "WHERE COALESCE(s.redistributable, 0) = 0 AND p.body_attempted_at IS NOT NULL",
    )
    conn.close()
    # 它**永远**进不了 `pick_body_candidates` 的候选池（SQL 按 redistributable 过滤）
    # → 清掉它的标记只会制造「待重置列表里有一条永远清不掉的项」这种假象
    # 📌 判据：**重置「候选资格」时，条件要与「挑候选」的条件同源**
    check("🔴 不可再分发的条目仍保持「已尝试」（没被无意义地清掉）",
          r0_still_tried == 1, f"实得 {r0_still_tried}")

    # ── 【8】库不存在时应干净报错（不要静默建空库）──────────────
    section("8 · 边界：库不存在")
    r = run("--db", os.path.join(tmpdir, "nope.db"), "--plan")
    check("库不存在 → 明确报错（不是静默建一个空库）",
          r.returncode != 0 and "不存在" in (r.stdout + r.stderr), r.stdout[-200:])

    # 清理
    try:
        for f in os.listdir(tmpdir):
            os.remove(os.path.join(tmpdir, f))
        os.rmdir(tmpdir)
    except OSError:
        pass

    print()
    print("=" * 74)
    if _fail:
        print(f"🔴 失败 {len(_fail)} 项 / 通过 {_pass} 项：")
        for f in _fail:
            print(f"    · {f}")
        sys.exit(1)
    print(f"✅ 全部通过：{_pass} 项")


if __name__ == "__main__":
    main()
