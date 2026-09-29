#!/usr/bin/env python3
"""CoEvo 词库重跑 · 共享契约与调用层

被以下脚本复用：
  · llm_full_rerun_sample.py   抽样验证
  · llm_full_rerun.py          全量生成（含断点续跑）

维护约定：
  🔴 契约（PROMPT）**只在这里改**，两个脚本自动同步 —— 避免「抽样用 v5、全量用 v4」的错配。
  改动契约后必须重跑抽样验证（历史教训：契约漏写 `form` 字段导致 219 个词素全废）。
"""
import http.client
import json
import os
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, 'data', 'coevo.db')
ENV = os.path.join(ROOT, 'backend', '.env')
PREBUILT = os.path.join(ROOT, 'data', 'curriculum', 'prebuilt')

API_URL = 'https://api.deepseek.com/chat/completions'
MODEL = os.environ.get('COEVO_LLM_MODEL', 'deepseek-flash')
THINKING = {'type': 'disabled'}

# ══════════════════════════════════════════════════════════════════════
# 🔴 代理开关（2026-09-26 压测发现，**影响并发上限 50 倍**）
#
#   实测本机环境有 http_proxy=http://127.0.0.1:63593，它是**并发瓶颈**：
#     走代理：≤200 并发可用（99 条/秒）；250 起偶发失败；300 起 43% 失败；500 起 66% 失败
#     直连  ：300/400/500/800/1000 并发全部 0 失败（最高 262 条/秒）
#   错误特征：`Tunnel connection failed: 503`（**代理返回的，不是 API 限流**）
#             `WinError 10053/10054`（连接被中止/重置）
#   → 而成功请求的 p50 延迟**完全不随并发变化**（恒定 1.5–1.7s）→ **服务端远未饱和**
#
#   默认 True（保守，保持既有行为）；高并发场景应设 `set_proxy(False)` 或传 `no_proxy=True`。
#   ⚠️ 前提：本机网络能直连 api.deepseek.com（已实测可行）。若所在环境强制走代理，直连会失败。
# ══════════════════════════════════════════════════════════════════════
_USE_PROXY = True
_OPENER = None


def set_proxy(enabled: bool):
    """切换是否使用系统代理（影响 `call_llm`）"""
    global _USE_PROXY, _OPENER
    _USE_PROXY = bool(enabled)
    _OPENER = None


def _get_opener():
    global _OPENER
    if _OPENER is None:
        if _USE_PROXY:
            _OPENER = urllib.request.build_opener()
        else:
            _OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return _OPENER


# ── 价格（deepseek-flash，¥/1M token）──
P_IN, P_OUT = 1.5, 4.5

# ══════════════════════════════════════════════════════════════════════
# 契约 v5（2026-09-26）
#   v1 → v2  新增 inflection_of + relation 扩 inflection
#   v2 → v3  删 base_form（可推导）+ 扁平化 entry + 改名 derived_from
#   v3 → v4  etymology 结构化（{text, etyma[]}）
#   v4 → v5  新增 entry_type + etyma[].parent + 「信任自身词汇知识」反制规则
#   v5 → v6  新增 ipa / definition / context —— 🔴 三个字段原本由**外部词典源**提供
#            （`coevo.db` 的 `prebuilt_language_cards`），该库于 2026-09-29 退役 → 契约须自产。
#            ⚠️ 这条改动同时**绕开了 P0 污染源**（`a`/`with`/`health care` 的错字段都来自那里）。
# ══════════════════════════════════════════════════════════════════════
CONTRACT_VERSION = 'v6'

