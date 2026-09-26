#!/usr/bin/env python3
"""词缀归一化 → `affix` 表初始数据

解决的问题（2026-09-26 就绪检查发现）：
  白哥方案是「词缀优先在 affix 表中选释义，匹配不上再新增」，
  **但表是空的，而它的数据只能从 LLM 跑出来** —— 先有鸡还是先有蛋。
  若不做归一化直接落库：LLM 对同一词缀的自由表述（如 `-ing` 有 9 种说法）
  会各占一行 → 词缀表膨胀成「每词一行」，失去共享意义。

做法：
  ① 收集 LLM 产出的全部 (form, type, meaning) 表述 + 频次
  ② 把同一 form 的所有表述交给 LLM，聚类成 canonical sense + aliases
  ③ 落 `affix` 表：canonical sense 一行，所有同义表述进 aliases

用法：
  python3 scripts/build_affix_table.py --from-sample          # 用抽样数据（验证用）
  python3 scripts/build_affix_table.py                        # 用全量 results.jsonl
  python3 scripts/build_affix_table.py --dry-run              # 只看聚类结果不写库
"""
import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.request
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

ROOT = cwc.ROOT
PREBUILT = cwc.PREBUILT
FULLRUN_JSONL = os.path.join(PREBUILT, 'fullrun', 'results.jsonl')
SAMPLE_JSON = os.path.join(PREBUILT, 'llm_rerun_sample.json')
OUT_JSON = os.path.join(PREBUILT, 'affix_normalized.json')
TARGET_DB = os.path.join(ROOT, 'data', 'word.db')

BATCH = 12   # 每次送 LLM 几个词缀

PROMPT = """You are a morphologist building a canonical AFFIX TABLE for an English learning app.

Below are affixes (prefixes/suffixes) extracted from word analyses, each with the DIFFERENT Chinese
wordings our model produced for it. Different wordings often mean the SAME linguistic sense
(e.g. "-ed" = "过去式/过去分词" and "过去分词" are the same sense).

Affixes:
{payload}

For EACH affix, decide how many DISTINCT SENSES it really has, and map every wording to one of them.

Return STRICT JSON:
{{"affixes":[
  {{"form":"-ed","type":"suffix","senses":[
     {{"sense":"past_participle","meaning_zh":"过去式/过去分词","aliases":["过去式/过去分词","过去分词/过去式","过去分词"]}},
     {{"sense":"adjectival","meaning_zh":"被…的（形容词化）","aliases":["被…的","已…的","…的","过去分词/形容词后缀"]}}
  ]}}
]}}

RULES:
- "form" and "type" must be copied EXACTLY as given (including hyphens).
- Every alias from the input MUST appear in exactly ONE sense's "aliases" — do NOT drop any.
- "sense" = a short snake_case English id for the sense (e.g. past_participle, plural, agent_noun,
  negation, progressive, nominalization, comparative, adjectival).
- "meaning_zh" = ONE clear Chinese phrase that best covers that sense (this is what users will read).
- Merge wordings that mean the same thing; SPLIT into different senses only when the linguistic
  function is genuinely different (e.g. agent -er vs comparative -er; progressive -ing vs
  adjectival -ing vs nominalizing -ing).
- If an affix truly has only one sense, return a single-element "senses" array.

Output JSON only."""


