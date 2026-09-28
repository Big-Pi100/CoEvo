#!/usr/bin/env python3
"""中文字体候选对比页 —— 评估「用 OFL 字体替代阿里普惠体」

## 为什么需要这一页

现用的**阿里普惠体**（3 字重 **24.16 MB**）条款**禁止子集化**
（官方声明禁止事项 ② 含「**转换**」「**拆分**」）→ 无法瘦身。
而 **OFL 类**字体明确允许 modify / **subset** → 可子集到实际的 3,873 汉字，
**省约 21 MB**。

但「换字体」首先是**视觉决策** —— 只看表格选不出来。
所以这一页把**同一批真实 UI 文案**用两个字体渲染出来，供对照。

## 🔴 本脚本的合规做法（重要）

**不把字体文件内联进 HTML。**

· OFL 允许内联，但**阿里普惠体不允许**（禁止「上传、发布、转载阿里巴巴字体文件」）。
  把 TTF base64 内联进 HTML 再放进 git 仓库 = 在仓库里分发字体文件 → ❌ 越界。

· 本脚本改用 **PIL 渲染成 PNG** —— 那是「**用字体创建的内容**」，
  两家条款都明确允许（OFL 原文：「The requirement for fonts to remain under this
  license does **not** apply to any document created using the Font Software」）。
  → 两边都是位图截图，**零许可争议**，且对比更公平。

## 用法

    python3 scripts/fetch_fonts.py --only noto-sc   # 先取源（NotoSansSC-var.ttf）
    python3 scripts/build_cjk_font_compare.py       # 生成对比图

输出：
  · `docs/design/cjk-font-compare-2026-09-27.png`   —— 对比图
  · `data/fonts-build/NotoSansSC-{400,500,600,700}.ttf` —— 子集产物（供后续体积核算）

## 字符集

从**真实数据**提取（与 `build_fonts.py` 的 `cjk_charset()` 同一份）：
  `word.db` 全部文本字段 ∪ `app/lib/**.dart` 源码
  → 实测 **3,873 个汉字**（占 Noto Sans SC 全部汉字的 13.2%）
"""

import os
import sys

# 🔑 **复用 `build_fonts.py` 的字符集逻辑，不重复实现**
#    —— 子集构建的字符集是**单一出处**：那边改了这边必须跟着改，
#    所以直接 import 而不是复制一份（复制就会漂移）。
#    ⚠️ 本脚本的输出目录 `data/fonts-build/` 里已有 `build_fonts.py` 的拉丁产物
#       （`charis-*.woff2` 等），中文产物用 `NotoSansSC-*.ttf` 前缀，**不会撞名**。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_fonts import collect_cjk, cjk_charset  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, 'data', 'fonts-src')
BUILD_DIR = os.path.join(ROOT, 'data', 'fonts-build')
OUT_PNG = os.path.join(ROOT, 'docs', 'design', 'cjk-font-compare-2026-09-27.png')

APP_FONTS = os.path.join(ROOT, 'app', 'assets', 'fonts')

#: 现状（阿里普惠体，**全量、不子集** —— 条款不允许；此处仅用于渲染对照）
#:
#: 🔴 **2026-09-27 更新**：本对比已完成使命 —— 决策是「换成 Noto Sans SC」，
#:    阿里普惠体已从 `app/assets/fonts/` **删除**（可从 git 恢复：
#:    `git checkout HEAD -- app/assets/fonts/AlibabaPuHuiTi-3-*.ttf`）。
#:    → 所以**重跑本脚本会失败**（找不到对照字体），这是**预期行为**。
#:    对比图 `docs/design/cjk-font-compare-2026-09-27.png` 是决策依据的存档。
CURRENT = {
    400: os.path.join(APP_FONTS, 'AlibabaPuHuiTi-3-55-Regular.ttf'),
    500: os.path.join(APP_FONTS, 'AlibabaPuHuiTi-3-65-Medium.ttf'),
    700: os.path.join(APP_FONTS, 'AlibabaPuHuiTi-3-85-Bold.ttf'),
}

#: 候选（Noto Sans SC，可变 → 构建期 instance 成静态）
CAND_SRC = os.path.join(SRC_DIR, 'NotoSansSC-var.ttf')

#: 🔑 要实例化的字重。
#:
#: **为什么是这四个**：实测代码里的用法 —— `w500` 21 处 · **`w600` 69 处** ·
#: `w700` 1 处 · `normal`(=400) 12 处。
#: ⚠️ **现状缺 w600** —— 当前阿里普惠体只声明 400/500/700，
#:    所以那 69 处 `w600` 是 Flutter「**就近取**」（拿 500 或 700，或合成）。
#:    → 候选**补上真 600**，这 69 处的观感会更准（本页可对照看出差别）。
WEIGHTS = [400, 500, 600, 700]

