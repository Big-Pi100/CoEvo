#!/usr/bin/env python3
"""在线制卡缓存 · 合规审计（词表变更后的配套运维工具）

## 为什么需要它

在线制卡（`POST /api/generate-card`）**只在「生成时」过合规闸门**
（Rust `api_server/src/compliance.rs`）；**缓存命中路径不再复检**。
于是存在一个窗口：

    T0  某词生成 → 过闸门 → 写进 `generated_card_cache`
    T1  词表**被改宽**（新增敏感词/收紧规则）→ 这条老缓存在新规则下其实违规
    T2  用户查该词 → **命中缓存直出** → 违规内容发给用户

→ 所以**每次实质修改 `compliance_terms.json` 之后**，都要跑一次本脚本。

## 判据（与 Rust 同口径）

| 关注点 | 做法 |
|---|---|
| 词表 | 读**同一份** `backend/prompts/compliance_terms.json` |
| 规则引擎 | import `scripts/scan_compliance.py::scan_parts`（**不复制**） |
| 卡 → (字段名, 文本) | 本文件 `collect_parts`，与 Rust `compliance.rs::collect_parts` **逐条对齐** |
| 🔑 适配层对不对 | 启动时先跑 **`compliance_cases.json` 的 `card_cases`** 自检；不通过就**拒绝出报告**（适配错了 → 报告不可信） |

🔑 「适配层自检」是关键：规则再准，**扫错字段**也等于没扫。
   这层最容易两侧漂（Rust 是类型安全递归，这里是脚本）→ 用共享用例锁住。

## 用法

    python3 scripts/audit_generated_card_cache.py                 # 只报告（默认）
    python3 scripts/audit_generated_card_cache.py --json out.json # 附 JSON 报告
    python3 scripts/audit_generated_card_cache.py --purge --yes    # 🔴 删除违规缓存行

退出码：有 P0 → 1；否则 0。（`--purge` 之后重新计算，全清则 0。）
"""
import argparse
import importlib.util
import json
import os
import sqlite3
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(ROOT, 'backend', 'data', 'coevo.db')
SCANNER = os.path.join(ROOT, 'scripts', 'scan_compliance.py')
CASES = os.path.join(ROOT, 'backend', 'prompts', 'compliance_cases.json')

#: 本脚本只关心 P0（业务级「不可上线」）；P1/P2 只统计不阻塞
BLOCKING = {'P0'}


# ─────────────────────────────────────────────────────────────
# 卡 → (字段名, 文本)   🔴 与 Rust `compliance.rs::collect_parts` 逐条对齐
# ─────────────────────────────────────────────────────────────
def collect_parts(v, path, out):
    """递归收集卡里所有**字符串**，给出 `(字段名, 文本)`。

    字段名规则（与 Rust 完全一致）：
      · 路径本身以 `.en` / `.zh` / `.text` 结尾 → 原样（如 `definition.en`）
      · 顶层 `word` → `spelling`
      · **其余一律补 `.text`** —— 在线卡整张都给用户看，未知字段也不许漏扫
      · 非字符串（数字/布尔/null）→ 不进扫描面
    """
    if isinstance(v, str):
        if not v.strip():
            return
        if path == 'word':
            label = 'spelling'
        elif path.endswith(('.en', '.zh', '.text')):
            label = path
        else:
            label = path + '.text'
        out.append((label, v))
    elif isinstance(v, list):
        for i, x in enumerate(v):
            p = str(i) if path == '' else '{}.{}'.format(path, i)
            collect_parts(x, p, out)
    elif isinstance(v, dict):
        # sorted：Rust 侧 serde_json 的 Map 默认是 BTreeMap（字典序）→ 保持同序
        for k in sorted(v.keys()):
            p = k if path == '' else '{}.{}'.format(path, k)
            collect_parts(v[k], p, out)
    # 其它类型（int/float/bool/None）→ 忽略


def scan_card(sc, card, spelling):
    """扫一张在线卡 → 发现列表（与 Rust `compliance.rs::scan_card` 同口径）。"""
    parts = [('spelling', spelling)]
    collect_parts(card, '', parts)
    return sc.scan_parts(parts, spelling)


