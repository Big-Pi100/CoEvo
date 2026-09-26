#!/usr/bin/env python3
"""LLM 全库重跑 · 抽样验证器

背景（2026-09-26 白哥定调）：
  「组 C / 18 条这些都是规则分析的残留，根本没有意义…… 你规则分析的遗漏怎么搞？
    不还是要 LLM 跑，最重要的是根本不知道哪些错了，哪些漏了，判断遗漏本身还是靠规则。」

本脚本验证「LLM 逐词全量重跑」的质量，不依赖任何规则判据。

抽样：
  S1  分层随机 100 词（每 CEFR 等级 20）           → 测内容生成质量
  S2  1,375 张 lemma 冲突卡随机 60 词              → 测归一化判定质量
  每词跑 2 轮（同 prompt / 温度 0.1）→ 测自洽性，暴露分歧项

产出（data/curriculum/prebuilt/llm_rerun_sample.json）：
  每词 × 2 轮的完整内容包 + 一致性分析 + 分歧清单

用法：
  python3 scripts/llm_full_rerun_sample.py            # 全量抽样（160 词 × 2 轮 ≈ ¥0.5）
  python3 scripts/llm_full_rerun_sample.py --per 5    # 每级 5 词（快速冒烟测试）
  python3 scripts/llm_full_rerun_sample.py --cached   # 复用上次结果，不重复调 LLM
"""
import argparse
import json
import os
import random
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.stdout.reconfigure(encoding='utf-8')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
ENV = os.path.join(ROOT, 'backend', '.env')
FAMILY = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_family_candidates.json')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'llm_rerun_sample.json')

API_URL = 'https://api.deepseek.com/chat/completions'
MODEL = os.environ.get('COEVO_LLM_MODEL', 'deepseek-flash')
THINKING = {'type': 'disabled'}

# ── 价格（deepseek-flash，¥/1M token）──
P_IN, P_OUT = 1.5, 4.5

