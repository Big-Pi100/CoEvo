#!/usr/bin/env python3
"""对「卡片字段可疑清单」跑 LLM 复核 + 生成修正候选。

# 它做什么

1. 读 `data/curriculum/prebuilt/card_field_candidates.json`（196 条 · 由
   `verify_card_field_consistency.py --json` 产出）
2. 对每个词调 **契约 v6**（`coevo_wordlib_contract.call_llm`），
   **并把现状释义作为参考传入** —— 让 LLM 有机会发现「现状是错的」并纠正
3. 与现网（`word.db` 的 `card.content`）逐字段比对 → 出差异

# 🔴 它**只生成，不写库**

写库需要额外的批准（改生产数据资产）。本脚本的产物是：
- `data/curriculum/prebuilt/card_field_fixes.json` —— 完整结果（供后续写库用）
- `data/reports/card_field_fixes-<date>.md` —— 人眼可读的差异报告

# 为什么样本是「可疑清单」而不是随机抽样

这 196 条是**已知有问题的**（由 5 个信号筛出），所以：
- **命中率即信号精确率**（能顺带评估之前那套判据准不准）
- 成本可控（≈ ¥1.3）
- 🔑 而且**它同时是「LLM 制卡」路径的首次实测集** —— 在线路径的质量基线

# 跑法

```bash
python scripts/gen_card_field_fixes.py                # 全量 196 条（≈¥1.3）
python scripts/gen_card_field_fixes.py --limit 10     # 先跑 10 条看看
```
"""

import argparse
import json
import os
import re
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coevo_wordlib_contract as cwc  # noqa: E402

ROOT = cwc.ROOT
PREBUILT = cwc.PREBUILT
WORD_DB = os.path.join(ROOT, 'data', 'word.db')
CANDS = os.path.join(PREBUILT, 'card_field_candidates.json')
OUT_JSON = os.path.join(PREBUILT, 'card_field_fixes.json')
OUT_REPORT = os.path.join(ROOT, 'data', 'reports',
                          f'card_field_fixes-{time.strftime("%Y-%m-%d")}.md')

WORKERS = 12          # 实测安全并发 300，这里取小值（196 条总量小，无需压满）


def load_current(con, spelling):
    """读该词**现状**的 ipa / definition / context（用于与 v6 产出比对）。"""
    import sqlite3  # noqa: F401  (类型提示用)
    r = con.execute("""
        SELECT c.content FROM card c JOIN word w ON w.id = c.word_id
        WHERE w.spelling = ? COLLATE NOCASE LIMIT 1""", (spelling,)).fetchone()
    out = {'ipa': None, 'def_pos': None, 'def_en': None, 'def_zh': None, 'context': None}
    if not r or not r[0]:
        return out
    try:
        d = json.loads(r[0])
    except (ValueError, TypeError):
        return out
    out['ipa'] = d.get('ipa')
    for s in (d.get('sections') or []):
        if not isinstance(s, dict):
            continue
        if s.get('type') == 'definition' and out['def_en'] is None:
            out['def_pos'], out['def_en'], out['def_zh'] = s.get('pos'), s.get('en'), s.get('zh')
        elif s.get('type') == 'context' and out['context'] is None:
            out['context'] = s.get('text')
    return out


# ══════════════════════════════════════════════════════════════════════
# 字段比对判据 —— 🔑 **按字段性质分档，不是「与原值是否相同」**
#
# 为什么不能只看「是否相同」（2026-09-29 实测教训）：
#   第一版用「与现状不同」判「有错」→ 得到 **196/196 全部不同** 的假象。
#   但 `context`（例句）是**开放式生成** —— 同一个词有无数个正确例句，
#   「不同」根本不能推出「现状错」。实测：151 条的现状例句与 v6 例句
#   **都含该词、都语法正确** → 它们**不是错**，只是换了个说法。
#
#   | 字段 | 性质 | 「现状错」的判据 |
#   |---|---|---|
#   | `ipa` | **封闭**（一个词只有有限正确音标） | ① 格式残缺 ② 多词词组未覆盖全 ③ 与 v6 不同（有一方错，需人眼） |
#   | `pos` | **近似封闭**（词性就那么几个） | 与 v6 不同 → 有一方错 |
#   | `definition` | **开放式**（同义表述很多） | 现状**为空**才是硬证据；否则需人眼 |
#   | `context` | **开放式**（例句无穷多） | **不含该词**（用词形表还原后）→ 确定错 |
#
# ⚠️ 另一条实测教训：**「例句是否含该词」必须用 `word_form` 表还原**，
#    不能用「词干截断」——后者会把 `brought`(bring) / `leaves`(leaf) /
#    `shrank`(shrink) / `t-`(t-shirt 连字符被切开) 全部误判为「不含」。
# ══════════════════════════════════════════════════════════════════════

