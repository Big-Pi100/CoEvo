#!/usr/bin/env python3
"""增量聚类引擎 —— 新词入库时更新聚类

## 为什么需要它

「词库从『预先建满』改为『按需生长』」的核心技术点：
新词（LLM 生成）必须**无缝并入已有聚类**，否则：
  · 它的词根族看不到它（聚合页缺人）
  · 已有的 2 词族加入第 3 词后**本该建页却不会建**（用户看不到新聚合页）

## 与 `load_llm_results.py` 的关系

`load_llm_results.py` 是**全量批量**（一次 13 步重建整库，内存里维护 `root_idx` 等批内缓存）。
本模块是**单条增量**：只改「这一个词 + 它牵连到的族」，其余不动。

**聚类逻辑必须与批量版完全一致**，否则两条路会产出不同的库：
  · 词根按 `(form, type, origin)` **三元组**匹配（不能只用 form —— 实测 116 个同形异源词根）
  · `cognate_group` 按 `root_id` 成组（`UNIQUE(root_id)`）
  · 聚合页门槛 **≥3**（v1 §8.5）

## 门槛跨越（本模块的关键贡献）

批量版是「先建完所有族，再统一建页」，天然处理了门槛。
增量版必须**显式检测跨越**：
  · 族 size 从 <3 → ≥3  ⟹ **新建聚合页**
  · 族 size 从 ≥3 → <3  ⟹ **删除聚合页**
  · 否则                ⟹ 更新 `member_count` + 成员列表

## 用法

    from incremental_clustering import add_word, remove_word, refresh_clusters

    rid, created = match_or_create_root(con, 'cept', 'root', 'Latin', '拿取')
    add_word(con, spec)          # spec 见 verify_incremental_clustering.py
"""

from collections import defaultdict

# 🔑 聚合页 content / label 的**唯一产出点**（与 `load_llm_results` 共用）
#    · 本文件原先自己拼 `{'members': [...]}`，与现网格式**完全不同**
#      → 用本引擎新建的聚合页，端侧读 `d['sections'][0]` 读不到 →
#        `source=null` + 成员无释义，**且不报错**（端侧 try/catch 故意静默）
#    · 修法是**消灭分叉**（两边都调这里），不是把格式改成另一边的样子
import aggregate_page_content as apc  # noqa: E402

PAGE_THRESHOLD = 3   # v1 §8.5「成员数 ≥ N（如 3）」


# ─────────────────────────────────────────────────────────────
# ① 词根匹配 / 新建
# ─────────────────────────────────────────────────────────────
def match_or_create_root(con, form, type_='root', origin=None, meaning=None):
    """按 `(form, type, origin)` 三元组匹配已有 `word_root`，无则新建。

    为什么必须带 `origin`：实测 **116 个同形异源**词根（如 `man` = 「人」OE
    与「停留」Latin 是两条记录）。只用 form 匹配会把它们错误合并 ——
    这正是批量版曾经踩过的坑（110 个族被污染）。

    返回 `(root_id, created: bool)`。
    """
    form = (form or '').strip()
    origin = (origin or '').strip() or None
    if not form:
        raise ValueError('词根 form 不能为空')

    # `origin IS ?` 才能正确处理 NULL（SQL 里 NULL != NULL）
    row = con.execute(
        'SELECT id FROM word_root WHERE form=? AND type=? AND origin IS ?',
        (form, type_, origin)).fetchone()
    if row:
        return row[0], False

    cur = con.execute(
        'INSERT INTO word_root (form, type, meaning, origin) VALUES (?,?,?,?)',
        (form, type_, meaning, origin))
    return cur.lastrowid, True


def match_or_create_affix(con, form, type_, meaning=None):
    """词缀匹配：与批量版同策略 —— 匹配不到就新增并标 `needs_review=1`。"""
    if type_ not in ('prefix', 'suffix'):
        return None
    row = con.execute('SELECT id FROM affix WHERE form=? AND type=? ORDER BY id LIMIT 1',
                      (form, type_)).fetchone()
    if row:
        return row[0]
    cur = con.execute(
        'INSERT INTO affix (form, type, sense, meaning_zh, needs_review) VALUES (?,?,?,?,1)',
        (form, type_, 'auto_incr', meaning or ''))
    return cur.lastrowid


