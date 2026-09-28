#!/usr/bin/env python3
"""字体子集构建（源 TTF → App 用的子集）

## 为什么必须自己子集化

spec §4.3 有一条**实测结论**：`@fontsource` 的分包**骗人** —— Charis SIL 的
latin/latin-ext 分包只有 **22/32** IPA 覆盖，缺的恰是最关键的 `ˈ`(U+02C8) `ː`(U+02D0) `θ`。
而 `unicode-range` 声明是**粗粒度**的，包含整个区间不代表字形存在。

→ **必须解 cmap 自己确认**，然后**自己子集**（不能拿现成分包）。

## 字符集怎么定（不能猜）

`data/reports/ipa_charset.json` 是从 **word.db 实际数据**里提的：
遍历 11,523 张卡的 `card.content.ipa`，统计所有非 ASCII 字符 → **34 种**（其中真·音标 30 种）。

🔑 **这一条改变了结论**：凭猜测会以为需要 25 个 IPA 字符；
实测是 **30 个**（含 4 个**组合符号** U+0303/032C/0329/032F）——
组合符号缺失时**变音符号会静默消失**，比回退字体更糟。

## 用法

    python3 scripts/build_fonts.py --list
    python3 scripts/build_fonts.py --candidate charis --out data/fonts-build
    python3 scripts/build_fonts.py --all --out data/fonts-build
    python3 scripts/build_fonts.py --candidate charis --out app/assets/fonts --ttf

`--ttf` 输出 TTF（Flutter 用）；默认输出 woff2（HTML 对照页用，体积更小）。
"""

import argparse
import glob
import io
import json
import os
import sqlite3
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, 'data', 'fonts-src')
CHARSET_JSON = os.path.join(ROOT, 'data', 'reports', 'ipa_charset.json')

#: 常用标点 —— 中文排版 + 英文引号/破折号，与 spec §4.3 的「ASCII 95 + 标点 8」一致
PUNCT = '’‘“”…—–·'