# ── 契约 prompt：🔑 **单一来源文件**（Python 与 Rust 后端共用，避免分叉）──
#
# 🔴 为什么抽出来：白哥要求「在线生成与预制**同一套 prompt**」。
#    若 Python（预制/回流）与 Rust（在线 A1）各写一份 → **必然分叉**。
#    → 抽成 `backend/prompts/wordlib_contract.md`，**两边都读它**。
#
# 🔑 部署一致性：后端 `COEVO_PROMPTS_DIR` 指向 prompts 目录 →
#    该文件随部署包一起走（`backend/prompts/` → `/opt/coevo/prompts/`）。
#
# ⚠️ 改这个文件 = 改契约 → **必须跑 `scripts/smoke_contract.py`**（10 项冒烟）验证。
_PROMPT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'backend', 'prompts', 'wordlib_contract.md',
)
if not os.path.exists(_PROMPT_PATH):                      # 🔴 明确失败，不静默给空 prompt
    raise FileNotFoundError(
        f'🔴 契约 prompt 文件不存在: {_PROMPT_PATH}\n'
        f'   （它由 Python 与 Rust 共用 —— 见 scripts/coevo_wordlib_contract.py 注释）'
    )
PROMPT = open(_PROMPT_PATH, encoding='utf-8').read()
if PROMPT.endswith('\n'):
    PROMPT = PROMPT[:-1]                                  # 精确还原（文件末尾的换行只是文件结束符）
if not PROMPT.strip():
    raise ValueError(f'🔴 契约 prompt 文件是空的: {_PROMPT_PATH}')


def load_key() -> str:
    for line in open(ENV, encoding='utf-8'):
        line = line.strip()
        if line.startswith('DEEPSEEK_API_KEY='):
            return line.split('=', 1)[1].strip()
    raise SystemExit('未找到 DEEPSEEK_API_KEY')


# ══════════════════════════════════════════════════════════════════════
# 调用统计（🔑 可观测性：没有它就看不出限流）
#
#   实测教训（2026-09-26）：生产脚本跑 400 条用 216 秒，而压测同并发 4000 条只用 43 秒。
#   差异根源是 `call_llm` 的 4 次指数退避重试会**把限流掩盖成「慢但成功」**
#   —— 不加统计，输出里只有「成功 400 · 失败 0」，完全看不出正在被限流。
#   统计项：`retried_calls` / `retries` / `http_429` 任一不为 0 → **说明在限流**
# ══════════════════════════════════════════════════════════════════════
_stats_lock = threading.Lock()
STATS = {'calls': 0, 'retried_calls': 0, 'retries': 0, 'http_429': 0,
         'http_5xx': 0, 'conn_err': 0, 'timeout': 0}


def reset_stats():
    with _stats_lock:
        for k in STATS:
            STATS[k] = 0


def stats_snapshot() -> dict:
    with _stats_lock:
        return dict(STATS)


def _bump(key, n=1):
    with _stats_lock:
        STATS[key] = STATS.get(key, 0) + n


# ══════════════════════════════════════════════════════════════════════
# 🔑 长连接复用（2026-09-26 压测定位，**提速 3.4 倍且失败率归零**）
#
#   100 并发 · 3000 条 · 直连 实测对照：
#     urllib 每请求新建连接 → 160.4s · 18.7 条/秒 · **1.83% 失败**（越跑越慢，尾部 72s）
#     长连接复用           →  47.0s · 63.8 条/秒 · **0% 失败**（曲线平稳）
#
#   根因：`urllib` **每个请求新建一条 TLS 连接**。动态端口仅 16,384 个，TIME_WAIT 保留 120s
#        → 高并发持续跑累积上万 TIME_WAIT → **端口耗尽 + TLS 握手风暴**
#        → 报错全是建连阶段（`SSL handshake timed out` / `SSLEOFError` / `ConnectionReset`）
#        → **`429` 全程为 0 → 根本不是 API 限流**
#   修法：每线程持有一条长连接反复复用 → 连接数 O(请求数) → O(并发数)
#   ⚠️ 走代理时不经此路径（http.client 走代理需 set_tunnel，值不回复杂度）→ 低并发够用
#
#   🔴 补充修法（2026-09-26 第二处）：长连接会被**服务端单方面关闭**（idle 超时 / 达到寿命），
#      客户端不知道 → 下次复用这条死连接 → 报 `RemoteDisconnected` / `SSLEOFError` / `ConnectionReset`
#      → 虽有重试兜底，但每次失败要退避 1–2 秒，**少数线程变成长尾**拖慢整体。
#      两条主动策略把「被动失败」转成「主动轮换」：
#        ① **响应头 `Connection: close` → 主动重置连接**（服务端明说了要关）
#        ② **连接复用次数上限**（`MAX_REUSE_PER_CONN`，到点主动重建，不等它坏）
# ══════════════════════════════════════════════════════════════════════
_tls_conn = threading.local()
_HOST = 'api.deepseek.com'
_PATH = '/chat/completions'

