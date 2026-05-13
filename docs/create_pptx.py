#!/usr/bin/env python3
"""Generate CoEvo product manual PPT from product-manual.md"""

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

# ── Brand Colors ──
DEEP_BLUE   = RGBColor(0x1A, 0x1A, 0x2E)
VIOLET      = RGBColor(0x6C, 0x63, 0xFF)
WHITE       = RGBColor(0xFF, 0xFF, 0xFF)
LIGHT_GRAY  = RGBColor(0xF0, 0xF0, 0xF5)
DARK_TEXT    = RGBColor(0x33, 0x33, 0x33)
MEDIUM_TEXT = RGBColor(0x55, 0x55, 0x55)
ACCENT_GREEN = RGBColor(0x4C, 0xAF, 0x50)
ACCENT_ORANGE = RGBColor(0xFF, 0x98, 0x00)
ACCENT_RED    = RGBColor(0xE5, 0x39, 0x35)

SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)

prs = Presentation()
prs.slide_width = SLIDE_W
prs.slide_height = SLIDE_H


# ── Helper Functions ──

def add_bg(slide, color=DEEP_BLUE):
    """Fill slide background with a solid color."""
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_shape(slide, left, top, width, height, fill_color=None, line_color=None):
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, left, top, width, height)
    if fill_color:
        shape.fill.solid()
        shape.fill.fore_color.rgb = fill_color
    else:
        shape.fill.background()
    if line_color:
        shape.line.color.rgb = line_color
        shape.line.width = Pt(1)
    else:
        shape.line.fill.background()
    return shape


def add_rounded_rect(slide, left, top, width, height, fill_color=None, line_color=None):
    shape = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, left, top, width, height)
    if fill_color:
        shape.fill.solid()
        shape.fill.fore_color.rgb = fill_color
    else:
        shape.fill.background()
    if line_color:
        shape.line.color.rgb = line_color
        shape.line.width = Pt(1.5)
    else:
        shape.line.fill.background()
    return shape


def set_text(shape, text, font_size=14, bold=False, color=DARK_TEXT, align=PP_ALIGN.LEFT, font_name="Microsoft YaHei"):
    tf = shape.text_frame
    tf.word_wrap = True
    tf.auto_size = None
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(font_size)
    p.font.bold = bold
    p.font.color.rgb = color
    p.font.name = font_name
    p.alignment = align
    return tf


def add_text_box(slide, left, top, width, height, text, font_size=14, bold=False, color=DARK_TEXT, align=PP_ALIGN.LEFT, font_name="Microsoft YaHei"):
    txBox = slide.shapes.add_textbox(left, top, width, height)
    tf = txBox.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(font_size)
    p.font.bold = bold
    p.font.color.rgb = color
    p.font.name = font_name
    p.alignment = align
    return tf


def add_multiline_textbox(slide, left, top, width, height, lines, font_size=13, color=DARK_TEXT, align=PP_ALIGN.LEFT, line_spacing=1.3, bold_first=False):
    """Add a text box with multiple lines. lines is a list of strings or (text, bold) tuples."""
    txBox = slide.shapes.add_textbox(left, top, width, height)
    tf = txBox.text_frame
    tf.word_wrap = True
    for i, line in enumerate(lines):
        if i == 0:
            p = tf.paragraphs[0]
        else:
            p = tf.add_paragraph()
        
        if isinstance(line, tuple):
            text, is_bold = line
        else:
            text = line
            is_bold = (bold_first and i == 0)
        
        p.text = text
        p.font.size = Pt(font_size)
        p.font.bold = is_bold
        p.font.color.rgb = color
        p.font.name = "Microsoft YaHei"
        p.alignment = align
        p.space_after = Pt(4)
    return tf


def add_card(slide, left, top, width, height, title, body, title_color=VIOLET, bg_color=WHITE):
    """Add a card with title and body text."""
    card = add_rounded_rect(slide, left, top, width, height, fill_color=bg_color)
    card.shadow.inherit = False
    
    # Title
    add_text_box(slide, left + Inches(0.2), top + Inches(0.12), width - Inches(0.4), Inches(0.4),
                 title, font_size=13, bold=True, color=title_color)
    
    # Body
    if isinstance(body, list):
        add_multiline_textbox(slide, left + Inches(0.2), top + Inches(0.5), width - Inches(0.4), height - Inches(0.6),
                              body, font_size=11, color=DARK_TEXT)
    else:
        add_text_box(slide, left + Inches(0.2), top + Inches(0.5), width - Inches(0.4), height - Inches(0.6),
                     body, font_size=11, color=DARK_TEXT)


