#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""执行词表清理（Phase 1 #3/#4）—— 按分类清单从词表移除噪声词条。

⚠️ 本脚本**会修改** data/coevo.db。执行前自动备份。

范围（白哥 2026-09-25 批复）
---------------------------
  ✅ 执行      ① 撇号残留 3 + ② 纯垃圾 1 + ③ 专有名词(pos) 445
              + ④ 纯专有(释义) 352 + ⑤ 化学元素符号 5 = **806 条**
  ✅ 执行      **生僻缩写**（见 COMMON_ABBR 白名单之外的）
  ✅ 保留      **常用缩写**（白名单，学习者真会查的：单位/时间/头衔/常见机构）
  ⛔ 不动      ⑦ 多词短语 142 —— 有教学价值，划不到但可作条目（待后续定）
  ⛔ 不动      ⑧ 生僻短词 27  —— 待后续定
  ⛔ 不动      ⑨ 释义串位 33 / ⑩ 内容缺陷 42 —— **内容问题，保留待重新生成释义**
  ⛔ 不动      ⑪⑫ 兼类词 —— 有独立词义，必须保留

产物
----
  data/backups/coevo_before_vocab_cleanup_<ts>.db     数据库备份
  data/curriculum/prebuilt/vocab_cleanup_result.json  删除清单（可据此回滚）

用法
----
    python3 scripts/apply_vocab_cleanup.py --dry-run     # 只预览
    python3 scripts/apply_vocab_cleanup.py --apply       # 实际执行
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
NOISE = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'vocab_noise.json')
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')
RESULT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt', 'vocab_cleanup_result.json')

# ── 常用缩写白名单（白哥决策：常用缩写留）──────────────────────────
# 判据：**英语学习者/真实文本中会遇到的**
#   时间 (a.m./p.m./hr/min/est) · 单位 (cm/mg/ml/ft/lb/mph/btu/kwhr/hp)
#   头衔 (dr/mr./mrs./ms./sr) · 常见机构与通用 (fbi/cdc/nato/ibm/nyu/co/vs/esp/pc…)
# 不在名单内的 → 生僻缩写 → 删除
COMMON_ABBR = {
    # 时间
    'a.m.', 'p.m.', 'hr', 'min', 'est', 'mon',
    # 单位
    'cm', 'mg', 'ml', 'ft', 'lb', 'mph', 'btu', 'kwhr', 'hp', 'rpm',
    # 头衔
    'dr', 'dr.', 'mr.', 'mrs.', 'ms.', 'sr',
    # 常见机构 / 专名
    'fbi', 'cdc', 'nato', 'ibm', 'nyu', 'nbc', 'gnp', 'icbm', 'gop', 'pta',
    'cio', 'tnt', 'ap',
    # 通用
    'co', 'esp', 'vs', 'pc', 'pm', 'ne', 'nw', 'sw', 'va', 're', 'usp',
}


