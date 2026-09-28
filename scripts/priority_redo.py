#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 `mnemonic_type.priority` 重判定 primary_code / secondary_codes + 摘除 cognate。

白哥 2026-09-28 定案：Ⅱ-乙（重判）· 0-A（摘除 cognate）· Ⅲ-甲（rationale 失配置空）

# 🔴 为什么需要这一步
重判前 `word_mnemonic_profile` 的 primary/secondary **不是按 priority 算出来的** ——
`word_query_service.dart` 的注释自己写着「**不经过优先级排序**」。
而 v1（L0）§4.1 原文要求：「**制卡时按 `mnemonic_type.priority` 选主记忆法和次记忆法**」。

# 口径（**以库表 `mnemonic_type.priority` 为准** —— 见 [order_from_db]）
| 项 | 值 |
|---|---|
| 顺序 | **`root`(1) > `etymology`(3) > `collocation`(4) > `image`(5)** ← 白哥 2026-09-28 19:3x 定「**词源优先**」 |
| 排除 | `cognate`（**聚合页，不是记忆法**）· `context`（卡片 ④ 固定段） |
| `image` | 保留在池里，但 ⚠️ **全库没有 `image` 段** → 它<u>永远不可能是 primary</u> |
| `rationale` | **失配置空 + 保留匹配的**（白哥选甲） |

# 📜 3/4 级的往复（两次改口，如实记录）
| 时间 | 决定 | 后果 |
|---|---|---|
| 09-27 14:08 | **交换**（etymology 3 / collocation 4） | etymology 上卡 51.4%，collocation 0.5% |
| 09-28 18:2x | **改回 v1**（collocation 3 / etymology 4） | collocation 上卡 99.3%，**词源故事只剩 51.4%** |
| **09-28 19:3x** | 🆕 **再改回「词源优先」**（etymology 3 / collocation 4） | 见下 |

🔑 **两次改口的判据变化（值得记住）**：
· 09-27 的理由是「`collocation` 条件**恒真**（99.3%）→ 排前会吃掉槽①」。
· ⚠️ 但 09-28 实测 **`etymology` 同样恒真（11,407 / 11,523 = 99.0%）**
  → 那条理由**对两者等效，不能用来裁决**（谁排 3 谁就吃 ①）。
· → 所以 3/4 级**只能靠产品判断**：卡片第二段给「**怎么用它**」（搭配）还是「**它从哪来**」（词源）。
  白哥 19:3x 定：**词源优先**。
· 📄 详见 `docs/design/card-aggregate-plan-2026-09-28.html` §四

# rationale 处理（白哥选甲）
`rationale` 是**为旧 `primary` 写下的理由**。重判后 primary 变了它就文不对题。
判据：关键词粗判 rationale 讲的是哪种法 → **等于新 primary 才保留，否则置空**。
🔑 保守方向正确：**宁可不显示，不显示错的**。
⚠️ 本脚本**每次重跑都会重算它**（所以反复重判会逐次收窄保留量）。

# 摘除 cognate（白哥选 A · 四处）
① `mnemonic_type` 删行 ② `profile` 的 secondary 清掉 / primary 按补位落定
③ `card.sections` 删 2,988 个冗余段（**零信息损失** —— 实测 100% 与同词 `root` 段同一 `page_id`）
④ 代码（另改，见 `word_query_service.dart` / `word_card.dart`）
⚠️ ①②③ 现均**幂等**（cognate 已摘除 → 再跑是空操作）。

# 用法
```bash
python scripts/priority_redo.py                 # dry-run（默认）：只报告，不写入
python scripts/priority_redo.py --apply         # 写入（先备份；两份词库同步）
python scripts/priority_redo.py --order=v1      # dry-run 另一种口径（仅用于对比）
```
🔴 **`--apply` 之后库表即成为权威** —— 制卡脚本 `load_llm_results.py` 调
`apply_order(con)` 不传顺序，**从库表读**（见 [order_from_db]），所以不会漂移。
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
from collections import Counter

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT_DIR, 'data', 'word.db')
# 🔴 打包进 App 的那份（pubspec 显式声明）—— 必须与源同步
ASSET_DB = os.path.join(ROOT_DIR, 'app', 'assets', 'word.db')

