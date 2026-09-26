#!/usr/bin/env python3
"""Backfill UUID `id` fields to stages and tasks in plan JSON files.

Problem:
- 12 subjects (math, physics, chemistry, biology, history, geography,
  politics, science, it, pe, japanese, russian) have NO `id` on any
  stage or task.
- chinese has partial coverage (131/131 stage ids, 502/681 task ids).
- english and art/labor already complete.

Root cause:
- V3 plans never had stage/task `id` fields.
- V3→V4 migration (migrate_v3_to_v4.py) only added `domain` to the plan.
- Commit 6ae0d46 ("渲染搞定") manually added UUIDs to english + chinese only.
- backfill_plan_fields.py only adds plan-level metadata + task dependencies,
  NOT stage/task `id`s.

Usage:
  python scripts/backfill_plan_ids.py [--dry-run]
"""

import argparse
import json
import os
import uuid

PLANS_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "data", "curriculum", "v4", "plans")
)

# Subjects whose ids are already complete (skip)
COMPLETE = {"english", "art", "labor"}


def backfill_file(subject: str, filepath: str, dry_run: bool = False) -> int:
    """Backfill UUID ids to stages and tasks missing them.
    Returns the number of ids added (0 if no change).
    """
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    added = 0

    for stage in data.get("stages", []):
        if "id" not in stage or not stage["id"]:
            stage["id"] = str(uuid.uuid4())
            added += 1

        for task in stage.get("tasks", []):
            if "id" not in task or not task["id"]:
                task["id"] = str(uuid.uuid4())
                added += 1

    if added > 0 and not dry_run:
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"  UPDATED {subject}: added {added} ids")

    return added


def main():
    parser = argparse.ArgumentParser(
        description="Backfill UUID ids to plan stages/tasks"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Dry run: only report what would be done, don't modify files",
    )
    args = parser.parse_args()

    if not os.path.isdir(PLANS_DIR):
        print(f"[ERROR] plans dir not found: {PLANS_DIR}")
        return 1

    all_files = sorted(
        f.replace(".json", "")
        for f in os.listdir(PLANS_DIR)
        if f.endswith(".json")
    )

    total_added = 0
    changed = 0

    print(f"{'Dry run' if args.dry_run else 'Updating'} plan files in {PLANS_DIR}")
    print()

    for subject in all_files:
        filepath = os.path.join(PLANS_DIR, f"{subject}.json")
        added = backfill_file(subject, filepath, dry_run=args.dry_run)
        total_added += added
        if added > 0:
            changed += 1

    print()
    print(f"Total: {changed} files changed, {total_added} ids added")
    if args.dry_run:
        print("(dry run — no files modified)")
    return 0


if __name__ == "__main__":
    exit(main())