def load_targets() -> tuple[list[str], list[str], dict]:
    """返回 (必删词, 生僻缩写, 统计)。"""
    with open(NOISE, encoding='utf-8') as f:
        noise = json.load(f)

    must_del: set[str] = set()
    for cat, rows in noise['flagged_delete'].items():
        must_del |= {r['word'] for r in rows}

    abbr = [r['word'] for r in noise['needs_review']['abbreviation']]
    rare_abbr = [w for w in abbr if w not in COMMON_ABBR]
    kept_abbr = [w for w in abbr if w in COMMON_ABBR]

    stats = {
        'flagged_delete': {k: len(v) for k, v in noise['flagged_delete'].items()},
        'must_del': len(must_del),
        'abbr_total': len(abbr),
        'abbr_kept': len(kept_abbr),
        'abbr_deleted': len(rare_abbr),
        'kept_abbr_list': sorted(kept_abbr),
        'untouched': {
            'multiword_phrase': len(noise['needs_review']['multiword_phrase']),
            'rare_short': len(noise['needs_review']['rare_short']),
            'def_collision': len(noise['keep']['def_collision']),
            'content_gap': len(noise['keep']['content_gap']),
            'abbr_mixed': len(noise['keep']['abbr_mixed']),
            'proper_mixed': len(noise['keep']['proper_mixed']),
        },
    }
    return sorted(must_del), sorted(rare_abbr), stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true', help='实际执行（默认只预览）')
    ap.add_argument('--dry-run', action='store_true', help='只预览')
    args = ap.parse_args()
    do_apply = args.apply and not args.dry_run

    must_del, rare_abbr, stats = load_targets()
    targets = sorted(set(must_del) | set(rare_abbr))

    print('=' * 76)
    print('词表清理 · ' + ('实际执行' if do_apply else '预览（dry-run）'))
    print('=' * 76)
    print(f"{'类别':<26}{'数量':>7}")
    print('-' * 76)
    for k, v in stats['flagged_delete'].items():
        print(f"  {k:<24}{v:>7}")
    print(f"  {'— 可删小计':<24}{stats['must_del']:>7}")
    print()
    print(f"  {'缩写总数':<24}{stats['abbr_total']:>7}")
    print(f"  {'  ├ 常用（保留）':<24}{stats['abbr_kept']:>7}")
    print(f"  {'  └ 生僻（删）':<24}{stats['abbr_deleted']:>7}")
    print('-' * 76)
    print(f"  {'🔴 本次删除合计':<24}{len(targets):>7}")
    print()
    print('  ⛔ 不动（白哥未指示 / 属内容问题，非噪声）：')
    for k, v in stats['untouched'].items():
        print(f"     {k:<22}{v:>6}")

    print()
    print(f"  保留的常用缩写（{stats['abbr_kept']} 条）：")
    line = '  '
    for w in stats['kept_abbr_list']:
        if len(line) + len(w) + 2 > 74:
            print(line); line = '  '
        line += w + '  '
    if line.strip():
        print(line)

    # 校验目标是否都在词表中
    con = sqlite3.connect(DB)
    cur = con.cursor()
    placeholders = ','.join('?' * len(targets))
    found = [
        r[0] for r in cur.execute(
            f"SELECT front FROM prebuilt_cards WHERE subject='english' "
            f"AND card_type='vocabulary' AND front IN ({placeholders})", targets)
    ]
    print(f"\n  校验：{len(found)}/{len(targets)} 条在词表中找到")
    missing = sorted(set(targets) - set(found))
    if missing:
        print(f"  ⚠️ 未找到（跳过）：{missing[:10]}{'…' if len(missing) > 10 else ''}")

    if not do_apply:
        con.close()
        print('\n（预览模式，未修改任何数据。加 --apply 执行）')
        return

    # ── 备份 ──
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup = os.path.join(BACKUP_DIR, f'coevo_before_vocab_cleanup_{ts}.db')
    shutil.copy2(DB, backup)
    print(f'\n✅ 已备份 → {os.path.relpath(backup, ROOT)}')

    # ── 取 id ──
    ids = [
        r[0] for r in cur.execute(
            f"SELECT id FROM prebuilt_cards WHERE subject='english' "
            f"AND card_type='vocabulary' AND front IN ({placeholders})", targets)
    ]

    before_cards = cur.execute(
        "SELECT COUNT(*) FROM prebuilt_cards WHERE subject='english'").fetchone()[0]
    before_vocab = cur.execute(
        "SELECT COUNT(*) FROM prebuilt_cards WHERE subject='english' "
        "AND card_type='vocabulary'").fetchone()[0]

    ph = ','.join('?' * len(ids))
    cur.execute(f'DELETE FROM prebuilt_cards WHERE id IN ({ph})', ids)
    d1 = cur.rowcount
    cur.execute(f'DELETE FROM prebuilt_language_cards WHERE id IN ({ph})', ids)
    d2 = cur.rowcount
    con.commit()

    after_cards = cur.execute(
        "SELECT COUNT(*) FROM prebuilt_cards WHERE subject='english'").fetchone()[0]
    after_vocab = cur.execute(
        "SELECT COUNT(*) FROM prebuilt_cards WHERE subject='english' "
        "AND card_type='vocabulary'").fetchone()[0]

    print('\n' + '=' * 76)
    print('执行结果')
    print('=' * 76)
    print(f"  prebuilt_cards 删除          : {d1}")
    print(f"  prebuilt_language_cards 删除 : {d2}")
    print()
    print(f"  english 卡片 : {before_cards:,} → {after_cards:,}")
    print(f"  词表词条     : {before_vocab:,} → {after_vocab:,}")

    # 写结果清单（可据此回滚）
    with open(RESULT, 'w', encoding='utf-8') as f:
        json.dump({
            '_meta': {
                'executed_at': datetime.now().isoformat(timespec='seconds'),
                'backup': os.path.relpath(backup, ROOT),
                'deleted_total': d1,
                'before_vocab': before_vocab,
                'after_vocab': after_vocab,
            },
            'deleted': {
                'flagged_delete': {k: [r['word'] for r in v]
                                   for k, v in json.load(open(NOISE, encoding='utf-8'))['flagged_delete'].items()},
                'rare_abbreviation': rare_abbr,
            },
            'kept_abbreviation': stats['kept_abbr_list'],
        }, f, ensure_ascii=False, indent=2)
    print(f"\n✅ 删除清单 → {os.path.relpath(RESULT, ROOT)}")
    con.close()


if __name__ == '__main__':
    main()