def add_violet_accent_line(slide, left, top, width):
    """Add a violet accent line."""
    line = add_shape(slide, left, top, width, Pt(3), fill_color=VIOLET)


# ══════════════════════════════════════════════
# SLIDE 1: COVER
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])  # Blank layout
add_bg(slide, DEEP_BLUE)

# Violet accent bar on left
add_shape(slide, Inches(0), Inches(0), Inches(0.12), SLIDE_H, fill_color=VIOLET)

# Decorative circle
circle = slide.shapes.add_shape(MSO_SHAPE.OVAL, Inches(0.5), Inches(0.5), Inches(0.8), Inches(0.8))
circle.fill.solid()
circle.fill.fore_color.rgb = VIOLET
circle.line.fill.background()

# Small decorative dots
dots_pos = [(Inches(0.4), Inches(1.5)), (Inches(0.7), Inches(1.3))]
for x, y in dots_pos:
    dot = slide.shapes.add_shape(MSO_SHAPE.OVAL, x, y, Inches(0.12), Inches(0.12))
    dot.fill.solid()
    dot.fill.fore_color.rgb = VIOLET
    dot.line.fill.background()

# Main title
add_text_box(slide, Inches(1.2), Inches(1.5), Inches(8), Inches(1),
             "刻意进化学习", font_size=48, bold=True, color=WHITE, align=PP_ALIGN.LEFT)

add_text_box(slide, Inches(1.2), Inches(2.5), Inches(8), Inches(0.6),
             "CoEvo", font_size=24, bold=False, color=RGBColor(0xAA, 0xAA, 0xCC), align=PP_ALIGN.LEFT)

# Violet line separator
add_shape(slide, Inches(1.2), Inches(3.3), Inches(3), Pt(3), fill_color=VIOLET)

# Product description
add_text_box(slide, Inches(1.2), Inches(3.7), Inches(10), Inches(0.6),
             "AI 特级教师", font_size=36, bold=True, color=VIOLET, align=PP_ALIGN.LEFT)

add_text_box(slide, Inches(1.2), Inches(4.4), Inches(10), Inches(0.8),
             "主动教 · 主动考 · 主动追薄弱点", font_size=20, bold=False, 
             color=RGBColor(0xBB, 0xBB, 0xDD), align=PP_ALIGN.LEFT)

# Subtitle
add_text_box(slide, Inches(1.2), Inches(5.3), Inches(10), Inches(0.5),
             "AI 对话 → 学习计划 → 主动教学 → 实时考核 → 科学复习 → 家长报告", 
             font_size=14, color=RGBColor(0x88, 0x88, 0xAA), align=PP_ALIGN.LEFT)

# Bottom info bar
bar = add_shape(slide, Inches(0), Inches(6.8), SLIDE_W, Inches(0.7), fill_color=RGBColor(0x12, 0x12, 0x20))
add_text_box(slide, Inches(0.5), Inches(6.85), Inches(12), Inches(0.5),
             "如果不想被 AI 取代，你需要刻意进化。",
             font_size=13, color=RGBColor(0x88, 0x88, 0xAA), align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 2: 一句话说清楚
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

# Title
add_text_box(slide, Inches(0.8), Inches(0.5), Inches(10), Inches(0.6),
             "CoEvo 是什么？", font_size=30, bold=True, color=DEEP_BLUE, align=PP_ALIGN.LEFT)

# Decorative line under title
add_shape(slide, Inches(0.8), Inches(1.1), Inches(2), Pt(3), fill_color=VIOLET)

# Main content box
content_box = add_rounded_rect(slide, Inches(0.8), Inches(1.5), Inches(11.5), Inches(5.2), 
                                fill_color=RGBColor(0xF5, 0xF5, 0xFA))

# Large quote
add_text_box(slide, Inches(1.2), Inches(1.7), Inches(10.5), Inches(0.6),
             "CoEvo 是一个 AI 特级教师。", font_size=28, bold=True, color=DEEP_BLUE)

# Process flow
flow_items = [
    ("①", "家长设定目标", "告诉AI想让孩子学什么"),
    ("②", "AI生成计划", "自动生成分阶段学习计划"),
    ("③", "每天主动教学", "AI按计划教→考→追薄弱→确认掌握→推进"),
    ("④", "科学复习不忘", "FSRS算法在遗忘前弹出复习"),
    ("⑤", "家长看报告", "每天30秒看进度"),
]

y_start = Inches(2.5)
for i, (num, title, desc) in enumerate(flow_items):
    y = y_start + Inches(i * 0.65)
    # Number circle
    circ = slide.shapes.add_shape(MSO_SHAPE.OVAL, Inches(1.3), y, Inches(0.4), Inches(0.4))
    circ.fill.solid()
    circ.fill.fore_color.rgb = VIOLET
    circ.line.fill.background()
    tf = circ.text_frame
    tf.paragraphs[0].text = num
    tf.paragraphs[0].font.size = Pt(14)
    tf.paragraphs[0].font.bold = True
    tf.paragraphs[0].font.color.rgb = WHITE
    tf.paragraphs[0].alignment = PP_ALIGN.CENTER
    
    # Title
    add_text_box(slide, Inches(1.9), y, Inches(3), Inches(0.4), 
                 title, font_size=16, bold=True, color=DEEP_BLUE)
    # Description
    add_text_box(slide, Inches(4.8), y, Inches(7), Inches(0.4),
                 desc, font_size=14, color=MEDIUM_TEXT)

# Bottom quote
add_text_box(slide, Inches(1.2), Inches(5.8), Inches(10.5), Inches(0.5),
             "这不是一个对话机器人——这是一个有课程大纲、有教学方法、有考核标准、有复习策略的 AI 教师。",
             font_size=13, bold=True, color=VIOLET, align=PP_ALIGN.CENTER)

# Bottom accent
add_shape(slide, Inches(0.8), Inches(6.6), Inches(11.5), Pt(2), fill_color=VIOLET)


# ══════════════════════════════════════════════
# SLIDE 3: 核心机制 — AI特级教师6步教学
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

# Title
add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "AI 特级教师：每天的教学流程", font_size=28, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(0.8), Inches(0.9), Inches(10), Inches(0.4),
             "孩子打开App，AI按学习计划主动推进", font_size=14, color=MEDIUM_TEXT)

