#!/usr/bin/env python3
"""#5 词形聚合 · 组 C（灰区）细分器。

背景（2026-09-25）：
  `build_variants_and_families.py` 产出的 #5 候选把 1,383 对分成 A/B/C 三组，
  其中 **组 C（161 条）被标为「灰区，待白哥判断」**。
  但逐条查看后发现它们**不是灰区** —— 而是有明确规律的五类，其中仅 18 条真需人判。

本脚本把组 C 细分为：
  C1 派生副词（-ly）        → 合并（语义可推导）
  C2 活动/领域名词（-ing）  → 保留（是独立事物/活动）
  C3 纯形态变化             → 合并
  C4 同形异义（homograph）  → 保留  ← 🔴 仅这 18 条需人判
  C5 数据问题               → 分别处理（5 个子类）

用法：
  python3 scripts/classify_family_group_c.py                # 分类 + 报告
  python3 scripts/classify_family_group_c.py --show C4      # 只看某一类
  python3 scripts/classify_family_group_c.py --emit-rules   # 输出可回写的处置清单
"""
import argparse
import json
import os
import re
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'word_family_candidates.json')
OUT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'group_c_resolution.json')

# ── C4 同形异义：form 与 lemma 是两个不同的词，必须独立建卡 ──
#   判据：词形已完全词汇化（不再是原词的形态变体），或与 lemma 语义无关
HOMOGRAPH = {
    'bore': '「使厌烦」独立动词 ≠ bear「忍受」',
    'wound': '「伤口/使受伤」≠ wind「缠绕」',
    'well': '独立副词/形容词（健康的）/名词（井）',
    'less': '独立副词/限定词',
    'might': '独立名词（力量、威力）',
    'bent': '独立形容词（弯曲的/不诚实的）',
    'drunk': '独立形容词（醉的）',
    'building': '独立名词（建筑物 —— 实体，非「建造」动作）',
    'meeting': '独立名词（会议）',
    'reading': '独立名词（阅读/读数/诠释）',
    'drawing': '独立名词（图画）',
    'training': '独立名词（训练）',
    'boxing': '独立名词（拳击）',
    'setting': '独立名词（背景/设定）',
    'shooting': '独立名词（射击/枪击案）',
    'leading': '独立形容词（主要的）',
    'rolling': '独立形容词（起伏的）',
    'winding': '独立形容词（蜿蜒的）',
}

# ── C5c 真实误连：form 不是 lemma 的变形，映射错了 ──
MISLINKED = {
    'feed': 'fee',      # feed 是独立动词，fee 的复数是 fees
    'inning': 'inn',    # inning 是棒球术语，与 inn 无关
    'lens': 'len',      # lens 是独立名词，len 不是英语词
}

# ── C5d 专有名词残留（上轮清洗漏网）──
PROPER_RESIDUE = {
    'laos': '老挝（国家名）',
    'nazis': '纳粹（政党成员）',
    'whigs': '辉格党（政党成员）',
    'pauling': '鲍林（电负性，源自人名 Linus Pauling）',
}

# ── C5e 其他（待定）──
# ── 🔑 自述型措辞判据（不用 pos —— 实测 pos 覆盖不足，会漏判）──
#   经验来源：2026-09-25 词表清洗 —— pos 常缺失/格式混乱，definitions 的措辞更可靠
NOUN_SELF = re.compile(
    # 活动/领域名词：「the activity/sport/act/process of ...」
    r'^(?:the|an?)\s+(?:activity|sport|act|action|process|practice|art|industry|'
    r'provision|use|occasion|system|business)\b',
    re.I,
)
NOUN_ENTITY = re.compile(
    # 实体/集合名词（不是动作）
    r'^(?:a|an|the)\s+(?:structure|picture|diagram|group|work of art|short trip|'
    r'large artificial basin|system of)|^clothes collectively|^the equipment',
    re.I,
)
ADJ_SELF = re.compile(
    # 形容词/分词用法：「causing / at or near / on fire / having / moving / ...」
    r'^(?:causing|at or near|on fire|having|moving|making|bending|performing|'
    r'most important|curved|affected by|filled with|on the surface)',
    re.I,
)

