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

# ── `word_form` 表的**已知边界**：它只收「规则变形」 ──────────────────
# 🔴 实测（2026-09-29）：`base=bury` 只有 burial/buries/burying（**没有 buried**）·
#    `base=leaf` 只有 leafed/leafing/leafs（**没有 leaves**）·
#    `base=shrink` 只有 shrinked/shrinking/shrinks（**没有 shrank**）。
#    → 只靠它判「例句是否含该词」，会把 buried/leaves/shrank/… **全部误判为「不含」**。
# 🔑 所以本文件**自己生成规则变形 + 补不规则/变体**，不假设该表完整。
#
# 出处：2026-09-29 对 64 条「例句不含该词」逐条复核 —— 其中 **47 条是判据误差**，
#       只有 17 条是真空。详见 `data/reports/card_field_fixes-*.md` §五。
_IRREGULAR = {
    # 不规则变形（word_form 表全缺）
    'anta': {'antae'}, 'leaf': {'leaves'}, 'leap': {'leapt'},
    'freshman': {'freshmen'}, 'grandchild': {'grandchildren'},
    'schoolchild': {'schoolchildren'}, 'vertebra': {'vertebrae'},
    'lied': {'lieder'}, 'seventy': {'seventieth'},
    'shrink': {'shrank', 'shrunk', 'shrunken'},
    'undo': {'undid', 'undone'},
    'withdraw': {'withdrew', 'withdrawn'},
    'withhold': {'withheld'},
    'undergo': {'underwent', 'undergone'},
    'outgrow': {'outgrew', 'outgrown'},
    'outshine': {'outshone'},
    'overpay': {'overpaid'},
    'overtake': {'overtook', 'overtaken'},
    'overthrow': {'overthrew', 'overthrown'},
    'retell': {'retold'},
    'rewrite': {'rewrote', 'rewritten'},
    'reunify': {'reunified', 'reunifies'},
    'sanctify': {'sanctified', 'sanctifies'},
    'petrify': {'petrified', 'petrifies'},
    'ratify': {'ratified', 'ratifies'},
    'ramify': {'ramified', 'ramifies'},
    'mimic': {'mimicked'},
    'dissatisfy': {'dissatisfied', 'dissatisfies'},
    'intensify': {'intensified', 'intensifies'},
    'exemplify': {'exemplified', 'exemplifies'},
    # 派生 / 词族（不是变形，但例句里出现时**不算「张冠李戴」**）
    'transfuse': {'transfusion', 'transfusions'},
    'alumnus': {'alumna', 'alumnae', 'alumni'},
    # 缩写 / 变体拼写
    'esquire': {'esq'}, 'jan': {'january'}, 'dc': {'dc'},
    'noel': {'nowell'}, 'calenda': {'calends', 'kalends'},
}


def _spelling_variants(w):
    """英美拼写变体（`-ize/-ise`、`-ization/-isation`）—— 两边都要能对上。"""
    out = set()
    for a, b in (('iz', 'is'), ('is', 'iz')):
        if a in w:
            out.add(w.replace(a, b, 1))
    return out


def _regular_forms(w):
    """自造规则变形（s/es/ed/d/ing + e 脱落 + y→i + 辅音双写）。"""
    out = set()
    if not w or ' ' in w or '-' in w:
        return out
    out |= {w + 's', w + 'es', w + 'ed', w + 'd', w + 'ing'}
    if w.endswith('e'):
        out |= {w[:-1] + 'ing', w[:-1] + 'ed', w[:-1] + 'es'}
    elif w[-1] not in 'aeiou':
        out |= {w + w[-1] + 'ed', w + w[-1] + 'ing'}
    if w.endswith('y') and len(w) > 2 and w[-2] not in 'aeiou':
        out |= {w[:-1] + 'ies', w[:-1] + 'ied', w[:-1] + 'ier', w[:-1] + 'iest'}
    return out


def surface_forms(word, forms_map):
    """该词的全部可接受表层形式（表 + 自造规则变形 + 变体 + 不规则）。"""
    w = word.lower()
    bases = {w} | _spelling_variants(w)
    out = {w} | forms_map.get(w, set()) | _IRREGULAR.get(w, set())
    for b in bases:
        out |= {b} | _regular_forms(b) | _IRREGULAR.get(b, set())
    return out


