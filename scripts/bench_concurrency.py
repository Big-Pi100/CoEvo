#!/usr/bin/env python3
"""并发压测 —— 测出 LLM 调用的真实吞吐上限

背景（2026-09-26）：
  全量生成估算耗时约 3.5 小时，此前只测过 8 / 16 两档，**吞吐相同（约 0.95 条/秒）**
  → 怀疑瓶颈在服务端单条延迟（~8.5 秒）。需要测更高并发确认拐点。

🔑 关键设计（否则测不准）：
  ① **关闭重试**（`retries=1`）—— 生产用的 `call_llm` 默认 4 次指数退避重试，
     会把 429 掩盖成「慢但成功」，**测不出真实失败率与限流阈值**
  ② **任务数必须 > 并发数** —— 并发数 = min(workers, 任务数)，
     所以要测 500 并发，词数必须 ≥500，否则并发根本达不到
  ③ **每档独立批次**（不同 seed，但分层抽样保证 CEFR 分布一致）
     —— 用同一批词会让服务端 prompt 缓存把延迟压低，不真实
  ④ **输出到独立目录** `bench/`，**不污染** `fullrun/results.jsonl`（断点续跑状态文件）
  ⑤ 记录**在途请求数曲线**（每秒采样）—— 能看出并发是否真的用满

用法：
  # 单档
  python3 scripts/bench_concurrency.py --workers 8

  # 多档（顺序跑，每档独立批次）
  python3 scripts/bench_concurrency.py --workers 100 200 500

  # 看历史结果对比
  python3 scripts/bench_concurrency.py --report
"""
import argparse
import http.client
import json
import os
import random
import sqlite3
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    'cwc', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coevo_wordlib_contract.py'))
cwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cwc)
sys.stdout.reconfigure(encoding='utf-8')

BENCH_DIR = os.path.join(cwc.PREBUILT, 'bench')
RESULTS = os.path.join(BENCH_DIR, 'bench_results.jsonl')
TIMEOUT = 120

_lock = threading.Lock()
_inflight = 0
_inflight_peak = 0
_inflight_samples = []

# 🔑 代理开关：实测本机有 http_proxy=127.0.0.1:63593，
#    500 并发时报 `Tunnel connection failed: 503`（**代理返回的，不是 API 限流**）
#    → 需对比「走代理 / 直连」定位瓶颈归属
_USE_PROXY = True
_OPENER = None


def _opener():
    global _OPENER
    if _OPENER is None:
        if _USE_PROXY:
            _OPENER = urllib.request.build_opener()
        else:
            _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return _OPENER


def _build_body(word, definition=None):
    content = cwc.PROMPT.format(word=word)
    if definition:
        content += (f'\n\n---\nThe current dictionary gloss for "{word}" in our (possibly outdated) '
                    f'database is:\n  {definition[:200]}\n'
                    f'If this gloss is WRONG or unrelated to the spelling, ignore it and trust your own knowledge.')
    return json.dumps({
        'model': cwc.MODEL,
        'messages': [{'role': 'user', 'content': content}],
        'temperature': 0.1,
        'max_tokens': 900,
        'response_format': {'type': 'json_object'},
        'thinking': cwc.THINKING,
    })


# ══════════════════════════════════════════════════════════════════════
# 🔑 连接复用模式（keep-alive）—— 解决「TIME_WAIT 端口耗尽」
#
#   实测：`urllib` **每个请求新建一条 TCP/TLS 连接**，不复用。
#     动态端口范围仅 16,384 个（49152–65535），Windows 默认 TIME_WAIT 保留 120 秒
#     → 300 并发下每秒新建 100–200 条连接 → 120 秒内累积 12,000–24,000 个 TIME_WAIT
#     → **超过端口上限 → 连接被拒（WinError 10053/10054）→ 越跑越慢**
#
#   现象印证：短时压测（4 秒，1000 并发）0 失败；持续跑（>1 分钟）开始大量连接错误。
#   修法：每线程持有一条长连接反复复用 → 连接数从 O(请求数) 降到 O(并发数)。
# ══════════════════════════════════════════════════════════════════════
_tls_conn = threading.local()
_USE_KEEPALIVE = False


def _call_keepalive(key, word, definition=None, timeout=TIMEOUT):
    """每线程一条长连接（复用），断线自动重连"""
    payload = _build_body(word, definition)
    headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'}
    last = None
    t0 = time.time()
    for attempt in range(3):
        c = getattr(_tls_conn, 'conn', None)
        if c is None:
            c = http.client.HTTPSConnection(
                'api.deepseek.com', timeout=timeout,
                context=ssl.create_default_context())
            _tls_conn.conn = c
        try:
            c.request('POST', '/chat/completions', body=payload, headers=headers)
            r = c.getresponse()
            raw = r.read()
            if r.status != 200:
                last = f'HTTP {r.status}'
                _tls_conn.conn = None      # 连接状态可能已坏
                continue
            res = json.loads(raw)
            u = res.get('usage', {})
            json.loads(res['choices'][0]['message'].get('content') or '{}')
            return {'ok': True, 'latency': time.time() - t0,
                    'in_tok': u.get('prompt_tokens', 0),
                    'out_tok': u.get('completion_tokens', 0), 'err': None}
        except Exception as e:
            last = f'{type(e).__name__}'
            try:
                c.close()
            except Exception:
                pass
            _tls_conn.conn = None          # 强制下次重连
    return {'ok': False, 'latency': time.time() - t0, 'in_tok': 0, 'out_tok': 0,
            'err': f'keepalive:{last}'}


