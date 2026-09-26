#!/usr/bin/env python3
"""Fix remaining cards missing _eval"""
import json, sys, time, urllib.request, re
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
sys.stdout.reconfigure(encoding='utf-8')

AK = open('backend/.env', 'r').read().strip().split('DEEPSEEK_API_KEY=')[1].split('\n')[0].strip().strip('"').strip("'")
EVAL_DIMS = ['全文完整度', '赏析质量', '手法分析', '主旨概括', '易错提示', '整体质量']

def llm_eval(card):
    n = card['front']
    ft = (card.get('full_text', '') or '')[:500]
    a = card.get('appreciation', '')
    tc = card.get('technique', '')
    th = card.get('theme', '')
    e = card.get('common_mistakes', '')
    
    prompt = (
        '评估学习卡片质量，逐项0-100分。理由限制40字内，只用一行，禁止换行。'
        '只回JSON，禁用markdown。\n\n'
        '卡片: ' + n + '\n全文: ' + ft + '\n赏析: ' + str(a)[:150]
        + '\n手法: ' + str(tc)[:150] + '\n主旨: ' + str(th)[:80]
        + '\n易错: ' + str(e)[:80] + '\n\n'
        '{"全文完整度":{"s":85,"r":"理由"},"赏析质量":{"s":80,"r":"理由"},'
        '"手法分析":{"s":75,"r":"理由"},"主旨概括":{"s":90,"r":"理由"},'
        '"易错提示":{"s":70,"r":"理由"},"整体质量":{"s":82,"r":"理由"}}'
    )
    
    for _ in range(3):
        try:
            p = json.dumps({
                'model': 'deepseek-v4-flash',
                'messages': [{'role': 'user', 'content': prompt}],
                'max_tokens': 700,
                'temperature': 0.0
            }).encode()
            req = urllib.request.Request(
                'https://api.deepseek.com/chat/completions',
                data=p,
                headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {AK}'}
            )
            resp = urllib.request.urlopen(req, timeout=120)
            raw = json.loads(resp.read().decode())['choices'][0]['message']['content']
            
            # Remove code fences
            if raw.startswith('```'):
                idx = raw.find('\n')
                if idx > 0:
                    raw = raw[idx+1:]
                else:
                    raw = raw[3:]
            if raw.endswith('```'):
                idx = raw.rfind('\n')
                if idx > 0:
                    raw = raw[:idx]
                else:
                    raw = raw[:-3]
            
            try:
                j = json.loads(raw)
            except json.JSONDecodeError:
                m = re.search(r'\{.*\}', raw, re.DOTALL)
                j = json.loads(m.group(0)) if m else None
            
            if j:
                res = {}
                for d in EVAL_DIMS:
                    v = j.get(d, {})
                    if isinstance(v, dict):
                        s = v.get('s', v.get('score', 50))
                        r_text = v.get('r', v.get('reason', ''))
                    else:
                        s = 50
                        r_text = ''
                    r_text = re.sub(r'\s+', ' ', str(r_text)).strip()[:60]
                    res[d] = {'s': int(s), 'r': r_text}
                return res
        except Exception as exc:
            time.sleep(3)
    return {d: {'s': 50, 'r': '超时'} for d in EVAL_DIMS}


def process_file(fp, label):
    d = json.load(open(fp, encoding='utf-8'))
    cs = d['cards']
    missing = [c for c in cs if '_eval' not in c]
    print(f'{label}: {len(missing)} cards missing _eval')
    
    for c in missing:
        r = llm_eval(c)
        c['_eval'] = {d: r[d]['s'] for d in EVAL_DIMS}
        c['_eval_r'] = {d: r[d]['r'] for d in EVAL_DIMS}
        ft = c.get('full_text', '') or ''
        l = len(ft)
        c['_eval']['全文完整度'] = 100 if l >= 100 else (85 if l >= 50 else 50)
        print(f'  {c["front"]}: overall={c["_eval"]["整体质量"]}')
    
    fp.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'  {label} saved')


if __name__ == '__main__':
    for fp, label in [
        (Path(r'E:\CoEvo\docs\curriculum\prebuilt\cards\chinese_reading_primary.json'), '小学课文'),
        (Path(r'E:\CoEvo\docs\curriculum\prebuilt\cards\chinese_reading_extended.json'), '拓展阅读'),
        (Path(r'E:\CoEvo\docs\curriculum\prebuilt\cards\chinese_reading_missing.json'), '补录课文'),
    ]:
        process_file(fp, label)
    print('All done!')
