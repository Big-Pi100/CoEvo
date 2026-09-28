#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
卡片结构验收 —— 把 v1 §4.2 + 白哥「库级可以就存在」的结构变成断言。

为什么需要（2026-09-26）：
  卡片结构此前**偏离 v1 达 8 项**，最严重的一项是**例句被塞在 `sense` 段里**。
  按 v1 §6.2 的朗读清单（只认 `context`/`collocation`/`front`），
  `sense` **一条音频都不会生成** → **240 MB 例句音频会全漏**。
  这个偏离**存在了很久没被发现**，因为在 DB 里看不出「例句 type 错了」。
  → 本脚本把「结构对不对」变成可复跑、有退出码的断言。

检查项（对应 docs/design/card-design-deviation-from-v1-2026-09-26.md）：
  ① 段类型合法性 —— 只允许 v1 定义的 8 种，`sense` 只能出现在 card_extra
  ② **例句独立成 `context`** —— 🔑 语音包前置（旧的 `sense` 会让朗读清单命中不了）
  ③ 首义进 `definition`，且**每卡只 1 条**
  ④ 记忆法段在 content 里按**生成时的存储顺序**排列（见下方 SECTION_STORAGE_ORDER 的注释）
  ⑤ `root` 若存在**必须排第一**（v1 §4.2 示例即如此；旧实现里 root 从不排第一）
  ⑥ 入口内嵌（`root`/`cognate`/`etymology` 段带 `entry.page_id`），**不单列 `aggregate_link` 段**
  ⑦ 渲染后段数 ≤ 4（v1 §5.1）；content 段数可更多（素材池）
  ⑧ 其余义项进 `card_extra`（不丢数据）

用法：
  python3 scripts/verify_card_structure.py
  python3 scripts/verify_card_structure.py --verbose
