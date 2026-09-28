#!/usr/bin/env python3
"""落库脚本：LLM 结果 JSON → 18 张表（12 步写入）

输入：
  data/curriculum/prebuilt/fullrun/results.jsonl   或
  data/curriculum/prebuilt/llm_rerun_sample.json   （--from-sample）
  data/curriculum/prebuilt/affix_normalized.json   （词缀归一化，由 build_affix_table.py 产出）
  data/curriculum/prebuilt/word_form_chained.json  （形态链，由 build_chains.py 产出）
  data/curriculum/prebuilt/etymon_chained.json     （词源链）

输出：
  data/word.db  （新的预制库，**不动 coevo.db**）

12 步写入顺序（按外键依赖）：
   1. mnemonic_type       静态 6 行
   2. affix               词缀表（已由 build_affix_table 写，这里只校验）
   3. word                词条主表（仅 is_own_entry=true；sort_seq NOT NULL）
   4. word_form           形态链（含 anchor；按 action 过滤 drop/pending）
   5. card / card_extra   卡片（现网 definitions 结构转换）
   6. word_root           词根（UNIQUE form,type,origin）
   7. word_morpheme       词↔词素（含 relation）
   8. etymon              源词（含 parent/anchor）
   9. word_etymon         词↔源词
  10. collocation / word_collocation
  11. cognate_group / member   （relation IN derivation/compound）
  12. aggregate_page / word   （族 ≥3 成员）+ word_mnemonic_profile

用法：
  python3 scripts/load_llm_results.py --from-sample --dry-run   # 只校验不写
  python3 scripts/load_llm_results.py --from-sample             # 写 word.db（小样）
  python3 scripts/load_llm_results.py                           # 全量
"""
import argparse
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

ROOT = cwc.ROOT
PREBUILT = cwc.PREBUILT
SRC_DB = cwc.DB
SENSES_SUPP = os.path.join(PREBUILT, 'senses_supplement.json')   # 补录词释义
WORD_DB = os.path.join(ROOT, 'data', 'word.db')
SAMPLE_JSON = os.path.join(PREBUILT, 'llm_rerun_sample.json')
FULLRUN_JSONL = os.path.join(PREBUILT, 'fullrun', 'results.jsonl')
INTER_JSONL = os.path.join(PREBUILT, 'intermediate', 'results.jsonl')
AFFIX_JSON = os.path.join(PREBUILT, 'affix_normalized.json')
WF_JSON = os.path.join(PREBUILT, 'word_form_chained.json')
ET_JSON = os.path.join(PREBUILT, 'etymon_chained.json')
ET_CANON = os.path.join(PREBUILT, 'etymon_canonical.json')   # 词源拼写归一化（normalize_etymon.py）
LEGACY_COLLOC_JSON = os.path.join(PREBUILT, 'collocation_parsed.json')

# ── 24 张表 DDL（与冻结版一致）──
DDL = [
"""CREATE TABLE IF NOT EXISTS word (
  id TEXT PRIMARY KEY, sort_seq INTEGER NOT NULL UNIQUE,
  spelling TEXT NOT NULL COLLATE NOCASE, cefr_level TEXT, entry_type TEXT,
  etymology_text TEXT, created_at TEXT DEFAULT (datetime('now')), UNIQUE (spelling))""",
"CREATE INDEX IF NOT EXISTS idx_word_spelling ON word (spelling)",
"""CREATE TABLE IF NOT EXISTS word_form (
  form TEXT NOT NULL COLLATE NOCASE, base TEXT NOT NULL COLLATE NOCASE,
  rule TEXT, kind TEXT, anchor TEXT COLLATE NOCASE, anchor_id TEXT,
  depth INTEGER DEFAULT 1, in_vocab INTEGER DEFAULT 0, action TEXT,
  PRIMARY KEY (form, base))""",
"CREATE INDEX IF NOT EXISTS idx_form ON word_form (form)",
"CREATE INDEX IF NOT EXISTS idx_anchor ON word_form (anchor)",
"""CREATE TABLE IF NOT EXISTS card (
  word_id TEXT PRIMARY KEY, content TEXT NOT NULL, content_hash TEXT,
  template_code TEXT, updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (word_id) REFERENCES word(id))""",
"CREATE INDEX IF NOT EXISTS idx_card_hash ON card (content_hash)",
"""CREATE TABLE IF NOT EXISTS card_extra (
  id INTEGER PRIMARY KEY AUTOINCREMENT, word_id TEXT NOT NULL,
  section TEXT NOT NULL, ord INTEGER, FOREIGN KEY (word_id) REFERENCES word(id))""",
"""CREATE TABLE IF NOT EXISTS affix (
  id INTEGER PRIMARY KEY AUTOINCREMENT, form TEXT NOT NULL COLLATE NOCASE,
  type TEXT NOT NULL, sense TEXT NOT NULL, meaning_zh TEXT NOT NULL,
  aliases TEXT, productivity INTEGER DEFAULT 0, needs_review INTEGER DEFAULT 0,
  UNIQUE (form, type, sense))""",
"""CREATE TABLE IF NOT EXISTS word_root (
  id INTEGER PRIMARY KEY AUTOINCREMENT, form TEXT NOT NULL COLLATE NOCASE,
  type TEXT NOT NULL, meaning TEXT, origin TEXT, UNIQUE (form, type, origin))""",
"""CREATE TABLE IF NOT EXISTS word_morpheme (
  word_id TEXT NOT NULL, position INTEGER NOT NULL, type TEXT NOT NULL,
  affix_id INTEGER, root_id INTEGER, surface TEXT, gloss TEXT, relation TEXT,
  PRIMARY KEY (word_id, position),
  CHECK ((type =  'root' AND root_id IS NOT NULL AND affix_id IS NULL) OR
         (type <> 'root' AND affix_id IS NOT NULL AND root_id IS NULL)))""",
"CREATE INDEX IF NOT EXISTS idx_morpheme_affix ON word_morpheme (affix_id)",
"CREATE INDEX IF NOT EXISTS idx_morpheme_root  ON word_morpheme (root_id)",
"""CREATE TABLE IF NOT EXISTS collocation (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  phrase TEXT NOT NULL UNIQUE COLLATE NOCASE, chinese TEXT, frequency INTEGER)""",
"""CREATE TABLE IF NOT EXISTS word_collocation (
  word_id TEXT NOT NULL, collocation_id INTEGER NOT NULL, ord INTEGER,
  PRIMARY KEY (word_id, collocation_id))""",
"""CREATE TABLE IF NOT EXISTS cognate_group (
  id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT NOT NULL,
  root_id INTEGER, label TEXT, origin TEXT, size INTEGER DEFAULT 0,
  UNIQUE (root_id),
  FOREIGN KEY (root_id) REFERENCES word_root(id))""",
"""CREATE TABLE IF NOT EXISTS cognate_group_member (
  group_id INTEGER NOT NULL, word_id TEXT NOT NULL, gloss TEXT,
  PRIMARY KEY (group_id, word_id))""",
"""CREATE TABLE IF NOT EXISTS etymon (
  id INTEGER PRIMARY KEY AUTOINCREMENT, form TEXT NOT NULL,
  form_ascii TEXT NOT NULL COLLATE NOCASE, language TEXT NOT NULL,
  meaning_zh TEXT, note TEXT, parent_id INTEGER, anchor_id INTEGER,
  depth INTEGER DEFAULT 0, size INTEGER DEFAULT 0,
  UNIQUE (form_ascii, language),
  FOREIGN KEY (parent_id) REFERENCES etymon(id),
  FOREIGN KEY (anchor_id) REFERENCES etymon(id))""",
"CREATE INDEX IF NOT EXISTS idx_etymon_ascii  ON etymon (form_ascii)",
"CREATE INDEX IF NOT EXISTS idx_etymon_anchor ON etymon (anchor_id)",
"""CREATE TABLE IF NOT EXISTS word_etymon (
  word_id TEXT NOT NULL, etymon_id INTEGER NOT NULL, role TEXT,
  is_direct INTEGER DEFAULT 1, ord INTEGER, PRIMARY KEY (word_id, etymon_id),
  FOREIGN KEY (etymon_id) REFERENCES etymon(id))""",
"CREATE INDEX IF NOT EXISTS idx_word_etymon_etymon ON word_etymon (etymon_id)",
"""CREATE TABLE IF NOT EXISTS aggregate_page (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  page_type TEXT NOT NULL CHECK(page_type IN ('root','etymon')),
  group_id INTEGER, etymon_id INTEGER, front TEXT NOT NULL, content TEXT NOT NULL,
  member_count INTEGER DEFAULT 0,
  CHECK ((page_type='root'   AND group_id  IS NOT NULL AND etymon_id IS NULL) OR
         (page_type='etymon' AND etymon_id IS NOT NULL AND group_id  IS NULL)))""",
"""CREATE TABLE IF NOT EXISTS aggregate_page_word (
  page_id INTEGER NOT NULL, word_id TEXT NOT NULL, ord INTEGER,
  PRIMARY KEY (page_id, word_id))""",
"""CREATE TABLE IF NOT EXISTS mnemonic_type (
  code TEXT PRIMARY KEY, priority INTEGER NOT NULL, name TEXT NOT NULL,
  applicable_when TEXT)""",
"""CREATE TABLE IF NOT EXISTS word_mnemonic_profile (
  word_id TEXT PRIMARY KEY, primary_code TEXT NOT NULL, secondary_codes TEXT,
  confidence REAL, rationale TEXT,
  FOREIGN KEY (primary_code) REFERENCES mnemonic_type(code))""",
"""CREATE TABLE IF NOT EXISTS card_audio (
  id INTEGER PRIMARY KEY AUTOINCREMENT, word_id TEXT NOT NULL,
  audio_type TEXT NOT NULL, scope TEXT, section_index INTEGER, text TEXT NOT NULL,
  file_name TEXT NOT NULL, duration_ms INTEGER, content_hash TEXT,
  UNIQUE (word_id, audio_type, scope, section_index))""",
]

