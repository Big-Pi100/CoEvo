#!/usr/bin/env python3
"""搭配解析（`related_phrases` → 结构化 phrase/chinese）

背景（2026-09-26 P2-12，此前审计连错两轮才定位）：
  现网 `prebuilt_language_cards.related_phrases` **两种格式并存**，而解析器只支持一种：

    **格式 A（共享尾部括号）**
      `let it be, be that as it may, be yourself（顺其自然，尽管如此，做你自己）`
      → 英文段用半角 `,` 分隔；中文只有一组括号，在**末尾**，内部用全角 `，` 分

    **格式 B（每段自带括号）**
      `blue sky（蓝天）, out of the blue（出乎意料）`
      → 每段自带括号，括号内即该段中文

  旧解析器（「第一个 `（` 为界 / 逗号分英文 / 全角逗号分中文」）在**格式 B 上完全错位**：
      `blue sky（蓝天）, out of the blue（出乎意料）`
      → EN=`blue sky` / ZH=`蓝天）, out of the blue（出乎意料`   🔴 张冠李戴
  全库 14,352 行中错位 **2,021 行 = 14.1%**。

本脚本：
  · 双格式兼容解析（先顶层切分 → 每段提取括号 → 判定共享/独立）
  · 括号内**不再切分**（防嵌套错位）
  · 中英条目数**不等时整条标记 mismatch**，不强行配对（避免再造错位）
  · 全库跑出统计 + mismatch 清单，产出 `collocation_parsed.json`

用法：
  python3 scripts/parse_related_phrases.py --dry-run   # 只统计，不写文件
  python3 scripts/parse_related_phrases.py             # 产出 JSON
"""
import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

DB = cwc.DB
OUT = os.path.join(cwc.PREBUILT, 'collocation_parsed.json')

OPEN_PARENS = '（(【['
CLOSE_PARENS = '）)】]'
EN_SEPS = ',，、;；'
# 🔴 中文**项间**分隔符只认 `，` 和 `,` ——
#    不能用 `；`/`;`/`、`：它们在中文里多为**项内**的补充/同义连接
#    （实测 `未经雕琢的钻石；璞玉` 是一项，切成两项会造成假 MISMATCH）
ZH_ITEM_SEPS = '，,'
# 尾注（`[注：…]` / `[Note: …]`）—— 不属于中文释义，解析前剥离
TAIL_NOTE = re.compile(r'\s*[\[【](注|Note|说明)[：:][^\]】]*[\]】]\s*$', re.I)


def split_top(s: str, seps=EN_SEPS):
    """按**顶层**分隔符切分（括号内的分隔符不切）"""
    out, buf, depth = [], '', 0
    for ch in s:
        if ch in OPEN_PARENS:
            depth += 1
            buf += ch
        elif ch in CLOSE_PARENS:
            depth = max(0, depth - 1)
            buf += ch
        elif depth == 0 and ch in seps:
            out.append(buf)
            buf = ''
        else:
            buf += ch
    out.append(buf)
    return [x.strip() for x in out if x.strip()]


TAIL_PAREN = re.compile(r'[（(]([^（()）]*)[）)]\s*$')
ANY_PAREN = re.compile(r'[（(]([^（()）]*)[）)]')


def take_paren(seg: str):
    """→ (短语, 括号内中文)

    🔑 用**配对法**从段尾回溯，支持**嵌套括号**：
       `apron strings（厨房围裙，围裙带（喻依赖））`
       → 短语=`apron strings`，中文=`厨房围裙，围裙带（喻依赖）`
       正则 `[^（()）]*` 会在内层括号处停住 → 中文被截断成 `喻依赖`（实测踩坑）。
    """
    s = seg.rstrip()
    if not s or s[-1] not in CLOSE_PARENS:
        # 末尾不是括号 → 退化为「取第一组括号」
        m = ANY_PAREN.search(s)
        if not m:
            return s.strip(), ''
        phrase = (s[:m.start()] + s[m.end():]).strip(' ,，、;；')
        return phrase, m.group(1).strip()

    depth = 0
    for i in range(len(s) - 1, -1, -1):
        ch = s[i]
        if ch in CLOSE_PARENS:
            depth += 1
        elif ch in OPEN_PARENS:
            depth -= 1
            if depth == 0:
                phrase = s[:i].strip(' ,，、;；')
                return phrase, s[i + 1:-1].strip()
    return s.strip(), ''


