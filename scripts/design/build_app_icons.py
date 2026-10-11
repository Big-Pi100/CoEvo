#!/usr/bin/env python3
"""生成并安装 App 图标全套（**记忆之书** · 思源黑体 Bold · 朱砂底白字 · 粘土风）。

# 白哥定案（2026-10-11）
| 项 | 值 |
|---|---|
| 名称 | 记忆之书 |
| 副标题 | 阅读英语原文 · 自动规划记忆曲线 |
| 字体 | **思源黑体 Bold**（`Noto Sans SC Bold`）|
| 图标字 | **记**（白哥 14:08 定；原选「书」，因「记忆之书」配「记」更贴）|
| 配色 | **朱砂底 `#B4432C` + 纸白字 `#F7F2EA`** |

# 两条实测得出的参数依据
* **字号占比 66%** —— 扫过 60/66/72：60% 在 20px 下偏糊；72% 最清晰但字太满，
  iOS 圆角裁切会吃掉四角内容 ⇒ **66% 是「清晰度」与「安全区」的平衡点**。
* **无衬线** —— 衬线体（思源宋体 Heavy）在 20px 下衬线细节变成噪点，明显糊。
* **描边 2.6%（STROKE）** —— 「记」是**左右结构**（讠+己），比「书」更容易在小尺寸下粘连。
  扫过 2.0/2.6/3.2：3.2% 在 20px 下明显糊；2.0% 最清晰但笔画偏瘦、粘土感弱；
  **2.6% 是「粘土厚度」与「部件可分辨」的平衡**，且与「书」同参数（只换字，最小改动）。
  📄 对比图：`docs/design/app-icon-candidates-2026-10-11/记字-描边扫描.png`

# 关键规格（🔴 都不是偏好，是硬要求）
* iOS 交付图：**方形 · RGB 无 alpha**（带透明上传即报错）；**不加圆角**（iOS 自己裁 squircle）
* iOS 文件名必须与 `AppIcon.appiconset/Contents.json` 引用的**完全一致**（脚本末尾会断言）
* Android：5 个密度的 `ic_launcher.png`

跑法：
    python scripts/design/build_app_icons.py            # 只生成到候选目录（预览）
    python scripts/design/build_app_icons.py --install  # 同时安装进 app/（会先备份原图标）
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(ROOT, "docs", "design", "app-icon-candidates-2026-10-11")
IOS_ICONSET = os.path.join(ROOT, "app", "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
ANDROID_RES = os.path.join(ROOT, "app", "android", "app", "src", "main", "res")
BACKUP_DIR = os.path.join(OUT_DIR, "_原图标备份")

CHAR = "记"
FONT_PATH = r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf"   # 思源黑体 Bold
CRIMSON = (0xB4, 0x43, 0x2C)
WARM_WHITE = (0xF7, 0xF2, 0xEA)

S = 1024
SS = 4                 # 超采样倍数
RATIO = 0.66           # 字占边长比例（实测最优）
STROKE = 0.026         # 描边宽度比例（决定笔画粗细）

# iOS：文件名 → 像素边长（与 Contents.json 一一对应）
IOS_FILES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

# Android：目录 → 像素边长
ANDROID_FILES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def _mix(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def _darker(c, t=0.35):
    return _mix(c, (0, 0, 0), t)


def _lighter(c, t=0.45):
    return _mix(c, (255, 255, 255), t)


def build_master() -> Image.Image:
    """生成 1024 母版（**RGB，无 alpha**）。"""
    n = S * SS

    # ① 背景（+ 极轻颗粒 ⇒ 哑光）
    base = Image.new("RGB", (n, n), CRIMSON)
    noise = Image.effect_noise((n, n), 22).convert("RGB")
    base = Image.blend(base, noise, 0.02)

    # 字形 mask（真实字体渲染 ⇒ 字形 100% 正确）
    mask = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(mask)
    font = ImageFont.truetype(FONT_PATH, int(n * RATIO))
    bbox = d.textbbox((0, 0), CHAR, font=font, stroke_width=int(n * STROKE))
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text(((n - w) // 2 - bbox[0], (n - h) // 2 - bbox[1]), CHAR,
           font=font, fill=255, stroke_width=int(n * STROKE), stroke_fill=255)

    # ② 外投影（下偏 + 大模糊）⇒ 让字浮起来
    sh = Image.new("L", (n, n), 0)
    sh.paste(mask, (0, int(n * 0.022)))
    sh = sh.filter(ImageFilter.GaussianBlur(n * 0.020)).point(lambda v: int(v * 0.38))
    base = Image.composite(Image.new("RGB", (n, n), _darker(CRIMSON, 0.45)), base, sh)

    # ③ 字本体
    base = Image.composite(Image.new("RGB", (n, n), WARM_WHITE), base, mask)

    # ④ 底部内阴影（只在下缘）⇒ 厚度
    up = Image.new("L", (n, n), 0)
    up.paste(mask, (0, -int(n * 0.014)))
    bb = ImageChops.subtract(mask, up).filter(ImageFilter.GaussianBlur(n * 0.008))
    bb = bb.point(lambda v: int(v * 0.42))
    base = Image.composite(Image.new("RGB", (n, n), _darker(WARM_WHITE, 0.42)), base, bb)

    # ⑤ 顶部内高光（只在上缘）⇒ 受光
    dn = Image.new("L", (n, n), 0)
    dn.paste(mask, (0, int(n * 0.013)))
    tb = ImageChops.subtract(mask, dn).filter(ImageFilter.GaussianBlur(n * 0.010))
    tb = tb.point(lambda v: int(v * 0.55))
    base = Image.composite(Image.new("RGB", (n, n), _lighter(WARM_WHITE, 0.52)), base, tb)

    return base.resize((S, S), Image.LANCZOS).convert("RGB")


def export(master: Image.Image, install: bool) -> int:
    fails = []

    # ── iOS ────────────────────────────────────────────────
    ios_out = IOS_ICONSET if install else os.path.join(OUT_DIR, "ios-full")
    os.makedirs(ios_out, exist_ok=True)
    for name, side in IOS_FILES.items():
        img = master.resize((side, side), Image.LANCZOS).convert("RGB")
        img.save(os.path.join(ios_out, name), "PNG", optimize=True)

    # 🔴 断言：生成的文件名集合必须与 Contents.json 引用的完全一致
    #    （不一致 ⇒ Xcode 报「图标缺失 / 未被引用」）
    with open(os.path.join(IOS_ICONSET, "Contents.json"), encoding="utf-8") as f:
        cj = json.load(f)
    need = {i["filename"] for i in cj["images"] if "filename" in i}
    made = set(IOS_FILES)
    if need != made:
        fails.append(f"iOS 文件名集合不匹配：缺 {need - made} / 多 {made - need}")

    # ── Android ────────────────────────────────────────────
    for dpi, side in ANDROID_FILES.items():
        d = os.path.join(ANDROID_RES, dpi)
        assert os.path.isdir(d), f"Android 目录不存在：{d}"
        img = master.resize((side, side), Image.LANCZOS).convert("RGB")
        out = os.path.join(OUT_DIR, "android-full", dpi) if not install else d
        os.makedirs(out, exist_ok=True)
        img.save(os.path.join(out, "ic_launcher.png"), "PNG", optimize=True)

    # ── 校验：无 alpha ─────────────────────────────────────
    for name in IOS_FILES:
        p = os.path.join(ios_out, name)
        if Image.open(p).mode != "RGB":
            fails.append(f"{name} 不是 RGB（{Image.open(p).mode}）")
    p1024 = os.path.join(ios_out, "Icon-App-1024x1024@1x.png")
    if Image.open(p1024).size != (1024, 1024):
        fails.append("1024 图标尺寸不对")

    return 0 if not fails else (print("\n".join("🔴 " + f for f in fails)) or 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true", help="安装进 app/（先备份原图标）")
    a = ap.parse_args()

    print(f"字体：{os.path.basename(FONT_PATH)}  "
          f"({'✅' if os.path.isfile(FONT_PATH) else '🔴 缺失'})")
    print(f"字：{CHAR} · 字号 {int(RATIO*100)}% · 朱砂底白字 · {S}×{S} 母版\n")

    if a.install:
        # 备份原图标（可回滚）
        os.makedirs(BACKUP_DIR, exist_ok=True)
        for name in IOS_FILES:
            src = os.path.join(IOS_ICONSET, name)
            if os.path.isfile(src) and not os.path.isfile(os.path.join(BACKUP_DIR, name)):
                shutil.copy2(src, os.path.join(BACKUP_DIR, name))
        for dpi in ANDROID_FILES:
            src = os.path.join(ANDROID_RES, dpi, "ic_launcher.png")
            bdir = os.path.join(BACKUP_DIR, "android", dpi)
            os.makedirs(bdir, exist_ok=True)
            if os.path.isfile(src) and not os.path.isfile(os.path.join(bdir, "ic_launcher.png")):
                shutil.copy2(src, os.path.join(bdir, "ic_launcher.png"))
        print(f"✅ 原图标已备份 → {BACKUP_DIR}\n")

    master = build_master()
    master.save(os.path.join(OUT_DIR, "master-1024.png"), "PNG", optimize=True)
    print(f"✅ 母版 master-1024.png ({master.mode})")

    rc = export(master, a.install)
    if rc == 0:
        print(f"\n✅ iOS {len(IOS_FILES)} 个尺寸 → {IOS_ICONSET if a.install else OUT_DIR + '/ios-full'}")
        print(f"✅ Android {len(ANDROID_FILES)} 个密度 → {ANDROID_RES if a.install else OUT_DIR + '/android-full'}")
        print("✅ 全部 RGB 无 alpha · 文件名与 Contents.json 一致")
    return rc


if __name__ == "__main__":
    sys.exit(main())