# 记忆法优先级 —— 🔴 **这些 priority 是「渲染层选槽位①的规则」，不是数据组织方式**
#
# ============================================================================
# ✅ 3/4 级当前生效：**`etymology` 3 / `collocation` 4**（词源优先）
#    白哥 2026-09-28 19:3x 定 · **别再来回改**
# ============================================================================
# 📜 当天改了两次，两次的理由都已记录（免得下次又绕回来）：
# · 09-27 14:08 白哥批准把 `etymology` 3 ↔ `collocation` 4 **交换**（原为 collocation 3）。
#   理由：`collocation` 的条件「有 ≥1 条高频固定搭配」**99.3% 的词都满足（几乎恒真）**
#   → 排第 3 会**必然吃掉所有「不可拆词」的槽位①** → `etymology` 只剩 0.5%（形同虚设）。
#   交换后实测：`etymology` 51.4% · `root` 47.6% · `collocation` 0.7%（与「不可拆词」52.4% 吻合）。
# · 09-28 18:2x 白哥**改回 v1 顺序**（collocation 3），后果：collocation 上卡 99.3%，
#   **词源故事只剩 51.4%**（有 `root` 段的 47.6% 词看不到词源）。
# · 🔴 09-28 19:3x 白哥**再改回词源优先**（本行生效值）——
#   🔑 关键：原先那条「`collocation` 恒真所以不该排前」的论据，**对 `etymology` 同样成立**
#      （实测 `etymology` 有段的词 = 11,407 / 11,523 = 99.0%，与 collocation 的 99.3% 几乎一样）
#      → 那条理由**对两者等效，不能用来裁决谁在前**。
#      → 3/4 级只能靠**产品判断**：卡片第二段给「**怎么用它**」（搭配）还是「**它从哪来**」（词源）。
#   📄 完整论证：`docs/review/mnemonic-slot-priority-conflict-2026-09-27.md`
#      §四 对比表：`docs/design/card-aggregate-plan-2026-09-28.html`
# ============================================================================
#
# 🔴 `cognate` 已于 2026-09-28 **整层摘除**（白哥：「同源串记是聚合页，现在还总是把这个
#    放在记忆法里」）。它不是卡上记忆法 —— 它的卡片段 100% 无文本、且与同词 `root` 段
#    指向同一个 `aggregate_page`（实测 2,988 段全部如此）→ 只是聚合页入口的冗余副本。
#    **不要再加回来**（表里另 5 个才是真的卡上记忆法）。
# ============================================================================
MNEMONIC_TYPES = [
    ('root', 1, '词根词缀', '可拆成现代英语仍透明的词根/词缀（incredible = in+cred+ible）'),
    ('etymology', 3, '词源故事', '整体借词、不可拆（café ← French café）'),
    ('collocation', 4, '搭配整记', '有 ≥1 条高频固定搭配'),
    ('image', 5, '联想图像', '抽象词，靠意象或谐音联想'),
    ('context', 6, '语境原句', '默认附加'),
]

# 合法词缀白名单（防幻觉词素入库）
# 真正合法的单字母后缀（实测幻觉：-d(bidding) / -n(given) 应拦）
SUFFIX_WHITELIST_1 = {'s', 'y', 'a', 'e'}
PREFIX_WHITELIST_1 = {'a', 'e'}


def parse_json_field(v):
    if not v:
        return None
    try:
        return json.loads(v)
    except Exception:
        return None