def _tokens(text):
    """分词 + 去缩写点（`D.C.` → `dc`）+ 所有格/连字符等价形。"""
    low = (text or '').lower().replace('.', '')
    out = set(re.findall(r"[a-z']+", low)) | set(re.findall(r'[a-z]+', low))
    out |= {t.replace("'s", '').replace("'", '') for t in list(out)}
    return out


def _compound_hit(w, toks):
    """复合词/派生词命中：`handloom` 含 `loom` · `readership` 含 `reader`。

    🔑 阈值是**有意**的：后缀 ≥3（beeswax 含 wax）· 前缀 ≥5（readership 含 reader，
        但 funky 不算 funk、illegal 不算 il）。
    """
    for t in toks:
        if t == w or len(t) <= len(w):
            continue
        if len(w) >= 3 and t.endswith(w):
            return True
        if len(w) >= 5 and t.startswith(w):
            return True
    return False


def load_surface_forms(db_path):
    """从 `word_form` 表建「base → 它的各种变形」映射（**仅作补充，不作为唯一依据**）。"""
    import sqlite3
    m = {}
    try:
        con = sqlite3.connect(db_path)
        for f_, b_ in con.execute('SELECT form, base FROM word_form'):
            m.setdefault(b_.lower(), set()).add(f_.lower())
        con.close()
    except Exception as e:      # noqa: BLE001
        print(f'  ⚠️ 读 word_form 失败（例句判定用自造变形兜底）: {e}')
    return m


def contains_word(text, spelling, forms_map):
    """例句是否含该词（或其变形）。返回 `(bool, 原因标签)`。"""
    if not text:
        return False, 'empty'
    low = text.lower()
    w = spelling.lower()
    if w in low and (' ' in w or '.' in w):       # 短语 / 缩写：整体子串先行
        return True, ('phrase-exact' if ' ' in w else 'abbr')
    if ' ' in w:                                  # 多词词组：逐词判（容忍变形）
        toks = _tokens(low)
        ok = all(bool(surface_forms(p, forms_map) & toks) for p in w.split())
        return ok, ('phrase-forms' if ok else 'phrase-miss')
    if '.' in w:                                  # 缩写：整体子串（`a.m.` / `Dr.`）
        return (w in low), ('abbr' if w in low else 'abbr-miss')
    toks = _tokens(low)
    if '-' in w:                                  # 连字符视为分隔（`t-shirt` → t / shirt）
        if all(seg in toks for seg in w.split('-') if seg):
            return True, 'hyphen'
    if w in toks:
        return True, 'exact'
    if surface_forms(w, forms_map) & toks:
        return True, 'form'
    if _compound_hit(w, toks):
        return True, 'compound'
    return False, 'miss'


def ipa_broken(s):
    """真「残缺」：连一个非空的 `/.../` 段都没有（`/ˈ`、`/`、空）。"""
    if not s:
        return True
    return not re.search(r'/[^/]{1,}/', s.strip())


def ipa_truncated(ipa, spelling):
    """「完整但是截断了」—— 实质音标字符数 / 拼写字母数 < 0.45（= 信号 S2 的口径）。

    🔑 为什么单列：`/ˈ` 那种残缺会被 `ipa_broken` 抓到，但 `/viː/`（abortive）·
       `/hɪs/`（hysterical）· `/sʌb/`（subsection）**格式完全合法**，
       `ipa_covers_phrase` 又只管多词词组 → 两者都漏。实测 S2 精确率 100%（18/18）。
    """
    if not ipa:
        return True
    letters = len(re.findall(r'[a-z]', spelling.lower()))
    if not letters:
        return False
    core = len(re.sub(r'[/ˈˌ.()\s]', '', ipa))
    return core / letters < 0.45


def ipa_covers_phrase(ipa, spelling):
    """多词词组的 ipa 是否覆盖**全部**词（粗判：段数 ≥ 词数）。

    🔑 这抓的是「ipa 只给了第一个词」那类错（`frying pan` 得到 `/fraɪ/`）。
    """
    if ' ' not in spelling:
        return True
    if not ipa:
        return False
    return len([x for x in re.split(r'\s+', ipa.strip('/')) if x]) >= len(spelling.split())


