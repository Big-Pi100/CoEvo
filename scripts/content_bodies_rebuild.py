#!/usr/bin/env python3
"""内容管线重抓：清理脏 summary + 重置抓取标记。

# 为什么需要这个脚本

后端正文提取器换成了 `dom_smoothie`（成熟包，见
`docs/review/content-pipeline-rebuild-plan-2026-10-02.md`），
它对**新抓的**文章直接生效；但**已有的存量**还是旧提取器的产物（纯文本、
`<pre>` 被压平、`<code>` 语义丢失）。→ 需要让存量也用新提取器跑一遍。

而补抓正文的查询是 **「只试一次」** 的（`content_pool.body_attempted_at`）：
已抓过的条目**不会再进候选队列** → 光部署新后端**不会**重抓存量。
→ 本脚本负责「把已抓过的标记清掉」，让现有抓取循环自然地把它们重抓一遍。

# 两个动作（互相独立，可分别执行）

| 动作 | 做什么 | 为什么 |
|---|---|---|
| `--clean-summary` | 把「源站报错」形态的 summary 置 NULL | 那类摘要**不是文章摘要**（如 `Liquid syntax error`），而端侧在 body 为空时会兜底显示它 → 用户看到报错信息 |
| `--reset-attempted` | 清 `body_attempted_at`（**分批**）| 让存量重新进候选队列，用新提取器重抓 |

# 🔴 分批（白哥 2026-10-02 定）
一次性清空 311 篇的标记，会让抓取循环「一次性排满队」。虽然它每轮**本来就有**上限
（`MAX_BODY_FETCH_PER_ROUND = 100`），但对源站的压力集中在头几轮。
→ `--reset-attempted --batch 100` **每批只清 100 篇**（按发布时间倒序，先抓新的），
   跑完一批、等下一轮抓完，再清下一批。

# 🔴🔴 「同一判据的两份实现」——本脚本与 Rust 侧必须一致
判据 `is_source_error_summary` 在**两处**各有一份：
· `backend/crates/api_server/src/content_fetch.rs`（写入侧，管新数据）
· 本脚本（存量清理，管老数据）
**两份实现必须一致**，否则会出现「新数据干净、老数据脏」这种最难查的状态。

→ 对策：本脚本内嵌**与 Rust 侧同一组样例**（`_SELF_CHECK_CASES`），
   启动时先自检。**判据漂移 → 脚本自己报错**，不会静默按错的判据删数据。
   📌 判据：**跨实现的一致性只能靠共享用例**（共用数据 ≠ 共用判据）。

# 用法

    # ① 只读：先看影响面（不写任何东西）
    python3 scripts/content_bodies_rebuild.py --db <path> --plan

    # ② 清脏 summary（幂等，可重复跑）
    python3 scripts/content_bodies_rebuild.py --db <path> --clean-summary

    # ③ 分批重置抓取标记
    python3 scripts/content_bodies_rebuild.py --db <path> --reset-attempted --batch 100

⚠️ 所有写操作默认 **dry-run**（只打印将要做什么）—— 要真写必须显式加 `--apply`。
"""

import argparse
import os
import re
import sqlite3
import sys

# ─────────────────────────────────────────────────────────────────────
# 判据（**必须与 Rust 侧 `SOURCE_ERROR_FINGERPRINTS` 一致**）
# ─────────────────────────────────────────────────────────────────────

#: 已知的「源站模板/框架报错」指纹（全部小写，用 `in` 匹配）。
#: 🔴 改这里 = 必须同步改 `content_fetch.rs::SOURCE_ERROR_FINGERPRINTS`。
FINGERPRINTS = [
    "liquid syntax error",
    "was never closed",
    "template render error",
    "an error occurred while rendering",
    "cannot read propert",  # 覆盖 properties / property
]

#: 「摘要」短过这个长度才可能是报错信息（与 Rust 侧同名常量一致）。
MAX_ERROR_SUMMARY_CHARS = 200


def is_source_error_summary(s: str) -> bool:
    """明显是源站渲染失败的摘要 —— 命中则视为「没有摘要」。

    判据 = **指纹 + 长度，两条一起**：
    · 只用指纹 → 正常文章里也可能出现 `syntax error`（讲编译错误的教程）→ 误杀
    · 只用长度 → 短摘要本身合法（一句话新闻）→ 误杀
    · **同时成立**才算：又短、又长得像框架报错
    """
    t = (s or "").strip()
    if not t:
        return False
    if len(t) > MAX_ERROR_SUMMARY_CHARS:
        return False
    low = t.lower()
    return any(p in low for p in FINGERPRINTS)