# 6-step flow with cards
steps = [
    ("① 讲解新知识点", "AI 按学习计划推进\n不是等孩子问——像老师上课一样", DEEP_BLUE),
    ("② 实时考核", "边讲边问，判断是否真正理解\n教完立刻出题", VIOLET),
    ("③ 发现薄弱点", "答错不是直接给答案\n从不同角度换一种方式再讲", ACCENT_ORANGE),
    ("④ 针对性攻克", "连续出错 → AI 停下来深挖\n换讲法、换例子——直到真懂", ACCENT_RED),
    ("⑤ 确认掌握 → 推进", "确认掌握了才进入下一个\n全部自动完成", ACCENT_GREEN),
    ("⑥ 复习旧知识", "之前学过的按记忆曲线安排\n答对拉长间隔，答错加练", DEEP_BLUE),
]

card_w = Inches(3.7)
card_h = Inches(2.2)
gap_x = Inches(0.35)
gap_y = Inches(0.3)
start_x = Inches(0.8)
start_y = Inches(1.5)

colors_bg = [
    RGBColor(0xEE, 0xEE, 0xF8),
    RGBColor(0xEE, 0xEE, 0xF8),
    RGBColor(0xFF, 0xF3, 0xE0),
    RGBColor(0xFF, 0xEB, 0xEB),
    RGBColor(0xE8, 0xF5, 0xE9),
    RGBColor(0xEE, 0xEE, 0xF8),
]

for i, (title, body, accent) in enumerate(steps):
    row = i // 3
    col = i % 3
    x = start_x + col * (card_w + gap_x)
    y = start_y + row * (card_h + gap_y)
    
    # Card background
    card = add_rounded_rect(slide, x, y, card_w, card_h, fill_color=colors_bg[i])
    # Top accent line on card
    add_shape(slide, x, y, card_w, Pt(4), fill_color=accent)
    
    # Step number and title
    add_text_box(slide, x + Inches(0.15), y + Inches(0.15), card_w - Inches(0.3), Inches(0.4),
                 title, font_size=14, bold=True, color=accent)
    
    # Description
    add_text_box(slide, x + Inches(0.15), y + Inches(0.6), card_w - Inches(0.3), card_h - Inches(0.8),
                 body, font_size=11, color=DARK_TEXT)

# Bottom note
add_text_box(slide, Inches(0.8), Inches(6.6), Inches(11), Inches(0.4),
             "全部在 AI 对话中完成，不需要切换任何界面。制卡 + 复习 + 验证全部自动，不需要手动操作。",
             font_size=12, color=MEDIUM_TEXT, align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 4: 竞品本质区别
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "和所有竞品的本质区别", font_size=28, bold=True, color=DEEP_BLUE)

