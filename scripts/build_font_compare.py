#!/usr/bin/env python3
"""字体对照页生成器 —— 用**真实字体 + 真实词卡**渲染

## 为什么要有这一页

选字体只看表格是选不出来的 —— 必须**看到同一段真实内容在各候选下的渲染**。
所以本脚本：
① 取 `word.db` 的**真实词卡**（含真实 IPA）作为对照内容
② 内联各候选的**子集 woff2**（base64），所以页面**离线可看、字体真实**
③ 用 `coevo_tokens` 的三档主题值做背景 —— 顺便验证「三档下 IPA 都不回退」

## 用法

    python3 scripts/build_fonts.py --all          # 先生成子集
    python3 scripts/build_font_compare.py         # 再生成对照页
"""

import base64
import json
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_DIR = os.path.join(ROOT, 'data', 'fonts-build')
DB = os.path.join(ROOT, 'data', 'word.db')
OUT = os.path.join(ROOT, 'docs', 'design', 'font-candidates-2026-09-26.html')

#: 对照用真实词（从 word.db 取，覆盖不同 IPA 特征）
PICK = ['absurd', 'achieve', 'vertical', 'measure', 'thought', 'garage',
        'pleasure', 'nurse', 'leisure', 'sure']

#: 三档主题 —— 值取自 `app/lib/theme/coevo_tokens.dart`（与 spec §2.1 一致）
THEMES = {
    'ink': dict(label='墨', page='#F1EDE4', read='#FAF8F4', card='#FFFFFF',
                ink='#24211C', ink2='#6E6659', ink3='#9A917F', accent='#B4432C',
                line='#EFE9DE', sunken='#EDE6DA', lh=1.82),
    'grid': dict(label='格', page='#EDEEF0', read='#FFFFFF', card='#FFFFFF',
                 ink='#0A0A0A', ink2='#5A5A5A', ink3='#8A8A8A', accent='#B4432C',
                 line='#E8E8E8', sunken='#F0F0F0', lh=1.74),
    'night': dict(label='夜', page='#0B0D12', read='#14161C', card='#1C1F27',
                  ink='#EDEBE6', ink2='#9AA0AE', ink3='#6E7484', accent='#DB7E6B',
                  line='#262A34', sunken='#0B0D12', lh=1.84),
}

IPA_NEED = ('ˈɪəːæʊɛˌʃɒʌɡɔʒɑŋɜθð̃ɚʁø̬̩ᵊɾɐ̯œ')

CANDIDATES = [
    dict(key='charis', name='Charis SIL', role='正文 + IPA 一体（spec 原选它做 IPA）',
         files=[('charis-regular.woff2', 400, 'normal'), ('charis-bold.woff2', 700, 'normal'),
                ('charis-italic.woff2', 400, 'italic')],
         traits=['SIL 为**语言学出版**设计 → IPA 是其本职', '有**静态** Regular/Bold/Italic',
                 '拉丁底座：Bitstream Charter（耐读书体）'],
         ipa_miss=0, static=True),
    dict(key='andika', name='Andika', role='正文 + IPA 一体',
         files=[('andika-regular.woff2', 400, 'normal'), ('andika-bold.woff2', 700, 'normal')],
         traits=['SIL 为「**初学者 / 识字学习者**」设计 —— 字母形刻意不易混淆（b/d、p/q）',
                 '有**静态**字重', '⚠️ **无衬线** —— 气质偏「教材」而非「文学」'],
         ipa_miss=0, static=True),
    dict(key='gentium', name='Gentium Book Plus', role='正文 + IPA 一体',
         files=[('gentium-regular.woff2', 400, 'normal'), ('gentium-bold.woff2', 700, 'normal')],
         traits=['SIL 书体，为**印刷可读性**优化', 'IPA 全量', '有**静态**字重',
                 '⚠️ 气质偏「古籍 / 学术」'],
         ipa_miss=0, static=True),
    dict(key='noto', name='Noto Serif', role='正文 + IPA 一体',
         files=[('noto-regular.woff2', 400, 'normal'), ('noto-bold.woff2', 700, 'normal')],
         traits=['IPA 全量 · **体积最小**', '⚠️ 只有**可变字体**（构建期已 instance 成静态）',
                 '家族最全 → 后续加字符最容易'],
         ipa_miss=0, static=False),
    dict(key='literata', name='Literata', role='正文（🔴 缺 IPA → 必须配 fallback）',
         files=[('literata-regular.woff2', 400, 'normal'), ('literata-bold.woff2', 700, 'normal')],
         traits=['Google 为**屏幕长文阅读**设计的书体',
                 '🔴 **缺 18 个 IPA 码位**（spec §4.2 已实测，本轮复核一致）',
                 '⚠️ 只有可变字体'],
         ipa_miss=18, static=False),
]