#: 🔑 自检用例 —— **与 Rust 侧 `content_fetch.rs` 的测试同一组**。
#: 判据漂移时（有人只改了一侧），脚本启动即报错，而不是静默按错的判据删数据。
_SELF_CHECK_CASES = [
    # (文本, 期望判定)
    ("Liquid syntax error: 'raw' tag was never closed", True),   # 实测真实案例
    ("Template render error: undefined method", True),
    ("An error occurred while rendering this page", True),
    ("Cannot read properties of undefined (reading 'map')", True),
    ("Cannot read property 'x' of null", True),
    ("A short news brief about the economy and jobs.", False),
    ("这里是中文摘要，讲的是同一天发生的两件事。", False),
    # 🔴 互补信号（长度）：长文里出现报错字样**不该**被误杀
    (
        "A long-form engineering write-up. In this post we walk through how we hit a "
        "syntax error while building our parser, why it took three days to find, and what "
        "we changed afterwards to make the failure loud instead of silent.",
        False,
    ),
    ("", False),
]


def self_check() -> None:
    """启动自检 —— 判据与 Rust 侧是否仍一致。"""
    bad = []
    for text, want in _SELF_CHECK_CASES:
        got = is_source_error_summary(text)
        if got != want:
            bad.append((text[:60], want, got))
    if bad:
        print("🔴 自检失败：本脚本的判据与预期不一致 —— **不要继续**。")
        for t, want, got in bad:
            print(f"   · {t!r} 期望 {want} 实际 {got}")
        print()
        print("   📌 最常见原因：有人改了 Rust 侧 `SOURCE_ERROR_FINGERPRINTS`")
        print("      但没同步本脚本的 `FINGERPRINTS`（或反之）。")
        print("      → 两份实现必须一致，否则会「新数据干净、老数据脏」。")
        sys.exit(2)

    # 判据 ②（「正文其实是片段」）也自检 —— 同样要求与 Rust 侧一致
    bad2 = []
    for text, want in _SELF_CHECK_CASES_EXCERPT:
        got = is_excerpt_marker_body(text)
        if got != want:
            bad2.append((text[:60], want, got))
    if bad2:
        print("🔴 自检失败：「片段」判据与预期不一致 —— **不要继续**。")
        for t, want, got in bad2:
            print(f"   · {t[:60]!r} 期望 {want} 实际 {got}")
        print()
        print("   📌 判据在**两处**各有一份实现，必须一致：")
        print("      · Rust：`content_rss.rs` 的 `EXCERPT_MARKERS` / `classify_encoded`")
        print("      · 本脚本：`EXCERPT_MARKERS` / `is_excerpt_marker_body`")
        sys.exit(2)


# ─────────────────────────────────────────────────────────────────────
# 判据 ②：「这段 body 其实是**片段**」（**必须与 Rust 侧一致**）
#
# 🔴 为什么需要它（2026-10-02 · 内容源报告发现）
#
# Ars Technica 的 `content:encoded` 是 **161 词片段**（尾部 `Read full article`），
# 而它的 `description` **是空的** ⇒ Rust 侧原来的相对判据
# `summary=None => 更长的` **恒真** ⇒ 片段被当全文存进 `body`。
#
# 后果（两个都严重）：
#   ① 用户看到的正文尾部直接是 `Read full article` / `Comments`
#   ② `pick_body_candidates` 要求 `body` 为空才补抓 ⇒ **永远不去抓网页全文**
#
# ⇒ Rust 侧已修（`classify_encoded`）；本脚本负责把**已经存进库的**片段迁出来。
#
# ⚠️ 与 Rust 侧判据的**一处有意差异**（别顺手「修」成一样）：
#    Rust 的 `classify_encoded` 有**两道闸**（片段标记 + 长度下限），
#    本脚本**只用片段标记**这一道 —— 因为存量 `body` 可能来自**网页提取**，
#    而**短的正文是合法的**（不是片段）。长度闸只适用于
#    「RSS 的 `content:encoded` 够不够格算全文」这个场景。
#    📌 判据的适用场景不同 ⇒ 不能把闸门照搬。
# ─────────────────────────────────────────────────────────────────────

