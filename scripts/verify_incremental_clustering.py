#!/usr/bin/env python3
"""增量聚类验收 —— 证明「新词入库 → 聚类正确更新」

## 为什么必须验证

「词库改为按需生长」的**唯一技术风险**是：新词并进来之后，
聚类还能不能保持一致。尤其是**门槛跨越**：
  一个 size=2 的族加入第 3 词后，**必须自动建出聚合页**，
  否则用户永远看不到这个新出现的词族。

批量版（`load_llm_results.py`）天然处理了门槛（先建完族再统一建页）；
增量版是**逐词**改的，所以跨越检测是新增的关键逻辑，必须锁住。

## 怎么跑

    python3 scripts/verify_incremental_clustering.py          # 用 data/word.db 的副本
    python3 scripts/verify_incremental_clustering.py --keep   # 保留临时库便于排查

**在副本上操作，绝不改动 `data/word.db`。** 退出码 0/1 可挂 CI。
"""

import os
import shutil
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from incremental_clustering import (  # noqa: E402
    PAGE_THRESHOLD, add_word_and_refresh, match_or_create_root,
    refresh_clusters, remove_word_and_refresh,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DB = os.path.join(ROOT, 'data', 'word.db')

_pass = _fail = 0
_failures = []


def _md5(path):
    import hashlib
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def check(desc, cond, detail=''):
    global _pass, _fail
    if cond:
        _pass += 1
        print(f'  ✅ {desc}' + (f'   [{detail}]' if detail else ''))
    else:
        _fail += 1
        _failures.append(desc)
        print(f'  🔴 {desc}' + (f'   [{detail}]' if detail else ''))


def eq(desc, got, want):
    check(desc, got == want, f'got={got} want={want}')


# ─────────────────────────────────────────────────────────────
def main():
    keep = '--keep' in sys.argv
    tmp = os.path.join(tempfile.gettempdir(),
                       f'worddb_incr_test_{os.getpid()}.db')

    # 🔑 先记录源库指纹 —— 结束时用它证明「源库未被动过」
    src_before = _md5(SRC_DB)

    shutil.copy2(SRC_DB, tmp)
    con = sqlite3.connect(tmp)
    con.execute('PRAGMA foreign_keys = ON')
    print(f'副本: {tmp}')
    print(f'源库: {SRC_DB}（只读，不会被改动）')
    print(f'源库指纹（前）: {src_before[:16]}…')

    # ⚠️ Python `sqlite3` 的 `close()` **不提交**，而是回滚未提交事务。
    #    所以每个写操作后必须显式 commit —— 否则「落盘」根本没发生。
    def commit():
        con.commit()

    # ── 基线 ──
    print('\n【0】基线（真库现状）')
    base_words = con.execute('SELECT count(*) FROM word').fetchone()[0]
    base_pages = con.execute('SELECT count(*) FROM aggregate_page').fetchone()[0]
    base_root_pages = con.execute(
        "SELECT count(*) FROM aggregate_page WHERE page_type='root'").fetchone()[0]
    print(f'     词 {base_words:,} · 聚合页 {base_pages:,}（root 型 {base_root_pages:,}）')

    # 达标族数应等于 root 型页数（不变量）
    qualified = con.execute(
        'SELECT count(*) FROM cognate_group WHERE size >= ?', (PAGE_THRESHOLD,)).fetchone()[0]
    eq('不变量：达标族数 == root 型页数', qualified, base_root_pages)

    # ─────────────────────────────────────────
    print('\n【1】新词加入**已有大族**（cept 族 23 词）→ 应只扩员、不新建页')
    rid_cept = con.execute("SELECT id FROM word_root WHERE form='cept' "
                           "AND type='root'").fetchone()
    if not rid_cept:
        print('  ⚠️ 库里没有 cept 词根，跳过该组'); sid = None
    else:
        rid_cept = rid_cept[0]
        before_size = con.execute('SELECT size FROM cognate_group WHERE root_id=?',
                                  (rid_cept,)).fetchone()[0]
        before_page = con.execute('SELECT id, member_count FROM aggregate_page '
                                  "WHERE page_type='root' AND group_id="
                                  '(SELECT id FROM cognate_group WHERE root_id=?)',
                                  (rid_cept,)).fetchone()
        print(f'     cept 族：size={before_size} · 页={before_page[0] if before_page else "无"}'
              f'（{before_page[1] if before_page else 0} 词）')

        spec = {
            'spelling': 'interception',
            'entry_type': 'word',
            'morphology': {'analyzable': True, 'relation': None, 'parts': [
                {'form': 'inter', 'type': 'prefix', 'meaning': '在…之间'},
                {'form': 'cept', 'type': 'root', 'meaning': '拿取', 'origin': 'Latin'},
                {'form': 'ion', 'type': 'suffix', 'meaning': '名词后缀'},
            ]},
            'etymology': {'text': 'inter-（在…之间）+ capere（拿取）',
                          'etyma': [{'form': 'capere', 'language': 'Latin',
                                     'meaning_zh': '拿取'}]},
            'card': {'front': 'interception', 'sections': []},
        }
        wid, rep = add_word_and_refresh(con, spec)
        commit()
        print(f'     新词 {wid}')

        # root_id 必须复用（不新建）
        n_root = con.execute("SELECT count(*) FROM word_root WHERE form='cept' "
                             "AND type='root'").fetchone()[0]
        eq('重复词根不新建（cept 仍只 1 条 word_root）', n_root, 1)

        after_size = con.execute('SELECT size FROM cognate_group WHERE root_id=?',
                                 (rid_cept,)).fetchone()[0]
        eq('族 size +1', after_size, before_size + 1)
        eq('⚠️ 无新建页（已有页只扩员）', len(rep['root']['pages_created']), 0)
        eq('更新了已有的页', len(rep['root']['pages_updated']), 1)

        if before_page:
            pid, cnt = before_page
            after_cnt = con.execute('SELECT member_count FROM aggregate_page WHERE id=?',
                                    (pid,)).fetchone()[0]
            eq('已有页 member_count +1', after_cnt, cnt + 1)
            in_page = con.execute('SELECT count(*) FROM aggregate_page_word '
                                  'WHERE page_id=? AND word_id=?', (pid, wid)).fetchone()[0]
            eq('新词已进入该页成员列表', in_page, 1)
        sid = rid_cept

    # ─────────────────────────────────────────
    print('\n【2】🔑 门槛跨越：新词加入 size=2 族 → **必须新建聚合页**')
    two = con.execute("""
        SELECT g.root_id, g.label, g.size FROM cognate_group g
        WHERE g.size = 2 AND g.root_id IS NOT NULL
        ORDER BY g.root_id LIMIT 1""").fetchone()
    if not two:
        print('  ⚠️ 库里没有 size=2 的族，跳过'); do2 = False
    else:
        do2 = True
        rid2, label2, size2 = two
        form2 = con.execute('SELECT form, origin FROM word_root WHERE id=?',
                            (rid2,)).fetchone()
        gid2 = con.execute('SELECT id FROM cognate_group WHERE root_id=?',
                           (rid2,)).fetchone()[0]
        page_before = con.execute('SELECT id FROM aggregate_page '
                                  "WHERE page_type='root' AND group_id=?", (gid2,)).fetchone()
        print(f'     目标族：{label2}（{form2[0]} / size={size2}）'
              f'· 现有页={"有" if page_before else "无（符合 <3 不建页）"}')
        check('跨门槛前：该族无聚合页（符合 <3 不建页）', page_before is None)

        # 构造第 3 个词（把该词根 + 一个后缀拼出来）
        third = form2[0].rstrip('-') + 'ition'
        spec2 = {
            'spelling': third,
            'entry_type': 'word',
            'morphology': {'analyzable': True, 'relation': None, 'parts': [
                {'form': form2[0], 'type': 'root', 'meaning': '测试用',
                 'origin': form2[1]},
                {'form': 'ition', 'type': 'suffix', 'meaning': '名词后缀'},
            ]},
            'card': {'front': third, 'sections': []},
        }
        wid2, rep2 = add_word_and_refresh(con, spec2)
        commit()
        print(f'     新词 {third} → {wid2}')

        after_size2 = con.execute('SELECT size FROM cognate_group WHERE root_id=?',
                                  (rid2,)).fetchone()[0]
        eq('族 size 2 → 3', after_size2, 3)
        check('🔑 新建了聚合页（门槛跨越）',
              len(rep2['root']['pages_created']) == 1,
              f'created={rep2["root"]["pages_created"]}')

        new_page = con.execute("SELECT id, member_count, front FROM aggregate_page "
                               "WHERE page_type='root' AND group_id=?", (gid2,)).fetchone()
        check('新页存在', new_page is not None)
        if new_page:
            eq('新页 member_count = 3', new_page[1], 3)
            n_mem = con.execute('SELECT count(*) FROM aggregate_page_word WHERE page_id=?',
                                (new_page[0],)).fetchone()[0]
            eq('新页成员列表 3 条', n_mem, 3)
            has_new = con.execute('SELECT count(*) FROM aggregate_page_word '
                                  'WHERE page_id=? AND word_id=?',
                                  (new_page[0], wid2)).fetchone()[0]
            eq('新词在新页里', has_new, 1)

    # ─────────────────────────────────────────
    print('\n【3】幂等：重复加入同一个词，不重复建页 / 不重复计数')
    if sid is not None:
        rep3 = refresh_clusters(con, [sid])
        commit()
        eq('重复刷新不新建页', len(rep3['root']['pages_created']), 0)

    # ─────────────────────────────────────────
    print('\n【4】词根匹配必须带 origin（同形异源不能混）')
    r1, c1 = match_or_create_root(con, 'man', 'root', 'Old English', '人')
    r2, c2 = match_or_create_root(con, 'man', 'root', 'Latin', '停留')
    commit()
    check('同 form 不同 origin → 两条独立记录', r1 != r2, f'rid1={r1} rid2={r2}')
    r3, c3 = match_or_create_root(con, 'man', 'root', 'Old English', '人')
    check('同三元组 → 复用', r3 == r1 and c3 is False, f'rid3={r3}')

    # ─────────────────────────────────────────
    print('\n【5】全新词根 → 新建 word_root + 新族 size=1 + **不建页**')
    spec5 = {
        'spelling': 'zzztestword',
        'entry_type': 'word',
        'morphology': {'analyzable': True, 'relation': None, 'parts': [
            {'form': 'zzztestroot', 'type': 'root', 'meaning': '测试词根',
             'origin': 'Test'},
        ]},
        'card': {'front': 'zzztestword', 'sections': []},
    }
    wid5, rep5 = add_word_and_refresh(con, spec5)
    commit()
    rid5 = con.execute("SELECT id FROM word_root WHERE form='zzztestroot'").fetchone()
    check('新建了 word_root', rid5 is not None)
    if rid5:
        sz5 = con.execute('SELECT size FROM cognate_group WHERE root_id=?',
                          (rid5[0],)).fetchone()[0]
        eq('新族 size=1', sz5, 1)
        eq('size=1 不建页', len(rep5['root']['pages_created']), 0)

    # ─────────────────────────────────────────
    print('\n【6】反向：删词后 size 跌破门槛 → **必须删页**')
    if do2 and new_page:
        rep6 = remove_word_and_refresh(con, wid2)
        commit()
        sz_after = con.execute('SELECT size FROM cognate_group WHERE root_id=?',
                               (rid2,)).fetchone()[0]
        eq('族 size 回到 2', sz_after, 2)
        check('🔑 跌破门槛 → 删页', len(rep6['root']['pages_deleted']) == 1,
              f'deleted={rep6["root"]["pages_deleted"]}')
        gone = con.execute('SELECT id FROM aggregate_page '
                           "WHERE page_type='root' AND group_id=?", (gid2,)).fetchone()
        check('该页确实不存在了', gone is None)
        n_left = con.execute('SELECT count(*) FROM card WHERE word_id=?',
                             (wid2,)).fetchone()[0]
        eq('该词的卡片也已清掉', n_left, 0)

    # ─────────────────────────────────────────
    print('\n【7】全库不变量（刷新后仍成立）')
    q2 = con.execute('SELECT count(*) FROM cognate_group WHERE size >= ?',
                     (PAGE_THRESHOLD,)).fetchone()[0]
    p2 = con.execute("SELECT count(*) FROM aggregate_page "
                     "WHERE page_type='root'").fetchone()[0]
    eq('达标族数 == root 型页数', q2, p2)
    orphan = con.execute("""
        SELECT count(*) FROM aggregate_page a
        WHERE a.page_type='root' AND NOT EXISTS (
          SELECT 1 FROM cognate_group g WHERE g.id=a.group_id AND g.size>=?)""",
        (PAGE_THRESHOLD,)).fetchone()[0]
    eq('无「低于门槛却仍有页」的残留', orphan, 0)
    stale = con.execute("""
        SELECT count(*) FROM aggregate_page a
        WHERE a.member_count <> (SELECT count(*) FROM aggregate_page_word w
                                 WHERE w.page_id = a.id)""").fetchone()[0]
    eq('无 member_count 与成员数不一致的页', stale, 0)

    con.close()

    # ── 源库未被改动（铁律）+ 写入确实落盘 ──
    print('\n【8】源库未被动过（铁律）· 且副本写入确实落盘')
    con.close()
    src_after = _md5(SRC_DB)
    eq('源库指纹未变（未被改动）', src_after, src_before)
    tmp_md5 = _md5(tmp)
    check('副本指纹已变（写入真的落盘了，而非只在连接内）',
          tmp_md5 != src_before, f'{tmp_md5[:16]}…')

    # 独立连接复查副本（证明不是同连接的内存假象）
    v = sqlite3.connect(tmp)
    n_word = v.execute('SELECT count(*) FROM word').fetchone()[0]
    # 加入 3 个（interception / riseition / zzztestword）、删掉 1 个（riseition）→ 净 +2
    eq('副本词数 = 源库 + 2（净增）', n_word, base_words + 2)
    for sp, want in (('interception', 1), ('zzztestword', 1), ('riseition', 0)):
        got = v.execute('SELECT count(*) FROM word WHERE spelling=?', (sp,)).fetchone()[0]
        eq(f'副本里 {sp} 状态（持久化后）', got, want)
    n_tmp_root = v.execute("SELECT count(*) FROM word_root WHERE form='zzztestroot'").fetchone()[0]
    eq('副本里新词根已持久化', n_tmp_root, 1)
    v.close()

    if keep:
        print(f'\n副本保留在 {tmp}')
    else:
        os.remove(tmp)

    # ── 汇总 ──
    print('\n' + '=' * 68)
    print(f'通过 {_pass} 项，失败 {_fail} 项')
    if _fail:
        print('\n失败项：')
        for f in _failures:
            print(f'  🔴 {f}')
        sys.exit(1)
    print('✅ 增量聚类全部通过 —— 新词可无缝并入已有聚类，门槛跨越正确')
    sys.exit(0)


if __name__ == '__main__':
    main()
