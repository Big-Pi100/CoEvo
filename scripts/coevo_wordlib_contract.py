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

PROMPT = """You are an expert English lexicographer building flashcard content for Chinese learners of English.

WORD: {word}

Return STRICT JSON with EXACTLY this shape (keys must all be present):
{{
  "word": "{word}",
  "entry_type": "word",
  "is_own_entry": true,
  "derived_from": null,
  "reason": "≤15字中文",
  "morphology": {{
    "analyzable": true,
    "relation": "derivation",
    "parts": [
      {{"form": "in-", "type": "prefix", "meaning": "不", "origin": "Latin"}},
      {{"form": "cred", "type": "root", "meaning": "相信", "origin": "Latin"}},
      {{"form": "-ible", "type": "suffix", "meaning": "可…的", "origin": "Latin"}}
    ]
  }},
  "etymology": {{
    "text": "拉丁 credere（相信）→ 不可相信的",
    "etyma": [
      {{"form": "credere", "form_ascii": "credere", "language": "Latin",
        "meaning": "相信", "role": "root", "parent": ""}}
    ]
  }},
  "ipa": "/ɪnˈkredəbl/",
  "definition": {{"pos": "[adj]", "en": "impossible or very hard to believe", "zh": "难以置信的"}},
  "context": "It seems incredible that no one noticed the mistake.",
  "collocations": [{{"phrase": "an incredible story", "zh": "一个难以置信的故事"}}],
  "mnemonic": {{"primary": "root", "secondary": ["cognate"], "rationale": "in(不)+cred(相信)+ible(可…的)"}},
  "confidence": 0.9
}}

FIELD RULES:
0) entry_type — classify the headword itself:
   * "word"         = single orthographic word (incredible, run, café, a.m. is NOT here)
   * "phrase"       = multi-word expression (ice cream, bus stop, have to, each other, according to)
   * "abbreviation" = an abbreviation / initialism as the headword (a.m., p.m., mr, cd, id, tv)
   * "proper"       = a proper name (India, Sunday, Isaac)
   * 🔴 If entry_type="phrase": morphology MUST be {{"analyzable": false, "relation": null, "parts": []}}
     because morpheme splitting does not apply to a multi-word expression.
   * 🔴 If entry_type="abbreviation": is_own_entry must be true (a learner must learn it as its own item)
     and give the EXPANSION inside "reason" (e.g. "a.m. = ante meridiem, 上午").
1) is_own_entry — does this spelling deserve its OWN flashcard?
   * false: regular inflections (plural / past / participle / comparative / 3rd person) AND transparent derivatives whose meaning is fully predictable from the base (e.g. "politically"←political, "quickly"←quick, "aberrations"←aberration, "ran"←run, "worse"←bad).
   * true: it carries a meaning or usage a learner must learn as a separate item, even if historically derived — e.g. "building"(建筑物), "bore"(使厌烦), "well"(副词/井), "lyrics"(歌词), "sanctions"(制裁), "coordinates"(坐标), "attuned"(对…敏感的), "used"(用过的/习惯于).
   * 🔴 If the given word's OWN definition (shown to you) is unrelated to its spelling — e.g. a function word whose gloss describes an emotion — TRUST YOUR OWN LEXICAL KNOWLEDGE over the supplied definition, and set is_own_entry=true with a correct reason.
   * If unsure, prefer false only when the meaning is 100% predictable.
2) derived_from — the base word this spelling is built from, whether by inflection OR by derivation (this is what a learner would look up to find the related core word). null only for a base word with no such relation.
   * INFLECTION examples: "used" -> "use"; "attuned" -> "attune"; "isolated" -> "isolate"; "ran" -> "run"; "feet" -> "foot"; "taught" -> "teach".
   * DERIVATION examples: "politically" -> "political"; "recently" -> "recent"; "farmer" -> "farm"; "incredible" -> null.
   * 🔴 HARD RULE: if is_own_entry=false, derived_from MUST NOT be null (the card must be findable via its base). e.g. "politically" is_own_entry=false AND derived_from="political".
   * Give it even when is_own_entry=true (e.g. "attuned": is_own_entry=true AND derived_from="attune", because a learner should also reach "attune").
3) morphology.analyzable — true ONLY if the word breaks into morphemes that are still SEMANTICALLY TRANSPARENT in modern English AND genuinely help memorization.
   * true examples: "incredible"=in-+cred+-ible; "subway"=sub+way (relation="compound"); "lovely"=love+-ly (relation="derivation"); "transact"=trans+act.
   * false for OPAQUE words even if they look affixed: "understand" is NOT under+stand; "interest" NOT in+terest; "reason" NOT re+ason; "decide"/"require"/"remain" have dead affixes. Base words like "happy"/"table"/"be"/"get" are false.
   * NEVER invent roots. If unsure set analyzable=false and lower confidence.
4) morphology.relation — ONE of:
   * "inflection"  = the affix is INFLECTIONAL, i.e. it does NOT change the part of speech and creates no new word: -ed, -ing, -s/-es, comparative -er, superlative -est. Examples: "attuned"=attune+-ed, "used"=use+-ed, "surprising"=surprise+-ing, "cheaper"=cheap+-er.
   * "derivation"  = a DERIVATIONAL affix changes the part of speech or creates a new lexical item: -er(agent noun), -ly, -able, -ment, -ness, -ful, -ous, -tion. Examples: "farmer"=farm+-er, "precisely"=precise+-ly, "incredible"=in-+cred+-ible.
   * "compound"    = two free morphemes joined: "subway"=sub+way, "earthquake"=earth+quake.
   * null          = analyzable=false.
   * 🔴 "-er" has TWO faces — decide by meaning, not spelling: AGENT "-er" (farmer, owner, folder) = "derivation"; COMPARATIVE "-er" (cheaper, taller, later) = "inflection".
   * 🔴 If any part is a purely inflectional suffix (-ed/-ing/-s/comparative -er/-est), the relation is "inflection" even if the base itself has a derivational structure.
5) morphology.parts — ONLY when analyzable=true, 2-4 items in order. EVERY part object MUST contain ALL FOUR keys, no exceptions:
      "form"    = the morpheme as it appears, hyphen on the affix side: "in-", "cred", "-ible", "at-", "tune", "-ed"
      "type"    = prefix | root | suffix
      "meaning" = CHINESE meaning (e.g. "不", "相信", "可…的")
      "origin"  = Latin | Greek | Germanic | French | Old English | other
   When analyzable=false, "parts" MUST be an empty array [].
6) etymology — an object with TWO keys, BOTH required:
      "text"  = ≤40 Chinese chars narrative, ONLY if it genuinely aids memory; use "" otherwise.
                e.g. "拉丁 credere（相信）→ 不可相信的"
      "etyma" = array of the HISTORICAL SOURCE WORDS this word descends from. 🔑 This is what
                enables cognate grouping by etymology, so give it even for otherwise opaque words.
                Each item MUST contain ALL SIX keys:
                  "form"       = source word as written, MAY be non-ASCII: "capere", "γράφειν", "café", "Ärger"
                  "form_ascii" = ASCII transliteration, used as the grouping key: "capere", "grafein", "cafe", "aerger"
                                 (Greek/Cyrillic -> romanize; diacritics -> strip or expand: ä->ae, é->e)
                  "language"   = Latin | Greek | French | Old English | Old Norse | Proto-Germanic | Italian | Spanish | Arabic | Hebrew | other
                  "meaning"    = CHINESE meaning, e.g. "拿取", "相信"
                  "role"       = root | prefix | derived | whole
                                 * "whole" = borrowed as a whole word rather than derived (e.g. "café" <- French "café")
                  "parent"     = 🆕 the EARLIER source word this item itself comes from, as plain text;
                                 "" if it is already a root with no earlier source.
                                 * "percipere" -> "capere"; "decipere" -> "capere"; "respicere" -> "specere"
                                 * "capere" -> "" (already the root)
                                 🔑 This matters: LLM naturally picks different granularities (perceive comes
                                   from "percipere" while receive comes from "capere"), so "parent" is what
                                   lets us walk up to the shared root and group them together.
                * 0-3 items. Use [] ONLY when no source is traceable (rare).
                * Do NOT repeat an item twice.
                * Examples:
                    "receive" -> [{{"form":"capere","form_ascii":"capere","language":"Latin","meaning":"拿取","role":"root","parent":""}}]
                    "perceive"-> [{{"form":"percipere","form_ascii":"percipere","language":"Latin","meaning":"完全拿取","role":"whole","parent":"capere"}}]
                    "café"    -> [{{"form":"café","form_ascii":"cafe","language":"French","meaning":"咖啡","role":"whole","parent":""}}]
7) collocations — 0-3 real frequent phrases, each with a Chinese gloss.
8) mnemonic.primary ∈ root|cognate|etymology|collocation|image|context — the single method most likely to help a learner recall THIS word.
   * 🔴 "cognate" means the word SHARES A ROOT OR ETYMON with another English word (receive/perceive/conceive).
     A mere sound-alike (e.g. "papa" ~ Chinese "爸爸") is NOT cognate -> use "image".
   * 🔴 HARD RULE: if primary="root", then morphology.analyzable MUST be true.
     Otherwise choose "etymology" or "context".
9) confidence — 0.0-1.0 for your overall judgement.
10) ipa — BRITISH (or American) phonetic transcription, wrapped in slashes.
    * MUST be COMPLETE: a well-formed `/.../`, never a fragment. 🔴 Never output just "/ˈ" or "/".
    * 🔴 Never truncate to a prefix. If you are unsure of the whole word, give your best full
      transcription — a partial one is WORSE than a slightly imprecise one.
    * UK/US differ → give both, in this exact style:
        "/ɡlɑːs/ (UK) or /ɡlæs/ (US)"
      Other legitimate variants: "/ˈdɛvi/ (or /ˈdiːvi/ unclear)" · "/ʃɑ̃ːbr/ (French) or /ˈʃɒmbər/ (anglicized)".
    * For entry_type="phrase": transcribe the WHOLE phrase, not just its first word.
      (Real bug this prevents: "frying pan" once got /fraɪ/ — the ipa of "fry".)
11) definition — an object with EXACTLY THREE keys:
      "pos" = part of speech in square brackets: "[n]", "[v]", "[adj]", "[adv]", "[prep]", "[conj]",
              "[pron]", "[det]", "[num]", "[int]" ... (a phrase/idiom → "[phr]")
      "en"  = a concise English definition of THIS word (one clause, ≤ 12 words, no full stop needed)
      "zh"  = Chinese meaning, ≤ 12 chars, comma-separated for multiple senses
    * 🔴 HARD RULE: "en" and "zh" MUST describe the given WORD. Do NOT describe a different word.
      (Real bug this prevents: the card for "a" once carried the definition of "happy".)
    * 🔴 If the supplied dictionary gloss (shown to you after the word) describes something
      UNRELATED to "{word}", IGNORE it entirely and write the correct definition yourself.
    * Give the word's OWN meaning, not the meaning of its base form:
      "building" → "[n] a structure with a roof and walls", NOT "to build".
12) context — ONE natural example sentence (English), using the word as a learner would meet it.
    * 🔴 HARD RULE: the sentence MUST contain "{word}" itself, or a regular inflection of it
      (plural / past / -ing / comparative). Never output a sentence that does not contain the word
      — otherwise the learner cannot see the word in context.
      (Real bug this prevents: "a"'s card once showed "I am happy to see you." — no "a" in it.)
    * Prefer a sentence from general/neutral prose (news-like). Avoid quotes, avoid proper names
      unless the word IS a proper noun. Length: 6–16 words. Plain text, no markdown, no wrapping quotes.

Output JSON only. No prose, no markdown fences."""


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

