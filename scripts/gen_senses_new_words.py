#!/usr/bin/env python3
"""为「补录的新词」生成卡片内容（IPA + CEFR + 释义）

背景（2026-09-26）：
  LLM 全量重跑时发现 **977 个中间节点**（别的词的 `derived_from` 指向它们）：
    · LLM **100% 判它们「值得独立成卡」**（`is_own_entry=true`）
    · 但它们**不在现网 11,917 词表**里 → 「词表漏了基础词」
  后果：**396 个词形的 anchor 落空 → 划词查不到任何卡**
    （`belched`→`belch`，而 `belch` 不在词表）

  → 白哥批准「补录」。补录后它们成为正式词条，链断归零。

🔑 为什么需要本脚本：
  这 977 个词的 `morphology`/`etymology`/`collocations`/`mnemonic` **已有**
  （在 `intermediate/results.jsonl` 里，同契约产出，已付费）。
  但**没有** `IPA` / `CEFR 等级` / `释义` —— 这三样现网词是有的（迁自存量），
  新词必须生成。缺了它们卡片就是空壳（用户划词跳过去看到空卡）。

产出：`senses_supplement.json`
  {"<word>": {"pronunciation": "/.../", "level": "B2",
              "definitions": [{"pos": "verb", "meaning": "...", "chinese": "...", "example": "..."}]}}
  供 `load_llm_results.py` 当作这些词的「现网释义」用（与 coevo.db 同结构）。

用法：
  python3 scripts/gen_senses_new_words.py --dry-run
  python3 scripts/gen_senses_new_words.py
"""
import argparse
import json
import os
import sqlite3
import sys
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

OUT = os.path.join(cwc.PREBUILT, 'senses_supplement.json')
FULLRUN = os.path.join(cwc.PREBUILT, 'fullrun', 'results.jsonl')
INTER = os.path.join(cwc.PREBUILT, 'intermediate', 'results.jsonl')

PROMPT = """You are an expert English lexicographer writing flashcard content for Chinese learners.

WORD: {word}

Return STRICT JSON with EXACTLY this shape:
{{
  "pronunciation": "/ɪɡˈzæmpəl/",
  "level": "B1",
  "definitions": [
    {{"pos": "verb", "meaning": "short English definition",
      "chinese": "中文释义", "example": "An English example sentence."}}
  ]
}}

RULES:
- pronunciation: IPA between slashes, British or American (either is fine). Use real IPA.
- level: CEFR level of this word for a Chinese learner — one of A1|A2|B1|B2|C1.
  Judge by frequency and difficulty, NOT by length.
- definitions: 1-3 senses, most common FIRST. Each sense needs all four keys.
  * pos: noun | verb | adjective | adverb | preposition | conjunction | pronoun | interjection | determiner
  * meaning: concise English gloss (≤12 words)
  * chinese: 中文释义（≤20字）
  * example: a natural, short English sentence

Output JSON only, no prose, no markdown fences."""