def call_once(key, word, definition=None):
    """单次调用（**不重试**）→ 如实测出失败率与延迟"""
    global _inflight, _inflight_peak
    if _USE_KEEPALIVE:
        with _lock:
            _inflight += 1
            if _inflight > _inflight_peak:
                _inflight_peak = _inflight
        try:
            return _call_keepalive(key, word, definition)
        finally:
            with _lock:
                _inflight -= 1

    body = json.loads(_build_body(word, definition))
    with _lock:
        _inflight += 1
        if _inflight > _inflight_peak:
            _inflight_peak = _inflight
    t0 = time.time()
    try:
        req = urllib.request.Request(
            cwc.API_URL, data=json.dumps(body).encode(),
            headers={'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'})
        with _opener().open(req, timeout=TIMEOUT) as r:
            res = json.loads(r.read())
        u = res.get('usage', {})
        c = res['choices'][0]['message'].get('content') or '{}'
        json.loads(c)                       # 校验能解析（解析失败要如实记为失败）
        return {'ok': True, 'latency': time.time() - t0,
                'in_tok': u.get('prompt_tokens', 0), 'out_tok': u.get('completion_tokens', 0),
                'err': None}
    except urllib.error.HTTPError as e:
        return {'ok': False, 'latency': time.time() - t0, 'in_tok': 0, 'out_tok': 0,
                'err': f'HTTP {e.code}'}
    except urllib.error.URLError as e:
        # 🔑 区分连接层原因（限流会返 HTTPError 429；URLError 是连不上）
        r = e.reason
        reason = f'{type(r).__name__}:{r}' if not isinstance(r, str) else r
        return {'ok': False, 'latency': time.time() - t0, 'in_tok': 0, 'out_tok': 0,
                'err': f'URLError[{reason[:60]}]'}
    except Exception as e:
        return {'ok': False, 'latency': time.time() - t0, 'in_tok': 0, 'out_tok': 0,
                'err': f'{type(e).__name__}:{str(e)[:60]}'}
    finally:
        with _lock:
            _inflight -= 1


def pct(xs, p):
    if not xs:
        return 0.0
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(p / 100 * (len(s) - 1)))))
    return s[i]


