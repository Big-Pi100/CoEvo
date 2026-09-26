#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复残留的「英文释义里混中文」（按**义项**粒度）

背景（2026-09-25 实测发现）
--------------------------
`fill_card_content_llm.py` 只写入 `items[0]`（**首个义项**）——
所以**次要义项**的历史问题一直没被触及。实测残留 3 组：

  A 冗余（29 个义项）：`chinese` 已填，但 `meaning` 尾部还有中文残留
      · 部分 `chinese` 填的是词性标签而非释义（`gran` → '非正式'，应为「奶奶」）
  B 真损坏（4 个义项）：中文被截断未闭合 → 用户会看到乱码
      · `color[4]` = 'to influence or distort (something). （影响，歪'
  C 合法（6 个义项）：解释中**正当引用**中文（专名注音）
      · `onleh[0]` = '...a Chinese given name (e.g., 温利 / Wēn Lì)'
      · `hwang[1]` = '...typically written as 黄 (Huáng)...'

处理
----
  · A / B → **整义项用 LLM 重新生成**（含正确的 meaning + chinese）
  · C → **保留不动**（判据：句中含 `written as` / `romanized` / `e.g.,` 等引用语）

用法
----
    python3 scripts/fix_residual_cjk.py --dry-run
    python3 scripts/fix_residual_cjk.py --apply
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
ENV = os.path.join(ROOT, 'backend', '.env')
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'residual_cjk_fix.json')

API_URL = 'https://api.deepseek.com/chat/completions'
MODEL = os.environ.get('COEVO_LLM_MODEL', 'deepseek-flash')
THINKING = {'type': 'disabled'}
PRICE_IN, PRICE_OUT = 1.5 / 1e6, 4.5 / 1e6

CJK = re.compile(r'[\u4e00-\u9fff]')
# 中文作为「正当引用」的语境（此类不修）
JUSTIFIED = re.compile(
    r'(written as|romanized|transliterat|e\.g\.,|pronounced|'
    r'see also|compare|in Mandarin|in Cantonese)', re.I)


def load_key() -> str:
    if os.path.exists(ENV):
        for line in open(ENV, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                os.environ.setdefault(k, v.strip())
    return os.environ.get('DEEPSEEK_API_KEY', '').strip()


PROMPT = """You are an English learner's dictionary editor. Fix ONE sense of a word card.

Word: {word}
Sense index: {idx}
Current (BROKEN) English definition: {meaning}

Problems with the current definition: a Chinese translation was accidentally
pasted INTO the English definition and may be truncated. Rewrite it cleanly.

Rules:
- `meaning`: clean ENGLISH definition only. NO Chinese characters at all.
  One sentence, <= 22 words, learner-friendly (CEFR A2-B2).
- `chinese`: correct Chinese translation of THIS sense, <= 12 chars. Chinese only.
- `pos`: part of speech for this sense: n / v / adj / adv / prep / pron / conj / num / int

Output STRICT JSON only:
{{"pos":"...","meaning":"...","chinese":"..."}}"""


def llm(prompt, key, max_tokens=400, retries=3):
    body = json.dumps({'model': MODEL, 'messages': [{'role': 'user', 'content': prompt}],
                       'temperature': 0.2, 'max_tokens': max_tokens,
                       'response_format': {'type': 'json_object'},
                       'thinking': THINKING}).encode()
    for i in range(retries):
        try:
            req = urllib.request.Request(API_URL, data=body,
                headers={'Content-Type': 'application/json',
                         'Authorization': f'Bearer {key}'})
            with urllib.request.urlopen(req, timeout=90) as r:
                res = json.loads(r.read())
            return res['choices'][0]['message']['content'], res.get('usage')
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503):
                time.sleep(2 ** i); continue
            return None, {'error': f'HTTP {e.code}'}
        except Exception as e:
            if i == retries - 1:
                return None, {'error': f'{type(e).__name__}'}
            time.sleep(2 ** i)
    return None, {'error': 'retry exhausted'}