def load_candidates():
    """→ [word…]：判 is_own_entry=true 且不在现网词表的中间节点"""
    con = sqlite3.connect(cwc.DB)
    vocab = {r[0].strip().lower() for r in con.execute(
        "SELECT front FROM prebuilt_cards WHERE subject='english' AND card_type='vocabulary'")}
    con.close()

    inter = {}
    for line in open(INTER, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get('ok') and r.get('data'):
            inter[r['word'].lower()] = r['data']
    return sorted(w for w, d in inter.items()
                  if d.get('is_own_entry') is True and w not in vocab)


_lock = threading.Lock()


def call_senses(key, word, retries=3):
    """用**本脚本自己的 prompt** 调 LLM（不能复用 `cwc.call_llm` —— 那是契约 v5 的 prompt）"""
    body = json.dumps({
        'model': cwc.MODEL,
        'messages': [{'role': 'user', 'content': PROMPT.format(word=word)}],
        'temperature': 0.1,
        'max_tokens': 900,
        'response_format': {'type': 'json_object'},
        'thinking': cwc.THINKING,
    })
    headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'}
    for attempt in range(retries):
        try:
            c = cwc._conn_get(60)
            c.request('POST', cwc._PATH, body=body, headers=headers)
            r = c.getresponse()
            raw = r.read()
            if r.status != 200:
                cwc._conn_reset()
                if r.status in (429, 500, 502, 503) and attempt < retries - 1:
                    time.sleep(2 ** attempt)
                    continue
                return {'ok': False, 'error': f'HTTP {r.status}'}
            if (r.getheader('Connection') or '').lower() == 'close':
                cwc._conn_reset()
            else:
                cwc._conn_bump()
            res = json.loads(raw)
            u = res.get('usage', {})
            return {'ok': True, 'data': json.loads(res['choices'][0]['message'].get('content') or '{}'),
                    'in_tok': u.get('prompt_tokens', 0), 'out_tok': u.get('completion_tokens', 0)}
        except Exception as e:
            cwc._conn_reset()
            if attempt < retries - 1:
                time.sleep(min(2 ** attempt, 2))
                continue
            return {'ok': False, 'error': f'{type(e).__name__}: {e}'}
    return {'ok': False, 'error': 'retries exhausted'}


class Sink:
    def __init__(self, path, flush_every=50):
        self.path = path
        self.buf = []
        self.fh = open(path, 'a', encoding='utf-8')

    def write(self, rec):
        with _lock:
            self.buf.append(json.dumps(rec, ensure_ascii=False))
            if len(self.buf) >= 50:
                self._flush()

    def _flush(self):
        if self.buf:
            self.fh.write('\n'.join(self.buf) + '\n')
            self.fh.flush()
            self.buf = []

    def close(self):
        with _lock:
            self._flush()
            self.fh.close()


def load_done(path):
    done = {}
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('word') and r.get('ok'):
                done[r['word']] = r
    return done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--workers', type=int, default=100)
    ap.add_argument('--limit', type=int)
    ap.add_argument('--force', action='store_true')
    args = ap.parse_args()

    cwc.set_proxy(False)
    words = load_candidates()
    print(f'  补录候选（判独立 + 不在词表）: {len(words)}')

    done = load_done(OUT + 'l')
    todo = words if args.force else [w for w in words if w not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f'  已完成 {len(done)} · 本次待跑 {len(todo)}')
    if args.dry_run:
        print('  样例:', todo[:15])
        print('  （--dry-run）')
        return
    if not todo:
        print('  ✅ 无待跑')
        return

    key = cwc.load_key()
    cwc.reset_stats()
    sink = Sink(OUT + 'l')
    total = {'in': 0, 'out': 0, 'ok': 0, 'fail': 0}
    t0 = time.time()

    def work(w):
        return w, call_senses(key, w)

    print(f'  跑 LLM（{args.workers} 并发）...')
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(work, w) for w in todo]
        for i, f in enumerate(as_completed(futs), 1):
            w, r = f.result()
            rec = {'word': w, 'ok': bool(r.get('ok'))}
            if r.get('ok'):
                rec['data'] = r['data']
                total['in'] += r.get('in_tok', 0)
                total['out'] += r.get('out_tok', 0)
                total['ok'] += 1
            else:
                rec['error'] = r.get('error')
                total['fail'] += 1
            sink.write(rec)
            if i % 200 == 0 or i == len(todo):
                el = time.time() - t0
                rate = i / el if el else 0
                print(f'    {i}/{len(todo)}  ok={total["ok"]} fail={total["fail"]}  '
                      f'{rate:.1f} 条/秒  ETA {(len(todo)-i)/rate/60:.1f} min' if rate else '')
    sink.close()

    cost = total['in'] * cwc.P_IN / 1e6 + total['out'] * cwc.P_OUT / 1e6
    print(f'\n  完成：成功 {total["ok"]} · 失败 {total["fail"]} · '
          f'耗时 {(time.time()-t0)/60:.1f} min · 成本 ≈ ¥{cost:.2f}')
    st = cwc.stats_snapshot()
    if st.get('conn_err'):
        print(f'  🟠 连接重试 {st["conn_err"]} 次')

    # 汇总成 senses_supplement.json
    allr = load_done(OUT + 'l')
    supp = {}
    bad = []
    for w, r in allr.items():
        d = r['data']
        defs = d.get('definitions')
        if not isinstance(defs, list) or not defs:
            bad.append(w)
            continue
        supp[w] = {'pronunciation': (d.get('pronunciation') or '').strip(),
                   'level': (d.get('level') or '').strip().upper(),
                   'definitions': defs}
    json.dump({'count': len(supp), 'items': supp},
              open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'  已写 {OUT}（{len(supp)} 词）')
    if bad:
        print(f'  🟠 definitions 缺失/非数组: {len(bad)} 条 {bad[:10]}')
    lv = Counter(v['level'] for v in supp.values())
    print(f'  CEFR 分布: {dict(sorted(lv.items()))}')
    print(f'  无 IPA 的: {sum(1 for v in supp.values() if not v["pronunciation"])}')


if __name__ == '__main__':
    main()
