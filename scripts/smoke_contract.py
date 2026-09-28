"""契约**冒烟测试** —— 用「已知问题词」验证 prompt 改动没把事做坏。

# 为什么是这 10 条（不是随机抽样）
每条都对应一个**真实发生过的 bug**或边界。随机抽样验不出「已知坏值是否被纠正」：
| 样本 | 对应的已知问题 |
|---|---|
| `a` | 🔴 P0 整卡串位（ipa/def/ctx 三段都是 `happy` 的） |
| `health care` | 🔴 P0 整卡串位（是 `heal` 的卡） |
| `with` | 🔴 ipa 串位（`/ɪt/`，是 `it` 的） |
| `first lady` | 🔴 ipa 串位（`first person` 的） |
| `frying pan` | 🔴 ipa 截断（`/fraɪ/`，只到 `fry`） |
| `hong kong` | 多词专名（库内 `hong`/`kong` 是两个独立 token） |
| `behavior` | 英美变体缺口 |
| `cannot` | 词元缺失 |
| `incredible` / `building` | 对照组（确认没把原来好的做坏） |

# 跑法
```bash
python scripts/smoke_contract.py          # 10 条，约 ¥0.07
```
🔑 **每次改契约 prompt 后都该跑它** —— 它是这套 prompt 的**回归测试**。

# 判据
自动判据只标「机器能判的」（ipa 完整性 / definition 三键 / context 是否含该词）；
**语义质量留给人眼** —— 语言对错不是正则能判的。

📌 首次跑（2026-09-29 · 契约 v5→v6）：10/10 成功 · 0 自动告警 · ¥0.0644
"""
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coevo_wordlib_contract as C  # noqa: E402

# ── 样本：每条都针对一个已知问题（`why` 列说明挑它的理由）──
SAMPLES = [
    # 🔴 P0 整卡串位（现状坏值 → 测「传入坏释义，LLM 能否纠正」）
    ('a', 'feeling or showing pleasure or contentment.', 'P0整卡串位：现状 ipa/def/ctx 三段都是 happy 的'),
    ('health care', 'to become healthy again', 'P0整卡串位：现状是 heal 的卡'),
    # 🔴 P0 仅 ipa 串位 / 截断
    ('with', None, 'P0 ipa 串位：现状 /ɪt/（是 it 的）'),
    ('first lady', None, 'P0 ipa 串位：现状 /fɜːst ˈpɜːsən/（first person 的）'),
    ('frying pan', None, 'P0 ipa 截断：现状 /fraɪ/（只到 fry）'),
    # 🆕 缺口样本（库里根本没有这些词）
    ('hong kong', None, '多词专名：库里 hong/kong 是两个独立 token，从未有过 hong kong'),
    ('behavior', None, '英美变体缺口：behavior/behaviour 两边都不在库'),
    ('cannot', None, '词元缺失（freq 258）：不是变形漏，是词元本身就缺'),
    # 对照组（正常词，看 v6 有没有把原来好的做坏）
    ('incredible', None, '对照组：契约示例词'),
    ('building', None, '对照组：is_own_entry 边界（building 是独立词，不是 build 的变形）'),
]


def check(rec):
    """自动判据 —— 只标「机器能判的」，语义质量留给人眼。"""
    d = rec.get('data') or {}
    flags = []

    # ① ipa：完整 /…/（P0 的 S1/S2）
    ipa = d.get('ipa') or ''
    if not ipa:
        flags.append('🔴 ipa 缺失')
    elif '/ˈ' == ipa.strip() or ipa.strip() in ('/', ''):
        flags.append('🔴 ipa 残缺')
    else:
        # 至少一个完整的 /.../
        segs = [s for s in ipa.strip().split('/') if s.strip() and not s.strip().startswith('(')]
        if not ipa.strip().startswith('/'):
            flags.append('🔴 ipa 未以 / 开头')
        if ipa.count('/') < 2:
            flags.append('🔴 ipa 无成对斜杠')

    # ② definition：三键齐全 + en 非空
    df = d.get('definition')
    if not isinstance(df, dict):
        flags.append('🔴 definition 不是对象')
    else:
        for k in ('pos', 'en', 'zh'):
            if not df.get(k):
                flags.append(f'🔴 definition.{k} 缺失')
        if df.get('pos') and not (df['pos'].startswith('[') and df['pos'].endswith(']')):
            flags.append(f"🟠 pos 未加方括号: {df['pos']!r}")

    # ③ context：必须含该词或其变形（P0 的 S4）
    ctx = d.get('context') or ''
    if not ctx:
        flags.append('🔴 context 缺失')
    else:
        w = rec['word'].lower()
        low = ctx.lower()
        if ' ' in w:                      # 多词：整体匹配
            if w not in low:
                flags.append(f'🔴 context 不含该短语: {ctx!r}')
        else:
            # 粗判据：词干（去尾 1-2 字母）出现即可，由人眼复核变形
            stem = w[:-1] if len(w) > 4 else w
            if not any(t.startswith(stem) for t in low.replace('.', ' ').replace(',', ' ').split()):
                flags.append(f'🔴 context 不含该词: {ctx!r}')
    return flags


