"""全科目数据质量审查"""
import json, os, sqlite3
from collections import Counter

V4 = r'E:/CoEvo/data/curriculum/v4'
DB = r'E:/CoEvo/backend/data/coevo.db'

conn = sqlite3.connect(DB)
cur = conn.cursor()

print('═══ 跨域全科目审查 ═══')
print()

# ── 1. 每个 domain+subject 的卡片统计 ──
print('=== 1. 各域/科目卡片统计 ===')
for domain in ['science', 'language', 'literature', 'humanities']:
    subjs = cur.execute('''
        SELECT subject, COUNT(*) FROM prebuilt_cards 
        WHERE domain = ?1 GROUP BY subject ORDER BY subject
    ''', [domain]).fetchall()
    print(f'[{domain}]')
    for s, cnt in subjs:
        print(f'    {s:12s}: {cnt}')
print()

# ── 2. Science 子表字段完整性 ──
print('=== 2. Science 子表字段完整性 ===')
sci_fields = ['definition', 'key_elements', 'applications', 'related_concepts', 'formula', 'graph', 'source']
sci_total = cur.execute('SELECT COUNT(*) FROM prebuilt_science_cards').fetchone()[0]
print(f'总卡: {sci_total}')
for field in sci_fields:
    filled = cur.execute(f'SELECT COUNT(*) FROM prebuilt_science_cards WHERE {field} IS NOT NULL AND {field} != ""').fetchone()[0]
    print(f'  {field:20s}: {filled}/{sci_total} ({filled*100//sci_total}%)')
print()

# ── 3. Humanities 子表字段完整性 ──
print('=== 3. Humanities 子表字段完整性 ===')
hum_fields = ['node_type', 'body', 'period', 'region']
hum_total = cur.execute('SELECT COUNT(*) FROM prebuilt_humanities_cards').fetchone()[0]
print(f'总卡: {hum_total}')
for field in hum_fields:
    filled = cur.execute(f'SELECT COUNT(*) FROM prebuilt_humanities_cards WHERE {field} IS NOT NULL AND {field} != ""').fetchone()[0]
    pct = filled * 100 // hum_total if hum_total else 0
    print(f'  {field:20s}: {filled}/{hum_total} ({pct}%)')
print()

# ── 4. Literature 子表字段完整性 ──
print('=== 4. Literature 子表字段完整性 ===')
lit_fields = ['full_text', 'translation', 'author', 'genre']
lit_total = cur.execute('SELECT COUNT(*) FROM prebuilt_literature_cards').fetchone()[0]
print(f'总卡: {lit_total}')
for field in lit_fields:
    filled = cur.execute(f'SELECT COUNT(*) FROM prebuilt_literature_cards WHERE {field} IS NOT NULL AND {field} != ""').fetchone()[0]
    pct = filled * 100 // lit_total if lit_total else 0
    print(f'  {field:20s}: {filled}/{lit_total} ({pct}%)')
print()

# ── 5. 跨域污染检查（所有子表）──
print('=== 5. 跨域污染（多余字段）===')
schemas = {
    'science': {'id', 'definition', 'key_elements', 'applications', 'related_concepts', 'formula', 'graph', 'source'},
    'language': {'id', 'pronunciation', 'pos', 'definitions', 'related_phrases', 'structure_meta', 'level'},
    'literature': {'id', 'full_text', 'translation', 'author', 'genre'},
    'humanities': {'id', 'node_type', 'body', 'period', 'region'},
}
for domain, expected in schemas.items():
    path = os.path.join(V4, 'cards', domain, f'prebuilt_{domain}_cards.json')
    with open(path, 'r', encoding='utf-8') as f:
        cards = json.load(f)
    bad = sum(1 for c in cards if set(c.keys()) - expected)
    print(f'  [{domain}] {bad}/{len(cards)} 有多余字段')
print()