def _partners(rec):
    """从候选的 `reasons` 里抽出「ipa 撞车的对端词」（S3a/S3b 的产物）。"""
    return re.findall(r"与 '([^']+)' 的 ipa 相同", ' '.join(rec.get('reasons') or []))


def detect_contamination(rec, cur, forms_map):
    """识别**整卡污染** —— 现状的 ipa/释义/例句整段来自**另一个词**。

    🔑 为什么需要单独识别（而不是「释义与 v6 不同就写」）：
       实测 `definition` 的差异**绝大多数只是措辞/大小写/句号**差异
       （例：`bulletin` 现状 "A short official notice or report giving news or
       information to many people." vs v6 "a short official notice or news report"
       —— 现状反而更详细）→ 按「不同」判错会大面积误伤。
    但确有整卡污染：`a` 的 ipa(`/ˈhæpi/`)/释义/例句**全是 `happy` 的**。

    判据（机械可判）：**例句不含本词，却含它的撞车对端词** → 内容来自对端词。
    返回对端词，或 None。
    """
    ctx = cur.get('context')
    if contains_word(ctx, rec['spelling'], forms_map)[0]:
        return None
    for p in _partners(rec):
        if contains_word(ctx or '', p, forms_map)[0]:
            return p
    return None


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
    elif ipa_truncated(cur['ipa'], rec['spelling']):
        hard.append('ipa 疑截断')
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


# ══════════════════════════════════════════════════════════════════════
# 🔑 写库字段选择 —— **每个字段必须有自己的硬证据，才允许覆盖**
#
# 为什么不能「整条一起写」：`definition` 是开放式字段，现状与 v6 不同**不等于**现状错
#   （实测大量差异只是措辞/大小写/句号）→ 整条覆盖会造成大面积无谓改动。
# 例外：**整卡污染**（见 `detect_contamination`）→ 释义必须一起换（否则留下别人的释义）。
# ══════════════════════════════════════════════════════════════════════
IPA_HARD = ('ipa 残缺', 'ipa 未覆盖全词组', 'ipa 疑截断')

# 人工核过：**现状对、v6 错** —— 信号确实命中（ipa 与别的词相同），但 v6 这条不可用。
#   `ms.` = Ms.（女士）读 `/mɪz/`；v6 给了 `/ˌem ˈes/`，那是 M.S.（理学硕士）。
# 🔑 这条同时是「LLM 复核有错、不能无脑照抄」的实证。
IPA_V6_WRONG = {'ms.'}

# ipa 归一化替换 —— **只为消除「写法差异」，不改变「读音」**
#   ɡ(U+0261)/g · ɛ/e · əʊ/oʊ（英/美 GOAT 元音）· ɝ/ɜ · 去掉重音·分隔·弱读央元音
_IPA_FOLD = (('ɡ', 'g'), ('ɛ', 'e'), ('əʊ', 'oʊ'), ('ɝ', 'ɜ'), ('ɜːr', 'ɜː'))


def ipa_core(s):
    """把 ipa 压成「音素串集合」，用于判断两个 ipa 是不是**同一个读音的两种写法**。"""
    if not s:
        return set()
    segs = re.findall(r'/([^/]+)/', s) or [s.strip('/')]
    out = set()
    for seg in segs:
        c = seg.lower()
        for a, b in _IPA_FOLD:
            c = c.replace(a, b)
        c = re.sub(r"[ˈˌ.\s(),;]", '', c)
        c = re.sub(r'[əɚ]', '', c)              # 弱读央元音：`pɜːsən` ≈ `pɜːsn`
        c = re.sub(r'r+$', '', c)               # 词尾 r：UK 非儿化写法
        if c:
            out.add(c)
    return out