# ── 两种口径 ─────────────────────────────────────────────────────
# 🔑 **当前生效的是 `db` 口径**（白哥 2026-09-28 19:3x 定「词源优先」）。
#    但**判定顺序的真正权威是 `mnemonic_type.priority`**（见 [order_from_db]）——
#    下面两个常量只用于 dry-run 对比两种口径，以及 `--apply` 时把库表改成对应值。
ORDER_DB = ['root', 'etymology', 'collocation', 'image']   # ✅ 当前（词源优先）
ORDER_V1 = ['root', 'collocation', 'etymology', 'image']   # 曾短暂生效（09-28 18:2x–19:3x）
ORDERS = {'v1': ORDER_V1, 'db': ORDER_DB}
DEFAULT_ORDER_KEY = 'db'   # `--apply` 未指定时的口径
# 所有可上卡的记忆法类型 —— **集合（与顺序无关）**，用于判断「这段是不是候选」。
# 🔑 与顺序解耦：`ORDER_V1` 与 `ORDER_DB` 的元素相同、只差顺序，
#    所以「是不是候选」用集合，「排在谁前」才用列表。
ALL_CODES = set(ORDER_V1)

EXCLUDED = {'cognate', 'context'}          # 聚合页 · ④ 固定段
MAX_SLOTS = 2
# 🔴 **断言的期望值 —— 独立于赋值逻辑单独写**（互为交叉校验）。
#    2026-09-28 的教训：首版把期望值写成 `(3,4) if order=='v1' else (4,3)`，
#    与赋值语句是**同一句推导** → 写反了也照样为绿。见下方 `--apply` 处的说明。
#
#    v1 §4.1（L0 原文）   → collocation 3 / etymology 4
#    库表原值（09-27 交换）→ etymology 3 / collocation 4
EXPECTED_PRIORITY = {'v1': (3, 4), 'db': (4, 3)}   # {口径: (collocation, etymology)}
# 🔴 无候选时的兜底：`context` 的 `applicable_when` 就是「默认附加」——
#    语义上它正是「没有别的法时」的落点；且 `offCard` 会把它从卡片上滤掉
#    （= 卡片表现仍为「无记忆法」）。`primary_code` 是 NOT NULL → 不能留空。
FALLBACK = 'context'


def section_has_content(sec):
    """段是否有**可读内容**（与卡片渲染口径一致）。

    🔑 判据来自数据实测：`cognate` 段 100% 无文本（只有族标签）→ 它天然不该占槽位；
       而 `etymology` 段 99.99% 有词源链文本 → 它是真内容。
    """
    t = sec.get('type')
    if t == 'root':
        return bool((sec.get('payload') or {}).get('parts') or [])
    if t == 'collocation':
        return bool(sec.get('items') or [])
    return bool((sec.get('text') or '').strip())


def read_cards(con):
    """word_id → 该词**有可读内容**且**未被排除**的类型集合。"""
    out = {}
    for wid, content in con.execute('SELECT word_id, content FROM card'):
        try:
            d = json.loads(content)
        except (TypeError, ValueError):
            out[wid] = set()
            continue
        avail = set()
        for sec in d.get('sections') or []:
            t = sec.get('type')
            if t in EXCLUDED:
                continue
            if t in ALL_CODES and section_has_content(sec):
                avail.add(t)
        out[wid] = avail
    return out


def resolve(avail, order):
    """按给定顺序取前 2 —— 这就是「按优先级选主/次」。"""
    picked = [c for c in order if c in avail][:MAX_SLOTS]
    return (picked[0] if picked else None), picked[1:]


