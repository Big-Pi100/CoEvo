"""理科生成器 — physics/chemistry/math/biology/science

每 task:
  遍历 task.gold_cr_ids:
    按 index 对齐 → 1 张 concept card
    back = 定义/关键要素/应用/关联（结构化 dict）
"""
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, save_cards, format_cr_id)

def science_generator(subject, level):
    gold_crs, domain = load_gold(subject, level)
    plan = load_plan(subject, level)
    if not plan or not gold_crs:
        return 0, 0, [], "no data"

    cards = []
    card_idx = 0
    missing_crs = []

    for stage in plan.get("stages", []):
        for task in stage.get("tasks", []):
            task_name = task.get("name", "")
            task_origin = task.get("origin", "extracted")

            for cr_id in task.get("gold_cr_ids", []):
                cr_num = parse_cr_id(cr_id)
                if cr_num is None:
                    missing_crs.append(str(cr_id))
                    continue

                cr_index = cr_num - 1  # 1-indexed → 0-indexed
                if cr_index < 0 or cr_index >= len(gold_crs):
                    missing_crs.append(str(cr_id))
                    continue

                cr = gold_crs[cr_index]
                front = cr.get("front", "")
                back = make_back_from_cr(cr)
                source = cr.get("source_sentence", "")
                gold_cr_id = format_cr_id(cr_index)

                card = build_card(
                    subject=subject,
                    level=level,
                    domain=domain,
                    card_idx=card_idx,
                    front=front,
                    back=back,
                    card_type="concept",
                    plan_task_id=task_name,
                    gold_cr_ids=[gold_cr_id],
                    source_sentence=source,
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0)

    msg = ""
    if missing_crs:
        msg = f"{len(missing_crs)} unmatched CRs (e.g. {missing_crs[:3]})"

    return total, total_in_plan, cards, msg
