#!/usr/bin/env python3
"""把「卡片字段修正候选」写回 `data/word.db`（**改生产数据资产**，需白哥批准）。

# 它做什么

1. 读 `data/curriculum/prebuilt/card_field_fixes.json`（LLM 契约 v6 复核结果）
2. 用 `gen_card_field_fixes.py` 的**同一套判据**决定「哪些字段该写」
3. 写回 `card.content` 的对应字段，并**重算 `content_hash`**
4. 写回后**逐字段读回断言**，并断言其余字段**逐字节未变**

# 🔑 三条硬规矩

① **不整条覆盖** —— 只动 `write_fields()` 判定该写的字段，其余原样保留。
   为什么：`definition` 是开放式字段，「与 v6 不同」多数只是措辞差异（见 gen 脚本 §五）。
② **写前必备份** —— `data/backups/word.db.bak-cardfix-<ts>`，失败可整体回滚。
③ **写完必读回** —— 断言每条的新值 == v6 值、且**非目标字段一个字符都没变**。

# 用法

```bash
python scripts/apply_card_field_fixes.py                     # dry-run（默认，只看不改）
python scripts/apply_card_field_fixes.py --tier ipa-hard --fields ipa --apply   # 第 1 批
python scripts/apply_card_field_fixes.py --apply             # 全部建议写入
python scripts/apply_card_field_fixes.py --only "a,with,meet" --apply
```
"""

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_card_field_fixes as G  # noqa: E402

ROOT = G.ROOT
WORD_DB = G.WORD_DB
FIXES = G.OUT_JSON
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')

# 段落规范顺序（现网实测：`definition` 在 `context` 前）
SEC_ORDER = ['root', 'collocation', 'etymology', 'definition', 'context', 'mnemonic']


def content_hash(content_json, extras):
    """与 `load_llm_results.py` 完全一致的算法（否则 hash 失去意义）。"""
    h = hashlib.sha256((content_json + ''.join(json.dumps(e, ensure_ascii=False)
                                               for e in extras)).encode()).hexdigest()
    return h[:32]


def load_plan(args):
    """算出「该写哪些词的哪些字段」。

    🔑 **两条关键设计**（2026-09-29 加）：

    ① **支持多个结果文件**（`--fixes a.json b.json`）——
       不同批次的候选（原 196 / S5 盲区 161）各有一份结果，合并后统一判定。
       同词冲突时保留 `generated_at` 更新的那份。

    ② 🔴 **用「库里的当前值」重算，不用文件里的 `current` 快照** ——
       文件里的 `current` 是**调用 LLM 那一刻**的现状；如果中间已经写过库，
       它就过时了。用过时快照判定会反复算出「要写」（虽然幂等无害），
       但**报出的「本次实际改动」会虚高**，且无法回答「现在到底还差几条」。
       改为现读库 → 判定天然幂等，且数字就是真实待办量。
    """
    con = sqlite3.connect(WORD_DB)
    forms_map = G.load_surface_forms(WORD_DB)
    best = {}                                 # spelling(lower) -> (generated_at, rec)
    for path in args.fixes:
        if not os.path.exists(path):
            con.close()
            sys.exit(f'🔴 找不到结果文件 {path}')
        payload = json.load(open(path, encoding='utf-8'))
        ga = payload.get('generated_at') or ''
        for r in payload['items']:
            if not r.get('ok'):
                continue
            k = r['spelling'].lower()
            if k in best and best[k][0] >= ga:
                continue
            # 🔴 现读库 → 覆盖文件里的过时快照
            r['current'] = G.load_current(con, r['spelling'])
            best[k] = (ga, r)
    con.close()

    plan = []
    for _ga, r in best.values():
        cur = r['current']
        lvl, hard, closed = G.classify(r, cur, forms_map)
        r['level'], r['hard'], r['closed'] = lvl, hard, closed
        fields = G.write_fields(r, cur, forms_map)
        if args.tier == 'ipa-hard':                       # 只取「ipa 格式硬证据」那一批
            if not any(h in IPA_HARD for h in hard):
                continue
            fields &= {'ipa'}
        if args.fields:                                   # 显式限定字段
            fields &= set(args.fields)
        if args.only and r['spelling'].lower() not in args.only:
            continue
        if not fields:
            continue
        plan.append((r, sorted(fields)))
    if args.only:
        missing = args.only - {r['spelling'].lower() for r, _ in plan}
        if missing:
            sys.exit(f'🔴 `--only` 里有没进计划的词（已无需修 / 不在候选）: {sorted(missing)}')
    return plan, forms_map


IPA_HARD = G.IPA_HARD


