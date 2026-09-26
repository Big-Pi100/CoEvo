#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 #7/#8 · LLM 批量补全词卡内容

处理三类问题（实测清洗后 11,917 条词表的待补全规模）
---------------------------------------------------
  A. **空壳卡**（729 条）
     · `definitions` 为空            49 条
     · 有结构但 `meaning`+`chinese` 皆空  680 条
     → 完整生成 pos / meaning / chinese / example
  B. **缺中文**（654 条）
     · 有英文 `meaning` 但 `chinese` 空
     → **只生成中文**（省 token）
  C. **释义不可信**（166 条）
     · 释义被别的词覆盖（`happy` ← `a` 的释义）
     → 重新生成全部字段

设计要点
--------
· **断点续跑**：结果落 `llm_fill_progress.json`，已完成的跳过（1,549 条需长时间）
· **并发**：默认 8 线程（DeepSeek 允许），失败自动重试
· **分类 prompt**：三类用不同提示词，A/C 要完整生成，B 只要中文
· **格式校验**：返回必须能解析为 JSON 且含必需字段，否则计失败
· **成本统计**：累计 token 用量并按 DeepSeek 价目估算
· **自动备份**：写入前备份 DB，结果清单可回滚

用法
----
    python3 scripts/fill_card_content_llm.py --dry-run          # 预览待补全清单
    python3 scripts/fill_card_content_llm.py --sample 5         # 只跑 5 条（验证 prompt）
    python3 scripts/fill_card_content_llm.py --apply            # 全量执行
    python3 scripts/fill_card_content_llm.py --apply --retry-failed   # 只重跑失败的
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
ENV = os.path.join(ROOT, 'backend', '.env')
BACKUP_DIR = os.path.join(ROOT, 'data', 'backups')
PROGRESS = os.path.join(ROOT, 'data', 'curriculum', 'llm_fill_progress.json')
RESULT = os.path.join(ROOT, 'data', 'curriculum', 'llm_fill_result.json')

API_URL = 'https://api.deepseek.com/chat/completions'
# 现行官方模型名（2026-09-25 核实）
#   ⚠️ `deepseek-chat` / `deepseek-reasoner` **已于 2026-07-24 下线**
#   ⚠️ `deepseek-v4-flash` 是 legacy 别名（仍接受，由 V4.1-Flash 承接）→ 用现行名
MODEL = os.environ.get('COEVO_LLM_MODEL', 'deepseek-flash')
CJK = re.compile(r'[\u4e00-\u9fff]')

# 🔴 必须显式关闭 thinking —— `deepseek-flash` **默认开启**，
#    实测同一请求：thinking 开 = 190 完成 token（含 150 推理）/ 关 = 33 token，**质量相同**。
#    词典内容生成属「简单结构化提取」，不需要推理 → 关闭后成本降至 1/6。
THINKING = {'type': 'disabled'}

# 定价（DeepSeek V4.1-Flash，元/百万 token，**空闲时段**）—— 仅用于估算
# 空闲/高峰：高峰 = 周一至周五 9:00–12:00、14:00–18:00（北京时间），价格翻倍
PRICE_IN = 1.5 / 1_000_000
PRICE_OUT = 4.5 / 1_000_000

_lock = threading.Lock()