# ─────────────────────────────────────────────────────────────
# ② 单条入库（word / word_morpheme / word_etymon / card）
# ─────────────────────────────────────────────────────────────
def next_sort_seq(con):
    return (con.execute('SELECT COALESCE(MAX(sort_seq), 0) FROM word').fetchone()[0] or 0) + 1


def add_word(con, spec, wid=None):
    """把一个新词写入词库（**不含聚类更新** —— 那由 `refresh_clusters` 负责）。

    `spec` 形如：
        {'spelling': 'interception',
         'entry_type': 'word',
         'morphology': {'analyzable': True, 'relation': None,
                        'parts': [{'form': 'inter', 'type': 'prefix', 'meaning': '在…之间'},
                                  {'form': 'cept',   'type': 'root',   'meaning': '拿取', 'origin': 'Latin'},
                                  {'form': 'ion',    'type': 'suffix', 'meaning': '名词后缀'}]},
         'etymology': {'text': '…', 'etyma': [{'form': 'capere', 'language': 'Latin',
                                               'meaning_zh': '拿取'}]},
         'card': {'front': 'interception', 'sections': [...]}}

    返回 `(word_id, 受影响的 root_id 集合, 受影响的 etymon 集合)`。
    """
    spelling = spec['spelling'].strip()
    entry_type = spec.get('entry_type') or 'word'

    if wid is None:
        wid = f'w{next_sort_seq(con):06d}'
    con.execute(
        'INSERT INTO word (id, sort_seq, spelling, entry_type, etymology_text) '
        'VALUES (?,?,?,?,?)',
        (wid, next_sort_seq(con), spelling, entry_type,
         (spec.get('etymology') or {}).get('text')))

    # ── 词素 ──
    affected_roots = set()
    mo = spec.get('morphology') or {}
    if mo.get('analyzable'):
        for pos, p in enumerate(mo.get('parts') or []):
            f = (p.get('form') or '').strip()
            t = (p.get('type') or '').strip().lower()
            bare = f.strip('-')
            # 幻觉词素过滤（与批量版同一套判据）
            if len(bare) <= 1 and not (t == 'suffix' and bare in ('s', 'y', 'a', 'e')):
                continue
            if t == 'root':
                rid, _ = match_or_create_root(con, f, 'root', p.get('origin'),
                                              p.get('meaning'))
                affected_roots.add(rid)
                con.execute(
                    'INSERT OR REPLACE INTO word_morpheme '
                    '(word_id,position,type,affix_id,root_id,surface,gloss,relation) '
                    'VALUES (?,?,?,?,?,?,?,?)',
                    (wid, pos, 'root', None, rid, f, p.get('meaning'), mo.get('relation')))
            else:
                aid = match_or_create_affix(con, f, t, p.get('meaning'))
                con.execute(
                    'INSERT OR REPLACE INTO word_morpheme '
                    '(word_id,position,type,affix_id,root_id,surface,gloss,relation) '
                    'VALUES (?,?,?,?,?,?,?,?)',
                    (wid, pos, t, aid, None, f, p.get('meaning'), mo.get('relation')))

    # ── 词源 ──
    affected_etyma = set()
    et = spec.get('etymology') or {}
    for ord_, e in enumerate(et.get('etyma') or []):
        eid = _match_or_create_etymon(con, e)
        affected_etyma.add(eid)
        con.execute(
            'INSERT OR REPLACE INTO word_etymon (word_id, etymon_id, ord, role) '
            'VALUES (?,?,?,?)',
            (wid, eid, ord_, e.get('role') or 'source'))

    # ── 卡片 ──
    if spec.get('card'):
        import json
        content = json.dumps(spec['card'], ensure_ascii=False)
        con.execute('INSERT OR REPLACE INTO card (word_id, content) VALUES (?,?)',
                    (wid, content))

    return wid, affected_roots, affected_etyma