LITERATA_FALLBACK = dict(key='literata-fb', name='Literata + Charis SIL 兜底',
                         role='spec 原案的完整形态（双字体 + fallback 链）',
                         files=[('literata-regular.woff2', 400, 'normal'),
                                ('literata-bold.woff2', 700, 'normal'),
                                ('charis-regular.woff2', 400, 'normal'),
                                ('charis-bold.woff2', 700, 'normal')],
                         traits=['正文用 Literata，IPA 缺失时**自动回退** Charis SIL',
                                 '🔑 这是 spec 的原设计 —— 技术上成立'],
                         ipa_miss=0, static=False, fallback='CoEvoIPA')


def _b64(path):
    with open(path, 'rb') as f:
        return base64.b64encode(f.read()).decode('ascii')


def _cards():
    con = sqlite3.connect(f'file:{DB}?mode=ro', uri=True)
    out = []
    for w in PICK:
        r = con.execute('SELECT id FROM word WHERE spelling=?', (w,)).fetchone()
        if not r:
            continue
        content = con.execute('SELECT content FROM card WHERE word_id=?', (r[0],)).fetchone()[0]
        d = json.loads(content)
        secs = {s['type']: s for s in d.get('sections', [])}
        mnem = next((s for s in d.get('sections', [])
                     if s['type'] in ('root', 'etymology', 'cognate')), None)
        out.append(dict(
            word=d.get('front'), ipa=d.get('ipa'),
            def_en=(secs.get('definition') or {}).get('en', ''),
            def_zh=(secs.get('definition') or {}).get('zh', ''),
            ctx=(secs.get('context') or {}).get('text', ''),
            mnem=(mnem or {}).get('text') or (mnem or {}).get('en') or '',
        ))
    con.close()
    return out


def _face_name(c, fname):
    """@font-face 的 family 名。

    🔑 fallback 链需要**两个不同 family 名**才能生效：
    正文体用 `CoEvoSerif-*`，IPA 兜底用 `CoEvoIPA-*`
    （对应 Flutter 的 `fontFamily` + `fontFamilyFallback`）。
    """
    is_ipa = bool(c.get('fallback')) and fname.startswith('charis')
    return f"CoEvoIPA-{c['key']}" if is_ipa else f"CoEvoSerif-{c['key']}"


def _collect_faces(c, store):
    """把该候选的字体收进全局表（按 名+字重+样式 去重）。

    ⚠️ **必须去重**：同一款字体在多个区域复用（如 Charis SIL 同时是
    候选本体、Literata 的兜底、三档主题演示），
    逐区域内联会让页面重复膨胀数倍（实测 858 KB → 去重后约 500 KB）。
    """
    for f, wt, st in c['files']:
        p = os.path.join(BUILD_DIR, f)
        if not os.path.exists(p):
            return False
        key = (_face_name(c, f), wt, st)
        if key not in store:
            store[key] = _b64(p)
    return True


