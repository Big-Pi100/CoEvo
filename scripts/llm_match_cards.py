#!/usr/bin/env python3
"""
LLM 辅助卡片匹配：逐科逐 task 匹配概念卡和词卡

对每个 task 发送 LLM 请求，让它从该科所有卡片中选出匹配的。
并行执行（最多 500 并发），结果直接更新原始 plan JSON 的 gold_cr_ids。
"""

import json, os, glob, concurrent.futures, sys, time
import urllib.request, urllib.error

# 从 backend/.env 加载环境变量
_env_path = os.path.join(os.path.dirname(__file__), '..', 'backend', '.env')
if os.path.exists(_env_path):
    with open(_env_path, encoding='utf-8') as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith('#'):
                _k, _v = _line.split('=', 1)
                os.environ[_k] = _v

BASE = 'data/curriculum/prebuilt'
OUT = 'data/curriculum/v3'

# DeepSeek API 配置
API_URL = "https://api.deepseek.com/chat/completions"
API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
if not API_KEY:
    print("❌ 请设置 DEEPSEEK_API_KEY 环境变量")
    sys.exit(1)

def get_cards_for_subject(subject_key):
    """获取某科目的所有概念卡（有 gold_cr_ids 的卡片才是可匹配的）"""
    cards_data = []
    for fn in sorted(glob.glob(os.path.join(BASE, 'cards', f'{subject_key}*.json'))):
        with open(fn, encoding='utf-8') as f:
            data = json.load(f)
        for c in data.get('cards', []):
            if c.get('card_type') not in ('concept', 'timeline', 'rule', 'relationship', 'skill'):
                continue  # 只匹配知识类卡片
            back_preview = c.get('back', '')[:80].replace('\n', ' ')
            cards_data.append({
                'id': c['id'],
                'front': c['front'],
                'back_preview': back_preview,
                'card_type': c.get('card_type', ''),
                'gold_cr_ids': c.get('gold_cr_ids', []),
            })
    return cards_data

def get_task_context(stage, task):
    """获取 task 的完整上下文"""
    parts = [task['name']]
    if task.get('focus'):
        parts.append(task['focus'])
    if stage.get('name'):
        parts.append(f"（所属阶段: {stage['name']}）")
    return ' '.join(parts)

def match_task(llm_config):
    """单次 LLM 调用：匹配一个 task 到卡片"""
    task_name, task_context, subject, all_cards = llm_config
    
    # 只取 concept 类卡片（含 front + back_preview）
    card_list = '\n'.join([
        f'  [{i}] {c["front"]} — {c["back_preview"]}'
        for i, c in enumerate(all_cards) if c['card_type'] == 'concept'
    ])
    
    # 也列出非 concept 但可能有用的
    extra_list = '\n'.join([
        f'  [{i}] {c["front"]} ({c["card_type"]})'
        for i, c in enumerate(all_cards) if c['card_type'] != 'concept'
    ])
    
    prompt = f"""你是课程设计专家。请判断学习任务与概念卡片的匹配关系。

学习任务: {task_context}
科目: {subject}

概念卡片列表：
{card_list or '(无概念卡)'}

其他可用卡片：
{extra_list or '(无)'}

请返回与此学习任务最直接相关的卡片序号（json 数组格式）。
匹配原则：
- 任务的教学目标与卡片的核心内容必须直接相关
- 宁缺毋滥：不确定就不匹配
- 只返回直接对应的卡片

返回格式: [3, 7, 15]  或  []（无匹配）
"""
    
    try:
        payload = json.dumps({
            "model": "deepseek-chat",
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.1,
            "max_tokens": 500,
        }).encode('utf-8')
        
        req = urllib.request.Request(API_URL, data=payload, headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json"
        })
        
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode('utf-8'))
        
        content = result['choices'][0]['message']['content'].strip()
        
        # 解析 JSON 数组
        # 处理可能的 markdown 代码块
        if '```' in content:
            content = content.split('```')[1]
            if content.startswith('json'):
                content = content[4:]
        content = content.strip()
        
        import ast
        indices = ast.literal_eval(content)
        if not isinstance(indices, list):
            return (task_name, None, f"不是数组: {content[:100]}")
        
        matched_ids = [all_cards[i]['id'] for i in indices if 0 <= i < len(all_cards)]
        return (task_name, matched_ids, None)
        
    except Exception as e:
        return (task_name, None, str(e))

def process_subject(subject_key):
    """处理一个科目：找出所有空 task 并并行匹配"""
    plan_fn = os.path.join(BASE, 'plans', f'{subject_key}.json')
    if not os.path.exists(plan_fn):
        return
    
    with open(plan_fn, encoding='utf-8') as f:
        plan = json.load(f)
    
    # 找出所有 gold_cr_ids 为空的 task（含原数据就有的空 + 需要 LLM 匹配的）
    # 同时也收集已有匹配的 task 用于校验
    empty_pairs = []  # (stage, task)
    existing_pairs = []  # (stage, task)
    for stage in plan.get('stages', []):
        for task in stage.get('tasks', []):
            ctx = get_task_context(stage, task)
            if not task.get('gold_cr_ids'):
                empty_pairs.append((stage, task, ctx))
            else:
                existing_pairs.append((stage, task, ctx))
    
    all_cards = get_cards_for_subject(subject_key)
    concept_cards = [c for c in all_cards if c['card_type'] == 'concept']
    
    print(f'  {subject_key}: {len(empty_pairs)} 个空 task, {len(existing_pairs)} 个已有匹配, {len(concept_cards)} 张概念卡')
    
    if not empty_pairs:
        print(f'  {subject_key}: 无需匹配 ✅')
        return
    
    # 并行调用 LLM
    configs = [(t['name'], ctx, subject_key, all_cards) for s, t, ctx in empty_pairs]
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=100) as executor:
        results = list(executor.map(match_task, configs))
    
    # 更新 plan
    matched_count = 0
    fail_count = 0
    for (s, t, ctx), (tname, matched_ids, error) in zip(empty_pairs, results):
        if error:
            fail_count += 1
            continue
        
        if matched_ids:
            matched_count += 1
            # 更新 gold_cr_ids
            task['gold_cr_ids'] = matched_ids
    
    # 写回
    with open(plan_fn, 'w', encoding='utf-8') as f:
        json.dump(plan, f, ensure_ascii=False, indent=2)
    
    print(f'  {subject_key}: 匹配 {matched_count}, 失败 {fail_count}')
    if fail_count > 0:
        for (s, t, ctx), (tname, matched_ids, error) in zip(empty_pairs, results):
            if error:
                print(f'    ❌ {t["name"]}: {error}')

def main():
    subjects = ['biology', 'chemistry', 'english', 'geography', 'history', 'it',
                'japanese', 'math', 'pe', 'physics', 'politics', 'russian', 'science']
    
    print(f'=== LLM 卡片匹配开始（{len(subjects)} 个科目）===\n')
    
    for subj in subjects:
        process_subject(subj)
    
    print('\n✅ 全部完成！重新运行 migrate_v3.py 以应用新的匹配结果。')

if __name__ == '__main__':
    main()