def find_targets(conn):
    rows = list(conn.execute("""
        SELECT c.id, c.front, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))
    targets, skipped = [], []
    for cid, word, defs in rows:
        if not defs:
            continue
        try:
            items = json.loads(defs)
        except Exception:
            continue
        if not isinstance(items, list):
            continue
        for idx, it in enumerate(items):
            if not isinstance(it, dict):
                continue
            mn = it.get('meaning') or ''
            if not CJK.search(mn):
                continue
            if JUSTIFIED.search(mn):
                skipped.append({'word': word, 'idx': idx, 'meaning': mn, 'reason': '正当引用'})
                continue
            targets.append({'id': cid, 'word': word, 'idx': idx, 'meaning': mn,
                            'chinese': (it.get('chinese') or '').strip()})
    return targets, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--workers', type=int, default=6)
    args = ap.parse_args()

    key = load_key()
    if not key:
        sys.exit('❌ 未找到 DEEPSEEK_API_KEY')

    conn = sqlite3.connect(DB)
    targets, skipped = find_targets(conn)

    print('=' * 78)
    print(f"残留内联中文修复 · {'执行' if args.apply else '预览'}")
    print('=' * 78)
    print(f"  🔴 待修复（A 冗余 + B 损坏）: {len(targets)} 个义项")
    print(f"  ✅ 保留（C 正当引用）        : {len(skipped)} 个义项")
    print(f"\n  待修复明细：")
    for t in targets:
        print(f"    {t['word']}[{t['idx']:<2}] chinese={t['chinese'][:14]!r:<18} {t['meaning'][:66]}")

    if not args.apply:
        conn.close()
        print('\n（预览模式。加 --apply 执行）')
        return

    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup = os.path.join(BACKUP_DIR, f'coevo_before_residual_cjk_{ts}.db')
    shutil.copy2(DB, backup)
    print(f'\n✅ 已备份 → {os.path.relpath(backup, ROOT)}')

    usage = {'in': 0, 'out': 0}
    results, fails = [], []

    def work(t):
        txt, us = llm(PROMPT.format(word=t['word'], idx=t['idx'],
                                    meaning=t['meaning'][:220]), key)
        if us and 'error' in us:
            return t, None, us['error']
        if us:
            usage['in'] += us.get('prompt_tokens', 0)
            usage['out'] += us.get('completion_tokens', 0)
        try:
            clean = re.sub(r'^```(?:json)?\s*|\s*```$', '', (txt or '').strip())
            data = json.loads(clean)
        except Exception:
            return t, None, 'JSON 解析失败'
        mn = (data.get('meaning') or '').strip()
        ch = (data.get('chinese') or '').strip()
        if not mn or not ch:
            return t, None, '字段为空'
        if CJK.search(mn):
            return t, None, '新释义仍含中文'
        return t, data, None

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for i, f in enumerate(as_completed([ex.submit(work, t) for t in targets]), 1):
            t, data, err = f.result()
            (results if data else fails).append((t, data, err))
            print(f"  [{i:>2}/{len(targets)}] {t['word']}[{t['idx']}] "
                  f"{'✅' if data else '❌ ' + str(err)}")

    # 写回（按义项索引精确替换）
    n = 0
    for t, data, _ in results:
        rows = list(conn.execute(
            'SELECT definitions FROM prebuilt_language_cards WHERE id=?', (t['id'],)))
        if not rows:
            continue
        items = json.loads(rows[0][0])
        it = items[t['idx']]
        if data.get('pos'):
            it['pos'] = data['pos']
        it['meaning'] = data['meaning']
        it['chinese'] = data['chinese']
        items[t['idx']] = it
        conn.execute('UPDATE prebuilt_language_cards SET definitions=? WHERE id=?',
                     (json.dumps(items, ensure_ascii=False), t['id']))
        n += 1
    conn.commit()

    cost = usage['in'] * PRICE_IN + usage['out'] * PRICE_OUT
    print('=' * 78)
    print(f"  ✅ 修复 {len(results)} · ❌ 失败 {len(fails)} · 写回 {n}")
    print(f"  token: 输入 {usage['in']:,} / 输出 {usage['out']:,}  💰 ≈ ¥{cost:.3f}")
    print('=' * 78)

    json.dump({'_meta': {'finished': datetime.now().isoformat(timespec='seconds'),
                         'backup': os.path.relpath(backup, ROOT),
                         'fixed': len(results), 'failed': len(fails),
                         'cost_cny': round(cost, 4)},
               'fixed': [{'word': t['word'], 'idx': t['idx'], 'data': d}
                         for t, d, _ in results],
               'failed': [{'word': t['word'], 'idx': t['idx'], 'error': e}
                          for t, _, e in fails],
               'skipped_justified': skipped},
              open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f"✅ 结果 → {os.path.relpath(OUT, ROOT)}")
    conn.close()


if __name__ == '__main__':
    main()
