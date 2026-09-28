#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""卡片字段自洽性校验 —— 把「字段对不对」变成可复跑、有退出码的断言

# 为什么需要（2026-09-28 白哥指示）
「**词在库但内容错要修 —— 这个要全库扫描，排查错误并重新修正**」

触发：发现 `a` 的卡片 ipa/definition/context **三段是 `happy` 的**；
深入扫描又查出三类系统性错误（详见 `docs/design/card-field-contamination-2026-09-28.md`）。

🔑 **与 `verify_card_structure.py` 的分工**（两者互补，都要跑）：
| 脚本 | 管什么 | 能抓 `a` 的 `/ˈhæpi/` 吗 |
|---|---|---|
| `verify_card_structure.py` | **结构**（段类型、顺序、数量） | ❌ 结构完全合法 |
| **本脚本** | **字段内容的自洽**（ipa/释义/例句 与词是否匹配） | ✅ |

# 四类信号
| 信号 | 判据 | 精确率（实测） |
|---|---|---|
| **S1** `ipa` 残缺 | 没有任何一个**完整**的 `/…/` 段 | 高（`/ˈ` 这种只剩重音符） |
| **S2** `ipa` 截断 | 实质字符数 / 拼写字母数 < **0.45** | **100%**（18/18 全真错） |
| **S3a** 多词短语 `ipa` 撞车 | 两个**不同短语**的 ipa 完全相同 | **100%**（不同短语不可能同音） |
| **S3b** 单词 `ipa` 撞车 | ipa 与「字形不相似」的词相同 | 中（含真同音词干扰，须逐条判） |
| **S4** `context` 不含该词 | 例句里找不到该词**或其已知变形** | 中（不规则变形/缩写会误报） |

# 🔴 已知边界（如实标注，不要当成"没问题是"）
· **S3b 无法区分「真同音词」与「字段错位」** —— `right`/`rite`/`write` 都该是 `/raɪt/`（合理），
  而 `a`/`happy` 也是 `/ˈhæpi/`（错误）。两者机械上同形 → **必须逐条人工/LLM 判定**。
· `en`/`ellen` 同 ipa 会**漏报**（`en` 是 `ellen` 的后缀，被"字形相似"规则放过）——
  它已被人工识别，见报告 §2.3。
· **S4 的变形还原是启发式的** —— 不规则变形（`outgrown`/`underwent`/`seventieth`）仍会误报。
· 本脚本**只查「字段是否张冠李戴」**，**不查语义是否正确**
  （释义写得对不对、词源可不可信 → 需 LLM 判定，见报告 §六）。

# 用法
    python3 scripts/verify_card_field_consistency.py               # 汇总
    python3 scripts/verify_card_field_consistency.py --list        # 列出全部候选
    python3 scripts/verify_card_field_consistency.py --json out.json   # 导出（供 LLM 复核）
    python3 scripts/verify_card_field_consistency.py --word a      # 只查某个词（生成后校验用）
退出码：0 = 无命中；1 = 有命中（**可用于 CI / 生成后闸门**）
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(ROOT, 'data', 'word.db')

# S2 的阈值：IPA 实质字符数 / 拼写字母数
# 实测：真错的一批在 0.23~0.44；正常词最低也有 0.5 以上 → 取 0.45 留余量
RATIO_MIN = 0.45

# S4 的轻量还原（补 `word_form` 的覆盖缺口 —— `committing`/`cancelled`/`outgrown` 都不在表里）
_SUFFIXES = ('s', 'es', 'ed', 'd', 'ing', 'ly')


def fold(s: str) -> str:
    """去变音符：Phèdre → phedre · café → cafe

    🔴 必需 —— 正则 `[a-z]` 遇到 `è` 会**断开**（`Phèdre` 被切成 `ph`+`dre`），
       造成「例句不含该词」的假阳性（实测：`phedre` 就是这么误报的）。
    """
    return ''.join(c for c in unicodedata.normalize('NFKD', (s or '').lower())
                   if not unicodedata.combining(c))


def tokens(text: str) -> set:
    """分词（已 fold）。额外产出所有格 / 连字符的等价形式以降低误报。"""
    out = set()
    for m in re.finditer(r"[a-z]+(?:['\-][a-z]+)*", fold(text)):
        tok = m.group(0)
        out.add(tok)
        out.add(tok.replace("'s", '').replace("'", ''))
        for part in re.split(r"['\-]", tok):
            if part:
                out.add(part)
    return out


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a or not b:
        return len(a) or len(b)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def ipa_segments(ipa: str) -> list:
    """提取所有完整的 /…/ 段"""
    return re.findall(r'/[^/]*/', ipa or '')