def rationale_kind(text):
    """粗判 rationale 在讲哪种记忆法（用于决定「保留 / 置空」）。

    ⚠️ 这是**关键词粗判**，不是精确分类。白哥选「甲：失配置空」——
       所以判错的代价是「该留的被置空」（信息少一点），
       而**不会**出现「该置空的留下」（显示错内容）。**方向是安全的**。

    🔴 2026-09-28 实测修正一处判据 bug：首版只查**半角** `(`，
       而数据里拆分式用的是**全角** `（）`（如 `vers（转）+ -atility → …`）
       → **2,295 条被误判为「无法判定」**（实为 `root`）→ 会被白白置空。
       🔑 教训：**「无法判定」占比异常高时（当时 20%），先怀疑判据，别接受它。**
    """
    t = (text or '')
    if not t.strip():
        return None
    # ① 拆分式：`a（x）+ b（y）→ …` / `a(x) + b(y)`（**全角半角都要认**）
    if ('+' in t and ('(' in t or '（' in t)) or ('→' in t):
        return 'root'
    if any(k in t for k in ('拆', '词根', '前缀', '后缀', '同根词', '合成', '复合')):
        return 'root'
    # ② 词源：「源自 / 来自」+ 各语种
    if any(k in t for k in ('源自', '来自', '借自', '同源', '语原意', '语意为', '语借',
                            '拉丁', '希腊', '古英语', '古法语', '法语', '德语', '荷兰语',
                            '意大利语', '西班牙语', '葡萄牙语', '希伯来语', '阿拉伯语',
                            '波斯语', '梵语', '俄语', '拉丁语', '古北欧语')):
        return 'etymology'
    # ③ 搭配：「常与 X 搭配 / 连用」或引号里的短语
    if any(k in t for k in ('搭配', '连用', '短语', '固定用法')):
        return 'collocation'
    # ④ 联想：「想象 / 联想」
    if any(k in t for k in ('想象', '联想', '画面', '谐音')):
        return 'image'
    return None


def strip_cognate_sections(con):
    """删 `card.sections` 里的 `cognate` 段 —— 返回 (改动的卡数, 删掉的段数)。

    🔑 零信息损失（实测）：2,988 个 `cognate` 段**100% 与同词 `root` 段指向同一 `page_id`**，
       且除 `entry` 外无任何独有内容（`text` 100% 为空）。
    """
    changed = removed = 0
    rows = list(con.execute('SELECT word_id, content FROM card'))
    for wid, content in rows:
        try:
            d = json.loads(content)
        except (TypeError, ValueError):
            continue
        secs = d.get('sections') or []
        kept = [s for s in secs if s.get('type') != 'cognate']
        if len(kept) == len(secs):
            continue
        d['sections'] = kept
        con.execute('UPDATE card SET content=? WHERE word_id=?',
                    (json.dumps(d, ensure_ascii=False), wid))
        changed += 1
        removed += len(secs) - len(kept)
    return changed, removed


def order_from_db(con):
    """从 `mnemonic_type.priority` 读顺序 —— **库表是唯一权威**。

    🔴 为什么要这个（2026-09-28 19:4x 加的，防一次真实回退）：

    原先 `apply_order()` 的 `order` 参数默认值写死 `ORDER_V1`。
    而 `load_llm_results.py`（制卡脚本）调用时**不传 order**：
    ```python
    n, ch_p, ch_s, no_cand = apply_order(con)   # ← 用默认值
    ```
    一旦库表改成**另一口径**（09-28 19:3x 白哥定「词源优先」＝ `etymology 3 / collocation 4`），
    制卡脚本仍会按写死的 `ORDER_V1`（搭配优先）重排
    → 🔴 **下次重建词库会静默回退到已被否决的口径**，而且**不报错**。

    🔑 判据：**同一件事的「约定」只能有一处权威。**
    把顺序放在函数默认值里 = 与库表构成**两份拷贝** → 必然漂移。
    改为**从库表读** → 制卡脚本、存量修复、`CardSlots.order` 三者
    都对同一个源头（`mnemonic_type.priority`）负责。
    """
    rows = con.execute('SELECT code FROM mnemonic_type ORDER BY priority').fetchall()
    out = [r[0] for r in rows if r[0] not in EXCLUDED]
    return out or ORDER_V1


