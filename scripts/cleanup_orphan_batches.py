"""
清理孤立批次数据迁移脚本

问题: 旧逻辑中提现审核直接分配 batch_no，产生了大量单人单笔的孤立批次
     这些批次的 expense 记录的 batch_no 需要清空，重新走新流程

运行: python scripts/cleanup_orphan_batches.py [--db-path 数据库路径]
      默认使用后端配置的数据库路径
"""

import argparse
import sqlite3
import sys
from pathlib import Path

def get_default_db_path():
    """尝试从后端环境推断数据库路径"""
    candidates = [
        Path("backend/data/coevo.db"),
        Path("data/coevo.db"),
    ]
    for p in candidates:
        if p.exists():
            return p
    return candidates[0]

def main():
    parser = argparse.ArgumentParser(description="清理孤立批次数据")
    parser.add_argument("--db", type=str, default=None, help="数据库路径")
    args = parser.parse_args()

    db_path = args.db or get_default_db_path()

    if not db_path.exists():
        print(f"数据库不存在: {db_path}")
        print("请指定正确的路径: python scripts/cleanup_orphan_batches.py --db /path/to/coevo.db")
        sys.exit(1)

    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    # 查找孤立批次: 只有1条记录的批次，且 expense_type='withdrawal'
    cursor.execute("""
        SELECT batch_no, COUNT(*) as cnt
        FROM distribution_expenses
        WHERE batch_no IS NOT NULL AND batch_no != ''
        GROUP BY batch_no
        HAVING cnt = 1
    """)
    orphans = cursor.fetchall()

    if not orphans:
        print("没有发现孤立批次数据 ✅")
        conn.close()
        return

    print(f"发现 {len(orphans)} 个孤立批次:")
    for bn, cnt in orphans:
        cursor.execute(
            "SELECT id, earner_id, amount, status FROM distribution_expenses WHERE batch_no = ?",
            (bn,)
        )
        row = cursor.fetchone()
        print(f"  {bn}: expense_id={row[0]}, earner={row[1]}, amount={row[2]/100:.2f}, status={row[3]}")

    confirm = input(f"\n确认清空这 {len(orphans)} 个批次的 batch_no? (y/N): ")
    if confirm.lower() != 'y':
        print("已取消")
        conn.close()
        return

    updated = 0
    for bn, _ in orphans:
        cursor.execute(
            "UPDATE distribution_expenses SET batch_no = NULL WHERE batch_no = ?",
            (bn,)
        )
        updated += cursor.rowcount

    conn.commit()
    conn.close()
    print(f"已清空 {updated} 条记录的 batch_no ✅")
    print("这些记录现在会出现在'待结算佣金'列表中，可重新走新流程结算。")

if __name__ == "__main__":
    main()
