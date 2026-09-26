#!/usr/bin/env python3
"""抽样验证「词根可行性」统计的准确度。

背景（2026-09-25）：
  word-db-migration 报告 §四 给出的「4,372 词可拆 / 36.7%」是**规则法粗估** ——
  纯字符串前缀/后缀匹配，不是词根分析。白哥质疑其可信度，故做本验证。

做法：
  ① 分层抽样（每 CEFR 等级 30 词 = 150 词）—— 保证各等级都有覆盖
  ② 用 LLM 判定「该词能否拆出词根/词缀」（附拆分结果）
  ③ 对比规则法 vs LLM 判定 → 得出
     · 真实的「可拆率」
     · 规则法的准确率 / 召回率
     · 4,372 这个数字的偏差方向与幅度

用法：
  python3 scripts/verify_root_feasibility.py            # 抽样 + 调 LLM + 报告
  python3 scripts/verify_root_feasibility.py --per 50   # 每层 50 词（更准，稍慢）
  python3 scripts/verify_root_feasibility.py --cached   # 复用上次结果，不重复调 LLM
"""
import argparse
import json
import os
import random
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
ENV = os.path.join(ROOT, 'backend', '.env')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'root_feasibility_verify.json')

API_URL = 'https://api.deepseek.com/chat/completions'
MODEL = os.environ.get('COEVO_LLM_MODEL', 'deepseek-flash')
THINKING = {'type': 'disabled'}

# ── 规则法（与 word-db-migration 报告 §四 完全一致，用于对比）──
PREFIX = ['un', 're', 'dis', 'in', 'im', 'il', 'ir', 'pre', 'pro', 'trans', 'con', 'com', 'per', 'sub', 'inter',
          'ex', 'de', 'ad', 'ob', 'ab', 'se', 'super', 'over', 'under', 'anti', 'auto', 'bi', 'co', 'counter',
          'extra', 'fore', 'hyper', 'micro', 'mid', 'mis', 'mono', 'multi', 'non', 'out', 'poly', 'post',
          'semi', 'tele', 'tri', 'ultra', 'vice', 'with', 'em', 'en', 'epi', 'eu', 'hetero', 'homo', 'meta', 'para', 'syn', 'sym']
SUFFIX = ['tion', 'sion', 'ation', 'able', 'ible', 'ment', 'ness', 'ity', 'ous', 'ive', 'al', 'ic', 'ize', 'ise',
          'ify', 'ance', 'ence', 'ful', 'less', 'ish', 'ist', 'ism', 'ary', 'ery', 'ory', 'ate', 'ent', 'ant',
          'age', 'dom', 'hood', 'ship', 'ward', 'wise', 'like', 'some', 'ious', 'eous', 'ancy']


def rule_says_splittable(w: str) -> bool:
    lw = w.lower()
    if len(lw) < 6:
        return False
    for p in PREFIX:
        if lw.startswith(p) and len(lw) - len(p) >= 4:
            return True
    for s in SUFFIX:
        if lw.endswith(s) and len(lw) - len(s) >= 4:
            return True
    return False


def load_key() -> str:
    for line in open(ENV, encoding='utf-8'):
        line = line.strip()
        if line.startswith('DEEPSEEK_API_KEY='):
            return line.split('=', 1)[1].strip()
    raise SystemExit('未找到 DEEPSEEK_API_KEY')