def load_key() -> str:
    if os.path.exists(ENV):
        for line in open(ENV, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                os.environ.setdefault(k, v.strip())
    return os.environ.get('DEEPSEEK_API_KEY', '').strip()


def llm(prompt: str, key: str, max_tokens: int = 700, retries: int = 3):
    """调用 LLM，返回 (文本, usage) 或 (None, None)。"""
    body = json.dumps({
        'model': MODEL,
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.2,
        'max_tokens': max_tokens,
        'response_format': {'type': 'json_object'},
        'thinking': THINKING,     # 关闭推理（见文件头说明）
    }).encode()
    for i in range(retries):
        try:
            req = urllib.request.Request(
                API_URL, data=body,
                headers={'Content-Type': 'application/json',
                         'Authorization': f'Bearer {key}'})
            with urllib.request.urlopen(req, timeout=90) as r:
                res = json.loads(r.read())
            return (res['choices'][0]['message']['content'], res.get('usage'))
        except urllib.error.HTTPError as e:
            detail = e.read().decode('utf-8', 'replace')[:160]
            if e.code in (429, 500, 502, 503):
                time.sleep(2 ** i)
                continue
            return (None, {'error': f'HTTP {e.code}: {detail}'})
        except Exception as e:
            if i == retries - 1:
                return (None, {'error': f'{type(e).__name__}: {e}'})
            time.sleep(2 ** i)
    return (None, {'error': '重试耗尽'})


def parse_json(text: str):
    """从 LLM 返回里抽 JSON（容忍 markdown 代码块）。"""
    if not text:
        return None
    t = text.strip()
    t = re.sub(r'^```(?:json)?\s*', '', t)
    t = re.sub(r'\s*```$', '', t)
    try:
        return json.loads(t)
    except Exception:
        m = re.search(r'\{.*\}', t, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except Exception:
                return None
    return None


# ── 三类 prompt ────────────────────────────────────────────────
P_FULL = """You are an English learner's dictionary editor. Create ONE card for the word below.

Word: {word}
{context}

Rules:
- `meaning`: English definition, ONE sentence, ≤ 22 words, learner-friendly (CEFR A2-B2 level).
- `chinese`: Chinese translation of the meaning, short (≤ 12 chars). Never mix English.
- `pos`: part of speech, one of: n / v / adj / adv / prep / pron / conj / num / int
- `example`: ONE natural English sentence using the word.
- If the word has multiple common senses, give the MOST COMMON one only.

Output STRICT JSON only:
{{"pos":"...","meaning":"...","chinese":"...","example":"..."}}"""

P_CN_ONLY = """You are a bilingual dictionary editor. Give the Chinese meaning for this English word.

Word: {word}
English definition: {meaning}

Rules:
- `chinese`: concise Chinese translation of the definition, ≤ 12 characters.
- Must be Chinese only. No English, no parentheses, no pinyin.

Output STRICT JSON only:
{{"chinese":"..."}}"""


def build_prompt(card: dict) -> tuple[str, int]:
    kind = card['kind']
    if kind == 'cn_only':
        return (P_CN_ONLY.format(word=card['word'],
                                 meaning=(card.get('meaning') or '')[:200]), 200)
    ctx = ''
    if card.get('bad_reason'):
        ctx = (f"Note: the existing definition is WRONG (it was overwritten by another word's "
               f"definition). Ignore it completely and write a correct one.\n"
               f"Bad definition to ignore: {(card.get('meaning') or '')[:120]}")
    return (P_FULL.format(word=card['word'], context=ctx), 700)


def write_back(conn, done: dict, only_unsaved: bool = True) -> int:
    """把进度文件里的生成结果写入 DB。

    `only_unsaved=True` 时只写 `written != True` 的条目 —— 支持：
      · 中断后补写（生成已完成但未落库）
      · 重复执行不产生无谓 UPDATE
    """
    n = 0
    for cid, rec in done.items():
        if not rec.get('ok') or not rec.get('data'):
            continue
        if only_unsaved and rec.get('written'):
            continue
        rows = list(conn.execute(
            'SELECT definitions FROM prebuilt_language_cards WHERE id=?', (cid,)))
        if not rows:
            continue
        try:
            items = json.loads(rows[0][0]) if rows[0][0] else []
        except Exception:
            items = []
        if not isinstance(items, list) or not items:
            items = [{}]
        d = rec['data']
        it = dict(items[0]) if isinstance(items[0], dict) else {}
        if d.get('pos'):
            it['pos'] = d['pos']
        if d.get('meaning'):
            it['meaning'] = d['meaning']
        if d.get('chinese'):
            it['chinese'] = d['chinese']
        if d.get('example'):
            it['example'] = d['example']
        items[0] = it
        conn.execute('UPDATE prebuilt_language_cards SET definitions=? WHERE id=?',
                     (json.dumps(items, ensure_ascii=False), cid))
        rec['written'] = True
        n += 1
    conn.commit()
    return n


def scan_targets(conn) -> dict[str, list[dict]]:
    """扫出三类待补全目标。"""
    rows = list(conn.execute("""
        SELECT c.id, c.front, l.definitions
        FROM prebuilt_cards c JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))

    # 「释义不可信」**动态判定**（不读静态清单）
    #   ⚠️ 早期版本读 `vocab_noise.json` 的静态快照 —— 一旦词条修好，
    #      静态清单仍把它标为「不可信」→ 重复执行会白白重新生成（浪费额度）。
    #   故改为每次重新检测，只看「当前 DB 内容是否仍存在矛盾」。
    bad_defs: dict[str, str] = {}
    try:
        import importlib.util as _ilu
        _sp = os.path.join(ROOT, 'scripts', 'classify_vocab_noise.py')
        _spec = _ilu.spec_from_file_location('_cvn', _sp)
        _m = _ilu.module_from_spec(_spec)
        import sys as _sys
        _argv_bak = _sys.argv
        _sys.argv = ['_cvn']          # 避免子模块的 argparse 解析
        try:
            _spec.loader.exec_module(_m)
        finally:
            _sys.argv = _argv_bak

        _cards = {r[0]: r[1] for r in conn.execute(
            "SELECT id, front FROM prebuilt_cards "
            "WHERE subject='english' AND card_type='vocabulary'")}
        _meta = {r[0]: (r[1], r[2], r[3]) for r in conn.execute(
            "SELECT id, pos, pronunciation, definitions FROM prebuilt_language_cards")}
        for _k, _v in _m.find_def_collisions(_cards, _meta).items():
            bad_defs[_k] = _v
        for _k, _v in _m.find_def_mismatch(_cards, _meta).items():
            bad_defs.setdefault(_k, f'释义疑似在解释 {_v!r}')
    except Exception as _e:
        print(f'  ⚠️ 动态检测释义不可信失败（降级为不检测）: {type(_e).__name__}: {_e}')

    empty, cn_only, bad = [], [], []
    for cid, word, defs in rows:
        if not word:
            continue
        items = []
        if defs and defs.strip():
            try:
                items = json.loads(defs)
            except Exception:
                items = []
        if not isinstance(items, list):
            items = []

        first = next((it for it in items if isinstance(it, dict)), None)
        mn = (first.get('meaning') or '').strip() if first else ''
        ch = (first.get('chinese') or '').strip() if first else ''

        if word.lower() in bad_defs:
            bad.append({'kind': 'full', 'id': cid, 'word': word,
                        'meaning': mn, 'bad_reason': bad_defs[word.lower()]})
        elif not mn and not ch:
            empty.append({'kind': 'full', 'id': cid, 'word': word, 'meaning': ''})
        elif mn and not ch:
            cn_only.append({'kind': 'cn_only', 'id': cid, 'word': word, 'meaning': mn})

    return {'empty': empty, 'cn_only': cn_only, 'bad': bad}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--sample', type=int, default=0, help='只跑 N 条做验证')
    ap.add_argument('--retry-failed', action='store_true', help='只重跑上次失败的')
    ap.add_argument('--kind', choices=['empty', 'cn_only', 'bad'],
                    help='只处理某一类（便于分类抽样验证）')
    ap.add_argument('--write-back-only', action='store_true',
                    help='只把进度文件里「已生成但未落库」的结果写入 DB，不调用 LLM')
    ap.add_argument('--workers', type=int, default=8)
    args = ap.parse_args()

    key = load_key()
    if not key:
        sys.exit('❌ 未找到 DEEPSEEK_API_KEY（应有于 backend/.env）')

    conn = sqlite3.connect(DB)
    targets = scan_targets(conn)
    allt = targets['empty'] + targets['cn_only'] + targets['bad']

    # 读进度（断点续跑）
    done: dict[str, dict] = {}
    if os.path.exists(PROGRESS):
        try:
            pdata = json.load(open(PROGRESS, encoding='utf-8'))
            done = pdata.get('done', {})
            _prev = pdata.get('_meta', {}).get('usage') or {}
            # 成本要累加历史（断点续跑时前面几轮的开销也要算进总成本）
            usage_carry = {'in': int(_prev.get('in', 0)), 'out': int(_prev.get('out', 0))}
        except Exception:
            done, usage_carry = {}, {'in': 0, 'out': 0}
    else:
        usage_carry = {'in': 0, 'out': 0}

    if args.kind:
        allt = targets[args.kind]
    if args.retry_failed:
        todo = [c for c in allt if done.get(c['id'], {}).get('ok') is False]
    else:
        todo = [c for c in allt if c['id'] not in done]

    print('=' * 78)
    print(f'LLM 批量补全 · {"执行" if args.apply else "预览"}')
    print('=' * 78)
    print(f"  空壳卡（完整生成）: {len(targets['empty']):>5}")
    print(f"  缺中文（只补中文）: {len(targets['cn_only']):>5}")
    print(f"  释义不可信（重生成）: {len(targets['bad']):>5}")
    print(f"  {'— 合计':<18}: {len(allt):>5}")
    print(f"  已完成（跳过）    : {len(allt) - len(todo):>5}")
    print(f"  🔴 待处理          : {len(todo):>5}")
    # 实测单卡：输入 ~165 token / 输出 ~40 token（thinking 关闭）
    est_in, est_out = len(todo) * 165, len(todo) * 40
    print(f"\n  预估 token: 输入 {est_in/1e3:.0f}K / 输出 {est_out/1e3:.0f}K → "
          f"成本 ≈ ¥{est_in*PRICE_IN + est_out*PRICE_OUT:.2f}（空闲时段）")

    if args.write_back_only:
        pend = [c for c in done.values() if c.get('ok') and not c.get('written')]
        print(f"\n  🔧 只写回模式：待补写 {len(pend)} 条（不调用 LLM）")
        if pend:
            n = write_back(conn, done, only_unsaved=True)
            with _lock:
                json.dump({'_meta': {'updated': datetime.now().isoformat(timespec='seconds'),
                                     'model': MODEL, 'usage': usage_carry},
                           'done': done},
                          open(PROGRESS, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
            print(f"  ✅ 已补写 {n} 条")
        conn.close()
        return

    if args.sample:
        todo = todo[:args.sample]
        print(f"\n  ⚠️ --sample {args.sample} → 只跑前 {len(todo)} 条")

    print('\n  样例：')
    for c in todo[:8]:
        print(f"    [{c['kind']:<8}] {c['word']:<18} {(c.get('meaning') or '')[:50]}")

    if not args.apply:
        conn.close()
        print('\n（预览模式。加 --apply 执行）')
        return

    # ── 备份 ──
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup = os.path.join(BACKUP_DIR, f'coevo_before_llm_fill_{ts}.db')
    if not args.sample:
        shutil.copy2(DB, backup)
        print(f'\n✅ 已备份 → {os.path.relpath(backup, ROOT)}')

    # ── 并发执行 ──
    usage = dict(usage_carry)
    stats = {'ok': 0, 'fail': 0}
    t0 = time.time()

    def work(card):
        prompt, mx = build_prompt(card)
        text, us = llm(prompt, key, mx)
        if us and 'error' in us:
            return card, None, us['error']
        if us:
            with _lock:
                usage['in'] += us.get('prompt_tokens', 0)
                usage['out'] += us.get('completion_tokens', 0)
        data = parse_json(text)
        if not data:
            return card, None, f'JSON 解析失败: {str(text)[:70]}'
        if card['kind'] == 'cn_only':
            if not (data.get('chinese') or '').strip():
                return card, None, 'chinese 为空'
        else:
            for f in ('meaning', 'chinese'):
                if not (data.get(f) or '').strip():
                    return card, None, f'{f} 为空'
        return card, data, None

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(work, c): c for c in todo}
        for i, f in enumerate(as_completed(futs), 1):
            card, data, err = f.result()
            if data:
                done[card['id']] = {'ok': True, 'word': card['word'],
                                   'kind': card['kind'], 'data': data}
                stats['ok'] += 1
            else:
                done[card['id']] = {'ok': False, 'word': card['word'],
                                    'kind': card['kind'], 'error': err}
                stats['fail'] += 1
            if i % 20 == 0 or i == len(todo):
                el = time.time() - t0
                with _lock:
                    json.dump({'_meta': {'updated': datetime.now().isoformat(timespec='seconds'),
                                         'model': MODEL, 'usage': usage}, 'done': done},
                              open(PROGRESS, 'w', encoding='utf-8'),
                              ensure_ascii=False, indent=1)
                print(f"  [{i:>4}/{len(todo)}] ok={stats['ok']} fail={stats['fail']} "
                      f"{el:.0f}s  ~{el/max(i,1)*(len(todo)-i):.0f}s 剩余")

    # ── 写回 DB ──
    #  ⚠️ 只写「本次生成且尚未落库」的（`written` 标记）。
    #     设计教训：早期版本把「LLM 生成成功」等同于「已落库」，
    #     结果进程在生成完成后、写回前被中断时，一批已生成的数据被搁置
    #     （进度文件里有、数据库里没有）→ 故引入 `written` 标记 + `--write-back-only`。
    print('\n写入数据库…')
    written = write_back(conn, done, only_unsaved=True)
    print(f"  本次写回 {written} 条")
    with _lock:
        json.dump({'_meta': {'updated': datetime.now().isoformat(timespec='seconds'),
                             'model': MODEL, 'usage': usage}, 'done': done},
                  open(PROGRESS, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

    cost = usage['in'] * PRICE_IN + usage['out'] * PRICE_OUT
    print('=' * 78)
    print(f"  ✅ 成功 {stats['ok']} · ❌ 失败 {stats['fail']} · 写回 {written}")
    print(f"  token: 输入 {usage['in']:,} / 输出 {usage['out']:,}")
    print(f"  模型: {MODEL}（thinking=disabled）")
    print(f"  💰 实际成本 ≈ ¥{cost:.2f}")
    print('=' * 78)

    json.dump({'_meta': {'finished': datetime.now().isoformat(timespec='seconds'),
                         'backup': os.path.relpath(backup, ROOT) if not args.sample else None,
                         'model': MODEL, 'ok': stats['ok'], 'fail': stats['fail'],
                         'usage': usage, 'cost_cny': round(cost, 3)},
               'changes': {k: v for k, v in done.items() if v.get('ok')}},
              open(RESULT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(f"✅ 结果清单 → {os.path.relpath(RESULT, ROOT)}")
    conn.close()


if __name__ == '__main__':
    main()
