#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
核查「记忆法全不可用」的词 —— 它们的 ③ 释义 / ④ 语境 是否完整。

口径（与 mnemonic-layer-separation-2026-09-26.md §3.1 一致）：
  可拆 root  = word_morpheme 里存在 type='root' 的记录
  有词源    = word.etymology_text 非空（含整体借词）
  → 两者皆无 = 记忆法全不可用（collocation 待判、image 无数据源，均不计）

核查项：
  zh_ok    sections 里至少一条 sense 的 zh 非空
  ex_ok    sections 里至少一条 sense 的 example 非空
  ipa_ok   card.ipa 非空
"""
import json
import re
import sqlite3
import sys
from collections import Counter

DB = r"E:\CoEvo\data\word.db"


def main() -> int:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row

    # ---- 1. 判定可拆 / 有词源 ---------------------------------------------
    decomposable = {
        r[0] for r in con.execute(
            "SELECT DISTINCT word_id FROM word_morpheme WHERE type='root'")
    }

    rows = con.execute("""
        SELECT w.id, w.spelling, w.cefr_level, w.entry_type, w.etymology_text,
               c.content, c.template_code
        FROM word w LEFT JOIN card c ON c.word_id = w.id
    """).fetchall()

    no_mnem = []
    for r in rows:
        if r["id"] in decomposable:
            continue
        if (r["etymology_text"] or "").strip():
            continue
        no_mnem.append(r)

    # ---- 2. 逐词核查 ③④ --------------------------------------------------
    stat = Counter()
    bad = []
    for r in no_mnem:
        content = r["content"]
        if not content:
            stat["no_card"] += 1
            bad.append((r["spelling"], "无 card 行", "", ""))
            continue
        try:
            data = json.loads(content)
        except Exception:
            stat["bad_json"] += 1
            bad.append((r["spelling"], "card JSON 解析失败", "", ""))
            continue

        sections = data.get("sections") or []
        senses = [s for s in sections if s.get("type") == "sense"]
        zh = next((s.get("zh") for s in senses if (s.get("zh") or "").strip()), "")
        ex = next((s.get("example") for s in senses if (s.get("example") or "").strip()), "")
        ipa = (data.get("ipa") or "").strip()

        if not senses:
            stat["no_sense"] += 1
        if zh:
            stat["zh_ok"] += 1
        else:
            stat["zh_missing"] += 1
        if ex:
            stat["ex_ok"] += 1
        else:
            stat["ex_missing"] += 1
        if ipa:
            stat["ipa_ok"] += 1

        if not zh or not ex:
            bad.append((r["spelling"], "" if zh else "缺释义",
                        "" if ex else "缺例句", ipa))

    total = len(no_mnem)
    print(f"记忆法全不可用的词：{total}")
    print(f"  有释义 : {stat['zh_ok']:5d}  缺释义: {stat['zh_missing']}")
    print(f"  有例句 : {stat['ex_ok']:5d}  缺例句: {stat['ex_missing']}")
    print(f"  有音标 : {stat['ipa_ok']:5d}")
    print(f"  无 card 行 / JSON 坏: {stat['no_card']} / {stat['bad_json']}")
    print()

    if bad:
        print(f"--- ③④ 不完整（{len(bad)} 条）---")
        for w, a, b, ipa in bad:
            print(f"  {w:22s} {a} {b}")
    else:
        print("--- ③④ 全部完整，无「四段全空」风险 ---")

    # ---- 3. 这 116 词都是什么词 ------------------------------------------
    print()
    print("--- 词形特征分布 ---")
    feat = Counter()
    for r in no_mnem:
        s = r["spelling"]
        if " " in s:
            feat["含空格(多词)"] += 1
        elif re.search(r"[A-Z]", s):
            feat["含大写(专名)"] += 1
        elif not s.isalpha():
            feat["非纯字母"] += 1
        elif len(s) <= 3:
            feat["≤3 字母"] += 1
        else:
            feat["普通小写词"] += 1
    for k, v in feat.most_common():
        print(f"  {k:16s} {v}")

    print()
    print("--- entry_type 分布 ---")
    for k, v in Counter((r["entry_type"] or "(null)") for r in no_mnem).most_common():
        print(f"  {k:16s} {v}")

    print()
    print("--- CEFR 分布 ---")
    for k, v in Counter((r["cefr_level"] or "(null)") for r in no_mnem).most_common():
        print(f"  {k:16s} {v}")

    print()
    print("--- 全部词表 ---")
    words = sorted(r["spelling"] for r in no_mnem)
    for i in range(0, len(words), 8):
        print("  " + "  ".join(f"{w:16s}" for w in words[i:i + 8]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