# Comparison table
table_data = [
    ["维度", "ChatGPT", "Anki", "学习机/辅导班", "CoEvo"],
    ["有教学大纲", "❌", "❌", "✅ 固定课表", "✅ AI定制"],
    ["主动教学", "❌ 你问才答", "❌", "✅ 老师讲", "✅ AI按计划"],
    ["实时考核", "❌", "❌", "课后考试", "✅ 边教边考"],
    ["找薄弱点", "❌", "❌", "❌ 等考试", "✅ 实时检测"],
    ["掌握才推进", "❌", "❌", "❌ 按进度", "✅ 掌握才通过"],
    ["科学复习", "❌", "✅", "❌ 统一作业", "✅ FSRS"],
    ["像什么", "百科全书", "单词本", "学校/补习班", "AI特级教师"],
]

rows = len(table_data)
cols = len(table_data[0])
table_left = Inches(0.8)
table_top = Inches(1.2)
table_w = Inches(11.5)
table_h = Inches(4.5)

table = slide.shapes.add_table(rows, cols, table_left, table_top, table_w, table_h).table

# Column widths
col_widths = [Inches(1.5), Inches(2.2), Inches(1.8), Inches(2.8), Inches(3.2)]
for i, w in enumerate(col_widths):
    table.columns[i].width = w

# Style table
for r in range(rows):
    for c in range(cols):
        cell = table.cell(r, c)
        cell.text = table_data[r][c]
        cell.vertical_anchor = MSO_ANCHOR.MIDDLE
        
        for paragraph in cell.text_frame.paragraphs:
            paragraph.alignment = PP_ALIGN.CENTER
            paragraph.font.size = Pt(11)
            paragraph.font.name = "Microsoft YaHei"
            
            if r == 0:  # Header row
                paragraph.font.bold = True
                paragraph.font.color.rgb = WHITE
            elif c == 0:  # First column
                paragraph.font.bold = True
                paragraph.font.color.rgb = DEEP_BLUE
            elif c == cols - 1:  # CoEvo column
                paragraph.font.bold = True
                paragraph.font.color.rgb = VIOLET
            else:
                paragraph.font.color.rgb = DARK_TEXT
        
        # Cell fill
        if r == 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = DEEP_BLUE
        elif r % 2 == 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0xF5, 0xF5, 0xFA)
        else:
            cell.fill.solid()
            cell.fill.fore_color.rgb = WHITE
        
        # CoEvo column highlight
        if c == cols - 1 and r > 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0xF0, 0xEE, 0xFF)

# Bottom note
add_text_box(slide, Inches(0.8), Inches(5.9), Inches(11.5), Inches(1.0),
             "市场上没有第二个产品同时做到：有教学大纲、主动教学、实时考核、自动找薄弱点、掌握才推进、科学复习——全部在一个产品里。",
             font_size=12, color=MEDIUM_TEXT, align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 5: 家长使用流程
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, DEEP_BLUE)

# Violet accent
add_shape(slide, Inches(0), Inches(0), Inches(0.12), SLIDE_H, fill_color=VIOLET)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "家长使用流程：总共约 1-5 分钟上手", font_size=28, bold=True, color=WHITE)
add_text_box(slide, Inches(0.8), Inches(0.9), Inches(10), Inches(0.4),
             "之后每天花 30 秒看进度", font_size=16, color=RGBColor(0xBB, 0xBB, 0xDD))

steps_flow = [
    ("30秒", "告诉AI目标", "发一句语音或打一行字：\n\"初一数学方程基础差，想用一个月打好基础\""),
    ("30秒~5分钟", "确认学习计划", "看一眼AI生成的分阶段计划\n觉得合适 → 回复\"可以\""),
    ("自动进行", "AI每天主动教学", "AI按计划教→考→追薄弱→推进\n孩子在对话中完成全部学习"),
    ("每天30秒", "看进度", "打开App看今日概览\n学了什么、掌握率、薄弱点"),
]

y_pos = Inches(1.5)
for i, (time, title, desc) in enumerate(steps_flow):
    x = Inches(0.8) + Inches(i * 3.05)
    
    # Time badge
    badge = add_rounded_rect(slide, x, y_pos, Inches(2.5), Inches(0.35), fill_color=VIOLET)
    set_text(badge, time, font_size=11, bold=True, color=WHITE, align=PP_ALIGN.CENTER)
    
    # Title
    add_text_box(slide, x, y_pos + Inches(0.45), Inches(2.5), Inches(0.4),
                 title, font_size=16, bold=True, color=WHITE)
    
    # Description
    add_text_box(slide, x, y_pos + Inches(0.9), Inches(2.8), Inches(1.5),
                 desc, font_size=11, color=RGBColor(0xBB, 0xBB, 0xDD))
    
    # Arrow (except last)
    if i < 3:
        arrow_x = x + Inches(2.6)
        arrow = add_text_box(slide, arrow_x, y_pos + Inches(0.15), Inches(0.5), Inches(0.4),
                             "→", font_size=24, bold=True, color=VIOLET, align=PP_ALIGN.CENTER)