def parse_related_phrases(s: str):
    """双格式兼容解析 → (items, status)

    items: [{'phrase': str, 'chinese': str}]
    status:
      'A'         共享尾部括号（含中文内嵌括号）
      'B'         每段自带括号
      'B_PARTIAL' 部分段无中文
      'F'         无中文（仅英文短语）
      'MISMATCH'  末段括号内中文数与英文段数不等（不再强配）
      'EMPTY'     空串
    """
    if not s or not s.strip():
        return [], 'EMPTY'

    s = TAIL_NOTE.sub('', s.strip())
    segs = split_top(s)
    if not segs:
        return [], 'EMPTY'

    parsed, with_paren = [], []
    for seg in segs:
        phrase, zh = take_paren(seg)
        parsed.append({'phrase': phrase, 'chinese': zh})
        if zh:
            with_paren.append(len(parsed) - 1)

    # ── 无任何括号 → 只有英文短语 ──
    if not with_paren:
        return parsed, 'F'

    # ── 单段（无英文分隔符）→ 括号内整体即中文，无需按数量配对 ──
    if len(parsed) == 1:
        return parsed, 'A'

    # ── 只有**最后一段**有括号 → 格式 A（共享尾部）──
    if len(with_paren) == 1 and with_paren[0] == len(parsed) - 1:
        inner = parsed[-1]['chinese']
        zhs = split_top(inner, ZH_ITEM_SEPS)
        if len(zhs) == len(parsed):
            for i, z in enumerate(zhs):
                parsed[i]['chinese'] = z
            return parsed, 'A'
        if len(zhs) < len(parsed):
            # 🟠 中文数 < 英文段数 → **前缀按序配对**（保住能确定的信息，不整条丢弃）
            for i, z in enumerate(zhs):
                parsed[i]['chinese'] = z
            return parsed, 'A_PARTIAL'
        # 中文数 > 英文段数 → 无法可靠配对
        return parsed, 'MISMATCH'

    # ── 多段自带括号（格式 B）或者混合 ──
    n_zh = sum(1 for p in parsed if p['chinese'])
    return parsed, ('B' if n_zh == len(parsed) else 'B_PARTIAL')


def old_parse(s: str):
    """复现旧解析器的行为（用于对照，证明修复价值）

    旧逻辑：以**第一个** `（` 为界 → 左边按 `,` 分英文 → 右边按 `，` 分中文 → 按序 zip。
    """
    if not s:
        return []
    m = re.search(r'[（(]', s)
    if not m:
        return [(x.strip(), '') for x in re.split(r'[,，、]', s) if x.strip()]
    en = s[:m.start()]
    zh = s[m.start():]
    zh = re.sub(r'^[（(]|[）)]$', '', zh)
    ens = [x.strip() for x in re.split(r'[,，]', en) if x.strip()]
    zhs = [x.strip() for x in re.split(r'[,，]', zh) if x.strip()]
    return list(zip(ens, zhs + [''] * (len(ens) - len(zhs))))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    con = sqlite3.connect(DB)
    rows = list(con.execute("""
        SELECT c.front, l.related_phrases FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
          AND l.related_phrases IS NOT NULL AND l.related_phrases <> ''
    """))
    con.close()

    stat = Counter()
    mismatch, all_items = [], []
    old_bad = []

    for word, s in rows:
        items, st = parse_related_phrases(s)
        stat[st] += 1
        for it in items:
            if it['phrase']:
                all_items.append({'word': word, **it})

        if st == 'MISMATCH':
            mismatch.append({'word': word, 'raw': s[:160],
                             'parsed': items})

        # 对照旧解析：**直接比较新旧结果集**
        #   （旧逻辑「以第一个 `（` 为界」在**格式 B** 上只产出 1 段且中文带残留 `）`
        #     —— 之前的「段数不等」判据会漏掉它们，故改为逐对比较）
        old = [(p, z) for p, z in old_parse(s)]
        new = [(p['phrase'], p['chinese']) for p in items]
        if old != new:
            old_bad.append({'word': word, 'raw': s[:120],
                            'old': old[:3], 'new': items[:3]})

    total = len(rows)
    print(f'解析 {total} 行（非空 related_phrases）')
    print()
    print('=== 格式分布（新解析器）===')
    label = {'A': '格式A 共享尾部括号', 'A_PARTIAL': 'A 中文数少于英文段（前缀配对）',
             'B': '格式B 每段自带括号',
             'B_PARTIAL': 'B 部分段无中文', 'F': 'F 无中文（仅英文短语）',
             'MISMATCH': '🔴 中文数多于英文段（无法配）'}
    for k, v in stat.most_common():
        print(f'  {label.get(k, k):<28}{v:>7}  {v/total*100:5.1f}%')
    print()
    print(f'=== 产出 ===')
    print(f'  短语条目总数        : {len(all_items)}')
    print(f'  有中文的            : {sum(1 for i in all_items if i["chinese"])}')
    print(f'  唯一短语(不分词)    : {len({i["phrase"].lower() for i in all_items})}')
    print()
    print(f'=== 🔴 旧解析器错位（对照）===')
    print(f'  会错位的行数        : {len(old_bad)}  = {len(old_bad)/total*100:.1f}%')
    for x in old_bad[:6]:
        print(f'    {x["word"]:<14} 原文={x["raw"][:70]}')
        print(f'     旧: {x["old"][:2]}')
        print(f'     新: {[{k: v for k, v in i.items() if k != "word"} for i in x["new"][:2]]}')
    print()
    if mismatch:
        print(f'=== 中英数不等清单（{len(mismatch)} 条，人工判）===')
        for x in mismatch[:10]:
            print(f'    {x["word"]:<14} {x["raw"][:90]}')
            print(f'      → {x["parsed"]}')

    if args.dry_run:
        print('\n（--dry-run，未写文件）')
        return

    json.dump({'source': 'coevo.db', 'total_rows': total,
               'format': dict(stat), 'items': all_items,
               'mismatch': mismatch},
              open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'\n  已写 {OUT}')


if __name__ == '__main__':
    main()
