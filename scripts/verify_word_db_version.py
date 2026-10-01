#!/usr/bin/env python3
"""`gen_word_db_version.py` 的独立验收 —— **版本指纹真的能判别内容变化吗？**

# 为什么需要它

版本指纹的价值全在「**内容变了它就变、内容没变它就不变**」这一个性质上。
若这个性质不成立，整套「发版收敛」的触发就会失效：
- **不敏感**（内容变了版本不变）→ 端侧判 `skipped` → **词库不更新 + 数据不收敛**（静默双错）
- **过敏**（内容没变版本也变）→ 端侧每次启动白复制 31 MB

两条都不报错，只能靠断言发现。

# 做法：用**临时副本**做破坏性验证（不碰源库）

| # | 项 | 期望 |
|---|---|---|
| 1 | 幂等 | 同一库跑两次 → 同版本 |
| 2 | 敏感性 | 改一个 `spelling` → 版本**必须变** |
| 3 | 敏感性（加词）| 追加一个词 → 版本**必须变** |
| 4 | 抗物理重排 | 模拟 VACUUM（重建库、行序变）→ 版本**不变** |
| 5 | 一致性 | `data/word_db.version` 与当前 `word.db` 相符 |

⚠️ 第 4 项最容易做错：直接比**文件字节**的实现在这里会红 ——
   而 VACUUM 是常规维护动作（本项目就跑过），不该被当成「词库更新」。

用法：`python scripts/verify_word_db_version.py`
"""

import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')
GEN = os.path.join(ROOT, 'scripts', 'gen_word_db_version.py')

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


def version_of(db):
    """跑 gen 脚本的 `--check` 拿期望值 —— 不重复实现指纹逻辑（避免两处定义）。"""
    r = subprocess.run(
        [sys.executable, GEN, '--db', db, '--out', _TMP_OUT, '--quiet'],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'gen 脚本失败: {r.stdout} {r.stderr}')
    return open(_TMP_OUT, encoding='utf-8').read().strip()


_TMP_OUT = ''


def main():
    global _TMP_OUT
    if not os.path.exists(SRC_DB):
        sys.exit(f'🔴 源库不存在: {SRC_DB}')

    work = tempfile.mkdtemp(prefix='coevo_ver_')
    _TMP_OUT = os.path.join(work, 'out.version')
    db = os.path.join(work, 'word.db')
    shutil.copy2(SRC_DB, db)          # 🔴 全程在副本上操作，源库一行不碰

    print('\n【1】幂等：同一份库跑两次')
    v1, v2 = version_of(db), version_of(db)
    check('两次结果相同', v1 == v2, f'{v1} vs {v2}')

    print('\n【2】🔴 敏感性：改一个 spelling → 版本**必须变**')
    con = sqlite3.connect(db)
    con.execute("UPDATE word SET spelling = 'zzz_modified' WHERE id = 'w000001'")
    con.commit()
    con.close()
    check('改拼写后版本变了（否则端侧会判 skipped → 词库不更新）',
          version_of(db) != v1, f'{version_of(db)} vs {v1}')

    print('\n【3】🔴 敏感性：追加一个词 → 版本**必须变**')
    con = sqlite3.connect(db)
    con.execute("UPDATE word SET spelling = 'absurd' WHERE id = 'w000001'")  # 还原
    con.execute(
        'INSERT INTO word (id, sort_seq, spelling, entry_type) VALUES (?,?,?,?)',
        ('w999999', 999999, 'zzz_appended', 'word'))
    con.commit()
    con.close()
    check('加词后版本变了', version_of(db) != v1, f'{version_of(db)} vs {v1}')

    print('\n【4】🔴 抗物理重排：模拟 VACUUM（行序变、内容同）→ 版本**不变**')
    con = sqlite3.connect(db)
    con.execute('DELETE FROM word WHERE id = ?', ('w999999',))     # 还原成原始内容
    con.commit()
    con.execute('VACUUM')
    # 再制造一次物理重排：整表重建（行序可能与原不同）
    con.execute('CREATE TABLE word_bak AS SELECT * FROM word')
    con.execute('DELETE FROM word')
    con.execute('INSERT INTO word SELECT * FROM word_bak ORDER BY spelling DESC')
    con.execute('DROP TABLE word_bak')
    con.commit()
    con.close()
    check('VACUUM + 行序重排后版本**不变**（否则每次维护都误判成更新）',
          version_of(db) == v1, f'{version_of(db)} vs {v1}')

    print('\n【5】与仓内版本文件一致（发版前提）')
    if os.path.exists(_TMP_OUT):
        os.remove(_TMP_OUT)
    r = subprocess.run([sys.executable, GEN, '--db', SRC_DB, '--check'],
                       capture_output=True, text=True)
    check('data/word_db.version 与 data/word.db 相符', r.returncode == 0,
          (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr) else '')

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
