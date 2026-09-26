"""地理生成器 — geography

按 task name 关键词分流：
  自然地理（理科策略）→ 概念卡
  人文地理（历史策略）→ 概念卡 + 脉络卡
  工具实践 → 技能卡
"""
from .base import (load_gold, load_plan, parse_cr_id, build_card,
                   make_back_from_cr, format_cr_id)

# 地理分类关键词
PHYSICAL_KW = {"地球", "宇宙", "地图", "气候", "天气", "地质", "地形", "海洋",
               "河流", "湖泊", "经纬", "比例尺", "方向", "自然"}
HUMAN_KW = {"人口", "城市", "乡村", "产业", "农业", "工业", "交通", "贸易",
            "区域", "文化", "聚落", "发展", "经济"}
PRACTICE_KW = {"实践", "调查", "工具", "考察", "实验", "操作", "绘制", "制作",
               "收集", "分析数据", "读图"}

def _classify_task(task_name):
    """判断 task 属于哪一类地理"""
    for kw in PRACTICE_KW:
        if kw in task_name:
            return "practice"
    for kw in PHYSICAL_KW:
        if kw in task_name:
            return "physical"
    for kw in HUMAN_KW:
        if kw in task_name:
            return "human"
    return "physical"  # fallback

def geography_generator(subject, level):
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
            category = _classify_task(task_name)
            task_gold_crs = []

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
                task_gold_crs.append(cr)

            # 人文地理 → 额外脉络卡
            if category == "human" and len(task_gold_crs) >= 2:
                parts = []
                for cr in task_gold_crs:
                    back = cr.get("back", "")
                    key = "关键要素"
                    if isinstance(back, dict) and key in back:
                        parts.append(f"• {cr.get('front', '')}: {back[key][:80]}")
                    else:
                        parts.append(f"• {cr.get('front', '')}")

                card = build_card(
                    subject=subject, level=level, domain=domain,
                    card_idx=card_idx,
                    front=f"{task_name}·脉络",
                    back="\n".join(parts),
                    card_type="timeline", plan_task_id=task_name,
                    gold_cr_ids=[format_cr_id(parse_cr_id(c_id) - 1)
                                 for c_id in task.get("gold_cr_ids", [])
                                 if parse_cr_id(c_id) is not None],
                    origin=task_origin,
                )
                cards.append(card)
                card_idx += 1

            # 工具实践 → 额外技能卡
            if category == "practice" and task_gold_crs:
                steps = []
                for cr in task_gold_crs:
                    front = cr.get("front", "")
                    back = cr.get("back", "")
                    if isinstance(back, dict):
                        app = back.get("应用", back.get("关键要素", ""))
                        steps.append(f"• {front}: {app[:60]}")
                    else:
                        steps.append(f"• {front}")

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

    total = len(cards)
    total_in_plan = plan.get("total_crs", 0)
    msg = f"{len(missing_crs)} unmatched" if missing_crs else ""
    return total, total_in_plan, cards, msg
