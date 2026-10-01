#!/usr/bin/env python3
"""`word_db_id_snapshot.py` 的独立验收 —— **快照真的能抓到破坏吗？**

# 为什么需要它

快照的价值全在「**破坏 id 稳定性时它必须报红**」。若它「永远为绿」，
就是一层**假保护** —— 比没有更糟（会让人以为有防线）。

三类变更的期望（与 `word_db_id_snapshot.py` 的判定一致）：

| 变更 | 期望退出码 | 为什么 |
|---|---|---|
| **纯新增** | **0** ✅ | 正常演进（回流就是它）|
| **无变化** | **0** ✅ | |
| **删除 id** | **1** 🔴 | 老用户记录指向不存在的词 |
| **改写 spelling** | **1** 🟠 | 端侧冗余值脱节 + 收敛结果改变 |

⚠️ 全程在**临时副本**上操作，源库一行不碰。

用法：`python scripts/verify_word_db_id_snapshot.py`
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')
TOOL = os.path.join(ROOT, 'scripts', 'word_db_id_snapshot.py')

_passed = 0
_failed = []


def check(label, ok, detail=''):
    global _passed
    if ok:
        _passed += 1
        print(f'  ✅ {label}{"" if not detail else f"  ({detail})"}')
    else:
        _failed.append(label)
        print(f'  🔴 {label}{"" if not detail else f"  ({detail})"}')


def run_tool(db, snapshot):
    """跑 `--check`，返回 (退出码, 输出)。"""
    r = subprocess.run(
        [sys.executable, TOOL, '--db', db, '--snapshot', snapshot, '--check'],
        capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def main():
    if not os.path.exists(SRC_DB):
        sys.exit(f'🔴 源库不存在: {SRC_DB}')

    work = tempfile.mkdtemp(prefix='coevo_idsnap_')
    db = os.path.join(work, 'word.db')
    snap = os.path.join(work, 'snap.json')
    shutil.copy2(SRC_DB, db)                       # 🔴 只在副本上操作

    # 用「当前副本」建基准
    subprocess.run([sys.executable, TOOL, '--db', db, '--snapshot', snap, '--write'],
                   capture_output=True, text=True, check=True)

    print('\n【1】无变化 → 应绿')
    code, out = run_tool(db, snap)
    check('退出码 0', code == 0, f'code={code}')

    print('\n【2】🔴 删除一个 id → 必须红')
    con = sqlite3.connect(db)
    con.execute("DELETE FROM word WHERE id = 'w000001'")
    con.commit()
    con.close()
    code, out = run_tool(db, snap)
    check('退出码 1（否则「删 id」这层保护是假的）', code == 1, f'code={code}')
    check('输出点出「删除」', '删除' in out, out.splitlines()[1] if len(out.splitlines()) > 1 else '')
    check('且指出违的是「id 永久不变」', '永久不变' in out)

    # 还原
    shutil.copy2(SRC_DB, db)

    print('\n【3】🟠 改写 spelling → 必须红')
    con = sqlite3.connect(db)
    con.execute("UPDATE word SET spelling = 'zzz_renamed' WHERE id = 'w000002'")
    con.commit()
    con.close()
    code, out = run_tool(db, snap)
    check('退出码 1（否则「改拼写」这层保护是假的）', code == 1, f'code={code}')
    check('输出点出「改写」', '改写' in out)
    check('且给出前后值', "'achieve'" in out and "'zzz_renamed'" in out)

    shutil.copy2(SRC_DB, db)

    print('\n【4】✅ 纯新增 → 应绿（正常演进不能被误判为破坏）')
    con = sqlite3.connect(db)
    con.execute('INSERT INTO word (id, sort_seq, spelling, entry_type) VALUES (?,?,?,?)',
                ('w999999', 999999, 'zzz_new', 'word'))
    con.commit()
    con.close()
    code, out = run_tool(db, snap)
    check('退出码 0', code == 0, f'code={code}')
    check('输出标为「新增」且说明允许', '新增' in out and '允许' in out)

    print('\n【5】真实仓库状态：基准与当前 word.db 必须一致')
    code, out = run_tool(SRC_DB, os.path.join(ROOT, 'data', 'word_db_id_snapshot.json'))
    check('退出码 0（若红，说明 word.db 相对基准有破坏性变更，须先查清）',
          code == 0, out.splitlines()[-1] if out else '')

    shutil.rmtree(work, ignore_errors=True)

    print('\n' + '═' * 62)
    if _failed:
        print(f'通过 {_passed} 项，**失败 {len(_failed)} 项**')
        for f in _failed:
            print(f'  🔴 {f}')
        return 1
    print(f'✅ 全部通过：{_passed} 项')
    return 0


if __name__ == '__main__':
    sys.exit(main())