def apply_one(con, rec, fields, dry):
    """改一条卡。返回 `(变更描述列表, word_id)`。"""
    sp = rec['spelling']
    rows = con.execute('SELECT id FROM word WHERE spelling = ? COLLATE NOCASE', (sp,)).fetchall()
    if len(rows) != 1:
        raise RuntimeError(f'🔴 `{sp}` 在 word 表命中 {len(rows)} 行（期望 1）—— 拒绝改')
    wid = rows[0][0]
    row = con.execute('SELECT content FROM card WHERE word_id = ?', (wid,)).fetchone()
    if not row:
        raise RuntimeError(f'🔴 `{sp}`（word_id={wid}）没有 card 行')
    content = row[0]
    d = json.loads(content)
    before = json.loads(content)                  # 用于「其余字段未变」断言
    d_new = rec['data']
    dfn_new = d_new.get('definition') or {}
    changes = []
    added_ctx = False

    # ── ipa ──
    if 'ipa' in fields:
        changes.append(('ipa', d.get('ipa'), d_new.get('ipa')))
        d['ipa'] = d_new.get('ipa')

    # ── definition 段（pos/en/zh 同属一段，一起换）──
    if 'definition' in fields:
        sec = next((s for s in d.get('sections') or []
                    if isinstance(s, dict) and s.get('type') == 'definition'), None)
        if sec is None:
            raise RuntimeError(f'🔴 `{sp}` 没有 definition 段 —— 拒绝改（不该整段新建）')
        for k, nk in (('pos', 'pos'), ('en', 'en'), ('zh', 'zh')):
            changes.append((f'definition.{k}', sec.get(k), dfn_new.get(nk)))
            if dfn_new.get(nk) is not None:
                sec[k] = dfn_new[nk]

    # ── context 段（没有就按规范顺序插入）──
    if 'context' in fields:
        sec = next((s for s in d.get('sections') or []
                    if isinstance(s, dict) and s.get('type') == 'context'), None)
        if sec is None:
            sec = {'type': 'context', 'text': None}
            secs = list(d.get('sections') or [])
            at = len(secs)
            for i, s in enumerate(secs):
                if isinstance(s, dict) and s.get('type') == 'definition':
                    at = i + 1
            secs.insert(at, sec)
            d['sections'] = secs
            added_ctx = True
        changes.append(('context.text', sec.get('text'), d_new.get('context')))
        sec['text'] = d_new.get('context')

    cj = json.dumps(d, ensure_ascii=False)
    extras = [json.loads(x[0]) for x in
              con.execute('SELECT section FROM card_extra WHERE word_id=? ORDER BY ord', (wid,))]
    h = content_hash(cj, extras)

    if not dry:
        con.execute("UPDATE card SET content=?, content_hash=?, updated_at=datetime('now') "
                    'WHERE word_id=?', (cj, h, wid))

    # ── 断言：**除目标字段外，其余逐字节未变** ──
    a, b = json.loads(cj), before
    if 'ipa' in fields:
        a.pop('ipa', None)
        b.pop('ipa', None)
    if 'definition' in fields:
        for x in (a, b):
            for s in x.get('sections') or []:
                if isinstance(s, dict) and s.get('type') == 'definition':
                    for k in ('pos', 'en', 'zh'):
                        s.pop(k, None)
    if 'context' in fields:
        if added_ctx:                             # 新建的段落 → 从「改后」里摘掉再比
            a['sections'] = [s for s in a.get('sections') or []
                             if not (isinstance(s, dict) and s.get('type') == 'context')]
        else:
            for x in (a, b):
                for s in x.get('sections') or []:
                    if isinstance(s, dict) and s.get('type') == 'context':
                        s.pop('text', None)
    if json.dumps(a, ensure_ascii=False, sort_keys=True) != \
       json.dumps(b, ensure_ascii=False, sort_keys=True):
        raise RuntimeError(f'🔴 `{sp}` 的非目标字段发生变化 —— 已中止，请从备份回滚')
    return changes, wid


