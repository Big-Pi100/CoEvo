#!/usr/bin/env python3
"""Backfill plan JSON files with extra fields.

idempotent: skips files that already have all fields.
"""

import json
import os
import uuid
import subprocess
import sys

PLANS_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "curriculum", "v4", "plans")
PLANS_DIR = os.path.normpath(PLANS_DIR)

SUBJECT_MAP = {
    "english":     {"display_name": "英语", "domain": "language",    "theme_color": "#81C784", "theme_icon": "language"},
    "chinese":     {"display_name": "语文", "domain": "language",    "theme_color": "#64B5F6", "theme_icon": "menu_book"},
    "math":        {"display_name": "数学", "domain": "science",     "theme_color": "#E57373", "theme_icon": "calculate"},
    "physics":     {"display_name": "物理", "domain": "science",     "theme_color": "#FFB74D", "theme_icon": "science"},
    "chemistry":   {"display_name": "化学", "domain": "science",     "theme_color": "#BA68C8", "theme_icon": "biotech"},
    "biology":     {"display_name": "生物", "domain": "science",     "theme_color": "#4DB6AC", "theme_icon": "pets"},
    "history":     {"display_name": "历史", "domain": "humanities",  "theme_color": "#F06292", "theme_icon": "auto_stories"},
    "geography":   {"display_name": "地理", "domain": "humanities",  "theme_color": "#4FC3F7", "theme_icon": "explore"},
    "politics":    {"display_name": "政治", "domain": "humanities",  "theme_color": "#A1887F", "theme_icon": "account_balance"},
    "science":     {"display_name": "科学", "domain": "science",     "theme_color": "#90A4AE", "theme_icon": "travel_explore"},
    "it":          {"display_name": "信息技术", "domain": "science", "theme_color": "#7986CB", "theme_icon": "computer"},
    "pe":          {"display_name": "体育", "domain": "science",     "theme_color": "",       "theme_icon": ""},
    "art":         {"display_name": "艺术", "domain": "humanities",  "theme_color": "",       "theme_icon": ""},
    "labor":       {"display_name": "劳动", "domain": "science",     "theme_color": "",       "theme_icon": ""},
    "japanese":    {"display_name": "日语", "domain": "language",    "theme_color": "",       "theme_icon": "", "visible": False},
    "russian":     {"display_name": "俄语", "domain": "language",    "theme_color": "",       "theme_icon": "", "visible": False},
}

# grade_band 推断规则
GRADE_BAND_RULES = {
    "english": "g1-12",
    "chinese": "g1-12",
    "math": "g1-12",
}

# 骨架文件（不存在的 JSON 文件需要创建）
SKELETON_STAGES = {
    "art": [
        {"id": str(uuid.uuid4()), "name": "小学阶段", "grade_band": "g1-6", "tasks": []},
        {"id": str(uuid.uuid4()), "name": "初中阶段", "grade_band": "g7-9", "tasks": []},
    ],
    "labor": [
        {"id": str(uuid.uuid4()), "name": "小学阶段", "grade_band": "g1-6", "tasks": []},
        {"id": str(uuid.uuid4()), "name": "初中阶段", "grade_band": "g7-9", "tasks": []},
    ],
}


def get_grade_band(subject: str, data: dict) -> str:
    if "grade_band" in data:
        return data["grade_band"]
    return GRADE_BAND_RULES.get(subject, "g7-12")


def backfill_file(subject: str, filepath: str) -> bool:
    """Backfill a single file. Returns True if modified."""
    info = SUBJECT_MAP.get(subject)
    if info is None:
        print(f"  SKIP {subject}: unknown subject")
        return False

    # Load or create skeleton
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        print(f"  CREATE skeleton for {subject}")
        grade_band = get_grade_band(subject, {})
        data = {
            "id": str(uuid.uuid4()),
            "title": f"{info['display_name']}课标",
            "author": "课标编制组",
            "display_name": info["display_name"],
            "domain": info["domain"],
            "grade_band": grade_band,
            "visible": info.get("visible", True),
            "theme_color": info["theme_color"],
            "theme_icon": info["theme_icon"],
            "stages": SKELETON_STAGES.get(subject, []),
        }
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return True

    changed = False

    # id
    if "id" not in data or not data["id"]:
        data["id"] = str(uuid.uuid4())
        changed = True

    # title
    if "title" not in data or not data["title"]:
        data["title"] = f"{info['display_name']}课标"
        changed = True

    # author
    if "author" not in data or not data["author"]:
        data["author"] = "课标编制组"
        changed = True

    # display_name
    if "display_name" not in data or not data["display_name"]:
        data["display_name"] = info["display_name"]
        changed = True

    # visible
    if "visible" not in data:
        data["visible"] = info.get("visible", True)
        changed = True

    # theme_color
    if "theme_color" not in data:
        data["theme_color"] = info["theme_color"]
        changed = True

    # theme_icon
    if "theme_icon" not in data:
        data["theme_icon"] = info["theme_icon"]
        changed = True

    # domain
    if "domain" not in data or not data["domain"]:
        data["domain"] = info["domain"]
        changed = True

    # grade_band
    if "grade_band" not in data:
        data["grade_band"] = get_grade_band(subject, data)
        changed = True

    # 为每个 task 补充 dependencies 和 origin
    for stage in data.get("stages", []):
        for task in stage.get("tasks", []):
            if "dependencies" not in task:
                task["dependencies"] = []
                changed = True
            if "origin" not in task:
                task["origin"] = "curriculum_v4"
                changed = True

    if changed:
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"  UPDATED {subject}")

    return changed


def main():
    os.makedirs(PLANS_DIR, exist_ok=True)
    all_subjects = list(SUBJECT_MAP.keys())
    modified = 0

    for subject in all_subjects:
        filepath = os.path.join(PLANS_DIR, f"{subject}.json")
        if backfill_file(subject, filepath):
            modified += 1

    print(f"\nDone. {modified} files modified.")

    # Git commit if available
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=os.path.dirname(PLANS_DIR),
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip():
            subprocess.run(
                ["git", "add", "."],
                cwd=os.path.dirname(PLANS_DIR),
                check=True, timeout=10
            )
            subprocess.run(
                ["git", "commit", "-m", "curriculum: backfill plan fields"],
                cwd=os.path.dirname(PLANS_DIR),
                check=True, timeout=10
            )
            print("Git commit created.")
        else:
            print("No changes to commit.")
    except Exception as e:
        print(f"Git: {e}")


if __name__ == "__main__":
    main()
