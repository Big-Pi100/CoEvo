import json, os
from collections import Counter

V3 = r'E:/CoEvo/data/curriculum/v3'
V4 = r'E:/CoEvo/data/curriculum/v4'

v3_zh = json.load(open(f'{V3}/cards/chinese.json', 'r', encoding='utf-8'))['cards']

# Count vocabulary cards per grade_band in V3
vocab_by_gb = Counter(c.get('grade_band','') for c in v3_zh if c['card_type'] == 'vocabulary')
print('V3 语文 vocabulary 卡 grade_band 分布:')
for gb, cnt in sorted(vocab_by_gb.items()):
    print(f'  [{gb:8s}] {cnt} 张')
print()

# Check non-g7-9 vocabulary cards
non_g79 = [c for c in v3_zh if c['card_type'] == 'vocabulary' and c.get('grade_band','') != 'g7-9']
print(f'非 g7-9 的 vocabulary: {len(non_g79)} 张')
for c in non_g79[:5]:
    print(f'  front={c["front"]} gb={c.get("grade_band","")}')

# Load Chinese plan
print()
plan = json.load(open(f'{V4}/plans/chinese.json', 'r', encoding='utf-8'))
print(f'语文 plan: {len(plan.get("stages",[]))} stages')
v3_map = {c['id']: c for c in v3_zh}

for s in plan.get('stages', []):
    stage_gb = s.get('grade_band', '')
    tasks = s.get('tasks', [])
    # Check first task's first card_id
    if not tasks:
        continue
    first_cid = tasks[0].get('card_ids', [''])[0]
    v3_card = v3_map.get(first_cid)
    v3_gb = v3_card.get('grade_band','') if v3_card else 'N/A'
    v3_type = v3_card.get('card_type','') if v3_card else 'N/A'
    mismatch = '⚠️ MISMATCH' if v3_gb != stage_gb else 'OK'
    print(f'  stage={s["name"][:20]:20s} plan_gb={stage_gb:8s} first_card_gb={v3_gb:8s} type={v3_type:15s} {mismatch}')

# Check: how many cards per stage have wrong grade_band
print()
print('=== 逐 stage grade_band 一致性检查 ===')
for s in plan.get('stages', []):
    stage_gb = s.get('grade_band', '')
    mismatches = 0
    total = 0
    stage_types = Counter()
    for t in s.get('tasks', []):
        for cid in t.get('card_ids', []):
            total += 1
            v3_card = v3_map.get(cid)
            if v3_card:
                v3_gb = v3_card.get('grade_band', '')
                stage_types[v3_card.get('card_type','')] += 1
                if v3_gb and v3_gb != stage_gb:
                    mismatches += 1
    pct = mismatches * 100 // total if total else 0
    print(f'  {s["name"][:20]:20s} plan_gb={stage_gb:8s} cards={total:5d} mismatches={mismatches:4d} ({pct}%) types={dict(stage_types.most_common(3))}')