# Summary bar
bar = add_rounded_rect(slide, Inches(0.8), Inches(5.5), Inches(11.5), Inches(1.2), 
                        fill_color=RGBColor(0x25, 0x25, 0x40))
add_text_box(slide, Inches(1), Inches(5.6), Inches(5), Inches(0.4),
             "家长全部投入", font_size=14, bold=True, color=VIOLET)
add_multiline_textbox(slide, Inches(1), Inches(5.95), Inches(10), Inches(0.7), [
    "首次：30秒说目标 + 30秒确认计划",
    "之后每天：30秒看进度  ·  每周：1分钟扫一眼周报",
], font_size=12, color=RGBColor(0xCC, 0xCC, 0xDD))


# ══════════════════════════════════════════════
# SLIDE 6: 学科覆盖
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "学科覆盖范围", font_size=28, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(0.8), Inches(0.9), Inches(11), Inches(0.4),
             "基于 DeepSeek 模型，AI 几乎囊括了人类已有的全部知识",
             font_size=14, color=MEDIUM_TEXT)

# Verified section
add_text_box(slide, Inches(0.8), Inches(1.4), Inches(5), Inches(0.4),
             "✅ 经过完整测试流程", font_size=18, bold=True, color=ACCENT_GREEN)

verified_items = [
    ("K12 课程", "数学、物理、化学、生物\n英语、语文、历史、地理"),
    ("编程", "Python、C++、JavaScript"),
    ("英语考试", "托福、雅思、考研英语"),
    ("职场技能", "Excel、PPT、项目管理"),
    ("大学专业", "高等数学、线性代数等"),
]

for i, (title, desc) in enumerate(verified_items):
    x = Inches(0.8) + (i % 3) * Inches(3.8)
    y = Inches(1.9) + (i // 3) * Inches(1.7)
    
    card = add_rounded_rect(slide, x, y, Inches(3.5), Inches(1.4), 
                             fill_color=RGBColor(0xE8, 0xF5, 0xE9))
    add_shape(slide, x, y, Inches(3.5), Pt(3), fill_color=ACCENT_GREEN)
    add_text_box(slide, x + Inches(0.15), y + Inches(0.1), Inches(3.2), Inches(0.35),
                 title, font_size=14, bold=True, color=ACCENT_GREEN)
    add_text_box(slide, x + Inches(0.15), y + Inches(0.5), Inches(3.2), Inches(0.8),
                 desc, font_size=11, color=DARK_TEXT)

# To be explored section
y_explore = Inches(5.0)
add_text_box(slide, Inches(0.8), y_explore, Inches(5), Inches(0.4),
             "🔍 待探索", font_size=18, bold=True, color=ACCENT_ORANGE)

explore_box = add_rounded_rect(slide, Inches(0.8), y_explore + Inches(0.4), Inches(11.5), Inches(1.2),
                                fill_color=RGBColor(0xFF, 0xF8, 0xE1))
add_text_box(slide, Inches(1), y_explore + Inches(0.5), Inches(11), Inches(0.9),
             "哲学、心理学、投资理财、摄影、乐理、法律基础……\nAI知识库里还有大量内容，理论上都可以学习。一个账号 = 一个人，家里有几个孩子就几个账号，进度不混。",
             font_size=12, color=DARK_TEXT)


# ══════════════════════════════════════════════
# SLIDE 7: 核心 Q&A — vs ChatGPT / vs 学习机
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "常见问题", font_size=28, bold=True, color=DEEP_BLUE)

# Q1
q1_box = add_rounded_rect(slide, Inches(0.8), Inches(1.2), Inches(5.6), Inches(2.6), 
                           fill_color=RGBColor(0xF5, 0xF5, 0xFA))
add_shape(slide, Inches(0.8), Inches(1.2), Inches(5.6), Pt(3), fill_color=VIOLET)
add_text_box(slide, Inches(1), Inches(1.3), Inches(5.2), Inches(0.4),
             "和 ChatGPT 有什么区别？", font_size=15, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(1), Inches(1.75), Inches(5.2), Inches(2.0),
             "ChatGPT 是你问它答——你不知道问什么，它就不教。\n\nCoEvo 是 AI 主动教——它有一套完整的学习计划，知道今天该学什么、该考什么、该复习什么。\n\nChatGPT 像百科全书，CoEvo 像特级教师。",
             font_size=11, color=DARK_TEXT)

# Q2
q2_box = add_rounded_rect(slide, Inches(6.8), Inches(1.2), Inches(5.6), Inches(2.6),
                           fill_color=RGBColor(0xF5, 0xF5, 0xFA))