#: 候选取材。
#:
#: `instances` = 可变字体需要 pin 的轴（Flutter 与浏览器对可变字体的处理都不如静态稳，
#: 所以**在构建期就 instance 成静态**，运行时只面对普通字重）。
#:
#: `file_base` = 输出文件名前缀（用**规范的字体名**，因为要直接进 `app/assets/fonts/`）。
CANDIDATES = {
    'charis': {
        'family': 'CoEvoSerif',   # 正文 + IPA 一体
        'file_base': 'CharisSIL',
        'label': 'Charis SIL',
        'fonts': [
            ('CharisSIL-Regular.ttf', None, 400, 'normal', 'Regular'),
            ('CharisSIL-Bold.ttf', None, 700, 'normal', 'Bold'),
            ('CharisSIL-Italic.ttf', None, 400, 'italic', 'Italic'),
        ],
    },
    'andika': {
        'family': 'CoEvoSerif',
        'file_base': 'Andika',
        'label': 'Andika',
        'fonts': [
            ('Andika-Regular.ttf', None, 400, 'normal', 'Regular'),
            ('Andika-Bold.ttf', None, 700, 'normal', 'Bold'),
        ],
    },
    'gentium': {
        'family': 'CoEvoSerif',
        'file_base': 'GentiumBookPlus',
        'label': 'Gentium Book Plus',
        'fonts': [
            ('GentiumBookPlus-Regular.ttf', None, 400, 'normal', 'Regular'),
            ('GentiumBookPlus-Bold.ttf', None, 700, 'normal', 'Bold'),
        ],
    },
    'literata': {
        'family': 'Literata',     # A′ 选定的正文体
        'file_base': 'Literata',
        'label': 'Literata（缺 IPA，须配 fallback）',
        'fonts': [
            # opsz=18：正文 18px ↔ 标题 32px 的折中（轴范围 7–72，默认 12）
            ('Literata-var.ttf', {'wght': 400, 'opsz': 18}, 400, 'normal', 'Regular'),
            ('Literata-var.ttf', {'wght': 700, 'opsz': 18}, 700, 'normal', 'Bold'),
            # 🔑 独立 Italic 源 —— 不装则 Flutter 只能合成斜体（词库有 39 张卡的书名标记）
            ('Literata-Italic-var.ttf', {'wght': 400, 'opsz': 18}, 400, 'italic', 'Italic'),
        ],
    },
    'noto': {
        'family': 'CoEvoSerif',
        'file_base': 'NotoSerif',
        'label': 'Noto Serif',
        'fonts': [
            ('NotoSerif-var.ttf', {'wght': 400, 'wdth': 100}, 400, 'normal', 'Regular'),
            ('NotoSerif-var.ttf', {'wght': 700, 'wdth': 100}, 700, 'normal', 'Bold'),
        ],
    },
    'inter': {
        'family': 'CoEvoUI',
        'file_base': 'Inter',
        'label': 'Inter（UI / 数字）',
        'fonts': [
            ('Inter-var.ttf', {'wght': 400, 'opsz': 14}, 400, 'normal', 'Regular'),
            ('Inter-var.ttf', {'wght': 700, 'opsz': 14}, 700, 'normal', 'Bold'),
        ],
    },
    # ── 🆕 中文字体（2026-09-27 · 替代阿里普惠体）────────────────
    #
    # ## 为什么换
    # 阿里普惠体条款**禁止子集化**（禁止事项 ② 含「**转换**」「**拆分**」）
    # → 24.16 MB **永远减不掉**。Noto Sans SC 是 **OFL 1.1**，明确允许 subset/modify。
    # 详见 `docs/review/cjk-font-switch-evaluation-2026-09-27.md`
    #
    # ## 关键实现点
    # · **`charset: 'cjk'`** —— 走 [cjk_charset]（汉字），不是默认的 IPA 字符集
    # · 🔴 **`wght` 轴默认值是 100（Thin，不是 Regular）** → 每个字重都**必须显式 pin**
    #   （Flutter 的 `fontWeight` **不会**驱动 VF 轴 → 必须在构建期转成静态字重）
    # · **四个字重**：实测代码里 `w600` 用了 **69 处**（最多）而阿里普惠体只声明了 400/500/700
    #   → 那 69 处一直是「就近取」→ 本次**补齐真 600**
    #
    # ⚠️ **子集化后的命名**：OFL 要求「Modified Version 不得用 Reserved Font Name」。
    #    官方 OFL.txt 写的保留名是 **`Source`**（继承思源黑体），**不是 `Noto`**
    #    → 沿用 `NotoSansSC` 作为 file_base / family 名**是允许的**。
    'noto-sc': {
        'family': 'NotoSansSC',
        'file_base': 'NotoSansSC',
        'label': 'Noto Sans SC（中文 UI · OFL 可子集化）',
        'charset': 'cjk',
        'fonts': [
            ('NotoSansSC-var.ttf', {'wght': 400}, 400, 'normal', 'Regular'),
            ('NotoSansSC-var.ttf', {'wght': 500}, 500, 'normal', 'Medium'),
            ('NotoSansSC-var.ttf', {'wght': 600}, 600, 'normal', 'SemiBold'),
            ('NotoSansSC-var.ttf', {'wght': 700}, 700, 'normal', 'Bold'),
        ],
    },
}


def _charset():
    """子集字符集 = ASCII 可打印 95 + 常用标点 + **从真实数据提取的 IPA**。"""
    d = json.load(open(CHARSET_JSON, encoding='utf-8'))
    ipa = ''.join(ch for ch in d['non_ascii'] if not (0x2010 <= ord(ch) <= 0x201F))
    return ''.join(chr(c) for c in range(0x20, 0x7F)) + PUNCT + ipa, ipa


# ── 🆕 CJK 字符集（2026-09-27）─────────────────────────────────
#
# 拉丁字体要 IPA，**中文字体要汉字** —— 是完全不同的字符集，不能共用。
# 所以按候选声明 `charset` 字段分派（默认 `latin`）。

#: 中文标点 —— UI 文案里真实会出现的。
#: （英文标点沿用 [PUNCT]；中文文案里 `，。、；：！？` 等是独立的码位，不包含在内）
CJK_PUNCT = '，。、；：！？（）「」『』《》〈〉·—…‘’“”【】％＃＆＊＋－／＝＠｜～　'

DB_PATH = os.path.join(ROOT, 'data', 'word.db')
LIB_PATH = os.path.join(ROOT, 'app', 'lib')