MISC = {
    'bogeyed': '高尔夫术语 bogey 的动词变形 —— 是否为独立词待定',
    'multiply': '独立动词（乘）≠ multiple（形容词/名词）',
    'metaphysics': '反向关系：metaphysics 是常用形，metaphysic 罕见',
}


def classify(rec: dict) -> tuple[str, str]:
    """返回 (类别, 说明)。顺序重要：先排数据问题，再排同形异义，最后才是形态类。"""
    f = rec['form']
    lem = rec['lemma']
    fpos = (rec.get('form_pos') or '').lower()
    lpos = (rec.get('lemma_pos') or '').lower()
    fdef = (rec.get('form_def') or '').lower()

    # C5c 真实误连
    if f in MISLINKED:
        return 'C5c_误连', f'form 不是 {lem} 的变形（应修正映射）'
    # C5d 专有名词残留
    if f in PROPER_RESIDUE:
        return 'C5d_专有名词残留', PROPER_RESIDUE[f]
    # C5e 其他
    if f in MISC:
        return 'C5e_其他', MISC[f]

    # C4 同形异义
    if f in HOMOGRAPH:
        return 'C4_同形异义', HOMOGRAPH[f]

    # 🔑 取「首义」判定 —— 经验：一词多义时类别由首义决定（2026-09-25 词表清洗同款教训）
    first = re.split(r'\.\s', fdef, maxsplit=1)[0] if fdef else ''

    # ── C2 派生活动/实体名词（-ing 但已词汇化）—— ⚠️ 必须排在 C5b 之前，否则被形态判据拦截 ──
    if f.endswith('ing'):
        if NOUN_SELF.search(first) or NOUN_ENTITY.search(first):
            return 'C2_活动名词', f'首义自述为活动/实体名词（{first[:44]}）'
        if not fdef.strip():
            return 'C2b_无释义待定', f'{f} 无释义，无法判定（需补内容）'
        # 落此处的 -ing 词：首义是分词/形容词用法 → 合并
        return 'C5b_正常变形', f'{f} 首义为分词/形容词（{first[:40]}）'

    # C5a 正常复数 / 第三人称单数（被误判成灰区）
    rest = f[len(lem):] if f.startswith(lem) else None
    if rest in ('s', 'es', 'ies', 'ves'):
        return 'C5a_正常复数', f'{f} = {lem} + {rest}（应归组 A 合并）'

    # C5b 正常变形（过去式/过去分词）
    if rest in ('ed', 'd', 'ied', 'ting', 'ning', 'ring', 'ding', 'ling'):
        return 'C5b_正常变形', f'{f} = {lem} + {rest}（应归组 A 合并）'

    # C1 派生副词
    if f.endswith('ly') and ('adverb' in fpos or f.endswith(('ally', 'ily', 'edly'))):
        return 'C1_派生副词', f'{f} = {lem} + -ly（语义可推导，建议合并）'

    # C3 纯形态（不规则变形等）
    return 'C3_纯形态', f'{f} ← {lem}（{rec.get("rule","")}）'