def _face_css(store):
    return '\n'.join(
        f"@font-face{{font-family:'{n}';"
        f"src:url(data:font/woff2;base64,{b}) format('woff2');"
        f"font-weight:{wt};font-style:{st};font-display:block}}"
        for (n, wt, st), b in store.items())


def _font_stack(c):
    """该候选的 CSS font-family 栈。

    🔑 **这就是 spec §4.2 的方案**：正文体排在前，IPA 字体在后做 fallback ——
    `TextStyle(fontFamily: 'Literata', fontFamilyFallback: ['CharisSIL'])`。
    """
    fam = f"'CoEvoSerif-{c['key']}'"
    if c.get('fallback'):
        fam += f", 'CoEvoIPA-{c['key']}'"
    return fam


def _card_html(c, x, theme):
    """一张真实词卡 —— 字号严格按 spec §5.2。"""
    fam = _font_stack(c)
    return f'''
    <div class="wcard" style="background:{theme['card']};color:{theme['ink']}">
      <div class="w-head">
        <span class="w-word" style="font-family:{fam}">{x['word']}</span>
        <span class="w-ipa" style="font-family:{fam};color:{theme['ink2']}">{x['ipa']}</span>
      </div>
      <div class="sec" style="background:{theme['sunken']}">
        <div class="lab" style="color:{theme['ink3']}">释义</div>
        <div class="def-en" style="font-family:{fam}">{x['def_en']}</div>
        <div class="def-zh" style="color:{theme['ink2']}">{x['def_zh']}</div>
      </div>
      <div class="sec">
        <div class="lab" style="color:{theme['ink3']}">语境</div>
        <div class="ctx" style="font-family:{fam}">{x['ctx']}</div>
      </div>
    </div>'''


