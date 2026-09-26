"""政治生成器 — politics

每 task:
  Step 1: 每个 gold_cr → 概念定义卡
  Step 2: 额外一张"关系链卡"（CR 之间的逻辑推演链条）
"""
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, format_cr_id)

def politics_generator(subject, level):
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
            task_crs = []

            # Step 1: 概念卡
            for cr_id in task.get("gold_cr_ids", []):
                cr_num = parse_cr_id(cr_id)
                if cr_num is None:
                    missing_crs.append(str(cr_id))
                    continue
                cr_index = cr_num - 1
                if cr_index < 0 or cr_index >= len(gold_crs):
                    missing_crs.append(str(cr_id))
                    continue

                cr = gold_crs[cr_index]
                front = cr.get("front", "")
                back = make_back_from_cr(cr)
                source = cr.get("source_sentence", "")
                gold_cr_id = format_cr_id(cr_index)

                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx, front=front, back=back,
                    card_type="concept", plan_task_id=task_name,
                    gold_cr_ids=[gold_cr_id], source_sentence=source,
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1
                task_crs.append(cr)

            # Step 2: 关系链卡（2+ CR 时生成）
            if len(task_crs) >= 2:
                chain_parts = []
                for i, cr in enumerate(task_crs):
                    front = cr.get("front", "")
                    back = cr.get("back", "")
                    if isinstance(back, dict):
                        key_elem = back.get("关键要素", back.get("定义", ""))
                        chain_parts.append(f"{i+1}. {front}: {key_elem[:100]}")
                    else:
                        chain_parts.append(f"{i+1}. {front}")

                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx,
                    front=f"{task_name}·关系",
                    back=" → ".join([cr.get("front", "") for cr in task_crs]) +
                         "\n\n" + "\n".join(chain_parts),
                    card_type="relationship", plan_task_id=task_name,
                    gold_cr_ids=[format_cr_id(parse_cr_id(c_id) - 1)
                                 for c_id in task.get("gold_cr_ids", [])
                                 if parse_cr_id(c_id) is not None],
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0)
    msg = f"{len(missing_crs)} unmatched" if missing_crs else ""
    return total, total_in_plan, cards, msg
