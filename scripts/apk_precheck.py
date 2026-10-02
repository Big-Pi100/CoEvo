#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""APK 免设备预检 —— 构建完立刻跑，10 秒，不用装机。

回答三个问题：

  ① 资产对不对   —— `word.db` 与 `word_db.version` 是否与仓库一致
  ② 代码真的进包了吗 —— 用**包内字符串**搜证（含负对照）
  ③ 体积有没有异常 —— 与上一版对比

用法：

    python scripts/apk_precheck.py                       # 默认 app-release.apk
    python scripts/apk_precheck.py <apk路径>             # 指定包
    python scripts/apk_precheck.py <新包> <旧包>          # 顺便对比体积

退出码：0 = 全部通过；1 = 有失败项。

------------------------------------------------------------------
# 🔑 为什么需要它：「构建成功」≠「你的改动在包里」

依赖没进包、代码被优化掉、assets 陈旧 —— 这些**都不会让构建失败**。
只能反过来查包里的内容。

# 🔴 两条方法学（不遵守会得出反向结论）

1. **非 ASCII 串必须按 UTF-16 搜**
   Dart 的 `String` 是 UTF-16 ⇒ release 的 AOT `.so` 里中文常量是 **UTF-16LE**。
   按 UTF-8 搜会得 0 次，误判成「没进包」。
   （对照：debug 包的 `kernel_blob.bin` 反而是 UTF-8。）
   ⇒ **能用 ASCII 标记就别用中文**（本脚本的 `MARKERS` 以函数名为准）。

2. **必须有负对照**
   「搜到了」可能只是撞上通用词。必须同时验证「一个已知不存在的串搜不到」。

# 🔑 为什么用「函数名」当标记