def collect_cjk():
    """从**真实数据**收集实际会渲染的汉字。

    🔑 两个来源缺一不可：
      · `word.db` 的文本字段 —— 中文释义（用户在词卡上看得见）
      · `app/lib/**.dart` —— UI 文案（字符串字面量）

    ⚠️ 源码里的**中文注释**也会被收进来（无法可靠区分注释与字符串）。
       但注释用字与 UI 用字高度重叠 → **多收成本极小（几十个码位）**，
       而漏收的代价是「界面上某个字变方块」→ **宁可多收**。
    """
    chars = set()

    con = sqlite3.connect(f'file:{DB_PATH}?mode=ro', uri=True)
    cur = con.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    for (t,) in cur.fetchall():
        try:
            cur.execute(f'SELECT * FROM "{t}"')
            for row in cur.fetchall():
                for v in row:
                    if isinstance(v, str):
                        chars |= {c for c in v if '\u4e00' <= c <= '\u9fff'}
        except sqlite3.Error:
            pass
    con.close()

    for dirpath, _, files in os.walk(LIB_PATH):
        for fn in files:
            if fn.endswith('.dart'):
                s = open(os.path.join(dirpath, fn), encoding='utf-8').read()
                chars |= {c for c in s if '\u4e00' <= c <= '\u9fff'}

    return chars


def cjk_charset():
    """中文字符集 = ASCII 可打印 + 中英标点 + **真实数据里的汉字**。"""
    hanz = collect_cjk()
    chars = ''.join(chr(c) for c in range(0x20, 0x7F)) + CJK_PUNCT + PUNCT + ''.join(sorted(hanz))
    return chars, ''


def charset_for(kind):
    """按候选的 `charset` 字段分派（默认 `latin`）。"""
    return cjk_charset() if kind == 'cjk' else _charset()


def verify_coverage(key='noto-sc'):
    """🔴 **校验「词库用到的汉字 ⊆ 字体 cmap」** —— 子集化后的关键防线。

    ## 为什么必须有这一条
    子集化把字体裁到 **4,014 码位**（见 [cjk_charset]）。而 `word.db` 是**会长大的**：
    将来加词若引入**新汉字**，那个字会：
      ① 缺字形 → **回退系统字体**（不是报错！）
      ② 一条释义里出现**两种字体**，肉眼能看出不齐（本项目已知教训：
         「**有 fallback ≠ 视觉一致**」—— 93.9% 的音标曾栽在同一件事上）

    → 所以把「覆盖关系」写成**可执行的校验**，而不是靠人记得重跑子集。
      同 `verify_worddb_sync` 的思路：**漂移必须能被立刻发现**。

    ## 与 `tokens_verify` 的分工
    · `tokens_verify`（Dart）：接线性断言（family 名 / pubspec 声明 / 字重 / 许可文本）
    · **本函数**（Python）：真正的 cmap 覆盖（需解析 TTF，Dart 侧无此能力）
    → 互补，缺一不可。
    """
    from fontTools.ttLib import TTFont

    spec = CANDIDATES[key]
    base = spec['file_base']
    need = collect_cjk()
    print(f'\n── cmap 覆盖校验：{spec["label"]} ──')
    print(f' 词库+UI 需要 {len(need):,} 个汉字')

    # 字体在哪？优先看 App assets（真正打包的那份），其次看构建产物
    cands = sorted(glob.glob(os.path.join(ROOT, 'app', 'assets', 'fonts',
                                              f'{base}-*.ttf')))
    if not cands:
        cands = sorted(glob.glob(os.path.join(ROOT, 'data', 'fonts-build',
                                                  f'{base}-*.ttf')))
    if not cands:
        print(f' 🔴 找不到 {base}-*.ttf（先跑 --candidate {key} --ttf）')
        return 1

    bad = 0
    for p in cands:
        ft = TTFont(p, lazy=True)
        cmap = ft.getBestCmap()
        ft.close()
        missing = sorted(c for c in need if ord(c) not in cmap)
        name = os.path.basename(p)
        if missing:
            bad += 1
            print(f' 🔴 {name:<30} 缺 {len(missing)} 个汉字：{"".join(missing[:20])}'
                  + ('…' if len(missing) > 20 else ''))
        else:
            print(f' ✅ {name:<30} 全覆盖（cmap {len(cmap):,} 码位）')

    if bad:
        print(f'\n🔴 {bad} 个字体文件缺字。')
        print('   → 「字库或词库变过」——重跑：')
        print(f'     python3 scripts/build_fonts.py --candidate {key} --ttf')
        print(f'     然后复制 data/fonts-build/{base}-*.ttf → app/assets/fonts/')
        return 1
    print(' ✅ 所有字重均覆盖词库全部汉字')
    return 0


