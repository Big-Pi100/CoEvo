#!/usr/bin/env python3
"""Verify build_plan_context outputs task card fronts."""
import urllib.request, json

API = "http://127.0.0.1:8080"

def req(method, path, data=None, token=None):
    h = {'Content-Type': 'application/json'}
    if token: h['Authorization'] = f'Bearer {token}'
    d = json.dumps(data).encode() if data else None
    r = urllib.request.Request(f'{API}{path}', data=d, headers=h, method=method)
    return json.loads(urllib.request.urlopen(r, timeout=30).read().decode())

d = req('POST', '/api/auth/login', {'username': 'chicn1780138167', 'password': 'test123'})
uid, token = d['user_id'], d['token']

plans = req('GET', f'/api/plans?user_id={uid}', token=token)
for p in plans.get('plans', []):
    domain = p.get('domain', '-')
    goal = p.get('goal', '-')[:40]
    conv = p.get('conversation_id', '')[:12]
    print(f'domain={domain} goal={goal} conv={conv}')
    if '数学' in goal and 'g10' in goal:
        cid = p['conversation_id']
        print(f'\n=== Found math g10-12: {cid} ===')
        p2 = req('GET', f'/api/plans?conversation_id={cid}', token=token)
        plan_obj = p2.get('plans', [{}])[0].get('plan', {})
        stages = plan_obj.get('stages', [])
        for s in stages[:1]:
            tasks = s.get('tasks', [])
            for t in tasks[:3]:
                tname = t.get('name', '?')
                tstatus = t.get('status', '?')
                gold = t.get('gold_cr_ids', [])
                vocab = t.get('vocab_card_ids', [])
                reading = t.get('reading_card_id', '')
                print(f'  {tname} ({tstatus}) gold={gold} vocab={vocab} reading={reading}')
        break
