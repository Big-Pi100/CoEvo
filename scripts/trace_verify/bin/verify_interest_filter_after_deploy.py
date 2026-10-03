#!/usr/bin/env python3
"""部署后验证：`/api/feed` 的 category 多值筛选（只读）。

跑法（在 VPS 上执行）：
    ssh -i ~/.ssh/coevo_key ubuntu@<vps> "python3 -" < scripts/trace_verify/bin/verify_interest_filter_after_deploy.py

# 🔑 为什么用「算术关系」当证据（而不是只看「非 0 就算通过」）

「多值返回非 0」只能证明「没坏」，不能证明「对」。本脚本用三条**可验算**的关系：

  ① **并集关系**：`total(tech,science) == total(tech) + total(science)`
     —— 依据：每个条目**只属于一个** category（互斥）⇒ 并集 = 各自之和。
     ⚠️ 若哪天出现「一条属于多类」（如跨类栏目），这条会红 —— **那正是要提醒的**。
  ② **分页自洽**：`len(fetch_all) == total`
     —— 这同时验证 `items` 与 `total` **两条 SQL 用的是同一个条件**
     （不同步时 `total` 会偏大 ⇒ 端侧 `hasMore` 恒真 ⇒ 无限上拉，且**不报错**）。
  ③ **失败路径正确**：全非法值 ⇒ **0**，而不是「不筛」的 990
     —— 「没传」与「传了但全非法」必须是两种结果（混淆 = 静默的行为反转）。
"""
import json
import sys
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8300/api/feed"

_pass = 0
_fail = 0
_failures = []


def check(label, ok, detail=""):
    global _pass, _fail
    if ok:
        _pass += 1
        print(f"  ✅ {label}{'' if not detail else '  (' + detail + ')'}")
    else:
        _fail += 1
        _failures.append(f"{label}  {detail}")
        print(f"  🔴 {label}{'' if not detail else '  (' + detail + ')'}")


def fetch(category=None, limit=1, offset=0):
    """返回 (total, items)。category=None ⇒ 不传该参数。"""
    q = f"?limit={limit}&offset={offset}"
    if category is not None:
        q += f"&category={urllib.parse.quote(category)}"
    with urllib.request.urlopen(BASE + q, timeout=10) as r:
        d = json.loads(r.read().decode("utf-8"))
    return d.get("total"), d.get("items", [])


def total_of(category=None):
    return fetch(category, limit=1)[0]


def main():
    print("CoEvo 兴趣筛选（category 多值）部署后验证 · 只读")
    print("=" * 70)

    # ── 【1】单值基线（应与部署前逐字相同）──────────────────────
    print("\n【1】单值行为（向后兼容：必须与部署前一致）")
    t_none = total_of(None)
    t_empty = total_of("")
    t_tech = total_of("tech")
    t_sci = total_of("science")
    check("不传 category ⇒ 全部", t_none > 0, f"total={t_none}")
    check("空串 category ⇒ 同「不传」（不筛）", t_empty == t_none,
          f"空串={t_empty} 不传={t_none}")
    check("单值 tech 有内容", t_tech > 0, f"total={t_tech}")
    check("单值 science 有内容", t_sci > 0, f"total={t_sci}")
    check("单值互不相等（说明确实在筛）", t_tech != t_none and t_sci != t_none)

    # ── 【2】🔴 多值 = 并集（核心）──────────────────────────────
    print("\n【2】🔴 多值：total 应 = 各单值之和（category 互斥 ⇒ 并集）")
    t_multi = total_of("tech,science")
    expect = t_tech + t_sci
    check("🔴 total(tech,science) == total(tech) + total(science)",
          t_multi == expect,
          f"{t_multi} == {t_tech} + {t_sci} = {expect}")

    # 顺序无关：两个顺序必须**同一个数**
    t_rev = total_of("science,tech")
    check("🔴 顺序无关（science,tech 与 tech,science 同值）",
          t_rev == t_multi, f"{t_rev} vs {t_multi}")

    # 三项
    t_three = total_of("tech,science,news")
    t_news = total_of("news")
    check("🔴 三项 = 三个单值之和",
          t_three == t_tech + t_sci + t_news,
          f"{t_three} == {t_tech}+{t_sci}+{t_news} = {t_tech + t_sci + t_news}")

    # 重复 / 空白 / 大小写 ⇒ 归一化后等价
    check("重复值去重（tech,tech == tech）", total_of("tech,tech") == t_tech)
    check("空白容忍（' tech ' == tech）", total_of(" tech ") == t_tech)
    check("🔴 大小写归一（TECH == tech）", total_of("TECH") == t_tech)

    # ── 【3】🔴 区分「没传」与「全非法」────────────────────────
    print("\n【3】🔴 「没传」与「全非法」必须是**两种**结果")
    t_bad = total_of("xyz")
    check("🔴 全非法 ⇒ 0（空结果），**不是** 990（不筛）",
          t_bad == 0, f"total={t_bad}（若=990 则说明混淆了两种语义）")
    check("混入非法值 ⇒ 非法部分被丢弃（tech,xyz == tech）",
          total_of("tech,xyz") == t_tech,
          f"{total_of('tech,xyz')} vs {t_tech}")
    check("通配符不是合法值（* ⇒ 0，本项目不支持 *）",
          total_of("*") == 0, f"total={total_of('*')}")
    # 注入尝试：应被白名单挡掉 ⇒ 空结果（且不该报 500）
    check("注入尝试 ⇒ 0 且不崩（白名单过滤生效）",
          total_of("'; DROP TABLE content_pool;--") == 0)

    # ── 【4】🔴 分页自洽（验证 items 与 total 两条 SQL 同步）────
    print("\n【4】🔴 分页自洽：实际能取到的条数 == total")
    for cat in ["tech", "tech,science", "xyz"]:
        t, _ = fetch(cat, limit=1)
        if t == 0:
            check(f"『{cat}』total=0 ⇒ 不需翻页", True)
            continue
        # 取满（分页拉）
        got = []
        off = 0
        while True:
            t2, items = fetch(cat, limit=50, offset=off)
            got.extend(items)
            off += 50
            if len(items) < 50 or off > t + 100:
                break
        check(f"🔴 『{cat}』能取到 == total（{t}）",
              len(got) == t, f"实取 {len(got)} · total={t}")

    # ── 【5】返回的条目确实在筛选范围内 ────────────────────────
    print("\n【5】返回条目确实属于所选分类")
    _, items = fetch("tech,science", limit=50)
    cats = sorted({(it.get("category") or "") for it in items})
    check("🔴 只返回 tech / science（无其它分类漏进来）",
          set(cats) <= {"tech", "science"}, f"实得 {cats}")

    _, items_none = fetch(None, limit=50)
    cats_none = sorted({(it.get("category") or "") for it in items_none})
    check("不筛时分类更多样（说明筛选确实在起作用）",
          len(cats_none) >= len(cats), f"不筛 {cats_none} vs 筛后 {cats}")

    # ── 汇总 ──────────────────────────────────────────────────
    print()
    print("=" * 70)
    print(f"  通过 {_pass} 项 · 失败 {_fail} 项")
    print("=" * 70)
    if _fail:
        print("🔴 失败清单：")
        for f in _failures:
            print("    ·", f)
        return 1
    print("✅ 全部通过 —— 退出码 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
