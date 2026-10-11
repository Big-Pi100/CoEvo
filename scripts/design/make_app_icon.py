#!/usr/bin/env python3
"""生成 App 图标候选（粘土风 · **真实字体渲染** · 零水印）。

# 为什么不用 AI 生成图（2026-10-11 实测结论）

| 问题 | 实测 |
|---|---|
| ① **字形不规范** | AI 生成的「记」把「讠」拆成**互不相连的三块**；「书」也不是标准 4 笔写法 |
| ② **带水印** | 每张右下角都有「**AI生成 WORKBUDDY**」水印 |

⇒ 图标上的字就是**品牌标识**，字形错很显眼；带水印则完全不能用。
⇒ 改用「**真实中文字体 + 图层化质感**」：字形 100% 正确、无任何水印、尺寸精确。

# 粘土质感（claymorphism）= 5 层，全部 PIL 可做

| 层 | 做法 | 作用 |
|---|---|---|
| ① 背景 | 纯色 + **极轻高斯噪点** | 哑光底（可选纸感/粘土颗粒）|
| ② 外投影 | 字形下偏 + **大模糊** + 低不透明度 | 让字「浮起来」|
| ③ 字本体 | 主色填充 | — |
| ④ **底部内阴影** | `mask & ~上移(mask)` ⇒ **只在下缘** | 给出**厚度**（粘土的核心）|
| ⑤ **顶部内高光** | `mask & ~下移(mask)` ⇒ **只在上缘** | 给出**受光** |

# 关键技术点

* 输出 **RGB（无 alpha）** —— 🔴 App Store 对 1024 图标的硬要求，带透明会直接报错
* **不加圆角** —— iOS 会自己裁圆角，自己加了会变成「圆角套圆角」
* 用 **`stroke_width`** 把细笔画加粗 ⇒ 幼圆（SIMYOU）+ 描边 = 圆润粗笔画，正是粘土形态
* 抗锯齿靠 **4 倍超采样**（在 4096 上画完再缩到 1024）

跑法：
    python scripts/design/make_app_icon.py            # 生成全部候选
    python scripts/design/make_app_icon.py --export   # 另出 iOS 全套尺寸
"""

from __future__ import annotations

import argparse
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 1024          # 最终边长
SS = 4            # 超采样倍数
FONT_PATH = r"C:\Windows\Fonts\SIMYOU.TTF"   # 幼圆（圆润 ⇒ 粘土形态）

# 品牌色（design-system-spec-2026-09-25）
CRIMSON = (0xB4, 0x43, 0x2C)   # 朱砂
PAPER = (0xF1, 0xED, 0xE4)     # 暖纸
WARM_WHITE = (0xF7, 0xF2, 0xEA)  # 纸白（朱砂底上的字）

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "docs", "design", "app-icon-candidates-2026-10-11",
)


def _mix(c1, c2, t):
    """线性混色：t=0 → c1，t=1 → c2。"""
    return tuple(int(round(a + (b - a) * t)) for a, b in zip(c1, c2))


def _darker(c, t=0.35):
    return _mix(c, (0, 0, 0), t)


def _lighter(c, t=0.45):
    return _mix(c, (255, 255, 255), t)


def _glyph_mask(char: str, size: int, font_px: int, stroke: int) -> Image.Image:
    """把字渲染成 L 模式的 mask（白=字）。白底黑字、居中。"""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    font = ImageFont.truetype(FONT_PATH, font_px)

    # 用 textbbox 精确居中（含描边宽度）
    bbox = d.textbbox((0, 0), char, font=font, stroke_width=stroke)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (size - w) // 2 - bbox[0]
    y = (size - h) // 2 - bbox[1]
    d.text((x, y), char, font=font, fill=255,
           stroke_width=stroke, stroke_fill=255)
    return m


