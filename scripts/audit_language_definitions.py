"""审查所有语言类卡片 definitions 缺失情况"""
import json, sqlite3, os

DB = r'E:/CoEvo/backend/data/coevo.db'
V3 = r'E:/CoEvo/data/curriculum/v3'

conn = sqlite3.connect(DB)
cur = conn.cursor()

print('═══ 语言类 cards definitions 缺失审查 ═══')
print()

# ── 1. 按语言统计 definitions 空值 ──
print('=== 1. 空 definitions 统计 ===')
for subj in ['chinese', 'english', 'japanese', 'russian']:
    total = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards WHERE subject = ?1 AND domain = 'language'
    ''', [subj]).fetchone()[0]
    
    empty_defs = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.definitions IS NULL OR plc.definitions = '[]')
    ''', [subj]).fetchone()[0]
    
    empty_top_pos = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.pos IS NULL OR plc.pos = '')
    ''', [subj]).fetchone()[0]
    
    empty_pron = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.pronunciation IS NULL OR plc.pronunciation = '')
    ''', [subj]).fetchone()[0]
    
    empty_phrases = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.related_phrases IS NULL OR plc.related_phrases = '')
    ''', [subj]).fetchone()[0]
    
    print(f'[{subj.upper()}] 总卡 {total}:')
    print(f'  definitions 为空: {empty_defs}')
    print(f'  pos 顶层为空:   {empty_top_pos}')
    print(f'  pronunciation 为空: {empty_pron}')
    print(f'  related_phrases 为空: {empty_phrases}')
print()

# ── 2. 有 defs 为空的卡片清单 ──
print('=== 2. 空 definitions 卡片明细 ===')
for subj in ['chinese', 'english', 'japanese', 'russian']:
    cards = cur.execute('''
        SELECT pc.front, pc.card_type, plc.pronunciation, plc.related_phrases, plc.level
        FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.definitions IS NULL OR plc.definitions = '[]')
        ORDER BY pc.front
        LIMIT 20
    ''', [subj]).fetchall()
    if cards:
        print(f'[{subj.upper()}] {len(cards)} 张（显示前20）:')
        for c in cards[:20]:
            print(f'  {c[0]:20s} type={c[1]:15s} pron={str(c[2])[:25]:25s} phrases={str(c[3])[:30]:30s} level={c[4]}')
    print()

# ── 3. 对照 V3，检查这些空 definitions 卡在 V3 是否有数据 ──
print('=== 3. V3 源数据对照（抽样） ===')
v3_files = {
    'chinese': f'{V3}/cards/chinese.json',
    'english': f'{V3}/cards/english.json',
    'japanese': f'{V3}/cards/japanese.json',
    'russian': f'{V3}/cards/russian.json',
}

for subj, path in v3_files.items():
    with open(path, 'r', encoding='utf-8') as f:
        v3_data = json.load(f)
    v3_list = v3_data.get('cards', v3_data.get('data', []))
    v3_map = {c['id']: c for c in v3_list if isinstance(c, dict) and 'id' in c}
    
    # Get V4 cards with empty definitions
    v4_empty = cur.execute('''
        SELECT pc.id, pc.front FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.subject = ?1 AND (plc.definitions IS NULL OR plc.definitions = '[]')
    ''', [subj]).fetchall()
    
    v3_has_defs = 0
    v3_no_back = 0
    for cid, front in v4_empty:
        v3_card = v3_map.get(cid)
        if v3_card:
            v3_back = v3_card.get('back', '')
            if v3_back and v3_back.strip() not in ('', '{}'):
                # Check if back JSON has definitions
                try:
                    back_data = json.loads(v3_back) if isinstance(v3_back, str) else v3_back
                    if isinstance(back_data, dict):
                        defs = back_data.get('definitions', [])
                        if defs and defs != []:
                            v3_has_defs += 1
                        else:
                            v3_no_back += 1
                    else:
                        v3_no_back += 1
                except:
                    v3_no_back += 1
            else:
                v3_no_back += 1
    
    total_empty = len(v4_empty)
    if total_empty > 0:
        print(f'[{subj.upper()}] 空 definitions 共 {total_empty} 张:')
        print(f'  V3 也没有定义: {v3_no_back}')
        print(f'  V3 有定义但 V4 丢失: {v3_has_defs}')
print()

# ── 4. 检查非 vocabulary 卡片的 definitions ──
print('=== 4. 非 vocabulary 类语言卡片的 definitions ===')
other_types = cur.execute('''
    SELECT pc.card_type, pc.subject, COUNT(*)
    FROM prebuilt_cards pc 
    JOIN prebuilt_language_cards plc ON pc.id = plc.id
    WHERE pc.card_type != 'vocabulary' AND pc.domain = 'language'
    GROUP BY pc.card_type, pc.subject
    ORDER BY pc.card_type
''').fetchall()
for ct, subj, cnt in other_types:
    empty = cur.execute('''
        SELECT COUNT(*) FROM prebuilt_cards pc 
        JOIN prebuilt_language_cards plc ON pc.id = plc.id
        WHERE pc.card_type = ?1 AND pc.subject = ?2 
        AND (plc.definitions IS NULL OR plc.definitions = '[]')
    ''', [ct, subj]).fetchone()[0]
    print(f'  [{ct:20s}] [{subj:12s}] 总{cnt}  空defs:{empty}')