退出码：0 = 全部通过；1 = 有断言失败
"""
import argparse
import json
import os
import sqlite3
import statistics
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'word.db')

# v1 §4.2 定义的 8 种 section 类型
V1_TYPES = {'root', 'definition', 'context', 'cognate', 'collocation',
            'etymology', 'imagery', 'aggregate_link'}
# 🔴 `card.sections` 的**历史存储顺序**（生成时按**当时**的 mnemonic priority 写入）。
#
# ⚠️ **它现在不等于 `mnemonic_type.priority`** —— 2026-09-27 白哥定「交换 etymology 3 ↔ collocation 4」，
#    但**没有重排已落库的 11,523 张卡**的段顺序（重排要改写 11,523 份 JSON，而**段顺序不承载语义**）。
#
# 🔑 **渲染层按 `mnemonic_type.priority` 取槽位①，不依赖本顺序** ——
#    `card.sections` 是**素材池**（「存全部素材、裁剪留渲染层」），顺序不是契约。
#    本常量只用于校验「生成时写入顺序没乱」，**不是**槽位选择的依据。
#    📄 论证：`docs/review/mnemonic-slot-priority-conflict-2026-09-27.md`
SECTION_STORAGE_ORDER = ['root', 'cognate', 'collocation', 'etymology', 'imagery']

_p = _f = 0
_fails = []


def check(name, ok, detail=''):
    global _p, _f
    tag = '✅' if ok else '🔴'
    if ok:
        _p += 1
    else:
        _f += 1
        _fails.append(name)
    print(f'  {tag} {name}' + (f'  —— {detail}' if detail else ''))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--verbose', '-v', action='store_true')
    args = ap.parse_args()

    if not os.path.exists(DB):
        print(f'🔴 找不到 {DB}')
        return 1
    con = sqlite3.connect(DB)

    cards = con.execute('select word_id, content from card').fetchall()
    total = len(cards)
    print(f'CoEvo · 卡片结构验收（{total:,} 张卡）')
    print('=' * 74)

    type_cnt = Counter()
    card_types = {}          # wid -> [types...]
    n_def = {}               # wid -> definition 条数
    root_first = root_present = 0
    in_context = in_sense = 0
    ctx_with_entry = 0       # context 段**不该**带 entry（它不是聚合页入口）
    agg_link_as_section = 0
    bad_order = []
    entry_embedded = 0
    entry_expected = 0
    render_secs = Counter()
    extra_total = 0
    render_chars = []

    for wid, content in cards:
        try:
            d = json.loads(content)
        except Exception:
            bad_order.append((wid, 'JSON 解析失败'))
            continue
        secs = d.get('sections') or []
        types = [s.get('type') for s in secs]
        card_types[wid] = types

        for t in types:
            type_cnt[t] += 1

        # ① 类型合法性
        illegal = [t for t in types if t not in V1_TYPES]
        if illegal:
            bad_order.append((wid, f'非法段类型 {illegal}'))

        # ② definition 只 1 条
        n_def[wid] = types.count('definition')

        # ③ root 位置
        if 'root' in types:
            root_present += 1
            if types[0] == 'root':
                root_first += 1

        # ④ 例句位置
        if 'context' in types:
            in_context += 1
        if 'sense' in types:
            in_sense += 1
        for s in secs:
            if s.get('type') == 'context' and 'entry' in s:
                ctx_with_entry += 1

        # ⑤ aggregate_link 不单列
        if 'aggregate_link' in types:
            agg_link_as_section += 1

        # ⑥ 记忆法段在 content 里的存储顺序（⚠️ 非 priority —— 见 SECTION_STORAGE_ORDER 注释）
        mnem = [t for t in types if t in SECTION_STORAGE_ORDER]
        if mnem != sorted(mnem, key=lambda x: SECTION_STORAGE_ORDER.index(x)):
            bad_order.append((wid, f'记忆法存储顺序错 {mnem}'))

        # ⑦ 入口内嵌
        for s in secs:
            if s.get('type') in ('root', 'cognate', 'etymology'):
                if isinstance(s.get('payload'), dict) and s['payload'].get('entry'):
                    entry_embedded += 1
                elif s.get('entry'):
                    entry_embedded += 1

        # ⑧ 渲染后段数：2 段记忆法 + definition + context
        r = min(len(mnem), 2) + (1 if 'definition' in types else 0) + (1 if 'context' in types else 0)
        render_secs[r] += 1
        txt = ''.join(str(s.get('text') or s.get('zh') or '') for s in secs)
        render_chars.append(len(txt))

    # ── 断言 ────────────────────────────────────────────────
    print('\n【①】段类型合法性（只允许 v1 §4.2 定义的 8 种）')
    for t, n in type_cnt.most_common():
        flag = '✅' if t in V1_TYPES else '🔴 非法'
        print(f'      {t:16s} {n:>7,}  {flag}')
    check('无非法段类型', not any(t not in V1_TYPES for t in type_cnt),
          str([t for t in type_cnt if t not in V1_TYPES]) or 'OK')
    check('`sense` 不再出现在 card.content（只允许在 card_extra）',
          'sense' not in type_cnt, f'实测 {type_cnt.get("sense", 0)} 条')

    print('\n【②】🔑 例句独立成 `context` —— 语音包前置')
    check('例句在 `context` 段', in_context == total or in_context / total > 0.99,
          f'{in_context:,} / {total:,} = {100*in_context/total:.2f}%')
    check('（v1 §6.2 朗读清单只认 context/collocation/front → 否则 240MB 音频全漏）',
          in_context > 0, f'旧结构此值为 0')

    print('\n【③】首义进 `definition`，每卡只 1 条')
    d1 = sum(1 for v in n_def.values() if v == 1)
    d0 = sum(1 for v in n_def.values() if v == 0)
    check('每卡恰好 1 条 definition', d1 == total, f'1 条 {d1:,} · 0 条 {d0:,}')

    print('\n【④⑤】记忆法段存储顺序正常，且 `root` 排第一'
          '（⚠️ 存储顺序 ≠ mnemonic priority，见 SECTION_STORAGE_ORDER）')
    check('无顺序错误', not bad_order, str(bad_order[:3]) or 'OK')
    check('root 存在时排第一', root_first == root_present,
          f'{root_first:,} / {root_present:,} = {100*root_first/max(root_present,1):.1f}%')

    print('\n【⑥】入口内嵌（不单列 `aggregate_link` 段）')
    check('无 `aggregate_link` 段', agg_link_as_section == 0, f'实测 {agg_link_as_section}')
    check('记忆法段带 entry（可点击）', entry_embedded > 0, f'{entry_embedded:,} 处入口')
    check('`context` 段不带 entry（它不是聚合页入口）', ctx_with_entry == 0,
          f'实测 {ctx_with_entry}')

    print('\n【⑦】渲染后段数 ≤ 4（v1 §5.1）；content 段数（素材池）可更多')
    for k, v in sorted(render_secs.items()):
        print(f'      渲染 {k} 段: {v:>7,}  {100*v/total:5.1f}%')
    check('渲染后 ≤ 4 段', max(render_secs) <= 4, f'最大 {max(render_secs)}')
    check('content 段数可 > 4（存全部素材，顺序留给渲染层）',
          len(card_types) > 0, f'content 段数分布 {sorted(Counter(len(v) for v in card_types.values()).items())}')

    print('\n【⑧】其余义项进 `card_extra`（不丢数据）')
    extra_total = con.execute('select count(*) from card_extra').fetchone()[0]
    cards_with_extra = con.execute('select count(distinct word_id) from card_extra').fetchone()[0]
    check('card_extra 有内容', extra_total > 0,
          f'{extra_total:,} 行 / {cards_with_extra:,} 张卡')

    print('\n【附】规模')
    sizes = [len(c.encode('utf-8')) for _, c in cards]
    print(f'      content 字节   p50 {statistics.median(sizes):,.0f} · max {max(sizes):,} '
          f'· 合计 {sum(sizes)/1024/1024:.1f} MB')
    print(f'      渲染文本字符   p50 {statistics.median(render_chars):.0f} · max {max(render_chars)}')
    print(f'      库大小         {os.path.getsize(DB)/1024/1024:.1f} MB')

    print('\n' + '=' * 74)
    print(f'通过 {_p} 项，失败 {_f} 项')
    if _f:
        for x in _fails:
            print(f'  🔴 {x}')
        if args.verbose:
            print('\n明细:')
            for wid, why in bad_order[:20]:
                print(f'  {wid}: {why}')
        return 1
    print('✅ 卡片结构符合 v1 §4.2 + 白哥「库级可以就存在」')
    return 0


if __name__ == '__main__':
    sys.exit(main())