def load_records(from_sample):
    recs = []
    if from_sample:
        d = json.load(open(SAMPLE_JSON, encoding='utf-8'))
        for x in d['items']:
            data = (x.get('r1') or {}).get('data')
            if data:
                recs.append({'word': x['word'], 'data': data})
    else:
        for line in open(FULLRUN_JSONL, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('ok') and r.get('data'):
                recs.append({'word': r['word'], 'data': r['data']})

        # 🆕 补录词并入（2026-09-26）：
        #   977 个「别的词的 derived_from 指向的词」不在现网词表，但 LLM 判它们值得独立成卡
        #   → 补录为正式词条，否则 396 个词形 anchor 落空（划词无卡）
        #   标记来源：`senses_supplement.json`（其释义/IPA/等级已由 gen_senses_new_words.py 生成）
        if os.path.exists(SENSES_SUPP) and os.path.exists(INTER_JSONL):
            supp = {w.lower() for w in (json.load(open(SENSES_SUPP, encoding='utf-8'))
                                        .get('items') or {})}
            have = {r['word'] for r in recs}
            n = 0
            for line in open(INTER_JSONL, encoding='utf-8'):
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                w = r.get('word')
                if (r.get('ok') and r.get('data') and w and w not in have
                        and w.lower() in supp):
                    recs.append({'word': w, 'data': r['data'], 'promoted': True})
                    n += 1
            if n:
                print(f'  并入补录词 {n} 个（原 {len(have)} → {len(recs)}）')
    return recs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from-sample', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--db', default=WORD_DB)
    ap.add_argument('--merge-legacy-collocations', action='store_true',
                    help='把现网 related_phrases 解析出的搭配**合并**进 collocation 表'
                         '（默认关闭，只用 LLM 的 collocations[]；实测两者仅 33%% 重合）')
    args = ap.parse_args()

    recs = load_records(args.from_sample)
    print(f'  LLM 记录: {len(recs)} 条（来源 {"抽样" if args.from_sample else "全量"}）')

    # 现网释义（卡片内容来源）
    #
    # 🔴🔴 2026-09-28 变更：`SRC_DB`（`data/coevo.db`）里的**词卡表已被清除**
    #    （白哥决定「只保留 VPS 在用的表」，词卡库一并清退 —— 理由：维护两份词库
    #    既无意义又易互相污染）。被删的是 `prebuilt_cards` 与 4 张域子表。
    #
    #    → 本段「从现网取 pronunciation」的路径**已失效**。
    #    🔑 **这里选择「明确报错」而非「静默跳过」**：
    #       若静默跳过，重建出来的 `card.content.ipa` 会全是 `None`
    #       → **产出 11,523 张没有音标的卡，且没有任何报错**（＝最危险的一类失败）。
    #    📄 决策与替代方案 → `docs/design/coevo-db-wordcard-removal-2026-09-28.md`
    #    💡 新方向：发音也应由 **LLM 生成**（白哥「不再补库，改调整 LLM 制卡」），
    #       而不是从一份已知不洁的旧库搬运（该库的 pronunciation 曾大面积串位）。
    con_src = sqlite3.connect(SRC_DB)
    src_defs, src_pron, supp_level = {}, {}, {}
    _has_wordcards = con_src.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='prebuilt_cards'"
    ).fetchone()[0]
    if not _has_wordcards:
        con_src.close()
        sys.exit(
            f'🔴 {SRC_DB} 里已没有 `prebuilt_cards` 表 —— 本脚本的「现网 IPA/释义来源」已失效。\n'
            f'   这是**有意的**：词卡库已于 2026-09-28 清除（见 docs/design/coevo-db-wordcard-removal-2026-09-28.md）。\n'
            f'   重建前请先决定 **IPA 与释义的新来源**（推荐：改由 LLM 生成，与「调整 LLM 制卡」的方向一致）。\n'
            f'   ⚠️ 不要为了让它跑通而静默跳过 —— 那会产出 11,523 张无音标的卡且不报错。'
        )
    for w, pron, d in con_src.execute("""
        SELECT c.front, l.pronunciation, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id=c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'"""):
        src_pron[w.lower()] = pron
        src_defs[w.lower()] = parse_json_field(d) or []
    con_src.close()

    # 🆕 补录词的释义/IPA/等级（现网没有 → 由 gen_senses_new_words.py 生成）
    #   背景：977 个「别的词的 derived_from 指向的词」不在现网词表，但 LLM 判它们
    #   值得独立成卡 → 不补录则 396 个词形划词无卡可跳（anchor 落空）。
    if os.path.exists(SENSES_SUPP) and not args.from_sample:
        sj = json.load(open(SENSES_SUPP, encoding='utf-8'))
        added = 0
        for w, v in (sj.get('items') or {}).items():
            wl = w.lower()
            if wl in src_defs:
                continue
            src_pron.setdefault(wl, v.get('pronunciation'))
            src_defs[wl] = v.get('definitions') or []
            supp_level[wl] = v.get('level') or ''
            added += 1
        print(f'  补录词释义: {added} 个（来自 {os.path.basename(SENSES_SUPP)}）')

    affixes = json.load(open(AFFIX_JSON, encoding='utf-8'))['affixes'] if os.path.exists(AFFIX_JSON) else []
    wf_chained = json.load(open(WF_JSON, encoding='utf-8'))['rows'] if os.path.exists(WF_JSON) else []
    et_chained = json.load(open(ET_JSON, encoding='utf-8'))['rows'] if os.path.exists(ET_JSON) else []
    print(f'  词缀归一化: {len(affixes)} · 形态链: {len(wf_chained)} · 词源链: {len(et_chained)}')

    stats = Counter()
    issues = []
    merge_legacy = args.merge_legacy_collocations

    if args.dry_run:
        db = ':memory:'
    else:
        if os.path.exists(args.db):
            os.remove(args.db)
        db = args.db
    con = sqlite3.connect(db)
    con.execute('PRAGMA foreign_keys = ON')
    for stmt in DDL:
        con.execute(stmt)

    # ── 1. mnemonic_type ──
    for code, pri, name, when in MNEMONIC_TYPES:
        con.execute('INSERT OR IGNORE INTO mnemonic_type VALUES (?,?,?,?)', (code, pri, name, when))
    stats['mnemonic_type'] = len(MNEMONIC_TYPES)

    # ── 2. affix（已在 build_affix_table 落过；这里在 :memory: 时重建）──
    for a in affixes:
        for s in (a.get('senses') or []):
            con.execute('INSERT OR IGNORE INTO affix (form,type,sense,meaning_zh,aliases) VALUES (?,?,?,?,?)',
                        (a['form'], a['type'], s.get('sense') or 'general', s.get('meaning_zh') or '',
                         json.dumps(s.get('aliases') or [], ensure_ascii=False)))
            stats['affix'] += 1
    affix_idx = {(r[0].lower(), r[1].lower(), r[2]): r[3]
                 for r in con.execute('SELECT form,type,sense,id FROM affix')}
    # 别名 → affix_id
    alias_idx = {}
    for fid, f, t, al in con.execute('SELECT id,form,type,aliases FROM affix'):
        for x in (json.loads(al or '[]') or []):
            alias_idx[(f.lower(), t.lower(), str(x).strip().lower())] = fid

    # ── 3. word（仅 is_own_entry=true）──
    sort_seq = 0
    wid_of = {}          # spelling_lower → id
    rec_by_word = {}
    wid_to_word = {}     # id → spelling_lower（聚合页要显示拼写，免 join）
    for r in recs:
        d = r['data']
        if d.get('is_own_entry') is not True:
            continue
        w = r['word']
        wl = w.lower()
        sort_seq += 1
        wid = f'w{sort_seq:06d}'
        wid_of[wl] = wid
        wid_to_word[wid] = wl
        rec_by_word[wl] = r
        et = d.get('etymology') or {}
        con.execute('INSERT OR IGNORE INTO word (id,sort_seq,spelling,cefr_level,entry_type,etymology_text) '
                    'VALUES (?,?,?,?,?,?)',
                    (wid, sort_seq, w,
                     (r.get('level') or None) if not from_sample_meta(r) else None,
                     d.get('entry_type'), (et.get('text') or None)))
        stats['word'] += 1
    # 补 cefr_level（抽样记录里没有 level 字段→从现网取）
    con_src = sqlite3.connect(SRC_DB)
    lv_map = {a.lower(): (b or '').strip()
              for a, b in con_src.execute("""
                  SELECT c.front, l.level FROM prebuilt_cards c
                  JOIN prebuilt_language_cards l ON l.id=c.id
                  WHERE c.subject='english' AND c.card_type='vocabulary'""")}
    con_src.close()
    con.execute('UPDATE word SET cefr_level = (SELECT NULL) WHERE 0')   # no-op 保持语义清晰
    for wl, wid in wid_of.items():
        # 🆕 补录词的等级来自 gen_senses_new_words.py（现网没有）
        lv = lv_map.get(wl) or supp_level.get(wl)
        if lv:
            con.execute('UPDATE word SET cefr_level=? WHERE id=?', (lv, wid))

    # ── 4. word_form（按 action 过滤）──
    for r in wf_chained:
        if r.get('action') in ('drop', 'pending'):
            continue
        wl = (r.get('anchor') or '').lower()
        con.execute('INSERT OR IGNORE INTO word_form (form,base,rule,kind,anchor,anchor_id,depth,in_vocab,action) '
                    'VALUES (?,?,?,?,?,?,?,?,?)',
                    (r['form'], r['base'], r.get('rule'), r.get('kind'), r.get('anchor'),
                     wid_of.get(wl), r.get('depth', 1), r.get('in_vocab', 0), r.get('action', 'keep')))
        stats['word_form'] += 1

    # ── 5. card / card_extra ──
    # 🔴 2026-09-26 **已移到末尾（第 13 步）**
    #   原因：制卡需要**全部素材表已落库** —— `word_morpheme`（幻觉过滤后的词素）、
    #        `word_collocation`、`word_etymon`、`cognate_group`、`aggregate_page`（入口 id）。
    #   旧实现在这里组装 → 只能用 LLM 原始数据，拿不到过滤结果，也拿不到聚合页 id。
    #   见文件末尾「13. card / card_extra」。

    # ── 6/7. word_root + word_morpheme ──
    root_idx = {}
    bad_morpheme = []
    for wl, wid in wid_of.items():
        d = rec_by_word[wl]['data']
        mo = d.get('morphology') or {}
        if not mo.get('analyzable'):
            continue
        parts = mo.get('parts') or []
        # 🔴 幻觉过滤：单字母词素
        #   实测两类：① prefix/suffix 的 `-d`(bidding) `-n`(given)
        #            ② **root 的 `-o-`/`-u-`（连接元音 combining vowel）** —— technology 的 techno+logy
        #   判据：单字符一律拦（真后缀 -s/-y/-a/-e 除外；root 没有单字母的）
        clean = []
        for p in parts:
            f = (p.get('form') or '').strip()
            t = (p.get('type') or '').strip().lower()
            bare = f.strip('-').lower()
            if len(bare) <= 1:
                ok_suffix = (t == 'suffix' and bare in SUFFIX_WHITELIST_1)
                ok_prefix = (t == 'prefix' and bare in PREFIX_WHITELIST_1)
                if not (ok_suffix or ok_prefix):
                    bad_morpheme.append((wl, f, t))
                    continue
            clean.append(p)
        if not clean:
            continue
        for pos, p in enumerate(clean):
            f = (p.get('form') or '').strip()
            t = (p.get('type') or '').strip().lower()
            if t == 'root':
                key = (f.lower(), 'root', (p.get('origin') or '').strip())
                rid = root_idx.get(key)
                if not rid:
                    cur = con.execute('INSERT OR IGNORE INTO word_root (form,type,meaning,origin) VALUES (?,?,?,?)',
                                      (f, 'root', p.get('meaning'), p.get('origin')))
                    rid = cur.lastrowid
                    if not rid:
                        rid = con.execute('SELECT id FROM word_root WHERE form=? AND type=? AND origin IS ?',
                                          (f, 'root', p.get('origin'))).fetchone()[0]
                    root_idx[key] = rid
                con.execute('INSERT OR REPLACE INTO word_morpheme '
                            '(word_id,position,type,affix_id,root_id,surface,gloss,relation) VALUES (?,?,?,?,?,?,?,?)',
                            (wid, pos, 'root', None, rid, f, p.get('meaning'), mo.get('relation')))
            else:
                aid = (alias_idx.get((f.lower(), t, (p.get('meaning') or '').strip().lower()))
                       or affix_idx.get((f.lower(), t, 'general')))
                if aid is None:
                    # 词缀表没这个义 → 允许新增（白哥方案）
                    cur = con.execute('INSERT OR IGNORE INTO affix (form,type,sense,meaning_zh,needs_review) '
                                      'VALUES (?,?,?,?,1)', (f, t, 'auto_' + str(abs(hash((f, t, p.get('meaning')))) % 10000),
                                                             p.get('meaning') or ''))
                    aid = cur.lastrowid or con.execute(
                        'SELECT id FROM affix WHERE form=? AND type=? ORDER BY id DESC LIMIT 1', (f, t)).fetchone()[0]
                con.execute('INSERT OR REPLACE INTO word_morpheme '
                            '(word_id,position,type,affix_id,root_id,surface,gloss,relation) VALUES (?,?,?,?,?,?,?,?)',
                            (wid, pos, t, aid, None, f, p.get('meaning'), mo.get('relation')))
            stats['word_morpheme'] += 1

    # ── 8/9. etymon + word_etymon ──
    #   🔑 先套归一化映射（`normalize_etymon.py` 产出）：
    #     同一源词的不同转写（`grafein`/`graphein` · `iustus`/`justus` · `up`/`upp`）
    #     归到同一 canonical → `UNIQUE(form_ascii,language)` 才能合并、词源族才不被打散。
    #     实测 149 组合并、299 个 etymon → 149 canonical；影响 108 组族（其中 18 组原本完全不成页）。
    canon_map, alias_map = {}, defaultdict(set)
    if ET_CANON and os.path.exists(ET_CANON):
        cj = json.load(open(ET_CANON, encoding='utf-8'))
        for g in cj.get('merged', []):
            lang = (g.get('language') or '').lower()
            canon = g['canonical']
            for m in g['members']:
                canon_map[(m.lower(), lang)] = canon
                if m != canon:
                    alias_map[(canon.lower(), lang)].add(m)
        print(f'  词源归一化: {len(cj.get("merged", []))} 组合并 · '
              f'{len(canon_map)} 个拼写映射到 canonical')

    def et_key(form_ascii, language):
        return ((form_ascii or '').lower(), (language or '').lower())

    def et_canon(form_ascii, language):
        return canon_map.get(et_key(form_ascii, language), form_ascii or '')

    et_idx = {}
    for r in et_chained:
        ck = et_key(et_canon(r.get('form_ascii'), r.get('language')), r.get('language'))
        if not ck[0]:
            continue
        # 显示形：若该 canonical 是某个成员，用它原本的 `form`；否则用 canonical
        con.execute('INSERT OR IGNORE INTO etymon (form,form_ascii,language,meaning_zh,depth) VALUES (?,?,?,?,?)',
                    (ck[0], r.get('form_ascii') if et_canon(r.get('form_ascii'), r.get('language')) == r.get('form_ascii') else ck[0],
                     r.get('language'), r.get('meaning'), r.get('depth', 0)))
        row = con.execute('SELECT id FROM etymon WHERE form_ascii=? AND language=?',
                          (ck[0], r.get('language'))).fetchone()
        if row:
            et_idx[ck] = row[0]
            et_idx[et_key(r.get('form_ascii'), r.get('language'))] = row[0]   # 原拼写也指向它
            stats['etymon'] += 1
    # canonical 的别名写入 note（供聚合页显示「weorc / work」）
    for (cf, cl), al in alias_map.items():
        eid = et_idx.get((cf.lower(), cl))
        if eid and al:
            con.execute('UPDATE etymon SET note=? WHERE id=?',
                        (' / '.join(sorted(al)), eid))
    # 回填 parent_id —— 🔑 **同时按 `form_ascii` 与「原文形 `form`」两个索引查**
    #   实测 bug：`parent` 是 LLM 给的**原文形**（可能是非 ASCII：`æfnian` · `χάρτης` ·
    #   `mystērion` · `εἰρήνη`），而原实现只按 `form_ascii` 查 → **115 条解析失败**，
    #   整条词源链在此断掉，该 etymon 被当成「根本源词」→ 族被拆小。
    by_ascii_idx, by_form_idx = {}, {}
    for (fa, lang), eid in et_idx.items():
        by_ascii_idx[(fa, lang)] = eid
    for row in con.execute('SELECT id, form, form_ascii, language FROM etymon'):
        by_form_idx[(row[1].lower(), (row[3] or '').lower())] = row[0]
        by_ascii_idx.setdefault((row[2].lower(), (row[3] or '').lower()), row[0])

    resolved = 0
    for r in et_chained:
        lang = (r.get('language') or '').lower()
        eid = et_idx.get(et_key(et_canon(r.get('form_ascii'), r.get('language')), r.get('language')))
        if not eid:
            continue
        p_raw = (r.get('parent') or '').strip()
        par = None
        if p_raw:
            pl = p_raw.lower()
            par = (by_ascii_idx.get((et_canon(p_raw, r.get('language')).lower(), lang))
                   or by_form_idx.get((pl, lang))
                   or by_ascii_idx.get((pl, lang)))
        if par and par != eid:
            con.execute('UPDATE etymon SET parent_id=? WHERE id=?', (par, eid))
            resolved += 1
    print(f'  词源 parent 解析成功: {resolved} 条')
    # 合并组的 parent 传播：canonical 自身 parent 为空时，取任一成员的 parent
    #   （实测：`iniungere` 无 parent，但被合并的 `injungere` 有 → 否则链断）
    con.execute("""
        UPDATE etymon SET parent_id = (
            SELECT e2.parent_id FROM etymon e2
            WHERE e2.parent_id IS NOT NULL AND e2.id <> etymon.id
              AND lower(e2.form_ascii) IN (
                  SELECT lower(trim(value)) FROM json_each('["' ||
                     replace(coalesce(etymon.note,''),' / ','","') || '"]'))
            LIMIT 1)
        WHERE parent_id IS NULL AND note IS NOT NULL AND note <> ''""")

    # 🔑 anchor_id + depth：**合并后用递归 CTE 重算**
    #   原实现直接信 `etymon_chained.json` 的 `anchor_ascii`（归一化**之前**算的）
    #   → 合并后的图变了，锚点必须重算，否则族还是按老结构聚。
    con.execute('UPDATE etymon SET anchor_id = id, depth = 0')
    con.execute("""
        WITH RECURSIVE up(id, cur, d) AS (
            SELECT id, id, 0 FROM etymon
            UNION ALL
            SELECT up.id, e.parent_id, up.d + 1
            FROM up JOIN etymon e ON e.id = up.cur
            WHERE e.parent_id IS NOT NULL AND up.d < 10
        )
        UPDATE etymon SET
            anchor_id = (SELECT cur FROM up WHERE up.id = etymon.id ORDER BY d DESC LIMIT 1),
            depth     = (SELECT max(d) FROM up WHERE up.id = etymon.id)
    """)
    # 🔴 修 `parent_id = id` 自指（实测 8 条：hora / basis / dresser / papa …）
    #    —— 根本源词没有更早的上级，`parent_id` 应为 NULL 而非指向自身
    con.execute('UPDATE etymon SET parent_id = NULL WHERE parent_id = id')

    # 🔑 ① 直接链接（is_direct=1）：词 → 它自己的 etymon（**anchor 算完之后才插**）
    for wl, wid in wid_of.items():
        d = rec_by_word[wl]['data']
        for i, e in enumerate(((d.get('etymology') or {}).get('etyma') or [])):
            k = et_key(et_canon(e.get('form_ascii'), e.get('language')), e.get('language'))
            eid = et_idx.get(k)
            if eid:
                con.execute('INSERT OR IGNORE INTO word_etymon (word_id,etymon_id,role,is_direct,ord) '
                            'VALUES (?,?,?,?,?)', (wid, eid, e.get('role'), 1, i))
                stats['word_etymon'] += 1

    # 🔑 ② anchor 链接（`is_direct=0`）：让「按根本源词聚合」可直接查 word_etymon
    #    （设计里 `is_direct` 就是用来「区分直接源 / 根本」的，此前全被写成 1）
    con.execute("""
        INSERT OR IGNORE INTO word_etymon (word_id, etymon_id, role, is_direct, ord)
        SELECT we.word_id, e.anchor_id, 'root', 0, 99
        FROM word_etymon we JOIN etymon e ON e.id = we.etymon_id
        WHERE e.anchor_id IS NOT NULL AND e.anchor_id <> e.id
          AND we.is_direct = 1""")
    con.execute('UPDATE word_form SET anchor_id = (SELECT id FROM word WHERE lower(spelling)=lower(word_form.anchor)) '
                'WHERE anchor_id IS NULL AND anchor IS NOT NULL')

    # ── 10. collocation ──
    #   数据源（2026-09-26 实测：两者仅 33% 重合，**互补性强**）：
    #     ① LLM 的 `collocations[]` —— 质量高（中文齐全、无错位），默认启用的来源
    #     ② 现网 `related_phrases` 解析（`collocation_parsed.json`）—— 存量资产
    #        ⚠️ 仅在 `--merge-legacy-collocations` 时并入，且**去重优先用 LLM 的中文**
    coll_idx = {}

    def put_coll(ph, zh, wid, ordi):
        ph = (ph or '').strip()
        if not ph or re.match(r'^\(', ph) or len(ph) > 80:
            return False
        key = ph.lower()
        cid = coll_idx.get(key)
        if not cid:
            cur = con.execute('INSERT OR IGNORE INTO collocation (phrase,chinese) VALUES (?,?)', (ph, zh))
            cid = cur.lastrowid
            if not cid:
                cid = con.execute('SELECT id FROM collocation WHERE phrase=?', (ph,)).fetchone()[0]
            coll_idx[key] = cid
        elif zh and not con.execute('SELECT chinese FROM collocation WHERE id=?', (cid,)).fetchone()[0]:
            # LLM 的中文优先；现网解析只补空缺
            con.execute('UPDATE collocation SET chinese=? WHERE id=?', (zh, cid))
        con.execute('INSERT OR IGNORE INTO word_collocation (word_id,collocation_id,ord) VALUES (?,?,?)',
                    (wid, cid, ordi))
        stats['word_collocation'] += 1
        return True

    legacy_by_word, legacy_only_log = {}, []
    if merge_legacy and os.path.exists(LEGACY_COLLOC_JSON):
        lj = json.load(open(LEGACY_COLLOC_JSON, encoding='utf-8'))
        for it in lj['items']:
            legacy_by_word.setdefault(it['word'].lower(), []).append(
                (it['phrase'], (it['chinese'] or '').strip()))

    for wl, wid in wid_of.items():
        d = rec_by_word[wl]['data']
        llm_ph = set()
        for i, c in enumerate((d.get('collocations') or [])):
            ph = (c.get('phrase') or '').strip()
            if put_coll(ph, c.get('zh'), wid, i):
                llm_ph.add(ph.lower())
        if merge_legacy:
            j = len(llm_ph)
            for ph, zh in legacy_by_word.get(wl, []):
                if ph.strip().lower() in llm_ph:
                    continue          # LLM 已有 → 不重复（中文也优先 LLM）
                if put_coll(ph, zh, wid, j):
                    j += 1
                    legacy_only_log.append({'word': wl, 'phrase': ph, 'chinese': zh})

    # ── 11. cognate_group（词根族）──
    #   🔴 修正（2026-09-26 复核发现）：**必须按 `root_id` 成组，不能按 form 字符串**。
    #      原实现按 `p['form'].lower()` 成组 → **同形异源词根被错误合并**。
    #      实测 **110 个族**受影响，最严重的 `man`：32 词混了「人」(Old English) 与「停留」(Latin)
    #      —— `policeman`/`mankind` 与 `permanence`/`remain` 根本不是一族。
    #      `word_root` 已用 `UNIQUE(form,type,origin)` 把同形异源分开存 → 这里按 id 成组即可对齐。
    by_root = defaultdict(list)
    for wid, rid, gloss in con.execute("""
            SELECT m.word_id, m.root_id, m.gloss FROM word_morpheme m
            JOIN word_root r ON r.id = m.root_id
            WHERE m.type = 'root'
              AND (m.relation IS NULL OR m.relation <> 'inflection')"""):
        by_root[rid].append((wid, gloss))
    for rid, members in by_root.items():
        row = con.execute('SELECT form, origin FROM word_root WHERE id=?', (rid,)).fetchone()
        form, origin = row[0], row[1]
        label = f'{form} 词根族' + (f'（{origin}）' if origin else '')
        con.execute('INSERT OR IGNORE INTO cognate_group (group_key,root_id,label,origin,size) '
                    'VALUES (?,?,?,?,?)', (form, rid, label, origin, len(members)))
        gid = con.execute('SELECT id FROM cognate_group WHERE root_id=?', (rid,)).fetchone()[0]
        for wid, gloss in members:
            con.execute('INSERT OR IGNORE INTO cognate_group_member (group_id,word_id,gloss) VALUES (?,?,?)',
                        (gid, wid, gloss))
        stats['cognate_group'] += 1

    # 回填 size（按「唯一词数」口径 —— 同一词可能有同 form 的多个词根，去重更准）
    con.execute('''UPDATE cognate_group SET size =
        (SELECT count(DISTINCT word_id) FROM cognate_group_member m WHERE m.group_id = cognate_group.id)''')

    # ── 12. aggregate_page（两类：root 词根族 + etymon 词源族）──
    #   成员列表带 `word` 拼写（供直接显示，免 join）+ `gloss`（该族内的中文提示）
    def word_zh(wl):
        """该词自身的中文释义（第一个义项的 chinese）"""
        for s in (src_defs.get(wl) or []):
            if (s.get('chinese') or '').strip():
                return s['chinese'].strip()[:30]
        return ''

    def spelling_of(wid):
        return wid_to_word.get(wid, '')

    # 12a. root 型
    #   🔴 修（2026-09-26）：`gloss` 原为**词根义**（"写" 重复 10 遍 → 对学习者无用），
    #      改为**该词自身的中文释义**；词根义移到 `section.source`。
    #      → 与 12b 的 etymon 型格式统一：`source` 放族的信息，`items[].gloss` 放单词释义。
    for gid, key, origin in con.execute(
            'SELECT id,group_key,origin FROM cognate_group WHERE size>=3 ORDER BY size DESC, group_key'):
        members = con.execute('SELECT word_id,gloss FROM cognate_group_member WHERE group_id=?', (gid,)).fetchall()
        members = [(w, g) for w, g in members if w in wid_to_word]
        if len(members) < 3:
            continue
        label = f'{key} 词根族' + (f'（{origin}）' if origin else '')
        items = []
        for w, root_gloss in members:
            sp = wid_to_word[w]
            items.append({'word': sp, 'word_id': w, 'gloss': word_zh(sp)})
        items.sort(key=lambda x: x['word'])
        content = json.dumps({'front': label, 'sections': [
            {'type': 'cognate_list',
             'source': {'form': key, 'type': 'root', 'origin': origin or '',
                        'meaning': next((g for _, g in members if g), '')},
             'items': items}]}, ensure_ascii=False)
        cur = con.execute('INSERT INTO aggregate_page (page_type,group_id,front,content,member_count) '
                          'VALUES (?,?,?,?,?)', ('root', gid, label, content, len(items)))
        pid = cur.lastrowid
        for i, it in enumerate(items):
            con.execute('INSERT OR IGNORE INTO aggregate_page_word (page_id,word_id,ord) VALUES (?,?,?)',
                        (pid, it['word_id'], i))
        stats['aggregate_page'] += 1

    # 12b. etymon 型（🆕 按 `anchor` 根本源词成组）
    #   🔑 口径是「**词数**」（页面列的是词），不是「etymon 节点数」：
    #     按节点数 ≥3 → 389 个族；按**词数** ≥3 → **1,014 个族**（差 2.6 倍，必须用词数）
    et_pages = con.execute("""
        SELECT e.anchor_id AS aid, count(DISTINCT we.word_id) AS c
        FROM word_etymon we JOIN etymon e ON e.id = we.etymon_id
        WHERE e.anchor_id IS NOT NULL
        GROUP BY e.anchor_id HAVING c >= 3
        ORDER BY c DESC, aid""").fetchall()
    for aid, c in et_pages:
        a = con.execute('SELECT form, language, meaning_zh, note FROM etymon WHERE id=?', (aid,)).fetchone()
        if not a:
            continue
        af, alang, amean, anote = a[0], a[1] or '', a[2] or '', a[3] or ''
        # 🔑 标题带上别名：归一化后 canonical 可能是**不好认的古拼法**
        #    （`weorc` 才是 OE 正确的源词，但用户不认识）→ 显示成 `weorc / work（Old English·工作）词源族`
        aliases = [x.strip() for x in anote.split('/') if x.strip()][:2]
        disp = ' / '.join([af] + aliases)
        label = f'{disp}（{alang}{"·" + amean if amean else ""}）词源族'
        members = con.execute("""
            SELECT DISTINCT we.word_id FROM word_etymon we
            JOIN etymon e ON e.id = we.etymon_id WHERE e.anchor_id = ?""", (aid,)).fetchall()
        items = []
        for (w,) in members:
            sp = spelling_of(w)
            if sp:
                items.append({'word': sp, 'word_id': w, 'gloss': word_zh(sp.lower())})
        if len(items) < 3:
            continue
        items.sort(key=lambda x: x['word'])
        content = json.dumps({'front': label, 'sections': [
            {'type': 'cognate_list',
             'source': {'form': af, 'aliases': aliases, 'language': alang, 'meaning': amean},
             'items': items}]}, ensure_ascii=False)
        cur = con.execute('INSERT INTO aggregate_page (page_type,etymon_id,front,content,member_count) '
                          'VALUES (?,?,?,?,?)', ('etymon', aid, label, content, len(items)))
        pid = cur.lastrowid
        for i, it in enumerate(items):
            con.execute('INSERT OR IGNORE INTO aggregate_page_word (page_id,word_id,ord) VALUES (?,?,?)',
                        (pid, it['word_id'], i))
        stats['aggregate_page'] += 1

    # ── 13. card / card_extra（2026-09-26 重组 · 按 v1 §4.2 + 白哥「库级可以就存在」）──
    #
    # 🔑 为什么放在最后：制卡需要**全部素材表已就绪**
    #    · `word_morpheme` —— 用**幻觉过滤后**的词素（不是 LLM 原始 parts）
    #    · `word_collocation` / `word_etymon` / `cognate_group` —— 各类素材
    #    · `aggregate_page` —— 入口要跳的 `page_id`
    #
    # 🔑 结构：
    #    sections = [ 记忆法×N（按 priority 1→6 排）, definition（首义）, context（例句） ]
    #
    # 四条设计决定（都对应一个已发生的偏离）：
    #  ① **例句独立成 `context` 段** —— 旧结构把它塞在 `sense` 里。
    #     v1 §6.2 朗读清单只认 `context`/`collocation`/`front` → 旧结构下**例句音频会全漏（240 MB）**。
    #     这是 Phase 2 语音包的前置修复。
    #  ② **存全部可用素材**，不只首段 —— 顺序/替换留给渲染层（白哥：「库级应该是可以就存在，
    #     而渲染端选择展示哪些、展示顺序、替换逻辑」）→ **改渲染规则不用重跑全库**。
    #  ③ **`aggregate_link` 不单列段**（白哥裁决）→ 入口 id 内嵌在 root/cognate/etymology 段里。
    #  ④ **其余义项 → `card_extra`**（v1 §5.2），首义进 `definition`。
    #
    # ⚠️ content 的段数（最多 6）**不等于渲染后的段数（4）** ——
    #    v1 §5.1「section ≤ 4」是针对**渲染后的一页**：选 2 段记忆法 + definition + context。
    import hashlib

    def _morph_parts(wid):
        """幻觉过滤后的词素（按 position）"""
        rows = con.execute(
            "SELECT type,surface,gloss,relation FROM word_morpheme WHERE word_id=? ORDER BY position",
            (wid,)).fetchall()
        return [{'form': r[1], 'type': r[0], 'meaning': r[2], 'relation': r[3]} for r in rows]

    def _collocs(wid, limit=3):
        return [{'phrase': r[0], 'zh': r[1] or ''} for r in con.execute(
            "SELECT c.phrase, c.chinese FROM word_collocation wc "
            "JOIN collocation c ON c.id = wc.collocation_id "
            "WHERE wc.word_id=? ORDER BY wc.ord LIMIT ?", (wid, limit))]

    def _etyma(wid, limit=3):
        return [{'form': r[0], 'language': r[1] or '', 'meaning': r[2] or '', 'role': r[3] or ''}
                for r in con.execute(
                    "SELECT e.form, e.language, e.meaning_zh, we.role FROM word_etymon we "
                    "JOIN etymon e ON e.id = we.etymon_id WHERE we.word_id=? ORDER BY we.ord LIMIT ?",
                    (wid, limit))]

    def _page_of(wid, page_type):
        """该词所属聚合页（入口用）—— 门槛 ≥3 已在建页时保证"""
        r = con.execute(
            "SELECT a.id, a.front, a.member_count FROM aggregate_page a "
            "JOIN aggregate_page_word p ON p.page_id = a.id "
            "WHERE p.word_id=? AND a.page_type=? ORDER BY a.member_count DESC LIMIT 1",
            (wid, page_type)).fetchone()
        return {'page_id': r[0], 'label': r[1], 'size': r[2]} if r else None

    def _cognate_group(wid):
        r = con.execute(
            "SELECT g.id, g.label, g.size, g.origin FROM cognate_group_member m "
            "JOIN cognate_group g ON g.id = m.group_id "
            "WHERE m.word_id=? AND g.size>=3 ORDER BY g.size DESC LIMIT 1", (wid,)).fetchone()
        return {'group_id': r[0], 'label': r[1], 'size': r[2], 'origin': r[3] or ''} if r else None

    for wl, wid in wid_of.items():
        d = rec_by_word[wl]['data']
        senses = src_defs.get(wl) or []
        mo = d.get('morphology') or {}

        sections = []

        # ① 记忆法（按 priority 1→6：root → cognate → collocation → etymology）
        parts = _morph_parts(wid) if mo.get('analyzable') else []
        if parts:
            sec = {'type': 'root',
                   'payload': {'parts': parts, 'relation': mo.get('relation')}}
            pg = _page_of(wid, 'root')
            if pg:                                   # ③ 入口内嵌（不单列 aggregate_link）
                sec['payload']['entry'] = pg
            sections.append(sec)

        cg = _cognate_group(wid)
        if cg:
            pg = _page_of(wid, 'root')               # 同源串记 → 词根族页
            sections.append({'type': 'cognate',
                             'payload': {**cg, **({'entry': pg} if pg else {})}})

        cs = _collocs(wid)
        if cs:
            sections.append({'type': 'collocation', 'items': cs})

        et = _etyma(wid)
        etxt = (d.get('etymology') or {}).get('text') or ''
        if etxt or et:
            sec = {'type': 'etymology', 'text': etxt, 'etyma': et}
            pg = _page_of(wid, 'etymon')             # ③ 入口内嵌
            if pg:
                sec['entry'] = pg
            sections.append(sec)

        # ③ 释义（只 1 条首义）+ ④ 语境原句（只 1 条）
        if senses:
            s0 = senses[0]
            sections.append({'type': 'definition', 'order': 1, 'pos': s0.get('pos'),
                             'en': s0.get('meaning'), 'zh': s0.get('chinese')})
            ex = (s0.get('example') or '').strip()
            if ex:
                sections.append({'type': 'context', 'text': ex})

        # ④ 其余义项 → card_extra
        extra = [{'type': 'sense', 'order': i + 2, 'pos': s.get('pos'),
                  'en': s.get('meaning'), 'zh': s.get('chinese'),
                  'example': s.get('example')}
                 for i, s in enumerate(senses[1:])]

        content = {'front': wl, 'ipa': src_pron.get(wl), 'entry_type': d.get('entry_type'),
                   'sections': sections}
        cj = json.dumps(content, ensure_ascii=False)
        h = hashlib.sha256((cj + ''.join(json.dumps(e, ensure_ascii=False) for e in extra)).encode()).hexdigest()[:32]
        # 🔑 P1-8：content_hash 覆盖 card_extra
        con.execute('INSERT OR IGNORE INTO card (word_id,content,content_hash) VALUES (?,?,?)', (wid, cj, h))
        for j, e in enumerate(extra):
            con.execute('INSERT INTO card_extra (word_id,section,ord) VALUES (?,?,?)',
                        (wid, json.dumps(e, ensure_ascii=False), j))
            stats['card_extra'] += 1
        stats['card'] += 1

    # word_mnemonic_profile
    #
    # 🔴🔴 2026-09-28 治本改动：**不再直接用 LLM 判定的 `mn['primary']`**
    #   原实现是 `VALUES (mn['primary'], ...)` —— 完全没经过 `priority`。
    #   这就是「卡片排序**不经过优先级排序**」的病根（v1 §4.1 明文要求按 priority 选主/次）。
    #   只在存量数据上修一次治不了根：**下次重建词库会静默回退**。
    # → 现在先按 LLM 结果落库（保留 rationale / confidence），
    #   再由 `priority_redo.apply_order()` **按 priority 重算 primary/secondary** ——
    #   🔑 **与存量修复共用同一个函数**（单一出处，不会两套口径）。
    for wl, wid in wid_of.items():
        d = rec_by_word[wl]['data']
        mn = d.get('mnemonic') or {}
        raw_primary = mn.get('primary')
        if not raw_primary:
            continue
        if raw_primary in ('cognate',):
            # cognate 已整层摘除 → 不落库（其余 5 类是合法记忆法）
            raw_primary = 'context'
        con.execute('INSERT OR REPLACE INTO word_mnemonic_profile '
                    '(word_id,primary_code,secondary_codes,confidence,rationale) VALUES (?,?,?,?,?)',
                    (wid, raw_primary,
                     json.dumps([c for c in (mn.get('secondary') or []) if c != 'cognate'],
                                ensure_ascii=False),
                     d.get('confidence'), mn.get('rationale')))
        stats['word_mnemonic_profile'] += 1

    # 🔑 按 priority 重算 —— 单一出处：`scripts/priority_redo.py` 的 apply_order()
    from priority_redo import apply_order  # noqa: E402  （同目录脚本）
    n, ch_p, ch_s, no_cand = apply_order(con)
    stats['profile_reordered'] = n
    print('   ↳ 按 priority 重算 profile：%d 行（primary 改 %d · secondary 改 %d · 无候选 %d）'
          % (n, ch_p, ch_s, no_cand))

    if not args.dry_run:
        con.commit()

    # ── 校验 ──
    print()
    print('=' * 88)
    print('落库统计')
    print('=' * 88)
    for k, v in stats.most_common():
        print(f'  {k:<26} {v:>7}')
    print()
    print(f'  🔴 幻觉词素被过滤: {len(bad_morpheme)}  {bad_morpheme[:6]}')
    print(f'  链断（等补跑）: {sum(1 for r in wf_chained if r.get("action")=="pending")}')
    if merge_legacy:
        print(f'  🟠 现网搭配并入（LLM 未给的）: {len(legacy_only_log)} 条')
        out = os.path.join(PREBUILT, 'collocation_legacy_only.json')
        json.dump({'count': len(legacy_only_log), 'items': legacy_only_log},
                  open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print(f'     清单已写 {out}（供质检）')

    # 一致性校验
    q = [
        ('word.spelling 大小写唯一', "SELECT count(*) FROM (SELECT lower(spelling) s FROM word GROUP BY s HAVING count(*)>1)"),
        ('word_form 有 anchor 的比例', "SELECT round(100.0*sum(CASE WHEN anchor IS NOT NULL THEN 1 ELSE 0 END)/count(*),1) FROM word_form"),
        ('aggregate_page 数（族≥3）', "SELECT count(*) FROM aggregate_page"),
        ('cognate_group ≥3 的族', "SELECT count(*) FROM cognate_group WHERE size>=3"),
        # 🆕 2026-09-26 卡片结构自检（详见 scripts/verify_card_structure.py）
        ('🔑 有 context 段的卡（语音包前置）',
         "SELECT count(*) FROM card WHERE content LIKE '%\"type\": \"context\"%'"),
        ('🔑 `sense` 残留在 card 的数（应 0）',
         "SELECT count(*) FROM card WHERE content LIKE '%\"type\": \"sense\"%'"),
        ('有 definition 段的卡（应 = 全部）',
         "SELECT count(*) FROM card WHERE content LIKE '%\"type\": \"definition\"%'"),
        ('card_extra 行数（其余义项）', "SELECT count(*) FROM card_extra"),
    ]
    for label, sql in q:
        try:
            print(f'  {label:<30} {con.execute(sql).fetchone()[0]}')
        except Exception as e:
            print(f'  {label:<30} ⚠️ {e}')

    con.close()
    if args.dry_run:
        print('\n  （dry-run，未落盘）')
    else:
        sz = os.path.getsize(args.db) / 1024
        print(f'\n  已写 {args.db}（{sz:.0f} KB）')


def from_sample_meta(r):
    return 'level' not in r


if __name__ == '__main__':
    main()
