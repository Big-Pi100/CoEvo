#!/usr/bin/env python3
"""链式计算：`word_form`（形态链）+ `etymon`（词源链）

解决的问题（2026-09-26 就绪检查发现）：
  原 `build_word_form.py` 只做**扁平一跳**（词表词 → 展开变形），
  实测两处链断：
    ① LLM 的 `derived_from` 有 12.3% 指向**词表外**（`attuned`→`attune`，attune 不在词表）
    ② `etymon.parent` 有 17% 需上溯（`perceive`→`percipere`→`capere`）
  不链式 → 划词查不到卡 / 词源族聚不起来。

本脚本产出（供落库脚本读）：
  · word_form_chained.json   {form, base, rule, kind, anchor, anchor_id, depth, in_vocab, preferred}
  · etymon_chained.json      {form, form_ascii, language, meaning, role, parent, anchor_form, anchor_ascii, depth}

用法：
  python3 scripts/build_chains.py --from-sample    # 用抽样验证
  python3 scripts/build_chains.py                  # 用全量 results.jsonl
"""
import argparse
import json
import os
import sqlite3
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

ROOT = cwc.ROOT
PREBUILT = cwc.PREBUILT
SAMPLE_JSON = os.path.join(PREBUILT, 'llm_rerun_sample.json')
FULLRUN_JSONL = os.path.join(PREBUILT, 'fullrun', 'results.jsonl')
OLD_WORD_FORM = os.path.join(PREBUILT, 'word_form.json')
INTER_JSONL = os.path.join(PREBUILT, 'intermediate', 'results.jsonl')
OUT_WF = os.path.join(PREBUILT, 'word_form_chained.json')
OUT_ET = os.path.join(PREBUILT, 'etymon_chained.json')
OUT_PENDING = os.path.join(PREBUILT, 'pending_intermediate.json')
OUT_BROKEN = os.path.join(PREBUILT, 'chain_broken.json')
SENSES_SUPP = os.path.join(PREBUILT, 'senses_supplement.json')   # 补录词清单

MAX_DEPTH = 4
INFL_SUFFIX = {'ed', 'ing', 's', 'es', 'er', 'est', 'en', 'n', 'd'}