#: 三档主题（值取自 `app/lib/theme/coevo_tokens.dart`，与 spec §2.1 一致）
THEMES = {
    'ink':   dict(label='墨（默认）', page='#F1EDE4', ink='#29251F', ink2='#6E6659', ink3='#988F7C'),
    'grid':  dict(label='格',        page='#EDEEF0', ink='#29251F', ink2='#5A5A5A', ink3='#8A8A8A'),
    'night': dict(label='夜',        page='#0B0D12', ink='#F2F0EC', ink2='#9AA0AE', ink3='#6E7484'),
}

#: 对照文案 —— **全部取自真实 UI**（不是编的例句）
#: 每条 = (用法说明, 字号, 字重, 文本)
SAMPLES = [
    ('页面标题', 23, 600, '今日精选'),
    ('页面标题', 23, 600, '收藏'),
    ('区块标题', 16, 600, '还没有收藏的文章'),
    ('正文说明', 13, 400, '读到喜欢的文章，点右上角的书签就能存下来，以后随时回来重读。'),
    ('副标题',   12, 400, '收藏的文章会一直留在这里，方便随时重读。'),
    ('引导行',   12, 400, '在卡片上找这个 图标'),
    ('标签',     11, 600, '阅读 复习 我的'),
    ('按钮',     11, 600, '收藏 12'),
    ('释义',     16, 400, '不再使用；放弃；抛弃 · 中止，放弃，停止'),
]

SCALE = 3          # 放大倍数（模拟 @3x，便于在小字号下看细节）
PAD = 22
COL_GAP = 26


# 🔑 `collect_cjk()` / `cjk_charset()` 已移到 `build_fonts.py`（子集构建的单一出处），
#    本脚本 import 复用，**不重复实现** —— 复制就会漂移。

def instance_and_subset():
    """把可变字体 instance 成静态字重并子集化。

    🔑 两步都是必需的：
      ① **instance** —— Noto Sans SC 的 `wght` 轴默认值是 **100（Thin）**！
         不显式 pin 就会得到极细的字重。且 Flutter 的 `fontWeight`
         **不会**驱动 VF 轴（要用 VF 得上 `FontVariation`）→ 构建期转静态最省事。
      ② **subset** —— 只留真实用到的 3,873 汉字 → 每字重约 1 MB。
    """
    from fontTools import subset
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer

    if not os.path.exists(CAND_SRC):
        sys.exit(f'🔴 缺源文件 {CAND_SRC}\n   先跑：python3 scripts/fetch_fonts.py --only noto-sc')

    # 🔑 字符集来自 `build_fonts.py`（**单一出处**，与生产子集用的是同一份）
    chars, _ = cjk_charset()
    os.makedirs(BUILD_DIR, exist_ok=True)
    out = {}
    print(f'子集字符集：{len(chars):,} 个码位（ASCII 95 + 中英标点 + 汉字 '
          f'{len(collect_cjk()):,}）\n')

    for w in WEIGHTS:
        ft = TTFont(CAND_SRC)
        # ⚠️ 必须 pin wght —— 默认 100(Thin)
        ft = instancer.instantiateVariableFont(ft, {'wght': w}, inplace=True,
                                               updateFontNames=False)
        # 子集前确认字形真的存在（spec §4.3 的教训：unicode-range 不可信）
        cmap_pre = ft.getBestCmap()
        missing = [c for c in chars if ord(c) not in cmap_pre]
        if missing:
            print(f'  ⚠️ wght={w}：{len(missing)} 个字符无字形 → {missing[:12]}')

        o = subset.Options()
        o.layout_features = ['*']
        o.name_IDs = ['*']
        o.notdef_outline = True
        o.drop_tables = ['DSIG']
        s = subset.Subsetter(options=o)
        s.populate(text=chars)
        s.subset(ft)

        dest = os.path.join(BUILD_DIR, f'NotoSansSC-{w}.ttf')
        ft.save(dest)
        ft.close()
        kb = os.path.getsize(dest) / 1024
        out[w] = dest
        print(f'  ✅ NotoSansSC-{w}.ttf  {kb:7.0f} KB')

    total = sum(os.path.getsize(p) for p in out.values()) / 1024 / 1024
    cur_total = sum(os.path.getsize(p) for p in CURRENT.values()) / 1024 / 1024
    print(f'\n  候选合计 {total:.2f} MB  vs  现状 {cur_total:.2f} MB'
          f'  → 省 {cur_total - total:.2f} MB')
    return out


