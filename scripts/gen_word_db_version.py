#!/usr/bin/env python3
"""从 `word.db` 生成**版本指纹** → `data/word_db.version`。

# 为什么需要它

端侧判断「要不要重新落盘」目前**只比文件大小**（`word_db_bootstrap.dart` 自述为
**启发式**，并预告「若将来真出现〔同大小不同内容〕，应改为版本号文件」）。

🔑 **那个「将来」已经到了**：一旦有词库回流（LLM 制卡 → 回灌 `word.db`），
   「词库更新」会从**罕见**变成**常态**（每次发版都可能变）。
   而**发版收敛**（把 `ext:<spelling>` 收敛成正式 `w…`、清掉已回流的端侧缓存）
   **依赖「我知道词库换了」这个信号** —— 若新版恰好大小相同 → 判 `skipped`
   → **词库没更新 + 用户数据没收敛，且完全不报错**（静默双错）。

# 🔴 版本号必须是「纯内容函数」—— 不能含日期/生成时间

这是本脚本最容易写错的地方：

| 写法 | 后果 |
|---|---|
| ❌ `2026.10.01+11523`（含**生成日期**）| **同一份库，今天生成与明天生成得到不同版本** → 端侧每次都判「变了」→ **每天白白重落盘 31 MB** |
| ✅ `11523+a1b2c3d4`（纯内容派生）| **幂等**：内容不变 → 版本永远不变 → 端侧正确 skip |

> 🔑 一般化：**「版本号」只能是「被版本化对象的函数」**。
>    掺入「生成时间/环境」的那一刻，它就退化成「每次运行都不同」，失去判别能力。
>    （同族判据：**幂等的东西不能用时间当输入**。）

# 指纹要覆盖什么

| 要求 | 为什么 |
|---|---|
| **必须覆盖 `(id, spelling)` 映射** | 发版收敛靠「拿 `ext:` 里的拼写去新库查 id」→ **这条映射一变，收敛结果就变** |
| **不受 `VACUUM` / 页布局影响** | 取**逻辑内容**（逐行 `id:spelling` 串起来哈希），**不取文件字节** —— 否则 VACUUM 一次就误判成「词库更新」 |
| 大小相同、内容不同也能检出 | 这正是它**取代**「比大小」的理由 |

# 格式

```
<词数>+<映射哈希前 8 位>        例：11523+a1b2c3d4
```

不加 schema 前缀 —— 目前只有一种形态，加前缀属于**为假想的复杂度付费**。

# 用法

```bash
python scripts/gen_word_db_version.py            # 生成/刷新 data/word_db.version
python scripts/gen_word_db_version.py --check    # 只比对（CI / 提交前），不一致退 1
```

退出码：0 = 一致（或已生成）；1 = 不一致（`--check`）；2 = 出错
"""

import argparse
import hashlib
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')
OUT = os.path.join(ROOT, 'data', 'word_db.version')


def fingerprint(db_path):
    """返回 `(词数, 映射哈希前 8 位)`。

    🔑 只读 `word` 表的 `(id, spelling)` —— 这是**收敛依赖的唯一映射**。
    ⚠️ 为什么不用 `card.content` 之类：那与本机制的目的（收敛 + 落盘判定）无关，
       且会让指纹变贵。卡片内容变化通常伴随文件大小变化，由「大小」这路信号兜。
    """
    con = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    try:
        # `ORDER BY id` —— 保证同样的内容永远得到同样的串（数据库物理顺序不保证）
        rows = con.execute('SELECT id, spelling FROM word ORDER BY id').fetchall()
    finally:
        con.close()

    h = hashlib.md5()
    for wid, spelling in rows:
        h.update(f'{wid}:{spelling}\n'.encode('utf-8'))
    return len(rows), h.hexdigest()[:8]


def make_version(db_path):
    n, h = fingerprint(db_path)
    return f'{n}+{h}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=SRC_DB)
    ap.add_argument('--out', default=OUT)
    ap.add_argument('--check', action='store_true', help='只比对，不写文件')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    if not os.path.exists(args.db):
        sys.exit(f'🔴 词库不存在: {args.db}')

    want = make_version(args.db)

    if args.check:
        if not os.path.exists(args.out):
            sys.exit(f'🔴 版本文件不存在: {args.out}\n'
                     f'   → 跑一次不带 --check 即可生成')
        got = open(args.out, encoding='utf-8').read().strip()
        if got != want:
            print(f'🔴 版本不一致 —— 词库改了但版本没重新生成：')
            print(f'   现有 {args.out}: {got}')
            print(f'   实测 word.db  : {want}')
            print(f'   → 跑一次不带 --check 即可刷新（并记得同步 app/assets 副本）')
            return 1
        if not args.quiet:
            print(f'✅ 版本一致: {want}')
        return 0

    old = open(args.out, encoding='utf-8').read().strip() if os.path.exists(args.out) else '(无)'
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(want + '\n')       # 🔴 行尾显式 LF（本仓库 pin 过行尾口径）
    if not args.quiet:
        print(f'✅ 已生成 {args.out}')
        print(f'   {old} → {want}')
        if old == want:
            print('   （内容未变 —— 版本号**幂等**，这正是它该有的行为）')
        print('   ⚠️ 还需同步副本：python scripts/sync_word_db_asset.py')
    return 0


if __name__ == '__main__':
    sys.exit(main())