def load_records(from_sample: bool):
    """→ [{'word','level','data','intermediate'?}]

    🔑 两个来源合并：
      ① 词表词的 LLM 结果（fullrun/results.jsonl）—— 决定建卡与 vocab_new
      ② **中间节点**的补跑结果（intermediate/results.jsonl）—— 只为补全 base，不建卡
    中间节点的 `derived_from` 收进 `direct` 图后，链才能继续上溯到 anchor。
    """
    recs = []
    if from_sample:
        d = json.load(open(SAMPLE_JSON, encoding='utf-8'))
        for x in d['items']:
            data = (x.get('r1') or {}).get('data')
            if data:
                recs.append({'word': x['word'], 'level': x.get('level'), 'data': data})
        return recs

    if not os.path.exists(FULLRUN_JSONL):
        raise SystemExit(f'找不到 {FULLRUN_JSONL}')
    for line in open(FULLRUN_JSONL, encoding='utf-8'):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get('ok') and r.get('data'):
            recs.append({'word': r['word'], 'level': r.get('level'), 'data': r['data']})

    # ② 中间节点补跑结果（可缺失 —— 未补跑时链会断在该节点）
    if os.path.exists(INTER_JSONL):
        n = 0
        for line in open(INTER_JSONL, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('ok') and r.get('data'):
                recs.append({'word': r['word'], 'level': None,
                             'data': r['data'], 'intermediate': True})
                n += 1
        print(f'  已并入中间节点补跑结果: {n} 条')
    else:
        print('  ⚠️ 尚无中间节点补跑结果（intermediate/results.jsonl）'
              ' → 链断率会偏高，可跑 run_intermediate.py 补')
    return recs


def build_word_form_chain(recs, vocab):
    """形态链：form → base → ... → anchor（第一个在**新词表**的词）

    🔑 三个关键点：
      ① anchor 必须对**新词表**算 —— 落库后 `word` 表只含 `is_own_entry=true` 的词，
         若对旧词表算，`carefully`（is_own_entry=false，将不建卡）会错误地把自己当 anchor。
      ② 按 §1.2 的 `relation` 分流，给每条映射打 `action`：
         · is_own_entry=false             → keep（查词路由，必需）
         · is_own_entry=true + inflection → keep（形态归并：FSRS 要能聚合）
         · is_own_entry=true + derivation → drop（旧 rule 标错，如 owner→own 说成 comparative）
      ③ `action` 的判据必须是 **LLM 的 is_own_entry**，不是旧库的 `in_vocab`
         （实测踩坑：`carefully` 旧库有卡但 LLM 判 false → 误删会断路由）
    """
    # 0. 独立词条 / relation（按词收集）
    own_map, rel_map = {}, {}
    for r in recs:
        wl = r['word'].lower()
        d = r['data']
        own_map[wl] = bool(d.get('is_own_entry'))
        rel_map[wl] = ((d.get('morphology') or {}).get('relation') or '').lower() or None

    # 🔑 已补跑过的中间节点 —— 它们**不再进 pending**
    #    （补跑后若 derived_from 仍为空，说明它是词根词，链到此为止，不是「待补」）
    inter_done = {r['word'].lower() for r in recs if r.get('intermediate')}

    # 🔑 新词表：剔除 LLM 判 is_own_entry=false 的（不在本批的保守保留）
    vocab_new = {w for w in vocab if own_map.get(w, True)}

    # 1. 收集 form → base（两个来源合并，先建全图再算 anchor）
    direct = {}      # form_lower → (base, rule, kind, in_vocab)
    #   ① 旧 word_form 的规则展开（词表词 → 变形）
    old_pre = json.load(open(OLD_WORD_FORM, encoding='utf-8')) if os.path.exists(OLD_WORD_FORM) else []
    for r in old_pre:
        f, lm = r['form'].lower(), r['lemma'].lower()
        if f == lm or f in direct:
            continue
        direct[f] = (lm, r.get('rule'), None, 1 if r.get('in_vocab') else 0)
    #   ② LLM 的 derived_from（覆盖规则结果，质量更高）
    for r in recs:
        w = r['word']
        wl = w.lower()
        d = r['data']
        df = (d.get('derived_from') or '').strip().lower() or None
        if not df or df == wl:
            continue
        mo = d.get('morphology') or {}
        rel = (mo.get('relation') or '').lower() or None
        rule = None
        for p in (mo.get('parts') or []):
            if (p.get('type') or '') == 'suffix':
                rule = (p.get('form') or '').strip('-').lower()
        direct[wl] = (df, rule, rel, 1 if wl in vocab_new else 0)

    # 2. 递归求 anchor（从 **form 自身**起步 —— 自己若在词表则 anchor=自己）
    cache = {}

    def anchor_of(x, path=None):
        if x in cache:
            return cache[x]
        path = (path or set()) | {x}
        if x in vocab_new:
            cache[x] = (x, 0)
            return cache[x]
        nx = direct.get(x)
        if not nx or nx[0] in path or len(path) > MAX_DEPTH:
            cache[x] = (None, 0)
            return cache[x]
        a, d = anchor_of(nx[0], path)
        cache[x] = (a, d + 1 if a else 0)
        return cache[x]

    # 3. 产出全部 form（旧展开 + LLM）
    rows = []
    seen = set()

    def rel_kind(f, src_rel):
        if src_rel:
            return 'inflection' if src_rel == 'inflection' else (
                'derivation' if src_rel in ('derivation', 'compound') else None)
        return 'inflection' if f not in vocab or f in vocab else None

    # 3. 产出全部 form（旧展开 + LLM）
    rows = []
    seen = set()
    dropped_double = []

    def is_double_inflection(f, base):
        """🔴 双重变形垃圾：form 的 base 自己也是变形（`abandoneds` ← `abandoned` ← `abandon`）

        根因：旧 `build_word_form.py` 对**已经是变形的词**（`abandoned`/`aberrations`/`abiding`）
        又展开了「复数/过去/ing」→ 生成 `abandoneds`/`abandoneded`/`abandoneding`。
        实测 **5,692 条（15.4%）** 是这类垃圾。
        """
        if not base:
            return False
        b = base.lower()
        if b == f:
            return False
        # base 自己也有 base → base 是变形 → 当前 form 是「变形的变形」
        nbx = direct.get(b)
        if nbx and nbx[0] and nbx[0].lower() != b:
            # 但若 form 与 base 是「同一词的不同形态」的正常关系（如 abandoned→abandon）
            # 这里只看 base 是否为二次加工对象
            return True
        return False

    for r in old_pre:
        f = r['form'].lower()
        if f in seen:
            continue
        seen.add(f)
        base = r['lemma']
        if is_double_inflection(f, base):
            dropped_double.append((r['form'], base))
            continue
        rel = rel_map.get(f)
        kind = 'inflection' if rel in (None, 'inflection') else (
            'derivation' if rel in ('derivation', 'compound') else None)
        # 🔴 修（2026-09-26）：`base` 必须与 `anchor_of` 用的**同一张图**（`direct`）
        #    原实现：`base` 取旧 word_form 的 `lemma`，而 `anchor_of` 走 `direct`
        #    —— LLM 的 `derived_from` 会覆盖 `direct`，两者不一致时：
        #      `loathed`：base 显示 `loath`（旧规则），anchor 却按 `loathe`（LLM）算
        #      → 且 `loath` 在词表 → 该行**永远不进 pending**，`loathe` 这个真正缺的词被漏掉
        base = direct.get(f, (base,))[0] or base
        a, dep = anchor_of(f)
        # 🔑 §1.2 分流 —— **依据必须是 LLM 的 is_own_entry，不是旧库的 in_vocab**
        #    · is_own_entry=True  且 relation=derivation → drop（自己有卡，且派生，旧 rule 标错）
        #    · is_own_entry=False → keep（不建卡，**必须靠这条映射路由**）
        #    · 无 LLM 数据（不在本批）→ keep（保守）
        own = own_map.get(f)
        action = 'drop' if (own is True and f in vocab_new and rel == 'derivation') else 'keep'
        rows.append({'form': r['form'], 'base': base, 'rule': r.get('rule'),
                     'kind': kind, 'anchor': a, 'anchor_id': None,
                     'depth': dep, 'in_vocab': r.get('in_vocab', 0),
                     'action': action, 'source': 'rule_expand'})

    for r in recs:
        wl = r['word'].lower()
        nx = direct.get(wl)
        if wl in seen or not nx:
            continue
        seen.add(wl)
        df, rule, rel, in_vocab = nx
        kind = 'inflection' if rel == 'inflection' else (
            'derivation' if rel in ('derivation', 'compound') else None)
        a, dep = anchor_of(wl)
        action = 'drop' if (own_map.get(wl) and wl in vocab_new and kind == 'derivation') else 'keep'
        rows.append({'form': r['word'], 'base': df, 'rule': rule, 'kind': kind,
                     'anchor': a, 'anchor_id': None, 'depth': dep,
                     'in_vocab': in_vocab, 'action': action, 'source': 'llm_derived_from'})

    # 4. 补中间节点自身（不在词表、但被别处引用的）
    #    ⚠️ 这些节点的 base **这里填不上** —— LLM 只跑了词表词，中间节点没有自己的记录。
    #       必须导出清单交给「补跑」脚本（见 --status 的待补跑清单）。
    #    🔴 修（2026-09-26）：pending 必须从 **`direct` 图**收集，不能只从行的 `base` 字段
    #       —— 两个来源不一致时会漏（实测漏掉 `loathe`：`loathed` 的行 base 是 `loath`（在词表），
    #       但 `anchor_of` 走的是 LLM 的 `loathe`（不在词表）→ 链断却未被列入 pending）。
    refs = ({v['base'] for v in rows if v['base']} |
            {dv[0] for dv in direct.values() if dv and dv[0]}) - vocab_new
    pending = []
    for mid in sorted(refs):
        if mid in seen or mid in inter_done:
            continue
        seen.add(mid)
        rows.append({'form': mid, 'base': None, 'rule': None, 'kind': None,
                     'anchor': None, 'anchor_id': None, 'depth': 0,
                     'in_vocab': 0, 'action': 'pending', 'source': 'intermediate'})
        pending.append(mid)

    return rows, direct, pending, dropped_double


def build_etymon_chain(recs):
    """词源链：etymon → parent → ... → anchor"""
    # etymon 节点：(form_ascii, language) → {meaning, parent}
    nodes = {}
    for r in recs:
        for e in ((r['data'].get('etymology') or {}).get('etyma') or []):
            fa = (e.get('form_ascii') or '').strip().lower()
            lang = (e.get('language') or '').strip().lower()
            if not fa:
                continue
            k = (fa, lang)
            if k not in nodes:
                nodes[k] = {'form': e.get('form'), 'form_ascii': e.get('form_ascii'),
                            'language': e.get('language'), 'meaning': e.get('meaning'),
                            'parent': (e.get('parent') or '').strip().lower() or None}
            elif not nodes[k]['parent'] and e.get('parent'):
                nodes[k]['parent'] = e['parent'].strip().lower()

    # parent 用 form_ascii 索引（parent 是纯文本，只能按 ascii 匹配）
    by_ascii = defaultdict(list)
    for k in nodes:
        by_ascii[k[0]].append(k)

    def resolve_parent(pform, lang):
        if pform in nodes:
            return pform
        cand = by_ascii.get(pform)
        return cand[0] if cand else None

    cache = {}

    def anchor_of(k, path=None):
        if k in cache:
            return cache[k]
        path = (path or set()) | {k}
        n = nodes.get(k)
        p = resolve_parent(n['parent'], k[1]) if (n and n.get('parent')) else None
        if not p or p in path or len(path) > MAX_DEPTH:
            cache[k] = (k, 0)
            return cache[k]
        a, d = anchor_of(p, path)
        cache[k] = (a, d + 1)
        return cache[k]

    rows = []
    for k, n in nodes.items():
        a, dep = anchor_of(k)
        rows.append({'form': n['form'], 'form_ascii': n['form_ascii'], 'language': n['language'],
                     'meaning': n['meaning'], 'parent': n['parent'],
                     'anchor_ascii': a[0], 'anchor_language': a[1], 'depth': dep})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from-sample', action='store_true')
    args = ap.parse_args()

    con = sqlite3.connect(cwc.DB)
    vocab = {r[0].strip().lower() for r in con.execute(
        "SELECT front FROM prebuilt_cards WHERE subject='english' AND card_type='vocabulary'")}
    con.close()

    # 🆕 补录词并入词表（2026-09-26）：
    #   977 个「别的词的 derived_from 指向的词」原本不在词表 → anchor 落空 → 396 个词形划词无卡。
    #   白哥批准补录后，它们成为正式词条 → **anchor 必须按「补录后的新词表」算**。
    #   标记来源：`senses_supplement.json`（补录过的词才有释义）
    if os.path.exists(SENSES_SUPP):
        supp = {w.strip().lower() for w in
                (json.load(open(SENSES_SUPP, encoding='utf-8')).get('items') or {})}
        added = supp - vocab
        vocab |= added
        print(f'  补录词并入词表: +{len(added)} → 共 {len(vocab)}')

    recs = load_records(args.from_sample)
    print(f'  来源: {"抽样" if args.from_sample else "全量 results.jsonl"} · {len(recs)} 条')
    print(f'  词表: {len(vocab)}')

    # ── word_form 链 ──
    wf, direct, pending, dbl = build_word_form_chain(recs, vocab)
    dc = defaultdict(int)
    for r in wf:
        dc[r['source']] += 1
    print(f'\n【word_form 链】{len(wf)} 行 · 来源分布 {dict(dc)}')
    print(f'  🔴 过滤双重变形垃圾: {len(dbl)} 条')
    resolved = [r for r in wf if r['anchor']]
    broken = [r for r in wf if not r['anchor']]
    print(f'  ✅ 有 anchor: {len(resolved)}')
    print(f'  🔴 链断(anchor=空): {len(broken)}')
    for r in broken[:10]:
        print(f'      {r["form"]:<16} base={r["base"]} source={r["source"]}')
    ddep = defaultdict(int)
    for r in wf:
        ddep[r['depth']] += 1
    print(f'  跳数分布: {dict(sorted(ddep.items()))}')
    print('  多跳样例（depth≥2）:')
    mh = [x for x in wf if x['depth'] >= 2]
    for r in mh[:8]:
        print(f'      {r["form"]:<16} → {r["base"]:<14} → anchor={r["anchor"]}  (depth={r["depth"]})')
    if not mh:
        print('      （本批无 —— 旧 word_form 的 lemma 恒在词表，故 rule_expand 全为 1 跳）')

    # 🔴 待补跑清单
    print(f'\n  🔴 **待补跑中间节点: {len(pending)}**')
    for m in pending[:12]:
        print(f'      {m}')
    if len(pending) > 12:
        print(f'      … 还有 {len(pending)-12} 个')

    # ── etymon 链 ──
    et = build_etymon_chain(recs)
    up = [r for r in et if r['parent']]
    print(f'\n【etymon 链】{len(et)} 个源词 · 需上溯 {len(up)}')
    anch = defaultdict(int)
    for r in et:
        anch[(r['anchor_ascii'], r['anchor_language'])] += 1
    shared = {k: v for k, v in anch.items() if v >= 2}
    print(f'  聚合到根本后：{len(anch)} 个根本源词 · 被 ≥2 词共享的 {len(shared)}')
    print(f'  被 ≥3 词共享（聚合页门槛）: {sum(1 for v in anch.values() if v >= 3)}')
    for r in up[:8]:
        print(f'      {r["form_ascii"]:<16} → {r["parent"]:<16} → anchor={r["anchor_ascii"]} (depth={r["depth"]})')
    if shared:
        print(f'  共享根本样例: {sorted(shared.items(), key=lambda kv: -kv[1])[:6]}')

    # 写 JSON
    json.dump({'source': 'sample' if args.from_sample else 'fullrun', 'rows': wf},
              open(OUT_WF, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    json.dump({'source': 'sample' if args.from_sample else 'fullrun', 'rows': et},
              open(OUT_ET, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    json.dump({'source': 'sample' if args.from_sample else 'fullrun',
               'count': len(pending), 'words': pending},
              open(OUT_PENDING, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    # 🔴 链断清单 —— 这些词的 base 不在词表（且已补跑确认它是基础词）
    #    → 用户划到这些形式会**查不到任何卡**，必须处置（补录 base 或降级卡）
    broken_rows = [{'form': r['form'], 'base': r['base'], 'action': r['action'],
                    'in_vocab': r['in_vocab'], 'source': r['source']}
                   for r in wf if not r['anchor']]
    json.dump({'source': 'sample' if args.from_sample else 'fullrun',
               'count': len(broken_rows), 'rows': broken_rows},
              open(OUT_BROKEN, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f'  已写 {OUT_BROKEN}（🔴 链断 {len(broken_rows)} 条 —— 需处置）')
    print(f'\n  已写 {OUT_WF}')
    print(f'  已写 {OUT_ET}')
    print(f'  已写 {OUT_PENDING}（待补跑 {len(pending)} 个）')


if __name__ == '__main__':
    main()