PROMPT = """You are an expert English lexicographer building flashcard content for Chinese learners of English.

WORD: {word}

Return STRICT JSON with EXACTLY this shape (keys must all be present):
{{
  "word": "{word}",
  "entry_type": "word",
  "is_own_entry": true,
  "derived_from": null,
  "reason": "≤15字中文",
  "morphology": {{
    "analyzable": true,
    "relation": "derivation",
    "parts": [
      {{"form": "in-", "type": "prefix", "meaning": "不", "origin": "Latin"}},
      {{"form": "cred", "type": "root", "meaning": "相信", "origin": "Latin"}},
      {{"form": "-ible", "type": "suffix", "meaning": "可…的", "origin": "Latin"}}
    ]
  }},
  "etymology": {{
    "text": "拉丁 credere（相信）→ 不可相信的",
    "etyma": [
      {{"form": "credere", "form_ascii": "credere", "language": "Latin",
        "meaning": "相信", "role": "root", "parent": ""}}
    ]
  }},
  "collocations": [{{"phrase": "an incredible story", "zh": "一个难以置信的故事"}}],
  "mnemonic": {{"primary": "root", "secondary": ["cognate"], "rationale": "in(不)+cred(相信)+ible(可…的)"}},
  "confidence": 0.9
}}

FIELD RULES:
0) entry_type — classify the headword itself:
   * "word"         = single orthographic word (incredible, run, café, a.m. is NOT here)
   * "phrase"       = multi-word expression (ice cream, bus stop, have to, each other, according to)
   * "abbreviation" = an abbreviation / initialism as the headword (a.m., p.m., mr, cd, id, tv)
   * "proper"       = a proper name (India, Sunday, Isaac)
   * 🔴 If entry_type="phrase": morphology MUST be {{"analyzable": false, "relation": null, "parts": []}}
     because morpheme splitting does not apply to a multi-word expression.
   * 🔴 If entry_type="abbreviation": is_own_entry must be true (a learner must learn it as its own item)
     and give the EXPANSION inside "reason" (e.g. "a.m. = ante meridiem, 上午").
1) is_own_entry — does this spelling deserve its OWN flashcard?
   * false: regular inflections (plural / past / participle / comparative / 3rd person) AND transparent derivatives whose meaning is fully predictable from the base (e.g. "politically"←political, "quickly"←quick, "aberrations"←aberration, "ran"←run, "worse"←bad).
   * true: it carries a meaning or usage a learner must learn as a separate item, even if historically derived — e.g. "building"(建筑物), "bore"(使厌烦), "well"(副词/井), "lyrics"(歌词), "sanctions"(制裁), "coordinates"(坐标), "attuned"(对…敏感的), "used"(用过的/习惯于).
   * 🔴 If the given word's OWN definition (shown to you) is unrelated to its spelling — e.g. a function word whose gloss describes an emotion — TRUST YOUR OWN LEXICAL KNOWLEDGE over the supplied definition, and set is_own_entry=true with a correct reason.
   * If unsure, prefer false only when the meaning is 100% predictable.
2) derived_from — the base word this spelling is built from, whether by inflection OR by derivation (this is what a learner would look up to find the related core word). null only for a base word with no such relation.
   * INFLECTION examples: "used" -> "use"; "attuned" -> "attune"; "isolated" -> "isolate"; "ran" -> "run"; "feet" -> "foot"; "taught" -> "teach".
   * DERIVATION examples: "politically" -> "political"; "recently" -> "recent"; "farmer" -> "farm"; "incredible" -> null.
   * 🔴 HARD RULE: if is_own_entry=false, derived_from MUST NOT be null (the card must be findable via its base). e.g. "politically" is_own_entry=false AND derived_from="political".
   * Give it even when is_own_entry=true (e.g. "attuned": is_own_entry=true AND derived_from="attune", because a learner should also reach "attune").
3) morphology.analyzable — true ONLY if the word breaks into morphemes that are still SEMANTICALLY TRANSPARENT in modern English AND genuinely help memorization.
   * true examples: "incredible"=in-+cred+-ible; "subway"=sub+way (relation="compound"); "lovely"=love+-ly (relation="derivation"); "transact"=trans+act.
   * false for OPAQUE words even if they look affixed: "understand" is NOT under+stand; "interest" NOT in+terest; "reason" NOT re+ason; "decide"/"require"/"remain" have dead affixes. Base words like "happy"/"table"/"be"/"get" are false.
   * NEVER invent roots. If unsure set analyzable=false and lower confidence.
4) morphology.relation — ONE of:
   * "inflection"  = the affix is INFLECTIONAL, i.e. it does NOT change the part of speech and creates no new word: -ed, -ing, -s/-es, comparative -er, superlative -est. Examples: "attuned"=attune+-ed, "used"=use+-ed, "surprising"=surprise+-ing, "cheaper"=cheap+-er.
   * "derivation"  = a DERIVATIONAL affix changes the part of speech or creates a new lexical item: -er(agent noun), -ly, -able, -ment, -ness, -ful, -ous, -tion. Examples: "farmer"=farm+-er, "precisely"=precise+-ly, "incredible"=in-+cred+-ible.
   * "compound"    = two free morphemes joined: "subway"=sub+way, "earthquake"=earth+quake.
   * null          = analyzable=false.
   * 🔴 "-er" has TWO faces — decide by meaning, not spelling: AGENT "-er" (farmer, owner, folder) = "derivation"; COMPARATIVE "-er" (cheaper, taller, later) = "inflection".
   * 🔴 If any part is a purely inflectional suffix (-ed/-ing/-s/comparative -er/-est), the relation is "inflection" even if the base itself has a derivational structure.
5) morphology.parts — ONLY when analyzable=true, 2-4 items in order. EVERY part object MUST contain ALL FOUR keys, no exceptions:
      "form"    = the morpheme as it appears, hyphen on the affix side: "in-", "cred", "-ible", "at-", "tune", "-ed"
      "type"    = prefix | root | suffix
      "meaning" = CHINESE meaning (e.g. "不", "相信", "可…的")
      "origin"  = Latin | Greek | Germanic | French | Old English | other
   When analyzable=false, "parts" MUST be an empty array [].
6) etymology — an object with TWO keys, BOTH required:
      "text"  = ≤40 Chinese chars narrative, ONLY if it genuinely aids memory; use "" otherwise.
                e.g. "拉丁 credere（相信）→ 不可相信的"
      "etyma" = array of the HISTORICAL SOURCE WORDS this word descends from. 🔑 This is what
                enables cognate grouping by etymology, so give it even for otherwise opaque words.
                Each item MUST contain ALL SIX keys:
                  "form"       = source word as written, MAY be non-ASCII: "capere", "γράφειν", "café", "Ärger"
                  "form_ascii" = ASCII transliteration, used as the grouping key: "capere", "grafein", "cafe", "aerger"
                                 (Greek/Cyrillic -> romanize; diacritics -> strip or expand: ä->ae, é->e)
                  "language"   = Latin | Greek | French | Old English | Old Norse | Proto-Germanic | Italian | Spanish | Arabic | Hebrew | other
                  "meaning"    = CHINESE meaning, e.g. "拿取", "相信"
                  "role"       = root | prefix | derived | whole
                                 * "whole" = borrowed as a whole word rather than derived (e.g. "café" <- French "café")
                  "parent"     = 🆕 the EARLIER source word this item itself comes from, as plain text;
                                 "" if it is already a root with no earlier source.
                                 * "percipere" -> "capere"; "decipere" -> "capere"; "respicere" -> "specere"
                                 * "capere" -> "" (already the root)
                                 🔑 This matters: LLM naturally picks different granularities (perceive comes
                                   from "percipere" while receive comes from "capere"), so "parent" is what
                                   lets us walk up to the shared root and group them together.
                * 0-3 items. Use [] ONLY when no source is traceable (rare).
                * Do NOT repeat an item twice.
                * Examples:
                    "receive" -> [{{"form":"capere","form_ascii":"capere","language":"Latin","meaning":"拿取","role":"root","parent":""}}]
                    "perceive"-> [{{"form":"percipere","form_ascii":"percipere","language":"Latin","meaning":"完全拿取","role":"whole","parent":"capere"}}]
                    "café"    -> [{{"form":"café","form_ascii":"cafe","language":"French","meaning":"咖啡","role":"whole","parent":""}}]
7) collocations — 0-3 real frequent phrases, each with a Chinese gloss.
8) mnemonic.primary ∈ root|cognate|etymology|collocation|image|context — the single method most likely to help a learner recall THIS word.
   * 🔴 "cognate" means the word SHARES A ROOT OR ETYMON with another English word (receive/perceive/conceive).
     A mere sound-alike (e.g. "papa" ~ Chinese "爸爸") is NOT cognate -> use "image".
   * 🔴 HARD RULE: if primary="root", then morphology.analyzable MUST be true.
     Otherwise choose "etymology" or "context".
9) confidence — 0.0-1.0 for your overall judgement.

Output JSON only. No prose, no markdown fences."""