def main():
    cards = _cards()
    if not cards:
        print('🔴 取不到词卡样例')
        return 1
    print(f'真实词卡样例：{len(cards)} 条')

    all_cands = CANDIDATES + [LITERATA_FALLBACK]

    # ── 第一遍：收集全部字体（去重）──
    store = {}
    for c in all_cands:
        if not _collect_faces(c, store):
            print('  🔴 缺子集文件 → 先跑 python scripts/build_fonts.py --all')
            return 1
    print(f'内联字体：{len(store)} 个（去重后）· {sum(len(v) for v in store.values())*3//4/1024:.0f} KB')

    total = {c['key']: sum(os.path.getsize(os.path.join(BUILD_DIR, f))
                           for f, _, _ in c['files']) for c in all_cands}

    # ── 第二遍：生成 HTML ──
    blocks = []
    for c in all_cands:
        cards_html = '\n'.join(_card_html(c, x, THEMES['ink']) for x in cards[:3])
        miss_html = (f'<div class="warn">🔴 缺 {c["ipa_miss"]} 个 IPA 码位 → 缺失处会回退系统字体'
                     f'（字宽/字重会跳）</div>' if c['ipa_miss'] else
                     '<div class="pass">✅ IPA 30/30 全覆盖 —— 无需 fallback</div>')
        badges = ' '.join(
            f'<span class="badge {"b-bad" if "🔴" in t else "b-warn" if "⚠️" in t else "b-ok"}">{t}</span>'
            for t in c['traits'])
        blocks.append(f'''
  <section class="cand">
    <h2>{c['name']}</h2>
    <div class="role">{c['role']}</div>
    <div class="badges">{badges}</div>
    {miss_html}
    <div class="metrics">
      <span>子集体积 <b>{total[c['key']]/1024:.1f} KB</b>（{len(c['files'])} 文件 · woff2）</span>
      <span>字重形态 <b>{"静态 TTF" if c['static'] else "可变字体（构建期已 instance）"}</b></span>
    </div>
    <div class="ipa-strip" style="font-family:{_font_stack(c)}">
      <span class="strip-lab">IPA</span>{IPA_NEED}
    </div>
    <div class="cards" style="background:{THEMES['ink']['page']}">
      {cards_html}
    </div>
  </section>''')

    # 三档主题演示（用 Charis SIL —— IPA 全量，做代表）
    rep = CANDIDATES[0]
    theme_grid = []
    for t in THEMES.values():
        body = '\n'.join(f'''<div class="wcard" style="background:{t['card']};color:{t['ink']}">
          <div class="w-head"><span class="w-word" style="font-family:{_font_stack(rep)}">{x['word']}</span>
          <span class="w-ipa" style="font-family:{_font_stack(rep)};color:{t['ink2']}">{x['ipa']}</span></div>
          <div class="sec" style="background:{t['sunken']}"><div class="lab" style="color:{t['ink3']}">释义</div>
          <div class="def-en" style="font-family:{_font_stack(rep)}">{x['def_en']}</div>
          <div class="def-zh" style="color:{t['ink2']}">{x['def_zh']}</div></div>
        </div>''' for x in cards[:2])
        theme_grid.append(f'''<div class="tbox" style="background:{t['page']};border-color:{t['line']}">
          <div class="tbox-h" style="color:{t['ink']}">{t['label']} <span style="color:{t['accent']}">●</span>
            <span class="tbox-m">行高 {t['lh']}</span></div>
          {body}</div>''')

    head_css = _face_css(store)
    rows = '\n'.join(
        f'<tr><td><b>{c["name"]}</b></td>'
        f'<td>{"✅ 30/30" if not c["ipa_miss"] else f"🔴 缺 {c["ipa_miss"]}"}</td>'
        f'<td style="font-size:12.5px">{c["role"]}</td>'
        f'<td>{total[c["key"]]/1024:.1f} KB</td>'
        f'<td>{"静态" if c["static"] else "可变→instance"}</td></tr>'
        for c in all_cands)

    # ── 机制对比：同一个字体组合，两种指定方式 ──
    # 🔑 这是本轮最重要的发现：**spec 的字体选择没问题，但「全局 fallback 链」这个用法
    #    会让 93.9% 的音标变成「一条音标两种字体」**（实测 10,823/11,523）。
    L = "'CoEvoSerif-literata'"
    C = "'CoEvoSerif-charis'"
    chain = f'{L}, {C}'   # spec §4.2 的写法：全局 fallback 链
    demo_rows = []
    for x in cards[:4]:
        demo_rows.append(f'''<tr>
      <td class="dw">{x['word']}</td>
      <td class="bad"  style="font-family:{chain}">{x['ipa']}</td>
      <td class="good" style="font-family:{C}">{x['ipa']}</td>
    </tr>''')
    mech = f'''<h2 style="margin:38px 0 2px;font-size:19px">🔴 但 spec 的「用法」会制造一个新的不一致</h2>
<div class="note">spec §4.2 的写法是 <code>fontFamily: 'Literata', fontFamilyFallback: ['CharisSIL']</code>
—— <b>整段用一个字体栈</b>。因为 Literata 缺 18 个 IPA 码位、Charis 又有，
所以<b>同一条音标里会一部分字来自 Literata、一部分来自 Charis</b>。<br>
实测：<b>10,823 / 11,523 = 93.9% 的卡</b>会出现这种「一条音标两种字体」。</div>
<table style="margin-top:12px">
<tr><th style="width:110px">单词</th>
    <th>④ spec 原法 —— 整段 fallback 链（🔴 混排）</th>
    <th>⑤ 修正法 —— 音标元素显式指定（✅ 一致）</th></tr>
{''.join(demo_rows)}
</table>
<div class="note">
🔑 <b>同一字体组合，两种指定方式的差别</b>：<br>
① spec 原法把 fallback 链加在<b>整张卡的文本样式</b>上 → 逐字符回退 → 混排<br>
② 修正法把音标作为<b>独立元素</b>、直接指定 Charis SIL → 整条一致<br>
实测「IPA 出现在哪些字段」：<b>11,477 张卡在独立的 <code>ipa</code> 字段</b>（可显式指定），
只有 <b>232 张（2.0%）</b>的 IPA 嵌在词源/释义正文里（那部分只能靠 fallback，也避免不了）。<br>
→ <b>改用法可把混排从 93.9% 降到 2.0%，且不需要换任何字体。</b>
</div>'''

    html = f'''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CoEvo 字体候选对照（2026-09-26）</title>
<style>
{head_css}
*{{box-sizing:border-box}}
body{{margin:0;font-family:-apple-system,'Segoe UI','AlibabaPuHuiTi',sans-serif;
  background:#F7F5F0;color:#24211C;line-height:1.6}}
.wrap{{max-width:1160px;margin:0 auto;padding:32px 24px 80px}}
h1{{font-size:27px;margin:0 0 6px;letter-spacing:-.3px}}
h2{{font-size:19px;margin:0 0 4px}}
.sub{{color:#6E6659;font-size:14px;margin-bottom:22px}}
.answer{{background:#FFF;border-left:4px solid #B4432C;padding:16px 20px;border-radius:0 10px 10px 0;
  margin:20px 0 30px;font-size:14.5px}}
.role{{color:#6E6659;font-size:13.5px;margin-bottom:10px}}
.badges{{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px}}
.badge{{font-size:12px;padding:3px 9px;border-radius:20px;background:#EFEBE3;color:#5A5248}}
.b-ok{{background:#E4F0E6;color:#1F5C2E}} .b-warn{{background:#FBF0DC;color:#7A5310}}
.b-bad{{background:#FBE3DE;color:#8E2A18}}
.warn{{font-size:13px;color:#8E2A18;background:#FBE9E5;padding:7px 11px;border-radius:6px;margin-bottom:10px}}
.pass{{font-size:13px;color:#1F5C2E;background:#E9F3EB;padding:7px 11px;border-radius:6px;margin-bottom:10px}}
.metrics{{display:flex;gap:20px;font-size:13px;color:#6E6659;margin-bottom:12px;flex-wrap:wrap}}
.metrics b{{color:#24211C}}
.cand{{background:#FFF;border:1px solid #E6E0D4;border-radius:14px;padding:22px;margin-bottom:26px}}
.ipa-strip{{background:#F4F1EA;border-radius:8px;padding:11px 14px;font-size:19px;
  letter-spacing:.6px;margin-bottom:14px;display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}}
.strip-lab{{font-size:11px;letter-spacing:.08em;color:#9A917F;font-family:-apple-system,sans-serif}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(268px,1fr));gap:14px;
  padding:16px;border-radius:10px}}
.wcard{{background:#fff;border-radius:10px;padding:14px;box-shadow:0 1px 3px rgba(0,0,0,.07)}}
.w-head{{display:flex;align-items:baseline;gap:10px;margin-bottom:10px;flex-wrap:wrap}}
.w-word{{font-size:26px}}
.w-ipa{{font-size:15px}}
.sec{{border-radius:7px;padding:9px 11px;margin-bottom:8px}}
.sec:last-child{{margin-bottom:0}}
.lab{{font-size:11px;letter-spacing:.05em;margin-bottom:3px}}
.def-en{{font-size:16px;font-weight:500}}
.def-zh{{font-size:13px;margin-top:2px}}
.ctx{{font-size:14.5px;line-height:1.72}}
table{{width:100%;border-collapse:collapse;font-size:13.5px;margin-top:8px}}
th,td{{text-align:left;padding:9px 11px;border-bottom:1px solid #E6E0D4}}
th{{background:#F4F1EA;font-weight:600;font-size:12.5px;color:#5A5248}}
.tgrid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-top:14px}}
.tbox{{border:1px solid;border-radius:12px;padding:14px}}
.tbox-h{{font-size:14px;font-weight:600;margin-bottom:10px}}
.tbox-m{{font-size:11px;color:#9A917F;font-weight:400;float:right}}
.note{{font-size:13px;color:#6E6659;margin-top:10px}}
.dw{{font-size:15px}}
.bad{{background:#FBE9E5;font-size:19px;letter-spacing:.4px}}
.good{{background:#E9F3EB;font-size:19px;letter-spacing:.4px}}
</style></head><body><div class="wrap">

<h1>CoEvo 字体候选对照</h1>
<div class="sub">2026-09-26 · 用<strong>真实字体</strong>渲染<strong>真实词卡</strong>（数据取自 <code>word.db</code>，字体为子集 woff2 内联）</div>

<div class="answer">
<b>先回答「从可获得的里出方案」—— 已实测完，而且原始阻塞解除了</b><br>
① <code>raw.githubusercontent</code> / <code>fonts.gstatic.com</code> / <code>npmmirror</code> <b>都不通</b>，
但 <b><code>cdn.jsdelivr.net</code> 能代理 GitHub</b> → <b>spec 原选的 Literata 与 Charis SIL 都拿到了</b>（完整 TTF）。<br>
② 真实 IPA 需求是 <b>30 个字符</b>（不是靠猜的 25 —— 含 4 个<b>组合符号</b>，缺了会让变音符号<b>静默消失</b>）。<br>
③ 用真实字符集一测就分出两层：<b>Charis SIL / Andika / Gentium / Noto Serif 单字体即 IPA 30/30</b>；
而 spec 选的正文体 <b>Literata 只有 12/30</b>（缺 18）→ <b>它必须配 fallback</b>（这正是 spec 的设计，技术成立）。<br>
④ 🔑 于是出现一个 spec 未考虑的选项：<b>IPA 全量的字体可以同时当正文</b> → <b>一个字体家族顶掉两个</b>。
</div>

<h2 style="font-size:19px;margin-bottom:2px">候选一览</h2>
<table>
<tr><th>候选</th><th>IPA</th><th>角色</th><th>子集体积</th><th>字重形态</th></tr>
{rows}
</table>
<div class="note">体积为 <b>woff2</b> 子集（133 码位）；Flutter 侧用 TTF，约 ×2（仍 &lt; 70 KB/字重）。</div>

<h2 style="margin:34px 0 2px;font-size:19px">各候选渲染同一批真实词卡</h2>
<div class="note">字号严格按 spec §5.2（单词 26 · 释义 16 · 语境 14.5 · IPA 15）。背景用「墨」档页面底。</div>
{''.join(blocks)}

<h2 style="margin:38px 0 2px;font-size:19px">三档主题下都要成立</h2>
<div class="note">spec §八 验收清单：<b>IPA 音标在三档主题下均不得回退</b>。下例用 Charis SIL 演示。</div>
<div class="tgrid">{''.join(theme_grid)}</div>
{mech}

<h2 style="margin:38px 0 2px;font-size:19px">怎么看这一页</h2>
<div class="answer" style="border-left-color:#2F4A73">
① 先看 <b>IPA 那一行</b> —— 缺字符的候选会出现<b>字宽/字重跳变</b>（Literata 最明显）。<br>
② 再看 <b>释义与语境</b>的阅读感 —— 这是读者每天真正在读的部分。<br>
③ <b>Andika</b> 是无衬线，SIL 明确说它<b>为识字初学者设计</b>（字母形刻意不易混淆）—— 对英语学习产品是<b>特征</b>，但不是「阅读体」气质。<br>
④ <b>Noto Serif</b> <b>体积最小</b>（34.6 KB）且 IPA 全量，但只有可变字体。
</div>

</div></body></html>'''

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'✅ 已生成 {os.path.relpath(OUT, ROOT)}（{os.path.getsize(OUT)/1024:.0f} KB）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
