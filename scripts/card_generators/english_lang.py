"""英语生成器 — english

每 task:
  Step 1: 每个 gold_cr → 概念卡（纯文本 back）
  Step 2: 按 task name 路由到不同类型：
    "词汇" → 从 CEFR 词表按等级+关键词筛选词汇卡
    "句型"/"语法" → 句型结构卡
    "场景对话" → 场景对话卡
    "阅读" → 阅读策略卡
    "写作" → 写作模版卡
"""
import re
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, save_cards, load_cefr,
                   keywords_from_task, format_cr_id)

# CEFR 等级映射
CEFR_LEVEL = {"compulsory": {"a1", "a2", "pre-a1"},
              "senior": {"b1", "b2"}}

# 英语 task 类型关键词
TASK_TYPE_KEYWORDS = {
    "vocabulary": {"词汇", "单词", "词", "vocabulary"},
    "grammar": {"句型", "语法", "句式", "时态", "grammar", "sentence"},
    "dialogue": {"对话", "交流", "沟通", "conversation", "dialogue", "场景"},
    "reading": {"阅读", "reading", "语篇", "理解"},
    "writing": {"写作", "writing", "作文", "应用文"},
    "pronunciation": {"语音", "语调", "音标", "发音"},
}

def _classify_english_task(task_name):
    """判断 English task 类型"""
    for task_type, keywords in TASK_TYPE_KEYWORDS.items():
        for kw in keywords:
            if kw in task_name:
                return task_type
    return "general"

def _search_cefr_vocab(cefr_dict, task_name, level):
    """从 CEFR 词表按 task 关键词和 CEFR 等级筛选词汇"""
    allowed_levels = CEFR_LEVEL.get(level, {"a1", "a2"})
    keywords = keywords_from_task(task_name)

    if not keywords:
        return []

    matched = []
    for word, entry in cefr_dict.items():
        entry_level = entry.get("cefr", "")
        entry_level = entry_level.lower().strip("-")
        if entry_level not in allowed_levels:
            continue

        # 检查 definition 中是否含有关键词
        definition = entry.get("definition", "")
        translation = entry.get("translation", "")
        search_text = (definition + translation + word).lower()

        for kw in keywords:
            if kw.lower() in search_text or kw.lower() in word.lower():
                matched.append((word, entry))
                break

        if len(matched) >= 50:
            break

    return matched

def english_generator(subject, level):
    gold_crs, domain = load_gold(subject, level)
    plan = load_plan(subject, level)
    if not plan or not gold_crs:
        return 0, 0, [], f"no data (gold={len(gold_crs)}, plan={'ok' if plan else 'none'})"

    cefr_dict = load_cefr()
    cards = []
    card_idx = 0
    missing_crs = []

    for stage in plan.get("stages", []):
        for task in stage.get("tasks", []):
            task_name = task.get("name", "")
            task_origin = task.get("origin", "extracted")
            task_type = _classify_english_task(task_name)
            task_gold_crs = []

            # Step 1: 概念卡（从 gold CR） — 已禁用：课标 CR 生成的 concept 卡质量差
            # for cr_id in task.get("gold_cr_ids", []):
            #     cr_num = parse_cr_id(cr_id)
            #     if cr_num is None:
            #         missing_crs.append(str(cr_id))
            #         continue
            #     cr_index = cr_num - 1
            #     if cr_index < 0 or cr_index >= len(gold_crs):
            #         missing_crs.append(str(cr_id))
            #         continue
            #
            #     cr = gold_crs[cr_index]
            #     front = cr.get("front", "")
            #     back = make_back_from_cr(cr)
            #     source = cr.get("source_sentence", "")
            #     gold_cr_id = format_cr_id(cr_index, zero_based=False)
            #
            #     card = build_card(
            #         subject=subject, level=level, domain=domain,
            #         card_idx=card_idx, front=front, back=back,
            #         card_type="concept", plan_task_id=task_name,
            #         gold_cr_ids=[gold_cr_id], source_sentence=source,
            #         origin=task_origin,
            #     )
            #     cards.append(card)
            #     card_idx += 1
            #     task_gold_crs.append(cr)

            # Step 2: 按 task 类型生成额外卡
            if task_type == "vocabulary" and cefr_dict:
                vocab_items = _search_cefr_vocab(cefr_dict, task_name, level)
                for word, entry in vocab_items:
                    trans = entry.get("translation", "")
                    cefr = entry.get("cefr", "").upper()
                    definition = entry.get("definition", trans)
                    examples = entry.get("examples", [])
                    if isinstance(examples, list):
                        examples = "; ".join(examples[:2])

                    back = f"CEFR: {cefr}\n释义: {definition}"
                    if examples:
                        back += f"\n例句: {examples}"
                    if trans and trans != definition:
                        back += f"\n翻译: {trans}"

                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx, front=word, back=back,
                        card_type="vocabulary", plan_task_id=task_name,
                        origin="extracted",
                    )
                    cards.append(card)
                    card_idx += 1

            elif task_type == "grammar":
                # 提取 task_name 中的语法点
                grammar_back = "句型结构练习\n\n请结合具体教材中的例句学习和练习。"
                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx, front=task_name, back=grammar_back,
                    card_type="sentence_pattern", plan_task_id=task_name,
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

            elif task_type == "dialogue" and task_gold_crs:
                dialogue_back = "场景对话练习\n\n"
                for cr in task_gold_crs:
                    dialogue_back += f"• {cr.get('front', '')}\n"
                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx, front=f"{task_name}·对话",
                    back=dialogue_back, card_type="dialogue",
                    plan_task_id=task_name, origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

            elif task_type == "reading":
                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx, front=task_name, back="阅读策略与理解",
                    card_type="reading", plan_task_id=task_name,
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

            elif task_type == "writing":
                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx, front=f"{task_name}·写作模板",
                    back="写作模板与范例参考", card_type="writing",
                    plan_task_id=task_name, origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0)
    msg = f"{len(missing_crs)} unmatched CRs" if missing_crs else ""
    return total, total_in_plan, cards, msg
