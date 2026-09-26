#!/usr/bin/env python3
"""
LLM 补全缺失的 card 内容：
- Chinese: missing pinyin (3张) + definitions (31张)
- English: missing phonetic (114张) + definitions (748张)
- Russian: missing pronunciation (98张)
"""
import json, os, sys, time, re

V4 = r'E:/CoEvo/data/curriculum/v4'
ENV = r'E:/CoEvo/backend/.env'

# 加载 API key
API_KEY = ''
if os.path.exists(ENV):
    with open(ENV, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os.environ[k] = v
API_KEY = os.environ.get('DEEPSEEK_API_KEY', '')

if not API_KEY:
    print('❌ DEEPSEEK_API_KEY 未设置')
    sys.exit(1)

def llm_call(prompt, model='deepseek-chat'):
    import urllib.request
    data = json.dumps({
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.1,
        'max_tokens': 2048,
    }).encode()
    req = urllib.request.Request(
        'https://api.deepseek.com/chat/completions',
        data=data,
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {API_KEY}',
        }
    )
    try:
        resp = urllib.request.urlopen(req, timeout=60)
        result = json.loads(resp.read())
        return result['choices'][0]['message']['content']
    except Exception as e:
        print(f'  LLM 调用失败: {e}')
        return None

# 加载数据
with open(f'{V4}/cards/language/prebuilt_cards.json', 'r', encoding='utf-8') as f:
    pc = json.load(f)
with open(f'{V4}/cards/language/prebuilt_language_cards.json', 'r', encoding='utf-8') as f:
    lang = json.load(f)
lang_map = {c['id']: c for c in lang}

print('═══ LLM 补全缺失内容 ═══\n')

# ── 1. Chinese: 缺 pinyin ──
print('--- 1. 中文补拼音 ---')
zh_missing_pinyin = []
for c in pc:
    if c.get('subject') != 'chinese':
        continue
    entry = lang_map.get(c['id'])
    if entry and not entry.get('pronunciation', '').strip():
        zh_missing_pinyin.append(c)
print(f'  缺拼音: {len(zh_missing_pinyin)} 张')
for card in zh_missing_pinyin:
    front = card['front']
    prompt = f'请为汉字"{front}"标注拼音（仅返回拼音，不要其他文字）'
    result = llm_call(prompt)
    if result:
        pinyin = result.strip().split('\n')[0].strip()
        entry = lang_map[card['id']]
        entry['pronunciation'] = pinyin
        print(f'  {front}: {pinyin}')
    time.sleep(0.5)

# ── 2. Chinese: 缺 definitions ──
print('\n--- 2. 中文补释义 ---')
zh_missing_defs = []
for c in pc:
    if c.get('subject') != 'chinese':
        continue
    entry = lang_map.get(c['id'])
    if entry and (not entry.get('definitions') or entry['definitions'] == '[]'):
        zh_missing_defs.append((c, entry))
print(f'  缺释义: {len(zh_missing_defs)} 张')
for card, entry in zh_missing_defs:
    front = card['front']
    pinyin = entry.get('pronunciation', '')
    existing = entry.get('related_phrases', '')
    prompt = f'''汉字"{front}"{f'拼音"{pinyin}"' if pinyin else ''}，{f'常用词组"{existing}"' if existing else ''}。
请以 JSON 数组格式返回这个字的释义，每个条目包含：
- pos: 词性（如"[名]""[动]"等）
- meaning: 释义
- example: 例词/例句（至少一个）
仅返回 JSON 数组，不要其他文字。'''
    result = llm_call(prompt)
    if result:
        try:
            # Extract JSON from result
            json_match = re.search(r'\[.*\]', result, re.DOTALL)
            if json_match:
                defs = json.loads(json_match.group())
                entry['definitions'] = json.dumps(defs, ensure_ascii=False)
                print(f'  {front}: 生成 {len(defs)} 条释义')
        except:
            print(f'  {front}: JSON 解析失败')
    time.sleep(0.5)

# ── 3. English: 缺 phonetic ──
print('\n--- 3. 英文补音标 ---')
en_missing_phonetic = []
for c in pc:
    if c.get('subject') != 'english' or c.get('card_type') != 'vocabulary':
        continue
    entry = lang_map.get(c['id'])
    if entry and not entry.get('pronunciation', '').strip():
        en_missing_phonetic.append((c, entry))
print(f'  缺音标: {len(en_missing_phonetic)} 张')
for card, entry in en_missing_phonetic:
    front = card['front']
    prompt = f'请为英文单词"{front}"标注国际音标（IPA）。仅返回音标，不要其他文字。'
    result = llm_call(prompt)
    if result:
        phonetic = result.strip().split('\n')[0].strip()
        entry['pronunciation'] = phonetic
        print(f'  {front}: {phonetic}')
    time.sleep(0.3)

# ── 4. Russian: 缺 pronunciation ──
print('\n--- 4. 俄文补读音 ---')
ru_missing = []
for c in pc:
    if c.get('subject') != 'russian':
        continue
    entry = lang_map.get(c['id'])
    if entry and not entry.get('pronunciation', '').strip():
        ru_missing.append((c, entry))
print(f'  缺读音: {len(ru_missing)} 张')
for card, entry in ru_missing:
    front = card['front']
    prompt = f'请为俄语单词"{front}"标注读音（用俄语字母注音或国际音标）。仅返回读音，不要其他文字。'
    result = llm_call(prompt)
    if result:
        pron = result.strip().split('\n')[0].strip()
        entry['pronunciation'] = pron
        print(f'  {front}: {pron}')
    time.sleep(0.5)

# 保存
json.dump(lang, open(f'{V4}/cards/language/prebuilt_language_cards.json', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
print(f'\n✅ 已保存更新')
