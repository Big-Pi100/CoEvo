"""历史生成器 — history

每 task:
  Step 1: 每个 gold_cr → 概念卡 (同理科)
  Step 2: 额外一张"脉络时间线卡"（该 task 所有 CR 的关键要素串联）
"""
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, save_cards, format_cr_id)

def history_generator(subject, level):
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

            # Step 2: 脉络时间线卡（只在有多个 CR 时生成）
            if len(task_crs) >= 2:
                timeline_parts = []
                for cr in task_crs:
                    KEY_ELEM_KEY = "关键要素"
                    back = cr.get("back", "")
                    if isinstance(back, dict) and KEY_ELEM_KEY in back:
                        elem = back[KEY_ELEM_KEY][:80]
                        timeline_parts.append(f"• {cr.get('front', '')}: {elem}")
                    else:
                        timeline_parts.append(f"• {cr.get('front', '')}")

                timeline_card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx,
                    front=f"{task_name}·脉络",
                    back="\n".join(timeline_parts),
                    card_type="timeline", plan_task_id=task_name,
                    gold_cr_ids=[format_cr_id(parse_cr_id(cr_id) - 1)
                                 for cr_id in task.get("gold_cr_ids", [])
                                 if parse_cr_id(cr_id) is not None],
                    origin=task_origin,
                )
                cards.append(timeline_card)
                card_idx += 1

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0)
    msg = f"{len(missing_crs)} unmatched" if missing_crs else ""
    return total, total_in_plan, cards, msg