# 英美/拼写变体的常见差异（用于判断「两个条目是不是同一个词的两种写法」）
_VARIANT_PAIRS = [('our', 'or'), ('ise', 'ize'), ('re', 'er'), ('ogue', 'og'),
                  ('ll', 'l'), ('mme', 'm'), ('ae', 'e'), ('oe', 'e')]


def _norm_phrase(s: str) -> str:
    """归一化短语：去空格/连字符 + 折叠常见英美变体差异

    `face to face` → `facetoface` · `face-to-face` → `facetoface`（相等 → 是同一个词）
    `sports centre` → `sportscener`（保留差异，交给编辑距离判定）
    """
    t = re.sub(r"[\s\-']", '', fold(s))
    for a, b in _VARIANT_PAIRS:
        t = t.replace(a, b)
    return t


def ipa_core_len(ipa: str) -> int:
    """IPA 实质字符数（去掉 / [ ] 重音 ˌˈ 音节点 . 与空白）"""
    return len(re.sub(r"[/\[\]ˌˈ\.\s]", '', ipa or ''))


def similar_word(x: str, y: str, forms_of) -> bool:
    """字形是否相似（相似 → 撞车合理，应排除）

    🔴 **不能用「互为子串」**（实测教训 2026-09-28）：
      · `'it' in 'with'`  → True（巧合）→ `with`/`it` 的污染被放过
      · `'a'  in 'happy'` → True（单字母是任何词的子串）→ `a`/`happy` 的污染被放过
    ✅ 改为「前缀/后缀」+「编辑距离 ≤2 **且** 长度差 ≤1」
      · `be`/`bee` 前缀 ✅ · `en`/`ellen` 后缀 ✅（⚠️ 这条会漏报 `en`，已知边界）
      · `it`/`with` 既非前后缀，距离 2 但长度差 2 → **正确判为不相似**
    """
    if x == y:
        return True
    if x.startswith(y) or y.startswith(x):
        return True
    if x.endswith(y) or y.endswith(x):
        return True
    if levenshtein(x, y) <= 2 and abs(len(x) - len(y)) <= 1:
        return True
    if forms_of(x) & forms_of(y):
        return True
    return False


def contains_word(text: str, spelling: str, forms_of) -> bool:
    """text 里是否出现该词（或其已知变形）"""
    t = tokens(text)
    s = fold(spelling)
    if not s:
        return True
    if s in t:
        return True
    if ' ' in s and s in fold(text):
        return True
    known = forms_of(s)
    if t & known:
        return True
    if t & light_forms(s):
        return True
    for tok in t:
        if s in light_forms(tok):
            return True
    return False


def light_forms(w: str) -> set:
    """轻量还原规则（补 `word_form` 覆盖不到的）"""
    out = set()
    for suf in _SUFFIXES:
        if w.endswith(suf) and len(w) - len(suf) >= 2:
            stem = w[:-len(suf)]
            out.add(stem)
            if len(stem) >= 3 and stem[-1] == stem[-2]:
                out.add(stem[:-1])          # committ → commit
            out.add(stem + 'e')             # achiev → achieve
    for suf in _SUFFIXES:
        out.add(w + suf)
    out.add(w + 'ed')
    out.add(w + 'd')
    out.add(w + 's')
    if len(w) >= 2:
        for suf in ('s', 'ed', 'ing'):
            out.add(w + w[-1] + suf)        # commit → committing
    return out


def load(db):
    con = sqlite3.connect(db)
    forms = defaultdict(set)
    for (f, b) in con.execute('SELECT form, base FROM word_form'):
        forms[fold(b)].add(fold(f))

    def forms_of(w):
        return forms.get(w, set())

    cards = []
    for (wid, sp, et, ct) in con.execute(
            'SELECT w.id, w.spelling, w.entry_type, c.content '
            'FROM word w JOIN card c ON c.word_id = w.id'):
        cards.append((wid, sp, et, json.loads(ct) if ct else {}))
    con.close()
    return cards, forms_of