def ipa_needs_write(rec, cur):
    """`ipa` 是否该覆盖。返回 `(bool, 理由)`。

    🔴 为什么**不**等于「与 v6 不同就写」：实测大量差异只是**写法**不同，而不是读音错。
       而且 v6 **未必更对**：
         · `jean` 现状 `/dʒiːn/` → v6 `/dʒiːn/ (UK) or /dʒiːn/ (US)`（只多了标注）
         · `lied` 现状 `(noun) /liːd/; (verb) /laɪd/`（更全）→ v6 `'/liːd/'`（**丢信息**）
         · `ms.`  现状 `/mɪz/`（**对**）→ v6 `/ˌem ˈes/`（**错**，那是 M.S.）→ 见 `IPA_V6_WRONG`
       → 判据：把两边归一化成**音素串**再比 —— **任一种读法对得上**就不写；
         只有「读法本身不同」（截断 / 是别的词的音标 / 真错）才写。
    """
    ipa = (cur.get('ipa') or '').strip()
    if not re.search(r'/[^/]{1,}/', ipa):
        return True, 'ipa 残缺'
    if rec['spelling'].lower() in IPA_V6_WRONG:
        return False, ''
    if ipa_core(ipa) & ipa_core(rec['data'].get('ipa')):
        return False, ''            # 至少一种读法对得上 → 只是写法/标注差异
    why = next((h for h in IPA_HARD if h in rec['hard']), '')
    if not why and any(s in ('S3a', 'S3b') for s in rec['signals']):
        why = 'ipa 撞车（读法是别的词的）'
    return True, (why or 'ipa 读法与 v6 不同')