def render(cand):
    """用 PIL 把对照文案渲染成 PNG。

    🔑 **不内联字体文件** —— 输出位图（见文件头「合规做法」）。
    """
    from PIL import Image, ImageDraw, ImageFont

    def fnt(path, size, px):
        return ImageFont.truetype(path, size * px)

    def pick(paths, weight):
        """按字重取字体文件；阿里普惠体没有 600 → 就近取 500（**如实反映现状**）。"""
        if weight in paths:
            return paths[weight]
        avail = sorted(paths)
        return paths[min(avail, key=lambda w: abs(w - weight))]

    # ── 先量尺寸 ──
    probe = ImageDraw.Draw(Image.new('RGB', (1, 1)))
    rows = []
    for theme_key, th in THEMES.items():
        for note, size, weight, text in SAMPLES:
            ws = []
            for label, paths in (('cur', CURRENT), ('cand', cand)):
                f = fnt(pick(paths, weight), size, SCALE)
                ws.append(probe.textbbox((0, 0), text, font=f)[2])
            rows.append((theme_key, th, note, size, weight, text, max(ws)))

    col_w = max(r[6] for r in rows) + 8

    # 每个主题块的高度 = 该档所有行高之和（行高随字号变，故逐行累加）
    heights = {}
    for k, th in THEMES.items():
        h = PAD
        for r in rows:
            if r[0] != k:
                continue
            h += max(r[3] * SCALE * 1.7, 22 * SCALE) + 14
        heights[k] = h + PAD

    W = PAD * 2 + col_w * 2 + COL_GAP
    H = sum(heights.values()) + PAD * len(THEMES) * 2 + 96
    img = Image.new('RGB', (int(W), int(H)), '#FFFFFF')
    d = ImageDraw.Draw(img)

    head = fnt(CURRENT[700], 13, SCALE)
    y = PAD
    d.text((PAD, y), '中文字体对照 —— 左：阿里普惠体（现状，24.16 MB，条款禁子集化）　'
                     '右：Noto Sans SC（OFL，可子集化，约 3 MB）',
           font=fnt(CURRENT[400], 12, SCALE), fill='#333333')
    y += 30 * SCALE

    for k, th in THEMES.items():
        # 主题块底板
        d.rectangle([PAD - 8, y - 8, W - PAD + 8, y + heights[k] - PAD + 4],
                    fill=th['page'])
        d.text((PAD, y), f'■ {th["label"]}', font=head, fill='#B4432C')
        y += 20 * SCALE + 6

        for r in rows:
            if r[0] != k:
                continue
            _, _, note, size, weight, text, _ = r
            line_h = max(size * SCALE * 1.7, 22 * SCALE)

            # 左侧：现状
            f_cur = fnt(pick(CURRENT, weight), size, SCALE)
            d.text((PAD, y), text, font=f_cur, fill=th['ink'])
            # 右侧：候选
            f_cand = fnt(pick(cand, weight), size, SCALE)
            d.text((PAD + col_w + COL_GAP, y), text, font=f_cand, fill=th['ink'])

            meta = f'{note} · {size}px · w{weight}'
            d.text((PAD + col_w + COL_GAP, y + line_h - 6),
                   meta, font=fnt(CURRENT[400], 8, SCALE), fill=th['ink3'])
            y += line_h + 14

        y += PAD

    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    img.save(OUT_PNG)
    print(f'\n✅ 对比图：{os.path.relpath(OUT_PNG, ROOT)}  ({img.width}×{img.height})')
    return OUT_PNG


def main():
    print('CoEvo 中文字体对比 —— 阿里普惠体（现状） vs Noto Sans SC（候选）\n')

    # 🔴 对照字体可能已不存在（2026-09-27 换字体后已从 assets 删除）→ 给明确指引，
    #    而不是让用户面对一句莫名其妙的 FileNotFoundError。
    missing = [f for f in CURRENT.values() if not os.path.exists(f)]
    if missing:
        print('🔴 缺少对照字体（阿里普惠体）：')
        for f in missing:
            print(f'     {os.path.relpath(f, ROOT)}')
        print('\n   原因：2026-09-27 已决定**换成 Noto Sans SC**，旧字体从 assets 删除。')
        print('   若要重跑本对比，先恢复：')
        print('     git checkout HEAD -- app/assets/fonts/AlibabaPuHuiTi-3-55-Regular.ttf \\')
        print('                            app/assets/fonts/AlibabaPuHuiTi-3-65-Medium.ttf \\')
        print('                            app/assets/fonts/AlibabaPuHuiTi-3-85-Bold.ttf')
        print('\n   ⚠️ 注意：阿里普惠体**条款禁止子集化**，恢复仅供本地渲染对照，')
        print('      不得用于生产（详见 docs/review/cjk-font-switch-evaluation-2026-09-27.md）')
        return 2

    cand = instance_and_subset()
    render(cand)
    return 0


if __name__ == '__main__':
    sys.exit(main())
