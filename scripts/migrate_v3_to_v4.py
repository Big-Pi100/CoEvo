#!/usr/bin/env python3
"""
migrate_v3_to_v4.py

将 data/curriculum/v3 格式的数据迁移到 data/curriculum/v4 格式。
V4 按 domain（science/language/literature/humanities）分类输出。

用法:
  python scripts/migrate_v3_to_v4.py [--input-dir data/curriculum/v3] [--output-dir data/curriculum/v4]
"""

import argparse
import glob
import json
import os
import re
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── 科目到 domain 的映射 ──
SUBJECT_DOMAIN = {
    # science
    "physics": "science", "chemistry": "science", "biology": "science",
    "geography": "science", "math": "science", "it": "science",
    "pe": "science", "science": "science",
    # language
    "english": "language", "japanese": "language", "russian": "language",
    # literature — chinese 较为特殊，按 card_type 细分
    "chinese": "literature",
    # humanities
    "history": "humanities", "politics": "humanities",
}

# Chinese card_type → domain 细分（chinese 文件中的卡片需要按此重新分类）
CHINESE_CARDTYPE_DOMAIN = {
    "vocabulary": "language",
    "poem": "literature",
    "classical": "literature",
    "foreign": "literature",
    "vernacular": "literature",
    "whole_book": "literature",
    "nursery_rhyme": "literature",
    "dialogue": "literature",
    "narrative": "literature",
    "letter": "literature",
    "informational": "literature",
    "instruction": "literature",
    "opinion": "literature",
    "biography": "literature",
    "report": "literature",
    "speech": "literature",
    "play": "literature",
    "review": "literature",
    "concept": "science",  # 中文概念卡（如修辞手法）归 science
}