def _match_or_create_etymon(con, e):
    """etymon 匹配：`(form, form_ascii)` 双列（NOCASE 只折叠 ASCII，故存双份）。"""
    import unicodedata
    form = (e.get('form') or '').strip()
    ascii_form = (e.get('form_ascii') or '').strip()
    if not ascii_form:
        ascii_form = ''.join(c for c in unicodedata.normalize('NFKD', form)
                             if not unicodedata.combining(c))
    row = con.execute('SELECT id FROM etymon WHERE form_ascii=? AND language IS ?',
                      (ascii_form, e.get('language'))).fetchone()
    if row:
        return row[0]
    cur = con.execute(
        'INSERT INTO etymon (form, form_ascii, language, meaning_zh) VALUES (?,?,?,?)',
        (form, ascii_form, e.get('language'), e.get('meaning_zh')))
    return cur.lastrowid


# ─────────────────────────────────────────────────────────────
# ③ 聚类刷新（含门槛跨越检测）—— 本模块的核心
# ─────────────────────────────────────────────────────────────
def refresh_clusters(con, root_ids=(), etymon_ids=()):
    """重算受影响族/词源族的 size，并处理**门槛跨越**。

    返回报告：新建/删除了哪些聚合页。
    """
    report = {'root': {'resized': [], 'pages_created': [], 'pages_deleted': [],
                       'pages_updated': []},
              'etymon': {'resized': [], 'pages_created': [], 'pages_deleted': [],
                         'pages_updated': []}}

    # ── 词根族 ──
    for rid in root_ids:
        gid, size = _sync_root_group(con, rid)
        if gid is None:
            continue
        report['root']['resized'].append((rid, size))
        _sync_root_page(con, gid, rid, size, report['root'])

    # ── 词源族 ──
    for eid in etymon_ids:
        size = con.execute('SELECT count(DISTINCT word_id) FROM word_etymon '
                           'WHERE etymon_id=?', (eid,)).fetchone()[0]
        report['etymon']['resized'].append((eid, size))
        _sync_etymon_page(con, eid, size, report['etymon'])

    return report


def _sync_root_group(con, rid):
    """重算该词根族的成员与 size（`cognate_group` 是 `UNIQUE(root_id)`）。"""
    row = con.execute('SELECT id FROM cognate_group WHERE root_id=?', (rid,)).fetchone()
    if row:
        gid = row[0]
    else:
        r = con.execute('SELECT form, origin FROM word_root WHERE id=?', (rid,)).fetchone()
        if not r:
            return None, 0
        form, origin = r[0], r[1]
        label = apc.root_label(form, origin)
        cur = con.execute('INSERT INTO cognate_group (group_key, root_id, label, origin, size) '
                          'VALUES (?,?,?,?,0)', (form, rid, label, origin))
        gid = cur.lastrowid

    members = con.execute("""
        SELECT m.word_id, m.gloss FROM word_morpheme m
        WHERE m.type='root' AND m.root_id=?
          AND (m.relation IS NULL OR m.relation <> 'inflection')""", (rid,)).fetchall()

    con.execute('DELETE FROM cognate_group_member WHERE group_id=?', (gid,))
    for wid, gloss in members:
        con.execute('INSERT OR IGNORE INTO cognate_group_member (group_id,word_id,gloss) '
                    'VALUES (?,?,?)', (gid, wid, gloss))
    size = con.execute('SELECT count(DISTINCT word_id) FROM cognate_group_member '
                       'WHERE group_id=?', (gid,)).fetchone()[0]
    con.execute('UPDATE cognate_group SET size=? WHERE id=?', (size, gid))
    return gid, size