# ─────────────────────────────────────────────────────────────
# 载入
# ─────────────────────────────────────────────────────────────
def load_scanner():
    spec = importlib.util.spec_from_file_location('scan_compliance', SCANNER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def selfcheck_card_cases(sc):
    """跑共享用例的 `card_cases` → 校验「卡适配层」两侧一致。

    🔴 不通过就拒绝出报告：适配错了，报告里的「合规/违规」都不可信。
    """
    with open(CASES, encoding='utf-8') as f:
        doc = json.load(f)
    cases = doc.get('card_cases') or []
    # 第一条是 `_why` 说明（无 id），跳过
    cases = [c for c in cases if 'id' in c]
    if not cases:
        return False, ['compliance_cases.json 里没有 card_cases —— 适配层未被校验']

    fails = []
    for c in cases:
        got = sorted([lvl, cat, fld]
                     for lvl, cat, fld, _s, _w in scan_card(sc, c['card'], c['spelling']))
        exp = sorted(list(t) for t in c['expect'])
        if got != exp:
            fails.append('  ✗ {}\n      期望 {}\n      实际 {}'.format(c['id'], exp, got))
    return not fails, fails


# ─────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description='在线制卡缓存 · 合规审计')
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--json', dest='json_out')
    ap.add_argument('--purge', action='store_true', help='删除违规（P0）缓存行')
    ap.add_argument('--yes', action='store_true', help='--purge 的确认开关（防误删）')
    ap.add_argument('--limit', type=int, default=0, help='每级最多显示条数（0=全部）')
    args = ap.parse_args()

    sc = load_scanner()

    # ① 适配层自检（不过 → 拒绝出报告）
    ok, fails = selfcheck_card_cases(sc)
    if not ok:
        print('🔴 卡适配层自检**未通过** —— 报告不可信，先修 `collect_parts`：\n')
        print('\n'.join(fails))
        print('\n（本脚本的 collect_parts 必须与 `backend/crates/api_server/src/compliance.rs` 同口径）')
        return 2
    print('✅ 卡适配层自检通过（与 Rust 侧共享用例一致）')

    if not os.path.exists(args.db):
        print('找不到库 {}'.format(args.db))
        return 1
    con = sqlite3.connect(args.db)
    has = con.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='generated_card_cache'"
    ).fetchone()[0]
    if not has:
        # ⚠️ 不是错误：老库 / 还没跑过新版后端时，本表不存在 = 无事可做
        print('ℹ️  {} 里没有 `generated_card_cache` 表 —— 尚未有在线制卡缓存，无需审计'.format(args.db))
        con.close()
        return 0

    rows = con.execute(
        "SELECT spelling, card_content, contract_version, hit_count, updated_at "
        "FROM generated_card_cache ORDER BY spelling"
    ).fetchall()
    print('库 {} · 缓存 {} 条'.format(args.db, len(rows)))

    findings = []       # (spelling, level, cat, field, reason)
    broken = []         # 内容不是合法 JSON 的行
    for spelling, content, contract, hits, updated in rows:
        try:
            card = json.loads(content)
        except Exception as e:
            broken.append((spelling, str(e)))
            continue
        for lvl, cat, fld, _snip, reason in scan_card(sc, card, spelling):
            findings.append((spelling, lvl, cat, fld, reason))

    p0 = [f for f in findings if f[1] in BLOCKING]
    by_level = Counter(f[1] for f in findings)
    print()
    print('═══ 结果 ═══')
    print('  P0（必须清）: {:>4}'.format(by_level.get('P0', 0)))
    print('  P1（复核）  : {:>4}'.format(by_level.get('P1', 0)))
    print('  P2（提示）  : {:>4}'.format(by_level.get('P2', 0)))
    if broken:
        print('  ⚠️ 内容非合法 JSON: {} 条（这些卡会 500 —— 见下）'.format(len(broken)))

    if p0:
        print()
        print('═══ P0 明细（{} 条 · 涉及 {} 个词）═══'.format(len(p0), len({f[0] for f in p0})))
        shown = p0 if not args.limit else p0[:args.limit]
        for sp, lvl, cat, fld, reason in shown:
            print('  [{}] {}  ({})'.format(cat, sp, fld))
            print('      {}'.format(reason))
        if args.limit and len(p0) > args.limit:
            print('  … 另有 {} 条'.format(len(p0) - args.limit))

    if broken:
        print()
        print('═══ 内容损坏（{} 条）═══'.format(len(broken)))
        for sp, err in broken if not args.limit else broken[:args.limit]:
            print('  {} — {}'.format(sp, err[:80]))

    if args.json_out:
        with open(args.json_out, 'w', encoding='utf-8') as f:
            json.dump({
                'db': args.db,
                'total': len(rows),
                'by_level': dict(by_level),
                'broken': [{'spelling': s, 'error': e} for s, e in broken],
                'findings': [{'spelling': s, 'level': l, 'category': c,
                              'field': fl, 'reason': r} for s, l, c, fl, r in findings],
            }, f, ensure_ascii=False, indent=1)
        print('\n已写 {}'.format(args.json_out))

    # ── purge ──
    if args.purge:
        targets = sorted({f[0] for f in p0} | {s for s, _ in broken})
        if not targets:
            print('\n✅ 无需清除')
            con.close()
            return 0
        print()
        print('🔴 --purge 将删除 {} 条缓存行：'.format(len(targets)))
        for sp in targets if not args.limit else targets[:args.limit]:
            print('    {}'.format(sp))
        if args.limit and len(targets) > args.limit:
            print('    … 另有 {} 条'.format(len(targets) - args.limit))
        if not args.yes:
            print('\n⚠️ 这只是预览 —— 加 `--yes` 才真的删（建议先跑 scripts/backup-db.sh）')
            con.close()
            return 1
        for sp in targets:
            con.execute('DELETE FROM generated_card_cache WHERE spelling = ?', (sp,))
            con.execute('DELETE FROM generated_card_hit WHERE spelling = ?', (sp,))
        con.commit()
        print('\n✅ 已删除 {} 行（含命中登记）'.format(len(targets)))
        left = con.execute('SELECT COUNT(*) FROM generated_card_cache').fetchone()[0]
        print('   剩余缓存 {} 条'.format(left))
        con.close()
        return 0

    con.close()
    print()
    if p0 or broken:
        print('🔴 有 {} 条 P0 + {} 条损坏 —— 建议 `--purge --yes`（先备份）'.format(len(p0), len(broken)))
        return 1
    print('✅ 缓存全部通过合规检查')
    return 0


if __name__ == '__main__':
    sys.exit(main())
