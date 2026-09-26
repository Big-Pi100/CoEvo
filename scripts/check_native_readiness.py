#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
原生就绪度检查 —— Step 1「清障」的进度度量器。

为什么需要它（2026-09-26 实测）：
  本地 Flutter 是**鸿蒙定制版**（3.27.5-ohos-1.0.5），
  `dart analyze` / `flutter analyze` 都会崩：
      analysis_server 启动失败 → "CreateFile failed 231 / 所有的管道范例都在使用中"
  但 `dart pub get` / `dart run` 可用。
  → 所以本地**做不了静态分析**，但**能做结构性检查**（grep 级）。
  本脚本填补这个空白：**把「Step 1 清障的目标」变成可本地跑、有退出码的断言**。

它检查什么（对应 ui-ux-refactor-assessment §7.1 Step 1 的 5 项）：
  ① dart:html / dart:js 残留 —— **编译阻塞项**（原生平台无这些库）
  ② admin 残留（app 内 admin + app_admin 整项目）—— 可删 ≈14,946 行
  ③ 可删字体权重是否已删（6 个未打包权重，释放 37 MB）
  ④ app/lib 代码量（清障后应降约 40%）

用法：
  python3 scripts/check_native_readiness.py            # 只读检查（默认）
  python3 scripts/check_native_readiness.py --verbose  # 列出每个文件
退出码：0 = 可编译就绪；1 = 仍有阻塞项
"""
import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict

# ── web-only 库（原生平台不存在，import = 编不过）────────────────────
# ⚠️ 口径演进（2026-09-26）：原来是 `dart:(html|js)` —— **漏掉了 `dart:ui_web`**
#    （实测 `lib/pages/admin/campaign/admin_campaign_detail.dart` 用了它）。
#    精确判据（按 AST 取 import，不受注释影响）见 `scripts/analyze_inproc/`。
WEB_ONLY_RE = re.compile(
    r"""import\s+['"]dart:(html|js|js_util|js_interop|indexed_db|svg|web_audio|web_gl|web_sql|ui_web)['"]"""
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'app')
LIB = os.path.join(APP, 'lib')

# ── 允许保留 dart:html 的白名单 ──────────────────────────────────────
# 说明：这些文件在 Step 1/3 会被重写或删除；列在这里是为了区分
#       「已知待处理」与「新引入的违规」。**不允许新增**。
KNOWN_DART_HTML = {
    'lib/pages/admin/campaign/admin_campaign_detail.dart',
    'lib/pages/admin/settlement/admin_batch_detail.dart',
    'lib/pages/admin/settlement/admin_commission_list.dart',
    'lib/pages/user/distribution/notification_panel.dart',
    'lib/providers/auth_provider.dart',
    'lib/screens/admin_screen.dart',
    'lib/screens/chat/chat_input.dart',
    'lib/screens/guardian_screen.dart',
    'lib/screens/profile_screen.dart',
    'lib/screens/review_screen.dart',
    'lib/widgets/achievement_share_card.dart',
    'lib/widgets/graph_widget.dart',
    'lib/widgets/review_card_widget.dart',
}

# admin 相关路径（删除目标）
ADMIN_PATTERNS = [
    re.compile(r'lib/pages/admin/'),
    re.compile(r'lib/screens/admin_screen\.dart$'),
]

# 2026-09-25 已删除的 6 个字体权重（不应再出现）
DELETED_FONT_WEIGHTS = [
    'AlibabaPuHuiTi-3-105-Heavy.ttf',
    'AlibabaPuHuiTi-3-115-Black.ttf',
    'AlibabaPuHuiTi-3-35-Thin.ttf',
    'AlibabaPuHuiTi-3-45-Light.ttf',
    'AlibabaPuHuiTi-3-75-SemiBold.ttf',
    'AlibabaPuHuiTi-3-95-ExtraBold.ttf',
]

# 清障目标（ui-ux §7.1：app/lib 删除后 ≈14,300 行 / 降 51%）
TARGET_LIB_LINES = 14_300


def sh(cmd: str) -> str:
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              cwd=ROOT, timeout=180).stdout
    except Exception:
        return ''


def dart_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.dart_tool', 'build', '.git')]
        for f in filenames:
            if f.endswith('.dart'):
                yield os.path.join(dirpath, f)