def build_words(n, seed):
    """分层抽样 n 条（各 CEFR 等量），保证跨档难度一致"""
    con = sqlite3.connect(cwc.DB)
    rows = list(con.execute("""
        SELECT c.front, l.level, l.definitions FROM prebuilt_cards c
        JOIN prebuilt_language_cards l ON l.id=c.id
        WHERE c.subject='english' AND c.card_type='vocabulary'"""))
    con.close()

    def first_gloss(d):
        if not d:
            return None
        try:
            j = json.loads(d)
            return (j[0].get('meaning') or None) if j else None
        except Exception:
            return None

    by = {}
    for w, lv, d in rows:
        by.setdefault((lv or '').strip(), []).append({'word': w, 'gloss': first_gloss(d)})
    rng = random.Random(seed)
    lvs = sorted(by)
    per = max(1, n // max(1, len(lvs)))
    out = []
    for lv in lvs:
        pool = by[lv][:]
        rng.shuffle(pool)
        for it in pool[:per]:
            it['level'] = lv
            out.append(it)
    rng.shuffle(out)
    return out[:n]


def sample_inflight(stop_evt, interval=1.0):
    """每秒采样在途请求数"""
    while not stop_evt.is_set():
        with _lock:
            _inflight_samples.append(_inflight)
        stop_evt.wait(interval)


def bench(workers, n_words, seed):
    global _inflight_peak, _inflight_samples
    _inflight_peak = 0
    _inflight_samples = []

    words = build_words(n_words, seed)
    key = cwc.load_key()

    lv_dist = Counter(it['level'] for it in words)
    print(f'\n{"="*88}')
    print(f'并发 {workers}  ·  词数 {len(words)}  ·  seed {seed}  ·  '
          f'{"走代理" if _USE_PROXY else "🔵 直连(无代理)"}'
          f'{"  ·  🔑 长连接复用" if _USE_KEEPALIVE else ""}')
    print(f'CEFR 分布: {dict(sorted(lv_dist.items()))}')
    print('=' * 88)

    stop_evt = threading.Event()
    sampler = threading.Thread(target=sample_inflight, args=(stop_evt,), daemon=True)
    sampler.start()

    t0 = time.time()
    res = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(call_once, key, it['word'], it.get('gloss')): it for it in words}
        done = 0
        for f in as_completed(futs):
            it = futs[f]
            try:
                r = f.result()
            except Exception as e:
                r = {'ok': False, 'latency': 0, 'in_tok': 0, 'out_tok': 0,
                     'err': f'{type(e).__name__}'}
            r['word'] = it['word']
            res.append(r)
            done += 1
            if done % max(1, len(words) // 10) == 0:
                el = time.time() - t0
                print(f'    {done}/{len(words)}  {done/el:.2f} 条/秒  '
                      f'在途 {_inflight}  峰值 {_inflight_peak}')
    stop_evt.set()
    elapsed = time.time() - t0

    ok = [r for r in res if r['ok']]
    bad = [r for r in res if not r['ok']]
    lat = [r['latency'] for r in ok]
    cost = sum(r['in_tok'] for r in res) * cwc.P_IN / 1e6 + \
           sum(r['out_tok'] for r in res) * cwc.P_OUT / 1e6

    summary = {
        'workers': workers, 'words': len(words), 'seed': seed,
        'proxy': _USE_PROXY, 'keepalive': _USE_KEEPALIVE,
        'elapsed_s': round(elapsed, 1),
        'throughput': round(len(words) / elapsed, 3) if elapsed else 0,
        'ok': len(ok), 'fail': len(bad),
        'fail_rate': round(len(bad) / len(words) * 100, 2),
        'err_dist': dict(Counter(r['err'] for r in bad).most_common()),
        'lat_p50': round(pct(lat, 50), 2), 'lat_p95': round(pct(lat, 95), 2),
        'lat_p99': round(pct(lat, 99), 2), 'lat_max': round(max(lat), 2) if lat else 0,
        'lat_min': round(min(lat), 2) if lat else 0,
        'inflight_peak': _inflight_peak,
        'inflight_avg': round(sum(_inflight_samples) / max(1, len(_inflight_samples)), 1),
        'inflight_series': _inflight_samples[:120],
        'cost': round(cost, 3),
        'ts': int(time.time()),
    }
    print(f'\n  耗时 {elapsed:.1f}s  ·  吞吐 {summary["throughput"]} 条/秒')
    print(f'  成功 {len(ok)} · 失败 {len(bad)} ({summary["fail_rate"]}%)  {summary["err_dist"]}')
    if lat:
        print(f'  延迟 min {summary["lat_min"]}s · p50 {summary["lat_p50"]}s · '
              f'p95 {summary["lat_p95"]}s · p99 {summary["lat_p99"]}s · max {summary["lat_max"]}s')
    print(f'  在途请求 峰值 {_inflight_peak} / 均值 {summary["inflight_avg"]}')
    print(f'  成本 ≈ ¥{summary["cost"]:.3f}')

    os.makedirs(BENCH_DIR, exist_ok=True)
    with open(RESULTS, 'a', encoding='utf-8') as fh:
        fh.write(json.dumps(summary, ensure_ascii=False) + '\n')
    return summary


def report():
    if not os.path.exists(RESULTS):
        print('  无历史结果')
        return
    rows = [json.loads(l) for l in open(RESULTS, encoding='utf-8') if l.strip()]
    print(f'\n{"并发":>6}{"词数":>7}{"耗时s":>9}{"条/秒":>9}{"失败%":>7}'
          f'{"p50":>7}{"p95":>7}{"在途峰":>8}{"代理":>6}{"成本":>8}')
    print('-' * 96)
    for r in sorted(rows, key=lambda x: (x.get('proxy', True), x['workers'])):
        print(f'{r["workers"]:>6}{r["words"]:>7}{r["elapsed_s"]:>9}{r["throughput"]:>9}'
              f'{r["fail_rate"]:>7}{r["lat_p50"]:>7}{r["lat_p95"]:>7}'
              f'{r["inflight_peak"]:>8}{("是" if r.get("proxy", True) else "🔵否"):>6}'
              f'{r["cost"]:>8}')
    print()
    print('  错误分布:')
    for r in sorted(rows, key=lambda x: x['workers']):
        if r['err_dist']:
            print(f'    并发 {r["workers"]:>4}: {r["err_dist"]}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--workers', type=int, nargs='+', default=[8],
                    help='并发档位，可多个（顺序跑）')
    ap.add_argument('--factor', type=float, default=1.2,
                    help='词数 = ceil(workers × factor)，须 >1 才能让并发用满')
    ap.add_argument('--words', type=int, help='直接指定词数（覆盖 factor）')
    ap.add_argument('--seed', type=int, default=20260926)
    ap.add_argument('--report', action='store_true')
    ap.add_argument('--no-proxy', action='store_true',
                    help='绕过 http_proxy 直连（对比瓶颈是否在本地代理）')
    ap.add_argument('--keepalive', action='store_true',
                    help='用长连接复用（对比瓶颈是否在「每请求新建 TLS 连接」）')
    args = ap.parse_args()

    global _USE_PROXY, _OPENER, _USE_KEEPALIVE
    if args.no_proxy:
        _USE_PROXY = False
        _OPENER = None
    _USE_KEEPALIVE = args.keepalive

    if args.report:
        report()
        return

    for i, w in enumerate(args.workers):
        n = args.words or int(-(-w * args.factor // 1))
        bench(w, n, args.seed + i * 7919)
    print()
    report()


if __name__ == '__main__':
    main()