def check_card(sp, et, d, forms_of):
    """返回该卡命中的信号列表"""
    hits = []
    ipa = (d.get('ipa') or '').strip()
    key = fold(sp)
    letters = len(re.sub(r'[^a-z]', '', key))
    is_phrase = ' ' in sp.strip() or et == 'phrase'

    # ── S1 ipa 残缺：没有任何一个完整 /…/ 段 ──
    if ipa and not ipa_segments(ipa):
        hits.append(('S1', f'ipa 无完整 /…/ 段: {ipa!r}'))
    elif not ipa:
        hits.append(('S1', 'ipa 为空'))

    # ── S2 ipa 截断：实质字符 / 拼写字母 < 阈值 ──
    if ipa and ipa_segments(ipa) and letters >= 4:
        cl = ipa_core_len(ipa)
        r = cl / letters
        if r < RATIO_MIN:
            hits.append(('S2', f'ipa 疑截断 {ipa!r}（实质 {cl} / 字母 {letters} = {r:.2f}）'))

    # ── S4 context 不含该词 ──
    ctx = next((s.get('text') or '' for s in d.get('sections') or []
                if s.get('type') == 'context'), '')
    if ctx and not contains_word(ctx, sp, forms_of):
        hits.append(('S4', f'例句不含该词: {ctx[:70]!r}'))

    return hits, ipa, key, is_phrase


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--list', action='store_true', help='列出全部候选')
    ap.add_argument('--json', metavar='PATH', help='导出候选（供 LLM 复核）')
    ap.add_argument('--word', help='只查某个词（生成后校验用）')
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f'✗ {args.db} 不存在')

    cards, forms_of = load(args.db)
    if args.word:
        cards = [c for c in cards if fold(c[1]) == fold(args.word)]
        if not cards:
            sys.exit(f'✗ 库里没有 {args.word!r}')

    # ── 逐卡检查（S1/S2/S4）──
    per_word = {}
    for wid, sp, et, d in cards:
        hits, ipa, key, is_phrase = check_card(sp, et, d, forms_of)
        per_word[key] = {'spelling': sp, 'entry_type': et, 'ipa': ipa,
                         'hits': hits, 'phrase': is_phrase}

    # ── S3 ipa 撞车（需全库分组）──
    by_ipa = defaultdict(list)
    for key, v in per_word.items():
        segs = ipa_segments(v['ipa'])
        if segs:
            by_ipa[' '.join(segs)].append(key)
    for ip, keys in by_ipa.items():
        if len(keys) < 2:
            continue
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                x, y = keys[i], keys[j]
                if per_word[x]['phrase'] and per_word[y]['phrase']:
                    # S3a：两个**不同短语**同 ipa。
                    # 🔴 但要先排除「**同一个词的两种写法**」—— 它们的 ipa 相同是**正常的**：
                    #    · `face to face` ≡ `face-to-face`（连字符差异）
                    #    · `disc jockey` ≡ `disk jockey`（disc/disk 变体拼写）
                    #    · `sports center` ≡ `sports centre`（英美变体）
                    #    判据：归一化后相同，或编辑距离 ≤ 2。
                    nx, ny = _norm_phrase(x), _norm_phrase(y)
                    if nx == ny or levenshtein(nx, ny) <= 2:
                        continue
                    per_word[x]['hits'].append(('S3a', f'与短语 {per_word[y]["spelling"]!r} 的 ipa 相同: {ip}'))
                    per_word[y]['hits'].append(('S3a', f'与短语 {per_word[x]["spelling"]!r} 的 ipa 相同: {ip}'))
                elif not similar_word(x, y, forms_of):
                    per_word[x]['hits'].append(('S3b', f'与 {per_word[y]["spelling"]!r} 的 ipa 相同: {ip}'))
                    per_word[y]['hits'].append(('S3b', f'与 {per_word[x]["spelling"]!r} 的 ipa 相同: {ip}'))

    flagged = {k: v for k, v in per_word.items() if v['hits']}

    # ── 输出 ──
    print('═' * 74)
    print('卡片字段自洽性校验')
    print('═' * 74)
    print(f'  检查卡片      : {len(cards):,}')
    print(f'  🔴 命中（可疑）: {len(flagged):,}'
          f'  ({len(flagged) / max(len(cards), 1) * 100:.1f}%)')
    print()
    by_sig = defaultdict(list)
    for k, v in flagged.items():
        for s, why in v['hits']:
            by_sig[s].append((v['spelling'], why))
    for s in ('S1', 'S2', 'S3a', 'S3b', 'S4'):
        print(f'    {s:<4} : {len(by_sig[s]):>5}')

    if args.list:
        for s in ('S1', 'S2', 'S3a', 'S3b', 'S4'):
            print()
            print('─' * 74)
            print(f'{s}（{len(by_sig[s])} 条）')
            print('─' * 74)
            for sp, why in sorted(by_sig[s]):
                print(f'  {sp:<24} {why}')

    if args.json:
        out = [{'spelling': v['spelling'], 'entry_type': v['entry_type'],
                'ipa': v['ipa'], 'signals': sorted({s for s, _ in v['hits']}),
                'reasons': [w for _, w in v['hits']]}
               for v in sorted(flagged.values(), key=lambda x: x['spelling'])]
        with open(args.json, 'w', encoding='utf-8') as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f'\n  已导出 {len(out)} 条 → {args.json}')

    return 1 if flagged else 0


if __name__ == '__main__':
    sys.exit(main())