# English 中少量非 vocabulary 卡片的 domain 映射
ENGLISH_CARDTYPE_DOMAIN = {
    "concept": "science",
    "nursery_rhyme": "language",
    "vocabulary": "language",
}


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(data, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


# ═══════════════════════════════════════════
#  1. Science 卡映射: 正则解析 back 文本
# ═══════════════════════════════════════════

SCIENCE_BACK_PATTERN = re.compile(
    r"定义:(?P<definition>.*?)(?:\n关键要素:|$)",
    re.DOTALL,
)
SCIENCE_KEYS_PATTERN = re.compile(
    r"关键要素:(?P<key_elements>.*?)(?:\n应用:|$)",
    re.DOTALL,
)
SCIENCE_APPS_PATTERN = re.compile(
    r"应用:(?P<applications>.*?)(?:\n关联:|$)",
    re.DOTALL,
)
SCIENCE_RELATED_PATTERN = re.compile(
    r"关联:(?P<related_concepts>.*?)$",
    re.DOTALL,
)


def parse_science_back(card_id, back_text):
    """将 science 文本 back 解析为结构化字段"""
    definition = _extract_match(SCIENCE_BACK_PATTERN, back_text, "definition")
    key_elements = _extract_match(SCIENCE_KEYS_PATTERN, back_text, "key_elements")
    applications = _extract_match(SCIENCE_APPS_PATTERN, back_text, "applications")
    related_concepts = _extract_match(SCIENCE_RELATED_PATTERN, back_text, "related_concepts")
    return {
        "id": card_id,
        "definition": definition.strip() if definition else "",
        "key_elements": key_elements.strip() if key_elements else "",
        "applications": applications.strip() if applications else "",
        "related_concepts": related_concepts.strip() if related_concepts else "",
        "formula": "",
        "graph": "",
        "source": "",
    }


def _extract_match(pattern, text, group):
    m = pattern.search(text)
    return m.group(group).strip() if m else ""


# ═══════════════════════════════════════════
#  2. Language 卡映射: JSON back
# ═══════════════════════════════════════════

def parse_language_back(card_id, back_json, card_type):
    """将 language JSON back 映射为新字段"""
    pronunciation = back_json.get("pronunciation") or back_json.get("pinyin", "")
    pos = back_json.get("pos", "")
    definitions_raw = back_json.get("definitions", "[]")
    if isinstance(definitions_raw, list):
        definitions = json.dumps(definitions_raw, ensure_ascii=False)
    elif isinstance(definitions_raw, str):
        # 尝试解析为 JSON
        try:
            json.loads(definitions_raw)
            definitions = definitions_raw
        except (json.JSONDecodeError, TypeError):
            definitions = definitions_raw
    else:
        definitions = "[]"

    related_phrases = back_json.get("related_phrases") or back_json.get("common_words", "")
    structure_meta = back_json.get("structure_meta", "")
    # 针对英语词汇：从 cefr_level 或 tags 获取 level
    level = back_json.get("level", "")
    if not level:
        level = back_json.get("cefr_level", "")
    if not level and "tags" in back_json and isinstance(back_json["tags"], list):
        for t in back_json["tags"]:
            if re.match(r"^[A-Z]\d$", t):
                level = t
                break

    return {
        "id": card_id,
        "pronunciation": str(pronunciation) if pronunciation else "",
        "pos": str(pos) if pos else "",
        "definitions": definitions if definitions else "[]",
        "related_phrases": str(related_phrases) if related_phrases else "",
        "structure_meta": structure_meta,
        "level": str(level) if level else "",
    }


# ═══════════════════════════════════════════
#  3. Literature 卡映射: JSON back, 精简
# ═══════════════════════════════════════════

def parse_literature_back(card_id, back_json, card_type):
    """将 literature JSON back 映射为新字段（只取核心字段）"""
    full_text = back_json.get("full_text", "")
    translation = back_json.get("translation", "")
    author = back_json.get("author", "")
    genre = back_json.get("genre", card_type)
    return {
        "id": card_id,
        "full_text": str(full_text) if full_text else "",
        "translation": str(translation) if translation else "",
        "author": str(author) if author else "",
        "genre": str(genre) if genre else "",
    }


# ═══════════════════════════════════════════
#  4. Humanities 卡映射: JSON back, 概念结构
# ═══════════════════════════════════════════

def parse_humanities_back(card_id, back_text, card_type):
    """将 humanities concept back 映射为 node_type + body"""
    # 对 concept 类型，back 也是 定义:\n关键要素:\n... 格式
    # node_type: "concept"
    # body: 完整 back 文本
    return {
        "id": card_id,
        "node_type": card_type,
        "body": back_text.strip(),
        "period": "",
        "region": "",
        "tags": "[]",
    }


# ═══════════════════════════════════════════
#  5. Plan 中添加 domain
# ═══════════════════════════════════════════

def add_domain_to_plan(plan_data, subject_key):
    """为 plan 添加 domain 字段"""
    domain = SUBJECT_DOMAIN.get(subject_key, "science")
    plan_data["domain"] = domain
    return plan_data


# ═══════════════════════════════════════════
#  主流程
# ═══════════════════════════════════════════

def get_card_domain(card, subject_key):
    """根据 subject 和 card_type 确定 domain"""
    if subject_key == "chinese":
        return CHINESE_CARDTYPE_DOMAIN.get(card.get("card_type", ""), "literature")
    elif subject_key == "english":
        return ENGLISH_CARDTYPE_DOMAIN.get(card.get("card_type", ""), "language")
    else:
        return SUBJECT_DOMAIN.get(subject_key, "science")


def should_science_back_parse(back_text):
    """判断 back 是否 science 格式（可解析）"""
    return "定义:" in back_text and "关键要素:" in back_text


def should_try_json_parse(back_text):
    """判断 back 是否 JSON 格式"""
    back_stripped = back_text.strip()
    return back_stripped.startswith("{") or back_stripped.startswith("[")


def parse_card(card, subject_key):
    """解析单张卡片，返回 (parent_record, sub_record, domain)"""
    card_id = card["id"]
    card_type = card.get("card_type", "concept")
    front = card.get("front", "")
    back_text = card.get("back", "")
    domain = get_card_domain(card, subject_key)
    grade_band = card.get("grade_band", "")
    subject = card.get("subject", subject_key)

    # Parent record (prebuilt_cards)
    parent = {
        "id": card_id,
        "card_type": card_type,
        "domain": domain,
        "subject": subject,
        "grade_band": grade_band,
        "front": front,
    }

    sub = None  # 子表记录

    if domain == "science" and should_science_back_parse(back_text):
        sub = parse_science_back(card_id, back_text)
    elif domain == "language" and should_try_json_parse(back_text):
        try:
            back_json = json.loads(back_text)
            sub = parse_language_back(card_id, back_json, card_type)
        except (json.JSONDecodeError, ValueError):
            # fallback: 将整个 back 作为 definitions 存入
            sub = {
                "id": card_id,
                "pronunciation": "",
                "pos": "",
                "definitions": json.dumps([{"meaning": back_text}], ensure_ascii=False),
                "related_phrases": "",
                "structure_meta": "",
                "level": "",
            }
    elif domain == "literature" and should_try_json_parse(back_text):
        try:
            back_json = json.loads(back_text)
            sub = parse_literature_back(card_id, back_json, card_type)
        except (json.JSONDecodeError, ValueError):
            sub = {
                "id": card_id,
                "full_text": back_text,
                "translation": "",
                "author": "",
                "genre": card_type,
            }
    elif domain == "humanities":
        sub = parse_humanities_back(card_id, back_text, card_type)
    else:
        # fallback: science 格式
        if should_science_back_parse(back_text):
            sub = parse_science_back(card_id, back_text)
        else:
            sub = {
                "id": card_id,
                "definition": back_text,
                "key_elements": "",
                "applications": "",
                "related_concepts": "",
                "formula": "",
                "graph": "",
                "source": "",
            }

    return parent, sub, domain


def migrate_cards(input_dir, output_dir):
    """迁移所有卡片文件"""
    cards_dir = os.path.join(input_dir, "cards")
    if not os.path.isdir(cards_dir):
        print(f"[ERROR] cards dir not found: {cards_dir}")
        return

    # domain → list of (parent, sub)
    by_domain = defaultdict(list)
    domain_sub_table = {
        "science": "prebuilt_science_cards",
        "language": "prebuilt_language_cards",
        "literature": "prebuilt_literature_cards",
        "humanities": "prebuilt_humanities_cards",
    }

    for fpath in sorted(glob.glob(os.path.join(cards_dir, "*.json"))):
        fname = os.path.basename(fpath)
        subject_key = fname.replace(".json", "")
        print(f"  Processing cards: {fname} (subject={subject_key})")
        data = load_json(fpath)
        cards = data.get("cards", [])
        for card in cards:
            parent, sub, domain = parse_card(card, subject_key)
            by_domain[domain].append((parent, sub))

    # 按 domain 输出
    for domain, records in by_domain.items():
        parents = []
        subs = []
        for p, s in records:
            parents.append(p)
            subs.append(s)
        sub_table = domain_sub_table.get(domain, "prebuilt_science_cards")

        out_dir = os.path.join(output_dir, "cards", domain)
        parent_path = os.path.join(out_dir, "prebuilt_cards.json")
        sub_path = os.path.join(out_dir, f"{sub_table}.json")

        save_json(parents, parent_path)
        save_json(subs, sub_path)
        print(f"  → {domain}: {len(parents)} parent cards, {len(subs)} sub cards")

    total = sum(len(v) for v in by_domain.values())
    print(f"\n  Total cards migrated: {total}")


def migrate_plans(input_dir, output_dir):
    """迁移 plan 文件，添加 domain 字段"""
    plans_dir = os.path.join(input_dir, "plans")
    if not os.path.isdir(plans_dir):
        print(f"[ERROR] plans dir not found: {plans_dir}")
        return

    output_plans_dir = os.path.join(output_dir, "plans")
    plan_count = 0

    for fpath in sorted(glob.glob(os.path.join(plans_dir, "*.json"))):
        fname = os.path.basename(fpath)
        if fname in ("id_mapping.json", "stage_grade_filter.json"):
            continue
        subject_key = fname.replace(".json", "")
        data = load_json(fpath)
        data = add_domain_to_plan(data, subject_key)
        out_path = os.path.join(output_plans_dir, fname)
        save_json(data, out_path)
        plan_count += 1
        print(f"  Plan: {fname} → domain={data.get('domain', '?')}")

    print(f"\n  Total plans migrated: {plan_count}")


def main():
    parser = argparse.ArgumentParser(description="Migrate V3 curriculum data to V4 format")
    parser.add_argument("--input-dir", default="data/curriculum/v3", help="V3 data directory")
    parser.add_argument("--output-dir", default="data/curriculum/v4", help="V4 output directory")
    args = parser.parse_args()

    input_dir = args.input_dir
    output_dir = args.output_dir

    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print()

    print("[Step 1/2] Migrating cards...")
    migrate_cards(input_dir, output_dir)

    print()
    print("[Step 2/2] Migrating plans...")
    migrate_plans(input_dir, output_dir)

    print()
    print("Done! Run the following to verify:")
    print(f"  find {output_dir}/cards -name '*.json' | head -20")
    print(f"  find {output_dir}/plans -name '*.json' | head -20")


if __name__ == "__main__":
    main()
