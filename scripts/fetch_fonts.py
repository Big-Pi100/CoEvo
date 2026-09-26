#!/usr/bin/env python3
"""取字体源文件（可复现 · 带校验）

## 为什么需要这个脚本

`docs/design/design-system-spec-2026-09-25.md` §四 定了三层字体组合，
但**字体源文件没有进仓库**（完整 TTF 合计 ~10 MB，而子集后只需 ~600 KB）。

→ 所以：**源文件不进仓库，但「怎么拿到」必须可复现** —— 就是这个脚本。

## 实测的可达性（2026-09-26）

| 渠道 | 结果 |
|---|---|
| `raw.githubusercontent.com` | ⚠️ 301 重定向后取不到（沙箱限流） |
| `github.com` / `fonts.gstatic.com` | 🔴 不通 |
| **`cdn.jsdelivr.net`** | ✅ **通 —— 且能代理 GitHub 仓库** |

🔑 **关键发现**：jsdelivr 的 **GitHub 代理**（`cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>`）
是这里唯一能拿到 `google/fonts` 完整 TTF 的通道。
`fonts.googleapis.com` / `npmmirror` 都不通，所以**不要改成它们**。

## 用法

    python3 scripts/fetch_fonts.py                    # 取全部候选
    python3 scripts/fetch_fonts.py --only literata    # 只取某款
    python3 scripts/fetch_fonts.py --verify           # 只校验已有文件

输出目录：`data/fonts-src/`（已在 `.gitignore`，不进仓库）

## 校验

每个文件记 sha256。首轮下载时会打印实际值；把它填进 `MANIFEST` 后，
`--verify` 就能检出**上游悄悄改版**（Google Fonts 会更新字体文件）。
"""

import argparse
import hashlib
import os
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, 'data', 'fonts-src')

#: jsdelivr 的 GitHub 代理 —— 实测唯一可用通道
_BASE = 'https://cdn.jsdelivr.net/gh/google/fonts@main'

#: 下载清单。
#:
#: `sha256` 留空 = 首次下载后填入（空值时只打印不阻断）。
#: 🔑 **不要为了让校验通过而改这个值** —— 变动要先确认是上游真的更新了。
MANIFEST = [
    # ── 候选：正文 / IPA 一体（静态字重齐全，Flutter 最省事）──
    {
        'key': 'charis',
        'name': 'Charis SIL',
        'note': 'SIL 为语言学出版设计；IPA 全量；有静态 Regular/Bold/Italic',
        'files': {
            'CharisSIL-Regular.ttf': ('ofl/charissil/CharisSIL-Regular.ttf',
                                      '346337374aa347d6'),
            'CharisSIL-Bold.ttf': ('ofl/charissil/CharisSIL-Bold.ttf',
                                   '68460d2b76c8f781'),
            'CharisSIL-Italic.ttf': ('ofl/charissil/CharisSIL-Italic.ttf',
                                     'e776e2961117b39c'),
        },
    },
    {
        'key': 'andika',
        'name': 'Andika',
        'note': 'SIL 为「初学者 / 识字学习者」设计（字母形不易混淆）；无衬线',
        'files': {
            'Andika-Regular.ttf': ('ofl/andika/Andika-Regular.ttf',
                                   '202b96b1f174a4a4'),
            'Andika-Bold.ttf': ('ofl/andika/Andika-Bold.ttf',
                                '4361126189a2d0e0'),
        },
    },
    {
        'key': 'gentium',
        'name': 'Gentium Book Plus',
        'note': 'SIL 书体；IPA 全量；有静态字重',
        'files': {
            'GentiumBookPlus-Regular.ttf': ('ofl/gentiumbookplus/GentiumBookPlus-Regular.ttf',
                                            'fe7b64eeacc430fc'),
            'GentiumBookPlus-Bold.ttf': ('ofl/gentiumbookplus/GentiumBookPlus-Bold.ttf',
                                         'b39c3fb12e2e15e2'),
        },
    },
    # ── spec 原案：正文（无 IPA，须配 fallback）──
    {
        'key': 'literata',
        'name': 'Literata',
        'note': '⚠️ 仅可变字体；🔴 缺 18 个 IPA 码位 → 必须配 fontFamilyFallback',
        'files': {
            'Literata-var.ttf': ('ofl/literata/Literata%5Bopsz,wght%5D.ttf',
                                 'b41138c9373112f3'),
            # 🔑 独立 Italic 字体 —— 不装则 Flutter 只能「合成斜体」（skew），
            #    而词库里 39 张卡的书名标记（`*Faust*`）会明显不自然
            'Literata-Italic-var.ttf': ('ofl/literata/Literata-Italic%5Bopsz,wght%5D.ttf',
                                        'd483dfaeba9cbf4c'),
        },
    },
    # ── UI / 数字 ──
    {
        'key': 'inter',
        'name': 'Inter',
        'note': '⚠️ 仅可变字体（且子集化需先 instance）',
        'files': {
            'Inter-var.ttf': ('ofl/inter/Inter%5Bopsz,wght%5D.ttf',
                              '29160a80ff49ddca'),
        },
    },
    # ── 备选（IPA 全量，但仅可变字体）──
    {
        'key': 'noto',
        'name': 'Noto Serif / Sans',
        'note': 'IPA 全量；仅可变字体；家族最全（后续加字符容易）',
        'files': {
            'NotoSerif-var.ttf': ('ofl/notoserif/NotoSerif%5Bwdth,wght%5D.ttf',
                                  '4d8e676142465686'),
            'NotoSans-var.ttf': ('ofl/notosans/NotoSans%5Bwdth,wght%5D.ttf',
                                 'bfb7bb691513f12e'),
        },
    },
]


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _download(url, dest):
    req = urllib.request.Request(url, headers={'User-Agent': 'coevo-fetch-fonts/1.0'})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    if len(data) < 5000:
        raise OSError(f'响应过小（{len(data)} B）—— 可能是错误页而非字体')
    with open(dest, 'wb') as f:
        f.write(data)
    return len(data)


