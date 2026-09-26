"""全面修复 prebuilt_language_cards 数据问题

修复清单：
1. 🔴 统一表结构：日文/俄文补全缺失字段 + 删除多余字段
2. 🔴 中文顶层 pos 从 definitions 提取
3. 🔴 日文/俄文 definitions 条目补上 pos
4. 🟡 删除所有跨域污染字段（日文/俄文残留）
5. 🟢 英文 structure_meta 保持现状（V3 无此数据）
"""
import json, os

V4 = r'E:/CoEvo/data/curriculum/v4'

with open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8') as f:
    pc = json.load(f)
with open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8') as f:
    lang = json.load(f)

lang_map = {c['id']: c for c in lang}

# language 子表标准字段
LANG_FIELDS = {'id', 'pronunciation', 'pos', 'definitions', 'related_phrases', 'structure_meta', 'level'}

stats = {subj: {'fixed_struct': 0, 'fixed_pos': 0, 'fixed_defs_pos': 0} 
         for subj in ['chinese', 'english', 'japanese', 'russian']}

for subj in ['chinese', 'english', 'japanese', 'russian']:
    subj_ids = [c['id'] for c in pc if c.get('subject') == subj]
    for cid in subj_ids:
        entry = lang_map.get(cid)
        if not entry:
            continue
        
        changed = False
        
        # ── 1. 删除多余字段 ──
        extras = set(entry.keys()) - LANG_FIELDS
        if extras:
            for k in extras:
                del entry[k]
            changed = True
        
        # ── 2. 补全缺失字段 ──
        missing = LANG_FIELDS - set(entry.keys())
        for k in missing:
            entry[k] = ''
            changed = True
        
        if changed:
            stats[subj]['fixed_struct'] += 1
        
        # ── 3. 中文顶层 pos ──
        if subj == 'chinese' and not entry.get('pos', '').strip():
            defs_raw = entry.get('definitions', '[]')
            try:
                defs = json.loads(defs_raw) if isinstance(defs_raw, str) else defs_raw
            except:
                defs = []
            if isinstance(defs, list) and defs and isinstance(defs[0], dict):
                first_pos = defs[0].get('pos', '')
                if first_pos:
                    entry['pos'] = first_pos
                    stats[subj]['fixed_pos'] += 1
        
        # ── 4. definitions 条目补上 pos ──
        defs_raw = entry.get('definitions', '[]')
        try:
            defs = json.loads(defs_raw) if isinstance(defs_raw, str) else defs_raw
        except:
            defs = []
        top_pos = entry.get('pos', '')
        if isinstance(defs, list):
            defs_changed = False
            for d in defs:
                if isinstance(d, dict) and not d.get('pos', '').strip() and top_pos:
                    d['pos'] = top_pos
                    defs_changed = True
            if defs_changed:
                entry['definitions'] = json.dumps(defs, ensure_ascii=False)
                stats[subj]['fixed_defs_pos'] += 1

# Save
json.dump(lang, open(f'{V4}/cards/language/prebuilt_language_cards.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)

print('═══ 修复汇总 ═══')
for subj, s in stats.items():
    print(f'[{subj.upper()}]')
    print(f'  表结构统一（删除多余+补全缺失）: {s["fixed_struct"]} 张')
    print(f'  顶层 pos 提取:                  {s["fixed_pos"]} 张')
    print(f'  definitions 补 pos:             {s["fixed_defs_pos"]} 张')
    print()