Dart AOT **保留函数名**（栈追踪需要），且与编码无关 ——
实测：`injectTraceMarkers` 在包内命中 1 次，`unescapeRedundantMarkdown`
在含它的版本里同样能命中。⇒ 每个功能加一个**独特的顶层函数名**，
就是天然的、稳定的「进包标记」。
"""

import io
import os
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_APK = os.path.join(
    REPO, 'app', 'build', 'app', 'outputs', 'flutter-apk', 'app-release.apk')

# ── 判别串 ──────────────────────────────────────────────────────────
# (标记, 说明, 是否应出现)
# 🔑 用**顶层函数名**（ASCII、AOT 保留、编码无关）。
# 新增功能时在这里加一行 —— 它就是「这个功能的代码进包了」的证据。
MARKERS = [
    (b'injectTraceMarkers',
     'S4 痕迹注入（源内控制字符标记）', True),
    (b'unescapeRedundantMarkdown',
     '§4 转义消化（markdown_unescape.dart）', True),
    (b'pickedTraceTiers',
     '痕迹档位判定（两条渲染路径共用）', True),
    (b'angelscript',
     'highlight 0.7.0 的语言键（传递依赖）', True),
    # ── 负对照：必须搜不到 ──
    (b'ZZ_NOT_A_REAL_MARKER_ZZ',
     '负对照（不存在的串）', False),
]

# 包内资产路径 → 仓库对应文件
ASSETS = [
    ('assets/flutter_assets/assets/word.db',
     os.path.join(REPO, 'app', 'assets', 'word.db')),
    ('assets/flutter_assets/assets/word_db.version',
     os.path.join(REPO, 'app', 'assets', 'word_db.version')),
]


def _cjk_hits(blob, text):
    """按 UTF-8 / UTF-16LE / UTF-16BE 三种编码搜，返回命中数（取最大）。"""
    cands = []
    for enc in ('utf-8', 'utf-16-le', 'utf-16-be'):
        try:
            cands.append(blob.count(text.encode(enc)))
        except Exception:
            pass
    return max(cands) if cands else 0


def _fmt(n):
    return f'{n:,}'


def main():
    args = [a for a in sys.argv[1:]]
    apk = args[0] if args else DEFAULT_APK
    baseline = args[1] if len(args) > 1 else None

    print('=' * 72)
    print('APK 免设备预检')
    print('=' * 72)

    if not os.path.exists(apk):
        print(f'🔴 找不到包：{apk}')
        print('   先构建：')
        print('     cd app && D:\\flutter\\bin\\flutter.bat build apk --release \\')
        print('       --target-platform android-arm64 \\')
        print('       --dart-define=API_HOST=api.keyievolution.fun')
        return 1

    ok = True
    z = zipfile.ZipFile(apk)
    names = z.namelist()

    # ── ① 基本信息 ──
    size = os.path.getsize(apk)
    print(f'\n包：{apk}')
    print(f'     {_fmt(size)} B = {size / 1048576:.2f} MiB'
          f' · mtime {_ts(os.path.getmtime(apk))}')
    if baseline and os.path.exists(baseline):
        bsz = os.path.getsize(baseline)
        d = size - bsz
        print(f'基准：{_fmt(bsz)} B = {bsz / 1048576:.2f} MiB'
              f' → 增量 {"+" if d >= 0 else ""}{_fmt(d)} B'
              f'（{d / bsz * 100:+.1f}%）')

    libapp = next((n for n in names if n.endswith('libapp.so')), None)
    if libapp:
        print(f'     {libapp} = {_fmt(z.getinfo(libapp).file_size)} B')
    dex = [n for n in names if n.endswith('.dex')]
    print(f'     dex 条目 {len(dex)} 个')

    # ── ② 资产 ──
    print('\n' + '-' * 72)
    print('① 资产（与仓库逐项对比）')
    print('-' * 72)
    for in_zip, on_disk in ASSETS:
        label = os.path.basename(in_zip)
        if in_zip not in names:
            print(f'  🔴 {label}: 包里没有')
            ok = False
            continue
        zsize = z.getinfo(in_zip).file_size
        if not os.path.exists(on_disk):
            print(f'  🟡 {label}: 包里 {_fmt(zsize)} B'
                  f' · 仓库文件不存在（无法对比）')
            continue
        dsize = os.path.getsize(on_disk)
        if zsize == dsize:
            # 文本类再比内容
            if label.endswith('.version') or dsize < 4096:
                zin = z.read(in_zip)
                din = open(on_disk, 'rb').read()
                same = zin == din
                print(f'  {"✅" if same else "🔴"} {label}:'
                      f' {_fmt(zsize)} B · 内容'
                      f' {"一致" if same else "不一致 🔴"}'
                      f' （{zin.decode("utf-8", "replace").strip()[:40]}）')
                ok = ok and same
            else:
                print(f'  ✅ {label}: {_fmt(zsize)} B · 与仓库**同大小**')
        else:
            print(f'  🔴 {label}: 包内 {_fmt(zsize)} B'
                  f' ≠ 仓库 {_fmt(dsize)} B → **资产陈旧**')
            ok = False

    # ── ③ 判别串（代码是否进包）──
    print('\n' + '-' * 72)
    print('② 代码进包验证（包内字符串搜证 · 含负对照）')
    print('-' * 72)
    blob = b''
    if libapp:
        blob = z.read(libapp)
    else:
        kbs = [n for n in names if n.endswith('kernel_blob.bin')]
        if kbs:
            blob = z.read(kbs[0])
    print(f'  扫描 {libapp or "kernel_blob.bin"} = {_fmt(len(blob))} B\n')
    print(f'  {"命中":>6}  {"期望":<6}  标记')
    print('  ' + '-' * 60)
    for needle, desc, should_exist in MARKERS:
        n = _cjk_hits(blob, needle.decode('ascii'))
        hit = n > 0
        good = (hit == should_exist)
        flag = '✅' if good else '🔴'
        exp = '应出现' if should_exist else '应=0'
        print(f'  {n:>6}  {exp:<6}  {flag} {desc}')
        print(f'  {"":>6}  {"":<6}     [{needle.decode("ascii")}]')
        if not good:
            ok = False

    # ── 结论 ──
    print('\n' + '=' * 72)
    if ok:
        print('✅ 预检全部通过 —— 可以装机')
        print('   下一步：真机验证（清单见 docs/review/a2-device-verification-checklist-*.md §九）')
    else:
        print('🔴 有失败项 —— **先别装机**，按上面提示处理')
    print('=' * 72)
    return 0 if ok else 1


def _ts(t):
    import datetime
    return datetime.datetime.fromtimestamp(t).strftime('%m-%d %H:%M')


if __name__ == '__main__':
    sys.exit(main())