#: **强标记**：短语级、无歧义 ⇒ **子串**匹配（与 Rust `EXCERPT_MARKERS_STRONG` 一致）
#:
#: 🔴 必须按**子串**匹配 —— 实测 Ars 的形态是标记**紧跟在正文最后一句后面**：
#:    `…they found.Read full article\nComments`
#:    ⇒ 我最初写成「整行匹配」，在真实 fixture 上**一条都认不出来**。
EXCERPT_MARKERS_STRONG: tuple[str, ...] = (
    "read full article",
    "read the full article",
    "read the full story",
    "read the rest of this article",
    "read the complete article",
    "view the full article",
    "continue reading",
)

#: **弱标记**：日常措辞 ⇒ 只在**整行就是它**时才算（与 Rust 侧一致）
EXCERPT_MARKERS_WEAK: tuple[str, ...] = ("read more", "read on", "full story")

#: 片段尾部的噪音行 —— 与 Rust `content_rss::EXCERPT_NOISE_LINES` 一致
EXCERPT_NOISE_LINES: tuple[str, ...] = ("comments", "comment", "share this story")

#: 自检用例（**含真实形态**，见上）
_SELF_CHECK_CASES_EXCERPT: list[tuple[str, bool]] = [
    # ① 🔴 Ars 的**真实**形态：标记紧跟正文（不独立成行）
    (
        "Attempts to see what was in the packets failed.\n"
        "But the traces showed something else.Read full article\nComments",
        True,
    ),
    # ② 标记独立成行
    ("Some teaser text about robots.\n\nRead full article\n\nComments", True),
    # ③ 变体措辞
    ("Teaser one.\nContinue reading", True),
    ("Teaser two.\nRead the full story", True),
    # ④ 🔴 正文里**提到** read more（弱标记，非独立行）⇒ 不是片段
    ("You can read more about this in the appendix. It is a long article.", False),
    # ⑤ 正常全文（无任何标记）⇒ 不是片段
    ("A normal full article body.\n\nWith a second paragraph.", False),
    # ⑥ 空 / 纯空白 ⇒ 不是片段（那是「没有正文」，另一回事）
    ("", False),
    ("   \n  ", False),
]


def has_excerpt_marker(text: str) -> bool:
    """文本里有没有「点这里看全文」标记（强标记按子串、弱标记按整行）。"""
    if not text:
        return False
    low = text.lower()
    if any(m in low for m in EXCERPT_MARKERS_STRONG):
        return True
    return any(l.strip().lower() in EXCERPT_MARKERS_WEAK for l in text.splitlines())


def strip_excerpt_markers(text: str) -> str:
    """剥掉标记与噪音行（**保留正文** —— 标记可能紧跟在正文后面）。"""
    s = text
    for m in EXCERPT_MARKERS_STRONG:
        # 大小写不敏感替换（Python 没有直接的，用 re）
        s = re.sub(re.escape(m), "", s, flags=re.IGNORECASE)
    kept = [
        line.strip()
        for line in s.splitlines()
        if line.strip()
        and line.strip().lower() not in EXCERPT_NOISE_LINES
        and line.strip().lower() not in EXCERPT_MARKERS_WEAK
    ]
    return "\n".join(kept).strip()


def is_excerpt_marker_body(text: str) -> bool:
    """这段 `body` 里有片段标记 ⇒ 它其实是片段，不是全文。

    ⚠️ **只按标记判**（有明确证据），**不加长度闸** —— 存量 `body` 可能来自
       **网页提取**，而**短的正文是合法的**（不是片段）。
       长度闸只适用于「RSS 的 `content:encoded` 够不够格算全文」那个场景。
    """
    if not text or not text.strip():
        return False
    return has_excerpt_marker(text)


# ─────────────────────────────────────────────────────────────────────
# 动作
# ─────────────────────────────────────────────────────────────────────


