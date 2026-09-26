#!/usr/bin/env python3
"""Audit chicn account: conversations, plans, cards, due cards."""
import urllib.request, json, sys

API = "http://127.0.0.1:8080"

def req(method, path, data=None, token=None):
    h = {'Content-Type': 'application/json'}
    if token: h['Authorization'] = f'Bearer {token}'
    d = json.dumps(data).encode() if data else None
    r = urllib.request.Request(f'{API}{path}', data=d, headers=h, method=method)
    return json.loads(urllib.request.urlopen(r, timeout=30).read().decode())

# Login
d = req('POST', '/api/auth/login', {'username': 'chicn1780138167', 'password': 'test123'})
uid, token = d['user_id'], d['token']
print(f'User: {uid}')

# Conversations (via history endpoint)
convs = req('GET', f'/api/history?user_id={uid}', token=token)
print(f'\n=== Conversations ({len(convs)}) ===')
for c in convs:
    print(f'  {c["id"][:8]}... subj={c.get("subject","-")} grade={c.get("grade_band","-")} turns={c.get("turn_count",0)}')

# Plans
plans = req('GET', f'/api/plans?user_id={uid}', token=token)
print(f'\n=== Plans ({len(plans.get("plans",[]))}) ===')
for p in plans.get('plans', []):
    print(f'  domain={p.get("domain","-")} goal={p.get("goal","-")[:50]}')

# Cards by domain
cards = req('GET', f'/api/cards/all?user_id={uid}', token=token)
all_cards = cards.get('cards', [])
print(f'\n=== Cards: {len(all_cards)} total ===')
domains = {}
for c in all_cards:
    d = c.get('domain', '(none)')
    domains[d] = domains.get(d, 0) + 1
for d, cnt in sorted(domains.items()):
    print(f'  domain="{d}": {cnt} cards')

# Sample free-dialogue cards (non-语文)
print(f'\n=== Sample cards NOT in "语文" domain ===')
for c in all_cards:
    if c.get('domain') != '语文':
        print(f'  "{c["front"][:40]:40}" domain={c["domain"]:10} type={c.get("card_type","?")}')

# Due cards
due = req('GET', f'/api/review/due?user_id={uid}', token=token)
print(f'\n=== Due cards: {len(due.get("cards",[]))} ===')
for c in due.get('cards', []):
    print(f'  "{c["front"][:30]:30}" domain={c["domain"]:10} type={c["card_type"]}')