def _sync_root_page(con, gid, rid, size, bucket):
    """🔑 门槛跨越检测 —— 增量版必须显式做，批量版是天然处理的。"""
    page = con.execute("SELECT id, member_count FROM aggregate_page "
                       "WHERE page_type='root' AND group_id=?", (gid,)).fetchone()

    if size >= PAGE_THRESHOLD and page is None:
        # ⬆️ 跨过门槛：新建聚合页
        pid = _build_root_page(con, gid, rid)
        bucket['pages_created'].append((gid, size, pid))
    elif size < PAGE_THRESHOLD and page is not None:
        # ⬇️ 跌破门槛：删页
        con.execute('DELETE FROM aggregate_page_word WHERE page_id=?', (page[0],))
        con.execute('DELETE FROM aggregate_page WHERE id=?', (page[0],))
        bucket['pages_deleted'].append((gid, size, page[0]))
    elif page is not None:
        # ➡️ 门槛内变化：更新成员与计数
        _rebuild_page_members(con, page[0], gid, 'root')
        con.execute('UPDATE aggregate_page SET member_count=? WHERE id=?', (size, page[0]))
        bucket['pages_updated'].append((gid, size, page[0]))


def _sync_etymon_page(con, eid, size, bucket):
    page = con.execute("SELECT id, member_count FROM aggregate_page "
                       "WHERE page_type='etymon' AND etymon_id=?", (eid,)).fetchone()
    if size >= PAGE_THRESHOLD and page is None:
        pid = _build_etymon_page(con, eid)
        bucket['pages_created'].append((eid, size, pid))
    elif size < PAGE_THRESHOLD and page is not None:
        con.execute('DELETE FROM aggregate_page_word WHERE page_id=?', (page[0],))
        con.execute('DELETE FROM aggregate_page WHERE id=?', (page[0],))
        bucket['pages_deleted'].append((eid, size, page[0]))
    elif page is not None:
        _rebuild_page_members(con, page[0], eid, 'etymon')
        con.execute('UPDATE aggregate_page SET member_count=? WHERE id=?', (size, page[0]))
        bucket['pages_updated'].append((eid, size, page[0]))


def _source_of(con, kind, group_or_etymon_id):
    """从数据源**重算** `section.source`（仅在现有 content 读不出时兜底）。"""
    if kind == 'root':
        row = con.execute('SELECT group_key, origin FROM cognate_group WHERE id=?',
                          (group_or_etymon_id,)).fetchone()
        if not row:
            return None
        key, origin = row[0], row[1]
        meaning = con.execute(
            'SELECT gloss FROM cognate_group_member WHERE group_id=? AND gloss IS NOT NULL '
            'AND gloss <> '' LIMIT 1', (group_or_etymon_id,)).fetchone()
        return apc.root_source(key, origin, meaning[0] if meaning else '')
    e = con.execute('SELECT form, language, meaning_zh, note FROM etymon WHERE id=?',
                    (group_or_etymon_id,)).fetchone()
    if not e:
        return None
    return apc.etymon_source(e[0], apc.etymon_aliases(e[3]), e[1] or '', e[2] or '')


def _rebuild_page_members(con, page_id, group_or_etymon_id, kind):
    """重建某聚合页的**成员列表（含 `ord`）+ content**。

    root 型：成员 = 该词根族的词 · etymon 型：成员 = 该词源的词

    # 🔴 2026-09-29 修：原实现**只改 `aggregate_page_word`，不重建 `content`**
    后果：成员**能出现在列表里**（端侧按 `JOIN aggregate_page_word` 取），
    但 `items[].gloss`（成员行的**释义**）**永远不更新**——它存在
    `content.sections[0].items[]` 里，而 content 没被重算 → 端侧成员行无释义。
    ⚠️ 而且**不报错**（端侧那层 `try/catch` 故意静默）→ 静默失效。

    # 页头信息从现有 content **保留**
    `front` / `source` 描述的是「**族**」（词根义、语种），不随成员增减变化 →
    保留可避免「因源数据漂移而改动页头」。读不出时（旧格式/坏数据）才重算。

    # `ord` 用**字母序**
    现网 1,777 个聚合页实测 **100% 是字母序**（`load_llm_results` 用排序后的 items 枚举）
    → 原实现在这里用 `sort_seq`，会产出与现网不同的库（分叉点之一）。
    """
    if kind == 'root':
        rows = con.execute("""
            SELECT m.word_id, w.spelling, c.content FROM cognate_group_member m
            JOIN word w ON w.id = m.word_id
            LEFT JOIN card c ON c.word_id = m.word_id
            WHERE m.group_id=?""", (group_or_etymon_id,)).fetchall()
    else:
        rows = con.execute("""
            SELECT we.word_id, w.spelling, c.content FROM word_etymon we
            JOIN word w ON w.id = we.word_id
            LEFT JOIN card c ON c.word_id = we.word_id
            WHERE we.etymon_id=?""", (group_or_etymon_id,)).fetchall()

    items = apc.sort_items([
        apc.make_item(sp, wid, apc.zh_from_card_content(cc))
        for wid, sp, cc in rows
    ])

    # ① 关联表（`ord` 用与 content.items **相同**的顺序）
    con.execute('DELETE FROM aggregate_page_word WHERE page_id=?', (page_id,))
    for ord_, it in enumerate(items):
        con.execute('INSERT OR IGNORE INTO aggregate_page_word (page_id, word_id, ord) '
                    'VALUES (?,?,?)', (page_id, it['word_id'], ord_))

    # ② content（页头保留 · 成员重算）
    page = con.execute('SELECT front, content FROM aggregate_page WHERE id=?',
                       (page_id,)).fetchone()
    if not page:
        return
    front = page[0]
    _, source, _ = apc.read_back(page[1])
    if source is None:                      # 旧格式/坏数据 → 从数据源兜底重算
        source = _source_of(con, kind, group_or_etymon_id)
    if source is None:
        return                              # 数据源也查不到 → 保持原样（不动）
    con.execute('UPDATE aggregate_page SET content=? WHERE id=?',
                (apc.dump_content(front, source, items), page_id))


