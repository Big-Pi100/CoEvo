#!/usr/bin/env python3
"""CoEvo 词库重跑 · 全量生成（含断点续跑）

背景（2026-09-26 白哥定）：
  抽样验证已通过（210 条 × 2 轮，契约 v5）。现在跑全量 11,917 条。
  就绪检查发现原抽样脚本三大缺口，本脚本解决：
    ① 无全量模式         → --full
    ② 无断点续跑（中断即全丢）→ JSONL 分批写入 + 启动时跳过已完成
    ③ 无失败清单         → failed.jsonl 单独落盘，可只重跑失败项

设计要点：
  · 输出 **JSONL**（一行一条），每 N 条 flush 一次 → 中断只丢最后一批
  · 启动时读已有 JSONL，**跳过已成功的词** → 可反复重跑直到补齐
  · 失败项进 `failed.jsonl`，含错误原因 → `--retry-failed` 只重跑这些
  · 并发 8（实测未触发限流）；`--workers` 可调，建议先压测再提
  · 每条记录带 `_v`（契约版本）+ `_ts` → 便于将来契约升级时识别旧数据

用法：
  # 冒烟（前 20 条）
  python3 scripts/llm_full_rerun.py --limit 20

  # 全量 11,917 条
  python3 scripts/llm_full_rerun.py --full

  # 中断后继续（自动跳过已完成）
  python3 scripts/llm_full_rerun.py --full

  # 只重跑失败项
  python3 scripts/llm_full_rerun.py --retry-failed

  # 看进度
  python3 scripts/llm_full_rerun.py --status
"""
import argparse
import json
import os
import random
import sqlite3
import sys
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)

sys.stdout.reconfigure(encoding='utf-8')

ROOT = cwc.ROOT
DB = cwc.DB
PREBUILT = cwc.PREBUILT

OUT_DIR = os.path.join(PREBUILT, 'fullrun')
OUT_JSONL = os.path.join(OUT_DIR, 'results.jsonl')
FAIL_JSONL = os.path.join(OUT_DIR, 'failed.jsonl')
PLAN_JSON = os.path.join(OUT_DIR, 'plan.json')

FLUSH_EVERY = 50          # 每 50 条 flush 一次
FSYNC_EVERY = 1000        # 每 1000 条 fsync 一次（🔴 见 Sink 注释：每批 fsync 慢 30 倍）
# 🔴 默认并发（2026-09-26 压测修正）
#    旧值 8 的由来是「8 与 16 并发吞吐相同」→ 误判瓶颈在服务端 →
#    开高并发才对。**实测瓶颈是本地代理**（详见 coevo_wordlib_contract.py 的代理开关注释）。
#    直连 300 / 代理 100；启动时 `probe_and_configure` 会自动选路并覆盖此默认值。
DEFAULT_WORKERS = 300

_lock = threading.Lock()