def apply_order(con, order=None, fallback=FALLBACK):
    """把 `word_mnemonic_profile` 的 primary/secondary **按 `order` 重算**（不碰 rationale）。

    🔑 **这是「单一出处」的那个函数** —— 两边共用：
    · `priority_redo.py --apply`（存量数据修复）
    · `load_llm_results.py`（制卡脚本，写完 profile 后立刻调用）

    ⚠️ **为什么制卡脚本必须调用它**（2026-09-28 查明的根因）：
    原实现是 `INSERT ... VALUES (mn['primary'], ...)` —— **直接用 LLM 判定的 primary**，
    完全没经过 `priority` → 这就是「卡片排序不经过优先级排序」的病根。
    只在存量数据上修一次是**治不了根**的：下次重建词库会**静默回退**。

    ⚠️ `order=None` → 从库表 `mnemonic_type.priority` 读（见 [order_from_db]）。
       调用方**不要传写死的顺序**，否则又变成两份拷贝。

    返回 (行数, primary 变化数, secondary 变化数, 无候选数)。
    """
    if order is None:
        order = order_from_db(con)
    cards = read_cards(con)
    rows = list(con.execute(
        'SELECT word_id, primary_code, secondary_codes FROM word_mnemonic_profile'))
    plan = []
    ch_p = ch_s = no_cand = 0
    for wid, old_p, old_s in rows:
        avail = cards.get(wid, set())
        new_p, new_s = resolve(avail, order)
        if new_p is None:
            no_cand += 1
            new_p = fallback           # NOT NULL → 兜底（offCard 会让卡片不显示它）
        try:
            old_sec = json.loads(old_s) if old_s else []
        except (TypeError, ValueError):
            old_sec = []
        # ⚠️ 归一化基准用 `order`（不是写死的 ORDER_V1）——
        #    否则「旧值的清洗口径」与「新值的生成口径」不一致 → 变化数虚高。
        old_clean = [c for c in old_sec if c not in EXCLUDED and c in order]
        if new_p != old_p:
            ch_p += 1
        if new_s != old_clean:
            ch_s += 1
        plan.append((new_p, json.dumps(new_s, ensure_ascii=False), wid))
    if plan:
        con.executemany(
            'UPDATE word_mnemonic_profile SET primary_code=?, secondary_codes=? WHERE word_id=?',
            plan)
    return (len(plan), ch_p, ch_s, no_cand)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true', help='写入（默认只 dry-run）')
    ap.add_argument('--order', choices=['v1', 'db'], default=DEFAULT_ORDER_KEY,
                    help='db=词源优先（当前生效）｜v1=搭配优先（09-28 18:2x–19:3x 曾用）')
    ap.add_argument('--db', default=DB)
    args = ap.parse_args()

    order = ORDERS[args.order]
    if not os.path.exists(args.db):
        sys.exit('找不到词库：%s' % args.db)

    con = sqlite3.connect(args.db)
    cards = read_cards(con)
    rows = list(con.execute(
        'SELECT word_id, primary_code, secondary_codes, rationale FROM word_mnemonic_profile'))

    plan = []            # (new_rationale, new_primary, new_secondary_json, word_id)
    ch_primary = ch_secondary = ch_rationale = 0
    no_candidate = 0
    pri_changes = Counter()
    rational_changes = Counter()
    mismatch_kinds = Counter()

    for wid, old_p, old_s, rationale in rows:
        avail = cards.get(wid, set())
        new_p, new_s = resolve(avail, order)
        if new_p is None:
            no_candidate += 1
            new_p = FALLBACK          # NOT NULL → 兜底（offCard 会让卡片不显示它）
        try:
            old_sec = json.loads(old_s) if old_s else []
        except (TypeError, ValueError):
            old_sec = []
        old_sec_clean = [c for c in old_sec if c not in EXCLUDED and c in order]
        if new_p != old_p:
            ch_primary += 1
            pri_changes['%s → %s' % (old_p or '空', new_p or '空')] += 1

        # ── rationale：等于新 primary 才保留，否则置空（白哥选甲）──
        k = rationale_kind(rationale)
        keep = (k == new_p)
        if (rationale or '').strip() and not keep:
            ch_rationale += 1
            if k is None:
                mismatch_kinds['无法判定 / 空 → 置空'] += 1
            else:
                mismatch_kinds['讲 %s，新主 %s → 置空' % (k, new_p)] += 1
            rational_changes['置空'] += 1
        elif keep:
            rational_changes['保留（恰好匹配）'] += 1
        new_r = rationale if keep else None

        if new_s != old_sec_clean:
            ch_secondary += 1
        plan.append((new_r, new_p, json.dumps(new_s, ensure_ascii=False), wid))

    total = len(rows)
    print('=' * 68)
    print('重判定 + 摘除 cognate —— %s' % ('【写入】' if args.apply else '【dry-run，未写入】'))
    print('=' * 68)
    print('顺序：' + ' > '.join(order) + '　（--order=%s）' % args.order)
    print('排除：' + ' / '.join(sorted(EXCLUDED)) + '　无候选兜底：%s' % FALLBACK)
    print()
    print('profile 行数                 : %d' % total)
    print('🔴 primary 变化               : %d (%.1f%%)' % (ch_primary, 100 * ch_primary / total))
    print('   secondary 变化             : %d (%.1f%%)' % (ch_secondary, 100 * ch_secondary / total))
    print('   rationale 置空             : %d' % ch_rationale)
    print('   rationale 保留（恰好匹配） : %d' % rational_changes['保留（恰好匹配）'])
    print('⚠️ 无候选（已兜底为 %s）      : %d' % (FALLBACK, no_candidate))
    print()
    print('── primary 变化形态（top 12）──')
    for k, v in pri_changes.most_common(12):
        print('   %-34s %5d' % (k, v))
    print()
    print('── rationale 置空原因（top 8）──')
    for k, v in mismatch_kinds.most_common(8):
        print('   %-40s %5d' % (k, v))
    print()
    print('── 重判后槽位① 分布 ──')
    d = Counter()
    for _, p, _, _ in plan:
        d[p] += 1
    for k, v in d.most_common():
        print('   %-14s %6d (%5.1f%%)' % (k, v, 100 * v / total))

    if not args.apply:
        print()
        print('ℹ️ dry-run。加 --apply 才写入（会先备份，并同步 app/assets/word.db）。')
        return

    # ══ 写入 ═══════════════════════════════════════════════
    ts = __import__('datetime').datetime.now().strftime('%Y%m%d-%H%M%S')
    for p in (args.db, ASSET_DB):
        if os.path.exists(p):
            bak = '%s.bak-priority-redo-%s' % (p, ts)
            shutil.copy2(p, bak)
            print('已备份 → %s' % bak)

    con.executemany(
        'UPDATE word_mnemonic_profile SET rationale=?, primary_code=?, secondary_codes=? WHERE word_id=?',
        plan)
    ch_cards, rm_secs = strip_cognate_sections(con)

    # ① mnemonic_type：3/4 级按选定口径 + 删 cognate 行
    #
    # 🔴🔴 2026-09-28 修一处**我写反了**的 bug：
    #    v1 §4.1 是 **collocation 3 / etymology 4**（搭配整记 3 > 词源故事 4），
    #    而首版写的是 `(3, 4) if order == 'v1'` → 把 etymology 赋成 3 —— **正好相反**。
    #    ⚠️ **断言当时没抓到**：因为断言的「期望值」也来自这同一句错误赋值
    #       → 「期望 = 实际 = 错的」照样为绿。
    #    🔑 判据：**断言的期望值必须独立于被测逻辑**（不能从同一处推导）。
    #       → 现改为 `EXPECTED_PRIORITY` 常量表（与赋值语句分开写，互为交叉校验）。
    (col, eth) = EXPECTED_PRIORITY[args.order]
    con.execute('UPDATE mnemonic_type SET priority=? WHERE code=?', (col, 'collocation'))
    con.execute('UPDATE mnemonic_type SET priority=? WHERE code=?', (eth, 'etymology'))
    before = con.execute('SELECT count(*) FROM mnemonic_type').fetchone()[0]
    # 🔴 幂等（2026-09-28 19:4x 修）：`cognate` 行**可能已经不在了**（09-28 已摘除）。
    #    原实现假设「本次一定会删掉一行」→ `assert after == before - 1`
    #    在**第二次执行时必然失败**（实测：重跑会崩在这条断言上）。
    #    → 改为「先看在不在」+ 断言「删后不存在」（真正的目标）。
    had_cognate = con.execute(
        "SELECT count(*) FROM mnemonic_type WHERE code='cognate'").fetchone()[0]
    if had_cognate:
        con.execute("DELETE FROM mnemonic_type WHERE code='cognate'")
    after = con.execute('SELECT count(*) FROM mnemonic_type').fetchone()[0]
    con.commit()

    # ── 断言（写入后必须成立）──────────────────────────────
    assert con.execute('SELECT count(*) FROM word_mnemonic_profile').fetchone()[0] == total
    assert after == before - had_cognate, \
        'mnemonic_type 行数应减 %d：%d → %d' % (had_cognate, before, after)
    assert con.execute("SELECT count(*) FROM mnemonic_type WHERE code='cognate'").fetchone()[0] == 0
    assert con.execute(
        "SELECT count(*) FROM word_mnemonic_profile WHERE primary_code='cognate'").fetchone()[0] == 0
    assert con.execute("SELECT count(*) FROM card WHERE content LIKE '%\"cognate\"%'").fetchone()[0] == 0
    assert con.execute('PRAGMA foreign_key_check').fetchall() == [], '外键违反'
    for code, want in (('collocation', col), ('etymology', eth)):
        got = con.execute('SELECT priority FROM mnemonic_type WHERE code=?', (code,)).fetchone()[0]
        assert got == want, '%s priority 应为 %d，实为 %d' % (code, want, got)

    # 🔴 交叉校验（2026-09-28 19:4x 加）：**库表顺序必须与本次写入用的 `order` 一致**。
    #    🔑 为什么必须单独断言：`--order=db` 时若忘了改 `mnemonic_type`，
    #        profile 按 db 排、库表还是 v1 → 制卡脚本（读库表）会按 v1 重排
    #        → **下次重建静默回退**。这条断言正是为了钉住「两者同源」。
    assert order_from_db(con) == order, \
        '库表顺序 %s 与本次口径 %s 不一致 —— 会导致制卡时静默回退' % (
            order_from_db(con), order)

    print()
    print('✅ 已写入：profile %d 行 · card 改 %d 张（删 %d 段）· mnemonic_type %d → %d 行'
          % (len(plan), ch_cards, rm_secs, before, after))
    print('✅ 口径 → 库表顺序已交叉校验：%s' % ' > '.join(order_from_db(con)))
    print('✅ 断言全过（含外键检查）')

    # ── 同步打包词库 ──────────────────────────────────────
    if os.path.abspath(args.db) == os.path.abspath(DB) and os.path.exists(ASSET_DB):
        shutil.copy2(DB, ASSET_DB)
        print('✅ 已同步 → %s（打包进 App 的那份）' % ASSET_DB)


if __name__ == '__main__':
    main()