add_shape(slide, Inches(6.8), Inches(1.2), Inches(5.6), Pt(3), fill_color=ACCENT_ORANGE)
add_text_box(slide, Inches(7), Inches(1.3), Inches(5.2), Inches(0.4),
             "和学习机/点读笔有什么区别？", font_size=15, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(7), Inches(1.75), Inches(5.2), Inches(2.0),
             "学习机播课——孩子看完就完了，记住了多少不知道。\n\nCoEvo 不止教学，它边教边考。教的每一个知识点当场验证，没懂就继续教，掌握了才进入下一个。\n\n学习机是播课，CoEvo 是教学+考核+追薄弱。",
             font_size=11, color=DARK_TEXT)

# Q5 - Replaces tutoring
q5_box = add_rounded_rect(slide, Inches(0.8), Inches(4.1), Inches(5.6), Inches(2.6),
                           fill_color=RGBColor(0xF5, 0xF5, 0xFA))
add_shape(slide, Inches(0.8), Inches(4.1), Inches(5.6), Pt(3), fill_color=ACCENT_GREEN)
add_text_box(slide, Inches(1), Inches(4.2), Inches(5.2), Inches(0.4),
             "CoEvo 能替代辅导班吗？", font_size=15, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(1), Inches(4.65), Inches(5.2), Inches(2.0),
             "能。辅导班老师面对几十个学生顾不过来。\n\nCoEvo 一对一：教新课 ✅ 出题考核 ✅ 找薄弱点 ✅ 攻克难点 ✅ 复习旧知识 ✅ 给家长报告 ✅\n\n辅导班一个月¥3,000-8,000，CoEvo 首批合伙人 ¥1,288 终身。",
             font_size=11, color=DARK_TEXT)

# Q7 - Age
q7_box = add_rounded_rect(slide, Inches(6.8), Inches(4.1), Inches(5.6), Inches(2.6),
                           fill_color=RGBColor(0xF5, 0xF5, 0xFA))
add_shape(slide, Inches(6.8), Inches(4.1), Inches(5.6), Pt(3), fill_color=VIOLET)
add_text_box(slide, Inches(7), Inches(4.2), Inches(5.2), Inches(0.4),
             "孩子多大可以用？", font_size=15, bold=True, color=DEEP_BLUE)
add_text_box(slide, Inches(7), Inches(4.65), Inches(5.2), Inches(2.0),
             "只要基本完成识字就可以用，一般 6-7 岁以上。年龄没有上限，大人自己用来学新东西也完全可以。\n\n不合适：幼儿园及学龄前（识字量不够）。",
             font_size=11, color=DARK_TEXT)


# ══════════════════════════════════════════════
# SLIDE 8: 产品界面概览
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, DEEP_BLUE)
add_shape(slide, Inches(0), Inches(0), Inches(0.12), SLIDE_H, fill_color=VIOLET)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "产品界面概览", font_size=28, bold=True, color=WHITE)

# Interface cards
pages = [
    ("💬 对话页", "主学习界面\nAI在这里教学、考核\n攻克薄弱点\n全部自动进行"),
    ("📋 学习计划", "当前学习计划展示\n阶段进展、任务状态\n一目了然"),
    ("🔄 复习页", "过往知识点的\n科学复习\nAI按记忆曲线安排"),
    ("📊 家长看板", "学习报告、每日概览\n薄弱点追踪\n家长30秒看懂进度"),
    ("🗂 卡片库", "所有已学知识点的\n卡片列表\n可按学科筛选"),
    ("🏆 个人主页", "学习统计数据\n成就勋章墙"),
]

for i, (title, desc) in enumerate(pages):
    col = i % 3
    row = i // 3
    x = Inches(0.8) + col * Inches(3.9)
    y = Inches(1.3) + row * Inches(2.8)
    
    card = add_rounded_rect(slide, x, y, Inches(3.5), Inches(2.4), 
                             fill_color=RGBColor(0x25, 0x25, 0x40))
    add_shape(slide, x, y, Inches(3.5), Pt(3), fill_color=VIOLET)
    
    add_text_box(slide, x + Inches(0.15), y + Inches(0.15), Inches(3.2), Inches(0.4),
                 title, font_size=14, bold=True, color=WHITE)
    add_text_box(slide, x + Inches(0.15), y + Inches(0.6), Inches(3.2), Inches(1.6),
                 desc, font_size=11, color=RGBColor(0xBB, 0xBB, 0xDD))

