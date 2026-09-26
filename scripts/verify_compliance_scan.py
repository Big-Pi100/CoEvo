#!/usr/bin/env python3
"""合规扫描器验收 —— 证明它**既不漏也不误报**

## 为什么需要「假的」测试数据

合规扫描器有两种失败，**方向相反，都会造成实害**：

| 失败 | 后果 |
|---|---|
| **漏报**（该报没报） | 🔴 违规内容上线 → 合规风险（不可逆） |
| **误报**（不该报却报） | 🟠 报告淹没在噪音里 → 真问题被忽略；或误改正常内容 |

而**只有真库是验不出误报的**（我们不知道真库里有几条「本该不报」）。
所以本脚本**手工构造两组用例**：

- **正例（MUST_CATCH）**：明确的违规内容 —— 全来自真库实际发现的问题
- **负例（MUST_NOT_CATCH）**：看起来像但**不是**违规的内容 —— 全来自首版真实的误报

## 历史真实误报（本脚本锁住它们，防回归）

| 误报 | 根因 |
|---|---|
| `grape` / `scraped` / `drapery` 命中 `rape` | **裸子串匹配**（g**rape**、sc**rape**d、d**rape**ry） |
| `schooner` 命中 `coon` | 子串（s**coon**er） |
| `independent` 例句 "India became an independent nation in 1947" | 未限定主体（印度独立是史实） |
| `hanover` "Hanover was once an independent kingdom" | 同上（汉诺威史实） |
| `massacre` / `rape` 的例句 | **词条本身就是该词**，解释它是正确的 |
| `nigger` 词条 | 已标注 "derogatory, offensive" → 正确行为 |
| `tibet` 修正后的「**an autonomous region … of China**」 | 🔴 **官方行政区划名被当成主权主张**（铁律 5）—— 判据方向反了 |

## 用法

    python3 scripts/verify_compliance_scan.py [--db data/word.db]

退出码 0/1 可挂 CI。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scan_compliance import load_records, scan_record  # noqa: E402

_pass = _fail = 0
_failures = []


def check(desc, cond, detail=''):
    global _pass, _fail
    if cond:
        _pass += 1
        print(f'  ✅ {desc}' + (f'   [{detail}]' if detail else ''))
    else:
        _fail += 1
        _failures.append(desc)
        print(f'  🔴 {desc}' + (f'   [{detail}]' if detail else ''))


def mk(spelling, **sections):
    """构造一条记录。`sections` 形如 definition_en='...', context_text='...'"""
    secs = []
    for k, v in sections.items():
        if k.startswith('definition_'):
            secs.append({'type': 'definition', k.split('_', 1)[1]: v})
        elif k.startswith('context_'):
            secs.append({'type': 'context', k.split('_', 1)[1]: v})
    return {'id': 'test', 'spelling': spelling, 'entry_type': 'word',
            'etymology_text': None, 'card': {'sections': secs}}


def levels_of(rec):
    return sorted({f[0] for f in scan_record(rec)})


def reasons_of(rec):
    return ' | '.join(f[4] for f in scan_record(rec))


# ─────────────────────────────────────────────────────────────
# 🔴 正例：必须抓到（全部来自真库实际发现）
# ─────────────────────────────────────────────────────────────
MUST_CATCH = [
    ('台湾「self-governing democracy」',
     mk('taiwan', definition_en='An island in East Asia that is a self-governing democracy.'),
     'P0', '涉主权'),
    ('西藏「historically an independent kingdom」',
     mk('tibet', definition_en='a region in central Asia, on the Tibetan Plateau; historically an independent kingdom, now an autonomous region of China.'),
     'P0', '涉主权'),
    ('西藏「independent kingdom」（主体触发）',
     mk('tibet', definition_en='on the Tibetan Plateau; an independent kingdom in history.'),
     'P0', '涉主权'),
    ('分裂主义措辞（无条件）',
     mk('someword', definition_en='a separatist movement in the region.'),
     'P0', '涉主权'),
    ('把中国领土说成「occupied territory」',
     mk('someword', definition_en='Tibet was an occupied territory.'),
     'P0', '涉主权'),
    ('「China claims ...」表述',
     mk('someword', definition_en='China claims the island as its territory.'),
     'P0', '涉主权'),
    ('敏感词出现在**别的词**且无标注',
     mk('neutralword', definition_en='a term of abuse like nigger used rudely.'),
     'P0', '涉歧视'),
    ('政治主体 + 定性词',
     mk('someword', definition_en='the tiananmen square massacre happened.'),
     'P0', '涉政'),
    ('敏感词条但**未标注**冒犯性 → P1',
     mk('cripple', definition_en='to cause someone to be unable to walk.'),
     'P1', '涉歧视'),
]

# ─────────────────────────────────────────────────────────────
# ✅ 负例：**绝不**该报（全部来自首版真实误报）
# ─────────────────────────────────────────────────────────────
MUST_NOT_CATCH = [
    ('grape 不应命中 rape（子串）',
     mk('grape', definition_en='a small round fruit with a smooth skin.')),
    ('scraped 不应命中 rape（子串）',
     mk('scrape', context_text='He fell and scraped his knee.')),
    ('drapery 不应命中 rape（子串）',
     mk('drapery', context_text='The heavy drapery blocked out the sunlight.')),
    ('schooner 不应命中 coon（子串）',
     mk('schooner', definition_en='a sailing ship with two or more masts.')),
    ('独立国 ≠ 涉主权（印度是史实）',
     mk('independent', context_text='India became an independent nation in 1947.')),
    ('独立王国 ≠ 涉主权（汉诺威是史实）',
     mk('hanover', context_text='Hanover was once an independent kingdom.')),
    ('massacre 词条自身的例句',
     mk('massacre', context_text='The massacre of civilians shocked the world.')),
    ('rape 词条自身的例句',
     mk('rape', context_text='She was a victim of rape.')),
    ('terrorist 词条自身的例句',
     mk('terrorist', context_text='The police arrested a terrorist who planned to attack.')),
    ('prostitution 词条自身的例句',
     mk('prostitution', context_text='Prostitution is illegal in many countries.')),
    ('narcotics 词条自身的例句',
     mk('narcotics', definition_en='illegal substances such as heroin or cocaine.')),
    ('nigger 词条**已标注**冒犯性 → 正确行为',
     mk('nigger', definition_en='(derogatory, offensive) a racial slur for a black person.')),
    ('retard **有正常义**（延缓）',
     mk('retard', definition_en='to delay or slow down progress.', context_text='The cold weather retarded the crops.')),
    ('faget 标注了 archaic（捆柴义）',
     mk('faget', definition_en='variant spelling of faggot (archaic: a bundle of sticks).')),
    ('massacre 出现在中性词例句（P1 可接受，但不得是 P0）',
     mk('appall', context_text='The news of the massacre appalled the world.')),
    ('正常词汇不应有任何发现',
     mk('apple', definition_en='a round fruit with red or green skin.')),
    ('正常短语不应有任何发现',
     mk('receive', definition_en='to get or be given something.', context_text='I received your letter.')),
]

# ─────────────────────────────────────────────────────────────
# ✅ 强化负例：**必须零发现**（连 P1 都不许有）
#
# 与 MUST_NOT_CATCH 的区别：那一组只断言「不得是 P0」（允许 P1 待复核）；
# 这一组是「**正确的官方表述**」—— 一条发现都不该有。
# ─────────────────────────────────────────────────────────────
MUST_BE_SILENT = [
    ('tibet「an autonomous region … of China」＝ 正确表述（铁律 5）',
     mk('tibet', definition_en='An autonomous region in southwestern China, on the Tibetan Plateau. '
                               'Tibet has been a part of China since ancient times.')),
    ('taiwan「a part of China」＝ 正确表述',
     mk('taiwan', definition_en='An island off the southeast coast of China. '
                                'Taiwan is a part of China.')),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'data', 'word.db'))
    args = ap.parse_args()

    print('═' * 68)
    print('合规扫描器验收')
    print('═' * 68)

    # ── ① 正例：必须抓到 ──
    print(f'\n【1】正例（必须抓到）—— {len(MUST_CATCH)} 项')
    for desc, rec, want_lvl, want_cat in MUST_CATCH:
        found = scan_record(rec)
        lvls = {f[0] for f in found}
        cats = {f[1] for f in found}
        ok = want_lvl in lvls and want_cat in cats
        check(desc, ok,
              f'期望 {want_lvl}/{want_cat}，实得 {sorted(lvls)}/{sorted(cats)}'
              if not ok else f'{want_lvl}/{want_cat}')
        if not ok:
            print(f'       实际发现: {found}')

    # ── ② 负例：绝不该报 ──
    print(f'\n【2】负例（绝不该报）—— {len(MUST_NOT_CATCH)} 项')
    for desc, rec in MUST_NOT_CATCH:
        found = scan_record(rec)
        # 「P1 可接受但不得是 P0」的特例：appall 提 massacre
        hard = [f for f in found if f[0] == 'P0']
        ok = not hard
        check(desc, ok, f'误报 P0 {len(hard)} 处: {[f[4] for f in hard]}' if not ok else '无误报 P0')
        if not ok:
            print(f'       实际发现: {hard}')

    # ── ②b 强化负例：**必须零发现**（连 P1 都不许有）──
    print(f'\n【2b】强化负例（连 P1 都不许有）—— {len(MUST_BE_SILENT)} 项')
    for desc, rec in MUST_BE_SILENT:
        found = scan_record(rec)
        check(desc, not found,
              f'实得 {[(f[0], f[4]) for f in found]}' if found else '零发现')

    # ── ③ 真库回归：P0 **必须为空**（零容忍 —— 上线要求）──
    if os.path.exists(args.db):
        print('\n【3】真库回归（P0 必须为空 —— 零容忍）')
        import sqlite3
        con = sqlite3.connect(args.db)
        recs = load_records(con)
        con.close()
        p0_words = sorted({r['spelling'] for r in recs
                           if any(f[0] == 'P0' for f in scan_record(r))})
        check('P0 词的集合 == 空集', p0_words == [], f'实测 {p0_words}')
        n_p0 = sum(1 for r in recs for f in scan_record(r) if f[0] == 'P0')
        check('P0 总数 == 0', n_p0 == 0, f'实测 {n_p0}')
        n_p1 = sum(1 for r in recs for f in scan_record(r) if f[0] == 'P1')
        print(f'        ℹ️  P1 = {n_p1}（需人工复核，不阻塞上线）')
        check('扫描全库不抛异常（11,523 词跑完）', len(recs) > 11000, f'{len(recs):,} 词')
    else:
        print(f'\n【3】跳过真库回归（{args.db} 不存在）')

    print('\n' + '=' * 68)
    print(f'通过 {_pass} 项，失败 {_fail} 项')
    if _fail:
        print('\n失败项：')
        for f in _failures:
            print(f'  🔴 {f}')
        sys.exit(1)
    print('✅ 合规扫描器既不漏（正例全中）也不误报（负例全过）')
    sys.exit(0)


if __name__ == '__main__':
    main()
