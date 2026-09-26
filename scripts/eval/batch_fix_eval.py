#!/usr/bin/env python3
"""Evaluate cards: 6 independent API calls per card, each dim sees only its own context."""
import json, sys, time, urllib.request, re
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
sys.stdout.reconfigure(encoding='utf-8')

BATCH_SIZE = 20
# Read API key from .env (robust: handles spaces/quotes)
_env = open('backend/.env', encoding='utf-8').read()
AK = ''
for line in _env.split('\n'):
    if 'DEEPSEEK_API_KEY' in line and '=' in line:
        AK = line.split('=', 1)[1].strip().strip('"').strip("'")
        break
CARD_DIR = Path('data/curriculum/prebuilt/cards')
FILES = [
    (CARD_DIR / 'chinese_reading_primary.json', '小学课文'),
    (CARD_DIR / 'chinese_reading_extended.json', '拓展阅读'),
    (CARD_DIR / 'chinese_reading_missing.json', '补录课文'),
]
EVAL_DIMS = ['全文完整度', '赏析质量', '手法分析', '主旨概括', '易错提示', '整体质量']

# Dimension-specific prompts - each only sees its relevant context
def fmt_field(val, maxc=300):
    """Format card field for prompt: join list items, truncate"""
    if isinstance(val, list):
        txt = '\n'.join(f'- {v}' for v in val)
    else:
        txt = str(val or '')
    return txt[:maxc]

def make_prompt(dim, card):
    n = card.get('front', '?')
    ft = card.get('full_text', '') or ''
    au = fmt_field(card.get('author', ''), 40)
    a = fmt_field(card.get('appreciation', ''), 300)
    t = fmt_field(card.get('technique', ''), 300)
    th = fmt_field(card.get('theme', '') or '', 200)
    e = fmt_field(card.get('common_mistakes', '') or '', 200)
    
    prompts = {
        '全文完整度': (
            '评估卡片【全文完整度】，0-100分。只看原文内容是否完整（有无截断、缺失）。理由限40字，单行。只回JSON。\n\n'
            '卡片: ' + n + '\n作者: ' + au + '\n全文: ' + ft + '\n\n'
            '{"全文完整度":{"s":85,"r":"理由（只看原文是否完整）"}}'
        ),
        '赏析质量': (
            '评估卡片【赏析质量】，0-100分。赏析是否引用原文具体语句，分析是否深入。理由限40字，单行。只回JSON。\n\n'
            '卡片: ' + n + '\n全文: ' + ft + '\n赏析: ' + a + '\n\n'
            '{"赏析质量":{"s":80,"r":"理由"}}'
        ),
        '手法分析': (
            '评估卡片【手法分析】，0-100分。手法识别是否准确，例证是否来自原文。理由限40字，单行。只回JSON。\n\n'
            '卡片: ' + n + '\n全文: ' + ft + '\n手法: ' + t + '\n\n'
            '{"手法分析":{"s":75,"r":"理由"}}'
        ),
        '主旨概括': (
            '评估卡片【主旨概括】，0-100分。主旨是否精准简洁（20字内为佳）。理由限40字，单行。只回JSON。\n\n'
            '卡片: ' + n + '\n主旨: ' + th + '\n\n'
            '{"主旨概括":{"s":90,"r":"理由"}}'
        ),
        '易错提示': (
            '评估卡片【易错提示】，0-100分。易错点是否具体、实用。理由限40字，单行。只回JSON。\n\n'
            '卡片: ' + n + '\n全文: ' + ft + '\n易错: ' + e + '\n\n'
            '{"易错提示":{"s":70,"r":"理由"}}'
        ),
    }
    return prompts.get(dim, '')


def call_api(prompt):
    """Single API call for one dimension, with exponential backoff"""
    delays = [5, 15, 30, 60, 120]  # 5 retries with increasing backoff
    for i, wait in enumerate(delays):
        try:
            p = json.dumps({'model': 'deepseek-v4-flash', 'messages': [{'role': 'user', 'content': prompt}], 'max_tokens': 400, 'temperature': 0.0}).encode()
            req = urllib.request.Request('https://api.deepseek.com/chat/completions', data=p, headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + AK})
            resp = urllib.request.urlopen(req, timeout=300)
            raw = json.loads(resp.read().decode())['choices'][0]['message']['content']
            # Extract JSON
            if raw.startswith('```'):
                idx = raw.find('\n')
                raw = raw[idx+1:] if idx > 0 else raw[3:]
            if raw.endswith('```'):
                idx = raw.rfind('\n')
                raw = raw[:idx] if idx > 0 else raw[:-3]
            try:
                j = json.loads(raw)
            except:
                m = re.search(r'\{.*?\}', raw, re.DOTALL)
                j = json.loads(m.group(0)) if m else None
            if j:
                for dim in EVAL_DIMS:
                    if dim in j:
                        v = j[dim]
                        s = v.get('s', v.get('score', 50))
                        r = str(v.get('r', v.get('reason', '')))[:60]
                        r = re.sub(r'\s+', ' ', r).strip()
                        return {'s': int(s), 'r': r}
            # Got response but couldn't parse — retry with longer wait
            time.sleep(wait)
        except:
            time.sleep(wait)  # exponential backoff
    return None  # failed after all retries