# 🔴 连接建立与读取用**不同超时**（2026-09-26 第三处修复）
#   原实现 `timeout=120` 同时作用于握手 → 握手卡住时单个请求要等 120 秒
#   正常 TLS 握手 + 首次响应应 <3 秒（实测 p99 3.6s）→ 连接超时 15 秒足够
CONNECT_TIMEOUT = 15      # 建立 TCP+TLS 连接（含握手）
READ_TIMEOUT = 60         # 连上后的读超时（实测 p99 3.6s / 偶见 22s，60 秒留足余量）
MAX_REUSE_PER_CONN = 200  # 🔑 单条连接最多复用多少次（到点主动重建，避免用到被服务端关掉的）


def _conn_get(timeout: int = READ_TIMEOUT):
    """取（或建）本线程的长连接"""
    c = getattr(_tls_conn, 'conn', None)
    if c is None:
        ctx = ssl.create_default_context()
        c = http.client.HTTPSConnection(_HOST, timeout=timeout, context=ctx)
        # 显式建连：**用短连接超时**，避免握手卡死拖 120 秒
        c.timeout = CONNECT_TIMEOUT
        c.connect()
        c.timeout = timeout                    # 连上后换成读超时
        if c.sock is not None:
            c.sock.settimeout(timeout)
        _tls_conn.conn = c
        _tls_conn.uses = 0
    return c


def _conn_bump():
    """记录本线程连接复用次数；到上限则主动重建（避免用到服务端已关闭的连接）"""
    n = getattr(_tls_conn, 'uses', 0) + 1
    _tls_conn.uses = n
    if n >= MAX_REUSE_PER_CONN:
        _conn_reset()


def _conn_reset():
    c = getattr(_tls_conn, 'conn', None)
    if c is not None:
        try:
            c.close()
        except Exception:
            pass
    _tls_conn.conn = None


def _conn_reset():
    c = getattr(_tls_conn, 'conn', None)
    if c is not None:
        try:
            c.close()
        except Exception:
            pass
    _tls_conn.conn = None