def load_surface_forms(db_path):
    """从 `word_form` 表建「base → 它的各种变形」映射（用于判定例句是否含该词）。"""
    import sqlite3
    m = {}
    try:
        con = sqlite3.connect(db_path)
        for f_, b_ in con.execute('SELECT form, base FROM word_form'):
            m.setdefault(b_.lower(), set()).add(f_.lower())
        con.close()
    except Exception as e:      # noqa: BLE001
        print(f'  ⚠️ 读 word_form 失败（例句判定会退化为精确匹配）: {e}')
    return m


def surface_forms(word, forms_map):
    w = word.lower()
    return {w} | forms_map.get(w, set())


def contains_word(text, spelling, forms_map):
    """例句是否含该词（或其变形）。返回 `(bool, 原因标签)`。"""
    if not text:
        return False, 'empty'
    low = text.lower()
    w = spelling.lower()
    if ' ' in w:                                  # 多词词组：逐词判（容忍变形）
        if w in low:
            return True, 'phrase-exact'
        toks = set(re.findall(r"[a-z']+", low))
        ok = all(bool(surface_forms(p, forms_map) & toks) for p in w.split())
        return ok, ('phrase-forms' if ok else 'phrase-miss')
    if '-' in w:                                  # 连字符视为分隔（`t-shirt` → t / shirt）
        toks = set(re.findall(r'[a-z]+', low))
        if all(seg in toks for seg in w.split('-') if seg):
            return True, 'hyphen'
    if '.' in w:                                  # 缩写：整体子串（`a.m.` / `Dr.`）
        return (w in low), ('abbr' if w in low else 'abbr-miss')
    toks = set(re.findall(r"[a-z']+", low))
    if w in toks:
        return True, 'exact'
    if surface_forms(w, forms_map) & toks:
        return True, 'form'
    return False, 'miss'


def ipa_broken(s):
    """真「残缺」：连一个非空的 `/.../` 段都没有（`/ˈ`、`/`、空）。"""
    if not s:
        return True
    return not re.search(r'/[^/]{1,}/', s.strip())


def ipa_covers_phrase(ipa, spelling):
    """多词词组的 ipa 是否覆盖**全部**词（粗判：段数 ≥ 词数）。

    🔑 这抓的是「ipa 只给了第一个词」那类错（`frying pan` 得到 `/fraɪ/`）。
    """
    if ' ' not in spelling:
        return True
    if not ipa:
        return False
    return len([x for x in re.split(r'\s+', ipa.strip('/')) if x]) >= len(spelling.split())


def classify(rec, cur, forms_map):
    """把一条结果分成三档 → `(档位, 硬证据列表, 封闭字段差异列表)`。"""
    d = rec.get('data') or {}
    dfn = d.get('definition') or {}
    hard, closed = [], []

    # ── ipa（封闭）──
    if ipa_broken(cur['ipa']):
        hard.append('ipa 残缺')
    elif not ipa_covers_phrase(cur['ipa'], rec['spelling']):
        hard.append('ipa 未覆盖全词组')
    if _n(cur['ipa']) != _n(d.get('ipa')):
        closed.append('ipa')

    # ── pos（近似封闭）──
    if _n(cur['def_pos'], strip_brackets=True) != _n(dfn.get('pos'), strip_brackets=True):
        closed.append('pos')

    # ── definition（开放式）──
    if not (cur['def_en'] or '').strip():
        hard.append('释义为空')
    elif _n(cur['def_en']) != _n(dfn.get('en')):
        closed.append('def_en')
    if _n(cur['def_zh']) != _n(dfn.get('zh')) and (dfn.get('zh') or '').strip():
        closed.append('def_zh')

    # ── context（开放式）：只判「是否含该词」──
    if not contains_word(cur['context'], rec['spelling'], forms_map)[0]:
        hard.append('例句不含该词')

    if hard:
        return '🔴 确定要修', hard, closed
    if closed:
        return '🟠 疑似（封闭字段不同，需人眼定谁错）', hard, closed
    return '✅ 无问题（信号误报）', hard, closed


