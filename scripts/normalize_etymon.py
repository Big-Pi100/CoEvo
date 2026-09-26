#!/usr/bin/env python3
"""`etymon.form_ascii` 归一化 —— 同一源词的不同转写合并

解决的问题（2026-09-26 全量复核发现）：
  LLM 给同一历史源词输出**不同转写**，`UNIQUE(form_ascii, language)` 视为不同条目
  → **词源族被拆开**。实测 **108 组**影响聚合页，其中 **18 组因此完全没有页**。

    同一个希腊词 γράφειν：  grafein (12 词)  vs  graphein (24 词)
    其他：up/upp · well/wel · iustus/justus · tekhne/techne · cognoscere/gnoscere
          sceoppa/scoppa · eligere/seligere · god/good（OE 里 god 就是 good）

🔴 为什么必须用 LLM 而不是规则：
  简单规则会**误合并不同的词**。实测「去掉 h 后同形」会命中：
      hand (手) vs and (和)      ← OE 的 h 是词义的一部分，不是转写差异
      haer (头发) vs aer (空气)
  规则无法区分「转写差异」与「真的不同词」—— 需要语义判断（这就是它和
  `build_affix_table.py` 里"词缀同义归一化"是同一类任务的体现）。

设计（与词缀归一化同构）：
  ① 候选生成：按语言分桶 + 归一化后字符串相似度≥0.82 → **连通分量**成簇
     （不做两两组合 → 826 簇而非 6270 对，LLM 输入小一个量级）
  ② LLM 只判两件事：**这簇里哪些是同一个源词** + **规范形该取哪个**
  ③ 产出 canonical → 落 `etymon_canonical.json`，供落库时合并族

用法：
  python3 scripts/normalize_etymon.py --dry-run   # 只出候选与统计
  python3 scripts/normalize_etymon.py             # 跑 LLM 归一化，产出 JSON
"""
import argparse
import difflib
import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

WORD_DB = os.path.join(cwc.ROOT, 'data', 'word.db')
OUT = os.path.join(cwc.PREBUILT, 'etymon_canonical.json')

SIM_THRESHOLD = 0.86
MAX_LEN_DIFF = 2
MAX_CLUSTER = 12       # 单簇上限（超过说明阈值太松，会失真）
SKEL_NEAR = 0.88       # 骨架相似度门槛（近变体候选）


def skeleton(s: str) -> str:
    """把常见**转写变体**折叠成同一骨架

    🔑 覆盖的等价关系（实测驱动）：
      i↔j (iustus/justus, iungere/jungere) · u↔v · k↔c (tekhne/techne)
      ph↔f (graphein/grafein) · ae/oe→e · y→i · 叠字母归一 (up/upp, well/wel)
    实测效果：真变体全部折叠为一，而 `hand`(手)/`and`(和) 的骨架仍不同 ✅
      —— 因为 OE 的 `h` 是词义的一部分，不是转写差异。
    """
    s = s.lower().strip('-')
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    s = s.replace('ph', 'f').replace('ck', 'c').replace('qu', 'cu')
    s = s.replace('j', 'i').replace('v', 'u').replace('k', 'c').replace('y', 'i')
    s = s.replace('ae', 'e').replace('oe', 'e').replace('w', 'u')
    s = re.sub(r'(.)\1+', r'\1', s)          # 叠字母归一
    return s


def build_clusters(items, threshold=SIM_THRESHOLD):
    """两层候选生成 → [(tier, [items…])]

    ① **骨架完全相同**（`tier='exact'`）—— 几乎必然是同一源词的转写变体
       （实测：`iustus/justus` · `up/upp` · `graphein/grafein` · `iungere/jungere`）
    ② **骨架高度相近**（`tier='near'`，≥`SKEL_NEAR`）—— 需 LLM 判
       （实测：`sceoppa/scoppa` 0.91 · `cognoscere/gnoscere` 0.89）

    🔴 不用连通分量：会**链式传递** —— 实测一个 Latin 簇膨胀到 400+ 词。
       改用**领导者聚类**（按词数多的当锚点，只收与锚点达标的），簇规模可控。
    """
    out = []

    # ① 骨架完全相同的分组
    by_skel = defaultdict(list)
    for it in items:
        k = skeleton(it['form'])
        if len(k) >= 2:
            by_skel[k].append(it)
    exact = []
    for k, v in by_skel.items():
        if len(v) < 2:
            continue
        if len(v) > MAX_CLUSTER:            # 骨架过于激进 → 降级为 near 处理
            v = sorted(v, key=lambda x: -x['words'])[:MAX_CLUSTER]
        exact.append(v)
    for v in exact:
        out.append(('exact', v))

    # ② 骨架相近的（领导者聚类，避开链式）
    covered = {it['form'] for v in exact for it in v}
    pool = sorted([it for it in items if it['form'] not in covered],
                  key=lambda x: (-x['words'], x['form'].lower()))
    used = set()
    for i, leader in enumerate(pool):
        if i in used:
            continue
        ls = skeleton(leader['form'])
        if len(ls) < 3:
            continue
        members = [leader]
        used.add(i)
        for j in range(i + 1, len(pool)):
            if j in used or len(members) >= MAX_CLUSTER:
                break
            js = skeleton(pool[j]['form'])
            if len(js) < 3 or abs(len(ls) - len(js)) > MAX_LEN_DIFF:
                continue
            if difflib.SequenceMatcher(None, ls, js).ratio() >= SKEL_NEAR:
                members.append(pool[j])
                used.add(j)
        if len(members) >= 2:
            out.append(('near', members))
    return out

