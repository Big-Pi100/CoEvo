"""补全语言子表数据：
1. 日文/俄文：definitions 条目加入 pos + 补 level/related_phrases/structure_meta（空字符串兜底）
2. 中文：顶层 pos 从 definitions 提取
3. 英文：补少量缺失的顶层 pos
"""
import json, os

V4 = r'E:/CoEvo/data/curriculum/v4'

with open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8') as f:
    pc = json.load(f)
with open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8') as f:
    lang = json.load(f)
lang_map = {c['id']: c for c in lang}

# 1. JAPANESE + RUSSIAN: fill definitions with pos, set missing fields
for subj in ['japanese', 'russian']:
    subj_ids = [c['id'] for c in pc if c.get('subject') == subj]
    for cid in subj_ids:
        entry = lang_map.get(cid)
        if not entry:
            continue
        
        # Fill missing fields
        if not entry.get('level', '').strip():
            entry['level'] = ''
        if not entry.get('related_phrases', '').strip():
            entry['related_phrases'] = ''
        if not entry.get('structure_meta', '').strip():
            entry['structure_meta'] = ''
        
        # Add pos to definitions entries
        defs_raw = entry.get('definitions', '[]')
        try:
            defs = json.loads(defs_raw) if isinstance(defs_raw, str) else defs_raw
        except:
            defs = []
        if isinstance(defs, list):
            top_pos = entry.get('pos', '')
            changed = False
            for d in defs:
                if isinstance(d, dict) and not d.get('pos', '').strip():
                    d['pos'] = top_pos
                    changed = True
            if changed:
                entry['definitions'] = json.dumps(defs, ensure_ascii=False)

# 2. CHINESE: extract top-level pos from first definitions entry
subj_ids = [c['id'] for c in pc if c.get('subject') == 'chinese']
for cid in subj_ids:
    entry = lang_map.get(cid)
    if not entry or entry.get('pos', '').strip():
        continue
    defs_raw = entry.get('definitions', '[]')
    try:
        defs = json.loads(defs_raw) if isinstance(defs_raw, str) else defs_raw
    except:
        defs = []
    if isinstance(defs, list) and defs:
        first_pos = defs[0].get('pos', '') if isinstance(defs[0], dict) else ''
        if first_pos:
            entry['pos'] = first_pos

# Save
json.dump(lang, open(f'{V4}/cards/language/prebuilt_language_cards.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
print('✅ 已修复')
