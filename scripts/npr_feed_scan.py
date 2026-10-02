#!/usr/bin/env python3
"""扫描 NPR feed ID 段 → 「ID → 频道」事实表。

# 🔴 为什么需要它

NPR 用**数字 ID** 暴露几十个分频道（`feeds.npr.org/<id>/rss.xml`），
而**官方目录页实测全 404**（`npr.org/rss/` · `/about-npr/.../rss-feeds` ·
`help.npr.org/rss-feeds` · `feeds.npr.org/` 都是 404）⇒ 没有权威清单可查。

结果就是**每要一个类，就一个一个 ID 去试**（本项目已这样试过两轮：补
`culture`/`health` 时试了 6 个，补 `sports`/`entertainment` 时又试了一遍）。
这个脚本把「试」变成**一次全扫 + 事实表**。

# 📌 判据（都是踩出来的）

1. 🔴 **ID → 频道名必须由 `<title>` 确认** —— 不能凭「这家有 X 频道」推断。
   （实例：凭记忆直连 `1045` 期望是 Movies，拿到**空 body**，差点判「不存在」。）
2. 🔴 **单次空 body 不足以判「不存在」** —— 可能是瞬时失败。
   本脚本对空 body 会**重试一次**再定性。
3. 🔑 **「活跃度」比「有没有条目」更重要** —— NPR 里大量 ID 是**历史 topic**
   （`Election 2008` / `Iraq` / `Summer Reading 2006`），条目还在但**早已停更**。
   只数 `items` 会把它们当成可用源。
   ⇒ 看**首条 `pubDate`**：`> STOP_DAYS`（默认 365）天 = **事实上停更**。

# 用法

```bash
python scripts/npr_feed_scan.py                    # 默认扫 1000-1300
python scripts/npr_feed_scan.py --start 1 --end 999   # 低段（老 ID）
python scripts/npr_feed_scan.py --out docs/review/npr-feed-catalog.md
```

⚠️ 只读：只发 HTTP 请求，不碰任何数据库。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import email.utils
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

UA = "Mozilla/5.0 (compatible; CoEvoBot/1.0)"
FEED = "https://feeds.npr.org/{}/rss.xml"

#: 首条 pubDate 超过这么多天 → 判「事实上停更」（不是「不可用」，是「不再更新」）
STOP_DAYS = 365


def _fetch(url: str, retries: int = 2) -> str | None:
    """取正文；失败或空 body 时重试。

    🔑 空 body 也重试 —— `1045` 首次请求返回过空 body，
       重试就正常了（见判据 2）。
    """
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=15) as r:
                data = r.read().decode("utf-8", "replace")
            if data.strip():
                return data
        except Exception:
            pass
        if attempt + 1 < retries:
            import time

            time.sleep(1.5)
    return None


def _strip_cdata(s: str) -> str:
    """剥 CDATA 包装。

    🔴 必须剥 —— 忘了剥会让 `title` 带上 `]]>`，
       上一轮「句末完整」判据就栽在这（报出假 0%，与真实 0% 混淆）。
    """
    return re.sub(r"<!\[CDATA\[|\]\]>", "", s).strip()


def probe(fid: int) -> dict:
    out = {"id": fid, "title": "", "items": 0, "latest": None, "bytes": 0, "err": ""}
    raw = _fetch(FEED.format(fid))
    if raw is None:
        out["err"] = "无响应/空 body（重试后仍失败）"
        return out
    out["bytes"] = len(raw)

    m = re.search(r"<title>(.*?)</title>", raw, re.S)
    out["title"] = _strip_cdata(m.group(1)) if m else "(无 title)"
    out["items"] = raw.count("<item>")

    dates = re.findall(r"<pubDate>(.*?)</pubDate>", raw, re.S)
    for d in dates:
        try:
            dt = email.utils.parsedate_to_datetime(_strip_cdata(d))
        except Exception:
            continue
        if dt is None:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        if out["latest"] is None or dt > out["latest"]:
            out["latest"] = dt
    return out


def age_days(dt: datetime | None) -> float | None:
    if dt is None:
        return None
    return (datetime.now(timezone.utc) - dt).total_seconds() / 86400


def status_of(r: dict) -> str:
    if r["err"]:
        return "❌ 无效"
    if r["items"] == 0:
        return "⚪ 无条目"
    a = age_days(r["latest"])
    if a is None:
        return "⚪ 无日期"
    if a <= 30:
        return "✅ 活跃"
    if a <= STOP_DAYS:
        return "🟡 低频"
    return "🔴 停更"


def main() -> int:
    ap = argparse.ArgumentParser(description="扫描 NPR feed ID 段")
    ap.add_argument("--start", type=int, default=1000, help="起始 ID（含）")
    ap.add_argument("--end", type=int, default=1300, help="结束 ID（含）")
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--out", default="", help="markdown 输出路径（留空则只打屏）")
    ap.add_argument(
        "--only-valid",
        action="store_true",
        help="只输出有 title 的（过滤掉无效 ID，看长表时有用）",
    )
    args = ap.parse_args()

    ids = list(range(args.start, args.end + 1))
    rows: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        for r in ex.map(probe, ids):
            rows.append(r)
    rows.sort(key=lambda r: r["id"])

    shown = [r for r in rows if not args.only_valid or not r["err"]]

    lines: list[str] = []
    lines.append(f"# NPR feed ID 目录扫描（{args.start}–{args.end}）")
    lines.append("")
    lines.append(f"_扫描时间：{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} · "
                 f"共 {len(ids)} 个 ID · 有效 {sum(1 for r in rows if not r['err'])} 个_")
    lines.append("")
    lines.append("| ID | 频道名 | 条目 | 首条日期 | 距今 | 状态 |")
    lines.append("|---|---|---|---|---|---|")
    for r in shown:
        a = age_days(r["latest"])
        lines.append(
            "| {} | {} | {} | {} | {} | {} |".format(
                r["id"],
                r["title"].replace("|", "\\|") or r["err"],
                r["items"] if not r["err"] else "—",
                r["latest"].strftime("%Y-%m-%d") if r["latest"] else "—",
                f"{a:.0f} 天" if a is not None else "—",
                status_of(r),
            )
        )
    text = "\n".join(lines) + "\n"

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"已写入 {args.out}", file=sys.stderr)

    # 摘要：按「频道名」列出**活跃**的（这才是可用的候选）
    active = [r for r in rows if status_of(r) == "✅ 活跃"]
    low = [r for r in rows if status_of(r) == "🟡 低频"]
    print(f"\n=== ✅ 活跃（30 天内更新，共 {len(active)} 个）===")
    for r in sorted(active, key=lambda r: r["title"]):
        print(f"  {r['id']:>5}  {r['items']:>3} 条  {r['title']}")
    print(f"\n=== 🟡 低频（30–{STOP_DAYS} 天，共 {len(low)} 个）===")
    for r in sorted(low, key=lambda r: r["title"]):
        print(f"  {r['id']:>5}  {r['items']:>3} 条  {r['title']}")
    stop = [r for r in rows if status_of(r) == "🔴 停更"]
    print(f"\n（🔴 停更 {len(stop)} 个 · ⚪ 无条目 {sum(1 for r in rows if status_of(r) == '⚪ 无条目')} 个"
          f" · ❌ 无效 {sum(1 for r in rows if r['err'])} 个）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