def build(char: str, bg: tuple, fg: tuple, *, grain: float = 0.0) -> Image.Image:
    """按「5 层」合成一张图标。"""
    n = S * SS  # 超采样画布边长

    # ── ① 背景：纯色（+ 可选颗粒）────────────────────────────
    base = Image.new("RGB", (n, n), bg)
    if grain > 0:
        noise = Image.effect_noise((n, n), 22).convert("RGB")
        base = Image.blend(base, noise, grain)

    # 字 mask（在超采样画布上画 ⇒ 缩小时天然抗锯齿）
    mask = _glyph_mask(char, n, int(n * 0.60), int(n * 0.026))

    # ── ② 外投影（下偏 + 大模糊）────────────────────────────
    shadow = Image.new("L", (n, n), 0)
    shadow.paste(mask, (0, int(n * 0.022)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(n * 0.020))
    shadow = shadow.point(lambda v: int(v * 0.38))
    base = Image.composite(Image.new("RGB", (n, n), _darker(bg, 0.45)), base, shadow)

    # ── ③ 字本体 ────────────────────────────────────────────
    base = Image.composite(Image.new("RGB", (n, n), fg), base, mask)

    # ── ④ 底部内阴影（只留「下缘带」）⇒ 厚度 ────────────────
    up = Image.new("L", (n, n), 0)
    up.paste(mask, (0, -int(n * 0.014)))
    bottom_band = ImageChops.subtract(mask, up)                 # mask & ~上移
    bottom_band = bottom_band.filter(ImageFilter.GaussianBlur(n * 0.008))
    bottom_band = bottom_band.point(lambda v: int(v * 0.42))
    base = Image.composite(Image.new("RGB", (n, n), _darker(fg, 0.42)), base, bottom_band)

    # ── ⑤ 顶部内高光（只留「上缘带」）⇒ 受光 ────────────────
    dn = Image.new("L", (n, n), 0)
    dn.paste(mask, (0, int(n * 0.013)))
    top_band = ImageChops.subtract(mask, dn)
    top_band = top_band.filter(ImageFilter.GaussianBlur(n * 0.010))
    top_band = top_band.point(lambda v: int(v * 0.55))
    base = Image.composite(Image.new("RGB", (n, n), _lighter(fg, 0.52)), base, top_band)

    return base.resize((S, S), Image.LANCZOS)


CANDIDATES = [
    # (文件名, 字, 背景, 字色, 颗粒)
    ("A-朱砂底-记.png", "记", CRIMSON, WARM_WHITE, 0.02),
    ("B-朱砂底-书.png", "书", CRIMSON, WARM_WHITE, 0.02),
    ("C-纸底-记.png", "记", PAPER, CRIMSON, 0.05),
    ("D-纸底-书.png", "书", PAPER, CRIMSON, 0.05),
]

# iOS 需要的尺寸（Contents.json 里那套：20/29/40/60 的 1x2x3x + 1024）
IOS_SIZES = [20, 29, 40, 60, 76, 83.5, 1024]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", action="store_true",
                    help="另出 iOS 全套尺寸（从 A 候选导出）")
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"输出目录：{OUT_DIR}")
    print(f"字体：{FONT_PATH}  ({'✅ 存在' if os.path.isfile(FONT_PATH) else '🔴 缺失'})")
    print()

    made = []
    for name, ch, bg, fg, grain in CANDIDATES:
        img = build(ch, bg, fg, grain=grain)
        p = os.path.join(OUT_DIR, name)
        # 🔴 显式存 RGB（无 alpha）—— App Store 硬要求
        img.convert("RGB").save(p, "PNG", optimize=True)
        mode = Image.open(p).mode
        made.append((name, p, mode))
        print(f"  ✅ {name:16} {img.size}  mode={mode}  "
              f"{os.path.getsize(p)/1024:.0f} KB")

    if args.export:
        src = Image.open(made[0][1])
        ex = os.path.join(OUT_DIR, "ios-full")
        os.makedirs(ex, exist_ok=True)
        for s in IOS_SIZES:
            px = int(round(s * 2)) if s < 100 else 1024   # 简化：≥ 提 2x
            for scale in (1, 2, 3):
                if s >= 100:
                    if scale != 1:
                        continue
                    side = 1024
                else:
                    side = int(round(s * scale))
                if side > 1024:
                    continue
                img = src.resize((side, side), Image.LANCZOS).convert("RGB")
                img.save(os.path.join(ex, f"Icon-{s}x{s}@{scale}x.png"), "PNG")
        print(f"\n  ✅ iOS 全套尺寸 → {ex}")

    print(f"\n共 {len(made)} 张。全部 RGB（无 alpha）✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
