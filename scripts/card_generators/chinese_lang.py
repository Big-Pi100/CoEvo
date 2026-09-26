"""语文生成器 — chinese

每 task:
  按 task name 关键词路由：
    "识字"/"拼音"/"写字" → 字符卡（从旧卡捞字表）
    "古诗"/"文言"/"传统语言" → 古诗文卡（LLM）
    "阅读" → 阅读策略卡
    "写作" → 写作模版卡
    "口语"/"交流" → 口语卡
    "探究"/"实践" → 活动卡
  fallback → 概念卡
"""
import json, urllib.request, time
import os
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, load_old_cards, format_cr_id)

API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")  # 2026-09-26 移除硬编码密钥

LLM_CACHE = {}

def _llm_generate_poem(task_name):
    """调用 LLM 生成古诗文卡片内容"""
    if task_name in LLM_CACHE:
        return LLM_CACHE[task_name]

    prompt = f"""你是一位语文教师。请为以下学习任务生成一张古诗文卡片。

任务名称: {task_name}

请按以下格式输出：
作品名称: （古诗文的标题）
作者: 
原文: （全文）
重点注释: （关键词语解释）
译文: （白话文翻译）
赏析要点: （鉴赏重点）

使用简体中文。只输出卡片内容，不要额外解释。"""

    data = json.dumps({
        "model": "deepseek-v4-flash",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 1000,
        "temperature": 0.3,
    }).encode()

    req = urllib.request.Request(
        "https://api.deepseek.com/chat/completions",
        data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {API_KEY}"}
    )

    for attempt in range(3):
        try:
            resp = urllib.request.urlopen(req, timeout=120)
            result = json.loads(resp.read().decode())["choices"][0]["message"]["content"]
            LLM_CACHE[task_name] = result
            return result
        except Exception as e:
            if attempt < 2:
                time.sleep(3)
    return "（生成失败）"

def chinese_generator(subject, level):
    gold_crs, domain = load_gold(subject, level)
    plan = load_plan(subject, level)
    if not gold_crs:
        return 0, 0, [], "no gold data"

    # 加载旧卡（字符卡，字表等）
    old_cards = load_old_cards(subject, level)
    char_cards = [c for c in old_cards if c.get("card_type") == "character"]

    cards = []
    card_idx = 0
    missing_crs = []

    if plan:
        for stage in plan.get("stages", []):
            for task in stage.get("tasks", []):
                task_name = task.get("name", "")
                task_origin = task.get("origin", "extracted")

                # 判断 task 类型
                task_type = "fallback"
                if "识字" in task_name or "拼音" in task_name or "写字" in task_name:
                    task_type = "character"
                elif "古诗" in task_name or "文言" in task_name or "传统语言" in task_name or "背诵" in task_name or "积累" in task_name:
                    task_type = "poem"
                elif "阅读" in task_name:
                    task_type = "reading"
                elif "写作" in task_name:
                    task_type = "writing"
                elif "口语" in task_name or "交流" in task_name or "交际" in task_name or "讲述" in task_name:
                    task_type = "speaking"
                elif "探究" in task_name or "实践" in task_name or "综合" in task_name:
                    task_type = "activity"

                # 概念卡（从 gold CR） — 已禁用：课标 CR 生成的 concept 卡质量差
                # for cr_id in task.get("gold_cr_ids", []):
                #     cr_num = parse_cr_id(cr_id)
                #     if cr_num is None:
                #         missing_crs.append(str(cr_id))
                #         continue
                #     cr_index = cr_num - 1
                #     if cr_index < 0 or cr_index >= len(gold_crs):
                #         missing_crs.append(str(cr_id))
                #         continue
                #     cr = gold_crs[cr_index]
                #     card = build_card(
                #         subject=subject, level=level, domain=domain,
                #         card_idx=card_idx, front=cr.get("front", ""),
                #         back=make_back_from_cr(cr),
                #         card_type="concept", plan_task_id=task_name,
                #         gold_cr_ids=[format_cr_id(cr_index)],
                #         source_sentence=cr.get("source_sentence", ""),
                #         origin=task_origin,
                #     )
                #     cards.append(card)
                #     card_idx += 1

                # Task 类型卡
                if task_type == "character" and char_cards:
                    # 从旧字卡中捞匹配
                    matched = 0
                    for cc in char_cards:
                        if matched >= 20:
                            break
                        # 直接复用旧字卡
                        cc_copy = dict(cc)
                        cc_copy["plan_task_id"] = task_name
                        cc_copy["id"] = f"{subject}_{level}_{card_idx:04d}"
                        cards.append(cc_copy)
                        card_idx += 1
                        matched += 1

                elif task_type == "poem":
                    poem_content = _llm_generate_poem(task_name)
                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx, front=task_name,
                        back=poem_content, card_type="poem",
                        plan_task_id=task_name, origin=task_origin,
                    )
                    cards.append(card)
                    card_idx += 1

                elif task_type == "reading":
                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx, front=task_name,
                        back="阅读方法与策略，请结合文本实践。",
                        card_type="reading", plan_task_id=task_name,
                        origin=task_origin,
                    )
                    cards.append(card)
                    card_idx += 1

                elif task_type == "writing":
                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx, front=f"{task_name}·写作",
                        back="写作方法与结构指导",
                        card_type="writing", plan_task_id=task_name,
                        origin=task_origin,
                    )
                    cards.append(card)
                    card_idx += 1

    # 无 Plan 时，直接按 CR 生成概念卡 — 已禁用
    # if not plan:
    #     for ci, cr in enumerate(gold_crs):
    #         card = build_card(
    #             subject=subject, level=level, domain=domain,
    #             card_idx=card_idx, front=cr.get("front", ""),
    #             back=make_back_from_cr(cr),
    #             card_type="concept", plan_task_id="",
    #             gold_cr_ids=[format_cr_id(ci)],
    #             source_sentence=cr.get("source_sentence", ""),
    #         )
    #         cards.append(card)
    #         card_idx += 1

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0) if plan else len(gold_crs)
    msg = f"{len(missing_crs)} unmatched CRs" if missing_crs else ""
    return total, total_in_plan, cards, msg
