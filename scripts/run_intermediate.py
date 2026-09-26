#!/usr/bin/env python3
"""中间节点补跑 —— 让形态链 / 词源链收敛

解决的问题（2026-09-26 就绪检查 + 1,000 词验证发现）：
  LLM 的 `derived_from` 有 12.3% 指向**词表外**的词（`attuned`→`attune`，attune 不在词表）。
  这些「中间节点」自己不在词表 → 没有 LLM 记录 → 它的 base 未知
  → 链在它这里**断掉** → `anchor` 算不出来 → 该词的形态归属丢失。

  实测（1,000 词）：待补跑 **96** 个 → 折算全量 ≈ 1,145 个。

本脚本：把中间节点**当普通词再问一次 LLM**（同一契约），得到它们自己的 `derived_from`
  → 链就能继续上溯 → `anchor` 可解。

设计要点：
  · 输出到 **独立目录** `intermediate/`，**不与词表词混存**
    （混存会让 `build_chains.py` 把中间节点当成词表词 → 错误地建卡）
  · 支持**多轮迭代**：补跑一轮后重跑 `build_chains.py`，若仍有新 pending 则再来一轮
    （链深一般 1–2 跳，实测 2 轮足够）
  · 断点续跑（同 llm_full_rerun）
  · 中间节点无现网释义 → `definition=None`（契约允许）

用法：
  # 看有多少待补跑
  python3 scripts/run_intermediate.py --status

  # 补跑一批（冒烟 20 条）
  python3 scripts/run_intermediate.py --limit 20

  # 全量补跑
  python3 scripts/run_intermediate.py --full

  # 中断后继续
  python3 scripts/run_intermediate.py --full
"""
import argparse
import json
import os
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

PREBUILT = cwc.PREBUILT
PENDING_JSON = os.path.join(PREBUILT, 'pending_intermediate.json')

OUT_DIR = os.path.join(PREBUILT, 'intermediate')
OUT_JSONL = os.path.join(OUT_DIR, 'results.jsonl')
FAIL_JSONL = os.path.join(OUT_DIR, 'failed.jsonl')

FLUSH_EVERY = 50
# 🔴 默认并发 + 自动选路（2026-09-26 压测修正）
#    实测：直连 + 长连接复用可支持 300 并发；走代理是瓶颈（>250 并发即失败）
#    启动时 `probe_and_configure` 自动选路并覆盖此默认值
DEFAULT_WORKERS = 300
_lock = threading.Lock()


def load_pending():
    if not os.path.exists(PENDING_JSON):
        raise SystemExit(
            f'找不到 {PENDING_JSON}\n请先跑：python3 scripts/build_chains.py')
    d = json.load(open(PENDING_JSON, encoding='utf-8'))
    return [w for w in (d.get('words') or []) if w and w.strip()]


def load_done(path):
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
            if r.get('word'):
                (done if r.get('ok') else fails)[r['word']] = r
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
    def __init__(self, path, flush_every=FLUSH_EVERY):
        self.path = path
        self.flush_every = flush_every
        self.buf = []
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.fh = open(path, 'a', encoding='utf-8')

    def write(self, rec):
        with _lock:
            self.buf.append(json.dumps(rec, ensure_ascii=False))
            if len(self.buf) >= self.flush_every:
                self._flush_locked()

    def _flush_locked(self):
        if self.buf:
            self.fh.write('\n'.join(self.buf) + '\n')
            self.fh.flush()
            os.fsync(self.fh.fileno())
            self.buf = []

    def close(self):
        with _lock:
            self._flush_locked()
            self.fh.close()


def run(words, workers):
    key = cwc.load_key()
    ok_sink, fail_sink = Sink(OUT_JSONL), Sink(FAIL_JSONL)
    total = {'in': 0, 'out': 0, 'ok': 0, 'fail': 0}
    t0 = time.time()

    def work(w):
        # 中间节点无现网释义 → definition=None
        return w, cwc.call_llm(key, w)

    print(f'  待跑 {len(words)} 条 · {workers} 并发 · 输出 {OUT_JSONL}')
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(work, w) for w in words]
        for i, f in enumerate(as_completed(futs), 1):
            w, r = f.result()
            rec = {'word': w, 'kind': 'intermediate',
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
            if i % 50 == 0 or i == len(words):
                el = time.time() - t0
                rate = i / el if el else 0
                eta = (len(words) - i) / rate if rate else 0
                print(f'    {i}/{len(words)}  ok={total["ok"]} fail={total["fail"]}  '
                      f'{rate:.1f} 条/秒  ETA {eta/60:.1f} min')
    ok_sink.close()
    fail_sink.close()

    cost = total['in'] * cwc.P_IN / 1e6 + total['out'] * cwc.P_OUT / 1e6
    print(f'\n  完成：成功 {total["ok"]} · 失败 {total["fail"]} · '
          f'耗时 {(time.time()-t0)/60:.1f} min · 成本 ≈ ¥{cost:.2f}')
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--full', action='store_true', help='补跑全部待补跑项')
    ap.add_argument('--limit', type=int, help='只跑前 N 条')
    ap.add_argument('--workers', type=int, default=None,
                    help=f'并发数（默认自动探测：直连 {cwc.WORKERS_DIRECT} / 代理 {cwc.WORKERS_PROXY}）')
    ap.add_argument('--no-proxy', action='store_true', help='强制直连（跳过探测）')
    ap.add_argument('--use-proxy', action='store_true', help='强制走代理（跳过探测）')
    ap.add_argument('--status', action='store_true')
    ap.add_argument('--force', action='store_true', help='忽略已有结果')
    args = ap.parse_args()

    # ── 选路（同 llm_full_rerun：实测影响并发上限 50 倍）──
    if args.no_proxy:
        cwc.set_proxy(False)
        workers, mode = (args.workers or cwc.WORKERS_DIRECT), '直连(强制)'
    elif args.use_proxy:
        cwc.set_proxy(True)
        workers, mode = (args.workers or cwc.WORKERS_PROXY), '代理(强制)'
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

    pending = load_pending()
    done, fails = load_done(OUT_JSONL)

    if args.status:
        left = [w for w in pending if w not in done]
        print(f'  待补跑清单（来自 build_chains.py）: {len(pending)}')
        print(f'  已完成                          : {len(done)}')
        print(f'  失败                            : {len(fails)}')
        print(f'  剩余                            : {len(left)}')
        if done:
            v = Counter(r.get('_v') for r in done.values())
            ti = sum(r.get('in_tok', 0) for r in done.values())
            to = sum(r.get('out_tok', 0) for r in done.values())
            print(f'  契约版本                        : {dict(v)}')
            print(f'  已花成本                        : ≈ ¥{ti*cwc.P_IN/1e6 + to*cwc.P_OUT/1e6:.2f}')
        return

    if not (args.full or args.limit):
        ap.error('需要 --full / --limit N / --status')

    todo = pending if args.force else [w for w in pending if w not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f'  待补跑 {len(pending)} · 已完成 {len(done)} · 本次待跑 {len(todo)}')
    if not todo:
        print('  ✅ 本轮无待补跑项（可能已收敛，或需先重跑 build_chains.py）')
        return
    print(f'  路径 {mode} · 并发 {workers}')
    run(todo, workers)
    print('\n  下一步：python3 scripts/build_chains.py'
          '   ← 重新生成链，看 pending 是否已收敛')


if __name__ == '__main__':
    main()
