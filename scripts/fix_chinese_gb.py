"""修正中文 vocabulary 卡的 grade_band：按 plan stage 的 grade_band 覆盖"""
import json, os
from collections import Counter

V4 = r'E:/CoEvo/data/curriculum/v4'

# Load data
v4_pc = json.load(open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8'))
v4_lang = json.load(open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8'))

v4_pc_map = {c['id']: c for c in v4_pc}
v4_lang_map = {c['id']: c for c in v4_lang}

# Load all plans
plans_dir = f'{V4}/plans'
plan_files = [f for f in os.listdir(plans_dir) if f.endswith('.json')]

# Build card_id → stage grade_band mapping from plans
card_gb = {}  # card_id → grade_band from plan
for pf in plan_files:
    plan = json.load(open(f'{plans_dir}/{pf}', 'r', encoding='utf-8'))
    for s in plan.get('stages', []):
        stage_gb = s.get('grade_band', '')
        if not stage_gb:
            continue
        for t in s.get('tasks', []):
            for cid in t.get('card_ids', []):
                if cid in card_gb:
                    # Multiple stages can reference same card; keep first
                    continue
                card_gb[cid] = stage_gb

# Apply to V4 language cards
updated = 0
for card in v4_pc:
    cid = card['id']
    if card.get('subject') != 'chinese':
        continue
    if cid not in card_gb:
        continue
    plan_gb = card_gb[cid]
    current_gb = card.get('grade_band', '')
    if current_gb != plan_gb:
        card['grade_band'] = plan_gb
        updated += 1

print(f'中文 vocabulary 卡修正: {updated} 张')

# Show distribution after fix
print('\n修正后 grade_band 分布:')
gb_counts = Counter(c.get('grade_band','') for c in v4_pc if c.get('subject') == 'chinese')
for gb, cnt in sorted(gb_counts.items()):
    levels = Counter()
    for c in v4_pc:
        if c.get('subject') == 'chinese' and c.get('grade_band','') == gb and c['id'] in v4_lang_map:
            lv = v4_lang_map[c['id']].get('level', '')
            if lv:
                levels[lv] += 1
    level_str = ', '.join(f'{k}={v}' for k, v in sorted(levels.items()))
    print(f'  {gb:8s}: {cnt:>5} 张  level={level_str}')

# Also update level based on new grade_band
gb_to_level = {
    'g1-2': 'A1',
    'g3-4': 'A2',
    'g5-6': 'B1',
    'g7-9': 'B1',
    'g10-12': 'B2',
}
level_updated = 0
for card in v4_pc:
    if card.get('subject') != 'chinese':
        continue
    cid = card['id']
    if cid not in v4_lang_map:
        continue
    gb = card.get('grade_band', '').strip()
    new_level = gb_to_level.get(gb)
    if new_level:
        entry = v4_lang_map[cid]
        entry['level'] = new_level
        level_updated += 1

print(f'\nlevel 重新映射: {level_updated} 张')

# Verify: show level distribution
print('\n最终 level 分布:')
lv_counts = Counter()
for card in v4_pc:
    if card.get('subject') == 'chinese' and card['id'] in v4_lang_map:
        lv = v4_lang_map[card['id']].get('level', '')
        if lv:
            lv_counts[lv] += 1
for lv, cnt in sorted(lv_counts.items()):
    print(f'  {lv}: {cnt} 张')

# Save
json.dump(v4_pc, open(f'{V4}/cards/language/prebuilt_cards.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
json.dump(v4_lang, open(f'{V4}/cards/language/prebuilt_language_cards.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
print('\n✅ 已保存')