def _fix_names(ft, family, tag, weight):
    """把 TTF 的 name 表改成「family + 字重」的正确组合。

    ## 为什么需要（见 `build()` 里的详细说明）
    VF 实例化后 name 表会残留**默认实例**的名字（Noto Sans SC 的默认是 **Thin**），
    导致 4 个静态字重全都叫同一个名字、字重信息丢失。
    **不影响 Flutter 渲染**（它按 pubspec 的 family + weight 索引，不看 name 表），
    但会误导一切用系统工具查看字体的人。

    ## 为什么用「Family=别名 + 字重进 Subfamily」这种排布
    跟随 OpenType 的通行做法（也是 `fontTools` 的 `instancer` 内部逻辑）：
      · ID 1 **Family**            → `NotoSansSC`（不带字重 —— 让字体库里归为一族）
      · ID 2 **Subfamily**         → 仅允许 `Regular`/`Bold`/`Italic`/`Bold Italic`（RIBBI）
                                     非 RIBBI 的字重必须归到 `Regular`，否则是老工具会认错
      · ID 4 **Full name**         → `NotoSansSC SemiBold`
      · ID 6 **PostScript name**   → `NotoSansSC-SemiBold`
      · ID 16/17 **Typographic Family/Subfamily** → 现代工具的**权威**来源，
                                     这里才放真正的字重名（`SemiBold`）
    """
    # Subfamily 只允许 RIBBI 四值 → 非 RIBBI 一律归 Regular（字重由 ID 17 表达）
    ribbi = 'Bold' if weight == 700 else 'Regular'
    full = f'{family} {tag}'
    ps = f'{family}-{tag}'
    for plat, enc, lang in ((3, 1, 0x409), (1, 0, 0)):   # Windows + Mac
        for nid, val in ((1, family), (2, ribbi), (3, f'{full};{ps}'),
                         (4, full), (6, ps), (16, family), (17, tag)):
            ft['name'].setName(val, nid, plat, enc, lang)


def build(key, out_dir, as_ttf=False):
    from fontTools.ttLib import woff2
    spec = CANDIDATES[key]
    # 🔑 按候选分派字符集：拉丁要 IPA、中文要汉字（见 `charset_for`）
    chars, ipa = charset_for(spec.get('charset', 'latin'))
    os.makedirs(out_dir, exist_ok=True)
    print(f'  字符集 {len(chars):,} 码位（{spec.get("charset", "latin")}）')
    results = []
    for fname, axes, weight, style, tag in spec['fonts']:
        src = os.path.join(SRC_DIR, fname)
        if not os.path.exists(src):
            print(f'  🔴 缺源文件 {fname} → 先跑 scripts/fetch_fonts.py --only {key}')
            return None

        ft = TTFont(src)
        if axes:
            ft = instancer.instantiateVariableFont(ft, axes, inplace=True,
                                                   updateFontNames=False)
            # 🔴 **修正 name 表**（2026-09-27）
            #
            # 为什么需要：`updateFontNames=False` 会**原样保留 VF 的 name 表** ——
            # 而 Noto Sans SC 的 VF 默认实例是 **Thin**，于是 4 个静态字重**全都叫
            # 「Noto Sans SC Thin」**，字重信息完全丢失（用字体查看器一看就发现）。
            #
            # ⚠️ 这**不影响 Flutter 渲染** —— Flutter 按 `pubspec.yaml` 里声明的
            #    family 别名 + `weight` 字段索引字体文件，**不看 TTF 内部的 name 表**。
            #    但名字错了会：① 误导用系统工具查字体的人 ② 在 Web/对照页等场景下混乱。
            #    → 属于「不影响功能但必须修」的一类。
            #
            # ⚠️ 改用 `updateFontNames=True` 也能修，但那会依赖字体自身 fvar 里的
            #    命名实例（`Noto Sans SC Thin` 这个名字就是它给的）→ **不可控**。
            #    这里**显式写死**，结果可预期、可断言。
            #
            # 🔴 OFL 条件 3：「Modified Version 不得使用 **Reserved Font Name**」。
            #    本字体的保留名是 **`Source`**（查官方 OFL.txt 原文），
            #    而 `NotoSansSC` **不是**保留名 → 设为 Family 名**合规**。
            _fix_names(ft, spec['file_base'], tag, weight)

        # 子集前先确认字形真的存在（spec §4.3 的教训：unicode-range 不可信）
        cmap_pre = ft.getBestCmap()
        missing = [c for c in chars if ord(c) not in cmap_pre]

        o = subset.Options()
        o.layout_features = ['*']
        o.name_IDs = ['*']
        o.notdef_outline = True
        o.drop_tables = ['DSIG']
        s = subset.Subsetter(options=o)
        s.populate(text=chars)
        s.subset(ft)

        ext = 'ttf' if as_ttf else 'woff2'
        base = spec['file_base']
        dest = os.path.join(out_dir, f'{base}-{tag}.{ext}')
        if as_ttf:
            ft.save(dest)
        else:
            # ⚠️ `woff2.compress()` 只接受**文件路径**（内部会重新读盘），
            #    不接受 `TTFont` 对象 → 先落临时 ttf 再压，最后删掉临时文件。
            tmp = os.path.join(out_dir, f'.{base}-{tag}.tmp.ttf')
            ft.save(tmp)
            with open(tmp, 'rb') as fin, open(dest, 'wb') as fout:
                woff2.compress(fin, fout)
            os.remove(tmp)
        size = os.path.getsize(dest)
        ft.close()
        results.append({'tag': tag, 'weight': weight, 'style': style,
                        'file': os.path.basename(dest), 'size': size,
                        'missing': missing})
        flag = '✅' if not missing else f'🔴 缺 {len(missing)}'
        print(f'  {flag} {os.path.basename(dest):<30} {size:>8,} B'
              + (f'   缺: {"".join(missing)}' if missing else ''))
    return results