def _build_root_page(con, gid, rid):
    """建 root 型（词根族）聚合页。

    🔑 结构（content/label/排序）全部由 `aggregate_page_content` 产出 ——
       与 `load_llm_results` 共用同一份定义，两条路产出的库**逐字节一致**。

    ⚠️ 两处与原实现不同（都是**对齐现网口径**，不是新设计）：
      · `items[].gloss` 改为**该词自身的中文释义**（原为词根义，会重复 N 遍）；
        词根义移到 `section.source.meaning` —— 这正是 `load_llm_results` 2026-09-26 的修法。
      · `ord` 用**字母序**（现网 1,777 页实测 100% 是字母序），原实现用 `sort_seq`。
    """
    row = con.execute('SELECT group_key, origin FROM cognate_group WHERE id=?', (gid,)).fetchone()
    key, origin = row[0], row[1]
    label = apc.root_label(key, origin)

    rows = con.execute("""
        SELECT m.word_id, w.spelling, m.gloss, c.content
        FROM cognate_group_member m
        JOIN word w ON w.id = m.word_id
        LEFT JOIN card c ON c.word_id = m.word_id
        WHERE m.group_id=?""", (gid,)).fetchall()
    # 词根义 → source.meaning（取第一个非空，与 load_llm_results 同口径）
    meaning = next((mg for _, _, mg, _ in rows if mg), '')
    items = apc.sort_items([
        apc.make_item(sp, wid, apc.zh_from_card_content(cc))
        for wid, sp, _mg, cc in rows
    ])

    content = apc.dump_content(label, apc.root_source(key, origin, meaning), items)
    cur = con.execute(
        'INSERT INTO aggregate_page (page_type, group_id, front, content, member_count) '
        'VALUES (?,?,?,?,?)', ('root', gid, label, content, len(items)))
    pid = cur.lastrowid
    for ord_, it in enumerate(items):
        con.execute('INSERT OR IGNORE INTO aggregate_page_word (page_id,word_id,ord) '
                    'VALUES (?,?,?)', (pid, it['word_id'], ord_))
    return pid