PROMPT = """You are an expert historical linguist validating whether **etymology source words** are the same word written differently.

Below is ONE cluster of source-word spellings that all belong to the same language. They came from an automatic process and are suspected to be **the same source word written in different transliterations or spellings**.

LANGUAGE: {language}

CANDIDATES (form | gloss in Chinese | number of English words traced to it):
{items}

TASK: decide which candidates are **THE SAME source word**.

⚠️ CRITICAL — these are NOT the same word, keep them SEPARATE:
   * Different words that merely look similar. Classic traps:
       "hand"(手) vs "and"(和)   — the "h" is part of the word, not a transliteration variant
       "haer"(头发) vs "aer"(空气)
       "man"(人) vs "manere"(停留) — different Latin words
   * If the glosses describe DIFFERENT concepts, they are different words.

✅ These ARE the same word:
   * Same gloss + transliteration variants of one script:
       grafein / graphein (both γράφειν "写")
       iustus / justus, tekhne / techne, graecus / graikos
   * Doubled/single letter variants: up / upp, well / wel, scen / scene
   * Same-language dialectal spellings of one word, same meaning.

Return STRICT JSON:
{{
  "groups": [
    {{
      "members": ["<form>", "<form>", ...],
      "canonical": "<the best/most standard spelling, must be one of members>",
      "reason": "≤20字中文"
    }}
  ]
}}

RULES:
- Every candidate must appear in EXACTLY ONE group (including singletons).
- Only put 2+ members in a group when you are CONFIDENT they are the same word.
- 🔴 When in doubt, KEEP THEM SEPARATE (singletons). A wrong merge is worse than a missed merge.
- `canonical` must be the most standard/recognizable spelling among the members.
- Output JSON only, no prose, no markdown fences."""


def load_etymons():
    con = sqlite3.connect(WORD_DB)
    rows = con.execute("""
        SELECT e.form_ascii, e.language, coalesce(e.meaning_zh,''),
               (SELECT count(DISTINCT we.word_id) FROM word_etymon we WHERE we.etymon_id = e.id)
        FROM etymon e""").fetchall()
    con.close()
    by_lang = defaultdict(list)
    for a, l, m, dc in rows:
        by_lang[l or 'other'].append({'form': a, 'meaning': m, 'words': dc})
    return by_lang


def merge_group(forms, lang, key, retries=3):
    """调 LLM 判一组是否同源 → [(canonical, [members]), ...]"""
    lines = '\n'.join(
        f'  - {f["form"]} | {f["meaning"] or "（无释义）"} | {f["words"]} 词' for f in forms)
    content = PROMPT.format(language=lang, items=lines)
    for attempt in range(retries):
        r = _call(key, content)
        if r.get('ok'):
            gs = (r['data'] or {}).get('groups')
            if isinstance(gs, list):
                return gs, r
        if attempt < retries - 1:
            import time
            time.sleep(2 ** attempt)
    return None, r