def eval_card(card):
    """Evaluate one card: 6 parallel API calls, one per dimension"""
    card_type = card.get('card_type', '')
    ft_len = len(card.get('full_text', '') or '')
    is_phonetic = (card_type == 'nursery_rhyme')
    is_tiny = (ft_len < 50)  # 超短课文（识字卡）跳过文学维度
    # 拼音卡/超短卡不适用文学维度，全部跳过
    skip_dims = set()
    if is_phonetic or is_tiny:
        skip_dims = {'赏析质量', '手法分析', '主旨概括', '易错提示'}
    
    futures = {}
    results = {}
    
    with ThreadPoolExecutor(max_workers=6) as ex:
        for dim in EVAL_DIMS[:5]:  # Dims 1-5: independent API calls
            if dim in skip_dims:
                results[dim] = {'s': 100, 'r': '拼音卡不适用此维度'}
                continue
            prompt = make_prompt(dim, card)
            futures[ex.submit(call_api, prompt)] = dim
        
        for f in as_completed(futures):
            dim = futures[f]
            r = f.result()
            if r:
                results[dim] = r
            else:
                results[dim] = {'s': 50, 'r': '评估失败'}
    
    # Dim 6: 整体质量 = average of 5 dimensions
    dims_5 = ['全文完整度', '赏析质量', '手法分析', '主旨概括', '易错提示']
    scores = [results.get(d, {'s': 50})['s'] for d in dims_5]
    avg = round(sum(scores) / len(scores))
    results['整体质量'] = {'s': avg, 'r': '维度均值'}
    
    return results


def process_batch(fp, cards):
    """Process a batch of cards, 5 concurrent"""
    d = json.load(open(fp, encoding='utf-8'))
    name_map = {c['front']: c for c in d['cards']}
    
    with ThreadPoolExecutor(max_workers=5) as ex:
        fs = {ex.submit(eval_card, c): c for c in cards}
        for f in as_completed(fs):
            c_in = fs[f]
            target = name_map.get(c_in.get('front', ''))
            if target is None:
                continue
            results = f.result()
            target['_eval'] = {dim: results[dim]['s'] for dim in EVAL_DIMS}
            target['_eval_r'] = {dim: results[dim]['r'] for dim in EVAL_DIMS}
    
    fp.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding='utf-8')
    return len(cards)


if __name__ == '__main__':
    # Collect all cards missing _eval
    all_missing = []
    for fp, label in FILES:
        d = json.load(open(fp, encoding='utf-8'))
        missing = [c for c in d['cards'] if '_eval' not in c]
        if missing:
            all_missing.append((fp, missing))
            print(f'{label}: {len(missing)} missing _eval')
        else:
            print(f'{label}: all ok')
    
    if not all_missing:
        print('No missing _eval!')
        sys.exit(0)
    
    total = sum(len(m) for _, m in all_missing)
    print(f'Total: {total} cards need evaluation')
    
    done = 0
    for fp, missing_cards in all_missing:
        for start in range(0, len(missing_cards), BATCH_SIZE):
            batch = missing_cards[start:start + BATCH_SIZE]
            n = process_batch(fp, batch)
            done += n
            print(f'  Batch {start // BATCH_SIZE + 1}: {n} cards [{done}/{total}]')
    
    print(f'All done! {done} cards evaluated (6 API calls per card).')
    
    # 二次重试阶段：专门重试评估失败的卡片
    retry_count = 0
    for fp, label in FILES:
        d = json.load(open(fp, encoding='utf-8'))
        failed = []
        for c in d['cards']:
            e = c.get('_eval', {})
            for dim in EVAL_DIMS:
                if '_eval_r' in c and c['_eval_r'].get(dim, '') == '评估失败':
                    failed.append(c)
                    break
        if failed:
            failed_unique = list({id(c): c for c in failed}.values())
            print(f'\n[重试] {label}: {len(failed_unique)} 张评估失败，重新评估...')
            retry_done = 0
            for start in range(0, len(failed_unique), BATCH_SIZE):
                batch = failed_unique[start:start + BATCH_SIZE]
                n = process_batch(fp, batch)
                retry_done += n
                retry_count += n
            print(f'  {retry_done}/{len(failed_unique)} 重试成功')
    
    if retry_count:
        print(f'\n重试完成: 共重评 {retry_count} 张')
    else:
        print('无需要重试的卡')