def sample(db_path: str, per_level: int, seed: int = 42):
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    rows = list(cur.execute("""
        SELECT c.front, l.level FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))
    con.close()
    by_level = defaultdict(list)
    for w, lv in rows:
        by_level[(lv or '').strip()].append(w)
    rng = random.Random(seed)
    picked = []
    for lv in ('A1', 'A2', 'B1', 'B2', 'C1'):
        pool = sorted(by_level.get(lv, []))
        rng.shuffle(pool)
        for w in pool[:per_level]:
            picked.append({'word': w, 'level': lv, 'rule': rule_says_splittable(w)})
    return picked


PROMPT = """You are an English etymology expert. For the word below, decide whether it is **morphologically analyzable** into roots and affixes that help a learner remember it.

Word: {word}

Rules:
- `analyzable`: true ONLY if the word can be broken into meaningful morphemes that are still semantically transparent in modern English (e.g. "incredible" = in- + cred + -ible; "transact" = trans- + act).
- false if:
  * it is a base word with no productive affix (e.g. "happy", "table")
  * it is a Germanic compound or opaque word, even if it looks like it has an affix (e.g. "understand" is NOT under+stand; "interest" is NOT in+terest; "reason" is NOT re+ason)
  * the affix no longer carries meaning in modern English (e.g. "decide", "require", "remain")
- `parts`: if analyzable, list morphemes in order. Each: {{"form": "in-", "type": "prefix|root|suffix", "meaning": "不"}}. Use Chinese for the meaning. Max 4 parts.
- `confidence`: 0.0-1.0

Output STRICT JSON only:
{{"analyzable": true, "parts": [{{"form":"...","type":"...","meaning":"..."}}], "confidence": 0.9}}"""


def call_llm(key: str, word: str, retries: int = 3):
    body = {
        'model': MODEL,
        'messages': [{'role': 'user', 'content': PROMPT.format(word=word)}],
        'temperature': 0.1, 'max_tokens': 400,
        'response_format': {'type': 'json_object'},
        'thinking': THINKING,
    }
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                API_URL, data=json.dumps(body).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'})
            with urllib.request.urlopen(req, timeout=90) as r:
                res = json.loads(r.read())
            usage = res.get('usage', {})
            content = res['choices'][0]['message'].get('content') or '{}'
            data = json.loads(content)
            return {
                'ok': True,
                'analyzable': bool(data.get('analyzable')),
                'parts': data.get('parts') or [],
                'confidence': data.get('confidence'),
                'in_tok': usage.get('prompt_tokens', 0),
                'out_tok': usage.get('completion_tokens', 0),
            }
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            return {'ok': False, 'error': f'HTTP {e.code}'}
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            return {'ok': False, 'error': f'{type(e).__name__}: {e}'}
    return {'ok': False, 'error': 'retries exhausted'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--per', type=int, default=30, help='每个 CEFR 等级抽多少词')
    ap.add_argument('--cached', action='store_true', help='复用上次结果')
    args = ap.parse_args()

    if args.cached and os.path.exists(OUT):
        saved = json.load(open(OUT, encoding='utf-8'))
        items = saved['items']
        print(f'复用缓存 {len(items)} 条')
    else:
        items = sample(DB, args.per)
        print(f'分层抽样 {len(items)} 词（每级 {args.per}）')
        key = load_key()
        usage = {'in': 0, 'out': 0}
        for i, it in enumerate(items, 1):
            r = call_llm(key, it['word'])
            it.update(r)
            if r.get('ok'):
                usage['in'] += r.get('in_tok', 0)
                usage['out'] += r.get('out_tok', 0)
            if i % 10 == 0 or i == len(items):
                ok = sum(1 for x in items if x.get('ok'))
                print(f'  {i}/{len(items)}  成功 {ok}  in={usage["in"]} out={usage["out"]}')
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        json.dump({'_meta': {'model': MODEL, 'per_level': args.per, 'usage': usage},
                   'items': items}, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        cost = usage['in'] * 1.5 / 1e6 + usage['out'] * 4.5 / 1e6
        print(f'成本 ≈ ¥{cost:.3f}')

    # ── 对比分析 ──
    valid = [x for x in items if x.get('ok')]
    if not valid:
        print('无有效结果'); return
    print()
    print('=' * 92)
    print(f'对比分析（有效样本 {len(valid)}）')
    print('=' * 92)

    tp = sum(1 for x in valid if x['rule'] and x['analyzable'])      # 规则说可拆 & LLM 说可拆
    fp = sum(1 for x in valid if x['rule'] and not x['analyzable'])  # 规则说可拆 & LLM 说不可
    fn = sum(1 for x in valid if not x['rule'] and x['analyzable'])  # 规则说不可 & LLM 说可拆
    tn = sum(1 for x in valid if not x['rule'] and not x['analyzable'])
    n = len(valid)

    print(f'\n  规则法 vs LLM 判定（混淆矩阵）')
    print(f'  {"":<18}{"LLM 可拆":>10}{"LLM 不可拆":>12}')
    print(f'  {"规则 可拆":<18}{tp:>10}{fp:>12}')
    print(f'  {"规则 不可拆":<18}{fn:>10}{tn:>12}')

    prec = tp / (tp + fp) * 100 if tp + fp else 0
    rec = tp / (tp + fn) * 100 if tp + fn else 0
    acc = (tp + tn) / n * 100
    print(f'\n  🔴 规则法准确率 (precision): {prec:.1f}%   ← 规则说可拆的里，有多少真的可拆')
    print(f'  🔴 规则法召回率 (recall)   : {rec:.1f}%   ← 真可拆的里，规则命中了多少')
    print(f'  整体一致率                 : {acc:.1f}%')

    llm_rate = sum(1 for x in valid if x['analyzable']) / n * 100
    rule_rate = sum(1 for x in valid if x['rule']) / n * 100
    print(f'\n  真实「可拆率」(LLM)  : {llm_rate:.1f}%')
    print(f'  规则法「可拆率」     : {rule_rate:.1f}%')
    print(f'  → 推算全词表（11,917）: LLM 法 ≈ {round(11917*llm_rate/100):,} 词   规则法 ≈ {round(11917*rule_rate/100):,} 词')

    print(f'\n  分等级真实可拆率:')
    print(f'  {"等级":<6}{"样本":>6}{"LLM可拆":>9}{"占该级":>9}{"规则法":>8}')
    for lv in ('A1', 'A2', 'B1', 'B2', 'C1'):
        sub = [x for x in valid if x['level'] == lv]
        if not sub:
            continue
        a = sum(1 for x in sub if x['analyzable'])
        print(f'  {lv:<6}{len(sub):>6}{a:>9}{a/len(sub)*100:>8.1f}%'
              f'{sum(1 for x in sub if x["rule"])/len(sub)*100:>7.1f}%')

    print(f'\n 🔴 规则法误判样例（说可拆但实际不可拆，前 20）:')
    for x in [y for y in valid if y['rule'] and not y['analyzable']][:20]:
        print(f'    {x["word"]:<18} [{x["level"]}]')

    print(f'\n ⚠️ 规则法漏判样例（说不可拆但实际可拆，前 12）:')
    for x in [y for y in valid if not y['rule'] and y['analyzable']][:12]:
        parts = ' + '.join(p.get('form', '') for p in x.get('parts', []))
        print(f'    {x["word"]:<18} [{x["level"]}]  → {parts}')

    print(f'\n ✅ LLM 拆分样例（可信的）:')
    for x in [y for y in valid if y['analyzable']][:10]:
        parts = ' + '.join(f"{p.get('form','')}({p.get('meaning','')})" for p in x.get('parts', []))
        print(f'    {x["word"]:<18} {parts}')


if __name__ == '__main__':
    main()