def _build_etymon_page(con, eid):
    """建 etymon 型（词源族）聚合页。

    🔑 标题带**别名**（`etymon.note`，`/` 分隔）—— 归一化后的 canonical 常是
       不好认的古拼法（`weorc`），标题要显示成 `weorc / work（Old English·工作）词源族`。
       与 `load_llm_results` 同口径（见 `aggregate_page_content.etymon_label`）。
    """
    e = con.execute('SELECT form, language, meaning_zh, note FROM etymon WHERE id=?',
                    (eid,)).fetchone()
    if not e:
        return None
    form, lang, mean, note = e[0], e[1] or '', e[2] or '', e[3]
    aliases = apc.etymon_aliases(note)
    label = apc.etymon_label(form, aliases, lang, mean)

    rows = con.execute("""
        SELECT we.word_id, w.spelling, c.content FROM word_etymon we
        JOIN word w ON w.id = we.word_id
        LEFT JOIN card c ON c.word_id = we.word_id
        WHERE we.etymon_id=?""", (eid,)).fetchall()
    items = apc.sort_items([
        apc.make_item(sp, wid, apc.zh_from_card_content(cc))
        for wid, sp, cc in rows
    ])

    content = apc.dump_content(label, apc.etymon_source(form, aliases, lang, mean), items)
    cur = con.execute(
        'INSERT INTO aggregate_page (page_type, etymon_id, front, content, member_count) '
        'VALUES (?,?,?,?,?)', ('etymon', eid, label, content, len(items)))
    pid = cur.lastrowid
    for ord_, it in enumerate(items):
        con.execute('INSERT OR IGNORE INTO aggregate_page_word (page_id,word_id,ord) '
                    'VALUES (?,?,?)', (pid, it['word_id'], ord_))
    return pid


# ─────────────────────────────────────────────────────────────
# ④ 便捷入口：加入一个词并刷新聚类
# ─────────────────────────────────────────────────────────────
def add_word_and_refresh(con, spec, wid=None):
    wid, roots, etyma = add_word(con, spec, wid=wid)
    rep = refresh_clusters(con, roots, etyma)
    return wid, rep


# ─────────────────────────────────────────────────────────────
# ⑤ 删词（级联 + 聚类回退）
# ─────────────────────────────────────────────────────────────
#: 所有引用 `word(id)` 的表（实测 10 张）。删词必须逐个清，否则 FK 报错。
_WORD_REF_TABLES = (
    'card_audio',              # 音频（新词通常无）
    'word_mnemonic_profile',   # 记忆法画像
    'aggregate_page_word',     # 聚合页成员
    'cognate_group_member',    # 词根族成员
    'word_collocation',        # 搭配
    'word_etymon',             # 词源链
    'word_morpheme',           # 词素
    'card_extra',              # 溢出义项
    'card',                    # 卡片本体
)


def remove_word(con, wid):
    """删除一个词及其从属数据，并返回受影响聚类（供 `refresh_clusters`）。

    ⚠️ **必须先收集 `root_id`/`etymon_id` 再删** —— 删完就查不到了，
    而调用方需要用它们重算族 size（可能导致聚合页被删）。

    用途：LLM 生成质量不合格需要下线、或词表清洗。
    """
    roots = {r[0] for r in con.execute(
        'SELECT root_id FROM word_morpheme WHERE word_id=? AND root_id IS NOT NULL',
        (wid,))}
    etyma = {r[0] for r in con.execute(
        'SELECT etymon_id FROM word_etymon WHERE word_id=?', (wid,))}

    for t in _WORD_REF_TABLES:
        con.execute(f'DELETE FROM "{t}" WHERE word_id=?', (wid,))
    # `word_form.anchor_id` 指向该词 —— 它的变形映射随之失效
    con.execute('DELETE FROM word_form WHERE anchor_id=?', (wid,))
    con.execute('DELETE FROM word WHERE id=?', (wid,))

    return roots, etyma


def remove_word_and_refresh(con, wid):
    roots, etyma = remove_word(con, wid)
    rep = refresh_clusters(con, roots, etyma)
    _prune_empty_groups(con)
    return rep


def _prune_empty_groups(con):
    """清理已无成员的族（`size=0`）—— 它们不影响聚合页（不达标），但留着是噪音。"""
    con.execute('DELETE FROM cognate_group WHERE size = 0')


def init_incremental_tables(con):
    """若缺 `word.sort_seq` 等增量所需列，做兼容处理（真库已有，仅为副本兜底）。"""
    cols = {r[1] for r in con.execute('PRAGMA table_info(word)')}
    if 'sort_seq' not in cols:
        con.execute('ALTER TABLE word ADD COLUMN sort_seq INTEGER')