def _call(key, content):
    """直连长连接调用（复用契约里的连接管理）"""
    import http.client
    body = json.dumps({
        'model': cwc.MODEL,
        'messages': [{'role': 'user', 'content': content}],
        'temperature': 0.1,
        'max_tokens': 1500,
        'response_format': {'type': 'json_object'},
        'thinking': cwc.THINKING,
    })
    try:
        c = cwc._conn_get(60)
        c.request('POST', cwc._PATH, body=body,
                  headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'})
        r = c.getresponse()
        raw = r.read()
        if r.status != 200:
            cwc._conn_reset()
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
        return {'ok': False, 'error': f'{type(e).__name__}: {e}'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--workers', type=int, default=100)
    ap.add_argument('--no-proxy', action='store_true', default=True,
                    help='默认直连（代理是并发瓶颈）')
    args = ap.parse_args()

    cwc.set_proxy(False)
    by_lang = load_etymons()
    total = sum(len(v) for v in by_lang.values())
    print(f'  etymon 共 {total} 个 · 语言 {len(by_lang)} 种')

    clusters = []
    for lang, items in by_lang.items():
        for tier, c in build_clusters(items):
            clusters.append((lang, c, tier))
    n_exact = sum(1 for _, _, t in clusters if t == 'exact')
    print(f'  候选簇 {len(clusters)}（骨架相同 {n_exact} · 骨架相近 {len(clusters)-n_exact}）'
          f' · 涉及 etymon {sum(len(c) for _, c, _ in clusters)}')

    if args.dry_run:
        print()
        print('  【骨架相同】样例（几乎必然要合并）:')
        for lang, c, t in sorted([x for x in clusters if x[2] == 'exact'],
                                 key=lambda x: -sum(f['words'] for f in x[1]))[:12]:
            print(f'    {lang:<14} {", ".join(f["form"] for f in c)}')
        print()
        print('  【骨架相近】样例（需 LLM 判断）:')
        for lang, c, t in sorted([x for x in clusters if x[2] == 'near'],
                                 key=lambda x: -sum(f['words'] for f in x[1]))[:8]:
            print(f'    {lang:<14} {", ".join(f["form"] for f in c)}')
        print('\n  （--dry-run，未调 LLM）')
        return

    key = cwc.load_key()
    cwc.reset_stats()
    from concurrent.futures import ThreadPoolExecutor, as_completed
    import time
    t0 = time.time()
    results = {'merged': [], 'kept': [], 'unresolved': []}
    tin = tout = 0

    def work(item):
        lang, forms, tier = item
        return item, merge_group(forms, lang, key)

    print(f'  跑 LLM 归一化（{args.workers} 并发）...')
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(work, it) for it in clusters]
        for i, f in enumerate(as_completed(futs), 1):
            (lang, forms, tier), (groups, r) = f.result()
            tin += r.get('in_tok', 0)
            tout += r.get('out_tok', 0)
            formset = {x['form'] for x in forms}
            if not groups:
                results['unresolved'].append({'language': lang, 'tier': tier,
                                              'forms': sorted(formset),
                                              'error': r.get('error')})
                continue
            for g in groups:
                ms = [m for m in (g.get('members') or []) if m in formset]
                canon = g.get('canonical')
                if len(ms) >= 2 and canon in ms:
                    results['merged'].append({'language': lang, 'tier': tier, 'canonical': canon,
                                              'members': ms, 'reason': g.get('reason')})
                else:
                    for m in ms or sorted(formset):
                        results['kept'].append({'language': lang, 'form': m})
            if i % 100 == 0 or i == len(clusters):
                el = time.time() - t0
                print(f'    {i}/{len(clusters)}  {i/el:.1f} 簇/秒  ETA {(len(clusters)-i)/(i/el)/60:.1f} min')

    cost = tin * cwc.P_IN / 1e6 + tout * cwc.P_OUT / 1e6
    print(f'\n  ✅ 合并组 {len(results["merged"])} · 单例 {len(results["kept"])} · '
          f'未解析 {len(results["unresolved"])}')
    print(f'  成本 ≈ ¥{cost:.3f} · 耗时 {(time.time()-t0)/60:.1f} min')
    st = cwc.stats_snapshot()
    if st.get('conn_err'):
        print(f'  🟠 连接重试 {st["conn_err"]} 次（不影响结果）')

    merged_forms = {m for g in results['merged'] for m in g['members']}
    affected = {g['canonical']: g['members'] for g in results['merged']}
    print(f'\n  涉及 etymon {len(merged_forms)} 个 → 归并为 {len(affected)} 个 canonical')
    print('  TOP 样例（按影响词数）:')
    wcount = {f['form']: f['words'] for items in by_lang.values() for f in items}
    for g in sorted(results['merged'],
                    key=lambda x: -sum(wcount.get(m, 0) for m in x['members']))[:10]:
        tot = sum(wcount.get(m, 0) for m in g['members'])
        print(f'    {" + ".join(g["members"])}  →  {g["canonical"]}   （{tot} 词）  {g.get("reason", "")}')

    json.dump({'source': 'word.db', 'clusters': len(clusters),
               'cost': round(cost, 3), **results},
              open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'\n  已写 {OUT}')


if __name__ == '__main__':
    main()