def fetch(only=None, verify_only=False):
    os.makedirs(OUT_DIR, exist_ok=True)
    groups = [g for g in MANIFEST if not only or g['key'] in only]

    n_ok = n_skip = n_bad = 0
    for g in groups:
        print(f"\n── {g['name']} ── {g['note']}")
        for fname, (rel, want) in g['files'].items():
            dest = os.path.join(OUT_DIR, fname)
            url = f'{_BASE}/{rel}'

            if verify_only or os.path.exists(dest):
                if not os.path.exists(dest):
                    print(f'  ⚠️  {fname:<32} 不存在')
                    n_bad += 1
                    continue
                got = _sha256(dest)
                if want and got.startswith(want):
                    print(f'  ✅ {fname:<32} 校验通过（{got[:16]}）')
                    n_ok += 1
                elif want:
                    print(f'  🔴 {fname:<32} 校验失败！')
                    print(f'       期望 {want}')
                    print(f'       实得 {got[:16]}   ← 上游可能已改版，先确认再决定')
                    n_bad += 1
                else:
                    print(f'  ⚠️  {fname:<32} 无期望值 · 实得 sha256 {got[:16]}（请填入 MANIFEST）')
                    n_ok += 1
                continue

            try:
                size = _download(url, dest)
            except (urllib.error.URLError, OSError) as e:
                print(f'  🔴 {fname:<32} 下载失败: {e}')
                print(f'       {url}')
                n_bad += 1
                continue

            got = _sha256(dest)
            flag = '✅' if (not want or got.startswith(want)) else '⚠️ '
            print(f'  {flag} {fname:<32} {size:>9,} B · sha256 {got[:16]}')
            if not want:
                print(f'       ↑ 首次下载，请把 {got[:16]} 填进 MANIFEST')
            n_ok += 1

    print(f'\n{"="*72}')
    print(f'完成：成功 {n_ok} · 失败 {n_bad}｜输出目录 {os.path.relpath(OUT_DIR, ROOT)}')
    print('⚠️ 本目录已在 .gitignore —— 字体源文件不进仓库，靠本脚本复现。')
    return 1 if n_bad else 0


def main():
    ap = argparse.ArgumentParser(description='取字体源文件（jsdelivr → google/fonts）')
    ap.add_argument('--only', nargs='*', metavar='KEY',
                    help=f'只取指定款（可选：{" / ".join(g["key"] for g in MANIFEST)}）')
    ap.add_argument('--verify', action='store_true', help='只校验已有文件，不下载')
    args = ap.parse_args()
    sys.exit(fetch(only=args.only, verify_only=args.verify))


if __name__ == '__main__':
    main()