def write_fields(rec, cur, forms_map):
    """返回该条**应当写入 word.db** 的字段集合（空集 = 只登记，不写）。

    🔴 `definition` **不因「ipa 有硬证据」就跟着写** —— 实测 `white`(/aɪ/)·
       `bulletin`(/bʊl/) 的 ipa 都坏了，但释义本身是对的。
       只有两种情况允许覆盖释义：① 现状为空 ② 已证实**整卡污染**。
    """
    out = set()
    if ipa_needs_write(rec, cur)[0]:
        out.add('ipa')
    if '例句不含该词' in rec['hard']:
        out.add('context')
    if '释义为空' in rec['hard']:
        out.add('definition')
    if detect_contamination(rec, cur, forms_map):
        out.add('definition')                       # 已证实内容来自对端词
    return out


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
    for r in results:                       # 用**当前**判据重算档位与写库字段
        lvl, hard, closed = classify(r, r['current'], forms_map)
        r['level'], r['hard'], r['closed'] = lvl, hard, closed
        r['write'] = sorted(write_fields(r, r['current'], forms_map))
        r['contam'] = detect_contamination(r, r['current'], forms_map)

    by_level = Counter(r['level'] for r in results)
    plan = [r for r in results if r['write']]
    fld = Counter(f for r in plan for f in r['write'])
    contam = [r for r in results if r['contam']]
    # S4 信号但判据（升级后）认为含该词 → 判据误差
    s4_fp = [r for r in results
             if 'S4' in r['signals']
             and contains_word(r['current']['context'], r['spelling'], forms_map)[0]]
    hard_sig = Counter(' + '.join(r['signals']) for r in results if r['hard'])
    sig_all = Counter(' + '.join(r['signals']) for r in results)

    L = []
    A = L.append
    A(f'# 卡片字段修正候选 —— LLM（契约 {cwc.CONTRACT_VERSION}）复核结果')
    A('')
    A(f'> 生成：{payload["generated_at"]} ｜ 模型 `{cwc.MODEL}` ｜ **只生成，未写库**')
    A(f'> 输入：`card_field_candidates.json`（{len(cands)} 条可疑项，由 5 个信号筛出）')
    A(f'> 成本 **¥{cost:.4f}**（in {tin:,} / out {tout:,} token）· 耗时 {secs:.0f}s · 并发 {args.workers}')
    A('')
    A('## 一、结论：三档 + 建议写入')
    A('')
    A('| 档位 | 条数 | 含义 |')
    A('|---|---:|---|')
    A(f'| **🔴 确定要修** | **{by_level.get("🔴 确定要修", 0)}** | 有**硬证据**（见 §二）：现状确实错 |')
    A(f'| 🟠 疑似 | {by_level.get("🟠 疑似（封闭字段不同，需人眼定谁错）", 0)} | 封闭字段与 v6 不同，**有一方错**，需人眼 |')
    A(f'| ✅ 无问题 | {by_level.get("✅ 无问题（信号误报）", 0)} | 现状没查出问题（信号**误报**） |')
    A(f'| — 失败 | {len(failed)} | 调用失败，未判定 |')
    A('')
    A(f'### 🔑 建议写入 `word.db`：**{len(plan)}** 条卡（按字段）')
    A('')
    A('| 字段 | 条数 | 允许覆盖的**前提**（每个字段须有自己的硬证据） |')
    A('|---|---:|---|')
    A(f'| `ipa` | {fld.get("ipa", 0)} | 残缺 / 未覆盖全词组 / 疑截断（S2）/ 与 v6 不同（封闭字段） |')
    A(f'| `context` | {fld.get("context", 0)} | 例句**不含该词**（词形还原后） |')
    A(f'| `definition` | {fld.get("definition", 0)} | **仅**：现状为空，或已证实**整卡污染**（见 §五） |')
    A('')
    A('> 🔴 **不整条覆盖** —— `definition` 是开放式字段，「与 v6 不同」绝大多数只是')
    A('> 措辞 / 大小写 / 句末句号差异（实测 `bulletin` 现状比 v6 更详细）→')
    A('> 按「不同」覆盖会造成大面积无谓改动（见 §五）。')
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
    A('> 🔑 `ipa 残缺` = 连一个完整的 `/.../` 都没有（`/ˈ`）·')
    A('>    `ipa 未覆盖全词组` = 多词词组只给了第一个词的音标（`frying pan` → `/fraɪ/`）·')
    A('>    `ipa 疑截断` = 格式合法但实质字符/拼写字母 < 0.45（`abortive` → `/viː/`）·')
    A('>    `例句不含该词` = 词形还原（见 §五）后仍找不到该词。')
    A('')
    A('## 三、按信号看（判据的命中率）')
    A('')
    A('| 信号组合 | 总数 | 确定要修 | 命中率 |')
    A('|---|---:|---:|---:|')
    for k, v in sig_all.most_common():
        c = hard_sig.get(k, 0)
        A(f'| `{k}` | {v} | {c} | {c / v * 100:.0f}% |')
    A('')
    A('### ⚠️ 但 S3a / S3b 的「0% / 1%」**不是「信号错了」** —— 是本表的硬证据判据**抓不到那一类**')
    A('')
    A('| 信号 | 它要抓什么 | 本表能判吗 |')
    A('|---|---|---|')
    A('| `S1` `S2` | ipa **残缺 / 截断**（段数不够、格式不完整） | ✅ **能**（纯格式，机械可判） |')
    A('| `S4` | 例句**不含该词** | ✅ **能**（查词形还原即可） |')
    A('| `S3a` `S3b` | ipa 是**另一个词**的音标（段数够、格式也合法） | 🔴 **不能** |')
    A('')
    A('🔑 为什么不能：`air conditioning` 的现状 ipa 是 `/ˈɛr fɔːrs/` —— **两段、格式合法**，')
    A('机械判据（段数 ≥ 词数）**完全通过**；要知道它是 `air force` 的音标，')
    A('必须**懂语义**。这正是 LLM 复核不可替代的地方。')
    A('')
    A('## 四、🔴 建议写入 —— 逐条（现状 → v6）')
    A('')
    A('| 词 | 写 | 信号 | 硬证据 | 现状 → v6 |')
    A('|---|---|---|---|---|')
    for r in sorted(plan, key=lambda x: x['spelling']):
        cu, d = r['current'], r['data']
        dfn = d.get('definition') or {}
        bits = []
        if 'ipa' in r['write']:
            bits.append(f'**ipa**: `{cu["ipa"]}` → `{d.get("ipa")}`')
        if 'context' in r['write']:
            bits.append(f'**例句**: "{cu["context"]}" → "{d.get("context")}"')
        if 'definition' in r['write']:
            tail = f'（整卡污染 ← `{r["contam"]}`）' if r['contam'] else ''
            bits.append(f'**释义**: "{cu["def_en"]}" → "{dfn.get("en")}" {tail}')
        A(f'| `{r["spelling"]}` | {"+".join(r["write"])} | {"·".join(r["signals"])} | '
          + ",".join(r['hard']) + ' | ' + '<br>'.join(bits) + ' |')
    A('')
    A('## 五、判据说明（🔑 为什么不能只看「是否相同」）')
    A('')
    A('| 字段 | 性质 | 「现状错」的判据 | 允许覆盖的字段 |')
    A('|---|---|---|---|')
    A('| `ipa` | **封闭**（一个词的正确音标有限） | 残缺 / 未覆盖全 / 疑截断 / 与 v6 不同 | ✅ `ipa` |')
    A('| `pos` | **近似封闭** | 与 v6 不同 → 有一方错（**须人眼**） | ❌ 不自动写 |')
    A('| `definition` | **开放式**（同义表述很多） | 现状**为空**；或已证实**整卡污染** | ⚠️ 仅上述两种 |')
    A('| `context` | **开放式**（例句无穷多） | **不含该词**（词形还原后） | ✅ `context` |')
    A('')
    A('### ⚠️ 教训一：`word_form` 表**只收规则变形** —— 拿它当唯一依据会大面积误报')
    A('')
    A('实测（2026-09-29）：`base=bury` 只有 burial/buries/burying（**没有 buried**）·')
    A('`base=leaf` 只有 leafed/leafing/leafs（**没有 leaves**）·')
    A('`base=shrink` 只有 shrinked/shrinking/shrinks（**没有 shrank**）。')
    A('→ 靠它判「例句是否含该词」，会把不规则变形**全部误判为「不含」**。')
    A('')
    A(f'本表改为**自造规则变形 + 补不规则/拼写变体 + 复合词判定**（见 `surface_forms`）。')
    A(f'结果：S4 命中里 **{len(s4_fp)} 条**是判据误差（例句其实是合法的），已从「确定要修」中剔除：')
    A('')
    if s4_fp:
        for r in sorted(s4_fp, key=lambda x: x['spelling'])[:60]:
            A(f'- `{r["spelling"]}`: "{r["current"]["context"]}"')
    A('')
    A('### 🔑 教训二：`definition` 的「不同」大多是**措辞差异**，不是错')
    A('')
    A('`definition` 是**开放式**字段（同义表述无穷多），且 LLM 与人工的书写习惯不同')
    A('（大小写、句末句号、详略）。实测 `bulletin` 现状 "A short official notice or report')
    A('giving news or information to many people." 比 v6 "a short official notice or news')
    A('report" **更详细** —— 覆盖它是**净损失**。')
    A('')
    A('唯一例外是**整卡污染**（内容来自另一个词），此时释义必须一起换：')
    A('')
    if contam:
        A('| 词 | 内容来自 | 现状 ipa | 现状例句 |')
        A('|---|---|---|---|')
        for r in sorted(contam, key=lambda x: x['spelling']):
            A(f'| `{r["spelling"]}` | `{r["contam"]}` | `{r["current"]["ipa"]}` | '
              f'"{r["current"]["context"]}" |')
    else:
        A('（本次未发现）')
    A('')
    A('## 六、v6 产出质量自查')
    A('')
    b_new = [r for r in results if ipa_broken(r['data'].get('ipa'))
             or not ipa_covers_phrase(r['data'].get('ipa'), r['spelling'])
             or ipa_truncated(r['data'].get('ipa'), r['spelling'])]
    c_new = [r for r in results
             if not contains_word(r['data'].get('context'), r['spelling'], forms_map)[0]]
    A('| 检查 | 结果 |')
    A('|---|---|')
    A(f'| v6 产出的 `ipa` 残缺 / 未覆盖全词组 / 疑截断 | **{len(b_new)}** |')
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
    A('*本报告**只生成候选，未写 `word.db`**。写库由 `scripts/apply_card_field_fixes.py` 执行（需单独批准）。*')

    os.makedirs(os.path.dirname(OUT_REPORT), exist_ok=True)
    open(OUT_REPORT, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
    print(f'✅ 报告已写 {OUT_REPORT}')

    print(f'\n汇总: 成功 {len(results)}/{len(cands)} · '
          + ' · '.join(f'{k}={v}' for k, v in by_level.most_common())
          + f' · 失败 {len(failed)}')
    print(f'建议写入 {len(plan)} 条 · 字段 {dict(fld)} · 整卡污染 {len(contam)} · S4 判据误差 {len(s4_fp)}')
    print(f'成本 ≈ ¥{cost:.4f} · 耗时 {secs:.0f}s')
    if st['http_429'] or st['retries']:
        print(f'⚠️ 疑似限流: {st}')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main())