def call_llm(key: str, word: str, retries: int = 4, definition: str = None, timeout: int = 120):
    """调用 LLM 产出词条内容包。

    definition: 现网释义（可选）—— 传入时附在 prompt 里，让 LLM 有机会用自身知识纠正坏数据
                （实测有效：`a` 的释义误为 `happy` 的，LLM 靠自身知识纠正了）
    timeout:    单次请求超时秒数（探测场景应设短，如 15）

    重试策略**按错误类型区分**（这点很关键）：
      · 连接层错误（SSL/重置/超时）→ **短退避后重建连接重试**（本地/网络问题，快速重连即可）
      · 429 / 5xx                → **指数退避**（服务端限流，等一等）
    """
    content = PROMPT.format(word=word)
    if definition:
        content += (f'\n\n---\nThe current dictionary gloss for "{word}" in our (possibly outdated) '
                    f'database is:\n  {definition[:200]}\n'
                    f'If this gloss is WRONG or unrelated to the spelling, ignore it and trust your own knowledge.')
    payload = json.dumps({
        'model': MODEL,
        'messages': [{'role': 'user', 'content': content}],
        'temperature': 0.1,
        'max_tokens': 900,
        'response_format': {'type': 'json_object'},
        'thinking': THINKING,
    })
    headers = {'Content-Type': 'application/json', 'Authorization': f'Bearer {key}'}

    for attempt in range(retries):
        _bump('calls')
        if attempt > 0:
            _bump('retried_calls')
            _bump('retries')
        try:
            if not _USE_PROXY:
                # ── 直连：长连接复用（高并发必需）──
                c = _conn_get(timeout)
                c.request('POST', _PATH, body=payload, headers=headers)
                r = c.getresponse()
                raw = r.read()
                status = r.status
                # 🔑 服务端明说 `Connection: close` → 主动重置，别等下次复用死连接
                if (r.getheader('Connection') or '').lower() == 'close':
                    _conn_reset()
                else:
                    _conn_bump()               # 到复用上限则主动轮换
            else:
                # ── 走代理：urllib（走代理时 http.client 需 set_tunnel，值不回复杂度）──
                req = urllib.request.Request(API_URL, data=payload.encode(), headers=headers)
                with _get_opener().open(req, timeout=timeout) as r:
                    raw = r.read()
                    status = r.status

            if status != 200:
                if status == 429:
                    _bump('http_429')
                elif status in (500, 502, 503):
                    _bump('http_5xx')
                _conn_reset()
                if status in (429, 500, 502, 503) and attempt < retries - 1:
                    time.sleep(2 ** attempt)          # 服务端限流 → 指数退避
                    continue
                return {'ok': False, 'error': f'HTTP {status}', 'attempts': attempt + 1}

            res = json.loads(raw)
            data = json.loads(res['choices'][0]['message'].get('content') or '{}')
            usage = res.get('usage', {})
            return {'ok': True, 'data': data,
                    'in_tok': usage.get('prompt_tokens', 0),
                    'out_tok': usage.get('completion_tokens', 0),
                    'attempts': attempt + 1}

        except (http.client.HTTPException, ssl.SSLError, OSError, TimeoutError,
                urllib.error.URLError, ConnectionError) as e:
            _bump('conn_err')
            _conn_reset()                              # 连接已坏 → 下次必重建
            if attempt < retries - 1:
                time.sleep(min(2 ** attempt, 2))       # 连接问题 → **短退避**，别等太久
                continue
            return {'ok': False, 'error': f'{type(e).__name__}: {e}', 'attempts': attempt + 1}
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            return {'ok': False, 'error': f'{type(e).__name__}: {e}', 'attempts': attempt + 1}
    return {'ok': False, 'error': 'retries exhausted', 'attempts': retries}


# 压测实测的安全并发（2026-09-26，`scripts/bench_concurrency.py`）
WORKERS_DIRECT = 300    # 直连：实测 300 持续 43s 稳定，失败 1/4000 = 0.03%
WORKERS_PROXY = 100     # 走代理：≤200 可用，取 100 留余量（250 起偶发失败）


def probe_and_configure(key: str, probe_word: str = 'the') -> tuple:
    """启动探测：确认「直连 / 代理」哪条路可用，自动配置并返回 (mode, workers)

    🔑 为什么需要：本机有 http_proxy，它是**并发瓶颈**（300 并发下 43% 失败），
       但某些环境可能强制走代理（直连不通）。**探测后自动选路**，避免跑全量时才发现。
    """
    # ① 先试直连（快超时，避免卡 120s）
    set_proxy(False)
    if call_llm(key, probe_word, retries=1, timeout=20).get('ok'):
        return '直连', WORKERS_DIRECT
    # ② 回退代理
    set_proxy(True)
    if call_llm(key, probe_word, retries=1, timeout=30).get('ok'):
        return '代理', WORKERS_PROXY
    return None, 0