def verify(con, rec, fields):
    """读回断言：新值 == v6 值。返回问题列表。"""
    sp = rec['spelling']
    wid = con.execute('SELECT id FROM word WHERE spelling = ? COLLATE NOCASE', (sp,)).fetchone()[0]
    ct, ch = con.execute('SELECT content, content_hash FROM card WHERE word_id=?', (wid,)).fetchone()
    d = json.loads(ct)
    bad = []
    if 'ipa' in fields and d.get('ipa') != rec['data'].get('ipa'):
        bad.append(f'ipa 读回不符: {d.get("ipa")!r}')
    if 'context' in fields:
        got = next((s.get('text') for s in d.get('sections') or []
                    if isinstance(s, dict) and s.get('type') == 'context'), None)
        if got != rec['data'].get('context'):
            bad.append(f'context 读回不符: {got!r}')
    if 'definition' in fields:
        sec = next((s for s in d.get('sections') or []
                    if isinstance(s, dict) and s.get('type') == 'definition'), {})
        exp = rec['data'].get('definition') or {}
        if sec.get('en') != exp.get('en'):
            bad.append(f'definition.en 读回不符: {sec.get("en")!r}')
    extras = [json.loads(x[0]) for x in
              con.execute('SELECT section FROM card_extra WHERE word_id=? ORDER BY ord', (wid,))]
    if ch != content_hash(ct, extras):
        bad.append('content_hash 与 content 不一致')
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tier', choices=['all', 'ipa-hard'], default='all')
    ap.add_argument('--fixes', nargs='+', default=[FIXES],
                    help=f'结果 json（可多个，合并去重）；默认 {os.path.basename(FIXES)}')
    ap.add_argument('--fields', default='',
                    help='限定字段，逗号分隔（ipa,context,definition）；默认用判据算出来的')
    ap.add_argument('--only', default='', help='只处理这些词（逗号分隔）')
    ap.add_argument('--apply', action='store_true', help='真的写（默认 dry-run）')
    ap.add_argument('--no-backup', action='store_true')
    args = ap.parse_args()
    args.fields = [x.strip() for x in args.fields.split(',') if x.strip()]
    args.only = {x.strip().lower() for x in args.only.split(',') if x.strip()} or None

    missing = [f for f in args.fixes if not os.path.exists(f)]
    if missing:
        sys.exit(f'🔴 找不到结果文件: {missing}')

    plan, _ = load_plan(args)

    print(f'{"词":26s} {"写":28s} 变更')
    nchg = 0
    for r, fields in sorted(plan, key=lambda x: x[0]['spelling']):
        for f in fields:
            nchg += 1
        cu, dn = r['current'], r['data']
        bits = []
        if 'ipa' in fields:
            bits.append(f'ipa {cu["ipa"]!r} → {dn.get("ipa")!r}')
        if 'context' in fields:
            bits.append(f'ctx {cu["context"]!r} → {dn.get("context")!r}')
        if 'definition' in fields:
            bits.append(f'def {cu["def_en"]!r} → {(dn.get("definition") or {}).get("en")!r}')
        print(f'  {r["spelling"]:24s} {"+".join(fields):28s} ' + ' | '.join(bits))
    print(f'\n计划：{len(plan)} 条卡 · {nchg} 个字段')

    if not args.apply:
        print('\n（dry-run：没有写任何东西。加 --apply 才写入）')
        return 0

    # ── 备份 ──
    os.makedirs(BACKUP_DIR, exist_ok=True)
    if args.no_backup:
        print('⚠️ --no-backup：跳过备份（不推荐）')
    else:
        bak = os.path.join(BACKUP_DIR, f'word.db.bak-cardfix-{time.strftime("%Y%m%d-%H%M%S")}')
        shutil.copy2(WORD_DB, bak)
        assert os.path.exists(bak) and os.path.getsize(bak) > 0
        print(f'✅ 备份: {bak}（回滚 = 把这个文件拷回 data/word.db）')

    con = sqlite3.connect(WORD_DB)
    con.execute('PRAGMA foreign_keys=ON')
    fails = []
    try:
        with con:                                  # 事务：要么全成，要么全回滚
            for r, fields in sorted(plan, key=lambda x: x[0]['spelling']):
                try:
                    apply_one(con, r, fields, dry=False)
                except Exception as e:             # noqa: BLE001
                    raise RuntimeError(f'`{r["spelling"]}` 写入失败: {e}') from e
            # 🔑 读回断言也放在事务内 —— 失败则整体回滚，不留半成品
            for r, fields in sorted(plan, key=lambda x: x[0]['spelling']):
                bad = verify(con, r, fields)
                if bad:
                    fails.append((r['spelling'], bad))
            if fails:
                raise RuntimeError('读回断言失败 → 回滚本次全部写入')
    except RuntimeError as e:
        con.close()
        print(f'\n🔴 已回滚：{e}')
        for sp, bad in fails:
            print(f'  {sp}: {"; ".join(bad)}')
        return 1
    finally:
        con.close()

    print(f'\n✅ {len(plan)} 条卡已写入并通过读回断言')
    print('   提示：`data/word.db` 体积会变大，可 `VACUUM` 回收（不影响正确性）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
