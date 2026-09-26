#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 #2 · 中文内联拆分 —— 把混在英文释义里的中文提取到 `chinese` 字段。

背景
----
文档记载「乙型空壳卡」：英文释义里已含括号包裹的中文（如
`"a prize or grant given for achievement (奖，奖品)"`），但 `chinese` 字段是空串 →
用户会看到「有英文释义但无中文」的残缺卡片。

**零 LLM 成本**：纯正则即可修复（无需重新生成）。

实测（2026-09-25，清洗后 11,917 条词表）
----------------------------------------
  · **194 条** 乙型（括号中文 + chinese 空）→ 提取即修好
  · **36 条** chinese 已有值但 `meaning` 里仍残留中文 → 去冗余
  · 合计 **230 条** `meaning` 含中文（属格式错误）

处理规则
--------
1. 从 `meaning` 里取出**括号包裹的中文段**（中文括号或英文半角括号）
2. 若 `chinese` 为空 → 写入（多个括号段用「；」连接）
3. 无论 `chinese` 是否为空 → **都从 `meaning` 移除**该中文段（保持英文释义纯净）
4. 清理移除后遗留的多余空格与孤立括号

⚠️ 安全性：只改 `definitions` 这一个字段的文本，不动卡片是否存在的判断。

用法
----
    python3 scripts/split_inline_chinese.py --dry-run   # 预览（默认）
    python3 scripts/split_inline_chinese.py --apply     # 执行
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'inline_chinese_result.json')

# 括号包裹的中文（中/英括号），括号内允许中文标点与空格
BRACKET_CJK = re.compile(r'[（(]\s*([\u4e00-\u9fff][^（()）]*?)\s*[）)]')
CJK = re.compile(r'[\u4e00-\u9fff]')


def _fix(text: str) -> tuple[str, list[str]]:
    """返回 (清理后的英文释义, 提取出的中文段列表)。"""
    found = BRACKET_CJK.findall(text)
    cleaned = BRACKET_CJK.sub('', text)
    # 清理残留：孤立空格、重复空格、末尾悬空的标点
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()
    cleaned = re.sub(r'\s+([.,;:])', r'\1', cleaned)
    cleaned = re.sub(r'[.,;:]\s*$', '', cleaned).strip()
    return cleaned, found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    do_apply = args.apply and not args.dry_run

    con = sqlite3.connect(DB)
    cur = con.cursor()
    rows = list(cur.execute("""
        SELECT c.id, c.front, l.definitions
        FROM prebuilt_cards c JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))

    to_fix: list[tuple] = []
    for cid, word, defs in rows:
        if not defs or not defs.strip():
            continue
        try:
            items = json.loads(defs)
        except Exception:
            continue
        if not isinstance(items, list):
            continue

        changed = False
        new_items = []
        for it in items:
            if not isinstance(it, dict):
                new_items.append(it)
                continue
            it = dict(it)
            # 处理 `meaning` 与 `example` 两个字段 —— 中文混进例句同样要清理
            for field in ('meaning', 'example'):
                text = it.get(field) or ''
                if not CJK.search(text):
                    continue
                cleaned, extracted = _fix(text)
                if not extracted:
                    continue
                if field == 'meaning' and not (it.get('chinese') or '').strip():
                    # chinese 为空 → 用提取值（多段用「；」连接并去重）
                    it['chinese'] = '；'.join(dict.fromkeys(extracted))
                it[field] = cleaned
                changed = True
            new_items.append(it)

        if changed:
            to_fix.append((cid, word, json.dumps(new_items, ensure_ascii=False),
                           json.dumps(items, ensure_ascii=False)))

    # 统计（注意方向：old 无值 + new 有值 = 填入）
    filled = 0      # chinese 原为空 → 填入
    dedup = 0       # chinese 原已有 → 仅去冗余
    for cid, word, new, old in to_fix:
        o = json.loads(old); n = json.loads(new)
        if any(not (a.get('chinese') or '').strip() and (b.get('chinese') or '').strip()
               for a, b in zip(o, n)):
            filled += 1
        else:
            dedup += 1

    print('=' * 76)
    print('中文内联拆分 · ' + ('实际执行' if do_apply else '预览'))
    print('=' * 76)
    print(f"  词表总数              : {len(rows):,}")
    print(f"  🔴 需要修复            : {len(to_fix)}")
    print(f"     ├ chinese 为空→填入 : {filled}")
    print(f"     └ chinese 已有→去冗余: {dedup}")

    print(f"\n  样例（前 12 条）：")
    for cid, word, new, old in to_fix[:12]:
        o, n = json.loads(old), json.loads(new)
        for a, b in zip(o, n):
            if a.get('meaning') != b.get('meaning'):
                print(f"    {word:<16} chinese: {a.get('chinese')!r} → {b.get('chinese')!r}")
                print(f"        meaning: {a.get('meaning')[:78]!r}")
                print(f"              → {b.get('meaning')[:78]!r}")
                break

    if not do_apply:
        con.close()
        print('\n（预览模式，未修改。加 --apply 执行）')
        return

    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup = os.path.join(BACKUP_DIR, f'coevo_before_inline_chinese_{ts}.db')
    shutil.copy2(DB, backup)
    print(f'\n✅ 已备份 → {os.path.relpath(backup, ROOT)}')

    for cid, word, new, old in to_fix:
        cur.execute('UPDATE prebuilt_language_cards SET definitions=? WHERE id=?', (new, cid))
    con.commit()

    # 复核
    # ⚠️ 只在 `meaning`/`example` 上检测 —— `chinese` 字段里出现中文括号是正常的
    left = 0
    for cid, word, defs in cur.execute("""
        SELECT c.id, c.front, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id=c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """):
        if not defs:
            continue
        try:
            its = json.loads(defs)
        except Exception:
            continue
        if any(BRACKET_CJK.search((it.get(f) or ''))
               for it in its if isinstance(it, dict)
               for f in ('meaning', 'example')):
            left += 1
    print(f"  已修复                : {len(to_fix)}")
    print(f"  仍残留括号中文          : {left} {'✅' if left == 0 else '⚠️'}")

    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump({
            '_meta': {'executed_at': datetime.now().isoformat(timespec='seconds'),
                      'backup': os.path.relpath(backup, ROOT),
                      'fixed': len(to_fix), 'filled': filled, 'dedup': dedup},
            'changes': [{'word': w, 'before': json.loads(o), 'after': json.loads(n)}
                        for _, w, n, o in to_fix],
        }, f, ensure_ascii=False, indent=2)
    print(f"✅ 变更清单 → {os.path.relpath(OUT, ROOT)}")
    con.close()


if __name__ == '__main__':
    main()