def main():
    ap = argparse.ArgumentParser(description='字体子集构建')
    ap.add_argument('--candidate', action='append', choices=list(CANDIDATES),
                    help='构建哪一款（**可重复**：--candidate literata --candidate charis）')
    ap.add_argument('--all', action='store_true', help='构建全部候选')
    ap.add_argument('--out', default=os.path.join(ROOT, 'data', 'fonts-build'),
                    help='输出目录（默认 data/fonts-build）')
    ap.add_argument('--ttf', action='store_true', help='输出 TTF（Flutter 用）；默认 woff2')
    ap.add_argument('--list', action='store_true', help='列出候选')
    ap.add_argument('--verify-coverage', metavar='KEY', nargs='?', const='noto-sc',
                    help='🔴 校验「词库用到的汉字 ⊆ 字体 cmap」（默认 noto-sc）—— '
                         '子集化后的关键防线，词库增长导致缺字时在此暴露')
    args = ap.parse_args()

    if args.verify_coverage:
        return verify_coverage(args.verify_coverage)

    if args.list:
        lat, ipa = _charset()
        cjk, _ = cjk_charset()
        print(f'拉丁字符集：{len(lat)} 码位（ASCII 95 + 标点 {len(PUNCT)} + IPA {len(ipa)}）')
        print(f'  IPA: {ipa}')
        print(f'中文字符集：{len(cjk)} 码位（ASCII 95 + 中英标点 + 汉字 {len(collect_cjk())}）\n')
        for k, v in CANDIDATES.items():
            cs = v.get('charset', 'latin')
            print(f'  {k:<10} [{cs:<5}] {v["label"]}')
        return 0

    keys = list(CANDIDATES) if args.all else args.candidate
    if not keys:
        ap.print_help()
        return 1

    # 🔑 字符集**按候选分派**（拉丁含 IPA / 中文含汉字）——
    #    所以不能在这里统一打一行提示，改为逐候选打印。
    print('输出目录：' + os.path.relpath(args.out, ROOT) + '\n')

    summary = {}
    for k in keys:
        print(f'── {CANDIDATES[k]["label"]} ──')
        r = build(k, args.out, as_ttf=args.ttf)
        if r:
            summary[k] = r
    print(f'\n{"="*72}')
    for k, r in summary.items():
        tot = sum(x['size'] for x in r)
        print(f'  {CANDIDATES[k]["label"]:<40} {tot:>8,} B ({tot/1024:.1f} KB) / {len(r)} 文件')
    return 0


if __name__ == '__main__':
    sys.exit(main())