# Bottom: child flow vs parent flow
add_text_box(slide, Inches(0.8), Inches(6.4), Inches(11.5), Inches(0.8),
             "👧 孩子：打开App → AI教学→出题→纠正→推进 → \"今日完成\" ✅\n👩 家长：打开看板 → 看今日概览 → 知道薄弱点 → 关闭，耗时约30秒",
             font_size=12, color=RGBColor(0xAA, 0xAA, 0xCC), align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 9: 与竞品完整对比
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, WHITE)
add_violet_accent_line(slide, Inches(0), Inches(0), SLIDE_W)

add_text_box(slide, Inches(0.8), Inches(0.4), Inches(10), Inches(0.6),
             "与竞品完整对比", font_size=28, bold=True, color=DEEP_BLUE)

# Comparison table - detailed
comp_data = [
    ["维度", "ChatGPT", "Anki", "学习机", "辅导班", "CoEvo"],
    ["主动教学", "❌", "❌", "❌ 播课", "✅ 老师", "✅ AI特级教师"],
    ["实时考核", "❌", "❌", "❌", "❌ 考试", "✅ 边教边考"],
    ["发现薄弱点", "❌", "❌", "❌", "❌ 经验", "✅ 逐知识点"],
    ["攻克才推进", "❌", "❌", "❌", "❌ 课表", "✅ 掌握再进"],
    ["科学复习", "❌", "✅", "❌", "❌ 作业", "✅ FSRS"],
    ["家长报告", "❌", "❌", "❌", "❌ 口头", "✅ 精确报告"],
    ["定制计划", "❌", "❌", "❌ 固定", "❌ 固定", "✅ AI定制"],
    ["价格", "免费/¥140月", "免费", "¥1k-3k", "¥3k-8k/月", "¥1,288 终身"],
]

rows = len(comp_data)
cols = len(comp_data[0])
tbl_left = Inches(0.5)
tbl_top = Inches(1.1)
tbl_w = Inches(12.3)
tbl_h = Inches(4.8)

table = slide.shapes.add_table(rows, cols, tbl_left, tbl_top, tbl_w, tbl_h).table
col_ws = [Inches(1.3), Inches(2.0), Inches(1.6), Inches(1.8), Inches(2.0), Inches(3.6)]
for i, w in enumerate(col_ws):
    table.columns[i].width = w

for r in range(rows):
    for c in range(cols):
        cell = table.cell(r, c)
        cell.text = comp_data[r][c]
        cell.vertical_anchor = MSO_ANCHOR.MIDDLE
        for para in cell.text_frame.paragraphs:
            para.alignment = PP_ALIGN.CENTER
            para.font.size = Pt(10)
            para.font.name = "Microsoft YaHei"
            if r == 0:
                para.font.bold = True
                para.font.color.rgb = WHITE
            elif c == 0:
                para.font.bold = True
                para.font.color.rgb = DEEP_BLUE
            elif c == cols - 1:
                para.font.bold = True
                para.font.color.rgb = VIOLET
            else:
                para.font.color.rgb = DARK_TEXT
        
        if r == 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = DEEP_BLUE
        elif r % 2 == 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0xF5, 0xF5, 0xFA)
        else:
            cell.fill.solid()
            cell.fill.fore_color.rgb = WHITE
        if c == cols - 1 and r > 0:
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0xF0, 0xEE, 0xFF)

# Bottom note
add_text_box(slide, Inches(0.8), Inches(6.1), Inches(11.5), Inches(1.0),
             "CoEvo 是唯一同时具备：主动教学 + 实时考核 + 自动找薄弱点 + 掌握才推进 + 科学复习 + 家长报告的 AI 学习产品。",
             font_size=13, bold=True, color=VIOLET, align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 10: 合伙人计划 — CTA
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, DEEP_BLUE)
add_shape(slide, Inches(0), Inches(0), Inches(0.12), SLIDE_H, fill_color=VIOLET)

add_text_box(slide, Inches(0.8), Inches(0.5), Inches(10), Inches(0.6),
             "首批合伙人计划", font_size=30, bold=True, color=WHITE)

# Pricing highlight
price_box = add_rounded_rect(slide, Inches(0.8), Inches(1.4), Inches(5.5), Inches(3.5),
                              fill_color=RGBColor(0x25, 0x25, 0x40))
add_shape(slide, Inches(0.8), Inches(1.4), Inches(5.5), Pt(3), fill_color=VIOLET)

add_text_box(slide, Inches(1.2), Inches(1.6), Inches(5), Inches(0.4),
             "🔥 终身合伙人", font_size=22, bold=True, color=VIOLET)

add_text_box(slide, Inches(1.2), Inches(2.2), Inches(5), Inches(0.8),
             "¥1,288", font_size=48, bold=True, color=WHITE)

