"""IT 生成器 — it

IT 的 gold_cr_ids 是中文文本（如 "TCP/IP协议"），需要用 front 字段
做模糊匹配来定位 gold CR。

类型路由：
  概念类 → 概念卡
  操作/技能类 → 技能步骤卡
  道德/规范类 → 规则卡
"""
from .base import (load_gold, load_plan, build_card,
                   make_back_from_cr, find_cr_index, format_cr_id)

# IT task 类型关键词
PRACTICE_KW = {"操作", "制作", "设计", "实现", "编程", "实验", "绘制", "处理"}
ETHICS_KW = {"道德", "规范", "责任", "安全", "法律", "伦理", "保护", "隐私"}

def _classify_it_task(task_name):
    for kw in ETHICS_KW:
        if kw in task_name:
            return "ethics"
    for kw in PRACTICE_KW:
        if kw in task_name:
            return "practice"
    return "concept"

def it_generator(subject, level):
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
                task_type = _classify_it_task(task_name)
                matched_crs = []

                for cr_id in task.get("gold_cr_ids", []):
                    cr_id_str = str(cr_id)
                    cr_index = find_cr_index(gold_crs, cr_id_str)
                    if cr_index is None:
                        missing_crs.append(cr_id_str)
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
                    matched_crs.append(cr)

                # 操作/技能类 → 额外技能步骤卡
                if task_type == "practice" and matched_crs:
                    steps = []
                    for cr in matched_crs:
                        back = cr.get("back", "")
                        if isinstance(back, dict):
                            app = back.get("应用", back.get("关键要素", ""))
                            steps.append(f"• {cr.get('front', '')}: {app[:80]}")
                        else:
                            steps.append(f"• {cr.get('front', '')}")

                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx,
                        front=f"{task_name}·技能",
                        back="\n".join(steps) if steps else "见相关概念卡",
                        card_type="skill", plan_task_id=task_name,
                        origin=task_origin,
                    )
                    cards.append(card)
                    card_idx += 1

                # 道德/规范类 → 规则卡
                if task_type == "ethics" and matched_crs:
                    rules = []
                    for cr in matched_crs:
                        rules.append(f"• {cr.get('front', '')}")
                    card = build_card(
                        subject=subject, level=level, domain=domain,
                        card_idx=card_idx,
                        front=f"{task_name}·规范",
                        back="\n".join(rules),
                        card_type="rule", plan_task_id=task_name,
                        origin=task_origin,
                    )
                    cards.append(card)
                    card_idx += 1
    else:
        for ci, cr in enumerate(gold_crs):
            card = build_card(
                subject=subject, level=level, domain=domain,
                card_idx=card_idx, front=cr.get("front", ""),
                back=make_back_from_cr(cr),
                card_type="concept", plan_task_id="",
                gold_cr_ids=[format_cr_id(ci)],
                source_sentence=cr.get("source_sentence", ""),
            )
            cards.append(card)
            card_idx += 1

    total_in_plan = plan.get("total_crs", 0) if plan else len(gold_crs)
    msg = f"{len(missing_crs)} unmatched ({missing_crs[:5]})" if missing_crs else ""
    return len(cards), total_in_plan, cards, msg