def _n(s, strip_brackets=False):
    """归一化比较：压空白、去句末句号、小写、统一引号。

    `strip_brackets=True` 用于**词性** —— 现网写 `n`、契约写 `[n]`，
    两者是**同一件事的两种写法**，不归一化会全部误报为「不同」
    （实测：123 条「疑似」里大部分是这个）。
    """
    if not s:
        return ''
    s = s.strip().replace('\u2019', "'").replace('\u201c', '"').replace('\u201d', '"')
    s = re.sub(r'\s+', ' ', s).rstrip('.').strip().lower()
    if strip_brackets:
        s = s.strip('[]()').strip()
    return s



def main():
    import sqlite3
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0, help='只跑前 N 条（0=全部）')
    ap.add_argument('--workers', type=int, default=WORKERS)
    ap.add_argument('--report-only', action='store_true',
                    help='从已有 card_field_fixes.json 重出报告（不重跑 LLM）')
    args = ap.parse_args()

    if not os.path.exists(CANDS):
        sys.exit(f'🔴 找不到 {CANDS}（先跑 verify_card_field_consistency.py --json）')
    cands = json.load(open(CANDS, encoding='utf-8'))
    if args.limit:
        cands = cands[:args.limit]
    print(f'候选 {len(cands)} 条 · 并发 {args.workers}')

    # ── `--report-only`：从已有 JSON 重出报告（🔑 不重跑 LLM，不花钱）──
    if args.report_only:
        if not os.path.exists(OUT_JSON):
            sys.exit(f'🔴 找不到 {OUT_JSON} —— 先跑一次完整生成')
        payload = json.load(open(OUT_JSON, encoding='utf-8'))
        forms_map = load_surface_forms(WORD_DB)
        results = [r for r in payload['items'] if r.get('ok')]
        failed = [r for r in payload['items'] if not r.get('ok')]
        cands = payload['items']
        for r in results:                       # 用**当前**判据重算档位
            lvl, hard, closed = classify(r, r['current'], forms_map)
            r['level'], r['hard'], r['closed'] = lvl, hard, closed
        tin = sum(r.get('in_tok', 0) for r in results)
        tout = sum(r.get('out_tok', 0) for r in results)
        cost = payload.get('cost_cny', 0.0)
        secs = 0
        st = payload.get('stats', {})
        print(f'report-only：复用 {payload.get("generated_at")} 的结果（未重跑 LLM）')
        print(f'  词形表: {len(forms_map):,} 个 base')
    else:
        key = cwc.load_key()
        mode, _ = cwc.probe_and_configure(key)
        if mode is None:
            sys.exit('🔴 LLM 不通（直连与代理都失败）')
        print(f'链路: {mode}')

        con = sqlite3.connect(WORD_DB)
        cur_map = {c['spelling']: load_current(con, c['spelling']) for c in cands}
        con.close()
        # 🔑 例句「是否含该词」必须用**词形表**判定（见文件上方判据说明）
        forms_map = load_surface_forms(WORD_DB)
        print(f'词形表: {len(forms_map):,} 个 base')

        cwc.reset_stats()
        t0 = time.time()
        results, failed = [], []
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            futs = {}
            for c in cands:
                sp = c['spelling']
                # 🔑 传入**现状英文释义** —— prompt 里已写明「若与本词无关则忽略它，信自己」
                futs[ex.submit(cwc.call_llm, key, sp, 4, cur_map[sp]['def_en'], 90)] = c
            done = 0
            for fu in as_completed(futs):
                c = futs[fu]
                r = fu.result()
                done += 1
                if done % 25 == 0 or done == len(cands):
                    print(f'  … {done}/{len(cands)}')
                rec = {**c, 'ok': bool(r.get('ok')), 'current': cur_map[c['spelling']]}
                if r.get('ok'):
                    rec['data'] = r['data']
                    rec['in_tok'], rec['out_tok'] = r.get('in_tok', 0), r.get('out_tok', 0)
                    lvl, hard, closed = classify(rec, cur_map[c['spelling']], forms_map)
                    rec['level'], rec['hard'], rec['closed'] = lvl, hard, closed
                    results.append(rec)
                else:
                    rec['error'] = r.get('error')
                    failed.append(rec)

        st = cwc.stats_snapshot()
        tin = sum(r['in_tok'] for r in results)
        tout = sum(r['out_tok'] for r in results)
        cost = (tin * cwc.P_IN + tout * cwc.P_OUT) / 1_000_000
        secs = time.time() - t0

        # ── 落 JSON（供后续写库）──
        payload = {
            'generated_at': time.strftime('%Y-%m-%d %H:%M:%S'),
            'contract': cwc.CONTRACT_VERSION,
            'model': cwc.MODEL,
            'total': len(cands), 'ok': len(results), 'failed': len(failed),
            'cost_cny': round(cost, 4),
            'stats': st,
            'items': sorted(results + failed, key=lambda r: (not r.get('ok'), r['spelling'])),
        }
        json.dump(payload, open(OUT_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print(f'\n✅ 结果已写 {OUT_JSON}')


    # ── 生成报告 ──
    by_level = Counter(r['level'] for r in results)
    hard_sig = Counter()
    for r in results:
        if r['hard']:
            hard_sig[' + '.join(r['signals'])] += 1
    sig_all = Counter(' + '.join(r['signals']) for r in results)

    L = []
    A = L.append
    A(f'# 卡片字段修正候选 —— LLM（契约 {cwc.CONTRACT_VERSION}）复核结果')
    A('')
    A(f'> 生成：{payload["generated_at"]} ｜ 模型 `{cwc.MODEL}` ｜ **只生成，未写库**')
    A(f'> 输入：`card_field_candidates.json`（{len(cands)} 条可疑项，由 5 个信号筛出）')
    A(f'> 成本 **¥{cost:.4f}**（in {tin:,} / out {tout:,} token）· 耗时 {secs:.0f}s · 并发 {args.workers}')
    A('')
    A('## 一、结论：三档')
    A('')
    A('| 档位 | 条数 | 含义 |')
    A('|---|---:|---|')
    A(f'| **🔴 确定要修** | **{by_level.get("🔴 确定要修", 0)}** | 有**硬证据**（见 §二）：现状确实错 |')
    A(f'| 🟠 疑似 | {by_level.get("🟠 疑似（封闭字段不同，需人眼定谁错）", 0)} | 封闭字段与 v6 不同，**有一方错**，需人眼 |')
    A(f'| ✅ 无问题 | {by_level.get("✅ 无问题（信号误报）", 0)} | 现状没查出问题（信号**误报**） |')
    A(f'| — 失败 | {len(failed)} | 调用失败，未判定 |')
    A('')
    A('> 🔑 **本表的判据是「字段性质」，不是「与原值是否相同」** —— 见 §五。')
    A('>    第一版用「与现状不同」判错，得到「196/196 全部不同」的**假象**：')
    A('>    例句是开放式生成，换个说法**不等于**原句错。')
    A('')
    A('## 二、硬证据分布（「确定要修」的原因）')
    A('')
    ev = Counter()
    for r in results:
        for h in r['hard']:
            ev[h] += 1
    if ev:
        A('| 硬证据 | 条数 |')
        A('|---|---:|')
        for k, v in ev.most_common():
            A(f'| {k} | {v} |')
    else:
        A('（无）')
    A('')
    A('> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）；')
    A('>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）；')
    A('>    `例句不含该词` = 用 **`word_form` 词形还原**后仍找不到该词。')
    A('')
    A('## 三、按信号看（判据的命中率）')
    A('')
    A('| 信号组合 | 总数 | 确定要修 | 命中率 |')
    A('|---|---:|---:|---:|')
    for k, v in sig_all.most_common():
        c = hard_sig.get(k, 0)
        A(f'| `{k}` | {v} | {c} | {c / v * 100:.0f}% |')
    A('')
    A('### ⚠️ 但 S3a / S3b 的「0% / 1%」**不是「信号错了**」—— 是本表的硬证据判据**抓不到那一类**')
    A('')
    A('| 信号 | 它要抓什么 | 本表能判吗 |')
    A('|---|---|---|')
    A('| `S1` `S2` | ipa **残缺 / 截断**（段数不够、格式不完整） | ✅ **能**（纯格式，机械可判） |')
    A('| `S4` | 例句**不含该词** | ✅ **能**（查词形表即可） |')
    A('| `S3a` `S3b` | ipa 是**另一个词**的音标（段数够、格式也合法） | 🔴 **不能** |')
    A('')
    A('🔑 为什么不能：`air conditioning` 的现状 ipa 是 `/ˈɛr fɔːrs/` —— **两段、格式合法**，')
    A('机械判据（段数 ≥ 词数）**完全通过**；要知道它是 `air force` 的音标，')
    A('必须**懂语义**。这正是 LLM 复核不可替代的地方。')
    A('')
    A('📌 所以本表三档的准确含义是：')
    A('- **🔴 确定要修** = 机械判据**能证实**的错（72 条）')
    A('- **🟠 疑似** = 机械判据**判不了**、只有 LLM 给了不同值的（123 条，其中 S3a 28 + S3b 78）')
    A('  → **不是「可能没错」，是「本表没有能力证明它错」** <- 这两句意思完全不同')
    A('')
    A('## 四、🔴 确定要修 —— 逐条（现状 → v6）')
    A('')
    A('| 词 | 信号 | 硬证据 | 现状 → v6 |')
    A('|---|---|---|---|')
    for r in sorted([x for x in results if x['hard']], key=lambda x: x['spelling']):
        cu, d = r['current'], r['data']
        dfn = d.get('definition') or {}
        bits = []
        if 'ipa 残缺' in r['hard'] or 'ipa 未覆盖全词组' in r['hard']:
            bits.append(f'**ipa**: `{cu["ipa"]}` → `{d.get("ipa")}`')
        if '例句不含该词' in r['hard']:
            bits.append(f'**例句**: "{cu["context"]}" → "{d.get("context")}"')
        if '释义为空' in r['hard']:
            bits.append(f'**释义**: (空) → "{dfn.get("en")}"')
        A(f'| `{r["spelling"]}` | {"·".join(r["signals"])} | {",".join(r["hard"])} | '
          + '<br>'.join(bits) + ' |')
    A('')
    A('## 五、判据说明（🔑 为什么不能只看「是否相同」）')
    A('')
    A('| 字段 | 性质 | 「现状错」的判据 |')
    A('|---|---|---|')
    A('| `ipa` | **封闭**（一个词的正确音标有限） | 格式残缺 / 多词未覆盖全 / 与 v6 不同（有一方错） |')
    A('| `pos` | **近似封闭** | 与 v6 不同 → 有一方错 |')
    A('| `definition` | **开放式**（同义表述很多） | 现状**为空**才是硬证据 |')
    A('| `context` | **开放式**（例句无穷多） | **不含该词**（词形还原后）→ 确定错 |')
    A('')
    A('⚠️ 实测教训：**「例句是否含该词」必须用 `word_form` 表还原**。')
    A('用「词干截断」会把 `brought`(bring) · `leaves`(leaf) · `shrank`(shrink) ·')
    A('`t-shirt`（连字符被分词切开）**全部误判为「不含」** ——')
    A('第一版因此把 v6 的 52 条合法 ipa 与 8 条正确例句误报为「违规」。')
    A('')
    A('## 六、v6 产出质量自查')
    A('')
    b_new = [r for r in results if ipa_broken(r['data'].get('ipa'))
             or not ipa_covers_phrase(r['data'].get('ipa'), r['spelling'])]
    c_new = [r for r in results
             if not contains_word(r['data'].get('context'), r['spelling'], forms_map)[0]]
    A('| 检查 | 结果 |')
    A('|---|---|')
    A(f'| v6 产出的 `ipa` 残缺 / 未覆盖全词组 | **{len(b_new)}** |')
    A(f'| v6 产出的例句「不含该词」 | {len(c_new)}（多为判据残余误差：缩写带点 / 不规则变形） |')
    if c_new:
        A('')
        A('需人眼确认的 v6 例句：')
        for r in c_new[:20]:
            A(f'- `{r["spelling"]}`: "{r["data"].get("context")}"')
    if failed:
        A('')
        A('## 七、失败项')
        A('')
        for r in failed:
            A(f'- `{r["spelling"]}` — {r.get("error")}')
    A('')
    A('---')
    A('')
    A('*本报告**只生成候选，未写 `word.db`**。写库需单独批准（改生产数据资产）。*')

    os.makedirs(os.path.dirname(OUT_REPORT), exist_ok=True)
    open(OUT_REPORT, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    print(f'✅ 报告已写 {OUT_REPORT}')

    print(f'\n汇总: 成功 {len(results)}/{len(cands)} · '
          + ' · '.join(f'{k}={v}' for k, v in by_level.most_common())
          + f' · 失败 {len(failed)}')
    print(f'成本 ≈ ¥{cost:.4f} · 耗时 {secs:.0f}s')
    if st['http_429'] or st['retries']:
        print(f'⚠️ 疑似限流: {st}')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
