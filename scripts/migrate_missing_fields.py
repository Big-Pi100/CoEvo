"""补全 V4 语言子表中 English/Japanese/Russian 迁移遗漏的字段。

映射表：
  V3 English           → V4 language sub-table
  ─────────────────────────────────────
  cefr_level           → level
  back.phonetic        → pronunciation
  back.definitions     → definitions
  back.collocations    → related_phrases
  back.key_grammar     → structure_meta
"""
import json, os

V3 = r'E:\CoEvo\data\curriculum\v3'
V4 = r'E:\CoEvo\data\curriculum\v4'

def load_json(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)

def save_json(path, data):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

# ── Load all data ──
v3_english = load_json(os.path.join(V3, 'cards', 'english.json'))['cards']
v3_chinese = load_json(os.path.join(V3, 'cards', 'chinese.json'))['cards']
v3_japanese = load_json(os.path.join(V3, 'cards', 'japanese.json'))['cards']
v3_russian = load_json(os.path.join(V3, 'cards', 'russian.json'))['cards']

v4_lang = load_json(os.path.join(V4, 'cards', 'language', 'prebuilt_language_cards.json'))
v4_pc = load_json(os.path.join(V4, 'cards', 'language', 'prebuilt_cards.json'))

# Build V4 indexes
v4_by_id = {c['id']: c for c in v4_lang}
v4_pc_by_id = {c['id']: c for c in v4_pc}

def fill(v3_cards, label):
    """Fill V4 language sub-table fields from V3 cards"""
    updated = 0
    level_filled = 0
    pron_filled = 0
    defs_filled = 0
    phrases_filled = 0
    grammar_filled = 0
    
    for v3_card in v3_cards:
        cid = v3_card['id']
        if cid not in v4_by_id:
            continue
        
        v4_entry = v4_by_id[cid]
        v3_back = v3_card.get('back', '{}')
        try:
            back_data = json.loads(v3_back) if isinstance(v3_back, str) else v3_back
        except (json.JSONDecodeError, TypeError):
            back_data = {}
        
        changed = False
        
        # 1. cefr_level → level
        level = v3_card.get('cefr_level', '')
        if level and not v4_entry.get('level', '').strip():
            v4_entry['level'] = level
            level_filled += 1
            changed = True
        
        # 2. back.phonetic → pronunciation
        phonetic = back_data.get('phonetic', '')
        if phonetic and not v4_entry.get('pronunciation', '').strip():
            v4_entry['pronunciation'] = phonetic
            pron_filled += 1
            changed = True
        
        # 3. back.definitions → definitions (only if currently empty)
        v3_defs = back_data.get('definitions', '')
        v4_defs = v4_entry.get('definitions', '[]').strip()
        if v3_defs and v4_defs in ('[]', '') and not isinstance(v3_defs, list):
            # V3 back.definitions is already a JSON string
            try:
                # Validate it's proper JSON
                json.loads(v3_defs) if isinstance(v3_defs, str) else v3_defs
                v4_entry['definitions'] = v3_defs
                defs_filled += 1
                changed = True
            except:
                pass
        elif v3_defs and v4_defs in ('[]', '') and isinstance(v3_defs, list):
            v4_entry['definitions'] = json.dumps(v3_defs, ensure_ascii=False)
            defs_filled += 1
            changed = True
        
        # 4. back.collocations → related_phrases
        colloc = back_data.get('collocations', '')
        if colloc and not v4_entry.get('related_phrases', '').strip():
            if isinstance(colloc, list):
                v4_entry['related_phrases'] = '、'.join(colloc)
            else:
                v4_entry['related_phrases'] = str(colloc)
            phrases_filled += 1
            changed = True
        
        # 5. back.key_grammar → structure_meta
        grammar = back_data.get('key_grammar', '')
        if grammar and not v4_entry.get('structure_meta', '').strip():
            if isinstance(grammar, dict):
                v4_entry['structure_meta'] = json.dumps(grammar, ensure_ascii=False)
            else:
                v4_entry['structure_meta'] = str(grammar)
            grammar_filled += 1
            changed = True
        
        if changed:
            updated += 1
    
    print(f'[{label}]')
    print(f'  更新条目: {updated}/{len(v3_cards)}')
    print(f'  level 补填:        {level_filled}')
    print(f'  pronunciation 补填: {pron_filled}')
    print(f'  definitions 补填:   {defs_filled}')
    print(f'  related_phrases 补填: {phrases_filled}')
    print(f'  structure_meta 补填:  {grammar_filled}')
    print()

# ── Run migrations ──
fill(v3_english, 'ENGLISH')
fill(v3_chinese, 'CHINESE')

# Check Japanese and Russian V3 back structure
for label, cards in [('JAPANESE', v3_japanese), ('RUSSIAN', v3_russian)]:
    has_back = sum(1 for c in cards if c.get('back', '{}').strip() not in ('', '{}'))
    print(f'[{label}] V3 有 back 数据: {has_back}/{len(cards)} 张')
    if has_back:
        sample = next(c for c in cards if c.get('back', '{}').strip() not in ('', '{}'))
        back = sample.get('back', '')
        try:
            bd = json.loads(back) if isinstance(back, str) else back
            print(f'  back keys: {list(bd.keys()) if isinstance(bd, dict) else "non-dict"}')
        except:
            print(f'  back (raw): {str(back)[:100]}')
    print()

# ── Save ──
save_json(os.path.join(V4, 'cards', 'language', 'prebuilt_language_cards.json'), v4_lang)
print('✅ V4 language 子表已保存')
