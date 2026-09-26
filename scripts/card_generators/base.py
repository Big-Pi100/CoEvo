"""卡片生成器公用模块"""
import json, re
from pathlib import Path

GOLD_DIR = Path(__file__).parent.parent.parent.parent / "docs" / "curriculum" / "gold"
PLAN_DIR = Path(__file__).parent.parent.parent.parent / "docs" / "curriculum" / "prebuilt" / "plans"
CARD_DIR = Path(__file__).parent.parent.parent.parent / "docs" / "curriculum" / "prebuilt" / "cards"
CEFR_PATH = Path(__file__).parent.parent.parent.parent / "backend" / "cefr_catalog.json"

def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def load_gold(subject, level):
    path = GOLD_DIR / level / f"{subject}.json"
    if path.exists():
        data = load_json(path)
        return data.get("content_requirements", []), data.get("domain", subject)
    return [], subject

def load_plan(subject, level):
    path = PLAN_DIR / f"{subject}_{level}.json"
    if path.exists():
        data = load_json(path)
        return data.get("plans", [{}])[0]
    return None

def load_cefr():
    """载入 CEFR 词表，返回 dict {word: entry}"""
    if CEFR_PATH.exists():
        return load_json(CEFR_PATH)
    return {}

def load_old_cards(subject, level):
    """载入旧卡片（词卡等），用于合并"""
    path = CARD_DIR / f"{subject}_{level}.json"
    if path.exists():
        return load_json(path).get("cards", [])
    return []

def format_cr_id(index, zero_based=True):
    """统一 CR ID 格式为 cr_001 (3 位, 1-indexed)"""
    if zero_based:
        return f"cr_{index + 1:03d}"
    return f"cr_{index:03d}"

def parse_cr_id(cr_id):
    """解析各种格式的 CR ID 为 1-indexed 数字，失败返回 None
    
    支持: "cr_001" → 1, "cr_01" → 1, "cr_1" → 1, "1" → 1, "TCP/IP协议" → None
    """
    s = str(cr_id).strip()
    # "cr_001" / "cr_01" / "cr_1"
    m = re.match(r"cr_(\d+)$", s, re.IGNORECASE)
    if m:
        return int(m.group(1))
    # "1", "42" (纯数字)
    try:
        return int(s)
    except ValueError:
        return None

def build_card(subject, level, domain, card_idx, front, back,
               card_type="concept", plan_task_id="", gold_cr_ids=None,
               source_sentence="", origin="extracted"):
    """创建统一格式的卡片 dict"""
    return {
        "id": f"{subject}_{level}_{card_idx:04d}",
        "subject": subject,
        "grade_band": level,
        "domain": domain,
        "front": front,
        "back": back,
        "card_type": card_type,
        "plan_task_id": plan_task_id,
        "gold_cr_ids": gold_cr_ids or [],
        "source_sentence": source_sentence or "",
        "origin": origin,
    }

def make_back_from_cr(cr):
    """从 gold CR 构建 back 字符串（支持 dict 或 string 格式）"""
    back = cr.get("back", "")
    if isinstance(back, dict):
        parts = []
        for k in ("定义", "关键要素", "应用", "关联"):
            v = back.get(k, "")
            if v:
                parts.append(f"{k}: {v}")
        return "\n\n".join(parts)
    return str(back)

def find_cr_index(subject_gold, cr_id_str):
    """在 gold CR 列表中通过 front 文本模糊匹配查找 index（用于 IT 等文本 CR ID）"""
    for idx, cr in enumerate(subject_gold):
        front = cr.get("front", "")
        if cr_id_str in front or front in cr_id_str:
            return idx
        # Token matching
        tokens = set(cr_id_str.replace("/", " ").split())
        front_tokens = set(front.replace("/", " ").split())
        if tokens & front_tokens:
            return idx
    return None

def keywords_from_task(task_name):
    """从 task name 提取关键词（用于英语词汇匹配等）"""
    # 移除通用词
    stopwords = {"的", "与", "和", "及", "基础", "初步", "认识", "了解", "学习",
                 "掌握", "技能", "方法", "应用", "实践", "探究", "活动"}
    tokens = re.findall(r"[\w\u4e00-\u9fff]+", task_name)
    return [t for t in tokens if t not in stopwords and len(t) > 1]

def save_cards(subject, level, new_cards, merge_old=True):
    """保存卡片（合并旧词卡）"""
    cards = list(new_cards)
    
    if merge_old:
        old = load_old_cards(subject, level)
        if old:
            # 只保留旧卡里 type 不是 concept 的（避免重复的概念卡）
            old_types = {c.get("card_type") for c in cards}
            for oc in old:
                ct = oc.get("card_type", "concept")
                if ct not in old_types and ct != "concept":
                    cards.append(oc)
                elif ct == "vocabulary":
                    cards.append(oc)
                elif ct == "character":
                    cards.append(oc)
    
    CARD_DIR.mkdir(parents=True, exist_ok=True)
    out_path = CARD_DIR / f"{subject}_{level}.json"
    out_path.write_text(json.dumps({"cards": cards}, ensure_ascii=False, indent=2))
    return len(cards), out_path.name
