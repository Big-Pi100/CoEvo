"""逐语言检查 prebuilt_language_cards 数据质量"""
import json, os
from collections import Counter

V4 = r'E:/CoEvo/data/curriculum/v4'

with open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8') as f:
    pc = json.load(f)
with open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8') as f:
    lang = json.load(f)
lang_map = {c['id']: c for c in lang}

print('═══ 逐语言数据质量检查 ═══')
print()

for subj in ['chinese', 'english', 'japanese', 'russian']:
    subj_ids = [c['id'] for c in pc if c.get('subject') == subj]
    print(f'[{subj.upper()}] {len(subj_ids)} 张')
    
    # Stats
    has_top_pos = 0
    has_pron = 0
    has_level = 0
    has_phrases = 0
    has_structure = 0
    defs_with_pos = 0
    defs_total = 0
    
    for cid in subj_ids:
        entry = lang_map.get(cid)
        if not entry:
            continue
        
        # Top-level fields
        if entry.get('pos', '').strip():
            has_top_pos += 1
        if entry.get('pronunciation', '').strip():
            has_pron += 1
        if entry.get('level', '').strip():
            has_level += 1
        if entry.get('related_phrases', '').strip():
            has_phrases += 1
        if entry.get('structure_meta', '').strip():
            has_structure += 1
        
        # Definitions JSON analysis
        defs_raw = entry.get('definitions', '[]')
        try:
            defs = json.loads(defs_raw) if isinstance(defs_raw, str) else defs_raw
        except:
            defs = []
        if isinstance(defs, list):
            for d in defs:
                defs_total += 1
                if isinstance(d, dict) and d.get('pos', '').strip():
                    defs_with_pos += 1
    
    n = len(subj_ids)
    print(f'  顶层 pos:       {has_top_pos}/{n}')
    print(f'  pronunciation:  {has_pron}/{n}')
    print(f'  level:          {has_level}/{n}')
    print(f'  related_phrases:{has_phrases}/{n}')
    print(f'  structure_meta: {has_structure}/{n}')
    if defs_total > 0:
        print(f'  definitions 有 pos: {defs_with_pos}/{defs_total}')
    print()