def main():
    key = C.load_key()
    mode, workers = C.probe_and_configure(key)
    print(f'探测: mode={mode!r} workers={workers}')
    if mode is None:
        sys.exit('🔴 不通')

    results = []
    with ThreadPoolExecutor(max_workers=5) as ex:
        futs = {}
        for w, dfn, why in SAMPLES:
            futs[ex.submit(C.call_llm, key, w, 3, dfn, 60)] = (w, dfn, why)
        for fu in as_completed(futs):
            w, dfn, why = futs[fu]
            r = fu.result()
            r['word'] = w
            r['passed_def'] = dfn
            r['why'] = why
            r['flags'] = check(r) if r.get('ok') else ['🔴 调用失败']
            results.append(r)

    # 按 SAMPLES 顺序重排，便于人眼对照
    order = {w: i for i, (w, _, _) in enumerate(SAMPLES)}
    results.sort(key=lambda r: order[r['word']])

    lines = []
    lines.append('=' * 100)
    lines.append(f'契约 {C.CONTRACT_VERSION} 小样本实测（{len(results)} 条）')
    lines.append('=' * 100)

    for r in results:
        lines.append('')
        lines.append('─' * 100)
        lines.append(f"【{r['word']}】  {r['why']}")
        if r['passed_def']:
            lines.append(f"  传入的现状释义: {r['passed_def'][:90]}")
        if not r.get('ok'):
            lines.append(f"  🔴 调用失败: {r.get('error')}")
            continue
        d = r['data']
        lines.append(f"  ipa        : {d.get('ipa')!r}")
        df = d.get('definition') or {}
        lines.append(f"  definition : pos={df.get('pos')!r}  en={df.get('en')!r}")
        lines.append(f"               zh={df.get('zh')!r}")
        lines.append(f"  context    : {d.get('context')!r}")
        lines.append(f"  entry_type : {d.get('entry_type')!r} | is_own_entry={d.get('is_own_entry')} "
                     f"| mnemonic.primary={(d.get('mnemonic') or {}).get('primary')!r}")
        mark = '✅ 无自动告警' if not r['flags'] else '  '.join(r['flags'])
        lines.append(f"  自动判据   : {mark}")

    st = C.stats_snapshot()
    ok = [r for r in results if r.get('ok')]
    tin = sum(r.get('in_tok', 0) for r in ok)
    tout = sum(r.get('out_tok', 0) for r in ok)
    cost = (tin * C.P_IN + tout * C.P_OUT) / 1_000_000
    lines.append('')
    lines.append('=' * 100)
    lines.append(f'汇总: 成功 {len(ok)}/{len(results)} · in={tin} out={tout} token · '
                 f'成本 ≈ ¥{cost:.4f}')
    lines.append(f'统计: {st}')
    nflag = sum(1 for r in ok if r['flags'])
    lines.append(f'自动判据有告警的: {nflag}/{len(ok)}')
    lines.append('=' * 100)

    out = '\n'.join(lines)
    p = os.path.join(os.environ.get('TEMP', '/tmp'), 'coevo_v6_smoke.txt')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(out)
    print(out)
    print(f'\n（完整输出已写入 {p}）')


if __name__ == '__main__':
    main()
