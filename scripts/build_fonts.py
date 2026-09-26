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
import io
import json
import os
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
}


def _charset():
    """子集字符集 = ASCII 可打印 95 + 常用标点 + **从真实数据提取的 IPA**。"""
    d = json.load(open(CHARSET_JSON, encoding='utf-8'))
    ipa = ''.join(ch for ch in d['non_ascii'] if not (0x2010 <= ord(ch) <= 0x201F))
    return ''.join(chr(c) for c in range(0x20, 0x7F)) + PUNCT + ipa, ipa


def build(key, out_dir, as_ttf=False):
    from fontTools.ttLib import woff2
    spec = CANDIDATES[key]
    chars, ipa = _charset()
    os.makedirs(out_dir, exist_ok=True)

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
    args = ap.parse_args()

    if args.list:
        chars, ipa = _charset()
        print(f'子集字符集：{len(chars)} 码位（ASCII 95 + 标点 {len(PUNCT)} + IPA {len(ipa)}）')
        print(f'IPA: {ipa}\n')
        for k, v in CANDIDATES.items():
            print(f'  {k:<10} {v["label"]}')
        return 0

    keys = list(CANDIDATES) if args.all else args.candidate
    if not keys:
        ap.print_help()
        return 1

    chars, ipa = _charset()
    print(f'子集字符集：{len(chars)} 码位（ASCII 95 + 标点 {len(PUNCT)} + IPA {len(ipa)}）')
    print(f'输出目录：{os.path.relpath(args.out, ROOT)}\n')

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
