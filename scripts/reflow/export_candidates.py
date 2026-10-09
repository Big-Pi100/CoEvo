#!/usr/bin/env python3
"""A3 · 回流候选导出（只读 · 运维工具）

从线上 `generated_card_cache` 导出「够热」的词 + LLM 原始 card，供
`reflow_into_word_db.dart` 做回流（写进 `word.db` 的 word/card 两表）。

# 用法（两段式的第一段 —— 在服务器上跑，只读）

    ssh -i ~/.ssh/coevo_key ubuntu@<VPS> "python3 - 3" < scripts/reflow/export_candidates.py \
      > /tmp/reflow_candidates.json

    # 指定门槛 K（默认 3）
    ssh … "python3 - 5" < scripts/reflow/export_candidates.py > /tmp/c.json

    # 指定库路径（默认线上路径）
    ssh … "python3 - 0 /opt/coevo/data/coevo.db" < scripts/reflow/export_candidates.py

⚠️ **必须走 stdin（`python3 -`）传入**：本仓库的脚本文件在 Windows 上，
   直接 `ssh … "python3 /path/to/script.py"` 需要先把文件传上去；
   用 stdin 则一条命令搞定，且**不落盘**（服务器上不留脚本副本）。

# 🔑 为什么门槛看 `distinct_user_count` 而不是 `hit_count`

既定口径（见 MEMORY「三层缓存」）：**去重看 distinct**。
`hit_count` 是「总次数」，**一个人刷 100 次也能刷出来** ⇒ 用它会把噪声当需求。
⇒ 默认门槛 `distinct_user_count >= 3`（三个不同设备查过）。

# 🔑 为什么 SQL 里就过滤掉 `contract_version != 'v6'`

端侧 `toCardContent` 对**不认识的契约版本**是**显式失败**的（宁可报错也不静默出空卡）。
在导出侧就滤掉，可以让下游拿到的每一行都**必然是端侧能转换的** ——
但下游**仍会再查一次**（双保险：脚本可能被改，契约可能升到 v7）。

# ⚠️ 现在导出什么都是 `count: 0`

2026-10-09 实测：线上 `generated_card_cache` 只有 10 行，`distinct_user_count` 最大 1
⇒ **任何 K >= 2 都是 0**。本脚本的产出要等**有真实用户量**才会变多。
用 `K=0` 可以导出全部（用于**验证脚本本身**是否工作）。
"""
import json
import sqlite3
import sys
from datetime import datetime, timezone

DEFAULT_DB = '/opt/coevo/data/coevo.db'
DEFAULT_K = 3

# 🔑 端侧认识的契约版本 —— 必须与 `app/lib/services/generated_card_adapter.dart`
#    的 `kKnownContractVersion` **一致**（本脚本只做粗筛，真正的判断在 Dart 侧）。
KNOWN_CONTRACT = 'v6'


def main() -> int:
    k = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_K
    db_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DB

    if k < 0:
        sys.stderr.write(f'K 不能为负数：{k}\n')
        return 2
    if not db_path:
        sys.stderr.write('库路径为空\n')
        return 2

    # 只读打开 —— 本脚本**永不写库**
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    try:
        rows = con.execute(
            '''SELECT spelling, card_content, contract_version,
                      hit_count, distinct_user_count
                 FROM generated_card_cache
                WHERE distinct_user_count >= ?
                  AND contract_version = ?
                  AND card_content IS NOT NULL
                ORDER BY distinct_user_count DESC, hit_count DESC, spelling ASC''',
            (k, KNOWN_CONTRACT),
        ).fetchall()
    finally:
        con.close()

    candidates = []
    skipped_bad_json = 0
    for spelling, raw, cv, hits, distinct in rows:
        try:
            card = json.loads(raw)
        except (TypeError, ValueError):
            # 🔴 缓存里的一条坏 JSON 不该让整个导出失败 —— 计数上报、跳过
            skipped_bad_json += 1
            continue
        candidates.append({
            'spelling': spelling,
            'raw_card': card,
            'contract_version': cv,
            'hit_count': hits,
            'distinct_user_count': distinct,
        })

    out = {
        'exported_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'threshold': {'distinct_user_count_gte': k, 'contract_version': KNOWN_CONTRACT},
        'count': len(candidates),
        'skipped_bad_json': skipped_bad_json,
        'candidates': candidates,
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
