#!/usr/bin/env python3
"""
YY/NN 卡片匹配：每 task-card 对问一次 LLM，YES/NO 判定。

对每个空 task 与每张概念卡组成 (task, card) 对，
问 LLM 这张卡是否属于这个任务。YES 就绑定，NO 就跳过。

并行 500 并发，全部跑完约 1-2 分钟。
"""

import json, os, glob, concurrent.futures, sys
import urllib.request, urllib.error

# 加载 .env
_env_path = os.path.join(os.path.dirname(__file__), '..', 'backend', '.env')
if os.path.exists(_env_path):
    with open(_env_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os.environ[k] = v

API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
if not API_KEY:
    print("❌ DEEPSEEK_API_KEY 未设置")
    sys.exit(1)

BASE = 'data/curriculum/prebuilt'

def ask_yes_no(task_name, card_front, subject):
    """问 LLM：这张卡是否属于这个任务？返回 YES/NO"""
    prompt = f"""Task: "{task_name}"
Card: "{card_front}"
Subject: {subject}

Is this card relevant to this task? Answer ONLY YES or NO."""
    
    payload = json.dumps({
        "model": "deepseek-chat",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": 5,
    }).encode()
    
    try:
        req = urllib.request.Request(
            "https://api.deepseek.com/chat/completions",
            data=payload,
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json"
            }
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
            answer = result['choices'][0]['message']['content'].strip().upper()
            return answer == "YES"
    except Exception as e:
        return None  # 失败，重试

def process_subject(subject_key):
    plan_fn = os.path.join(BASE, 'plans', f'{subject_key}.json')
    if not os.path.exists(plan_fn):
        return
    
    with open(plan_fn) as f:
        plan = json.load(f)
    
    # 找空 task
    empty_tasks = []
    for stage in plan['stages']:
        for task in stage.get('tasks', []):
            if not task.get('gold_cr_ids'):
                empty_tasks.append((stage, task))
    
    if not empty_tasks:
        return
    
    # 加载该科所有概念卡
    all_cards = []
    for fn in sorted(glob.glob(os.path.join(BASE, 'cards', f'{subject_key}*.json'))):
        with open(fn) as f:
            for c in json.load(f).get('cards', []):
                if c.get('card_type') == 'concept':
                    all_cards.append(c)
    
    if not all_cards:
        return
    
    # 构造所有 (task, card) 对
    pairs = [(stage, task, card) for stage, task in empty_tasks for card in all_cards]
    print(f'  {subject_key}: {len(empty_tasks)} 空 task × {len(all_cards)} 卡 = {len(pairs)} 对')
    
    # 并行调用 LLM
    def match_one(p):
        stage, task, card = p
        result = ask_yes_no(task['name'], card['front'], subject_key)
        return (task['name'], card['id'], result)
    
    matched = 0
    failed = 0
    # 分批执行（每批 500 对，避免 API 限流）
    batch_size = 500
    for batch_start in range(0, len(pairs), batch_size):
        batch = pairs[batch_start:batch_start + batch_size]
        with concurrent.futures.ThreadPoolExecutor(max_workers=batch_size) as ex:
            for tname, cid, result in ex.map(match_one, batch):
                if result is None:
                    failed += 1
                elif result:
                    matched += 1
                    for stage in plan['stages']:
                        for task in stage.get('tasks', []):
                            if task['name'] == tname:
                                if 'gold_cr_ids' not in task or not task['gold_cr_ids']:
                                    task['gold_cr_ids'] = []
                                task['gold_cr_ids'].append(cid)
                                break
    
    # 最终写回
    with open(plan_fn, 'w') as f:
        json.dump(plan, f, ensure_ascii=False, indent=2)
    
    still_empty = sum(1 for s in plan['stages'] for t in s.get('tasks',[]) if not t.get('gold_cr_ids'))
    print(f'  → {matched} YES, {failed} failed, 仍空 {still_empty}/{len(empty_tasks)}')
    
    still_empty = sum(1 for s in plan['stages'] for t in s.get('tasks',[]) if not t.get('gold_cr_ids'))
    print(f'  → 匹配 {matched} 对, 失败 {failed}, 仍空 {still_empty} task')

def main():
    subjects = ['biology', 'chemistry', 'english', 'geography', 'history', 'it',
                'japanese', 'math', 'pe', 'physics', 'politics', 'russian', 'science']
    
    for subj in subjects:
        process_subject(subj)

if __name__ == '__main__':
    main()