def collect_expressions(from_sample: bool):
    """→ {(form,type): Counter(meaning → freq)}, 及每条的样例词"""
    aff = defaultdict(Counter)
    ex = defaultdict(list)

    def feed(word, parts):
        for p in (parts or []):
            t = (p.get('type') or '').strip().lower()
            if t not in ('prefix', 'suffix'):
                continue
            f = (p.get('form') or '').strip().lower()
            m = (p.get('meaning') or '').strip()
            if f and m:
                aff[(f, t)][m] += 1
                if len(ex[(f, t)]) < 3:
                    ex[(f, t)].append(word)

    if from_sample:
        d = json.load(open(SAMPLE_JSON, encoding='utf-8'))
        for x in d['items']:
            for rd in ('r1', 'r2'):
                data = (x.get(rd) or {}).get('data') or {}
                feed(x['word'], (data.get('morphology') or {}).get('parts'))
    else:
        if not os.path.exists(FULLRUN_JSONL):
            raise SystemExit(f'找不到 {FULLRUN_JSONL}，先跑全量或加 --from-sample')
        for line in open(FULLRUN_JSONL, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if not r.get('ok'):
                continue
            feed(r['word'], ((r.get('data') or {}).get('morphology') or {}).get('parts'))
    return aff, ex


def llm_normalize(key, batch):
    """batch: [((form,type), Counter)] → [affix dict]"""
    payload = json.dumps(
        [{'form': f, 'type': t, 'wordings': [{'text': m, 'count': n} for m, n in c.most_common()]}
         for (f, t), c in batch],
        ensure_ascii=False, indent=1)
    body = {
        'model': cwc.MODEL,
        'messages': [{'role': 'user', 'content': PROMPT.format(payload=payload)}],
        'temperature': 0.1, 'max_tokens': 4000,
        'response_format': {'type': 'json_object'},
        'thinking': cwc.THINKING,
    }
    for attempt in range(4):
        try:
            req = urllib.request.Request(
                cwc.API_URL, data=json.dumps(body).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'})
            with urllib.request.urlopen(req, timeout=180) as r:
                res = json.loads(r.read())
            u = res.get('usage', {})
            data = json.loads(res['choices'][0]['message'].get('content') or '{}')
            return data.get('affixes') or [], u.get('prompt_tokens', 0), u.get('completion_tokens', 0)
        except Exception as e:
            if attempt < 3:
                time.sleep(2 ** attempt)
                continue
            print(f'    🔴 失败: {type(e).__name__}: {e}')
            return None, 0, 0
    return None, 0, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from-sample', action='store_true', help='用抽样数据（验证用）')
    ap.add_argument('--dry-run', action='store_true', help='只聚类不写库')
    args = ap.parse_args()

    aff, ex = collect_expressions(args.from_sample)
    n_expr = sum(len(c) for c in aff.values())
    print(f'  来源: {"抽样" if args.from_sample else "全量 results.jsonl"}')
    print(f'  词缀 form: {len(aff)} · (form,meaning) 表述: {n_expr}')

    multi = {k: v for k, v in aff.items() if len(v) >= 2}
    print(f'  其中表述 ≥2 种的（需归一化）: {len(multi)}')

    keys = sorted(aff.keys())
    batches = [keys[i:i + BATCH] for i in range(0, len(keys), BATCH)]
    print(f'  LLM 批数: {len(batches)}')

    key = cwc.load_key()
    out, tin, tout = [], 0, 0
    for bi, bt in enumerate(batches, 1):
        batch = [((f, t), aff[(f, t)]) for (f, t) in bt]
        res, pi, po = llm_normalize(key, batch)
        tin += pi
        tout += po
        if res is None:
            print(f'    批 {bi}/{len(batches)} 失败')
            continue
        # 补全缺的（LLM 漏掉的词缀按单义处理）
        got = {(a.get('form', '').lower(), (a.get('type') or '').lower()) for a in res}
        for (f, t), c in batch:
            if (f, t) not in got:
                res.append({'form': f, 'type': t, 'senses': [
                    {'sense': 'general', 'meaning_zh': c.most_common(1)[0][0],
                     'aliases': list(c.keys())}]})
        out += res
        print(f'    批 {bi}/{len(batches)}  ok · 累计 {len(out)} 词缀')

    # ── 校验：aliases 是否覆盖全部输入表述 ──
    print()
    print('=' * 88)
    print('校验')
    print('=' * 88)
    covered, lost = 0, []
    for a in out:
        k = (a['form'].lower(), a['type'].lower())
        src = {m.lower() for m in aff.get(k, {})}
        got_al = set()
        for s in a.get('senses', []):
            got_al |= {str(x).strip().lower() for x in (s.get('aliases') or [])}
        covered += len(src & got_al)
        for m in src - got_al:
            lost.append((k, m))
    print(f'  覆盖输入表述: {covered}/{n_expr} = {covered/n_expr*100:.1f}%')
    if lost:
        print(f'  🟠 未覆盖 {len(lost)} 条（前 10）:')
        for k, m in lost[:10]:
            print(f'      {k[0]:<10} {k[1]:<8} {m}')

    n_before = n_expr
    n_after = sum(len(a.get('senses') or []) for a in out)
    print(f'  归一化: {n_before} 条表述 → {n_after} 个 canonical sense '
          f'（压缩 {(1-n_after/n_before)*100:.0f}%）')

    cost = tin * cwc.P_IN / 1e6 + tout * cwc.P_OUT / 1e6
    print(f'  成本 ≈ ¥{cost:.3f}  (in={tin} out={tout})')

    # 存 JSON
    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump({'version': cwc.CONTRACT_VERSION, 'source': 'sample' if args.from_sample else 'fullrun',
                   'affixes': out}, f, ensure_ascii=False, indent=1)
    print(f'  已写 {OUT_JSON}')

    if args.dry_run:
        print('  （dry-run，未写库）')
        return

    # ── 写 affix 表 ──
    os.makedirs(os.path.dirname(TARGET_DB), exist_ok=True)
    con = sqlite3.connect(TARGET_DB)
    con.execute('''
    CREATE TABLE IF NOT EXISTS affix (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      form         TEXT NOT NULL COLLATE NOCASE,
      type         TEXT NOT NULL,
      sense        TEXT NOT NULL,
      meaning_zh   TEXT NOT NULL,
      aliases      TEXT,
      productivity INTEGER DEFAULT 0,
      needs_review INTEGER DEFAULT 0,
      UNIQUE (form, type, sense)
    )''')
    ins = 0
    for a in out:
        for s in (a.get('senses') or []):
            con.execute(
                'INSERT OR IGNORE INTO affix (form,type,sense,meaning_zh,aliases,productivity) '
                'VALUES (?,?,?,?,?,?)',
                (a['form'], a['type'], s.get('sense') or 'general',
                 s.get('meaning_zh') or '', json.dumps(s.get('aliases') or [], ensure_ascii=False),
                 aff.get((a['form'].lower(), a['type'].lower()), Counter()).total()))
            ins += 1
    con.commit()
    n = con.execute('SELECT count(*) FROM affix').fetchone()[0]
    con.close()
    print(f'  写入 affix 表 {ins} 行（表内共 {n} 行）→ {TARGET_DB}')


if __name__ == '__main__':
    main()
