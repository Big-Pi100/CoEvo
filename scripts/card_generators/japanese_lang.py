"""日语生成器 — japanese

日语词卡来自旧 cards/（附录提取），新脚本只生成概念卡。
"""
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, load_old_cards, format_cr_id)

def japanese_generator(subject, level):
    gold_crs, domain = load_gold(subject, level)
    plan = load_plan(subject, level)
    if not gold_crs:
        return 0, 0, [], "no gold data"

    cards = []
    card_idx = 0
    missing_crs = []

    if plan:
        for stage in plan.get("stages", []):
            for task in stage.get("tasks", []):
                task_name = task.get("name", "")
                task_origin = task.get("origin", "extracted")

                # 概念卡 — 已禁用：课标 CR 生成的 concept 卡质量差
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
    else:
        # 无 Plan 时的概念卡 fallback — 已禁用
        pass
        # for ci, cr in enumerate(gold_crs):
        #     card = build_card(
        #         subject=subject, level=level, domain=domain,
        #         card_idx=card_idx, front=cr.get("front", ""),
        #         back=make_back_from_cr(cr),
        #         card_type="concept", plan_task_id="",
        #         gold_cr_ids=[format_cr_id(ci)],
        #         source_sentence=cr.get("source_sentence", ""),
        #     )
        #     cards.append(card)
        #     card_idx += 1

    total_in_plan = plan.get("total_crs", 0) if plan else len(gold_crs)
    msg = f"{len(missing_crs)} unmatched" if missing_crs else ""
    return len(cards), total_in_plan, cards, msg