def load_key() -> str:
    for line in open(ENV, encoding='utf-8'):
        line = line.strip()
        if line.startswith('DEEPSEEK_API_KEY='):
            return line.split('=', 1)[1].strip()
    raise SystemExit('未找到 DEEPSEEK_API_KEY')


def build_samples(per_level: int, conflict_n: int, seed: int = 20260927,
                  phrase_n: int = 20, short_n: int = 20):
    con = sqlite3.connect(DB)
    rows = list(con.execute("""
        SELECT c.front, l.level, l.pronunciation, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))
    con.close()
    by_level = defaultdict(list)
    meta = {}
    for w, lv, pr, df in rows:
        by_level[(lv or '').strip()].append(w)
        meta[w] = {'pron': pr, 'defs': df}

    rng = random.Random(seed)
    s1 = []
    for lv in ('A1', 'A2', 'B1', 'B2', 'C1'):
        pool = sorted(set(by_level.get(lv, [])))
        rng.shuffle(pool)
        for w in pool[:per_level]:
            s1.append({'word': w, 'level': lv, 'group': 'S1'})

    fam = json.load(open(FAMILY, encoding='utf-8'))
    conflicts = []
    for k in ('A_纯屈折_建议合并', 'B_有独立义_建议保留', 'C_灰区_待白哥判断'):
        for x in fam.get(k, []):
            conflicts.append({'word': x['form'], 'lemma': x['lemma'],
                              'group': 'S2', 'rule_group': k[0],
                              'form_def': (x.get('form_def') or '')[:200]})
    rng.shuffle(conflicts)
    s2 = conflicts[:conflict_n]

    # 🆕 S3a 多词短语（设计完全空白的部分）
    phrases = sorted({w for w in meta if ' ' in w})
    rng.shuffle(phrases)
    s3a = [{'word': w, 'group': 'S3a_phrase'} for w in phrases[:phrase_n]]

    # 🆕 S3b 可疑短词（≤2 字符，含已知坏数据 'a'）
    shorts = sorted({w for w in meta if len(w) <= 2})
    rng.shuffle(shorts)
    s3b = [{'word': w, 'group': 'S3b_short'} for w in shorts[:short_n]]
    for x in s3b:
        nd = meta.get(x['word'], {}).get('defs')
        if nd:
            try:
                j = json.loads(nd)
                x['form_def'] = (j[0].get('meaning') or '')[:160] if j else ''
            except Exception:
                x['form_def'] = ''
    # 确保已知坏数据 'a' 在样本里
    if 'a' not in {x['word'] for x in s3b}:
        r = [x for x in s3b if not x['word']]
        s3b[0] = {'word': 'a', 'group': 'S3b_short',
                  'form_def': 'feeling or showing pleasure or contentment.'}

    return s1 + s2 + s3a + s3b


def call_llm(key: str, word: str, retries: int = 4):
    body = {
        'model': MODEL,
        'messages': [{'role': 'user', 'content': PROMPT.format(word=word)}],
        'temperature': 0.1,
        'max_tokens': 900,
        'response_format': {'type': 'json_object'},
        'thinking': THINKING,
    }
    for attempt in range(retries):
        try:
            req = urllib.request.Request(
                API_URL, data=json.dumps(body).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'})
            with urllib.request.urlopen(req, timeout=120) as r:
                res = json.loads(r.read())
            usage = res.get('usage', {})
            content = res['choices'][0]['message'].get('content') or '{}'
            data = json.loads(content)
            return {'ok': True, 'data': data,
                    'in_tok': usage.get('prompt_tokens', 0),
                    'out_tok': usage.get('completion_tokens', 0)}
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


def norm_parts(parts):
    """归一化词素列表用于比对：form 去连字符小写 + type"""
    out = []
    for p in (parts or []):
        f = (p.get('form') or '').strip().lower().strip('-')
        out.append((f, (p.get('type') or '').strip().lower()))
    return tuple(out)


def run_round(key, items, round_no, workers=8):
    print(f'  第 {round_no} 轮：{len(items)} 词 / {workers} 并发 …')
    usage = {'in': 0, 'out': 0}

    def work(it):
        r = call_llm(key, it['word'])
        return it, r

    with ThreadPoolExecutor(max_workers=workers) as ex:
        for i, (it, r) in enumerate(ex.map(work, items), 1):
            it[f'r{round_no}'] = r
            if r.get('ok'):
                usage['in'] += r.get('in_tok', 0)
                usage['out'] += r.get('out_tok', 0)
            if i % 20 == 0 or i == len(items):
                ok = sum(1 for x in items if x.get(f'r{round_no}', {}).get('ok'))
                print(f'    {i}/{len(items)}  成功 {ok}  in={usage["in"]} out={usage["out"]}')
    return usage


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--per', type=int, default=20, help='S1 每 CEFR 等级抽多少词')
    ap.add_argument('--conflicts', type=int, default=60, help='S2 冲突卡抽多少词')
    ap.add_argument('--phrases', type=int, default=20, help='S3a 多词短语抽多少条')
    ap.add_argument('--shorts', type=int, default=20, help='S3b 可疑短词抽多少条')
    ap.add_argument('--rounds', type=int, default=2, help='跑几轮（测自洽性）')
    ap.add_argument('--cached', action='store_true')
    args = ap.parse_args()

    if args.cached and os.path.exists(OUT):
        saved = json.load(open(OUT, encoding='utf-8'))
        items = saved['items']
        print(f'复用缓存 {len(items)} 条')
    else:
        items = build_samples(args.per, args.conflicts, phrase_n=args.phrases, short_n=args.shorts)
        from collections import Counter as _CC
        gc = _CC(x['group'] for x in items)
        print(f'抽样 {len(items)} 条 · 分组 {dict(gc)}')
        key = load_key()
        total = {'in': 0, 'out': 0}
        for rd in range(1, args.rounds + 1):
            u = run_round(key, items, rd)
            total['in'] += u['in']
            total['out'] += u['out']
        cost = total['in'] * P_IN / 1e6 + total['out'] * P_OUT / 1e6
        print(f'  成本 ≈ ¥{cost:.3f}  (in={total["in"]} out={total["out"]})')
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        json.dump({'_meta': {'model': MODEL, 'per_level': args.per,
                             'conflicts': args.conflicts, 'rounds': args.rounds,
                             'usage': total, 'cost_cny': round(cost, 4)},
                   'items': items}, open(OUT, 'w', encoding='utf-8'),
                  ensure_ascii=False, indent=1)
        print(f'  已写入 {OUT}')

    analyze(items)


def analyze(items):
    print()
    print('=' * 96)
    print('抽样质量分析（不依赖任何规则判据）')
    print('=' * 96)

    valid = [x for x in items if x.get('r1', {}).get('ok')]
    print(f'\n有效样本（第 1 轮成功）: {len(valid)} / {len(items)}')

    def g(x, rd, *path):
        d = x.get(f'r{rd}', {}).get('data') or {}
        for p in path:
            d = (d or {}).get(p) if isinstance(d, dict) else None
        return d

    # ── ⓪ 契约合规性（查字段是否齐全 —— 这是契约检查，不是判对错）──
    total_parts = miss_form = miss_mean = miss_type = miss_origin = 0
    anlz_empty = nonanlz_has = 0
    miss_infl_of = 0
    bad_relation = []
    VALID_REL = {'inflection', 'derivation', 'compound', None}
    for x in valid:
        mo = g(x, 1, 'morphology') or {}
        if not isinstance(mo, dict):
            continue
        if 'derived_from' not in (g(x, 1) or {}):
            miss_infl_of += 1
        rel = mo.get('relation')
        if rel not in VALID_REL:
            bad_relation.append((x['word'], rel))
        ps = mo.get('parts') or []
        anlz = mo.get('analyzable')
        if anlz and not ps:
            anlz_empty += 1
        if (not anlz) and ps:
            nonanlz_has += 1
        for p in ps:
            total_parts += 1
            if not p.get('form'):
                miss_form += 1
            if not p.get('meaning'):
                miss_mean += 1
            if not p.get('type'):
                miss_type += 1
            if not p.get('origin'):
                miss_origin += 1
    print(f'\n【⓪ 输出契约合规性】（字段齐全度，非质量判断）')
    print(f'  词素 parts 总数        : {total_parts}')
    print(f'  🔴 缺 form 的词素      : {miss_form:>4}/{total_parts}'
          f'{"   ← 不可接受（word_root.form 会全空）" if miss_form else "   ✅"}')
    print(f'  缺 meaning / type / origin: {miss_mean} / {miss_type} / {miss_origin}')
    print(f'  analyzable=true 但 parts 空 : {anlz_empty}')
    print(f'  analyzable=false 但有 parts : {nonanlz_has}')
    print(f'  🆕 缺 derived_from 键       : {miss_infl_of:>4}/{len(valid)}')
    print(f'  🆕 relation 值越界           : {len(bad_relation)} {bad_relation[:6] if bad_relation else "✅"}')

    # ── ⓪0 契约 v5：entry_type + 短语/缩写专项 ──
    from collections import Counter as _C5
    et_c = _C5()
    bad_phrase_morph = []
    abbr_no_reason = 0
    for x in valid:
        t = g(x, 1, 'entry_type')
        et_c[t] += 1
        if t == 'phrase':
            mo = g(x, 1, 'morphology') or {}
            if mo.get('analyzable') or (mo.get('parts') or []):
                bad_phrase_morph.append(x['word'])
        if t == 'abbreviation' and not (g(x, 1, 'reason') or '').strip():
            abbr_no_reason += 1
    print(f'\n【⓪0 🆕 entry_type 分布（契约 v5）】')
    for k, v in et_c.most_common():
        print(f'  {str(k):<14}: {v:>4}')
    print(f'  🔴 phrase 却拆了词素      : {len(bad_phrase_morph)}'
          f'{"   ✅" if not bad_phrase_morph else " " + str(bad_phrase_morph[:8])}')
    print(f'  缩写缺 reason            : {abbr_no_reason}')

    # 分组明细：短语 / 短词 LLM 怎么处理的
    for grp, label in (('S3a_phrase', '多词短语'), ('S3b_short', '可疑短词')):
        sub = [x for x in valid if x.get('group') == grp]
        if not sub:
            continue
        tg = _C5(g(x, 1, 'entry_type') for x in sub)
        own_t = sum(1 for x in sub if g(x, 1, 'is_own_entry') is True)
        print(f'\n  【{label} n={len(sub)}】entry_type={dict(tg)} · is_own_entry=true {own_t}/{len(sub)}')
        for x in sub[:12]:
            print(f"    {x['word']:<22} type={str(g(x,1,'entry_type')):<13} "
                  f"own={str(g(x,1,'is_own_entry')):<6} {str(g(x,1,'reason'))[:34]}")

    # ── ⓪a 契约 v4：etymology 结构化合规性（白哥指出「词源字段太简单」）──
    from collections import Counter as _Cnt2
    et_not_obj = et_text_empty = et_etyma_empty = 0
    et_total_items = 0
    et_miss_key = _Cnt2()
    et_lang = _Cnt2()
    et_role = _Cnt2()
    et_ascii_ok = et_ascii_bad = 0
    for x in valid:
        et = g(x, 1, 'etymology')
        if not isinstance(et, dict):
            et_not_obj += 1
            continue
        if 'text' not in et:
            et_miss_key['text'] += 1
        if 'etyma' not in et:
            et_miss_key['etyma'] += 1
        if not (et.get('text') or '').strip():
            et_text_empty += 1
        ety = et.get('etyma') or []
        if not ety:
            et_etyma_empty += 1
        for e in ety:
            et_total_items += 1
            for k in ('form', 'form_ascii', 'language', 'meaning', 'role'):
                if not (e.get(k) or '').strip():
                    et_miss_key[f'item.{k}'] += 1
            et_lang[e.get('language') or '(空)'] += 1
            et_role[e.get('role') or '(空)'] += 1
            # form_ascii 是否真的 ASCII
            fa = e.get('form_ascii') or ''
            if fa and all(ord(c) < 128 for c in fa):
                et_ascii_ok += 1
            else:
                et_ascii_bad += 1

    print(f'\n【⓪a 🆕 etymology 结构化（契约 v4）】')
    print(f'  非对象（仍是字符串）    : {et_not_obj:>4}/{len(valid)}'
          f'{"   🔴 契约未生效" if et_not_obj else "   ✅"}')
    print(f'  缺 text 键 / 缺 etyma 键 : {et_miss_key.get("text",0)} / {et_miss_key.get("etyma",0)}')
    print(f'  text 为空               : {et_text_empty:>4}')
    print(f'  🔴 etyma 为空数组        : {et_etyma_empty:>4}/{len(valid)}'
          f' = {et_etyma_empty/len(valid)*100:.0f}%   ← 越高聚合覆盖面越低')
    print(f'  etyma 条目总数          : {et_total_items}')
    if et_miss_key:
        bad = {k: v for k, v in et_miss_key.items() if k.startswith('item.')}
        if bad:
            print(f'  🔴 条目内缺键            : {dict(bad)}')
    print(f'  form_ascii 是纯 ASCII   : {et_ascii_ok}/{et_ascii_ok+et_ascii_bad}'
          f'{"   ✅" if et_ascii_bad == 0 else f"   🟠 非 ASCII {et_ascii_bad} 条"}'  )
    print(f'  语言分布（前 8）        : {dict(et_lang.most_common(8))}')
    print(f'  role 分布               : {dict(et_role.most_common())}')

    # 🆕 词源链式：parent 覆盖率与上溯能力
    has_parent = parent_as_root = 0
    parent_not_self = []
    for x in valid:
        for e in (g(x, 1, 'etymology', 'etyma') or []):
            p = (e.get('parent') or '').strip()
            if p:
                has_parent += 1
                parent_not_self.append((x['word'], e.get('form'), p))
            else:
                parent_as_root += 1
    print(f'  🆕 etyma.parent 非空（需上溯）: {has_parent}  空（已是根本）: {parent_as_root}')
    if parent_not_self:
        print(f'     上溯样例: {parent_not_self[:6]}')

    # 🔑 词源聚合潜力：同一 etymon 被多少词共享
    et_share = _Cnt2()
    for x in valid:
        for e in (g(x, 1, 'etymology', 'etyma') or []):
            key = ((e.get('form_ascii') or '').lower(), (e.get('language') or '').lower())
            if key[0]:
                et_share[key] += 1
    shared = {k: v for k, v in et_share.items() if v >= 2}
    print(f'\n  🔑 词源聚合潜力：{len(et_share)} 个不同 etymon，其中被 ≥2 词共享的 {len(shared)}')
    print(f'     被 ≥3 词共享的（聚合页门槛）: {sum(1 for v in et_share.values() if v >= 3)}')
    if shared:
        print(f'     共享样例: {sorted(shared.items(), key=lambda kv: -kv[1])[:8]}')

    # ── ⓪b 契约 v2：relation 分布 + 屈折/派生 × 独立词条 交叉表 ──
    from collections import Counter as _Cnt
    rel_c = _Cnt(g(x, 1, 'morphology', 'relation') for x in valid
                 if g(x, 1, 'morphology', 'analyzable'))
    print(f'\n【⓪b relation 分布（v3 契约）】')
    for k in ('inflection', 'derivation', 'compound'):
        v = rel_c.get(k, 0)
        print(f'  {k:<12}: {v:>4}')
    infl_of = sum(1 for x in valid if g(x, 1, 'derived_from'))
    print(f'  derived_from 非空       : {infl_of:>4}/{len(valid)} = {infl_of/len(valid)*100:.1f}%')

    # 🔴 硬约束检查：is_own_entry=false ⟹ derived_from 非空
    viol = [x['word'] for x in valid
            if g(x, 1, 'is_own_entry') is False and not g(x, 1, 'derived_from')]
    print(f'  🔴 违反硬约束（own=false 但 derived_from 空）: {len(viol)} {viol[:10] if viol else "✅"}')
    # 冗余检查：base_form 可推导性
    derivable = 0
    for x in valid:
        own = g(x, 1, 'is_own_entry')
        bf = (x.get(f'r1', {}).get('data') or {}).get('base_form')
        if bf is None:
            derivable += 1  # v3 已无该字段
            continue
        pred = x['word'] if own else g(x, 1, 'derived_from')
        if (pred or '').lower() == (bf or '').lower():
            derivable += 1
    print(f'  base_form 可推导（或已删） : {derivable}/{len(valid)}')

    print(f'\n【⓪c 🔑 屈折/派生 × is_own_entry 交叉表】（决定 word_form 映射去留）')
    tab = _Cnt()
    for x in valid:
        own = bool(g(x, 1, 'is_own_entry'))
        rel = g(x, 1, 'morphology', 'relation')
        tab[(own, rel)] += 1
    print(f'  {"is_own_entry":<14}{"inflection":>12}{"derivation":>12}{"compound":>10}{"null":>7}')
    for own in (True, False):
        print(f'  {str(own):<14}{tab[(own,"inflection")]:>12}{tab[(own,"derivation")]:>12}'
              f'{tab[(own,"compound")]:>10}{tab[(own,None)]:>7}')
    print(f'  → 独立+屈折（{tab[(True,"inflection")] }）: word_form 映射【保留】+ in_vocab=1')
    print(f'  → 独立+派生/复合（{tab[(True,"derivation")]+tab[(True,"compound")]}）: word_form 旧映射【删除】')
    infl_only = [(x['word'], g(x, 1, 'derived_from'))
                 for x in valid
                 if g(x, 1, 'morphology', 'relation') == 'inflection'
                 and g(x, 1, 'is_own_entry') is True]
    if infl_only:
        print(f'\n  🔑 独立词条但有屈折形式的（形态归属必须留住，前 12）:')
        for w, io_ in infl_only[:12]:
            print(f'      {w:<16} derived_from={io_}')

    # ── ① 第 2 轮是否存在 ──
    has_r2 = [x for x in valid if x.get('r2', {}).get('ok')]
    if not has_r2:
        print('（仅 1 轮，跳过一致性分析）')
        return

    # ── ② 自洽性（两轮比对）──
    agree_entry, agree_anlz, agree_parts, agree_primary = 0, 0, 0, 0
    agree_rel, agree_infl_of = 0, 0
    disagree = []
    for x in has_r2:
        a1, a2 = g(x, 1, 'is_own_entry'), g(x, 2, 'is_own_entry')
        m1, m2 = g(x, 1, 'morphology', 'analyzable'), g(x, 2, 'morphology', 'analyzable')
        p1 = norm_parts(g(x, 1, 'morphology', 'parts'))
        p2 = norm_parts(g(x, 2, 'morphology', 'parts'))
        k1, k2 = g(x, 1, 'mnemonic', 'primary'), g(x, 2, 'mnemonic', 'primary')
        r1_, r2_ = g(x, 1, 'morphology', 'relation'), g(x, 2, 'morphology', 'relation')
        i1 = (g(x, 1, 'derived_from') or '').lower().strip()
        i2 = (g(x, 2, 'derived_from') or '').lower().strip()
        e_ok, m_ok, p_ok, k_ok = (a1 == a2), (m1 == m2), (p1 == p2), (k1 == k2)
        r_ok, i_ok = (r1_ == r2_), (i1 == i2)
        agree_entry += e_ok
        agree_anlz += m_ok
        agree_parts += p_ok
        agree_primary += k_ok
        agree_rel += r_ok
        agree_infl_of += i_ok
        if not (e_ok and m_ok and p_ok):
            disagree.append({'word': x['word'], 'group': x.get('group'),
                             'is_own_entry': (a1, a2), 'analyzable': (m1, m2),
                             'parts': (p1, p2), 'primary': (k1, k2)})
    n = len(has_r2)
    print(f'\n【① 两轮自洽性】（一致 = 同一模型两次独立判断结论相同）')
    print(f'  is_own_entry 一致        : {agree_entry:>4}/{n}  = {agree_entry/n*100:5.1f}%')
    print(f'  morphology.analyzable   : {agree_anlz:>4}/{n}  = {agree_anlz/n*100:5.1f}%')
    print(f'  词根拆分 parts 完全一致  : {agree_parts:>4}/{n}  = {agree_parts/n*100:5.1f}%')
    print(f'  mnemonic.primary 一致    : {agree_primary:>4}/{n}  = {agree_primary/n*100:5.1f}%')
    print(f'  🆕 morphology.relation 一致 : {agree_rel:>4}/{n}  = {agree_rel/n*100:5.1f}%')
    print(f'  derived_from 一致        : {agree_infl_of:>4}/{n}  = {agree_infl_of/n*100:5.1f}%')
    print(f'  🔴 三项任一不一致        : {len(disagree):>4}/{n}  = {len(disagree)/n*100:5.1f}%  ← 必查清单')

    # ── ③ 可拆率 / 独立词条率（LLM 口径，替代规则法）──
    anlz_r1 = sum(1 for x in valid if g(x, 1, 'morphology', 'analyzable'))
    own_r1 = sum(1 for x in valid if g(x, 1, 'is_own_entry'))
    print(f'\n【② LLM 判定分布（第 1 轮）】')
    print(f'  可拆 (analyzable)     : {anlz_r1:>4}/{len(valid)} = {anlz_r1/len(valid)*100:5.1f}%')
    print(f'  独立词条 (is_own_entry): {own_r1:>4}/{len(valid)} = {own_r1/len(valid)*100:5.1f}%')
    lowconf = [x for x in valid if (g(x, 1, 'confidence') or 1) < 0.6]
    print(f'  低置信 (<0.6)          : {len(lowconf):>4}/{len(valid)} ← 建议人工复核')

    # ── ②b S2 冲突卡：LLM 归一化判定 vs 规则分组（给 word 表定规模 + 暴露分歧）──
    s2 = [x for x in valid if x.get('group') == 'S2']
    if s2:
        from collections import Counter as _C
        tab = _C()
        for x in s2:
            tab[(x.get('rule_group'), bool(g(x, 1, 'is_own_entry')))] += 1
        print(f'\n【②b S2 冲突卡 · 规则分组 × LLM 归一化判定】（n={len(s2)}）')
        print(f'  {"规则组":<8}{"LLM 判独立":>12}{"LLM 判合并":>12}')
        for rg in ('A', 'B', 'C'):
            t, fo = tab.get((rg, True), 0), tab.get((rg, False), 0)
            if t + fo:
                print(f'  {rg:<8}{t:>12}{fo:>12}')
        own = sum(1 for x in s2 if g(x, 1, 'is_own_entry'))
        keep = round(1375 * own / len(s2))
        print(f'  → LLM 判「独立词条」: {own}/{len(s2)} = {own/len(s2)*100:.1f}%')
        print(f'  → 折算全 1,375 张冲突卡：约 {keep} 张保留 / {1375-keep} 张合并')
        print(f'\n  🔴 与规则法分歧（前 20）—— 规则无法自证遗漏，此处即「规则的盲区」：')
        shown = 0
        for x in s2:
            llm_own = bool(g(x, 1, 'is_own_entry'))
            rule_merge = (x.get('rule_group') == 'A')
            if rule_merge == llm_own and shown < 20:
                shown += 1
                print(f"    {x['word']:<18} 规则组={x.get('rule_group')}"
                      f"({'建议合并' if rule_merge else '建议保留'}) → LLM own={llm_own} "
                      f"derived_from={g(x, 1, 'derived_from')}")

    # ── ④ 分歧与低置信明细（可读）──
    print(f'\n【③ 🔴 必查清单 · 两轮不一致（前 25）】')
    for d in disagree[:25]:
        print(f'    {d["word"]:<20} [{d["group"]}] own={d["is_own_entry"]} anlz={d["analyzable"]} '
              f'parts={d["parts"][0]} → {d["parts"][1]}')

    print(f'\n【④ 样本明细 · S1 前 15（人工盲评用）】')
    cnt = 0
    for x in valid:
        if x['group'] != 'S1':
            continue
        cnt += 1
        if cnt > 15:
            break
        d = x['r1']['data']
        parts = ' + '.join(f"{p.get('form','')}({p.get('type','')[:4]}:{p.get('meaning','')})"
                           for p in (g(x, 1, 'morphology', 'parts') or []))
        print(f"    {x['word']:<18} [{x.get('level','')}] own={g(x, 1, 'is_own_entry')} "
              f"anlz={g(x,1,'morphology','analyzable')} conf={g(x,1,'confidence')}")
        print(f"        parts: {parts or '—'}")
        print(f"        mnemonic: {g(x,1,'mnemonic','primary')} / {g(x,1,'mnemonic','rationale')}")
        et = (g(x, 1, 'etymology', 'text') or '')[:60]
        if et:
            print(f"        etym: {et}")
        ety = g(x, 1, 'etymology', 'etyma') or []
        if ety:
            parts_e = ' + '.join(f"{e.get('form','')}[{e.get('language','')}·{e.get('role','')}]" for e in ety)
            print(f"        etyma: {parts_e}")

    print(f'\n【⑤ 样本明细 · S2 冲突卡前 20（验归一化判定）】')
    cnt = 0
    for x in valid:
        if x['group'] != 'S2':
            continue
        cnt += 1
        if cnt > 20:
            break
        print(f"    {x['word']:<18} 规则组={x.get('rule_group')} | LLM: own={g(x, 1, 'is_own_entry')} "
              f"derived_from={g(x, 1, 'derived_from')} | {g(x, 1, 'reason')}  (conf={g(x,1,'confidence')})")


if __name__ == '__main__':
    main()