add_text_box(slide, Inches(1.2), Inches(3.0), Inches(5), Inches(0.4),
             "终身使用 · 限 20 个名额", font_size=14, color=RGBColor(0xBB, 0xBB, 0xDD))

add_text_box(slide, Inches(1.2), Inches(3.5), Inches(5), Inches(1.0),
             "后续正式价：¥100-200/月 或 ¥1,288/年\n首批合伙人 = 终身省掉每年的续费",
             font_size=12, color=RGBColor(0x99, 0x99, 0xBB))

# Comparison vs tutoring
compare_box = add_rounded_rect(slide, Inches(6.8), Inches(1.4), Inches(5.5), Inches(3.5),
                                fill_color=RGBColor(0x25, 0x25, 0x40))
add_shape(slide, Inches(6.8), Inches(1.4), Inches(5.5), Pt(3), fill_color=ACCENT_GREEN)

add_text_box(slide, Inches(7.2), Inches(1.6), Inches(5), Inches(0.4),
             "和辅导班对比", font_size=22, bold=True, color=ACCENT_GREEN)

add_multiline_textbox(slide, Inches(7.2), Inches(2.2), Inches(5), Inches(2.5), [
    ("辅导班：¥3,000 - ¥8,000 / 月", False),
    ("  → 每月接送、盯作业、沟通老师", False),
    ("  → 一个老师对几十个学生", False),
    ("  → 效果不可量化", False),
    ("", False),
    ("CoEvo ¥1,288 终身", True),
    ("  → 30秒设定目标，之后每天30秒看报告", False),
    ("  → AI一对一，逐知识点追踪", False),
    ("  → 精确到每个知识点的掌握数据", False),
], font_size=12, color=RGBColor(0xCC, 0xCC, 0xDD))

# Trust note
trust_box = add_rounded_rect(slide, Inches(0.8), Inches(5.3), Inches(11.5), Inches(1.2),
                              fill_color=RGBColor(0x20, 0x20, 0x35))
add_text_box(slide, Inches(1.2), Inches(5.4), Inches(10.5), Inches(1.0),
             "30 天不满意全额退款 · 我们全程协助配置\n你和孩子没有任何风险，只需试试。",
             font_size=16, bold=False, color=RGBColor(0xCC, 0xCC, 0xDD), align=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════
# SLIDE 11: 封底
# ══════════════════════════════════════════════
slide = prs.slides.add_slide(prs.slide_layouts[6])
add_bg(slide, DEEP_BLUE)
add_shape(slide, Inches(0), Inches(0), Inches(0.12), SLIDE_H, fill_color=VIOLET)

add_text_box(slide, Inches(0.8), Inches(2.0), Inches(10), Inches(0.8),
             "刻意进化学习", font_size=40, bold=True, color=WHITE, align=PP_ALIGN.CENTER)

add_text_box(slide, Inches(0.8), Inches(2.8), Inches(10), Inches(0.5),
             "CoEvo", font_size=22, color=RGBColor(0xAA, 0xAA, 0xCC), align=PP_ALIGN.CENTER)

add_shape(slide, Inches(5), Inches(3.5), Inches(3), Pt(3), fill_color=VIOLET)

add_text_box(slide, Inches(0.8), Inches(3.9), Inches(10), Inches(0.6),
             "如果不想被 AI 取代，你需要刻意进化。", font_size=20, bold=True, color=VIOLET, align=PP_ALIGN.CENTER)

add_text_box(slide, Inches(0.8), Inches(4.7), Inches(10), Inches(0.5),
             "免费试学，满意再付费", font_size=16, color=RGBColor(0xBB, 0xBB, 0xDD), align=PP_ALIGN.CENTER)

add_text_box(slide, Inches(0.8), Inches(5.4), Inches(10), Inches(0.5),
             "微信联系：XXXXXXXXX", font_size=14, color=RGBColor(0x88, 0x88, 0xAA), align=PP_ALIGN.CENTER)

# Bottom bar
bar = add_shape(slide, Inches(0), Inches(6.8), SLIDE_W, Inches(0.7), fill_color=RGBColor(0x12, 0x12, 0x20))
add_text_box(slide, Inches(0.5), Inches(6.85), Inches(12), Inches(0.5),
             "© 2026 刻意进化 · CoEvo",
             font_size=12, color=RGBColor(0x66, 0x66, 0x88), align=PP_ALIGN.CENTER)


# ── Save ──
output_path = r"E:\CoEvo\docs\CoEvo_产品手册.pptx"
prs.save(output_path)
print(f"✅ PPT saved to: {output_path}")
print(f"   Slides: {len(prs.slides)}")
