#!/usr/bin/env python3
"""App 图标「字体对比」预览（朱砂底 + 同一字 × 多种字体 + **iOS 圆角**）。

# 为什么要这个脚本

白哥反馈两点（2026-10-11）：
1. 「圆角好像小了，跟设计语言不一致」—— 🔴 **是我预览做错了**：
   我 present 的是**方形原图**（Apple 要求交付图必须方形、无 alpha、无圆角，
   由 iOS 自己裁 squircle）⇒ 但**预览**里看不到圆角，就没有「圆润」的观感。
   ⇒ 本脚本在**预览**上复原 iOS 圆角（≈ 边长 22.37%），交付图仍保持方形。
2. 「字体也不好看」—— 幼圆（SIMYOU）是 Windows 里最老的圆体，笔画粗细不均。
   本机其实装了 **思源宋体 Heavy / 思源黑体 Bold / HarmonyOS Sans Bold** 等现代字体。

# 交付 vs 预览（🔴 别混淆）

| | 形态 | 谁加圆角 |
|---|---|---|
| **交付给 iOS**（`make_app_icon.py` 的输出）| 方形满版 · RGB 无 alpha | iOS 自己裁 |
| **预览**（本脚本）| 圆角矩形 | 本脚本（仅为「看起来像真机」）|

跑法：`python scripts/design/preview_icon_fonts.py`
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_app_icon import CRIMSON, WARM_WHITE, build  # noqa: E402

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "docs", "design", "app-icon-candidates-2026-10-11",
)

# (显示名, 字体路径, ttc 的 index, 备注)
FONTS = [
    ("思源宋体 Heavy", r"C:\Windows\Fonts\Source Han Serif SC Heavy (TrueType).ttf", None, "衬线·书卷气"),
    ("思源黑体 Bold", r"C:\Windows\Fonts\Noto Sans SC Bold (TrueType).otf", None, "现代·通用"),
    ("HarmonyOS Sans Bold", r"C:\Windows\Fonts\HarmonyOS_Sans_SC_Bold.ttf", None, "几何·利落"),
    ("微软雅黑 Bold", r"C:\Windows\Fonts\msyhbd.ttc", 0, "稳妥·常见"),
    ("苹方 Medium", r"C:\Windows\Fonts\PingFang Medium.ttf", None, "苹果风(偏细)"),
    ("等线 Bold", r"C:\Windows\Fonts\Dengb.ttf", None, "细长现代"),
    ("黑体", r"C:\Windows\Fonts\simhei.ttf", None, "老派黑体"),
    ("楷体", r"C:\Windows\Fonts\simkai.ttf", None, "书法感(笔画细)"),
    ("幼圆（你否掉的）", r"C:\Windows\Fonts\SIMYOU.TTF", None, "对照"),
]

CHAR = "书"
CELL = 320          # 每格边长
PAD = 20
LBL = 62
COLS = 3

# iOS 图标圆角 ≈ 边长的 22.37%（squircle 近似）
CORNER_RATIO = 0.2237


def rounded(img: Image.Image, radius_ratio: float = CORNER_RATIO) -> Image.Image:
    """把方形图裁成 iOS 那样的圆角（**仅用于预览**）。"""
    s = img.size[0]
    r = int(s * radius_ratio)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=255)
    out = img.convert("RGB").copy()
    out.putalpha(mask)
    # 贴到浅灰底上，模拟桌面
    bg = Image.new("RGB", (s, s), (238, 238, 236))
    bg.paste(out, (0, 0), out)
    return bg


def build_graphic(char, bg, fg):
    """与 make_app_icon.build 同逻辑（**复用其质感参数**），字体由 `M.FONT_PATH` 决定。"""
    import make_app_icon as M

    n = M.S * M.SS
    base = M.Image.new("RGB", (n, n), bg)
    noise = M.Image.effect_noise((n, n), 22).convert("RGB")
    base = M.Image.blend(base, noise, 0.02)

    mask = M._glyph_mask(char, n, int(n * 0.60), int(n * 0.026))

    shadow = M.Image.new("L", (n, n), 0)
    shadow.paste(mask, (0, int(n * 0.022)))
    shadow = shadow.filter(M.ImageFilter.GaussianBlur(n * 0.020))
    shadow = shadow.point(lambda v: int(v * 0.38))
    base = M.Image.composite(M.Image.new("RGB", (n, n), M._darker(bg, 0.45)), base, shadow)

    base = M.Image.composite(M.Image.new("RGB", (n, n), fg), base, mask)

    up = M.Image.new("L", (n, n), 0)
    up.paste(mask, (0, -int(n * 0.014)))
    bb = M.ImageChops.subtract(mask, up).filter(M.ImageFilter.GaussianBlur(n * 0.008))
    bb = bb.point(lambda v: int(v * 0.42))
    base = M.Image.composite(M.Image.new("RGB", (n, n), M._darker(fg, 0.42)), base, bb)

    dn = M.Image.new("L", (n, n), 0)
    dn.paste(mask, (0, int(n * 0.013)))
    tb = M.ImageChops.subtract(mask, dn).filter(M.ImageFilter.GaussianBlur(n * 0.010))
    tb = tb.point(lambda v: int(v * 0.55))
    base = M.Image.composite(M.Image.new("RGB", (n, n), M._lighter(fg, 0.52)), base, tb)

    return base.resize((M.S, M.S), M.Image.LANCZOS)


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    rows = (len(FONTS) + COLS - 1) // COLS
    W = PAD + COLS * (CELL + PAD)
    H = PAD + rows * (CELL + LBL + PAD)
    canvas = Image.new("RGB", (W, H), (250, 250, 248))
    d = ImageDraw.Draw(canvas)
    try:
        f_big = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 21)
        f_sm = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 16)
    except Exception:  # noqa: BLE001
        f_big = f_sm = ImageFont.load_default()

    print(f"渲染「{CHAR}」× {len(FONTS)} 种字体（朱砂底 + 白字 + iOS 圆角预览）\n")
    import make_app_icon as M

    for i, (name, path, idx, note) in enumerate(FONTS):
        r, c = divmod(i, COLS)
        x = PAD + c * (CELL + PAD)
        y = PAD + r * (CELL + LBL + PAD)

        if not os.path.isfile(path):
            print(f"  🔴 {name}: 文件不存在")
            continue
        # 🔴 关键：_glyph_mask 用的是模块级 FONT_PATH ⇒ 必须改它，否则九格全是同一字体
        M.FONT_PATH = path
        img = build_graphic(CHAR, CRIMSON, WARM_WHITE)
        prev = rounded(img).resize((CELL, CELL), Image.LANCZOS)
        canvas.paste(prev, (x, y))
        d.text((x + 4, y + CELL + 8), name, fill=(30, 30, 30), font=f_big)
        d.text((x + 4, y + CELL + 34), note, fill=(140, 140, 140), font=f_sm)
        print(f"  ✅ {name:22} ({note})")

    out = os.path.join(OUT_DIR, "字体对比-朱砂底-书.png")
    canvas.save(out, "PNG")
    print(f"\n✅ {out}  {canvas.size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