def build_word_list(limit: int = None, seed: int = 20260928):
    """全量词表（含现网释义，供 LLM 纠错用）。"""
    con = sqlite3.connect(DB)
    rows = list(con.execute("""
        SELECT c.front, l.level, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id = c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'
    """))
    con.close()

    def first_gloss(d):
        if not d:
            return None
        try:
            j = json.loads(d)
            return (j[0].get('meaning') or None) if j else None
        except Exception:
            return None

    items = [{'word': w, 'level': (lv or '').strip(), 'gloss': first_gloss(d)}
             for w, lv, d in rows]
    items.sort(key=lambda x: x['word'].lower())
    if limit:
        # 分层取样：保证各 CEFR 都有
        rng = random.Random(seed)
        by = {}
        for it in items:
            by.setdefault(it['level'], []).append(it)
        picked, per = [], max(1, limit // max(1, len(by)))
        for lv in sorted(by):
            pool = by[lv][:]
            rng.shuffle(pool)
            picked += pool[:per]
        picked = picked[:limit]
        picked.sort(key=lambda x: x['word'].lower())
        return picked
    return items


def load_done(path: str):
    """读已完成结果 → {word: record}（失败的不算完成）"""
    done, fails = {}, {}
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            w = r.get('word')
            if not w:
                continue
            if r.get('ok'):
                done[w] = r
            else:
                fails[w] = r
    # 失败清单覆盖 done（后写优先）
    if os.path.exists(FAIL_JSONL):
        for line in open(FAIL_JSONL, encoding='utf-8'):
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('word'):
                fails[r['word']] = r
    return done, fails


class Sink:
    """JSONL 分批写入（线程安全）

    🔴 fsync 策略（2026-09-26 实测，**影响 30 倍速度**）：
      `os.fsync` 在 Windows = `FlushFileBuffers`（刷整个卷），且**在全局锁内** ——
      一次慢刷盘会阻塞所有完成线程的写入 → 整条流水线跟着卡。
      实测（200 并发 · 直连 · 长连接）：
        · 每批 fsync  → 200 条用 **2.4 分钟**，33 次连接重试（被拖出来的次生问题）
        · 不 fsync    → 300 条用 **8 秒**，0 重试
      → 改为**每 `FSYNC_EVERY` 条 fsync 一次**（折中：既不被拖慢，进程被杀最多丢一批）
      `COEVO_NO_FSYNC=1` 可完全关闭（最快，但丢最后一批）；`COEVO_FSYNC_EVERY=N` 可调
    """

    def __init__(self, path, flush_every=FLUSH_EVERY, fsync_every=None):
        self.path = path
        self.flush_every = flush_every
        self.fsync_every = fsync_every
        self.buf = []
        self._n_since_fsync = 0
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.fh = open(path, 'a', encoding='utf-8')

    def write(self, rec):
        with _lock:
            self.buf.append(json.dumps(rec, ensure_ascii=False))
            if len(self.buf) >= self.flush_every:
                self._flush_locked()

    def _should_fsync(self):
        if os.environ.get('COEVO_NO_FSYNC') == '1':
            return False
        if os.environ.get('COEVO_FSYNC_EVERY'):
            n = int(os.environ['COEVO_FSYNC_EVERY'])
        else:
            n = self.fsync_every if self.fsync_every else FSYNC_EVERY
        if n <= 0:
            return False
        return self._n_since_fsync >= n

    def _flush_locked(self):
        if self.buf:
            self.fh.write('\n'.join(self.buf) + '\n')
            self.fh.flush()
            self._n_since_fsync += len(self.buf)
            if self._should_fsync():
                os.fsync(self.fh.fileno())
                self._n_since_fsync = 0
            self.buf = []

    def close(self):
        with _lock:
            self._flush_locked()
            try:
                os.fsync(self.fh.fileno())     # 收尾必刷（保证已完成的都在盘上）
            except Exception:
                pass
            self.fh.close()


def run(items, workers: int, out_path: str):
    key = cwc.load_key()
    cwc.reset_stats()
    ok_sink = Sink(out_path)
    fail_sink = Sink(FAIL_JSONL)
    total = {'in': 0, 'out': 0, 'ok': 0, 'fail': 0}
    t0 = time.time()

    def work(it):
        r = cwc.call_llm(key, it['word'], definition=it.get('gloss'))
        return it, r

    print(f'  待跑 {len(items)} 条 · {workers} 并发 · 输出 {out_path}')
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(work, it) for it in items]
        for i, f in enumerate(as_completed(futs), 1):
            it, r = f.result()
            rec = {'word': it['word'], 'level': it.get('level'),
                   '_v': cwc.CONTRACT_VERSION, '_ts': int(time.time()),
                   'ok': bool(r.get('ok'))}
            if r.get('ok'):
                rec['data'] = r['data']
                rec['in_tok'] = r.get('in_tok', 0)
                rec['out_tok'] = r.get('out_tok', 0)
                total['in'] += r.get('in_tok', 0)
                total['out'] += r.get('out_tok', 0)
                total['ok'] += 1
                ok_sink.write(rec)
            else:
                rec['error'] = r.get('error')
                total['fail'] += 1
                fail_sink.write(rec)
            if i % 100 == 0 or i == len(items):
                el = time.time() - t0
                rate = i / el if el else 0
                eta = (len(items) - i) / rate if rate else 0
                print(f'    {i}/{len(items)}  ok={total["ok"]} fail={total["fail"]}  '
                      f'{rate:.1f} 条/秒  ETA {eta/60:.1f} min')
    ok_sink.close()
    fail_sink.close()

    cost = total['in'] * cwc.P_IN / 1e6 + total['out'] * cwc.P_OUT / 1e6
    print(f'\n  完成：成功 {total["ok"]} · 失败 {total["fail"]} · '
          f'耗时 {(time.time()-t0)/60:.1f} min · 成本 ≈ ¥{cost:.2f}')
    # 🔑 可观测性：区分「服务端限流」与「本地连接翻腾」（两者处理方式完全不同）
    st = cwc.stats_snapshot()
    rc, r429, r5xx, rconn = (st.get('retried_calls', 0), st.get('http_429', 0),
                             st.get('http_5xx', 0), st.get('conn_err', 0))
    if rc or r429:
        print(f'  🟠 重试：{rc} 个请求 · 共 {st.get("retries", 0)} 次 '
              f'（429 {r429} · 5xx {r5xx} · 连接错误 {rconn}）')
        if r429 or r5xx:
            print('     ⚠️ 有 429/5xx → **服务端限流**。降低 --workers 或稍后再跑')
        elif rconn:
            print(f'     ⚠️ 全是连接错误（{rconn}）→ **本地连接问题**，不是 API 限流。'
                  f'检查：是否走代理（🔴 代理是瓶颈）、网络是否抖动。')
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--full', action='store_true', help='全量 11,917 条')
    ap.add_argument('--limit', type=int, help='只跑前 N 条（分层抽样，冒烟用）')
    ap.add_argument('--workers', type=int, default=None,
                    help=f'并发数（默认自动探测：直连 {cwc.WORKERS_DIRECT} / 代理 {cwc.WORKERS_PROXY}）')
    ap.add_argument('--no-proxy', action='store_true', help='强制直连（跳过探测）')
    ap.add_argument('--use-proxy', action='store_true', help='强制走代理（跳过探测）')
    ap.add_argument('--retry-failed', action='store_true', help='只重跑失败项')
    ap.add_argument('--status', action='store_true', help='只看进度')
    ap.add_argument('--no-probe', action='store_true', help='跳过启动探测（用 --workers 原值）')
    force = ap.add_argument('--force', action='store_true', help='忽略已有结果，全部重跑')
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)

    # ── 选路：直连 or 代理（实测影响并发上限 50 倍）──
    if args.no_proxy:
        cwc.set_proxy(False)
        workers, mode = (args.workers or cwc.WORKERS_DIRECT), '直连(强制)'
    elif args.use_proxy:
        cwc.set_proxy(True)
        workers, mode = (args.workers or cwc.WORKERS_PROXY), '代理(强制)'
    elif args.no_probe:
        workers, mode = (args.workers or DEFAULT_WORKERS), '未探测'
    elif args.status:
        workers, mode = (args.workers or DEFAULT_WORKERS), '-'
    else:
        print('  探测网络路径...')
        m, w = cwc.probe_and_configure(cwc.load_key())
        if not m:
            print('  🔴 直连与代理均不可用，请检查网络/API key')
            return
        mode, workers = m, (args.workers or w)
        print(f'  ✅ {mode}可用 → 并发 {workers}')

    if args.status:
        done, fails = load_done(OUT_JSONL)
        allw = build_word_list()
        print(f'  词表总数     : {len(allw)}')
        print(f'  已完成       : {len(done)}  ({len(done)/len(allw)*100:.1f}%)')
        print(f'  失败         : {len(fails)}')
        print(f'  剩余         : {len(allw) - len(done) - len(fails)}')
        if done:
            v = Counter(r.get('_v') for r in done.values())
            print(f'  契约版本分布  : {dict(v)}')
            ti = sum(r.get('in_tok', 0) for r in done.values())
            to = sum(r.get('out_tok', 0) for r in done.values())
            print(f'  已花成本     : ≈ ¥{ti*cwc.P_IN/1e6 + to*cwc.P_OUT/1e6:.2f}')
        return

    if args.retry_failed:
        _, fails = load_done(OUT_JSONL)
        if not fails:
            print('  无失败项')
            return
        items = [{'word': w, 'gloss': None} for w in sorted(fails)]
        print(f'  重跑失败项 {len(items)} 条')
        run(items, workers, OUT_JSONL)
        return

    if not (args.full or args.limit):
        ap.error('需要 --full 或 --limit N 或 --status 或 --retry-failed')

    allw = build_word_list(limit=args.limit)
    done, _ = load_done(OUT_JSONL)
    if args.force:
        todo = allw
    else:
        todo = [it for it in allw if it['word'] not in done]
    print(f'  路径 {mode} · 并发 {workers}')
    print(f'  词表 {len(allw)} · 已完成 {len(done)} · 本次待跑 {len(todo)}')

    if not todo:
        print('  ✅ 全部已完成')
        return

    run(todo, workers, OUT_JSONL)


if __name__ == '__main__':
    main()
