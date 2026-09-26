import json, os

V4 = r'E:/CoEvo/data/curriculum/v4'

with open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8') as f:
    lang_cards = json.load(f)

for c in lang_cards:
    if 'definition' in c:
        print('典型污染卡:')
        print(json.dumps(c, indent=2, ensure_ascii=False)[:500])
        print()
        break

# Check science sub-table for the same card
sci_all = json.load(open(f'{V4}/cards/science/prebuilt_science_cards.json', 'r', encoding='utf-8'))
sci_map = {c['id']: c for c in sci_all}

cid = lang_cards[0]['id']
if cid in sci_map:
    print(f'卡 {cid[:20]}... 也在 science 域')
else:
    print(f'卡 {cid[:20]}... 不在 science 域')

# Count cross-domain cards
both = 0
for c in lang_cards:
    if 'definition' in c and c['id'] in sci_map:
        both += 1
polluted = [c for c in lang_cards if 'definition' in c]
print(f'污染卡: {len(polluted)}')
print(f'其中也在 science 域的: {both}')

# Check the source of contamination
print('\n=== 检查 science 子表语言卡片 ===')
lang_pc = {c['id']: c for c in json.load(open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8'))}
for c in sci_all:
    if c['id'] in lang_pc:
        pc = lang_pc[c['id']]
        print(f'{pc.get("front","?")[:30]:30s} domain={pc.get("domain","")} card_type={pc.get("card_type","")}')
        break
print(f'science 子表中属于 language 域的: {sum(1 for c in sci_all if c["id"] in lang_pc)}')