def action_plan(conn: sqlite3.Connection) -> None:
    """只读：报告影响面（不写任何东西）。"""
    rows = conn.execute(
        "SELECT id, title, summary, body FROM content_pool"
    ).fetchall()
    total = len(rows)

    dirty = [(r[0], r[1], r[2]) for r in rows if r[2] and is_source_error_summary(r[2])]
    with_body = [r for r in rows if r[3] and r[3].strip()]
    no_body = [r for r in rows if not (r[3] and r[3].strip())]
    # 🆕 「body 其实是片段」——这些**不该算有正文**（见 `action_demote_excerpt_bodies`）
    excerpt_bodies = [r for r in with_body if is_excerpt_marker_body(r[3])]
    # ⚠️ 口径必须与 `action_reset_attempted` **完全一致**（含 redistributable 过滤），
    #    否则 plan 报的「重置对象 N 篇」与实际会重置的不是同一批 —— 那正是
    #    「同一件事两处口径」的经典表现（数字看着对，成员对不上）。
    attempted = conn.execute(
        "SELECT COUNT(*) FROM content_pool p "
        "LEFT JOIN content_source s ON s.id = p.source_id "
        "WHERE COALESCE(s.redistributable, 0) = 1 AND p.body_attempted_at IS NOT NULL"
    ).fetchone()[0]
    not_fetchable = conn.execute(
        "SELECT COUNT(*) FROM content_pool p "
        "LEFT JOIN content_source s ON s.id = p.source_id "
        "WHERE COALESCE(s.redistributable, 0) = 0 AND p.body_attempted_at IS NOT NULL"
    ).fetchone()[0]

    print("=" * 70)
    print("内容重抓 · 影响面（只读）")
    print("=" * 70)
    print(f"  全表                    : {total} 篇")
    print(f"  有正文                   : {len(with_body)} 篇  ← 重抓的主要对象（换 Markdown）")
    print(f"  无正文                   : {len(no_body)} 篇  ← ⚠️ 也值得重抓（新提取器可能救回来）")
    if excerpt_bodies:
        print(
            f"  🔴 其中**其实是片段**         : {len(excerpt_bodies)} 篇  "
            f"← 用 `--demote-excerpt-bodies` 迁走（它们不算真正文）"
        )
    print(f"  重置对象（可抓取且试过）   : {attempted} 篇  ← reset 会清这些标记")
    if not_fetchable:
        print(f"  ⚠️ 不可抓取但试过的        : {not_fetchable} 篇（跳过 —— 它们永远不会进候选池）")
    rounds = -(-attempted // 100) if attempted else 0
    print(f"     预估耗时              : {rounds} 轮 × 6h ≈ {rounds * 6} 小时（每轮上限 100 篇）")
    print()
    print(f"🔴 待清理的「源站报错」摘要 : {len(dirty)} 篇")
    for i, (rid, title, summ) in enumerate(dirty[:20]):
        print(f"    id={rid:<6} {str(summ)[:60]!r}")
        print(f"            {str(title)[:60]}")
    if len(dirty) > 20:
        print(f"    …（还有 {len(dirty) - 20} 篇）")
    if not dirty:
        print("    （无 —— 要么源站没给过这类脏数据，要么已经清过了）")
    print()
    print("📌 下一步（按这个顺序 —— 顺序反了会白跑）：")
    print("   ① `--demote-excerpt-bodies --apply`  把「其实是片段」的 body 迁到摘要（幂等）")
    print("   ② 服务开重抓模式：COEVO_REFETCH_BODIES=1（systemd drop-in）+ 重启")
    print("   ③ `--reset-attempted --batch N --apply` 分批清标记（现在能被挑中了）")
    print("   ④ 跑完关掉重抓模式（删 drop-in + 重启）")


def action_clean_summary(conn: sqlite3.Connection, apply: bool) -> None:
    """把「源站报错」形态的 summary 置 NULL（幂等）。"""
    rows = conn.execute("SELECT id, title, summary FROM content_pool WHERE summary IS NOT NULL").fetchall()
    victims = [(r[0], r[1], r[2]) for r in rows if is_source_error_summary(r[2])]

    print(f"待清理：{len(victims)} 篇")
    for rid, title, summ in victims[:20]:
        print(f"    id={rid:<6} {str(summ)[:60]!r}")
    if len(victims) > 20:
        print(f"    …（还有 {len(victims) - 20} 篇）")

    if not victims:
        print("✅ 无需清理（已干净）")
        return

    if not apply:
        print()
        print("⚠️ DRY-RUN：什么都没写。要真写请加 `--apply`。")
        return

    # 🔑 逐条 UPDATE（用 id 定位）而不是「按 LIKE 批量删」——
    #    判据在 Python 侧跑过一遍，就不该再用 SQL 表达式猜一遍（两套判据 = 漂移源）。
    conn.executemany(
        "UPDATE content_pool SET summary = NULL WHERE id = ?",
        [(rid,) for rid, _, _ in victims],
    )
    conn.commit()

    left = conn.execute(
        "SELECT COUNT(*) FROM content_pool WHERE summary IS NOT NULL"
    ).fetchone()[0]
    print(f"✅ 已清理 {len(victims)} 篇（剩余非空 summary {left} 篇）")


def action_demote_excerpt_bodies(conn: sqlite3.Connection, apply: bool) -> None:
    """把「其实是片段」的 `body` 迁到 `summary`，并把 `body` 置空（幂等）。

    # 为什么要迁（而不是留在 `body`）

    `body` 的语义是**全文**。它被填上一个片段会造成两件事：
    · 上层无法区分「拿到全文」与「只拿到片段」
    · `pick_body_candidates` 要求 `body` 为空才补抓 ⇒ **永远不去抓网页全文**

    # 迁成什么样

    | 列 | 迁移前 | 迁移后 |
    |---|---|---|
    | `body` | 片段（含 `Read full article`）| **NULL** |
    | `summary` | 14 词导读 | **片段**（已剥标记）—— 取更有用的那个 |
    | `body_attempted_at` | 已设 | **NULL**（重新进候选队列）|

    ⚠️ **`body_attempted_at` 也清** —— 否则 `body` 空了但「已试过」还在 ⇒ 仍然不会被抓。
       📌 判据：**改「内容列」时要连带检查「控制流列」** —— 两者是一件事的两半。

    ⚠️ 与 [`better_summary`]（Rust 侧）同口径：**明显更长才替换源摘要** ——
       否则 NPR 那种「两者本来就一样」的情况会无谓地换掉源摘要。
    """
    rows = conn.execute(
        "SELECT id, title, summary, body FROM content_pool "
        "WHERE body IS NOT NULL AND body <> ''"
    ).fetchall()
    victims = [r for r in rows if is_excerpt_marker_body(r[3])]

    print(f"待迁移（body 里有片段标记）：{len(victims)} 篇  /  有正文总数 {len(rows)} 篇")
    for rid, title, summ, body in victims[:15]:
        print(f"    id={rid:<6} body={len(body):>6}B → 摘要={len(summ or '')}B  {str(title)[:44]}")
    if len(victims) > 15:
        print(f"    …（还有 {len(victims) - 15} 篇）")

    if not victims:
        print("✅ 无需迁移（已干净）")
        return

    if not apply:
        print()
        print("⚠️ DRY-RUN：什么都没写。要真写请加 `--apply`。")
        return

    moved_summary = 0
    for rid, _title, summ, body in victims:
        cleaned = strip_excerpt_markers(body)
        # 与 Rust `better_summary` 同口径：片段**明显更长**才替换源摘要
        use_excerpt = bool(cleaned)
        if summ and summ.strip() and cleaned:
            dw = len(summ.split())
            ew = len(cleaned.split())
            if not (ew >= dw * 2 and ew - dw >= 50):
                use_excerpt = False
        new_summary = cleaned if use_excerpt else (summ if summ and summ.strip() else cleaned)
        if not (summ and summ.strip()):
            moved_summary += 1
        conn.execute(
            "UPDATE content_pool SET body = NULL, summary = ?1, body_attempted_at = NULL "
            "WHERE id = ?2",
            (new_summary, rid),
        )
    conn.commit()

    left = conn.execute(
        "SELECT COUNT(*) FROM content_pool WHERE body IS NOT NULL AND body <> ''"
    ).fetchone()[0]
    print(f"✅ 已迁移 {len(victims)} 篇（其中 {moved_summary} 篇的摘要由片段兜底）")
    print(f"   剩余有正文 {left} 篇 · 它们的 `body_attempted_at` 已清 → 会重新进候选队列")
    print()
    print("📌 下一步：确认服务开了重抓模式（COEVO_REFETCH_BODIES=1），否则它们仍不会被挑中")


def action_reset_attempted(conn: sqlite3.Connection, batch: int, apply: bool) -> None:
    """分批清 `body_attempted_at`，让存量重新进候选队列。"""
    # 🔑 两个条件都必须与 `pick_body_candidates` 的 WHERE **对齐**：
    #    · `redistributable = 1` —— 否则会重置「永远不会被挑中」的条目：
    #      标记被清掉，但下一轮 SQL 又按 `redistributable` 把它过滤掉
    #      → 一次**无意义的状态变更**（而且是静默的）。
    #      📌 判据：**重置「候选资格」时，条件要与「挑候选」的条件同源**。
    #      ⚠️ 实测（2026-10-02）当前生产库 269 篇**全是** r=1 —— 所以这条现在不改变结果；
    #         加它是为了让「将来出现 r=0 的源」时行为仍正确。
    #    · `body_attempted_at IS NOT NULL` —— 只重置**试过的**（没试过的本来就在队列里）
    #    排序：**按发布时间倒序**（先重抓用户最可能读到的新文章）—— 与 `pick_body_candidates` 一致，
    #    避免两处口径不同（否则「先重置的」与「先被挑中的」不是同一批，分批节奏会乱）。
    rows = conn.execute(
        "SELECT p.id, p.title FROM content_pool p "
        "LEFT JOIN content_source s ON s.id = p.source_id "
        "WHERE COALESCE(s.redistributable, 0) = 1 AND p.body_attempted_at IS NOT NULL "
        "ORDER BY COALESCE(p.published_at, p.fetched_at) DESC LIMIT ?",
        (batch,),
    ).fetchall()

    total_pending = conn.execute(
        "SELECT COUNT(*) FROM content_pool p "
        "LEFT JOIN content_source s ON s.id = p.source_id "
        "WHERE COALESCE(s.redistributable, 0) = 1 AND p.body_attempted_at IS NOT NULL"
    ).fetchone()[0]

    print(f"本轮将重置：{len(rows)} 篇（当前待重置总数 {total_pending} 篇）")
    for rid, title in rows[:20]:
        print(f"    id={rid:<6} {str(title)[:60]}")
    if len(rows) > 20:
        print(f"    …（还有 {len(rows) - 20} 篇）")
    print()
    print(f"📌 重置后它们会重新进入 `pick_body_candidates` 的候选池；")
    print(f"   而抓取循环每轮**本来就有**上限（100 篇）→ 天然是分批的。")
    print(f"   剩余 {max(0, total_pending - len(rows))} 篇请在本轮抓完后再跑一次本命令。")

    if not rows:
        print("✅ 无需重置（都还没抓过，或已全部重置）")
        return

    if not apply:
        print()
        print("⚠️ DRY-RUN：什么都没写。要真写请加 `--apply`。")
        return

    conn.executemany(
        "UPDATE content_pool SET body_attempted_at = NULL WHERE id = ?",
        [(rid,) for rid, _ in rows],
    )
    conn.commit()
    left = conn.execute(
        "SELECT COUNT(*) FROM content_pool WHERE body_attempted_at IS NOT NULL"
    ).fetchone()[0]
    print(f"✅ 已重置 {len(rows)} 篇（剩余待重置 {left} 篇）")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="内容管线重抓：清理脏 summary + 重置抓取标记",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--db", required=True, help="coevo.db 路径")
    ap.add_argument("--plan", action="store_true", help="只读：报告影响面")
    ap.add_argument("--clean-summary", action="store_true", help="清「源站报错」摘要")
    ap.add_argument(
        "--demote-excerpt-bodies",
        action="store_true",
        help="把「其实是片段」的 body 迁到 summary 并置空 body（见该函数的说明）",
    )
    ap.add_argument("--reset-attempted", action="store_true", help="分批清抓取标记")
    ap.add_argument("--batch", type=int, default=100, help="--reset-attempted 每批篇数")
    ap.add_argument("--apply", action="store_true", help="真写库（默认 dry-run）")
    args = ap.parse_args()

    if not (
        args.plan
        or args.clean_summary
        or args.demote_excerpt_bodies
        or args.reset_attempted
    ):
        ap.print_help()
        sys.exit(1)

    # 🔴 先自检判据（与 Rust 侧是否仍一致）—— 判据错了会静默删错数据
    self_check()

    if not os.path.exists(args.db):
        print(f"🔴 库不存在: {args.db}")
        sys.exit(2)

    # ⚠️ 用**只读**连接做 plan；写操作用读写连接。
    #    （只读 URI 拼错会「静默建一个空库」—— 见 memory 判据库，
    #     所以这里对「文件存在」先显式检查了一次。）
    if args.plan and not (
        args.clean_summary or args.demote_excerpt_bodies or args.reset_attempted
    ):
        conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
        try:
            action_plan(conn)
        finally:
            conn.close()
        return

    conn = sqlite3.connect(args.db)
    try:
        # 写操作前也先出一次影响面（避免「不看就改」）
        action_plan(conn)
        print()
        if args.clean_summary:
            print("─" * 70)
            print("【动作】清理「源站报错」摘要")
            action_clean_summary(conn, args.apply)
        if args.demote_excerpt_bodies:
            print("─" * 70)
            print("【动作】把「其实是片段」的正文迁到摘要")
            action_demote_excerpt_bodies(conn, args.apply)
        if args.reset_attempted:
            print("─" * 70)
            print("【动作】分批重置抓取标记")
            action_reset_attempted(conn, args.batch, args.apply)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