def count_lines(paths) -> int:
    n = 0
    for p in paths:
        try:
            with open(p, encoding='utf-8', errors='ignore') as fh:
                n += sum(1 for _ in fh)
        except Exception:
            pass
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--verbose', '-v', action='store_true')
    args = ap.parse_args()

    blockers = []
    warnings = []

    print('CoEvo · 原生就绪度检查（Step 1 清障的进度度量）')
    print('=' * 72)

    # ── ① web-only 库（原生平台不存在）────────────────────────────
    print('\n【①】web-only 库残留 —— 🔴 编译阻塞项（原生平台无这些库）')
    offenders = []
    for p in dart_files(LIB):
        try:
            src = open(p, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        if WEB_ONLY_RE.search(src):
            offenders.append(os.path.relpath(p, APP).replace(os.sep, '/'))

    known = [o for o in offenders if o in KNOWN_DART_HTML]
    new = [o for o in offenders if o not in KNOWN_DART_HTML]

    print(f'      残留 {len(offenders)} 个文件（已知 {len(known)} / 新增 {len(new)}）')
    if args.verbose or new:
        for o in sorted(offenders):
            tag = '新增 🔴' if o not in KNOWN_DART_HTML else '已知'
            print(f'        [{tag}] {o}')
    if new:
        blockers.append(f'web-only 库新增 {len(new)} 处（不在白名单）')
    if offenders:
        blockers.append(f'web-only 库仍有 {len(offenders)} 处 → **原生无法编译**')

    # ── ② admin 残留 ────────────────────────────────────────────
    print('\n【②】admin 残留 —— 删除目标（ui-ux §7.1；可删 ≈14,946 行）')
    admin_in_app = []
    for p in dart_files(LIB):
        rel = os.path.relpath(p, APP).replace(os.sep, '/')
        if any(rx.search(rel) for rx in ADMIN_PATTERNS):
            admin_in_app.append(p)
    admin_lines = count_lines(admin_in_app)

    app_admin_dir = os.path.join(ROOT, 'app_admin')
    app_admin_exists = os.path.isdir(app_admin_dir)
    app_admin_lines = count_lines(dart_files(app_admin_dir)) if app_admin_exists else 0

    # 其他 admin 相关文件（非 pages/admin 目录）
    other_admin = []
    for pat in ['lib/pages/user/distribution/', 'lib/screens/user_detail_screen.dart']:
        p = os.path.join(APP, pat.rstrip('/'))
        if os.path.isdir(p):
            other_admin.append(pat)
        elif os.path.isfile(p):
            other_admin.append(pat)

    print(f'      app 内 admin      : {len(admin_in_app):3d} 文件 / {admin_lines:>6,} 行')
    print(f'      app_admin 整项目  : {"存在" if app_admin_exists else "已删"}'
          f' / {app_admin_lines:>6,} 行')
    if args.verbose:
        for p in sorted(admin_in_app):
            print(f'        {os.path.relpath(p, APP)}')
    if app_admin_exists or admin_in_app:
        blockers.append(f'admin 未删（合计 ≈{admin_lines + app_admin_lines:,} 行）')

    # ── ③ 字体权重 ──────────────────────────────────────────────
    print('\n【③】未打包字体权重（2026-09-25 已删 6 个，释放 37 MB）')
    fonts_dir = os.path.join(APP, 'assets', 'fonts')
    leftovers = []
    if os.path.isdir(fonts_dir):
        present = set(os.listdir(fonts_dir))
        leftovers = [f for f in DELETED_FONT_WEIGHTS if f in present]
    if leftovers:
        print(f'      🔴 又出现 {len(leftovers)} 个已删权重: {leftovers}')
        warnings.append(f'已删字体权重回归 {len(leftovers)} 个')
    else:
        print('      ✅ 无残留')
    # pubspec 里是否还声明
    pubspec = os.path.join(APP, 'pubspec.yaml')
    if os.path.exists(pubspec):
        ps = open(pubspec, encoding='utf-8', errors='ignore').read()
        declared = [f for f in DELETED_FONT_WEIGHTS if f in ps]
        if declared:
            print(f'      🔴 pubspec.yaml 仍声明 {len(declared)} 个: {declared}')
            warnings.append(f'pubspec 仍声明已删字体 {len(declared)} 个')

    # ── ④ 代码量 ────────────────────────────────────────────────
    print('\n【④】app/lib 代码量（清障目标 ≈{:,} 行 / 降约 51%）'.format(TARGET_LIB_LINES))
    lib_files = list(dart_files(LIB))
    lib_lines = count_lines(lib_files)
    pct = 100 * lib_lines / TARGET_LIB_LINES - 100
    print(f'      当前: {len(lib_files)} 文件 / {lib_lines:,} 行'
          f'  → 距目标还多 {lib_lines - TARGET_LIB_LINES:,} 行（{pct:+.0f}%）')
    if lib_lines > TARGET_LIB_LINES * 1.5:
        warnings.append(f'app/lib 仍 {lib_lines:,} 行（目标 {TARGET_LIB_LINES:,}）')

    # ── 汇总 ────────────────────────────────────────────────────
    print('\n' + '=' * 72)
    if blockers:
        print(f'🔴 阻塞项 {len(blockers)} 条（这些不解决，原生编译不过）：')
        for b in blockers:
            print(f'    · {b}')
    if warnings:
        print(f'🟠 提示 {len(warnings)} 条：')
        for w in warnings:
            print(f'    · {w}')
    if not blockers:
        print('✅ 无编译阻塞项 —— 原生就绪')
        if warnings:
            print('   （仍有提示项，见上）')
        return 0
    print('\n→ 对应行动计划：docs/plan-and-progress-2026-09-26.md §四 P1（Step 1 清障）')
    return 1


if __name__ == '__main__':
    sys.exit(main())