ADVICE = {
    'C1_派生副词':      ('❌ 合并', '语义可推导，副词单独建卡记忆价值低'),
    'C2_活动名词':      ('✅ 保留', '是独立事物/活动名，不是动词的 -ing 形式'),
    'C2b_无释义待定':   ('🟠 待定', '无释义 → 无法判定（应归内容补全）'),
    'C3_纯形态':        ('❌ 合并', '纯形态变化'),
    'C4_同形异义':      ('✅ 保留', '🔴 需人判 —— form 与 lemma 是两个词'),
    'C5a_正常复数':      ('❌ 合并', '纯复数，应归组 A'),
    'C5b_正常变形':      ('❌ 合并', '纯形态变化，应归组 A'),
    'C5c_误连':         ('🔧 修正', '映射错误 —— 从 word_form 移除'),
    'C5d_专有名词残留':  ('🗑️ 删除', '与已批准的「专有名词可删」同类'),
    'C5e_其他':         ('🟠 待定', '需白哥判'),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--show', help='只显示某一类（如 C4）')
    ap.add_argument('--emit-rules', action='store_true', help='输出处置清单 JSON')
    args = ap.parse_args()

    data = json.load(open(SRC, encoding='utf-8'))
    C = data['C_灰区_待白哥判断']

    buckets = defaultdict(list)
    for rec in C:
        cat, why = classify(rec)
        rec = dict(rec)
        rec['_class'] = cat
        rec['_reason'] = why
        buckets[cat].append(rec)

    order = ['C1_派生副词', 'C2_活动名词', 'C2b_无释义待定', 'C3_纯形态', 'C4_同形异义',
             'C5a_正常复数', 'C5b_正常变形', 'C5c_误连', 'C5d_专有名词残留', 'C5e_其他']

    print('=' * 96)
    print(f'组 C 细分（{len(C)} 条 → 9 类）')
    print('=' * 96)
    print(f'{"类别":<20}{"数量":>6}  处置      说明')
    print('-' * 96)
    for k in order:
        rows = buckets.get(k, [])
        if not rows:
            continue
        adv, note = ADVICE[k]
        print(f'{k:<20}{len(rows):>6}  {adv:<9}{note}')
    print('-' * 96)

    merge = sum(len(buckets.get(k, [])) for k in ('C1_派生副词', 'C3_纯形态', 'C5a_正常复数', 'C5b_正常变形'))
    keep = sum(len(buckets.get(k, [])) for k in ('C2_活动名词', 'C4_同形异义'))
    print(f'❌ 合并 {merge}  |  ✅ 保留 {keep}  |  '
          f'🗑️ 删除 {len(buckets.get("C5d_专有名词残留", []))}  |  '
          f'🔧 修正 {len(buckets.get("C5c_误连", []))}  |  '
          f'🟠 待定 {len(buckets.get("C5e_其他", []))}')
    print()
    print('🔴 真正需要白哥判断的：')
    print(f'   C4 同形异义 {len(buckets.get("C4_同形异义", []))} 条 ＋ C5e 其他 {len(buckets.get("C5e_其他", []))} 条'
          f' ＋ C2/C4 的边界判据（是否同意「已完全名词化的 -ing 保留」）')

    show = [args.show] if args.show else None
    order = [k for k in order if k in buckets] + [k for k in buckets if k not in order]
    keys = [k for k in order if (show is None or any(k.startswith(s) or s in k for s in show))]
    # 默认只详列 C4 / C5c / C5d / C5e
    if not args.show:
        keys = ['C4_同形异义', 'C5c_误连', 'C5d_专有名词残留', 'C5e_其他']
    for k in keys:
        rows = buckets.get(k, [])
        if not rows:
            continue
        adv, note = ADVICE[k]
        print(f'\n{"─" * 96}\n{k} · {len(rows)} 条 · {adv}\n{"─" * 96}')
        for r in sorted(rows, key=lambda x: x['form']):
            print(f"  {r['form']:<16} ← {r['lemma']:<14} {r['_reason'][:60]}")

    if args.emit_rules:
        payload = {
            '_meta': {
                'source': os.path.basename(SRC),
                'total': len(C),
                'note': '组 C 细分结果 —— 供 Phase 1 #5（词形聚合）的 M0 阶段直接使用',
            },
            'merge_to_lemma': {k: buckets.get(k, []) for k in
                               ('C1_派生副词', 'C3_纯形态', 'C5a_正常复数', 'C5b_正常变形')},
            'keep_standalone': {k: buckets.get(k, []) for k in
                                ('C2_活动名词', 'C4_同形异义')},
            'delete': buckets.get('C5d_专有名词残留', []),
            'fix_mapping': buckets.get('C5c_误连', []),
            'pending': buckets.get('C5e_其他', []) + buckets.get('C2b_无释义待定', []),
        }
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        json.dump(payload, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print(f'\n✅ 处置清单已写入 {os.path.relpath(OUT, ROOT)}')


if __name__ == '__main__':
    main()