# ── 6. 按 card_type 检查定义完整性 ──
print('=== 6. card_type 维度检查 ===')
types = cur.execute('''
    SELECT card_type, domain, COUNT(*) FROM prebuilt_cards 
    GROUP BY card_type, domain ORDER BY card_type, domain
''').fetchall()
for ct, domain, cnt in types:
    print(f'  {ct:20s} [{domain:12s}] {cnt} 张')
print()

# ── 7. 各 subject 缺失 definitions/body/full_text 明细 ──
print('=== 7. 内容字段空值科目明细 ===')
# Science: empty definition
sci_empty = cur.execute('''
    SELECT pc.subject, COUNT(*) FROM prebuilt_cards pc
    JOIN prebuilt_science_cards psc ON pc.id = psc.id
    WHERE psc.definition IS NULL OR psc.definition = ''
    GROUP BY pc.subject
''').fetchall()
print('Science 空 definition:')
for s, c in sci_empty: print(f'  {s:12s}: {c}')

# Humanities: empty body
hum_empty = cur.execute('''
    SELECT pc.subject, COUNT(*) FROM prebuilt_cards pc
    JOIN prebuilt_humanities_cards phc ON pc.id = phc.id
    WHERE phc.body IS NULL OR phc.body = ''
    GROUP BY pc.subject
''').fetchall()
print('Humanities 空 body:')
for s, c in hum_empty: print(f'  {s:12s}: {c}')

# Literature: empty full_text
lit_empty = cur.execute('''
    SELECT pc.subject, COUNT(*) FROM prebuilt_cards pc
    JOIN prebuilt_literature_cards plc ON pc.id = plc.id
    WHERE plc.full_text IS NULL OR plc.full_text = ''
    GROUP BY pc.subject
''').fetchall()
print('Literature 空 full_text:')
for s, c in lit_empty: print(f'  {s:12s}: {c}')
print()

# ── 8. 检查 science 卡 formula/graph 覆盖率 ──
print('=== 8. Science 公式/图表覆盖率 ===')
for subj in ['physics', 'math', 'chemistry', 'biology', 'geography', 'it', 'pe', 'science']:
    row = cur.execute('''
        SELECT COUNT(*), 
               SUM(CASE WHEN formula != '' THEN 1 ELSE 0 END),
               SUM(CASE WHEN graph != '' THEN 1 ELSE 0 END)
        FROM prebuilt_science_cards psc JOIN prebuilt_cards pc ON psc.id = pc.id
        WHERE pc.subject = ?1
    ''', [subj]).fetchone()
    total, formulas, graphs = row
    print(f'  {subj:12s}: {total} 张, formula={formulas}, graph={graphs}')
print()

# ── 9. 检查 science 卡 source/related_concepts/applications ──
print('=== 9. Science 教学辅助字段覆盖率 ===')
for subj in ['physics', 'math', 'chemistry', 'biology', 'geography']:
    row = cur.execute('''
        SELECT COUNT(*),
               SUM(CASE WHEN source != '' THEN 1 ELSE 0 END),
               SUM(CASE WHEN related_concepts != '' THEN 1 ELSE 0 END),
               SUM(CASE WHEN applications != '' THEN 1 ELSE 0 END),
               SUM(CASE WHEN key_elements != '' THEN 1 ELSE 0 END)
        FROM prebuilt_science_cards psc JOIN prebuilt_cards pc ON psc.id = pc.id
        WHERE pc.subject = ?1
    ''', [subj]).fetchone()
    total, src, concepts, apps, keys = row
    print(f'  {subj:12s}: source={src}/{total}, concepts={concepts}/{total}, apps={apps}/{total}, elements={keys}/{total}')
print()

# ── 10. 最终结论 ──
print('=== 10. 审查结论 ===')
total_cards = cur.execute('SELECT COUNT(*) FROM prebuilt_cards').fetchone()[0]
total_sub_tables = sum([
    cur.execute(f'SELECT COUNT(*) FROM prebuilt_{d}_cards').fetchone()[0] 
    for d in ['science', 'language', 'literature', 'humanities']
])
print(f'总预置卡: {total_cards}')
print(f'子表条目合计: {total_sub_tables}')
print(f'差额: {total_cards - total_sub_tables}')
